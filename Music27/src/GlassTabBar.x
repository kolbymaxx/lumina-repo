#import "Music27.h"
#import "M27FloatingDock.h"
#import "M27GlassChrome.h"
#import "SPKOverlayWindow.h"
#import "SPKRuntime.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Floating Liquid Glass dock for Music.
//
// READ THIS BEFORE THEORISING ABOUT THE OVERLAY WINDOW.
//
// 1.1.19 through 1.1.24 all assumed the "white screen" on iOS 17.3 was a
// compositing problem and blamed, in turn: the cover plate, the window level,
// Music's own window level, and the window's size. Each theory was built from
// what the screen looked like, because nothing could observe what the code did.
//
// It was none of them. Music was crashing during install, and a dead app draws
// a blank white (or black, in dark mode) window. Every window property those
// builds adjusted belongs to code that never executed.
//
// 1.1.26: THE CRASH IS MPMusicPlayerController, NOT THE OVERLAY WINDOW.
//
// 1.1.25's synchronous log, three consecutive launches on 17.3 with dock ON:
//
//   install_begin tabs=5 -> dock_created h=118 -> (process gone)
//
// layout_begin never fires, so M27LayoutDock is never entered and the overlay
// window is never created. Every window theory from 1.1.19 onward was aimed at
// code that does not run. The white screen was Music dying at install.
//
// The only statement in that span not already executed before dock_created is
// syncNowPlaying, which called MPMusicPlayerController.systemMusicPlayer — an
// IPC client for Music, called from inside Music. That is now gone; playbackRate
// from nowPlayingInfo gives the same answer with no IPC. Per-statement
// breadcrumbs remain so the next log names the faulting call if this is wrong.
//
// 1.1.24 (strip behaviour, unchanged here):
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
/// How long a scroll must be underway, and how far it must travel, before the
/// dock collapses. Both must hold — a timer alone lets a slow nudge through, a
/// distance alone lets a flick through.
static const NSTimeInterval kM27ScrollCollapseDelay = 0.45;
static const CGFloat kM27ScrollCollapseDistance = 90.0;
/// A gap this long means a new scroll, so the timer restarts rather than
/// treating a fresh flick as the continuation of an old one.
static const NSTimeInterval kM27ScrollIdleReset = 0.9;
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

#pragma mark - On-device status (1.1.23+, synchronous since 1.1.25)

/// SYNCHRONOUS ON PURPOSE.
///
/// 1.1.24 queued these writes with dispatch_async. On the 17.3 run with the dock
/// ON, status.log showed `loaded` and then nothing at all — no install_ok, no
/// install_exception, no layout. Every branch past the prefs check writes
/// something, so the only way to get silence is for the process to die before
/// the queue drained. An async logger loses precisely the line that explains a
/// crash, which makes it useless for the one job it exists to do.
///
/// So: write inline, on the calling thread, before returning. Callers pair a
/// `_begin` line with a result line, so a missing result now pins the crash to a
/// known span instead of erasing the whole attempt.
///
/// Cost is a small append on the main thread. `layout` is deduped by content so
/// repeated identical layouts do not hammer the disk.
///
/// The implementation now lives in SPKit as SPKTrace, unchanged in behaviour —
/// same synchronous append, same fsync, same per-stage dedup. This wrapper keeps
/// the name every Music27 call site already uses.
void M27WriteStatus(NSString *stage, NSDictionary *info) {
    // %ctor configures tracing before any hook can run, but a %ctor ordering
    // surprise must not silently drop the log that explains it.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SPKTraceConfigure(@"Music27", M27VersionString);
        // Layout runs on every viewDidLayoutSubviews; only record real changes.
        SPKTraceDedupeStage(@"layout");
    });
    SPKTrace(stage, info);
}

/// Set while Music's full-screen player is on screen. The dock lives in its own
/// window, so nothing in the app's presentation takes it away — and layout runs
/// constantly, so without this every relayout would pop the pills back over the
/// player a frame after they were hidden.
static BOOL gM27FullPlayerUp = NO;

static const void *kM27DockControllerKey = &kM27DockControllerKey;
static const void *kM27DockViewKey = &kM27DockViewKey;
static const void *kM27DockWindowKey = &kM27DockWindowKey;
static const void *kM27LayoutGuardKey = &kM27LayoutGuardKey;

#pragma mark - Passthrough overlay window

/// All the behaviour — passthrough hit-testing, never becoming key, sizing at
/// creation — now lives in SPKOverlayWindow. Eight builds of hard-won rules,
/// written down once instead of per tweak.
///
/// This stays a distinct subclass purely for identity. Music27 tears down and
/// skips over "its" overlay by class, and SwiftPeek or CC27 may have their own
/// SPKOverlayWindow in the same process — those must not match.
@interface M27DockOverlayWindow : SPKOverlayWindow
@end

@implementation M27DockOverlayWindow
@end

#pragma mark - MediaRemote (soft-linked)

// Music does NOT publish through MPNowPlayingInfoCenter. Every build from
// 1.1.24 onward logged `sync_info keys=0` — an empty dictionary — because that
// API is how an app *publishes* its state, and Music uses MediaRemote instead.
// Read back from inside Music it will always be empty, which is why the dock
// showed "Not Playing" with no artwork and never updated.
//
// MediaRemote is the right source and is already proven safe in this process:
// the dock's play/pause and skip run through MRMediaRemoteSendCommand.
typedef void (*M27MRSendCommandFunc)(unsigned int command, CFDictionaryRef options);
typedef void (*M27MRGetNowPlayingInfoFunc)(dispatch_queue_t queue,
                                           void (^handler)(CFDictionaryRef info));
typedef void (*M27MRRegisterNotificationsFunc)(dispatch_queue_t queue);

static void *M27MediaRemoteHandle(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                        RTLD_LAZY);
    });
    return handle;
}

static M27MRSendCommandFunc M27MRSendCommand(void) {
    static M27MRSendCommandFunc fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = M27MediaRemoteHandle();
        if (h) fn = (M27MRSendCommandFunc)dlsym(h, "MRMediaRemoteSendCommand");
    });
    return fn;
}

static M27MRGetNowPlayingInfoFunc M27MRGetNowPlayingInfo(void) {
    static M27MRGetNowPlayingInfoFunc fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = M27MediaRemoteHandle();
        if (h) fn = (M27MRGetNowPlayingInfoFunc)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    });
    return fn;
}

static M27MRRegisterNotificationsFunc M27MRRegisterNotifications(void) {
    static M27MRRegisterNotificationsFunc fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = M27MediaRemoteHandle();
        if (h) fn = (M27MRRegisterNotificationsFunc)
                    dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    });
    return fn;
}

// MediaRemote's dictionary keys are these literal strings.
static NSString *const kM27MRTitle = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kM27MRArtist = @"kMRMediaRemoteNowPlayingInfoArtist";
static NSString *const kM27MRArtworkData = @"kMRMediaRemoteNowPlayingInfoArtworkData";
static NSString *const kM27MRPlaybackRate = @"kMRMediaRemoteNowPlayingInfoPlaybackRate";

static void M27TogglePlayPause(void) {
    M27MRSendCommandFunc send = M27MRSendCommand();
    if (send) {
        send(2, NULL);
        return;
    }
    // No MPMusicPlayerController fallback: it is an IPC client for Music and we
    // are inside Music. If MediaRemote is unavailable, do nothing rather than
    // risk the same crash that killed install (see syncNowPlaying).
    M27WriteStatus(@"playpause_no_mediaremote", @{});
}

static void M27NextTrack(void) {
    M27MRSendCommandFunc send = M27MRSendCommand();
    if (send) {
        send(4, NULL);
        return;
    }
    M27WriteStatus(@"next_no_mediaremote", @{});
}

#pragma mark - Dock controller bridge

@class M27DockController;

static void M27LayoutDock(UITabBarController *tbc, M27FloatingDock *dock);
static UIViewController *M27FindMiniPlayerViewController(UITabBarController *tbc);
/// Hide / restore without touching alpha — see the definitions below for why
/// `layer.opacity` is not an option. Declared here because the chrome restore
/// path is defined earlier in the file than the helpers themselves.
static void M27MaskOutView(UIView *view);
static void M27UnmaskView(UIView *view);

@interface M27DockController : NSObject <M27FloatingDockDelegate>
@property (nonatomic, weak) UITabBarController *tabBarController;
@property (nonatomic, weak) M27FloatingDock *dock;
/// Real viewControllers indices that actually own a tab — Music 17 has one more
/// controller than tabs, so dock index N is not viewControllers[N].
- (NSArray<NSNumber *> *)visibleTabIndexes;
/// Push the tab bar controller's selection into the dock, index-mapped.
- (void)syncSelection;
- (void)syncNowPlaying;
- (void)beginObservingNowPlaying;
@end

@implementation M27DockController

/// Real `viewControllers` indices that actually have a tab.
///
/// Music on iOS 17 reports SIX view controllers but shows FIVE tabs — the log
/// line `install_begin tabs=6` next to a dock rendering a stray "Tab 5" is that
/// extra controller, which carries no tab bar item. Indices must therefore be
/// mapped: dock index N is not necessarily viewControllers[N].
- (NSArray<NSNumber *> *)visibleTabIndexes {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    UITabBarController *tbc = self.tabBarController;
    NSArray<__kindof UIViewController *> *vcs = tbc.viewControllers;
    NSArray<UITabBarItem *> *items = tbc.tabBar.items;
    for (NSInteger i = 0; i < (NSInteger)vcs.count; i++) {
        UITabBarItem *item = vcs[i].tabBarItem;
        if (!item) continue;
        // Authoritative when available: the bar itself knows what it displays.
        if (items.count > 0 && ![items containsObject:item]) continue;
        if (item.title.length == 0 && item.image == nil) continue;
        [out addObject:@(i)];
    }
    // Never leave the dock empty just because the matching heuristics failed.
    if (out.count == 0) {
        for (NSInteger i = 0; i < (NSInteger)vcs.count; i++) [out addObject:@(i)];
    }
    return out;
}

- (NSInteger)realIndexForDockIndex:(NSInteger)dockIndex {
    NSArray<NSNumber *> *visible = [self visibleTabIndexes];
    if (dockIndex < 0 || dockIndex >= (NSInteger)visible.count) return NSNotFound;
    return visible[dockIndex].integerValue;
}

- (NSInteger)dockIndexForRealIndex:(NSInteger)realIndex {
    NSArray<NSNumber *> *visible = [self visibleTabIndexes];
    NSInteger at = (NSInteger)[visible indexOfObject:@(realIndex)];
    return at == NSNotFound ? 0 : at;
}

/// Pushes the tab bar controller's current selection into the dock, mapped.
- (void)syncSelection {
    self.dock.selectedTabIndex =
        [self dockIndexForRealIndex:(NSInteger)self.tabBarController.selectedIndex];
}

- (UIViewController *)viewControllerForDockIndex:(NSInteger)index {
    NSInteger real = [self realIndexForDockIndex:index];
    NSArray<__kindof UIViewController *> *vcs = self.tabBarController.viewControllers;
    if (real == NSNotFound || real >= (NSInteger)vcs.count) return nil;
    return vcs[real];
}

- (NSInteger)numberOfTabsForFloatingDock:(M27FloatingDock *)dock {
    (void)dock;
    return (NSInteger)[self visibleTabIndexes].count;
}

- (NSString *)floatingDock:(M27FloatingDock *)dock titleForTabIndex:(NSInteger)index {
    (void)dock;
    return [self viewControllerForDockIndex:index].tabBarItem.title;
}

- (UIImage *)floatingDock:(M27FloatingDock *)dock iconForTabIndex:(NSInteger)index selected:(BOOL)selected {
    (void)dock;
    UITabBarItem *item = [self viewControllerForDockIndex:index].tabBarItem;
    if (!item) return nil;
    return selected && item.selectedImage ? item.selectedImage : item.image;
}

- (void)floatingDock:(M27FloatingDock *)dock didSelectTabIndex:(NSInteger)index {
    (void)dock;
    NSInteger real = [self realIndexForDockIndex:index];
    if (real == NSNotFound) return;
    self.tabBarController.selectedIndex = (NSUInteger)real;
}

- (void)floatingDockDidTapSearch:(M27FloatingDock *)dock {
    (void)dock;
    NSArray<NSNumber *> *visible = [self visibleTabIndexes];
    NSArray<__kindof UIViewController *> *vcs = self.tabBarController.viewControllers;
    NSInteger dockIndex = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)visible.count; i++) {
        NSInteger real = visible[i].integerValue;
        if (real >= (NSInteger)vcs.count) continue;
        NSString *title = vcs[real].tabBarItem.title.lowercaseString ?: @"";
        if ([title containsString:@"search"]) {
            dockIndex = i;
            break;
        }
    }
    if (dockIndex == NSNotFound && visible.count > 0) {
        dockIndex = (NSInteger)visible.count - 1;
    }
    if (dockIndex == NSNotFound) return;
    NSInteger real = [self realIndexForDockIndex:dockIndex];
    if (real == NSNotFound) return;
    self.tabBarController.selectedIndex = (NSUInteger)real;
    self.dock.selectedTabIndex = dockIndex;
}

- (void)floatingDockDidTapPlayPause:(M27FloatingDock *)dock {
    (void)dock;
    M27TogglePlayPause();
}

- (void)floatingDockDidTapNext:(M27FloatingDock *)dock {
    (void)dock;
    M27NextTrack();
}

/// First UIControl anywhere under `view`, breadth-first, depth-capped.
/// Fallback for when hitTest finds nothing useful — Music's mini player wraps
/// its tap target differently across versions.
// THE CONTROL SEARCH IS GONE, AND SO IS ITS PLAUSIBILITY FILTER.
//
// "Find the first UIControl in this subtree and fire it" produced two wrong
// buttons in two builds:
//
//   1.1.37  NowPlayingShuffleButton   {{-28, 14}, {28, 28}}   toggled shuffle
//   1.1.38  NowPlayingTransportButton {{0, 17.7}, {21, 21}}   played/paused
//
// 1.1.38 added a filter rejecting off-screen, hidden, transparent and
// zero-sized controls. It worked exactly as designed — and the search simply
// returned the next candidate, which was play/pause. That is the tell: the mini
// player owns playPauseButton, skipButton, reverseButton, shuffleButton,
// repeatButton and handoffButton, and not one of them opens the player.
// Expanding is a gesture. No filter can rescue a search for something that is
// not there, so both the search and its filter are deleted rather than tuned
// again.

/// Every tap/long-press recogniser on `view` and its ancestors, nearest first.
static NSArray<UIGestureRecognizer *> *M27TapGesturesNear(UIView *view, NSInteger levels) {
    NSMutableArray<UIGestureRecognizer *> *found = [NSMutableArray array];
    UIView *node = view;
    for (NSInteger i = 0; node && i <= levels; i++, node = node.superview) {
        for (UIGestureRecognizer *gr in node.gestureRecognizers) {
            if (!gr.isEnabled) continue;
            if ([gr isKindOfClass:UITapGestureRecognizer.class]) [found addObject:gr];
        }
    }
    return found;
}

// THE GESTURE-FIRING PATH IS GONE.
//
// It read UIGestureRecognizer's private `_targets`, pulled `_target` and
// `_action` out of each entry by raw ivar offset, and performSelector'd the
// result. That is undefined behaviour the moment a firmware lays those ivars
// out differently, and iOS 17.3 is a strong suspect for the crash reported when
// tapping the collapsed pill's artwork: the last breadcrumb before the process
// died was a layout line, meaning it never reached nowplaying_begin — so it
// died during touch delivery, before the handler ran.
//
// It also never once worked. On 16.7 it resolved and called Music's real
// handler (PalettePresentationInteraction.tapGestureRecognized:) and the player
// stayed shut, because that handler checks gr.state and the recogniser sits in
// .possible. On 17.3 it resolved nothing at all.
//
// Zero demonstrated value, non-zero chance of being the crash. The passthrough
// in 1.1.43 is what actually opens the player, and it is confirmed working.

/// Selectors on `obj`'s class chain that look like they present Now Playing.
///
/// Recon, not action. If the gesture path below also comes back empty, this line
/// names what to call next instead of leaving another round to guesswork.
static NSString *M27PresentationSelectors(NSObject *obj) {
    if (!obj) return @"-";
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    Class cls = object_getClass(obj);
    for (NSInteger depth = 0; cls && depth < 4; depth++, cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        if (!methods) continue;
        for (unsigned int i = 0; i < count && names.count < 12; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            // `palette` is here because the 16.7 log named the mechanism:
            // MusicApplication.PalettePresentationInteraction. Music calls the
            // full player the "palette", so that is the word its presenter will
            // be spelled with.
            if ([lower containsString:@"nowplaying"] || [lower containsString:@"expand"] ||
                [lower containsString:@"handoff"] || [lower containsString:@"presentplayer"] ||
                [lower containsString:@"palette"]) {
                if (![names containsObject:name]) [names addObject:name];
            }
        }
        free(methods);
    }
    return names.count ? [names componentsJoinedByString:@","] : @"none";
}

- (void)floatingDockDidTapNowPlaying:(M27FloatingDock *)dock {
    (void)dock;
    // 1.1.33 wrote NO nowplaying_* line at all, and that was read as "the tap
    // never arrives". It could not answer that: the success branch below logged
    // nothing, so a tap that found a control and fired it looked exactly like a
    // tap that never happened. Same silent-branch mistake as the 1.1.23 async
    // logger. Entry and every exit are recorded now.
    M27WriteStatus(@"nowplaying_begin", @{});

    UIViewController *miniVC = M27FindMiniPlayerViewController(self.tabBarController);
    UIView *mini = miniVC.view;
    if (!mini) {
        M27WriteStatus(@"nowplaying_no_mini", @{});
        return;
    }

    // The mini player is deliberately non-interactive while the dock is up, and
    // hitTest: refuses views with userInteractionEnabled == NO. Lift it only for
    // the duration of this lookup so stray taps still cannot reach it.
    BOOL wasInteractive = mini.userInteractionEnabled;
    mini.userInteractionEnabled = YES;

    BOOL activated = NO;
    @try {
        activated = [mini accessibilityActivate];
    } @catch (__unused NSException *ex) {}
    if (activated) {
        M27WriteStatus(@"nowplaying_activated", @{ @"via": @"accessibility_root" });
        mini.userInteractionEnabled = wasInteractive;
        return;
    }

    // This path only runs when the passthrough declined to hand the touch over,
    // which in practice means the collapsed dock — its pill sits below Music's
    // mini player, so there is nothing underneath to receive the tap.
    //
    // Nothing here synthesises an action any more. Reading a recogniser's
    // private targets and performSelector'ing them was removed after the 17.3
    // crash report; see the note where that function used to live.
    NSArray<UIGestureRecognizer *> *taps = M27TapGesturesNear(mini, 3);

    UIView *target = nil;
    @try {
        CGPoint point = CGPointMake(CGRectGetMidX(mini.bounds), CGRectGetMidY(mini.bounds));
        target = [mini hitTest:point withEvent:nil];
    } @catch (__unused NSException *ex) {}

    if (target && target != mini) {
        @try {
            activated = [target accessibilityActivate];
        } @catch (__unused NSException *ex) {}
        if (activated) {
            M27WriteStatus(@"nowplaying_activated", @{
                @"via": @"accessibility_hit",
                @"target": @(object_getClassName(target)),
            });
            mini.userInteractionEnabled = wasInteractive;
            return;
        }
    }

    // NO CONTROL FALLBACK. FIRING ANY BUTTON HERE IS WRONG BY CONSTRUCTION.
    //
    // Two builds, two different wrong buttons:
    //
    //   1.1.37  NowPlayingShuffleButton   {{-28, 14}, {28, 28}}   → toggled shuffle
    //   1.1.38  NowPlayingTransportButton {{0, 17.7}, {21, 21}}   → played/paused
    //
    // 1.1.38 rejected the off-screen one and simply found the next candidate,
    // which was play/pause. That is the tell: the mini player has no control
    // that expands it, so "find a control and fire it" cannot ever be right,
    // and every refinement of the search just picks a different wrong button.
    // Doing nothing is strictly better than performing an action the user did
    // not ask for.
    //
    // It also cost a round of evidence. The recon below only ran when no control
    // was found, and a control was always found, so the gesture inventory this
    // was supposed to collect never got written. Diagnostics must not sit behind
    // the success of the thing they are diagnosing.
    NSMutableArray<NSString *> *grDesc = [NSMutableArray array];
    for (UIGestureRecognizer *gr in taps) {
        [grDesc addObject:[NSString stringWithFormat:@"%@@%@",
                           NSStringFromClass(gr.class),
                           gr.view ? NSStringFromClass(gr.view.class) : @"?"]];
        if (grDesc.count >= 6) break;
    }
    M27WriteStatus(@"nowplaying_no_control", @{
        @"target": target ? @(object_getClassName(target)) : @"nil",
        @"mini": @(object_getClassName(mini)),
        @"tap_gestures": @((long)taps.count),
        @"gestures": grDesc.count ? [grDesc componentsJoinedByString:@" "] : @"none",
        @"mini_sels": M27PresentationSelectors(miniVC),
        @"parent_sels": M27PresentationSelectors(miniVC.parentViewController),
        @"tbc_sels": M27PresentationSelectors(self.tabBarController),
        @"mini_super": mini.superview ? @(object_getClassName(mini.superview)) : @"nil",
        // 1.1.39's target=nil needs explaining: a zero bounds, a hidden view or
        // a cleared alpha all make hitTest refuse, and they are not the same bug.
        @"mini_bounds": NSStringFromCGRect(mini.bounds),
        @"mini_alpha": @((double)mini.alpha),
        @"mini_opacity": @((double)mini.layer.opacity),
        @"mini_hidden": mini.hidden ? @"yes" : @"no",
        @"fire_detail": why.length ? why : @"-",
    });

    mini.userInteractionEnabled = wasInteractive;
}

/// Decline the touch when Music's own mini player is underneath it.
///
/// This is the fix for four builds of trying to open the full player by
/// synthesising an action. There is no button to press — the mini player owns
/// playPauseButton, skipButton, reverseButton, shuffleButton, repeatButton and
/// handoffButton, and none of them expands it — and firing "some control" only
/// ever picked a different wrong one.
///
/// But Music's real mini player has been sitting under the glass pill the whole
/// time. The dock hides it with `layer.opacity = 0`, which makes it invisible
/// while leaving it perfectly hit-testable, so a touch that reaches it opens the
/// player natively, with Music's own animation and the lyrics screen. That is
/// almost certainly what happened when the player "popped up by accident" —
/// a tap landed just outside the pill and hit the real thing.
///
/// So the geometry is checked rather than assumed: pass the touch through only
/// where the stock mini player actually is. Anywhere else the dock keeps it, so
/// a stray tap can never fall through to whatever else is down there.
- (BOOL)floatingDock:(M27FloatingDock *)dock shouldPassThroughPoint:(CGPoint)point {
    UIViewController *miniVC = M27FindMiniPlayerViewController(self.tabBarController);
    UIView *mini = miniVC.view;
    if (!mini || mini.hidden || !mini.window) return NO;

    // BOTH RECTS MUST BE IN SCREEN COORDINATES.
    //
    // 1.1.41 compared them in "window" coordinates and always got inside=no:
    //
    //   mini_window={{0, 665}, {375, 64}}   tap_window={51, 30.7}   inside=no
    //
    // `convertRect:toView:nil` stops at the *receiver's own* window, and the
    // dock deliberately lives in a separate overlay UIWindow from Music. So
    // that compared a strip-relative y of 30 against Music's screen-absolute
    // 665 — two different origins, and no tap could ever match.
    //
    // Converting both through `convertRect:toWindow:nil` puts them on the
    // screen. The overlap is real once it is measured in one space: with a
    // track playing the pill occupies roughly screen 660–712 and Music's mini
    // player 665–729.
    UIWindow *miniWindow = mini.window;
    UIWindow *dockWindow = dock.window;
    if (!miniWindow || !dockWindow) return NO;

    CGRect miniOnScreen = [miniWindow convertRect:[mini convertRect:mini.bounds toView:nil]
                                         toWindow:nil];
    if (CGRectIsEmpty(miniOnScreen)) return NO;

    CGPoint tapOnScreen = [dockWindow convertPoint:[dock convertPoint:point toView:nil]
                                          toWindow:nil];
    BOOL inside = CGRectContainsPoint(miniOnScreen, tapOnScreen);

    // A handful of lines rather than one: the single 1.1.41 line happened to be
    // logged while the dock was still in its no-track layout, which made the
    // numbers look far more wrong than they were.
    static NSInteger logged = 0;
    if (logged < 4) {
        logged++;
        M27WriteStatus(@"passthrough_geometry", @{
            @"mini_screen": NSStringFromCGRect(miniOnScreen),
            @"dock_screen": NSStringFromCGRect(
                [dockWindow convertRect:[dock convertRect:dock.bounds toView:nil]
                               toWindow:nil]),
            @"tap_screen": NSStringFromCGPoint(tapOnScreen),
            @"inside": inside ? @"yes" : @"no",
            @"mini_alpha": @((double)mini.alpha),
            @"mini_opacity": @((double)mini.layer.opacity),
        });
    }
    return inside;
}

- (void)floatingDockDidChangeMode:(M27FloatingDock *)dock {
    M27LayoutDock(self.tabBarController, dock);
}

/// Collect up to two non-empty label strings and the first real image under
/// `view`. Fallback for when MediaRemote returns nothing — the stock mini
/// player already has the data rendered in it, and SwiftPeek confirmed those
/// labels are readable (it dumped "Gypsy" / "Lady Gaga" from this very view).
static void M27CollectMiniLabels(UIView *view, NSInteger depth,
                                 NSMutableArray<UILabel *> *labels, UIImage **image) {
    if (!view || depth > 5) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)sub;
            if (label.text.length) [labels addObject:label];
        } else if ([sub isKindOfClass:UIImageView.class] && !*image) {
            UIImage *img = ((UIImageView *)sub).image;
            if (img && img.size.width > 8.0) *image = img;
        }
        M27CollectMiniLabels(sub, depth + 1, labels, image);
    }
}

/// Pick title and artist out of the stock mini player's labels.
///
/// Taking the first two in subview order gave "iPhone / KISS" on device —
/// "iPhone" is the AirPlay route label, which happens to come first in the
/// hierarchy. SwiftPeek's dump of MiniPlayerViewController showed the same
/// three-string shape: ["Gypsy", "Lady Gaga", "iPhone"].
///
/// Title and artist are the two largest labels; between those two, the title
/// sits above the artist.
static void M27ScrapeMiniPlayer(UIView *view, NSInteger depth,
                                NSMutableArray<NSString *> *texts, UIImage **image) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    M27CollectMiniLabels(view, depth, labels, image);
    if (labels.count == 0) return;

    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGFloat fa = a.font.pointSize, fb = b.font.pointSize;
        if (fa > fb) return NSOrderedAscending;
        if (fa < fb) return NSOrderedDescending;
        CGFloat ya = a.frame.origin.y, yb = b.frame.origin.y;
        if (ya < yb) return NSOrderedAscending;
        if (ya > yb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSArray<UILabel *> *top = labels.count > 2
        ? [labels subarrayWithRange:NSMakeRange(0, 2)] : labels;
    NSArray<UILabel *> *ordered = [top sortedArrayUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        if (a.frame.origin.y < b.frame.origin.y) return NSOrderedAscending;
        if (a.frame.origin.y > b.frame.origin.y) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (UILabel *label in ordered) {
        if (label.text.length && ![texts containsObject:label.text]) [texts addObject:label.text];
    }
}

#pragma mark - Last played track

// iOS 27 does not empty the pill when nothing is playing — open Music fresh and
// it shows the last song you played, paused. 1.1.37 dropped the pill instead,
// which fixed the "Loading…" placeholder but replaced it with the wrong
// behaviour. The placeholder was never the point; showing Music's internal
// loading text as if it were a song was.
//
// So remember the last real track across launches and fall back to it.

static NSString *M27LastTrackPath(void) {
    return SPKRootedPath(@"/var/mobile/Library/Music27/lasttrack.plist");
}

static void M27SaveLastTrack(NSString *title, NSString *artist, UIImage *artwork) {
    if (!title.length) return;

    // syncNowPlaying runs on every MediaRemote notification; only touch the disk
    // when the track actually changed.
    static NSString *lastSaved = nil;
    NSString *key = [NSString stringWithFormat:@"%@\n%@", title, artist ?: @""];
    if ([key isEqualToString:lastSaved]) return;
    lastSaved = [key copy];

    @try {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"title"] = title;
        if (artist.length) entry[@"artist"] = artist;
        if (artwork) {
            NSData *jpeg = UIImageJPEGRepresentation(artwork, 0.8);
            // Cap it — this is a convenience cache, not an artwork library.
            if (jpeg.length > 0 && jpeg.length < 512 * 1024) entry[@"artwork"] = jpeg;
        }
        NSString *path = M27LastTrackPath();
        [NSFileManager.defaultManager
            createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil];
        [entry writeToFile:path atomically:YES];
    } @catch (__unused NSException *ex) {}
}

static NSDictionary *M27LoadLastTrack(void) {
    static NSDictionary *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            cached = [NSDictionary dictionaryWithContentsOfFile:M27LastTrackPath()];
        } @catch (__unused NSException *ex) {}
    });
    return cached;
}

/// NEVER touch MPMusicPlayerController from here — it is an IPC client for the
/// Music app and this code runs inside Music. That is what crashed install
/// until 1.1.26.
- (void)applyNowPlayingInfo:(NSDictionary *)info {
    if (info.count > 0) {
        NSString *title = info[kM27MRTitle];
        NSString *artist = info[kM27MRArtist];
        if (title.length) self.dock.trackTitle = title;
        if (artist.length) self.dock.artistName = artist;

        @try {
            NSData *art = info[kM27MRArtworkData];
            if ([art isKindOfClass:NSData.class] && art.length) {
                UIImage *image = [UIImage imageWithData:art];
                if (image) self.dock.artwork = image;
            }
        } @catch (__unused NSException *ex) {}

        id rate = info[kM27MRPlaybackRate];
        self.dock.playing = [rate respondsToSelector:@selector(doubleValue)]
                          ? ([rate doubleValue] > 0.01) : NO;
        if (title.length) {
            self.dock.hasTrack = YES;
            M27SaveLastTrack(title, artist, self.dock.artwork);
        }
        M27WriteStatus(@"sync_applied", @{
            @"src": @"mediaremote",
            @"title": title.length ? @"yes" : @"no",
            @"artwork": self.dock.artwork ? @"yes" : @"no",
            @"has_track": self.dock.hasTrack ? @"yes" : @"no",
        });
    } else {
        UIViewController *miniVC = M27FindMiniPlayerViewController(self.tabBarController);
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        UIImage *image = nil;
        if (miniVC.isViewLoaded) M27ScrapeMiniPlayer(miniVC.view, 0, texts, &image);

        // ONE LABEL MEANS MUSIC'S OWN PLACEHOLDER, NOT A TRACK.
        //
        // 1.1.33's log named the "weird loading thing" exactly:
        //
        //   src=scrape texts=1 title=Not Playing
        //   src=scrape texts=1 title=Loading…
        //
        // Those are Music's placeholder strings, scraped out of the stock mini
        // player and rendered in our pill as though they were a song. Every real
        // track in that log arrived through MediaRemote with a title; every
        // placeholder was a scrape with a single label and no artist.
        //
        // So require both lines. Matching the strings themselves would only work
        // in English, and a title-shaped guess is what put "iPhone" — the AirPlay
        // route label — in the pill back in 1.1.32.
        BOOL scraped = (texts.count > 1);
        NSString *source = @"scrape";
        if (scraped) {
            self.dock.trackTitle = texts[0];
            self.dock.artistName = texts[1];
            if (image) self.dock.artwork = image;
            self.dock.hasTrack = YES;
            M27SaveLastTrack(texts[0], texts[1], image);
        }
        // Whatever is shown, nothing is actually playing on this path.
        self.dock.playing = NO;

        M27WriteStatus(@"sync_applied", @{
            @"src": source,
            @"texts": @((long)texts.count),
            @"title": texts.count > 0 ? texts[0] : (self.dock.trackTitle ?: @"-"),
            @"artist": texts.count > 1 ? texts[1] : @"-",
            @"artwork": self.dock.artwork ? @"yes" : @"no",
            @"has_track": self.dock.hasTrack ? @"yes" : @"no",
        });
    }

    // Still nothing to show — from either path, including MediaRemote answering
    // with a dictionary that has no title. Fall back to the last real track,
    // paused. This is what iOS 27 does on a fresh launch, and it is why 1.1.37's
    // "drop the pill" was the wrong correction: the placeholder text was the
    // bug, not the pill.
    if (!self.dock.hasTrack) {
        NSDictionary *last = M27LoadLastTrack();
        id lastTitle = last[@"title"];
        if ([lastTitle isKindOfClass:NSString.class] && [lastTitle length]) {
            self.dock.trackTitle = lastTitle;
            id lastArtist = last[@"artist"];
            self.dock.artistName = [lastArtist isKindOfClass:NSString.class] ? lastArtist : nil;
            id jpeg = last[@"artwork"];
            if ([jpeg isKindOfClass:NSData.class]) {
                UIImage *restored = [UIImage imageWithData:(NSData *)jpeg];
                if (restored) self.dock.artwork = restored;
            }
            self.dock.playing = NO;
            self.dock.hasTrack = YES;
            M27WriteStatus(@"sync_last_track", @{ @"title": lastTitle });
        }
    }

    [self syncSelection];
    [self.dock refreshChrome];
    M27WriteStatus(@"sync_done", @{});
}

- (void)syncNowPlaying {
    M27WriteStatus(@"sync_begin", @{});

    M27MRGetNowPlayingInfoFunc get = M27MRGetNowPlayingInfo();
    if (!get) {
        M27WriteStatus(@"sync_no_mediaremote", @{});
        [self applyNowPlayingInfo:@{}];
        return;
    }

    __weak typeof(self) weakSelf = self;
    @try {
        get(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
            NSDictionary *info = raw ? [(__bridge NSDictionary *)raw copy] : nil;
            M27WriteStatus(@"sync_info", @{ @"keys": @((long)info.count) });
            [weakSelf applyNowPlayingInfo:info ?: @{}];
        });
    } @catch (NSException *ex) {
        M27WriteStatus(@"sync_exception", @{ @"reason": ex.reason ?: @"?" });
        [self applyNowPlayingInfo:@{}];
    }
}

/// The old refresh trigger was a hook on `MPNowPlayingInfoCenter
/// setNowPlayingInfo:` — which Music never calls, so the dock's text never
/// changed after the first layout. MediaRemote posts these instead.
- (void)beginObservingNowPlaying {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        M27MRRegisterNotificationsFunc reg = M27MRRegisterNotifications();
        if (reg) reg(dispatch_get_main_queue());
    });
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" ]) {
        [nc removeObserver:self name:name object:nil];
        [nc addObserver:self selector:@selector(nowPlayingChanged:) name:name object:nil];
    }
}

- (void)nowPlayingChanged:(NSNotification *)note {
    (void)note;
    [self syncNowPlaying];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
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
    return [SPKOverlayWindow sceneForView:tbc.view];
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
    bar.layer.opacity = 1.0;
    bar.userInteractionEnabled = YES;
    bar.hidden = NO;

    @try {
        id tabsVC = [tbc valueForKey:@"tabsViewController"];
        if ([tabsVC isKindOfClass:UIViewController.class]) {
            UIView *v = ((UIViewController *)tabsVC).view;
            if (v) {
                v.alpha = 1.0;
                v.layer.opacity = 1.0;
                v.userInteractionEnabled = YES;
            }
        }
    } @catch (__unused NSException *ex) {}

    for (UIView *sub in tbc.view.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"PaletteContainerView"]) {
            sub.layer.opacity = 1.0;
            M27UnmaskView(sub);
        }
    }

    UIViewController *miniVC = M27FindMiniPlayerViewController(tbc);
    if (miniVC.isViewLoaded && M27ClassNameHasSuffix(miniVC, @"MiniPlayerViewController")) {
        UIView *mini = miniVC.view;
        if (mini) {
            mini.alpha = 1.0;
            mini.layer.opacity = 1.0;
            M27UnmaskView(mini);
            mini.userInteractionEnabled = YES;
        }
    }
}

/// Fade Music's own tab bar and mini player so the glass pills are not a second
/// copy of chrome that is already on screen.
///
/// `layer.opacity` only — never `hidden`, never `alpha`, never removed, never a
/// safe-area change. Music's layout is untouched and this is fully reversible.
/// Using `alpha` would also make the views un-hit-testable, which is what broke
/// the dock's Now Playing tap in 1.1.28.
///
/// 1.1.14 attributed a black/crash regression to fading the MiniPlayer view. That
/// build also carried the MPMusicPlayerController call that 1.1.26 proved was
/// crashing Music, so the attribution is suspect — but it is not disproven
/// either, hence the separate `hideStockChrome` pref.
/// Hide a view without making it un-hit-testable.
///
/// The whole point: an empty CALayer mask has no opaque pixels, so the view
/// renders nothing — but `alpha` is untouched, `hidden` stays NO, and
/// `hitTest:` still descends into it. That is the one thing neither `alpha` nor
/// `layer.opacity` can do, because they are the same property.
static void M27MaskOutView(UIView *view) {
    if (!view) return;
    if (view.layer.mask && view.layer.mask.name &&
        [view.layer.mask.name isEqualToString:@"M27Mask"]) {
        return;  // already masked; re-masking every layout would churn
    }
    CALayer *mask = [CALayer layer];
    mask.name = @"M27Mask";
    mask.frame = CGRectZero;
    view.layer.mask = mask;
}

static void M27UnmaskView(UIView *view) {
    if (!view) return;
    CALayer *mask = view.layer.mask;
    if (mask && mask.name && [mask.name isEqualToString:@"M27Mask"]) {
        view.layer.mask = nil;
    }
}

static void M27HideStockChromeForDock(UITabBarController *tbc) {
    if (!tbc.isViewLoaded) return;
    if (!M27Prefs.shared.hideStockChromeEnabled) {
        M27RestoreStockChromeIfNeeded(tbc);
        return;
    }

    BOOL hidMini = NO;
    BOOL hidPalette = NO;
    @try {
        tbc.tabBar.layer.opacity = 0.0;
        tbc.tabBar.userInteractionEnabled = NO;

        @try {
            id tabsVC = [tbc valueForKey:@"tabsViewController"];
            if ([tabsVC isKindOfClass:UIViewController.class]) {
                UIView *v = ((UIViewController *)tabsVC).view;
                if (v) {
                    v.layer.opacity = 0.0;
                    v.userInteractionEnabled = NO;
                }
            }
        } @catch (__unused NSException *ex) {}

        // The "heavy blur" at the bottom is Music's own backdrop behind its tab
        // bar. SwiftPeek's window dump named it:
        //   MusicApplication.PaletteContainerView {0,667,375,145}
        // Hiding the tab bar and mini player alone leaves that panel painting.
        // layer.opacity keeps its children hit-testable, which matters because
        // the mini player we forward Now Playing taps to lives inside it.
        for (UIView *sub in tbc.view.subviews) {
            if ([NSStringFromClass(sub.class) containsString:@"PaletteContainerView"]) {
                // MASK, not opacity. The mini player lives INSIDE this container
                // (`mini_super=…PaletteContainerView…ContainerView`), so fading
                // the container blocks hit-testing for everything in it — the
                // mini player included.
                M27MaskOutView(sub);
                hidPalette = YES;
            }
        }

        UIViewController *miniVC = M27FindMiniPlayerViewController(tbc);
        if (miniVC.isViewLoaded && M27ClassNameHasSuffix(miniVC, @"MiniPlayerViewController")) {
            UIView *mini = miniVC.view;
            if (mini) {
                // `layer.opacity` IS `alpha`. They are one property.
                //
                // 1.1.29 swapped alpha for layer.opacity to keep this view
                // hit-testable, and that never did anything: UIView.alpha is
                // backed by CALayer.opacity, so setting either sets both. The
                // device log said so plainly — only layer.opacity was ever
                // assigned here, and it read back `mini_alpha=0 mini_opacity=0`.
                // hitTest: refuses anything under alpha 0.01, so the mini player
                // has been unreachable this whole time and the passthrough had
                // nothing to hand the touch to.
                //
                // A mask hides the view without touching alpha at all: an empty
                // mask layer has no opaque pixels, so nothing renders, while
                // alpha stays 1 and hit-testing still descends.
                M27MaskOutView(mini);
                // And it has to accept touches now — declining a touch only
                // helps if the thing underneath will take it.
                mini.userInteractionEnabled = YES;
                hidMini = YES;
            }
        }
    } @catch (NSException *ex) {
        M27WriteStatus(@"chrome_hide_exception", @{ @"reason": ex.reason ?: @"?" });
        M27RestoreStockChromeIfNeeded(tbc);
        return;
    }
    M27WriteStatus(@"chrome_hidden", @{
        @"mini": hidMini ? @"yes" : @"no",
        @"palette": hidPalette ? @"yes" : @"no",
    });
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

/// The bottom strip the overlay window occupies.
///
/// THE OVERLAY MUST NEVER BE FULL-SCREEN. Every full-screen build white-screened
/// Music on 17.3 regardless of level — StatusBar-1 (1.1.19, 1.1.21) and Normal+2
/// (1.1.22) alike, with and without a cover plate. The single build that did not
/// blank Music was 1.1.20, the only one whose window was a bottom strip. Size,
/// not level, is the variable.
///
/// The 30% cap that enforces this is now SPKit's, so the next tweak inherits the
/// rule instead of rediscovering it.
static CGRect M27StripFrame(CGRect screen, CGFloat dockHeight, CGFloat safeBottom) {
    return [SPKOverlayWindow bottomStripFrameInScreen:screen
                                        contentHeight:dockHeight
                                                  gap:M27FloatGap()
                                           safeBottom:safeBottom];
}

static M27DockOverlayWindow *M27EnsureOverlayWindow(UITabBarController *tbc, CGRect stripFrame) {
    M27DockOverlayWindow *overlay = objc_getAssociatedObject(tbc, kM27DockWindowKey);

    if (overlay) {
        overlay.windowLevel = M27OverlayWindowLevel();
        if (!gM27FullPlayerUp) overlay.hidden = NO;
        return overlay;
    }

    // Created at its real strip size. 1.1.20 seeded a 1pt-tall window and resized
    // it afterwards, and that build never painted — SPKit refuses the seed too.
    overlay = [M27DockOverlayWindow overlayWithFrame:stripFrame
                                         windowScene:M27SceneForTabBarController(tbc)
                                               level:M27OverlayWindowLevel()];

    objc_setAssociatedObject(tbc, kM27DockWindowKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    M27WriteStatus(@"overlay_created", @{
        @"frame": NSStringFromCGRect(overlay.frame),
        @"level": @((double)overlay.windowLevel),
    });
    NSLog(@"[Music27 " M27_VERSION "] overlay window created level=%.1f frame=%@ iOS=%ld",
          overlay.windowLevel, NSStringFromCGRect(overlay.frame), (long)M27SystemMajorVersion());
    return overlay;
}

static void M27LayoutDock(UITabBarController *tbc, M27FloatingDock *dock) {
    if (!tbc || !dock) return;
    if (objc_getAssociatedObject(tbc, kM27LayoutGuardKey)) return;
    objc_setAssociatedObject(tbc, kM27LayoutGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        M27WriteStatus(@"layout_begin", @{});
        CGRect screen = M27ScreenBounds(tbc);
        CGFloat screenW = CGRectGetWidth(screen);
        CGFloat screenH = CGRectGetHeight(screen);
        if (screenW < 10 || screenH < 10) {
            NSLog(@"[Music27 " M27_VERSION "] layout skip: empty screen bounds");
            M27WriteStatus(@"layout_skip_bounds", @{});
            return;
        }

        CGFloat height = dock.preferredHeight;
        if (height < 10 || height > 160.0) {
            height = 52.0 + 8.0 + 58.0;
            NSLog(@"[Music27 " M27_VERSION "] preferredHeight out of range → fallback %.0f", height);
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
        if (!gM27FullPlayerUp) overlay.hidden = NO;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.opaque = NO;

        UIView *host = overlay.rootViewController.view;
        if (!host) {
            NSLog(@"[Music27 " M27_VERSION "] layout skip: no host view");
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

        NSLog(@"[Music27 " M27_VERSION "] layout iOS=%ld screen=%.0fx%.0f strip=%@ dockY=%.0f "
              @"dockH=%.0f safeB=%.0f gap=%.0f level=%.1f hidden=%d",
              (long)M27SystemMajorVersion(), screenW, screenH,
              NSStringFromCGRect(stripFrame), y, height, safeBottom,
              floatGap, overlay.windowLevel, (int)overlay.hidden);
        M27HideStockChromeForDock(tbc);
        M27WriteStatus(@"layout", @{
            @"strip": NSStringFromCGRect(stripFrame),
            @"screen": NSStringFromCGSize(CGSizeMake(screenW, screenH)),
            @"dock_frame": NSStringFromCGRect(dock.frame),
            @"safe_bottom": @((double)safeBottom),
            @"level": @((double)overlay.windowLevel),
            @"full_screen": @(CGRectGetHeight(stripFrame) >= screenH - 1.0),
        });
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
        NSLog(@"[Music27 " M27_VERSION "] install skip: nil tbc");
        M27WriteStatus(@"install_skip_nil_tbc", @{});
        return;
    }
    if (!tbc.isViewLoaded) {
        NSLog(@"[Music27 " M27_VERSION "] install skip: tbc not loaded");
        M27WriteStatus(@"install_skip_tbc_unloaded", @{});
        return;
    }
    M27Prefs *prefs = M27Prefs.shared;

    if (!(prefs.enabled && prefs.glassTabBarEnabled)) {
        NSLog(@"[Music27 " M27_VERSION "] install skip: prefs en=%d dock=%d",
              (int)prefs.enabled, (int)prefs.glassTabBarEnabled);
        M27WriteStatus(@"install_skip_prefs", @{
            @"enabled": @(prefs.enabled),
            @"glassTabBar": @(prefs.glassTabBarEnabled),
        });
        M27RemoveDock(tbc);
        return;
    }

    @try {
        M27WriteStatus(@"install_begin", @{ @"tabs": @((long)tbc.viewControllers.count) });
        // No solid cover; bottom-strip overlay only. Stock chrome is faded at the
        // end of layout via M27HideStockChromeForDock — restoring it here would
        // fight that on every pass.
        M27SweepLegacyDockSubviews();

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
            NSLog(@"[Music27 " M27_VERSION "] dock view created");
            M27WriteStatus(@"dock_created", @{ @"h": @((double)dock.preferredHeight) });
        }
        // One breadcrumb per step: 1.1.25 narrowed the crash to this span but
        // could not say which call. A missing line names the next statement.
        dock.delegate = controller;
        controller.dock = dock;
        M27WriteStatus(@"pre_reload", @{});
        [dock reloadTabs];
        M27WriteStatus(@"pre_setmode", @{});
        [dock setMode:M27DockModeExpanded animated:NO];
        M27WriteStatus(@"pre_selected", @{
            @"idx": @((long)tbc.selectedIndex),
            @"visible": @((long)[controller visibleTabIndexes].count),
        });
        [controller syncSelection];
        [controller beginObservingNowPlaying];
        M27WriteStatus(@"pre_sync", @{});
        [controller syncNowPlaying];
        M27WriteStatus(@"pre_layout", @{});
        M27LayoutDock(tbc, dock);
        M27DockOverlayWindow *ov = objc_getAssociatedObject(tbc, kM27DockWindowKey);
        NSLog(@"[Music27 " M27_VERSION "] install OK dock=%p overlay=%p", dock, ov);
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
        NSLog(@"[Music27 " M27_VERSION "] install exception: %@", ex);
        M27WriteStatus(@"install_exception", @{ @"reason": ex.reason ?: @"?" });
        M27RemoveDock(tbc);
    }
}

static void M27HandleScrollOffset(UIScrollView *scrollView) {
    if (!scrollView.isDragging && !scrollView.isDecelerating) return;
    if (fabs(scrollView.contentOffset.x) > fabs(scrollView.contentOffset.y)) return;
    if (scrollView.contentOffset.y < kM27ScrollCollapseY) return;

    // Don't collapse on a flick. 48pt is about one thumb-nudge, and the dock was
    // snapping shut the instant a scroll started — it felt like it was waiting
    // to pounce rather than responding to a deliberate scroll.
    //
    // Two guards: the scroll has to have been going for a moment, and it has to
    // have covered real distance. Either alone is defeatable — a slow 10pt drag
    // passes the timer, a fast flick passes the distance — so both must hold.
    static NSTimeInterval scrollBegan = 0;
    static CGFloat beganAtY = 0;
    NSTimeInterval now = CACurrentMediaTime();
    if (scrollBegan == 0 || (now - scrollBegan) > kM27ScrollIdleReset) {
        scrollBegan = now;
        beganAtY = scrollView.contentOffset.y;
    }
    if ((now - scrollBegan) < kM27ScrollCollapseDelay) return;
    if ((scrollView.contentOffset.y - beganAtY) < kM27ScrollCollapseDistance) return;

    // Collapse the overlay dock only — never mutate scroll hosts / Library.
    UITabBarController *tbc = M27MusicTabBarController();
    if (!tbc) return;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    M27FloatingDock *dock = M27DockForTabBarController(tbc);
    if (!dock || dock.mode == M27DockModeCollapsed) return;
    [dock collapseFromScroll];
}

void M27SetDockOverlayHidden(BOOL hidden) {
    gM27FullPlayerUp = hidden;
    UITabBarController *tbc = M27MusicTabBarController();
    if (!tbc) return;
    M27DockOverlayWindow *overlay = objc_getAssociatedObject(tbc, kM27DockWindowKey);
    if (!overlay || overlay.hidden == hidden) return;
    overlay.hidden = hidden;
    M27WriteStatus(@"dock_overlay", @{ @"hidden": hidden ? @"yes" : @"no" });
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
        NSLog(@"[Music27 " M27_VERSION "] TBC viewDidAppear");
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
    if (!M27DockForTabBarController(self)) return;
    [objc_getAssociatedObject(self, kM27DockControllerKey) syncSelection];
}

- (void)setSelectedViewController:(UIViewController *)selectedViewController {
    %orig;
    if (!M27DockForTabBarController(self)) return;
    [objc_getAssociatedObject(self, kM27DockControllerKey) syncSelection];
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
        NSLog(@"[Music27 " M27_VERSION "] UIWindow makeKeyAndVisible → install");
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
