#import "Music27.h"
#import "M27GlassChrome.h"
#import <objc/runtime.h>

// Restyles album / playlist detail Play|Shuffle into the iOS 27 row:
//   [ Shuffle circle ]  [ Play pill ]  [ Download circle ]

static const NSInteger kM27AlbumControlsTag = 0x4D324143; // 'M2AC'
static const CGFloat kM27Circle = 52.0;
static const CGFloat kM27PlayHeight = 52.0;

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

static UIView *M27FindDownloadControl(UIViewController *vc) {
    // Prefer nav-bar download; fall back to hierarchy search.
    for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems ?: @[]) {
        UIView *view = [item valueForKey:@"view"];
        if (!view) continue;
        NSString *desc = view.description.lowercaseString;
        if ([desc containsString:@"download"] || [desc containsString:@"arrow.down"]) {
            return view;
        }
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:UIImageView.class] || [sub isKindOfClass:UIButton.class]) {
                return view;
            }
        }
    }
    UIView *byTitle = M27FindControlWithTitle(vc.view, @[ @"download" ], NO, 0);
    if (byTitle) return byTitle;

    // 1.1.31 logged `download=nil`: neither the nav-bar scan nor the title
    // search finds it on 17.3. Play and Shuffle both resolve to
    // MusicCoreUI.SymbolButton, so search the nav bar for a UIControl whose
    // accessibility label reads like a download action.
    return M27FindDownloadByAccessibility(vc.navigationController.navigationBar ?: vc.view, 0);
}

/// Compact description for status.log — class plus frame. Defined below.
static NSString *M27DescribeControl(UIView *view);

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
        [_shuffleButton setImage:[UIImage systemImageNamed:@"shuffle" withConfiguration:cfg]
                        forState:UIControlStateNormal];
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
        [_downloadButton setImage:[UIImage systemImageNamed:@"arrow.down" withConfiguration:cfg]
                         forState:UIControlStateNormal];
        _downloadButton.tintColor = UIColor.labelColor;
        [_downloadButton addTarget:self action:@selector(downloadTapped)
                  forControlEvents:UIControlEventTouchUpInside];
        [_downloadGlass.contentView addSubview:_downloadButton];
    }
    return self;
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
}

- (void)shuffleTapped { M27FireControl(self.stockShuffle); }
- (void)playTapped { M27FireControl(self.stockPlay); }
- (void)downloadTapped { M27FireControl(self.stockDownload); }

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
    // layer.opacity, not alpha: alpha < 0.01 makes a view un-hit-testable, and
    // M27FireControl may need to reach it. Same trap the dock hit in 1.1.28.
    view.layer.opacity = 0.0;
    return nil;
}

static NSString *M27DescribeControl(UIView *view) {
    if (!view) return @"nil";
    return [NSString stringWithFormat:@"%@%@", NSStringFromClass(view.class),
            NSStringFromCGRect(view.frame)];
}

static void M27InstallAlbumControls(UIViewController *vc) {
    M27Prefs *prefs = M27Prefs.shared;
    // May live in vc.view (older builds) or in the stock controls' superview.
    UIView *existing = [vc.view viewWithTag:kM27AlbumControlsTag];

    if (!(prefs.enabled && prefs.glassTabBarEnabled)) {
        [existing removeFromSuperview];
        return;
    }
    if (!M27IsAlbumDetailController(vc)) {
        [existing removeFromSuperview];
        return;
    }

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
        return;
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
    row.stockDownload = download;
    row.frame = CGRectMake(minX, top, maxX - minX, kM27PlayHeight);
    [host bringSubviewToFront:row];

    M27WriteStatus(@"album_row_placed", @{
        @"host": NSStringFromClass(host.class),
        @"row": NSStringFromCGRect(row.frame),
        @"span": NSStringFromCGRect(span),
        @"sibling_of_hidden_row": stockRow ? @"yes" : @"no",
    });
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    if (!M27IsAlbumDetailController(self)) return;
    __weak UIViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        M27InstallAlbumControls(weakSelf);
    });
}

- (void)viewDidLayoutSubviews {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.glassTabBarEnabled)) return;
    // Only refresh an already-installed row during layout — never first-install here.
    if ([self.view viewWithTag:kM27AlbumControlsTag]) {
        M27InstallAlbumControls(self);
    }
}

%end
