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
| **1.1.24** | **White-screen fix:** overlay window is a **bottom strip**, never full-screen, created at its real size (no 1pt seed). On device with the dock ON, `status.log` showed `loaded` and then **nothing** — no `install_ok`, no exception, no `layout` |
| **1.1.25** | Synchronous + `fsync`'d logging with breadcrumbs. Caught it: three launches, all `install_begin` → `dock_created` → **process gone**, never reaching `layout_begin` |
| **1.1.26** | **Real fix.** Music was *crashing* during install; the white/black screen was a dead app, not a compositing bug. Cause: `MPMusicPlayerController.systemMusicPlayer` in `syncNowPlaying` — an IPC client for Music, called from inside Music. Removed everywhere. **Dock renders on 17.3 for the first time** |
| **1.1.27** | Stray sixth tab: Music reports **6 view controllers but shows 5 tabs**, and the extra one rendered as "Tab 5". Dock indices are now mapped to the controllers that actually own a tab bar item |
| **1.1.28** | Hides Music's own tab bar + mini player behind the dock. Worked — but hiding with `alpha` also made the mini player **un-hit-testable**, so the dock's Now Playing pill went dead |
| **1.1.29** | Hides via `layer.opacity` instead of `alpha`. `hitTest:` refuses any view with `alpha < 0.01`, and the Now Playing tap is forwarded by hit-testing the stock mini player — so `alpha` was hiding the very thing it needed to find |
| **1.1.35** | **Stock album glyphs finally covered.** 1.1.33's readback closed this: `play_hidden=yes play_opacity=0 play_alpha=0` while the red ▶ and "Shuffle" were plainly still on screen, so nothing was resetting the hide — the "re-render race" theory was wrong. `MusicCoreUI.SymbolButton` is only the **grey capsule background**; SwiftUI draws the glyph and label as siblings, outside that view's layer subtree. The row *container* is hidden now, and the glass row moves to be its sibling (a child would inherit `opacity 0`). Also: 1.1.33 wrote no `nowplaying_*` line at all, which was read as "the tap never arrives" — but the success branch logged nothing, so a tap that fired a control looked identical to no tap. Entry and every exit are recorded now, and the tap asks `accessibilityActivate` first instead of firing the first `UIControl` it finds, which was most likely the play/pause button |
| **1.1.34** | **No user-visible change.** The jailbreak-root resolver, prefs path list, `status.log` writer and the overlay window move to [SPKit](../SPKit), the shared runtime SwiftPeek and the 27-series tweaks build on. Music27 is its first consumer, so if this build behaves differently from 1.1.33 in any way, the extraction is wrong. Also collapses fifteen hardcoded `"1.1.33"` string literals into one `M27_VERSION` |
| **1.1.33** | Mini pill showed **"iPhone"** as the song title — that is the AirPlay route label, which happens to come first in the mini player's view order. Title/artist are now the two largest labels, ordered title-above-artist. Also reparents the album Play/Shuffle row to the stock controls' own superview so it scrolls with the header instead of floating over the track list on playlists |
| **1.1.32** | **Mini pill tap fixed.** The Now Playing gesture was attached only to the 36pt artwork and the title label, so most of the pill was dead — `status.log` proved it by never writing a single `nowplaying_*` line. The gesture moves to the whole pill. Also hides `MusicApplication.PaletteContainerView`, the bottom blur backdrop SwiftPeek identified, and finds the album Download control by accessibility label since title text returns nil on 17.3 |
| **1.1.31** | Album row diagnostics. The glass Shuffle/Play/Download circles are inert and do not cover the stock controls. `M27HideViewKeepLayout` refused silently for any view over 420pt wide or 72pt tall, making a failed lookup indistinguishable from a refused hide — both now report to `status.log`, and the hide uses `layer.opacity` so forwarding still works |
| **1.1.30** | **Track info finally populates.** Every build since 1.1.24 logged `sync_info keys=0` — `MPNowPlayingInfoCenter` is the *publishing* side of that API and Music does not use it, so reading it from inside Music was always empty. Now reads MediaRemote (`MRMediaRemoteGetNowPlayingInfo`), already proven safe in-process by the working play/pause. Refresh moves to MediaRemote notifications, since the old `setNowPlayingInfo:` hook never fired — which is why the pill never changed. Falls back to scraping the stock mini player's labels |

Prefs are read preferring jbroot (RootHide), then `/var/jb/.../com.music27.tweak.plist` (Dopamine), then rootful. Since 1.1.34 that list comes from `SPKPrefsCandidatePaths` in [SPKit](../SPKit) rather than a copy local to this tweak; on Dopamine the resolved jbroot *is* `/var/jb`, so the effective order is unchanged.

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
2. **Settings → Music27** footer must say **1.1.27**. This build does **not** force Floating Glass Dock OFF — it keeps whatever you last set, so if you turned it off to escape the 1.1.21 white screen, turn it back on.
3. Make sure Enable Music27 and Floating Glass Dock are both **ON**, then **force-quit Music** and relaunch.
4. Expect the glass pills to render, and `status.log` to reach `install_ok` with `overlay=yes`. Scrolling down should collapse the dock and shrink the strip.
5. `status.log` is the primary diagnostic and needs no Mac. The same lines also go to Console under the filter `Music27 1.1.27` if you have one attached.

### The white screen was a crash, not a rendering bug

1.1.25's synchronous log caught it — three launches, all ending the same way:

```
install_begin tabs=5 → dock_created h=118 → (process gone)
```

`layout_begin` never fired, so `M27LayoutDock` was never entered and the overlay
window was never created. Every window theory from 1.1.19 onward — cover plate,
window level, Music's own level, window size — was aimed at code that does not
run. A crashed app draws a blank white window (black in dark mode); that is all
"white screen" ever was.

The cause was `MPMusicPlayerController.systemMusicPlayer` in `syncNowPlaying`.
That class is an IPC client for the Music app, and this code runs *inside* Music.

**Do not reintroduce `MPMusicPlayerController` anywhere in Music27.** MediaRemote
handles play/pause and skip; without it the dock no-ops rather than reaching for
the IPC client. `playbackRate` from `nowPlayingInfo` supplies play state with no
IPC.

With that gone, 1.1.26 completes the whole path on iPhone13,1 / 17.3:

```
install_begin tabs=6 → dock_created → pre_reload → pre_setmode
→ pre_selected idx=3 → pre_sync → sync_begin → sync_info keys=0 → sync_done
→ pre_layout → layout_begin
→ overlay_created frame={{0,646},{375,166}} level=2
→ layout dock_frame={{0,14},{375,118}} full_screen=0 strip={{0,646},{375,166}}
→ install_ok overlay=yes overlay_hidden=0 dock_alpha=1 dock_superview=yes
```

Scroll-collapse works too — the strip shrinks to `{{0,700},{375,112}}` with a
64pt dock and expands back.

**A note on the window configuration.** Bottom-strip at `Normal + 2` is what
shipped and it renders, but it was chosen while chasing a crash that had nothing
to do with windows. It is a working default, not a validated design — the
full-screen and `StatusBar - 1` variants were never actually disproven, because
none of that code ever executed.

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

Known in 1.1.28, to tighten next — measured against iOS 26/27 reference shots:

- **Collapsed state should be three separate capsules**, not one merged pill: a circular Music button, a floating now-playing pill, and a circular Search button, each with a gap. Music27 currently draws them as one continuous pill.
- **Selected tab needs a proper filled capsule** behind it. The reference uses a clearly visible light capsule; Music27 uses a 12% tint that barely reads.
- Pill insets and corner radii are still tuned for the 16 layout. The reference insets both capsules from the screen edges and stacks them with a visible gap.
- The strip sits over the bottom of full-screen Now Playing and presented sheets. It stays passthrough, but it is visible there.

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
