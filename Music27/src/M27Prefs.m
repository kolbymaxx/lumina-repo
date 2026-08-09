#import "Music27.h"
#import <dlfcn.h>

NSString *const M27PrefDomain = @"com.music27.tweak";
NSString *const M27ThemeDidChangeNotification = @"M27ThemeDidChangeNotification";
NSString *const M27PinsDidChangeNotification = @"M27PinsDidChangeNotification";
const NSInteger M27MaxPins = 12;

// Resolve jailbreak root the same way Siri27 does — RootHide jbroot, then
// /var/jb, then rootful.
static NSString *M27JailbreakRootPrefix(void) {
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
        if (dladdr((const void *)M27JailbreakRootPrefix, &info) && info.dli_fname) {
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

static NSArray<NSString *> *M27PrefsCandidatePaths(void) {
    NSString *rel = @"/var/mobile/Library/Preferences/com.music27.tweak.plist";
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    // Prefer /var/jb first (Dopamine rootless). Then jbroot (RootHide), then rootful.
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    NSString *jb = M27JailbreakRootPrefix();
    if (jb.length > 0 && ![jb isEqualToString:@"/var/jb"]) {
        [paths addObject:[jb stringByAppendingString:rel]];
    }
    [paths addObject:rel];
    return paths;
}

static NSDictionary *M27ReadPrefsDictionary(void) {
    for (NSString *path in M27PrefsCandidatePaths()) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([dict isKindOfClass:NSDictionary.class] && dict.count > 0) {
            return dict;
        }
    }
    return @{};
}

static void M27WritePrefsDictionary(NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class]) return;
    NSArray<NSString *> *paths = M27PrefsCandidatePaths();
    // Prefer an already-existing candidate; else /var/jb (first).
    NSString *target = paths.firstObject;
    for (NSString *path in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            target = path;
            break;
        }
    }
    if (!target) return;
    NSString *dir = [target stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [dict writeToFile:target atomically:YES];
}

@implementation M27Prefs {
    NSDictionary *_plist;
}

+ (instancetype)shared {
    static M27Prefs *shared;
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

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)fallback {
    id value = _plist[key];
    if (value == nil) {
        CFPropertyListRef cfVal = CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, (__bridge CFStringRef)M27PrefDomain);
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
        return fallback;
    }
    return [value boolValue];
}

- (void)reload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)M27PrefDomain);
    _plist = M27ReadPrefsDictionary();

    // One-time recovery markers. 1.1.9 forced dock/theme OFF so Music could
    // launch; later markers record safer dock hosting without re-forcing OFF
    // if the user already re-enabled the dock for verification.
    if (_plist[@"blankScreenFix119"] == nil) {
        NSMutableDictionary *seed = [_plist mutableCopy] ?: [NSMutableDictionary dictionary];
        seed[@"blankScreenFix119"] = @YES;
        seed[@"hostBlankFix111"] = @YES;
        seed[@"dockOverlayFix112"] = @YES;
        seed[@"dockSafeBoot115"] = @YES;
        seed[@"miniFadeRecovery115"] = @YES;
        if (seed[@"enabled"] == nil) seed[@"enabled"] = @YES;
        seed[@"glassTabBar"] = @NO;
        seed[@"colorTheme"] = @NO;
        if (seed[@"libraryPins"] == nil) seed[@"libraryPins"] = @NO;
        M27WritePrefsDictionary(seed);
        _plist = [seed copy];
        CFPreferencesSetAppValue(CFSTR("blankScreenFix119"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("hostBlankFix111"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("dockOverlayFix112"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("glassTabBar"), kCFBooleanFalse,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("colorTheme"), kCFBooleanFalse,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("enabled"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)M27PrefDomain);
    } else if (_plist[@"miniFadeRecovery115"] == nil) {
        // 1.1.15: recover from 1.1.14 MiniPlayer fade black/crash — force dock OFF once.
        NSMutableDictionary *seed = [_plist mutableCopy] ?: [NSMutableDictionary dictionary];
        seed[@"miniFadeRecovery115"] = @YES;
        seed[@"dockOverlayFix112"] = @YES;
        seed[@"hostBlankFix111"] = @YES;
        seed[@"glassTabBar"] = @NO;
        M27WritePrefsDictionary(seed);
        _plist = [seed copy];
        CFPreferencesSetAppValue(CFSTR("miniFadeRecovery115"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("dockOverlayFix112"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("hostBlankFix111"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("glassTabBar"), kCFBooleanFalse,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)M27PrefDomain);
    } else if (_plist[@"dockOverlayFix112"] == nil) {
        NSMutableDictionary *seed = [_plist mutableCopy] ?: [NSMutableDictionary dictionary];
        seed[@"dockOverlayFix112"] = @YES;
        seed[@"hostBlankFix111"] = @YES;
        M27WritePrefsDictionary(seed);
        _plist = [seed copy];
        CFPreferencesSetAppValue(CFSTR("dockOverlayFix112"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("hostBlankFix111"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)M27PrefDomain);
    } else if (_plist[@"hostBlankFix111"] == nil) {
        NSMutableDictionary *seed = [_plist mutableCopy] ?: [NSMutableDictionary dictionary];
        seed[@"hostBlankFix111"] = @YES;
        M27WritePrefsDictionary(seed);
        _plist = [seed copy];
        CFPreferencesSetAppValue(CFSTR("hostBlankFix111"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)M27PrefDomain);
    }

    _enabled = [self boolForKey:@"enabled" defaultValue:YES];
    // Safe defaults when keys are missing: dock/theme OFF so Music opens.
    _glassTabBarEnabled = [self boolForKey:@"glassTabBar" defaultValue:NO];
    _colorThemeEnabled = [self boolForKey:@"colorTheme" defaultValue:NO];
    _libraryPinsEnabled = [self boolForKey:@"libraryPins" defaultValue:NO];
}

@end
