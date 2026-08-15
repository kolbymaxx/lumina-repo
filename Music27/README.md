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
5. **Swipe the mini pill** left for next, right for previous. The pan lives on Music's own mini player so tap-to-open still passes through. Reasoned in 1.1.56; not yet on device.

## Planned next: full-bleed album artwork

Not started. Recorded here so it survives the conversation.

**The change.** On the album / playlist detail page, iOS 26/27 runs the cover
art **edge to edge** across the top — behind the nav bar, no inset square — and
lets the artwork's colour carry down into the page background. iOS 17 shows a
small centred square on a plain background. Reference screenshots: *Positions
(Deluxe)*, stock 17 versus 27.

**Colour matching — settled on device, and the answer is "extract it ourselves".**

The plan was to read the palette Apple computed for the full-screen player
rather than derive a worse one from the same artwork. SwiftPeek 0.5.4 answered
that with a focused walk of the player (`focus_root` on
`MusicApplication.TintColorObservingView`, depth 8):

```
d1  MusicLyricsBackgroundView   {0,0,375,812}   gradient=[clear → rgba(0,0,0,1.00)]
d2    MTKView                   {0,0,375,812}
d2    …Gradient.View            alpha=0.40       gradient=[clear → black]
d2    MusicApplication.BackdropView  hidden
```

**`MTKView` — the player's background is rendered in Metal.** There is no
CGColor to read; the colour is computed on the GPU. The only gradients on that
screen are `clear → black` legibility scrims. So the palette cannot be copied,
and this is a measured result rather than an assumption.

Two things this settles in our favour:

1. **`M27ColorTheme` already works.** The same dumps show our own extraction
   running on device — the wash on the album page carries
   `rgba(0.38,0.35,0.36,0.45) → rgba(0.21,0.19,0.20,0.18) → clear`, which is
   `M27ApplyWash`'s exact 0.45 / 0.18 / clear constants over an artwork-derived
   colour, and the glass pills carry `rgba(0.85,0.77,0.81,0.10)` from
   `applyPaletteTintToGlass`. Nothing needs building; it needs placing.
2. **`PaletteContainerView` is not the palette.** Its gradient reads
   `rgba(0.90,0.90,0.90,0.80)` in light mode and `rgba(0.00,0.00,0.00,0.80)` in
   dark — it tracks the *theme*, not the artwork. The name is misleading and
   would have cost a build.

**Where the wash actually goes.** It is applied to the album detail
controller's root `UIView {0,0,375,812}`, which also has an opaque black
`backgroundColor` and **one unvisited child** (`truncated: 1`) filling the same
frame. That child is the next thing to identify — the fix is either inserting
above it or colouring it directly, not moving the wash further back.

**The full-screen player, measured** (tweak off, iPhone13,1 / 17.3, 375×812) —
what 1.1.36 needed and never had:

| View | Frame |
|------|-------|
| `NowPlayingContentView` | `{24,92,327,327}` |
| └ `MusicArtworkComponentImageView` | `{44,44,239,239}` |
| `NowPlayingTransportControlStackView` | `{62,24,252,113}` |
| └ 3 × `NowPlayingTransportButton` | 40×40 |
| `VolumeSlider` | `{33,140,309,40}` |
| `PlayerTimeControl` | `{32,524,311,42}` |
| `AudioTraitButton` | `{146,552,83,15}` |
| `_UIGrabber` | `{170,56,36,5}` |
| `NowPlayingShuffleButton` | `{-23,66,28,28}`, **hidden** |

That last row is the control 1.1.38 fired by accident, confirmed off-screen at
negative x. Also present and worth knowing: the player contains real SwiftUI
(`SwiftUI._UIInheritedView`, `_UIGraphicsView`, a generic-mangled
`UIHostingContentView` for the Reactions button), even though SwiftPeek's own
host detector reported `hosts_found: 0` — its matcher misses the mangled generic
form.

**Where the wash has to go.** Measured, not guessed: the album page's
`UICollectionView` reports `bg 1.00`, and the wash is currently inserted at
layer index 0 with `zPosition -1000`, which puts it behind an opaque wall. That
is why *Artwork Color Theme* has never appeared to do anything. It has to colour
the collection view's own background, or sit above it.

**The constraint that matters: iOS 17+ album covers can be animated.** Several
albums ship video artwork that plays on the detail page — the *Positions
(Deluxe)* cover in the reference shots is one. So the artwork view cannot be
swapped for a static `UIImageView`, and its layer cannot be replaced with a
snapshot. Whatever resizes it has to resize **Music's own view**, leaving
whatever is driving the animation attached to it. Verify against an animated
cover, not just a still one, before believing it works.

**Measured on device (1.1.50, `album_tree`, iPhone 12 mini / 17.3, 375×812):**

```
safe_top = 94
0  UIView                                             {0,0,375,812}    bg 1.00
1  MusicApplication…VerticalStackViewController.ScrollView             bg 1.00
2  MusicApplication.TintColorObservingView                             bg 0.00
3  UICollectionView                                   {0,0,375,812}    bg 1.00
4  MusicApplication.ContainerDetailHeaderReusableView  {0,94,375,414}   bg 1.00
5  MusicApplication.DetailHeader                       {0,94,375,414}   bg 0.00
6  UIView                                              {72,101,231,231} bg 0.00   ← artwork
6  MusicApplication…DetailHeader.DetailsView           {20,332,335,176} bg 0.00
```

- **The artwork is the 231×231 `UIView` at `{72, 101}`** — centred (72 + 231 +
  72 = 375) and square, sitting directly above `DetailsView` (101 + 231 = 332).
  It is a plain `UIView` with no image of its own, so the thing actually drawing
  the cover is a level or two deeper than the depth-6 cap; the next dump needs a
  deeper walk rooted at this view, not at the page.
- **`DetailHeader` starts at y = 94, exactly `safe_top`.** Full-bleed means the
  artwork has to escape both the header's inset *and* the header's own origin —
  it must reach y = 0 and span the full 375, so this is not a matter of widening
  one view inside its parent's bounds.
- **The colour wash has never been visible, and now we know why.** It is
  inserted at layer index 0 of `vc.view` with `zPosition = -1000`, and the
  `UICollectionView` above it reports **`bg 1.00`** — a fully opaque background
  covering the whole page, with `ContainerDetailHeaderReusableView` opaque on
  top of that. So *Artwork Color Theme* has been painting behind an opaque wall
  regardless of the toggle. The fix is to colour the collection view's own
  background (or insert above it), not to insert further back.

**What this session already established that applies here:**

- The detail header is built **asynchronously** — `album_lookup_failed
  play=nil shuffle=nil` fires at both `viewWillAppear` and the first
  `viewDidLayoutSubviews`. Anything touching this page needs the same retry the
  glass row uses.
- The Play/Shuffle row lives in a `MusicApplication…Spacer` inside
  `_TtCC16MusicApplication12DetailHeader11DetailsView`. Full-bleed artwork will
  move relative to that row, so the glass row's placement will need rechecking.
- Hiding a view you still need to hit-test needs a **mask**, never `alpha` or
  `layer.opacity` — they are the same property. See 1.1.43.

## Planned next: swipe the mini pill to skip / go back

**Shipped in 1.1.56. Reasoned, not yet verified on device.**

**The change.** On iOS 26/27 the mini player is swipeable: drag it left for the
next track, right for the previous one, and the artwork and titles slide with
your finger rather than cutting. Wanted on **both** dock modes — the expanded
mini pill and the collapsed centre capsule.

**Gesture delivery — option 1 of the three that were written down.** A
recogniser on our pill would never fire: `pointInside:` returns `NO` over the
artwork and titles so the touch reaches Music's masked mini player underneath
and Music expands the full player natively (1.1.41, confirmed working in
1.1.44). Taking the touch back would trade tap-to-open for swipe-to-skip.

So the pan is attached to **Music's own mini player**, the view the passthrough
already targets and already un-masks for hit-testing, with `cancelsTouchesInView
= NO`. Music's tap-to-expand is told to wait for that pan to fail, so a tap
still opens the player and a horizontal pan does not. Install once, remove on
teardown. A second pan lives on the dock itself for the sliver of pill that
does not overlap the mini player (~5pt expanded, ~19pt collapsed).

Option 2 (pan on the strip window) was not built: `hitTest:` returning nil
takes the overlay out of the recogniser walk, so that pan would never see the
passthrough touches. Option 3 (split regions) was not built.

**It is a carousel, not a crossfade.** Two content stacks translate together
inside a clip that stops at the play/pause button. Commit at 35% of the clip
width or a 480pt/s flick; otherwise snap back. Direction bias: horizontal must
beat vertical by 1.35×, or a 52pt-tall capsule claims every touch that moves.
Scroll-collapse still watches the collection view, not this pan.

**What we cannot know.** MediaRemote's now-playing dictionary is the current
track. The queue is behind `MPMusicPlayerController`, which crashes Music.
Previous-track artwork comes from a ring of tracks this process has already
seen (up to 8). Next-track incoming starts blank and fills if MediaRemote
answers during the settle animation. That is a measured limit, not a guess —
say so if the incoming side looks empty on a skip-forward.

**On-device checks that still have to happen (iPhone 12 mini / 17.3):**

- Tap on the pill still opens the full player in both dock modes.
- Swipe left / right skips and goes back, and the stacks slide rather than cut.
- A vertical drag on the pill does not collapse the dock and does not skip.
- Play/pause and the expanded skip button still win over the pan.
- Tearing the dock down (prefs off) removes the pan from Music's mini player.
- `status.log` should show `swipe_installed`, then `swipe_begin` / `swipe_commit`
  or `swipe_cancel`. A swipe with no `swipe_installed` means the mini player
  was not found.

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
| **1.1.29** | Hides via `layer.opacity` instead of `alpha`. ~~`hitTest:` refuses any view with `alpha < 0.01`, so `alpha` was hiding the very thing it needed to find.~~ **Wrong — see 1.1.43.** `UIView.alpha` is backed by `CALayer.opacity`; they are the same property, so this changed nothing. The view stayed un-hit-testable for fourteen more versions |
| **1.1.56** | **Swipe the mini pill to skip / go back.** A pan on Music's own mini player — the view the passthrough already delivers taps to — drives a two-stack carousel on both dock modes. Music's tap-to-expand waits for that pan to fail, so tap-to-open and swipe-to-skip can coexist. Previous incoming uses tracks this process has already seen; next incoming is blank until MediaRemote answers. Direction-biased so a 52pt capsule does not steal vertical scrolls. **Reasoned, not yet on device.** |
| **1.1.55** | **1.1.54 was wrong, and the log said so in one number.** | 1.1.54 asserted there were two download controls — one in the nav bar, one in the header — and scoped `M27FindDownloadControl` to `vc.view` to keep them apart. On device: **`download=nil` on all 192 samples**, while `nav_download` resolved every time. There is no download button inside the album page on 17.3. Scoping the lookup to the page did not separate two controls, it discarded the only one — which is exactly why the glass button "does nothing" and the red one sat at the top permanently. Two consequences follow. **The 1.1.53 "regression" was not one:** the label match did change what the lookup returned, but from *nothing yet* to *the real control*, and the drop in `download=nil` counts was the fix appearing, not a fault. **And the nav button is not a spare:** ours mirrors and fires it, so restoring it while our row is up just puts the duplicate back, and iOS 27 shows only "•••" there anyway — it is now restored on `viewWillDisappear` alone. **The tap works because it stopped pretending the view was a control.** `MusicCoreUI.SymbolButton` is not a `UIControl`, so `sendActionsForControlEvents:` reached nothing; the row keeps the `UIBarButtonItem` and sends its own `target`/`action`, both public properties. **The hide is retried, not one-shot** — at `viewWillAppear` the item usually has no view yet, which is why 1.1.54's single attempt left `nav_download_opacity=1` in 191 of 192 samples — and it re-hides when Music swaps the item through Download → Downloading → Downloaded, handing the previous view back first |
| **1.1.54** | **The flashing button was never the one being chased.** 1.1.53's `album_nav` named the nav bar's three right-hand items: `More` (SymbolButton 28×28, alpha 1.0), a `{0,1}` spacer, and **`Download` — a second `MusicCoreUI.SymbolButton`, also 28×28**. Two identical-looking controls on two different screens is exactly why every log until now was ambiguous. **The flash is a gate, not a delay.** `M27InstallAlbumControls` looks up play and shuffle first and returns early if either is missing — *before it ever reaches the download control* — and Music builds the header asynchronously, so for that whole window nothing has been hidden while the nav bar is painted from frame one. No amount of speeding the retry up can close a window that starts before the retry has anything to do, which is why 1.1.52 cut the header gap from 1.2s to 0.3s and the flash survived. The nav button is now hidden **before** the gate at `viewWillAppear`, and restored the moment the glass row installs — our row is a sibling of the header row and scrolls away with it, so leaving the nav button hidden would take away the only download control a scrolled page has. Also restored unconditionally on `viewWillDisappear`, prefs check or not. **And a self-inflicted regression, caught by the numbers:** 1.1.53's new accessibility-label match made the nav-bar loop in `M27FindDownloadControl` hit for the first time, so `download=nil` went from 52 occurrences in the 1.1.52 half of the log to **zero** in the 1.1.53 half. Nothing had got faster — the lookup had quietly started returning the nav control instead of the header's, so the header's own button stopped being what we hid and mirrored. That function is scoped to `vc.view` now and cannot wander into the nav bar; `album_controls` reports `nav_download` and its opacity separately so the two can never be confused again |
| **1.1.53** | **The header download control is fixed; the flash that is left is a different button.** 1.1.52 is confirmed by measurement, not impression — the gap between `download=nil` and the control being found and hidden went from **avg 1.2s / max 7s** across 8 album opens to **avg 0.3s / max 1s** across 9, at one-second log granularity. But the flash persists, which places it on the **navigation bar** button, and that lives outside `vc.view` where nothing in this file has ever looked. 1.1.52's `nav_right` could only say `UIBarButtonItem/-/noimg` three times: no accessibility label, no `image`, so the glyph is drawn by a view *inside* the item. This build looks one level in — `customView` or the item's own backing view, its class, frame, alpha, hidden flag, and its first three children — and **samples twice, at 0.05s and 1.5s**, because one sample cannot show a flash and two either side of the header build show whether an item goes away on its own and which one it was. **Also removes a matcher that was wrong by construction:** the nav-bar download search returned *any* right-hand item containing a `UIImageView` or `UIButton`, which on this page is the "•••" more-menu — it would have hidden it. All 74 `album_controls` samples in the 1.1.52 log resolve download via the header search instead, so it has never fired; unreached is not the same as correct, and this project has already spent three builds on that exact species of matcher |
| **1.1.52** | **"Success" was declared before the download control existed.** The 1.1.51 log gives the remaining flash a measurable cause — every album open reads the same way, one second apart: `18:44:00 album_controls download=nil download_hidden=nil` then `18:44:01 album_controls download=Symbol download_hidden=yes`. Play and shuffle are in the header the moment it builds; the download control arrives about a second later. `M27InstallAlbumControls` returned YES as soon as the row was placed, which told the 1.1.47 retry timer its job was done — so nothing was watching for the control that had not turned up yet, and Music's own red one sat uncovered underneath for that second. Success now means the download control was found too. The row is still placed on the same pass either way; only the answer to "is there anything left to wait for" changes, and an album with genuinely no download control simply costs the retry its ~2s cap. **The other red button** — the one that "flashes at the top and then comes down" — is in the navigation bar, which is not inside `vc.view`, so nothing in this file has ever seen it. `album_controls` now names the nav bar's right-hand items instead of hiding a control that has not been identified |
| **1.1.51** | **Two glyphs sized by two unrelated rules cannot match.** "The download one is much smaller than the shuffle button we created." It was: shuffle is an SF Symbol rendered at a chosen point size, while download is a photograph of Apple's control — an arrow drawn small inside a 28pt canvas with whatever margin Apple left around it. Nothing was ever going to make those agree. So neither picks its own size now. Every glyph in the row is trimmed to its **real alpha bounding box** and redrawn centred in one fixed 22pt box, aspect preserved. **Contrast is stretched too**, because plain desaturation left Apple's mid-grey arrow reading lighter than our solid-black shuffle: the opaque pixels' own min and max luminance are measured and remapped, so a single-colour glyph (the plain arrow, the finished tick) has no spread and lands flat at full `labelColor` matching shuffle exactly, while a progress ring does have spread and keeps its dark arc and pale track apart. The light end stops at 165 rather than white so a track stays visible against the glass. **The placeholder flash goes with it**: the `arrow.down` placeholder now runs through the identical path as the mirror, so the handover has nothing left to show — it was visible only because the two were sized differently |
| **1.1.50** | **Keep the mirror, drop the colour.** "Our black and white download logo appears for a second and then disappears, then it just does the original red one." Both halves are exactly what the code did: the button starts as our `arrow.down` in `labelColor`, and the first mirror tick replaces it with a photograph of Apple's red control. Drawing our own animated ring instead would mean inventing a state machine (idle / downloading / done) and a progress source, and every language-independent signal for those is a guess — the mirror already knows all of it correctly, in every language, including states Apple has not shipped. Only the colour is wrong. So the snapshot is converted to **luminance with alpha preserved**: the red ring becomes mid grey, the pale unfilled track stays pale, and the progress animation survives because the conversion runs on every frame the mirror takes. A template image would be simpler and wrong — templates use alpha only, so the ring's opaque grey track would flood to solid black and the progress would vanish at every percentage. **Skip glyph cropped:** the circle buttons set `cornerRadius = kM27CircleButton / 2` — half of *44* — but the mini pill lays them out at **34pt**, and Core Animation clamps a radius to half the shorter side, so `clipsToBounds` masked the button to a 34pt circle and `forward.fill`'s outer tip fell outside it. Clipping is off (the translucent background is painted by the layer and stays rounded regardless) and the symbol drops 20pt → 18pt. **Album page measured:** `album_tree` records class, frame in page coordinates, background alpha and image dimensions, 0.6s after the page appears so the asynchronous header has been built. Two open questions ride on it — which view holds the artwork (it is not in `DetailHeader.DetailsView`, the only part of this page identified so far), and whether an opaque background has been burying the colour wash at layer index 0 all along |
| **1.1.49** | **The edge light was a ruled line, and the download button was frozen by its own change check.** The highlight was a flat 1pt bar of white at alpha 0.55 running across the top of every pill — which is why it read as "a slight grey line, not a true refraction glass look". Light on a curved edge falls off as the surface turns away and dies out where the capsule curves, so it is now a view backed by a vertical gradient (0.50 white at the very top, gone by 3pt) masked by a horizontal one that tapers to nothing at each end. The corner inset drops from `radius * 0.7` to `radius * 0.35`, since the taper keeps the light off the corners by fading rather than by stopping dead. **Download button:** the mirroring worked — the user's own screenshot shows the red partial ring and stop square in the glass button — but `mirrorDownloadState` gated the re-render on the stock control's `accessibilityLabel` changing, and that label stays "Downloading" for the entire download while the ring fills. So one frame of the ring was captured and held. The snapshot is unconditional now (a 28×28 layer render, cheap enough to do several times a second) and the label is used only to decide whether the transition is worth a `status.log` line; the poll also moves from 1.0s to 0.25s |
| **1.1.48** | **The collapsed row's position was never a choice between the two extremes.** 1.1.46 put it at dock y 0 (screen 660–712): tappable, but floating far too high. 1.1.47 dropped it to y 60 (720–778): correct-looking, ~3pt of overlap, tap dead. Music's mini player is at 667–723 and the dock spans 660–778, so **y = 30** lands the row at 690–742 — 33pt of overlap, comfortably tappable, and visually between the two. Both requirements fit at once, which is why treating it as a trade kept producing a build that failed one of them. The collapsed special case in `nowPlayingTapped` goes away with it, since the passthrough now reaches in both modes. **"It gets fat when it collapses":** it did — the capsules were laid out at the 58pt tab-row height, so collapsing swapped a 52pt pill for a 58pt one. They use the mini pill's height now. The collapsed affordance also changes from a music-note list on a solid red tile to a red-tinted **house** glyph sitting in the glass with no tile, matching the reference |
| **1.1.47** | **Position wins, and the album flash gets its real cause.** 1.1.46's y = 0 read as floating far too high on device; the row belongs in the space the categories occupied. At the tab slot it overlaps the mini player by ~3pt, so a collapsed tap cannot be handed to Music — collapsed taps go back to expanding the dock, and the trade is stated rather than buried. (1.1.48 dissolves it.) **Album flash:** "the old red shuffle/play/download buttons still show for a second or two." Neither `viewWillAppear` nor the first `viewDidLayoutSubviews` could fix that, and `status.log` said why — both reported `album_lookup_failed play=nil shuffle=nil`. Music builds the detail header **asynchronously**, so at both moments there is nothing to hide, and layout does not run again until something changes; that gap *is* the second or two of stock buttons. The install now reports whether it actually placed the row, and a 50ms timer retries until it does, capped at ~2s, stopping on success or when the page leaves the window, scheduled in common run-loop modes so a scroll in progress cannot stall it |
| **1.1.46** | **Three collapsed capsules, and a collapsed tap that reaches.** iOS 27's collapsed dock is three separate capsules — tab affordance, now-playing pill, Search — not one merged pill. Splitting it also explained the dead collapsed tap, which was never hit-testing but geometry: `dock_screen={{0,714},{375,64}}` against `mini_screen={{12,667},{351,56}}`. The strip is pinned to the bottom, so a shorter collapsed dock sits *lower* — 15pt of overlap against 47pt when expanded, which is exactly why one mode worked and the other did not. `preferredHeight` returns the expanded height in both modes now and the collapsed capsules lay out inside it, so the pill keeps its position and the empty space below simply passes touches through. The artwork and titles lose their tap gestures — over the mini player, a gesture here swallows the touch Music needs. **Full player:** the second guess was wrong the same way the first was. 1.1.45's ivar enumeration returned `count=1`, and that one was `_view` — this controller holds none of its controls as properties, so the offline catalog's names were never going to appear under any spelling. The probe walks the view tree instead (class and frame, breadth-first, 60 rows, depth 4, no ivar reads) |
| **1.1.45** | **The glass wasn't glass.** Three things were stacking opacity: `SystemChromeMaterial`, a white tint on the content view, and a "highlight" covering the **top 45% of every pill at alpha 0.28**. The result was flat grey with no artwork visible behind it, which is the opposite of the reference — in Apple's iOS 26/27 shots the album art reads clearly *through* the pill. Now `SystemUltraThinMaterial` (the most transparent UIKit offers), the tint pulled back to 0.04/0.06 white, the palette tint from 0.22 to 0.10, and the highlight reduced to a **1pt hairline along the top edge**, inset to follow the capsule. Liquid Glass is light catching an edge, not a wash over half the shape. **Also:** the dock hid on the player's `viewDidAppear` — a whole presentation animation too late, so the pills stayed visible over the player during the slide-up. Moved to `viewWillAppear`, which runs before the animation starts. Crash on 17.3 confirmed fixed |
| **1.1.44** | **Confirmed on device: the mask fixed it.** `mini_alpha=1 mini_opacity=1` where every prior build read 0, `inside=yes`, and the full player opens on a tap. Three follow-ups. **(1) Crash on 17.3** when tapping the collapsed pill's artwork — the last breadcrumb before the process died was a layout line, never `nowplaying_begin`, so it died during touch delivery rather than in the handler. The gesture-firing code is deleted: it read `UIGestureRecognizer`'s private `_targets`, pulled `_target`/`_action` out by raw ivar offset and `performSelector`'d the result, which is undefined behaviour the moment a firmware lays those ivars out differently. It also never once opened the player — on 16.7 it called Music's real handler and nothing happened (`gr.state` is `.possible` and read-only), on 17.3 it resolved nothing. Zero value, non-zero crash risk. **(2) Collapsed pill was a dead tap** — measured at `dock_screen={{0,714},{375,64}}` against `mini_screen={{12,667},{351,56}}`, it sits *below* Music's mini player, so the passthrough correctly finds nothing underneath. It expands the dock now, which puts the pill back over the mini player where a second tap does open the player. **(3) The dock floated over the full player** — it lives in its own window at `Normal + 2`, so unlike Music's own mini player and tab bar it does not vanish with the presentation. It hides on the player's `viewDidAppear` and returns on `viewWillDisappear`, with a flag so the constant relayout cannot pop it back a frame later |
| **1.1.43** | **`layer.opacity` IS `alpha` — the 1.1.29 "fix" never did anything.** 1.1.42's passthrough worked exactly as designed: three taps, `inside=yes`, dock declined the touch. And no `nowplaying_controls` followed for over two minutes. The field added in 1.1.40 for this exact question said why: `mini_alpha=0 mini_opacity=0` — when only `layer.opacity` was ever assigned. `UIView.alpha` is backed by `CALayer.opacity`; they are one property, so every build since 1.1.29 that "avoided alpha" was setting alpha. `hitTest:` refuses anything under alpha 0.01, so Music's mini player has been unreachable the whole time and there was nothing to hand the declined touch to. Worse, the mini player lives *inside* `PaletteContainerView`, which was faded the same way — so even at alpha 1 the container would have blocked it. Both are hidden with an **empty `CALayer` mask** now: no opaque pixels means nothing renders, while `alpha` stays 1 and hit-testing still descends. The mini player also gets `userInteractionEnabled = YES` back, since declining a touch only helps if something underneath will take it. **Also:** the dock no longer snaps shut on every flick — collapsing needs both 0.45s of sustained scrolling and 90pt of travel, since a timer alone lets a slow nudge through and a distance alone lets a flick through |
| **1.1.42** | **The passthrough was right in principle and wrong in arithmetic.** First 16.7 data (iPhone X) gave `mini_window={{0, 665}, {375, 64}}` against `tap_window={51, 30.7}` → `inside=no`. `convertRect:toView:nil` stops at the *receiver's own* window, and the dock deliberately lives in a separate overlay `UIWindow` — so 1.1.41 compared a strip-relative y of 30 against Music's screen-absolute 665. No tap could ever have matched. Both are converted through `convertRect:toWindow:nil` now, and in one space they genuinely overlap: with a track playing the pill occupies roughly screen 660–712 and Music's mini player 665–729, so 47 of the pill's 52 points pass through. The single 1.1.41 log line also happened to be written while the dock was in its no-track layout, which made the numbers look worse than they were — it logs up to four decisions now, with the dock's own screen frame alongside. Also 16.7 named the mechanism: `MusicApplication.PalettePresentationInteraction.tapGestureRecognized:` fires and does nothing, which is the `gr.state` caveat flagged when that path was written — so "fired a target" no longer counts as success and no longer hides the recon behind it |
| **1.1.41** | **Stop pressing buttons; get out of the way.** Four builds tried to open the full player by synthesising an action, and the mini player has no button that expands it — `playPauseButton`, `skipButton`, `reverseButton`, `shuffleButton`, `repeatButton`, `handoffButton`, none of them. The answer was in a user report: the player "popped up by accident" once. Music's **real** mini player is still under the glass pill, hidden with `layer.opacity = 0` — invisible but perfectly hit-testable — so a tap that lands just outside the pill reaches it and Music expands natively. So the pill now *declines* touches on its artwork and titles, and Music handles them with its own animation and lyrics screen. Passthrough is geometric, not blanket: only where the stock mini player actually is, checked in window coordinates. Play/pause and skip stay ours, with a 6pt generous hit area, and the tab row never passes through — a tap there would otherwise reach Music's real tab bar and switch tabs twice |
| **1.1.40** | **The flash had a cause, and it was my "fix" for it.** 1.1.38 moved the install to `viewWillAppear` to beat the flash; `status.log` replied `album_lookup_failed play=nil shuffle=nil` — at `viewWillAppear` those buttons don't exist yet. So the first real install still landed on `viewDidAppear`, after the page is on screen, because the `viewDidLayoutSubviews` path refused to install unless a row was *already* there. Layout is the first moment the stock row exists and it runs before the frame is presented, so first-install moves there. **Mini pill:** the recon dump did its job — there really is a `UITapGestureRecognizer` near the mini player, `hitTest` returns `nil`, and `parent_sels`/`tbc_sels` are empty. Firing the recogniser's targets silently did nothing, so this build reports the target count, the resolved target/action names, and any exception, plus the mini player's bounds/alpha/opacity/hidden to explain the nil hit-test. **Full player:** the catalog was wrong for this device — the class is `MusicNowPlayingControlsViewController` (plain ObjC) and all 21 catalog ivars came back `missing`. It now enumerates the real view-typed ivars with their frames instead |
| **1.1.39** | **Stop firing buttons at the mini player.** Two builds, two different wrong buttons: 1.1.37 fired `NowPlayingShuffleButton` at `{{-28,14}}`, and 1.1.38 — having correctly rejected the off-screen one — simply found the next candidate, `NowPlayingTransportButton` at `{{0,17.7},{21,21}}`, and played/paused instead. That is the tell. The mini player has **no** control that expands it, so "find a control and fire it" cannot ever be right; each refinement just picks a different wrong button. Doing nothing beats performing an action nobody asked for. It also cost a round of evidence: the recon dump sat behind "no control found", and a control was always found, so the gesture inventory never got written — **diagnostics must not depend on the success of the thing they diagnose.** It now always runs. **Download glyph:** 1.1.38 logged `album_download_glyph` zero times because `MusicCoreUI.SymbolButton` is not a `UIButton` and holds no `UIImageView` — it draws its own symbol, so there was no image to borrow. It's rendered via `renderInContext:` instead (lifting `layer.opacity` for the draw), which captures the red progress ring mid-download in any language |
| **1.1.38** | **The pill tap was firing the wrong control — and my read of 1.1.37's silence was wrong twice over.** With the branch instrumented, the log said `nowplaying_sent_action control=MusicApplication.NowPlayingShuffleButton frame={{-28, 14}, {28, 28}}` 48 times. `shuffleButton` is a genuine ivar of `MiniPlayerViewController`, parked off-screen because the compact layout doesn't show it, and "first `UIControl` in the subtree" happily returned it. So every tap silently toggled shuffle. Controls that are off-screen, hidden, transparent or tiny are now rejected outright, and since *none* of the mini player's buttons expand it — expanding is a gesture — the tap fires the recogniser's targets instead. **Also reverted 1.1.37's pill hiding:** iOS 27 shows the last song paused on a fresh launch, so the last real track is now persisted and restored. **Download button** mirrors Music's own glyph, so the stop control during a download comes along for free instead of being reimplemented. **Stock buttons stop flashing** — the install moved from `viewDidAppear` + `dispatch_async` (several frames after the page is visible) to `viewWillAppear` |
| **1.1.37** | **No more placeholder pill.** `status.log` named the "weird loading thing" outright: `src=scrape texts=1 title=Not Playing` and `title=Loading…` — Music's *own* placeholder strings, scraped out of the stock mini player and rendered in the glass pill as though they were a song. Every real track in that log arrived via MediaRemote with a title; every placeholder was a scrape with a single label and no artist, so the scrape fallback now requires both lines. Matching the strings themselves would only work in English, and a title-shaped guess is what put "iPhone" in the pill in the first place. With no track the pill is dropped entirely and the dock becomes just the tab row, as on iOS 27 — and a scroll can no longer collapse it into an empty pill |
| **1.1.36** | **Full-screen player, first pass** — behind *Restyle Full-Screen Player*, off by default. SwiftPeek's offline catalog says `MusicApplication.NowPlayingControlsViewController` is plain **UIKit**, not SwiftUI: `artworkView`, `titleLabel`, `subtitleButton`, `favoriteButton`, `contextButton`, `timeControl`, `transportControlsStackView`, `playPauseStopButton`, `volumeSlider`, `lyricsButton`, `routeButton`, `queueButton` are all real named views, which is why this screen is tractable where the album header was not. This build rounds the artwork and — the actual point — writes `nowplaying_controls` naming every ivar it found with its real frame, so the layout work runs on measurements instead of screenshots. Ivars are read one name at a time and only when the runtime says the type is an object; a struct read is how SwiftPeek earned its SIGSEGVs |
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

**The apt index lags the builds.** `dist/` and `Packages` are only updated when
someone runs `scripts/publish-to-lumina.sh` and commits the result, which has not
happened for the 1.1.2x–1.1.5x series — the index currently advertises a much
older version. Until a build is published, the `.deb` for a given version comes
from its **CI run artifact** (`Music27-rootless-deb`) on the *Build Music27*
workflow, not from Sileo.

Manual / Filza: install `packages/com.music27.tweak_*.deb`, respring, force-quit and relaunch **Music**. Toggle features under **Settings → Music27**.

## Packaging schemes

| Scheme | Architecture | Status |
|--------|--------------|--------|
| **rootless** (Dopamine) | `iphoneos-arm64`, files under `/var/jb` | **Supported.** Every version is verified on an iPhone 12 mini / iOS 17.3 before it is called done |
| **roothide** | `iphoneos-arm64` | **Built, not verified.** Produced by CI whenever the toolchain cooperates, but the maintainer no longer runs a roothide jailbreak and cannot test it |

The roothide CI job is `continue-on-error: true` deliberately — for the support
reason above, and **not** as flake insurance.

That distinction matters, because the first version of this note got it wrong.
It said the TLS failure was specific to the roothide Theos fork. It is not: on
1.1.53 the identical error hit the *rootless* job (`theos/theos` rather than
`theos/sdks`). It comes from `waruhachi/theos-action`'s `cache-key` step
reaching `api.github.com`, one second into the run, before anything is compiled,
and it can land on either job — four times in one afternoon.

**If a build goes red, check which step failed before believing it.** A failure
inside `Setup Theos` is this flake; re-running the failed job has cleared it
every time. A failure inside `Build Music27` is real.

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
