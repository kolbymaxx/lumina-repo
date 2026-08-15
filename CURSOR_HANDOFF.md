# Handoff prompt — lumina-repo (Music27 / SwiftPeek / SPKit)

Paste everything below the line into Cursor.

---

You are continuing work on `ma6x9x/lumina-repo`, a jailbreak-tweak monorepo for
iOS 16/17. Read `AGENTS.md` first, then `Music27/README.md` and
`SwiftPeek/docs/DEPENDENCY_PLAN.md`. Those three files are the real state; this
prompt is the summary.

## The projects

- **Music27** (`Music27/`, v1.1.55) — restyles Apple Music toward the iOS 26/27
  "Liquid Glass" look. Logos/Theos tweak, `.x` + ObjC. The active project.
- **SwiftPeek** (`SwiftPeek/`, v0.6.0) — read-only SwiftUI + window-tree
  inspector. Being grown into a dependency other tweaks can use.
- **SPKit** (`SPKit/`) — shared ObjC source (jbroot resolver, prefs, trace
  writer, passthrough overlay window). Consumed by symlink, not linked.
- **tools/swiftpeek/** — host-side Python that reads SwiftPeek dumps. 49 tests.

## Hard rules

1. **One project per branch.** `claude/continue-*` owns `Music27/`;
   `claude/swiftpeek-*` owns `SwiftPeek/` + `tools/swiftpeek/`. This is a rule
   because it was already violated — see `SwiftPeek/docs/MERGE_NOTES.md` for the
   three-way collision it produced. Current branches:
   - Music27 → `claude/continue-1-1-21-owif9e` (at `26409c7`)
   - SwiftPeek → `claude/swiftpeek-springboard-recon` (at `173152b`)
2. **Never push to `main`.** Never open a PR unless explicitly asked.
3. **SwiftPeek is read-only and must never mutate UI.** Its SpringBoard path is
   ObjC-only: no hooks, no swizzles, no FOVO, no Swift metadata walks. Icons only
   via `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]` and
   `LSApplicationWorkspace` — never `SBIconModel`, the icon cache, or the icon
   view tree. A Swift-linked dylib in SpringBoard caused Safe Mode at 0.2.1; CI
   asserts on the built binary that the Swift runtime is not linked.
4. **There is no iOS SDK in this environment.** You cannot compile the ObjC.
   Four CI breaks in this repo came from editing ObjC without a compiler, all of
   them `-Werror` pointer-type or unused-variable classes. Re-read every ObjC
   edit for those specifically before pushing.
5. **Device testing is iPhone 12 mini (iPhone13,1) / iOS 17.3 only.** 16.7 is
   untried. Do not claim 16.7 verification.
6. `tools/swiftpeek/icons.py` thresholds are calibrated against a **real**
   201-entry SpringBoard inventory, not synthetic data. If you change one,
   re-run against a real dump; the override count must stay a small minority.

## Verify before pushing

```bash
cd tools && python3 -m unittest swiftpeek.test_icons swiftpeek.test_api swiftpeek.test_scaffold
./scripts/check-swiftpeek-version.sh     # SwiftPeek version appears in 4 places
```

CI builds both rootless and roothide `.deb`s per project. The Theos setup step
and `actions/checkout` both flake on TLS regularly — six times in one day. Both
have retries; a red build is worth reading before assuming it is your code.

## Music27 — the queue

Working and verified on device: glass mini-pill and floating dock, edge-light
refraction, live download progress ring, normalised black/white glyphs,
nav-bar download hide + tap forwarding.

1. **Swipe the mini pill to skip / go back** — recorded in `Music27/README.md`
   under "Planned next: swipe the mini pill", both dock modes. The open problem
   is gesture delivery: the pill lives in a passthrough overlay window and the
   carousel underneath wants the same horizontal pan. Read that section before
   designing anything.
2. **Full-bleed album artwork + colour-matched album screen.** Key finding
   already made: Apple's full-screen player background is an **`MTKView`
   (Metal)**, so its palette cannot be copied — Music27 extracts its own.
   `PaletteContainerView` tracks theme, not artwork. `M27ApplyWash` already
   applies the right colours (`0.45/0.18/clear`, confirmed in a device dump) to
   the album controller's root view — but that root has an opaque black
   background and **one unvisited child** (`truncated: 1`) painting over it.
   **Next concrete step: one SwiftPeek dump at Depth 10 on the album screen to
   name that child.** Then move the wash above it.
3. **Replace the two polling timers** — a 0.25s download-state mirror and a 50ms
   retry — with observation.
4. **Honour Low Power Mode** (skip animations/blur when enabled).

## SwiftPeek — the queue

0.6.0 just landed: the injection filter is now `com.apple.UIKit` and the target
decision happens at runtime (`targetCustom` + a free-text bundle-ID list in
Settings), so the tool can finally be pointed at an app other than the seven
that were hardcoded. Every dump records `target_rule` explaining why SwiftPeek
did or did not run. CI asserts `SPIsAllowedProcess()` is still the **first**
statement of the constructor — a broad filter with a late gate would be a real
hazard, and that check is what stops it becoming one by accident.

1. **Stable anchors** — capability 1 in `SwiftPeek/docs/DEPENDENCY_CAPABILITIES.md`,
   and the one Music27 keeps hand-rolling. SwiftUI gives no persistent object to
   hold and rebuilds its tree on state change; consumers re-resolve by hand every
   time. This is the highest-value dependency work.
2. **Control discovery** — the open requirement in `DEPENDENCY_PLAN.md`. Music27
   finds stock controls by matching title text, which is fragile. Answer "what is
   the tappable thing here?" by accessibility label, gesture-recogniser presence
   and geometry, and report what was *not* found rather than failing silently.
3. **A 16.7 SpringBoard dump** from the iPhone X, to close the firmware caveat.
4. Dogfooding step 3 in `DEPENDENCY_PLAN.md`: `SPPrefs.m` and `SPDumpWriter.m`
   still carry their own copies of the jbroot resolver that SPKit now owns.

## Hazards that already cost device cycles

The full registry is the table in `SwiftPeek/docs/DEPENDENCY_PLAN.md`. Read it.
The ones most likely to bite next:

- **`UIView.alpha` is backed by `CALayer.opacity` — the same property.** A build
  once "fixed" a dead tap by swapping one for the other, changed nothing, and the
  view stayed unreachable for fourteen versions. `hitTest:` refuses views under
  alpha 0.01. To hide something you still need to hit-test, give it an empty
  `CALayer` mask and leave `alpha` at 1.
- **A SwiftUI view's parts are not inside its parent's layer subtree.**
  `MusicCoreUI.SymbolButton` is *only* the grey capsule; SwiftUI draws the glyph
  and label as siblings. Hiding the button can never hide the glyph.
- **`MusicCoreUI.SymbolButton` is not a `UIControl`** —
  `sendActionsForControlEvents:` hits nothing. Fire the bar item's
  `target`/`action` instead.
- **`MPMusicPlayerController` inside Music.app crashes it** (it is an IPC client
  *for* Music). Use MediaRemote: `MRMediaRemoteSendCommand`, 2 = playpause,
  4 = next, 5 = previous.
- **Never assert a cause from a symptom without instrumentation.** Five wrong
  theories in a row on one bug; the real cause was a crash. Log synchronously
  with `fsync` — async logging loses exactly the line that explains the crash.
- **A field catalog answers for one firmware, not for the device in front of
  you.** `FieldCatalog.lookup()` returns `provenance` with every hit for this
  reason. If a dump and the catalog disagree, the dump wins.

## How the loop works

The user installs each build on the device and returns screenshots plus
`status.log` (Music27) or JSON dumps (SwiftPeek). Bump the version on every
build so logs are attributable, add a changelog row to the project README, and
say plainly what is verified on device versus what is only reasoned about.
