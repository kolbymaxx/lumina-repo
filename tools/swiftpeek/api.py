from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator

from .paths import DEFAULT_CATALOG


#: Where the bundled catalog came from. See docs/OFFLINE_MUSIC_FIELDS.md.
#:
#: This is not trivia — it is the answer to a failure that cost real builds.
#: Music27 1.1.36 read `MusicApplication.NowPlayingControlsViewController` out
#: of this catalog and laid out against `artworkView`, `dismissButton` and
#: eighteen more named fields. On an iOS 17.3 device the class is
#: `MusicNowPlayingControlsViewController`, every catalog name came back
#: `missing`, and a follow-up ivar enumeration returned `count=1` — that one
#: being `_view`. The catalog was not wrong; it was answering for a different
#: firmware, and nothing at the point of use said so.
DEFAULT_CATALOG_PROVENANCE = "iOS 16.7.10 (20H350), iPhone10,3 / iPhone10,6"


def load_dump(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text())


@dataclass
class FieldHit:
    type_name: str
    name: str
    type_hint: str
    index: int
    source: str  # "field" | "screen_string"
    node: dict[str, Any]


class FieldCatalog:
    """Offline MusicApplication (etc.) field layouts from swiftmd."""

    def __init__(self, path: str | Path | None = None):
        self.path = Path(path) if path else DEFAULT_CATALOG
        raw = json.loads(self.path.read_text())
        self._full: dict[str, dict[str, Any]] = raw
        self._short: dict[str, list[str]] = {}
        for full in self._full:
            short = full.rsplit(".", 1)[-1]
            self._short.setdefault(short, []).append(full)
        # A caller-supplied catalog may name its own firmware in a sidecar; the
        # bundled one is described by the constant above.
        sidecar = self.path.with_suffix(".provenance")
        if sidecar.is_file():
            self.provenance = sidecar.read_text().strip()
        elif self.path == DEFAULT_CATALOG:
            self.provenance = DEFAULT_CATALOG_PROVENANCE
        else:
            self.provenance = "unknown"

    def __len__(self) -> int:
        return len(self._full)

    def lookup(self, type_name: str | None, objc: str | None = None) -> dict[str, Any] | None:
        # Every hit carries where it came from. A consumer reading field names
        # off this is about to write layout code against them, and that is the
        # moment it needs to know which firmware answered.
        for cand in (type_name, objc):
            if not cand:
                continue
            if cand in self._full:
                return {"key": cand, "provenance": self.provenance, **self._full[cand]}
            base = cand.split("<", 1)[0]
            if base in self._full:
                return {"key": base, "provenance": self.provenance, **self._full[base]}
            short = base.rsplit(".", 1)[-1]
            hits = self._short.get(short) or []
            pref = [h for h in hits if h.startswith("MusicApplication.")]
            chosen = pref or hits
            if chosen:
                k = chosen[0]
                return {"key": k, "provenance": self.provenance, **self._full[k]}
        return None

    def fields_for(self, type_name: str | None, objc: str | None = None) -> list[dict[str, Any]]:
        hit = self.lookup(type_name, objc)
        if not hit:
            return []
        return list(hit.get("fields") or [])


def annotate_dump(dump: dict[str, Any], catalog: FieldCatalog | None = None) -> dict[str, Any]:
    cat = catalog or FieldCatalog()
    nodes = dump.get("nodes") or []
    annotated: list[dict[str, Any]] = []
    matched = 0
    for node in nodes:
        out = dict(node)
        hit = cat.lookup(node.get("type"), node.get("objc_class"))
        if hit and hit.get("fields"):
            out["offline_fields"] = hit["fields"]
            out["offline_type"] = hit["key"]
            out["offline_kind"] = hit.get("kind")
            matched += 1
        else:
            out["offline_fields"] = []
        annotated.append(out)

    result = dict(dump)
    result["nodes"] = annotated
    result["offline_annotate"] = {
        "matched_nodes": matched,
        "total_nodes": len(annotated),
        "catalog_types": len(cat),
        "note": "layouts from offline swiftmd; not live FOVO",
        "api_version": "0.5.0",
    }
    return result


class PeekSession:
    """Read API over a live dump (+ optional annotate)."""

    def __init__(
        self,
        dump: dict[str, Any] | str | Path,
        catalog: FieldCatalog | None = None,
        *,
        annotate: bool = True,
    ):
        if isinstance(dump, (str, Path)):
            data = load_dump(dump)
        else:
            data = dump
        self.catalog = catalog or FieldCatalog()
        if annotate:
            data = annotate_dump(data, self.catalog)
        self.dump = data

    @property
    def nodes(self) -> list[dict[str, Any]]:
        return list(self.dump.get("nodes") or [])

    @property
    def windows(self) -> list[dict[str, Any]]:
        """UIWindow snapshot, ascending windowLevel (SwiftPeek 0.4.0+).

        Empty for dumps written by older builds.
        """
        return list(self.dump.get("windows") or [])

    @staticmethod
    def _view_flags(node: dict[str, Any]) -> list[str]:
        flags = []
        if node.get("hidden"):
            flags.append("HIDDEN")
        alpha = node.get("alpha")
        if isinstance(alpha, (int, float)) and alpha < 0.999:
            flags.append(f"alpha={alpha:.2f}")
        if node.get("opaque"):
            flags.append("OPAQUE")
        bg = node.get("background")
        if bg and bg not in ("clear", "nil"):
            flags.append(f"bg={bg}")
        # SwiftPeek 0.5.0+. A view with no backgroundColor can still be the thing
        # painting the screen — Music's artwork-derived player background is a
        # CAGradientLayer, invisible to a view-only walk.
        layer_bg = node.get("layer_background")
        if layer_bg and layer_bg not in ("clear", "nil"):
            flags.append(f"layerbg={layer_bg}")
        gradient = node.get("gradient")
        if gradient:
            flags.append(f"gradient=[{gradient}]")
        if node.get("invisible"):
            flags.append("<-- INVISIBLE")
        return flags

    def windows_table(self, *, views: bool = False) -> list[str]:
        """One aligned line per window — the fastest way to eyeball an overlay.

        Reads as: level, frame, class, root view controller, flags. With
        ``views=True`` each window is followed by its indented view subtree,
        which is where a correctly-placed overlay hiding an empty or zero-sized
        subview shows itself.
        """
        rows = []
        for w in self.windows:
            flags = self._view_flags(w)
            if w.get("is_key"):
                flags.insert(0, "KEY")
            rows.append(
                "level={:<8.1f} {:<22} {:<28} root={:<28} {}".format(
                    float(w.get("level") or 0),
                    str(w.get("frame") or "?"),
                    str(w.get("class") or "?"),
                    str(w.get("root_vc") or "?"),
                    " ".join(flags),
                )
            )
            if not views:
                continue
            for node in w.get("views") or []:
                depth = int(node.get("depth") or 0)
                rows.append(
                    "    {}{:<34} {:<22} {}".format(
                        "  " * depth,
                        str(node.get("class") or "?"),
                        str(node.get("frame") or "?"),
                        " ".join(self._view_flags(node)),
                    ).rstrip()
                )
        return rows

    def summary(self) -> dict[str, Any]:
        nodes = self.nodes
        ann = self.dump.get("offline_annotate") or {}
        return {
            "tool_version": self.dump.get("tool_version"),
            "milestone": self.dump.get("milestone"),
            "message": self.dump.get("message"),
            "nodes": len(nodes),
            "windows": len(self.windows),
            "matched_nodes": ann.get("matched_nodes"),
            "catalog_types": ann.get("catalog_types", len(self.catalog)),
            "with_fields": sum(1 for n in nodes if n.get("offline_fields")),
            "with_strings": sum(1 for n in nodes if n.get("screen_strings")),
        }

    def iter_types(self) -> Iterator[dict[str, Any]]:
        for n in self.nodes:
            yield {
                "type": n.get("offline_type") or n.get("type") or n.get("objc_class"),
                "role": n.get("role"),
                "field_count": len(n.get("offline_fields") or []),
                "string_count": len(n.get("screen_strings") or []),
                "screen_strings": n.get("screen_strings") or [],
                "address": n.get("address"),
            }

    def nodes_matching(self, needle: str) -> list[dict[str, Any]]:
        n = needle.lower()
        out = []
        for node in self.nodes:
            blob = " ".join(
                str(x or "")
                for x in (node.get("offline_type"), node.get("type"), node.get("objc_class"))
            ).lower()
            if n in blob:
                out.append(node)
        return out

    def fields(self, type_needle: str) -> list[dict[str, Any]]:
        """Return field lists for nodes whose type matches substring."""
        rows = []
        for node in self.nodes_matching(type_needle):
            rows.append(
                {
                    "type": node.get("offline_type") or node.get("type"),
                    "fields": node.get("offline_fields") or [],
                    "screen_strings": node.get("screen_strings") or [],
                }
            )
        return rows

    def find(self, needle: str) -> list[FieldHit]:
        n = needle.lower()
        hits: list[FieldHit] = []
        for node in self.nodes:
            t = node.get("offline_type") or node.get("type") or "?"
            for f in node.get("offline_fields") or []:
                name = str(f.get("name") or "")
                typ = str(f.get("type") or "")
                if n in name.lower() or n in typ.lower():
                    hits.append(
                        FieldHit(
                            type_name=t,
                            name=name,
                            type_hint=typ,
                            index=int(f.get("index") or 0),
                            source="field",
                            node=node,
                        )
                    )
            for s in node.get("screen_strings") or []:
                if n in str(s).lower():
                    hits.append(
                        FieldHit(
                            type_name=t,
                            name=str(s),
                            type_hint="screen_string",
                            index=-1,
                            source="screen_string",
                            node=node,
                        )
                    )
        return hits
