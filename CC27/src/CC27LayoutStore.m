#import "CC27.h"

static NSString *CC27SizeOverridesPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *rel = @"/var/mobile/Library/Preferences/com.kolby.cc27.sizes.plist";
        const char *(*jbrootFn)(const char *) = (const char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootFn) {
            const char *p = jbrootFn([rel UTF8String]);
            if (p && p[0]) {
                path = [NSString stringWithUTF8String:p];
                return;
            }
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:[@"/var/jb" stringByAppendingString:rel]]) {
            path = [@"/var/jb" stringByAppendingString:rel];
        } else {
            path = rel;
        }
    });
    return path;
}

@implementation CC27LayoutStore {
    NSMutableDictionary *_sizes; // id -> @{w,h}
}

+ (instancetype)shared {
    static CC27LayoutStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self reload];
    }
    return self;
}

- (void)reload {
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:CC27SizeOverridesPath()];
    _sizes = disk.mutableCopy ?: [NSMutableDictionary new];
}

- (void)_saveSizes {
    NSString *path = CC27SizeOverridesPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [_sizes writeToFile:path atomically:YES];
}

- (CCSModuleSettingsProvider *)_provider {
    Class cls = NSClassFromString(@"CCSModuleSettingsProvider");
    if (!cls) return nil;
    return [cls sharedProvider];
}

- (NSArray<NSString *> *)enabledIdentifiers {
    NSArray *ids = self._provider.orderedUserEnabledModuleIdentifiers;
    return ids ?: @[];
}

- (NSArray<NSString *> *)fixedIdentifiers {
    NSMutableOrderedSet *fixed = [NSMutableOrderedSet orderedSet];
    CCSModuleSettingsProvider *provider = self._provider;
    if ([provider respondsToSelector:@selector(orderedFixedModuleIdentifiers)]) {
        @try {
            NSArray *ids = provider.orderedFixedModuleIdentifiers;
            if ([ids isKindOfClass:NSArray.class]) [fixed addObjectsFromArray:ids];
        } @catch (__unused NSException *e) {}
    }
    // Known always-present modules on iOS 15–17 in case the provider API moves.
    [fixed addObjectsFromArray:@[
        @"com.apple.control-center.ConnectivityModule",
        @"com.apple.mediaremote.controlcenter.nowplaying",
        @"com.apple.control-center.OrientationLockModule",
        @"com.apple.donotdisturb.DoNotDisturbModule",
        @"com.apple.FocusUIModule",
        @"com.apple.control-center.DisplayModule",
        @"com.apple.control-center.AudioModule",
        @"com.apple.mediaremote.controlcenter.audio",
    ]];
    return fixed.array;
}

- (BOOL)isModuleFixed:(NSString *)identifier {
    return identifier.length > 0 && [[self fixedIdentifiers] containsObject:identifier];
}

- (BOOL)isModuleInControlCenter:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    if ([self.enabledIdentifiers containsObject:identifier]) return YES;
    return [self isModuleFixed:identifier];
}

- (NSArray<NSString *> *)disabledIdentifiers {
    NSMutableSet *all = [NSMutableSet set];
    for (CC27ModuleInfo *info in CC27ModuleCatalog.shared.allModules) {
        if (info.identifier) [all addObject:info.identifier];
    }
    [all minusSet:[NSSet setWithArray:self.enabledIdentifiers]];
    return all.allObjects;
}

- (BOOL)isModuleInstantiated:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    Class mgrCls = NSClassFromString(@"CCUIModuleInstanceManager");
    id mgr = [mgrCls respondsToSelector:@selector(sharedInstance)] ? [mgrCls sharedInstance] : nil;
    if (!mgr) return NO;
    if ([mgr respondsToSelector:@selector(instanceForModuleIdentifier:)]) {
        id inst = [mgr instanceForModuleIdentifier:identifier];
        if (inst) return YES;
    }
    @try {
        NSDictionary *map = [mgr valueForKey:@"_moduleInstanceByIdentifier"];
        if ([map isKindOfClass:NSDictionary.class] && map[identifier]) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

- (void)_forceSettingsReload {
    CCSModuleSettingsProvider *provider = self._provider;
    if (!provider) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    for (NSString *name in @[ @"_handleConfigurationFileUpdate", @"_loadSettings", @"_queue_loadSettings" ]) {
        SEL sel = NSSelectorFromString(name);
        if ([provider respondsToSelector:sel]) {
            @try { [provider performSelector:sel]; } @catch (NSException *e) {
                NSLog(@"[CC27] settings reload %@ threw: %@", name, e);
            }
            break;
        }
    }
#pragma clang diagnostic pop
}

- (void)_forceInstanceRebuild {
    Class mgrCls = NSClassFromString(@"CCUIModuleInstanceManager");
    id mgr = [mgrCls respondsToSelector:@selector(sharedInstance)] ? [mgrCls sharedInstance] : nil;
    if (!mgr) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    for (NSString *name in @[
        @"_updateModuleInstances",
        @"updateModuleInstances",
        @"_reloadModuleInstances",
        @"loadModuleInstances",
        @"_loadModuleInstances"
    ]) {
        SEL sel = NSSelectorFromString(name);
        if ([mgr respondsToSelector:sel]) {
            @try { [mgr performSelector:sel]; } @catch (NSException *e) {
                NSLog(@"[CC27] instance rebuild %@ threw: %@", name, e);
            }
            break;
        }
    }
#pragma clang diagnostic pop
}

- (CCUIModuleCollectionViewController *)_collectionViewController {
    Class coll = NSClassFromString(@"CCUIModuleCollectionViewController");
    Class mod = NSClassFromString(@"CCUIModularControlCenterViewController");
    Class overlay = NSClassFromString(@"CCUIModularControlCenterOverlayViewController");
    if ([mod respondsToSelector:@selector(_sharedCollectionViewController)]) {
        return [mod _sharedCollectionViewController];
    }
    if ([overlay respondsToSelector:@selector(_sharedCollectionViewController)]) {
        return [overlay _sharedCollectionViewController];
    }
    if ([coll respondsToSelector:@selector(_sharedCollectionViewController)]) {
        return [coll _sharedCollectionViewController];
    }
    return nil;
}

// Reorder-only refresh: the module instances are unchanged, so skip the
// aggressive instance rebuild that can throw mid-gesture and safe-mode
// SpringBoard. Just reload settings and ask the collection to re-place views.
- (void)refreshModulePositionsOnly {
    [self _forceSettingsReload];

    CCUIModuleCollectionViewController *vc = [self _collectionViewController];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if (vc) {
        for (NSString *name in @[ @"_refreshPositionProviders", @"_updatePositionProviders" ]) {
            SEL sel = NSSelectorFromString(name);
            if ([vc respondsToSelector:sel]) {
                @try { [vc performSelector:sel]; } @catch (NSException *e) {
                    NSLog(@"[CC27] position refresh %@ threw: %@", name, e);
                }
            }
        }
        @try {
            [vc.view setNeedsLayout];
            [vc.view layoutIfNeeded];
        } @catch (NSException *e) {
            NSLog(@"[CC27] position relayout threw: %@", e);
        }
    }
#pragma clang diagnostic pop

    [[NSNotificationCenter defaultCenter] postNotificationName:CC27LayoutDidChangeNotification object:nil];
}

- (void)refreshControlCenterLayout {
    [self _forceSettingsReload];
    [self _forceInstanceRebuild];

    CCUIModuleCollectionViewController *vc = [self _collectionViewController];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if (vc) {
        for (NSString *name in @[
            @"_refreshPositionProviders",
            @"_updatePositionProviders",
            @"_repopulateModuleViews",
            @"reloadData"
        ]) {
            SEL sel = NSSelectorFromString(name);
            if ([vc respondsToSelector:sel]) {
                @try { [vc performSelector:sel]; } @catch (NSException *e) {
                    NSLog(@"[CC27] layout refresh %@ threw: %@", name, e);
                }
            }
        }
        @try {
            [vc.view setNeedsLayout];
            [vc.view layoutIfNeeded];
        } @catch (NSException *e) {
            NSLog(@"[CC27] layout relayout threw: %@", e);
        }
    }
#pragma clang diagnostic pop

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.opa334.ccsupport/ReloadSizes"),
                                         NULL, NULL, TRUE);
}

- (BOOL)enableModule:(NSString *)identifier {
    return [self enableModuleWithResult:identifier] != CC27LayoutApplyFailed;
}

- (CC27LayoutApplyResult)enableModuleWithResult:(NSString *)identifier {
    if (identifier.length == 0) return CC27LayoutApplyFailed;
    CCSModuleSettingsProvider *provider = self._provider;
    if (!provider) {
        NSLog(@"[CC27] enableModule: CCSModuleSettingsProvider missing — is CCSupport installed?");
        return CC27LayoutApplyFailed;
    }

    // Never add a module that is already in Control Center. Fixed system modules
    // (Volume, Brightness, Connectivity, …) live outside the user-enabled list;
    // appending them there spawns a duplicate instance and crashes SpringBoard.
    if ([self isModuleInControlCenter:identifier]) {
        NSLog(@"[CC27] enableModule: %@ is already present — skipping", identifier);
        return CC27LayoutApplyAlreadyPresent;
    }

    NSMutableArray *ordered = self.enabledIdentifiers.mutableCopy ?: [NSMutableArray new];
    if (![ordered containsObject:identifier]) {
        [ordered addObject:identifier];
        [provider setAndSaveOrderedUserEnabledModuleIdentifiers:ordered];
    }

    // 1.0.9 stability: persist once. Prefer NeedsReopen — never double-call
    // refreshControlCenterLayout / _forceInstanceRebuild while CC is open
    // (that path Safe Modes on 17.3). One rebuild only after dismiss, if CC
    // is not currently presenting.
    [[NSNotificationCenter defaultCenter] postNotificationName:CC27LayoutDidChangeNotification object:nil];

    if (CC27EditSession.shared.hostVisible) {
        return CC27LayoutApplyNeedsReopen;
    }

    [self refreshControlCenterLayout]; // at most once, and only when CC is closed

    if ([self.enabledIdentifiers containsObject:identifier] && [self isModuleInstantiated:identifier]) {
        return CC27LayoutApplyVisible;
    }
    if ([self.enabledIdentifiers containsObject:identifier]) {
        return CC27LayoutApplyNeedsReopen;
    }
    return CC27LayoutApplyFailed;
}

- (BOOL)disableModule:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    // Fixed system modules can't be removed — they aren't in the user list.
    if ([self isModuleFixed:identifier] && ![self.enabledIdentifiers containsObject:identifier]) return NO;
    CCSModuleSettingsProvider *provider = self._provider;
    if (!provider) return NO;
    NSMutableArray *ordered = self.enabledIdentifiers.mutableCopy ?: [NSMutableArray new];
    [ordered removeObject:identifier];
    [provider setAndSaveOrderedUserEnabledModuleIdentifiers:ordered];
    // 1.0.9: same as add — no live instance rebuild while CC is open.
    if (!CC27EditSession.shared.hostVisible) {
        [self refreshControlCenterLayout];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:CC27LayoutDidChangeNotification object:nil];
    return YES;
}

- (BOOL)moveModule:(NSString *)identifier toIndex:(NSUInteger)index {
    if (identifier.length == 0) return NO;
    CCSModuleSettingsProvider *provider = self._provider;
    if (!provider) return NO;
    NSMutableArray *ordered = self.enabledIdentifiers.mutableCopy ?: [NSMutableArray new];
    NSUInteger from = [ordered indexOfObject:identifier];
    if (from == NSNotFound) return NO;
    [ordered removeObjectAtIndex:from];
    NSUInteger to = MIN(index, ordered.count);
    [ordered insertObject:identifier atIndex:to];
    [provider setAndSaveOrderedUserEnabledModuleIdentifiers:ordered];
    // Reorder keeps the same instances alive — use the gentle refresh. The
    // full refresh (instance rebuild) mid-gesture could throw and safe-mode.
    [self refreshModulePositionsOnly];
    return YES;
}

- (CCUILayoutSize)sizeForModule:(NSString *)identifier fallback:(CCUILayoutSize)fallback {
    NSDictionary *entry = _sizes[identifier];
    if (![entry isKindOfClass:NSDictionary.class]) return fallback;
    NSNumber *w = entry[@"w"];
    NSNumber *h = entry[@"h"];
    if (!w || !h) return fallback;
    CCUILayoutSize size;
    size.width = MAX(1, w.unsignedIntegerValue);
    size.height = MAX(1, h.unsignedIntegerValue);
    return size;
}

- (void)setSize:(CCUILayoutSize)size forModule:(NSString *)identifier {
    if (identifier.length == 0) return;
    _sizes[identifier] = @{ @"w": @(MAX(1, size.width)), @"h": @(MAX(1, size.height)) };
    [self _saveSizes];
    [self refreshControlCenterLayout];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.opa334.ccsupport/ReloadSizes"),
                                         NULL, NULL, TRUE);
    [[NSNotificationCenter defaultCenter] postNotificationName:CC27LayoutDidChangeNotification object:nil];
}

- (NSArray<NSValue *> *)_allowedSizesForModule:(NSString *)identifier current:(CCUILayoutSize)current {
    NSSet *preferLarge = [NSSet setWithArray:@[
        @"com.apple.control-center.ConnectivityModule",
        @"com.apple.mediaremote.controlcenter.nowplaying",
        @"com.apple.Home.ControlCenter",
    ]];
    NSSet *sliders = [NSSet setWithArray:@[
        @"com.apple.control-center.DisplayModule",
        @"com.apple.control-center.AudioModule",
        @"com.apple.mediaremote.controlcenter.audio",
    ]];

    NSMutableArray *options = [NSMutableArray array];
    void (^add)(NSUInteger, NSUInteger) = ^(NSUInteger w, NSUInteger h) {
        CCUILayoutSize s = { .width = w, .height = h };
        [options addObject:[NSValue valueWithBytes:&s objCType:@encode(CCUILayoutSize)]];
    };

    if ([sliders containsObject:identifier]) {
        add(1, 2); add(1, 4); add(2, 2);
    } else if ([preferLarge containsObject:identifier]) {
        add(2, 2); add(4, 2); add(2, 1); add(1, 1);
    } else {
        add(1, 1); add(2, 1); add(1, 2); add(2, 2);
    }

    BOOL hasCurrent = NO;
    for (NSValue *v in options) {
        CCUILayoutSize s; [v getValue:&s];
        if (s.width == current.width && s.height == current.height) { hasCurrent = YES; break; }
    }
    if (!hasCurrent && current.width > 0 && current.height > 0) {
        [options insertObject:[NSValue valueWithBytes:&current objCType:@encode(CCUILayoutSize)] atIndex:0];
    }
    return options;
}

- (CCUILayoutSize)cycleSizeForModule:(NSString *)identifier current:(CCUILayoutSize)current {
    NSArray *options = [self _allowedSizesForModule:identifier current:current];
    NSUInteger idx = 0;
    for (NSUInteger i = 0; i < options.count; i++) {
        CCUILayoutSize s; [options[i] getValue:&s];
        if (s.width == current.width && s.height == current.height) { idx = i; break; }
    }
    NSUInteger next = (idx + 1) % options.count;
    CCUILayoutSize result; [options[next] getValue:&result];
    [self setSize:result forModule:identifier];
    return result;
}

@end
