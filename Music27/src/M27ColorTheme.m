#import "Music27.h"

@implementation M27ColorPalette
@end

static CGFloat M27Luminance(CGFloat r, CGFloat g, CGFloat b) {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

@implementation M27ColorTheme

+ (instancetype)shared {
    static M27ColorTheme *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
    });
    return shared;
}

/// Most saturated non-black/non-white pixel in a 16×16 downsample.
/// A 1×1 average of Positions is grey-green mud; the portrait's olive and
/// the pink on A-POD both lose to a flat mean. iOS 27 keeps the colour that
/// reads as "the cover", not the average of every pixel.
- (UIColor *)_dominantColorFromImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;

    const int dim = 16;
    uint8_t pixels[16 * 16 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, dim, dim, 8, dim * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, dim, dim), cgImage);
    CGContextRelease(ctx);

    CGFloat bestScore = -1;
    CGFloat bestR = 0, bestG = 0, bestB = 0;
    for (int i = 0; i < dim * dim; i++) {
        CGFloat r = pixels[i * 4 + 0] / 255.0;
        CGFloat g = pixels[i * 4 + 1] / 255.0;
        CGFloat b = pixels[i * 4 + 2] / 255.0;
        CGFloat a = pixels[i * 4 + 3] / 255.0;
        if (a < 0.50) continue;
        CGFloat mx = MAX(r, MAX(g, b));
        CGFloat mn = MIN(r, MIN(g, b));
        if (mx < 0.08 || mx > 0.96) continue;
        CGFloat sat = (mx > 0.001) ? ((mx - mn) / mx) : 0;
        CGFloat score = sat * mx * a;
        if (score > bestScore) {
            bestScore = score;
            bestR = r;
            bestG = g;
            bestB = b;
        }
    }
    if (bestScore < 0) return nil;
    return [UIColor colorWithRed:bestR green:bestG blue:bestB alpha:1.0];
}

- (UIColor *)_pageColorFrom:(UIColor *)color {
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) return color;
    // Keep hue. Lift grey covers a little; punch real colours.
    if (s > 0.12) {
        s = MIN(1.0, MAX(0.42, s * 1.28));
    }
    // Mid-dark page, not the 0.55-darken-toward-black that made every
    // album a muddy maroon. iOS 27 stays readable and still looks like the art.
    b = MIN(0.52, MAX(0.24, b * 0.72));
    return [UIColor colorWithHue:h saturation:s brightness:b alpha:1.0];
}

- (UIColor *)_shiftBrightness:(UIColor *)color by:(CGFloat)delta {
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) return color;
    b = MIN(1.0, MAX(0.0, b + delta));
    return [UIColor colorWithHue:h saturation:s brightness:b alpha:1.0];
}

- (M27ColorPalette *)paletteFromImage:(UIImage *)image {
    if (!image) return nil;
    UIColor *dominant = [self _dominantColorFromImage:image];
    if (!dominant) return nil;

    UIColor *page = [self _pageColorFrom:dominant];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [page getRed:&r green:&g blue:&b alpha:&a];

    M27ColorPalette *palette = [M27ColorPalette new];
    palette.background = page;
    palette.backgroundSecondary = [self _shiftBrightness:page by:-0.10];
    palette.tint = dominant;
    palette.glassTint = [dominant colorWithAlphaComponent:0.35];
    palette.prefersLightContent = M27Luminance(r, g, b) < 0.6;
    palette.foreground = palette.prefersLightContent ? UIColor.whiteColor : UIColor.blackColor;
    return palette;
}

- (void)applyPalette:(M27ColorPalette *)palette animated:(BOOL)animated {
    if (self.activePalette == palette) return;
    self.activePalette = palette;
    void (^notify)(void) = ^{
        NSDictionary *info = palette ? @{ @"palette": palette } : @{};
        [NSNotificationCenter.defaultCenter postNotificationName:M27ThemeDidChangeNotification
                                                          object:nil
                                                        userInfo:info];
    };
    if (animated) {
        [UIView animateWithDuration:0.35 animations:notify completion:nil];
    } else {
        notify();
    }
}

- (void)clearThemeAnimated:(BOOL)animated {
    [self applyPalette:nil animated:animated];
}

@end
