#import "NativeDownloadPresentation.h"
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "Core/SGCore.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static char bindingKey, registrationKey, pageStateKey;

static id objectGetter(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *error) { return nil; }
}

static NSString *pageURL(UIViewController *page) {
    // FTP is embedded in an IdentifiedPageHostingViewController. Its own responder
    // chain does not always expose the URI; walk its actual containment parents.
    for (NSUInteger depth = 0; page && depth < 12; depth++, page = page.parentViewController) {
        // Navigation containers report their current top page, not necessarily this
        // button's page during an interactive transition. Never borrow that identity.
        if ([page isKindOfClass:UINavigationController.class] || [page isKindOfClass:UITabBarController.class]) return nil;
        for (NSString *getter in @[@"spt_pageURI", @"pageURI", @"URI"]) {
            NSString *url = SGAutomaticSpotifyURL(objectGetter(page, getter));
            if ([url hasPrefix:@"https://open.spotify.com/playlist/"]) return url;
        }
    }
    return nil;
}

static UIViewController *owningPage(UIView *view) {
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 32; depth++, responder = responder.nextResponder)
        if ([responder isKindOfClass:UIViewController.class] && pageURL((id)responder)) return (id)responder;
    return nil;
}

static BOOL knownTarget(id object) {
    NSString *name = NSStringFromClass([object class]);
    return [name isEqual:@"_TtCOOOE32EncoreConsumerMobile_ElementsKitO19LegacyUI_ECMCoreKit10Components22GranularDownloadButton2UI7Private22GranularDownloadButton"] ||
        [name isEqual:@"_TtC28EncoreConsumerMobile_BaseKitP33_B18AD9CFD34D2E2EF5BE4AC1DDAEB28B14DownloadButton"];
}

@interface SGNativeDownloadArrow : UIControl
@property(nonatomic, strong) UIImageView *symbol;
@property(nonatomic, strong) CAShapeLayer *ring;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, copy) NSDictionary *renderedStatus;
- (void)showStatus:(NSDictionary *)status;
@end

@implementation SGNativeDownloadArrow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityIdentifier = @"spoti.download.playlist";
        _symbol = [UIImageView new]; _symbol.contentMode = UIViewContentModeScaleAspectFit;
        _symbol.userInteractionEnabled = NO; [self addSubview:_symbol];
        _ring = [CAShapeLayer layer]; _ring.fillColor = UIColor.clearColor.CGColor;
        _ring.lineWidth = 2; _ring.lineCap = kCALineCapRound; [self.layer addSublayer:_ring];
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES; _spinner.userInteractionEnabled = NO; [self addSubview:_spinner];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = MIN(28, MIN(self.bounds.size.width, self.bounds.size.height));
    _symbol.frame = CGRectMake((self.bounds.size.width-side)/2, (self.bounds.size.height-side)/2, side, side);
    _spinner.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat radius = MAX(4, side/2 - 1);
    _ring.frame = self.bounds;
    _ring.path = [UIBezierPath bezierPathWithArcCenter:_spinner.center radius:radius
        startAngle:-M_PI_2 endAngle:3*M_PI_2 clockwise:YES].CGPath;
}
- (void)showStatus:(NSDictionary *)status {
    if ([self.renderedStatus isEqual:status]) return;
    self.renderedStatus = [status copy];
    NSString *state = status[@"state"];
    BOOL ready = [state isEqual:@"ready"], error = [state isEqual:@"error"] || [state isEqual:@"partial"];
    BOOL incomplete = [state isEqual:@"incomplete"];
    BOOL running = [state isEqual:@"running"];
    CGFloat progress = MAX(0, MIN(1, [status[@"progress"] doubleValue]));
    UIColor *green = [UIColor colorWithRed:0.114 green:0.843 blue:0.376 alpha:1];
    UIColor *tint = ready ? green : incomplete ? UIColor.systemOrangeColor : error ? UIColor.systemRedColor : UIColor.lightGrayColor;
    NSString *symbol = ready || incomplete ? @"arrow.down.circle.fill" : [state isEqual:@"paused"] ? @"pause.circle" : @"arrow.down.circle";
    if (running && progress > 0) symbol = @"arrow.down";
    _symbol.image = [UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:25 weight:UIImageSymbolWeightRegular]];
    _symbol.tintColor = tint;
    _symbol.hidden = running && progress <= 0;
    _ring.hidden = !running || progress <= 0;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _ring.strokeColor = green.CGColor; _ring.strokeEnd = progress; [CATransaction commit];
    if (running && progress <= 0) [_spinner startAnimating]; else [_spinner stopAnimating];
    _spinner.color = tint;
    NSUInteger completed = [status[@"completed"] unsignedIntegerValue], total = [status[@"total"] unsignedIntegerValue];
    self.accessibilityLabel = ready ? @"Téléchargée sur cet iPhone" : incomplete ? @"Titres accessibles enregistrés ; liste possiblement incomplète" : error ? @"Téléchargement à compléter" :
        running ? @"Téléchargement en cours" : [state isEqual:@"paused"] ? @"Téléchargement en pause" : @"Télécharger sur cet iPhone";
    self.accessibilityValue = total ? [NSString stringWithFormat:@"%lu sur %lu morceaux", (unsigned long)completed, (unsigned long)total] : nil;
    self.accessibilityHint = error ? @"Ouvrir les morceaux manquants et ajouter une source" : incomplete ? @"Voir les titres récupérés et vérifier les morceaux manquants" : @"Ouvrir les téléchargements de cette playlist";
}
@end

@interface SGNativeDownloadBinding : NSObject
@property(nonatomic, weak) UIView *host;
@property(nonatomic, strong) SGNativeDownloadArrow *arrow;
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *nativeAlpha;
@property(nonatomic, strong) NSMapTable<UIGestureRecognizer *, NSNumber *> *nativeTaps;
@property(nonatomic) BOOL originalAccessibility;
@property(nonatomic, copy) NSString *url;
- (void)refresh;
- (void)restore;
@end

@implementation SGNativeDownloadBinding
- (instancetype)init {
    if ((self = [super init])) {
        _nativeAlpha = [NSMapTable weakToStrongObjectsMapTable];
        _nativeTaps = [NSMapTable weakToStrongObjectsMapTable];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:@"SGAutomaticDownloadsDidChange" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:NSUserDefaultsDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)changed:(NSNotification *)note {
    if (NSThread.isMainThread) [self refresh];
    else { __weak typeof(self) weak = self; dispatch_async(dispatch_get_main_queue(), ^{ [weak refresh]; }); }
}
- (void)refresh {
    UIView *host = self.host;
    if (!host) return;
    NSString *current = pageURL(owningPage(host));
    if (!SGAutomaticDownloadIsEnabled() || !current || ![current isEqual:self.url]) {
        [self restore]; return;
    }
    for (UIView *child in host.subviews) {
        if (child == self.arrow) continue;
        if (![self.nativeAlpha objectForKey:child]) [self.nativeAlpha setObject:@(child.alpha) forKey:child];
        // Alpha preserves native intrinsic sizes and stack layout during transitions.
        if (child.alpha != 0) child.alpha = 0;
    }
    for (UIGestureRecognizer *recognizer in host.gestureRecognizers) {
        if (![recognizer isKindOfClass:UITapGestureRecognizer.class]) continue;
        if (![self.nativeTaps objectForKey:recognizer]) [self.nativeTaps setObject:@(recognizer.enabled) forKey:recognizer];
        if (recognizer.enabled) recognizer.enabled = NO;
    }
    if (host.isAccessibilityElement) host.isAccessibilityElement = NO;
    if (host.subviews.lastObject != self.arrow) [host bringSubviewToFront:self.arrow];
    [self.arrow showStatus:SGAutomaticDownloadStatus(self.url) ?: @{@"state":@"idle"}];
}
- (void)restore {
    UIView *host = self.host;
    for (UIView *child in self.nativeAlpha.keyEnumerator) child.alpha = [[self.nativeAlpha objectForKey:child] doubleValue];
    for (UIGestureRecognizer *recognizer in self.nativeTaps.keyEnumerator) recognizer.enabled = [[self.nativeTaps objectForKey:recognizer] boolValue];
    host.isAccessibilityElement = self.originalAccessibility;
    [self.arrow removeFromSuperview];
    objc_setAssociatedObject(host, &bindingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)tapped:(SGNativeDownloadArrow *)sender {
    // Resolve again because collection header views can be recycled between playlists.
    NSString *current = pageURL(owningPage(self.host));
    if (![current isEqual:self.url]) { [self restore]; return; }
    // The engine owns start feedback, avoiding two haptics for the same tap.
    SGAutomaticDownloadEntity(current, sender);
}
@end

static void installArrow(UIView *view, NSString *url) {
    SGNativeDownloadBinding *existing = objc_getAssociatedObject(view, &bindingKey);
    if (existing && ![existing.url isEqual:url]) { [existing restore]; existing = nil; }
    if (existing) { [existing refresh]; return; }
    SGNativeDownloadBinding *binding = [SGNativeDownloadBinding new];
    binding.host = view; binding.url = url; binding.originalAccessibility = view.isAccessibilityElement;
    binding.arrow = [[SGNativeDownloadArrow alloc] initWithFrame:view.bounds];
    [binding.arrow addTarget:binding action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(view, &bindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [view addSubview:binding.arrow]; [binding refresh];
    SGLog(@"[SGAutoDownloads] native arrow attached class=%@ page=%@", NSStringFromClass(view.class), url);
}

static BOOL nativeDownloadCandidate(UIView *view) {
    if (objc_getAssociatedObject(view, &bindingKey) || objc_getAssociatedObject(view, &registrationKey)) return YES;
    if ([view isKindOfClass:UIControl.class]) {
        for (id target in ((UIControl *)view).allTargets) if (knownTarget(target)) return YES;
    }
    // Exact localized semantics only; never a substring of a song or playlist title.
    // The unique-match requirement below prevents replacing several per-track icons.
    BOOL button = [view isKindOfClass:UIControl.class] || (view.accessibilityTraits & UIAccessibilityTraitButton);
    if (!button || !view.userInteractionEnabled) return NO;
    NSString *label = [[view.accessibilityLabel ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [@[@"télécharger", @"téléchargé", @"téléchargée", @"télécharger cette playlist", @"télécharger la playlist",
        @"téléchargement en cours", @"supprimer des téléchargements", @"download", @"downloaded", @"download playlist",
        @"downloading", @"remove download", @"remove from downloads"] containsObject:label];
}

static void diagnostic(UIViewController *page, NSString *url, NSArray<UIView *> *candidates, NSString *result) {
    NSMutableArray *rows = [NSMutableArray array];
    for (UIView *view in candidates) {
        NSMutableArray *targets = [NSMutableArray array];
        if ([view isKindOfClass:UIControl.class]) for (id target in ((UIControl *)view).allTargets)
            [targets addObject:@{@"class":NSStringFromClass([target class]), @"actions":[((UIControl *)view) actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] ?: @[]}];
        [rows addObject:@{@"class":NSStringFromClass(view.class), @"label":view.accessibilityLabel ?: @"",
            @"frame":NSStringFromCGRect(view.frame), @"targets":targets}];
    }
    NSDictionary *record = @{@"pageClass":NSStringFromClass(page.class), @"pageURI":url, @"result":result, @"candidates":rows};
    static NSString *last;
    NSString *signature = record.description;
    if ([last isEqual:signature]) return;
    last = signature;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *cache = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *file = [cache URLByAppendingPathComponent:@"spoti-download-diagnostics.json"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [data writeToURL:file options:NSDataWritingAtomic error:nil]; });
}

@interface SGNativeDownloadPageState : NSObject
@property(nonatomic, weak) UIViewController *page;
@property(nonatomic) BOOL pending;
@property(nonatomic) CFTimeInterval lastScan;
@property(nonatomic, strong) UIBarButtonItem *fallback;
@property(nonatomic, strong) SGNativeDownloadArrow *fallbackArrow;
- (void)scan;
@end

@implementation SGNativeDownloadPageState
- (instancetype)init {
    if ((self = [super init])) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:@"SGAutomaticDownloadsDidChange" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:NSUserDefaultsDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)changed:(NSNotification *)note {
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{ SGNativeDownloadRefreshPage(weak.page); });
}
- (void)scan {
    self.pending = NO;
    self.lastScan = CACurrentMediaTime();
    UIViewController *page = self.page;
    UIView *root = page.viewIfLoaded;
    NSString *url = pageURL(page);
    BOOL enabled = SGAutomaticDownloadIsEnabled();
    if (!root.window || !url || !enabled) {
        [self removeFallback]; return;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root], *candidates = [NSMutableArray array], *suspects = [NSMutableArray array];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 1400) {
        UIView *view = queue.lastObject; [queue removeLastObject];
        if ([view isKindOfClass:SGNativeDownloadArrow.class] || view.hidden || view.alpha < .02) continue;
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        if (suspects.count < 12 && ([label containsString:@"download"] || [label containsString:@"télécharg"])) [suspects addObject:view];
        if (nativeDownloadCandidate(view)) {
            CGSize size = view.bounds.size;
            CGRect frame = [view convertRect:view.bounds toView:root];
            BOOL compact = size.width >= 16 && size.width <= 90 && size.height >= 16 && size.height <= 90;
            BOOL header = CGRectGetMidY(frame) < MIN(root.bounds.size.height * .78, 700);
            if (compact && header) { [candidates addObject:view]; continue; }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    if (candidates.count == 1) {
        [self removeFallback]; installArrow(candidates.firstObject, url);
        diagnostic(page, url, candidates, @"attached");
    } else {
        diagnostic(page, url, candidates.count ? candidates : suspects, candidates.count ? @"ambiguous-native-control" : @"native-control-not-found");
        // A navigation fallback is visible only when Spotify actually shows that bar.
        // Preserve existing items and never add a second button next to an identified arrow.
        if (!candidates.count && page.navigationController.topViewController == page && !page.navigationController.navigationBarHidden)
            [self installFallback];
        else [self removeFallback];
    }
}
- (void)installFallback {
    if (!self.fallback) {
        self.fallbackArrow = [[SGNativeDownloadArrow alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        [self.fallbackArrow addTarget:self action:@selector(fallbackTapped:) forControlEvents:UIControlEventTouchUpInside];
        self.fallback = [[UIBarButtonItem alloc] initWithCustomView:self.fallbackArrow];
        NSMutableArray *items = [self.page.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
        [items insertObject:self.fallback atIndex:0]; self.page.navigationItem.rightBarButtonItems = items;
    }
    [self.fallbackArrow showStatus:SGAutomaticDownloadStatus(pageURL(self.page)) ?: @{@"state":@"idle"}];
}
- (void)removeFallback {
    if (!self.fallback) return;
    NSMutableArray *items = [self.page.navigationItem.rightBarButtonItems mutableCopy];
    [items removeObjectIdenticalTo:self.fallback]; self.page.navigationItem.rightBarButtonItems = items;
    self.fallback = nil; self.fallbackArrow = nil;
}
- (void)fallbackTapped:(UIView *)sender { SGAutomaticDownloadEntity(pageURL(self.page), sender); }
@end

void SGNativeDownloadRefreshPage(UIViewController *page) {
    if (!NSThread.isMainThread || ![page isKindOfClass:UIViewController.class]) return;
    SGNativeDownloadPageState *state = objc_getAssociatedObject(page, &pageStateKey);
    if (!state) {
        if (!pageURL(page)) return;
        state = [SGNativeDownloadPageState new]; state.page = page;
        objc_setAssociatedObject(page, &pageStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.pending) return;
    state.pending = YES;
    __weak SGNativeDownloadPageState *weak = state;
    NSTimeInterval delay = MAX(0, .35 - (CACurrentMediaTime() - state.lastScan));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weak scan]; });
}

void SGNativeDownloadRegisterView(UIView *view) {
    if (!NSThread.isMainThread || ![view isKindOfClass:UIView.class]) return;
    objc_setAssociatedObject(view, &registrationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIViewController *page = owningPage(view);
    if (page) SGNativeDownloadRefreshPage(page);
}

BOOL SGNativeDownloadActivateWrapper(id wrapper) {
    UIView *view = objectGetter(wrapper, @"uiView");
    if (![view isKindOfClass:UIView.class]) return NO;
    SGNativeDownloadRegisterView(view);
    NSString *url = pageURL(owningPage(view));
    return url && SGAutomaticDownloadEntity(url, view);
}
