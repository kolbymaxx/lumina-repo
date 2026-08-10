#import "GLRecipeBuilder.h"
#import "GLPrefs.h"

// -----------------------------------------------------------------------------
// Glyph Phase D — preferences → composite recipe
// -----------------------------------------------------------------------------

static GLRecipe gGLRecipe;
static uint64_t gGLRecipeHash = 0;
static BOOL gGLRecipeValid = NO;
static BOOL gGLCompositingActive = NO;
static NSSet<NSString *> *gGLExcluded = nil;
static NSDictionary *gGLPerApp = nil;

GLColor GLColorFromPrefString(NSString *hex, GLColor fallback) {
    if (![hex isKindOfClass:[NSString class]]) return fallback;

    NSString *s = [hex stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    else if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) s = [s substringFromIndex:2];

    // Accept RGB shorthand as well as RRGGBB; ignore any alpha the user pasted.
    if (s.length == 3) {
        unichar c[3];
        [s getCharacters:c range:NSMakeRange(0, 3)];
        s = [NSString stringWithFormat:@"%C%C%C%C%C%C", c[0], c[0], c[1], c[1], c[2], c[2]];
    }
    if (s.length == 8) s = [s substringToIndex:6];
    if (s.length != 6) return fallback;

    NSScanner *scanner = [NSScanner scannerWithString:s];
    unsigned long long value = 0;
    if (![scanner scanHexLongLong:&value]) return fallback;
    if (!scanner.isAtEnd) return fallback;

    return GLColorFromHex((uint32_t)(value & 0xFFFFFFu));
}

static float GLPrefFloatClamped(NSString *key, float fallback, float lo, float hi) {
    double v = GLPrefDouble(key, fallback);
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return (float)v;
}

static GLMode GLModeFromPrefs(void) {
    NSInteger raw = GLPrefInteger(@"iconMode", GLModeStock);
    if (raw < GLModeStock || raw > GLModeClearGlassDark) return GLModeStock;
    return (GLMode)raw;
}

static void GLBuildRecipeIfNeeded(void) {
    if (gGLRecipeValid) return;

    GLColor tint = GLColorFromPrefString(GLPrefString(@"tintColor"),
                                         GLColorFromHex(0xFF5FB2));
    GLMode mode = GLModeFromPrefs();
    GLRecipeDefaults(&gGLRecipe, mode, tint);

    gGLRecipe.tint.levels       = GLPrefFloatClamped(@"tintLevels", 0.85f, 0.0f, 1.0f);
    gGLRecipe.tint.contrast     = GLPrefFloatClamped(@"tintContrast", 0.35f, 0.0f, 1.0f);
    gGLRecipe.tint.gamma        = GLPrefFloatClamped(@"tintGamma", 1.0f, 0.4f, 2.5f);
    gGLRecipe.tint.shadowLift   = GLPrefFloatClamped(@"tintShadowLift", 0.10f, 0.0f, 1.0f);
    gGLRecipe.tint.highlightSat = GLPrefFloatClamped(@"tintHighlightSat",
                                                     mode == GLModeTintedLight ? 0.85f : 0.30f,
                                                     0.0f, 1.0f);
    gGLRecipe.tint.plateFill    = GLPrefBool(@"plateFill", YES) ? 1 : 0;

    gGLRecipe.dark.strength   = GLPrefFloatClamped(@"darkStrength", 0.55f, 0.0f, 1.0f);
    gGLRecipe.dark.saturation = GLPrefFloatClamped(@"darkSaturation", 1.05f, 0.0f, 2.0f);

    gGLRecipe.glass.plateAlpha  = GLPrefFloatClamped(@"glassPlateAlpha",
                                                     mode == GLModeClearGlassDark ? 0.26f : 0.22f,
                                                     0.0f, 1.0f);
    gGLRecipe.glass.glyphAlpha  = GLPrefFloatClamped(@"glassGlyphAlpha", 0.92f, 0.0f, 1.0f);
    gGLRecipe.glass.frost       = GLPrefFloatClamped(@"glassFrost",
                                                     mode == GLModeClearGlassDark ? 0.42f : 0.55f,
                                                     0.0f, 1.0f);
    gGLRecipe.glass.specular    = GLPrefFloatClamped(@"glassSpecular", 0.55f, 0.0f, 1.0f);
    gGLRecipe.glass.rim         = GLPrefFloatClamped(@"glassRim", 0.60f, 0.0f, 1.0f);
    gGLRecipe.glass.innerShadow = GLPrefFloatClamped(@"glassInnerShadow", 0.45f, 0.0f, 1.0f);
    gGLRecipe.glass.refraction  = GLPrefFloatClamped(@"glassRefraction", 0.55f, 0.0f, 1.0f);
    gGLRecipe.glass.tintAmount  = GLPrefFloatClamped(@"glassTintAmount", 0.0f, 0.0f, 1.0f);
    gGLRecipe.glass.tint        = tint;

    gGLRecipe.cornerRadiusFrac = GLPrefFloatClamped(@"cornerRadius", 0.0f, 0.0f, 1.0f);

    gGLRecipeHash = GLRecipeHash(&gGLRecipe);
    gGLCompositingActive = (mode != GLModeStock) || (gGLRecipe.cornerRadiusFrac > 0.0f);

    NSArray *excluded = GLPrefArray(@"excludedApps");
    NSMutableSet *set = [NSMutableSet set];
    for (id entry in excluded ?: @[]) {
        if ([entry isKindOfClass:[NSString class]] && [entry length]) [set addObject:entry];
    }
    gGLExcluded = [set copy];

    // Optional per-app overrides: { "com.foo.bar": { "mode": 4, "tint": "#33aaff" } }
    id perApp = GLPrefs()[@"perApp"];
    gGLPerApp = [perApp isKindOfClass:[NSDictionary class]] ? [perApp copy] : nil;

    gGLRecipeValid = YES;
}

/// Read one float from a per-app override dictionary, clamped, leaving the
/// slot untouched when the key is absent or the wrong type.
static void GLOverrideFloat(NSDictionary *dict, NSString *key, float *slot,
                            float lo, float hi) {
    id v = dict[key];
    if (![v isKindOfClass:[NSNumber class]]) return;
    float f = [v floatValue];
    if (f < lo) f = lo;
    if (f > hi) f = hi;
    *slot = f;
}

/// Apply a `perApp` entry on top of the global recipe.
///
/// The key set matches what `swiftpeek tint-plan` emits, so an analysed
/// inventory dump can be pasted straight into the prefs plist: an icon the
/// analyser flagged as glyph-only gets `plateFill`, one with a degenerate
/// histogram gets its auto-levels dialled back, and so on.
static void GLApplyPerAppOverride(GLRecipe *out, NSDictionary *dict) {
    if (!out || ![dict isKindOfClass:[NSDictionary class]]) return;

    GLColor tint = out->tint.tint;
    id tintVal = dict[@"tint"];
    if ([tintVal isKindOfClass:[NSString class]]) {
        tint = GLColorFromPrefString(tintVal, tint);
    }

    id modeVal = dict[@"mode"];
    if ([modeVal isKindOfClass:[NSNumber class]]) {
        NSInteger raw = [modeVal integerValue];
        if (raw >= GLModeStock && raw <= GLModeClearGlassDark) {
            // Re-seed from that mode's tuned defaults rather than inheriting
            // the global mode's parameters, then re-apply the global choices
            // that are not mode-specific.
            float corner = out->cornerRadiusFrac;
            int plateFill = out->tint.plateFill;
            GLRecipeDefaults(out, (GLMode)raw, tint);
            out->cornerRadiusFrac = corner;
            out->tint.plateFill = plateFill;
        }
    }

    out->tint.tint = tint;
    out->glass.tint = tint;

    id plateFill = dict[@"plateFill"];
    if ([plateFill isKindOfClass:[NSNumber class]]) {
        out->tint.plateFill = [plateFill boolValue] ? 1 : 0;
    }

    GLOverrideFloat(dict, @"tintLevels",      &out->tint.levels,       0.0f, 1.0f);
    GLOverrideFloat(dict, @"tintContrast",    &out->tint.contrast,     0.0f, 1.0f);
    GLOverrideFloat(dict, @"tintGamma",       &out->tint.gamma,        0.4f, 2.5f);
    GLOverrideFloat(dict, @"tintShadowLift",  &out->tint.shadowLift,   0.0f, 1.0f);
    GLOverrideFloat(dict, @"darkStrength",    &out->dark.strength,     0.0f, 1.0f);
    GLOverrideFloat(dict, @"glassPlateAlpha", &out->glass.plateAlpha,  0.0f, 1.0f);
    GLOverrideFloat(dict, @"glassFrost",      &out->glass.frost,       0.0f, 1.0f);
    GLOverrideFloat(dict, @"glassTintAmount", &out->glass.tintAmount,  0.0f, 1.0f);
    GLOverrideFloat(dict, @"cornerRadius",    &out->cornerRadiusFrac,  0.0f, 1.0f);
}

BOOL GLRecipeForBundleID(NSString *bundleID, GLRecipe *out) {
    if (!out) return NO;
    GLBuildRecipeIfNeeded();

    if (bundleID.length && [gGLExcluded containsObject:bundleID]) return NO;

    *out = gGLRecipe;

    if (bundleID.length && gGLPerApp) {
        id entry = gGLPerApp[bundleID];
        if ([entry isKindOfClass:[NSDictionary class]]) {
            GLApplyPerAppOverride(out, (NSDictionary *)entry);
        }
    }

    return (out->mode != GLModeStock) || (out->cornerRadiusFrac > 0.0f);
}

uint64_t GLCurrentRecipeHash(void) {
    GLBuildRecipeIfNeeded();
    return gGLRecipeHash;
}

BOOL GLRecipeCompositingActive(void) {
    GLBuildRecipeIfNeeded();
    return gGLCompositingActive;
}

void GLRecipeBuilderInvalidate(void) {
    gGLRecipeValid = NO;
    gGLExcluded = nil;
    gGLPerApp = nil;
}
