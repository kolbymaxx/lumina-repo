# SwiftPeek as a tweak dependency

Goal: SwiftPeek becomes the support library modern jailbreak tweaks build on —
the thing that makes SwiftUI-era apps tweakable the way MobileSubstrate made
UIKit-era apps hookable. First customer is this monorepo (Music27, CC27,
Siri27); third-party developers after that.

Substrate is **not** being replaced. Substrate gets you into the process.
SwiftPeek helps you find, host and safely augment UI once you are there.

## Packaging: three shapes, pick deliberately

| Shape | Runtime dependency? | Blast radius of a bad update |
|-------|--------------------|------------------------------|
| **1. Shared source** in this monorepo | none | none |
| **2. Static library** (`.a`) linked into each tweak | none | none until each tweak rebuilds |
| **3. Shared dylib** + `Depends:` (the MobileSubstrate model) | yes, enforced by the package manager | every dependent tweak, at once |

**Start at 1, plan for 2, move to 3 only when something forces it.** The API is
identical in all three; packaging is an afternoon's work to change, while a bad
API that others already depend on is permanent.

What forces shape 3:
- **Third-party consumers.** They need fixes without you rebuilding their code.
- **Cross-tweak coordination.** Two tweaks both wanting a SpringBoard overlay
  must arbitrate; shared state needs a shared runtime.
- **One kill switch for everything.** Today `DISABLE` only stops SwiftPeek. In
  shape 3 a single file could safe-mode every dependent tweak — the strongest
  argument of the three, given how cheap it is to brick SpringBoard.

## API surface

Every item below is something we either built or duplicated by hand while
getting Music27 working. Nothing here is speculative.

Shipped pieces live in [`SPKit/`](../../SPKit) as shape 1. The prefix is `SPK`,
not `SP`, because SwiftPeek's own tweak already exports `SPPrefBool(key,
fallback)` with a different signature and both dylibs load into the same process.

### Runtime hygiene — pure dedup, zero risk — **shipped**

`SPKJailbreakRoot()` · `SPKRootedPath()` · `SPKPrefBool(domain, key, default)` ·
`SPKPrefs(domain)` · `SPKKillSwitchEngaged(subdir)` · `SPKTrace(stage, dict)`

Justification: **six near-identical copies** of the jbroot resolver exist today
across Music27, SwiftPeek and CC27 — four inside CC27 alone. Fix a bug in it and
you fix it six times, or forget five.

### Tracing — the highest-value piece — **shipped**

`SPKTrace` is **synchronous and `fsync`'d**, with `_begin`/`_result` pairs.

This is not a style preference. Music27 1.1.23 logged asynchronously; when Music
crashed during install the queue never drained and the log showed nothing at all,
making a crash indistinguishable from a code path that never ran. 1.1.25 made it
synchronous and the same bug was pinned in **one run** after five builds of
guessing.

A state dump cannot show you code that did not execute. Inspection and
instrumentation are different tools and the library needs both.

### Overlay hosting — **shipped**

`SPKOverlayWindow` — passthrough window that:
- never becomes key (`canBecomeKeyWindow` NO, `makeKeyWindow` neutered), so the
  host app keeps first responder and status-bar ownership
- hit-tests through everything that is not an explicit child
- supports **bottom-strip** and full-screen modes, sized at creation rather than
  seeded small and resized
- exposes its level as one reviewable constant

Eight Music27 builds went into getting this right. CC27 and Siri27 will need it.

### SwiftUI discovery — the differentiator

- `SPHostingViewsIn(window)` — already exists internally
- `SPControllerWithSuffix(root, @"MiniPlayerViewController")` — Music27 hand-rolled this
- `SPAppTabBarController()` — Music27 hand-rolled this
- `SPSwiftTypeName(obj)` — already exists internally

### Control discovery — open requirement

**Find the real interactive control behind a visible element.**

Music27's album row (Shuffle / Play / Download) locates stock controls by
matching **title text**, which is fragile and appears to fail on iOS 17.3 — the
glass buttons are inert and the stock ones are not covered. If Music renders that
row through SwiftUI there may be no titled `UIControl` to find at all.

The library should answer "what is the tappable thing here?" without every tweak
inventing its own heuristic. Candidate approach: search by accessibility label,
by gesture-recogniser presence, and by geometry, then report what was found and
what was not — rather than failing silently.

SwiftPeek already has an offline `MA-AlbumDetail` catalog; making it queryable
from a live album page is the natural first test of this API.

## Hazard registry

The most valuable thing here, and the part nobody else can cheaply reproduce.
Each entry cost at least one device cycle.

| Hazard | Consequence | Rule |
|--------|-------------|------|
| `MPMusicPlayerController` inside Music.app | **Crashes Music** — it is an IPC client for Music, called from inside Music | Never. Use MediaRemote |
| `MPNowPlayingInfoCenter.nowPlayingInfo` read inside the playing app | Always empty — it is the *publish* side of the API | Read MediaRemote instead |
| Swift-linked dylib in SpringBoard | Safe Mode (SwiftPeek 0.2.1) | Keep the library ObjC-only |
| `alpha < 0.01` to hide a view you still need to hit-test | `hitTest:` returns nil; forwarded taps die silently | Use `layer.opacity = 0` |
| `userInteractionEnabled = NO` on a view you forward taps to | Same — `hitTest:` refuses it | Lift it only for the lookup |
| FOVO field walks on Music UIViewControllers / UIViews | SIGSEGV (0.3.0, 0.3.5) | Per-app allowlist; never transfers |
| Async logging around a suspected crash | Loses exactly the line that explains it | Synchronous + `fsync` |
| Asserting a cause from a symptom without instrumentation | Five wrong Music27 theories: cover plate → window level → app window level → window size → install path. The real cause was a crash | Instrument first |
| Shared-source **ObjC classes** with one fixed name | ObjC's class table is global and keyed by name; two dylibs in one process register the same class and the runtime picks one — possibly a stale copy from a tweak built months ago | `-DSPK_CLASS_PREFIX` per consumer. Plain C functions are safe (two-level namespace) |
| `../` in a Theos `_FILES` entry | Object files land outside `.theos/obj` | Symlink the shared directory into `src/` |
| Path-filtered CI that does not list the shared directory | A shared-source change silently ships nothing | Add `SPKit/**` to every consumer's workflow trigger |

## Dogfooding order

1. ~~Extract runtime hygiene + overlay hosting as **shared source**.~~ Done —
   `SPKit/`.
2. ~~**Music27 consumes it**, deleting its own jbroot resolver, prefs reader,
   status writer and overlay window.~~ Done in Music27 1.1.34. Baseline for
   comparison is 1.1.33: the extraction is only correct if 1.1.34 behaves
   identically on device.
3. SwiftPeek itself — `SPPrefs.m` and `SPDumpWriter.m` still carry their own
   copies of the resolver.
4. CC27 next — first real test of whether the overlay window generalises, and
   four jbroot copies to collapse.
5. Siri27 via `SiriViewService` / `assistantd`. SpringBoard only after the kill
   switch has been exercised for real on a lower-risk target.
6. Promote to a static library, then a `Depends:` package when shape 3 is forced.

If it survives being a dependency of your own tweaks across a few releases, it is
ready for anyone else's.
