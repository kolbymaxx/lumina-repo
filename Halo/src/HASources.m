#import "Halo.h"
#import <notify.h>

// -----------------------------------------------------------------------------
// Halo — event sources
//
// Only sources with a real, documented-enough signal are here. Each one is
// individually toggleable and each is purely reactive: a notification arrives,
// an activity is posted, and nothing else happens until the next one. No
// timers, no polling.
// -----------------------------------------------------------------------------

static BOOL gHASourcesRunning = NO;
static NSMutableArray *gHATokens = nil;       // NSNotificationCenter tokens
static int gHARingerToken = NOTIFY_TOKEN_INVALID;
static int gHALockToken = NOTIFY_TOKEN_INVALID;

#pragma mark - Symbols

static UIImage *HASymbol(NSString *name) {
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:name];
        if (image) {
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:15
                                                                weight:UIImageSymbolWeightSemibold];
            UIImage *configured = [image imageByApplyingSymbolConfiguration:cfg];
            image = configured ?: image;
            return [image imageWithTintColor:UIColor.whiteColor
                               renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
    }
    return nil;
}

#pragma mark - Battery

static void HAPublishBattery(void) {
    @try {
        if (!HAPrefBool(@"sourceCharging", YES)) return;
        UIDevice *device = UIDevice.currentDevice;
        UIDeviceBatteryState state = device.batteryState;
        if (state != UIDeviceBatteryStateCharging && state != UIDeviceBatteryStateFull) {
            [HAPresenter.shared dismissActivityWithIdentifier:@"battery"];
            return;
        }

        float level = device.batteryLevel;   // -1 when unknown
        NSString *title = (level >= 0)
            ? [NSString stringWithFormat:@"%.0f%%", level * 100.0]
            : @"Charging";

        HAActivity *a = [HAActivity activityWithIdentifier:@"battery" title:title];
        a.subtitle = (state == UIDeviceBatteryStateFull) ? @"Fully Charged" : @"Charging";
        a.priority = HAActivityPriorityImportant;
        a.duration = HAPrefDouble(@"chargingDuration", 3.0);
        a.accentColor = [UIColor colorWithRed:0.20 green:0.82 blue:0.35 alpha:1.0];
        a.progress = (level >= 0) ? level : -1.0;
        a.leadingImage = HASymbol(@"bolt.fill");
        a.expandable = YES;
        [HAPresenter.shared presentActivity:a];
    } @catch (__unused id e) {}
}

#pragma mark - Low power

static void HAPublishLowPower(void) {
    @try {
        if (!HAPrefBool(@"sourceLowPower", YES)) return;
        if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
            [HAPresenter.shared dismissActivityWithIdentifier:@"lowpower"];
            return;
        }
        HAActivity *a = [HAActivity activityWithIdentifier:@"lowpower"
                                                     title:@"Low Power"];
        a.priority = HAActivityPriorityNormal;
        a.duration = 2.5;
        a.accentColor = [UIColor colorWithRed:1.00 green:0.80 blue:0.10 alpha:1.0];
        a.leadingImage = HASymbol(@"battery.25");
        [HAPresenter.shared presentActivity:a];
    } @catch (__unused id e) {}
}

#pragma mark - Screen capture

static void HAPublishCapture(void) {
    @try {
        if (!HAPrefBool(@"sourceScreenCapture", YES)) return;
        if (!UIScreen.mainScreen.isCaptured) {
            [HAPresenter.shared dismissActivityWithIdentifier:@"capture"];
            return;
        }
        HAActivity *a = [HAActivity activityWithIdentifier:@"capture"
                                                     title:@"Recording"];
        a.priority = HAActivityPriorityCritical;
        a.duration = 0;      // stays for the whole recording
        a.accentColor = [UIColor colorWithRed:0.98 green:0.24 blue:0.24 alpha:1.0];
        a.leadingImage = HASymbol(@"record.circle");
        [HAPresenter.shared presentActivity:a];
    } @catch (__unused id e) {}
}

#pragma mark - Ringer

static void HAPublishRinger(uint64_t state) {
    @try {
        if (!HAPrefBool(@"sourceRinger", YES)) return;
        BOOL silent = (state == 0);
        HAActivity *a = [HAActivity activityWithIdentifier:@"ringer"
                                                     title:silent ? @"Silent" : @"Ring"];
        a.priority = HAActivityPriorityNormal;
        a.duration = 1.8;
        a.leadingImage = HASymbol(silent ? @"bell.slash.fill" : @"bell.fill");
        [HAPresenter.shared presentActivity:a];
    } @catch (__unused id e) {}
}

#pragma mark - Lifecycle

void HASourcesStart(void) {
    if (gHASourcesRunning) return;
    gHASourcesRunning = YES;
    gHATokens = [NSMutableArray array];

    @try {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

        if (HAPrefBool(@"sourceCharging", YES)) {
            UIDevice.currentDevice.batteryMonitoringEnabled = YES;
            [gHATokens addObject:[center addObserverForName:UIDeviceBatteryStateDidChangeNotification
                                                     object:nil
                                                      queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(__unused NSNotification *n) {
                HAPublishBattery();
            }]];
        }

        if (HAPrefBool(@"sourceLowPower", YES)) {
            [gHATokens addObject:[center addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                                                     object:nil
                                                      queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(__unused NSNotification *n) {
                HAPublishLowPower();
            }]];
        }

        if (HAPrefBool(@"sourceScreenCapture", YES)) {
            [gHATokens addObject:[center addObserverForName:UIScreenCapturedDidChangeNotification
                                                     object:nil
                                                      queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(__unused NSNotification *n) {
                HAPublishCapture();
            }]];
            HAPublishCapture();   // catch a recording already in progress
        }

        if (HAPrefBool(@"sourceRinger", YES)) {
            notify_register_dispatch("com.apple.springboard.ringerstate",
                                     &gHARingerToken, dispatch_get_main_queue(),
                                     ^(int token) {
                uint64_t state = 1;
                notify_get_state(token, &state);
                HAPublishRinger(state);
            });
        }

        // Clear transient activities when the device locks — nothing should be
        // left hanging over the lock screen after the display sleeps.
        notify_register_dispatch("com.apple.springboard.lockstate",
                                 &gHALockToken, dispatch_get_main_queue(),
                                 ^(int token) {
            uint64_t locked = 0;
            notify_get_state(token, &locked);
            if (locked) {
                [HAPresenter.shared dismissActivityWithIdentifier:@"ringer"];
                [HAPresenter.shared dismissActivityWithIdentifier:@"lowpower"];
            }
        });

        if (HAPrefBool(@"sourceMedia", YES)) {
            HAMediaRemoteStartObserving();
        }
    } @catch (__unused id e) {}
}

void HASourcesStop(void) {
    if (!gHASourcesRunning) return;
    @try {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (id token in gHATokens ?: @[]) {
            [center removeObserver:token];
        }
        [gHATokens removeAllObjects];

        if (gHARingerToken != NOTIFY_TOKEN_INVALID) {
            notify_cancel(gHARingerToken);
            gHARingerToken = NOTIFY_TOKEN_INVALID;
        }
        if (gHALockToken != NOTIFY_TOKEN_INVALID) {
            notify_cancel(gHALockToken);
            gHALockToken = NOTIFY_TOKEN_INVALID;
        }
        HAMediaRemoteStopObserving();
    } @catch (__unused id e) {}
    gHASourcesRunning = NO;
}
