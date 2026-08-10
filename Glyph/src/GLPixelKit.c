#include "GLPixelKit.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// -----------------------------------------------------------------------------
// Glyph Phase D — composite kernels (pure C, host-testable)
// -----------------------------------------------------------------------------

#define GL_HIST_BINS 1024

static inline float glClampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline float glMixf(float a, float b, float t) {
    return a + (b - a) * t;
}

static inline float glLuma(float r, float g, float b) {
    return 0.2126f * r + 0.7152f * g + 0.0722f * b;
}

float GLSRGBToLinear(float c) {
    if (c <= 0.04045f) return c / 12.92f;
    return powf((c + 0.055f) / 1.055f, 2.4f);
}

float GLLinearToSRGB(float c) {
    if (c <= 0.0031308f) return c * 12.92f;
    return 1.055f * powf(c, 1.0f / 2.4f) - 0.055f;
}

GLColor GLColorFromHex(uint32_t rgb) {
    GLColor c;
    c.r = (float)((rgb >> 16) & 0xFF) / 255.0f;
    c.g = (float)((rgb >> 8) & 0xFF) / 255.0f;
    c.b = (float)(rgb & 0xFF) / 255.0f;
    return c;
}

/// HSB-ish helpers used to derive the two tint stops. Working in sRGB here is
/// intentional: the stops are a designer-facing choice, not a physical one, and
/// sRGB matches what a colour picker shows the user.
static void glRGBToHSB(GLColor c, float *h, float *s, float *v) {
    float mx = fmaxf(c.r, fmaxf(c.g, c.b));
    float mn = fminf(c.r, fminf(c.g, c.b));
    float d = mx - mn;
    *v = mx;
    *s = (mx <= 0.0001f) ? 0.0f : (d / mx);
    if (d <= 0.0001f) {
        *h = 0.0f;
        return;
    }
    float hh;
    if (mx == c.r)      hh = (c.g - c.b) / d + (c.g < c.b ? 6.0f : 0.0f);
    else if (mx == c.g) hh = (c.b - c.r) / d + 2.0f;
    else                hh = (c.r - c.g) / d + 4.0f;
    *h = hh / 6.0f;
}

static GLColor glHSBToRGB(float h, float s, float v) {
    GLColor out = { v, v, v };
    if (s <= 0.0001f) return out;
    h = h - floorf(h);
    float i = floorf(h * 6.0f);
    float f = h * 6.0f - i;
    float p = v * (1.0f - s);
    float q = v * (1.0f - s * f);
    float t = v * (1.0f - s * (1.0f - f));
    switch (((int)i) % 6) {
        case 0: out.r = v; out.g = t; out.b = p; break;
        case 1: out.r = q; out.g = v; out.b = p; break;
        case 2: out.r = p; out.g = v; out.b = t; break;
        case 3: out.r = p; out.g = q; out.b = v; break;
        case 4: out.r = t; out.g = p; out.b = v; break;
        default: out.r = v; out.g = p; out.b = q; break;
    }
    return out;
}

// -----------------------------------------------------------------------------
// Alpha conversions
// -----------------------------------------------------------------------------

void GLUnpremultiplyInPlace(uint8_t *rgba, int w, int h) {
    if (!rgba || w <= 0 || h <= 0) return;
    size_t n = (size_t)w * (size_t)h;
    for (size_t i = 0; i < n; i++) {
        uint8_t *p = rgba + i * 4;
        uint32_t a = p[3];
        if (a == 0) { p[0] = p[1] = p[2] = 0; continue; }
        if (a == 255) continue;
        for (int c = 0; c < 3; c++) {
            uint32_t v = ((uint32_t)p[c] * 255u + a / 2u) / a;
            p[c] = (uint8_t)(v > 255u ? 255u : v);
        }
    }
}

void GLPremultiplyInPlace(uint8_t *rgba, int w, int h) {
    if (!rgba || w <= 0 || h <= 0) return;
    size_t n = (size_t)w * (size_t)h;
    for (size_t i = 0; i < n; i++) {
        uint8_t *p = rgba + i * 4;
        uint32_t a = p[3];
        if (a == 255) continue;
        if (a == 0) { p[0] = p[1] = p[2] = 0; continue; }
        for (int c = 0; c < 3; c++) {
            p[c] = (uint8_t)(((uint32_t)p[c] * a + 127u) / 255u);
        }
    }
}

// -----------------------------------------------------------------------------
// Statistics
// -----------------------------------------------------------------------------

static float glHistPercentile(const uint32_t *hist, int bins, uint32_t total, float p) {
    if (total == 0) return 0.0f;
    uint32_t target = (uint32_t)(p * (float)total);
    uint32_t acc = 0;
    for (int i = 0; i < bins; i++) {
        acc += hist[i];
        if (acc >= target) return (float)i / (float)(bins - 1);
    }
    return 1.0f;
}

void GLBitmapStats(const uint8_t *rgba, int w, int h, GLStats *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!rgba || w <= 0 || h <= 0) return;

    uint32_t hist[GL_HIST_BINS];
    memset(hist, 0, sizeof(hist));

    // 5 bits per channel is coarse enough that an anti-aliased flat plate lands
    // in a single bucket, which is exactly what plateRatio is asking about.
    static const int kQuant = 32;
    uint32_t *cube = (uint32_t *)calloc((size_t)kQuant * kQuant * kQuant, sizeof(uint32_t));

    double sumR = 0, sumG = 0, sumB = 0, sumSat = 0, sumAlpha = 0;
    uint32_t opaque = 0;
    size_t n = (size_t)w * (size_t)h;

    for (size_t i = 0; i < n; i++) {
        const uint8_t *p = rgba + i * 4;
        float a = p[3] / 255.0f;
        sumAlpha += a;
        if (a <= 0.5f) continue;

        float r = p[0] / 255.0f, g = p[1] / 255.0f, b = p[2] / 255.0f;
        float l = glLuma(r, g, b);
        int bin = (int)(l * (GL_HIST_BINS - 1) + 0.5f);
        if (bin < 0) bin = 0;
        if (bin >= GL_HIST_BINS) bin = GL_HIST_BINS - 1;
        hist[bin]++;

        sumR += r; sumG += g; sumB += b;
        float mx = fmaxf(r, fmaxf(g, b));
        float mn = fminf(r, fminf(g, b));
        sumSat += (mx <= 0.0001f) ? 0.0f : ((mx - mn) / mx);
        opaque++;

        if (cube) {
            int qr = (int)(r * (kQuant - 1));
            int qg = (int)(g * (kQuant - 1));
            int qb = (int)(b * (kQuant - 1));
            cube[((size_t)qr * kQuant + qg) * kQuant + qb]++;
        }
    }

    out->alphaCoverage = (float)(sumAlpha / (double)n);
    out->opaquePixels = (int)opaque;

    if (opaque == 0) {
        free(cube);
        return;
    }

    out->lumaP02 = glHistPercentile(hist, GL_HIST_BINS, opaque, 0.02f);
    out->lumaP50 = glHistPercentile(hist, GL_HIST_BINS, opaque, 0.50f);
    out->lumaP98 = glHistPercentile(hist, GL_HIST_BINS, opaque, 0.98f);
    out->meanSaturation = (float)(sumSat / opaque);
    out->meanColor.r = (float)(sumR / opaque);
    out->meanColor.g = (float)(sumG / opaque);
    out->meanColor.b = (float)(sumB / opaque);

    if (cube) {
        uint32_t best = 0;
        int bestIdx = 0;
        for (int i = 0; i < kQuant * kQuant * kQuant; i++) {
            if (cube[i] > best) { best = cube[i]; bestIdx = i; }
        }
        out->plateRatio = (float)best / (float)opaque;
        out->dominantColor.b = (float)(bestIdx % kQuant) / (kQuant - 1);
        out->dominantColor.g = (float)((bestIdx / kQuant) % kQuant) / (kQuant - 1);
        out->dominantColor.r = (float)(bestIdx / (kQuant * kQuant)) / (kQuant - 1);
        free(cube);
    }

    // Corner alpha separates full-bleed app artwork from a free-standing glyph.
    int block = w / 16;
    if (block < 1) block = 1;
    double cornerSum = 0;
    int cornerCount = 0;
    for (int cy = 0; cy < 2; cy++) {
        for (int cx = 0; cx < 2; cx++) {
            for (int y = 0; y < block; y++) {
                for (int x = 0; x < block; x++) {
                    int px = cx ? (w - 1 - x) : x;
                    int py = cy ? (h - 1 - y) : y;
                    cornerSum += rgba[((size_t)py * w + px) * 4 + 3] / 255.0;
                    cornerCount++;
                }
            }
        }
    }
    out->cornerAlpha = cornerCount ? (float)(cornerSum / cornerCount) : 0.0f;
}

// -----------------------------------------------------------------------------
// Separable box blur (3 passes ~= Gaussian)
// -----------------------------------------------------------------------------

static void glBoxBlurPass(const float *src, float *dst, int w, int h, int radius) {
    if (radius < 1) {
        memcpy(dst, src, (size_t)w * h * sizeof(float));
        return;
    }
    float norm = 1.0f / (float)(2 * radius + 1);

    // Horizontal
    for (int y = 0; y < h; y++) {
        const float *row = src + (size_t)y * w;
        float *out = dst + (size_t)y * w;
        float acc = row[0] * (float)(radius + 1);
        for (int i = 1; i <= radius && i < w; i++) acc += row[i];
        if (w <= radius) acc = row[0] * (float)(2 * radius + 1);
        for (int x = 0; x < w; x++) {
            int addIdx = x + radius + 1;
            int subIdx = x - radius;
            float add = row[addIdx < w ? (addIdx < 0 ? 0 : addIdx) : (w - 1)];
            float sub = row[subIdx > 0 ? (subIdx < w ? subIdx : w - 1) : 0];
            out[x] = acc * norm;
            acc += add - sub;
        }
    }

    // Vertical, in place over dst using a scratch column accumulator.
    float *col = (float *)malloc((size_t)h * sizeof(float));
    if (!col) return;
    for (int x = 0; x < w; x++) {
        for (int y = 0; y < h; y++) col[y] = dst[(size_t)y * w + x];
        float acc = col[0] * (float)(radius + 1);
        for (int i = 1; i <= radius && i < h; i++) acc += col[i];
        if (h <= radius) acc = col[0] * (float)(2 * radius + 1);
        for (int y = 0; y < h; y++) {
            int addIdx = y + radius + 1;
            int subIdx = y - radius;
            float add = col[addIdx < h ? (addIdx < 0 ? 0 : addIdx) : (h - 1)];
            float sub = col[subIdx > 0 ? (subIdx < h ? subIdx : h - 1) : 0];
            dst[(size_t)y * w + x] = acc * norm;
            acc += add - sub;
        }
    }
    free(col);
}

static void glBlur(const float *src, float *dst, int w, int h, int radius, float *scratch) {
    glBoxBlurPass(src, dst, w, h, radius);
    glBoxBlurPass(dst, scratch, w, h, radius);
    glBoxBlurPass(scratch, dst, w, h, radius);
}

static inline float glSampleF(const float *buf, int w, int h, float x, float y) {
    int xi = (int)glClampf(x, 0.0f, (float)(w - 1));
    int yi = (int)glClampf(y, 0.0f, (float)(h - 1));
    return buf[(size_t)yi * w + xi];
}

// -----------------------------------------------------------------------------
// Glyph / plate separation
//
// Local contrast tells the difference between artwork detail (a logo, a
// letterform) and the flat plate it sits on. Both the dark stage and the glass
// stage need it: the plate is what should darken or turn to glass, while the
// glyph has to stay legible.
// -----------------------------------------------------------------------------

static int glComputeGlyphMask(const uint8_t *rgba, int w, int h, float *out) {
    if (!rgba || !out || w <= 0 || h <= 0) return 0;
    size_t n = (size_t)w * (size_t)h;
    float *luma = (float *)malloc(n * sizeof(float));
    float *lumaB = (float *)malloc(n * sizeof(float));
    float *scratch = (float *)malloc(n * sizeof(float));
    if (!luma || !lumaB || !scratch) {
        free(luma); free(lumaB); free(scratch);
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        const uint8_t *px = rgba + i * 4;
        luma[i] = glLuma(px[0] / 255.0f, px[1] / 255.0f, px[2] / 255.0f);
    }
    int edge = (w < h ? w : h);
    int radius = edge / 12;
    if (radius < 1) radius = 1;
    glBlur(luma, lumaB, w, h, radius, scratch);
    for (size_t i = 0; i < n; i++) {
        out[i] = glClampf(fabsf(luma[i] - lumaB[i]) * 4.0f, 0.0f, 1.0f);
    }
    free(luma); free(lumaB); free(scratch);
    return 1;
}

// -----------------------------------------------------------------------------
// Plate synthesis
// -----------------------------------------------------------------------------

int GLSynthesizePlate(uint8_t *rgba, int w, int h, GLColor plate, float radiusFrac) {
    if (!rgba || w <= 0 || h <= 0) return 0;

    const float nExp = 5.0f;
    float cx = (float)w * 0.5f, cy = (float)h * 0.5f;
    float shape = glClampf(radiusFrac <= 0.0f ? 1.0f : radiusFrac, 0.0f, 1.0f);
    float aa = 2.0f / (float)w;

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            size_t i = (size_t)y * w + x;
            uint8_t *px = rgba + i * 4;

            float dx = fabsf(((float)x + 0.5f - cx) / cx);
            float dy = fabsf(((float)y + 0.5f - cy) / cy);
            float d = powf(powf(dx, nExp) + powf(dy, nExp), 1.0f / nExp);
            d = glMixf(fmaxf(dx, dy), d, shape);
            float cover = glClampf((1.0f - d) / aa, 0.0f, 1.0f);

            float a = px[3] / 255.0f;
            float r = glMixf(plate.r, px[0] / 255.0f, a);
            float g = glMixf(plate.g, px[1] / 255.0f, a);
            float b = glMixf(plate.b, px[2] / 255.0f, a);

            px[0] = (uint8_t)(glClampf(r, 0.0f, 1.0f) * 255.0f + 0.5f);
            px[1] = (uint8_t)(glClampf(g, 0.0f, 1.0f) * 255.0f + 0.5f);
            px[2] = (uint8_t)(glClampf(b, 0.0f, 1.0f) * 255.0f + 0.5f);
            px[3] = (uint8_t)(cover * 255.0f + 0.5f);
        }
    }
    return 1;
}

// -----------------------------------------------------------------------------
// Tinted (iOS 18 parity)
// -----------------------------------------------------------------------------

void GLTintStops(const GLTintParams *p, GLColor *dark, GLColor *mid, GLColor *light) {
    if (!p) return;
    float hue, sat, bri;
    glRGBToHSB(p->tint, &hue, &sat, &bri);

    // Three stops, not two. A straight dark→light interpolation of one hue
    // passes through grey in the midtones, which is why a two-stop ramp makes
    // every icon look brown no matter what colour the user picked. Anchoring
    // the middle of the ramp at the user's actual colour keeps the hue present
    // exactly where most of an icon's pixels land.
    GLColor d = glHSBToRGB(hue, glClampf(sat * 1.05f, 0.0f, 1.0f),
                           glClampf(0.06f + p->shadowLift * 0.34f, 0.0f, 1.0f));
    GLColor m = glHSBToRGB(hue, glClampf(sat, 0.0f, 1.0f),
                           glClampf(fmaxf(bri, 0.62f), 0.0f, 1.0f));
    GLColor l = glHSBToRGB(hue, glClampf(sat * p->highlightSat, 0.0f, 1.0f),
                           glClampf(0.90f + bri * 0.10f, 0.0f, 1.0f));

    if (p->invert) {
        // Light plate, dark glyph: near-white at the bottom of the ramp, the
        // user's colour still in the middle, a deep version of it on top.
        d = glHSBToRGB(hue, glClampf(sat * 0.18f, 0.0f, 1.0f),
                       glClampf(0.95f + bri * 0.05f, 0.0f, 1.0f));
        m = glHSBToRGB(hue, glClampf(sat * 0.95f, 0.0f, 1.0f),
                       glClampf(fmaxf(bri * 0.92f, 0.55f), 0.0f, 1.0f));
        l = glHSBToRGB(hue, glClampf(sat * 1.10f, 0.0f, 1.0f),
                       glClampf(0.12f + p->shadowLift * 0.22f, 0.0f, 1.0f));
    }

    if (dark) *dark = d;
    if (mid) *mid = m;
    if (light) *light = l;
}

int GLApplyTint(uint8_t *rgba, int w, int h, const GLTintParams *p, const GLStats *s) {
    if (!rgba || !p || !s || w <= 0 || h <= 0) return 0;
    if (s->opaquePixels <= 0) return 0;

    GLColor darkStop, midStop, lightStop;
    GLTintStops(p, &darkStop, &midStop, &lightStop);

    // Pre-linearise the stops once instead of per pixel.
    const float dR = GLSRGBToLinear(darkStop.r),  dG = GLSRGBToLinear(darkStop.g),  dB = GLSRGBToLinear(darkStop.b);
    const float mR = GLSRGBToLinear(midStop.r),   mG = GLSRGBToLinear(midStop.g),   mB = GLSRGBToLinear(midStop.b);
    const float lR = GLSRGBToLinear(lightStop.r), lG = GLSRGBToLinear(lightStop.g), lB = GLSRGBToLinear(lightStop.b);

    // Auto-levels window. Guard against flat artwork (a solid-colour icon has
    // p02 == p98 and would divide by zero into a hard-edged mess).
    float lo = s->lumaP02, hi = s->lumaP98;
    if (hi - lo < 0.04f) {
        float mid = 0.5f * (lo + hi);
        lo = glClampf(mid - 0.15f, 0.0f, 1.0f);
        hi = glClampf(mid + 0.15f, 0.0f, 1.0f);
    }
    float levels = glClampf(p->levels, 0.0f, 1.0f);
    float gamma = (p->gamma > 0.05f) ? p->gamma : 1.0f;
    float contrast = glClampf(p->contrast, 0.0f, 1.0f);

    size_t n = (size_t)w * (size_t)h;
    for (size_t i = 0; i < n; i++) {
        uint8_t *px = rgba + i * 4;
        float a = px[3] / 255.0f;
        if (a <= 0.003f) continue;

        float r = px[0] / 255.0f, g = px[1] / 255.0f, b = px[2] / 255.0f;
        float l = glLuma(r, g, b);

        // Normalise, then shape. `levels` blends between raw and normalised so
        // the user can dial back auto-levels on artwork it flatters badly.
        float norm = glClampf((l - lo) / (hi - lo), 0.0f, 1.0f);
        float t = glMixf(l, norm, levels);
        t = powf(glClampf(t, 0.0f, 1.0f), 1.0f / gamma);
        float sCurve = t * t * (3.0f - 2.0f * t);
        t = glMixf(t, sCurve, contrast);

        // Ramp in linear light — mixing colours in sRGB darkens the midtones.
        // Two segments through the mid stop keep the user's hue at full
        // strength across the middle of the range.
        float linR, linG, linB;
        if (t <= 0.5f) {
            float k = t * 2.0f;
            linR = glMixf(dR, mR, k);
            linG = glMixf(dG, mG, k);
            linB = glMixf(dB, mB, k);
        } else {
            float k = (t - 0.5f) * 2.0f;
            linR = glMixf(mR, lR, k);
            linG = glMixf(mG, lG, k);
            linB = glMixf(mB, lB, k);
        }

        px[0] = (uint8_t)(glClampf(GLLinearToSRGB(linR), 0.0f, 1.0f) * 255.0f + 0.5f);
        px[1] = (uint8_t)(glClampf(GLLinearToSRGB(linG), 0.0f, 1.0f) * 255.0f + 0.5f);
        px[2] = (uint8_t)(glClampf(GLLinearToSRGB(linB), 0.0f, 1.0f) * 255.0f + 0.5f);
    }
    return 1;
}

// -----------------------------------------------------------------------------
// Dark (iOS 18 parity) — keep the hue, compress the highlights
// -----------------------------------------------------------------------------

int GLApplyDark(uint8_t *rgba, int w, int h, const GLDarkParams *p) {
    if (!rgba || !p || w <= 0 || h <= 0) return 0;
    float strength = glClampf(p->strength, 0.0f, 1.0f);
    float satMul = (p->saturation > 0.0f) ? p->saturation : 1.0f;

    size_t n = (size_t)w * (size_t)h;

    // Darkening by luminance alone is wrong: the brightest pixels in a typical
    // icon are the white glyph, so a naive version dims exactly the part that
    // has to stay legible. Apple's dark icons darken the *plate* and leave the
    // artwork on top of it alone, so separate the two first.
    float *glyphM = (float *)malloc(n * sizeof(float));
    int haveMask = glyphM ? glComputeGlyphMask(rgba, w, h, glyphM) : 0;

    for (size_t i = 0; i < n; i++) {
        uint8_t *px = rgba + i * 4;
        if (px[3] == 0) continue;

        float r = px[0] / 255.0f, g = px[1] / 255.0f, b = px[2] / 255.0f;
        float l = glLuma(r, g, b);
        float detail = haveMask ? glyphM[i] : 0.0f;

        // Plate pixels take the full darkening; glyph detail is spared.
        float t = glClampf((l - 0.15f) / 0.85f, 0.0f, 1.0f);
        float roll = 0.40f + 0.60f * (t * t * (3.0f - 2.0f * t));
        float target = l * (1.0f - strength * roll * (1.0f - detail));
        float gain = (l > 0.001f) ? (target / l) : 1.0f;

        r *= gain; g *= gain; b *= gain;

        if (fabsf(satMul - 1.0f) > 0.001f) {
            float nl = glLuma(r, g, b);
            r = glMixf(nl, r, satMul);
            g = glMixf(nl, g, satMul);
            b = glMixf(nl, b, satMul);
        }

        px[0] = (uint8_t)(glClampf(r, 0.0f, 1.0f) * 255.0f + 0.5f);
        px[1] = (uint8_t)(glClampf(g, 0.0f, 1.0f) * 255.0f + 0.5f);
        px[2] = (uint8_t)(glClampf(b, 0.0f, 1.0f) * 255.0f + 0.5f);
    }
    free(glyphM);
    return 1;
}

// -----------------------------------------------------------------------------
// Clear glass (iOS 26/27 look)
//
// The important design decision: this stage does NOT sample the wallpaper. It
// leaves the plate partially transparent and bakes only the light behaviour —
// specular, rim, inner shadow, edge lensing. SpringBoard's compositor then
// shows the real wallpaper through the icon, live, as you scroll pages, for
// exactly zero per-frame cost on our side. Sampling a wallpaper crop would
// have forced a re-composite on every page change and every wallpaper change,
// and would still have been wrong the moment the user scrolled.
// -----------------------------------------------------------------------------

int GLApplyGlass(uint8_t *rgba, int w, int h, const GLGlassParams *p, const GLStats *s) {
    if (!rgba || !p || w <= 0 || h <= 0) return 0;
    (void)s;

    size_t n = (size_t)w * (size_t)h;
    float *mask   = (float *)malloc(n * sizeof(float));
    float *maskB  = (float *)malloc(n * sizeof(float));
    float *luma   = (float *)malloc(n * sizeof(float));
    float *lumaB  = (float *)malloc(n * sizeof(float));
    float *scratch = (float *)malloc(n * sizeof(float));
    uint8_t *src  = (uint8_t *)malloc(n * 4);
    if (!mask || !maskB || !luma || !lumaB || !scratch || !src) {
        free(mask); free(maskB); free(luma); free(lumaB); free(scratch); free(src);
        return 0;   // fail closed — caller keeps the un-glassed image
    }
    memcpy(src, rgba, n * 4);

    for (size_t i = 0; i < n; i++) {
        const uint8_t *px = src + i * 4;
        mask[i] = px[3] / 255.0f;
        luma[i] = glLuma(px[0] / 255.0f, px[1] / 255.0f, px[2] / 255.0f);
    }

    int edge = (w < h ? w : h);
    int shapeRadius = edge / 22; if (shapeRadius < 1) shapeRadius = 1;
    int detailRadius = edge / 12; if (detailRadius < 1) detailRadius = 1;
    glBlur(mask, maskB, w, h, shapeRadius, scratch);
    glBlur(luma, lumaB, w, h, detailRadius, scratch);

    float frost = glClampf(p->frost, 0.0f, 1.0f);
    float specularK = glClampf(p->specular, 0.0f, 1.0f);
    float rimK = glClampf(p->rim, 0.0f, 1.0f);
    float innerK = glClampf(p->innerShadow, 0.0f, 1.0f);
    float refractK = glClampf(p->refraction, 0.0f, 1.0f);
    float plateA = glClampf(p->plateAlpha, 0.0f, 1.0f);
    float glyphA = glClampf(p->glyphAlpha, 0.0f, 1.0f);
    float tintK = glClampf(p->tintAmount, 0.0f, 1.0f);

    GLColor glassBase = p->dark ? (GLColor){ 0.07f, 0.08f, 0.10f }
                                : (GLColor){ 0.93f, 0.95f, 0.98f };
    GLColor specColor = p->dark ? (GLColor){ 0.80f, 0.86f, 1.00f }
                                : (GLColor){ 1.00f, 1.00f, 1.00f };

    // Light from the top-left, the same direction Apple lights its glass.
    const float lx = -0.55f, ly = -0.62f, lz = 0.56f;
    float shadowShift = (float)edge * 0.045f;
    float maxDisplace = (float)edge * 0.055f * refractK;

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            size_t i = (size_t)y * w + x;
            float m = mask[i];
            if (m <= 0.002f) {
                uint8_t *out = rgba + i * 4;
                out[0] = out[1] = out[2] = out[3] = 0;
                continue;
            }

            // Surface normal of the blurred shape: flat in the middle, curved
            // at the edge. That curvature is what makes the rim read as glass.
            float gx = glSampleF(maskB, w, h, (float)(x + 1), (float)y) -
                       glSampleF(maskB, w, h, (float)(x - 1), (float)y);
            float gy = glSampleF(maskB, w, h, (float)x, (float)(y + 1)) -
                       glSampleF(maskB, w, h, (float)x, (float)(y - 1));
            float nx = -gx * 6.0f, ny = -gy * 6.0f, nz = 1.0f;
            float nlen = sqrtf(nx * nx + ny * ny + nz * nz);
            if (nlen > 0.0001f) { nx /= nlen; ny /= nlen; nz /= nlen; }

            // Edge lensing: displace the sample along the shape gradient and
            // split the channels slightly. Cheap, and visually it is the part
            // people actually read as "thick glass".
            float edgeStrength = sqrtf(gx * gx + gy * gy) * 6.0f;
            edgeStrength = glClampf(edgeStrength, 0.0f, 1.0f);
            float dispX = 0.0f, dispY = 0.0f;
            if (maxDisplace > 0.0f && edgeStrength > 0.001f) {
                float glen = sqrtf(gx * gx + gy * gy);
                if (glen > 0.0001f) {
                    dispX = (gx / glen) * maxDisplace * edgeStrength;
                    dispY = (gy / glen) * maxDisplace * edgeStrength;
                }
            }

            float rr, gg, bb;
            if (dispX != 0.0f || dispY != 0.0f) {
                float dr = 1.18f, db = 0.82f;   // chromatic dispersion
                int xr = (int)glClampf((float)x + dispX * dr, 0.0f, (float)(w - 1));
                int yr = (int)glClampf((float)y + dispY * dr, 0.0f, (float)(h - 1));
                int xg = (int)glClampf((float)x + dispX, 0.0f, (float)(w - 1));
                int yg = (int)glClampf((float)y + dispY, 0.0f, (float)(h - 1));
                int xb = (int)glClampf((float)x + dispX * db, 0.0f, (float)(w - 1));
                int yb = (int)glClampf((float)y + dispY * db, 0.0f, (float)(h - 1));
                rr = src[((size_t)yr * w + xr) * 4 + 0] / 255.0f;
                gg = src[((size_t)yg * w + xg) * 4 + 1] / 255.0f;
                bb = src[((size_t)yb * w + xb) * 4 + 2] / 255.0f;
            } else {
                rr = src[i * 4 + 0] / 255.0f;
                gg = src[i * 4 + 1] / 255.0f;
                bb = src[i * 4 + 2] / 255.0f;
            }

            // Local contrast marks where real glyph detail lives, as opposed to
            // the flat plate behind it. Detail keeps its colour and opacity;
            // the plate turns to glass.
            float detail = fabsf(luma[i] - lumaB[i]) * 4.0f;
            float glyphM = glClampf(detail, 0.0f, 1.0f);

            // Frost the plate toward the glass base colour.
            float f = frost * (1.0f - glyphM);
            rr = glMixf(rr, glassBase.r, f);
            gg = glMixf(gg, glassBase.g, f);
            bb = glMixf(bb, glassBase.b, f);

            if (tintK > 0.0f) {
                float tk = tintK * (1.0f - glyphM * 0.5f);
                rr = glMixf(rr, p->tint.r, tk);
                gg = glMixf(gg, p->tint.g, tk);
                bb = glMixf(bb, p->tint.b, tk);
            }

            // Inner shadow: the shape offset down-right, subtracted.
            float shifted = glSampleF(maskB, w, h, (float)x - shadowShift,
                                      (float)y - shadowShift);
            float inner = glClampf((m - shifted) * 1.6f, 0.0f, 1.0f) * innerK;
            float darken = 1.0f - inner * 0.55f;
            rr *= darken; gg *= darken; bb *= darken;

            // Specular + rim.
            float ndl = nx * lx + ny * ly + nz * lz;
            if (ndl < 0.0f) ndl = 0.0f;
            float spec = powf(ndl, 18.0f) * specularK;
            float rimBand = glClampf((m - maskB[i]) * 3.2f, 0.0f, 1.0f);
            float facing = glClampf(0.5f + 0.5f * (nx * lx + ny * ly), 0.0f, 1.0f);
            float rim = rimBand * rimK * (0.35f + 0.65f * facing);

            float light = spec + rim;
            rr += specColor.r * light;
            gg += specColor.g * light;
            bb += specColor.b * light;

            // Straight alpha out: plate goes translucent, glyph stays solid,
            // highlights stay visible over any wallpaper.
            float outA = m * glMixf(plateA, glyphA, glyphM);
            outA = glClampf(outA + light * 0.85f, 0.0f, 1.0f);

            uint8_t *out = rgba + i * 4;
            out[0] = (uint8_t)(glClampf(rr, 0.0f, 1.0f) * 255.0f + 0.5f);
            out[1] = (uint8_t)(glClampf(gg, 0.0f, 1.0f) * 255.0f + 0.5f);
            out[2] = (uint8_t)(glClampf(bb, 0.0f, 1.0f) * 255.0f + 0.5f);
            out[3] = (uint8_t)(outA * 255.0f + 0.5f);
        }
    }

    free(mask); free(maskB); free(luma); free(lumaB); free(scratch); free(src);
    return 1;
}

// -----------------------------------------------------------------------------
// Corner mask (superellipse / squircle)
// -----------------------------------------------------------------------------

int GLApplyCornerMask(uint8_t *rgba, int w, int h, float radiusFrac) {
    if (!rgba || w <= 0 || h <= 0) return 0;
    if (radiusFrac <= 0.0f) return 0;

    // iOS icon corners are a continuous curve, not a circular arc. A
    // superellipse with n ~= 5 is visually indistinguishable at icon sizes.
    const float nExp = 5.0f;
    float cx = (float)w * 0.5f, cy = (float)h * 0.5f;
    float ax = cx, ay = cy;
    float shape = glClampf(radiusFrac, 0.0f, 1.0f);

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            size_t i = (size_t)y * w + x;
            float dx = fabsf(((float)x + 0.5f - cx) / ax);
            float dy = fabsf(((float)y + 0.5f - cy) / ay);
            float d = powf(powf(dx, nExp) + powf(dy, nExp), 1.0f / nExp);

            // Blend between "square" (no mask) and the full superellipse so a
            // partial radius still means something.
            float dSquare = fmaxf(dx, dy);
            d = glMixf(dSquare, d, shape);

            // ~1px of antialiasing at the boundary.
            float aa = 2.0f / (float)w;
            float cover = glClampf((1.0f - d) / aa, 0.0f, 1.0f);
            if (cover >= 1.0f) continue;

            uint8_t *px = rgba + i * 4;
            px[3] = (uint8_t)((px[3] / 255.0f) * cover * 255.0f + 0.5f);
        }
    }
    return 1;
}

// -----------------------------------------------------------------------------
// Recipes
// -----------------------------------------------------------------------------

void GLRecipeDefaults(GLRecipe *out, GLMode mode, GLColor tint) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->mode = mode;
    out->tint = (GLTintParams){
        .tint = tint, .levels = 0.85f, .contrast = 0.35f, .gamma = 1.0f,
        .shadowLift = 0.10f, .highlightSat = 0.30f, .plateFill = 0, .invert = 0,
    };
    out->dark = (GLDarkParams){ .strength = 0.55f, .saturation = 1.05f };
    out->glass = (GLGlassParams){
        .plateAlpha = 0.22f, .glyphAlpha = 0.92f, .frost = 0.55f,
        .specular = 0.55f, .rim = 0.60f, .innerShadow = 0.45f,
        .refraction = 0.55f, .tint = tint, .tintAmount = 0.0f, .dark = 0,
    };
    out->cornerRadiusFrac = 0.0f;

    switch (mode) {
        case GLModeTintedLight:
            out->tint.invert = 1;
            out->tint.highlightSat = 0.85f;
            break;
        case GLModeClearGlassDark:
            out->glass.dark = 1;
            out->glass.frost = 0.42f;
            out->glass.plateAlpha = 0.26f;
            break;
        default:
            break;
    }
}

static void glHashFloat(uint64_t *acc, float v) {
    // Quantise before hashing: a slider that renders identically must not
    // invalidate the cache because of float noise.
    int32_t q = (int32_t)lrintf(v * 4096.0f);
    uint32_t u = (uint32_t)q;
    for (int i = 0; i < 4; i++) {
        *acc ^= (uint64_t)((u >> (i * 8)) & 0xFF);
        *acc *= 1099511628211ULL;
    }
}

static void glHashInt(uint64_t *acc, int v) {
    uint32_t u = (uint32_t)v;
    for (int i = 0; i < 4; i++) {
        *acc ^= (uint64_t)((u >> (i * 8)) & 0xFF);
        *acc *= 1099511628211ULL;
    }
}

uint64_t GLRecipeHash(const GLRecipe *r) {
    uint64_t acc = 14695981039346656037ULL;
    if (!r) return acc;

    glHashInt(&acc, (int)r->mode);

    glHashFloat(&acc, r->tint.tint.r);
    glHashFloat(&acc, r->tint.tint.g);
    glHashFloat(&acc, r->tint.tint.b);
    glHashFloat(&acc, r->tint.levels);
    glHashFloat(&acc, r->tint.contrast);
    glHashFloat(&acc, r->tint.gamma);
    glHashFloat(&acc, r->tint.shadowLift);
    glHashFloat(&acc, r->tint.highlightSat);
    glHashInt(&acc, r->tint.plateFill);
    glHashInt(&acc, r->tint.invert);

    glHashFloat(&acc, r->dark.strength);
    glHashFloat(&acc, r->dark.saturation);

    glHashFloat(&acc, r->glass.plateAlpha);
    glHashFloat(&acc, r->glass.glyphAlpha);
    glHashFloat(&acc, r->glass.frost);
    glHashFloat(&acc, r->glass.specular);
    glHashFloat(&acc, r->glass.rim);
    glHashFloat(&acc, r->glass.innerShadow);
    glHashFloat(&acc, r->glass.refraction);
    glHashFloat(&acc, r->glass.tint.r);
    glHashFloat(&acc, r->glass.tint.g);
    glHashFloat(&acc, r->glass.tint.b);
    glHashFloat(&acc, r->glass.tintAmount);
    glHashInt(&acc, r->glass.dark);

    glHashFloat(&acc, r->cornerRadiusFrac);
    return acc;
}

int GLApplyRecipe(uint8_t *rgba, int w, int h, const GLRecipe *r) {
    if (!rgba || !r || w <= 0 || h <= 0) return 0;
    if (r->mode == GLModeStock && r->cornerRadiusFrac <= 0.0f) return 0;

    GLStats stats;
    GLBitmapStats(rgba, w, h, &stats);
    if (stats.opaquePixels <= 0) return 0;

    int touched = 0;

    // Glyph-only artwork (a themed PNG with a transparent background) has no
    // plate for the ramp or the glass stage to work on, and would come out as
    // a floating shape. Coverage is the reliable test here, not corner alpha:
    // ordinary full-bleed icons are already masked to a squircle, so their
    // corners are transparent too.
    if (r->tint.plateFill && stats.alphaCoverage < 0.55f) {
        GLColor plate;
        switch (r->mode) {
            case GLModeTinted:
            case GLModeTintedLight:
                // Deliberately a dark neutral rather than one of the ramp
                // stops. The plate is about to be pushed through the tint ramp
                // like every other pixel, so what matters is where its
                // luminance lands: low, i.e. the bottom of the ramp. That comes
                // out as the dark stop normally and as the near-white stop when
                // inverted, which is what each mode wants. Seeding it with the
                // stop colour itself double-applies the ramp and inverts the
                // light variant back to dark.
                plate = (GLColor){ 0.10f, 0.10f, 0.11f };
                break;
            case GLModeDark:
                plate = (GLColor){ 0.11f, 0.11f, 0.12f };
                break;
            case GLModeClearGlass:
                plate = (GLColor){ 0.72f, 0.75f, 0.80f };
                break;
            case GLModeClearGlassDark:
                plate = (GLColor){ 0.20f, 0.22f, 0.26f };
                break;
            default:
                // Stock: no ramp will run, so darken the artwork's own dominant
                // colour enough that the glyph still reads against it.
                plate = (GLColor){ stats.dominantColor.r * 0.35f,
                                   stats.dominantColor.g * 0.35f,
                                   stats.dominantColor.b * 0.35f };
                break;
        }
        float radius = (r->cornerRadiusFrac > 0.0f) ? r->cornerRadiusFrac : 1.0f;
        touched |= GLSynthesizePlate(rgba, w, h, plate, radius);
        // The image changed shape and tone — every later stage needs the new
        // histogram, not the one from the bare glyph.
        GLBitmapStats(rgba, w, h, &stats);
    }

    switch (r->mode) {
        case GLModeTinted:
        case GLModeTintedLight:
            touched |= GLApplyTint(rgba, w, h, &r->tint, &stats);
            break;
        case GLModeDark:
            touched |= GLApplyDark(rgba, w, h, &r->dark);
            break;
        case GLModeClearGlass:
        case GLModeClearGlassDark:
            // Tinted glass runs the tint ramp first so the glyph carries the
            // user's hue, then turns the plate to glass.
            if (r->glass.tintAmount > 0.0f && r->tint.levels > 0.0f) {
                touched |= GLApplyTint(rgba, w, h, &r->tint, &stats);
            }
            touched |= GLApplyGlass(rgba, w, h, &r->glass, &stats);
            break;
        case GLModeStock:
        default:
            break;
    }

    if (r->cornerRadiusFrac > 0.0f) {
        touched |= GLApplyCornerMask(rgba, w, h, r->cornerRadiusFrac);
    }
    return touched;
}
