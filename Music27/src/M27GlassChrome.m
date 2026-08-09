#import "M27GlassChrome.h"
#import "Music27.h"

@implementation M27GlassChrome

+ (UIVisualEffectView *)pillWithCornerRadius:(CGFloat)radius {
    // Chrome material reads closer to iOS 26/27 floating glass than ultra-thin.
    UIBlurEffectStyle style = UIBlurEffectStyleSystemChromeMaterial;
    if (@available(iOS 15.0, *)) {
        style = UIBlurEffectStyleSystemChromeMaterial;
    }
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:style];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.clipsToBounds = YES;
    glass.userInteractionEnabled = YES;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [self applySpecularBorderToView:glass];

    // Soft top specular highlight — reads like Liquid Glass edge light.
    UIView *highlight = [[UIView alloc] initWithFrame:CGRectZero];
    highlight.tag = 0x4D324847; // 'M2HG'
    highlight.userInteractionEnabled = NO;
    highlight.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    highlight.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [glass.contentView insertSubview:highlight atIndex:0];

    return glass;
}

+ (void)applySpecularBorderToView:(UIView *)view {
    view.layer.borderWidth = 0.7;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
}

+ (void)applyPaletteTintToGlass:(UIVisualEffectView *)glass {
    if (![glass isKindOfClass:UIVisualEffectView.class]) return;
    M27ColorPalette *palette = M27ColorTheme.shared.activePalette;
    if (palette.glassTint) {
        glass.contentView.backgroundColor = [palette.glassTint colorWithAlphaComponent:0.22];
    } else {
        BOOL dark = NO;
        if (@available(iOS 13.0, *)) {
            dark = glass.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
        glass.contentView.backgroundColor = dark
            ? [UIColor colorWithWhite:1.0 alpha:0.10]
            : [UIColor colorWithWhite:1.0 alpha:0.16];
    }

    UIView *highlight = [glass.contentView viewWithTag:0x4D324847];
    if (highlight) {
        CGFloat w = glass.bounds.size.width;
        CGFloat h = glass.bounds.size.height;
        highlight.frame = CGRectMake(1.0, 1.0, MAX(0, w - 2.0), MAX(1.0, h * 0.45));
        highlight.layer.cornerRadius = MAX(0, glass.layer.cornerRadius - 1.0);
        if (@available(iOS 13.0, *)) {
            highlight.layer.cornerCurve = kCACornerCurveContinuous;
            highlight.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        }
        highlight.clipsToBounds = YES;
    }
}

+ (void)addSoftShadowToHost:(UIView *)host {
    host.layer.shadowColor = [UIColor blackColor].CGColor;
    host.layer.shadowOpacity = 0.28;
    host.layer.shadowRadius = 22.0;
    host.layer.shadowOffset = CGSizeMake(0, 8);
    host.layer.masksToBounds = NO;
}

@end
