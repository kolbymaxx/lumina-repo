#import "GLIconCache.h"
#import "GLThemeStore.h"

@implementation GLIconCache {
    NSCache<NSString *, id> *_cache;   // UIImage, or NSNull for negative hits
    NSUInteger _generation;
}

+ (instancetype)shared {
    static GLIconCache *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [GLIconCache new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSCache new];
        _cache.countLimit = 512;   // ~a few home screen pages of icons
        _generation = 1;
    }
    return self;
}

- (NSUInteger)generation {
    @synchronized (self) { return _generation; }
}

- (void)bumpGeneration {
    @synchronized (self) {
        _generation++;
        [_cache removeAllObjects];
    }
    [GLThemeStore invalidate];
}

- (UIImage *)imageForBundleID:(NSString *)bundleID
                    pointSize:(CGSize)pointSize
                        scale:(CGFloat)scale {
    if (bundleID.length == 0) return nil;
    if (pointSize.width < 1.0 || pointSize.height < 1.0) return nil;
    if (scale <= 0) scale = UIScreen.mainScreen.scale;

    NSString *key = [NSString stringWithFormat:@"%lu|%@|%.0fx%.0f|%.0f",
                     (unsigned long)self.generation, bundleID,
                     pointSize.width, pointSize.height, scale];

    id cached = [_cache objectForKey:key];
    if (cached == (id)[NSNull null]) return nil;
    if ([cached isKindOfClass:[UIImage class]]) return cached;

    UIImage *decoded = nil;
    @try {
        NSString *path = [GLThemeStore iconPathForBundleID:bundleID];
        if (path) {
            UIImage *raw = [UIImage imageWithContentsOfFile:path];
            if (raw) {
                // Force-decode once at the exact pixel size the icon view
                // draws at. The theme PNG's own dimensions never matter again.
                UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
                fmt.scale = scale;
                fmt.opaque = NO;
                UIGraphicsImageRenderer *renderer =
                    [[UIGraphicsImageRenderer alloc] initWithSize:pointSize format:fmt];
                decoded = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
                    [raw drawInRect:CGRectMake(0, 0, pointSize.width, pointSize.height)];
                }];
            }
        }
    } @catch (__unused id e) {
        decoded = nil;   // fail closed — stock icon is always the fallback
    }

    [_cache setObject:(decoded ?: (id)[NSNull null]) forKey:key];
    return decoded;
}

@end
