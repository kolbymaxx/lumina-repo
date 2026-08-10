#import "CC27.h"

NSString * const CC27PrefDomain = @"com.kolby.cc27";
NSString * const CC27ReloadPrefsNotification = @"com.kolby.cc27/ReloadPrefs";
NSString * const CC27LayoutDidChangeNotification = @"com.kolby.cc27/LayoutDidChange";

// Exported (declared in CC27.h) so the %ctor kill-switch check resolves the same
// jbroot prefix as prefs do. Deliberately CC27's own copy: the emergency switch
// must keep working even if the linked SwiftPeek recon sources are ever dropped.
NSString *CC27JailbreakRootPrefix(void) {
    static NSString *prefix;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = @"";
        const char *(*jbrootFn)(const char *) = (const char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootFn) {
            const char *p = jbrootFn("/");
            if (p && p[0] != '\0' && strcmp(p, "/") != 0) {
                prefix = [[NSString stringWithUTF8String:p] stringByStandardizingPath];
                return;
            }
        }
        Dl_info info = {0};
        if (dladdr((const void *)CC27JailbreakRootPrefix, &info) && info.dli_fname) {
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

static NSArray<NSString *> *CC27PrefsCandidatePaths(void) {
    NSString *rel = @"/var/mobile/Library/Preferences/com.kolby.cc27.plist";
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *jb = CC27JailbreakRootPrefix();
    if (jb.length > 0) {
        [paths addObject:[jb stringByAppendingString:rel]];
    }
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];
    return paths;
}

static NSDictionary *CC27ReadPrefsDictionary(void) {
    for (NSString *path in CC27PrefsCandidatePaths()) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([dict isKindOfClass:NSDictionary.class] && dict.count > 0) {
            return dict;
        }
    }
    return @{};
}

@implementation CC27Prefs {
    // Values are resolved once per reload and cached here. Pref getters are hit
    // from hot paths (every module layoutSubviews); a cfprefsd XPC round-trip
    // per read would pile up badly during SpringBoard boot.
    BOOL _enabled;
    BOOL _glassChrome;
    BOOL _editModeEnabled;
    BOOL _allowResize;
    BOOL _showTopButtons;
    BOOL _hapticFeedback;
    BOOL _reconDump;
}

+ (instancetype)shared {
    static CC27Prefs *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self reload];
    }
    return self;
}

static BOOL CC27ResolveBool(NSDictionary *plist, NSString *key, BOOL fallback) {
    id v = plist[key];
    if (!v) {
        CFPropertyListRef cf = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)CC27PrefDomain);
        if (cf) {
            v = CFBridgingRelease(cf);
        }
    }
    if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
    return fallback;
}

- (void)reload {
    NSDictionary *plist = CC27ReadPrefsDictionary() ?: @{};
    _enabled         = CC27ResolveBool(plist, @"enabled", YES);
    _glassChrome     = CC27ResolveBool(plist, @"glassChrome", YES);
    _editModeEnabled = CC27ResolveBool(plist, @"editModeEnabled", YES);
    _allowResize     = CC27ResolveBool(plist, @"allowResize", NO);
    _showTopButtons  = CC27ResolveBool(plist, @"showTopButtons", YES);
    _hapticFeedback  = CC27ResolveBool(plist, @"hapticFeedback", YES);
    // Debug recon only. Default OFF and never seeded on — a dump walks the live
    // CC view tree, which is not something to do on a user's device by default.
    _reconDump       = CC27ResolveBool(plist, @"reconDump", NO);
}

- (BOOL)enabled { return _enabled; }
- (BOOL)glassChrome { return _glassChrome; }
- (BOOL)editModeEnabled { return _editModeEnabled; }
- (BOOL)allowResize { return _allowResize; }
- (BOOL)showTopButtons { return _showTopButtons; }
- (BOOL)hapticFeedback { return _hapticFeedback; }
- (BOOL)reconDump { return _reconDump; }

@end
