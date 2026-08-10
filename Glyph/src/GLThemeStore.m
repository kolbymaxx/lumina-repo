#import "GLThemeStore.h"
#import "GLPrefs.h"

@implementation GLThemeStore

static NSArray<NSString *> *gGLResolvedIconBundleDirs = nil;

+ (NSArray<NSString *> *)themesRootCandidates {
    NSMutableArray *roots = [NSMutableArray array];
    NSString *jbPrefix = GLJailbreakRootPrefix();
    if (jbPrefix.length) [roots addObject:[jbPrefix stringByAppendingString:@"/Library/Themes"]];
    [roots addObject:@"/var/jb/Library/Themes"];
    [roots addObject:@"/Library/Themes"];
    return roots;
}

+ (NSArray<NSString *> *)availableThemeNames {
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in [self themesRootCandidates]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;
        for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            NSString *name = entry;
            if ([name hasSuffix:@".theme"]) name = [name substringToIndex:name.length - 6];
            if (name.length) [names addObject:name];
        }
    }
    return [names.array sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

/// Resolve the selected themes (pref `selectedThemes`, priority order) to
/// absolute IconBundles directories that actually exist. Cached until
/// -invalidate. A theme folder may be named "<Name>" or "<Name>.theme".
+ (NSArray<NSString *> *)resolvedIconBundleDirs {
    if (gGLResolvedIconBundleDirs) return gGLResolvedIconBundleDirs;

    NSMutableArray *dirs = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *selected = GLPrefArray(@"selectedThemes");
    for (id entry in selected ?: @[]) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *themeName = entry;
        // Fail closed on anything that could escape the Themes directory.
        if ([themeName containsString:@"/"] || [themeName containsString:@".."]) continue;

        for (NSString *root in [self themesRootCandidates]) {
            for (NSString *folder in @[ themeName,
                                        [themeName stringByAppendingString:@".theme"] ]) {
                NSString *dir = [[root stringByAppendingPathComponent:folder]
                                 stringByAppendingPathComponent:@"IconBundles"];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) {
                    [dirs addObject:dir];
                    goto nextTheme;   // first existing root wins for this theme
                }
            }
        }
    nextTheme:;
    }
    gGLResolvedIconBundleDirs = [dirs copy];
    return gGLResolvedIconBundleDirs;
}

+ (NSString *)iconPathForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;
    if ([bundleID containsString:@"/"] || [bundleID containsString:@".."]) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [self resolvedIconBundleDirs]) {
        for (NSString *suffix in @[ @"-large.png", @"@3x.png", @"@2x.png", @".png" ]) {
            NSString *path = [dir stringByAppendingPathComponent:
                              [bundleID stringByAppendingString:suffix]];
            if ([fm fileExistsAtPath:path]) return path;
        }
    }
    return nil;
}

+ (BOOL)hasActiveThemes {
    return [self resolvedIconBundleDirs].count > 0;
}

+ (void)invalidate {
    gGLResolvedIconBundleDirs = nil;
}

@end
