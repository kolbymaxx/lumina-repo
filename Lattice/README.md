# Lattice

Home Screen grid freedom for iOS 16.7.x (iPhone X / Dopamine) and 17.x
(12 mini / Relaxin').

**Status:** 0.1.0 — untested on device. Not published to the APT repo.

## What Lattice is (and is not)

iOS has never allowed a custom Home Screen grid, and free icon placement only
arrived in **iOS 18** — neither is available on 16.7 or 17.x. Lattice brings
the grid half of that: any number of rows and columns per page, an independent
dock width, and optional hidden labels.

What it is *not* is an icon rearranger. Every hook in Lattice returns a
**number**. It never moves an icon, never inserts a placeholder, never reorders
a page, and never writes to the icon state file. That boundary is the whole
safety argument:

- Returning a wrong number gives you an ugly grid, which you undo in Settings.
- Writing a wrong icon model persists to disk, survives a respring, and is not
  self-healing.

Free placement and blank slots need the second kind of change, so they are
**not** in 0.1.0. See [`docs/LAYOUT.md`](docs/LAYOUT.md) for what is gated and
why — same discipline as Glyph's `SURFACES.md`.

## Design

| File | Role |
|------|------|
| `src/Tweak.x` | Hooks, runtime selector verification, relayout |
| `src/LTLayout.m` | Preferences → clamped layout struct |
| `src/LTPrefs.m` | jbroot resolution, prefs, kill switch |

**Policy lives in `LTLayout.m`, not in the hooks.** Every hook body is a couple
of lines that return a value someone already clamped, so there is no place for
a bad number to originate inside a method SpringBoard calls during layout.

**Values are clamped** to 2–12 rows, 2–10 columns, 1–8 dock icons. A
hand-edited plist cannot produce a zero-column grid.

**The dock shares the page's configuration class**, so Lattice tells them apart
by the configuration's own row count — a dock is one row, a page never is. With
"Custom Dock Width" off, the dock keeps its stock width no matter what the grid
is set to.

**Nothing is hooked until the selector is verified to exist** on the running
firmware (`class_getInstanceMethod` before `%init`). A firmware that does not
have the expected shape gets an inert tweak and a log line, not a guess.

## Prefs

Domain: `com.kolby.lattice`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Master switch |
| `overrideGrid` | `false` | Apply the custom rows/columns |
| `rows` | `6` | Rows per page (2–12) |
| `columns` | `4` | Columns per page (2–10) |
| `landscapeRows` / `landscapeColumns` | unset | Defaults to portrait, swapped |
| `overrideDock` | `false` | Apply the custom dock width |
| `dockColumns` | `4` | Dock icons (1–8) |
| `hideLabels` | `false` | Hide icon name labels |
| `logEvents` | `true` | NSLog event lines |

## Safety

- Prefs default **off**, and with every override off Lattice returns `%orig`
  from every hook — a literal no-op.
- **Kill switch:** `touch /var/mobile/Library/Preferences/com.kolby.lattice.killswitch`
  and respring to restore the stock layout without uninstalling.
- **Zero boot-path work.** Reading prefs means touching the filesystem, which
  is exactly what cost CC27 a 60 s boot hang, so the constructor only registers
  a Darwin observer. Hooks install 2 s after
  `UIApplicationDidFinishLaunching` and then force one relayout, so the custom
  grid appears a moment into boot rather than risking the boot itself.
- **Fail closed.** Selector existence verified before `%init`; the label hook
  is wrapped so a surprise leaves the label visible.

## Build

```bash
cd Lattice
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # iPhone X / Dopamine
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # 12 mini / Relaxin'
```
