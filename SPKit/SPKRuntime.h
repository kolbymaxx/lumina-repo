#import <Foundation/Foundation.h>

// SPKit — the shared runtime SwiftPeek and the 27-series tweaks build on.
//
// Shipped as SHARED SOURCE: each consumer compiles these files into its own
// dylib. There is no runtime dependency and no `Depends:` line yet, so a change
// here cannot brick an installed tweak that has not been rebuilt. See
// SwiftPeek/docs/DEPENDENCY_PLAN.md for when that changes.
//
// Prefix is SPK, not SP, on purpose: SwiftPeek's own tweak already exports
// SPPrefBool(key, fallback) with a different signature, and both dylibs load
// into the same process.

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Jailbreak root

/// Jailbreak root prefix: "" (rootful), "/var/jb" (Dopamine), or the RootHide
/// jbroot path. Resolved once per process.
///
/// Six near-identical copies of this existed across Music27, SwiftPeek and CC27
/// before extraction — four inside CC27 alone. This is the canonical one.
NSString *SPKJailbreakRoot(void);

/// `SPKJailbreakRoot()` + `relativePath`. Pass paths as they appear on a rootful
/// device ("/var/mobile/Library/…"); the prefix is applied for you.
NSString *SPKRootedPath(NSString *relativePath);

#pragma mark - Preferences

/// Every plausible on-disk location for `domain`'s plist, most likely first:
/// jbroot prefix, then /var/jb, then the raw rootful path. Deduplicated.
/// Exposed for diagnostics — reading code should use SPKPrefBool.
NSArray<NSString *> *SPKPrefsCandidatePaths(NSString *domain);

/// Live CFPreferences first (PreferenceLoader writes there and the file can lag
/// by seconds), falling back to the first non-empty plist on disk.
BOOL SPKPrefBool(NSString *domain, NSString *key, BOOL fallback);

/// Whole preference dictionary for `domain`, cached for 0.5s. Empty if none of
/// the candidate paths hold a non-empty dictionary.
NSDictionary *SPKPrefs(NSString *domain);

/// Drop the cache so the next read hits disk. Call from a ReloadPrefs observer.
void SPKPrefsInvalidate(void);

#pragma mark - Kill switch

/// YES when `<jbroot>/var/mobile/Library/<subdirectory>/DISABLE` exists.
///
/// The escape hatch for a tweak that will not let you reach Settings. Check it
/// before installing anything, and check it early — the point is to be reachable
/// over SSH from a device that is otherwise unusable:
///     touch /var/jb/var/mobile/Library/Music27/DISABLE
BOOL SPKKillSwitchEngaged(NSString *subdirectory);

#pragma mark - Tracing

/// Name the log directory and the version stamped on every line. Call once,
/// early — from %ctor, before anything that could crash.
///
/// Writes land in `<jbroot>/var/mobile/Library/<subdirectory>/status.log`
/// (append) and `status.json` (last entry).
void SPKTraceConfigure(NSString *subdirectory, NSString *version);

/// Append one `key=value` line. SYNCHRONOUS AND fsync'd BEFORE RETURNING.
///
/// This is not a style preference, it is the whole reason the function exists.
/// Music27 1.1.23 logged through a dispatch queue; when Music crashed during
/// install the queue never drained and status.log showed nothing at all — making
/// a crash indistinguishable from a code path that never ran, and costing five
/// builds of guessing. 1.1.25 made it synchronous and pinned the bug in one run.
///
/// Pair a `_begin` line with a result line at every call site you suspect. A
/// missing result then names the span that died instead of erasing the attempt.
void SPKTrace(NSString *stage, NSDictionary *_Nullable info);

/// Collapse consecutive identical lines for `stage`. For stages driven by the
/// layout pass, which would otherwise write on every frame.
void SPKTraceDedupeStage(NSString *stage);

NS_ASSUME_NONNULL_END
