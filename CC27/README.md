# CC27

iOS **26-style Control Center** for jailbroken **iOS 15–17** (works alongside rootless + RootHide).

Unlike aesthetic-only tweaks (CC26 / CCXVIII), CC27 focuses on the **real customization UX**:

- **Hold empty space** or tap **+** to enter edit mode (jiggle)
- **Drag** modules to rearrange
- **−** to remove a control
- **Add a Control** opens a searchable list gallery (Available / All)
- Gallery lists **system + third-party CCSupport modules + CC27 widgets**
- Liquid-glass module chrome (round 1×1 / pill modules; expanded menus stay unclipped)
- Built-in CC27 modules: **Respring**, **Safe Mode**, **UICache**, **Userspace Reboot**

## 1.0.9 fixes

- **Lock screen guard now fails closed.** `CC27ViewIsInControlCenter` returned
  `YES` whenever the ancestor walk was inconclusive. During early `layoutSubviews`
  the superview chain is still being assembled, so a Lock Screen quick-action
  container (flashlight / camera — same class CC27 hooks) could reach that default
  and get styled. That is the 1.0.5 / 1.0.6 freeze pattern, still reachable in
  1.0.8. Views not yet in a window are now skipped, and only a positive
  `ControlCenter` ancestor qualifies. **This does not undo 1.0.8:** the whitelist
  still wins per level while walking up, so CC opened over the lock screen — which
  legitimately has `CoverSheet` ancestors above its CC chrome — keeps its glass.
- **Emergency kill switch works on RootHide.** The `%ctor` check hardcoded
  `/var/mobile/…`, so on RootHide the one escape hatch from a boot hang silently
  did nothing. It now resolves through the same jbroot prefix the prefs use
  (rootless, RootHide, and rootful paths are all checked).
- **Opt-in recon dump** (Settings → CC27 → Debug → Recon Dump, default **off**).

## Recon dump

CC27 hardcodes private `CCUI*` / `CCS*` class names and KVC keys
(`_moduleInstanceByIdentifier`, `moduleIdentifier`, `_repository`, `_viewDelegate`)
that were never verified against a real device. With Recon Dump on, opening
Control Center writes a read-only snapshot in **SwiftPeek's** dump format:

```
<jbroot>/var/mobile/Library/SwiftPeek/dumps/SpringBoard_<timestamp>.json
```

Pull it with Filza. The most useful part is the `fields` object, which no host tool
surfaces — read it straight out of the JSON:

```bash
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); \
[print(f'{v:<28} {k}') for k,v in sorted(d['fields'].items())]" SpringBoard_….json
```

Every entry reports `present` / `MISSING` / `nil` / `THREW:…`. **Anything that is not
`present` is a hardcoded string in CC27 that needs correcting.** Each module-container
node also carries `in_control_center` — the live answer from the guard above.

For the view tree, these work on a SpringBoard dump:

```bash
PYTHONPATH=tools python3 -m swiftpeek summary SpringBoard_….json
PYTHONPATH=tools python3 -m swiftpeek types   SpringBoard_….json
PYTHONPATH=tools python3 -m swiftpeek targets SpringBoard_….json
```

`annotate` and `find` will **not** help here and that is expected, not a bug: both
resolve against the offline field catalog, which was sampled from
`MusicApplication` — `find` searches only annotated fields and screen strings, never
class names, so it returns nothing on a CC dump. Teaching the host tools about CC
types is a follow-up.

This works **without injecting SwiftPeek into SpringBoard** — CC27 already runs
there and links SwiftPeek's dump writer in-process (`CC27/Makefile`). SwiftPeek's
own SpringBoard guards are untouched, and its FOVO field walker is deliberately not
linked. Note the offline field catalog is Music-sampled, so `annotate` adds little
here; the class names and hierarchy are the useful part.

Caps: max 10 dumps per respring, 400 nodes, depth 12. Never runs while locked.

## 1.0.8 fixes

- **Rounded / glassy module styling restored.** Two regressions were stripping the
  liquid-glass look: the expanded-module check could match an unrelated "expanded"
  property higher in the CC view hierarchy (sending every module down the unstyled
  path), and the lock screen guard was overly broad. CC detection is now
  whitelist-first (any `ControlCenter` ancestor ⇒ style it) and expansion is read
  only from the module's own container view controller.
- **Glass styling works again when CC is opened from the lock screen.** The lock
  screen freeze turned out to be caused by a different tweak, so styling is no
  longer suppressed while locked. Edit mode and the top buttons remain
  unlock-only, matching stock iOS 26 behavior.
- The boot-path hardening from 1.0.7 (no hooks until after SpringBoard finishes
  launching) is kept — it costs nothing and avoids boot-time interference.

## 1.0.7 fixes

- **Boot hang / black reload screen fixed**: CC27 no longer runs any code during
  SpringBoard's launch. Hooks are installed a couple of seconds *after* launch
  completes, so the boot-critical path (and the first lock screen) is 100% stock.
  This targets the ~1-minute hang followed by a black reload screen after
  re-jailbreaking.
- **No more per-read preference lookups**: preference values are cached once at
  load and on change, removing synchronous cfprefsd round-trips from every
  Control Center layout pass.

## 1.0.6 fixes

- **Freeze when opening CC from the lock screen fixed**: CC27 is now fully inert while the
  device UI is locked — no chrome, no glass styling, no edit mode until you unlock.
  (Stock iOS 26 doesn't allow CC editing from the lock screen either.) Control Center
  opened while locked looks stock; all CC27 features return after unlocking.

## 1.0.5 fixes

- **Frozen lock screen on iOS 16 fixed**: the Lock Screen flashlight/camera quick actions embed
  real CC module views — CC27 was styling them too. CC27 now refuses to touch any module
  container hosted outside Control Center (quick actions, cover sheet, lock screen)
- Chrome (+/power buttons, gestures) is created on first CC presentation instead of at
  SpringBoard boot; all module styling is wrapped in exception guards
- CC27 action modules no longer force-load their views during boot instantiation
- **Emergency kill switch**: `touch /var/mobile/Library/Preferences/com.kolby.cc27.killswitch`
  (SSH or Filza) then respring — CC27 stays installed but fully inert. Delete the file to re-enable
- Settings layout editor refuses to save an empty module list

## 1.0.4 fixes

- **Drag no longer safe-modes**: dragging now moves a snapshot while Control Center keeps
  owning the real views, and the reorder commit uses a gentle settings-only refresh wrapped
  in exception guards — the aggressive instance rebuild that crashed SpringBoard is gone
- Modules move freely under your finger (CC's layout can no longer fight the drag)
- **New: Settings → CC27 → Edit Control Center Layout** — a mirror of your CC grid
  (2×2 connectivity/media, tall brightness/volume sliders, 1×1 toggles) where you hold &
  drag tiles to rearrange with native reflow, then Apply & Respring commits the order

## 1.0.3 fixes

- **No more duplicate-add crash**: built-in controls (Volume, Brightness, Connectivity, …) are marked
  **Built-in** in the gallery and can't be added twice
- Gallery rows for user-added controls now show a red **Remove** pill (tap to remove)
- **Liquid-glass 3-D UI**: blurred glass gallery cards, icon tiles, top buttons, Add pill and toasts —
  all with sheen gradients, hairline borders and depth shadows
- Modules cast a soft drop shadow and carry a glass sheen
- **Home-screen style drag**: while you drag a module, the others reflow live around your finger,
  and the layout commits where you drop it

## 1.0.2 fixes

- Restored round / pill module glass (clips collapsed modules; still skips expanded menus)
- Removed resize entirely — the old size override path could safe-mode SpringBoard
- Gallery icons: unique SF Symbols per control (no more blank white squares / identical glyphs)
- Settings → CC27 → Respring works on rootless / RootHide

## 1.0.1 fixes

- Top **+** / power buttons stay visible while Control Center is open
- Add Control gallery uses readable list rows (no overlapping “System” labels)
- Adding a control reloads module instances (or prompts one reopen if needed)
- Expanded menus no longer cut into a circle by glass clipping

## Install

Add **Lumina Repo** in Sileo:

```
https://raw.githubusercontent.com/ma6x9x/lumina-repo/main/
```

Install **CC27** (depends on **CCSupport**). Respring. Open Control Center → tap **+** or touch & hold empty space.

Settings live under **Settings → CC27**.

## Build

```bash
cd CC27
export THEOS=~/theos
make package FINALPACKAGE=1
# RootHide:
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

Or run **Actions → Build CC27** on GitHub and grab the artifact `.deb`.

## Notes

- Requires [CCSupport](https://github.com/opa334/CCSupport) so `/Library/ControlCenter/Bundles` modules and the CC27 provider load.
- Conflicts with CC26 / CCXVIII / CC18 (overlapping Control Center chrome).
- Resize is an approximation of iOS 26’s freeform grid on top of the iOS 15–17 modular layout engine.
- Target: **iOS 15–17**; may load on 14 but is not the focus.
