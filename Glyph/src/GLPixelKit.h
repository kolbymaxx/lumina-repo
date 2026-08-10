#ifndef GL_PIXELKIT_H
#define GL_PIXELKIT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// -----------------------------------------------------------------------------
// Glyph Phase D — composite kernels
//
// Deliberately plain C with no Foundation, no UIKit, no CoreGraphics. Two
// reasons:
//
//   1. This is the only code in Glyph that touches every pixel, so it must not
//      pay for an objc_msgSend per operation.
//   2. It compiles and runs on a Linux host, which means the colour maths is
//      covered by a real test harness (`tools/glyph-preview.c`) instead of
//      being validated for the first time on a device that can Safe Mode.
//
// Every function here runs at *composite* time — once per icon per cache
// generation, when a theme or preference actually changes. Nothing in this file
// is ever on a per-frame path.
//
// Buffers are RGBA8 with **straight** (un-premultiplied) alpha, row-major, no
// padding. CoreGraphics hands back premultiplied pixels, so the ObjC bridge
// calls GLUnpremultiplyInPlace on the way in and GLPremultiplyInPlace on the
// way out.
// -----------------------------------------------------------------------------

typedef struct { float r, g, b; } GLColor;

typedef enum {
    GLModeStock          = 0,  // passthrough — no compositing
    GLModeTinted         = 1,  // iOS 18 "tinted": dark plate, light glyph, user hue
    GLModeTintedLight    = 2,  // inverted: light plate, dark glyph
    GLModeDark           = 3,  // iOS 18 "dark": keep hue, compress highlights
    GLModeClearGlass     = 4,  // iOS 26/27 clear glass, light
    GLModeClearGlassDark = 5,  // iOS 26/27 clear glass, dark
} GLMode;

/// Whole-image statistics. Computed once per composite and reused by every
/// stage, because auto-levels needs percentiles and the glass stage needs to
/// know whether it is looking at full-bleed artwork or a free-standing glyph.
typedef struct {
    float lumaP02, lumaP50, lumaP98;  // luminance percentiles over opaque pixels
    float meanSaturation;
    float alphaCoverage;              // fraction of pixels with alpha > 0.5
    float cornerAlpha;                // ~1.0 => full-bleed artwork
    float plateRatio;                 // high => glyph sitting on a flat plate
    GLColor meanColor;
    GLColor dominantColor;
    int    opaquePixels;
} GLStats;

typedef struct {
    GLColor tint;
    float levels;        // 0..1 — how much auto-levels normalisation to apply
    float contrast;      // 0..1 — S-curve amount on the normalised luminance
    float gamma;         // 0.4..2.5 — midpoint shaping
    float shadowLift;    // 0..1 — how far the dark stop lifts off black
    float highlightSat;  // 0..1 — saturation retained in the light stop
    int   plateFill;     // synthesise a plate behind glyph-only icons
    int   invert;        // 1 = light plate / dark glyph (iOS 18 "light tinted")
} GLTintParams;

typedef struct {
    float strength;      // 0..1 — highlight compression
    float saturation;    // multiplier, 1.0 = unchanged
} GLDarkParams;

typedef struct {
    float plateAlpha;    // 0..1 — alpha left on the glass plate
    float glyphAlpha;    // 0..1 — alpha retained where glyph detail lives
    float frost;         // 0..1 — desaturate + lift toward the glass base
    float specular;      // 0..1 — top-left highlight strength
    float rim;           // 0..1 — edge light band
    float innerShadow;   // 0..1 — bottom-right inner shading
    float refraction;    // 0..1 — edge lensing + chromatic dispersion
    GLColor tint;
    float tintAmount;    // 0..1
    int   dark;          // dark glass variant
} GLGlassParams;

typedef struct {
    GLMode mode;
    GLTintParams tint;
    GLDarkParams dark;
    GLGlassParams glass;
    float cornerRadiusFrac;  // 0 = leave alpha alone; else squircle mask
} GLRecipe;

/// Fill a recipe with the defaults for `mode` and a tint colour. Callers then
/// override individual fields from preferences.
void GLRecipeDefaults(GLRecipe *out, GLMode mode, GLColor tint);

/// Stable 64-bit digest of a recipe. Part of the icon cache key, so changing
/// any slider invalidates exactly the affected images and nothing else.
uint64_t GLRecipeHash(const GLRecipe *r);

/// Alpha conversions for the CoreGraphics boundary.
void GLUnpremultiplyInPlace(uint8_t *rgba, int w, int h);
void GLPremultiplyInPlace(uint8_t *rgba, int w, int h);

/// Whole-image statistics over straight-alpha RGBA8.
void GLBitmapStats(const uint8_t *rgba, int w, int h, GLStats *out);

/// Composite the image over a synthesised rounded plate of `plate`, setting
/// alpha to the squircle coverage. Used for glyph-only artwork (a themed PNG
/// with a transparent background), which otherwise has nothing for the tint
/// ramp or the glass stage to act on. Alpha-changing by design.
int GLSynthesizePlate(uint8_t *rgba, int w, int h, GLColor plate, float radiusFrac);

/// The three colour stops the tint ramp interpolates through, derived from the
/// user's colour. Exposed so the plate synthesiser and the preference UI's
/// preview swatch agree with what GLApplyTint will actually draw.
void GLTintStops(const GLTintParams *p, GLColor *dark, GLColor *mid, GLColor *light);

/// Individual stages. Each is in-place, alpha-preserving unless documented,
/// and a no-op on bad input. Return 1 on success, 0 if the stage bailed
/// (allocation failure, degenerate input) leaving the buffer untouched.
int GLApplyTint(uint8_t *rgba, int w, int h, const GLTintParams *p, const GLStats *s);
int GLApplyDark(uint8_t *rgba, int w, int h, const GLDarkParams *p);
int GLApplyGlass(uint8_t *rgba, int w, int h, const GLGlassParams *p, const GLStats *s);
int GLApplyCornerMask(uint8_t *rgba, int w, int h, float radiusFrac);

/// Run a whole recipe. Computes stats internally. Returns 1 when the buffer was
/// modified, 0 when the recipe was a passthrough or the input was rejected.
int GLApplyRecipe(uint8_t *rgba, int w, int h, const GLRecipe *r);

/// sRGB helpers, exposed for the preference UI's live swatch.
float GLSRGBToLinear(float c);
float GLLinearToSRGB(float c);
GLColor GLColorFromHex(uint32_t rgb);

#ifdef __cplusplus
}
#endif

#endif // GL_PIXELKIT_H
