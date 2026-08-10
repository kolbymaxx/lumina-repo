#import "M27GlassChrome.h"
#import "Music27.h"

/// How far in from each end the top edge-light should start, so it follows the
/// capsule rather than running out over the rounded corners.
static CGFloat M27EdgeLightInset(UIVisualEffectView *glass) {
    CGFloat radius = glass.layer.cornerRadius;
    return MAX(4.0, radius * 0.7);
}

@implementation M27GlassChrome

+ (UIVisualEffectView *)pillWithCornerRadius:(CGFloat)radius {
    // GLASS SHOULD BE SEE-THROUGH. Chrome material is not.
    //
    // The old value here was SystemChromeMaterial, chosen on the theory that it
    // "reads closer to iOS 26/27 floating glass than ultra-thin". On device it
    // does not: the pills come out flat grey, and you cannot see the artwork
    // behind them at all. In Apple's own iOS 26/27 shots the album art is
    // clearly legible through the pill — that is the whole effect.
    //
    // Three things were stacking opacity: chrome material, a white tint on the
    // content view, and a highlight block covering the top 45% at alpha 0.28.
    // Ultra-thin is the most transparent material UIKit offers, and the other
    // two are pulled right back below.
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.clipsToBounds = YES;
    glass.userInteractionEnabled = YES;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [self applySpecularBorderToView:glass];

    // A thin bright line along the top edge, not a wash over half the pill.
    // Liquid Glass reads as light catching an edge; a 45%-height block just
    // reads as milk.
    UIView *highlight = [[UIView alloc] initWithFrame:CGRectZero];
    highlight.tag = 0x4D324847; // 'M2HG'
    highlight.userInteractionEnabled = NO;
    highlight.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    highlight.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [glass.contentView insertSubview:highlight atIndex:0];

    return glass;
}

+ (void)applySpecularBorderToView:(UIView *)view {
    // Hairline. 0.7pt at 0.42 white drew a visible outline rather than an edge.
    view.layer.borderWidth = 0.5;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
}

+ (void)applyPaletteTintToGlass:(UIVisualEffectView *)glass {
    if (![glass isKindOfClass:UIVisualEffectView.class]) return;
    M27ColorPalette *palette = M27ColorTheme.shared.activePalette;
    if (palette.glassTint) {
        // 0.22 buried the artwork behind a colour wash; the tint should read as
        // a hint of the album's colour in the glass, not as a coloured panel.
        glass.contentView.backgroundColor = [palette.glassTint colorWithAlphaComponent:0.10];
    } else {
        BOOL dark = NO;
        if (@available(iOS 13.0, *)) {
            dark = glass.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
        // Barely there. Ultra-thin material already carries the frost; anything
        // meaningful here just paints over the artwork we want showing through.
        glass.contentView.backgroundColor = dark
            ? [UIColor colorWithWhite:1.0 alpha:0.04]
            : [UIColor colorWithWhite:1.0 alpha:0.06];
    }

    UIView *highlight = [glass.contentView viewWithTag:0x4D324847];
    if (highlight) {
        CGFloat w = glass.bounds.size.width;
        // A 1pt edge line inset from the corners, not a block. Height is fixed
        // rather than a fraction of the pill, so it stays an edge on a 52pt mini
        // pill and on a 58pt tab row alike.
        CGFloat inset = M27EdgeLightInset(glass);
        highlight.frame = CGRectMake(inset, 0.5, MAX(0, w - inset * 2.0), 1.0);
        highlight.layer.cornerRadius = 0.5;
        if (@available(iOS 13.0, *)) {
            highlight.layer.cornerCurve = kCACornerCurveContinuous;
            highlight.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        }
        highlight.clipsToBounds = YES;
    }
}

+ (void)addSoftShadowToHost:(UIView *)host {
    host.layer.shadowColor = [UIColor blackColor].CGColor;
    // Slightly stronger on light canvases so floating pills read above Library art.
    BOOL dark = NO;
    if (@available(iOS 13.0, *)) {
        dark = host.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    host.layer.shadowOpacity = dark ? 0.32 : 0.22;
    host.layer.shadowRadius = 24.0;
    host.layer.shadowOffset = CGSizeMake(0, 10);
    host.layer.masksToBounds = NO;
}

@end
