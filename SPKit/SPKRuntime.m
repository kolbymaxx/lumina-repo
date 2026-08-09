#import "SPKRuntime.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#pragma mark - Jailbreak root

NSString *SPKJailbreakRoot(void) {
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = @"";

        // RootHide exports jbroot(); it is the authoritative answer where it
        // exists. Reject NULL, empty and bare "/" — all three mean "no prefix",
        // and appending "/" would produce doubled separators downstream.
        const char *(*jbrootFn)(const char *) =
            (const char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootFn) {
            const char *p = jbrootFn("/");
            if (p && p[0] != '\0' && strcmp(p, "/") != 0) {
                prefix = [[NSString stringWithUTF8String:p] stringByStandardizingPath];
                return;
            }
        }

        // Otherwise infer it from where this dylib was loaded from. On Dopamine
        // that yields "/var/jb"; on a rootful jailbreak the marker sits at index
        // 0 and we correctly fall through to "".
        Dl_info info = {0};
        if (dladdr((const void *)SPKJailbreakRoot, &info) && info.dli_fname) {
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

NSString *SPKRootedPath(NSString *relativePath) {
    NSString *rel = relativePath ?: @"";
    if (rel.length && ![rel hasPrefix:@"/"]) rel = [@"/" stringByAppendingString:rel];
    return [SPKJailbreakRoot() stringByAppendingString:rel];
}

#pragma mark - Preferences

NSArray<NSString *> *SPKPrefsCandidatePaths(NSString *domain) {
    if (domain.length == 0) return @[];
    NSString *rel = [NSString stringWithFormat:
                     @"/var/mobile/Library/Preferences/%@.plist", domain];

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *jb = SPKJailbreakRoot();
    if (jb.length) [paths addObject:[jb stringByAppendingString:rel]];
    // /var/jb explicitly, in case the dladdr inference above came back empty on
    // a rootless install (a tweak loaded from an unusual path, say).
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];

    NSMutableArray<NSString *> *unique = [NSMutableArray array];
    for (NSString *p in paths) {
        if (![unique containsObject:p]) [unique addObject:p];
    }
    return unique;
}

static NSMutableDictionary<NSString *, NSDictionary *> *SPKPrefsCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static NSMutableDictionary<NSString *, NSNumber *> *SPKPrefsCacheStamps(void) {
    static NSMutableDictionary *stamps = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ stamps = [NSMutableDictionary dictionary]; });
    return stamps;
}

NSDictionary *SPKPrefs(NSString *domain) {
    if (domain.length == 0) return @{};

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *stamp = SPKPrefsCacheStamps()[domain];
    NSDictionary *cached = SPKPrefsCache()[domain];
    if (cached && stamp && (now - stamp.doubleValue) < 0.5) return cached;

    NSDictionary *found = @{};
    for (NSString *path in SPKPrefsCandidatePaths(domain)) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        // An empty dictionary is not a hit — a stub file at an early candidate
        // would otherwise mask the real prefs at a later one.
        if ([d isKindOfClass:NSDictionary.class] && d.count > 0) {
            found = d;
            break;
        }
    }

    SPKPrefsCache()[domain] = found;
    SPKPrefsCacheStamps()[domain] = @(now);
    return found;
}

BOOL SPKPrefBool(NSString *domain, NSString *key, BOOL fallback) {
    if (domain.length == 0 || key.length == 0) return fallback;

    // PreferenceLoader writes through CFPreferences; the plist on disk can lag
    // behind a toggle the user just flipped.
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef cfVal = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)domain);
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

    id v = SPKPrefs(domain)[key];
    if (v != nil) return [v boolValue];
    return fallback;
}

void SPKPrefsInvalidate(void) {
    [SPKPrefsCache() removeAllObjects];
    [SPKPrefsCacheStamps() removeAllObjects];
}

#pragma mark - Kill switch

BOOL SPKKillSwitchEngaged(NSString *subdirectory) {
    if (subdirectory.length == 0) return NO;
    NSString *rel = [NSString stringWithFormat:@"/var/mobile/Library/%@/DISABLE", subdirectory];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *jb = SPKJailbreakRoot();
    if (jb.length) [paths addObject:[jb stringByAppendingString:rel]];
    [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
    [paths addObject:rel];

    for (NSString *p in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) return YES;
    }
    return NO;
}

#pragma mark - Tracing

static NSString *gSPKTraceSubdirectory = nil;
static NSString *gSPKTraceVersion = nil;
static NSMutableSet<NSString *> *gSPKTraceDedupedStages = nil;
static NSMutableDictionary<NSString *, NSString *> *gSPKTraceLastBody = nil;

void SPKTraceConfigure(NSString *subdirectory, NSString *version) {
    gSPKTraceSubdirectory = [subdirectory copy];
    gSPKTraceVersion = [version copy];
    if (!gSPKTraceDedupedStages) gSPKTraceDedupedStages = [NSMutableSet set];
    if (!gSPKTraceLastBody) gSPKTraceLastBody = [NSMutableDictionary dictionary];
}

void SPKTraceDedupeStage(NSString *stage) {
    if (stage.length == 0) return;
    if (!gSPKTraceDedupedStages) gSPKTraceDedupedStages = [NSMutableSet set];
    [gSPKTraceDedupedStages addObject:stage];
}

void SPKTrace(NSString *stage, NSDictionary *info) {
    if (gSPKTraceSubdirectory.length == 0) return;

    NSMutableDictionary *entry = [info mutableCopy] ?: [NSMutableDictionary dictionary];
    entry[@"stage"] = stage ?: @"?";
    if (gSPKTraceVersion.length) entry[@"version"] = gSPKTraceVersion;
    entry[@"ios"] = UIDevice.currentDevice.systemVersion ?: @"?";

    // Nothing below may throw out of this function. A trace call that crashes
    // the process it is meant to explain is worse than no trace at all.
    @try {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *key in [entry.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, entry[key]]];
        }
        NSString *body = [parts componentsJoinedByString:@" "];

        if (stage.length && [gSPKTraceDedupedStages containsObject:stage]) {
            if ([body isEqualToString:gSPKTraceLastBody[stage]]) return;
            gSPKTraceLastBody[stage] = [body copy];
        }

        NSString *dir = SPKRootedPath([NSString stringWithFormat:
                                       @"/var/mobile/Library/%@", gSPKTraceSubdirectory]);
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];

        NSISO8601DateFormatter *fmt = [NSISO8601DateFormatter new];
        NSString *ts = [fmt stringFromDate:NSDate.date] ?: @"";
        entry[@"timestamp"] = ts;

        NSString *line = [NSString stringWithFormat:@"%@ %@\n", ts, body];
        NSString *logPath = [dir stringByAppendingPathComponent:@"status.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                // Force it to disk now. A crash one instruction later must not
                // take this line with it — that is the entire contract.
                [fh synchronizeFile];
            } @finally {
                [fh closeFile];
            }
        } else {
            [line writeToFile:logPath atomically:YES
                     encoding:NSUTF8StringEncoding error:nil];
        }

        NSData *json = [NSJSONSerialization dataWithJSONObject:entry
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        if (json) {
            [json writeToFile:[dir stringByAppendingPathComponent:@"status.json"]
                      options:NSDataWritingAtomic error:nil];
        }
    } @catch (__unused NSException *ex) {}
}
