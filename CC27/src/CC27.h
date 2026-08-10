#import "CC27Headers.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const CC27PrefDomain;
FOUNDATION_EXPORT NSString * const CC27ReloadPrefsNotification;
FOUNDATION_EXPORT NSString * const CC27LayoutDidChangeNotification;

/// Jailbreak root prefix ("" / "/var/jb" / roothide jbroot). Same resolution the
/// prefs use, exported so the %ctor kill-switch check can reach the real path.
FOUNDATION_EXPORT NSString *CC27JailbreakRootPrefix(void);

@interface CC27Prefs : NSObject
+ (instancetype)shared;
- (void)reload;
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL glassChrome;
@property (nonatomic, readonly) BOOL editModeEnabled;
@property (nonatomic, readonly) BOOL allowResize;
@property (nonatomic, readonly) BOOL showTopButtons;
@property (nonatomic, readonly) BOOL hapticFeedback;
/// Debug: write a read-only dump of the live Control Center view tree. Default off.
@property (nonatomic, readonly) BOOL reconDump;
@end

@interface CC27Glass : NSObject
+ (void)applyToModuleContainer:(UIView *)view;
+ (CGFloat)cornerRadiusForSize:(CGSize)size;
+ (void)applyContinuousCorners:(UIView *)view radius:(CGFloat)radius;
@end

typedef NS_ENUM(NSInteger, CC27LayoutApplyResult) {
    CC27LayoutApplyFailed = 0,
    CC27LayoutApplyVisible,        // module instances refreshed in the open CC
    CC27LayoutApplyNeedsReopen,    // saved, but CC must be reopened to see it
    CC27LayoutApplyAlreadyPresent  // module is already in Control Center — nothing done
};

@interface CC27LayoutStore : NSObject
+ (instancetype)shared;
- (void)reload;
- (NSArray<NSString *> *)enabledIdentifiers;
- (NSArray<NSString *> *)fixedIdentifiers;
- (BOOL)isModuleFixed:(NSString *)identifier;
- (BOOL)isModuleInControlCenter:(NSString *)identifier;
- (NSArray<NSString *> *)disabledIdentifiers;
- (BOOL)enableModule:(NSString *)identifier;
- (CC27LayoutApplyResult)enableModuleWithResult:(NSString *)identifier;
- (BOOL)disableModule:(NSString *)identifier;
- (BOOL)moveModule:(NSString *)identifier toIndex:(NSUInteger)index;
- (CCUILayoutSize)sizeForModule:(NSString *)identifier fallback:(CCUILayoutSize)fallback;
- (CCUILayoutSize)cycleSizeForModule:(NSString *)identifier current:(CCUILayoutSize)current;
- (void)setSize:(CCUILayoutSize)size forModule:(NSString *)identifier;
- (void)refreshControlCenterLayout;
- (void)refreshModulePositionsOnly;
- (BOOL)isModuleInstantiated:(NSString *)identifier;
@end

@interface CC27ModuleInfo : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, copy) NSString *category; // System, Connectivity, Media, Utilities, Third Party, CC27
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL fixed; // always-present system module (Connectivity, Volume, …)
@property (nonatomic, assign) BOOL isCC27;
@property (nonatomic, assign) BOOL isThirdParty;
@end

@interface CC27ModuleCatalog : NSObject
+ (instancetype)shared;
- (void)reload;
- (NSArray<CC27ModuleInfo *> *)allModules;
- (NSArray<CC27ModuleInfo *> *)modulesMatchingSearch:(NSString *)query;
- (nullable CC27ModuleInfo *)infoForIdentifier:(NSString *)identifier;
@end

@interface CC27EditSession : NSObject
+ (instancetype)shared;
+ (BOOL)deviceUILocked;
@property (nonatomic, weak, nullable) UIViewController *hostController;
@property (nonatomic, readonly, getter=isEditing) BOOL editing;
@property (nonatomic, readonly, getter=isHostVisible) BOOL hostVisible;
- (void)enterEditModeAnimated:(BOOL)animated;
- (void)exitEditModeAnimated:(BOOL)animated;
- (void)toggleEditMode;
- (void)presentGalleryFrom:(UIViewController *)presenter;
- (void)attachChromeToHost:(UIViewController *)host;
- (void)setHostVisible:(BOOL)visible host:(UIViewController *)host;
- (void)updateChromeForPresentationState:(NSInteger)state host:(UIViewController *)host;
- (void)layoutChromeOnHost:(UIViewController *)host;
- (void)decorateModuleContainer:(UIView *)container identifier:(NSString *)identifier;
- (void)undecorateAll;
- (void)dismissControlCenter;
- (void)showToast:(NSString *)message;
@end

@interface CC27GalleryController : UIViewController
- (instancetype)initWithCatalog:(CC27ModuleCatalog *)catalog;
@end

NS_ASSUME_NONNULL_END
