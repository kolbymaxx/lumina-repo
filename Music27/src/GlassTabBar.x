#import "Music27.h"
#import "M27FloatingDock.h"
#import "M27GlassChrome.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Floating Liquid Glass dock for Music.
//
// 1.1.17 (cover, don't mutate):
// - Soft-hiding Music tab/mini views failed or crashed. Stop touching them.
// - Paint a COVER on our overlay over the stock chrome zone, then float dual
//   glass pills on top. Music's hierarchy is never mutated.
//
// 1.1.18 (make cover + dock actually visible on device):
// - 1.1.17 looked 100% stock for some users: overlay level too low and/or
//   UIVisualEffect cover failed to paint in a secondary window.
// - Solid dark cover UIView (always paints), windowLevel = StatusBar-1,
//   bottomPad = safeBottom+12, force screen bounds, retry install, NSLogs.

static const NSInteger kM27DockTag = 0x4D323744; // 'M27D'
static const NSInteger kM27CoverTag = 0x4D32434F; // 'M2CO'
static const CGFloat kM27ScrollCollapseY = 48.0;
static const CGFloat kM27FloatGap = 12.0;
static const void *kM27DockControllerKey = &kM27DockControllerKey;
static const void *kM27DockViewKey = &kM27DockViewKey;
static const void *kM27DockWindowKey = &kM27DockWindowKey;
static const void *kM27CoverViewKey = &kM27CoverViewKey;
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
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
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

static UIView *M27EnsureCoverView(UIView *host) {
    UIView *cover = objc_getAssociatedObject(host, kM27CoverViewKey);
    if (cover) return cover;

    // Solid UIView — UIVisualEffect covers in secondary windows can paint
    // nothing on some devices; solid always proves the overlay is alive.
    UIView *plate = [[UIView alloc] initWithFrame:CGRectZero];
    plate.tag = kM27CoverTag;
    plate.userInteractionEnabled = YES; // absorb taps so stock chrome underneath isn't used
    plate.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    plate.opaque = YES;
    [host insertSubview:plate atIndex:0];
    objc_setAssociatedObject(host, kM27CoverViewKey, plate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[Music27 1.1.18] cover view created");
    return plate;
}

static M27DockOverlayWindow *M27EnsureOverlayWindow(UITabBarController *tbc) {
    M27DockOverlayWindow *overlay = objc_getAssociatedObject(tbc, kM27DockWindowKey);
    CGRect screen = UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(screen)) {
        screen = tbc.view.window.bounds;
    }

    if (overlay) {
        // Keep alive + on top across layout passes.
        if (!CGRectIsEmpty(screen) && !CGRectEqualToRect(overlay.frame, screen)) {
            overlay.frame = screen;
        }
        overlay.windowLevel = UIWindowLevelStatusBar - 1.0;
        overlay.hidden = NO;
        return overlay;
    }

    UIWindowScene *scene = M27SceneForTabBarController(tbc);
    if (scene) {
        overlay = [[M27DockOverlayWindow alloc] initWithWindowScene:scene];
        CGRect sceneBounds = scene.coordinateSpace.bounds;
        overlay.frame = CGRectIsEmpty(sceneBounds) ? screen : sceneBounds;
    } else {
        overlay = [[M27DockOverlayWindow alloc] initWithFrame:screen];
    }
    // Above Music chrome (Normal+2 was under stock mini/tab for some users).
    overlay.windowLevel = UIWindowLevelStatusBar - 1.0;
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
    NSLog(@"[Music27 1.1.18] overlay window created level=%.1f frame=%.0fx%.0f",
          overlay.windowLevel, overlay.bounds.size.width, overlay.bounds.size.height);
    return overlay;
}

static void M27LayoutDock(UITabBarController *tbc, M27FloatingDock *dock) {
    if (!tbc || !dock) return;
    if (objc_getAssociatedObject(tbc, kM27LayoutGuardKey)) return;
    objc_setAssociatedObject(tbc, kM27LayoutGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        M27DockOverlayWindow *overlay = M27EnsureOverlayWindow(tbc);
        if (!overlay) return;

        // Prefer full screen bounds — scene coordinates can be empty early.
        CGRect targetBounds = UIScreen.mainScreen.bounds;
        if (CGRectIsEmpty(targetBounds) && overlay.windowScene) {
            targetBounds = overlay.windowScene.coordinateSpace.bounds;
        }
        if (CGRectIsEmpty(targetBounds) && tbc.isViewLoaded && tbc.view.window) {
            targetBounds = tbc.view.window.bounds;
        }
        if (!CGRectIsEmpty(targetBounds) && !CGRectEqualToRect(overlay.frame, targetBounds)) {
            overlay.frame = targetBounds;
        }
        overlay.windowLevel = UIWindowLevelStatusBar - 1.0;
        overlay.hidden = NO;

        CGFloat width = overlay.bounds.size.width;
        CGFloat hostH = overlay.bounds.size.height;
        if (width < 10 || hostH < 10) {
            NSLog(@"[Music27 1.1.18] layout skip: empty overlay bounds");
            return;
        }

        CGFloat height = dock.preferredHeight;
        // Hard cap — a full-screen dock frame would cover Library hosts.
        // Don't bail silently: fall back so cover + pills still appear.
        if (height < 10 || height > 160.0) {
            height = 52.0 + 8.0 + 58.0; // expanded mini + gap + tabs
            NSLog(@"[Music27 1.1.18] preferredHeight out of range → fallback %.0f", height);
        }

        UIView *host = overlay.rootViewController.view;
        if (!host) {
            NSLog(@"[Music27 1.1.18] layout skip: no host view");
            return;
        }
        host.frame = overlay.bounds;

        UIView *cover = M27EnsureCoverView(host);
        if (dock.superview != host) {
            [host addSubview:dock];
        }
        [host insertSubview:cover atIndex:0];
        [host bringSubviewToFront:dock];

        CGFloat safeBottom = overlay.safeAreaInsets.bottom;
        if (safeBottom < 1.0 && tbc.isViewLoaded) {
            safeBottom = tbc.view.safeAreaInsets.bottom;
        }
        if (safeBottom < 1.0) {
            UIWindow *musicWindow = tbc.view.window;
            if (musicWindow) safeBottom = musicWindow.safeAreaInsets.bottom;
        }
        if (safeBottom < 1.0) safeBottom = 34.0; // iPhone X home-indicator floor

        // Cover stock mini (~64) + tab bar (~49) + home indicator zone.
        // Never mutate those Music views — just paint over them.
        CGFloat coverH = safeBottom + 49.0 + 64.0 + 16.0;
        coverH = MAX(coverH, height + kM27FloatGap + safeBottom);
        coverH = MIN(coverH, hostH * 0.42); // never cover most of Library
        CGRect coverFrame = CGRectMake(0, hostH - coverH, width, coverH);
        if (!CGRectEqualToRect(cover.frame, coverFrame)) {
            cover.frame = coverFrame;
        }
        cover.hidden = NO;
        cover.alpha = 1.0;

        // Real float: gap above the home indicator, not glued to the bezel.
        CGFloat bottomPad = safeBottom + kM27FloatGap;
        CGFloat y = hostH - height - bottomPad;
        if (y < CGRectGetMinY(coverFrame) + 6.0) {
            y = CGRectGetMinY(coverFrame) + 6.0;
        }
        CGRect frame = CGRectMake(0, y, width, height);
        if (!CGRectEqualToRect(dock.frame, frame)) {
            dock.frame = frame;
        }
        dock.hidden = NO;
        dock.alpha = 1.0;
        dock.userInteractionEnabled = YES;
        dock.backgroundColor = UIColor.clearColor;
        [dock setNeedsLayout];
        [dock layoutIfNeeded];

        NSLog(@"[Music27 1.1.18] layout screen=%.0fx%.0f coverH=%.0f safeB=%.0f dockY=%.0f dockH=%.0f",
              width, hostH, coverH, safeBottom, y, height);

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
        UIView *cover = objc_getAssociatedObject(host, kM27CoverViewKey);
        [cover removeFromSuperview];
        objc_setAssociatedObject(host, kM27CoverViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *sub in host.subviews.copy) {
            if (sub.tag == kM27CoverTag) [sub removeFromSuperview];
        }
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
        NSLog(@"[Music27 1.1.18] install skip: nil tbc");
        return;
    }
    if (!tbc.isViewLoaded) {
        NSLog(@"[Music27 1.1.18] install skip: tbc not loaded");
        return;
    }
    M27Prefs *prefs = M27Prefs.shared;

    if (!(prefs.enabled && prefs.glassTabBarEnabled)) {
        NSLog(@"[Music27 1.1.18] install skip: prefs en=%d dock=%d",
              (int)prefs.enabled, (int)prefs.glassTabBarEnabled);
        M27RemoveDock(tbc);
        return;
    }

    @try {
        // Never mutate Music chrome — cover from overlay only.
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
            NSLog(@"[Music27 1.1.18] dock view created");
        }
        dock.delegate = controller;
        controller.dock = dock;
        // Always expanded dual-pill on install; reload tabs every time so icons
        // appear after Music finishes populating viewControllers.
        [dock reloadTabs];
        [dock setMode:M27DockModeExpanded animated:NO];
        dock.selectedTabIndex = (NSInteger)tbc.selectedIndex;
        [controller syncNowPlaying];
        M27LayoutDock(tbc, dock);
        NSLog(@"[Music27 1.1.18] install OK dock=%p overlay=%p",
              dock, objc_getAssociatedObject(tbc, kM27DockWindowKey));
    } @catch (NSException *ex) {
        NSLog(@"[Music27 1.1.18] install exception: %@", ex);
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
        NSLog(@"[Music27 1.1.18] TBC viewDidAppear");
        M27InstallDockIfNeeded(weakSelf);
    });
    // Delayed retries — Music finishes chrome layout after first appear.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        M27InstallDockIfNeeded(weakSelf);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
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
        NSLog(@"[Music27 1.1.18] UIWindow makeKeyAndVisible → install");
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
