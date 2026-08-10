#import "Halo.h"

// -----------------------------------------------------------------------------
// Halo — notch metrics
//
// There is no API that reports the notch's *width*. `safeAreaInsets.top` gives
// its height and nothing else, so the width comes from a table keyed on the
// screen's point size. Anything unrecognised with a tall top inset gets a
// conservative default rather than a guess dressed up as a measurement.
// -----------------------------------------------------------------------------

typedef struct {
    CGFloat w, h;              // screen points (portrait)
    CGFloat notchW, notchH;
    BOOL island;
} HADeviceEntry;

static const HADeviceEntry kHADevices[] = {
    // Notch devices
    { 375, 812, 209, 30, NO },   // X, XS, 11 Pro
    { 414, 896, 209, 30, NO },   // XR, XS Max, 11, 11 Pro Max
    { 390, 844, 210, 32, NO },   // 12, 12 Pro, 13, 13 Pro, 14
    { 360, 780, 210, 32, NO },   // 12 mini, 13 mini
    { 428, 926, 219, 32, NO },   // 12 Pro Max, 13 Pro Max, 14 Plus
    // Dynamic Island devices — Halo stays out of their way
    { 393, 852, 125, 37, YES },  // 14 Pro, 15, 15 Pro, 16
    { 430, 932, 125, 37, YES },  // 14 Pro Max, 15 Plus, 15 Pro Max
    { 402, 874, 125, 37, YES },  // 16 Pro
    { 440, 956, 125, 37, YES },  // 16 Pro Max
};

HANotchMetrics HACurrentNotchMetrics(void) {
    HANotchMetrics m = { 0, 0, 0, NO, NO };

    CGSize size = UIScreen.mainScreen.bounds.size;
    CGFloat w = MIN(size.width, size.height);
    CGFloat h = MAX(size.width, size.height);

    CGFloat topInset = 0;
    if (@available(iOS 11.0, *)) {
        // keyWindow is deprecated but in SpringBoard it is the reliable way to
        // reach a window with real safe-area insets this early.
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win.safeAreaInsets.top > topInset) topInset = win.safeAreaInsets.top;
        }
    }
    m.topInset = topInset;

    for (size_t i = 0; i < sizeof(kHADevices) / sizeof(kHADevices[0]); i++) {
        const HADeviceEntry *e = &kHADevices[i];
        if (fabs(e->w - w) < 0.5 && fabs(e->h - h) < 0.5) {
            m.notchWidth = e->notchW;
            m.notchHeight = e->notchH;
            m.hasDynamicIsland = e->island;
            m.hasNotch = !e->island;
            if (m.topInset <= 0) m.topInset = e->island ? 59 : 44;
            return m;
        }
    }

    // Unknown device: a tall top inset means *some* cutout, but not which kind
    // or how wide. Treat it as a notch of default width and let the user nudge
    // it from preferences rather than inventing a measurement.
    if (topInset >= 44.0) {
        m.hasNotch = YES;
        m.notchWidth = 210;
        m.notchHeight = MAX(topInset - 12.0, 28.0);
    }
    return m;
}

BOOL HADeviceSupported(void) {
    HANotchMetrics m = HACurrentNotchMetrics();
    if (m.hasDynamicIsland) return NO;   // the real thing is already there
    return m.hasNotch;
}
