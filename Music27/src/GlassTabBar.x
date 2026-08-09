#import "Music27.h"
#import "M27FloatingDock.h"
#import "M27GlassChrome.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Floating Liquid Glass dock for Music.
//
// NEVER MAKE THE OVERLAY WINDOW FULL-SCREEN.
//
// Device results on iPhone13,1 / iOS 17.3 Dopamine, dock ON:
//
//   1.1.19   full-screen   StatusBar-1   plate      WHITE SCREEN
//   1.1.20   bottom strip  Normal+10     no plate   no white screen; nothing painted
//   1.1.21   full-screen   StatusBar-1   NO plate   WHITE SCREEN
//   1.1.22   full-screen   Normal+2      no plate   WHITE SCREEN
//
// Three full-screen builds at two very different levels, with and without a
// cover plate, all blanked Music. The only build that did NOT blank it is the
// only one whose window was a bottom strip. Size is the variable; level is not,
// and neither is the plate. 1.1.19-1.1.22 each blamed one of those instead.
//
// A SwiftPeek 0.4.1 dump (dock OFF) also confirms Music's own window sits at
// level 0 with nothing above it, so "Normal+2 is too low to composite" was never
// true either.
//
// 1.1.24 (this build):
// - The overlay window is a BOTTOM STRIP: dock height + float gap + safe area,
//   hard-capped at 30% of the screen so it can never grow toward full-screen.
// - Created at its real strip size. 1.1.20 seeded a 1pt-tall window and resized
//   it afterwards and never painted; that seed is gone.
// - Dock coordinates are strip-relative, not screen-relative.
// - Level stays Normal+2. Music's window is at 0, so this is above it.
// - No cover plate. Never mutate MiniPlayer/Library/tabBar.
// - M27WriteStatus records the strip frame and a full_screen flag on every
//   layout, so a regression back to full-screen is visible from Filza.

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

#pragma mark - On-device status (1.1.23+)

/// The install path used to report itself only through NSLog, which needs a Mac
/// with Console attached. This writes the same facts to disk so the phone can
/// answer on its own — which is how the strip-vs-full-screen result above was
/// finally pinned down instead of guessed at.
void M27WriteStatus(NSString *stage, NSDictionary *info) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.music27.status", DISPATCH_QUEUE_SERIAL);
    });

    NSMutableDictionary *entry = [info mutableCopy] ?: [NSMutableDictionary dictionary];
    entry[@"stage"] = stage ?: @"?";
    entry[@"version"] = @"1.1.24";
    entry[@"ios"] = UIDevice.currentDevice.systemVersion ?: @"?";

    dispatch_async(queue, ^{
        @try {
            NSString *dir = [M27JailbreakRoot() ?: @""
                             stringByAppendingString:@"/var/mobile/Library/Music27"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];

            NSISO8601DateFormatter *fmt = [NSISO8601DateFormatter new];
            NSString *ts = [fmt stringFromDate:NSDate.date] ?: @"";
            entry[@"timestamp"] = ts;

            // status.json is the latest state; status.log keeps the sequence,
            // which is what shows a dock being installed and then torn down.
            NSData *json = [NSJSONSerialization dataWithJSONObject:entry
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:nil];
            if (json) {
                [json writeToFile:[dir stringByAppendingPathComponent:@"status.json"]
                          options:NSDataWritingAtomic error:nil];
            }

            NSMutableArray *parts = [NSMutableArray array];
            for (NSString *key in [entry.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                if ([key isEqualToString:@"timestamp"]) continue;
                [parts addObject:[NSString stringWithFormat:@"%@=%@", key, entry[key]]];
            }
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", ts,
                              [parts componentsJoinedByString:@" "]];
            NSString *logPath = [dir stringByAppendingPathComponent:@"status.log"];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (fh) {
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                } @finally {
                    [fh closeFile];
                }
            } else {
                [line writeToFile:logPath atomically:YES
                         encoding:NSUTF8StringEncoding error:nil];
            }
        } @catch (__unused NSException *ex) {}
    });
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

// The strip still spans the full width, so every pixel that is not a dock pill
// must fall through to Music or the area above the home indicator eats taps.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

// Music must keep key-window status — the keyboard, first responder and status
// bar style all follow the key window, and an overlay stealing it is one more
// way an app ends up looking blank.
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

static UIWindowLevel M27OverlayWindowLevel(void) {
    return UIWindowLevelNormal + 2.0;
}

/// Height of the bottom strip the overlay window occupies.
///
/// THE OVERLAY MUST NEVER BE FULL-SCREEN. Every full-screen build white-screened
/// Music on 17.3 regardless of level — StatusBar-1 (1.1.19, 1.1.21) and Normal+2
/// (1.1.22) alike, with and without a cover plate. The single build that did not
/// blank Music was 1.1.20, the only one whose window was a bottom strip. Size,
/// not level, is the variable.
static CGFloat M27StripHeight(CGFloat dockHeight, CGFloat safeBottom, CGFloat screenH) {
    CGFloat h = dockHeight + M27FloatGap() + safeBottom;
    // Never let a rounding or safe-area surprise grow this toward full-screen.
    CGFloat cap = MAX(120.0, screenH * 0.30);
    return MIN(h, cap);
}

static CGRect M27StripFrame(CGRect screen, CGFloat dockHeight, CGFloat safeBottom) {
    CGFloat screenH = CGRectGetHeight(screen);
    CGFloat h = M27StripHeight(dockHeight, safeBottom, screenH);
    return CGRectMake(0, screenH - h, CGRectGetWidth(screen), h);
}

static M27DockOverlayWindow *M27EnsureOverlayWindow(UITabBarController *tbc, CGRect stripFrame) {
    M27DockOverlayWindow *overlay = objc_getAssociatedObject(tbc, kM27DockWindowKey);

    if (overlay) {
        overlay.windowLevel = M27OverlayWindowLevel();
        overlay.hidden = NO;
        return overlay;
    }

    UIWindowScene *scene = M27SceneForTabBarController(tbc);
    // Created at its real strip size. 1.1.20 seeded a 1pt-tall window and resized
    // it afterwards, and that build never painted — so do not repeat the seed.
    CGRect seed = stripFrame;
    if (CGRectIsEmpty(seed) || seed.size.height < 10.0) {
        seed = CGRectMake(0, 0, 320, 166);
    }

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
    NSLog(@"[Music27 1.1.24] overlay window created level=%.1f frame=%@ iOS=%ld",
          overlay.windowLevel, NSStringFromCGRect(overlay.frame), (long)M27SystemMajorVersion());
    return overlay;
}

static void M27LayoutDock(UITabBarController *tbc, M27FloatingDock *dock) {
    if (!tbc || !dock) return;
    if (objc_getAssociatedObject(tbc, kM27LayoutGuardKey)) return;
    objc_setAssociatedObject(tbc, kM27LayoutGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        CGRect screen = M27ScreenBounds(tbc);
        CGFloat screenW = CGRectGetWidth(screen);
        CGFloat screenH = CGRectGetHeight(screen);
        if (screenW < 10 || screenH < 10) {
            NSLog(@"[Music27 1.1.24] layout skip: empty screen bounds");
            M27WriteStatus(@"layout_skip_bounds", @{});
            return;
        }

        CGFloat height = dock.preferredHeight;
        if (height < 10 || height > 160.0) {
            height = 52.0 + 8.0 + 58.0;
            NSLog(@"[Music27 1.1.24] preferredHeight out of range → fallback %.0f", height);
        }

        // Safe-area read before the window exists, so the strip can be created at
        // its real size rather than seeded small and resized (the 1.1.20 mistake).
        CGFloat safeBottom = M27SafeBottomInset(tbc, nil);
        CGFloat floatGap = M27FloatGap();
        CGRect stripFrame = M27StripFrame(screen, height, safeBottom);

        M27DockOverlayWindow *overlay = M27EnsureOverlayWindow(tbc, stripFrame);
        if (!overlay) return;

        // Re-read now that the window exists; its own safeAreaInsets are the
        // authoritative ones. Recompute the strip if that changed anything.
        CGFloat safeBottom2 = M27SafeBottomInset(tbc, overlay);
        if (fabs(safeBottom2 - safeBottom) > 0.5) {
            safeBottom = safeBottom2;
            stripFrame = M27StripFrame(screen, height, safeBottom);
        }

        if (!CGRectEqualToRect(overlay.frame, stripFrame)) {
            overlay.frame = stripFrame;
        }
        overlay.windowLevel = M27OverlayWindowLevel();
        overlay.hidden = NO;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.opaque = NO;

        UIView *host = overlay.rootViewController.view;
        if (!host) {
            NSLog(@"[Music27 1.1.24] layout skip: no host view");
            M27WriteStatus(@"layout_skip_no_host", @{});
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

        // Dock coordinates are strip-relative now, not screen-relative. Sit it at
        // the top of the strip; the home-indicator gap below stays passthrough.
        CGFloat stripH = CGRectGetHeight(stripFrame);
        CGFloat y = MAX(0.0, stripH - safeBottom - height);
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

        NSLog(@"[Music27 1.1.24] layout iOS=%ld screen=%.0fx%.0f strip=%@ dockY=%.0f "
              @"dockH=%.0f safeB=%.0f gap=%.0f level=%.1f hidden=%d",
              (long)M27SystemMajorVersion(), screenW, screenH,
              NSStringFromCGRect(stripFrame), y, height, safeBottom,
              floatGap, overlay.windowLevel, (int)overlay.hidden);
        M27WriteStatus(@"layout", @{
            @"strip": NSStringFromCGRect(stripFrame),
            @"screen": NSStringFromCGSize(CGSizeMake(screenW, screenH)),
            @"dock_frame": NSStringFromCGRect(dock.frame),
            @"safe_bottom": @((double)safeBottom),
            @"level": @((double)overlay.windowLevel),
            @"full_screen": @(CGRectGetHeight(stripFrame) >= screenH - 1.0),
        });

        M27RestoreStockChromeIfNeeded(tbc);
    } @finally {
        objc_setAssociatedObject(tbc, kM27LayoutGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void M27RemoveDock(UITabBarController *tbc) {
    M27FloatingDock *dock = M27DockForTabBarController(tbc);
    // Logged because "installed, then silently torn down" and "never installed"
    // look identical from outside, and we cannot yet tell them apart.
    M27WriteStatus(@"remove_dock", @{ @"had_dock": dock ? @"yes" : @"no" });
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
        NSLog(@"[Music27 1.1.24] install skip: nil tbc");
        M27WriteStatus(@"install_skip_nil_tbc", @{});
        return;
    }
    if (!tbc.isViewLoaded) {
        NSLog(@"[Music27 1.1.24] install skip: tbc not loaded");
        M27WriteStatus(@"install_skip_tbc_unloaded", @{});
        return;
    }
    M27Prefs *prefs = M27Prefs.shared;

    if (!(prefs.enabled && prefs.glassTabBarEnabled)) {
        NSLog(@"[Music27 1.1.24] install skip: prefs en=%d dock=%d",
              (int)prefs.enabled, (int)prefs.glassTabBarEnabled);
        M27WriteStatus(@"install_skip_prefs", @{
            @"enabled": @(prefs.enabled),
            @"glassTabBar": @(prefs.glassTabBarEnabled),
        });
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
            NSLog(@"[Music27 1.1.24] dock view created");
        }
        dock.delegate = controller;
        controller.dock = dock;
        [dock reloadTabs];
        [dock setMode:M27DockModeExpanded animated:NO];
        dock.selectedTabIndex = (NSInteger)tbc.selectedIndex;
        [controller syncNowPlaying];
        M27LayoutDock(tbc, dock);
        M27DockOverlayWindow *ov = objc_getAssociatedObject(tbc, kM27DockWindowKey);
        NSLog(@"[Music27 1.1.24] install OK dock=%p overlay=%p", dock, ov);
        M27WriteStatus(@"install_ok", @{
            @"overlay": ov ? @"yes" : @"no",
            @"overlay_level": @(ov ? (double)ov.windowLevel : -1.0),
            @"overlay_hidden": @(ov ? ov.hidden : YES),
            @"overlay_frame": NSStringFromCGRect(ov ? ov.frame : CGRectZero),
            @"dock_frame": NSStringFromCGRect(dock.frame),
            @"dock_hidden": @(dock.hidden),
            @"dock_alpha": @((double)dock.alpha),
            @"dock_superview": dock.superview ? @"yes" : @"no",
            @"tabs": @((long)tbc.viewControllers.count),
        });
    } @catch (NSException *ex) {
        NSLog(@"[Music27 1.1.24] install exception: %@", ex);
        M27WriteStatus(@"install_exception", @{ @"reason": ex.reason ?: @"?" });
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
        NSLog(@"[Music27 1.1.24] TBC viewDidAppear");
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
        NSLog(@"[Music27 1.1.24] UIWindow makeKeyAndVisible → install");
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
