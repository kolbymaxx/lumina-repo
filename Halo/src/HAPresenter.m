#import "Halo.h"
#import <objc/message.h>

// -----------------------------------------------------------------------------
// Halo — window, activity queue, gestures
//
// One window, one capsule, one visible activity. Sources post and retract;
// the presenter picks a winner by priority and animates. Nothing runs on a
// timer except the auto-dismiss of an activity that asked for one.
// -----------------------------------------------------------------------------

/// Passthrough window: everything outside the capsule belongs to SpringBoard.
/// Getting this wrong would swallow status bar taps and notification-centre
/// pulls across the whole top of the screen.
@interface HAWindow : UIWindow
@property (nonatomic, weak) HACapsuleView *capsule;
@end

@implementation HAWindow

// First responder, keyboard and status-bar style all follow the key window, so
// an overlay that becomes key is one of the ways the app underneath ends up
// blank. Halo never calls -makeKeyAndVisible, but refusing key status outright
// means nothing else can hand it over either. (Lesson banked by Music27's
// overlay work — see SPKOverlayWindow in PR #59, which Halo should adopt
// wholesale once that lands.)
- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    HACapsuleView *capsule = self.capsule;
    if (!capsule || capsule.hidden || capsule.alpha < 0.01) return nil;
    if (capsule.state == HACapsuleStateHidden) return nil;
    if (!CGRectContainsPoint(capsule.frame, point)) return nil;
    return [super hitTest:point withEvent:event];
}

@end

@interface HAPresenter ()
@property (nonatomic, strong, nullable) HAWindow *window;
@property (nonatomic, strong, nullable) HACapsuleView *capsule;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HAActivity *> *activities;
@property (nonatomic, strong) NSMutableArray<NSString *> *order;   // recency, last = newest
@property (nonatomic, strong, nullable) HAActivity *current;
@property (nonatomic, assign) NSUInteger dismissGeneration;
@property (nonatomic, assign) BOOL active;
@end

@implementation HAPresenter

+ (instancetype)shared {
    static HAPresenter *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [HAPresenter new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _activities = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Window

static UIWindowScene *HAActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (void)activate {
    if (self.active) return;
    if (!HADeviceSupported()) return;

    @try {
        HANotchMetrics metrics = HACurrentNotchMetrics();

        CGRect screen = UIScreen.mainScreen.bounds;
        CGRect frame = CGRectMake(0, 0, screen.size.width,
                                  metrics.notchHeight + 140.0);

        HAWindow *window = nil;
        UIWindowScene *scene = HAActiveWindowScene();
        if (scene) {
            window = [[HAWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
        } else {
            window = [[HAWindow alloc] initWithFrame:frame];
        }
        window.backgroundColor = UIColor.clearColor;
        window.opaque = NO;
        window.windowLevel = (UIWindowLevel)HAPrefDouble(@"windowLevel",
                                                         UIWindowLevelStatusBar + 51.0);
        window.userInteractionEnabled = YES;
        window.hidden = NO;

        HACapsuleView *capsule = [[HACapsuleView alloc] initWithMetrics:metrics];
        [capsule applyActivity:nil state:HACapsuleStateHidden animated:NO];
        [window addSubview:capsule];
        window.capsule = capsule;

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [capsule addGestureRecognizer:tap];

        UILongPressGestureRecognizer *hold =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHold:)];
        hold.minimumPressDuration = 0.28;
        [capsule addGestureRecognizer:hold];

        UISwipeGestureRecognizer *swipe =
            [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
        swipe.direction = UISwipeGestureRecognizerDirectionUp;
        [capsule addGestureRecognizer:swipe];

        self.window = window;
        self.capsule = capsule;
        self.active = YES;
    } @catch (__unused id e) {
        self.window = nil;
        self.capsule = nil;
        self.active = NO;
    }
}

- (void)deactivate {
    @try {
        self.window.hidden = YES;
        self.window = nil;
        self.capsule = nil;
        self.active = NO;
        [self.activities removeAllObjects];
        [self.order removeAllObjects];
        self.current = nil;
    } @catch (__unused id e) {}
}

#pragma mark - Queue

- (void)presentActivity:(HAActivity *)activity {
    if (!activity.identifier.length) return;
    dispatch_block_t work = ^{
        @try {
            if (!self.active) [self activate];
            if (!self.active) return;

            self.activities[activity.identifier] = activity;
            [self.order removeObject:activity.identifier];
            [self.order addObject:activity.identifier];
            [self reevaluateAnimated:YES];

            if (activity.duration > 0) {
                NSUInteger gen = ++self.dismissGeneration;
                NSString *identifier = activity.identifier;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(activity.duration * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gen != self.dismissGeneration) return;   // superseded
                    [self dismissActivityWithIdentifier:identifier];
                });
            }
        } @catch (__unused id e) {}
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)dismissActivityWithIdentifier:(NSString *)identifier {
    if (!identifier.length) return;
    dispatch_block_t work = ^{
        @try {
            [self.activities removeObjectForKey:identifier];
            [self.order removeObject:identifier];
            [self reevaluateAnimated:YES];
        } @catch (__unused id e) {}
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

/// Highest priority wins; ties go to whichever was posted most recently.
- (HAActivity *)winningActivity {
    HAActivity *best = nil;
    NSInteger bestIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)self.order.count; i++) {
        HAActivity *candidate = self.activities[self.order[i]];
        if (!candidate) continue;
        if (!best || candidate.priority > best.priority ||
            (candidate.priority == best.priority && i > bestIndex)) {
            best = candidate;
            bestIndex = i;
        }
    }
    return best;
}

- (void)reevaluateAnimated:(BOOL)animated {
    if (!self.capsule) return;
    HAActivity *winner = [self winningActivity];
    self.current = winner;

    if (!winner) {
        [self.capsule applyActivity:nil state:HACapsuleStateHidden animated:animated];
        return;
    }
    HACapsuleState state = (self.capsule.state == HACapsuleStateExpanded && winner.expandable)
        ? HACapsuleStateExpanded
        : HACapsuleStateCompact;
    [self.capsule applyActivity:winner state:state animated:animated];
}

#pragma mark - Gestures

- (void)handleTap:(UITapGestureRecognizer *)tap {
    @try {
        HAActivity *activity = self.current;
        if (!activity) return;

        if (self.capsule.state == HACapsuleStateExpanded) {
            if (activity.launchBundleID.length && HAPrefBool(@"tapToOpen", YES)) {
                [self launchBundleID:activity.launchBundleID];
            }
            [self.capsule applyActivity:activity state:HACapsuleStateCompact animated:YES];
            return;
        }

        if (activity.expandable && HAPrefBool(@"tapToExpand", YES)) {
            [self.capsule applyActivity:activity state:HACapsuleStateExpanded animated:YES];
        } else if (activity.launchBundleID.length && HAPrefBool(@"tapToOpen", YES)) {
            [self launchBundleID:activity.launchBundleID];
        }
    } @catch (__unused id e) {}
}

- (void)handleHold:(UILongPressGestureRecognizer *)hold {
    if (hold.state != UIGestureRecognizerStateBegan) return;
    @try {
        HAActivity *activity = self.current;
        if (!activity || !activity.expandable) return;
        [self.capsule applyActivity:activity state:HACapsuleStateExpanded animated:YES];
    } @catch (__unused id e) {}
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)swipe {
    @try {
        HAActivity *activity = self.current;
        if (!activity) return;
        if (self.capsule.state == HACapsuleStateExpanded) {
            [self.capsule applyActivity:activity state:HACapsuleStateCompact animated:YES];
        } else {
            [self dismissActivityWithIdentifier:activity.identifier];
        }
    } @catch (__unused id e) {}
}

/// Launch through LSApplicationWorkspace. SpringBoard's own activation paths
/// (SBUIController et al) change shape between releases; this one is stable
/// and is guarded by respondsToSelector anyway.
- (void)launchBundleID:(NSString *)bundleID {
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) return;
        SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
        if (![workspaceClass respondsToSelector:defaultSel]) return;
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSel);
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (![workspace respondsToSelector:openSel]) return;
        ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bundleID);
    } @catch (__unused id e) {}
}

@end
