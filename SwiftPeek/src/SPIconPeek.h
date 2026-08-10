#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// SwiftPeek M4 — home screen icon inventory.
///
/// SwiftPeek went Music-only at 0.2.1 after a SpringBoard Safe Mode. This module
/// is the careful way back in, and it earns its keep: an icon-theming engine has
/// to know, per app, whether the artwork is full-bleed or a glyph on a plate,
/// how much contrast it carries, and whether a legacy theme already overrides
/// it. That is not answerable from a class dump.
///
/// Ground rules, all enforced below:
///   * opt-in behind the `iconInventory` pref, which itself requires
///     `targetSpringBoard`; both default off,
///   * no hooks, no swizzles, no Swift metadata walks, no FOVO,
///   * icon artwork is read through `+[UIImage _applicationIconImageForBundleIdentifier:…]`,
///     which renders from the app bundle and never touches SpringBoard's icon
///     model, cache, or view tree,
///   * the app list comes from LSApplicationWorkspace, not SBIconModel, so a
///     bad selector guess cannot perturb the home screen.

/// True when the inventory can run in this process (SpringBoard, pref enabled).
BOOL SPIconPeekAvailable(void);

/// One entry per installed, user-visible app:
///
///   bundle_id, display_name
///   icon_signature   — SPRenderSignatureForImage over the app's icon
///   theme_override   — path of a legacy IconBundles/SnowBoard override, if any
///   theme_signature  — signature of that override image, when readable
///
/// `maxIcons` caps the scan (0 → 200). Runs entirely off the main thread-safe
/// path; every per-icon step is individually @try-wrapped so one bad bundle
/// cannot abort the sweep.
NSArray<NSDictionary *> *SPIconInventory(NSInteger maxIcons);

/// Directories searched for legacy icon themes, jbroot-aware. Exposed for the
/// status breadcrumb so a user can see where SwiftPeek looked.
NSArray<NSString *> *SPIconThemeSearchPaths(void);

NS_ASSUME_NONNULL_END
