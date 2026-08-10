#import "GLPrefs.h"
#import <dlfcn.h>

static NSString * const kGLPrefsDomain = @"com.kolby.glyph";

static NSDictionary *gGLPrefsCache = nil;
static CFAbsoluteTime gGLPrefsLastLoad = 0;

NSString *GLJailbreakRootPrefix(void) {
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = @"";
        const char *(*jbrootFn)(const char *) = (const char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootFn) {
            const char *p = jbrootFn("/");
            // Music27 lesson: reject NULL, empty, and bare "/"
            if (p && p[0] != '\0' && strcmp(p, "/") != 0) {
                prefix = [[NSString stringWithUTF8String:p] stringByStandardizingPath];
                return;
            }
        }
        Dl_info info = {0};
        if (dladdr((const void *)GLJailbreakRootPrefix, &info) && info.dli_fname) {
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

NSArray<NSString *> *GLPrefsCandidatePaths(void) {
    NSString *rel = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kGLPrefsDomain];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *jbPrefix = GLJailbreakRootPrefix();
    if (jbPrefix.length) [paths addObject:[jbPrefix stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    return paths;
}

NSDictionary *GLPrefs(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gGLPrefsCache && (now - gGLPrefsLastLoad) < 0.5) return gGLPrefsCache;

    for (NSString *p in GLPrefsCandidatePaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        // Require non-empty — an empty file/dict is not a real prefs hit.
        if ([d isKindOfClass:[NSDictionary class]] && d.count > 0) {
            gGLPrefsCache = d;
            gGLPrefsLastLoad = now;
            return gGLPrefsCache;
        }
    }
    gGLPrefsCache = @{};
    gGLPrefsLastLoad = now;
    return gGLPrefsCache;
}

BOOL GLPrefBool(NSString *key, BOOL fallback) {
    id v = GLPrefs()[key];
    if (v != nil) return [v boolValue];

    // CFPreferences fallback (same lesson as Music27 on rootless/roothide).
    CFPropertyListRef cfVal = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kGLPrefsDomain);
    if (cfVal == NULL) return fallback;

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

NSArray *GLPrefArray(NSString *key) {
    id v = GLPrefs()[key];
    if ([v isKindOfClass:[NSArray class]]) return v;

    CFPropertyListRef cfVal = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kGLPrefsDomain);
    if (cfVal == NULL) return nil;

    NSArray *result = nil;
    if (CFGetTypeID(cfVal) == CFArrayGetTypeID()) {
        result = (__bridge_transfer NSArray *)cfVal;
    } else {
        CFRelease(cfVal);
    }
    return result;
}

void GLPrefsInvalidate(void) {
    gGLPrefsCache = nil;
    gGLPrefsLastLoad = 0;
}

BOOL GLKillSwitchPresent(void) {
    NSString *rel = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.killswitch", kGLPrefsDomain];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *jbPrefix = GLJailbreakRootPrefix();
    if (jbPrefix.length) [paths addObject:[jbPrefix stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return YES;
    }
    return NO;
}
