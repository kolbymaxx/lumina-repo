#import "SPIconPeek.h"
#import "SPRenderPeek.h"
#import "SPPrefs.h"
#import <objc/runtime.h>
#import <objc/message.h>

// -----------------------------------------------------------------------------
// SwiftPeek M4 — icon inventory (read-only, SpringBoard, opt-in)
// -----------------------------------------------------------------------------

BOOL SPIconPeekAvailable(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (![bundle isEqualToString:@"com.apple.springboard"]) return NO;
    if (!SPPrefBool(@"enabled", NO)) return NO;
    if (!SPPrefBool(@"targetSpringBoard", NO)) return NO;
    return SPPrefBool(@"iconInventory", NO);
}

NSArray<NSString *> *SPIconThemeSearchPaths(void) {
    NSString *jb = SPJailbreakRootPrefix() ?: @"";
    NSArray *rel = @[
        @"/Library/Themes",
        @"/Library/Application Support/SnowBoard/Themes",
        @"/Library/Application Support/SBHUDEnabler",  // harmless if absent
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *r in rel) {
        if (jb.length) [out addObject:[jb stringByAppendingString:r]];
        [out addObject:[@"/var/jb" stringByAppendingString:r]];
        [out addObject:r];
    }
    return out;
}

/// Look for `<theme>/IconBundles/<bundleid>.png` (and the @2x/@3x variants that
/// SnowBoard and Anemone both understand). First hit wins, same as the runtime
/// order a themer would see.
static NSString *SPThemeOverridePathForBundle(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *suffixes = @[ @"@3x.png", @"@2x.png", @".png" ];

    for (NSString *root in SPIconThemeSearchPaths()) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;
        NSArray *themes = [fm contentsOfDirectoryAtPath:root error:NULL];
        for (NSString *theme in themes) {
            NSString *bundlesDir = [[root stringByAppendingPathComponent:theme]
                                    stringByAppendingPathComponent:@"IconBundles"];
            for (NSString *suffix in suffixes) {
                NSString *candidate = [bundlesDir stringByAppendingPathComponent:
                                       [bundleID stringByAppendingString:suffix]];
                if ([fm fileExistsAtPath:candidate]) return candidate;
            }
        }
    }
    return nil;
}

/// `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]` — UIKit
/// private, present on every iOS 9…18 build, renders straight from the app
/// bundle. Format 2 is the home screen size. Called through a typed
/// `objc_msgSend` cast because the selector takes an int + CGFloat.
static UIImage *SPIconImageForBundle(NSString *bundleID) {
    static SEL sel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    });
    if (!sel || ![UIImage respondsToSelector:sel]) return nil;

    UIImage *(*send)(id, SEL, id, int, CGFloat) =
        (UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend;
    UIImage *image = nil;
    @try {
        image = send([UIImage class], sel, bundleID, 2, UIScreen.mainScreen.scale);
    } @catch (__unused id e) {
        return nil;
    }
    return image;
}

/// Installed applications via LSApplicationWorkspace. Read-only, and it does not
/// go anywhere near SBIconModel — which is what made 0.2.x dangerous.
static NSArray *SPInstalledApplicationProxies(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return @[];
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    if (![workspaceClass respondsToSelector:defaultSel]) return @[];

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSel);
    if (!workspace) return @[];

    SEL allSel = NSSelectorFromString(@"allInstalledApplications");
    if (![workspace respondsToSelector:allSel]) return @[];
    id result = ((id (*)(id, SEL))objc_msgSend)(workspace, allSel);
    return [result isKindOfClass:[NSArray class]] ? result : @[];
}

static NSString *SPProxyStringValue(id proxy, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!sel || ![proxy respondsToSelector:sel]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(proxy, sel);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Apple's own daemons and hidden system bundles are noise for a themer.
static BOOL SPProxyIsUserVisible(id proxy) {
    NSString *type = SPProxyStringValue(proxy, @"applicationType") ?: @"";
    if ([type isEqualToString:@"Hidden"]) return NO;
    NSString *bundleID = SPProxyStringValue(proxy, @"applicationIdentifier") ?: @"";
    if (bundleID.length == 0) return NO;
    if ([bundleID hasPrefix:@"com.apple.datadetectors"]) return NO;
    if ([bundleID hasPrefix:@"com.apple.webapp"]) return NO;
    return YES;
}

NSArray<NSDictionary *> *SPIconInventory(NSInteger maxIcons) {
    if (maxIcons <= 0) maxIcons = 200;
    NSMutableArray *out = [NSMutableArray array];

    @try {
        NSArray *proxies = SPInstalledApplicationProxies();
        for (id proxy in proxies) {
            if ((NSInteger)out.count >= maxIcons) break;
            @try {
                if (!SPProxyIsUserVisible(proxy)) continue;
                NSString *bundleID = SPProxyStringValue(proxy, @"applicationIdentifier");
                if (bundleID.length == 0) continue;

                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[@"bundle_id"] = bundleID;
                NSString *name = SPProxyStringValue(proxy, @"localizedName");
                if (name.length) entry[@"display_name"] = name;
                NSString *type = SPProxyStringValue(proxy, @"applicationType");
                if (type.length) entry[@"app_type"] = type;

                UIImage *icon = SPIconImageForBundle(bundleID);
                NSDictionary *sig = SPRenderSignatureForImage(icon);
                if (sig) entry[@"icon_signature"] = sig;

                NSString *override = SPThemeOverridePathForBundle(bundleID);
                if (override) {
                    entry[@"theme_override"] = override;
                    UIImage *themed = [UIImage imageWithContentsOfFile:override];
                    NSDictionary *themedSig = SPRenderSignatureForImage(themed);
                    if (themedSig) entry[@"theme_signature"] = themedSig;
                }

                [out addObject:entry];
            } @catch (__unused id e) {
                // One unreadable bundle must not end the sweep.
            }
        }
    } @catch (__unused id e) {
        return [out copy];
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(NSString *)a[@"bundle_id"] compare:(NSString *)b[@"bundle_id"]];
    }];
    return [out copy];
}
