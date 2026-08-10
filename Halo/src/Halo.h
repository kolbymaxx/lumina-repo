#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// -----------------------------------------------------------------------------
// Halo — a Dynamic Island for notch devices
//
// The Dynamic Island is a 14 Pro-and-later feature. An iPhone X or a 12 mini
// has a physical notch cut out of the display: those pixels do not exist and no
// tweak can light them up. Halo does not pretend otherwise. What it does is
// recreate the *presentation* — a glass capsule that hugs the notch and expands
// below it — and drive it from the same system events the Island shows.
//
// Everything here is event-driven. There is no polling loop and no per-frame
// work: sources post activities, the presenter animates once, and the capsule
// sits idle until the next event.
// -----------------------------------------------------------------------------

#pragma mark - Preferences

NSString *HAJailbreakRootPrefix(void);
NSDictionary *HAPrefs(void);
BOOL HAPrefBool(NSString *key, BOOL fallback);
double HAPrefDouble(NSString *key, double fallback);
void HAPrefsInvalidate(void);

/// Emergency kill switch, jbroot-aware:
///   /var/mobile/Library/Preferences/com.kolby.halo.killswitch
BOOL HAKillSwitchPresent(void);

#pragma mark - Geometry

typedef struct {
    CGFloat notchWidth;
    CGFloat notchHeight;
    CGFloat topInset;
    BOOL    hasNotch;
    BOOL    hasDynamicIsland;
} HANotchMetrics;

/// Metrics for the current device. Resolved from the main screen's point size
/// against a table of known notch geometries, because there is no API that
/// reports notch width — the safe-area inset only gives its height.
HANotchMetrics HACurrentNotchMetrics(void);

/// YES when Halo should run at all: a notch device that is not already a
/// Dynamic Island device. Halo stays inert on Island hardware rather than
/// fighting the real thing.
BOOL HADeviceSupported(void);

#pragma mark - Activities

typedef NS_ENUM(NSInteger, HAActivityPriority) {
    HAActivityPriorityAmbient  = 0,   // now playing — shown whenever nothing else is
    HAActivityPriorityNormal   = 10,  // ringer, low power
    HAActivityPriorityImportant = 20, // charging
    HAActivityPriorityCritical = 30,  // screen capture
};

/// One thing the capsule can display. Immutable once posted; a source that
/// wants to change its content posts a new activity with the same identifier.
@interface HAActivity : NSObject
@property (nonatomic, copy) NSString *identifier;      // stable per source
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, strong, nullable) UIImage *leadingImage;
@property (nonatomic, strong, nullable) UIColor *accentColor;
@property (nonatomic, assign) HAActivityPriority priority;
/// Seconds before auto-dismiss; 0 means "stays until the source retracts it".
@property (nonatomic, assign) NSTimeInterval duration;
/// Bundle ID to launch on tap, if any.
@property (nonatomic, copy, nullable) NSString *launchBundleID;
/// Progress 0..1 rendered as a thin bar when >= 0.
@property (nonatomic, assign) CGFloat progress;
/// YES for activities worth expanding into the large presentation on tap.
@property (nonatomic, assign) BOOL expandable;

+ (instancetype)activityWithIdentifier:(NSString *)identifier
                                 title:(NSString *)title;
@end

#pragma mark - Capsule

typedef NS_ENUM(NSInteger, HACapsuleState) {
    HACapsuleStateHidden = 0,
    HACapsuleStateCompact,    // hugging the notch
    HACapsuleStateExpanded,   // rounded panel below the notch
};

@interface HACapsuleView : UIView
@property (nonatomic, readonly) HACapsuleState state;
@property (nonatomic, strong, nullable) HAActivity *activity;
- (instancetype)initWithMetrics:(HANotchMetrics)metrics;
- (void)applyActivity:(nullable HAActivity *)activity state:(HACapsuleState)state animated:(BOOL)animated;
/// Frame the capsule wants for a given state, in window coordinates.
- (CGRect)frameForState:(HACapsuleState)state;
@end

#pragma mark - Presenter

@interface HAPresenter : NSObject
+ (instancetype)shared;

/// Bring up the hosting window. Safe to call more than once.
- (void)activate;
/// Tear the window down (prefs disabled).
- (void)deactivate;
@property (nonatomic, readonly, getter=isActive) BOOL active;

/// Post or replace an activity. Highest priority wins; equal priority means
/// most recent wins. Never throws.
- (void)presentActivity:(HAActivity *)activity;
/// Withdraw whatever the given source posted.
- (void)dismissActivityWithIdentifier:(NSString *)identifier;
@end

#pragma mark - Media

/// Thin dlopen bridge to MediaRemote. Every symbol is looked up defensively;
/// when any of them is missing the whole media source simply never arms.
BOOL HAMediaRemoteAvailable(void);
void HAMediaRemoteStartObserving(void);
void HAMediaRemoteStopObserving(void);
/// 0 play, 1 pause, 2 toggle, 4 next, 5 previous (MediaRemote command codes).
void HAMediaRemoteSendCommand(int command);

#pragma mark - Sources

/// Arm the event sources the user has enabled. Idempotent.
void HASourcesStart(void);
void HASourcesStop(void);

NS_ASSUME_NONNULL_END
