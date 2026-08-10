// glyph-preview — host-side smoke test + contact sheet for Glyph's composite
// kernels.
//
// Glyph's colour maths lives in pure C (Glyph/src/GLPixelKit.c) precisely so it
// can be exercised here, on a Linux box, instead of being seen for the first
// time on a device that can Safe Mode. This tool synthesises the three icon
// shapes that matter (full-bleed artwork, glyph-on-plate, flat solid), runs
// every Glyph mode over them, composites the results over a wallpaper-ish
// gradient so translucency is actually visible, and writes a PNG contact sheet.
//
//   cc -O2 -o tools/glyph-preview tools/glyph-preview.c Glyph/src/GLPixelKit.c -lm
//   ./tools/glyph-preview /tmp/glyph-sheet.png
//
// Exit status is non-zero if any kernel reports failure or produces a buffer
// that is empty / fully transparent, so it doubles as a regression check.

#include "../Glyph/src/GLPixelKit.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// -----------------------------------------------------------------------------
// Minimal PNG writer (stored-deflate; no zlib dependency)
// -----------------------------------------------------------------------------

static uint32_t crcTable[256];
static int crcReady = 0;

static void crcInit(void) {
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crcTable[n] = c;
    }
    crcReady = 1;
}

static uint32_t crc32buf(const uint8_t *buf, size_t len, uint32_t crc) {
    if (!crcReady) crcInit();
    crc = crc ^ 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) crc = crcTable[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}

static void writeChunk(FILE *f, const char *type, const uint8_t *data, size_t len) {
    uint8_t hdr[8];
    put32(hdr, (uint32_t)len);
    memcpy(hdr + 4, type, 4);
    fwrite(hdr, 1, 8, f);
    if (len) fwrite(data, 1, len, f);

    uint32_t crc = crc32buf((const uint8_t *)type, 4, 0);
    if (len) crc = crc32buf(data, len, crc);
    uint8_t crcb[4];
    put32(crcb, crc);
    fwrite(crcb, 1, 4, f);
}

static int writePNG(const char *path, const uint8_t *rgba, int w, int h) {
    FILE *f = fopen(path, "wb");
    if (!f) return 0;

    static const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    fwrite(sig, 1, 8, f);

    uint8_t ihdr[13];
    put32(ihdr, (uint32_t)w);
    put32(ihdr + 4, (uint32_t)h);
    ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    writeChunk(f, "IHDR", ihdr, sizeof(ihdr));

    // Raw scanlines with filter byte 0.
    size_t rawLen = (size_t)h * (1 + (size_t)w * 4);
    uint8_t *raw = (uint8_t *)malloc(rawLen);
    if (!raw) { fclose(f); return 0; }
    for (int y = 0; y < h; y++) {
        uint8_t *dst = raw + (size_t)y * (1 + (size_t)w * 4);
        dst[0] = 0;
        memcpy(dst + 1, rgba + (size_t)y * w * 4, (size_t)w * 4);
    }

    // zlib stream with stored deflate blocks.
    size_t blocks = (rawLen + 65534) / 65535;
    size_t zLen = 2 + blocks * 5 + rawLen + 4;
    uint8_t *z = (uint8_t *)malloc(zLen);
    if (!z) { free(raw); fclose(f); return 0; }

    size_t zi = 0;
    z[zi++] = 0x78; z[zi++] = 0x01;
    size_t off = 0;
    while (off < rawLen) {
        size_t chunk = rawLen - off;
        if (chunk > 65535) chunk = 65535;
        int final = (off + chunk >= rawLen) ? 1 : 0;
        z[zi++] = (uint8_t)final;
        z[zi++] = (uint8_t)(chunk & 0xFF);
        z[zi++] = (uint8_t)((chunk >> 8) & 0xFF);
        z[zi++] = (uint8_t)(~chunk & 0xFF);
        z[zi++] = (uint8_t)((~chunk >> 8) & 0xFF);
        memcpy(z + zi, raw + off, chunk);
        zi += chunk;
        off += chunk;
    }
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < rawLen; i++) {
        a = (a + raw[i]) % 65521;
        b = (b + a) % 65521;
    }
    put32(z + zi, (b << 16) | a);
    zi += 4;

    writeChunk(f, "IDAT", z, zi);
    writeChunk(f, "IEND", NULL, 0);

    free(z);
    free(raw);
    fclose(f);
    return 1;
}

// -----------------------------------------------------------------------------
// Synthetic icons
// -----------------------------------------------------------------------------

static float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

static void setPx(uint8_t *buf, int w, int x, int y, float r, float g, float b, float a) {
    uint8_t *p = buf + ((size_t)y * w + x) * 4;
    p[0] = (uint8_t)(clamp01(r) * 255.0f + 0.5f);
    p[1] = (uint8_t)(clamp01(g) * 255.0f + 0.5f);
    p[2] = (uint8_t)(clamp01(b) * 255.0f + 0.5f);
    p[3] = (uint8_t)(clamp01(a) * 255.0f + 0.5f);
}

/// Coverage of a rounded-square icon shape at (x, y), antialiased.
static float squircleCover(int x, int y, int size) {
    float cx = size * 0.5f, cy = size * 0.5f;
    float dx = fabsf((x + 0.5f - cx) / cx);
    float dy = fabsf((y + 0.5f - cy) / cy);
    float d = powf(powf(dx, 5.0f) + powf(dy, 5.0f), 1.0f / 5.0f);
    return clamp01((1.0f - d) / (2.0f / size));
}

/// A rounded "A"-ish glyph: a chunky ring plus a bar. Enough structure for the
/// local-contrast detector to have something to find.
static float glyphCover(int x, int y, int size) {
    float cx = size * 0.5f, cy = size * 0.5f;
    float fx = (x + 0.5f - cx) / (size * 0.5f);
    float fy = (y + 0.5f - cy) / (size * 0.5f);
    float r = sqrtf(fx * fx + fy * fy);
    float ring = clamp01((0.55f - fabsf(r - 0.42f) * 6.0f));
    float bar = (fabsf(fy) < 0.09f && fabsf(fx) < 0.30f) ? 1.0f : 0.0f;
    return clamp01(fmaxf(ring, bar));
}

typedef enum { kFullBleed = 0, kGlyphOnly = 1, kFlatSolid = 2 } IconKind;

static void makeIcon(uint8_t *buf, int size, IconKind kind) {
    memset(buf, 0, (size_t)size * size * 4);
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            float shape = squircleCover(x, y, size);
            float gl = glyphCover(x, y, size);
            float t = (float)y / (float)(size - 1);

            switch (kind) {
                case kFullBleed: {
                    // Diagonal orange→magenta artwork with a white glyph.
                    float r = 0.98f - 0.20f * t, g = 0.42f + 0.10f * t, b = 0.15f + 0.55f * t;
                    r = r * (1.0f - gl) + 1.0f * gl;
                    g = g * (1.0f - gl) + 1.0f * gl;
                    b = b * (1.0f - gl) + 1.0f * gl;
                    setPx(buf, size, x, y, r, g, b, shape);
                    break;
                }
                case kGlyphOnly: {
                    // No plate at all — corner alpha near zero.
                    setPx(buf, size, x, y, 0.15f, 0.55f, 0.95f, gl);
                    break;
                }
                case kFlatSolid: {
                    // Flat plate, dark glyph. Exercises the degenerate
                    // auto-levels window (p02 ~= p98).
                    float base = 0.20f;
                    float r = base * (1.0f - gl) + 0.92f * gl;
                    float g = 0.62f * (1.0f - gl) + 0.92f * gl;
                    float b = 0.35f * (1.0f - gl) + 0.92f * gl;
                    setPx(buf, size, x, y, r, g, b, shape);
                    break;
                }
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Contact sheet
// -----------------------------------------------------------------------------

/// Wallpaper stand-in: a saturated gradient with a couple of bright blobs, so
/// translucent glass has something worth showing through.
static void wallpaperPixel(int x, int y, int w, int h, float *r, float *g, float *b) {
    float u = (float)x / (float)w, v = (float)y / (float)h;
    *r = 0.10f + 0.35f * v;
    *g = 0.06f + 0.16f * u;
    *b = 0.22f + 0.55f * (1.0f - v);
    float dx = u - 0.28f, dy = v - 0.22f;
    float blob = expf(-(dx * dx + dy * dy) * 26.0f);
    *r += blob * 0.55f; *g += blob * 0.30f; *b += blob * 0.10f;
    dx = u - 0.74f; dy = v - 0.68f;
    blob = expf(-(dx * dx + dy * dy) * 34.0f);
    *r += blob * 0.10f; *g += blob * 0.45f; *b += blob * 0.40f;
    *r = clamp01(*r); *g = clamp01(*g); *b = clamp01(*b);
}

static void blitOver(uint8_t *sheet, int sw, int sx, int sy,
                     const uint8_t *icon, int size) {
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            const uint8_t *s = icon + ((size_t)y * size + x) * 4;
            float a = s[3] / 255.0f;
            if (a <= 0.0f) continue;
            uint8_t *d = sheet + ((size_t)(sy + y) * sw + (sx + x)) * 4;
            for (int c = 0; c < 3; c++) {
                float src = s[c] / 255.0f;
                float dst = d[c] / 255.0f;
                d[c] = (uint8_t)(clamp01(src * a + dst * (1.0f - a)) * 255.0f + 0.5f);
            }
            d[3] = 255;
        }
    }
}

typedef struct {
    const char *name;
    GLMode mode;
    int tintedGlass;
} ModeSpec;

int main(int argc, char **argv) {
    const char *outPath = (argc > 1) ? argv[1] : "/tmp/glyph-sheet.png";
    const int size = 120;
    const int pad = 16;

    ModeSpec modes[] = {
        { "stock",       GLModeStock,          0 },
        { "tinted",      GLModeTinted,         0 },
        { "tintedLight", GLModeTintedLight,    0 },
        { "dark",        GLModeDark,           0 },
        { "glass",       GLModeClearGlass,     0 },
        { "glassDark",   GLModeClearGlassDark, 0 },
        { "glassTinted", GLModeClearGlass,     1 },
    };
    const int modeCount = (int)(sizeof(modes) / sizeof(modes[0]));
    const int kinds = 3;

    int sheetW = pad + modeCount * (size + pad);
    int sheetH = pad + kinds * (size + pad);
    uint8_t *sheet = (uint8_t *)malloc((size_t)sheetW * sheetH * 4);
    uint8_t *icon = (uint8_t *)malloc((size_t)size * size * 4);
    uint8_t *work = (uint8_t *)malloc((size_t)size * size * 4);
    if (!sheet || !icon || !work) {
        fprintf(stderr, "glyph-preview: out of memory\n");
        return 2;
    }

    for (int y = 0; y < sheetH; y++) {
        for (int x = 0; x < sheetW; x++) {
            float r, g, b;
            wallpaperPixel(x, y, sheetW, sheetH, &r, &g, &b);
            setPx(sheet, sheetW, x, y, r, g, b, 1.0f);
        }
    }

    // Tint colour for the sheet: a Lumina-ish pink/magenta.
    GLColor tint = GLColorFromHex(0xFF5FB2);
    int failures = 0;

    for (int k = 0; k < kinds; k++) {
        for (int m = 0; m < modeCount; m++) {
            makeIcon(icon, size, (IconKind)k);
            memcpy(work, icon, (size_t)size * size * 4);

            GLRecipe recipe;
            GLRecipeDefaults(&recipe, modes[m].mode, tint);
            recipe.tint.plateFill = (k == kGlyphOnly) ? 1 : 0;
            if (modes[m].tintedGlass) {
                recipe.glass.tintAmount = 0.35f;
                recipe.glass.tint = tint;
            }

            int touched = GLApplyRecipe(work, size, size, &recipe);
            if (modes[m].mode != GLModeStock && !touched) {
                fprintf(stderr, "FAIL: %s on kind %d reported no change\n",
                        modes[m].name, k);
                failures++;
            }

            // Sanity: the result must not be blank.
            long alphaSum = 0;
            for (int i = 0; i < size * size; i++) alphaSum += work[i * 4 + 3];
            if (alphaSum == 0) {
                fprintf(stderr, "FAIL: %s on kind %d produced a fully "
                                "transparent icon\n", modes[m].name, k);
                failures++;
            }

            GLStats st;
            GLBitmapStats(work, size, size, &st);
            printf("%-12s kind=%d  cornerA=%.2f  plate=%.2f  p02=%.2f p50=%.2f "
                   "p98=%.2f  cover=%.2f\n",
                   modes[m].name, k, st.cornerAlpha, st.plateRatio,
                   st.lumaP02, st.lumaP50, st.lumaP98, st.alphaCoverage);

            int sx = pad + m * (size + pad);
            int sy = pad + k * (size + pad);
            blitOver(sheet, sheetW, sx, sy, work, size);
        }
    }

    if (!writePNG(outPath, sheet, sheetW, sheetH)) {
        fprintf(stderr, "glyph-preview: failed to write %s\n", outPath);
        return 2;
    }
    printf("\nwrote %s (%dx%d)\n", outPath, sheetW, sheetH);
    printf("columns: stock tinted tintedLight dark glass glassDark glassTinted\n");
    printf("rows:    full-bleed, glyph-only, flat-solid\n");

    free(sheet); free(icon); free(work);
    if (failures) {
        fprintf(stderr, "\n%d kernel check(s) failed\n", failures);
        return 1;
    }
    return 0;
}
