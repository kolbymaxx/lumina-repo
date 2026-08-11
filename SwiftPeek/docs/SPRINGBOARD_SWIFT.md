# Swift in SpringBoard — what is settled and what is not

## Settled: ObjC-only SwiftPeek runs in SpringBoard

SwiftPeek 0.4.0 ran in SpringBoard on **iPhone13,1 / iOS 17.3** with
`targetSpringBoard` + `sbScanWindows` + `iconInventory` all on: four dumps, no
Safe Mode, no respring loop. See `MERGE_NOTES.md` — that is device evidence,
not argument.

So the blanket reading of the 0.2.1 Safe Mode — "SwiftPeek must stay out of
SpringBoard" — is retired. What actually failed in 0.2.1 was a **Swift-linked
dylib**, and an ObjC-only build installing no hooks, swizzling nothing, and
walking no Swift metadata does not reproduce it.

Two caveats stay on the record: it is **one device on one firmware**, and 16.7
has not been tried.

## Not settled: whether a *Swift-linked* dylib can live there

This is the open question, and the honest position is that it has not been
tested rather than that it is impossible. The facts point at "probably, with
care":

- Swift has been **ABI-stable since Swift 5 / iOS 12.2**, with the runtime
  shipped in the OS at `/usr/lib/swift/` rather than copied into each binary.
- SpringBoard on iOS 16/17 **already loads SwiftUI-backed system UI**. Swift is
  resident in that process whether or not a tweak puts it there.

"A Swift dylib killed SpringBoard once" was never the same claim as "Swift
cannot live in SpringBoard", and the two were conflated. What makes it worth
being careful about is not likelihood — it is **cost of failure**: a SpringBoard
crash loop costs a device you cannot drive, where an app crash costs a relaunch.

## How to try it without betting the device

Three mechanisms, in the order they should be built. None of them is exotic;
together they turn a gamble into an experiment.

### 1. Prove it on a relaunchable target first

`targetSettings` already exists and Settings is SwiftUI-heavy on 17 — a good
soak target that costs a force-quit when it goes wrong. `SiriViewService` is
the next rung: system UI, still not SpringBoard. A Swift-linked build should
survive both before SpringBoard is discussed.

### 2. `dlopen` the Swift part; do not link it

If the Swift code lives in a **separate dylib loaded on demand**, a load failure
returns an error instead of taking the process down with it, and the ObjC core
still comes up to report what happened. Linking it into the main dylib means
dyld resolves it at injection time, in every targeted process, before any of our
code can decide whether it should.

This also keeps the SpringBoard rule enforceable by construction rather than by
discipline: the Swift plugin is simply never loaded there until it has earned
it, and CI can keep asserting that no Swift source enters the ObjC build.

### 3. Crash-loop auto-disable

The kill switch (`$jbroot/var/mobile/Library/SwiftPeek/DISABLE`) requires a
working device to create the file. That is exactly what a boot loop takes away.

So invert it. Before the risky work, write a breadcrumb; clear it after. On the
next launch, if the breadcrumb is still there, **disable and do not retry**.

```
write  .../SwiftPeek/LOADING     ← before the risky path
clear  .../SwiftPeek/LOADING     ← after it returns
on launch: LOADING exists ⇒ previous attempt did not survive ⇒ stay off
```

One bad boot instead of a wall, and it recovers itself. This is the same
synchronous, `fsync`'d breadcrumb discipline that caught the Music27 install
crash in 1.1.25 — three launches all reading `install_begin` → `dock_created` →
process gone, which is what identified `MPMusicPlayerController` as the cause.

Worth adding regardless of Swift: it makes the existing ObjC SpringBoard target
safer too, and it is the piece that makes aggressive reverse engineering
survivable rather than reckless.

## What stays true either way

- SpringBoard access remains behind opt-in prefs, all defaulting off.
- `dumpFieldMeta` stays forced off in SpringBoard regardless of pref.
- Icons come only from `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]`
  and `LSApplicationWorkspace` — never `SBIconModel`, the icon cache, or the
  icon view tree.
- No hooks, no swizzles, no `FOVO`, no Swift metadata walks in SpringBoard.
- CI keeps asserting the opt-in gate and that no Swift source enters the build.
