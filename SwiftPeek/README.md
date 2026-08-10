# SwiftPeek

Read-only SwiftUI / Music view inspector for jailbroken iOS. Recovers live
type names (M1) and optional on-screen strings (M2) without mutating the UI.

**Status:** Phase 1 — M1 + safe M2 `screen_strings` proven on iPhone X /
16.7.14. Live FOVO field meta is **unsafe** on Music — leave Dump Field Meta
**off**. 0.4.0 adds opt-in SpringBoard recon (M3/M4) for Glyph. Field **names/layouts** for device-sampled Music types are
recoverable **offline** via `swiftmd` on `MusicApplication.framework`
([docs/OFFLINE_MUSIC_FIELDS.md](docs/OFFLINE_MUSIC_FIELDS.md)). Phase 2–3 host
tools: annotate / query / **ranked targets** / **Theos scaffold** —
[`docs/READ_API.md`](docs/READ_API.md), [`docs/TWEAK_WORKFLOW.md`](docs/TWEAK_WORKFLOW.md),
`PYTHONPATH=tools python3 -m swiftpeek …`. Not published to APT.

> **Concurrent branches:** PRs #47, #59 and #60 all change SwiftPeek, and #59
> and #60 disagree about whether SwiftPeek may enter SpringBoard at all. See
> [`docs/MERGE_NOTES.md`](docs/MERGE_NOTES.md) before merging any of them.

## Targets

| Process | Why |
|---------|-----|
| Music | Primary prove device — stay here before any other app |
| SpringBoard | 0.4.0, opt-in only: icon inventory + hook-free hosting-view scan for Glyph's surface inventory |

Prefs default **off** everywhere.

### SpringBoard mode (0.4.0)

SwiftPeek went Music-only at 0.2.1 after putting SpringBoard into Safe Mode.
The way back in is deliberately narrow, and everything about it is opt-in:

- ObjC-only dylib, **no hooks, no swizzles, no FOVO, no Swift metadata walks**
  (`dumpFieldMeta` is forced off in SpringBoard regardless of the pref).
- **M4 icon inventory** reads each installed app's artwork through
  `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]` and lists
  apps via `LSApplicationWorkspace` — SBIconModel, the icon cache and the icon
  view tree are never touched. Each icon gets an **M3 pixel signature**
  (luminance percentiles, alpha coverage, corner alpha, plate ratio, edge
  density, dominant colour), plus the path of any legacy IconBundles /
  SnowBoard override already installed for it.
- **Hosting-view scan** (`sbScanWindows`) is the existing hook-free window walk,
  scheduled 25 s after launch. It answers UIKit-vs-SwiftUI for a surface, which
  is what flips a row in `Glyph/docs/SURFACES.md` from `PENDING DUMP`.

Trigger an inventory on demand without a respring:
`notify_post("com.kolby.swiftpeek/icons")`.

## Prefs

Domain: `com.kolby.swiftpeek`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Master kill switch |
| `scanWindows` | `false` | Walk loaded VC tree → coalesced attach dump |
| `dumpFields` | `false` | M2: on-screen UILabel/accessibility strings (**safe**) |
| `dumpFieldMeta` | `false` | Hosting FOVO only; Music 16.7 has no hosts — **leave off** |
| `installHooks` | `false` | Swizzle hosting layout (**leave off**) |
| `logAttach` | `true` | NSLog attach lines when enabled |
| `targetSpringBoard` | `false` | Allow injection into SpringBoard at all (0.4.0) |
| `iconInventory` | `false` | M4 icon inventory + pixel signatures (needs `targetSpringBoard`) |
| `sbScanWindows` | `false` | Hook-free hosting-view scan in SpringBoard (needs `targetSpringBoard`) |

**Proven device path:** Enable + Scan Windows + Dump Fields. Field Meta off.
Hooks off. Force-quit Music after pref changes.

## Dumps

```
$jbroot/var/mobile/Library/SwiftPeek/dumps/<process>_<timestamp>.json
$jbroot/var/mobile/Library/SwiftPeek/status.json
```

## Build

```bash
cd SwiftPeek
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # iPhone X / Dopamine
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # 12 mini / Relaxin
```

ObjC-only dylib (no Swift). Depends on `mobilesubstrate` at runtime.

## Safety

- Read-only. No view mutation.
- SpringBoard injection requires `targetSpringBoard`; with it off the
  constructor returns immediately and SwiftPeek is inert there.
- Never FOVO-walk Music UIViewControllers or Music UIViews (known crash).
- Install Hooks remains opt-in and off by default.
