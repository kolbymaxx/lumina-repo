# Offline Music field recovery (post-0.3.6)

## Why offline

Live FOVO walks on Music crashed the process:

| Target | Result |
|--------|--------|
| Music `UIViewController`s (0.3.0) | crash |
| Allowlisted Music `UIView`s (0.3.5) | crash |
| `_UIHostingView` in-window (0.3.4) | **none found** (`hosts=0`) |

Device `view_class_sample` showed custom `MusicApplication.*` UIViews only.
Field **names/layouts** are still recoverable from the Mach-O without touching
the live heap.

## Binary

iOS **16.7.10** (`20H350`) IPSW for iPhone10,3 / iPhone10,6 (same Music build
family as the prove device on 16.7.14):

```
Music.app/Frameworks/MusicApplication.framework/MusicApplication
```

The top-level `Music.app/Music` executable is a ~93 KB stub — do **not** run
`swiftmd` on that. Real metadata is in `MusicApplication`.

Companion DSC frameworks (same IPSW dyld cache) also carry related Now Playing
SwiftUI structs (`MediaCoreUI`, `MusicUI`) — useful for 17.x / MediaCore paths,
but the X’s in-app UI classes live in `MusicApplication`.

**Music27 dock prove (2026):** prefer a **fresh SwiftPeek dump on iOS 17
Dopamine** before treating the 16.7.10 catalog as authoritative for floating
mini / tab chrome. Stock Music on 17 already floats the mini-player; MediaCoreUI
`MiniPlayer*` companions are more relevant there. Keep using
`MusicApplication.MiniPlayerViewController` / `tabsViewController` names when
the live dump still shows them — do not invent offsets from 16.7 alone.

## `swiftmd` result (MusicApplication)

```
__swift5_types   2088 descriptors
__swift5_fieldmd 1834 with field records
unresolved slots 0
verdict: field names ARE recoverable — proceed to the runtime step
```

No `HostingView` types in this binary (matches device `hosts=0`).

## Device-sampled types → offline fields

From 0.3.4 `view_class_sample` / allowlist:

| Live class (device) | Offline fields (excerpt) |
|---------------------|---------------------------|
| `NowPlayingContentView` | `mode`, `videoContext`, `artworkComponent`, `playerPath`, `deferArtworkUpdates` |
| `PaletteContainerView` | `contentInsets`, `backgroundView`, `containerView`, `gradientLayer`, … |
| `UberNavigationTitleView` | `navigationController`, `_backButtonStyle`, `customBackButton` |
| `NowPlayingTransportControlStackView` | `useBoundsAsPointInside` |
| `NowPlayingVibrancyEffectView` | `vibrancyState`, `contentItemView`, `vibrancyStyle` |
| `MiniPlayerViewController` (scan) | rich: artwork/title labels, transport, shuffle/repeat, bindings… |

Dumps checked into [`offline/`](offline/).

## Reproduce

```bash
# 1) Extract MusicApplication from IPSW (remote OK)
URL=$(ipsw download ipsw --device iPhone10,6 --version 16.7.10 --urls --confirm --no-color \
      | rg -o 'https://[^ ]+\.ipsw' | head -1)
ipsw extract --remote "$URL" --files --pattern 'MusicApplication\.framework/MusicApplication$' \
  -o /tmp/sp-music-ma

MA=$(find /tmp/sp-music-ma -name MusicApplication -type f | head -1)

# 2) Dump
cc -O2 -o tools/swiftmd tools/swiftmd.c
./tools/swiftmd "$MA"                       # summary on stderr
./tools/swiftmd "$MA" --filter NowPlayingContentView
./tools/swiftmd "$MA" --filter PaletteContainerView
```

DSC companions (optional):

```bash
DSC=/tmp/swiftpeek-dsc/16.7.10/*/dyld_shared_cache_arm64
ipsw dyld extract "$DSC" \
  /System/Library/PrivateFrameworks/MediaCoreUI.framework/MediaCoreUI \
  -o /tmp/sp-music-dylibs --force
./tools/swiftmd /tmp/sp-music-dylibs/MediaCoreUI --filter NowPlaying
```

## Implications for SwiftPeek

1. **Keep live Field Meta off** on Music — FOVO against live objects is unsafe.
2. **Proven live path stays** Enable + Scan + Dump Fields (`screen_strings` + types).
3. **Substrate field layouts** for 16.7 Music should come from **offline `swiftmd`**
   tables (this doc), keyed by the live `type` / `objc_class` strings already in dumps.
4. A future runtime step needs pointer-validated reads (or a different host process
   that actually embeds `_UIHostingView`) — not another unguarded FOVO pass.

## Annotate a live dump (join)

Copy a Filza dump off-device (AirDrop / Files), then on a Mac with the repo:

```bash
cd ~/lumina-repo
git pull origin cursor/swiftpeek-m2-screen-99e4
python3 tools/annotate-dump.py ~/Downloads/Music_….json -o ~/Downloads/annotated.json
```

Uses [`offline/field-catalog.json`](offline/field-catalog.json) — full
`MusicApplication` pass (**~1955** types, **~1728** with fields), built from
[`offline/MusicApplication-full.txt`](offline/MusicApplication-full.txt).

Each matched node gains `offline_fields` / `offline_type` without live FOVO.
