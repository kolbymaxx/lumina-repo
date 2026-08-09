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
