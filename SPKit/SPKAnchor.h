#import <UIKit/UIKit.h>

// SPKAnchor — find the real view behind a visible element, and say why you
// could not.
//
// ## The problem this exists for
//
// Every tweak that augments someone else's UI starts by locating a view it does
// not own. On UIKit-era iOS you did that by class name. On a SwiftUI-era app you
// often cannot: the class is a mangled generic, there is no named subview, and
// the tree is rebuilt whenever state changes. So each tweak hand-rolls a
// geometry heuristic — "the biggest roughly-square thing in the top half" — and
// each one has the same two failure modes:
//
//   1. It returns nil and the tweak silently does nothing. The page looks
//      stock, there is no error, and the developer cannot tell "not found" from
//      "found and my styling is wrong".
//   2. It returns the WRONG view. Music27 once fired `NowPlayingShuffleButton`
//      — a real control parked off-screen at x=-28 — on 48 consecutive taps,
//      silently toggling shuffle instead of expanding the player.
//
// Music27 hand-rolled this three times (album artwork, the track collection,
// the download control). Two of the three have returned nil on a real device
// and cost builds to diagnose. This is that heuristic, written once, with the
// part that was always missing: **a census of what it rejected and why.**
//
// ## What makes this different from a `viewWithTag:` helper
//
// A failed resolve is not a nil return. It is a report:
//
//     visited=63 candidates=7 chose=MusicArtworkComponentImageView score=631
//     rejected: aspect=4 (closest 0.58) side=2 (largest 96) originY=1
//
// That line turns "the page looks stock" into "there IS a square, it is 96pt,
// and my minSide of 150 threw it away" — which is a one-line fix instead of a
// device cycle.
//
// ## Deliberately not included
//
// No hooks, no swizzles, no caching of the resolved view. A view found on one
// layout pass may be gone on the next; hold it weakly, or re-resolve. SwiftUI
// gives no stable identity and this API does not pretend otherwise.
//
// Plain C functions and a struct on purpose. Shared-source ObjC *classes* with
// one fixed name are a hazard — the ObjC class table is global and keyed by
// name, so two dylibs registering the same class let the runtime pick one,
// possibly a stale copy from a tweak built months ago. C functions get
// two-level namespacing and are safe.

NS_ASSUME_NONNULL_BEGIN

/// A declarative description of the view you are looking for.
///
/// Build one with `SPKAnchorQueryMake()` and set only the fields you care
/// about — a zeroed field means "no constraint", never "constraint of zero".
typedef struct SPKAnchorQuery {
    /// Lowercase substring of the class name, e.g. "artwork". NULL = any.
    /// Matching is a bonus, not a requirement, unless `requireName` is YES.
    const char *nameContains;
    /// YES to reject anything `nameContains` does not match.
    BOOL requireName;

    /// Reject candidates whose shorter side is below this, in points.
    /// The single most common reason a real match is thrown away — check the
    /// `side` rejection count before raising it.
    CGFloat minSide;
    /// Reject candidates whose shorter side exceeds `coordinateSpace` width
    /// times this. Use ~0.96 to skip containers that are already the page.
    /// 0 = no limit.
    CGFloat maxSideFraction;
    /// Reject candidates whose origin.y exceeds the space's height times this.
    /// Use ~0.5 for "in the top half". 0 = no limit.
    CGFloat maxOriginYFraction;

    /// Width/height bounds. Use 0.68/1.50 for "roughly square".
    /// Both 0 = no aspect constraint.
    CGFloat minAspect;
    CGFloat maxAspect;

    /// Reject `UIControl`s. Almost always YES — a button inside the artwork is
    /// not the artwork, and picking it is the "48 consecutive taps" bug.
    BOOL rejectControls;
    /// Reject `UILabel`s.
    BOOL rejectLabels;
    /// Reject `UIScrollView`s and `UICollectionView`s.
    BOOL rejectScrollViews;
    /// Reject hidden views and anything under alpha 0.01. Almost always YES.
    BOOL requireVisible;

    /// Score added when the class name matches `nameContains`.
    CGFloat nameBonus;
    /// Score added when the view is a `UIImageView` carrying a non-nil image.
    CGFloat imageBonus;
    /// Score added when the view hosts an `AVPlayerLayer` or is an `MTKView` —
    /// i.e. an ANIMATED cover. iOS 17+ album art can be video, and a snapshot
    /// or a replacement `UIImageView` would freeze it.
    CGFloat playerBonus;

    /// Traversal caps. 0 uses the defaults (120 views, 24 children each).
    NSInteger maxVisited;
    NSInteger maxChildrenPerView;
} SPKAnchorQuery;

/// A query with every constraint off and the conventional bonuses set
/// (name 400, image 200, player 300) plus `rejectControls`, `rejectLabels` and
/// `requireVisible` on. Start here and add constraints.
SPKAnchorQuery SPKAnchorQueryMake(void);

/// Breadth-first search from `root` for the highest-scoring view matching `q`.
///
/// `coordinateSpace` is what geometry is measured against — pass the page or
/// window, NOT `root`, so fractional limits mean what you think. Passing nil
/// uses `root`.
///
/// Returns nil when nothing matched. Call `SPKAnchorReport()` immediately
/// afterwards to find out why; do not guess.
UIView *_Nullable SPKAnchorResolve(UIView *_Nullable root,
                                   UIView *_Nullable coordinateSpace,
                                   SPKAnchorQuery q);

/// One-line human-readable census of the most recent `SPKAnchorResolve`.
///
/// Safe to log verbatim into a status file. Overwritten by the next resolve on
/// the same thread, so read it before resolving again.
NSString *SPKAnchorReport(void);

/// The same census, machine-readable, for embedding in a JSON status payload.
/// Keys: visited, candidates, chose, score, and one entry per rejection reason
/// ("rej_side", "rej_aspect", "rej_originY", "rej_kind", "rej_name",
/// "rej_hidden") plus "near_side" / "near_aspect" — the closest value that was
/// thrown away, which is what tells you a threshold is one notch too tight.
NSDictionary<NSString *, id> *SPKAnchorStats(void);

NS_ASSUME_NONNULL_END
