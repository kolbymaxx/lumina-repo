# Music27

Jailbreak tweak that restyles **Apple Music on iOS 16 / 17** toward the **iOS 26 / 27 Liquid Glass** look:

- **Floating glass dock**
  - **Expanded:** mini-player glass pill stacked above a 5-tab glass pill
  - **Collapsed (after scroll down):** merged pill with red Music button · now playing · Search
  - Tap the **red button** to expand back to the 5-tab layout
- **Album / playlist controls:** Shuffle (circle) · Play (pill) · Download (circle)
- Artwork-driven color wash on album / playlist / now-playing
- **Pinned** row at the top of Library + Pin / Unpin in context menus and detail nav bars

Settings live under **Settings → Music27**.

## Dock behavior

1. Fresh launch starts **expanded** (mini pill + 5-tab pill).
2. Scrolling down collapses into the merged red · mini · Search pill.
3. Tap the **red button** to expand back to the 5-tab layout.
4. Stock tab bar / mini player stay intact; an overlay cover paints over them while the glass dock is ON.

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
| **1.1.18** | **Make cover visible:** solid dark cover (not fragile blur), `UIWindowLevelStatusBar - 1`, `safeBottom+12` float, install retries + Console logs. Still never mutates Music views |

Prefs are read preferring `/var/jb/.../com.music27.tweak.plist` (Dopamine), then jbroot (RootHide), then rootful.

## Install via Sileo (Lumina Repo — recommended)

Add this source in Sileo (**Sources → Edit → Add**):

```
https://raw.githubusercontent.com/ma6x9x/lumina-repo/main/
```

Then search for **Music27** and install. New versions show up as normal Sileo updates when the repo is refreshed.

Manual / Filza: install `packages/com.music27.tweak_*.deb`, respring, force-quit and relaunch **Music**. Toggle features under **Settings → Music27**.

Architecture: `iphoneos-arm64` (rootless, files under `/var/jb`).

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
