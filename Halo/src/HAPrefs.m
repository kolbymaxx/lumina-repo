#import "Halo.h"
#import <dlfcn.h>

// -----------------------------------------------------------------------------
// Halo — prefs, jbroot resolution, kill switch
// Same pattern as Glyph / SwiftPeek / Music27: resolve jbroot, read the plist,
// fall back to CFPreferences because PreferenceLoader writes through cfprefsd
// and the on-disk file can lag behind it on rootless.
// -----------------------------------------------------------------------------

static NSString * const kHAPrefsDomain = @"com.kolby.halo";

static NSDictionary *gHAPrefsCache = nil;
static CFAbsoluteTime gHAPrefsLastLoad = 0;

NSString *HAJailbreakRootPrefix(void) {
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
        if (dladdr((const void *)HAJailbreakRootPrefix, &info) && info.dli_fname) {
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

static NSArray<NSString *> *HAPrefsCandidatePaths(void) {
    NSString *rel = [NSString stringWithFormat:
                     @"/var/mobile/Library/Preferences/%@.plist", kHAPrefsDomain];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *jb = HAJailbreakRootPrefix();
    if (jb.length) [paths addObject:[jb stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    return paths;
}

NSDictionary *HAPrefs(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gHAPrefsCache && (now - gHAPrefsLastLoad) < 0.5) return gHAPrefsCache;

    for (NSString *p in HAPrefsCandidatePaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]] && d.count > 0) {
            gHAPrefsCache = d;
            gHAPrefsLastLoad = now;
            return gHAPrefsCache;
        }
    }
    gHAPrefsCache = @{};
    gHAPrefsLastLoad = now;
    return gHAPrefsCache;
}

static id HAPrefValue(NSString *key) {
    id v = HAPrefs()[key];
    if (v != nil) return v;
    CFPropertyListRef cf = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kHAPrefsDomain);
    if (cf == NULL) return nil;
    return (__bridge_transfer id)cf;
}

BOOL HAPrefBool(NSString *key, BOOL fallback) {
    id v = HAPrefValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return fallback;
}

double HAPrefDouble(NSString *key, double fallback) {
    id v = HAPrefValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [v doubleValue];
    return fallback;
}

void HAPrefsInvalidate(void) {
    gHAPrefsCache = nil;
    gHAPrefsLastLoad = 0;
}

BOOL HAKillSwitchPresent(void) {
    NSString *rel = [NSString stringWithFormat:
                     @"/var/mobile/Library/Preferences/%@.killswitch", kHAPrefsDomain];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *jb = HAJailbreakRootPrefix();
    if (jb.length) [paths addObject:[jb stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    for (NSString *p in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) return YES;
    }
    return NO;
}
