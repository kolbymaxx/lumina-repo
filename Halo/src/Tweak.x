#import "Halo.h"

// -----------------------------------------------------------------------------
// Halo — entry point
//
// Note what is *not* here: there are no %hook blocks. Halo does not need to
// change SpringBoard's behaviour, only to add a window of its own and listen to
// notifications, so it never patches a single method. That is the cheapest
// possible safety story, and it is why this tweak cannot cause a Safe Mode
// through a bad hook — the only failure mode left is its own window, which is
// created behind a device check and a pref, both defaulting to off.
//
// Boot path: the constructor reads the kill switch, registers Darwin observers
// and returns. Nothing else happens until well after
// UIApplicationDidFinishLaunching.
// -----------------------------------------------------------------------------

static BOOL gHAStarted = NO;

static void HALog(NSString *format, ...) {
    if (!HAPrefBool(@"logEvents", YES)) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[Halo] %@", msg);
}

static void HAStart(void) {
    if (gHAStarted) return;
    if (!HAPrefBool(@"enabled", NO)) {
        HALog(@"disabled in prefs — idle");
        return;
    }

    HANotchMetrics metrics = HACurrentNotchMetrics();
    if (metrics.hasDynamicIsland) {
        HALog(@"device already has a Dynamic Island — staying inert");
        return;
    }
    if (!metrics.hasNotch) {
        HALog(@"no notch on this device — staying inert");
        return;
    }

    [HAPresenter.shared activate];
    if (!HAPresenter.shared.isActive) {
        HALog(@"presenter failed to activate — staying inert");
        return;
    }
    HASourcesStart();
    gHAStarted = YES;
    HALog(@"0.1.0 armed — notch %.0fx%.0f, media=%d",
          metrics.notchWidth, metrics.notchHeight, HAMediaRemoteAvailable() ? 1 : 0);
}

static void HAStop(void) {
    if (!gHAStarted) return;
    HASourcesStop();
    [HAPresenter.shared deactivate];
    gHAStarted = NO;
    HALog(@"stopped");
}

static void HAPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    HAPrefsInvalidate();
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (HAPrefBool(@"enabled", NO)) {
                if (gHAStarted) {
                    // Source toggles changed: re-arm from scratch rather than
                    // trying to diff which observers should still exist.
                    HASourcesStop();
                    HASourcesStart();
                } else {
                    HAStart();
                }
            } else {
                HAStop();
            }
        } @catch (__unused id e) {}
    });
}

%ctor {
    @autoreleasepool {
        // Emergency kill switch:
        //   touch /var/mobile/Library/Preferences/com.kolby.halo.killswitch
        if (HAKillSwitchPresent()) {
            NSLog(@"[Halo] kill switch present — not loading");
            return;
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, HAPrefsChanged,
                                        CFSTR("com.kolby.halo/prefschanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        __block id token = nil;
        token = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            if (token) {
                [NSNotificationCenter.defaultCenter removeObserver:token];
                token = nil;
            }
            // Same 2 s cushion as Glyph: clear of the launch watchdog, and
            // late enough that the window scene exists.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { HAStart(); } @catch (__unused id e) {}
            });
        }];

        NSLog(@"[Halo] 0.1.0 loaded — waiting for SpringBoard launch to finish");
    }
}
