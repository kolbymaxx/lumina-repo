#import "Music27.h"

// Constructor + preference observers. Logos %ctor runs once when Music loads.

static void M27ReloadPrefsCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Kill switch and feature toggles must tear down / reinstall chrome.
        M27ApplyChromeForCurrentPrefs();
    });
}

static void M27ClearPinsCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [M27PinStore.shared clearAll];
    });
}

%ctor {
    @autoreleasepool {
        [M27Prefs.shared reload];
        (void)M27PinStore.shared;
        (void)M27ColorTheme.shared;
        // Console filter: Music27 1.1.18 — proves dylib loaded after install.
        NSLog(@"[Music27 1.1.18] loaded into %@ enabled=%d glassDock=%d",
              NSBundle.mainBundle.bundleIdentifier ?: @"?",
              (int)M27Prefs.shared.enabled,
              (int)M27Prefs.shared.glassTabBarEnabled);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            M27ReloadPrefsCallback,
            CFSTR("com.music27.tweak/ReloadPrefs"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            M27ClearPinsCallback,
            CFSTR("com.music27.tweak/ClearPins"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
