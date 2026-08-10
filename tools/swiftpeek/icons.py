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

# Thresholds, calibrated against a real inventory (iPhone13,1 / iOS 17.3, 201
# entries of which 95 carry genuine artwork). The first cut used values guessed
# from synthetic test icons and flagged 189 of 201 as needing a per-app
# override, which is worse than useless — an override list is only meaningful
# if it is the exception. Real app artwork is far denser than a synthetic
# glyph: measured edge density runs p25 0.052 / median 0.085 / p90 0.150, so
# "busy" has to mean the top decile, not everything above a synthetic baseline.
GLYPH_ONLY_COVERAGE = 0.55   # below this, there is no plate to speak of
FLAT_PLATE_RATIO = 0.70      # real median is 0.415; a true flat plate is p85+
LOW_CONTRAST_SPAN = 0.36     # real p05 is 0.354 — below that auto-levels bands
BUSY_EDGE_DENSITY = 0.150    # real p90; above this the ramp fights the artwork

# Signature of the generic placeholder UIKit returns for a bundle that has no
# icon of its own — 106 of those 201 entries were this exact image. They are UI
# service bundles that never appear on the Home Screen. SwiftPeek 0.4.1 filters
# them on-device via `appTags`; this is the backstop for dumps taken before
# that, and for firmwares that tag things differently.
PLACEHOLDER_MEAN_HEX = "#f2f2f2"
PLACEHOLDER_DOMINANT_HEX = "#ffffff"


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


def is_placeholder(sig: dict[str, Any]) -> bool:
    """True for the blank icon UIKit substitutes when a bundle has none."""
    if not sig:
        return False
    if (sig.get("mean_hex") == PLACEHOLDER_MEAN_HEX
            and sig.get("dominant_hex") == PLACEHOLDER_DOMINANT_HEX):
        return True
    # Belt and braces: fully desaturated and uniformly near-white.
    try:
        if (float(sig.get("saturation_mean", 1.0)) <= 0.001
                and float(sig.get("luma_p02", 0.0)) >= 0.85):
            return True
    except (TypeError, ValueError):
        pass
    return False


def iter_icons(dump: dict[str, Any], *, skip_placeholders: bool = True
               ) -> Iterable[dict[str, Any]]:
    for entry in dump.get("icons") or []:
        if not isinstance(entry, dict) or not entry.get("bundle_id"):
            continue
        if skip_placeholders and not entry.get("theme_override"):
            sig = entry.get("icon_signature")
            if isinstance(sig, dict) and is_placeholder(sig):
                continue
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
    all_entries = list(iter_icons(dump, skip_placeholders=False))
    kept = list(iter_icons(dump))
    skipped = len(all_entries) - len(kept)
    verdicts = [classify_icon(e) for e in kept]

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
            "placeholders_skipped": skipped,
            "themed": sum(1 for v in verdicts if v.themed),
            "shapes": shapes,
            "contrast": contrasts,
            "needs_override": len(per_app),
        },
        "per_app": per_app,
        "verdicts": [v.as_dict() for v in verdicts],
    }


# The four quantities the thresholds cut against, and which side of the cut
# counts as "selected" — i.e. the branch that produces a per-app override.
_CALIBRATED = (
    ("alpha_coverage", "GLYPH_ONLY_COVERAGE", GLYPH_ONLY_COVERAGE, "below"),
    ("plate_ratio", "FLAT_PLATE_RATIO", FLAT_PLATE_RATIO, "at_or_above"),
    ("luma_span", "LOW_CONTRAST_SPAN", LOW_CONTRAST_SPAN, "below"),
    ("edge_density", "BUSY_EDGE_DENSITY", BUSY_EDGE_DENSITY, "at_or_above"),
)

_PERCENTILES = (5, 25, 50, 75, 90, 95)


def _percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile. No numpy — this package stays dependency-free."""
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (pct / 100.0) * (len(ordered) - 1)
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    frac = rank - low
    return ordered[low] * (1.0 - frac) + ordered[high] * frac


def calibration_report(dump: dict[str, Any]) -> dict[str, Any]:
    """Where this dump's measurements actually fall against the thresholds.

    The thresholds in this module are tuned to one real inventory (iPhone13,1 /
    iOS 17.3). A first attempt tuned them against synthetic icons instead and
    flagged 189 of 201 entries as needing a per-app override — an override list
    is only useful when it is the exception, so that was worse than useless.

    Nothing here changes a threshold. It reports the distribution each threshold
    is cutting and the resulting override rate, so a dump from another device or
    firmware can be checked in one command rather than by eye. If the override
    rate is not a small minority, the thresholds do not transfer to that dump —
    which is a finding about the dump, not a licence to retune blind.
    """
    entries = list(iter_icons(dump, skip_placeholders=True))
    total_raw = len(dump.get("icons") or [])

    samples: dict[str, list[float]] = {name: [] for name, _, _, _ in _CALIBRATED}
    readable = 0
    for entry in entries:
        sig = _sig(entry)
        if not sig or not sig.get("opaque_pixels"):
            continue
        readable += 1
        try:
            samples["alpha_coverage"].append(float(sig.get("alpha_coverage") or 0.0))
            samples["plate_ratio"].append(float(sig.get("plate_ratio") or 0.0))
            samples["luma_span"].append(
                float(sig.get("luma_p98") or 0.0) - float(sig.get("luma_p02") or 0.0)
            )
            samples["edge_density"].append(float(sig.get("edge_density") or 0.0))
        except (TypeError, ValueError):
            continue

    metrics = []
    for name, const_name, value, side in _CALIBRATED:
        values = samples[name]
        if side == "below":
            selected = sum(1 for v in values if v < value)
        else:
            selected = sum(1 for v in values if v >= value)
        metrics.append({
            "metric": name,
            "threshold_name": const_name,
            "threshold": value,
            "selects": side,
            "selected": selected,
            "selected_pct": (selected / len(values)) if values else 0.0,
            "percentiles": {f"p{p:02d}": _percentile(values, p) for p in _PERCENTILES},
            "samples": len(values),
        })

    verdicts = [classify_icon(e) for e in entries]
    overridden = sum(1 for v in verdicts if v.settings)

    return {
        "device_model": dump.get("device_model"),
        "ios_version": dump.get("ios_version"),
        "icons_in_dump": total_raw,
        "analysed": len(entries),
        "readable_artwork": readable,
        "placeholders_skipped": total_raw - len(entries),
        "overrides": overridden,
        "override_rate": (overridden / len(verdicts)) if verdicts else 0.0,
        "metrics": metrics,
    }


def format_calibration(report: dict[str, Any]) -> str:
    lines = [
        f"device        {report.get('device_model') or '?'}"
        f"  iOS {report.get('ios_version') or '?'}",
        f"icons         {report['icons_in_dump']} in dump, "
        f"{report['analysed']} analysed "
        f"({report['placeholders_skipped']} placeholders skipped), "
        f"{report['readable_artwork']} with readable artwork",
        "",
        f"{'metric':<15}{'threshold':>10} {'selects':>12} "
        + " ".join(f"{'p%02d' % p:>7}" for p in _PERCENTILES),
    ]
    for m in report["metrics"]:
        pcts = " ".join(f"{m['percentiles'][f'p{p:02d}']:>7.3f}" for p in _PERCENTILES)
        lines.append(
            f"{m['metric']:<15}{m['threshold']:>10.3f} "
            f"{m['selected']:>4} {m['selected_pct']:>6.1%} {pcts}"
        )

    rate = report["override_rate"]
    lines.append("")
    lines.append(f"per-app overrides: {report['overrides']}/{report['analysed']} ({rate:.1%})")
    # The 189/201 run was 94%. A third is already high enough to be worth a look.
    if rate > 0.34:
        lines.append(
            "  WARNING: overrides are not a small minority — these thresholds do"
        )
        lines.append(
            "  not transfer to this dump. Re-check against a real inventory before"
        )
        lines.append("  changing any constant.")
    return "\n".join(lines)


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
