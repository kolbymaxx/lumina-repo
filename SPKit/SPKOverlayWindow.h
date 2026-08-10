#import <UIKit/UIKit.h>

// Shared-source ObjC classes need per-consumer names.
//
// C functions are fine as-is: tweak dylibs are two-level namespace, so each
// binds to its own copy. ObjC classes are NOT — the runtime keeps one global
// table keyed by name. Music27 and SwiftPeek both load into Music.app, and two
// dylibs registering "SPKOverlayWindow" gets you the runtime's "implemented in
// both, one of the two will be used" warning and a coin flip over which copy
// wins. That coin flip can hand you a stale class from a tweak built months ago.
//
// So each consumer compiles with -DSPK_CLASS_PREFIX=<theirs> and gets its own
// class names, while the source below keeps calling them SPKOverlayWindow.
#ifndef SPK_CLASS_PREFIX
#define SPK_CLASS_PREFIX SPK
#endif
#define SPK_PASTE_INNER(a, b) a##b
#define SPK_PASTE(a, b) SPK_PASTE_INNER(a, b)
#define SPKOverlayWindow   SPK_PASTE(SPK_CLASS_PREFIX, OverlayWindow)
#define SPKPassthroughView SPK_PASTE(SPK_CLASS_PREFIX, PassthroughView)

NS_ASSUME_NONNULL_BEGIN

/// Root view of an SPKOverlayWindow. Passes taps that land on empty chrome
/// through to whatever is underneath — only real subviews receive them.
@interface SPKPassthroughView : UIView
@end

/// A window you can put custom chrome in without breaking the app underneath.
///
/// Eight Music27 builds went into the rules encoded here:
///
/// - **It never becomes key.** First responder, keyboard and status-bar style
///   all follow the key window; an overlay that steals it is one of the ways an
///   app ends up looking blank.
/// - **It hit-tests through itself.** Anything landing on the window or its root
///   view returns nil, so the host app keeps every tap that is not on your UI.
/// - **Size it at creation.** Music27 1.1.20 seeded a 1pt-tall window and
///   resized it afterwards; that build never painted at all.
/// - **Prefer a bottom strip over full-screen.** `+bottomStripFrameInScreen:`
///   caps the height so a safe-area surprise cannot grow it.
///
/// Hiding rule that is NOT in this class but bites everyone who uses it: to hide
/// a view you still need to hit-test, use an **empty `CALayer` mask**. `hitTest:`
/// refuses views below alpha 0.01, so a faded view swallows nothing and forwards
/// nothing — and `layer.opacity` is NOT a way around that. `UIView.alpha` is
/// backed by `CALayer.opacity`; they are the same property. Music27 1.1.29
/// swapped one for the other believing otherwise and left a dead tap in place
/// for fourteen versions. A mask layer with no opaque pixels renders nothing
/// while `alpha` stays 1, which is the only combination that works.
@interface SPKOverlayWindow : UIWindow

/// Create at `frame`, attached to `scene` when one is available. The window is
/// clear, non-opaque, interactive, visible, and already has a
/// `SPKPassthroughView` root — ready for you to add subviews to `hostView`.
+ (instancetype)overlayWithFrame:(CGRect)frame
                     windowScene:(nullable UIWindowScene *)scene
                           level:(UIWindowLevel)level;

/// The passthrough root view. Add your chrome here.
@property (nonatomic, readonly) UIView *hostView;

/// The window scene owning `view`, walking up its window and falling back to the
/// first foreground-active scene in the app.
+ (nullable UIWindowScene *)sceneForView:(nullable UIView *)view;

/// A bottom strip of `contentHeight` + `gap` + `safeBottom`, pinned to the
/// bottom of `screen` and hard-capped at 30% of the screen height.
+ (CGRect)bottomStripFrameInScreen:(CGRect)screen
                     contentHeight:(CGFloat)contentHeight
                               gap:(CGFloat)gap
                        safeBottom:(CGFloat)safeBottom;

@end

NS_ASSUME_NONNULL_END
