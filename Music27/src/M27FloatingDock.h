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
- (NSInteger)numberOfTabsForFloatingDock:(M27FloatingDock *)dock;
- (nullable UIImage *)floatingDock:(M27FloatingDock *)dock iconForTabIndex:(NSInteger)index selected:(BOOL)selected;
- (nullable NSString *)floatingDock:(M27FloatingDock *)dock titleForTabIndex:(NSInteger)index;
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

@end

NS_ASSUME_NONNULL_END
