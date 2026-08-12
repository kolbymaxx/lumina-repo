# Using SwiftPeek on your own app

You are writing a tweak for an app you did not write, on an OS whose UI is
increasingly SwiftUI, and the usual first move — dump the class tree, find the
view, hook it — keeps returning nothing useful. This is the tool for the step
before the hook: **what is actually on this screen, and what is drawing it.**

It is read-only. It installs no hooks unless you ask, mutates nothing ever, and
every collection mode is off until you turn it on.

## 1. Point it at your app

Settings → SwiftPeek:

1. **Enable SwiftPeek** — on.
2. Under **Your own targets**: **Enable custom targets** on, then put your app's
   bundle identifier (or its process name) in the **Targets** field. Several are
   fine, comma- or newline-separated, up to 16.
3. Under **Collection**: **Scan Windows** on. Leave *Dump Field Meta* and
   *Install Hooks* off — see [Hazards](#hazards).
4. Force-quit the app and reopen it.

Apps only. A process whose main bundle is not a `.app` is refused by the custom
path no matter what you type, and the seven built-in targets (Music, Podcasts,
TV, Settings, SiriViewService, assistantd, SpringBoard) keep their own switches
— naming one of those here does nothing.

## 2. Read what came out

Dumps land in:

```
$jbroot/var/mobile/Library/SwiftPeek/dumps/<Process>_<timestamp>.json
```

with a rolling `status.json` beside them. Pull them off with Filza, SSH, or the
Files app.

The first one written at launch is the **probe**, and it is the one to check
when nothing else appears:

```json
"target_rule": "custom:com.example.app",
"bundle_id":  "com.example.app",
"message":    "MyApp launch probe (0.6.0) rule=custom:com.example.app scanWindows=1 …"
```

`target_rule` is why SwiftPeek did or did not run here:

| Value | Meaning |
|-------|---------|
| `builtin:Music:on` | matched the built-in table, switch on |
| `builtin:Podcasts:off` | matched the table, **switch off** — turn it on |
| `custom:com.example.app` | matched your list |
| `nomatch:custom-off` | not in the table and *Enable custom targets* is off |
| `nomatch` | custom targets on, but nothing in your list matched |
| `denied:not-an-app` | matched your list, but the process is not an `.app` |
| `denied:killswitch` | the DISABLE file exists (see below) |

No probe at all means the dylib never loaded — check the app actually links
UIKit, and that SwiftPeek is installed for your jailbreak's rootless/roothide
scheme.

## 3. Find the surface you care about

The host-side reader turns a dump into something you can skim:

```bash
cd /path/to/lumina-repo
PYTHONPATH=tools python3 -m swiftpeek windows path/to/MyApp_….json --views
```

Each row is a window, then its view subtree, then flags:

```
level=0.0  {{0,0,390,844}}  UIWindow  root=MyRootViewController  KEY
    UIView                  {{0,0,390,844}}  OPAQUE bg=rgba(0,0,0,1.00)
      _TtGC7SwiftUI…HostingContentView  {{0,88,390,300}}  SwiftUI
      UICollectionView      {{0,0,390,600}}  bg=rgba(1,1,1,1.00) <-- STOPPED, 4 more below
```

What the flags are for, and what each one has already caught:

- **`layerbg=` / `gradient=[…]`** — a view with no `backgroundColor` can still be
  the thing painting the screen. Music's artwork-derived player background is a
  `CAGradientLayer`, invisible to a view-only walk.
- **`bg=` alpha** — an opaque view above yours is why your overlay "doesn't
  render". One dump found a `UICollectionView` at `bg 1.00` sitting over a colour
  wash inserted at layer index 0 with `zPosition -1000`. That answered a question
  that had been open for eleven builds.
- **`<-- STOPPED, N more below`** — the walk hit the depth cap here. A leaf and a
  truncation used to look identical.
- **`SwiftUI`** — SwiftUI drew this itself, as opposed to a UIKit host wrapping
  one. This is the "is this surface worth attacking" flag, and the honest answer
  is often no: see below.
- **`<-- INVISIBLE`**, **`HIDDEN`**, **`alpha=`** — a view that exists, is in the
  right place, and shows nothing.

## 4. Go deeper on one screen

Two limits matter. Under **Deep Dive**:

- **Depth** and **Max nodes** — the walk's budget. 3/48 by default; 8/200 when
  chasing something specific.
- **Focus** — restarts the depth budget at any view whose *class name* contains
  the text. It matches **view** classes, not controllers, so a name ending in
  `ViewController` will never match.
- **Repeat scan** — the important one. The two automatic scans fire 5s and 12s
  after launch, which cannot catch a screen you navigate to afterwards. Three
  attempts at capturing Music's full-screen player produced three dumps of
  whatever was up at 12 seconds. Set a repeat interval, open the screen, wait one
  interval. It stops after 40 scans so it cannot fill the device.

## 5. What SwiftPeek will not tell you

Worth knowing before you spend a build on it.

**SwiftUI has no stable identity.** No named subviews, no persistent object to
hold, and a tree rebuilt whenever state changes. SwiftPeek can tell you a
surface is SwiftUI-drawn and where it currently sits; it cannot give you a
handle that survives the next rebuild. Consumers hand-roll re-resolution today
(see [`DEPENDENCY_CAPABILITIES.md`](DEPENDENCY_CAPABILITIES.md) §1).

**A SwiftUI view's parts are not inside its parent's layer subtree.**
`MusicCoreUI.SymbolButton` turned out to be *only* the grey capsule background —
SwiftUI drew the glyph and the label as siblings, outside it. Hiding the button
could never hide the glyph, and three builds went past before a readback forced
the issue. If a frame looks right but hiding it does nothing, look at the
siblings.

**Field names come from a catalog, and a catalog answers for one firmware.**
`FieldCatalog.lookup()` returns a `provenance` string with every hit for exactly
this reason; the bundled one is iOS 16.7.10. On a firmware it does not cover,
take a fresh dump. If a dump and the catalog disagree, the dump wins. That cost
two Music27 builds — [`OFFLINE_MUSIC_FIELDS.md`](OFFLINE_MUSIC_FIELDS.md).

## Hazards

Two switches can crash the app you are inspecting, and they are labelled
*(unsafe)* in Settings because they earned it:

- **Dump Field Meta** walks Swift field metadata against live objects. SIGSEGV on
  Music at 0.3.0 and again at 0.3.5. The rule that came out of it: an ivar is
  only safe to read as an object when `ivar_getTypeEncoding` says `@`. Swift
  structs and enums read as `id` are how both crashes happened. There is a
  per-app allowlist behind this and it does **not** transfer to your app.
- **Install Hooks** is the only mode that modifies the process at all.

Everything else — the window tree, the view subtree, `screen_strings` — is
property reads.

## Kill switch

Before prefs, before the target check, before anything:

```
$jbroot/var/mobile/Library/SwiftPeek/DISABLE
```

If that file exists, SwiftPeek refuses to attach to any process. It is the
recovery path for a target you cannot force-quit: `touch` it over SSH and
respring. Create it *before* enabling a system process, not after.

## Host-side tools

Everything in `tools/swiftpeek` reads dumps offline — no device needed:

```bash
PYTHONPATH=tools python3 -m swiftpeek summary  dump.json            # header + counts
PYTHONPATH=tools python3 -m swiftpeek windows  dump.json --views
PYTHONPATH=tools python3 -m swiftpeek find     dump.json shuffle
PYTHONPATH=tools python3 -m swiftpeek targets  dump.json            # ranked hook candidates
PYTHONPATH=tools python3 -m swiftpeek scaffold dump.json -o MyTweak --name MyTweak
```

Full reference: [`READ_API.md`](READ_API.md). End-to-end walkthrough:
[`TWEAK_WORKFLOW.md`](TWEAK_WORKFLOW.md).
