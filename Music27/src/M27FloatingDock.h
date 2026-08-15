#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, M27DockMode) {
    /// Mini-player glass pill stacked above a 5-tab glass pill.
    M27DockModeExpanded = 0,
    /// Single merged pill: red Music button · mini player · Search.
    M27DockModeCollapsed = 1,
};

@class M27FloatingDock;

@protocol M27FloatingDockDelegate <NSObject>
- (void)floatingDock:(M27FloatingDock *)dock didSelectTabIndex:(NSInteger)index;
- (void)floatingDockDidTapSearch:(M27FloatingDock *)dock;
- (void)floatingDockDidTapPlayPause:(M27FloatingDock *)dock;
- (void)floatingDockDidTapNowPlaying:(M27FloatingDock *)dock;
@optional
- (void)floatingDockDidTapNext:(M27FloatingDock *)dock;
- (void)floatingDockDidChangeMode:(M27FloatingDock *)dock;
/// Horizontal swipe-to-skip. `direction` is +1 previous (drag right) or
/// -1 next (drag left). Incoming keys: `title`, `artist`, `artwork` (UIImage).
- (BOOL)floatingDockShouldAllowSwipe:(M27FloatingDock *)dock;
- (nullable NSDictionary *)floatingDock:(M27FloatingDock *)dock
            incomingTrackForDirection:(NSInteger)direction;
- (void)floatingDock:(M27FloatingDock *)dock didCommitSwipeWithDirection:(NSInteger)direction;
- (void)floatingDockDidCancelSwipe:(M27FloatingDock *)dock;
- (NSInteger)numberOfTabsForFloatingDock:(M27FloatingDock *)dock;
- (nullable UIImage *)floatingDock:(M27FloatingDock *)dock iconForTabIndex:(NSInteger)index selected:(BOOL)selected;
- (nullable NSString *)floatingDock:(M27FloatingDock *)dock titleForTabIndex:(NSInteger)index;

/// Should a touch at `point` (dock coordinates) be declined so it reaches the
/// app underneath instead?
///
/// Opening the full player is the one thing the dock cannot do for itself: the
/// mini player has no button that expands it, and three builds proved that
/// firing "some control" just picks a different wrong one. But Music's own mini
/// player is still sitting under the pill, hidden with `layer.opacity = 0` —
/// invisible and fully hit-testable. Declining the touch lets Music open the
/// player natively, with its real animation and lyrics screen.
- (BOOL)floatingDock:(M27FloatingDock *)dock shouldPassThroughPoint:(CGPoint)point;
@end

/// iOS 27-style floating Music dock with Liquid Glass chrome.
@interface M27FloatingDock : UIView

@property (nonatomic, weak, nullable) id<M27FloatingDockDelegate> delegate;
@property (nonatomic, assign) M27DockMode mode;
@property (nonatomic, assign) NSInteger selectedTabIndex;
@property (nonatomic, strong, nullable) UIImage *artwork;
@property (nonatomic, copy, nullable) NSString *trackTitle;
@property (nonatomic, copy, nullable) NSString *artistName;
@property (nonatomic, assign) BOOL playing;
/// NO when there is genuinely nothing to show — the mini pill is dropped and the
/// dock becomes just the tab row, as it is on iOS 27 before you play anything.
/// Defaults NO so a freshly built dock never flashes a placeholder pill.
@property (nonatomic, assign) BOOL hasTrack;

/// Preferred height for the current mode (excludes external bottom safe-area
/// padding the host may add below the dock).
@property (nonatomic, readonly) CGFloat preferredHeight;

- (void)setMode:(M27DockMode)mode animated:(BOOL)animated;
- (void)reloadTabs;
- (void)refreshChrome;
- (void)collapseFromScroll;
- (void)expandFromRedButton;

/// Pan attached to Music's own mini player — the view the passthrough already
/// delivers touches to. Same state machine as the dock's own pan, so a swipe
/// that starts on either side of the window boundary still drives the carousel.
- (void)handleExternalSwipePan:(UIPanGestureRecognizer *)pan;
/// Direction bias shared with the mini-player pan: horizontal must dominate
/// or a 52pt-tall capsule claims every touch that moves.
+ (BOOL)panGestureIsHorizontalSwipe:(UIPanGestureRecognizer *)pan;

@end

NS_ASSUME_NONNULL_END
