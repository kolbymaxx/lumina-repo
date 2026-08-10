#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "GLPrefs.h"
#import "GLThemeStore.h"
#import "GLIconCache.h"
#import "GLRecipeBuilder.h"

// -----------------------------------------------------------------------------
// Glyph — Phase B: UIKit icon engine (the SnowBoard-compatible core)
//
// Home Screen icons on iOS 16.7 / 17.x are pure UIKit: SBIconView owns an
// SBIconImageView, and the final rendered icon bitmap arrives at exactly one
// choke point — -[SBIconImageView setContentsImage:]. Glyph substitutes the
// themed bitmap there and nowhere else. No SwiftUI on this path, no per-frame
// work: every themed icon is decoded once (GLIconCache) and handed out from
// memory afterwards.
//
// Safety pattern (inherited from CC27 / SwiftPeek):
//   - prefs default OFF, kill-switch file, fail closed on anything unexpected
//   - constructor does no hooking; hooks arrive after
//     UIApplicationDidFinishLaunching, outside the watchdog window, so
//     SpringBoard's boot path runs 100% stock
// -----------------------------------------------------------------------------

// Minimal SpringBoard interfaces (private). Presence is re-verified at
// runtime before hooking — see GLInstallHooks.
@interface SBIconImageView : UIView
- (id)icon;
- (UIImage *)contentsImage;
- (void)setContentsImage:(UIImage *)image;
@end

static BOOL gGLHooksInstalled = NO;

static void GLLog(NSString *format, ...) {
    if (!GLPrefBool(@"logEvents", YES)) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[Glyph] %@", msg);
}

#pragma mark - Icon identity

/// Bundle ID (or leaf identifier for web clips / non-app icons) of an SBIcon.
static NSString *GLIdentifierForIcon(id icon) {
    if (!icon) return nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        for (NSString *selName in @[ @"applicationBundleID", @"leafIdentifier" ]) {
            SEL sel = NSSelectorFromString(selName);
            if ([icon respondsToSelector:sel]) {
                id result = [icon performSelector:sel];
                if ([result isKindOfClass:[NSString class]] && [result length]) {
                    return result;
                }
            }
        }
#pragma clang diagnostic pop
    } @catch (__unused id e) {}
    return nil;
}

#pragma mark - Provenance

// Phase D composites *from* the stock bitmap, not just from a theme PNG, which
// creates a hazard Phase B did not have: the refresh pass re-feeds an icon
// view's current image, and after the first pass that image is Glyph's own
// output. Compositing it again would stack tint on tint every time a
// preference changed. So mark what we produce, and remember the stock bitmap
// each view was originally handed.
static const void *kGLMarkKey = &kGLMarkKey;
static const void *kGLOriginalKey = &kGLOriginalKey;

static inline BOOL GLImageIsOurs(UIImage *image) {
    return image && objc_getAssociatedObject(image, kGLMarkKey) != nil;
}

static inline void GLMarkImageAsOurs(UIImage *image) {
    if (image) {
        objc_setAssociatedObject(image, kGLMarkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

/// The stock bitmap for this icon view: the incoming image when SpringBoard
/// hands us a fresh one, or the one we stashed the first time if we are being
/// re-fed our own output.
static UIImage *GLResolveStockImage(SBIconImageView *iconView, UIImage *incoming) {
    if (!GLImageIsOurs(incoming)) {
        if (incoming) {
            objc_setAssociatedObject(iconView, kGLOriginalKey, incoming,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return incoming;
    }
    return objc_getAssociatedObject(iconView, kGLOriginalKey);
}

#pragma mark - Substitution

/// Replacement for the image about to land on an icon view, or nil to leave the
/// stock image untouched. Never throws.
static UIImage *GLThemedImageForIconView(SBIconImageView *iconView, UIImage *stock) {
    @try {
        if (!GLPrefBool(@"enabled", NO)) return nil;
        // Phase D: a tint or glass recipe applies to every icon, so an active
        // recipe is reason enough to act even with no theme installed.
        if (![GLThemeStore hasActiveThemes] && !GLRecipeCompositingActive()) return nil;

        id icon = [iconView respondsToSelector:@selector(icon)] ? [iconView icon] : nil;
        NSString *identifier = GLIdentifierForIcon(icon);
        if (!identifier) return nil;

        // Match the stock bitmap's geometry exactly so masks, badges and
        // labels line up; fall back to the view's own bounds.
        CGSize size = CGSizeZero;
        CGFloat scale = 0;
        if (stock && stock.size.width >= 1.0 && stock.size.height >= 1.0) {
            size = stock.size;
            scale = stock.scale;
        } else if (iconView.bounds.size.width >= 1.0) {
            size = iconView.bounds.size;
        }

        UIImage *result = [[GLIconCache shared] imageForBundleID:identifier
                                                      stockImage:stock
                                                       pointSize:size
                                                           scale:scale];
        GLMarkImageAsOurs(result);
        return result;
    } @catch (__unused id e) {
        return nil;   // fail closed — stock icon
    }
}

#pragma mark - Hooks

%group GlyphIcons

%hook SBIconImageView

- (void)setContentsImage:(UIImage *)image {
    UIImage *stock = GLResolveStockImage(self, image);
    UIImage *themed = stock ? GLThemedImageForIconView(self, stock) : nil;
    %orig(themed ?: (stock ?: image));
}

%end

%end // GlyphIcons

#pragma mark - Refresh pass

/// One-shot, bounded walk over the live view hierarchy that re-feeds every
/// existing SBIconImageView through the (now hooked) setContentsImage: path.
/// Needed because hooks install after launch, when the first screenful of
/// icons has already rendered stock. Not a polling loop — runs only on
/// install and on theme/prefs changes.
static void GLRefreshVisibleIcons(void) {
    if (!gGLHooksInstalled) return;
    if (!GLPrefBool(@"enabled", NO)) return;
    if (![GLThemeStore hasActiveThemes] && !GLRecipeCompositingActive()) return;

    @try {
        Class iconImageViewClass = NSClassFromString(@"SBIconImageView");
        if (!iconImageViewClass) return;

        NSMutableArray<UIView *> *queue = [NSMutableArray array];
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            [queue addObject:w];
        }

        NSInteger budget = 6000;
        NSInteger refreshed = 0;
        while (queue.count && budget-- > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];

            if ([v isKindOfClass:iconImageViewClass] &&
                [v respondsToSelector:@selector(contentsImage)] &&
                [v respondsToSelector:@selector(setContentsImage:)]) {
                SBIconImageView *iv = (SBIconImageView *)v;
                UIImage *current = [iv contentsImage];
                if (current) {
                    // Goes through the hook, which substitutes the themed image.
                    [iv setContentsImage:current];
                    refreshed++;
                }
            }
            for (UIView *sub in v.subviews) [queue addObject:sub];
        }
        GLLog(@"refresh pass re-fed %ld icon views", (long)refreshed);
    } @catch (__unused id e) {
        // fail closed — worst case some icons stay stock until they redraw
    }
}

#pragma mark - Install

// Installed well after SpringBoard finishes launching so Glyph contributes
// exactly zero work to the boot-critical path (CC27's ~60 s boot hang +
// watchdog reload came from tweak code running during launch).
// Not dispatch_once: a disabled first call must not burn the only chance to
// install, because the user can enable Glyph from Settings later the same
// boot. Always invoked on the main queue, so a plain flag is safe.
static void GLInstallHooks(void) {
    if (gGLHooksInstalled) return;
    if (!GLPrefBool(@"enabled", NO)) {
        GLLog(@"disabled in prefs — hooks not installed");
        return;
    }

    // Verify the hook point actually exists on this firmware before touching
    // anything. Never invent surfaces that are not there.
    Class cls = NSClassFromString(@"SBIconImageView");
    if (!cls || !class_getInstanceMethod(cls, @selector(setContentsImage:))) {
        GLLog(@"SBIconImageView / setContentsImage: not found on this firmware — staying inert");
        return;
    }

    %init(GlyphIcons);
    gGLHooksInstalled = YES;
    GLLog(@"0.1.0 icon hooks installed (post-launch), %lu theme(s) active",
          (unsigned long)([GLThemeStore hasActiveThemes] ? GLPrefArray(@"selectedThemes").count : 0));

    GLRefreshVisibleIcons();
}

#pragma mark - Notifications

static void GLPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    GLPrefsInvalidate();
    [[GLIconCache shared] bumpGeneration];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gGLHooksInstalled) {
            // Enabled for the first time this boot — install now (we are long
            // past launch, so this is safe).
            GLInstallHooks();
        } else {
            GLRefreshVisibleIcons();
        }
    });
}

#pragma mark - Constructor (boot path: read prefs, schedule, nothing else)

%ctor {
    @autoreleasepool {
        // Emergency kill switch: create this file (via SSH/Filza) and respring
        // to fully disable Glyph without uninstalling:
        //   touch /var/mobile/Library/Preferences/com.kolby.glyph.killswitch
        if (GLKillSwitchPresent()) {
            NSLog(@"[Glyph] kill switch present — not loading");
            return;
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        GLPrefsChanged,
                                        CFSTR("com.kolby.glyph/prefschanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        GLPrefsChanged,
                                        CFSTR("com.kolby.glyph/themeschanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        // Do NOT hook anything yet. SpringBoard's launch (including the first
        // lock screen) runs 100% stock; hooks arrive a moment after
        // UIApplicationDidFinishLaunching, safely outside the watchdog window.
        __block id token = nil;
        token = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            if (token) {
                [[NSNotificationCenter defaultCenter] removeObserver:token];
                token = nil;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                GLInstallHooks();
            });
        }];
        NSLog(@"[Glyph] 0.1.0 loaded — waiting for SpringBoard launch to finish before hooking");
    }
}
