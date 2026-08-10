#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Jailbreak root prefix ("" / "/var/jb" / roothide jbroot). Same pattern as
/// SwiftPeek / Music27 / Siri27.
NSString *GLJailbreakRootPrefix(void);

/// Preference domain: com.kolby.glyph
NSDictionary *GLPrefs(void);
BOOL GLPrefBool(NSString *key, BOOL fallback);
NSArray *_Nullable GLPrefArray(NSString *key);
void GLPrefsInvalidate(void);

/// Candidate prefs file paths (jbroot -> /var/jb -> rootfs), for diagnostics.
NSArray<NSString *> *GLPrefsCandidatePaths(void);

/// YES when the emergency kill-switch file exists at any candidate location:
///   <prefix>/var/mobile/Library/Preferences/com.kolby.glyph.killswitch
BOOL GLKillSwitchPresent(void);

NS_ASSUME_NONNULL_END
