#!/usr/bin/env python3
"""Unified SwiftPeek host CLI.

  python3 -m swiftpeek annotate DUMP.json -o annotated.json
  python3 -m swiftpeek summary annotated.json
  python3 -m swiftpeek types annotated.json
  python3 -m swiftpeek strings annotated.json
  python3 -m swiftpeek windows annotated.json
  python3 -m swiftpeek fields annotated.json MiniPlayer
  python3 -m swiftpeek find annotated.json artwork
  python3 -m swiftpeek targets annotated.json
  python3 -m swiftpeek scaffold annotated.json -o ~/Tweaks/MyMusicTweak --name MyMusicTweak
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow `python3 -m swiftpeek` from tools/ or repo root.
if __name__ == "__main__" and (__package__ is None or __package__ == ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "swiftpeek"

from .api import FieldCatalog, PeekSession, annotate_dump, load_dump
from .paths import DEFAULT_CATALOG
from .scaffold import format_targets, rank_targets, write_scaffold


def _cmd_annotate(args: argparse.Namespace) -> int:
    if not args.dump.is_file():
        print(f"missing dump: {args.dump}", file=sys.stderr)
        return 1
    cat = FieldCatalog(args.catalog)
    out = annotate_dump(load_dump(args.dump), cat)
    text = json.dumps(out, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        sys.stdout.write(text)
    if not args.quiet:
        info = out["offline_annotate"]
        print(
            f"# matched {info['matched_nodes']}/{info['total_nodes']} nodes "
            f"against {info['catalog_types']} catalog types",
            file=sys.stderr,
        )
    return 0


def _session(args: argparse.Namespace) -> PeekSession:
    return PeekSession(args.dump, FieldCatalog(args.catalog), annotate=True)


def _cmd_windows(args: argparse.Namespace) -> int:
    sess = _session(args)
    rows = sess.windows_table()
    if not rows:
        print(
            "no window data in this dump "
            "(needs SwiftPeek 0.4.0+ with Window Tree enabled)",
            file=sys.stderr,
        )
        return 1
    for line in rows:
        print(line)
    return 0


def _cmd_summary(args: argparse.Namespace) -> int:
    s = _session(args).summary()
    for k in (
        "tool_version",
        "milestone",
        "message",
        "nodes",
        "windows",
        "matched_nodes",
        "catalog_types",
        "with_fields",
        "with_strings",
    ):
        label = {
            "tool_version": "tool_version",
            "milestone": "milestone",
            "message": "message",
            "nodes": "nodes",
            "windows": "windows",
            "matched_nodes": "offline",
            "catalog_types": "catalog",
            "with_fields": "with_fields",
            "with_strings": "with_strings",
        }[k]
        if k == "matched_nodes":
            print(
                f"offline:      {s.get('matched_nodes')}/{s.get('nodes')} matched "
                f"({s.get('catalog_types')} catalog types)"
            )
        elif k == "catalog_types":
            continue
        else:
            print(f"{label + ':':13} {s.get(k)}")
    return 0


def _cmd_types(args: argparse.Namespace) -> int:
    for row in _session(args).iter_types():
        print(
            f"{row['field_count']:3d}f {row['string_count']:2d}s  "
            f"{(row.get('role') or ''):16} {row.get('type')}"
        )
    return 0


def _cmd_strings(args: argparse.Namespace) -> int:
    for n in _session(args).nodes:
        ss = n.get("screen_strings") or []
        if not ss:
            continue
        print(f"## {n.get('type') or '?'}")
        for s in ss:
            print(f"  - {s}")
        print()
    return 0


def _cmd_fields(args: argparse.Namespace) -> int:
    rows = _session(args).fields(args.needle)
    if not rows:
        print(f"no nodes matching {args.needle!r}", file=sys.stderr)
        return 1
    for row in rows:
        print(f"## {row['type']}")
        for f in row["fields"]:
            print(f"  [{f.get('index')}] {f.get('name')} : {f.get('type')}")
        print()
    return 0


def _cmd_find(args: argparse.Namespace) -> int:
    hits = _session(args).find(args.needle)
    for h in hits:
        if h.source == "screen_string":
            print(f"{h.type_name} screen_string={h.name!r}")
        else:
            print(f"{h.type_name}.{h.name} : {h.type_hint}")
    return 0


def _cmd_targets(args: argparse.Namespace) -> int:
    sess = _session(args)
    targets = rank_targets(sess, limit=args.limit)
    if args.json:
        print(json.dumps([t.as_dict() for t in targets], indent=2))
    else:
        text = format_targets(targets)
        if not text.endswith("\n"):
            text += "\n"
        sys.stdout.write(text)
    return 0


def _cmd_scaffold(args: argparse.Namespace) -> int:
    if not args.dump.is_file():
        print(f"missing dump: {args.dump}", file=sys.stderr)
        return 1
    sess = _session(args)
    root = write_scaffold(
        sess,
        args.output,
        name=args.name,
        bundle_id=args.bundle_id,
        filter_substr=args.filter,
        limit=args.limit,
    )
    print(f"# scaffold written to {root}", file=sys.stderr)
    print(f"# edit {root / 'src' / 'Tweak.x'} and see {root / 'TARGETS.md'}", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="swiftpeek", description=__doc__)
    ap.add_argument(
        "--catalog",
        type=Path,
        default=DEFAULT_CATALOG,
        help=f"field catalog JSON (default: {DEFAULT_CATALOG})",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("annotate", help="join dump with offline fields")
    p.add_argument("dump", type=Path)
    p.add_argument("-o", "--output", type=Path)
    p.add_argument("-q", "--quiet", action="store_true")
    p.set_defaults(func=_cmd_annotate)

    for name, help_, fn in (
        ("summary", "dump overview", _cmd_summary),
        ("types", "list node types", _cmd_types),
        ("strings", "list screen_strings", _cmd_strings),
        ("windows", "list UIWindows by level (0.4.0+)", _cmd_windows),
    ):
        p = sub.add_parser(name, help=help_)
        p.add_argument("dump", type=Path)
        p.set_defaults(func=fn)

    p = sub.add_parser("fields", help="show offline fields for type substring")
    p.add_argument("dump", type=Path)
    p.add_argument("needle")
    p.set_defaults(func=_cmd_fields)

    p = sub.add_parser("find", help="search field names / screen strings")
    p.add_argument("dump", type=Path)
    p.add_argument("needle")
    p.set_defaults(func=_cmd_find)

    p = sub.add_parser("targets", help="rank dump nodes for tweakability")
    p.add_argument("dump", type=Path)
    p.add_argument("-n", "--limit", type=int, default=20)
    p.add_argument("--json", action="store_true", help="emit JSON instead of markdown")
    p.set_defaults(func=_cmd_targets)

    p = sub.add_parser("scaffold", help="emit a Music-only Theos tweak skeleton")
    p.add_argument("dump", type=Path)
    p.add_argument(
        "-o",
        "--output",
        type=Path,
        required=True,
        help="directory to write the Theos project into",
    )
    p.add_argument("--name", default="PeekMusicTweak", help="TWEAK_NAME / package Name")
    p.add_argument(
        "--bundle-id",
        default="com.kolby.peekmusic",
        help="debian Package id (default: com.kolby.peekmusic)",
    )
    p.add_argument(
        "--filter",
        default=None,
        help="only hook types matching this substring (e.g. MiniPlayer)",
    )
    p.add_argument("-n", "--limit", type=int, default=12, help="targets listed in TARGETS.md")
    p.set_defaults(func=_cmd_scaffold)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
