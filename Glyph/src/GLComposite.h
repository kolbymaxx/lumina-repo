#import <UIKit/UIKit.h>
#import "GLPixelKit.h"

NS_ASSUME_NONNULL_BEGIN

/// The CoreGraphics ↔ GLPixelKit bridge. Draws `base` into an RGBA8 bitmap at
/// exactly `pointSize` × `scale`, runs the recipe over the pixels, and hands
/// back a UIImage.
///
/// Called only from GLIconCache on a miss — i.e. once per icon per cache
/// generation, when a theme or a preference actually changed. Never on a
/// per-frame path.
///
/// Returns nil if anything at all goes wrong, which the caller treats as
/// "use the stock icon".
UIImage *_Nullable GLCompositeImage(UIImage *_Nullable base,
                                    CGSize pointSize,
                                    CGFloat scale,
                                    const GLRecipe *recipe);

NS_ASSUME_NONNULL_END
