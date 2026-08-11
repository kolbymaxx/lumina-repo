#import "SPKOverlayWindow.h"

@implementation SPKPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Empty chrome must not eat the host app's taps — only real subviews count.
    return (hit == self) ? nil : hit;
}

@end

@implementation SPKOverlayWindow

+ (instancetype)overlayWithFrame:(CGRect)frame
                     windowScene:(UIWindowScene *)scene
                           level:(UIWindowLevel)level {
    // Never seed small and resize later; see the class comment.
    CGRect seed = frame;
    if (CGRectIsEmpty(seed) || seed.size.height < 10.0) {
        CGRect screen = UIScreen.mainScreen.bounds;
        seed = CGRectMake(0, CGRectGetHeight(screen) - 166.0,
                          CGRectGetWidth(screen), 166.0);
    }

    SPKOverlayWindow *overlay;
    if (scene) {
        overlay = [[self alloc] initWithWindowScene:scene];
        overlay.frame = seed;
    } else {
        overlay = [[self alloc] initWithFrame:seed];
    }

    overlay.windowLevel = level;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.userInteractionEnabled = YES;
    overlay.hidden = NO;

    UIViewController *root = [UIViewController new];
    SPKPassthroughView *pass = [[SPKPassthroughView alloc] initWithFrame:overlay.bounds];
    pass.backgroundColor = UIColor.clearColor;
    pass.opaque = NO;
    pass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.view = pass;
    overlay.rootViewController = root;

    return overlay;
}

- (UIView *)hostView {
    return self.rootViewController.view;
}

// The strip spans the full width, so every pixel that is not one of your
// subviews has to fall through or the band above the home indicator eats taps.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (void)makeKeyWindow {
}

- (void)makeKeyAndVisible {
    self.hidden = NO;
}

+ (UIWindowScene *)sceneForView:(UIView *)view {
    UIWindowScene *scene = view.window.windowScene;
    if (scene) return scene;

    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        if (candidate.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)candidate;
        }
    }
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)candidate;
    }
    return nil;
}

+ (CGRect)bottomStripFrameInScreen:(CGRect)screen
                     contentHeight:(CGFloat)contentHeight
                               gap:(CGFloat)gap
                        safeBottom:(CGFloat)safeBottom {
    CGFloat screenH = CGRectGetHeight(screen);
    CGFloat h = contentHeight + gap + safeBottom;
    // A rounding or safe-area surprise must never grow this toward full-screen.
    CGFloat cap = MAX(120.0, screenH * 0.30);
    h = MIN(h, cap);
    return CGRectMake(0, screenH - h, CGRectGetWidth(screen), h);
}

@end
