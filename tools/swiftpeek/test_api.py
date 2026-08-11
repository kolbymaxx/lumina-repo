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


if __name__ == "__main__":
    unittest.main()
