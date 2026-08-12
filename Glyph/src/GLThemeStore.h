#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads classic SnowBoard theme packs exactly as they exist on disk:
///   <jbroot>/Library/Themes/<Theme>/IconBundles/<bundleID>-large.png
/// No conversion, no re-packaging. Read-only.
@interface GLThemeStore : NSObject

/// Candidate Themes directories, most specific first
/// (jbroot -> /var/jb -> rootfs).
+ (NSArray<NSString *> *)themesRootCandidates;

/// Theme folder names present on disk (".theme" suffix stripped), sorted.
/// For the Phase D manager UI; Phase B reads `selectedThemes` from prefs.
+ (NSArray<NSString *> *)availableThemeNames;

/// Absolute path of the themed PNG for a bundle ID, or nil when no selected
/// theme provides one. Iterates the `selectedThemes` pref in priority order;
/// within a theme tries the classic filename variants:
///   <id>-large.png, <id>@3x.png, <id>@2x.png, <id>.png
+ (nullable NSString *)iconPathForBundleID:(NSString *)bundleID;

/// YES when at least one selected theme resolves to a real IconBundles dir.
+ (BOOL)hasActiveThemes;

/// Drop the resolved-directory cache (call when themes or prefs change).
+ (void)invalidate;

@end

NS_ASSUME_NONNULL_END
