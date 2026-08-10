"""Analyse SwiftPeek 0.4.0 icon-inventory dumps and emit a Glyph tint plan.

A SpringBoard dump carries an `icons` array, one entry per installed app, each
with an M3 pixel signature. That signature answers the questions an icon
recolouring engine actually has to answer before it can tint anything:

* Is this full-bleed artwork, or a glyph floating on transparency? A glyph-only
  icon needs a synthesised plate or it comes out as a shape hanging in space.
* How much contrast does it carry? Flat artwork has a degenerate auto-levels
  window and needs the ramp dialled back.
* Is a legacy IconBundles / SnowBoard override already installed for it? Then
  the pack's PNG is the base layer, not the stock icon.

`build_tint_plan` turns all of that into per-app settings Glyph can consume
directly as its `perApp` preference dictionary.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

# Glyph's GLMode values (Glyph/src/GLPixelKit.h). Kept in sync by hand; the
# CLI prints them by name so a drift shows up immediately.
MODE_STOCK = 0
MODE_TINTED = 1
MODE_TINTED_LIGHT = 2
MODE_DARK = 3
MODE_CLEAR_GLASS = 4
MODE_CLEAR_GLASS_DARK = 5

MODE_NAMES = {
    MODE_STOCK: "stock",
    MODE_TINTED: "tinted",
    MODE_TINTED_LIGHT: "tintedLight",
    MODE_DARK: "dark",
    MODE_CLEAR_GLASS: "glass",
    MODE_CLEAR_GLASS_DARK: "glassDark",
}

# Thresholds. These mirror the ones GLApplyRecipe uses on device so the host
# plan and the runtime agree about what a given icon is.
GLYPH_ONLY_COVERAGE = 0.55   # below this, there is no plate to speak of
FLAT_PLATE_RATIO = 0.45      # this much of one quantised colour == a flat plate
LOW_CONTRAST_SPAN = 0.18     # p98 - p02 below this is degenerate for auto-levels
BUSY_EDGE_DENSITY = 0.045    # dense detail: photographic or heavily textured


@dataclass
class IconVerdict:
    bundle_id: str
    display_name: str
    shape: str                 # full_bleed | glyph_only | flat_plate
    contrast: str              # normal | low | busy
    themed: bool               # a legacy pack already overrides this icon
    notes: list[str] = field(default_factory=list)
    settings: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "bundle_id": self.bundle_id,
            "shape": self.shape,
            "contrast": self.contrast,
            "themed": self.themed,
        }
        if self.display_name:
            out["display_name"] = self.display_name
        if self.notes:
            out["notes"] = list(self.notes)
        if self.settings:
            out["settings"] = dict(self.settings)
        return out


def load_icon_dump(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text())


def iter_icons(dump: dict[str, Any]) -> Iterable[dict[str, Any]]:
    for entry in dump.get("icons") or []:
        if isinstance(entry, dict) and entry.get("bundle_id"):
            yield entry


def _sig(entry: dict[str, Any]) -> dict[str, Any]:
    """Prefer the themed override's signature — that is the bitmap Glyph will
    actually composite when a pack provides one."""
    themed = entry.get("theme_signature")
    if isinstance(themed, dict) and themed.get("opaque_pixels"):
        return themed
    sig = entry.get("icon_signature")
    return sig if isinstance(sig, dict) else {}


def classify_icon(entry: dict[str, Any]) -> IconVerdict:
    sig = _sig(entry)
    bundle_id = str(entry.get("bundle_id") or "")
    name = str(entry.get("display_name") or "")
    themed = bool(entry.get("theme_override"))

    verdict = IconVerdict(
        bundle_id=bundle_id,
        display_name=name,
        shape="full_bleed",
        contrast="normal",
        themed=themed,
    )

    if not sig or not sig.get("opaque_pixels"):
        verdict.shape = "unknown"
        verdict.notes.append("no readable artwork")
        return verdict

    coverage = float(sig.get("alpha_coverage") or 0.0)
    plate_ratio = float(sig.get("plate_ratio") or 0.0)
    p02 = float(sig.get("luma_p02") or 0.0)
    p98 = float(sig.get("luma_p98") or 0.0)
    edges = float(sig.get("edge_density") or 0.0)

    if coverage < GLYPH_ONLY_COVERAGE:
        verdict.shape = "glyph_only"
        verdict.settings["plateFill"] = True
        verdict.notes.append(
            f"only {coverage:.0%} coverage — needs a synthesised plate"
        )
    elif plate_ratio >= FLAT_PLATE_RATIO:
        verdict.shape = "flat_plate"
        verdict.notes.append(f"{plate_ratio:.0%} of pixels are one flat colour")

    span = p98 - p02
    if span < LOW_CONTRAST_SPAN:
        verdict.contrast = "low"
        # Auto-levels on a near-flat histogram amplifies noise into banding.
        verdict.settings["tintLevels"] = 0.35
        verdict.settings["tintContrast"] = 0.15
        verdict.notes.append(
            f"luminance span {span:.2f} — auto-levels dialled back"
        )
    elif edges >= BUSY_EDGE_DENSITY:
        verdict.contrast = "busy"
        # Dense artwork keeps more of its own structure with a softer ramp.
        verdict.settings["tintContrast"] = 0.20
        verdict.notes.append(f"edge density {edges:.3f} — busy artwork")

    if themed:
        verdict.notes.append("legacy theme override in place")

    return verdict


def build_tint_plan(dump: dict[str, Any], mode: int = MODE_TINTED,
                    tint: str = "#FF5FB2") -> dict[str, Any]:
    """Per-app Glyph settings derived from an inventory dump.

    The `per_app` block is shaped for Glyph's `perApp` preference key; entries
    only appear for icons that actually need something other than the global
    recipe, so the plan stays small and readable.
    """
    verdicts = [classify_icon(e) for e in iter_icons(dump)]

    per_app: dict[str, Any] = {}
    for v in verdicts:
        if v.settings:
            entry: dict[str, Any] = dict(v.settings)
            per_app[v.bundle_id] = entry

    shapes: dict[str, int] = {}
    contrasts: dict[str, int] = {}
    for v in verdicts:
        shapes[v.shape] = shapes.get(v.shape, 0) + 1
        contrasts[v.contrast] = contrasts.get(v.contrast, 0) + 1

    return {
        "generated_by": "swiftpeek icons",
        "source": {
            "device_model": dump.get("device_model"),
            "ios_version": dump.get("ios_version"),
            "tool_version": dump.get("tool_version"),
            "timestamp": dump.get("timestamp"),
        },
        "global": {
            "iconMode": mode,
            "mode_name": MODE_NAMES.get(mode, str(mode)),
            "tintColor": tint,
            "plateFill": True,
        },
        "summary": {
            "icons": len(verdicts),
            "themed": sum(1 for v in verdicts if v.themed),
            "shapes": shapes,
            "contrast": contrasts,
            "needs_override": len(per_app),
        },
        "per_app": per_app,
        "verdicts": [v.as_dict() for v in verdicts],
    }


def format_icons(verdicts: list[IconVerdict], limit: int = 0) -> str:
    rows = verdicts[:limit] if limit else verdicts
    lines = []
    for v in rows:
        flag = "T" if v.themed else " "
        note = ("; ".join(v.notes)) if v.notes else ""
        lines.append(
            f"{flag} {v.shape:<11} {v.contrast:<6} {v.bundle_id:<44} {note}"
        )
    return "\n".join(lines)
