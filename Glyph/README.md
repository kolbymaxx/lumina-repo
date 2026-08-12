# Glyph

Clean, modern, high-performance successor to SnowBoard for rootless and
roothide jailbreaks. Targets iOS 16.7.x (iPhone X / Dopamine) and 17.x
(12 mini / Relaxin').

**Status:** Phase B (UIKit icon engine) — first scaffold, untested on device.
Not published to the APT repo.

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
  is real but boring: decode each themed icon exactly once, at its exact
  on-screen pixel size, then serve it from memory.

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

## Prefs

Domain: `com.kolby.glyph`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Master switch |
| `logEvents` | `true` | NSLog event lines |
| `selectedThemes` | `[]` | Theme folder names, priority order (first hit wins) |

Until the Phase D manager UI ships, set `selectedThemes` by writing the array
into the prefs plist. Darwin notifications `com.kolby.glyph/prefschanged` and
`com.kolby.glyph/themeschanged` re-theme live; respring after disabling to
restore stock icons.

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
| D | Precomputed effects (glass, corner masks, tints) + theme manager UI | Gated on B |
