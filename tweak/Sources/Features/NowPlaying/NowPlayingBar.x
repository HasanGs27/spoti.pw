// Design A: the album-coloured card becomes a glass card with rounded-square artwork and the
// progress line under the text. Spotify's own labels, buttons and gestures stay in place.
//
// The full screen player does not fade in over the bar, it morphs the bar's own card and artwork
// into the cover art, so for the length of that animation the bar is handed back: the rounding
// this file applied is undone, the album colour returns through Appearance/Repaint.x and the glass fades
// out. Without that the card animates from a transparent circle-artwork bar into the player and
// reads as a cut. Coming back the glass dissolves in as the artwork settles.
//
// Tree (trees/home.txt): NowPlayingBarContainerViewController.view 402x56 > NowPlayingBarViewController.view
//   at {8,0} 386x56 > UIView 386x56 (the painted card) > artwork 40x40 r=4, title stack,
//   progress line 370x2 at the bottom. The glass pane goes on the container's view.
#import "Core/SGCore.h"
#import "NowPlaying.h"

static const CGFloat kCardRadius = 18, kArtworkRadius = 10;
static const NSTimeInterval kFadeOut = 0.12, kFadeIn = 0.2;
static char kGlassKey, kRadiusKey, kProgressFrameKey, kProgressTargetKey, kLayoutPendingKey;

// The view carrying the glass pane, so the transition hooks reach it without the controllers.
static __weak UIView *sg_barGlassHost = nil;
// Open and close tapped in quick succession overlap; only the newest animation takes the bar back.
static NSUInteger sg_barTransition = 0;

// The karaoke card under the player puts its display link down while the player animates.
NSString *const SGPlayerTransitionNotification = @"spotifyglass.playerTransition";
NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
static CFTimeInterval sg_transitionEnds;
static NSUInteger sg_transitionGeneration;

CFTimeInterval SGPlayerTransitionEnds(void) {
    return sg_transitionEnds > CACurrentMediaTime() ? sg_transitionEnds : 0;
}

// The two animators hooked below are what the bar was written against, but the player of this
// Spotify never runs through them (no log of theirs has ever shown up), so the announcement comes
// from the appearance callbacks of a controller inside the player, which UIKit sends as the
// presentation or the dismissal begins, whatever animates it; the transition coordinator says when
// it is over, a cancelled swipe included.
static void announceTransition(UIViewController *unit, BOOL animated, NSString *what) {
    id<UIViewControllerTransitionCoordinator> coordinator = unit.transitionCoordinator;
    if (!animated || !coordinator) return;
    NSTimeInterval duration = MAX(0.1, coordinator.transitionDuration);
    NSUInteger generation = ++sg_transitionGeneration;
    sg_transitionEnds = CACurrentMediaTime() + duration;
    [NSNotificationCenter.defaultCenter postNotificationName:SGPlayerTransitionNotification object:nil];
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (generation != sg_transitionGeneration) return;
        sg_transitionEnds = 0;
        [NSNotificationCenter.defaultCenter postNotificationName:SGPlayerTransitionEndedNotification object:nil];
    }];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"player %@ over %.2fs, by its appearance callbacks", what, duration); });
}

static UIView *detectColoredCard(UIView *bar) {
    __block UIView *best = nil;
    __block CGFloat bestArea = 0;
    SGForEachView(bar, ^(UIView *v) {
        if ([v isKindOfClass:UIVisualEffectView.class] || SGKeepsColor(v) || !SGLooksLikeCard(v, v.layer.backgroundColor)) return;
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        if (area > bestArea) { bestArea = area; best = v; }
    });
    return best;
}

// Fallback when nothing is painted: the box around artwork, text and the small buttons.
static CGRect contentBounds(UIView *bar, UIView *target) {
    __block CGRect box = CGRectNull;
    SGForEachView(bar, ^(UIView *v) {
        if (v.hidden || v.alpha == 0) return;
        CGFloat width = v.bounds.size.width;
        BOOL content = ([v isKindOfClass:UIImageView.class] && width >= 20 && width <= 120)
            || [v isKindOfClass:UILabel.class]
            || ([v isKindOfClass:UIControl.class] && width <= 100);
        if (content) box = CGRectUnion(box, SGFrameIn(v, target));
    });
    return CGRectIsNull(box) ? box : CGRectInset(box, -10, -8);
}

// Spotify's own radius is kept the first time each view is rounded, so the bar can be put back
// the way it was laid out for the player's expand animation.
static void roundView(UIView *view, CGFloat radius) {
    if (!objc_getAssociatedObject(view, &kRadiusKey)) {
        objc_setAssociatedObject(view, &kRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static void restoreRounding(UIView *root) {
    SGForEachView(root, ^(UIView *v) {
        NSNumber *saved = objc_getAssociatedObject(v, &kRadiusKey);
        if (saved) v.layer.cornerRadius = saved.doubleValue;
        NSValue *frame = objc_getAssociatedObject(v, &kProgressFrameKey);
        if (frame) {
            v.frame = frame.CGRectValue;
            objc_setAssociatedObject(v, &kProgressFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(v, &kProgressTargetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

static void restyleCardContent(UIView *card) {
    __block CGFloat artworkRight = 0;
    SGForEachView(card, ^(UIView *v) {
        CGSize size = v.bounds.size;
        BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
        CGRect inCard = SGFrameIn(v, card);
        if (!square || v.layer.cornerRadius <= 0 || CGRectGetMinX(inCard) > card.bounds.size.width * 0.25) return;
        artworkRight = MAX(artworkRight, CGRectGetMaxX(inCard));
        for (UIView *u = v; u && u != card && CGSizeEqualToSize(u.bounds.size, size); u = u.superview) {
            roundView(u, MIN(kArtworkRadius, size.width / 4));
            u.clipsToBounds = YES;
        }
    });
    // Follow Spotify's actual text/button layout rather than a fixed 226 pt line.
    __block CGFloat textLeft = CGFLOAT_MAX;
    __block CGFloat controlsLeft = card.bounds.size.width - 12;
    SGForEachView(card, ^(UIView *v) {
        if (v.hidden || v.alpha <= 0) return;
        CGRect frame = SGFrameIn(v, card);
        CGFloat left = CGRectGetMinX(frame);
        if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length &&
            frame.size.width > 40 && left >= artworkRight + 2 && left < card.bounds.size.width * 0.65)
            textLeft = MIN(textLeft, left);
        if ([v isKindOfClass:UIControl.class] && frame.size.width >= 20 && frame.size.width <= 80 &&
            left > card.bounds.size.width * 0.55) controlsLeft = MIN(controlsLeft, left - 12);
    });
    if (textLeft == CGFLOAT_MAX) textLeft = MAX(52, artworkRight + 10);
    CGFloat right = MIN(controlsLeft, card.bounds.size.width - 104);
    if (right - textLeft < 40) return;
    SGForEachView(card, ^(UIView *v) {
        CGRect f = v.frame;
        NSValue *previousTarget = objc_getAssociatedObject(v, &kProgressTargetKey);
        if (!previousTarget && (f.size.height <= 0 || f.size.height > 3 || f.size.width < 200 ||
            v.superview.bounds.size.height < 40 || CGRectGetMinY(SGFrameIn(v, card)) < card.bounds.size.height - 8)) return;
        CGRect target = [card convertRect:CGRectMake(textLeft, card.bounds.size.height - 6, right - textLeft, 2) toView:v.superview];
        if (CGRectEqualToRect(f, target)) return;
        if (!previousTarget || !CGRectEqualToRect(f, previousTarget.CGRectValue))
            objc_setAssociatedObject(v, &kProgressFrameKey, [NSValue valueWithCGRect:f], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &kProgressTargetKey, [NSValue valueWithCGRect:target], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        v.frame = target;
    });
}

static BOOL insideClass(UIView *view, NSString *marker) {
    for (UIView *v = view; v; v = v.superview) if ([NSStringFromClass(v.class) containsString:marker]) return YES;
    return NO;
}

// trees/test6.txt: the button row is a UIStackView holding Connect_EntryPointsImpl.ConnectStateView
// (the connected device) and .ConnectButtonView, each wrapped; hiding the wrapper closes the gap.
// The ConnectStateView under the title ("playing on ...") sits in InformationContainer and stays.
static void hideConnectButton(UIView *bar) {
    if (!SGHidden(SGHideBarConnect)) return;
    SGForEachView(bar, ^(UIView *v) {
        NSString *name = NSStringFromClass(v.class);
        if (![name containsString:@"ConnectButtonView"] && ![name containsString:@"ConnectStateView"]) return;
        if (insideClass(v, @"InformationContainer")) return;
        UIView *item = v;
        while (item.superview && ![item.superview isKindOfClass:UIStackView.class]) item = item.superview;
        if (item.superview && !item.hidden) item.hidden = YES;
    });
}

static char kOfflineOffsetKey, kOfflineTransformKey;

static BOOL visibleInWindow(UIView *view) {
    if (!view.window) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview)
        if (ancestor.hidden || ancestor.alpha < 0.01) return NO;
    return YES;
}

// The system tab bar can grow above Spotify's compact bar when an offline
// banner changes the safe area. Move the complete mini-player only by the
// measured overlap, including its glass and artwork, then restore it online.
static void spaceOfflineBar(UIView *bar) {
    if (!bar.window) return;
    CGAffineTransform transform = bar.transform;
    NSValue *previous = objc_getAssociatedObject(bar, &kOfflineTransformKey);
    CGFloat oldOffset = previous && CGAffineTransformEqualToTransform(transform, previous.CGAffineTransformValue)
        ? [objc_getAssociatedObject(bar, &kOfflineOffsetKey) doubleValue] : 0;
    transform.ty -= oldOffset;
    __block BOOL offline = NO;
    __block UIView *tabs = nil;
    SGForEachView(bar.window, ^(UIView *view) {
        if (!visibleInWindow(view)) return;
        if ([NSStringFromClass(view.class) isEqualToString:@"SGSystemTabBar"]) tabs = view;
        if ([view isKindOfClass:UILabel.class]) {
            NSString *text = ((UILabel *)view).text.lowercaseString;
            if ([text containsString:@"vous êtes en mode hors connexion"] ||
                [text isEqualToString:@"you're offline"] || [text isEqualToString:@"you’re offline"]) offline = YES;
        }
    });
    CGFloat offset = 0;
    if (offline && tabs && !sg_nowPlayingStock) {
        CGRect player = [bar convertRect:bar.bounds toView:bar.window];
        player.origin.y -= oldOffset;
        CGRect navigation = [tabs convertRect:tabs.bounds toView:bar.window];
        CGFloat overlap = CGRectGetMaxY(player) + 6 - CGRectGetMinY(navigation);
        if (overlap > 0 && overlap < 96 && CGRectGetMinY(player) < CGRectGetMaxY(navigation)) offset = -overlap;
    }
    transform.ty += offset;
    if (!CGAffineTransformEqualToTransform(bar.transform, transform)) bar.transform = transform;
    objc_setAssociatedObject(bar, &kOfflineOffsetKey, @(offset), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bar, &kOfflineTransformKey, [NSValue valueWithCGAffineTransform:transform], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void styleNowPlayingBar(UIViewController *container) {
    if (!SGFlag(SGKeyNowPlayingBar, NO)) return;
    spaceOfflineBar(container.view);
    UIViewController *barVC = container.childViewControllers.firstObject;
    UIView *bar = barVC.viewIfLoaded ?: container.view;
    sg_nowPlayingRoot = bar;
    sg_barGlassHost = container.view;
    // Mid-transition the bar is Spotify's; its layout runs untouched so the progress line, the
    // corners and the paint are whatever the animation needs.
    if (sg_nowPlayingStock) return;

    UIView *card = sg_nowPlayingCard;
    if (!card || !SGIsInside(card, bar)) card = sg_nowPlayingCard = detectColoredCard(bar);

    container.view.layer.backgroundColor = NULL;
    SGStripBackgrounds(bar);

    CGRect frame = card ? SGFrameIn(card, container.view) : contentBounds(bar, container.view);
    if (CGRectIsNull(frame)) return;
    frame.size.height = MIN(frame.size.height, 80);
    if (frame.size.height < 30 || frame.size.width < 100) return;

    CGFloat radius = MIN(kCardRadius, frame.size.height / 2);
    if (card) {
        roundView(card, radius);
        restyleCardContent(card);
        // Reapply once after any pending stock child layout, without forcing it to
        // immediately lay the progress view back across the card's bottom edge.
        if (![objc_getAssociatedObject(card, &kLayoutPendingKey) boolValue]) {
            objc_setAssociatedObject(card, &kLayoutPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView *weakCard = card;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIView *current = weakCard;
                if (!current) return;
                objc_setAssociatedObject(current, &kLayoutPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (!sg_nowPlayingStock && current == sg_nowPlayingCard && current.window) restyleCardContent(current);
            });
        }
    }

    UIVisualEffectView *glass = SGGlassFor(container.view, &kGlassKey);
    glass.frame = frame;
    SGShapeGlass(glass, radius, NO);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"now playing card %@ at %@ (bar %@, container %@)", card.class, NSStringFromCGRect(frame),
              NSStringFromCGRect(bar.frame), NSStringFromCGRect(container.view.bounds));
    });
}

#pragma mark - the player's expand and close animations

// `stock` gives the bar back to Spotify for the length of an animation, and takes it again after.
static void barStock(BOOL stock, NSTimeInterval fade) {
    UIView *host = sg_barGlassHost;
    if (!host || !SGFlag(SGKeyNowPlayingBar, NO) || sg_nowPlayingStock == stock) return;
    sg_nowPlayingStock = stock;

    if (stock) {
        restoreRounding(host);
        if (sg_nowPlayingCardColor) sg_nowPlayingCard.layer.backgroundColor = sg_nowPlayingCardColor;
    }
    // A layout pass with the flag already set puts the bar in the state the flag asks for: the
    // hook above either stands aside or restyles from scratch.
    [host setNeedsLayout];
    [host layoutIfNeeded];

    UIVisualEffectView *glass = objc_getAssociatedObject(host, &kGlassKey);
    [UIView animateWithDuration:fade animations:^{ glass.alpha = stock ? 0 : 1; }];
}

// Both animators are UIViewControllerAnimatedTransitioning. The bar is Spotify's own from the
// first frame and glass again once the animation has had its duration; on the way up it is behind
// the player by then, on the way down the dissolve lands with the artwork.
static void playerTransition(id<UIViewControllerAnimatedTransitioning> animator, id<UIViewControllerContextTransitioning> context) {
    NSTimeInterval duration = MAX(0.1, [animator transitionDuration:context]);
    NSUInteger generation = ++sg_barTransition;
    sg_transitionEnds = CACurrentMediaTime() + duration;
    [NSNotificationCenter.defaultCenter postNotificationName:SGPlayerTransitionNotification object:nil];
    barStock(YES, MIN(kFadeOut, duration / 3));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == sg_barTransition) barStock(NO, kFadeIn);
    });
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"player transition %@ over %.2fs", [animator class], duration); });
}

%hook _TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    styleNowPlayingBar((UIViewController *)self);
}
%end

%hook SGSystemTabBar
- (void)layoutSubviews {
    %orig;
    if (SGFlag(SGKeyNowPlayingBar, NO)) spaceOfflineBar(sg_barGlassHost);
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    hideConnectButton(((UIViewController *)self).view);
    UIViewController *parent = ((UIViewController *)self).parentViewController;
    if ([NSStringFromClass(parent.class) containsString:@"NowPlayingBarContainer"]) styleNowPlayingBar(parent);
}
%end

%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    announceTransition((UIViewController *)self, animated, @"opens");
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    announceTransition((UIViewController *)self, animated, @"closes");
}
%end

%hook _TtC23NowPlaying_ViewPageImpl35ShowFullscreenAnimatedTransitioning
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    playerTransition((id)self, context);
    %orig;
}
%end

%hook _TtC23NowPlaying_ViewPageImpl36CloseFullScreenAnimatedTransitioning
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    playerTransition((id)self, context);
    %orig;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[
        @"_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController",
        @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",
        @"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController",
        @"_TtC23NowPlaying_ViewPageImpl35ShowFullscreenAnimatedTransitioning",
        @"_TtC23NowPlaying_ViewPageImpl36CloseFullScreenAnimatedTransitioning",
    ]);
}
