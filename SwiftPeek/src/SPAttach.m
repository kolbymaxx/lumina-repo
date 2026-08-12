#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "SPPrefs.h"
#import "SPSwiftMeta.h"
#import "SPDumpWriter.h"
#import "SPFieldWalk.h"
#import "SPRenderPeek.h"
#import "SPIconPeek.h"

// -----------------------------------------------------------------------------
// SwiftPeek — read-only SwiftUI inspector (Phase 1 / milestones 1–2)
// -----------------------------------------------------------------------------

static NSMutableSet *gSPLoggedHosts;
static NSInteger gSPAttachCount = 0;
static const NSInteger kSPMaxAttachLogs = 48;
static BOOL gSPHookedHostingView = NO;
static BOOL gSPHookedHostingController = NO;
static NSString *gSPHookedViewClassName;
static NSString *gSPHookedControllerClassName;
static NSMutableSet *gSPSwizzledKeys;

// Per-class originals — NEVER share one global IMP across classes (UI freezes / crashes).
static NSMutableDictionary<NSString *, NSValue *> *gSPOrigLayoutByClass;    // class name -> IMP
static NSMutableDictionary<NSString *, NSValue *> *gSPOrigDidLayoutByClass;

static void SPStartIfEnabled(void);
static void SPWriteHeartbeat(NSString *message, BOOL hooked,
                             NSArray *viewNames, NSArray *controllerNames);
static void SPHookedLayoutSubviews(UIView *self, SEL _cmd);
static void SPHookedViewDidLayout(UIViewController *self, SEL _cmd);

static void SPEnsureOrigMaps(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSPOrigLayoutByClass = [NSMutableDictionary dictionary];
        gSPOrigDidLayoutByClass = [NSMutableDictionary dictionary];
        gSPSwizzledKeys = [NSMutableSet set];
    });
}

/// True only when `sel` is implemented on `cls` itself (not inherited).
static BOOL SPClassOwnsInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    Class superCls = class_getSuperclass(cls);
    if (!superCls) return YES;
    Method sm = class_getInstanceMethod(superCls, sel);
    if (m != sm) return YES;
    // Belt-and-suspenders: some runtimes alias Method pointers oddly.
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    if (!list) return NO;
    BOOL owns = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { owns = YES; break; }
    }
    free(list);
    return owns;
}

/// Walk to the class in `cls`'s hierarchy that actually implements `sel`.
static Class SPClassProvidingInstanceMethod(Class cls, SEL sel) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (SPClassOwnsInstanceMethod(c, sel)) return c;
    }
    return Nil;
}

static IMP SPLookupOrigIMP(NSDictionary<NSString *, NSValue *> *map, Class start) {
    if (!map || !start) return NULL;
    for (Class cls = start; cls; cls = class_getSuperclass(cls)) {
        const char *name = class_getName(cls);
        if (!name) continue;
        NSValue *boxed = map[@(name)];
        if (boxed) return (IMP)boxed.pointerValue;
    }
    return NULL;
}

static void SPCallOrigLayoutSubviews(UIView *self, SEL _cmd) {
    IMP imp = SPLookupOrigIMP(gSPOrigLayoutByClass, object_getClass(self));
    if (!imp) {
        // Fail-open without super (super can re-enter our hook on subclasses).
        imp = class_getMethodImplementation([UIView class], _cmd);
    }
    if (imp && imp != (IMP)SPHookedLayoutSubviews) {
        ((void (*)(id, SEL))imp)(self, _cmd);
    }
}

static void SPCallOrigViewDidLayout(UIViewController *self, SEL _cmd) {
    IMP imp = SPLookupOrigIMP(gSPOrigDidLayoutByClass, object_getClass(self));
    if (!imp) {
        imp = class_getMethodImplementation([UIViewController class], _cmd);
    }
    if (imp && imp != (IMP)SPHookedViewDidLayout) {
        ((void (*)(id, SEL))imp)(self, _cmd);
    }
}

static void SPPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    SPPrefsInvalidate();
    // Stay off the main queue — Music's UI thread is sacred.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            if (SPPrefBool(@"enabled", NO)) {
                dispatch_async(dispatch_get_main_queue(), ^{ SPStartIfEnabled(); });
            } else {
                SPWriteHeartbeat(@"disabled via prefs", NO, @[], @[]);
            }
        } @catch (__unused id e) {}
    });
}

static void SPEnsureSwiftUILoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
                    RTLD_LAZY | RTLD_NOLOAD)) {
            dlopen("/System/Library/Frameworks/SwiftUI.framework/SwiftUI", RTLD_LAZY);
        }
        NSBundle *b = [NSBundle bundleWithPath:@"/System/Library/Frameworks/SwiftUI.framework"];
        if (b && !b.isLoaded) [b load];
    });
}

static BOOL SPIsBoringTypeName(NSString *name) {
    if (name.length == 0) return YES;
    static NSSet *boring;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        boring = [NSSet setWithArray:@[
            @"UIView", @"UIViewController", @"UIWindow", @"UIWindowController",
            @"UILayoutContainerView", @"UITransitionView", @"UIDropShadowView",
            @"UINavigationController", @"UITabBarController", @"UIApplicationRotationFollowingController",
            @"<unknown>",
        ]];
    });
    if ([boring containsObject:name]) return YES;
    // Still boring if it's a plain UIKit class with no SwiftUI / app module signal.
    if ([name hasPrefix:@"UI"] && [name rangeOfString:@"Hosting"].location == NSNotFound) {
        return YES;
    }
    return NO;
}

static BOOL SPClassNameLooksLikeHostingView(const char *name) {
    if (!name) return NO;
    if (strstr(name, "_UIHostingView") != NULL) return YES;
    if (strstr(name, "UIHostingView") != NULL) return YES;
    // Mangled Swift generics often embed HostingView without the UIKit spelling.
    if (strstr(name, "HostingView") != NULL && strstr(name, "Controller") == NULL) {
        return YES;
    }
    return NO;
}

/// True for live `_UIHostingView` instances (incl. generic subclasses).
static BOOL SPViewIsHostingView(UIView *v) {
    if (!v) return NO;
    @try {
        if ([v isKindOfClass:[UIViewController class]]) return NO;
        Class hv = NSClassFromString(@"_UIHostingView");
        if (hv && [v isKindOfClass:hv]) return YES;
        Class hv2 = NSClassFromString(@"UIHostingView");
        if (hv2 && [v isKindOfClass:hv2]) return YES;
        const char *cn = object_getClassName(v);
        if (SPClassNameLooksLikeHostingView(cn)) return YES;
        NSString *tn = SPSwiftTypeNameFromObject(v);
        if (tn.length == 0) return NO;
        if ([tn rangeOfString:@"_UIHostingView"].location != NSNotFound) return YES;
        if ([tn rangeOfString:@"UIHostingView"].location != NSNotFound) return YES;
        if ([tn rangeOfString:@"HostingView"].location != NSNotFound &&
            [tn rangeOfString:@"Controller"].location == NSNotFound) {
            return YES;
        }
    } @catch (__unused id e) {}
    return NO;
}

static BOOL SPClassNameLooksLikeHostingController(const char *name) {
    if (!name) return NO;
    // Narrow: real SwiftUI hosting only. Bare "*HostingController*" matched Music
    // helpers that inherit viewDidLayoutSubviews from UIViewController — 0.2.4
    // then walked up and swizzled UIViewController itself (Music crash).
    if (strcmp(name, "UIHostingController") == 0) return YES;
    if (strstr(name, "UIHostingController") != NULL) return YES;
    return NO;
}

static BOOL SPIsForbiddenHookTarget(Class cls) {
    if (!cls) return YES;
    if (cls == [UIView class] || cls == [UIViewController class]) return YES;
    if (cls == [UIResponder class] || cls == [NSObject class]) return YES;
    const char *name = class_getName(cls);
    if (!name) return YES;
    if (strcmp(name, "UIView") == 0 || strcmp(name, "UIViewController") == 0) return YES;
    if (strcmp(name, "UIResponder") == 0 || strcmp(name, "NSObject") == 0) return YES;
    return NO;
}

static NSInteger SPHostingControllerRank(const char *name) {
    if (!name) return 0;
    if (strcmp(name, "UIHostingController") == 0) return 100;
    if (strstr(name, "SwiftUI") && strstr(name, "UIHostingController")) return 90;
    if (strstr(name, "UIHostingController") != NULL) return 80;
    if (strstr(name, "HostingController") != NULL) return 40;
    return 10;
}

static void SPWriteHeartbeat(NSString *message, BOOL hooked,
                             NSArray *viewNames, NSArray *controllerNames) {
    NSMutableArray *prefsInfo = [NSMutableArray array];
    for (NSString *p in SPPrefsCandidatePaths()) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:p];
        [prefsInfo addObject:@{ @"path": p, @"exists": @(exists) }];
    }
    SPWriteStatus(@{
        @"status": hooked ? @"hooked" : @"loaded",
        @"enabled": @(SPPrefBool(@"enabled", NO)),
        @"jbroot": SPJailbreakRootPrefix() ?: @"",
        @"prefs_paths": prefsInfo,
        @"hosting_view": @((viewNames.count > 0) || gSPHookedHostingView),
        @"hosting_controller": @((controllerNames.count > 0) || gSPHookedHostingController),
        @"hosting_view_names": viewNames ?: @[],
        @"hosting_controller_names": controllerNames ?: @[],
        @"hooked_view_class": gSPHookedViewClassName ?: [NSNull null],
        @"hooked_controller_class": gSPHookedControllerClassName ?: [NSNull null],
        @"hooked": @(hooked),
        @"message": message ?: @"",
    });
}

/// Collect hosting views under `root` (BFS). Dedupes by pointer.
static NSArray<UIView *> *SPCollectHostingViews(UIView *root, NSInteger maxNodes,
                                                NSInteger maxResults) {
    if (!root || maxNodes <= 0 || maxResults <= 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger n = 0;
    while (q.count && n < maxNodes && (NSInteger)out.count < maxResults) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        NSValue *key = [NSValue valueWithNonretainedObject:v];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        n++;
        if (SPViewIsHostingView(v)) [out addObject:v];
        for (UIView *sub in v.subviews) [q addObject:sub];
    }
    return out;
}

static UIView *SPFindHostingViewBFS(UIView *root, NSInteger maxNodes) {
    NSArray *found = SPCollectHostingViews(root, maxNodes, 1);
    return found.firstObject;
}

/// Unique view class names seen in a shallow BFS — diagnostics when hosts=0.
static NSArray<NSString *> *SPSampleViewClassNames(UIView *root, NSInteger maxNodes,
                                                   NSInteger maxNames) {
    if (!root || maxNodes <= 0 || maxNames <= 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seenNames = [NSMutableSet set];
    NSMutableSet *seenPtrs = [NSMutableSet set];
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger n = 0;
    while (q.count && n < maxNodes && (NSInteger)out.count < maxNames) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        NSValue *key = [NSValue valueWithNonretainedObject:v];
        if ([seenPtrs containsObject:key]) continue;
        [seenPtrs addObject:key];
        n++;
        NSString *cn = @(object_getClassName(v) ?: "?");
        if (![seenNames containsObject:cn]) {
            [seenNames addObject:cn];
            // Skip pure UIKit noise; keep anything that might be a host/app view.
            BOOL keep = SPClassNameLooksLikeHostingView(cn.UTF8String) ||
                        [cn rangeOfString:@"Hosting"].location != NSNotFound ||
                        [cn rangeOfString:@"SwiftUI"].location != NSNotFound ||
                        [cn hasPrefix:@"_Tt"] ||
                        [cn hasPrefix:@"Music"] ||
                        [cn rangeOfString:@"MusicApplication"].location != NSNotFound;
            if (keep) [out addObject:cn];
        }
        for (UIView *sub in v.subviews) [q addObject:sub];
    }
    return out;
}

static void SPAddScreenString(NSMutableArray *out, NSMutableSet *seen, NSString *raw) {
    if (!raw) return;
    NSString *t = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2 || t.length > 80) return;
    if ([seen containsObject:t]) return;
    [seen addObject:t];
    [out addObject:t];
}

/// Visible UIKit strings under a view — safe M2 pixel correspondence (no Swift meta).
static NSArray<NSString *> *SPScreenStrings(UIView *root) {
    if (!root) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 64;
    while (q.count && budget-- > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            SPAddScreenString(out, seen, [(UILabel *)v text]);
        } else if ([v isKindOfClass:[UIButton class]]) {
            SPAddScreenString(out, seen, [(UIButton *)v titleForState:UIControlStateNormal]);
        } else if ([v isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)v;
            SPAddScreenString(out, seen, tf.text.length ? tf.text : tf.placeholder);
        } else if ([v isKindOfClass:[UINavigationBar class]]) {
            UINavigationItem *item = [(UINavigationBar *)v topItem];
            SPAddScreenString(out, seen, item.title);
        }
        SPAddScreenString(out, seen, v.accessibilityLabel);
        for (UIView *sub in v.subviews) [q addObject:sub];
        if (out.count >= 16) break;
    }
    return out;
}

/// Cheap titles from a VC without forcing view load.
static NSArray<NSString *> *SPControllerTitles(UIViewController *vc) {
    if (!vc) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    SPAddScreenString(out, seen, vc.title);
    SPAddScreenString(out, seen, vc.navigationItem.title);
    SPAddScreenString(out, seen, vc.tabBarItem.title);
    return out;
}

static void SPLogAttachObject(id object, NSString *role) {
    if (!object) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSPLoggedHosts = [NSMutableSet set];
    });

    NSValue *key = [NSValue valueWithNonretainedObject:object];
    if ([gSPLoggedHosts containsObject:key]) return;
    if (gSPAttachCount >= kSPMaxAttachLogs) return;

    NSString *objcName = @(object_getClassName(object) ?: "?");
    NSString *typeName = SPSwiftTypeNameFromObject(object) ?: objcName;

    // Milestone 1 proof needs a real SwiftUI / app type — skip plain UIKit noise.
    if (SPIsBoringTypeName(typeName) && SPIsBoringTypeName(objcName)) {
        return;
    }

    [gSPLoggedHosts addObject:key];
    gSPAttachCount++;

    uintptr_t addr = (uintptr_t)(__bridge void *)object;
    if (SPPrefBool(@"logAttach", YES)) {
        NSLog(@"[SwiftPeek] attach process=%@ role=%@ type=%@ objc=%@ addr=0x%lx",
              NSProcessInfo.processInfo.processName ?: @"?",
              role, typeName, objcName, (unsigned long)addr);
    }

    // Heavy field / mirror work off the layout path.
    id obj = object;
    NSString *roleCopy = [role copy] ?: @"";
    NSString *objcCopy = objcName;
    NSString *typeCopy = typeName;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary *node = [@{
            @"address": [NSString stringWithFormat:@"0x%lx", (unsigned long)addr],
            @"objc_class": objcCopy,
            @"role": roleCopy,
            @"type": typeCopy,
        } mutableCopy];

        NSInteger milestone = 1;
        // Screen strings are relatively safe. Metadata field walks are opt-in
        // via dumpFieldMeta — walking Music UIViewControllers SIGSEGV'd on 0.3.0.
        if (SPPrefBool(@"dumpFields", NO)) {
            @try {
                UIView *view = nil;
                if ([obj isKindOfClass:[UIView class]]) {
                    view = (UIView *)obj;
                } else if ([obj isKindOfClass:[UIViewController class]]) {
                    UIViewController *vc = (UIViewController *)obj;
                    if (vc.isViewLoaded) view = vc.view;
                }
                if (view) {
                    NSArray *screen = SPScreenStrings(view);
                    if (screen.count) {
                        node[@"screen_strings"] = screen;
                        milestone = 2;
                    }
                }
            } @catch (__unused id e) {}
        }
        if (SPPrefBool(@"dumpFieldMeta", NO)) {
            @try {
                // Hosting UIViews only — never Music / hosting controllers.
                BOOL allow = [obj isKindOfClass:[UIView class]] &&
                             SPViewIsHostingView((UIView *)obj);
                if (allow) {
                    NSArray *fields = SPWalkFields(obj, 0, 8);
                    if (fields.count) {
                        node[@"fields"] = fields;
                        milestone = 2;
                    } else {
                        node[@"meta_empty"] = @YES;
                    }
                } else {
                    node[@"meta_skipped"] = @"not_hosting_view";
                }
            } @catch (__unused id e) {}
        }

        NSDictionary *payload = @{
            @"milestone": @(milestone),
            @"nodes": @[node],
        };
        NSString *path = SPWriteJSONDump(payload);
        SPWriteHeartbeat(path ? @"attach dump written" : @"attach seen but dump write failed",
                         YES, @[], @[]);
        if (path) NSLog(@"[SwiftPeek] dump written %@ milestone=%ld", path, (long)milestone);
    });
}

static void SPHookedLayoutSubviews(UIView *self, SEL _cmd) {
    SPCallOrigLayoutSubviews(self, _cmd);
    // Never do attach work synchronously on the layout path.
    UIView *view = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { SPLogAttachObject(view, @"hosting_view"); } @catch (__unused id e) {}
    });
}

static void SPHookedViewDidLayout(UIViewController *self, SEL _cmd) {
    SPCallOrigViewDidLayout(self, _cmd);
    UIViewController *vc = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SPLogAttachObject(vc, @"hosting_controller");
            UIView *hosting = SPFindHostingViewBFS(vc.view, 64);
            if (hosting) SPLogAttachObject(hosting, @"hosting_view");
        } @catch (__unused id e) {}
    });
}

/// Swizzle only methods owned by `cls`. Store original IMP in per-class map.
static BOOL SPSwizzleOwned(Class cls, SEL sel, IMP replacement,
                           NSMutableDictionary<NSString *, NSValue *> *origMap) {
    if (!cls || !sel || !replacement || !origMap) return NO;
    SPEnsureOrigMaps();

    const char *cname = class_getName(cls);
    if (!cname) return NO;
    NSString *classKey = @(cname);
    NSString *key = [NSString stringWithFormat:@"%@|%s", classKey, sel_getName(sel)];
    if ([gSPSwizzledKeys containsObject:key]) return YES;

    // Critical: do not touch inherited Method slots (would rewrite the superclass).
    if (!SPClassOwnsInstanceMethod(cls, sel)) return NO;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP current = method_getImplementation(m);
    if (current == replacement) {
        [gSPSwizzledKeys addObject:key];
        return YES;
    }

    IMP prev = method_setImplementation(m, replacement);
    if (!prev) return NO;
    origMap[classKey] = [NSValue valueWithPointer:(const void *)prev];
    [gSPSwizzledKeys addObject:key];
    return YES;
}

static void SPTryInstallHooks(void) {
    SPEnsureSwiftUILoaded();

    NSMutableArray *viewClasses = [NSMutableArray array];
    NSMutableArray *viewNames = [NSMutableArray array];
    NSMutableArray *vcClasses = [NSMutableArray array];
    NSMutableArray *vcNames = [NSMutableArray array];

    Class directView = NSClassFromString(@"_UIHostingView");
    if (directView && [directView isSubclassOfClass:[UIView class]]) {
        [viewNames addObject:@"_UIHostingView"];
        [viewClasses addObject:[NSValue valueWithPointer:(__bridge void *)directView]];
    }

    Class directVC = NSClassFromString(@"UIHostingController");
    if (directVC && [directVC isSubclassOfClass:[UIViewController class]]) {
        [vcNames addObject:@"UIHostingController"];
        [vcClasses addObject:[NSValue valueWithPointer:(__bridge void *)directVC]];
    }

    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (list) {
        for (unsigned int i = 0; i < n; i++) {
            const char *name = class_getName(list[i]);
            if (!name) continue;

            if (SPClassNameLooksLikeHostingView(name)) {
                [viewNames addObject:@(name)];
                if ([list[i] isSubclassOfClass:[UIView class]]) {
                    [viewClasses addObject:[NSValue valueWithPointer:(__bridge void *)list[i]]];
                }
            }
            if (SPClassNameLooksLikeHostingController(name)) {
                [vcNames addObject:@(name)];
                if ([list[i] isSubclassOfClass:[UIViewController class]]) {
                    [vcClasses addObject:[NSValue valueWithPointer:(__bridge void *)list[i]]];
                }
            }
        }
        free(list);
    }

    SPEnsureOrigMaps();

    // Only swizzle an owner that (1) owns the method, (2) still looks like a
    // hosting type, (3) is never a UIKit base class. Walking to UIViewController
    // in 0.2.4 crashed Music on first layout.
    NSMutableArray *hookedViewOwners = [NSMutableArray array];
    NSMutableSet *viewTargets = [NSMutableSet set];
    NSInteger viewHooks = 0;
    for (NSValue *v in viewClasses) {
        Class cand = (Class)v.pointerValue;
        Class owner = SPClassProvidingInstanceMethod(cand, @selector(layoutSubviews));
        if (!owner || SPIsForbiddenHookTarget(owner)) continue;
        const char *oname = class_getName(owner);
        if (!SPClassNameLooksLikeHostingView(oname)) continue;
        NSString *name = @(oname);
        if ([viewTargets containsObject:name]) continue;
        [viewTargets addObject:name];
        if (SPSwizzleOwned(owner, @selector(layoutSubviews),
                           (IMP)SPHookedLayoutSubviews,
                           gSPOrigLayoutByClass)) {
            viewHooks++;
            [hookedViewOwners addObject:name];
            if (!gSPHookedViewClassName) gSPHookedViewClassName = name;
        }
    }
    if (viewHooks > 0) gSPHookedHostingView = YES;

    NSArray *sorted = [vcClasses sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        const char *an = class_getName((Class)a.pointerValue);
        const char *bn = class_getName((Class)b.pointerValue);
        NSInteger ar = SPHostingControllerRank(an);
        NSInteger br = SPHostingControllerRank(bn);
        if (ar != br) return ar > br ? NSOrderedAscending : NSOrderedDescending;
        size_t al = an ? strlen(an) : 9999;
        size_t bl = bn ? strlen(bn) : 9999;
        if (al == bl) return NSOrderedSame;
        return al < bl ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray *hookedVCOwners = [NSMutableArray array];
    NSMutableSet *vcTargets = [NSMutableSet set];
    NSInteger vcHooks = 0;
    for (NSValue *v in sorted) {
        if (vcHooks >= 4) break;
        Class cand = (Class)v.pointerValue;
        Class owner = SPClassProvidingInstanceMethod(cand, @selector(viewDidLayoutSubviews));
        if (!owner || SPIsForbiddenHookTarget(owner)) continue;
        const char *oname = class_getName(owner);
        if (!SPClassNameLooksLikeHostingController(oname)) continue;
        NSString *name = @(oname);
        if ([vcTargets containsObject:name]) continue;
        [vcTargets addObject:name];
        if (SPSwizzleOwned(owner, @selector(viewDidLayoutSubviews),
                           (IMP)SPHookedViewDidLayout,
                           gSPOrigDidLayoutByClass)) {
            vcHooks++;
            [hookedVCOwners addObject:name];
            if (!gSPHookedControllerClassName) gSPHookedControllerClassName = name;
        }
    }
    if (vcHooks > 0) gSPHookedHostingController = YES;

    BOOL hooked = gSPHookedHostingView || gSPHookedHostingController;
    NSString *msg = nil;
    if (hooked) {
        msg = [NSString stringWithFormat:
               @"hooks installed (views=%ld controllers=%ld) viewOwners=%@ vcOwners=%@",
               (long)viewHooks, (long)vcHooks, hookedViewOwners, hookedVCOwners];
    } else if (viewNames.count || vcNames.count) {
        msg = [NSString stringWithFormat:
               @"candidates but no safe owners (views=%lu controllers=%lu)",
               (unsigned long)viewNames.count, (unsigned long)vcNames.count];
    } else {
        msg = @"enabled but no hosting classes visible yet";
    }
    SPWriteHeartbeat(msg, hooked, viewNames, vcNames);
    NSLog(@"[SwiftPeek] %@", msg);

    static NSInteger sSPHookProbeCount = 0;
    if (sSPHookProbeCount < 3) {
        sSPHookProbeCount++;
        SPWriteJSONDump(@{
            @"milestone": hooked ? @1 : @0,
            @"probe": @YES,
            @"message": msg ?: @"",
            @"hooked": @(hooked),
            @"hooked_view_owners": hookedViewOwners,
            @"hooked_controller_owners": hookedVCOwners,
            @"nodes": @[],
        });
    }
}

static void SPOnImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    if (!SPPrefBool(@"installHooks", NO)) return;
    const char *imageName = NULL;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == mh) {
            imageName = _dyld_get_image_name(i);
            break;
        }
    }
    if (!imageName || !strstr(imageName, "SwiftUI")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (SPPrefBool(@"installHooks", NO)) SPTryInstallHooks();
    });
}

static BOOL SPIsSpringBoard(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:@"com.apple.springboard"];
}

/// Disk kill switch. Checked before prefs and before anything else runs, so a
/// target that will not boot far enough to reach Settings can still be shut off
/// over SSH:  `touch /var/jb/var/mobile/Library/SwiftPeek/DISABLE`
///
/// This matters most for SpringBoard — a broken app costs a relaunch, a broken
/// SpringBoard costs a device you cannot drive.
static BOOL SPKillSwitchEngaged(void) {
    static BOOL engaged = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *rel = @"/var/mobile/Library/SwiftPeek/DISABLE";
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        NSString *jb = SPJailbreakRootPrefix();
        if (jb.length) [paths addObject:[jb stringByAppendingString:rel]];
        [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
        [paths addObject:rel];
        for (NSString *p in paths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                engaged = YES;
                NSLog(@"[SwiftPeek] kill switch present at %@ — refusing to attach", p);
                return;
            }
        }
    });
    return engaged;
}

/// Per-process opt-in. Every target defaults OFF except Music, which is the
/// only one with a crash-tested field-walk allowlist behind it
/// (`SPClassNameIsMusicMetaView`). That allowlist does NOT transfer, so a newly
/// enabled target gets the window/VC tree only until it earns more.
///
/// SPRINGBOARD IS IN THE TABLE, AND THAT IS SETTLED BY DEVICE EVIDENCE.
///
/// The two branches this file was merged from disagreed about it. The
/// pref-driven side said SpringBoard was "deliberately absent" until the kill
/// switch had been exercised on a lower-risk target; the recon side said an
/// ObjC-only build was a different proposition from the Swift-linked one that
/// caused the 0.2.1 Safe Mode. The recon side is right, and not as an argument:
/// on 2026-08-10, 0.4.0 took four SpringBoard dumps on iPhone13,1 / iOS 17.3
/// with `targetSpringBoard` + `sbScanWindows` + `iconInventory` all on — no
/// Safe Mode, no respring loop.
///
/// Two caveats stay on the record: one device, one firmware, and 16.7 untried.
/// SpringBoard therefore keeps a second gate (`sbScanWindows`) that no other
/// target has, and `dumpFieldMeta` is forced off there regardless of pref.
static BOOL SPIsAllowedProcess(void) {
    if (SPKillSwitchEngaged()) return NO;

    NSString *name = NSProcessInfo.processInfo.processName ?: @"";
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";

    // name, bundle id, pref key, default
    NSArray<NSArray *> *targets = @[
        @[ @"Music",           @"com.apple.Music",           @"targetMusic",      @YES ],
        @[ @"Podcasts",        @"com.apple.podcasts",        @"targetPodcasts",   @NO  ],
        @[ @"TV",              @"com.apple.tv",              @"targetTV",         @NO  ],
        @[ @"Preferences",     @"com.apple.Preferences",     @"targetSettings",   @NO  ],
        @[ @"SiriViewService", @"com.apple.SiriViewService", @"targetSiriView",   @NO  ],
        @[ @"assistantd",      @"com.apple.assistantd",      @"targetAssistantd", @NO  ],
        // One more row rather than a special case. The key name is unchanged so
        // SPIconPeek's own gate still reads the same pref.
        @[ @"SpringBoard",     @"com.apple.springboard",     @"targetSpringBoard", @NO ],
    ];

    for (NSArray *t in targets) {
        BOOL matches = [name isEqualToString:t[0]] || [bundle isEqualToString:t[1]];
        if (!matches) continue;
        return SPPrefBool(t[2], [t[3] boolValue]);
    }

    // Never attach to a process we have not explicitly reasoned about, even if
    // the MobileSubstrate filter somehow loads us there.
    return NO;
}

static BOOL gSPDyldWatchInstalled = NO;

#pragma mark - Window tree (0.4.0)

/// Read-only snapshot of every UIWindow in the process, ordered the way the
/// compositor stacks them (ascending windowLevel).
///
/// This is deliberately the safest thing SwiftPeek does: plain property reads,
/// no field walking, no Swift metadata. It exists because Music27 burned four
/// device cycles guessing at window level and opacity with no way to see
/// either. `level`, `hidden`, `alpha`, `background` and `opaque` together
/// explain both failure modes we hit — a window that paints over the app, and
/// a window that never composites at all.
///
/// Each window also carries a shallow view subtree (`views`), because knowing
/// the overlay window is correct is only half an answer: an overlay that exists
/// at the right level with the right frame can still show nothing if the view
/// inside it is zero-sized, transparent or hidden. Depth- and breadth-capped so
/// this stays a bounded walk, never a full hierarchy dump.
static NSString *SPColorDescription(UIColor *color) {
    if (!color) return @"nil";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        if (a < 0.001) return @"clear";
        return [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a];
    }
    CGFloat w = 0;
    if ([color getWhite:&w alpha:&a]) {
        if (a < 0.001) return @"clear";
        return [NSString stringWithFormat:@"white(%.2f,a=%.2f)", w, a];
    }
    return color.description ?: @"?";
}

static NSString *SPRectString(CGRect r) {
    return [NSString stringWithFormat:@"{%.0f,%.0f,%.0f,%.0f}",
            r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *SPCGColorDescription(CGColorRef cg) {
    if (!cg) return @"nil";
    return SPColorDescription([UIColor colorWithCGColor:cg]);
}

/// Colour that lives on the layer rather than on the view.
///
/// THE VIEW WALK ANSWERS "WHAT IS THERE", NOT "WHAT COLOUR IS IT".
///
/// Music's full-screen player derives its whole background from the artwork —
/// warm brown behind a gold cover, periwinkle behind a grey one, transport
/// glyphs tinted to match. A tweak trying to reproduce that wants to read the
/// colour Apple already computed rather than derive a worse one from the same
/// image. But `view.backgroundColor` is nil for it: the offline catalog lists
/// `gradientLayer` and `destOverLayer` on `MusicApplication.PaletteContainerView`,
/// so the colour is in a `CAGradientLayer`, and a walk that reads only views
/// reports nothing and looks like a dead end rather than a blind spot.
///
/// Still the safest thing here: plain `CALayer` property reads. No field
/// walking, no Swift metadata, nothing forced to load, and bounded to the
/// view's own layer plus its immediate sublayers.
static void SPAppendLayerColors(UIView *view, NSMutableDictionary *node) {
    CALayer *layer = view.layer;
    if (!layer) return;

    // A layer background with no view background is exactly the case that used
    // to vanish from these dumps.
    if (!view.backgroundColor && layer.backgroundColor) {
        NSString *lbg = SPCGColorDescription(layer.backgroundColor);
        if (![lbg isEqualToString:@"clear"] && ![lbg isEqualToString:@"nil"]) {
            node[@"layer_background"] = lbg;
        }
    }

    NSMutableArray<CALayer *> *candidates = [NSMutableArray arrayWithObject:layer];
    NSInteger seen = 0;
    for (CALayer *sub in layer.sublayers) {
        if (seen++ >= 6) break;
        [candidates addObject:sub];
    }

    for (CALayer *candidate in candidates) {
        if (![candidate isKindOfClass:CAGradientLayer.class]) continue;
        CAGradientLayer *gradient = (CAGradientLayer *)candidate;
        NSMutableArray<NSString *> *stops = [NSMutableArray array];
        for (id entry in gradient.colors) {
            if (stops.count >= 4) break;
            if (CFGetTypeID((__bridge CFTypeRef)entry) != CGColorGetTypeID()) continue;
            [stops addObject:SPCGColorDescription((__bridge CGColorRef)entry)];
        }
        if (stops.count == 0) continue;
        node[@"gradient"] = [stops componentsJoinedByString:@" "];
        node[@"gradient_layer"] = @(object_getClassName(gradient) ?: "?");
        break;  // the first one identifies the carrier; that is the question
    }
}

/// THE CAPS ARE THE REASON A DUMP CAN COME BACK LOOKING LIKE A DEAD END.
///
/// Depth 3 across 48 nodes is right for "is my overlay window composited" —
/// the question 0.4.1 was built for. It is wrong for "which view is painting
/// this colour": the first real 0.5.0 dump of Music returned 13 views across 3
/// windows and hit the depth cap immediately, several levels above anything
/// interesting. A walk that stops early and a walk that finds nothing produce
/// the same empty result, which is exactly the failure mode this tool exists to
/// prevent.
///
/// So the caps are prefs. Defaults match 0.4.1 so an existing dump is unchanged,
/// and the ceilings are there because an unbounded walk of SpringBoard is not a
/// diagnostic, it is a hang.
static NSInteger SPViewTreeMaxDepth(void) {
    NSInteger d = SPPrefInteger(@"viewTreeDepth", 3);
    return MAX(1, MIN(d, 12));
}

static NSInteger SPViewTreeMaxNodes(void) {
    NSInteger n = SPPrefInteger(@"viewTreeNodes", 48);
    return MAX(8, MIN(n, 600));
}

static const NSInteger kSPViewTreeMaxSiblings = 12;

/// Optional substring. When set, any view whose class name contains it is
/// treated as a fresh root: its subtree is walked from depth 0 again, so the
/// budget goes where the question is instead of being spent on the twelve
/// levels of `UITransitionView` / `UIDropShadowView` scaffolding above it.
///
/// This is what lets one dump answer "what paints the now-playing background"
/// without lifting the global depth to something that would take SpringBoard
/// with it.
///
/// Give it something specific. A substring like `UIView` matches almost every
/// node, restarts the budget at each one, and turns the walk into "everything
/// until `viewTreeNodes` runs out" — bounded, but useless. `NowPlaying`,
/// `Palette` or `DetailHeader` are the shape of a useful answer.
static NSString *SPViewTreeFocus(void) {
    return SPPrefString(@"viewTreeFocus");
}

/// Shallow view walk under a window. Class name, geometry and the handful of
/// properties that decide whether something is on screen at all. No field
/// walking, no Swift metadata, no forcing of lazily-loaded views.
static void SPAppendViewTree(UIView *view, NSInteger depth,
                             NSMutableArray<NSDictionary *> *out) {
    NSInteger maxNodes = SPViewTreeMaxNodes();
    if (!view || out.count >= maxNodes) return;

    // A focus match restarts the depth budget here, and says so in the dump so
    // a reader is not left wondering why the numbering jumps.
    BOOL refocused = NO;
    NSString *focus = SPViewTreeFocus();
    if (focus.length) {
        const char *cn = object_getClassName(view);
        if (cn && strstr(cn, focus.UTF8String) != NULL && depth > 0) {
            refocused = YES;
        }
    }

    CGRect f = view.frame;
    NSMutableDictionary *node = [@{
        @"depth": @(depth),
        @"class": @(object_getClassName(view) ?: "?"),
        @"frame": SPRectString(f),
        @"hidden": @(view.hidden),
        @"alpha": @((double)view.alpha),
        @"subviews": @(view.subviews.count),
    } mutableCopy];

    // Only record a background when it would actually paint — keeps the common
    // case terse and makes an unexpected opaque fill jump out.
    NSString *bg = SPColorDescription(view.backgroundColor);
    if (![bg isEqualToString:@"clear"] && ![bg isEqualToString:@"nil"]) {
        node[@"background"] = bg;
    }
    SPAppendLayerColors(view, node);
    // The three ways a view is present but invisible.
    if (view.hidden || view.alpha < 0.01 ||
        CGRectIsEmpty(f) || f.size.width < 1.0 || f.size.height < 1.0) {
        node[@"invisible"] = @YES;
    }
    if (view.tag != 0) {
        // Tweaks tag their views; 'M27D' etc. read better as FourCC.
        node[@"tag"] = @(view.tag);
    }
    if (refocused) node[@"focus_root"] = @YES;
    [out addObject:node];

    NSInteger childDepth = refocused ? 1 : depth + 1;
    if (!refocused && depth >= SPViewTreeMaxDepth()) {
        // STOPPED IS NOT THE SAME AS EMPTY, AND THE DUMP HAS TO SAY WHICH.
        //
        // The first depth-6 dump of the now-playing screen ended on
        // MusicApplication.TintColorObservingView with subviews=4 — one level
        // above everything worth seeing. Nothing in the output said "there is
        // more here", so a reader has to notice the subview count and do the
        // arithmetic. That is the same trap as a diagnostic that logs nothing
        // on success: two very different states rendering identically.
        if (view.subviews.count > 0) {
            NSMutableDictionary *last = out.lastObject;
            if ([last isKindOfClass:NSMutableDictionary.class]) {
                last[@"truncated"] = @(view.subviews.count);
            }
        }
        return;
    }
    NSInteger siblings = 0;
    for (UIView *sub in view.subviews) {
        if (siblings++ >= kSPViewTreeMaxSiblings) break;
        if (out.count >= maxNodes) break;
        SPAppendViewTree(sub, childDepth, out);
    }
}

static NSArray<NSDictionary *> *SPCollectWindowTree(void) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    @try {
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

        // Prefer per-scene enumeration so we can label which scene each window
        // belongs to; fall back to the deprecated flat list pre-iOS 13.
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (![windows containsObject:w]) [windows addObject:w];
                }
            }
        }
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (![windows containsObject:w]) [windows addObject:w];
        }

        [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
            if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
            if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        NSInteger budget = 40;
        for (UIWindow *w in windows) {
            if (budget-- <= 0) break;
            UIViewController *root = w.rootViewController;
            NSMutableDictionary *entry = [@{
                @"class": @(object_getClassName(w) ?: "?"),
                @"level": @((double)w.windowLevel),
                @"frame": SPRectString(w.frame),
                @"hidden": @(w.hidden),
                @"opaque": @(w.opaque),
                @"alpha": @((double)w.alpha),
                @"is_key": @(w.isKeyWindow),
                @"background": SPColorDescription(w.backgroundColor),
                @"user_interaction": @(w.userInteractionEnabled),
                @"subviews": @(w.subviews.count),
                @"addr": [NSString stringWithFormat:@"0x%lx",
                          (unsigned long)(uintptr_t)(__bridge void *)w],
            } mutableCopy];

            entry[@"root_vc"] = root ? @(object_getClassName(root) ?: "?") : @"nil";
            // A root VC whose view is not loaded is a window that will never
            // paint — worth distinguishing from one that simply has no root.
            entry[@"root_view_loaded"] = @(root ? root.isViewLoaded : NO);

            if (@available(iOS 13.0, *)) {
                UIWindowScene *ws = w.windowScene;
                entry[@"scene"] = ws ? (ws.session.persistentIdentifier ?: @"?") : @"nil";
                entry[@"scene_active"] =
                    @(ws ? (ws.activationState == UISceneActivationStateForegroundActive) : NO);
            }

            // Never touch root.view when the view is not loaded — forcing it to
            // load is a mutation, and doing that to Music blanked Library once.
            if (SPPrefBool(@"dumpWindowViews", YES)) {
                NSMutableArray<NSDictionary *> *views = [NSMutableArray array];
                for (UIView *sub in w.subviews) {
                    if (views.count >= SPViewTreeMaxNodes()) break;
                    SPAppendViewTree(sub, 0, views);
                }
                if (views.count) entry[@"views"] = views;
            }
            [out addObject:entry];
        }
    } @catch (__unused id e) {
        return @[];
    }
    return out;
}

/// Lightweight, hook-free attach: walk already-loaded VC tree only.
/// Never force `vc.view` (that blanked Music Library content) and never
/// call objc_copyClassList here (that froze the UI on main).
/// Writes one coalesced dump; optional M2 field/screen enrichment off-main.
static void SPScanWindowsForHosts(void) {
    if (!SPPrefBool(@"enabled", NO)) return;
    @try {
        // Ensure `_UIHostingView` is registered for isKindOfClass checks.
        SPEnsureSwiftUILoaded();

        NSMutableArray *captured = [NSMutableArray array]; // @{obj, role, ...}
        NSMutableSet *hostAddrs = [NSMutableSet set];
        NSMutableArray *viewClassSample = [NSMutableArray array];
        NSMutableSet *sampleSeen = [NSMutableSet set];
        __block NSInteger hostsFound = 0;
        // FOVO stays hard-off in SpringBoard regardless of the pref. The
        // SpringBoard path exists to answer "UIKit or SwiftUI?", and that is
        // answerable from class names alone.
        BOOL wantMeta = SPPrefBool(@"dumpFieldMeta", NO) && !SPIsSpringBoard();

        void (^captureHost)(UIView *) = ^(UIView *host) {
            if (!host || !SPViewIsHostingView(host)) return;
            NSString *akey = [NSString stringWithFormat:@"0x%lx",
                              (unsigned long)(uintptr_t)(__bridge void *)host];
            if ([hostAddrs containsObject:akey]) return;
            [hostAddrs addObject:akey];
            hostsFound++;
            NSString *hObjc = @(object_getClassName(host) ?: "?");
            NSString *hType = SPSwiftTypeNameFromObject(host) ?: hObjc;
            NSMutableDictionary *entry = [@{
                @"object": host,
                @"role": @"scan_view",
                @"objc_class": hObjc,
                @"type": hType,
                @"address": akey,
                @"view_loaded": @YES,
            } mutableCopy];
            if (SPPrefBool(@"dumpFields", NO)) {
                @try {
                    NSArray *screen = SPScreenStrings(host);
                    if (screen.count) entry[@"screen_strings"] = screen;
                } @catch (__unused id e) {}
            }
            [captured addObject:entry];
            if (SPPrefBool(@"logAttach", YES)) {
                NSLog(@"[SwiftPeek] scan_view type=%@ addr=%@", hType, akey);
            }
        };

        NSArray *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *w in windows) {
            // Window-level pass catches hosts outside the VC.view we happen to walk.
            for (UIView *host in SPCollectHostingViews(w, 160, 6)) {
                captureHost(host);
            }
            // Diagnostic only — FOVO on Music UIViews crashed on 0.3.5; do not walk.
            if (wantMeta) {
                for (NSString *cn in SPSampleViewClassNames(w, 80, 16)) {
                    if (![sampleSeen containsObject:cn]) {
                        [sampleSeen addObject:cn];
                        [viewClassSample addObject:cn];
                    }
                }
            }

            UIViewController *root = w.rootViewController;
            NSMutableArray *stack = [NSMutableArray array];
            if (root) [stack addObject:root];
            NSInteger budget = 36;
            while (stack.count && budget-- > 0) {
                UIViewController *vc = stack.lastObject;
                [stack removeLastObject];
                NSString *objcName = @(object_getClassName(vc) ?: "?");
                NSString *typeName = SPSwiftTypeNameFromObject(vc) ?: objcName;
                if (!SPIsBoringTypeName(typeName) || !SPIsBoringTypeName(objcName)) {
                    NSMutableDictionary *entry = [@{
                        @"object": vc,
                        @"role": @"scan_controller",
                        @"objc_class": objcName,
                        @"type": typeName,
                        @"address": [NSString stringWithFormat:@"0x%lx",
                                     (unsigned long)(uintptr_t)(__bridge void *)vc],
                        @"view_loaded": @(vc.isViewLoaded),
                    } mutableCopy];
                    // Safe M2: titles always; view walk only if already loaded.
                    if (SPPrefBool(@"dumpFields", NO)) {
                        @try {
                            NSArray *titles = SPControllerTitles(vc);
                            NSMutableArray *screen = titles.count
                                ? [titles mutableCopy]
                                : [NSMutableArray array];
                            if (vc.isViewLoaded) {
                                NSArray *fromView = SPScreenStrings(vc.view);
                                for (NSString *s in fromView) {
                                    if (![screen containsObject:s]) [screen addObject:s];
                                }
                            }
                            if (screen.count) entry[@"screen_strings"] = screen;
                        } @catch (__unused id e) {}
                    }
                    [captured addObject:entry];
                    if (SPPrefBool(@"logAttach", YES)) {
                        NSLog(@"[SwiftPeek] scan type=%@ addr=%@", typeName,
                              entry[@"address"]);
                    }
                }
                if (vc.isViewLoaded) {
                    // Deeper per-VC BFS; also covers UIHostingController.view itself.
                    for (UIView *host in SPCollectHostingViews(vc.view, 96, 4)) {
                        captureHost(host);
                    }
                }
                for (UIViewController *child in vc.childViewControllers) {
                    [stack addObject:child];
                }
                if (vc.presentedViewController) {
                    [stack addObject:vc.presentedViewController];
                }
            }
        }

        // Main-thread only — UIWindow property reads must not go off-main.
        // Collected before the early return below: "no interesting controllers"
        // is exactly the case where the window list is the whole story.
        NSArray<NSDictionary *> *windowTree =
            SPPrefBool(@"dumpWindows", YES) ? SPCollectWindowTree() : @[];

        if (captured.count == 0) {
            NSString *msg = [NSString stringWithFormat:
                @"window scan found no interesting controllers (windows=%lu)",
                (unsigned long)windowTree.count];
            if (windowTree.count) {
                // Still worth a dump — the window list alone explains a tweak
                // overlay that is missing, hidden, or painting over the app.
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    SPWriteJSONDump(@{
                        @"milestone": @1,
                        @"scan": @YES,
                        @"message": msg,
                        @"nodes": @[],
                        @"hosts_found": @0,
                        @"windows": windowTree,
                    });
                });
            }
            SPWriteHeartbeat(msg, NO, @[], @[]);
            return;
        }

        BOOL enrichScreen = SPPrefBool(@"dumpFields", NO);
        BOOL enrichMeta = wantMeta;
        NSArray *snapshot = [captured copy];
        NSArray *sampleCopy = [viewClassSample copy];
        NSInteger hostsCopy = hostsFound;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSMutableArray *nodes = [NSMutableArray array];
            NSInteger milestone = 1;
            // Hosting FOVO only. Music UIView FOVO crashed on 0.3.5 — disabled.
            NSInteger metaBudget = 4;
            NSInteger metaTried = 0;
            NSInteger metaHit = 0;
            for (NSDictionary *item in snapshot) {
                NSMutableDictionary *node = [@{
                    @"address": item[@"address"] ?: @"",
                    @"objc_class": item[@"objc_class"] ?: @"",
                    @"role": item[@"role"] ?: @"",
                    @"type": item[@"type"] ?: @"",
                } mutableCopy];

                if (item[@"screen_strings"]) {
                    node[@"screen_strings"] = item[@"screen_strings"];
                    milestone = 2;
                }

                if (enrichMeta && metaBudget > 0) {
                    NSString *role = item[@"role"] ?: @"";
                    id obj = item[@"object"];
                    // Never FOVO-walk Music VCs (0.3.0) or Music UIViews (0.3.5).
                    if ([role isEqualToString:@"scan_view"] &&
                        [obj isKindOfClass:[UIView class]] &&
                        SPViewIsHostingView((UIView *)obj)) {
                        metaBudget--;
                        metaTried++;
                        @try {
                            NSArray *fields = SPWalkFields(obj, 0, 8);
                            if (fields.count) {
                                node[@"fields"] = fields;
                                milestone = 2;
                                metaHit++;
                            } else {
                                node[@"meta_empty"] = @YES;
                            }
                        } @catch (__unused id e) {
                            node[@"meta_skipped"] = @"walk_exception";
                        }
                    }
                }
                [nodes addObject:node];
            }

            NSString *msg = [NSString stringWithFormat:
                @"window scan nodes=%lu milestone=%ld screen=%d meta=%d hosts=%ld tried=%ld hit=%ld windows=%lu",
                (unsigned long)nodes.count, (long)milestone,
                enrichScreen ? 1 : 0, enrichMeta ? 1 : 0,
                (long)hostsCopy, (long)metaTried, (long)metaHit,
                (unsigned long)windowTree.count];
            NSMutableDictionary *payload = [@{
                @"milestone": @(milestone),
                @"scan": @YES,
                @"message": msg,
                @"nodes": nodes,
                @"hosts_found": @(hostsCopy),
            } mutableCopy];
            if (windowTree.count) payload[@"windows"] = windowTree;
            // Class sample only — no FOVO. Safe when hosts=0 on Music 16.7.
            if (enrichMeta && hostsCopy == 0 && sampleCopy.count) {
                payload[@"view_class_sample"] = sampleCopy;
            }
            NSString *path = SPWriteJSONDump(payload);
            SPWriteHeartbeat(path ? msg : @"window scan dump write failed", NO, @[], @[]);
            if (path) NSLog(@"[SwiftPeek] %@", msg);
        });
    } @catch (__unused id e) {
        SPWriteHeartbeat(@"window scan failed closed", NO, @[], @[]);
    }
}

/// SpringBoard-side entry point (0.4.0). Deliberately tiny: one inventory pass,
/// off the main thread, no hooks, no view walking. Everything it needs comes
/// from UIKit + LSApplicationWorkspace, so the icon model is never touched.
static void SPRunIconInventory(NSString *reason) {
    if (!SPIconPeekAvailable()) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSArray *icons = SPIconInventory(220);
            NSInteger themed = 0;
            for (NSDictionary *icon in icons) {
                if (icon[@"theme_override"]) themed++;
            }
            NSString *msg = [NSString stringWithFormat:
                @"icon inventory (%@) icons=%lu themed=%ld",
                reason ?: @"timer", (unsigned long)icons.count, (long)themed];
            NSString *path = SPWriteJSONDump(@{
                @"milestone": @4,
                @"icons": icons,
                @"icon_theme_paths": SPIconThemeSearchPaths(),
                @"message": msg,
                @"nodes": @[],
            });
            SPWriteHeartbeat(path ? msg : @"icon inventory dump write failed", NO, @[], @[]);
            NSLog(@"[SwiftPeek] %@", msg);
        } @catch (__unused id e) {
            SPWriteHeartbeat(@"icon inventory failed closed", NO, @[], @[]);
        }
    });
}

static void SPIconsRequestedCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    SPPrefsInvalidate();
    SPRunIconInventory(@"notification");
}

static void SPStartIfEnabled(void) {
    if (SPIsSpringBoard()) {
        // SpringBoard never installs hooks and never walks Swift metadata —
        // the icon inventory, plus an optional hook-free hosting-view scan that
        // is what resolves Glyph's PENDING DUMP surface rows.
        if (!SPPrefBool(@"enabled", NO) || !SPPrefBool(@"targetSpringBoard", NO)) return;
        BOOL sbScan = SPPrefBool(@"sbScanWindows", NO);
        NSLog(@"[SwiftPeek] SpringBoard recon mode (0.5.3) iconInventory=%d sbScanWindows=%d",
              SPPrefBool(@"iconInventory", NO) ? 1 : 0, sbScan ? 1 : 0);
        SPRunIconInventory(@"launch");

        if (sbScan) {
            static dispatch_once_t sbScanOnce;
            dispatch_once(&sbScanOnce, ^{
                // Long delay on purpose: well clear of launch, and late enough
                // that the first home screen has settled.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!SPPrefBool(@"enabled", NO)) return;
                    if (!SPPrefBool(@"targetSpringBoard", NO)) return;
                    if (!SPPrefBool(@"sbScanWindows", NO)) return;
                    SPScanWindowsForHosts();
                });
            });
        }
        return;
    }

    if (!SPPrefBool(@"enabled", NO)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SPWriteHeartbeat(@"ctor disabled (kill switch)", NO, @[], @[]);
        });
        NSLog(@"[SwiftPeek] disabled — idle");
        return;
    }

    NSLog(@"[SwiftPeek] loaded in %@ jbroot='%@'",
          NSProcessInfo.processInfo.processName ?: @"?",
          SPJailbreakRootPrefix() ?: @"");

    BOOL scanOn = SPPrefBool(@"scanWindows", NO);
    BOOL hooksOn = SPPrefBool(@"installHooks", NO);
    BOOL fieldsOn = SPPrefBool(@"dumpFields", NO);
    BOOL metaOn = SPPrefBool(@"dumpFieldMeta", NO);

    static dispatch_once_t launchOnce;
    dispatch_once(&launchOnce, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *msg = [NSString stringWithFormat:
                @"%@ launch probe (0.5.3) scanWindows=%d installHooks=%d dumpFields=%d dumpFieldMeta=%d",
                NSProcessInfo.processInfo.processName ?: @"?",
                scanOn ? 1 : 0, hooksOn ? 1 : 0, fieldsOn ? 1 : 0, metaOn ? 1 : 0];
            SPWriteHeartbeat(msg, NO, @[], @[]);
            SPWriteJSONDump(@{
                @"milestone": @0,
                @"probe": @YES,
                @"launch": @YES,
                @"message": msg,
                @"prefs": @{
                    @"enabled": @YES,
                    @"scanWindows": @(scanOn),
                    @"installHooks": @(hooksOn),
                    @"dumpFields": @(fieldsOn),
                    @"dumpFieldMeta": @(metaOn),
                },
                @"nodes": @[],
            });
        });
    });

    // Window scan is opt-in — schedule every Music launch when enabled.
    if (scanOn) {
        static dispatch_once_t scanScheduleOnce;
        dispatch_once(&scanScheduleOnce, ^{
            NSLog(@"[SwiftPeek] scanWindows on — scheduling scans");
            for (NSNumber *sec in @[ @5.0, @12.0 ]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(sec.doubleValue * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!SPPrefBool(@"enabled", NO) || !SPPrefBool(@"scanWindows", NO)) return;
                    SPScanWindowsForHosts();
                });
            }
        });
    }

    if (hooksOn) {
        static dispatch_once_t hooksOnce;
        dispatch_once(&hooksOnce, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!SPPrefBool(@"installHooks", NO)) return;
                SPTryInstallHooks();
            });
            if (!gSPDyldWatchInstalled) {
                gSPDyldWatchInstalled = YES;
                _dyld_register_func_for_add_image(SPOnImageAdded);
            }
        });
    }
}

__attribute__((constructor)) static void SPConstructor(void) {
    @autoreleasepool {
        if (!SPIsAllowedProcess()) {
            return;
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        SPPrefsChangedCallback,
                                        CFSTR("com.kolby.swiftpeek/prefschanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        // Never touch main in the constructor. Schedule from a utility queue.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try {
                if (!SPPrefBool(@"enabled", NO)) {
                    SPWriteHeartbeat(@"ctor disabled (kill switch)", NO, @[], @[]);
                    return;
                }
                // Bounce to main only to kick opt-in timers (UIApplication-safe).
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try { SPStartIfEnabled(); } @catch (__unused id e) {}
                });
            } @catch (__unused id e) {
                NSLog(@"[SwiftPeek] ctor failed closed");
            }
        });
    }
}
