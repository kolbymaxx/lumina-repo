# Lumina Repo

<p align="center">
  <img src="repo-site/logo.png" width="128" height="128" alt="Lumina Repo logo">
</p>

<p align="center">
  Custom jailbreak tweaks by <strong>ma6x9x</strong>, built with AI.<br>
  Dopamine (rootless) + RootHide.
</p>

## Add in Sileo

**Sources → + → Add** (this is also the landing page):

```
https://ma6x9x.github.io/lumina-repo/
```

Same URL works in Zebra. Origin / label: **Lumina Repo**.

Sileo installs the right build for your jailbreak (`iphoneos-arm64` on Dopamine, `iphoneos-arm64e` on RootHide). If you still have an old KDotz source, remove it, add this one, then refresh.

## Tweaks

| | |
|---|---|
| **Siri27** | iOS 27-style liquid glass Siri orb — voice-reactive rainbow wave. Replaces FloatingSiri. |
| **Music27** | Apple Music Liquid Glass UI for iOS 16/17 — floating glass dock, artwork color themes, library pins. |
| **CC27** | iOS 26-style Control Center for iOS 15–17 — edit mode, add-control gallery, glass modules. Needs CCSupport. |
| **RHCompat** | RootHide-only Settings / PreferenceLoader companion. Use **1.0.2+** (1.0.1 could black-screen). |

### In development (not on the repo yet)

| | |
|---|---|
| **Glyph** | SnowBoard successor. Reads existing SnowBoard theme packs unchanged, then recolours every icon — iOS 18-style tinted and dark icons in any colour you pick, or iOS 26-style clear glass that lets the real wallpaper show through. Composited once and cached, never per frame. |
| **Halo** | A Dynamic Island for notch devices. A glass capsule hugs the notch and expands below it for now playing, charging, ringer, Low Power Mode and screen recording. Installs no hooks at all. |
| **Lattice** | Home Screen grid freedom — any rows × columns, independent dock width, optional hidden labels. iOS has never allowed a custom grid, and free placement only arrived in iOS 18. |

These build in CI but are **untested on device** and are not published to the
APT repo. Each defaults to off and ships a kill-switch file.

## Credits

- LiquidSiri by Thijs Mussig
- Liquid (Gl)ass (`liquidass`) by winaviation-tweaks
