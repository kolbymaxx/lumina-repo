#import "Lattice.h"
#import <objc/runtime.h>
#import <objc/message.h>

// -----------------------------------------------------------------------------
// Lattice — hooks
//
// Every hook here returns a number. None of them mutates the icon model,
// inserts an icon, or reorders anything, which keeps the worst case at "ugly
// grid" rather than "SpringBoard will not boot".
//
// Each hooked class and selector is verified to exist at runtime before %init
// (the Glyph pattern). If a firmware does not have the shape Lattice expects,
// it logs and stays completely inert instead of guessing.
// -----------------------------------------------------------------------------

@interface SBIconListGridLayoutConfiguration : NSObject
- (NSUInteger)numberOfPortraitRows;
- (NSUInteger)numberOfPortraitColumns;
- (NSUInteger)numberOfLandscapeRows;
- (NSUInteger)numberOfLandscapeColumns;
@end

@interface SBIconView : UIView
@end

static BOOL gLTGridHooksInstalled = NO;
static BOOL gLTLabelHooksInstalled = NO;

static void LTLog(NSString *format, ...) {
    if (!LTPrefBool(@"logEvents", YES)) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[Lattice] %@", msg);
}

#pragma mark - Grid

%group LatticeGrid

// The dock is laid out by this same configuration class, so a naive override
// would stretch a 6x5 grid across the dock and deform it. The discriminator is
// the configuration's *own* row count: a dock is one row, an icon page never
// is. That is self-validating — it asks the object what it already is instead
// of guessing at a private dock-specific class name.
%hook SBIconListGridLayoutConfiguration

- (NSUInteger)numberOfPortraitRows {
    NSUInteger orig = %orig;
    LTLayout layout = LTCurrentLayout();
    if (!layout.overrideGrid) return orig;
    if (orig <= 1) return orig;              // dock — stays a single row
    return (NSUInteger)layout.rows;
}

- (NSUInteger)numberOfPortraitColumns {
    NSUInteger orig = %orig;
    LTLayout layout = LTCurrentLayout();
    // Re-entering our own rows hook is safe and only goes one level deep: for
    // a dock it returns %orig unchanged, for a page it returns the override.
    BOOL isDock = ([self numberOfPortraitRows] <= 1);
    if (isDock) return layout.overrideDock ? (NSUInteger)layout.dockColumns : orig;
    if (!layout.overrideGrid) return orig;
    return (NSUInteger)layout.columns;
}

- (NSUInteger)numberOfLandscapeRows {
    NSUInteger orig = %orig;
    LTLayout layout = LTCurrentLayout();
    if (!layout.overrideGrid) return orig;
    if (orig <= 1) return orig;
    return (NSUInteger)layout.landscapeRows;
}

- (NSUInteger)numberOfLandscapeColumns {
    NSUInteger orig = %orig;
    LTLayout layout = LTCurrentLayout();
    BOOL isDock = ([self numberOfLandscapeRows] <= 1);
    if (isDock) return layout.overrideDock ? (NSUInteger)layout.dockColumns : orig;
    if (!layout.overrideGrid) return orig;
    return (NSUInteger)layout.landscapeColumns;
}

%end

%end // LatticeGrid

#pragma mark - Labels

%group LatticeLabels

%hook SBIconView

// The label is a child view of the icon view; hiding it is reversible and
// touches no layout maths, so a respring puts everything back.
- (void)layoutSubviews {
    %orig;
    @try {
        // This runs for every icon on every layout pass, so the disabled path
        // must be nothing more than a read of a cached struct — and the
        // enabled path uses a cached selector with a typed objc_msgSend rather
        // than KVC, which would be both slower and able to throw.
        LTLayout layout = LTCurrentLayout();
        if (!layout.hideLabels) return;

        static SEL labelSel;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ labelSel = NSSelectorFromString(@"labelView"); });
        if (!labelSel || ![self respondsToSelector:labelSel]) return;

        UIView *label = ((UIView *(*)(id, SEL))objc_msgSend)(self, labelSel);
        if ([label isKindOfClass:[UIView class]] && !label.hidden) {
            label.hidden = YES;
        }
    } @catch (__unused id e) {
        // fail closed — the label stays visible
    }
}

%end

%end // LatticeLabels

#pragma mark - Install

/// Verify a class implements every selector we intend to hook. Hooking a
/// selector that does not exist on this firmware is how a layout tweak takes
/// SpringBoard down, so no guessing: present or inert.
static BOOL LTClassHasSelectors(NSString *className, NSArray<NSString *> *selectorNames) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        LTLog(@"%@ not present on this firmware", className);
        return NO;
    }
    for (NSString *name in selectorNames) {
        SEL sel = NSSelectorFromString(name);
        if (!sel || !class_getInstanceMethod(cls, sel)) {
            LTLog(@"%@ has no -%@ — staying inert", className, name);
            return NO;
        }
    }
    return YES;
}

// Not dispatch_once: a first call while disabled must not burn the only chance
// to install, because the user can enable Lattice from Settings later the same
// boot. Always called on the main queue, so plain flags are safe.
static void LTInstallHooks(void) {
    if (!LTPrefBool(@"enabled", NO)) {
        LTLog(@"disabled in prefs — hooks not installed");
        return;
    }

    if (!gLTGridHooksInstalled &&
        LTClassHasSelectors(@"SBIconListGridLayoutConfiguration", @[
            @"numberOfPortraitRows", @"numberOfPortraitColumns",
            @"numberOfLandscapeRows", @"numberOfLandscapeColumns",
        ])) {
        %init(LatticeGrid);
        gLTGridHooksInstalled = YES;
        LTLog(@"grid hooks installed");
    }

    if (!gLTLabelHooksInstalled &&
        LTClassHasSelectors(@"SBIconView", @[ @"layoutSubviews" ])) {
        %init(LatticeLabels);
        gLTLabelHooksInstalled = YES;
        LTLog(@"label hooks installed");
    }

    LTLayout layout = LTCurrentLayout();
    LTLog(@"0.1.0 armed — grid %ldx%ld (override=%d) labels=%@",
          (long)layout.columns, (long)layout.rows, layout.overrideGrid ? 1 : 0,
          layout.hideLabels ? @"hidden" : @"shown");
}

/// Ask SpringBoard to rebuild the icon layout. Every step is guarded, and a
/// miss just means the new grid appears after the next respring.
static void LTRelayoutHomeScreen(void) {
    @try {
        Class controllerClass = NSClassFromString(@"SBIconController");
        if (!controllerClass) return;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if (![controllerClass respondsToSelector:sharedSel]) return;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id controller = [controllerClass performSelector:sharedSel];
        if (!controller) return;

        for (NSString *name in @[ @"_relayoutIconLists", @"relayoutIconLists" ]) {
            SEL sel = NSSelectorFromString(name);
            if ([controller respondsToSelector:sel]) {
                [controller performSelector:sel];
                return;
            }
        }
#pragma clang diagnostic pop
        LTLog(@"no relayout selector found — respring to apply");
    } @catch (__unused id e) {}
}

static void LTPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    LTPrefsInvalidate();
    LTLayoutInvalidate();
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gLTGridHooksInstalled && !gLTLabelHooksInstalled) {
                LTInstallHooks();   // enabled for the first time this boot
            }
            LTRelayoutHomeScreen();
        } @catch (__unused id e) {}
    });
}

%ctor {
    @autoreleasepool {
        // Emergency kill switch:
        //   touch /var/mobile/Library/Preferences/com.kolby.lattice.killswitch
        if (LTKillSwitchPresent()) {
            NSLog(@"[Lattice] kill switch present — not loading");
            return;
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, LTPrefsChanged,
                                        CFSTR("com.kolby.lattice/prefschanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        // The icon grid is built during launch, which is an argument for
        // hooking from the constructor — and the wrong call. Reading prefs
        // means touching the filesystem on the boot-critical path, which is
        // exactly the class of work that cost CC27 a 60 s boot hang. Lattice
        // waits like everything else and then forces a relayout, so the custom
        // grid appears a moment into boot instead of risking the boot itself.
        __block id token = nil;
        token = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            if (token) {
                [NSNotificationCenter.defaultCenter removeObserver:token];
                token = nil;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    LTInstallHooks();
                    if (LTLayoutActive()) LTRelayoutHomeScreen();
                } @catch (__unused id e) {}
            });
        }];

        NSLog(@"[Lattice] 0.1.0 loaded — waiting for SpringBoard launch to finish");
    }
}
