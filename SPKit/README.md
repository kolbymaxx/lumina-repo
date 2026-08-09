# SPKit

The shared runtime behind SwiftPeek and the 27-series tweaks. This is step 1 of
[SwiftPeek/docs/DEPENDENCY_PLAN.md](../SwiftPeek/docs/DEPENDENCY_PLAN.md):
**shared source**, not a linked library and not a `Depends:` package.

That distinction is the point. A change here cannot break an installed tweak
that has not been rebuilt, because there is nothing to load at runtime. The API
is the same one a static library or a dylib would expose later, so promoting it
is a packaging change rather than a rewrite — while a bad API that other people
already depend on is permanent.

## What is in it

| File | Provides |
|------|----------|
| `SPKRuntime.h/.m` | `SPKJailbreakRoot` · `SPKRootedPath` · `SPKPrefBool` · `SPKPrefs` · `SPKKillSwitchEngaged` · `SPKTrace` |
| `SPKOverlayWindow.h/.m` | `SPKOverlayWindow` — passthrough overlay window and bottom-strip sizing |

Nothing here is speculative. Every piece was written by hand at least twice
before it was extracted: six near-identical copies of the jailbreak-root
resolver existed across Music27, SwiftPeek and CC27, four of them inside CC27
alone.

## Consuming it

Symlink it into your project and add the sources:

```sh
ln -s ../../SPKit YourTweak/src/spkit
```

```make
YourTweak_FILES = \
	src/spkit/SPKRuntime.m \
	src/spkit/SPKOverlayWindow.m \
	src/Tweak.x

YourTweak_CFLAGS = -fobjc-arc \
	-I$(THEOS_PROJECT_DIR)/src/spkit -DSPK_CLASS_PREFIX=YT
```

Then, first thing in `%ctor`:

```objc
SPKTraceConfigure(@"YourTweak", @"1.0.0");
```

Two details that are not optional:

**`-DSPK_CLASS_PREFIX` is required, and must be unique per tweak.** ObjC keeps
one global class table keyed by name. Two dylibs in the same process that both
register `SPKOverlayWindow` produce the runtime's "implemented in both, one of
the two will be used" warning and a coin flip over which copy wins — possibly a
stale one from a tweak built months ago. The prefix gives each consumer its own
class names while the source still reads `SPKOverlayWindow`. (Plain C functions
do not need this: tweak dylibs are two-level namespace, so each binds its own.)

**The symlink is required too** — Theos writes object files to
`.theos/obj/<source path>`, so a literal `../SPKit/…` in `_FILES` escapes the
build directory.

If your CI filters builds by path, add `SPKit/**` to the tweak's trigger. Shared
source means a change here changes your binary.

## Rules encoded here

These cost device cycles to learn. They are enforced in code so the next tweak
inherits them:

- **`SPKTrace` is synchronous and `fsync`'d.** Music27 1.1.23 logged through a
  dispatch queue; when Music crashed during install the queue never drained and
  the log was empty, making a crash indistinguishable from a code path that
  never ran. Five builds of guessing. 1.1.25 made it synchronous and pinned the
  bug in one run.
- **`SPKOverlayWindow` never becomes key.** First responder, keyboard and
  status-bar style follow the key window.
- **It is sized at creation.** Music27 1.1.20 seeded a 1pt-tall window and
  resized it after; that build never painted.
- **`bottomStripFrameInScreen:` caps at 30% of the screen.** Every full-screen
  overlay build white-screened Music on iOS 17.3.
- **An empty prefs dictionary is not a hit.** Otherwise a stub file at an early
  candidate path masks the real prefs at a later one.

One rule that belongs with these but cannot live in a class: to hide a view you
still need to hit-test, use `layer.opacity = 0`, never `alpha = 0`. `hitTest:`
refuses views below alpha 0.01 and forwarded taps die silently. Music27 hit this
twice, in 1.1.28 and 1.1.31.

## Adoption

| Tweak | Status |
|-------|--------|
| Music27 | 1.1.34 — jbroot resolver, prefs paths, status log and overlay window all removed in favour of SPKit. **Device-verified**: `overlay_created` frame and level, `dock_created`, `install_ok` and `album_controls` are identical to 1.1.33 on iOS 17.3 |
| SwiftPeek | pending |
| CC27 | pending — four jbroot copies to collapse |
| Siri27 | pending |
