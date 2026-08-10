# Glyph

Clean, modern, high-performance successor to SnowBoard for rootless and
roothide jailbreaks. Targets iOS 16.7.x (iPhone X / Dopamine) and 17.x
(12 mini / Relaxin').

**Status:** Phase B (UIKit icon engine) + Phase D (recolouring / glass) —
untested on device. Not published to the APT repo.

## What Glyph is (and is not)

- Full compatibility with existing SnowBoard theme packs — PNG `IconBundles/`
  under `$jbroot/Library/Themes/`, read exactly as they exist on disk. No
  conversion, ever.
- Home Screen icons (grid, dock, folders, badges) on iOS 16.7 / 17.x are
  **pure UIKit** (`SBIconView` / `SBIconImageView`). Glyph themes them with a
  classic UIKit hook — there is no SwiftUI icon view on the icon grid and
  Glyph does not pretend there is.
- SwiftUI theming (Phase C) is allowed **only** on surfaces SwiftPeek dumps
  have confirmed as SwiftUI-hosted, and only at the layer/image boundary
  (`CALayer.contents`). Never AttributeGraph hooks, never SwiftUI ownership
  mutation.
- No "locked 120Hz" or other invented firmware features. The performance win
  is real but boring: composite each icon exactly once, at its exact
  on-screen pixel size, then serve it from memory.
- Phase D recreates the *look* of iOS 18 tinted icons and iOS 26 clear glass on
  firmware that has neither. That is theming, and it is described as theming —
  Glyph never claims 16.7/17 ship those features.

## How the icon engine works

`-[SBIconImageView setContentsImage:]` is the single choke point where the
final rendered icon bitmap lands on the view. Glyph hooks it, asks
`GLIconCache` for a themed bitmap (decoded once per theme generation at the
stock image's exact geometry so masks/badges/labels line up), and substitutes
it. No match, any error, or theming disabled → stock image passes through
untouched.

| File | Role |
|------|------|
| `src/Tweak.x` | Hook, post-launch install, one-shot refresh pass |
| `src/GLThemeStore.m` | SnowBoard `IconBundles/` reader (`<id>-large.png`, `@3x`, `@2x`, plain) |
| `src/GLIconCache.m` | Decoded-once image cache, generation-keyed, negative caching |
| `src/GLPrefs.m` | jbroot resolution, prefs, kill switch (SwiftPeek/Music27 pattern) |
| `src/GLRecipeBuilder.m` | Preferences → `GLRecipe`, per-app overrides, exclusions |
| `src/GLComposite.m` | CoreGraphics ↔ GLPixelKit bridge (draw, composite, wrap) |
| `src/GLPixelKit.c` | The composite kernels: tint ramp, dark, glass, plate, corner mask |

## Prefs

Domain: `com.kolby.glyph`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Master switch |
| `logEvents` | `true` | NSLog event lines |
| `selectedThemes` | `[]` | Theme folder names, priority order (first hit wins) |
| `iconMode` | `0` | 0 stock · 1 tinted · 2 light tinted · 3 dark · 4 glass · 5 glass dark |
| `tintColor` | `#FF5FB2` | Your colour, `#rrggbb` |
| `plateFill` | `true` | Give transparent glyph-only artwork a plate to sit on |
| `tintLevels` / `tintContrast` / `tintGamma` / `tintShadowLift` | `0.85` / `0.35` / `1.0` / `0.10` | Tint ramp shaping |
| `darkStrength` | `0.55` | How far dark mode pushes the plate down |
| `glassPlateAlpha` / `glassFrost` / `glassSpecular` / `glassRim` / `glassRefraction` | `0.22` / `0.55` / `0.55` / `0.60` / `0.55` | Glass appearance |
| `glassTintAmount` | `0.0` | Mix your colour into the glass |
| `cornerRadius` | `0.0` | Squircle-mask square theme artwork (0 = leave alone) |
| `excludedApps` | `[]` | Bundle IDs Glyph leaves completely alone |
| `perApp` | `{}` | Per-app overrides, e.g. `{"com.foo.bar": {"mode": 4, "tint": "#33aaff", "plateFill": true}}`. Accepts `mode`, `tint`, `plateFill`, `tintLevels`, `tintContrast`, `tintGamma`, `tintShadowLift`, `darkStrength`, `glassPlateAlpha`, `glassFrost`, `glassTintAmount`, `cornerRadius` |

Set `selectedThemes` by writing the array into the prefs plist. Darwin
notifications `com.kolby.glyph/prefschanged` and `com.kolby.glyph/themeschanged`
re-theme live; respring after disabling to restore stock icons.

## Phase D — recolouring and glass

Everything in Phase D is composited at **cache-miss time** — once per icon per
theme/preference generation — and then served from memory. Nothing here runs
per frame.

- **Tinted / light tinted.** The artwork's luminance is auto-levelled per icon
  and mapped onto a three-stop ramp built from your colour. Three stops, not
  two: a straight dark→light interpolation of one hue passes through grey in
  the midtones, which is why a naive version makes every icon look brown
  regardless of the colour picked. Anchoring the middle of the ramp at your
  actual colour keeps the hue where most of an icon's pixels land.
- **Dark.** Darkens the plate while sparing the artwork. Local contrast
  separates glyph from plate first, because the brightest pixels in a typical
  icon *are* the white logo — darkening by luminance alone dims exactly the
  part that has to stay legible.
- **Clear glass.** The plate is left partly transparent and only the light
  behaviour is baked in: specular highlight, edge rim, inner shadow, and edge
  lensing with a little chromatic dispersion. SpringBoard's own compositor then
  shows the real wallpaper through the icon, live, as you scroll pages — for
  zero per-frame cost on our side. Sampling a wallpaper crop into the bitmap
  instead would have forced a re-composite on every page change and still been
  wrong the moment you scrolled.
- **Un-themed icons are included.** When no selected theme provides artwork for
  a bundle ID, the stock bitmap becomes the base layer, which is what lets one
  colour apply across the whole home screen.

### Generating per-app overrides

SwiftPeek 0.4.0's icon inventory records a pixel signature for every installed
app, and the host analyser turns that into a `perApp` dictionary — glyph-only
artwork gets `plateFill`, artwork with a degenerate histogram gets its
auto-levels dialled back, and everything else is left to the global recipe:

```bash
PYTHONPATH=tools python3 -m swiftpeek icons SpringBoard_<ts>.json
PYTHONPATH=tools python3 -m swiftpeek tint-plan SpringBoard_<ts>.json --mode 4 -o plan.json
```

The `per_app` block of `plan.json` goes straight into `com.kolby.glyph.plist`
under the `perApp` key.

### Verifying the kernels without a device

The colour maths lives in `src/GLPixelKit.c` as plain C — no Foundation, no
UIKit — specifically so it can be exercised on a Linux host instead of being
seen for the first time on a device that can Safe Mode:

```bash
cc -O2 -o tools/glyph-preview tools/glyph-preview.c Glyph/src/GLPixelKit.c -lm
./tools/glyph-preview /tmp/glyph-sheet.png
```

That renders a contact sheet of every mode over three icon shapes (full-bleed
artwork, glyph-only, flat solid) composited over a stand-in wallpaper, and
exits non-zero if any kernel fails or produces an empty bitmap.

## Safety (non-negotiable)

- Prefs default **off**. When off, the constructor registers two notification
  observers and returns — zero hooks.
- **Kill switch:** `touch /var/mobile/Library/Preferences/com.kolby.glyph.killswitch`
  and respring. Constructor checks it (jbroot-aware) before doing anything.
- **Zero boot-path work.** No hooking in the constructor; hooks install after
  `UIApplicationDidFinishLaunching` + 2 s, outside the watchdog window (the
  CC27 1.0.7 lesson). A bounded one-shot refresh pass then re-themes the
  icons that already rendered stock.
- **Fail closed everywhere.** Hook point verified to exist before `%init`;
  every theming path is wrapped so any surprise returns the stock image.
- No per-frame work: theming happens only when SpringBoard itself pushes a
  new contents image, plus the one-shot pass on install / theme change.

## Build

```bash
cd Glyph
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # iPhone X / Dopamine
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # 12 mini / Relaxin'
```

Depends on `mobilesubstrate` (ElleKit provides it on device) and
`preferenceloader`.

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| A | `docs/SURFACES.md` from real SwiftPeek dumps | Template ready, awaiting dumps |
| B | UIKit icon engine (this package) | Scaffolded, needs on-device validation |
| C | One confirmed SwiftUI surface (Lock Screen widgets or App Library), layer boundary only | Gated on Phase A |
| D | Precomputed effects (glass, corner masks, tints) + manager UI | Kernels done and host-verified; needs on-device validation |
