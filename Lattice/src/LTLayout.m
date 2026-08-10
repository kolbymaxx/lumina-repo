#import "Lattice.h"

// -----------------------------------------------------------------------------
// Lattice — resolved layout
//
// Preferences in, clamped numbers out. Everything here exists so that a hook
// can be a single line that returns a value someone already sanity-checked:
// the hooks themselves must not contain policy.
// -----------------------------------------------------------------------------

static LTLayout gLTLayout;
static BOOL gLTLayoutValid = NO;
static BOOL gLTActive = NO;

// Bounds chosen so a wrong preference is ugly, never broken. Two columns is
// the fewest that still looks like a grid; twelve is past the point where an
// icon is tappable, which is the real ceiling.
static const NSInteger kLTMinRows = 2,    kLTMaxRows = 12;
static const NSInteger kLTMinColumns = 2, kLTMaxColumns = 10;
static const NSInteger kLTMinDock = 1,    kLTMaxDock = 8;

static NSInteger LTClampInteger(NSInteger v, NSInteger lo, NSInteger hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static void LTBuildLayoutIfNeeded(void) {
    if (gLTLayoutValid) return;

    LTLayout layout;
    memset(&layout, 0, sizeof(layout));

    layout.overrideGrid = LTPrefBool(@"overrideGrid", NO);
    layout.overrideDock = LTPrefBool(@"overrideDock", NO);

    layout.rows = LTClampInteger(LTPrefInteger(@"rows", 6), kLTMinRows, kLTMaxRows);
    layout.columns = LTClampInteger(LTPrefInteger(@"columns", 4), kLTMinColumns, kLTMaxColumns);

    // Landscape defaults follow portrait unless the user set them explicitly,
    // which is nearly always what someone means by "6x5 grid".
    NSInteger lr = LTPrefInteger(@"landscapeRows", 0);
    NSInteger lc = LTPrefInteger(@"landscapeColumns", 0);
    layout.landscapeRows = (lr > 0)
        ? LTClampInteger(lr, kLTMinRows, kLTMaxRows) : layout.columns;
    layout.landscapeColumns = (lc > 0)
        ? LTClampInteger(lc, kLTMinColumns, kLTMaxColumns) : layout.rows;

    layout.dockColumns = LTClampInteger(LTPrefInteger(@"dockColumns", 4),
                                        kLTMinDock, kLTMaxDock);

    layout.hideLabels = LTPrefBool(@"hideLabels", NO);

    gLTLayout = layout;
    gLTLayoutValid = YES;

    gLTActive = layout.overrideGrid || layout.overrideDock || layout.hideLabels;
}

LTLayout LTCurrentLayout(void) {
    LTBuildLayoutIfNeeded();
    return gLTLayout;
}

void LTLayoutInvalidate(void) {
    gLTLayoutValid = NO;
}

BOOL LTLayoutActive(void) {
    LTBuildLayoutIfNeeded();
    return gLTActive;
}
