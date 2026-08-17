#import "SPKAnchor.h"
#import <string.h>

// Census of the most recent resolve. A global rather than an out-parameter
// because the interesting call site is a one-liner in a layout pass, and
// threading an NSError through it would guarantee nobody reads it. UI work is
// main-thread, and the contract in the header says read it before resolving
// again.
static NSInteger gSPKVisited = 0;
static NSInteger gSPKCandidates = 0;
static NSInteger gSPKRejSide = 0;
static NSInteger gSPKRejAspect = 0;
static NSInteger gSPKRejOriginY = 0;
static NSInteger gSPKRejKind = 0;
static NSInteger gSPKRejName = 0;
static NSInteger gSPKRejHidden = 0;
static CGFloat gSPKNearSide = 0;      // largest side thrown away by minSide
static CGFloat gSPKNearAspect = 0;    // aspect closest to the allowed band
static CGFloat gSPKChoseScore = 0;
static NSString *gSPKChose = @"-";

static void SPKAnchorResetCensus(void) {
    gSPKVisited = 0;
    gSPKCandidates = 0;
    gSPKRejSide = 0;
    gSPKRejAspect = 0;
    gSPKRejOriginY = 0;
    gSPKRejKind = 0;
    gSPKRejName = 0;
    gSPKRejHidden = 0;
    gSPKNearSide = 0;
    gSPKNearAspect = 0;
    gSPKChoseScore = 0;
    gSPKChose = @"-";
}

SPKAnchorQuery SPKAnchorQueryMake(void) {
    SPKAnchorQuery q;
    memset(&q, 0, sizeof(q));
    q.rejectControls = YES;
    q.rejectLabels = YES;
    q.requireVisible = YES;
    q.nameBonus = 400.0;
    q.imageBonus = 200.0;
    q.playerBonus = 300.0;
    return q;
}

/// An animated cover. Checked on the view's own layer only — a deep search
/// would find the player layer of an unrelated sibling and score it here.
static BOOL SPKAnchorHasPlayer(UIView *view) {
    if (!view) return NO;
    Class mtk = NSClassFromString(@"MTKView");
    if (mtk && [view isKindOfClass:mtk]) return YES;
    for (CALayer *layer in view.layer.sublayers) {
        NSString *name = NSStringFromClass([layer class]);
        if ([name containsString:@"AVPlayer"] || [name containsString:@"PlayerLayer"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL SPKAnchorNameMatches(UIView *view, const char *needle) {
    if (needle == NULL || needle[0] == '\0') return NO;
    NSString *name = [NSStringFromClass([view class]) lowercaseString];
    const char *hay = [name UTF8String];
    if (hay == NULL) return NO;
    return strstr(hay, needle) != NULL;
}

UIView *SPKAnchorResolve(UIView *root, UIView *coordinateSpace, SPKAnchorQuery q) {
    SPKAnchorResetCensus();
    if (!root) return nil;

    UIView *space = coordinateSpace ?: root;
    CGRect spaceBounds = space.bounds;
    CGFloat spaceW = CGRectGetWidth(spaceBounds);
    CGFloat spaceH = CGRectGetHeight(spaceBounds);

    NSInteger maxVisited = q.maxVisited > 0 ? q.maxVisited : 120;
    NSInteger maxChildren = q.maxChildrenPerView > 0 ? q.maxChildrenPerView : 24;

    UIView *best = nil;
    CGFloat bestScore = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0 && gSPKVisited < maxVisited) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        gSPKVisited++;

        // Children are enqueued whatever the verdict on the parent — the match
        // is frequently a grandchild of something that fails every constraint.
        NSInteger count = MIN((NSInteger)view.subviews.count, maxChildren);
        for (NSInteger i = 0; i < count; i++) {
            [queue addObject:view.subviews[(NSUInteger)i]];
        }

        if (view == root) continue;

        if (q.requireVisible && (view.hidden || view.alpha < 0.01)) {
            gSPKRejHidden++;
            continue;
        }
        if ((q.rejectControls && [view isKindOfClass:UIControl.class]) ||
            (q.rejectLabels && [view isKindOfClass:UILabel.class]) ||
            (q.rejectScrollViews && [view isKindOfClass:UIScrollView.class])) {
            gSPKRejKind++;
            continue;
        }

        BOOL named = SPKAnchorNameMatches(view, q.nameContains);
        if (q.requireName && !named) {
            gSPKRejName++;
            continue;
        }

        CGRect frame = [view convertRect:view.bounds toView:space];
        CGFloat w = CGRectGetWidth(frame);
        CGFloat h = CGRectGetHeight(frame);
        CGFloat side = MIN(w, h);

        if (q.minSide > 0 && side < q.minSide) {
            gSPKRejSide++;
            if (side > gSPKNearSide) gSPKNearSide = side;
            continue;
        }
        if (q.maxSideFraction > 0 && spaceW > 0 && side > spaceW * q.maxSideFraction) {
            gSPKRejSide++;
            continue;
        }
        if (q.maxOriginYFraction > 0 && spaceH > 0 &&
            CGRectGetMinY(frame) > spaceH * q.maxOriginYFraction) {
            gSPKRejOriginY++;
            continue;
        }
        if ((q.minAspect > 0 || q.maxAspect > 0) && h > 0.5) {
            CGFloat aspect = w / h;
            BOOL tooNarrow = (q.minAspect > 0 && aspect < q.minAspect);
            BOOL tooWide = (q.maxAspect > 0 && aspect > q.maxAspect);
            if (tooNarrow || tooWide) {
                gSPKRejAspect++;
                // Record the aspect that came closest to the allowed band, so a
                // band that is one notch too tight is visible in the report.
                CGFloat miss = tooNarrow ? (q.minAspect - aspect) : (aspect - q.maxAspect);
                CGFloat bestMiss = 0;
                if (gSPKNearAspect > 0) {
                    bestMiss = (q.minAspect > 0 && gSPKNearAspect < q.minAspect)
                        ? (q.minAspect - gSPKNearAspect)
                        : (gSPKNearAspect - q.maxAspect);
                }
                if (gSPKNearAspect <= 0 || miss < bestMiss) gSPKNearAspect = aspect;
                continue;
            }
        }

        gSPKCandidates++;
        BOOL isImage = [view isKindOfClass:UIImageView.class]
            && ((UIImageView *)view).image != nil;
        BOOL hasPlayer = SPKAnchorHasPlayer(view);
        CGFloat score = side
            + (named ? q.nameBonus : 0)
            + (isImage ? q.imageBonus : 0)
            + (hasPlayer ? q.playerBonus : 0);
        if (score > bestScore) {
            bestScore = score;
            best = view;
        }
    }

    if (best) {
        gSPKChose = NSStringFromClass([best class]);
        gSPKChoseScore = bestScore;
    }
    return best;
}

NSString *SPKAnchorReport(void) {
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"visited=%ld candidates=%ld chose=%@ score=%.0f",
        (long)gSPKVisited, (long)gSPKCandidates, gSPKChose, (double)gSPKChoseScore];
    NSMutableArray<NSString *> *rej = [NSMutableArray array];
    if (gSPKRejSide > 0) {
        [rej addObject:[NSString stringWithFormat:@"side=%ld (largest %.0f)",
                        (long)gSPKRejSide, (double)gSPKNearSide]];
    }
    if (gSPKRejAspect > 0) {
        [rej addObject:[NSString stringWithFormat:@"aspect=%ld (closest %.2f)",
                        (long)gSPKRejAspect, (double)gSPKNearAspect]];
    }
    if (gSPKRejOriginY > 0) {
        [rej addObject:[NSString stringWithFormat:@"originY=%ld", (long)gSPKRejOriginY]];
    }
    if (gSPKRejKind > 0) {
        [rej addObject:[NSString stringWithFormat:@"kind=%ld", (long)gSPKRejKind]];
    }
    if (gSPKRejName > 0) {
        [rej addObject:[NSString stringWithFormat:@"name=%ld", (long)gSPKRejName]];
    }
    if (gSPKRejHidden > 0) {
        [rej addObject:[NSString stringWithFormat:@"hidden=%ld", (long)gSPKRejHidden]];
    }
    if (rej.count > 0) {
        [out appendFormat:@" rejected: %@", [rej componentsJoinedByString:@" "]];
    }
    return out;
}

NSDictionary<NSString *, id> *SPKAnchorStats(void) {
    return @{
        @"visited": @((long)gSPKVisited),
        @"candidates": @((long)gSPKCandidates),
        @"chose": gSPKChose ?: @"-",
        @"score": @((double)gSPKChoseScore),
        @"rej_side": @((long)gSPKRejSide),
        @"rej_aspect": @((long)gSPKRejAspect),
        @"rej_originY": @((long)gSPKRejOriginY),
        @"rej_kind": @((long)gSPKRejKind),
        @"rej_name": @((long)gSPKRejName),
        @"rej_hidden": @((long)gSPKRejHidden),
        @"near_side": @((double)gSPKNearSide),
        @"near_aspect": @((double)gSPKNearAspect),
    };
}
