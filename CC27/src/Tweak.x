#import "CC27.h"
#import "SPDumpWriter.h"
#import <objc/runtime.h>
#import <string.h>

static void CC27ReloadPrefs(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [CC27Prefs.shared reload];
    [CC27LayoutStore.shared reload];
}

// On iOS 16+, the Lock Screen's flashlight / camera quick actions embed real
// CC module container views — the exact class we hook. CC27 must never style
// or decorate those: mutating lock screen views can wedge the whole cover
// sheet. Only views living inside actual Control Center chrome qualify.
//
// Whitelist first: real CC lives under "ControlCenter" chrome
// (CCUIModularControlCenterView / SBControlCenterWindow), so any such ancestor
// is a definitive yes. The lock screen blacklist stays as a safety net for the
// quick-action containers, which never have a ControlCenter ancestor.
//
// The per-level order matters and must not be "simplified": CC presented over
// the lock screen legitimately has CoverSheet ancestors *above* its
// ControlCenter chrome, so the whitelist has to win as soon as it matches while
// walking up. Checking the blacklist across the whole chain first would strip
// glass from lock screen CC — the exact regression 1.0.8 had to undo.
static BOOL CC27ViewIsInControlCenter(UIView *view) {
    if (!view) return NO;
    // Not in a window yet → the superview chain is still being assembled, so
    // neither list can be trusted. This is how a Lock Screen quick-action
    // container reached the old fail-open default and got styled (the
    // 1.0.5/1.0.6 freezes). The view gets another layoutSubviews once it is
    // hosted; decide then instead of guessing now.
    if (!view.window) return NO;

    UIView *v = view;
    while (v) {
        const char *cls = class_getName(v.class);
        if (cls) {
            if (strstr(cls, "ControlCenter")) {
                return YES;
            }
            if (strstr(cls, "QuickAction") || strstr(cls, "CoverSheet") ||
                strstr(cls, "DashBoard") || strstr(cls, "Dashboard") ||
                strstr(cls, "LockScreen")) {
                return NO;
            }
        }
        v = v.superview;
    }
    // Fail CLOSED. Only a positive ControlCenter ancestor proves this container
    // is real CC chrome; anything inconclusive is left stock.
    return NO;
}

#pragma mark - Recon dump (opt-in, default off)

// Read-only snapshot of the live Control Center view tree, written in SwiftPeek's
// dump format so the host tools under tools/ read it with no schema change
// (`process` in the header is "SpringBoard", so dumps self-identify).
//
// Why this exists: CC27 hardcodes ~14 private class names and KVC keys that were
// never checked against a real device. Music27 spent six releases proving what
// guessing at private hierarchy costs; in SpringBoard the price is a boot hang or
// a wedged lock screen, so the guesses get verified from data instead.
//
// Hard rules, matching the rest of this file's hardening:
//   - class names and hierarchy shape only. No FOVO walking, never force vc.view.
//     SwiftPeek's SPFieldWalk.m is deliberately NOT linked, for exactly that reason.
//   - never while locked, never on the boot path.
//   - UIKit is read on the main thread; only serialization + file I/O go off-thread.
static const NSUInteger kCC27ReconMaxNodes = 400;
static const NSUInteger kCC27ReconMaxDepth = 12;
static const NSUInteger kCC27ReconMaxDumps = 10; // per SpringBoard session
static NSUInteger gCC27ReconDumpCount = 0;

/// Reports whether a guessed KVC key actually resolves, and to what.
/// "MISSING" / "nil" / "THREW:" in a dump means the corresponding hardcoded
/// string elsewhere in CC27 is wrong and needs correcting.
static NSString *CC27ReconProbeKey(id target, NSString *key) {
    if (!target) return @"no-instance";
    @try {
        id value = [target valueForKey:key];
        if (!value) return @"nil";
        if ([value isKindOfClass:NSDictionary.class]) {
            return [NSString stringWithFormat:@"NSDictionary(%lu)",
                    (unsigned long)((NSDictionary *)value).count];
        }
        if ([value isKindOfClass:NSArray.class]) {
            return [NSString stringWithFormat:@"NSArray(%lu)",
                    (unsigned long)((NSArray *)value).count];
        }
        if ([value isKindOfClass:NSString.class]) {
            return [NSString stringWithFormat:@"NSString:%@", value];
        }
        return NSStringFromClass([value class]) ?: @"?";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"THREW:%@", e.name ?: @"?"];
    }
}

/// Confirms every class CC27 resolves by name, and every KVC key it reads,
/// using the same access paths the real code uses.
static NSDictionary *CC27ReconProbeFields(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    for (NSString *name in @[ @"CCUIModularControlCenterOverlayViewController",
                              @"CCUIContentModuleContentContainerView",
                              @"CCUIContentModuleContainerViewController",
                              @"CCUIModuleInstanceManager",
                              @"CCUIModuleCollectionViewController",
                              @"CCUIModularControlCenterViewController",
                              @"CCSModuleRepository",
                              @"CCSModuleSettingsProvider",
                              @"MTMaterialView",
                              @"SBLockScreenManager" ]) {
        out[[@"class:" stringByAppendingString:name]] =
            NSClassFromString(name) ? @"present" : @"MISSING";
    }

    // Same acquisition path as CC27LayoutStore / CC27ModuleCatalog.
    Class mgrCls = NSClassFromString(@"CCUIModuleInstanceManager");
    id mgr = [mgrCls respondsToSelector:@selector(sharedInstance)] ? [mgrCls sharedInstance] : nil;
    out[@"CCUIModuleInstanceManager.sharedInstance"] = mgr ? @"present" : @"MISSING";
    out[@"CCUIModuleInstanceManager._moduleInstanceByIdentifier"] =
        CC27ReconProbeKey(mgr, @"_moduleInstanceByIdentifier");
    out[@"CCUIModuleInstanceManager._repository"] = CC27ReconProbeKey(mgr, @"_repository");

    return out;
}

/// One node per view: ObjC class, depth, geometry. `objc_class` is the field the
/// host tools fall back to when there is no Swift `type` (CC's UI is all ObjC).
static void CC27ReconCollectView(UIView *view, NSUInteger depth, NSMutableArray *out) {
    if (!view || depth > kCC27ReconMaxDepth || out.count >= kCC27ReconMaxNodes) return;

    CGRect f = view.frame;
    NSMutableDictionary *node = [@{
        @"objc_class": NSStringFromClass(view.class) ?: @"?",
        @"role": @"view",
        @"depth": @(depth),
        @"address": [NSString stringWithFormat:@"%p", view],
        @"frame": [NSString stringWithFormat:@"%.0f,%.0f,%.0fx%.0f",
                   f.origin.x, f.origin.y, f.size.width, f.size.height],
        @"hidden": @(view.isHidden),
    } mutableCopy];

    // For module containers, exercise the exact ancestor + KVC path the styling
    // hook uses, so a dump proves whether that lookup still works.
    if ([view isKindOfClass:NSClassFromString(@"CCUIContentModuleContentContainerView")]) {
        node[@"in_control_center"] = @(CC27ViewIsInControlCenter(view));
        UIViewController *owner = nil;
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            SEL sel = NSSelectorFromString(@"_viewControllerForAncestor");
            for (UIView *v = view; v; v = v.superview) {
                id vc = [v respondsToSelector:sel] ? [v performSelector:sel] : nil;
                if ([vc isKindOfClass:NSClassFromString(@"CCUIContentModuleContainerViewController")]) {
                    owner = vc;
                    break;
                }
            }
#pragma clang diagnostic pop
        } @catch (__unused NSException *e) {}
        node[@"module_identifier"] = CC27ReconProbeKey(owner, @"moduleIdentifier");
        node[@"module_view_delegate"] = CC27ReconProbeKey(owner, @"_viewDelegate");
    }

    [out addObject:node];
    for (UIView *sub in view.subviews) {
        CC27ReconCollectView(sub, depth + 1, out);
    }
}

/// Main thread only. Snapshots into plain collections, then hands the write off.
static void CC27WriteReconDump(UIViewController *host) {
    if (!CC27Prefs.shared.reconDump) return;
    if (gCC27ReconDumpCount >= kCC27ReconMaxDumps) return;
    if ([CC27EditSession deviceUILocked]) return;
    if (!host.isViewLoaded || !host.view.window) return;

    @try {
        NSMutableArray *collected = [NSMutableArray array];
        CC27ReconCollectView(host.view, 0, collected);

        // Freeze before handing off: the background queue must never see a
        // collection the main thread could still be holding a mutable ref to.
        NSArray *nodes = [collected copy];
        NSUInteger nodeCount = nodes.count;

        NSDictionary *payload = @{
            @"milestone": @"cc27-recon",
            @"probe": @{
                @"host_class": NSStringFromClass(host.class) ?: @"?",
                @"dump_index": @(gCC27ReconDumpCount),
                @"truncated": @(nodeCount >= kCC27ReconMaxNodes),
            },
            @"fields": CC27ReconProbeFields(),
            @"nodes": nodes,
        };
        gCC27ReconDumpCount++; // main thread only (viewDidAppear) — no barrier needed

        // UIKit reads are done; serialization and file I/O must not sit on the main thread.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try {
                NSString *path = SPWriteJSONDump(payload);
                NSLog(@"[CC27] recon dump %@ (%lu nodes)",
                      path ?: @"FAILED", (unsigned long)nodeCount);
            } @catch (NSException *e) {
                NSLog(@"[CC27] recon dump write threw (suppressed): %@", e);
            }
        });
    } @catch (NSException *e) {
        NSLog(@"[CC27] recon dump threw (suppressed): %@", e);
    }
}

%group CC27

%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    // Fully inert while locked — CC presented over the lock screen stays stock.
    if ([CC27EditSession deviceUILocked]) return;
    [CC27EditSession.shared setHostVisible:YES host:self];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    if ([CC27EditSession deviceUILocked]) return;
    [CC27EditSession.shared setHostVisible:YES host:self];
    // Fully presented and laid out — the only point where a snapshot is both
    // meaningful and far away from the boot path. No-op unless reconDump is on.
    CC27WriteReconDump(self);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    [CC27EditSession.shared setHostVisible:NO host:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    [CC27EditSession.shared setHostVisible:NO host:self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    // Chrome is created lazily on first presentation (viewWillAppear), not at
    // SpringBoard boot — here we only keep existing chrome positioned.
    if (CC27EditSession.shared.hostVisible) {
        [CC27EditSession.shared layoutChromeOnHost:self];
    }
}

- (void)setPresentationState:(NSInteger)state {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    if ([CC27EditSession deviceUILocked]) {
        [CC27EditSession.shared setHostVisible:NO host:self];
        return;
    }
    [CC27EditSession.shared updateChromeForPresentationState:state host:self];
}

%end

%hook CCUIContentModuleContentContainerView

// The layoutSubviews guard below refuses to classify a container that is not in a
// window yet, because its superview chain is still incomplete. That is the right
// call for safety, but it would leave a module unstyled if it never got another
// layout pass afterwards. Once the container is actually hosted it can be
// classified, so ask for one more pass — real CC modules keep their glass, and
// Lock Screen quick actions still fail the check and are left alone.
- (void)didMoveToWindow {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    if (self.window && CC27ViewIsInControlCenter(self)) {
        [self setNeedsLayout];
    }
}

- (void)layoutSubviews {
    %orig;
    if (!CC27Prefs.shared.enabled) return;
    // Never touch module containers hosted outside Control Center (Lock
    // Screen quick actions on iOS 16 use this same class). Glass styling is
    // allowed while locked — real CC opened from the lock screen has
    // ControlCenter ancestors, quick actions never do. Edit chrome stays
    // unlock-only (gated inside CC27EditSession).
    if (!CC27ViewIsInControlCenter(self)) return;
    @try {
        if (CC27Prefs.shared.glassChrome) {
            [CC27Glass applyToModuleContainer:self];
        }
        if (CC27EditSession.shared.editing) {
            NSString *identifier = nil;
            UIView *v = self;
            while (v) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                SEL sel = NSSelectorFromString(@"_viewControllerForAncestor");
                UIViewController *vc = [v respondsToSelector:sel] ? [v performSelector:sel] : nil;
#pragma clang diagnostic pop
                if ([vc isKindOfClass:NSClassFromString(@"CCUIContentModuleContainerViewController")]) {
                    @try { identifier = [vc valueForKey:@"moduleIdentifier"]; } @catch (__unused NSException *e) {}
                    break;
                }
                v = v.superview;
            }
            if (identifier.length) {
                [CC27EditSession.shared decorateModuleContainer:self identifier:identifier];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[CC27] module styling threw (suppressed): %@", e);
    }
}

%end // CCUIContentModuleContentContainerView

%end // group

// Installs the hooks. Called well after SpringBoard finishes launching so that
// CC27 contributes exactly zero work to the boot-critical path (the ~60 s
// boot hang + watchdog reload came from tweak code running during launch).
static void CC27InstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!CC27Prefs.shared.enabled) {
            NSLog(@"[CC27] disabled in prefs — hooks not installed");
            return;
        }
        %init(CC27);
        NSLog(@"[CC27] 1.0.9 hooks installed (post-launch)");
    });
}

%ctor {
    @autoreleasepool {
        // Emergency kill switch: create this file (e.g. via SSH/Filza) and
        // respring to fully disable CC27 without uninstalling:
        //   touch <jbroot>/var/mobile/Library/Preferences/com.kolby.cc27.killswitch
        //
        // Resolved through the jbroot prefix, same as the prefs lookup. The old
        // hardcoded /var/mobile path was unreachable on roothide, so the one
        // escape hatch from a boot hang silently did nothing there.
        NSString *killRel = @"/var/mobile/Library/Preferences/com.kolby.cc27.killswitch";
        NSMutableArray<NSString *> *killPaths = [NSMutableArray array];
        NSString *jbPrefix = CC27JailbreakRootPrefix();
        if (jbPrefix.length > 0) {
            [killPaths addObject:[jbPrefix stringByAppendingString:killRel]];
        }
        [killPaths addObject:[@"/var/jb" stringByAppendingString:killRel]];
        [killPaths addObject:killRel];
        for (NSString *killPath in killPaths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:killPath]) {
                NSLog(@"[CC27] kill switch present (%@) — not loading", killPath);
                return;
            }
        }
        [CC27Prefs.shared reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        CC27ReloadPrefs,
                                        CFSTR("com.kolby.cc27/ReloadPrefs"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        // Do NOT hook anything yet. SpringBoard's launch (including the first
        // lock screen) runs 100% stock; hooks arrive a moment after
        // UIApplicationDidFinishLaunching, safely outside the watchdog window.
        // Control Center isn't usable that early anyway, so nothing is lost.
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
                CC27InstallHooks();
            });
        }];
        NSLog(@"[CC27] 1.0.9 loaded — waiting for SpringBoard launch to finish before hooking");
    }
}
