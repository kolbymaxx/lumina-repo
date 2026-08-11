# SwiftPeek as a dependency — the three capabilities worth building

Not started. This is a design note, written from evidence rather than from
taste: every item below is here because a consumer tweak hit the problem on a
real device and paid for it in builds.

The framing question was whether SwiftPeek should become a "UIKit → SwiftUI
translator" that tweaks could depend on. It should not, and the reason points
at what it should be instead.

## Why a translator is the wrong shape

SwiftUI is not a layer over UIKit. It has its own layout engine and its own
private backing views (`_UIGraphicsView`, `CGDrawingView`, and friends), so
there is no seam where a live `UIView` could be re-expressed as SwiftUI —
nothing on the SwiftUI side consumes an existing view hierarchy. The two
directions that exist are both *embedding*:

- `UIHostingController` puts SwiftUI inside UIKit. This is what Music does, and
  the `_UIHostingView` SwiftPeek already looks for.
- `UIViewRepresentable` puts a UIKit view inside SwiftUI. It still renders as
  UIKit; SwiftUI only reserves space.

Neither converts anything, and conversion would not help. The difficulty a
tweak hits on a SwiftUI host is not the notation — it is that SwiftUI offers
**no stable identity**: no named subviews, no persistent object to hold, and a
tree that gets rebuilt whenever state changes.

Music27 1.1.35 is the canonical example. `MusicCoreUI.SymbolButton` turned out
to be *only the grey capsule background*; SwiftUI drew the glyph and the label
as siblings, outside that view's layer subtree. Hiding the button could never
hide the red ▶, and three builds went past before a readback (`play_hidden=yes
play_opacity=0 play_alpha=0` while the glyph was plainly still on screen)
forced the issue. Re-expressing that tree as SwiftUI would have produced the
same shapeless result in different words.

## 1. Stable anchors

**The ask.** "Give me the view rendering this SwiftUI type, and keep pointing
at it after SwiftUI rebuilds."

SwiftPeek already does the hard half — it finds `_UIHostingView`s and demangles
Swift type names, which is how `MusicApplication.PaletteContainerView` and
`MiniPlayerViewController` were identified in the first place. What is missing
is **re-resolution**: a handle that survives a rebuild, so a consumer is not
re-walking the tree on every layout pass and hoping.

Every tweak touching a modern app needs this, and every one currently solves it
by hand. Music27's version is `M27FindControlWithTitle` — a recursive search
matching on title text and accessibility labels, depth-capped at 8, run again
on every `viewDidLayoutSubviews`. It works, it is not cheap, and it is wrong in
ways that took builds to find: 1.1.38 fired `NowPlayingShuffleButton` because
"first `UIControl` in the subtree" happily returned an off-screen one.

**Shape.** A token identifying a match (type name + role + a positional
discriminator), a `resolve` that returns the current view or nil, and a change
notification when the identity moves. Read-only throughout — this is a lookup
service, not a mutation API.

## 2. Declarative overlay hosting

**The ask.** Not translating the host's UI — letting a *tweak* declare its own
UI and pin it to a host anchor, with the window rules already correct.

`SPKit`'s `SPKOverlayWindow` is most of this already, and every rule in it was
bought with a broken build:

- never becomes key (`canBecomeKeyWindow` → NO)
- hit-tests through itself, so host content under the clear regions stays live
- sized at creation, never seeded at 1pt and grown
- capped to a bottom strip, never full-screen
- `UIWindowLevelNormal + 2`, not `StatusBar - 1`

Music27 1.1.19 through 1.1.24 is the receipt: a full-screen overlay at
`StatusBar - 1` white-screened Music on 17.3, and 1.1.21 proved the window
level was the cause rather than the plate, because 1.1.19 and 1.1.21 differed
only by the plate and both blanked. `Normal + 10` then failed the other way —
it does not composite above Music at all.

**Shape.** Anchor + content + lifecycle. The consumer says "this content,
pinned to that anchor, torn down when the anchor goes"; the dependency owns the
window, the level, the passthrough, and the teardown.

**Constraint.** If the content is ever declared in SwiftUI, that links the Swift
runtime into the host process — see `SPRINGBOARD_SWIFT.md`. The ObjC content
path has to stay first-class.

## 3. Measurement

**The ask.** A read-only tree dump with enough in it to build on.

This is the one with the clearest track record: it unblocked two stuck screens
in a row after targeted ivar reads failed twice.

- The full-screen player. The offline catalog named
  `MusicApplication.NowPlayingControlsViewController` with `artworkView`,
  `dismissButton` and eighteen more fields. On device the class was
  `MusicNowPlayingControlsViewController` and every catalog name came back
  `missing`; the follow-up enumeration returned `count=1`, that one being
  `_view`. A breadth-first class + frame walk got further in one build than two
  rounds of ivar guessing.
- The album page. `album_tree` located the artwork (a 231×231 `UIView` at
  `{72, 101}`, holding no image of its own) and — from a single extra column —
  showed the `UICollectionView` above the colour wash reporting `bg 1.00`. That
  one field explains why *Artwork Color Theme* had never been visible: it is
  inserted at layer index 0 with `zPosition -1000`, behind an opaque wall.

**Shape.** Breadth-first, capped rows and depth, one row per view: class, frame
in a caller-chosen space, background alpha, and image dimensions when the view
carries one. No ivar reads — the type-encoding rule below still applies.

**Already proven necessary:** the background-alpha column. It was added on a
guess and immediately answered a question that had been open for eleven builds.

## Rules any of this inherits

- **Read-only.** SwiftPeek must never mutate host UI. Capability 2 hosts a
  *consumer's* view in its own window; it does not touch the host's.
- **Only `@` is safe.** `ivar_getTypeEncoding` must say object before an ivar is
  read. Swift structs and enums read as `id` are how 0.3.0 and 0.3.5 earned
  their SIGSEGVs.
- **`UIView.alpha` is `CALayer.opacity`.** One property. Hiding something that
  must stay hit-testable needs an empty `CALayer` mask. Music27 believed
  otherwise for fourteen versions.
- **Diagnostics must not sit behind the success of the thing they diagnose.**
  Music27 lost a round of evidence to a recon dump gated on "no control found"
  when a control was always found.
