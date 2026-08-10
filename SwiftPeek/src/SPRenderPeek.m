#import "SPRenderPeek.h"
#import <objc/runtime.h>

// -----------------------------------------------------------------------------
// SwiftPeek M3 — image statistics + structural view peek (read-only)
// -----------------------------------------------------------------------------

static const size_t kSPSampleEdge = 64;   // images are downsampled to 64x64
static const size_t kSPHistBuckets = 8;

static inline double SPLuma(double r, double g, double b) {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

static double SPPercentile(const double *sorted, size_t count, double p) {
    if (count == 0) return 0.0;
    double idx = p * (double)(count - 1);
    size_t lo = (size_t)floor(idx);
    size_t hi = (size_t)ceil(idx);
    if (hi >= count) hi = count - 1;
    double frac = idx - (double)lo;
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

static int SPCompareDouble(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static NSString *SPHex(double r, double g, double b) {
    int ri = (int)lround(fmin(fmax(r, 0.0), 1.0) * 255.0);
    int gi = (int)lround(fmin(fmax(g, 0.0), 1.0) * 255.0);
    int bi = (int)lround(fmin(fmax(b, 0.0), 1.0) * 255.0);
    return [NSString stringWithFormat:@"#%02x%02x%02x", ri, gi, bi];
}

NSDictionary *SPRenderSignatureForRGBA(const uint8_t *rgba, size_t width,
                                       size_t height, CGFloat scale) {
    if (!rgba || width == 0 || height == 0) return nil;

    size_t total = width * height;
    double *lumas = (double *)calloc(total, sizeof(double));
    double *lumaField = (double *)calloc(total, sizeof(double)); // 0 where transparent
    if (!lumas || !lumaField) {
        free(lumas);
        free(lumaField);
        return nil;
    }

    // 5-bit-per-channel histogram for the dominant-colour pass. 32^3 buckets
    // is small enough to sit on the stack-adjacent heap and coarse enough that
    // an anti-aliased plate still collapses into one bucket.
    static const int kQuant = 32;
    uint32_t *cube = (uint32_t *)calloc(kQuant * kQuant * kQuant, sizeof(uint32_t));
    if (!cube) {
        free(lumas);
        free(lumaField);
        return nil;
    }

    double sumR = 0, sumG = 0, sumB = 0, sumSat = 0, sumAlpha = 0;
    size_t opaque = 0;

    for (size_t i = 0; i < total; i++) {
        const uint8_t *px = rgba + i * 4;
        double a = px[3] / 255.0;
        sumAlpha += a;
        if (a <= 0.004) {
            lumaField[i] = 0.0;
            continue;
        }
        // Buffer is premultiplied — undo it before looking at colour.
        double r = fmin((px[0] / 255.0) / a, 1.0);
        double g = fmin((px[1] / 255.0) / a, 1.0);
        double b = fmin((px[2] / 255.0) / a, 1.0);
        double l = SPLuma(r, g, b);
        lumaField[i] = l;

        if (a > 0.5) {
            lumas[opaque++] = l;
            sumR += r; sumG += g; sumB += b;
            double mx = fmax(r, fmax(g, b));
            double mn = fmin(r, fmin(g, b));
            sumSat += (mx <= 0.0001) ? 0.0 : ((mx - mn) / mx);

            int qr = (int)(r * (kQuant - 1));
            int qg = (int)(g * (kQuant - 1));
            int qb = (int)(b * (kQuant - 1));
            cube[(qr * kQuant + qg) * kQuant + qb]++;
        }
    }

    if (opaque == 0) {
        free(lumas);
        free(lumaField);
        free(cube);
        return @{
            @"width": @((double)width),
            @"height": @((double)height),
            @"scale": @((double)scale),
            @"alpha_coverage": @0.0,
            @"opaque_pixels": @0,
            @"empty": @YES,
        };
    }

    // Dominant quantised colour + how much of the icon sits in that bucket.
    uint32_t bestCount = 0;
    int bestIdx = 0;
    for (int i = 0; i < kQuant * kQuant * kQuant; i++) {
        if (cube[i] > bestCount) { bestCount = cube[i]; bestIdx = i; }
    }
    double domB = (double)(bestIdx % kQuant) / (kQuant - 1);
    double domG = (double)((bestIdx / kQuant) % kQuant) / (kQuant - 1);
    double domR = (double)(bestIdx / (kQuant * kQuant)) / (kQuant - 1);
    double plateRatio = (double)bestCount / (double)opaque;
    free(cube);

    // Luminance percentiles drive the auto-levels stage of a tint pipeline.
    qsort(lumas, opaque, sizeof(double), SPCompareDouble);
    double p02 = SPPercentile(lumas, opaque, 0.02);
    double p50 = SPPercentile(lumas, opaque, 0.50);
    double p98 = SPPercentile(lumas, opaque, 0.98);

    double hist[kSPHistBuckets];
    memset(hist, 0, sizeof(hist));
    for (size_t i = 0; i < opaque; i++) {
        size_t bucket = (size_t)(lumas[i] * (double)(kSPHistBuckets - 1) + 0.5);
        if (bucket >= kSPHistBuckets) bucket = kSPHistBuckets - 1;
        hist[bucket] += 1.0;
    }
    NSMutableArray *histOut = [NSMutableArray arrayWithCapacity:kSPHistBuckets];
    for (size_t i = 0; i < kSPHistBuckets; i++) {
        [histOut addObject:@(hist[i] / (double)opaque)];
    }

    // Sobel-ish gradient magnitude: how much structure the artwork carries.
    double edgeSum = 0;
    size_t edgeCount = 0;
    for (size_t y = 1; y + 1 < height; y++) {
        for (size_t x = 1; x + 1 < width; x++) {
            size_t i = y * width + x;
            if (rgba[i * 4 + 3] <= 128) continue;
            double gx = lumaField[i + 1] - lumaField[i - 1];
            double gy = lumaField[i + width] - lumaField[i - width];
            edgeSum += sqrt(gx * gx + gy * gy);
            edgeCount++;
        }
    }

    // Corner alpha: full-bleed app artwork is opaque into all four corners,
    // a free-standing glyph is not. This is the single most useful bit when
    // deciding whether an icon needs a synthesised plate.
    size_t block = width < 16 ? 2 : width / 16;
    if (block < 1) block = 1;
    double cornerSum = 0;
    size_t cornerCount = 0;
    for (size_t cy = 0; cy < 2; cy++) {
        for (size_t cx = 0; cx < 2; cx++) {
            for (size_t y = 0; y < block; y++) {
                for (size_t x = 0; x < block; x++) {
                    size_t px = cx ? (width - 1 - x) : x;
                    size_t py = cy ? (height - 1 - y) : y;
                    cornerSum += rgba[(py * width + px) * 4 + 3] / 255.0;
                    cornerCount++;
                }
            }
        }
    }

    NSDictionary *out = @{
        @"width": @((double)width),
        @"height": @((double)height),
        @"scale": @((double)scale),
        @"opaque_pixels": @((double)opaque),
        @"alpha_coverage": @(sumAlpha / (double)total),
        @"corner_alpha": @(cornerCount ? cornerSum / (double)cornerCount : 0.0),
        @"mean_hex": SPHex(sumR / opaque, sumG / opaque, sumB / opaque),
        @"dominant_hex": SPHex(domR, domG, domB),
        @"plate_ratio": @(plateRatio),
        @"luma_p02": @(p02),
        @"luma_p50": @(p50),
        @"luma_p98": @(p98),
        @"luma_hist": histOut,
        @"saturation_mean": @(sumSat / (double)opaque),
        @"edge_density": @(edgeCount ? edgeSum / (double)edgeCount : 0.0),
    };

    free(lumas);
    free(lumaField);
    return out;
}

NSDictionary *SPRenderSignatureForImage(UIImage *image) {
    if (!image) return nil;
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;

    size_t edge = kSPSampleEdge;
    size_t bytesPerRow = edge * 4;
    uint8_t *buffer = (uint8_t *)calloc(edge * bytesPerRow, 1);
    if (!buffer) return nil;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buffer, edge, edge, 8, bytesPerRow, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) {
        free(buffer);
        return nil;
    }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, edge, edge), cg);
    CGContextRelease(ctx);

    NSMutableDictionary *sig = [SPRenderSignatureForRGBA(buffer, edge, edge, image.scale) mutableCopy];
    free(buffer);
    if (!sig) return nil;

    // Report the *source* dimensions alongside the sampled ones.
    sig[@"width"] = @(image.size.width);
    sig[@"height"] = @(image.size.height);
    sig[@"sample_edge"] = @((double)edge);
    return sig;
}

// -----------------------------------------------------------------------------
// Structural peek
// -----------------------------------------------------------------------------

static NSDictionary *SPNodeForView(UIView *view, NSInteger depth) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"objc_class"] = NSStringFromClass(object_getClass(view)) ?: @"?";
    node[@"depth"] = @(depth);
    node[@"address"] = [NSString stringWithFormat:@"0x%lx",
                        (unsigned long)(uintptr_t)(__bridge void *)view];
    CGRect f = view.frame;
    node[@"frame"] = @[ @(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height) ];
    node[@"alpha"] = @(view.alpha);
    node[@"hidden"] = @(view.isHidden);
    node[@"opaque"] = @(view.isOpaque);
    node[@"clips"] = @(view.clipsToBounds);
    node[@"subviews"] = @(view.subviews.count);

    CALayer *layer = view.layer;
    if (layer) {
        if (layer.cornerRadius > 0) node[@"corner_radius"] = @(layer.cornerRadius);
        if (layer.masksToBounds) node[@"masks_to_bounds"] = @YES;
        if (layer.borderWidth > 0) node[@"border_width"] = @(layer.borderWidth);
        if (layer.shadowOpacity > 0) node[@"shadow_opacity"] = @(layer.shadowOpacity);
        node[@"contents_scale"] = @(layer.contentsScale);
        if (layer.sublayers.count) node[@"sublayers"] = @(layer.sublayers.count);
    }

    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)view;
        UIImage *img = iv.image;
        node[@"content_mode"] = @(iv.contentMode);
        if (img) {
            node[@"image_size"] = @[ @(img.size.width), @(img.size.height) ];
            node[@"image_scale"] = @(img.scale);
            node[@"image_rendering_mode"] = @(img.renderingMode);
        } else {
            node[@"image"] = @"nil";
        }
    }

    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffect *effect = [(UIVisualEffectView *)view effect];
        node[@"visual_effect"] = effect ? (NSStringFromClass(object_getClass(effect)) ?: @"?") : @"nil";
    }

    return node;
}

NSArray<NSDictionary *> *SPRenderPeekViewTree(UIView *root, NSInteger maxNodes,
                                              NSInteger maxDepth) {
    if (!root) return @[];
    if (maxNodes <= 0) maxNodes = 200;
    if (maxDepth < 0) maxDepth = 0;

    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];

    @try {
        while (queue.count > 0 && (NSInteger)out.count < maxNodes) {
            UIView *view = queue.firstObject;
            NSInteger depth = [depths.firstObject integerValue];
            [queue removeObjectAtIndex:0];
            [depths removeObjectAtIndex:0];
            if (![view isKindOfClass:[UIView class]]) continue;

            [out addObject:SPNodeForView(view, depth)];
            if (depth >= maxDepth) continue;
            for (UIView *child in view.subviews) {
                [queue addObject:child];
                [depths addObject:@(depth + 1)];
            }
        }
    } @catch (__unused id e) {
        // Fail closed — a partial tree is still useful, a crash never is.
    }
    return out;
}
