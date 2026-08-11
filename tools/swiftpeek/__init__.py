"""SwiftPeek host-side read API — annotate live dumps with offline field layouts.

Phase 2: read/annotate/query. Phase 3: ranked targets + Theos scaffold.
Phase 4: icon-inventory analysis + Glyph tint plans (SwiftPeek 0.4.0 dumps).
No live FOVO; safe to use with 0.3.6 and 0.4.0 device dumps.
"""

from .api import FieldCatalog, PeekSession, annotate_dump, load_dump
from .icons import (
    IconVerdict,
    build_tint_plan,
    calibration_report,
    classify_icon,
    format_calibration,
    format_icons,
    load_icon_dump,
)
from .scaffold import TargetScore, format_targets, generate_tweak_x, rank_targets, write_scaffold

__all__ = [
    "FieldCatalog",
    "IconVerdict",
    "PeekSession",
    "TargetScore",
    "annotate_dump",
    "build_tint_plan",
    "calibration_report",
    "classify_icon",
    "format_calibration",
    "format_icons",
    "load_icon_dump",
    "format_targets",
    "generate_tweak_x",
    "load_dump",
    "rank_targets",
    "write_scaffold",
]

__version__ = "0.7.0"
