#import "M27FloatingDock.h"
#import "M27GlassChrome.h"
#import "Music27.h"

static const CGFloat kM27DockSideInset = 18.0;
/// Collapsed capsule height. Matches the expanded mini pill rather than the
/// 58pt tab row: at 58 the collapsed capsules read as visibly fatter than the
/// pill they replace, which is the "gets fat when it collapses" complaint.
static const CGFloat kM27CollapsedPill = 52.0;
static const CGFloat kM27CollapsedGap = 8.0;
static const CGFloat kM27ExpandedMiniHeight = 52.0;
static const CGFloat kM27ExpandedTabHeight = 58.0;
static const CGFloat kM27ExpandedGap = 8.0;
static const CGFloat kM27CircleButton = 44.0;

@interface M27FloatingDock ()
/// Collapsed is THREE separate capsules, matching iOS 27: the tab affordance in
/// its own rounded square, the now-playing pill, and Search in a circle.
@property (nonatomic, strong) UIView *collapsedLeadingHost;
@property (nonatomic, strong) UIVisualEffectView *collapsedLeadingGlass;
@property (nonatomic, strong) UIView *collapsedTrailingHost;
@property (nonatomic, strong) UIVisualEffectView *collapsedTrailingGlass;
@property (nonatomic, strong) UIView *collapsedHost;
@property (nonatomic, strong) UIVisualEffectView *collapsedGlass;
@property (nonatomic, strong) UIButton *redButton;
@property (nonatomic, strong) UIImageView *collapsedArt;
@property (nonatomic, strong) UILabel *collapsedTitle;
@property (nonatomic, strong) UILabel *collapsedArtist;
@property (nonatomic, strong) UIButton *collapsedPlayPause;
@property (nonatomic, strong) UIButton *searchButton;

@property (nonatomic, strong) UIView *expandedHost;
@property (nonatomic, strong) UIVisualEffectView *miniGlass;
@property (nonatomic, strong) UIImageView *expandedArt;
@property (nonatomic, strong) UILabel *expandedTitle;
@property (nonatomic, strong) UILabel *expandedArtist;
@property (nonatomic, strong) UIButton *expandedPlayPause;
@property (nonatomic, strong) UIButton *expandedNext;
@property (nonatomic, strong) UIVisualEffectView *tabsGlass;
@property (nonatomic, strong) UIStackView *tabsStack;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
@end

@implementation M27FloatingDock

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        _mode = M27DockModeExpanded;
        _selectedTabIndex = 0;
        _tabButtons = [NSMutableArray array];
        [self buildCollapsed];
        [self buildExpanded];
        [self applyModeAnimated:NO];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(themeChanged:)
                                                     name:M27ThemeDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Build

- (UIButton *)circleIconButtonWithSystemName:(NSString *)name
                                      tint:(UIColor *)tint
                                    target:(id)target
                                    action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:cfg];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = tint;
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    button.layer.cornerRadius = kM27CircleButton / 2.0;
    if (@available(iOS 13.0, *)) {
        button.layer.cornerCurve = kCACornerCurveContinuous;
    }
    button.clipsToBounds = YES;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildCollapsed {
    // Leading capsule: the tab affordance on its own.
    _collapsedLeadingHost = [[UIView alloc] initWithFrame:CGRectZero];
    _collapsedLeadingHost.backgroundColor = UIColor.clearColor;
    [M27GlassChrome addSoftShadowToHost:_collapsedLeadingHost];
    [self addSubview:_collapsedLeadingHost];

    _collapsedLeadingGlass = [M27GlassChrome pillWithCornerRadius:kM27CollapsedPill / 2.0];
    [_collapsedLeadingHost addSubview:_collapsedLeadingGlass];

    // A house, tinted, sitting in the glass — not a music-note list on a solid
    // red tile. The reference shot is unambiguous about this one.
    _redButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _redButton.backgroundColor = UIColor.clearColor;
    _redButton.tintColor = [UIColor colorWithRed:0.98 green:0.24 blue:0.35 alpha:1.0];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    [_redButton setImage:[UIImage systemImageNamed:@"house.fill" withConfiguration:cfg]
                forState:UIControlStateNormal];
    [_redButton addTarget:self action:@selector(redTapped) forControlEvents:UIControlEventTouchUpInside];
    [_collapsedLeadingGlass.contentView addSubview:_redButton];

    // Centre capsule: the now-playing pill.
    _collapsedHost = [[UIView alloc] initWithFrame:CGRectZero];
    _collapsedHost.backgroundColor = UIColor.clearColor;
    [M27GlassChrome addSoftShadowToHost:_collapsedHost];
    [self addSubview:_collapsedHost];

    _collapsedGlass = [M27GlassChrome pillWithCornerRadius:kM27CollapsedPill / 2.0];
    [_collapsedHost addSubview:_collapsedGlass];

    _collapsedArt = [UIImageView new];
    _collapsedArt.contentMode = UIViewContentModeScaleAspectFill;
    _collapsedArt.clipsToBounds = YES;
    _collapsedArt.layer.cornerRadius = 8.0;
    if (@available(iOS 13.0, *)) {
        _collapsedArt.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _collapsedArt.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.25];
    // No tap gesture here. The pill's own hit-testing decides between keeping
    // the touch and declining it to Music (see pointInside:), and a gesture on
    // the artwork would swallow it before that choice is ever made.
    _collapsedArt.userInteractionEnabled = NO;
    [_collapsedGlass.contentView addSubview:_collapsedArt];

    _collapsedTitle = [UILabel new];
    _collapsedTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _collapsedTitle.textColor = UIColor.labelColor;
    _collapsedTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    _collapsedTitle.userInteractionEnabled = NO;
    [_collapsedGlass.contentView addSubview:_collapsedTitle];

    _collapsedArtist = [UILabel new];
    _collapsedArtist.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _collapsedArtist.textColor = UIColor.secondaryLabelColor;
    _collapsedArtist.lineBreakMode = NSLineBreakByTruncatingTail;
    _collapsedArtist.userInteractionEnabled = NO;
    [_collapsedGlass.contentView addSubview:_collapsedArtist];

    _collapsedPlayPause = [self circleIconButtonWithSystemName:@"pause.fill"
                                                          tint:UIColor.labelColor
                                                        target:self
                                                        action:@selector(playPauseTapped)];
    _collapsedPlayPause.backgroundColor = UIColor.clearColor;
    [_collapsedGlass.contentView addSubview:_collapsedPlayPause];

    // Trailing capsule: Search on its own.
    _collapsedTrailingHost = [[UIView alloc] initWithFrame:CGRectZero];
    _collapsedTrailingHost.backgroundColor = UIColor.clearColor;
    [M27GlassChrome addSoftShadowToHost:_collapsedTrailingHost];
    [self addSubview:_collapsedTrailingHost];

    _collapsedTrailingGlass = [M27GlassChrome pillWithCornerRadius:kM27CollapsedPill / 2.0];
    [_collapsedTrailingHost addSubview:_collapsedTrailingGlass];

    _searchButton = [self circleIconButtonWithSystemName:@"magnifyingglass"
                                                    tint:UIColor.labelColor
                                                  target:self
                                                  action:@selector(searchTapped)];
    _searchButton.backgroundColor = UIColor.clearColor;
    [_collapsedTrailingGlass.contentView addSubview:_searchButton];
}

- (void)buildExpanded {
    _expandedHost = [[UIView alloc] initWithFrame:CGRectZero];
    _expandedHost.backgroundColor = UIColor.clearColor;
    [self addSubview:_expandedHost];

    _miniGlass = [M27GlassChrome pillWithCornerRadius:22.0];
    UIView *miniHost = [[UIView alloc] initWithFrame:CGRectZero];
    miniHost.tag = 0x4D324D48; // 'M2MH'
    miniHost.backgroundColor = UIColor.clearColor;
    // The whole pill opens Now Playing. Previously only the 36pt artwork and
    // the title label carried the gesture, so most of the pill was dead — and
    // status.log proved it: not a single nowplaying_* line was ever written,
    // meaning the delegate was never reached. The play/pause and next buttons
    // are UIControl subviews, so they still win the hit test over this.
    miniHost.userInteractionEnabled = YES;
    [miniHost addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nowPlayingTapped)]];
    [M27GlassChrome addSoftShadowToHost:miniHost];
    [miniHost addSubview:_miniGlass];
    [_expandedHost addSubview:miniHost];

    _expandedArt = [UIImageView new];
    _expandedArt.contentMode = UIViewContentModeScaleAspectFill;
    _expandedArt.clipsToBounds = YES;
    _expandedArt.layer.cornerRadius = 8.0;
    if (@available(iOS 13.0, *)) {
        _expandedArt.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _expandedArt.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.25];
    _expandedArt.userInteractionEnabled = YES;
    [_expandedArt addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nowPlayingTapped)]];
    [_miniGlass.contentView addSubview:_expandedArt];

    _expandedTitle = [UILabel new];
    _expandedTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _expandedTitle.textColor = UIColor.labelColor;
    _expandedTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    _expandedTitle.userInteractionEnabled = YES;
    [_expandedTitle addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nowPlayingTapped)]];
    [_miniGlass.contentView addSubview:_expandedTitle];

    _expandedArtist = [UILabel new];
    _expandedArtist.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _expandedArtist.textColor = UIColor.secondaryLabelColor;
    _expandedArtist.lineBreakMode = NSLineBreakByTruncatingTail;
    _expandedArtist.userInteractionEnabled = NO; // falls through to miniHost
    [_miniGlass.contentView addSubview:_expandedArtist];

    _expandedPlayPause = [self circleIconButtonWithSystemName:@"pause.fill"
                                                         tint:UIColor.labelColor
                                                       target:self
                                                       action:@selector(playPauseTapped)];
    _expandedPlayPause.backgroundColor = UIColor.clearColor;
    [_miniGlass.contentView addSubview:_expandedPlayPause];

    _expandedNext = [self circleIconButtonWithSystemName:@"forward.fill"
                                                    tint:UIColor.labelColor
                                                  target:self
                                                  action:@selector(nextTapped)];
    _expandedNext.backgroundColor = UIColor.clearColor;
    [_miniGlass.contentView addSubview:_expandedNext];

    _tabsGlass = [M27GlassChrome pillWithCornerRadius:28.0];
    UIView *tabsHost = [[UIView alloc] initWithFrame:CGRectZero];
    tabsHost.tag = 0x4D325448; // 'M2TH'
    tabsHost.backgroundColor = UIColor.clearColor;
    [M27GlassChrome addSoftShadowToHost:tabsHost];
    [tabsHost addSubview:_tabsGlass];
    [_expandedHost addSubview:tabsHost];

    _tabsStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _tabsStack.axis = UILayoutConstraintAxisHorizontal;
    _tabsStack.distribution = UIStackViewDistributionFillEqually;
    _tabsStack.alignment = UIStackViewAlignmentCenter;
    [_tabsGlass.contentView addSubview:_tabsStack];
}

#pragma mark - Public

- (CGFloat)preferredHeight {
    if (!self.hasTrack) {
        // Tab row only — no pill, so no pill height and no gap.
        return kM27ExpandedTabHeight;
    }
    // COLLAPSED KEEPS THE EXPANDED HEIGHT ON PURPOSE.
    //
    // The strip is pinned to the bottom of the screen, so a shorter dock sits
    // lower. Collapsing used to drop the pill from screen 660-712 to 714-778,
    // and Music's own mini player is at 665-729 — which left 15pt of overlap
    // and no way for a tap to reach it. That is why tapping the collapsed
    // artwork could not open the player while the expanded pill could.
    //
    // Holding the height keeps the collapsed capsules at the same y as the
    // expanded pill, where they overlap the mini player by ~47pt. The space
    // below them is empty and passes touches through, which costs nothing.
    return kM27ExpandedMiniHeight + kM27ExpandedGap + kM27ExpandedTabHeight;
}

- (void)setMode:(M27DockMode)mode {
    [self setMode:mode animated:NO];
}

- (void)setMode:(M27DockMode)mode animated:(BOOL)animated {
    if (_mode == mode && self.collapsedHost.alpha > 0.5 == (mode == M27DockModeCollapsed)) {
        [self setNeedsLayout];
        return;
    }
    _mode = mode;
    [self applyModeAnimated:animated];
    if ([self.delegate respondsToSelector:@selector(floatingDockDidChangeMode:)]) {
        [self.delegate floatingDockDidChangeMode:self];
    }
}

- (void)collapseFromScroll {
    if (self.mode == M27DockModeCollapsed) return;
    // Collapsing trades the tab row for a now-playing pill. With nothing
    // playing that trade leaves an empty pill and no tabs, so refuse it.
    if (!self.hasTrack) return;
    [self setMode:M27DockModeCollapsed animated:YES];
}

- (void)expandFromRedButton {
    if (self.mode == M27DockModeExpanded) return;
    [self setMode:M27DockModeExpanded animated:YES];
}

- (void)setSelectedTabIndex:(NSInteger)selectedTabIndex {
    _selectedTabIndex = selectedTabIndex;
    [self updateTabSelection];
}

- (void)setArtwork:(UIImage *)artwork {
    _artwork = artwork;
    self.collapsedArt.image = artwork;
    self.expandedArt.image = artwork;
}

- (void)setTrackTitle:(NSString *)trackTitle {
    _trackTitle = [trackTitle copy];
    // No "Not Playing" fallback any more. When nothing is playing the pill is
    // removed entirely (see setHasTrack:), so a placeholder string here would
    // only ever be visible for the frame before that happens.
    self.collapsedTitle.text = trackTitle ?: @"";
    self.expandedTitle.text = trackTitle ?: @"";
}

- (void)setHasTrack:(BOOL)hasTrack {
    if (_hasTrack == hasTrack) return;
    _hasTrack = hasTrack;

    // Collapsing exists to make room for the now-playing pill. With no track
    // there is nothing to collapse to, so stay expanded — otherwise a scroll
    // would shrink the dock to a pill showing nothing.
    if (!hasTrack && self.mode == M27DockModeCollapsed) {
        [self setMode:M27DockModeExpanded animated:YES];
    }

    [self setNeedsLayout];
    // preferredHeight just changed, so the overlay strip has to be resized. The
    // mode delegate is the existing "my height moved" signal.
    if ([self.delegate respondsToSelector:@selector(floatingDockDidChangeMode:)]) {
        [self.delegate floatingDockDidChangeMode:self];
    }
}

- (void)setArtistName:(NSString *)artistName {
    _artistName = [artistName copy];
    self.collapsedArtist.text = artistName ?: @"";
    self.expandedArtist.text = artistName ?: @"";
}

- (void)setPlaying:(BOOL)playing {
    _playing = playing;
    NSString *name = playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:cfg];
    [self.collapsedPlayPause setImage:image forState:UIControlStateNormal];
    [self.expandedPlayPause setImage:image forState:UIControlStateNormal];
}

- (void)reloadTabs {
    for (UIView *view in self.tabsStack.arrangedSubviews) {
        [self.tabsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.tabButtons removeAllObjects];

    NSInteger count = 5;
    if ([self.delegate respondsToSelector:@selector(numberOfTabsForFloatingDock:)]) {
        count = MAX(1, [self.delegate numberOfTabsForFloatingDock:self]);
    }

    static NSArray<NSString *> *fallbackIcons;
    static NSArray<NSString *> *fallbackTitles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fallbackIcons = @[ @"play.circle", @"square.grid.2x2", @"dot.radiowaves.left.and.right",
                           @"music.note.list", @"magnifyingglass" ];
        fallbackTitles = @[ @"Listen Now", @"Browse", @"Radio", @"Library", @"Search" ];
    });

    for (NSInteger i = 0; i < count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = i;
        button.tintColor = UIColor.secondaryLabelColor;

        NSString *title = nil;
        if ([self.delegate respondsToSelector:@selector(floatingDock:titleForTabIndex:)]) {
            title = [self.delegate floatingDock:self titleForTabIndex:i];
        }
        if (!title) {
            title = i < (NSInteger)fallbackTitles.count ? fallbackTitles[i] : [NSString stringWithFormat:@"Tab %ld", (long)i];
        }

        UIImage *icon = nil;
        if ([self.delegate respondsToSelector:@selector(floatingDock:iconForTabIndex:selected:)]) {
            icon = [self.delegate floatingDock:self iconForTabIndex:i selected:(i == self.selectedTabIndex)];
        }
        if (!icon) {
            NSString *sys = i < (NSInteger)fallbackIcons.count ? fallbackIcons[i] : @"circle";
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
            icon = [UIImage systemImageNamed:sys withConfiguration:cfg];
        }

        // UIButtonConfiguration keeps icon-above-title stable (old edgeInsets often
        // collapsed to an empty tabs pill — stock Music tabs stayed visible alone).
        if (@available(iOS 15.0, *)) {
            UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
            config.image = icon;
            config.title = title;
            config.imagePlacement = NSDirectionalRectEdgeTop;
            config.imagePadding = 2.0;
            config.baseForegroundColor = UIColor.secondaryLabelColor;
            UIFont *font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
            config.titleTextAttributesTransformer =
                ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
                    NSMutableDictionary *out = [incoming mutableCopy] ?: [NSMutableDictionary dictionary];
                    out[NSFontAttributeName] = font;
                    return out;
                };
            config.contentInsets = NSDirectionalEdgeInsetsMake(4, 2, 4, 2);
            button.configuration = config;
        } else {
            [button setImage:icon forState:UIControlStateNormal];
            [button setTitle:title forState:UIControlStateNormal];
            [button setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
            button.titleLabel.numberOfLines = 1;
            button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        }
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.tabsStack addArrangedSubview:button];
        [self.tabButtons addObject:button];
    }
    [self updateTabSelection];
    [self setNeedsLayout];
}

- (void)refreshChrome {
    [M27GlassChrome applyPaletteTintToGlass:self.collapsedGlass];
    [M27GlassChrome applyPaletteTintToGlass:self.miniGlass];
    [M27GlassChrome applyPaletteTintToGlass:self.tabsGlass];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat side = kM27DockSideInset;

    // Collapsed: three capsules, parked between the two extremes.
    //
    // 1.1.46 put this row at y = 0 (screen 660-712) so it overlapped Music's
    // hidden mini player and a tap could be handed over — but it read as
    // floating far too high. 1.1.47 dropped it to the tab slot (720-778), which
    // looked right and left only ~3pt of overlap, so the tap died.
    //
    // Neither end is necessary. Music's mini player sits at 667-723 and the dock
    // spans 660-778, so y = 30 puts this row at screen 690-742: 33pt of overlap,
    // comfortably tappable, and visually centred between the mini pill's old
    // position and the tab row's. Both requirements fit; they just could not be
    // met at either extreme.
    CGFloat pillH = kM27CollapsedPill;   // 52, not the 58 tab height — see below
    CGFloat rowY = 30.0;
    CGFloat capsule = pillH;

    self.collapsedLeadingHost.frame = CGRectMake(side, rowY, capsule, pillH);
    self.collapsedLeadingGlass.frame = self.collapsedLeadingHost.bounds;
    [M27GlassChrome applyPaletteTintToGlass:self.collapsedLeadingGlass];
    CGFloat redSide = kM27CircleButton;
    self.redButton.frame = CGRectMake((capsule - redSide) / 2.0, (pillH - redSide) / 2.0,
                                      redSide, redSide);

    CGFloat trailingX = width - side - capsule;
    self.collapsedTrailingHost.frame = CGRectMake(trailingX, rowY, capsule, pillH);
    self.collapsedTrailingGlass.frame = self.collapsedTrailingHost.bounds;
    [M27GlassChrome applyPaletteTintToGlass:self.collapsedTrailingGlass];
    self.searchButton.frame = CGRectMake((capsule - kM27CircleButton) / 2.0,
                                         (pillH - kM27CircleButton) / 2.0,
                                         kM27CircleButton, kM27CircleButton);

    CGFloat centreX = side + capsule + kM27CollapsedGap;
    CGFloat centreW = MAX(0, trailingX - kM27CollapsedGap - centreX);
    self.collapsedHost.frame = CGRectMake(centreX, rowY, centreW, pillH);
    self.collapsedGlass.frame = self.collapsedHost.bounds;
    [M27GlassChrome applyPaletteTintToGlass:self.collapsedGlass];

    CGFloat pad = 8.0;
    CGFloat art = 40.0;
    CGFloat artY = (pillH - art) / 2.0;
    self.collapsedArt.frame = CGRectMake(pad, artY, art, art);

    CGFloat playW = 36.0;
    CGFloat playX = MAX(0, centreW - pad - playW);
    self.collapsedPlayPause.frame = CGRectMake(playX, (pillH - playW) / 2.0, playW, playW);

    CGFloat textX = CGRectGetMaxX(self.collapsedArt.frame) + 9.0;
    CGFloat textW = MAX(0, playX - 6.0 - textX);
    self.collapsedTitle.frame = CGRectMake(textX, artY + 3.0, textW, 16.0);
    self.collapsedArtist.frame = CGRectMake(textX, artY + 20.0, textW, 14.0);

    // Expanded
    CGFloat expandedH = self.preferredHeight;
    self.expandedHost.frame = CGRectMake(0, 0, width, expandedH);

    UIView *miniHost = [self.expandedHost viewWithTag:0x4D324D48];
    UIView *tabsHost = [self.expandedHost viewWithTag:0x4D325448];

    // Nothing playing: drop the pill and pull the tabs up to fill the strip.
    // `hidden`, not alpha — this view must not hit-test either, and the pill
    // carries the Now Playing tap.
    BOOL showMini = self.hasTrack;
    miniHost.hidden = !showMini;
    CGFloat tabsY = showMini ? (kM27ExpandedMiniHeight + kM27ExpandedGap) : 0.0;

    miniHost.frame = CGRectMake(side, 0, width - side * 2.0, kM27ExpandedMiniHeight);
    self.miniGlass.frame = miniHost.bounds;
    [M27GlassChrome applyPaletteTintToGlass:self.miniGlass];

    tabsHost.frame = CGRectMake(side, tabsY,
                                width - side * 2.0, kM27ExpandedTabHeight);
    self.tabsGlass.frame = tabsHost.bounds;
    [M27GlassChrome applyPaletteTintToGlass:self.tabsGlass];
    self.tabsStack.frame = CGRectInset(self.tabsGlass.contentView.bounds, 4.0, 4.0);

    CGFloat eArt = 36.0;
    CGFloat ePad = 10.0;
    CGFloat eArtY = (kM27ExpandedMiniHeight - eArt) / 2.0;
    self.expandedArt.frame = CGRectMake(ePad, eArtY, eArt, eArt);
    CGFloat eBtn = 34.0;
    CGFloat nextX = CGRectGetWidth(self.miniGlass.bounds) - ePad - eBtn;
    self.expandedNext.frame =
        CGRectMake(nextX, (kM27ExpandedMiniHeight - eBtn) / 2.0, eBtn, eBtn);
    self.expandedPlayPause.frame =
        CGRectMake(nextX - eBtn - 2.0, (kM27ExpandedMiniHeight - eBtn) / 2.0, eBtn, eBtn);
    CGFloat eTextX = CGRectGetMaxX(self.expandedArt.frame) + 8.0;
    CGFloat eTextW = MAX(0, CGRectGetMinX(self.expandedPlayPause.frame) - 8.0 - eTextX);
    self.expandedTitle.frame = CGRectMake(eTextX, eArtY + 1.0, eTextW, 16.0);
    self.expandedArtist.frame = CGRectMake(eTextX, eArtY + 18.0, eTextW, 14.0);
}

- (void)applyModeAnimated:(BOOL)animated {
    BOOL collapsed = (self.mode == M27DockModeCollapsed);
    NSArray<UIView *> *collapsedHosts = @[ self.collapsedLeadingHost ?: [UIView new],
                                           self.collapsedHost ?: [UIView new],
                                           self.collapsedTrailingHost ?: [UIView new] ];
    void (^changes)(void) = ^{
        for (UIView *host in collapsedHosts) {
            host.alpha = collapsed ? 1.0 : 0.0;
            host.transform = collapsed ? CGAffineTransformIdentity
                                       : CGAffineTransformMakeScale(0.96, 0.96);
            host.userInteractionEnabled = collapsed;
        }
        self.expandedHost.alpha = collapsed ? 0.0 : 1.0;
        self.expandedHost.transform = collapsed ? CGAffineTransformMakeScale(0.96, 0.96)
                                                : CGAffineTransformIdentity;
        self.expandedHost.userInteractionEnabled = !collapsed;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.38
                              delay:0
             usingSpringWithDamping:0.86
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)updateTabSelection {
    UIColor *active = [UIColor colorWithRed:0.98 green:0.18 blue:0.30 alpha:1.0];
    UIColor *inactive = UIColor.secondaryLabelColor;
    for (UIButton *button in self.tabButtons) {
        BOOL selected = (button.tag == self.selectedTabIndex);
        UIColor *color = selected ? active : inactive;
        button.tintColor = color;
        if (@available(iOS 15.0, *)) {
            UIButtonConfiguration *config = button.configuration;
            if (config) {
                config.baseForegroundColor = color;
                button.configuration = config;
            }
        } else {
            [button setTitleColor:color forState:UIControlStateNormal];
        }
        if (selected) {
            button.backgroundColor = [active colorWithAlphaComponent:0.12];
            button.layer.cornerRadius = 16.0;
            if (@available(iOS 13.0, *)) {
                button.layer.cornerCurve = kCACornerCurveContinuous;
            }
        } else {
            button.backgroundColor = UIColor.clearColor;
        }
    }
}

#pragma mark - Actions

- (void)redTapped {
    [self expandFromRedButton];
}

- (void)searchTapped {
    if ([self.delegate respondsToSelector:@selector(floatingDockDidTapSearch:)]) {
        [self.delegate floatingDockDidTapSearch:self];
    }
}

- (void)playPauseTapped {
    if ([self.delegate respondsToSelector:@selector(floatingDockDidTapPlayPause:)]) {
        [self.delegate floatingDockDidTapPlayPause:self];
    }
}

- (void)nextTapped {
    if ([self.delegate respondsToSelector:@selector(floatingDockDidTapNext:)]) {
        [self.delegate floatingDockDidTapNext:self];
    }
}

- (void)nowPlayingTapped {
    // No collapsed special case any more. At y = 30 the row overlaps Music's
    // mini player by ~33pt in both modes, so the passthrough hands the touch
    // over and this is only reached when a tap misses the mini player outright.
    if ([self.delegate respondsToSelector:@selector(floatingDockDidTapNowPlaying:)]) {
        [self.delegate floatingDockDidTapNowPlaying:self];
    }
}

- (void)tabTapped:(UIButton *)sender {
    self.selectedTabIndex = sender.tag;
    if ([self.delegate respondsToSelector:@selector(floatingDock:didSelectTabIndex:)]) {
        [self.delegate floatingDock:self didSelectTabIndex:sender.tag];
    }
}

- (void)themeChanged:(NSNotification *)note {
    (void)note;
    [self refreshChrome];
}

#pragma mark - Hit testing

/// Is `point` on one of the dock's own buttons? Those always win.
- (BOOL)m27PointOnOwnControl:(CGPoint)point {
    NSArray<UIButton *> *buttons = (self.mode == M27DockModeCollapsed)
        ? @[ self.redButton ?: (UIButton *)NSNull.null,
             self.collapsedPlayPause ?: (UIButton *)NSNull.null,
             self.searchButton ?: (UIButton *)NSNull.null ]
        : @[ self.expandedPlayPause ?: (UIButton *)NSNull.null,
             self.expandedNext ?: (UIButton *)NSNull.null ];

    for (UIButton *button in buttons) {
        if (![button isKindOfClass:UIButton.class]) continue;
        if (button.hidden || !button.isEnabled) continue;
        CGPoint p = [self convertPoint:point toView:button];
        // Generous: these are small circles and a near miss should still be a
        // press rather than falling through to Music.
        if (CGRectContainsPoint(CGRectInset(button.bounds, -6.0, -6.0), p)) return YES;
    }
    return NO;
}

/// The pill body opens the full player, and only Music can do that.
- (BOOL)m27ShouldPassThrough:(CGPoint)point {
    if (![self.delegate respondsToSelector:@selector(floatingDock:shouldPassThroughPoint:)]) {
        return NO;
    }
    return [self.delegate floatingDock:self shouldPassThroughPoint:point];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // Full-width host frame is taller/wider than the glass pills. Only the
    // visible chrome should capture touches so Library content under the
    // clear regions stays tappable.
    if (self.mode == M27DockModeCollapsed) {
        if (!self.collapsedHost.userInteractionEnabled || self.collapsedHost.alpha <= 0.01) {
            return NO;
        }
        // The two end capsules are entirely ours — never pass those through.
        for (UIView *capsule in @[ self.collapsedLeadingHost ?: [UIView new],
                                   self.collapsedTrailingHost ?: [UIView new] ]) {
            CGPoint p = [self convertPoint:point toView:capsule];
            if ([capsule pointInside:p withEvent:event]) return YES;
        }
        CGPoint p = [self convertPoint:point toView:self.collapsedHost];
        if ([self.collapsedHost pointInside:p withEvent:event]) {
            if ([self m27PointOnOwnControl:point]) return YES;
            // Artwork and titles: hand the touch to Music's mini player, which
            // the pill now sits over in this mode too.
            return ![self m27ShouldPassThrough:point];
        }
        return NO;
    }
    if (self.expandedHost.userInteractionEnabled && self.expandedHost.alpha > 0.01) {
        UIView *miniHost = [self.expandedHost viewWithTag:0x4D324D48];
        UIView *tabsHost = [self.expandedHost viewWithTag:0x4D325448];
        if (miniHost && !miniHost.hidden) {
            CGPoint p = [self convertPoint:point toView:miniHost];
            if ([miniHost pointInside:p withEvent:event]) {
                if ([self m27PointOnOwnControl:point]) return YES;
                return ![self m27ShouldPassThrough:point];
            }
        }
        // The tab row is entirely ours — never pass those through, or a tap
        // would reach Music's real tab bar underneath and switch tabs twice.
        if (tabsHost) {
            CGPoint p = [self convertPoint:point toView:tabsHost];
            if ([tabsHost pointInside:p withEvent:event]) return YES;
        }
    }
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.userInteractionEnabled || self.hidden || self.alpha < 0.01) return nil;
    if (![self pointInside:point withEvent:event]) return nil;
    return [super hitTest:point withEvent:event];
}

@end
