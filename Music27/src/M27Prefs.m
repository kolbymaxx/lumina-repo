#import "Music27.h"
#import "SPKRuntime.h"

NSString *const M27PrefDomain = @"com.music27.tweak";
NSString *const M27ThemeDidChangeNotification = @"M27ThemeDidChangeNotification";
NSString *const M27PinsDidChangeNotification = @"M27PinsDidChangeNotification";
const NSInteger M27MaxPins = 12;

// Jailbreak root and prefs path resolution now live in SPKit — one copy shared
// with SwiftPeek and CC27 instead of six that drift apart. M27JailbreakRoot
// stays as the name the rest of Music27 calls.
NSString *M27JailbreakRoot(void) {
    return SPKJailbreakRoot();
}

static NSArray<NSString *> *M27PrefsCandidatePaths(void) {
    return SPKPrefsCandidatePaths(M27PrefDomain);
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
        seed[@"whiteScreenRecovery120"] = @YES;
        seed[@"statusBarOverlay121"] = @YES;
        seed[@"dockWindowLevel122"] = @YES;
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
    } else if (_plist[@"dockWindowLevel122"] == nil) {
        // 1.1.22: overlay window level back to Normal+2 (the 1.1.12 config).
        // StatusBar-1 was what blanked Music in 1.1.19/1.1.21, not the cover
        // plate, and that level is gone — so this migration does NOT force the
        // dock OFF. Whatever the user last chose is kept.
        NSMutableDictionary *seed = [_plist mutableCopy] ?: [NSMutableDictionary dictionary];
        seed[@"dockWindowLevel122"] = @YES;
        seed[@"statusBarOverlay121"] = @YES;
        seed[@"whiteScreenRecovery120"] = @YES;
        seed[@"miniFadeRecovery115"] = @YES;
        seed[@"dockOverlayFix112"] = @YES;
        seed[@"hostBlankFix111"] = @YES;
        M27WritePrefsDictionary(seed);
        _plist = [seed copy];
        CFPreferencesSetAppValue(CFSTR("dockWindowLevel122"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("statusBarOverlay121"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("whiteScreenRecovery120"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("miniFadeRecovery115"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("dockOverlayFix112"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("hostBlankFix111"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)M27PrefDomain);
    } else if (_plist[@"whiteScreenRecovery120"] == nil) {
        // 1.1.20: 1.1.19 full-screen white cover blanked iOS 17.3 light Music.
        // Force dock OFF once so Library is usable after install.
        NSMutableDictionary *seed = [_plist mutableCopy] ?: [NSMutableDictionary dictionary];
        seed[@"whiteScreenRecovery120"] = @YES;
        seed[@"miniFadeRecovery115"] = @YES;
        seed[@"dockOverlayFix112"] = @YES;
        seed[@"hostBlankFix111"] = @YES;
        seed[@"glassTabBar"] = @NO;
        M27WritePrefsDictionary(seed);
        _plist = [seed copy];
        CFPreferencesSetAppValue(CFSTR("whiteScreenRecovery120"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("miniFadeRecovery115"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("dockOverlayFix112"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("hostBlankFix111"), kCFBooleanTrue,
                                 (__bridge CFStringRef)M27PrefDomain);
        CFPreferencesSetAppValue(CFSTR("glassTabBar"), kCFBooleanFalse,
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
    _hideStockChromeEnabled = [self boolForKey:@"hideStockChrome" defaultValue:YES];
    _nowPlayingGlassEnabled = [self boolForKey:@"nowPlayingGlass" defaultValue:NO];
}

@end
