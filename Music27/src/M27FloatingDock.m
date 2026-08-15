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

@interface M27FloatingDock () <UIGestureRecognizerDelegate>
/// Collapsed is THREE separate capsules, matching iOS 27: the tab affordance in
/// its own rounded square, the now-playing pill, and Search in a circle.
@property (nonatomic, strong) UIView *collapsedLeadingHost;
@property (nonatomic, strong) UIVisualEffectView *collapsedLeadingGlass;
@property (nonatomic, strong) UIView *collapsedTrailingHost;
@property (nonatomic, strong) UIVisualEffectView *collapsedTrailingGlass;
@property (nonatomic, strong) UIView *collapsedHost;
@property (nonatomic, strong) UIVisualEffectView *collapsedGlass;
@property (nonatomic, strong) UIButton *redButton;
@property (nonatomic, strong) UIView *collapsedClip;
@property (nonatomic, strong) UIView *collapsedCurrentStack;
@property (nonatomic, strong) UIView *collapsedIncomingStack;
@property (nonatomic, strong) UIImageView *collapsedArt;
@property (nonatomic, strong) UILabel *collapsedTitle;
@property (nonatomic, strong) UILabel *collapsedArtist;
@property (nonatomic, strong) UIImageView *collapsedIncomingArt;
@property (nonatomic, strong) UILabel *collapsedIncomingTitle;
@property (nonatomic, strong) UILabel *collapsedIncomingArtist;
@property (nonatomic, strong) UIButton *collapsedPlayPause;
@property (nonatomic, strong) UIButton *searchButton;

@property (nonatomic, strong) UIView *expandedHost;
@property (nonatomic, strong) UIVisualEffectView *miniGlass;
@property (nonatomic, strong) UIView *expandedClip;
@property (nonatomic, strong) UIView *expandedCurrentStack;
@property (nonatomic, strong) UIView *expandedIncomingStack;
@property (nonatomic, strong) UIImageView *expandedArt;
@property (nonatomic, strong) UILabel *expandedTitle;
@property (nonatomic, strong) UILabel *expandedArtist;
@property (nonatomic, strong) UIImageView *expandedIncomingArt;
@property (nonatomic, strong) UILabel *expandedIncomingTitle;
@property (nonatomic, strong) UILabel *expandedIncomingArtist;
@property (nonatomic, strong) UIButton *expandedPlayPause;
@property (nonatomic, strong) UIButton *expandedNext;
@property (nonatomic, strong) UIVisualEffectView *tabsGlass;
@property (nonatomic, strong) UIStackView *tabsStack;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;

@property (nonatomic, strong) UIPanGestureRecognizer *swipePan;
@property (nonatomic, assign) CGFloat swipeOffset;
@property (nonatomic, assign) NSInteger swipeDirection;
@property (nonatomic, assign) BOOL swipeActive;
@property (nonatomic, assign) BOOL swipeCommitted;
@property (nonatomic, copy, nullable) NSString *incomingTitle;
@property (nonatomic, copy, nullable) NSString *incomingArtist;
@property (nonatomic, strong, nullable) UIImage *incomingArtwork;
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
        [self installDockSwipePan];
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
    // 18pt, not 20. These buttons are laid out at 34pt in the mini pill, and
    // `forward.fill` is the widest symbol used here — two triangles side by
    // side, so it runs roughly 1.4x the width of `play.fill` at the same point
    // size. At 20pt semibold it overhangs a 34pt box.
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:cfg];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = tint;
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    button.layer.cornerRadius = kM27CircleButton / 2.0;
    if (@available(iOS 13.0, *)) {
        button.layer.cornerCurve = kCACornerCurveContinuous;
    }
    // NOT clipsToBounds. That is what cropped the skip glyph.
    //
    // The corner radius is kM27CircleButton / 2 = 22, and Core Animation clamps
    // a radius to half the shorter side — so on a 34pt button the mask is a
    // 34pt circle, and a wide symbol's outer tips fall outside it. The
    // translucent background is painted by the layer and is rounded by
    // cornerRadius with or without clipping, so turning clipping off costs the
    // shape nothing and stops the mask reaching the glyph.
    button.clipsToBounds = NO;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

/// Artwork + title + artist as one translating unit. The play/pause and skip
/// buttons stay outside the clip so they do not slide with the carousel.
- (UIView *)m27BuildTrackStackArt:(UIImageView * __strong *)artOut
                            title:(UILabel * __strong *)titleOut
                           artist:(UILabel * __strong *)artistOut {
    UIView *stack = [[UIView alloc] initWithFrame:CGRectZero];
    stack.userInteractionEnabled = NO;
    stack.clipsToBounds = YES;
    stack.backgroundColor = UIColor.clearColor;

    UIImageView *art = [UIImageView new];
    art.contentMode = UIViewContentModeScaleAspectFill;
    art.clipsToBounds = YES;
    art.layer.cornerRadius = 8.0;
    if (@available(iOS 13.0, *)) {
        art.layer.cornerCurve = kCACornerCurveContinuous;
    }
    art.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.25];
    art.userInteractionEnabled = NO;
    [stack addSubview:art];

    UILabel *title = [UILabel new];
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.userInteractionEnabled = NO;
    [stack addSubview:title];

    UILabel *artist = [UILabel new];
    artist.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    artist.textColor = UIColor.secondaryLabelColor;
    artist.lineBreakMode = NSLineBreakByTruncatingTail;
    artist.userInteractionEnabled = NO;
    [stack addSubview:artist];

    if (artOut) *artOut = art;
    if (titleOut) *titleOut = title;
    if (artistOut) *artistOut = artist;
    return stack;
}

- (void)m27LayoutTrackStack:(UIView *)stack
                        art:(UIImageView *)art
                      title:(UILabel *)title
                     artist:(UILabel *)artist
                    artSize:(CGFloat)artSize
                     height:(CGFloat)height
                    titleY0:(CGFloat)titleY0 {
    CGFloat width = CGRectGetWidth(stack.bounds);
    CGFloat artY = (height - artSize) / 2.0;
    art.frame = CGRectMake(0, artY, artSize, artSize);
    CGFloat textX = artSize + 8.0;
    CGFloat textW = MAX(0, width - textX);
    title.frame = CGRectMake(textX, artY + titleY0, textW, 16.0);
    artist.frame = CGRectMake(textX, artY + titleY0 + 17.0, textW, 14.0);
}

- (void)m27ApplyIncomingTitle:(NSString *)title
                       artist:(NSString *)artist
                      artwork:(UIImage *)artwork {
    self.incomingTitle = title;
    self.incomingArtist = artist;
    self.incomingArtwork = artwork;
    self.collapsedIncomingTitle.text = title ?: @"";
    self.expandedIncomingTitle.text = title ?: @"";
    self.collapsedIncomingArtist.text = artist ?: @"";
    self.expandedIncomingArtist.text = artist ?: @"";
    self.collapsedIncomingArt.image = artwork;
    self.expandedIncomingArt.image = artwork;
}

- (void)m27ClearIncoming {
    [self m27ApplyIncomingTitle:nil artist:nil artwork:nil];
}

- (void)m27AskDelegateForIncoming:(NSInteger)direction {
    if (direction == 0) return;
    if (![self.delegate respondsToSelector:@selector(floatingDock:incomingTrackForDirection:)]) {
        [self m27ClearIncoming];
        return;
    }
    NSDictionary *incoming = [self.delegate floatingDock:self incomingTrackForDirection:direction];
    NSString *title = nil;
    NSString *artist = nil;
    UIImage *artwork = nil;
    id rawTitle = incoming[@"title"];
    if ([rawTitle isKindOfClass:NSString.class]) title = (NSString *)rawTitle;
    id rawArtist = incoming[@"artist"];
    if ([rawArtist isKindOfClass:NSString.class]) artist = (NSString *)rawArtist;
    id rawArt = incoming[@"artwork"];
    if ([rawArt isKindOfClass:UIImage.class]) artwork = (UIImage *)rawArt;
    [self m27ApplyIncomingTitle:title artist:artist artwork:artwork];
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

    // Clip is the art+titles band only. Play/pause stays a sibling so it does
    // not translate with the carousel, and incoming artwork cannot slide over it.
    _collapsedClip = [[UIView alloc] initWithFrame:CGRectZero];
    _collapsedClip.clipsToBounds = YES;
    _collapsedClip.userInteractionEnabled = NO;
    _collapsedClip.backgroundColor = UIColor.clearColor;
    [_collapsedGlass.contentView addSubview:_collapsedClip];

    UIImageView *collapsedArt = nil;
    UILabel *collapsedTitle = nil;
    UILabel *collapsedArtist = nil;
    _collapsedCurrentStack = [self m27BuildTrackStackArt:&collapsedArt
                                                   title:&collapsedTitle
                                                  artist:&collapsedArtist];
    _collapsedArt = collapsedArt;
    _collapsedTitle = collapsedTitle;
    _collapsedArtist = collapsedArtist;
    [_collapsedClip addSubview:_collapsedCurrentStack];

    UIImageView *collapsedIncomingArt = nil;
    UILabel *collapsedIncomingTitle = nil;
    UILabel *collapsedIncomingArtist = nil;
    _collapsedIncomingStack = [self m27BuildTrackStackArt:&collapsedIncomingArt
                                                    title:&collapsedIncomingTitle
                                                   artist:&collapsedIncomingArtist];
    _collapsedIncomingArt = collapsedIncomingArt;
    _collapsedIncomingTitle = collapsedIncomingTitle;
    _collapsedIncomingArtist = collapsedIncomingArtist;
    _collapsedIncomingStack.hidden = YES;
    [_collapsedClip addSubview:_collapsedIncomingStack];

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
    UITapGestureRecognizer *miniTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nowPlayingTapped)];
    [miniHost addGestureRecognizer:miniTap];
    [M27GlassChrome addSoftShadowToHost:miniHost];
    [miniHost addSubview:_miniGlass];
    [_expandedHost addSubview:miniHost];

    _expandedClip = [[UIView alloc] initWithFrame:CGRectZero];
    _expandedClip.clipsToBounds = YES;
    _expandedClip.userInteractionEnabled = NO;
    _expandedClip.backgroundColor = UIColor.clearColor;
    [_miniGlass.contentView addSubview:_expandedClip];

    UIImageView *expandedArt = nil;
    UILabel *expandedTitle = nil;
    UILabel *expandedArtist = nil;
    _expandedCurrentStack = [self m27BuildTrackStackArt:&expandedArt
                                                  title:&expandedTitle
                                                 artist:&expandedArtist];
    _expandedArt = expandedArt;
    _expandedTitle = expandedTitle;
    _expandedArtist = expandedArtist;
    [_expandedClip addSubview:_expandedCurrentStack];

    UIImageView *expandedIncomingArt = nil;
    UILabel *expandedIncomingTitle = nil;
    UILabel *expandedIncomingArtist = nil;
    _expandedIncomingStack = [self m27BuildTrackStackArt:&expandedIncomingArt
                                                   title:&expandedIncomingTitle
                                                  artist:&expandedIncomingArtist];
    _expandedIncomingArt = expandedIncomingArt;
    _expandedIncomingTitle = expandedIncomingTitle;
    _expandedIncomingArtist = expandedIncomingArtist;
    _expandedIncomingStack.hidden = YES;
    [_expandedClip addSubview:_expandedIncomingStack];

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
    // After a committed swipe the new track arrives on the incoming stack so
    // the one sliding out keeps the old art. Before commit, MediaRemote progress
    // updates still belong on the current stack.
    if (self.swipeCommitted) {
        self.incomingArtwork = artwork;
        self.collapsedIncomingArt.image = artwork;
        self.expandedIncomingArt.image = artwork;
        return;
    }
    self.collapsedArt.image = artwork;
    self.expandedArt.image = artwork;
}

- (void)setTrackTitle:(NSString *)trackTitle {
    _trackTitle = [trackTitle copy];
    // No "Not Playing" fallback any more. When nothing is playing the pill is
    // removed entirely (see setHasTrack:), so a placeholder string here would
    // only ever be visible for the frame before that happens.
    if (self.swipeCommitted) {
        self.incomingTitle = _trackTitle;
        self.collapsedIncomingTitle.text = _trackTitle ?: @"";
        self.expandedIncomingTitle.text = _trackTitle ?: @"";
        return;
    }
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
    if (self.swipeCommitted) {
        self.incomingArtist = _artistName;
        self.collapsedIncomingArtist.text = _artistName ?: @"";
        self.expandedIncomingArtist.text = _artistName ?: @"";
        return;
    }
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
    CGFloat playW = 36.0;
    CGFloat playX = MAX(0, centreW - pad - playW);
    self.collapsedPlayPause.frame = CGRectMake(playX, (pillH - playW) / 2.0, playW, playW);

    CGFloat clipW = MAX(0, playX - 6.0 - pad);
    self.collapsedClip.frame = CGRectMake(pad, 0, clipW, pillH);
    [self m27LayoutCarouselInClip:self.collapsedClip
                    currentStack:self.collapsedCurrentStack
                   incomingStack:self.collapsedIncomingStack
                             art:self.collapsedArt
                           title:self.collapsedTitle
                          artist:self.collapsedArtist
                    incomingArt:self.collapsedIncomingArt
                  incomingTitle:self.collapsedIncomingTitle
                 incomingArtist:self.collapsedIncomingArtist
                        artSize:art
                         height:pillH
                        titleY0:3.0];

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
    CGFloat eBtn = 34.0;
    CGFloat nextX = CGRectGetWidth(self.miniGlass.bounds) - ePad - eBtn;
    self.expandedNext.frame =
        CGRectMake(nextX, (kM27ExpandedMiniHeight - eBtn) / 2.0, eBtn, eBtn);
    self.expandedPlayPause.frame =
        CGRectMake(nextX - eBtn - 2.0, (kM27ExpandedMiniHeight - eBtn) / 2.0, eBtn, eBtn);
    CGFloat eClipW = MAX(0, CGRectGetMinX(self.expandedPlayPause.frame) - 8.0 - ePad);
    self.expandedClip.frame = CGRectMake(ePad, 0, eClipW, kM27ExpandedMiniHeight);
    [self m27LayoutCarouselInClip:self.expandedClip
                    currentStack:self.expandedCurrentStack
                   incomingStack:self.expandedIncomingStack
                             art:self.expandedArt
                           title:self.expandedTitle
                          artist:self.expandedArtist
                    incomingArt:self.expandedIncomingArt
                  incomingTitle:self.expandedIncomingTitle
                 incomingArtist:self.expandedIncomingArtist
                        artSize:eArt
                         height:kM27ExpandedMiniHeight
                        titleY0:1.0];
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

#pragma mark - Swipe carousel

static const CGFloat kM27SwipeCommitFraction = 0.35;
static const CGFloat kM27SwipeCommitVelocity = 480.0;

+ (BOOL)panGestureIsHorizontalSwipe:(UIPanGestureRecognizer *)pan {
    if (![pan isKindOfClass:UIPanGestureRecognizer.class]) return NO;
    UIView *view = pan.view;
    if (!view) return NO;
    CGPoint translation = [pan translationInView:view];
    CGPoint velocity = [pan velocityInView:view];
    CGFloat dx = translation.x;
    CGFloat dy = translation.y;
    // shouldBegin often fires with a tiny translation; fall back to velocity.
    if (fabs(dx) < 0.5 && fabs(dy) < 0.5) {
        dx = velocity.x;
        dy = velocity.y;
    }
    if (fabs(dx) < 6.0 && fabs(velocity.x) < 120.0) return NO;
    return fabs(dx) > fabs(dy) * 1.35;
}

- (void)installDockSwipePan {
    if (self.swipePan) return;
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.delegate = self;
    [self addGestureRecognizer:pan];
    self.swipePan = pan;

    // A tap on the sliver of pill that does not overlap Music's mini player
    // still has to open the player. The tap waits for this pan to fail.
    UIView *miniHost = [self.expandedHost viewWithTag:0x4D324D48];
    NSArray<UIView *> *hosts = @[
        miniHost ?: (UIView *)NSNull.null,
        self.collapsedHost ?: (UIView *)NSNull.null,
    ];
    for (UIView *host in hosts) {
        if (![host isKindOfClass:UIView.class]) continue;
        for (UIGestureRecognizer *gr in host.gestureRecognizers) {
            if ([gr isKindOfClass:UITapGestureRecognizer.class]) {
                [gr requireGestureRecognizerToFail:pan];
            }
        }
    }
}

- (void)handleSwipePan:(UIPanGestureRecognizer *)pan {
    [self m27ApplySwipePan:pan];
}

- (void)handleExternalSwipePan:(UIPanGestureRecognizer *)pan {
    [self m27ApplySwipePan:pan];
}

- (CGFloat)m27SwipeWidth {
    CGFloat width = CGRectGetWidth(self.expandedClip.bounds);
    if (self.mode == M27DockModeCollapsed) {
        width = CGRectGetWidth(self.collapsedClip.bounds);
    }
    if (width < 1.0) width = MAX(120.0, CGRectGetWidth(self.bounds) * 0.55);
    return width;
}

- (void)m27LayoutCarouselInClip:(UIView *)clip
                  currentStack:(UIView *)current
                 incomingStack:(UIView *)incoming
                           art:(UIImageView *)art
                         title:(UILabel *)title
                        artist:(UILabel *)artist
                  incomingArt:(UIImageView *)incomingArt
                incomingTitle:(UILabel *)incomingTitle
               incomingArtist:(UILabel *)incomingArtist
                      artSize:(CGFloat)artSize
                       height:(CGFloat)height
                      titleY0:(CGFloat)titleY0 {
    CGFloat clipW = CGRectGetWidth(clip.bounds);
    CGFloat offset = self.swipeOffset;
    current.frame = CGRectMake(offset, 0, clipW, height);
    CGFloat incomingShift = -clipW;
    if (offset < -0.5 || (fabs(offset) <= 0.5 && self.swipeDirection < 0)) {
        incomingShift = clipW;
    }
    incoming.frame = CGRectMake(offset + incomingShift, 0, clipW, height);
    incoming.hidden = (fabs(offset) < 0.5 && !self.swipeActive);
    [self m27LayoutTrackStack:current art:art title:title artist:artist
                      artSize:artSize height:height titleY0:titleY0];
    [self m27LayoutTrackStack:incoming art:incomingArt title:incomingTitle
                       artist:incomingArtist artSize:artSize height:height titleY0:titleY0];
}

- (void)m27ApplySwipePan:(UIPanGestureRecognizer *)pan {
    if (![pan isKindOfClass:UIPanGestureRecognizer.class]) return;
    UIView *view = pan.view;
    if (!view) return;
    CGFloat tx = [pan translationInView:view].x;
    CGFloat vx = [pan velocityInView:view].x;
    UIGestureRecognizerState state = pan.state;
    if (state == UIGestureRecognizerStateBegan) {
        [self m27SwipeBegan:tx];
        return;
    }
    if (state == UIGestureRecognizerStateChanged) {
        [self m27SwipeChanged:tx];
        return;
    }
    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        BOOL cancelled = (state != UIGestureRecognizerStateEnded);
        [self m27SwipeEnded:tx velocity:vx cancelled:cancelled];
    }
}

- (void)m27SwipeBegan:(CGFloat)tx {
    if (self.swipeActive) return;
    if ([self.delegate respondsToSelector:@selector(floatingDockShouldAllowSwipe:)] &&
        ![self.delegate floatingDockShouldAllowSwipe:self]) {
        return;
    }
    self.swipeActive = YES;
    self.swipeCommitted = NO;
    self.swipeDirection = (tx < -0.5) ? -1 : ((tx > 0.5) ? 1 : 0);
    if (self.swipeDirection != 0) {
        [self m27AskDelegateForIncoming:self.swipeDirection];
    } else {
        [self m27ClearIncoming];
    }
    self.swipeOffset = 0;
    M27WriteStatus(@"swipe_begin", @{
        @"dir": (self.swipeDirection < 0) ? @"next" :
                ((self.swipeDirection > 0) ? @"prev" : @"?"),
    });
    [self setNeedsLayout];
}

- (void)m27SwipeChanged:(CGFloat)tx {
    if (!self.swipeActive || self.swipeCommitted) return;
    CGFloat width = [self m27SwipeWidth];
    CGFloat clamped = MAX(-width, MIN(width, tx));
    NSInteger dir = 0;
    if (clamped < -0.5) dir = -1;
    else if (clamped > 0.5) dir = 1;
    if (dir != 0 && dir != self.swipeDirection) {
        self.swipeDirection = dir;
        [self m27AskDelegateForIncoming:dir];
    }
    self.swipeOffset = clamped;
    [self setNeedsLayout];
}

- (void)m27PromoteIncomingToCurrent {
    // Always take incoming, even when blank. A next-track swipe has no queue
    // to read, so incoming starts empty; keeping the outgoing labels here
    // would snap the old track back after the carousel finished.
    NSString *title = self.incomingTitle ?: @"";
    NSString *artist = self.incomingArtist ?: @"";
    UIImage *artwork = self.incomingArtwork;
    _trackTitle = [title copy];
    _artistName = [artist copy];
    _artwork = artwork;
    self.collapsedTitle.text = title;
    self.expandedTitle.text = title;
    self.collapsedArtist.text = artist;
    self.expandedArtist.text = artist;
    self.collapsedArt.image = artwork;
    self.expandedArt.image = artwork;
    [self m27ClearIncoming];
}

- (void)m27SwipeEnded:(CGFloat)tx velocity:(CGFloat)vx cancelled:(BOOL)cancelled {
    if (!self.swipeActive || self.swipeCommitted) return;
    CGFloat width = [self m27SwipeWidth];
    NSInteger dir = self.swipeDirection;
    if (dir == 0) {
        if (tx < -0.5) dir = -1;
        else if (tx > 0.5) dir = 1;
    }
    BOOL sameSign = (tx * (CGFloat)dir) > 0.0 || dir == 0;
    BOOL farEnough = fabs(tx) > width * kM27SwipeCommitFraction;
    BOOL flicked = (fabs(vx) > kM27SwipeCommitVelocity) && (vx * tx > 0.0);
    BOOL commit = !cancelled && dir != 0 && sameSign && (farEnough || flicked);

    if (commit) {
        self.swipeCommitted = YES;
        if ([self.delegate respondsToSelector:@selector(floatingDock:didCommitSwipeWithDirection:)]) {
            [self.delegate floatingDock:self didCommitSwipeWithDirection:dir];
        }
        CGFloat target = (dir < 0) ? -width : width;
        [self m27AnimateSwipeOffsetTo:target thenReset:YES];
        return;
    }

    if ([self.delegate respondsToSelector:@selector(floatingDockDidCancelSwipe:)]) {
        [self.delegate floatingDockDidCancelSwipe:self];
    }
    [self m27AnimateSwipeOffsetTo:0 thenReset:YES];
}

- (void)m27AnimateSwipeOffsetTo:(CGFloat)target thenReset:(BOOL)reset {
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.92
          initialSpringVelocity:0.35
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self.swipeOffset = target;
                         [self setNeedsLayout];
                         [self layoutIfNeeded];
                     }
                     completion:^(BOOL finished) {
                         (void)finished;
                         if (!reset) return;
                         if (self.swipeCommitted) {
                             [self m27PromoteIncomingToCurrent];
                         } else {
                             [self m27ClearIncoming];
                         }
                         self.swipeOffset = 0;
                         self.swipeDirection = 0;
                         self.swipeActive = NO;
                         self.swipeCommitted = NO;
                         [self setNeedsLayout];
                     }];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if (gr != self.swipePan) return YES;
    if (![gr isKindOfClass:UIPanGestureRecognizer.class]) return NO;
    if ([self.delegate respondsToSelector:@selector(floatingDockShouldAllowSwipe:)] &&
        ![self.delegate floatingDockShouldAllowSwipe:self]) {
        return NO;
    }
    return [M27FloatingDock panGestureIsHorizontalSwipe:(UIPanGestureRecognizer *)gr];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if (gr != self.swipePan) return NO;
    if ([other isKindOfClass:UITapGestureRecognizer.class]) return YES;
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    if (gr != self.swipePan) return YES;
    UIView *view = touch.view;
    UIView *tabsHost = [self.expandedHost viewWithTag:0x4D325448];
    while (view && view != self) {
        if ([view isKindOfClass:UIButton.class]) return NO;
        // The tab row and the collapsed end-caps are not the mini pill.
        if (view == tabsHost || view == self.tabsStack) return NO;
        if (view == self.collapsedLeadingHost || view == self.collapsedTrailingHost) return NO;
        view = view.superview;
    }
    return YES;
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
