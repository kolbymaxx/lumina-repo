#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Decoded-icon cache. Each themed icon is loaded from disk and decoded into
/// a bitmap at its exact on-screen pixel size exactly once per theme
/// generation. After that, hooks hand out the cached UIImage — zero per-frame
/// decode, scale, or disk work. Misses are negatively cached so unthemed
/// bundle IDs cost one disk probe per generation.
@interface GLIconCache : NSObject

+ (instancetype)shared;

/// Monotonic generation. Bumped (and the cache emptied) whenever prefs or the
/// theme set change, so stale images can never be served.
@property (atomic, readonly) NSUInteger generation;

/// Themed image for a bundle ID rendered at pointSize x scale, or nil when no
/// selected theme provides one (callers then fall through to %orig).
- (nullable UIImage *)imageForBundleID:(NSString *)bundleID
                             pointSize:(CGSize)pointSize
                                 scale:(CGFloat)scale;

/// Empty the cache and start a new generation.
- (void)bumpGeneration;

@end

NS_ASSUME_NONNULL_END
