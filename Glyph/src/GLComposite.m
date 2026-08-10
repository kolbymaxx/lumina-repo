#import "GLComposite.h"

// -----------------------------------------------------------------------------
// Glyph Phase D — CoreGraphics bridge
// -----------------------------------------------------------------------------

/// Upper bound on the bitmap we will composite. Home screen icons top out
/// around 60pt @3x = 180px; this leaves headroom for larger icon formats while
/// refusing to burn memory or main-thread time on something pathological.
static const CGFloat kGLMaxCompositeEdge = 512.0;

UIImage *GLCompositeImage(UIImage *base, CGSize pointSize, CGFloat scale,
                          const GLRecipe *recipe) {
    if (!base || !recipe) return nil;
    if (pointSize.width < 1.0 || pointSize.height < 1.0) return nil;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = 2.0;

    size_t pxW = (size_t)llround(pointSize.width * scale);
    size_t pxH = (size_t)llround(pointSize.height * scale);
    if (pxW == 0 || pxH == 0) return nil;
    if ((CGFloat)pxW > kGLMaxCompositeEdge || (CGFloat)pxH > kGLMaxCompositeEdge) return nil;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return nil;

    // Byte order 32Big + PremultipliedLast puts the bytes in memory as
    // R, G, B, A — exactly the layout GLPixelKit expects.
    CGContextRef ctx = CGBitmapContextCreate(NULL, pxW, pxH, 8, pxW * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;

    UIImage *result = nil;
    @try {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGRect full = CGRectMake(0, 0, (CGFloat)pxW, (CGFloat)pxH);

        CGImageRef cg = base.CGImage;
        if (cg && base.imageOrientation == UIImageOrientationUp) {
            // No flip here on purpose. CGContextDrawImage into a bitmap context
            // already lands row 0 of the image on row 0 of the buffer; adding
            // the usual UIKit flip is what turns themed icons upside down.
            CGContextDrawImage(ctx, full, cg);
        } else {
            // No CGImage (CIImage-backed) or a non-Up orientation: let UIKit
            // resolve it. UIKit assumes y-down, so this path does need the flip.
            UIGraphicsPushContext(ctx);
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, 0, (CGFloat)pxH);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            [base drawInRect:full];
            CGContextRestoreGState(ctx);
            UIGraphicsPopContext();
        }

        uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(ctx);
        if (!pixels) {
            CGContextRelease(ctx);
            return nil;
        }

        GLUnpremultiplyInPlace(pixels, (int)pxW, (int)pxH);
        int touched = GLApplyRecipe(pixels, (int)pxW, (int)pxH, recipe);
        GLPremultiplyInPlace(pixels, (int)pxW, (int)pxH);

        if (!touched) {
            // Recipe was a passthrough. Returning nil here rather than a
            // needlessly re-encoded copy keeps the stock bitmap on screen.
            CGContextRelease(ctx);
            return nil;
        }

        CGImageRef out = CGBitmapContextCreateImage(ctx);
        if (out) {
            result = [UIImage imageWithCGImage:out
                                         scale:scale
                                   orientation:UIImageOrientationUp];
            CGImageRelease(out);
        }
    } @catch (__unused id e) {
        result = nil;   // fail closed
    }

    CGContextRelease(ctx);
    return result;
}
