#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// SwiftPeek M3 — "render peek".
///
/// Everything here is read-only in the strongest sense: it never touches a live
/// view's geometry, never forces a layout pass, and never renders a view
/// hierarchy. The only pixels it reads come from `UIImage` objects the caller
/// already holds, drawn into a private offscreen bitmap.
///
/// The point is to answer questions a class dump cannot: *what does this image
/// actually look like* — is it full-bleed or a glyph sitting on a plate, how
/// much contrast does it carry, where does its luminance sit. That is exactly
/// what an icon-recolouring pipeline has to know before it can tint anything.

/// Pixel signature for one image. Keys are stable and JSON-safe:
///
///   width, height, scale          — points and screen scale of the source
///   alpha_coverage                — fraction of pixels with alpha > 0.5
///   corner_alpha                  — mean alpha of the four corner blocks
///                                   (~1.0 means full-bleed artwork)
///   mean_hex                      — average opaque colour, "#rrggbb"
///   dominant_hex                  — most common quantised opaque colour
///   plate_ratio                   — fraction of opaque pixels close to the
///                                   dominant colour (high == glyph on a plate)
///   luma_p02 / luma_p50 / luma_p98 — luminance percentiles over opaque pixels
///   luma_hist                     — 8 normalised luminance buckets
///   saturation_mean               — mean HSB saturation of opaque pixels
///   edge_density                  — mean luminance gradient magnitude
///   opaque_pixels                 — sample count behind the statistics
///
/// Returns nil when the image has no drawable backing.
NSDictionary * _Nullable SPRenderSignatureForImage(UIImage * _Nullable image);

/// Same statistics, straight from a premultiplied RGBA8 buffer. Exposed so a
/// caller that already has pixels (a cache, a decoder) skips the extra draw.
NSDictionary * _Nullable SPRenderSignatureForRGBA(const uint8_t *rgba,
                                                  size_t width,
                                                  size_t height,
                                                  CGFloat scale);

/// Breadth-first structural peek over a view tree. Records class, geometry and
/// the layer/image properties that matter when re-skinning something — corner
/// radius, mask, content mode, image point size. Never forces `-layoutIfNeeded`
/// and never instantiates a lazily-loaded view.
NSArray<NSDictionary *> *SPRenderPeekViewTree(UIView * _Nullable root,
                                              NSInteger maxNodes,
                                              NSInteger maxDepth);

NS_ASSUME_NONNULL_END
