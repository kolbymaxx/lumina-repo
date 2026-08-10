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
| Notification badges | CONFIRMED UIKIT | CONFIRMED UIKIT | `SBIconBadgeView` (UIKit) | D — badge asset theming, classic hook |
| Lock Screen widgets | PENDING DUMP | PENDING DUMP | Expected SwiftUI-hosted (WidgetKit); needs SwiftPeek dump from SpringBoard with `dumpFields` on, lock screen visible | C candidate — `CALayer.contents` boundary only, after dump confirms |
| App Library detail panes | PENDING DUMP | PENDING DUMP | Expected partially SwiftUI on 17.x; unknown on 16.7 | C candidate — after dump confirms |
| Spotlight | PENDING DUMP | PENDING DUMP | Expected mixed UIKit/SwiftUI | C candidate — after dump confirms |
| Control Center modules | CONFIRMED UIKIT | CONFIRMED UIKIT | `CCUI*` classes (see CC27, which hooks them today) | Out of scope for Glyph — CC27 territory |

## Other processes

| Surface | Host process | iOS 16.7.x | iOS 17.x | Evidence | Glyph phase |
|---------|--------------|-----------|----------|----------|-------------|
| Music app UI | `Music` | PENDING DUMP | PENDING DUMP | SwiftPeek's primary target; dumps exist conceptually but must be attached here | Not planned — Music27 territory; listed for completeness |
| Settings icons (per-app) | `Preferences` | CONFIRMED UIKIT | CONFIRMED UIKIT | Standard `UITableViewCell` image views | D candidate — separate injection filter, only if wanted |

## How to fill in a PENDING DUMP row

1. Enable SwiftPeek (`enabled` + `dumpFields`) on the device, injected into
   SpringBoard, and bring the surface on screen (respring for lock screen).
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
