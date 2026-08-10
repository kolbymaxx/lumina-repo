#import "GLIconCache.h"
#import "GLThemeStore.h"
#import "GLRecipeBuilder.h"
#import "GLComposite.h"

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
    GLRecipeBuilderInvalidate();
}

- (UIImage *)imageForBundleID:(NSString *)bundleID
                   stockImage:(UIImage *)stockImage
                    pointSize:(CGSize)pointSize
                        scale:(CGFloat)scale {
    if (bundleID.length == 0) return nil;
    if (pointSize.width < 1.0 || pointSize.height < 1.0) return nil;
    if (scale <= 0) scale = UIScreen.mainScreen.scale;

    GLRecipe recipe;
    BOOL composite = GLRecipeForBundleID(bundleID, &recipe);

    NSString *themePath = [GLThemeStore iconPathForBundleID:bundleID];
    if (!themePath && !composite) {
        // Nothing to do: no theme art for this app and no active effect.
        return nil;
    }

    // The recipe hash is part of the key, so moving a slider invalidates
    // exactly the images it affects and leaves the rest of the cache warm.
    NSString *key = [NSString stringWithFormat:@"%lu|%llu|%@|%@|%.0fx%.0f|%.0f",
                     (unsigned long)self.generation,
                     (unsigned long long)(composite ? GLRecipeHash(&recipe) : 0ULL),
                     themePath ? @"T" : @"S", bundleID,
                     pointSize.width, pointSize.height, scale];

    id cached = [_cache objectForKey:key];
    if (cached == (id)[NSNull null]) return nil;
    if ([cached isKindOfClass:[UIImage class]]) return cached;

    UIImage *result = nil;
    @try {
        // Base layer: the theme's PNG if the pack provides one, otherwise the
        // stock bitmap SpringBoard was about to draw.
        UIImage *base = nil;
        if (themePath) {
            base = [UIImage imageWithContentsOfFile:themePath];
        } else if (composite) {
            base = stockImage;
        }

        if (base) {
            if (composite) {
                result = GLCompositeImage(base, pointSize, scale, &recipe);
            }
            if (!result && themePath) {
                // Either no recipe, or the composite bailed. A themed pack
                // still has to be honoured, so decode it once at the exact
                // pixel size the icon view draws at and stop there.
                UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
                fmt.scale = scale;
                fmt.opaque = NO;
                UIGraphicsImageRenderer *renderer =
                    [[UIGraphicsImageRenderer alloc] initWithSize:pointSize format:fmt];
                result = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
                    [base drawInRect:CGRectMake(0, 0, pointSize.width, pointSize.height)];
                }];
            }
        }
    } @catch (__unused id e) {
        result = nil;   // fail closed — stock icon is always the fallback
    }

    [_cache setObject:(result ?: (id)[NSNull null]) forKey:key];
    return result;
}

@end
