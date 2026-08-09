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
4. Stock mini / tabs stay intact; glass pills float in a **bottom-strip overlay** (no solid cover plate — that caused the iOS 17 white screen).

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
| **1.1.21** | **Dock visible again:** back to the full-screen `UIWindowLevelStatusBar - 1` window that 1.1.19 proved *does* paint on 17.3, but with **no cover plate** — pills only, every other pixel clear passthrough. Overlay can never become key window. Migration keeps the user's dock toggle instead of forcing it OFF |

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
2. **Settings → Music27** footer must say **1.1.21**. Unlike 1.1.15/1.1.20 this build does **not** force Floating Glass Dock OFF — it keeps whatever you last set.
3. Make sure Enable Music27 and Floating Glass Dock are both **ON**, then **force-quit Music** and relaunch.
4. Expect: dual glass pills floating above the home indicator, and Library still scrollable/tappable everywhere else (stock mini may peek behind the pills — OK). No white or black plate anywhere.
5. Optional Console filter: `Music27 1.1.21` → `loaded` / `install OK` / `overlay window created level=` / `layout … screen=`.
   - `level=` should print roughly `999.0` (`UIWindowLevelStatusBar - 1`). If `install skip: prefs` shows instead, the toggle did not stick.

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
