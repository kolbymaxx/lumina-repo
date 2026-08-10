# Halo

A Dynamic Island for notch devices. Targets iOS 16.7.x (iPhone X / Dopamine)
and 17.x (12 mini / Relaxin').

**Status:** 0.1.0 — untested on device. Not published to the APT repo.

## What Halo is (and is not)

The Dynamic Island is a 14 Pro-and-later feature. An iPhone X or a 12 mini has
a **physical notch** cut out of the display: those pixels do not exist, and no
tweak can light them up or change the cutout's shape. Halo does not pretend
otherwise.

What it does is recreate the *presentation*: a glass capsule that hugs the
notch, flanking it with content on both sides, and expands into a panel below
it — driven by the same system events the real Island surfaces. On a device
that already has a Dynamic Island, Halo detects it and stays inert rather than
fighting the real thing.

## Design

**Halo installs no hooks.** There are no `%hook` blocks anywhere in the tweak.
It does not need to change SpringBoard's behaviour, only to add a window of its
own and listen for notifications — so there is no method to patch and no
patched method to get wrong. The only moving part is its own window, created
behind a device check and a preference that defaults to off.

Everything is event-driven. A source posts an activity, the presenter animates
once, and nothing runs until the next event. There is no polling loop, no
display link, and no per-second timer — even the media progress bar is sampled
from the change notification rather than ticked, because a progress bar is not
worth a wakeup every second.

| File | Role |
|------|------|
| `src/Tweak.x` | Constructor, kill switch, post-launch start |
| `src/HAGeometry.m` | Notch metrics table + Dynamic Island detection |
| `src/HAPresenter.m` | Passthrough window, activity queue, gestures |
| `src/HACapsuleView.m` | The capsule: compact and expanded layouts |
| `src/HAMediaRemote.m` | dlopen bridge to MediaRemote for now playing |
| `src/HASources.m` | Battery, ringer, Low Power, screen capture, lock |
| `src/HAPrefs.m` | jbroot resolution, prefs, kill switch |

### Notch metrics

There is no API that reports the notch's **width** — `safeAreaInsets.top` gives
its height and nothing else. Width comes from a table keyed on the screen's
point size (375×812, 390×844, 360×780, 414×896, 428×926). An unrecognised
device with a tall top inset gets a conservative default rather than a guess
presented as a measurement.

### Passthrough window

`HAWindow -hitTest:withEvent:` returns nil for every point outside the capsule.
Getting that wrong would swallow status bar taps and Notification Centre pulls
across the entire top of the screen, so it is the first thing to check if
anything at the top of the display stops responding.

## Sources

| Source | Signal | Priority |
|--------|--------|----------|
| Now Playing | MediaRemote change notifications | Ambient |
| Ringer switch | `com.apple.springboard.ringerstate` | Normal |
| Low Power Mode | `NSProcessInfoPowerStateDidChangeNotification` | Normal |
| Charging | `UIDeviceBatteryStateDidChangeNotification` | Important |
| Screen recording | `UIScreenCapturedDidChangeNotification` | Critical |

Highest priority wins; ties go to whichever was posted most recently. Only
sources with a real, stable signal are included — Halo would rather ship five
that work than ten that guess.

MediaRemote is resolved by `dlopen` + `dlsym`, never linked. If a symbol Halo
needs is missing on a given firmware, the media source never arms and the rest
of the tweak carries on.

## Prefs

Domain: `com.kolby.halo`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Master switch |
| `sourceMedia` | `true` | Now Playing capsule |
| `mediaShowWhenPaused` | `false` | Keep the capsule up while paused |
| `sourceCharging` | `true` | Charging / fully charged |
| `sourceRinger` | `true` | Ringer switch flips |
| `sourceLowPower` | `true` | Low Power Mode |
| `sourceScreenCapture` | `true` | Screen recording indicator |
| `tapToExpand` | `true` | Tap the capsule to expand it |
| `tapToOpen` | `true` | Tap the expanded capsule to open the app |
| `chargingDuration` | `3.0` | Seconds the charging capsule stays up |
| `logEvents` | `true` | NSLog event lines |
| `windowLevel` | `1051` | Window level, if something else fights for the top |

## Safety

- Prefs default **off**. When off, the constructor registers one Darwin
  observer and returns.
- **No hooks at all** — nothing is swizzled and no `%init` ever runs.
- **Kill switch:** `touch /var/mobile/Library/Preferences/com.kolby.halo.killswitch`
  and respring. Checked (jbroot-aware) before anything else happens.
- **Zero boot-path work.** The window is built 2 s after
  `UIApplicationDidFinishLaunching`, outside the watchdog window.
- **Fail closed.** Every source callback and every presenter entry point is
  wrapped; a failure leaves the capsule hidden rather than taking SpringBoard
  with it.

## Build

```bash
cd Halo
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # iPhone X / Dopamine
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # 12 mini / Relaxin'
```

## Not implemented (deliberately)

Live Activities, call state and timers are **not** wired up. Each would need a
private interface whose shape is not confirmed on both 16.7 and 17.x, and
guessing at one is how a SpringBoard tweak earns a Safe Mode. They are
candidates once a SwiftPeek dump confirms the surface, same rule as Glyph
Phase C.
