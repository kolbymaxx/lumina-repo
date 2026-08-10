#import <Foundation/Foundation.h>
#import "GLPixelKit.h"

NS_ASSUME_NONNULL_BEGIN

/// Turns preferences into a GLRecipe. Phase D's whole configuration surface
/// funnels through here, so there is exactly one place that decides what a
/// given icon should look like.
///
/// The built recipe is cached and only rebuilt when GLRecipeBuilderInvalidate()
/// runs (prefs or theme change), because it is consulted on every cache miss.

/// Recipe for a specific app. Returns NO when Glyph should leave this icon
/// completely alone — the app is excluded, or the effective mode is stock with
/// no corner mask, in which case a themed PNG still applies but no compositing
/// happens.
BOOL GLRecipeForBundleID(NSString *_Nullable bundleID, GLRecipe *out);

/// Digest of the current global recipe, part of the icon cache key.
uint64_t GLCurrentRecipeHash(void);

/// YES when the current configuration composites anything at all. Lets the hook
/// keep Phase B's exact behaviour (themed PNG substitution only) when the user
/// has not turned on any Phase D effect.
BOOL GLRecipeCompositingActive(void);

/// Drop the cached recipe.
void GLRecipeBuilderInvalidate(void);

/// Parse "#rrggbb" / "rrggbb" / "0xRRGGBB". Returns `fallback` on anything
/// unexpected — fail closed, never a crash on a hand-edited plist.
GLColor GLColorFromPrefString(NSString *_Nullable hex, GLColor fallback);

NS_ASSUME_NONNULL_END
