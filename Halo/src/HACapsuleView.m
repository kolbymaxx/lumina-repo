#import "Halo.h"

// -----------------------------------------------------------------------------
// Halo — the capsule
//
// Compact state sits as two small pills flanking the notch, inside the status
// bar strip. Expanded state is a glass panel that drops below the notch and
// visually merges with it: the panel's top corners are square where they meet
// the notch and rounded everywhere else, which is what sells the illusion that
// the cutout itself grew.
// -----------------------------------------------------------------------------

static const CGFloat kHACompactPillHeight = 24.0;
static const CGFloat kHACompactPillWidth  = 62.0;
static const CGFloat kHAExpandedHeight    = 84.0;
static const CGFloat kHAExpandedInset     = 12.0;
static const CGFloat kHAExpandedRadius    = 30.0;

@interface HACapsuleView ()
@property (nonatomic, assign) HANotchMetrics metrics;
@property (nonatomic, assign) HACapsuleState state;
@property (nonatomic, strong) UIVisualEffectView *backdrop;
@property (nonatomic, strong) UIView *tintOverlay;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressFill;
@end

@implementation HACapsuleView

- (instancetype)initWithMetrics:(HANotchMetrics)metrics {
    if ((self = [super initWithFrame:CGRectZero])) {
        _metrics = metrics;
        _state = HACapsuleStateHidden;

        self.clipsToBounds = YES;
        self.layer.cornerRadius = kHAExpandedRadius;
        if (@available(iOS 13.0, *)) {
            self.layer.cornerCurve = kCACornerCurveContinuous;
        }
        self.backgroundColor = UIColor.clearColor;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        _backdrop = [[UIVisualEffectView alloc] initWithEffect:blur];
        _backdrop.userInteractionEnabled = NO;
        [self addSubview:_backdrop];

        // A near-black wash under the blur so the capsule reads as an
        // extension of the notch rather than a floating panel.
        _tintOverlay = [UIView new];
        _tintOverlay.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.82];
        _tintOverlay.userInteractionEnabled = NO;
        [self addSubview:_tintOverlay];

        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = 7.0;
        [self addSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_titleLabel];

        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_subtitleLabel];

        _progressTrack = [UIView new];
        _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        _progressTrack.layer.cornerRadius = 1.5;
        _progressTrack.hidden = YES;
        [self addSubview:_progressTrack];

        _progressFill = [UIView new];
        _progressFill.backgroundColor = UIColor.whiteColor;
        _progressFill.layer.cornerRadius = 1.5;
        [_progressTrack addSubview:_progressFill];
    }
    return self;
}

#pragma mark - Layout

- (CGRect)frameForState:(HACapsuleState)state {
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    CGFloat notchW = self.metrics.notchWidth;
    CGFloat notchH = self.metrics.notchHeight;

    switch (state) {
        case HACapsuleStateHidden: {
            // Collapsed to nothing, centred on the notch, so the spring
            // animation grows out of the cutout.
            return CGRectMake((screenW - notchW) / 2.0, 0, notchW, notchH);
        }
        case HACapsuleStateCompact: {
            // Spans the notch plus a pill on each side.
            CGFloat width = notchW + (kHACompactPillWidth * 2.0) + 16.0;
            width = MIN(width, screenW - 16.0);
            return CGRectMake((screenW - width) / 2.0, 0, width, notchH);
        }
        case HACapsuleStateExpanded: {
            CGFloat width = screenW - (kHAExpandedInset * 2.0);
            return CGRectMake(kHAExpandedInset, 0, width, notchH + kHAExpandedHeight);
        }
    }
    return CGRectZero;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.backdrop.frame = b;
    self.tintOverlay.frame = b;

    CGFloat notchW = self.metrics.notchWidth;
    CGFloat notchH = self.metrics.notchHeight;

    if (self.state == HACapsuleStateExpanded) {
        CGFloat pad = 16.0;
        CGFloat contentTop = notchH + 8.0;
        CGFloat iconSize = 40.0;
        self.iconView.frame = CGRectMake(pad, contentTop, iconSize, iconSize);

        CGFloat textX = pad + iconSize + 12.0;
        CGFloat textW = MAX(b.size.width - textX - pad, 10.0);
        self.titleLabel.frame = CGRectMake(textX, contentTop + 2.0, textW, 18.0);
        self.subtitleLabel.frame = CGRectMake(textX, contentTop + 22.0, textW, 16.0);

        CGFloat trackY = contentTop + iconSize + 12.0;
        self.progressTrack.frame = CGRectMake(pad, trackY, b.size.width - pad * 2.0, 3.0);
    } else {
        // Compact: icon left of the notch, text right of it. The notch itself
        // is dead space — nothing may be laid out under it.
        CGFloat sideWidth = MAX((b.size.width - notchW) / 2.0, 0.0);
        CGFloat inset = 10.0;
        CGFloat pillH = MIN(kHACompactPillHeight, notchH);
        CGFloat y = (notchH - pillH) / 2.0;

        CGFloat iconSize = MIN(pillH, 20.0);
        self.iconView.frame = CGRectMake(inset, y + (pillH - iconSize) / 2.0, iconSize, iconSize);

        CGFloat rightX = b.size.width - sideWidth + inset - 6.0;
        CGFloat rightW = MAX(sideWidth - inset * 2.0 + 6.0, 10.0);
        self.titleLabel.frame = CGRectMake(rightX, y, rightW, pillH);
        self.subtitleLabel.frame = CGRectZero;
        self.progressTrack.frame = CGRectZero;
    }

    CGRect track = self.progressTrack.bounds;
    CGFloat p = self.activity ? MAX(MIN(self.activity.progress, 1.0), 0.0) : 0.0;
    self.progressFill.frame = CGRectMake(0, 0, track.size.width * p, track.size.height);
}

#pragma mark - Content

- (void)applyActivity:(HAActivity *)activity state:(HACapsuleState)state animated:(BOOL)animated {
    self.activity = activity;
    self.state = state;

    self.iconView.image = activity.leadingImage;
    self.iconView.hidden = (activity.leadingImage == nil);
    self.titleLabel.text = activity.title ?: @"";

    BOOL expanded = (state == HACapsuleStateExpanded);
    self.subtitleLabel.text = activity.subtitle ?: @"";
    self.subtitleLabel.hidden = !expanded || activity.subtitle.length == 0;
    self.titleLabel.font = [UIFont systemFontOfSize:expanded ? 15 : 12
                                             weight:UIFontWeightSemibold];
    self.titleLabel.textAlignment = expanded ? NSTextAlignmentLeft : NSTextAlignmentRight;

    BOOL showProgress = expanded && activity.progress >= 0.0;
    self.progressTrack.hidden = !showProgress;
    if (activity.accentColor) {
        self.progressFill.backgroundColor = activity.accentColor;
        self.titleLabel.textColor = UIColor.whiteColor;
    }

    CGRect target = [self frameForState:state];
    CGFloat radius = (state == HACapsuleStateExpanded)
        ? kHAExpandedRadius
        : MIN(self.metrics.notchHeight / 2.0, target.size.height / 2.0);

    void (^apply)(void) = ^{
        self.frame = target;
        self.layer.cornerRadius = radius;
        self.alpha = (state == HACapsuleStateHidden) ? 0.0 : 1.0;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    };

    if (!animated) {
        apply();
        return;
    }
    [UIView animateWithDuration:0.42
                          delay:0.0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionBeginFromCurrentState
                     animations:apply
                     completion:nil];
}

@end
