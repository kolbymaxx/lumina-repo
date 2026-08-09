# Music27

Jailbreak tweak that restyles **Apple Music on iOS 16 / 17** toward the **iOS 26 / 27 Liquid Glass** look:

- **Floating glass dock**
  - **Expanded:** mini-player glass pill stacked above a 5-tab glass pill
  - **Collapsed (after scroll down):** merged pill with red Music button · now playing · Search
  - Tap the **red button** to expand back to the 5-tab layout
- **Album / playlist controls:** Shuffle (circle) · Play (pill) · Download (circle)
- Artwork-driven color wash on album / playlist / now-playing
- **Pinned** row at the top of Library + Pin / Unpin in context menus and detail nav bars

**Primary prove target: iOS 17 rootless Dopamine.** Stock Music on 17 already floats the mini-player closer to the iOS 27 look; 16 remains supported but is secondary until the 17 dock is verified.

Settings live under **Settings → Music27**.

## Dock behavior

1. Fresh launch starts **expanded** (mini pill + 5-tab pill).
2. Scrolling down collapses into the merged red · mini · Search pill.
3. Tap the **red button** to expand back to the 5-tab layout.
4. Stock mini / tabs stay intact; glass pills float in a **passthrough bottom-strip window at `Normal + 2`** with no solid cover plate. The window must never be full-screen — see *Measured* under **Verify**.

## Blank-screen history

| Version | Notes |
|--------|--------|
| 1.1.0 | Safe-area mutation every layout + mini-player walk → white/blank Music |
| 1.1.1 | Safer dock install; briefly worked on device |
| 1.1.3–1.1.5 | Library blank / dock restore churn |
| 1.1.8 | Claimed “overlay without safe-area crush” but still cleared `additionalSafeAreaInsets` and installed from broad hooks → blank on iPhone X / Dopamine |
| **1.1.9** | **Never** mutates `additionalSafeAreaInsets`. Installs dock once from `UITabBarController viewDidAppear` only. One-time safe-boot forces Floating Glass Dock + Color Theme **OFF** so Music opens; re-enable after verifying |
| **1.1.10** | Dock-ON blank Library: host dock on the **window** (not `UITabBarController.view`), never fade stock mini-player, pass-through hit-testing outside glass pills |
| **1.1.11** | SwiftPeek proved `MusicApplication.LibraryViewController` / `MiniPlayerViewController` / SwiftUI hosts stay alive while Music looks black. Narrow matchers; never hide protected hosts; leave stock tab bar intact |
| **1.1.12** | Dock moves to a **dedicated passthrough `UIWindow`** — never a subview of Music’s key window. Library usable with dock ON |
| **1.1.13** | Soft-hide stock chrome + stronger glass, but float pad still capped (~18pt) — still looked glued on iPhone X |
| **1.1.14** | Real float + faded MiniPlayerViewController.view → black/crash regression on iPhone X |
| **1.1.15** | **Never** fade MiniPlayer. Soft-hide UITabBar only. Keep `safeBottom+12` float + overlay window. One-time force dock OFF for recovery |
| **1.1.16** | Soft-hide Music `tabsViewController` chrome — still left stock tabs visible on device for many users |
| **1.1.17** | **Cover, don’t mutate:** overlay mask over stock chrome + dual glass pills on top. Never alpha-hide Music views |
| **1.1.18** | **Make cover visible:** solid cover, `UIWindowLevelStatusBar - 1`, `safeBottom+12` float, install retries + Console logs |
| **1.1.19** | **iOS 17-first:** adaptive light/dark cover on a full-screen StatusBar-level overlay — **white-screened** light Library on iOS 17.3 (SwiftPeek still saw TabBar/MiniPlayer alive) |
| **1.1.20** | **White-screen recovery:** remove solid cover; overlay is a **bottom strip only** at `Normal+10`; one-time force dock OFF. SwiftPeek dump on iPhone13,1 / 17.3 confirmed `TabBarController` + `MiniPlayerViewController`. Dock then never painted at all on 17.3 — `Normal+10` does not composite above Music |
| **1.1.21** | Full-screen `StatusBar - 1` overlay with **no plate at all** — still white-screened. This is the decisive result: 1.1.19 and 1.1.21 differ only by the plate and both blanked Music, so **the plate was never the cause — the window level was** |
| **1.1.22** | **White-screen fixed, dock still invisible:** level back to `UIWindowLevelNormal + 2`. Library usable on 17.3, Music still stock |
| **1.1.23** | Diagnostics only: `status.log` / `status.json` so the install path is readable from Filza. SwiftPeek 0.4.1 confirmed Music's own window is at level 0 |
| **1.1.24** | **White-screen fix:** overlay window is a **bottom strip**, never full-screen, created at its real size (no 1pt seed). Every full-screen build blanked Music at every level tried; the only non-blanking build was the only strip. Size was the variable all along |

Prefs are read preferring `/var/jb/.../com.music27.tweak.plist` (Dopamine), then jbroot (RootHide), then rootful.

## Install via Sileo (Lumina Repo — recommended)

Add this source in Sileo (**Sources → Edit → Add**):

```
https://raw.githubusercontent.com/ma6x9x/lumina-repo/main/
```

Then search for **Music27** and install. New versions show up as normal Sileo updates when the repo is refreshed.

Manual / Filza: install `packages/com.music27.tweak_*.deb`, respring, force-quit and relaunch **Music**. Toggle features under **Settings → Music27**.

Architecture: `iphoneos-arm64` (rootless, files under `/var/jb`).

## Verify on iOS 17 (Dopamine rootless)

1. Install the CI rootless `.deb` for this version; respring.
2. **Settings → Music27** footer must say **1.1.24**. This build does **not** force Floating Glass Dock OFF — it keeps whatever you last set, so if you turned it off to escape the 1.1.21 white screen, turn it back on.
3. Make sure Enable Music27 and Floating Glass Dock are both **ON**, then **force-quit Music** and relaunch.
4. Expect on 17.3 as of 1.1.24: glass pills in a bottom strip, Library usable, **no white screen**. If Music goes white, turn Floating Glass Dock back OFF and send `status.log` — a `layout` line with `full_screen=1` says the strip cap failed.
5. `status.log` is the primary diagnostic and needs no Mac. The same lines also go to Console under the filter `Music27 1.1.24` if you have one attached.

### Measured: full-screen is the variable, not window level

On iPhone13,1 / iOS 17.3 with Floating Glass Dock **on**:

| Build | Window shape | Level | Plate | Result |
|---|---|---|---|---|
| 1.1.19 | full-screen | `StatusBar - 1` | yes | **white screen** |
| 1.1.20 | **bottom strip** | `Normal + 10` | no | no white screen; nothing painted |
| 1.1.21 | full-screen | `StatusBar - 1` | **no** | **white screen** |
| 1.1.22 | full-screen | `Normal + 2` | no | **white screen** |

Three full-screen builds, at two very different levels, with and without a cover
plate, all blanked Music. The one build that did **not** blank it is the one whose
window was a bottom strip. **Size is the variable.** Level is not, and neither is
the plate — 1.1.19 through 1.1.22 each blamed one of those in turn.

A SwiftPeek 0.4.1 window dump (taken with the dock off) independently rules the
level theory out: Music's own window sits at **level 0** with nothing above it, so
`Normal + 2` was never "too low to composite".

```
level=0.0  {0,0,375,812}  MusicApplication.Window  root=MusicApplication.TabBarController  KEY OPAQUE
```

Do not make the overlay window full-screen again. `M27StripHeight()` hard-caps it
at 30% of screen height, and every layout records a `full_screen` flag to
`status.log` so a regression is visible without a device session.

### On-device diagnostics (1.1.23+)

The install and layout path reports itself to disk — no Console or Mac needed:

```
$jbroot/var/mobile/Library/Music27/status.log    # sequence of events
$jbroot/var/mobile/Library/Music27/status.json   # latest state
```

Readable in Filza. Force-quit Music, relaunch, then read `status.log`:

| Stage | Meaning |
|-------|---------|
| *(no lines at all)* | The dylib was never injected into Music |
| `loaded` only | Loaded, but the `UITabBarController` hooks never fired |
| `install_skip_prefs` | Declined; same line shows `enabled=` / `glassTabBar=` |
| `install_skip_nil_tbc` / `install_skip_tbc_unloaded` | Hook fired before Music's tab bar controller was usable |
| `install_ok` then `remove_dock` | Installed, then torn down by something later |
| `layout` | Records `strip=`, `dock_frame=`, `safe_bottom=`, `level=`, and `full_screen=` |

`full_screen=1` on a `layout` line means the strip cap failed and a white screen
is expected — that is the regression to watch for.

Known in 1.1.24, to tighten next: the strip sits over the bottom of full-screen Now Playing and any presented sheet. It stays passthrough — only the pills take taps — but it is visible there. Hiding the dock while Music presents a modal is the follow-up, along with sizing the pills for the 17 layout and suppressing the stock mini-player peek-through.

## Build

```bash
export THEOS=/opt/theos
make package FINALPACKAGE=1
```

Requires Theos with an iOS 15+ SDK (this project targets `iphone:clang:16.5:15.0`) and a rootless packaging scheme.

## Publish updates to Lumina Repo

After building a new `.deb`, publish it into Lumina Repo (`dist/` + apt index):

```bash
./scripts/publish-to-lumina.sh
# then commit/push from the monorepo root (or the branch it creates)
```

Or copy the deb into `dist/` at the Lumina Repo root and run `scripts/update-apt-repo.sh`, then commit `Packages`, `Packages.gz`, `Packages.bz2`, `Packages.xz`, and `Release`.

## Scope / honesty

This approximates Liquid Glass with `UIVisualEffectView` + continuous corners + specular border + soft shadow. It is **not** Apple’s private Liquid Glass renderer. The dock replaces Music’s stock tab bar / mini-player chrome visually while forwarding tab selection, Search, play/pause (MediaRemote), and Now Playing presentation to Music’s real controllers.
