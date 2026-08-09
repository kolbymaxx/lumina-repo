# SwiftPeek

Read-only SwiftUI / Music view inspector for jailbroken iOS. Recovers live
type names (M1) and optional on-screen strings (M2) without mutating the UI.

**Status:** Phase 1 — M1 + safe M2 `screen_strings` proven on iPhone X /
16.7.14. **Music27 dock work now prefers iOS 17 Dopamine dumps** (stock mini
already floats; see [`docs/TWEAK_WORKFLOW.md`](docs/TWEAK_WORKFLOW.md)). Live
FOVO field meta is **unsafe** on Music — leave Dump Field Meta **off** (0.4.0).
Field **names/layouts** for device-sampled Music types are recoverable
**offline** via `swiftmd` on `MusicApplication.framework`
([docs/OFFLINE_MUSIC_FIELDS.md](docs/OFFLINE_MUSIC_FIELDS.md)). Phase 2–3 host
tools: annotate / query / **ranked targets** / **Theos scaffold** —
[`docs/READ_API.md`](docs/READ_API.md), [`docs/TWEAK_WORKFLOW.md`](docs/TWEAK_WORKFLOW.md),
`PYTHONPATH=tools python3 -m swiftpeek …`. Not published to APT.

## Targets

Per-process, pref-gated, all **off by default except Music**. A process that is
not in this table is never attached to, even if the MobileSubstrate filter
loads the dylib there.

| Process | Pref | Default | Why |
|---------|------|---------|-----|
| Music | `targetMusic` | **on** | Primary prove device; only target with a crash-tested field-walk allowlist |
| Podcasts | `targetPodcasts` | off | Same tab-bar + mini-player shape as Music — first test of whether the `MediaCoreUI` knowledge transfers |
| TV | `targetTV` | off | As above |
| Settings | `targetSettings` | off | SwiftUI-heavy on 17, trivially relaunchable — good low-risk soak target |
| SiriViewService | `targetSiriView` | off | Siri UI without touching SpringBoard |
| assistantd | `targetAssistantd` | off | Siri backend; no UI, so window/VC trees will be thin |

**SpringBoard is deliberately absent.** The 0.2.1 Safe Mode came from a
Swift-linked build and this dylib has been ObjC-only since, so the original
cause is gone — but a SpringBoard crash costs a device you cannot drive, not an
app relaunch. It goes in only after the kill switch below has been exercised for
real on one of the targets above.

`SPClassNameIsMusicMetaView` is a **Music-specific** allowlist earned through two
crashes. It does not transfer. A newly enabled target gets the window and
controller trees only.

## Kill switch

SwiftPeek checks for this file before prefs and before anything else runs:

```
$jbroot/var/mobile/Library/SwiftPeek/DISABLE
```

If it exists, SwiftPeek refuses to attach to any process. This is the recovery
path for a target you cannot force-quit — `touch` it over SSH and respring.
It exists so that pointing SwiftPeek at a system process is a recoverable
mistake rather than a fatal one.

## Prefs

Domain: `com.kolby.swiftpeek`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Master kill switch |
| `scanWindows` | `false` | Walk loaded VC tree → coalesced attach dump |
| `dumpWindows` | `true` | Per-`UIWindow` level/frame/alpha/background snapshot (**safe** — plain property reads) |
| `dumpFields` | `false` | M2: on-screen UILabel/accessibility strings (**safe**) |
| `dumpFieldMeta` | `false` | Hosting FOVO only; Music 16.7 has no hosts — **leave off** |
| `installHooks` | `false` | Swizzle hosting layout (**leave off**) |
| `logAttach` | `true` | NSLog attach lines when enabled |

**Proven device path:** Enable + Scan Windows + Dump Fields. Field Meta off.
Hooks off. Force-quit Music after pref changes.

## Dumps

```
$jbroot/var/mobile/Library/SwiftPeek/dumps/<process>_<timestamp>.json
$jbroot/var/mobile/Library/SwiftPeek/status.json
```

### Window tree (0.4.0)

Every dump written with `dumpWindows` on carries a `windows` array — one entry
per `UIWindow`, sorted ascending by `windowLevel`, i.e. the order the compositor
stacks them. Fields: `class`, `level`, `frame`, `hidden`, `opaque`, `alpha`,
`is_key`, `background`, `root_vc`, `root_view_loaded`, `subviews`, `scene`.

```bash
PYTHONPATH=tools python3 -m swiftpeek windows dump.json
```

```
level=0.0    {0,0,390,844}  UIWindow              root=MusicApplication.RootViewController KEY OPAQUE
level=2.0    {0,0,390,844}  M27DockOverlayWindow  root=UIViewController
level=999.0  {0,0,390,844}  UITextEffectsWindow   root=nil                                 HIDDEN
```

This exists because Music27 spent four device cycles (1.1.19–1.1.22) guessing at
window level and opacity with no way to observe either. The two failure modes it
makes obvious:

- **Overlay paints over the app** — a window above the app's with `OPAQUE` or a
  non-`clear` `bg=`. This was the 1.1.19 white screen.
- **Overlay never composites** — the window is missing from the list, `HIDDEN`,
  `alpha=0.00`, or has a zero-size `frame`. This was 1.1.20.

Written even when the controller scan finds nothing interesting, since "the app
looks completely stock" is exactly when the window list is the whole story.

## Build

```bash
cd SwiftPeek
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # iPhone X / Dopamine
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # 12 mini / Relaxin
```

ObjC-only dylib (no Swift). Depends on `mobilesubstrate` at runtime.

## Safety

- Read-only. No view mutation.
- Never FOVO-walk Music UIViewControllers or Music UIViews (known crash).
- Install Hooks remains opt-in and off by default.
- Window tree is plain property reads — no recursion, no Swift memory, capped at
  40 windows. It is the safest data SwiftPeek collects.
- Unknown processes fail closed; the disk kill switch overrides every pref.
