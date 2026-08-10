#!/usr/bin/env python3
"""Smoke tests for the icon-inventory analyser (no device required)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from swiftpeek.icons import (  # noqa: E402
    MODE_CLEAR_GLASS,
    build_tint_plan,
    classify_icon,
    format_icons,
    iter_icons,
)


def sig(**kw):
    base = {
        "width": 60.0,
        "height": 60.0,
        "scale": 3.0,
        "opaque_pixels": 3000.0,
        "alpha_coverage": 0.93,
        "corner_alpha": 0.02,
        "mean_hex": "#c0603a",
        "dominant_hex": "#d06840",
        "plate_ratio": 0.12,
        "luma_p02": 0.20,
        "luma_p50": 0.48,
        "luma_p98": 0.95,
        "luma_hist": [0.1] * 8,
        "saturation_mean": 0.55,
        "edge_density": 0.02,
    }
    base.update(kw)
    return base


DUMP = {
    "device_model": "iPhone10,6",
    "ios_version": "16.7.14",
    "tool_version": "0.4.0",
    "icons": [
        {"bundle_id": "com.full.bleed", "display_name": "Full", "icon_signature": sig()},
        {
            "bundle_id": "com.glyph.only",
            "display_name": "Glyph",
            "icon_signature": sig(alpha_coverage=0.08, plate_ratio=0.9),
        },
        {
            "bundle_id": "com.flat.plate",
            "display_name": "Flat",
            "icon_signature": sig(plate_ratio=0.72),
        },
        {
            "bundle_id": "com.low.contrast",
            "display_name": "Low",
            "icon_signature": sig(luma_p02=0.50, luma_p98=0.58),
        },
        {
            "bundle_id": "com.busy.art",
            "display_name": "Busy",
            "icon_signature": sig(edge_density=0.09),
        },
        {
            "bundle_id": "com.themed.app",
            "display_name": "Themed",
            "icon_signature": sig(),
            "theme_override": "/var/jb/Library/Themes/X.theme/IconBundles/com.themed.app.png",
            "theme_signature": sig(alpha_coverage=0.20),
        },
        {"bundle_id": "com.no.art", "display_name": "None"},
    ],
}


class IconClassificationTests(unittest.TestCase):
    def verdict(self, bundle_id):
        for entry in iter_icons(DUMP):
            if entry["bundle_id"] == bundle_id:
                return classify_icon(entry)
        self.fail(f"no such icon {bundle_id}")

    def test_full_bleed_needs_nothing(self):
        v = self.verdict("com.full.bleed")
        self.assertEqual(v.shape, "full_bleed")
        self.assertEqual(v.contrast, "normal")
        self.assertEqual(v.settings, {})

    def test_glyph_only_gets_a_plate(self):
        v = self.verdict("com.glyph.only")
        self.assertEqual(v.shape, "glyph_only")
        self.assertTrue(v.settings["plateFill"])

    def test_flat_plate_detected(self):
        self.assertEqual(self.verdict("com.flat.plate").shape, "flat_plate")

    def test_low_contrast_dials_back_auto_levels(self):
        v = self.verdict("com.low.contrast")
        self.assertEqual(v.contrast, "low")
        self.assertLess(v.settings["tintLevels"], 0.5)

    def test_busy_artwork_softens_the_ramp(self):
        v = self.verdict("com.busy.art")
        self.assertEqual(v.contrast, "busy")
        self.assertLess(v.settings["tintContrast"], 0.35)

    def test_themed_icon_is_judged_on_the_theme_bitmap(self):
        # The pack's PNG is what Glyph composites, so its coverage — not the
        # stock icon's — decides whether a plate is needed.
        v = self.verdict("com.themed.app")
        self.assertTrue(v.themed)
        self.assertEqual(v.shape, "glyph_only")

    def test_missing_artwork_is_not_fatal(self):
        v = self.verdict("com.no.art")
        self.assertEqual(v.shape, "unknown")
        self.assertEqual(v.settings, {})


class TintPlanTests(unittest.TestCase):
    def test_plan_shape(self):
        plan = build_tint_plan(DUMP, mode=MODE_CLEAR_GLASS, tint="#33AAFF")
        self.assertEqual(plan["global"]["iconMode"], MODE_CLEAR_GLASS)
        self.assertEqual(plan["global"]["mode_name"], "glass")
        self.assertEqual(plan["global"]["tintColor"], "#33AAFF")
        self.assertEqual(plan["summary"]["icons"], 7)
        self.assertEqual(plan["summary"]["themed"], 1)
        self.assertEqual(plan["source"]["ios_version"], "16.7.14")

    def test_only_icons_needing_overrides_are_listed(self):
        plan = build_tint_plan(DUMP)
        self.assertIn("com.glyph.only", plan["per_app"])
        self.assertIn("com.low.contrast", plan["per_app"])
        self.assertNotIn("com.full.bleed", plan["per_app"])
        self.assertEqual(plan["summary"]["needs_override"], len(plan["per_app"]))

    def test_empty_dump_is_handled(self):
        plan = build_tint_plan({"icons": []})
        self.assertEqual(plan["summary"]["icons"], 0)
        self.assertEqual(plan["per_app"], {})

    def test_format_is_stable(self):
        verdicts = [classify_icon(e) for e in iter_icons(DUMP)]
        text = format_icons(verdicts, limit=3)
        self.assertEqual(len(text.splitlines()), 3)
        self.assertIn("com.full.bleed", text)


if __name__ == "__main__":
    unittest.main()
