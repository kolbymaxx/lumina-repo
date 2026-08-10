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

/// Final image for a bundle ID rendered at pointSize x scale, or nil when Glyph
/// has nothing to contribute (callers then fall through to %orig).
///
/// The base layer is the selected theme's PNG when one exists. When no theme
/// provides that bundle ID, `stockImage` becomes the base instead — which is
/// what lets a tint or glass recipe recolour every icon on the home screen,
/// themed or not. With no theme *and* no active recipe this returns nil, so
/// Phase B behaviour is preserved exactly.
- (nullable UIImage *)imageForBundleID:(NSString *)bundleID
                            stockImage:(nullable UIImage *)stockImage
                             pointSize:(CGSize)pointSize
                                 scale:(CGFloat)scale;

/// Empty the cache and start a new generation.
- (void)bumpGeneration;

@end

NS_ASSUME_NONNULL_END
