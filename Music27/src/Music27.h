#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Shared declarations for the Music27 tweak.
//
// Music27 restyles Apple Music on iOS 16/17 toward the iOS 26/27
// "Liquid Glass" look: floating glass dock (collapsed red·mini·search /
// expanded mini + 5 tabs), album Shuffle·Play·Download controls,
// artwork-driven color theming, and a pinned items row at the top of
// the Library page.

extern NSString *const M27PrefDomain;           // com.music27.tweak
extern NSString *const M27ThemeDidChangeNotification;
extern NSString *const M27PinsDidChangeNotification;
extern const NSInteger M27MaxPins;

#pragma mark - Preferences

@interface M27Prefs : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL glassTabBarEnabled;
@property (nonatomic, assign) BOOL colorThemeEnabled;
@property (nonatomic, assign) BOOL libraryPinsEnabled;
/// Fade Music's own tab bar + mini player while the glass dock is up. Separate
/// from the dock toggle so a chrome regression can be switched off without
/// losing the dock — 1.1.14 blamed a MiniPlayer fade for a crash that was very
/// likely the MPMusicPlayerController bug fixed in 1.1.26, so this needs its own
/// off switch until it has proven itself.
@property (nonatomic, assign) BOOL hideStockChromeEnabled;
/// Restyle Music's full-screen player toward the iOS 27 look. Defaults OFF —
/// this is a brand new hook on a screen nothing else touches, and it should
/// prove itself on a device before it ships switched on.
@property (nonatomic, assign) BOOL nowPlayingGlassEnabled;
+ (instancetype)shared;
- (void)reload;
@end

#pragma mark - Color theme

@interface M27ColorPalette : NSObject
@property (nonatomic, strong) UIColor *background;
@property (nonatomic, strong) UIColor *backgroundSecondary;
@property (nonatomic, strong) UIColor *foreground;
@property (nonatomic, strong) UIColor *tint;
@property (nonatomic, strong) UIColor *glassTint;
@property (nonatomic, assign) BOOL prefersLightContent;
@end

@interface M27ColorTheme : NSObject
@property (nonatomic, strong, nullable) M27ColorPalette *activePalette;
+ (instancetype)shared;
/// Returns nil when image is nil — callers must treat nil as "no theme".
- (nullable M27ColorPalette *)paletteFromImage:(nullable UIImage *)image;
- (void)applyPalette:(nullable M27ColorPalette *)palette animated:(BOOL)animated;
- (void)clearThemeAnimated:(BOOL)animated;
@end

#pragma mark - Pins

typedef NS_ENUM(NSInteger, M27PinType) {
    M27PinTypeAlbum = 0,
    M27PinTypePlaylist = 1,
    M27PinTypeArtist = 2,
    M27PinTypeOther = 3,
};

@interface M27PinnedItem : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, assign) M27PinType type;
@property (nonatomic, strong, nullable) NSData *artworkJPEG;
@end

@interface M27PinStore : NSObject
+ (instancetype)shared;
- (NSArray<M27PinnedItem *> *)pins;
- (BOOL)isPinned:(NSString *)identifier;
- (BOOL)pinItem:(M27PinnedItem *)item error:(NSError * _Nullable * _Nullable)error;
- (void)unpinIdentifier:(NSString *)identifier;
- (void)movePinAtIndex:(NSInteger)from toIndex:(NSInteger)to;
- (void)clearAll;
@end

@interface M27PinnedHeaderView : UIView
@property (nonatomic, copy, nullable) void (^onSelect)(M27PinnedItem *item);
- (void)reload;
@end

#pragma mark - Shared helpers (defined in Helpers.m)

UIViewController *_Nullable M27TopViewController(void);
UIImage *_Nullable M27LargestImageInView(UIView *_Nullable view);
BOOL M27ClassNameContains(NSObject *_Nullable obj, NSArray<NSString *> *needles);
/// Matches Swift `MusicApplication.Foo` or ObjC `Foo` by final type name.
BOOL M27ClassNameHasSuffix(NSObject *_Nullable obj, NSString *suffix);
/// SwiftPeek-proven content hosts that must never be hidden/faded/washed.
BOOL M27IsProtectedMusicHost(NSObject *_Nullable obj);

/// Tear down / reinstall chrome from current prefs (kill switch + dock toggle).
void M27ApplyChromeForCurrentPrefs(void);

/// Tweak version, in one place. Bump here and in Music27/control together.
/// Usable inside a literal: NSLog(@"[Music27 " M27_VERSION "] ...")
#define M27_VERSION "1.1.43"
#define M27VersionString @M27_VERSION

/// Jailbreak root prefix ("" / "/var/jb" / RootHide jbroot).
/// Thin wrapper over SPKit's SPKJailbreakRoot().
NSString *M27JailbreakRoot(void);

/// Append one line to $jbroot/var/mobile/Library/Music27/status.log and mirror
/// the latest state to status.json. Readable in Filza — the point is that the
/// dock's install path can be diagnosed from the phone, without a Console
/// session attached to a Mac.
void M27WriteStatus(NSString *stage, NSDictionary *info);

NS_ASSUME_NONNULL_END
