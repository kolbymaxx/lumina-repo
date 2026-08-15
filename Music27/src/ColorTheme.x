#import "Music27.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// Artwork-driven color theming.
//
// 1.1.11: match only MusicApplication detail VCs proven by SwiftPeek.
// Never wash Library*/MiniPlayer*/UIHosting* hosts (those stayed alive while
// Music looked black — a broad wash covered them).

static BOOL M27LooksLikeAlbumOrPlaylist(UIViewController *vc) {
    if (!vc || M27IsProtectedMusicHost(vc)) return NO;
    if ([vc isKindOfClass:UITabBarController.class] ||
        [vc isKindOfClass:UINavigationController.class] ||
        [vc isKindOfClass:UISplitViewController.class]) {
        return NO;
    }
    // Exact MusicApplication type names (module prefix optional).
    if (M27ClassNameHasSuffix(vc, @"AlbumDetailViewController")) return YES;
    if (M27ClassNameHasSuffix(vc, @"PlaylistDetailViewController")) return YES;
    return NO;
}

static BOOL M27IsNowPlayingController(UIViewController *vc) {
    if (!vc || M27IsProtectedMusicHost(vc)) return NO;
    // MiniPlayerViewController is protected and is NOT full-screen now playing.
    if (M27ClassNameHasSuffix(vc, @"NowPlayingViewController")) return YES;
    if (M27ClassNameHasSuffix(vc, @"FullscreenPlayerViewController")) return YES;
    return NO;
}

static BOOL M27ShouldThemeController(UIViewController *vc) {
    if (M27IsNowPlayingController(vc)) return YES;
    if (M27LooksLikeAlbumOrPlaylist(vc)) return YES;
    return NO;
}

static CAGradientLayer *M27FindWashLayer(UIView *view) {
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer.name isEqualToString:@"M27Wash"]) return (CAGradientLayer *)layer;
    }
    return nil;
}

static void M27RemoveWash(UIView *view) {
    CAGradientLayer *wash = M27FindWashLayer(view);
    [wash removeFromSuperlayer];
}

static void M27ApplyWash(UIView *view, M27ColorPalette *palette) {
    if (!view) return;
    if (!palette) {
        M27RemoveWash(view);
        return;
    }

    CAGradientLayer *wash = M27FindWashLayer(view);
    if (!wash) {
        wash = [CAGradientLayer layer];
        wash.name = @"M27Wash";
        // zPosition -1000 put this behind the album page's opaque
        // UICollectionView (bg 1.00). The wash has to sit on that view, or
        // at least not behind it.
        [view.layer insertSublayer:wash atIndex:0];
    }
    wash.frame = view.bounds;
    wash.colors = @[
        (id)[palette.background colorWithAlphaComponent:0.92].CGColor,
        (id)[palette.backgroundSecondary colorWithAlphaComponent:0.78].CGColor,
        (id)[palette.background colorWithAlphaComponent:0.55].CGColor
    ];
    wash.startPoint = CGPointMake(0.5, 0.0);
    wash.endPoint = CGPointMake(0.5, 1.0);
}

static void M27TintControls(UIView *view, M27ColorPalette *palette) {
    if (!view || !palette) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    NSInteger visited = 0;
    while (stack.count > 0 && visited < 80) {
        UIView *current = stack.lastObject;
        [stack removeLastObject];
        visited++;
        if ([current isKindOfClass:UISlider.class]) {
            UISlider *slider = (UISlider *)current;
            slider.minimumTrackTintColor = palette.tint;
            slider.thumbTintColor = palette.foreground;
        } else if ([current isKindOfClass:UIProgressView.class]) {
            UIProgressView *progress = (UIProgressView *)current;
            progress.progressTintColor = palette.tint;
        }
        if (current.subviews.count && visited < 80) {
            [stack addObjectsFromArray:current.subviews];
        }
    }
}

static UIImage *M27ArtworkFromNowPlayingInfo(void) {
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    id artwork = info[MPMediaItemPropertyArtwork];
    if (![artwork isKindOfClass:MPMediaItemArtwork.class]) return nil;
    return [(MPMediaItemArtwork *)artwork imageWithSize:CGSizeMake(300, 300)];
}

static UIView *M27ThemePaintTarget(UIViewController *vc) {
    if (!vc.isViewLoaded) return nil;
    if (!M27LooksLikeAlbumOrPlaylist(vc)) return vc.view;
    // The album wash was painted on vc.view at zPosition -1000. The
    // UICollectionView above it reports bg 1.00 and covers the page, which is
    // why Artwork Color Theme never appeared. Colour the collection view.
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
    NSInteger visited = 0;
    while (stack.count > 0 && visited < 40) {
        UIView *current = stack.lastObject;
        [stack removeLastObject];
        visited++;
        if ([current isKindOfClass:UICollectionView.class]) return current;
        NSInteger count = MIN((NSInteger)current.subviews.count, 16);
        for (NSInteger i = 0; i < count; i++) {
            [stack addObject:current.subviews[(NSUInteger)i]];
        }
    }
    return vc.view;
}

static void M27ThemeController(UIViewController *vc) {
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.colorThemeEnabled)) {
        if (vc.isViewLoaded) {
            M27RemoveWash(vc.view);
            UIView *target = M27ThemePaintTarget(vc);
            if (target != vc.view) M27RemoveWash(target);
        }
        return;
    }
    if (!M27ShouldThemeController(vc)) return;

    UIImage *artwork = M27LargestImageInView(vc.view);
    if (!artwork && M27IsNowPlayingController(vc)) {
        artwork = M27ArtworkFromNowPlayingInfo();
    }
    M27ColorPalette *palette = [M27ColorTheme.shared paletteFromImage:artwork];
    if (!palette) return;
    [M27ColorTheme.shared applyPalette:palette animated:YES];
    UIView *target = M27ThemePaintTarget(vc);
    if (target != vc.view) {
        target.backgroundColor = palette.background;
        vc.view.backgroundColor = palette.background;
    }
    M27ApplyWash(target, palette);
    M27TintControls(vc.view, palette);
}

static void M27ClearThemeOnController(UIViewController *vc) {
    if (vc.isViewLoaded) {
        M27RemoveWash(vc.view);
        UIView *target = M27ThemePaintTarget(vc);
        if (target != vc.view) M27RemoveWash(target);
    }
    if (M27IsNowPlayingController(vc) || M27LooksLikeAlbumOrPlaylist(vc)) {
        UIViewController *top = M27TopViewController();
        if (top != vc) {
            [M27ColorTheme.shared clearThemeAnimated:YES];
        }
    }
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.colorThemeEnabled)) return;
    M27ThemeController(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.colorThemeEnabled)) return;
    if (!M27ShouldThemeController(self)) return;
    M27ColorPalette *palette = M27ColorTheme.shared.activePalette;
    if (palette) M27ApplyWash(M27ThemePaintTarget(self), palette);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.colorThemeEnabled)) return;
    M27ClearThemeOnController(self);
}

%end

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    M27Prefs *prefs = M27Prefs.shared;
    if (!(prefs.enabled && prefs.colorThemeEnabled)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *artwork = nil;
        id artObj = info[MPMediaItemPropertyArtwork];
        if ([artObj isKindOfClass:MPMediaItemArtwork.class]) {
            artwork = [(MPMediaItemArtwork *)artObj imageWithSize:CGSizeMake(300, 300)];
        }
        M27ColorPalette *palette = [M27ColorTheme.shared paletteFromImage:artwork];
        if (!palette) return;
        [M27ColorTheme.shared applyPalette:palette animated:YES];

        UIViewController *top = M27TopViewController();
        if (top && M27IsNowPlayingController(top)) {
            M27ApplyWash(top.view, palette);
            M27TintControls(top.view, palette);
        }
    });
}

%end
