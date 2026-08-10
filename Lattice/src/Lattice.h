#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// -----------------------------------------------------------------------------
// Lattice — Home Screen layout freedom
//
// iOS 18 added free icon placement. 16.7 and 17.x did not get it, and neither
// has ever allowed a custom grid size. Lattice brings the grid part: any number
// of rows and columns per page, icons scaled to match, spacing and labels under
// your control.
//
// Scope discipline: everything Lattice does is *return a different number* from
// the layout configuration object. It never mutates the icon model, never
// inserts placeholder icons, and never reorders anything. A wrong number gives
// you an ugly grid you can undo in Settings; mutating the model is what turns a
// layout tweak into a Safe Mode, and that work is gated on device confirmation
// (see docs/LAYOUT.md).
// -----------------------------------------------------------------------------

#pragma mark - Preferences

NSString *LTJailbreakRootPrefix(void);
NSDictionary *LTPrefs(void);
BOOL LTPrefBool(NSString *key, BOOL fallback);
NSInteger LTPrefInteger(NSString *key, NSInteger fallback);
double LTPrefDouble(NSString *key, double fallback);
void LTPrefsInvalidate(void);

/// Emergency kill switch, jbroot-aware:
///   /var/mobile/Library/Preferences/com.kolby.lattice.killswitch
BOOL LTKillSwitchPresent(void);

#pragma mark - Layout

/// The resolved layout, clamped to values that cannot produce a degenerate
/// grid. Rebuilt only when preferences change.
typedef struct {
    NSInteger rows;
    NSInteger columns;
    NSInteger landscapeRows;
    NSInteger landscapeColumns;
    NSInteger dockColumns;
    BOOL      hideLabels;
    BOOL      overrideGrid;   // NO = leave rows/columns entirely alone
    BOOL      overrideDock;
} LTLayout;

LTLayout LTCurrentLayout(void);
void LTLayoutInvalidate(void);

/// YES when any override is actually active. With everything at its default,
/// Lattice returns %orig for every hook and is a no-op.
BOOL LTLayoutActive(void);

NS_ASSUME_NONNULL_END
