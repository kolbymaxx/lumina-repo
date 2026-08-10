#import "Lattice.h"
#import <dlfcn.h>

// -----------------------------------------------------------------------------
// Lattice — prefs, jbroot resolution, kill switch
// Same pattern as Glyph / SwiftPeek / Music27: resolve jbroot, read the plist,
// fall back to CFPreferences because PreferenceLoader writes through cfprefsd
// and the on-disk file can lag behind it on rootless.
// -----------------------------------------------------------------------------

static NSString * const kLTPrefsDomain = @"com.kolby.lattice";

static NSDictionary *gLTPrefsCache = nil;
static CFAbsoluteTime gLTPrefsLastLoad = 0;

NSString *LTJailbreakRootPrefix(void) {
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = @"";
        const char *(*jbrootFn)(const char *) =
            (const char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootFn) {
            const char *p = jbrootFn("/");
            if (p && p[0] != '\0' && strcmp(p, "/") != 0) {
                prefix = [[NSString stringWithUTF8String:p] stringByStandardizingPath];
                return;
            }
        }
        Dl_info info = {0};
        if (dladdr((const void *)LTJailbreakRootPrefix, &info) && info.dli_fname) {
            NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
            for (NSString *marker in @[ @"/Library/MobileSubstrate/DynamicLibraries/",
                                        @"/usr/lib/TweakInject/" ]) {
                NSRange r = [dylibPath rangeOfString:marker];
                if (r.location != NSNotFound && r.location > 0) {
                    prefix = [dylibPath substringToIndex:r.location];
                    return;
                }
            }
        }
    });
    return prefix;
}

static NSArray<NSString *> *LTPrefsCandidatePaths(void) {
    NSString *rel = [NSString stringWithFormat:
                     @"/var/mobile/Library/Preferences/%@.plist", kLTPrefsDomain];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *jb = LTJailbreakRootPrefix();
    if (jb.length) [paths addObject:[jb stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    return paths;
}

NSDictionary *LTPrefs(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLTPrefsCache && (now - gLTPrefsLastLoad) < 0.5) return gLTPrefsCache;

    for (NSString *p in LTPrefsCandidatePaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]] && d.count > 0) {
            gLTPrefsCache = d;
            gLTPrefsLastLoad = now;
            return gLTPrefsCache;
        }
    }
    gLTPrefsCache = @{};
    gLTPrefsLastLoad = now;
    return gLTPrefsCache;
}

static id LTPrefValue(NSString *key) {
    id v = LTPrefs()[key];
    if (v != nil) return v;
    CFPropertyListRef cf = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kLTPrefsDomain);
    if (cf == NULL) return nil;
    return (__bridge_transfer id)cf;
}

BOOL LTPrefBool(NSString *key, BOOL fallback) {
    id v = LTPrefValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return fallback;
}

double LTPrefDouble(NSString *key, double fallback) {
    id v = LTPrefValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [v doubleValue];
    return fallback;
}

NSInteger LTPrefInteger(NSString *key, NSInteger fallback) {
    id v = LTPrefValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    if ([v isKindOfClass:[NSString class]]) return [v integerValue];
    return fallback;
}

void LTPrefsInvalidate(void) {
    gLTPrefsCache = nil;
    gLTPrefsLastLoad = 0;
}

BOOL LTKillSwitchPresent(void) {
    NSString *rel = [NSString stringWithFormat:
                     @"/var/mobile/Library/Preferences/%@.killswitch", kLTPrefsDomain];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *jb = LTJailbreakRootPrefix();
    if (jb.length) [paths addObject:[jb stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    for (NSString *p in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) return YES;
    }
    return NO;
}
