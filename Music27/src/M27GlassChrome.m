#import "M27GlassChrome.h"
#import "Music27.h"

/// How far in from each end the top edge-light should start, so it follows the
/// capsule rather than running out over the rounded corners.
static CGFloat M27EdgeLightInset(UIVisualEffectView *glass) {
    CGFloat radius = glass.layer.cornerRadius;
    // Was radius * 0.7, back when the light stopped dead at each end and had to
    // be kept clear of the corners by geometry alone. The view tapers itself
    // now, so this only has to keep the bright middle away from the curve.
    return MAX(2.0, radius * 0.35);
}

/// The top edge light.
///
/// 1.1.48 and earlier drew this as a flat 1pt bar of white at alpha 0.55, and on
/// device that reads as exactly what it is: a grey line ruled across the top of
/// the pill. Light catching a curved glass edge does two things a ruled line
/// does not — it falls off as the surface turns away from the viewer, and it
/// dies out towards the ends where the capsule curves away. So this view is
/// backed by a vertical gradient (bright at the very top edge, gone ~3pt down)
/// and masked by a horizontal one (nothing at the ends, full through the
/// middle). Peak alpha is well under the old flat value because a gradient
/// carries much further than a hard line at the same brightness.
@interface M27EdgeLightView : UIView
@end

@implementation M27EdgeLightView

+ (Class)layerClass { return CAGradientLayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    CAGradientLayer *fall = (CAGradientLayer *)self.layer;
    fall.startPoint = CGPointMake(0.5, 0.0);
    fall.endPoint = CGPointMake(0.5, 1.0);
    fall.colors = @[
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.50].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.16].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
    ];
    fall.locations = @[@0.0, @0.45, @1.0];

    CAGradientLayer *taper = [CAGradientLayer layer];
    taper.startPoint = CGPointMake(0.0, 0.5);
    taper.endPoint = CGPointMake(1.0, 0.5);
    taper.colors = @[
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
    ];
    taper.locations = @[@0.0, @0.30, @0.70, @1.0];
    self.layer.mask = taper;

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // The mask is a plain sublayer, so it does not follow autoresizing. Frame
    // changes here arrive with an implicit animation attached; the mask must
    // track the bounds exactly or the taper drifts out of the pill mid-collapse.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.mask.frame = self.bounds;
    [CATransaction commit];
}

@end

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

    // Light catching the top edge, not a wash over half the pill and not a
    // ruled line either — see M27EdgeLightView.
    UIView *highlight = [[M27EdgeLightView alloc] initWithFrame:CGRectZero];
    highlight.tag = 0x4D324847; // 'M2HG'
    highlight.userInteractionEnabled = NO;
    highlight.backgroundColor = UIColor.clearColor;
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
        // 3pt of falloff rather than 1pt of line. Height is fixed rather than a
        // fraction of the pill, so it stays an edge on a 52pt mini pill and on a
        // 58pt tab row alike. The inset is now small — the horizontal taper
        // inside the view does the work of keeping the light off the corners,
        // and it does it by fading rather than by stopping dead.
        CGFloat inset = M27EdgeLightInset(glass);
        highlight.frame = CGRectMake(inset, 0.0, MAX(0, w - inset * 2.0), 3.0);
        // Resize the taper mask now rather than waiting for the next layout
        // pass — this is often the last thing that runs before the pill is on
        // screen, and a mask still sized to the old width is visible.
        [highlight layoutIfNeeded];
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
