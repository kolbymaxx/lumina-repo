#import "Halo.h"
#import <dlfcn.h>

// -----------------------------------------------------------------------------
// Halo — MediaRemote bridge
//
// SpringBoard cannot read another app's MPNowPlayingInfoCenter, so now-playing
// state comes from MediaRemote. Every symbol is resolved by dlsym and checked;
// if any of the ones we actually need is missing on a given firmware, the media
// source simply never arms and Halo carries on without it. No hard link, no
// assumption that a private symbol exists.
// -----------------------------------------------------------------------------

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRUnregisterFn)(void);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef Boolean (*MRSendCommandFn)(int, id);

static void *gHAMRHandle = NULL;
static MRRegisterFn gHARegister = NULL;
static MRUnregisterFn gHAUnregister = NULL;
static MRGetInfoFn gHAGetInfo = NULL;
static MRSendCommandFn gHASendCommand = NULL;

static NSString *gHANotifyInfoChanged = nil;
static NSString *gHANotifyPlayingChanged = nil;
static NSString *gHAKeyTitle = nil;
static NSString *gHAKeyArtist = nil;
static NSString *gHAKeyAlbum = nil;
static NSString *gHAKeyArtwork = nil;
static NSString *gHAKeyRate = nil;
static NSString *gHAKeyDuration = nil;
static NSString *gHAKeyElapsed = nil;

static BOOL gHAObserving = NO;
static id gHAInfoToken = nil;
static id gHAPlayingToken = nil;

/// Dereference a CFStringRef* exported constant into an NSString.
static NSString *HAStringConstant(void *handle, const char *symbol) {
    if (!handle || !symbol) return nil;
    CFStringRef *ref = (CFStringRef *)dlsym(handle, symbol);
    if (!ref || !*ref) return nil;
    return (__bridge NSString *)*ref;
}

static BOOL HAMediaRemoteLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHAMRHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                             RTLD_LAZY);
        if (!gHAMRHandle) return;

        gHARegister = (MRRegisterFn)dlsym(gHAMRHandle,
            "MRMediaRemoteRegisterForNowPlayingNotifications");
        gHAUnregister = (MRUnregisterFn)dlsym(gHAMRHandle,
            "MRMediaRemoteUnregisterForNowPlayingNotifications");
        gHAGetInfo = (MRGetInfoFn)dlsym(gHAMRHandle, "MRMediaRemoteGetNowPlayingInfo");
        gHASendCommand = (MRSendCommandFn)dlsym(gHAMRHandle, "MRMediaRemoteSendCommand");

        gHANotifyInfoChanged = HAStringConstant(gHAMRHandle,
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification");
        gHANotifyPlayingChanged = HAStringConstant(gHAMRHandle,
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");

        gHAKeyTitle    = HAStringConstant(gHAMRHandle, "kMRMediaRemoteNowPlayingInfoTitle");
        gHAKeyArtist   = HAStringConstant(gHAMRHandle, "kMRMediaRemoteNowPlayingInfoArtist");
        gHAKeyAlbum    = HAStringConstant(gHAMRHandle, "kMRMediaRemoteNowPlayingInfoAlbum");
        gHAKeyArtwork  = HAStringConstant(gHAMRHandle, "kMRMediaRemoteNowPlayingInfoArtworkData");
        gHAKeyRate     = HAStringConstant(gHAMRHandle, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
        gHAKeyDuration = HAStringConstant(gHAMRHandle, "kMRMediaRemoteNowPlayingInfoDuration");
        gHAKeyElapsed  = HAStringConstant(gHAMRHandle, "kMRMediaRemoteNowPlayingInfoElapsedTime");
    });
    return gHAMRHandle != NULL;
}

BOOL HAMediaRemoteAvailable(void) {
    if (!HAMediaRemoteLoad()) return NO;
    // The minimum viable set: without these there is nothing to show.
    return gHARegister && gHAGetInfo && gHAKeyTitle && gHANotifyInfoChanged;
}

static void HAPublishNowPlaying(NSDictionary *info) {
    @try {
        NSString *title = [info[gHAKeyTitle] isKindOfClass:[NSString class]]
            ? info[gHAKeyTitle] : nil;
        if (title.length == 0) {
            [HAPresenter.shared dismissActivityWithIdentifier:@"media"];
            return;
        }

        double rate = [info[gHAKeyRate] respondsToSelector:@selector(doubleValue)]
            ? [info[gHAKeyRate] doubleValue] : 0.0;
        if (rate <= 0.0 && !HAPrefBool(@"mediaShowWhenPaused", NO)) {
            [HAPresenter.shared dismissActivityWithIdentifier:@"media"];
            return;
        }

        HAActivity *activity = [HAActivity activityWithIdentifier:@"media" title:title];
        activity.priority = HAActivityPriorityAmbient;
        activity.duration = 0;          // stays until playback stops
        activity.expandable = YES;

        NSString *artist = [info[gHAKeyArtist] isKindOfClass:[NSString class]]
            ? info[gHAKeyArtist] : nil;
        NSString *album = [info[gHAKeyAlbum] isKindOfClass:[NSString class]]
            ? info[gHAKeyAlbum] : nil;
        activity.subtitle = artist.length ? artist : album;

        NSData *artwork = [info[gHAKeyArtwork] isKindOfClass:[NSData class]]
            ? info[gHAKeyArtwork] : nil;
        if (artwork.length) {
            UIImage *image = [UIImage imageWithData:artwork];
            if (image) activity.leadingImage = image;
        }

        double duration = [info[gHAKeyDuration] respondsToSelector:@selector(doubleValue)]
            ? [info[gHAKeyDuration] doubleValue] : 0.0;
        double elapsed = [info[gHAKeyElapsed] respondsToSelector:@selector(doubleValue)]
            ? [info[gHAKeyElapsed] doubleValue] : 0.0;
        // Sampled once per change notification, never ticked on a timer — a
        // progress bar is not worth a wakeup every second.
        activity.progress = (duration > 0.5) ? (CGFloat)(elapsed / duration) : -1.0;

        [HAPresenter.shared presentActivity:activity];
    } @catch (__unused id e) {}
}

static void HARefreshNowPlaying(void) {
    if (!gHAGetInfo) return;
    @try {
        gHAGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
            NSDictionary *info = (__bridge NSDictionary *)raw;
            if (![info isKindOfClass:[NSDictionary class]]) {
                [HAPresenter.shared dismissActivityWithIdentifier:@"media"];
                return;
            }
            HAPublishNowPlaying(info);
        });
    } @catch (__unused id e) {}
}

void HAMediaRemoteStartObserving(void) {
    if (gHAObserving) return;
    if (!HAMediaRemoteAvailable()) return;

    @try {
        gHARegister(dispatch_get_main_queue());
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

        gHAInfoToken = [center addObserverForName:gHANotifyInfoChanged
                                           object:nil
                                            queue:NSOperationQueue.mainQueue
                                       usingBlock:^(__unused NSNotification *note) {
            HARefreshNowPlaying();
        }];
        if (gHANotifyPlayingChanged.length) {
            gHAPlayingToken = [center addObserverForName:gHANotifyPlayingChanged
                                                  object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(__unused NSNotification *note) {
                HARefreshNowPlaying();
            }];
        }
        gHAObserving = YES;
        HARefreshNowPlaying();
    } @catch (__unused id e) {
        gHAObserving = NO;
    }
}

void HAMediaRemoteStopObserving(void) {
    if (!gHAObserving) return;
    @try {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        if (gHAInfoToken) { [center removeObserver:gHAInfoToken]; gHAInfoToken = nil; }
        if (gHAPlayingToken) { [center removeObserver:gHAPlayingToken]; gHAPlayingToken = nil; }
        if (gHAUnregister) gHAUnregister();
    } @catch (__unused id e) {}
    gHAObserving = NO;
    [HAPresenter.shared dismissActivityWithIdentifier:@"media"];
}

void HAMediaRemoteSendCommand(int command) {
    if (!HAMediaRemoteLoad() || !gHASendCommand) return;
    @try {
        gHASendCommand(command, nil);
    } @catch (__unused id e) {}
}
