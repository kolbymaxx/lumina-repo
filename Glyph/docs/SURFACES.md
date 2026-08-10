# Glyph Phase A — themable surface inventory

Ground truth for what Glyph is allowed to touch, and with which technique.
Rule: **UIKit surfaces get classic hooks; SwiftUI theming is permitted only
for surfaces confirmed SwiftUI-hosted by a real SwiftPeek dump on that
firmware.** No dump, no SwiftUI hook.

Status legend:

- `CONFIRMED UIKIT` — known UIKit classes, verified hook point
- `CONFIRMED SWIFTUI` — SwiftPeek dump shows a `_UIHostingView` hosting this surface (cite the dump file)
- `PENDING DUMP` — expectation only; **not** a valid Phase C target yet

## SpringBoard (host process: `SpringBoard`)

| Surface | iOS 16.7.x | iOS 17.x | Evidence | Glyph phase / technique |
|---------|-----------|----------|----------|-------------------------|
| Home Screen icon grid | CONFIRMED UIKIT | CONFIRMED UIKIT | `SBIconView` / `SBIconImageView` present on both firmwares; no SwiftUI icon view exists on the grid | B — hook `-[SBIconImageView setContentsImage:]` |
| Dock icons | CONFIRMED UIKIT | CONFIRMED UIKIT | Same `SBIconImageView` pipeline as the grid | B — same hook, no extra code |
| Folder icons (mini-grids) | CONFIRMED UIKIT | CONFIRMED UIKIT | Folder blur/mini-icons composed from the same icon images | B — themed automatically via the icon pipeline; folder background theming deferred to D |
| Notification badges | CONFIRMED UIKIT | CONFIRMED UIKIT | `SBIconBadgeView` (UIKit) | D — badge asset theming, classic hook (not yet implemented) |
| Lock Screen widgets | PENDING DUMP | **CONFIRMED UIKIT (host process)** | `dumps/SpringBoard_17.3_windowscan_141702.json`: `CSCoverSheetViewController`, `CSProminentDisplayViewController`, `CSComplicationContainerViewController`, `SBFLockScreenDateViewController` — all UIKit, **`hosts_found: 0`** | **Not a Phase C target.** See "WidgetKit is not in SpringBoard" below |
| App Library detail panes | PENDING DUMP | PENDING DUMP | Not on screen during the 17.3 scans; `SBHRootSidebarController` / `SBHWidgetStackViewController` seen, no App Library classes | C candidate — needs a dump with App Library open |
| Spotlight | PENDING DUMP | **CONFIRMED UIKIT** | Same dump: `SBSpotlightPresentableViewController`, `SBHomeScreenSpotlightViewController`, `screen_strings: ["Search"]`, `hosts_found: 0` | Classic UIKit hook if ever wanted |
| Control Center modules | CONFIRMED UIKIT | CONFIRMED UIKIT | `CCUI*` classes (see CC27, which hooks them today) | Out of scope for Glyph — CC27 territory |

## WidgetKit is not in SpringBoard — and that settles Phase C's first target

Two full window scans on **iPhone13,1 / iOS 17.3** (lock screen, home screen,
Spotlight, switcher and Control Center all reached: 73 and 76 controllers)
returned **`hosts_found: 0`**. Not one `_UIHostingView` anywhere in
SpringBoard's window tree.

That is not a scan failure — it is the answer. WidgetKit widgets are rendered
**out of process** by their own extension and delivered to SpringBoard as
archived drawing output. The SwiftUI lives in the widget extension, not here.
`SBHWidgetViewController` and `SBHWidgetContainerViewController` are present in
the dump and are plain UIKit containers around that delivered content.

Consequences for Glyph:

- **Lock Screen widgets cannot be themed from SpringBoard at the SwiftUI
  layer**, because there is no SwiftUI layer in SpringBoard to reach. Phase C's
  presumed first target does not exist as described. The remaining options are
  the `CALayer.contents` boundary of the UIKit container, or injecting into the
  widget extension process — a different tweak with a different filter and a
  different risk profile.
- Phase C is **not** blocked on more dumps for this surface. It is blocked on
  choosing between those two options.

Caveat on scope: these scans are 17.3 only, and the walk covers
already-loaded view trees, so a surface that was never on screen was never
walked. App Library stays `PENDING DUMP` for exactly that reason, and 16.7
still needs its own scan.

## Other processes

| Surface | Host process | iOS 16.7.x | iOS 17.x | Evidence | Glyph phase |
|---------|--------------|-----------|----------|----------|-------------|
| Music app UI | `Music` | PENDING DUMP | PENDING DUMP | SwiftPeek's primary target; dumps exist conceptually but must be attached here | Not planned — Music27 territory; listed for completeness |
| Settings icons (per-app) | `Preferences` | CONFIRMED UIKIT | CONFIRMED UIKIT | Standard `UITableViewCell` image views | D candidate — separate injection filter, only if wanted |

## How to fill in a PENDING DUMP row

SwiftPeek was Music-only through 0.3.6 (it put SpringBoard into Safe Mode at
0.2.1), so none of these rows could be resolved. **SwiftPeek 0.4.0 adds an
opt-in SpringBoard mode** built for exactly this: ObjC-only, no hooks, no Swift
metadata walks, and two independent switches that both default off —
`targetSpringBoard` to allow injection at all, then `sbScanWindows` for the
hook-free hosting-view scan that answers the UIKit-vs-SwiftUI question.

**Proven on device (2026-08-10, iPhone13,1 / 17.3):** SwiftPeek 0.4.0 ran in
SpringBoard with `targetSpringBoard` + `sbScanWindows` + `iconInventory` and
produced four dumps with **no Safe Mode and no respring loop**. The dumps are
banked in [`dumps/`](dumps/).

1. Enable SwiftPeek (`enabled` + `targetSpringBoard` + `sbScanWindows`, plus
   `dumpFields` for on-screen strings) and bring the surface on screen
   (respring for lock screen).
2. Pull the dump JSON from
   `$jbroot/var/mobile/Library/SwiftPeek/dumps/SpringBoard_<timestamp>.json`.
3. If the dump shows a `_UIHostingView` whose Swift type resolves to that
   surface, flip the row to `CONFIRMED SWIFTUI`, cite the dump filename and
   the resolved type name, and copy the dump into `Glyph/docs/dumps/`.
4. If it shows only UIKit classes, flip the row to `CONFIRMED UIKIT` and
   record the classes seen.

Firmware note (from SwiftPeek PHASE0): SwiftUI reflection metadata churns
heavily 16 → 17 (1434 types added / 517 removed) but is effectively frozen
across 17.2–17.3.1 point releases. A `CONFIRMED SWIFTUI` verdict from one
17.x point release carries to the others; 16.7 always needs its own dump.
