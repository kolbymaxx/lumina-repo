#import "SPPrefs.h"
#import <dlfcn.h>

static NSString * const kSPPrefsDomain = @"com.kolby.swiftpeek";

static NSDictionary *gSPPrefsCache = nil;
static CFAbsoluteTime gSPPrefsLastLoad = 0;

NSString *SPJailbreakRootPrefix(void) {
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = @"";
        const char *(*jbrootFn)(const char *) = (const char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootFn) {
            const char *p = jbrootFn("/");
            // Music27: reject NULL, empty, and bare "/"
            if (p && p[0] != '\0' && strcmp(p, "/") != 0) {
                prefix = [[NSString stringWithUTF8String:p] stringByStandardizingPath];
                return;
            }
        }
        Dl_info info = {0};
        if (dladdr((const void *)SPJailbreakRootPrefix, &info) && info.dli_fname) {
            NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
            for (NSString *marker in @[@"/Library/MobileSubstrate/DynamicLibraries/",
                                       @"/usr/lib/TweakInject/"]) {
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

NSArray<NSString *> *SPPrefsCandidatePaths(void) {
    NSString *rel = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kSPPrefsDomain];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *jbPrefix = SPJailbreakRootPrefix();
    if (jbPrefix.length) [paths addObject:[jbPrefix stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    return paths;
}

NSDictionary *SPPrefs(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gSPPrefsCache && (now - gSPPrefsLastLoad) < 0.5) return gSPPrefsCache;

    for (NSString *p in SPPrefsCandidatePaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        // Require non-empty — an empty file/dict is not a real prefs hit.
        if ([d isKindOfClass:[NSDictionary class]] && d.count > 0) {
            gSPPrefsCache = d;
            gSPPrefsLastLoad = now;
            return gSPPrefsCache;
        }
    }
    gSPPrefsCache = @{};
    gSPPrefsLastLoad = now;
    return gSPPrefsCache;
}

BOOL SPPrefBool(NSString *key, BOOL fallback) {
    // Prefer live CFPreferences (PreferenceLoader writes here); file can lag.
    CFPreferencesAppSynchronize((__bridge CFStringRef)kSPPrefsDomain);
    CFPropertyListRef cfVal = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kSPPrefsDomain);
    if (cfVal != NULL) {
        BOOL result = fallback;
        if (CFGetTypeID(cfVal) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)cfVal);
        } else if (CFGetTypeID(cfVal) == CFNumberGetTypeID()) {
            int n = 0;
            CFNumberGetValue((CFNumberRef)cfVal, kCFNumberIntType, &n);
            result = n != 0;
        }
        CFRelease(cfVal);
        return result;
    }

    id v = SPPrefs()[key];
    if (v != nil) return [v boolValue];
    return fallback;
}

void SPPrefsInvalidate(void) {
    gSPPrefsCache = nil;
    gSPPrefsLastLoad = 0;
}

NSInteger SPPrefInteger(NSString *key, NSInteger fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kSPPrefsDomain);
    CFPropertyListRef cfVal = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kSPPrefsDomain);
    if (cfVal != NULL) {
        NSInteger result = fallback;
        if (CFGetTypeID(cfVal) == CFNumberGetTypeID()) {
            long long n = 0;
            CFNumberGetValue((CFNumberRef)cfVal, kCFNumberLongLongType, &n);
            result = (NSInteger)n;
        } else if (CFGetTypeID(cfVal) == CFStringGetTypeID()) {
            result = [(__bridge NSString *)cfVal integerValue];
        }
        CFRelease(cfVal);
        return result;
    }
    id v = SPPrefs()[key];
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return fallback;
}

NSString *SPPrefString(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kSPPrefsDomain);
    CFPropertyListRef cfVal = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kSPPrefsDomain);
    if (cfVal != NULL) {
        NSString *result = nil;
        if (CFGetTypeID(cfVal) == CFStringGetTypeID()) {
            result = [(__bridge NSString *)cfVal copy];
        }
        CFRelease(cfVal);
        if (result.length) return result;
    }
    id v = SPPrefs()[key];
    return [v isKindOfClass:NSString.class] && [v length] ? v : nil;
}
