#import "Music27.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// Music's full-screen player, restyled toward iOS 26/27.
//
// WHY THIS SCREEN IS TRACTABLE AND THE ALBUM HEADER WAS NOT.
//
// The album Play/Shuffle row cost four builds because it is SwiftUI: the thing
// that looks like a button is a MusicCoreUI.SymbolButton drawing only the
// capsule, with the glyph and label rendered as siblings outside its layer
// subtree. Hiding the "button" left the glyph on screen.
//
// The full player is not like that. SwiftPeek's offline field catalog gives
// MusicApplication.NowPlayingControlsViewController as a plain UIKit controller
// with named ivars for every part of the iOS 27 layout:
//
//   artworkView · titleLabel · subtitleButton · favoriteButton · contextButton
//   timeControl · transportControlsStackView · leftButton · playPauseStopButton
//   rightButton · volumeSlider · bottomButtonsStackView · lyricsButton
//   routeButton · queueButton · grabberView · backgroundView
//
// So this restyles real views instead of guessing at a render tree.
//
// FIRST PASS IS DELIBERATELY SMALL. Everything here is reversible and visually
// obvious, and the build's main job is to write `nowplaying_controls` naming
// every ivar it found with its real frame. Guessing geometry from screenshots is
// what the hazard registry calls asserting a cause from a symptom; one log line
// from the device replaces all of it. Pref-gated OFF by default.

static const void *kM27NowPlayingRadiusKey = &kM27NowPlayingRadiusKey;

static const CGFloat kM27ArtworkCornerRadius = 20.0;

static BOOL M27IsNowPlayingControls(UIViewController *vc) {
    return M27ClassNameHasSuffix(vc, @"NowPlayingControlsViewController");
}

/// Read one named ivar — but only when the runtime says it holds an object.
///
/// Most of this controller's fields are Swift structs and enums. Reading one of
/// those as an id is how SwiftPeek 0.3.0 and 0.3.5 earned their SIGSEGVs, so the
/// type encoding check is not optional: `@` means object, anything else is
/// refused. This is a targeted read of a known name, never a field walk.
static id M27IvarObject(NSObject *obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    if (!enc || enc[0] != '@') return nil;
    id value = nil;
    @try {
        value = object_getIvar(obj, iv);
    } @catch (__unused NSException *ex) {
        return nil;
    }
    return value;
}

static UIView *M27IvarView(NSObject *obj, const char *name) {
    id value = M27IvarObject(obj, name);
    return [value isKindOfClass:UIView.class] ? (UIView *)value : nil;
}

/// "<class> {x, y, w, h}", or "nil" — same shape as the album row's logging.
static NSString *M27DescribeView(UIView *view) {
    if (!view) return @"nil";
    return [NSString stringWithFormat:@"%@%@",
            NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];
}

static NSArray<NSString *> *M27NowPlayingIvarNames(void) {
    return @[ @"artworkView", @"titleLabel", @"subtitleButton", @"favoriteButton",
              @"contextButton", @"grabberView", @"timeControl", @"volumeSlider",
              @"transportControlsStackView", @"leftButton", @"playPauseStopButton",
              @"rightButton", @"bottomButtonsStackView", @"lyricsButton",
              @"routeButton", @"queueButton", @"titlesStackView", @"buttonsStackView",
              @"topContainerView", @"bottomContainerView", @"mainContainerView" ];
}

/// One line per presentation naming what was actually found on this device.
///
/// The catalog was built from a different Music build than the one running here,
/// so treat it as a hypothesis. A missing name in this log means the ivar was
/// renamed or is a struct, and the next build targets something else instead of
/// re-deriving the same wrong guess.
/// Every view-typed ivar this controller actually has, with its frame.
///
/// The catalog was a hypothesis and 1.1.39 falsified it in one line: the class
/// on this device is `MusicNowPlayingControlsViewController` — plain ObjC, no
/// Swift module prefix — and all 21 catalog names came back missing. That
/// catalog was built from a different Music build.
///
/// So stop guessing names and read the ones that are here. Only object-typed
/// ivars are touched, and only their class and frame are recorded, so this is a
/// targeted read rather than the kind of field walk that SIGSEGV'd SwiftPeek.
static void M27ReportRealIvars(UIViewController *vc) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    Class cls = object_getClass(vc);

    for (NSInteger depth = 0; cls && depth < 3; depth++, cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;

        for (unsigned int i = 0; i < count && found.count < 40; i++) {
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            if (!enc || enc[0] != '@') continue;

            id value = nil;
            @try {
                value = object_getIvar(vc, ivars[i]);
            } @catch (__unused NSException *ex) { continue; }
            if (![value isKindOfClass:UIView.class]) continue;

            UIView *view = (UIView *)value;
            [found addObject:[NSString stringWithFormat:@"%s:%@%@",
                              ivar_getName(ivars[i]),
                              NSStringFromClass(view.class),
                              NSStringFromCGRect(view.frame)]];
        }
        free(ivars);
    }

    M27WriteStatus(@"nowplaying_ivars", @{
        @"vc": NSStringFromClass(vc.class),
        @"count": @((long)found.count),
        @"views": found.count ? [found componentsJoinedByString:@" "] : @"none",
    });
}

static void M27ReportNowPlayingControls(UIViewController *vc) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];

    for (NSString *name in M27NowPlayingIvarNames()) {
        UIView *view = M27IvarView(vc, name.UTF8String);
        if (view) {
            info[name] = M27DescribeView(view);
        } else {
            [missing addObject:name];
        }
    }
    info[@"missing"] = missing.count ? [missing componentsJoinedByString:@","] : @"none";
    info[@"vc"] = NSStringFromClass(vc.class);
    info[@"view"] = NSStringFromCGRect(vc.view.bounds);

    M27WriteStatus(@"nowplaying_controls", info);
}

static void M27StyleNowPlayingControls(UIViewController *vc) {
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.nowPlayingGlassEnabled)) return;

    UIView *artwork = M27IvarView(vc, "artworkView");
    if (!artwork) return;

    // iOS 27's artwork is noticeably more rounded than 17's. Continuous curve —
    // the squircle is most of what separates the two at a glance.
    NSNumber *saved = objc_getAssociatedObject(vc, kM27NowPlayingRadiusKey);
    if (!saved) {
        objc_setAssociatedObject(vc, kM27NowPlayingRadiusKey,
                                 @((double)artwork.layer.cornerRadius),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (fabs(artwork.layer.cornerRadius - kM27ArtworkCornerRadius) > 0.5) {
        artwork.layer.cornerRadius = kM27ArtworkCornerRadius;
        if (@available(iOS 13.0, *)) {
            artwork.layer.cornerCurve = kCACornerCurveContinuous;
        }
        artwork.layer.masksToBounds = YES;
        M27WriteStatus(@"nowplaying_styled", @{
            @"artwork": M27DescribeView(artwork),
            @"radius": @(kM27ArtworkCornerRadius),
        });
    }
}

%hook UIViewController

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (!M27IsNowPlayingControls(self)) return;
    if (!M27Prefs.shared.enabled) return;
    M27SetDockOverlayHidden(NO);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!M27IsNowPlayingControls(self)) return;
    M27Prefs *prefs = M27Prefs.shared;
    if (!prefs.enabled) return;

    // The dock has its own window at Normal + 2, above Music's, so the pills
    // keep floating over the full-screen player once it opens. Music's own mini
    // player and tab bar disappear with the presentation because they live in
    // the app's window; ours has to be told. Not gated on nowPlayingGlass —
    // this is a bug, not a restyle.
    if (prefs.glassTabBarEnabled) M27SetDockOverlayHidden(YES);

    // Report on every presentation regardless of the style pref — the point is
    // to learn this screen's real shape, and that costs one log line.
    M27ReportNowPlayingControls(self);
    M27ReportRealIvars(self);
    M27StyleNowPlayingControls(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!M27IsNowPlayingControls(self)) return;
    // Music re-lays this out constantly (marquee, scrubber, artwork transitions),
    // so the styling has to be idempotent — it re-applies only when the radius
    // has actually been reset.
    M27StyleNowPlayingControls(self);
}

%end
