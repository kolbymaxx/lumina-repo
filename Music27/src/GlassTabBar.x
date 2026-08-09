#import "Music27.h"
#import "M27FloatingDock.h"
#import "M27GlassChrome.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Floating Liquid Glass dock for Music.
//
// WINDOW LEVEL IS THE WHOLE BALLGAME. Device results on iPhone13,1 / iOS 17.3
// Dopamine, all with a full-screen passthrough overlay window:
//
//   1.1.12-1.1.16  Normal+2      no plate    dock VISIBLE, Library USABLE  ✓
//   1.1.19         StatusBar-1   plate       white screen
//   1.1.20         Normal+10     no plate    never painted (Music 100% stock)
//   1.1.21         StatusBar-1   NO plate    white screen
//
// 1.1.19 and 1.1.21 differ only by the cover plate and both white-screened, so
// the plate was never the cause: a full-screen window at StatusBar-1 blanks
// Music on 17.3 even when it draws literally nothing. Best theory is that a
// full-screen window at/above status-bar level makes the system treat Music's
// own window as occluded, or makes Music's SwiftUI hosts resolve "the" window
// to ours; either way the fix is the same — stay low.
//
// 1.1.21 wrongly assumed StatusBar-1 was safe because 1.1.19's plate had been
// visible there. Visible and safe are not the same thing.
//
// 1.1.22 (this build):
// - Window level back to Normal+2, the exact 1.1.12 configuration and the only
//   one that ever produced a visible dock AND a usable Library on this device.
// - Full-screen passthrough window, no cover plate, pills only.
// - Window can never become key, so Music keeps first responder / status bar.
// - Never mutate MiniPlayer/Library/tabBar. Prefs left as the user set them.

static const NSInteger kM27DockTag = 0x4D323744; // 'M27D'
static const NSInteger kM27CoverTag = 0x4D32434F; // 'M2CO' (legacy teardown only)
static const CGFloat kM27ScrollCollapseY = 48.0;
static const CGFloat kM27FloatGap16 = 12.0;
static const CGFloat kM27FloatGap17 = 14.0;

static NSInteger M27SystemMajorVersion(void) {
    static NSInteger major = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        major = UIDevice.currentDevice.systemVersion.integerValue;
    });
    return major;
}

static CGFloat M27FloatGap(void) {
    return M27SystemMajorVersion() >= 17 ? kM27FloatGap17 : kM27FloatGap16;
}

static const void *kM27DockControllerKey = &kM27DockControllerKey;
static const void *kM27DockViewKey = &kM27DockViewKey;
static const void *kM27DockWindowKey = &kM27DockWindowKey;
static const void *kM27LayoutGuardKey = &kM27LayoutGuardKey;

#pragma mark - Passthrough overlay window

@interface M27PassthroughView : UIView
@end

@implementation M27PassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Empty chrome must not eat Library taps — only the dock pills should.
    return (hit == self) ? nil : hit;
}
@end

@interface M27DockOverlayWindow : UIWindow
@end

@implementation M27DockOverlayWindow

// The window is full-screen, so every pixel that is not a dock pill must fall
// through to Music, or Library becomes untappable even while it stays visible.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

// Music must keep key-window status — the keyboard, first responder and status
// bar style all follow the key window, and a full-screen overlay stealing it is
// exactly how an app ends up looking blank.
- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (void)makeKeyWindow {
}

- (void)makeKeyAndVisible {
    self.hidden = NO;
}

@end

#pragma mark - MediaRemote (soft-linked)

typedef void (*M27MRSendCommandFunc)(unsigned int command, CFDictionaryRef options);

static M27MRSendCommandFunc M27MRSendCommand(void) {
    static M27MRSendCommandFunc fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (handle) {
            fn = (M27MRSendCommandFunc)dlsym(handle, "MRMediaRemoteSendCommand");
        }
    });
    return fn;
}

static void M27TogglePlayPause(void) {
    M27MRSendCommandFunc send = M27MRSendCommand();
    if (send) {
        send(2, NULL);
        return;
    }
    MPMusicPlayerController *player = MPMusicPlayerController.systemMusicPlayer;
    if (player.playbackState == MPMusicPlaybackStatePlaying) {
        [player pause];
    } else {
        [player play];
    }
}

static void M27NextTrack(void) {
    M27MRSendCommandFunc send = M27MRSendCommand();
    if (send) {
        send(4, NULL);
        return;
    }
    [MPMusicPlayerController.systemMusicPlayer skipToNextItem];
}

#pragma mark - Dock controller bridge

@class M27DockController;

static void M27LayoutDock(UITabBarController *tbc, M27FloatingDock *dock);
static UIViewController *M27FindMiniPlayerViewController(UITabBarController *tbc);

@interface M27DockController : NSObject <M27FloatingDockDelegate>
@property (nonatomic, weak) UITabBarController *tabBarController;
@property (nonatomic, weak) M27FloatingDock *dock;
@end

@implementation M27DockController

- (NSInteger)numberOfTabsForFloatingDock:(M27FloatingDock *)dock {
    (void)dock;
    return (NSInteger)self.tabBarController.viewControllers.count;
}

- (NSString *)floatingDock:(M27FloatingDock *)dock titleForTabIndex:(NSInteger)index {
    (void)dock;
    NSArray<__kindof UIViewController *> *vcs = self.tabBarController.viewControllers;
    if (index < 0 || index >= (NSInteger)vcs.count) return nil;
    return vcs[index].tabBarItem.title;
}

- (UIImage *)floatingDock:(M27FloatingDock *)dock iconForTabIndex:(NSInteger)index selected:(BOOL)selected {
    (void)dock;
    NSArray<__kindof UIViewController *> *vcs = self.tabBarController.viewControllers;
    if (index < 0 || index >= (NSInteger)vcs.count) return nil;
    UITabBarItem *item = vcs[index].tabBarItem;
    return selected && item.selectedImage ? item.selectedImage : item.image;
}

- (void)floatingDock:(M27FloatingDock *)dock didSelectTabIndex:(NSInteger)index {
    (void)dock;
    if (index < 0 || index >= (NSInteger)self.tabBarController.viewControllers.count) return;
    self.tabBarController.selectedIndex = (NSUInteger)index;
}

- (void)floatingDockDidTapSearch:(M27FloatingDock *)dock {
    (void)dock;
    NSInteger searchIndex = NSNotFound;
    NSArray<__kindof UIViewController *> *vcs = self.tabBarController.viewControllers;
    for (NSInteger i = 0; i < (NSInteger)vcs.count; i++) {
        NSString *title = vcs[i].tabBarItem.title.lowercaseString ?: @"";
        if ([title containsString:@"search"]) {
            searchIndex = i;
            break;
        }
    }
    if (searchIndex == NSNotFound && vcs.count > 0) {
        searchIndex = (NSInteger)vcs.count - 1;
    }
    if (searchIndex != NSNotFound) {
        self.tabBarController.selectedIndex = (NSUInteger)searchIndex;
        self.dock.selectedTabIndex = searchIndex;
    }
}

- (void)floatingDockDidTapPlayPause:(M27FloatingDock *)dock {
    (void)dock;
    M27TogglePlayPause();
}

- (void)floatingDockDidTapNext:(M27FloatingDock *)dock {
    (void)dock;
    M27NextTrack();
}

- (void)floatingDockDidTapNowPlaying:(M27FloatingDock *)dock {
    (void)dock;
    UIViewController *miniVC = M27FindMiniPlayerViewController(self.tabBarController);
    UIView *mini = miniVC.view;
    if (!mini) return;
    CGPoint point = CGPointMake(CGRectGetMidX(mini.bounds), CGRectGetMidY(mini.bounds));
    UIView *target = [mini hitTest:point withEvent:nil] ?: mini;
    if ([target isKindOfClass:UIControl.class]) {
        [(UIControl *)target sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

- (void)floatingDockDidChangeMode:(M27FloatingDock *)dock {
    M27LayoutDock(self.tabBarController, dock);
}

- (void)syncNowPlaying {
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    NSString *title = info[MPMediaItemPropertyTitle];
    NSString *artist = info[MPMediaItemPropertyArtist];
    UIImage *art = nil;
    id artwork = info[MPMediaItemPropertyArtwork];
    if ([artwork isKindOfClass:MPMediaItemArtwork.class]) {
        art = [(MPMediaItemArtwork *)artwork imageWithSize:CGSizeMake(120, 120)];
    }
    self.dock.trackTitle = title;
    self.dock.artistName = artist;
    self.dock.artwork = art;

    BOOL playing = (MPMusicPlayerController.systemMusicPlayer.playbackState == MPMusicPlaybackStatePlaying);
    id rate = info[@"playbackRate"];
    if ([rate respondsToSelector:@selector(doubleValue)]) {
        playing = [rate doubleValue] > 0.01;
    }
    self.dock.playing = playing;
    self.dock.selectedTabIndex = (NSInteger)self.tabBarController.selectedIndex;
    [self.dock refreshChrome];
}

@end

#pragma mark - MiniPlayerViewController (SwiftPeek name, read-only)

static UIViewController *M27FindMiniPlayerInController(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 6) return nil;
    if (M27ClassNameHasSuffix(vc, @"MiniPlayerViewController")) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *hit = M27FindMiniPlayerInController(child, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UIViewController *M27FindMiniPlayerViewController(UITabBarController *tbc) {
    if (!tbc) return nil;
    UIViewController *hit = M27FindMiniPlayerInController(tbc, 0);
    if (hit) return hit;
    if (tbc.parentViewController) {
        hit = M27FindMiniPlayerInController(tbc.parentViewController, 0);
        if (hit) return hit;
    }
    return nil;
}

#pragma mark - Dock install / layout (dedicated overlay window)

static M27DockController *M27ControllerForTabBarController(UITabBarController *tbc) {
    M27DockController *controller = objc_getAssociatedObject(tbc, kM27DockControllerKey);
    if (!controller) {
        controller = [M27DockController new];
        controller.tabBarController = tbc;
        objc_setAssociatedObject(tbc, kM27DockControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return controller;
}

static M27FloatingDock *M27DockForTabBarController(UITabBarController *tbc) {
    if (!tbc) return nil;
    return objc_getAssociatedObject(tbc, kM27DockViewKey);
}

static UIWindowScene *M27SceneForTabBarController(UITabBarController *tbc) {
    if (@available(iOS 13.0, *)) {
        UIWindow *host = tbc.view.window;
        if (host.windowScene) return host.windowScene;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static UITabBarController *M27MusicTabBarController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            // Skip our own overlay.
            if ([window isKindOfClass:M27DockOverlayWindow.class]) continue;
            UIViewController *root = window.rootViewController;
            if ([root isKindOfClass:UITabBarController.class]) {
                return (UITabBarController *)root;
            }
            if (root.tabBarController) return root.tabBarController;
            for (UIViewController *child in root.childViewControllers) {
                if ([child isKindOfClass:UITabBarController.class]) {
                    return (UITabBarController *)child;
                }
            }
        }
    }
    return nil;
}

static void M27SweepLegacyDockSubviews(void) {
    // Remove any dock that older builds left on Music's own windows / tbc.view.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window isKindOfClass:M27DockOverlayWindow.class]) continue;
            for (UIView *sub in window.subviews.copy) {
                if (sub.tag == kM27DockTag) [sub removeFromSuperview];
            }
            UIViewController *root = window.rootViewController;
            if (root.isViewLoaded) {
                for (UIView *sub in root.view.subviews.copy) {
                    if (sub.tag == kM27DockTag) [sub removeFromSuperview];
                }
            }
            if ([root isKindOfClass:UITabBarController.class]) {
                UITabBarController *tbc = (UITabBarController *)root;
                tbc.tabBar.alpha = 1.0;
                tbc.tabBar.userInteractionEnabled = YES;
                tbc.tabBar.hidden = NO;
            }
        }
    }
}

/// Undo soft-hides from 1.1.13–1.1.16. 1.1.17 covers chrome from the overlay
/// instead of mutating Music views.
static void M27RestoreStockChromeIfNeeded(UITabBarController *tbc) {
    if (!tbc.isViewLoaded) return;
    UITabBar *bar = tbc.tabBar;
    bar.alpha = 1.0;
    bar.userInteractionEnabled = YES;
    bar.hidden = NO;

    @try {
        id tabsVC = [tbc valueForKey:@"tabsViewController"];
        if ([tabsVC isKindOfClass:UIViewController.class]) {
            UIView *v = ((UIViewController *)tabsVC).view;
            if (v) {
                v.alpha = 1.0;
                v.userInteractionEnabled = YES;
            }
        }
    } @catch (__unused NSException *ex) {}

    UIViewController *miniVC = M27FindMiniPlayerViewController(tbc);
    if (miniVC.isViewLoaded && M27ClassNameHasSuffix(miniVC, @"MiniPlayerViewController")) {
        UIView *mini = miniVC.view;
        if (mini) {
            mini.alpha = 1.0;
            mini.userInteractionEnabled = YES;
        }
    }
}

static CGFloat M27SafeBottomInset(UITabBarController *tbc, UIWindow *overlay) {
    CGFloat safeBottom = overlay.safeAreaInsets.bottom;
    if (safeBottom < 1.0 && tbc.isViewLoaded) {
        safeBottom = tbc.view.safeAreaInsets.bottom;
    }
    if (safeBottom < 1.0) {
        UIWindow *musicWindow = tbc.view.window;
        if (musicWindow) safeBottom = musicWindow.safeAreaInsets.bottom;
    }
    if (safeBottom < 1.0) safeBottom = 34.0;
    return safeBottom;
}

static CGRect M27ScreenBounds(UITabBarController *tbc) {
    CGRect screen = UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(screen) && tbc.isViewLoaded && tbc.view.window) {
        screen = tbc.view.window.bounds;
    }
    if (CGRectIsEmpty(screen)) {
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = M27SceneForTabBarController(tbc);
            if (scene) screen = scene.coordinateSpace.bounds;
        }
    }
    return screen;
}

/// Tear down leftover solid cover plates from 1.1.17–1.1.19.
static void M27StripLegacyCoverViews(UIView *host) {
    if (!host) return;
    for (UIView *sub in host.subviews.copy) {
        if (sub.tag == kM27CoverTag) [sub removeFromSuperview];
    }
}

/// The one level proven good on-device. See the header note: a full-screen
/// window at StatusBar-1 blanks Music on 17.3 even when nothing is drawn in it,
/// and Normal+10 never composited. Normal+2 is what 1.1.12–1.1.16 shipped with a
/// visible dock and a usable Library. Do not raise this without a device test.
static UIWindowLevel M27OverlayWindowLevel(void) {
    return UIWindowLevelNormal + 2.0;
}

static M27DockOverlayWindow *M27EnsureOverlayWindow(UITabBarController *tbc) {
    M27DockOverlayWindow *overlay = objc_getAssociatedObject(tbc, kM27DockWindowKey);
    CGRect screen = M27ScreenBounds(tbc);

    if (overlay) {
        overlay.windowLevel = M27OverlayWindowLevel();
        overlay.hidden = NO;
        return overlay;
    }

    UIWindowScene *scene = M27SceneForTabBarController(tbc);
    // Full-screen from the start — the dock pill is the only thing that paints.
    CGRect seed = screen;
    if (CGRectIsEmpty(seed)) seed = CGRectMake(0, 0, 320, 568);

    if (scene) {
        overlay = [[M27DockOverlayWindow alloc] initWithWindowScene:scene];
        overlay.frame = seed;
    } else {
        overlay = [[M27DockOverlayWindow alloc] initWithFrame:seed];
    }
    overlay.windowLevel = M27OverlayWindowLevel();
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.userInteractionEnabled = YES;
    overlay.hidden = NO;

    UIViewController *root = [UIViewController new];
    M27PassthroughView *pass = [[M27PassthroughView alloc] initWithFrame:overlay.bounds];
    pass.backgroundColor = UIColor.clearColor;
    pass.opaque = NO;
    pass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.view = pass;
    overlay.rootViewController = root;

    objc_setAssociatedObject(tbc, kM27DockWindowKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[Music27 1.1.22] overlay window created level=%.1f frame=%@ iOS=%ld",
          overlay.windowLevel, NSStringFromCGRect(overlay.frame), (long)M27SystemMajorVersion());
    return overlay;
}

static void M27LayoutDock(UITabBarController *tbc, M27FloatingDock *dock) {
    if (!tbc || !dock) return;
    if (objc_getAssociatedObject(tbc, kM27LayoutGuardKey)) return;
    objc_setAssociatedObject(tbc, kM27LayoutGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        M27DockOverlayWindow *overlay = M27EnsureOverlayWindow(tbc);
        if (!overlay) return;

        CGRect screen = M27ScreenBounds(tbc);
        CGFloat screenW = CGRectGetWidth(screen);
        CGFloat screenH = CGRectGetHeight(screen);
        if (screenW < 10 || screenH < 10) {
            NSLog(@"[Music27 1.1.22] layout skip: empty screen bounds");
            return;
        }

        CGFloat height = dock.preferredHeight;
        if (height < 10 || height > 160.0) {
            height = 52.0 + 8.0 + 58.0;
            NSLog(@"[Music27 1.1.22] preferredHeight out of range → fallback %.0f", height);
        }

        CGFloat safeBottom = M27SafeBottomInset(tbc, overlay);
        CGFloat floatGap = M27FloatGap();

        // Full-screen and fully clear except for the dock. Full-screen is fine —
        // 1.1.12 shipped it. It is the LEVEL that blanks Music when raised.
        CGRect overlayFrame = CGRectMake(0, 0, screenW, screenH);
        if (!CGRectEqualToRect(overlay.frame, overlayFrame)) {
            overlay.frame = overlayFrame;
        }
        overlay.windowLevel = M27OverlayWindowLevel();
        overlay.hidden = NO;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.opaque = NO;

        UIView *host = overlay.rootViewController.view;
        if (!host) {
            NSLog(@"[Music27 1.1.22] layout skip: no host view");
            return;
        }
        host.frame = overlay.bounds;
        host.backgroundColor = UIColor.clearColor;
        host.opaque = NO;
        // Any plate left behind by 1.1.17–1.1.19 is what blanked Library.
        M27StripLegacyCoverViews(host);

        if (dock.superview != host) {
            [host addSubview:dock];
        }
        [host bringSubviewToFront:dock];

        // Float above the home indicator, measured from the bottom of the screen.
        CGFloat y = screenH - safeBottom - floatGap - height;
        y = MAX(0, y);
        CGRect frame = CGRectMake(0, y, screenW, height);
        if (!CGRectEqualToRect(dock.frame, frame)) {
            dock.frame = frame;
        }
        dock.hidden = NO;
        dock.alpha = 1.0;
        dock.userInteractionEnabled = YES;
        dock.backgroundColor = UIColor.clearColor;
        [dock setNeedsLayout];
        [dock layoutIfNeeded];

        NSLog(@"[Music27 1.1.22] layout iOS=%ld screen=%.0fx%.0f dockY=%.0f dockH=%.0f "
              @"safeB=%.0f gap=%.0f level=%.1f hidden=%d host=%@",
              (long)M27SystemMajorVersion(), screenW, screenH, y, height, safeBottom,
              floatGap, overlay.windowLevel, (int)overlay.hidden,
              NSStringFromCGRect(host.frame));

        M27RestoreStockChromeIfNeeded(tbc);
    } @finally {
        objc_setAssociatedObject(tbc, kM27LayoutGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void M27RemoveDock(UITabBarController *tbc) {
    M27FloatingDock *dock = M27DockForTabBarController(tbc);
    [dock removeFromSuperview];
    objc_setAssociatedObject(tbc, kM27DockViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    M27RestoreStockChromeIfNeeded(tbc);

    M27DockOverlayWindow *overlay = objc_getAssociatedObject(tbc, kM27DockWindowKey);
    if (overlay) {
        UIView *host = overlay.rootViewController.view;
        M27StripLegacyCoverViews(host);
        overlay.hidden = YES;
        overlay.rootViewController = nil;
        objc_setAssociatedObject(tbc, kM27DockWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    M27SweepLegacyDockSubviews();

    // Tear down any leftover overlay windows from prior installs.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows.copy) {
            if ([window isKindOfClass:M27DockOverlayWindow.class]) {
                window.hidden = YES;
                window.rootViewController = nil;
            }
        }
    }
}

static void M27InstallDockIfNeeded(UITabBarController *tbc) {
    if (!tbc) {
        NSLog(@"[Music27 1.1.22] install skip: nil tbc");
        return;
    }
    if (!tbc.isViewLoaded) {
        NSLog(@"[Music27 1.1.22] install skip: tbc not loaded");
        return;
    }
    M27Prefs *prefs = M27Prefs.shared;

    if (!(prefs.enabled && prefs.glassTabBarEnabled)) {
        NSLog(@"[Music27 1.1.22] install skip: prefs en=%d dock=%d",
              (int)prefs.enabled, (int)prefs.glassTabBarEnabled);
        M27RemoveDock(tbc);
        return;
    }

    @try {
        // Never mutate Music chrome. No solid cover. Bottom-strip overlay only.
        M27SweepLegacyDockSubviews();
        M27RestoreStockChromeIfNeeded(tbc);

        M27DockController *controller = M27ControllerForTabBarController(tbc);
        M27FloatingDock *dock = M27DockForTabBarController(tbc);
        if (!dock) {
            dock = [[M27FloatingDock alloc] initWithFrame:CGRectZero];
            dock.tag = kM27DockTag;
            dock.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
            dock.backgroundColor = UIColor.clearColor;
            objc_setAssociatedObject(tbc, kM27DockViewKey, dock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [dock reloadTabs];
            [dock setMode:M27DockModeExpanded animated:NO];
            NSLog(@"[Music27 1.1.22] dock view created");
        }
        dock.delegate = controller;
        controller.dock = dock;
        [dock reloadTabs];
        [dock setMode:M27DockModeExpanded animated:NO];
        dock.selectedTabIndex = (NSInteger)tbc.selectedIndex;
        [controller syncNowPlaying];
        M27LayoutDock(tbc, dock);
        NSLog(@"[Music27 1.1.22] install OK dock=%p overlay=%p",
              dock, objc_getAssociatedObject(tbc, kM27DockWindowKey));
    } @catch (NSException *ex) {
        NSLog(@"[Music27 1.1.22] install exception: %@", ex);
        M27RemoveDock(tbc);
    }
}

static void M27HandleScrollOffset(UIScrollView *scrollView) {
    if (!scrollView.isDragging && !scrollView.isDecelerating) return;
    if (fabs(scrollView.contentOffset.x) > fabs(scrollView.contentOffset.y)) return;
    if (scrollView.contentOffset.y < kM27ScrollCollapseY) return;

    // Collapse the overlay dock only — never mutate scroll hosts / Library.
    UITabBarController *tbc = M27MusicTabBarController();
    if (!tbc) return;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    M27FloatingDock *dock = M27DockForTabBarController(tbc);
    if (!dock || dock.mode == M27DockModeCollapsed) return;
    [dock collapseFromScroll];
}

void M27ApplyChromeForCurrentPrefs(void) {
    [M27Prefs.shared reload];
    UITabBarController *tbc = M27MusicTabBarController();
    if (tbc) {
        M27InstallDockIfNeeded(tbc);
    } else {
        M27SweepLegacyDockSubviews();
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows.copy) {
                if ([window isKindOfClass:M27DockOverlayWindow.class]) {
                    window.hidden = YES;
                    window.rootViewController = nil;
                }
                for (UIView *sub in window.subviews.copy) {
                    if (sub.tag == kM27DockTag) [sub removeFromSuperview];
                }
            }
        }
    }

    M27Prefs *prefs = M27Prefs.shared;
    BOOL stripAll = !prefs.enabled;
    BOOL stripPins = stripAll || !prefs.libraryPinsEnabled;
    BOOL stripAlbum = stripAll || !prefs.glassTabBarEnabled;
    BOOL stripTheme = stripAll || !prefs.colorThemeEnabled;

    if (!(stripAll || stripPins || stripAlbum || stripTheme)) return;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window isKindOfClass:M27DockOverlayWindow.class]) {
                if (stripAll || !prefs.glassTabBarEnabled) {
                    window.hidden = YES;
                }
                continue;
            }
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
            while (stack.count) {
                UIView *view = stack.lastObject;
                [stack removeLastObject];
                if (stripAll && view.tag == kM27DockTag) {
                    [view removeFromSuperview];
                    continue;
                }
                if (stripAlbum && view.tag == 0x4D324143) { // M2AC
                    [view removeFromSuperview];
                    continue;
                }
                if (stripPins && view.tag == 0x4D323750) { // M27P
                    [view removeFromSuperview];
                    continue;
                }
                if (stripTheme) {
                    for (CALayer *layer in view.layer.sublayers.copy) {
                        if ([layer.name isEqualToString:@"M27Wash"]) {
                            [layer removeFromSuperlayer];
                        }
                    }
                }
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
}

#pragma mark - Hooks

%hook UITabBarController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    __weak UITabBarController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[Music27 1.1.22] TBC viewDidAppear");
        M27InstallDockIfNeeded(weakSelf);
    });
    // One delayed retry — Music finishes chrome layout after first appear.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        M27InstallDockIfNeeded(weakSelf);
    });
}

- (void)viewDidLayoutSubviews {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    M27FloatingDock *dock = M27DockForTabBarController(self);
    if (dock) {
        M27LayoutDock(self, dock);
    } else {
        M27InstallDockIfNeeded(self);
    }
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    %orig;
    M27FloatingDock *dock = M27DockForTabBarController(self);
    if (dock) dock.selectedTabIndex = (NSInteger)selectedIndex;
}

- (void)setSelectedViewController:(UIViewController *)selectedViewController {
    %orig;
    M27FloatingDock *dock = M27DockForTabBarController(self);
    if (dock) dock.selectedTabIndex = (NSInteger)self.selectedIndex;
}

%end

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    if ([self isKindOfClass:M27DockOverlayWindow.class]) return;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    UIViewController *root = self.rootViewController;
    if (!root) return;
    UITabBarController *tbc = nil;
    if ([root isKindOfClass:UITabBarController.class]) {
        tbc = (UITabBarController *)root;
    } else if (root.tabBarController) {
        tbc = root.tabBarController;
    } else {
        for (UIViewController *child in root.childViewControllers) {
            if ([child isKindOfClass:UITabBarController.class]) {
                tbc = (UITabBarController *)child;
                break;
            }
        }
    }
    if (!tbc) return;
    __weak UITabBarController *weakTBC = tbc;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[Music27 1.1.22] UIWindow makeKeyAndVisible → install");
        M27InstallDockIfNeeded(weakTBC);
    });
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    if (!self.isDragging && !self.isDecelerating) return;
    static NSTimeInterval last = 0;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - last < 0.15) return;
    last = now;
    M27HandleScrollOffset(self);
}

%end

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITabBarController *tbc = M27MusicTabBarController();
        if (!tbc) return;
        M27DockController *controller = objc_getAssociatedObject(tbc, kM27DockControllerKey);
        [controller syncNowPlaying];
    });
}

%end
