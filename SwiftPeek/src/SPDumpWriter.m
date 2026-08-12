#import "SPDumpWriter.h"
#import "SPPrefs.h"
#import <notify.h>
#import <sys/utsname.h>
#import <UIKit/UIKit.h>

static NSString * const kSPDumpNotify = @"com.kolby.swiftpeek/dump";

NSDictionary *SPDumpHeader(void) {
    NSString *iosVersion = UIDevice.currentDevice.systemVersion ?: @"unknown";
    struct utsname u;
    NSString *machine = @"unknown";
    if (uname(&u) == 0) {
        machine = [NSString stringWithUTF8String:u.machine] ?: @"unknown";
    }
    NSString *proc = NSProcessInfo.processInfo.processName ?: @"unknown";
    NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
    fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                        NSISO8601DateFormatWithFractionalSeconds;
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    NSString *ts = [fmt stringFromDate:[NSDate date]] ?: @"";

    return @{
        @"device_model": machine,
        @"ios_version": iosVersion,
        @"process": proc,
        @"timestamp": ts,
        @"tool": @"SwiftPeek",
        @"tool_version": @"0.5.3",
    };
}

NSString *SPDumpDirectory(void) {
    NSString *rel = @"/var/mobile/Library/SwiftPeek/dumps";
    NSString *jb = SPJailbreakRootPrefix();
    if (jb.length) return [jb stringByAppendingString:rel];
    NSString *rootless = [@"/var/jb" stringByAppendingString:rel];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb" isDirectory:&isDir] && isDir) {
        return rootless;
    }
    return rel;
}

static NSString *SPStatusPath(void) {
    NSString *rel = @"/var/mobile/Library/SwiftPeek/status.json";
    NSString *jb = SPJailbreakRootPrefix();
    if (jb.length) return [jb stringByAppendingString:rel];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb" isDirectory:&isDir] && isDir) {
        return [@"/var/jb" stringByAppendingString:rel];
    }
    return rel;
}

static NSData *SPStableJSONData(NSDictionary *root, NSError **outError) {
    NSArray *keyOrder = @[
        @"device_model", @"ios_version", @"process", @"timestamp",
        @"tool", @"tool_version", @"milestone", @"status", @"enabled",
        @"jbroot", @"prefs_paths", @"hosting_view", @"hosting_controller",
        @"hosting_view_names", @"hosting_controller_names",
        @"hooked_view_class", @"hooked_controller_class",
        @"hooked", @"nodes", @"message", @"probe", @"launch", @"scan", @"prefs",
        @"hosts_found", @"music_views_found", @"view_class_sample",
        @"windows",
        @"fields", @"mirror_strings", @"screen_strings"
    ];
    NSMutableString *json = [NSMutableString stringWithString:@"{\n"];
    BOOL first = YES;
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *key in keyOrder) {
        id value = root[key];
        if (!value) continue;
        [seen addObject:key];
        NSData *chunk = [NSJSONSerialization dataWithJSONObject:@{key: value}
                                                        options:0
                                                          error:outError];
        if (!chunk) return nil;
        NSString *s = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
        if (s.length < 2) return nil;
        NSString *inner = [s substringWithRange:NSMakeRange(1, s.length - 2)];
        if (!first) [json appendString:@",\n"];
        first = NO;
        [json appendFormat:@"  %@", [inner stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    }
    NSArray *extra = [[root.allKeys filteredArrayUsingPredicate:
                       [NSPredicate predicateWithBlock:^BOOL(NSString *k, id _) {
        return ![seen containsObject:k];
    }]] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in extra) {
        id value = root[key];
        if (!value) continue;
        NSData *chunk = [NSJSONSerialization dataWithJSONObject:@{key: value}
                                                        options:0
                                                          error:outError];
        if (!chunk) return nil;
        NSString *s = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
        if (s.length < 2) return nil;
        NSString *inner = [s substringWithRange:NSMakeRange(1, s.length - 2)];
        if (!first) [json appendString:@",\n"];
        first = NO;
        [json appendFormat:@"  %@", [inner stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    }
    [json appendString:@"\n}\n"];
    return [json dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *SPWriteJSONToPath(NSDictionary *payload, NSString *path, BOOL notify) {
    if (![NSJSONSerialization isValidJSONObject:payload]) return nil;

    NSMutableDictionary *root = [SPDumpHeader() mutableCopy];
    [payload enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        root[key] = obj;
    }];

    NSError *err = nil;
    NSData *data = SPStableJSONData(root, &err);
    if (!data) return nil;

    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&err]) {
        return nil;
    }

    if (![data writeToFile:path options:NSDataWritingAtomic error:&err]) {
        return nil;
    }
    if (notify) notify_post(kSPDumpNotify.UTF8String);
    return path;
}

NSString *SPWriteStatus(NSDictionary *payload) {
    return SPWriteJSONToPath(payload, SPStatusPath(), NO);
}

NSString *SPWriteJSONDump(NSDictionary *payload) {
    NSMutableDictionary *root = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *header = SPDumpHeader();
    NSString *ts = header[@"timestamp"] ?: @"unknown";
    NSString *safeTs = [[ts stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                        stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSString *proc = header[@"process"] ?: @"proc";
    NSString *name = [NSString stringWithFormat:@"%@_%@.json", proc, safeTs];
    NSString *path = [SPDumpDirectory() stringByAppendingPathComponent:name];
    return SPWriteJSONToPath(root, path, YES);
}
// ci-kick
