#!/usr/bin/env python3
"""Smoke tests for the SwiftPeek read API (no device required)."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from swiftpeek.api import FieldCatalog, PeekSession, annotate_dump  # noqa: E402
from swiftpeek.paths import DEFAULT_CATALOG  # noqa: E402


SAMPLE = {
    "tool_version": "0.3.6",
    "milestone": 2,
    "message": "test",
    "nodes": [
        {
            "type": "MusicApplication.MiniPlayerViewController",
            "role": "scan_controller",
            "screen_strings": ["kiss me", "Ariana Grande"],
        },
        {
            "type": "MusicApplication.NowPlayingContentView",
            "role": "scan_view",
        },
        {
            "type": (
                "MusicApplication.SearchViewController"
                "<MusicApplication.SearchLandingViewController>"
            ),
            "role": "scan_controller",
            "screen_strings": ["Search"],
        },
    ],
}


# Shaped exactly like a 0.4.0 on-device window dump: ascending windowLevel,
# app window at 0, tweak overlay above it, system window on top.
WINDOW_SAMPLE = {
    "tool_version": "0.4.0",
    "milestone": 1,
    "message": "window scan nodes=0 windows=3",
    "nodes": [],
    "windows": [
        {
            "class": "UIWindow",
            "level": 0.0,
            "frame": "{0,0,390,844}",
            "hidden": False,
            "opaque": True,
            "alpha": 1.0,
            "is_key": True,
            "background": "nil",
            "root_vc": "MusicApplication.RootViewController",
            "root_view_loaded": True,
        },
        {
            "class": "M27DockOverlayWindow",
            "level": 2.0,
            "frame": "{0,0,390,844}",
            "hidden": False,
            "opaque": False,
            "alpha": 1.0,
            "is_key": False,
            "background": "clear",
            "root_vc": "UIViewController",
            "root_view_loaded": True,
        },
        {
            "class": "UITextEffectsWindow",
            "level": 999.0,
            "frame": "{0,0,390,844}",
            "hidden": True,
            "opaque": False,
            "alpha": 1.0,
            "is_key": False,
            "background": "nil",
            "root_vc": "nil",
            "root_view_loaded": False,
        },
    ],
}


class ReadAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not DEFAULT_CATALOG.is_file():
            raise unittest.SkipTest(f"missing catalog {DEFAULT_CATALOG}")
        cls.catalog = FieldCatalog(DEFAULT_CATALOG)

    def test_catalog_nonempty(self):
        self.assertGreater(len(self.catalog), 1000)

    def test_bundled_catalog_names_its_firmware(self):
        # Music27 1.1.36 laid out against catalog field names that do not exist
        # on iOS 17.3, because nothing at the point of use said which firmware
        # the catalog described. It says so now.
        self.assertIn("16.7", self.catalog.provenance)

    def test_lookup_carries_provenance(self):
        hit = self.catalog.lookup("MusicApplication.MiniPlayerViewController")
        self.assertIsNotNone(hit)
        self.assertEqual(hit["provenance"], self.catalog.provenance)

    def test_foreign_catalog_provenance_is_not_guessed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "other-catalog.json"
            path.write_text(json.dumps({"Foo.Bar": {"kind": "class", "fields": []}}))
            cat = FieldCatalog(path)
            self.assertEqual(cat.provenance, "unknown")

    def test_sidecar_overrides_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "other-catalog.json"
            path.write_text(json.dumps({"Foo.Bar": {"kind": "class", "fields": []}}))
            path.with_suffix(".provenance").write_text("iOS 17.3 (21D50), iPhone13,1\n")
            cat = FieldCatalog(path)
            self.assertEqual(cat.provenance, "iOS 17.3 (21D50), iPhone13,1")

    def test_annotate_matches(self):
        out = annotate_dump(SAMPLE, self.catalog)
        info = out["offline_annotate"]
        self.assertEqual(info["matched_nodes"], 3)
        self.assertEqual(info["api_version"], "0.5.0")
        mini = out["nodes"][0]
        self.assertTrue(mini["offline_fields"])
        names = {f["name"] for f in mini["offline_fields"]}
        self.assertIn("artworkView", names)

    def test_session_find_artwork(self):
        sess = PeekSession(SAMPLE, self.catalog)
        hits = sess.find("artwork")
        self.assertTrue(hits)
        self.assertTrue(any(h.source == "field" for h in hits))

    def test_session_summary(self):
        sess = PeekSession(SAMPLE, self.catalog)
        s = sess.summary()
        self.assertEqual(s["nodes"], 3)
        self.assertEqual(s["with_strings"], 2)
        self.assertGreaterEqual(s["with_fields"], 2)

    def test_generic_type_strip(self):
        hit = self.catalog.lookup(
            "MusicApplication.SearchViewController"
            "<MusicApplication.SearchLandingViewController>"
        )
        self.assertIsNotNone(hit)
        self.assertTrue(str(hit["key"]).startswith("MusicApplication.SearchViewController"))

    def test_roundtrip_file(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "dump.json"
            p.write_text(json.dumps(SAMPLE))
            sess = PeekSession(p, self.catalog)
            self.assertEqual(sess.summary()["matched_nodes"], 3)

    def test_windows_absent_on_old_dump(self):
        """0.3.x dumps have no `windows` key — must not raise."""
        sess = PeekSession(SAMPLE, self.catalog)
        self.assertEqual(sess.windows, [])
        self.assertEqual(sess.windows_table(), [])
        self.assertEqual(sess.summary()["windows"], 0)

    def test_windows_sorted_and_flagged(self):
        sess = PeekSession(WINDOW_SAMPLE, self.catalog)
        self.assertEqual(len(sess.windows), 3)
        self.assertEqual(sess.summary()["windows"], 3)

        rows = sess.windows_table()
        self.assertEqual(len(rows), 3)
        # Overlay window: transparent, not key, so no OPAQUE/KEY/bg flags.
        overlay = rows[1]
        self.assertIn("M27DockOverlayWindow", overlay)
        self.assertIn("level=2.0", overlay)
        self.assertNotIn("HIDDEN", overlay)
        self.assertNotIn("bg=", overlay)
        # Hidden window is flagged — the signature of an overlay that never paints.
        self.assertIn("HIDDEN", rows[2])
        # App window keeps KEY + OPAQUE.
        self.assertIn("KEY", rows[0])
        self.assertIn("OPAQUE", rows[0])

    def test_windows_views_opt_in(self):
        """View subtree is printed only with views=True."""
        sample = json.loads(json.dumps(WINDOW_SAMPLE))
        sample["windows"][1]["views"] = [
            {
                "depth": 0,
                "class": "M27PassthroughView",
                "frame": "{0,0,390,844}",
                "hidden": False,
                "alpha": 1.0,
            },
            {
                "depth": 1,
                "class": "M27FloatingDock",
                "frame": "{0,0,0,0}",
                "hidden": False,
                "alpha": 1.0,
                "invisible": True,
            },
        ]
        sess = PeekSession(sample, self.catalog)

        plain = sess.windows_table()
        self.assertEqual(len(plain), 3)
        self.assertFalse(any("M27FloatingDock" in r for r in plain))

        with_views = sess.windows_table(views=True)
        self.assertEqual(len(with_views), 5)
        dock = [r for r in with_views if "M27FloatingDock" in r]
        self.assertEqual(len(dock), 1)
        # A zero-sized dock inside a correct overlay is the case we are hunting.
        self.assertIn("INVISIBLE", dock[0])
        self.assertIn("{0,0,0,0}", dock[0])

    def test_windows_views_absent_is_safe(self):
        """Windows with no `views` key must not break views=True."""
        sess = PeekSession(WINDOW_SAMPLE, self.catalog)
        self.assertEqual(len(sess.windows_table(views=True)), 3)

    def test_windows_flags_opaque_background(self):
        """A solid background is the white-screen signature — must surface."""
        sess = PeekSession(
            {
                "tool_version": "0.4.0",
                "nodes": [],
                "windows": [
                    {
                        "class": "BadOverlay",
                        "level": 999.0,
                        "frame": "{0,0,390,844}",
                        "hidden": False,
                        "opaque": True,
                        "alpha": 0.5,
                        "is_key": False,
                        "background": "white(1.00,a=1.00)",
                        "root_vc": "UIViewController",
                    }
                ],
            },
            self.catalog,
        )
        row = sess.windows_table()[0]
        self.assertIn("bg=white(1.00,a=1.00)", row)
        self.assertIn("alpha=0.50", row)
        self.assertIn("OPAQUE", row)


if __name__ == "__main__":
    unittest.main()


class LayerColorTests(unittest.TestCase):
    """SwiftPeek 0.5.0 reports colour that lives on the layer, not the view."""

    @classmethod
    def setUpClass(cls):
        if not DEFAULT_CATALOG.is_file():
            raise unittest.SkipTest(f"missing catalog {DEFAULT_CATALOG}")
        cls.catalog = FieldCatalog(DEFAULT_CATALOG)

    def _session(self, view: dict) -> PeekSession:
        sample = json.loads(json.dumps(WINDOW_SAMPLE))
        sample["windows"][0]["views"] = [view]
        return PeekSession(sample, self.catalog)

    def test_layer_background_surfaces(self):
        rows = self._session({
            "depth": 0,
            "class": "MusicApplication.PaletteContainerView",
            "frame": "{0,0,390,844}",
            "hidden": False,
            "alpha": 1.0,
            "layer_background": "rgba(0.40,0.28,0.20,1.00)",
        }).windows_table(views=True)
        hit = [r for r in rows if "PaletteContainerView" in r]
        self.assertEqual(len(hit), 1)
        self.assertIn("layerbg=rgba(0.40,0.28,0.20,1.00)", hit[0])

    def test_gradient_surfaces(self):
        rows = self._session({
            "depth": 0,
            "class": "MusicApplication.PaletteContainerView",
            "frame": "{0,0,390,844}",
            "hidden": False,
            "alpha": 1.0,
            "gradient": "rgba(0.40,0.28,0.20,1.00) rgba(0.10,0.08,0.06,1.00)",
            "gradient_layer": "CAGradientLayer",
        }).windows_table(views=True)
        hit = [r for r in rows if "PaletteContainerView" in r]
        self.assertEqual(len(hit), 1)
        self.assertIn("gradient=[", hit[0])
        self.assertIn("rgba(0.10,0.08,0.06,1.00)", hit[0])

    def test_absent_layer_colour_adds_nothing(self):
        """A 0.4.x dump has neither key and must read exactly as before."""
        rows = self._session({
            "depth": 0,
            "class": "UIView",
            "frame": "{0,0,390,844}",
            "hidden": False,
            "alpha": 1.0,
        }).windows_table(views=True)
        hit = [r for r in rows if r.strip().startswith("UIView")]
        self.assertEqual(len(hit), 1)
        self.assertNotIn("layerbg=", hit[0])
        self.assertNotIn("gradient=", hit[0])


class TruncationTests(unittest.TestCase):
    """0.5.3: a walk that stopped must not read like a walk that finished."""

    @classmethod
    def setUpClass(cls):
        if not DEFAULT_CATALOG.is_file():
            raise unittest.SkipTest(f"missing catalog {DEFAULT_CATALOG}")
        cls.catalog = FieldCatalog(DEFAULT_CATALOG)

    def _rows(self, view):
        sample = json.loads(json.dumps(WINDOW_SAMPLE))
        sample["windows"][0]["views"] = [view]
        return PeekSession(sample, self.catalog).windows_table(views=True)

    def test_truncated_node_says_how_many_it_missed(self):
        rows = self._rows({
            "depth": 6, "class": "MusicApplication.TintColorObservingView",
            "frame": "{0,0,375,812}", "hidden": False, "alpha": 1.0,
            "subviews": 4, "truncated": 4,
        })
        hit = [r for r in rows if "TintColorObservingView" in r]
        self.assertEqual(len(hit), 1)
        self.assertIn("STOPPED, 4 more below", hit[0])

    def test_real_leaf_is_not_marked(self):
        rows = self._rows({
            "depth": 6, "class": "UIView", "frame": "{0,0,10,10}",
            "hidden": False, "alpha": 1.0, "subviews": 0,
        })
        hit = [r for r in rows if r.strip().startswith("UIView")]
        self.assertEqual(len(hit), 1)
        self.assertNotIn("STOPPED", hit[0])
