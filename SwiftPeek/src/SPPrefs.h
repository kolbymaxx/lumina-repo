#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Jailbreak root prefix ("" / "/var/jb" / roothide jbroot). Same pattern as Siri27/Music27.
NSString *SPJailbreakRootPrefix(void);

/// Preference domain: com.kolby.swiftpeek
NSDictionary *SPPrefs(void);
BOOL SPPrefBool(NSString *key, BOOL fallback);
NSInteger SPPrefInteger(NSString *key, NSInteger fallback);
/// nil when unset or empty — callers treat that as "feature off".
NSString *_Nullable SPPrefString(NSString *key);
void SPPrefsInvalidate(void);

/// Candidate prefs file paths (jbroot → /var/jb → rootfs), for diagnostics.
NSArray<NSString *> *SPPrefsCandidatePaths(void);

NS_ASSUME_NONNULL_END
