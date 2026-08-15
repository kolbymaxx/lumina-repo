#import "Music27.h"
#import "M27GlassChrome.h"
#import <objc/runtime.h>

// Restyles album / playlist detail Play|Shuffle into the iOS 27 row:
//   [ Shuffle circle ]  [ Play pill ]  [ Download circle ]

static const NSInteger kM27AlbumControlsTag = 0x4D324143; // 'M2AC'
static const CGFloat kM27Circle = 52.0;
static const CGFloat kM27PlayHeight = 52.0;

/// Optical size every glyph in this row is normalised to.
///
/// "The download one is much smaller than the shuffle button we created."
/// It was, and the two could not have matched by construction: shuffle was an
/// SF Symbol at a chosen point size, while download was a photograph of Apple's
/// control — an arrow drawn small inside a 28pt canvas, scaled by whatever
/// margin Apple left around it. Two unrelated sizing rules cannot agree.
///
/// So neither one picks its own size now. Both are trimmed to their glyph's
/// actual bounding box and redrawn to this box, which is the only way a
/// rendered symbol and a captured one can be made to match.
static const CGFloat kM27GlyphBox = 22.0;

// Defined further down, next to the mirroring they share. Declared here because
// the controls view is built above them.
static UIImage *M27NormalizedGlyph(UIImage *source, BOOL dark);
static UIImage *M27SymbolGlyph(NSString *name, BOOL dark);

static BOOL M27IsAlbumDetailController(UIViewController *vc) {
    if (!vc) return NO;
    if (M27IsProtectedMusicHost(vc)) return NO;
    if ([vc isKindOfClass:UITabBarController.class] ||
        [vc isKindOfClass:UINavigationController.class] ||
        [vc isKindOfClass:UISplitViewController.class]) {
        return NO;
    }
    // SwiftPeek: MusicApplication.AlbumDetailViewController only.
    // Do not match AlbumDetailSongsViewController or broad "album" tokens.
    return M27ClassNameHasSuffix(vc, @"AlbumDetailViewController")
        || M27ClassNameHasSuffix(vc, @"PlaylistDetailViewController");
}

static UIView *M27FindControlWithTitle(UIView *root, NSArray<NSString *> *titles, BOOL exact, NSInteger depth) {
    if (!root || depth > 8) return nil;
    NSString *label = nil;
    if ([root isKindOfClass:UIButton.class]) {
        label = ((UIButton *)root).currentTitle ?: ((UIButton *)root).titleLabel.text;
        if (!label.length) {
            // Accessibility label often survives SwiftUI hosting.
            label = root.accessibilityLabel;
        }
    } else if ([root isKindOfClass:UILabel.class]) {
        label = ((UILabel *)root).text;
    } else if (root.accessibilityLabel.length) {
        label = root.accessibilityLabel;
    } else if ([root respondsToSelector:@selector(text)]) {
        @try { label = [root valueForKey:@"text"]; } @catch (__unused NSException *ex) {}
    }
    if (label.length) {
        NSString *lower = [[label lowercaseString]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        for (NSString *title in titles) {
            BOOL match = exact ? [lower isEqualToString:title] : [lower containsString:title];
            if (match) {
                // Prefer the tappable ancestor.
                UIView *cursor = root;
                while (cursor && cursor != root.window) {
                    if ([cursor isKindOfClass:UIControl.class]) return cursor;
                    if (cursor.gestureRecognizers.count > 0) return cursor;
                    cursor = cursor.superview;
                }
                return root;
            }
        }
    }
    NSInteger count = MIN((NSInteger)root.subviews.count, 50);
    for (NSInteger i = 0; i < count; i++) {
        UIView *hit = M27FindControlWithTitle(root.subviews[i], titles, exact, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

/// Search for a control that reads like "download" via accessibility, which
/// survives SwiftUI rendering better than title text does.
static UIView *M27FindDownloadByAccessibility(UIView *root, NSInteger depth) {
    if (!root || depth > 6) return nil;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:UIControl.class]) {
            NSString *label = (sub.accessibilityLabel ?: @"").lowercaseString;
            NSString *ident = (sub.accessibilityIdentifier ?: @"").lowercaseString;
            for (NSString *needle in @[ @"download", @"add to library", @"cloud", @"arrow.down" ]) {
                if ([label containsString:needle] || [ident containsString:needle]) return sub;
            }
        }
        UIView *hit = M27FindDownloadByAccessibility(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

/// The navigation bar's download button — a *different control* from the one in
/// the header, and the source of the flash.
///
/// 1.1.53's `album_nav` finally named the three right-hand items:
///
///   More       | MusicCoreUI.SymbolButton {28x28} | alpha 1.0
///   -          | UIView {0x1}                     | spacer
///   Download   | MusicCoreUI.SymbolButton {28x28} | alpha 0.0
///
/// Both downloads are 28x28 `MusicCoreUI.SymbolButton`s, which is exactly why
/// they have been indistinguishable in every log until now. They are not the
/// same view: this one is in the nav bar and exists the instant the page is
/// pushed; the header's is built asynchronously a beat later.
static UIView *M27BarItemView(UIBarButtonItem *item) {
    UIView *view = item.customView;
    if (view) return view;
    @try { return [item valueForKey:@"view"]; } @catch (__unused NSException *ex) {}
    return nil;
}

static UIBarButtonItem *M27NavDownloadItem(UIViewController *vc) {
    for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems ?: @[]) {
        UIView *view = M27BarItemView(item);
        NSString *label = (item.accessibilityLabel ?: (view.accessibilityLabel ?: @"")).lowercaseString;
        // "Download" and "Downloaded" both start this way; "More" does not.
        if ([label hasPrefix:@"download"]) return item;
    }
    return nil;
}

static UIView *M27NavDownloadControl(UIViewController *vc) {
    return M27BarItemView(M27NavDownloadItem(vc));
}

/// THERE IS ONLY ONE DOWNLOAD CONTROL, AND IT IS IN THE NAVIGATION BAR.
///
/// 1.1.54 was built on the opposite belief — that the nav bar and the header
/// each had one — and scoped this function to `vc.view` to keep them apart. The
/// log answered in one line: **`download=nil` on all 192 samples**, while
/// `nav_download` resolved every time. There is no download button inside the
/// album page on 17.3. Scoping this to `vc.view` did not separate two controls,
/// it discarded the only one, which is why the glass button stopped doing
/// anything.
///
/// It also means the "regression" reported in 1.1.54 was not one. 1.1.53's
/// label match did change which control this returned, but it changed it from
/// *nothing found yet* to *the real one*, and the drop in `download=nil` counts
/// was the fix showing up, not a fault.
///
/// The page is still searched first — a playlist or a future firmware may put a
/// control there — and the nav bar is the fallback rather than the exclusion.
static UIView *M27FindDownloadControl(UIViewController *vc) {
    UIView *byTitle = M27FindControlWithTitle(vc.view, @[ @"download" ], NO, 0);
    if (byTitle) return byTitle;
    UIView *byAccessibility = M27FindDownloadByAccessibility(vc.view, 0);
    if (byAccessibility) return byAccessibility;
    return M27NavDownloadControl(vc);
}

/// Compact description for status.log — class plus frame. Defined below.
static NSString *M27DescribeControl(UIView *view);

static const void *kM27NavDownloadKey = &kM27NavDownloadKey;

/// Cover the nav bar's download button for exactly as long as the flash lasts.
///
/// THE FLASH IS A GATE, NOT A DELAY. Look at the order in
/// `M27InstallAlbumControls`: play and shuffle are looked up first, and if
/// either is missing it returns immediately — *before* it ever reaches the
/// download control. Music builds the header asynchronously, so on every album
/// open there is a window where play and shuffle do not exist yet and therefore
/// nothing at all has been hidden. The nav bar, meanwhile, is up and painted
/// from the first frame. That window is the red button at the top, and no
/// amount of making the retry faster removes it — 1.1.52 cut the header gap
/// from 1.2s to 0.3s and the flash survived, which is the evidence for this.
///
/// So this runs before the gate, at `viewWillAppear`, and does not depend on
/// anything the header has to build.
///
/// IT IS RESTORED ON THE WAY OUT, AND ONLY THEN. 1.1.54 also restored it as
/// soon as the glass row installed, on the theory that the nav button was a
/// second control worth keeping for the scrolled state. It is not a second
/// control — it is *the* control (see `M27FindDownloadControl`), so ours mirrors
/// and fires it, and putting it back while our row is on screen just returns
/// the duplicate that was being complained about. iOS 27 shows only "•••" up
/// there, which is the look this is aiming at anyway.
///
/// RETRIED, NOT ONE-SHOT. At `viewWillAppear` the bar item usually has no view
/// yet — 191 of 192 samples read `nav_download_opacity=1` after 1.1.54 tried
/// exactly once — so this is called from every install pass, including the
/// 50ms retry, and returns early once it owns the view.
static void M27SetNavDownloadHidden(UIViewController *vc, BOOL hidden) {
    if (!vc) return;
    UIView *tracked = objc_getAssociatedObject(vc, kM27NavDownloadKey);

    if (hidden) {
        UIView *nav = M27NavDownloadControl(vc);
        if (!nav) return;                  // item has no view yet — retry next pass
        if (tracked == nav) return;        // already ours
        // Music swaps this item as the state moves Download → Downloading →
        // Downloaded. Tracking only the first one would leave the replacement
        // visible and the old one hidden forever, so hand the previous view
        // back before taking the new one.
        if (tracked) tracked.layer.opacity = 1.0;
        nav.layer.opacity = 0.0;
        // RETAIN, not ASSIGN. Music can replace a bar button item at any time,
        // and an unretained association would then be a dangling pointer we
        // later message to restore — the same species of raw-pointer hazard
        // that the 1.1.44 crash came from. Holding the view costs one
        // retain and is released on restore or with the controller.
        objc_setAssociatedObject(vc, kM27NavDownloadKey, nav,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Restore only what we hid. If Music has since replaced the item, the
    // tracked view is simply orphaned and setting its opacity affects nothing.
    if (!tracked) return;
    tracked.layer.opacity = 1.0;
    objc_setAssociatedObject(vc, kM27NavDownloadKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void M27FireControl(UIView *control) {
    if (!control) {
        M27WriteStatus(@"album_fire_nil", @{});
        return;
    }
    M27WriteStatus(@"album_fire", @{ @"target": M27DescribeControl(control) });
    if ([control isKindOfClass:UIControl.class]) {
        [(UIControl *)control sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }
    for (UIGestureRecognizer *gr in control.gestureRecognizers) {
        if (![gr isKindOfClass:UITapGestureRecognizer.class] || !gr.enabled) continue;
        @try {
            NSArray *targets = [gr valueForKey:@"targets"];
            for (id token in targets) {
                id tgt = [token valueForKey:@"target"];
                NSString *actionName = [[token valueForKey:@"action"] description];
                SEL sel = actionName.length ? NSSelectorFromString(actionName) : NULL;
                if (tgt && sel && [tgt respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [tgt performSelector:sel withObject:gr];
#pragma clang diagnostic pop
                }
            }
        } @catch (__unused NSException *ex) {}
        return;
    }
    // Climb for a UIControl parent.
    UIView *cursor = control.superview;
    while (cursor) {
        if ([cursor isKindOfClass:UIControl.class]) {
            [(UIControl *)cursor sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
        cursor = cursor.superview;
    }
}

@interface M27AlbumControlsView : UIView
@property (nonatomic, strong) UIVisualEffectView *shuffleGlass;
@property (nonatomic, strong) UIVisualEffectView *playGlass;
@property (nonatomic, strong) UIVisualEffectView *downloadGlass;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, weak) UIView *stockPlay;
@property (nonatomic, weak) UIView *stockShuffle;
@property (nonatomic, weak) UIView *stockDownload;
/// Set when the download control came from the nav bar, which on 17.3 is
/// always. A bar button item's action is public API and is what actually
/// starts the download — the item's *view* is a MusicCoreUI.SymbolButton, not a
/// UIControl, so sending it touch events does nothing.
@property (nonatomic, weak) UIBarButtonItem *stockDownloadItem;
@property (nonatomic, strong) NSTimer *mirrorTimer;
@property (nonatomic, copy) NSString *lastDownloadLabel;
@property (nonatomic, assign) BOOL downloadMirrored;
- (BOOL)mirrorDownloadState;
- (void)m27ApplyStaticGlyphs;
@end

@implementation M27AlbumControlsView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;

        _shuffleGlass = [M27GlassChrome pillWithCornerRadius:kM27Circle / 2.0];
        _downloadGlass = [M27GlassChrome pillWithCornerRadius:kM27Circle / 2.0];
        _playGlass = [M27GlassChrome pillWithCornerRadius:kM27PlayHeight / 2.0];
        [self addSubview:_shuffleGlass];
        [self addSubview:_playGlass];
        [self addSubview:_downloadGlass];

        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];

        _shuffleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _shuffleButton.tintColor = UIColor.labelColor;
        [_shuffleButton addTarget:self action:@selector(shuffleTapped)
                 forControlEvents:UIControlEventTouchUpInside];
        [_shuffleGlass.contentView addSubview:_shuffleButton];

        _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_playButton setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:cfg]
                     forState:UIControlStateNormal];
        [_playButton setTitle:@"  Play" forState:UIControlStateNormal];
        _playButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _playButton.tintColor = UIColor.labelColor;
        [_playButton setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        _playButton.backgroundColor = [UIColor labelColor];
        // Invert: white text on black pill / black text on white pill via labelColor bg.
        // Use a solid contrasting fill approximating iOS 27's prominent Play.
        BOOL dark = NO;
        if (@available(iOS 13.0, *)) {
            dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
        if (dark) {
            _playButton.backgroundColor = UIColor.whiteColor;
            _playButton.tintColor = UIColor.blackColor;
            [_playButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
        } else {
            _playButton.backgroundColor = UIColor.blackColor;
            _playButton.tintColor = UIColor.whiteColor;
            [_playButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        }
        _playButton.layer.cornerRadius = kM27PlayHeight / 2.0;
        if (@available(iOS 13.0, *)) {
            _playButton.layer.cornerCurve = kCACornerCurveContinuous;
        }
        [_playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
        [_playGlass.contentView addSubview:_playButton];

        _downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _downloadButton.tintColor = UIColor.labelColor;
        [_downloadButton addTarget:self action:@selector(downloadTapped)
                  forControlEvents:UIControlEventTouchUpInside];
        [_downloadGlass.contentView addSubview:_downloadButton];

        [self m27ApplyStaticGlyphs];
    }
    return self;
}

/// Shuffle, and the download glyph before the mirror has anything to show.
///
/// Both go through the same normaliser the mirror uses, which is the point: the
/// placeholder arrow and the mirrored arrow come out at the same box size and
/// the same weight, so the handover between them has nothing left to show. It
/// was visible before because they were sized by two unrelated rules.
- (void)m27ApplyStaticGlyphs {
    BOOL dark = NO;
    if (@available(iOS 13.0, *)) {
        dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    UIImage *shuffle = M27SymbolGlyph(@"shuffle", dark);
    if (shuffle) {
        [self.shuffleButton setImage:[shuffle imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                            forState:UIControlStateNormal];
    }
    // Only until the first mirror tick — after that the stock control's own
    // glyph is the truth, in whatever state it is in.
    if (!self.downloadMirrored) {
        UIImage *arrow = M27SymbolGlyph(@"arrow.down", dark);
        if (arrow) {
            [self.downloadButton setImage:[arrow imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                                 forState:UIControlStateNormal];
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat gap = 12.0;
    CGFloat side = kM27Circle;
    CGFloat playW = MAX(120.0, w - side * 2.0 - gap * 2.0);

    self.shuffleGlass.frame = CGRectMake(0, (h - side) / 2.0, side, side);
    self.downloadGlass.frame = CGRectMake(w - side, (h - side) / 2.0, side, side);
    self.playGlass.frame = CGRectMake(side + gap, (h - kM27PlayHeight) / 2.0, playW, kM27PlayHeight);

    self.shuffleButton.frame = self.shuffleGlass.contentView.bounds;
    self.downloadButton.frame = self.downloadGlass.contentView.bounds;
    self.playButton.frame = self.playGlass.contentView.bounds;

    [M27GlassChrome applyPaletteTintToGlass:self.shuffleGlass];
    [M27GlassChrome applyPaletteTintToGlass:self.downloadGlass];
    // Play uses solid fill; keep glass subtle underneath.
    self.playGlass.contentView.backgroundColor = UIColor.clearColor;
    self.playGlass.effect = nil;
    self.playGlass.backgroundColor = UIColor.clearColor;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    BOOL dark = NO;
    if (@available(iOS 13.0, *)) {
        dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    if (dark) {
        self.playButton.backgroundColor = UIColor.whiteColor;
        self.playButton.tintColor = UIColor.blackColor;
        [self.playButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    } else {
        self.playButton.backgroundColor = UIColor.blackColor;
        self.playButton.tintColor = UIColor.whiteColor;
        [self.playButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    }
    // The glyphs are baked images now, not tinted templates, so a light/dark
    // switch has to redraw them. The mirrored one comes back on the next tick.
    [self m27ApplyStaticGlyphs];
}

- (void)shuffleTapped { M27FireControl(self.stockShuffle); }
- (void)playTapped { M27FireControl(self.stockPlay); }
- (void)downloadTapped {
    // Prefer the bar button item's own target/action. Both are public
    // properties, so this is an ordinary message send rather than the
    // gesture-recogniser archaeology that M27FireControl falls back to — and it
    // is the only thing that works here, because the item's view is a
    // MusicCoreUI.SymbolButton and not a UIControl.
    UIBarButtonItem *item = self.stockDownloadItem;
    if (item.target && item.action && [item.target respondsToSelector:item.action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [item.target performSelector:item.action withObject:item];
#pragma clang diagnostic pop
        M27WriteStatus(@"album_download_tap", @{
            @"via": @"baritem",
            @"action": NSStringFromSelector(item.action),
        });
        return;
    }
    M27WriteStatus(@"album_download_tap", @{
        @"via": @"control",
        @"item": item ? @"yes" : @"no",
        @"stock": M27DescribeControl(self.stockDownload),
    });
    M27FireControl(self.stockDownload);
}

#pragma mark - Download state

/// Draw the stock control into an image, whatever it happens to be made of.
///
/// 1.1.38 tried to find a UIImage on the stock control and mirror it, and
/// `album_download_glyph` logged exactly zero times: MusicCoreUI.SymbolButton is
/// not a UIButton and keeps no UIImageView — it draws its symbol itself. There
/// is no image to borrow.
///
/// So render its layer instead. That captures whatever Music is showing right
/// now, including the red progress ring mid-download, in every language, for
/// states Apple has not shipped yet.
///
/// The control is hidden with `layer.opacity = 0`, and renderInContext: honours
/// that, so opacity is lifted for the draw and restored immediately. Nothing
/// paints between the two, so there is no flash.
static UIImage *M27SnapshotStockGlyph(UIView *stock) {
    if (!stock) return nil;
    CGRect bounds = stock.bounds;
    if (bounds.size.width < 4.0 || bounds.size.height < 4.0) return nil;

    float savedOpacity = stock.layer.opacity;
    stock.layer.opacity = 1.0;
    UIImage *shot = nil;
    @try {
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithBounds:bounds];
        shot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [stock.layer renderInContext:ctx.CGContext];
        }];
    } @catch (__unused NSException *ex) {
    } @finally {
        stock.layer.opacity = savedOpacity;
    }
    return shot;
}

/// Strip the colour out of a mirrored glyph, keeping its shape and its shading.
///
/// "Our new black and white download logo appears for a second and then
/// disappears, then it just does the original red one." Both halves of that are
/// exactly right: the button starts as our own `arrow.down` in `labelColor`, and
/// the first mirror tick replaces it with a photograph of Apple's red control.
///
/// The obvious fix — draw our own ring and animate it — means inventing a state
/// machine (idle / downloading / done) and a progress source, and every
/// language-independent signal for those is a guess. The mirror already knows
/// all of it, correctly, in every language, including states Apple has not
/// shipped yet. What is wrong with it is only the colour.
///
/// So: convert to luminance and keep alpha. Red ring becomes mid grey, the pale
/// unfilled track stays pale, the glyph keeps its shape, and the progress
/// animation survives intact because this runs on every frame the mirror takes.
/// In dark mode the luminance is inverted so the glyph reads light on dark.
///
/// A template image would be simpler and wrong: templates use alpha only, so the
/// ring's unfilled track — opaque grey, alpha 1 — would flood to solid black and
/// the progress would become invisible at every percentage.
///
/// 1.1.51 adds the other two halves of "make them match".
///
/// **Contrast is stretched, not just desaturated.** A straight luminance map
/// left Apple's mid-grey arrow as mid grey next to our solid-black shuffle, so
/// they read as different weights. The opaque pixels' own min and max luminance
/// are measured and remapped, which drives the darkest part of the glyph to full
/// `labelColor` and holds the lightest at a visible grey. A single-colour glyph —
/// the plain arrow, the finished tick — has no spread, so it lands flat at
/// `labelColor` and matches shuffle exactly; a progress ring does have spread,
/// so its dark arc and pale track stay distinguishable.
///
/// **Size is normalised.** The glyph is trimmed to its real bounding box and
/// redrawn to `kM27GlyphBox`, so a captured 28pt canvas with unknown margins and
/// a rendered SF Symbol end up the same optical size.
static UIImage *M27NormalizedGlyph(UIImage *source, BOOL dark) {
    if (!source) return nil;
    CGImageRef cg = source.CGImage;
    if (!cg) return source;

    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    if (w == 0 || h == 0 || w > 512 || h > 512) return source;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return source;
    size_t stride = w * 4;
    uint8_t *pixels = calloc(h, stride);
    if (!pixels) {
        CGColorSpaceRelease(space);
        return source;
    }

    UIImage *result = source;
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, stride, space,
                                             kCGImageAlphaPremultipliedLast |
                                             kCGBitmapByteOrder32Big);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);

        // Pass 1: the glyph's real extent, and its luminance range. Only pixels
        // solid enough to be glyph rather than antialiasing count towards the
        // range, or one faint edge pixel sets the black point for everything.
        size_t minX = w, minY = h, maxX = 0, maxY = 0;
        float minLuma = 255.0f, maxLuma = 0.0f;
        BOOL any = NO;
        for (size_t y = 0; y < h; y++) {
            for (size_t x = 0; x < w; x++) {
                size_t i = y * stride + x * 4;
                uint8_t a = pixels[i + 3];
                if (a < 8) continue;
                any = YES;
                if (x < minX) minX = x;
                if (y < minY) minY = y;
                if (x > maxX) maxX = x;
                if (y > maxY) maxY = y;
                if (a < 200) continue;
                float inv = 255.0f / (float)a;
                float luma = 0.2126f * (float)pixels[i + 0] * inv +
                             0.7152f * (float)pixels[i + 1] * inv +
                             0.0722f * (float)pixels[i + 2] * inv;
                if (luma > 255.0f) luma = 255.0f;
                if (luma < minLuma) minLuma = luma;
                if (luma > maxLuma) maxLuma = luma;
            }
        }

        // Below this spread the glyph is one colour and should come out flat at
        // labelColor; above it there is a ring and a track to keep apart.
        float span = maxLuma - minLuma;
        BOOL stretch = (span >= 40.0f);
        // The light end stops short of white so a progress track stays visible
        // against the glass rather than dissolving into it.
        const float kLightEnd = 165.0f;

        for (size_t i = 0; i < h * stride; i += 4) {
            uint8_t a = pixels[i + 3];
            if (a == 0) continue;
            float t = 0.0f;
            if (stretch) {
                float inv = 255.0f / (float)a;
                float luma = 0.2126f * (float)pixels[i + 0] * inv +
                             0.7152f * (float)pixels[i + 1] * inv +
                             0.0722f * (float)pixels[i + 2] * inv;
                t = (luma - minLuma) / span;
                if (t < 0.0f) t = 0.0f;
                if (t > 1.0f) t = 1.0f;
            }
            float out = dark ? (255.0f - t * kLightEnd) : (t * kLightEnd);
            uint8_t v = (uint8_t)((out * (float)a) / 255.0f + 0.5f);  // re-premultiply
            pixels[i + 0] = v;
            pixels[i + 1] = v;
            pixels[i + 2] = v;
        }

        CGImageRef out = CGBitmapContextCreateImage(ctx);
        if (out) {
            CGImageRef cropped = NULL;
            if (any) {
                CGRect box = CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
                cropped = CGImageCreateWithImageInRect(out, box);
            }
            result = [UIImage imageWithCGImage:(cropped ?: out)
                                         scale:source.scale
                                   orientation:source.imageOrientation];
            if (cropped) CGImageRelease(cropped);
            CGImageRelease(out);
        }
        CGContextRelease(ctx);
    }
    free(pixels);
    CGColorSpaceRelease(space);

    // Redraw the trimmed glyph centred in a fixed box, scaled to fit. Aspect is
    // preserved — a wide glyph fills the width, a tall one the height — so the
    // arrow and the ring occupy the same visual weight as shuffle without being
    // distorted to a square.
    CGSize glyph = result.size;
    if (glyph.width < 0.5 || glyph.height < 0.5) return result;
    CGFloat fit = kM27GlyphBox / MAX(glyph.width, glyph.height);
    CGSize drawn = CGSizeMake(glyph.width * fit, glyph.height * fit);
    CGRect target = CGRectMake((kM27GlyphBox - drawn.width) / 2.0,
                               (kM27GlyphBox - drawn.height) / 2.0,
                               drawn.width, drawn.height);

    UIGraphicsImageRendererFormat *fmt = UIGraphicsImageRendererFormat.preferredFormat;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kM27GlyphBox, kM27GlyphBox)
                                               format:fmt];
    UIImage *boxed = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rctx) {
        (void)rctx;
        [result drawInRect:target];
    }];
    return boxed ?: result;
}

/// An SF Symbol put through the same normaliser as the mirror.
///
/// The point of routing our own glyphs through this rather than trusting a point
/// size: the placeholder arrow and the mirrored one then come out identical, so
/// the swap from one to the other — the "fake one appearing before the real
/// one" — has nothing left to show.
static UIImage *M27SymbolGlyph(NSString *name, BOOL dark) {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!symbol) return nil;

    // Flatten to a bitmap first. A symbol image is vector-backed and its
    // `CGImage` can be nil, which the normaliser would have to refuse — and
    // refusing is how the two glyphs ended up different sizes in the first
    // place. Drawn plain it comes out black on transparent, which is what the
    // normaliser expects: it decides the final value, and inverts for dark mode.
    UIGraphicsImageRendererFormat *fmt = UIGraphicsImageRendererFormat.preferredFormat;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:symbol.size format:fmt];
    UIImage *flat = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rctx) {
        (void)rctx;
        [symbol drawInRect:CGRectMake(0, 0, symbol.size.width, symbol.size.height)];
    }];
    return flat ? M27NormalizedGlyph(flat, dark) : nil;
}

/// Returns YES when the state changed, so callers log only real transitions.
- (BOOL)mirrorDownloadState {
    UIView *stock = self.stockDownload;
    if (!stock) return NO;

    // RE-RENDER EVERY TICK, NOT ONLY WHEN THE LABEL MOVES.
    //
    // "Download button is always a static image and not showing the live
    // downloading progress." The mirroring works — the screenshot shows the red
    // ring and stop square — but it was frozen at the first frame, because the
    // accessibility label was used as the change signal and it stays
    // "Downloading" for the whole download while the ring advances behind it.
    // A label that does not change meant a glyph that never redrew.
    //
    // So the snapshot is unconditional. It is a 28x28 layer render; doing it a
    // few times a second costs nothing next to being wrong.
    NSString *label = stock.accessibilityLabel ?: @"";
    BOOL labelChanged = !self.downloadMirrored || ![label isEqualToString:self.lastDownloadLabel];

    UIImage *shot = M27SnapshotStockGlyph(stock);
    if (!shot) return NO;

    BOOL dark = NO;
    if (@available(iOS 13.0, *)) {
        dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    UIImage *mono = M27NormalizedGlyph(shot, dark);

    // Original rendering mode, not template — the mono conversion has already
    // put the shading where it belongs, and a template would flatten it back.
    [self.downloadButton setImage:[mono imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                         forState:UIControlStateNormal];
    self.downloadButton.accessibilityLabel = stock.accessibilityLabel;
    self.lastDownloadLabel = label;
    self.downloadMirrored = YES;
    // Only a real state change is worth a log line; a progress ring ticking
    // would otherwise write to disk several times a second.
    return labelChanged;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.mirrorTimer invalidate];
    self.mirrorTimer = nil;
    if (!self.window) return;

    // Nothing tells us the download state moved — the stock control changes its
    // own glyph without laying us out. A poll while this row is on screen is
    // cheap and stops the moment it leaves the window. It was one second up to
    // 1.1.48, which is far too slow for a progress ring: the glass button held
    // one frozen frame of the ring for a second at a time, which is exactly what
    // "always a static image" looks like.
    __weak typeof(self) weakSelf = self;
    self.mirrorTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.window) {
            [timer invalidate];
            return;
        }
        if ([strongSelf mirrorDownloadState]) {
            M27WriteStatus(@"album_download_glyph", @{
                @"label": strongSelf.downloadButton.accessibilityLabel ?: @"-",
                @"stock": M27DescribeControl(strongSelf.stockDownload),
            });
        }
    }];
    [self mirrorDownloadState];
}

- (void)dealloc {
    [_mirrorTimer invalidate];
}

@end

/// Returns the reason a hide was refused, or nil when it was applied.
///
/// The size guards exist so we never blank a content container, but when they
/// trip the stock control stays visible under our glass row — which is exactly
/// the "not covering the old ones" symptom on 17.3. Silent refusal made that
/// indistinguishable from a failed lookup, so it reports now.
static NSString *M27HideViewKeepLayout(UIView *view) {
    if (!view) return @"nil";
    if (M27IsProtectedMusicHost(view)) return @"protected_host";
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Hosting"] || [name containsString:@"UIHosting"]) return @"hosting";
    if (view.bounds.size.height > 72.0) return @"too_tall";
    if (view.bounds.size.width > 420.0) return @"too_wide";
    // NOTE: this does NOT keep the view hit-testable. UIView.alpha is backed by
    // CALayer.opacity — they are one property — so this sets alpha to 0 just as
    // surely as assigning alpha would. 1.1.29 believed otherwise and the dock
    // paid for it until 1.1.43.
    //
    // It is fine here only because M27FireControl sends actions to the stock
    // control directly and never hit-tests it. Anything that needs to stay
    // tappable has to be masked instead — see M27MaskOutView in GlassTabBar.x.
    view.layer.opacity = 0.0;
    return nil;
}

static NSString *M27DescribeControl(UIView *view) {
    if (!view) return @"nil";
    return [NSString stringWithFormat:@"%@%@", NSStringFromClass(view.class),
            NSStringFromCGRect(view.frame)];
}

/// Name the nav bar's right-hand items, without touching them.
///
/// 1.1.52's version reported `UIBarButtonItem/-/noimg` three times over and
/// nothing else, which says only that these items carry neither an
/// accessibility label nor an `image` — the glyph is drawn by a view inside
/// them. So go one level in: the item's `customView`, the view UIKit actually
/// installed for it, and that view's immediate subviews.
///
/// Read-only. `valueForKey:@"view"` is the item's own backing view, which is the
/// same lookup `M27FindDownloadControl` has always done here.
static NSString *M27DescribeBarItems(NSArray<UIBarButtonItem *> *items) {
    if (items.count == 0) return @"none";
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (UIBarButtonItem *item in items) {
        if (out.count >= 4) break;

        UIView *view = item.customView;
        NSString *origin = @"custom";
        if (!view) {
            @try { view = [item valueForKey:@"view"]; } @catch (__unused NSException *ex) {}
            origin = view ? @"itemview" : @"none";
        }

        NSMutableArray<NSString *> *kids = [NSMutableArray array];
        for (UIView *sub in view.subviews) {
            if (kids.count >= 3) break;
            [kids addObject:NSStringFromClass(sub.class)];
        }

        // label / where the view came from / class+frame / visible? / children
        [out addObject:[NSString stringWithFormat:@"%@|%@|%@|a%.1f%@|%@",
                        item.accessibilityLabel ?: (view.accessibilityLabel ?: @"-"),
                        origin,
                        view ? M27DescribeControl(view) : @"nil",
                        view ? view.alpha : 0.0,
                        (view && view.hidden) ? @"H" : @"",
                        kids.count ? [kids componentsJoinedByString:@"+"] : @"-"]];
    }
    return [out componentsJoinedByString:@" ,"];
}

#pragma mark - Full-bleed artwork

static const void *kM27ArtStockFrameKey = &kM27ArtStockFrameKey;
static const void *kM27ArtStockCornerKey = &kM27ArtStockCornerKey;
static const void *kM27UnclippedKey = &kM27UnclippedKey;
static const void *kM27OrigBGKey = &kM27OrigBGKey;
static const void *kM27OrigBGViewKey = &kM27OrigBGViewKey;
static const void *kM27BleedLoggedKey = &kM27BleedLoggedKey;
static const void *kM27ArtSampleKey = &kM27ArtSampleKey;
static const void *kM27ArtBleedViewKey = &kM27ArtBleedViewKey;
static const void *kM27BleedArtVCKey = &kM27BleedArtVCKey;
static const void *kM27BleedPaletteKey = &kM27BleedPaletteKey;
static const NSInteger kM27BleedPlateTag = 0x4D324250; // 'M2BP'

static BOOL gM27BleedReentry = NO;
static __weak UIViewController *gM27BleedVC = nil;

static UIView *M27FindSubviewWithSuffix(UIView *root, NSString *suffix, NSInteger depth) {
    if (!root || !suffix.length || depth > 8) return nil;
    if (M27ClassNameHasSuffix(root, suffix)) return root;
    NSInteger count = MIN((NSInteger)root.subviews.count, 40);
    for (NSInteger i = 0; i < count; i++) {
        UIView *hit = M27FindSubviewWithSuffix(root.subviews[(NSUInteger)i], suffix, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UICollectionView *M27FindAlbumCollectionView(UIView *root, NSInteger depth) {
    if (!root || depth > 6) return nil;
    if ([root isKindOfClass:UICollectionView.class]) return (UICollectionView *)root;
    NSInteger count = MIN((NSInteger)root.subviews.count, 20);
    for (NSInteger i = 0; i < count; i++) {
        UICollectionView *hit = M27FindAlbumCollectionView(root.subviews[(NSUInteger)i], depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static BOOL M27ViewHasPlayer(UIView *view) {
    if (!view) return NO;
    if ([view isKindOfClass:NSClassFromString(@"MTKView")]) return YES;
    for (CALayer *layer in view.layer.sublayers) {
        NSString *name = NSStringFromClass(layer.class);
        if ([name containsString:@"AVPlayer"] || [name containsString:@"PlayerLayer"]) return YES;
    }
    return NO;
}

static BOOL M27ViewLooksLikeArtwork(UIView *view, CGRect pageBounds, CGRect pageFrame) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;
    if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class]) return NO;
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UIScrollView.class]) return NO;
    if (M27ClassNameHasSuffix(view, @"DetailsView")) return NO;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"DetailsView"]) return NO;
    CGFloat pageW = CGRectGetWidth(pageBounds);
    CGFloat pageH = CGRectGetHeight(pageBounds);
    CGFloat side = MIN(pageFrame.size.width, pageFrame.size.height);
    if (side < 150.0) return NO;
    // The whole DetailHeader is ~375×414 — skip anything that is already the page.
    if (side > pageW * 0.96) return NO;
    if (pageFrame.origin.y > pageH * 0.52) return NO;
    CGFloat ratio = pageFrame.size.height > 0.5
        ? (pageFrame.size.width / pageFrame.size.height) : 0;
    if (ratio < 0.68 || ratio > 1.50) return NO;
    return YES;
}

static CGFloat M27ArtworkScore(UIView *view, CGRect pageFrame) {
    CGFloat score = MIN(pageFrame.size.width, pageFrame.size.height);
    NSString *name = NSStringFromClass(view.class);
    if ([name.lowercaseString containsString:@"artwork"]) score += 400.0;
    if ([view isKindOfClass:UIImageView.class]) score += 200.0;
    if (M27ViewHasPlayer(view)) score += 300.0;
    return score;
}

/// 1.1.57 only looked at DetailHeader's *direct* children. On several albums
/// the square is a grandchild, or a sibling of DetailHeader inside the
/// reusable wrapper — and the page stayed stock. Search the header tree,
/// then the whole page, by geometry.
static UIView *M27FindAlbumArtworkView(UIView *page) {
    if (!page) return nil;
    CGRect pageBounds = page.bounds;
    UIView *best = nil;
    CGFloat bestScore = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    UIView *header = M27FindSubviewWithSuffix(page, @"DetailHeader", 0);
    UIView *reusable = M27FindSubviewWithSuffix(page, @"ContainerDetailHeaderReusableView", 0);
    if (header) [queue addObject:header];
    if (reusable && reusable != header) [queue addObject:reusable];
    if (queue.count == 0) [queue addObject:page];

    NSInteger visited = 0;
    while (queue.count > 0 && visited < 80) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        CGRect pageFrame = [view convertRect:view.bounds toView:page];
        if (M27ViewLooksLikeArtwork(view, pageBounds, pageFrame)) {
            CGFloat score = M27ArtworkScore(view, pageFrame);
            if (score > bestScore) {
                best = view;
                bestScore = score;
            }
        }
        NSInteger count = MIN((NSInteger)view.subviews.count, 24);
        for (NSInteger i = 0; i < count; i++) {
            [queue addObject:view.subviews[(NSUInteger)i]];
        }
    }
    if (best) return best;

    // Second pass: a player layer or a view named "artwork", even if the
    // square is slightly off the geometry window (or already full-bleed).
    [queue removeAllObjects];
    if (header) [queue addObject:header];
    if (reusable && reusable != header) [queue addObject:reusable];
    if (queue.count == 0) [queue addObject:page];
    visited = 0;
    while (queue.count > 0 && visited < 80) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        CGRect pageFrame = [view convertRect:view.bounds toView:page];
        CGFloat side = MIN(pageFrame.size.width, pageFrame.size.height);
        if (side >= 100.0 && pageFrame.origin.y <= pageBounds.size.height * 0.60) {
            NSString *name = NSStringFromClass(view.class).lowercaseString;
            BOOL named = [name containsString:@"artwork"];
            BOOL player = M27ViewHasPlayer(view);
            BOOL image = [view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image != nil;
            if ((named || player || image) && ![view isKindOfClass:UIControl.class]) {
                CGFloat score = side + (named ? 400.0 : 0) + (player ? 300.0 : 0) + (image ? 200.0 : 0);
                if (score > bestScore) {
                    best = view;
                    bestScore = score;
                }
            }
        }
        NSInteger count = MIN((NSInteger)view.subviews.count, 24);
        for (NSInteger i = 0; i < count; i++) {
            [queue addObject:view.subviews[(NSUInteger)i]];
        }
    }
    return best;
}

static UIView *M27FindMarkedArtwork(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    while (queue.count > 0 && visited < 80) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (objc_getAssociatedObject(view, kM27ArtBleedViewKey)) return view;
        NSInteger count = MIN((NSInteger)view.subviews.count, 24);
        for (NSInteger i = 0; i < count; i++) {
            [queue addObject:view.subviews[(NSUInteger)i]];
        }
    }
    return nil;
}

static UIView *M27ResolvedArtwork(UIViewController *vc, UIView *page) {
    UIView *art = objc_getAssociatedObject(vc, kM27BleedArtVCKey);
    if (art && art.superview && [art isDescendantOfView:page]) return art;
    art = M27FindMarkedArtwork(page);
    if (art) return art;
    return M27FindAlbumArtworkView(page);
}

static BOOL M27LowPowerMode(void) {
    return NSProcessInfo.processInfo.isLowPowerModeEnabled;
}

/// Freeze Music's own artwork. Do not swap it for a snapshot.
/// Low Power Mode: pause any AVPlayer and stop layer time. Otherwise leave
/// playback to Music — calling play() here would restart a cover Music paused.
static void M27SetArtworkMotionEnabled(UIView *art, BOOL enabled) {
    if (!art) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:art];
    NSInteger visited = 0;
    while (stack.count > 0 && visited < 40) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited++;
        view.layer.speed = enabled ? 1.0 : 0.0;
        for (CALayer *layer in view.layer.sublayers) {
            NSString *lname = NSStringFromClass(layer.class);
            if (![lname containsString:@"AVPlayer"] && ![lname containsString:@"PlayerLayer"]) {
                continue;
            }
            id player = nil;
            @try { player = [layer valueForKey:@"player"]; } @catch (__unused NSException *ex) {}
            if (!enabled && player && [player respondsToSelector:@selector(pause)]) {
                @try { [player pause]; } @catch (__unused NSException *ex) {}
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

static void M27RememberBackground(UIView *view) {
    if (!view || objc_getAssociatedObject(view, kM27OrigBGKey)) return;
    id stored = view.backgroundColor ?: [NSNull null];
    objc_setAssociatedObject(view, kM27OrigBGKey, stored, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void M27RestoreBackground(UIView *view) {
    if (!view) return;
    id stored = objc_getAssociatedObject(view, kM27OrigBGKey);
    if (!stored) return;
    view.backgroundColor = [stored isKindOfClass:UIColor.class] ? (UIColor *)stored : nil;
    objc_setAssociatedObject(view, kM27OrigBGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void M27UnclipView(UIView *view) {
    if (!view) return;
    if (objc_getAssociatedObject(view, kM27UnclippedKey)) return;
    if (!view.clipsToBounds && !view.layer.masksToBounds) return;
    objc_setAssociatedObject(view, kM27UnclippedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.clipsToBounds = NO;
    view.layer.masksToBounds = NO;
}

static void M27ReclipView(UIView *view) {
    if (!view || !objc_getAssociatedObject(view, kM27UnclippedKey)) return;
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
    objc_setAssociatedObject(view, kM27UnclippedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Resize Music's own artwork surface. Do not replace it — iOS 17+ covers can
/// be video, and a snapshot or a fresh UIImageView would freeze them.
static void M27FillArtworkSubtree(UIView *view, NSInteger depth) {
    if (!view || depth > 4) return;
    CGRect bounds = view.bounds;
    for (UIView *sub in view.subviews) {
        CGFloat parentW = CGRectGetWidth(bounds);
        CGFloat childW = CGRectGetWidth(sub.frame);
        BOOL fills = (parentW > 1.0) && (childW >= parentW * 0.80);
        BOOL image = [sub isKindOfClass:UIImageView.class];
        if (fills || image || depth == 0) {
            if (!CGRectEqualToRect(sub.frame, bounds)) {
                sub.frame = bounds;
            }
            sub.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        if (image) {
            ((UIImageView *)sub).contentMode = UIViewContentModeScaleAspectFill;
            sub.clipsToBounds = YES;
        }
        sub.layer.cornerRadius = 0;
        for (CALayer *layer in sub.layer.sublayers) {
            NSString *lname = NSStringFromClass(layer.class);
            if ([lname containsString:@"AVPlayer"] || [lname containsString:@"PlayerLayer"]) {
                @try { [layer setValue:@"resizeAspectFill" forKey:@"videoGravity"]; }
                @catch (__unused NSException *ex) {}
                layer.frame = sub.bounds;
            }
        }
        M27FillArtworkSubtree(sub, depth + 1);
    }
}

static void M27ApplyAlbumWash(UIView *view, M27ColorPalette *palette) {
    if (!view) return;
    CAGradientLayer *wash = nil;
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer.name isEqualToString:@"M27Wash"]) {
            wash = (CAGradientLayer *)layer;
            break;
        }
    }
    if (!palette) {
        [wash removeFromSuperlayer];
        return;
    }
    if (!wash) {
        wash = [CAGradientLayer layer];
        wash.name = @"M27Wash";
        // Not zPosition -1000. That is what put the wash behind the opaque
        // collection view and made Artwork Color Theme a no-op for every build.
        [view.layer insertSublayer:wash atIndex:0];
    }
    wash.frame = view.bounds;
    wash.colors = @[
        (id)[palette.background colorWithAlphaComponent:0.92].CGColor,
        (id)[palette.backgroundSecondary colorWithAlphaComponent:0.78].CGColor,
        (id)[palette.background colorWithAlphaComponent:0.55].CGColor,
    ];
    wash.startPoint = CGPointMake(0.5, 0.0);
    wash.endPoint = CGPointMake(0.5, 1.0);
}

static void M27SetAlbumNavBarClear(UIViewController *vc, BOOL clear) {
    UINavigationBar *bar = vc.navigationController.navigationBar;
    if (!bar) return;
    if (clear) {
        [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
        bar.shadowImage = [UIImage new];
        bar.translucent = YES;
        return;
    }
    [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    bar.shadowImage = nil;
}

static NSString *M27ArtworkInnerDescription(UIView *art) {
    if (!art) return @"-";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:art];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray arrayWithObject:@0];
    while (queue.count > 0 && parts.count < 8) {
        UIView *view = queue.firstObject;
        NSInteger depth = depths.firstObject.integerValue;
        [queue removeObjectAtIndex:0];
        [depths removeObjectAtIndex:0];
        NSString *img = @"-";
        if ([view isKindOfClass:UIImageView.class]) {
            UIImage *shown = ((UIImageView *)view).image;
            if (shown) {
                img = [NSString stringWithFormat:@"%.0fx%.0f",
                       shown.size.width, shown.size.height];
            }
        }
        NSString *player = @"-";
        for (CALayer *layer in view.layer.sublayers) {
            NSString *lname = NSStringFromClass(layer.class);
            if ([lname containsString:@"AVPlayer"] || [lname containsString:@"PlayerLayer"] ||
                [lname containsString:@"MTKView"] || [lname containsString:@"Player"]) {
                player = lname;
                break;
            }
        }
        if ([view isKindOfClass:NSClassFromString(@"MTKView")]) player = @"MTKView";
        [parts addObject:[NSString stringWithFormat:@"%ld:%@%@ img%@ ply%@",
                          (long)depth, NSStringFromClass(view.class),
                          NSStringFromCGRect(view.bounds), img, player]];
        if (depth >= 3) continue;
        for (UIView *sub in view.subviews) {
            [queue addObject:sub];
            [depths addObject:@(depth + 1)];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : @"-";
}

static NSString *M27ColorHex(UIColor *color) {
    if (!color) return @"-";
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return @"-";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)(r * 255.0 + 0.5), (int)(g * 255.0 + 0.5), (int)(b * 255.0 + 0.5)];
}

/// The header cell that lives in the collection — not the artwork itself.
/// Its `frame` is in content space and does not move when the user scrolls.
static UIView *M27BleedHomeView(UIView *art) {
    UIView *home = art;
    NSInteger hops = 0;
    while (home.superview && hops < 8) {
        UIView *parent = home.superview;
        if ([parent isKindOfClass:UICollectionView.class] ||
            [parent isKindOfClass:UIScrollView.class]) {
            break;
        }
        home = parent;
        hops++;
    }
    return home;
}

/// Content-space {0,0,W,W} in the artwork's superview.
///
/// 1.1.58 converted window {0,0,W,W}. That pins the cover to the screen, so
/// as the header scrolls the enlarged art sits still *behind* Music's original
/// square, title, and Play row — "something behind the original UI". The
/// target has to travel with the header. The reusable view's frame in the
/// collection is content-stable, so content {0,0,W,W} relative to that frame
/// is the page-top square and scrolls with it.
static CGRect M27BleedTargetFrame(UIView *art, UIView *page) {
    if (!art.superview) return CGRectZero;
    CGFloat width = 0;
    if (page) width = CGRectGetWidth(page.bounds);
    if (width < 200.0 && art.window) width = CGRectGetWidth(art.window.bounds);
    if (width < 200.0) return CGRectZero;

    UIView *home = M27BleedHomeView(art);
    UIView *scroller = home.superview;
    if ([scroller isKindOfClass:UIScrollView.class]) {
        CGRect homeFrame = home.frame;
        CGRect targetInHome = CGRectMake(-homeFrame.origin.x,
                                         -homeFrame.origin.y,
                                         width, width);
        // Header at content y≈0 with a top inset still has to reach under
        // the nav bar. Do not add the inset when the header is already at
        // y=94 — that would double-count and push the cover off-screen.
        if (homeFrame.origin.y < 8.0) {
            CGFloat inset = 0;
            if (@available(iOS 11.0, *)) {
                inset = ((UIScrollView *)scroller).adjustedContentInset.top;
            } else {
                inset = ((UIScrollView *)scroller).contentInset.top;
            }
            if (inset > 8.0) targetInHome.origin.y -= inset;
        }
        if (art.superview == home) return targetInHome;
        return [home convertRect:targetInHome toView:art.superview];
    }
    if (page) {
        return [page convertRect:CGRectMake(0, 0, width, width) toView:art.superview];
    }
    return CGRectZero;
}

static BOOL M27TransformsClose(CGAffineTransform a, CGAffineTransform b) {
    return fabs(a.a - b.a) < 0.002 && fabs(a.d - b.d) < 0.002
        && fabs(a.tx - b.tx) < 0.5 && fabs(a.ty - b.ty) < 0.5
        && fabs(a.b - b.b) < 0.002 && fabs(a.c - b.c) < 0.002;
}

/// Scale Music's own artwork so the nested image / player scales with it.
/// Fighting child frames left the outer view large and the cover at 231×231
/// — a second copy of the square sitting on the original UI.
static void M27PinArtwork(UIView *art, UIView *page) {
    if (!art.superview) return;
    CGSize size = art.bounds.size;
    if (size.width < 8.0 || size.height < 8.0) return;
    // `frame` is undefined once a transform is set. Center + bounds stay in
    // the untransformed layout Music just applied.
    CGRect stock = CGRectMake(art.center.x - size.width / 2.0,
                              art.center.y - size.height / 2.0,
                              size.width, size.height);
    CGFloat pageW = page ? CGRectGetWidth(page.bounds) : 0;
    if (pageW < 200.0 && art.window) pageW = CGRectGetWidth(art.window.bounds);
    if (!objc_getAssociatedObject(art, kM27ArtStockFrameKey) &&
        size.width < pageW * 0.90) {
        objc_setAssociatedObject(art, kM27ArtStockFrameKey,
                                 [NSValue valueWithCGRect:stock],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(art, kM27ArtStockCornerKey,
                                 @(art.layer.cornerRadius),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect target = M27BleedTargetFrame(art, page);
    if (CGRectIsEmpty(target)) return;
    CGFloat sx = target.size.width / stock.size.width;
    CGFloat sy = target.size.height / stock.size.height;
    CGFloat tx = CGRectGetMidX(target) - CGRectGetMidX(stock);
    CGFloat ty = CGRectGetMidY(target) - CGRectGetMidY(stock);
    CGAffineTransform next = CGAffineTransformMake(sx, 0, 0, sy, tx, ty);
    if (!M27TransformsClose(art.transform, next)) {
        art.transform = next;
    }
    art.layer.cornerRadius = 0;
    if (@available(iOS 13.0, *)) {
        art.layer.cornerCurve = kCACornerCurveContinuous;
    }
    art.clipsToBounds = YES;
}

static void M27UnclipToCollection(UIView *from, UIView *stop) {
    UIView *view = from;
    NSInteger hops = 0;
    while (view && hops < 8) {
        if (view == stop) break;
        M27UnclipView(view);
        view = view.superview;
        hops++;
    }
}

static void M27ReclipToCollection(UIView *from, UIView *stop) {
    UIView *view = from;
    NSInteger hops = 0;
    while (view && hops < 8) {
        if (view == stop) break;
        M27ReclipView(view);
        view = view.superview;
        hops++;
    }
}

static BOOL M27IsBleedProtected(UIView *view) {
    if (!view) return YES;
    if (view.tag == kM27BleedPlateTag) return YES;
    if (objc_getAssociatedObject(view, kM27ArtBleedViewKey)) return YES;
    return NO;
}

/// Track rows keep their own opaque black views *inside* contentView.
/// Clearing only cell.backgroundColor (1.1.58) left those walls up, so the
/// plate never showed and the header — now punched clear — revealed a
/// second layer behind the original UI.
static void M27ClearOpaqueWalls(UIView *view, NSInteger depth) {
    if (!view || depth > 5) return;
    if (M27IsBleedProtected(view)) return;
    if ([view isKindOfClass:UIControl.class] ||
        [view isKindOfClass:UILabel.class] ||
        [view isKindOfClass:UIImageView.class] ||
        [view isKindOfClass:UIVisualEffectView.class]) {
        return;
    }
    if ([view isKindOfClass:NSClassFromString(@"MTKView")]) return;

    if ([view isKindOfClass:UICollectionViewCell.class]) {
        UICollectionViewCell *cell = (UICollectionViewCell *)view;
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.opaque = NO;
        if (cell.backgroundView && cell.backgroundView.tag != kM27BleedPlateTag) {
            cell.backgroundView.backgroundColor = UIColor.clearColor;
            cell.backgroundView.opaque = NO;
        }
        if (cell.selectedBackgroundView) {
            cell.selectedBackgroundView.backgroundColor = UIColor.clearColor;
        }
        M27ClearOpaqueWalls(cell.contentView, depth + 1);
        return;
    }

    NSString *name = NSStringFromClass(view.class);
    BOOL systemBG = [name containsString:@"SystemBackground"]
        || [name containsString:@"BackgroundView"];
    CGFloat alpha = view.backgroundColor
        ? CGColorGetAlpha(view.backgroundColor.CGColor) : 0.0;
    CGFloat w = view.bounds.size.width;
    CGFloat h = view.bounds.size.height;
    if (systemBG || (alpha > 0.01 && w >= 160.0 && h >= 28.0)) {
        view.backgroundColor = UIColor.clearColor;
        view.opaque = NO;
    }

    NSInteger count = MIN((NSInteger)view.subviews.count, 16);
    for (NSInteger i = 0; i < count; i++) {
        UIView *sub = view.subviews[(NSUInteger)i];
        if (M27IsBleedProtected(sub)) continue;
        M27ClearOpaqueWalls(sub, depth + 1);
    }
}

static void M27ClearVisibleCellBackgrounds(UICollectionView *collection) {
    if (!collection) return;
    for (UICollectionViewCell *cell in collection.visibleCells) {
        M27ClearOpaqueWalls(cell, 0);
    }
    for (NSString *kind in @[
             UICollectionElementKindSectionHeader,
             UICollectionElementKindSectionFooter
         ]) {
        for (UICollectionReusableView *supp in [collection visibleSupplementaryViewsOfKind:kind]) {
            if (M27IsBleedProtected(supp)) continue;
            M27ClearOpaqueWalls(supp, 0);
        }
    }
}

static UIImage *M27ImageForAlbumColor(UIView *art, UIView *page) {
    UIImage *image = art ? M27LargestImageInView(art) : nil;
    if (!image) image = M27LargestImageInView(page);
    if (!image && art && !CGRectIsEmpty(art.bounds)) {
        id rawSample = objc_getAssociatedObject(art, kM27ArtSampleKey);
        UIImage *sampled = [rawSample isKindOfClass:UIImage.class] ? (UIImage *)rawSample : nil;
        if (!sampled) {
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(32, 32), YES, 1.0);
            [art drawViewHierarchyInRect:CGRectMake(0, 0, 32, 32) afterScreenUpdates:NO];
            sampled = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (sampled) {
                objc_setAssociatedObject(art, kM27ArtSampleKey, sampled,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        image = sampled;
    }
    return image;
}

static void M27InstallBleedPlate(UICollectionView *collection, UIColor *color) {
    if (!collection || !color) return;
    UIView *existing = collection.backgroundView;
    if (existing.tag != kM27BleedPlateTag) {
        if (!objc_getAssociatedObject(collection, kM27OrigBGViewKey)) {
            id stored = existing ?: [NSNull null];
            objc_setAssociatedObject(collection, kM27OrigBGViewKey, stored,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *plate = [[UIView alloc] initWithFrame:collection.bounds];
        plate.tag = kM27BleedPlateTag;
        plate.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        collection.backgroundView = plate;
        existing = plate;
    }
    existing.backgroundColor = color;
    existing.frame = collection.bounds;
}

static void M27PaintSolidAncestors(UIView *from, UIView *page, UIColor *color) {
    UIView *wall = from;
    NSInteger hops = 0;
    while (wall && hops < 8) {
        M27RememberBackground(wall);
        wall.backgroundColor = color;
        wall.opaque = YES;
        if (wall == page) break;
        wall = wall.superview;
        hops++;
    }
}

static void M27PaintAlbumPageColor(UIView *page, UIView *header, UICollectionView *collection,
                                   M27ColorPalette *palette) {
    if (!palette) return;
    [M27ColorTheme.shared applyPalette:palette animated:NO];
    // Solid colour, not a translucent wash. 1.1.58's alpha gradient on the
    // collection sat behind Music's still-opaque cells and read as a ghost
    // copy of the page.
    if (collection) {
        M27PaintSolidAncestors(collection, page, palette.background);
    } else if (page) {
        M27RememberBackground(page);
        page.backgroundColor = palette.background;
        page.opaque = YES;
    }
    NSArray *headers = @[
        header ?: (UIView *)[NSNull null],
        header.superview ?: (UIView *)[NSNull null],
    ];
    for (id obj in headers) {
        if (![obj isKindOfClass:UIView.class]) continue;
        UIView *chrome = (UIView *)obj;
        if (chrome == collection || chrome == page) continue;
        M27RememberBackground(chrome);
        chrome.backgroundColor = UIColor.clearColor;
        chrome.opaque = NO;
    }
    M27InstallBleedPlate(collection, palette.background);
    M27ClearVisibleCellBackgrounds(collection);
    M27ApplyAlbumWash(collection, nil);
    M27ApplyAlbumWash(page, nil);
}

static void M27EnsurePowerObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            UIViewController *vc = gM27BleedVC;
            if (!vc.isViewLoaded || !vc.view.window) return;
            UIView *art = objc_getAssociatedObject(vc, kM27BleedArtVCKey);
            if (art) M27SetArtworkMotionEnabled(art, !M27LowPowerMode());
        }];
    });
}

static UIViewController *M27AlbumPageControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            UIViewController *vc = (UIViewController *)responder;
            if (M27IsAlbumDetailController(vc)) return vc;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static void M27RestoreFullBleed(UIViewController *vc) {
    if (!vc.isViewLoaded) return;
    UIView *art = objc_getAssociatedObject(vc, kM27BleedArtVCKey);
    if (!art) art = M27FindMarkedArtwork(vc.view);
    if (!art) art = M27FindAlbumArtworkView(vc.view);
    UICollectionView *collection = M27FindAlbumCollectionView(vc.view, 0);
    if (art) {
        objc_setAssociatedObject(art, kM27ArtBleedViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        M27SetArtworkMotionEnabled(art, YES);
        art.transform = CGAffineTransformIdentity;
        NSValue *stock = objc_getAssociatedObject(art, kM27ArtStockFrameKey);
        if (stock) art.frame = stock.CGRectValue;
        NSNumber *corner = objc_getAssociatedObject(art, kM27ArtStockCornerKey);
        if (corner) art.layer.cornerRadius = corner.doubleValue;
        objc_setAssociatedObject(art, kM27ArtStockFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(art, kM27ArtStockCornerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (CALayer *layer in art.layer.sublayers.copy) {
            if ([layer.name isEqualToString:@"M27ArtFade"]) [layer removeFromSuperlayer];
        }
        M27ReclipToCollection(art.superview, collection);
    }
    objc_setAssociatedObject(vc, kM27BleedArtVCKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kM27BleedPaletteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gM27BleedVC == vc) gM27BleedVC = nil;
    UIView *header = M27FindSubviewWithSuffix(vc.view, @"DetailHeader", 0);
    M27ReclipView(header);
    M27ReclipView(header.superview);
    if (collection) {
        id stored = objc_getAssociatedObject(collection, kM27OrigBGViewKey);
        if (stored) {
            collection.backgroundView = [stored isKindOfClass:UIView.class] ? (UIView *)stored : nil;
            objc_setAssociatedObject(collection, kM27OrigBGViewKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    UIView *wall = collection ?: vc.view;
    NSInteger restoreHops = 0;
    while (wall && restoreHops < 8) {
        M27RestoreBackground(wall);
        if (wall == vc.view) break;
        wall = wall.superview;
        restoreHops++;
    }
    M27RestoreBackground(header);
    M27RestoreBackground(header.superview);
    M27ApplyAlbumWash(collection, nil);
    M27ApplyAlbumWash(vc.view, nil);
    M27SetAlbumNavBarClear(vc, NO);
    objc_setAssociatedObject(vc, kM27BleedLoggedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL M27ApplyFullBleed(UIViewController *vc) {
    if (gM27BleedReentry) return NO;
    if (!vc.isViewLoaded || !vc.view) return NO;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) {
        M27RestoreFullBleed(vc);
        return NO;
    }
    if (!M27IsAlbumDetailController(vc)) return NO;

    UIView *page = vc.view;
    CGFloat pageW = CGRectGetWidth(page.bounds);
    if (pageW < 200.0) return NO;

    gM27BleedReentry = YES;
    M27EnsurePowerObserver();
    gM27BleedVC = vc;

    UIView *art = M27ResolvedArtwork(vc, page);
    UIView *header = art.superview ?: M27FindSubviewWithSuffix(page, @"DetailHeader", 0);
    UICollectionView *collection = M27FindAlbumCollectionView(page, 0);
    BOOL lpm = M27LowPowerMode();
    BOOL plateOK = collection.backgroundView.tag == kM27BleedPlateTag;
    CGRect target = art ? M27BleedTargetFrame(art, page) : CGRectZero;

    // Scrolling re-lays out the collection. Re-pin and keep cells clear;
    // do not re-extract a palette on every tick.
    if (art && plateOK && objc_getAssociatedObject(vc, kM27BleedLoggedKey)) {
        M27PinArtwork(art, page);
        M27FillArtworkSubtree(art, 0);
        M27ColorPalette *held = objc_getAssociatedObject(vc, kM27BleedPaletteKey);
        if ([held isKindOfClass:M27ColorPalette.class]) {
            collection.backgroundColor = held.background;
            page.backgroundColor = held.background;
            M27InstallBleedPlate(collection, held.background);
        }
        M27ClearVisibleCellBackgrounds(collection);
        M27SetArtworkMotionEnabled(art, !lpm);
        gM27BleedReentry = NO;
        return YES;
    }
    if (!art && plateOK && objc_getAssociatedObject(vc, kM27BleedLoggedKey)) {
        M27ColorPalette *held = objc_getAssociatedObject(vc, kM27BleedPaletteKey);
        if ([held isKindOfClass:M27ColorPalette.class]) {
            M27InstallBleedPlate(collection, held.background);
        }
        M27ClearVisibleCellBackgrounds(collection);
        gM27BleedReentry = NO;
        return NO;
    }

    if (art) {
        objc_setAssociatedObject(vc, kM27BleedArtVCKey, art, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(art, kM27ArtBleedViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        M27PinArtwork(art, page);
        M27FillArtworkSubtree(art, 0);
        M27UnclipToCollection(art.superview, collection);
        M27SetArtworkMotionEnabled(art, !lpm);
        target = M27BleedTargetFrame(art, page);
    }

    UIImage *image = M27ImageForAlbumColor(art, page);
    M27ColorPalette *palette = [M27ColorTheme.shared paletteFromImage:image];
    if (palette) {
        objc_setAssociatedObject(vc, kM27BleedPaletteKey, palette,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Colour the whole page even when the square was not found. 1.1.57
    // returned here and left Apple's header-only wash + black track cells.
    M27PaintAlbumPageColor(page, header, collection, palette);
    M27SetAlbumNavBarClear(vc, YES);

    if (art) {
        CAGradientLayer *fade = nil;
        for (CALayer *layer in art.layer.sublayers) {
            if ([layer.name isEqualToString:@"M27ArtFade"]) {
                fade = (CAGradientLayer *)layer;
                break;
            }
        }
        if (!fade) {
            fade = [CAGradientLayer layer];
            fade.name = @"M27ArtFade";
            [art.layer addSublayer:fade];
        }
        fade.frame = art.bounds;
        UIColor *fadeTo = palette.background ?: UIColor.blackColor;
        fade.colors = @[
            (id)[UIColor clearColor].CGColor,
            (id)[UIColor clearColor].CGColor,
            (id)[fadeTo colorWithAlphaComponent:0.55].CGColor,
        ];
        fade.locations = @[ @0.0, @0.62, @1.0 ];
        fade.startPoint = CGPointMake(0.5, 0.0);
        fade.endPoint = CGPointMake(0.5, 1.0);
    }

    NSString *foundNow = art ? @"yes" : @"no";
    id logged = objc_getAssociatedObject(vc, kM27BleedLoggedKey);
    NSString *loggedFound = [logged isKindOfClass:NSString.class] ? (NSString *)logged : nil;
    if (!loggedFound || ![loggedFound isEqualToString:foundNow]) {
        objc_setAssociatedObject(vc, kM27BleedLoggedKey, foundNow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (art) target = M27BleedTargetFrame(art, page);
        CGFloat headerBG = header.backgroundColor
            ? CGColorGetAlpha(header.backgroundColor.CGColor) : 0.0;
        CGFloat collectionBG = collection.backgroundColor
            ? CGColorGetAlpha(collection.backgroundColor.CGColor) : 0.0;
        NSInteger cells = collection.visibleCells.count;
        M27WriteStatus(@"album_bleed", @{
            @"found": art ? @"yes" : @"no",
            @"art": art ? M27DescribeControl(art) : @"nil",
            @"header": header ? NSStringFromClass(header.class) : @"nil",
            @"collection": collection ? NSStringFromClass(collection.class) : @"nil",
            @"target": NSStringFromCGRect(target),
            @"page": NSStringFromCGRect(page.bounds),
            @"header_bg": @((double)headerBG),
            @"collection_bg": @((double)collectionBG),
            @"cells": @((long)cells),
            @"plate": (collection.backgroundView.tag == kM27BleedPlateTag) ? @"yes" : @"no",
            @"palette": palette ? @"yes" : @"no",
            @"color": M27ColorHex(palette.background),
            @"lpm": lpm ? @"yes" : @"no",
            @"pin": @"content",
            @"xform": art ? [NSString stringWithFormat:@"%.2f,%.1f,%.1f",
                             art.transform.a, art.transform.tx, art.transform.ty] : @"-",
            @"inner": M27ArtworkInnerDescription(art),
        });
    }

    gM27BleedReentry = NO;
    return art != nil;
}

static BOOL M27InstallAlbumControls(UIViewController *vc) {
    M27Prefs *prefs = M27Prefs.shared;
    // May live in vc.view (older builds) or in the stock controls' superview.
    UIView *existing = [vc.view viewWithTag:kM27AlbumControlsTag];

    if (!(prefs.enabled && prefs.glassTabBarEnabled)) {
        [existing removeFromSuperview];
        return NO;
    }
    if (!M27IsAlbumDetailController(vc)) {
        [existing removeFromSuperview];
        return NO;
    }

    // BEFORE THE GATE. The download button is in the nav bar, which is painted
    // from the first frame, while the lookup below returns early for the second
    // or so Music spends building the header. Everything after this point is
    // gated on a header that does not exist yet; this is not.
    M27SetNavDownloadHidden(vc, YES);

    // Exact title match avoids false positives like "playlist" / "Listen Now".
    UIView *play = M27FindControlWithTitle(vc.view, @[ @"play" ], YES, 0);
    UIView *shuffle = M27FindControlWithTitle(vc.view, @[ @"shuffle" ], YES, 0);
    if (!play || !shuffle) {
        // The lookup matches on title text; if Music 17 renders these through
        // SwiftUI there may be no titled UIControl to find, which would explain
        // both dead buttons and uncovered stock ones.
        M27WriteStatus(@"album_lookup_failed", @{
            @"play": M27DescribeControl(play),
            @"shuffle": M27DescribeControl(shuffle),
            @"vc": NSStringFromClass(vc.class),
        });
        return NO;
    }

    // Hide only small stock controls — never a hosting/content ancestor.
    NSString *playWhy = M27HideViewKeepLayout(play);
    NSString *shuffleWhy = M27HideViewKeepLayout(shuffle);

    UIView *download = M27FindDownloadControl(vc);
    NSString *downloadWhy = M27HideViewKeepLayout(download);

    // THE SYMBOLBUTTON IS ONLY THE CAPSULE BACKGROUND.
    //
    // 1.1.33's readback settled this. On device, with the stock glyphs plainly
    // still on screen, status.log said:
    //
    //   play_hidden=yes play_opacity=0 play_alpha=0
    //
    // The hide stuck, and nothing reset it — so the earlier "something
    // re-renders and undoes it" theory was wrong. The photos say what actually
    // happens: before the tweak these are grey capsules with red content, and
    // after, the grey capsules vanish while the red ▶ and "Shuffle" stay. The
    // MusicCoreUI.SymbolButton we hide is the capsule; SwiftUI draws the glyph
    // and label as siblings, outside that view's layer subtree, so hiding the
    // button can never take them with it.
    //
    // So hide the row container — the view that holds both capsules and their
    // content — and only when it hugs the pair tightly enough to be that row and
    // nothing more. A loose match here would blank part of the album header.
    UIView *stockRow = nil;
    NSString *stockRowWhy = @"no_container";
    UIView *sharedParent = play.superview;
    if (sharedParent && sharedParent == shuffle.superview) {
        CGRect pair = CGRectUnion(play.frame, shuffle.frame);
        CGSize slack = CGSizeMake(CGRectGetWidth(sharedParent.bounds) - CGRectGetWidth(pair),
                                  CGRectGetHeight(sharedParent.bounds) - CGRectGetHeight(pair));
        if (slack.width <= 24.0 && slack.height <= 24.0) {
            stockRow = sharedParent;
            stockRowWhy = M27HideViewKeepLayout(stockRow) ?: @"yes";
        } else {
            stockRowWhy = [NSString stringWithFormat:@"slack_%.0fx%.0f", slack.width, slack.height];
        }
    }

    M27WriteStatus(@"album_controls", @{
        @"vc": NSStringFromClass(vc.class),
        @"play": M27DescribeControl(play),
        @"play_is_control": [play isKindOfClass:UIControl.class] ? @"yes" : @"no",
        @"play_hidden": playWhy ?: @"yes",
        @"play_opacity": @((double)play.layer.opacity),
        @"shuffle": M27DescribeControl(shuffle),
        @"shuffle_is_control": [shuffle isKindOfClass:UIControl.class] ? @"yes" : @"no",
        @"shuffle_hidden": shuffleWhy ?: @"yes",
        @"stock_row": M27DescribeControl(stockRow),
        @"stock_row_hidden": stockRowWhy,
        @"download": M27DescribeControl(download),
        @"download_hidden": downloadWhy ?: @"yes",
        // Both downloads are 28x28 MusicCoreUI.SymbolButtons, so the class and
        // frame alone cannot tell them apart — which is how 1.1.53 swapped one
        // for the other without it showing in the log. Report the nav one's
        // opacity separately so the two are never confusable again.
        @"nav_download": M27DescribeControl(M27NavDownloadControl(vc)),
        @"nav_download_opacity": @((double)M27NavDownloadControl(vc).layer.opacity),
        // "There's a flash with the real red download button at the top for a
        // second, and then it comes down." The one in the row is accounted for
        // above; the one at the top is not in vc.view at all, so nothing here
        // has ever seen it. If it is a bar button item this names it, and the
        // next build can decide what to do about it on evidence rather than by
        // hiding a control we have not identified.
        @"nav_right": M27DescribeBarItems(vc.navigationItem.rightBarButtonItems),
    });

    // Host the row in the stock controls' OWN superview, not vc.view.
    //
    // On a playlist page the row was landing in the middle of the track list:
    // parented to vc.view it stays fixed while the header scrolls away beneath
    // it. As a sibling of the stock buttons it scrolls with them and stays put
    // relative to the artwork, which is what the album page already looked like
    // by accident because its header happened not to scroll far.
    //
    // When the row container is the thing we hid, our row has to be its SIBLING.
    // `layer.opacity = 0` applies to the whole layer subtree, so a child of the
    // hidden container would be invisible too — the 1.1.28 alpha mistake in a
    // different costume.
    UIView *host = stockRow ? (stockRow.superview ?: vc.view)
                            : (play.superview ?: vc.view);
    UIView *existingInHost = [host viewWithTag:kM27AlbumControlsTag];
    if (existing && existing != existingInHost) [existing removeFromSuperview];

    CGRect playFrame = [play convertRect:play.bounds toView:host];
    CGRect shuffleFrame = [shuffle convertRect:shuffle.bounds toView:host];
    CGRect span = CGRectUnion(playFrame, shuffleFrame);
    // Cover exactly the ground the stock pair occupies.
    CGFloat minX = CGRectGetMinX(span);
    CGFloat maxX = CGRectGetMaxX(span);
    if (maxX - minX < 120.0) {
        minX = 20.0;
        maxX = host.bounds.size.width - 20.0;
    }
    CGFloat top = CGRectGetMidY(span) - kM27PlayHeight / 2.0;

    M27AlbumControlsView *row = (M27AlbumControlsView *)existingInHost;
    if (![row isKindOfClass:M27AlbumControlsView.class]) {
        row = [[M27AlbumControlsView alloc] initWithFrame:CGRectZero];
        row.tag = kM27AlbumControlsTag;
        [host addSubview:row];
    }
    row.stockPlay = play;
    row.stockShuffle = shuffle;
    row.stockDownloadItem = M27NavDownloadItem(vc);
    // A different album means a different download control in a different state.
    if (row.stockDownload != download) {
        row.stockDownload = download;
        row.downloadMirrored = NO;
        row.lastDownloadLabel = nil;
    }
    row.frame = CGRectMake(minX, top, maxX - minX, kM27PlayHeight);
    [host bringSubviewToFront:row];
    // Pick up whatever state the stock download control is in right now, rather
    // than waiting up to a second for the poll.
    [row mirrorDownloadState];

    M27WriteStatus(@"album_row_placed", @{
        @"host": NSStringFromClass(host.class),
        @"row": NSStringFromCGRect(row.frame),
        @"span": NSStringFromCGRect(span),
        @"sibling_of_hidden_row": stockRow ? @"yes" : @"no",
    });

    // "COMPLETE" MEANS THE DOWNLOAD CONTROL TOO, NOT JUST PLAY AND SHUFFLE.
    //
    // 1.1.51's log is unambiguous about the remaining flash. Every album open
    // reads the same way, one second apart:
    //
    //   18:44:00  album_controls  download=nil    download_hidden=nil
    //   18:44:01  album_controls  download=Symbol download_hidden=yes
    //
    // Play and shuffle are in the header as soon as it builds; the download
    // control arrives about a second later. Returning YES here as soon as the
    // row was placed told the retry timer its job was done, so nothing was
    // watching for the control that had not turned up yet — and Music's own red
    // one sat there uncovered for that second.
    //
    // The row is still placed on this pass either way; only the answer to "is
    // there anything left to wait for" changes. An album with genuinely no
    // download control just costs the retry its full ~2s cap and then stops.
    return download != nil;
}

/// Keep trying until the stock row exists.
///
/// "The old red shuffle play and download buttons still show for a second or
/// two." They do, and neither viewWillAppear nor the first viewDidLayoutSubviews
/// can help: status.log reports `album_lookup_failed play=nil shuffle=nil` at
/// both, because Music builds this header asynchronously. Layout does not run
/// again until something changes, which is exactly the second or two of stock
/// buttons on screen.
///
/// So poll — briefly, and only until it works. Every other trigger stays; this
/// just closes the window none of them cover.
static void M27RetryAlbumInstall(UIViewController *vc) {
    if (!vc) return;
    __weak UIViewController *weakVC = vc;
    __block NSInteger attempts = 0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        __strong UIViewController *strongVC = weakVC;
        attempts++;
        // ~2s. If the header has not appeared by then it is not going to, and a
        // timer that never stops is worse than a flash.
        if (!strongVC || !strongVC.isViewLoaded || strongVC.view.window == nil || attempts > 40) {
            [t invalidate];
            return;
        }
        BOOL controls = M27InstallAlbumControls(strongVC);
        BOOL bleed = M27ApplyFullBleed(strongVC);
        if (controls && bleed) [t invalidate];
    }];
    // Common modes: a scroll in progress must not stall the retry.
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

/// Measure the album detail page, once per opening.
///
/// Two open requests need this and neither can be answered by guessing.
///
/// **Full-bleed artwork.** iOS 26/27 runs the cover edge to edge under the nav
/// bar; iOS 17 shows a small centred square. To resize Music's own artwork view —
/// which it must be, because iOS 17+ covers can be animated and a snapshot would
/// freeze them — the view has to be identified first. The only thing known about
/// this page so far is `DetailHeader.DetailsView`, the container holding the
/// title and buttons, and the artwork is not in it.
///
/// **Colour matching.** The wash already exists behind *Artwork Color Theme*,
/// and it goes in at layer index 0 with zPosition -1000. If Music's own content
/// paints an opaque background over it, it has never been visible no matter what
/// the pref said — so every row records whether it is opaque, which settles that
/// without another build.
///
/// Read-only: class, frame, opacity, and image dimensions. No ivar reads.
static void M27ReportAlbumTree(UIViewController *vc) {
    if (!vc.isViewLoaded || !vc.view) return;

    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:vc.view];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray arrayWithObject:@0];

    while (queue.count > 0 && rows.count < 70) {
        UIView *view = queue.firstObject;
        NSInteger depth = depths.firstObject.integerValue;
        [queue removeObjectAtIndex:0];
        [depths removeObjectAtIndex:0];

        CGRect f = [view convertRect:view.bounds toView:vc.view];
        if (f.size.width >= 8.0 && f.size.height >= 8.0 && !view.hidden && view.alpha > 0.01) {
            // Opaque background = a candidate for what buries the wash.
            // CGColorGetAlpha, not getWhite:alpha: — the latter reports failure
            // and leaves its out-params untouched for any non-greyscale colour,
            // which is most of them.
            CGFloat bgAlpha = view.backgroundColor
                ? CGColorGetAlpha(view.backgroundColor.CGColor) : 0.0;
            // Any image this view is showing, without walking into private
            // structure: UIImageView's own property, or a layer whose contents
            // is a CGImage (which is how a SwiftUI image usually lands).
            NSString *img = @"-";
            if ([view isKindOfClass:UIImageView.class]) {
                UIImage *shown = ((UIImageView *)view).image;
                if (shown) img = [NSString stringWithFormat:@"%.0fx%.0f",
                                  shown.size.width, shown.size.height];
            } else if (view.layer.contents &&
                       CFGetTypeID((__bridge CFTypeRef)view.layer.contents) == CGImageGetTypeID()) {
                CGImageRef cg = (__bridge CGImageRef)view.layer.contents;
                img = [NSString stringWithFormat:@"%zux%zu",
                       CGImageGetWidth(cg), CGImageGetHeight(cg)];
            }
            [rows addObject:[NSString stringWithFormat:@"%ld|%@%@|bg%.2f|img%@",
                             (long)depth, NSStringFromClass(view.class),
                             NSStringFromCGRect(f), bgAlpha, img]];
        }
        if (depth >= 10) continue;
        for (UIView *sub in view.subviews) {
            [queue addObject:sub];
            [depths addObject:@(depth + 1)];
        }
    }

    M27WriteStatus(@"album_tree", @{
        @"vc": NSStringFromClass(vc.class),
        @"view": NSStringFromCGRect(vc.view.bounds),
        @"safe_top": @((double)vc.view.safeAreaInsets.top),
        @"rows": @((long)rows.count),
        @"tree": rows.count ? [rows componentsJoinedByString:@" "] : @"none",
    });
}

%hook UIViewController

// "The red buttons do appear for a second sometimes, and then disappear."
//
// Of course they do: the install ran on viewDidAppear, and then hopped to the
// next runloop turn via dispatch_async. By then the stock row has been on screen
// for several frames. Hiding it is a layout-time job, not an after-the-fact one.
//
// viewWillAppear runs before the screen is shown and synchronously, so the stock
// row is hidden in the same pass that reveals the page. viewDidAppear stays as a
// backstop for the case where the header was not laid out yet and the lookup
// found nothing to hide.
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    if (!M27IsAlbumDetailController(self)) return;
    if (!M27InstallAlbumControls(self)) M27RetryAlbumInstall(self);
    M27ApplyFullBleed(self);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (!M27IsAlbumDetailController(self)) return;
    // Unconditional — not behind the prefs check. If the tweak is switched off
    // while an album page is open, the button we hid still has to come back.
    M27SetNavDownloadHidden(self, NO);
    M27RestoreFullBleed(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    if (!M27IsAlbumDetailController(self)) return;
    M27InstallAlbumControls(self);
    M27ApplyFullBleed(self);

    // Measure after the header has had time to build itself. At viewDidAppear
    // the artwork is often not there yet — the same asynchrony that made the
    // stock buttons flash — and a dump of a half-built page is what sent the
    // full-player work down two wrong paths.
    __weak UIViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong UIViewController *strongSelf = weakSelf;
        if (strongSelf && strongSelf.isViewLoaded && strongSelf.view.window) {
            M27ReportAlbumTree(strongSelf);
        }
    });

    // SAMPLE THE NAV BAR TWICE, BECAUSE THE THING WE ARE CHASING IS A CHANGE.
    //
    // "It still has the flashing of the button problem." The download control
    // in the header is accounted for — 1.1.52 closed that gap from ~1.2s
    // average to ~0.3s, measured. What is left is the red button at the *top*,
    // which is in the navigation bar and therefore not in `vc.view` at all.
    //
    // A single sample cannot show a flash. Two, either side of the moment the
    // header finishes building, show whether the item goes away on its own —
    // and if it does, which of the three it was.
    for (NSNumber *delay in @[ @0.05, @1.5 ]) {
        double seconds = delay.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong UIViewController *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isViewLoaded || !strongSelf.view.window) return;
            M27WriteStatus(@"album_nav", @{
                @"at": [NSString stringWithFormat:@"%.2fs", seconds],
                @"right": M27DescribeBarItems(strongSelf.navigationItem.rightBarButtonItems),
                @"left": M27DescribeBarItems(strongSelf.navigationItem.leftBarButtonItems),
            });
        });
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    if (!M27IsAlbumDetailController(self)) return;

    // FIRST INSTALL BELONGS HERE, and this is why the stock buttons still flash.
    //
    // 1.1.38 moved the install to viewWillAppear to beat the flash, and
    // status.log answered with `album_lookup_failed play=nil shuffle=nil`: at
    // viewWillAppear those buttons do not exist yet, so there was nothing to
    // hide and the first real install still happened on viewDidAppear — after
    // the page is on screen.
    //
    // Layout is the first moment the stock row exists, and it runs before the
    // frame is presented. The old guard here refused to install unless a row was
    // already present, which guaranteed the late path won every time.
    M27InstallAlbumControls(self);
    M27ApplyFullBleed(self);
}

%end

/// Music's collection view resets the artwork layout after the view
/// controller's pass. Re-apply the content-space transform here — not a
/// window-space frame, which is what sat behind the original UI in 1.1.58.
%hook UIView

- (void)layoutSubviews {
    %orig;
    if (gM27BleedReentry) return;
    if (!objc_getAssociatedObject(self, kM27ArtBleedViewKey)) return;
    gM27BleedReentry = YES;
    M27PinArtwork(self, nil);
    M27FillArtworkSubtree(self, 0);
    gM27BleedReentry = NO;
}

%end

%hook UICollectionView

- (void)layoutSubviews {
    %orig;
    if (gM27BleedReentry) return;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    UIViewController *vc = M27AlbumPageControllerForView(self);
    if (!vc) return;
    M27ApplyFullBleed(vc);
}

%end

/// Cells recycle with Music's opaque black backgrounds. Clearing them only
/// at apply time left newly-appeared rows black and the plate hidden.
%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    if (gM27BleedReentry || !gM27BleedVC) return;
    UIView *page = gM27BleedVC.view;
    if (!page.window || self.window != page.window) return;
    UIView *cursor = self.superview;
    NSInteger hops = 0;
    BOOL onAlbum = NO;
    while (cursor && hops < 8) {
        if (cursor == page) { onAlbum = YES; break; }
        cursor = cursor.superview;
        hops++;
    }
    if (!onAlbum) return;
    gM27BleedReentry = YES;
    M27ClearOpaqueWalls(self, 0);
    gM27BleedReentry = NO;
}

%end
