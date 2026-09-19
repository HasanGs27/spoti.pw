#import "PlayerNativeSpeed.h"
#import "PlayerNativeSpeedModel.h"
#import "Core/SGCore.h"
#import <math.h>
#import <string.h>

@protocol SGNativeSpeedPlayer <NSObject>
- (id)state;
- (id)setOptions:(id)options;
@end

static __weak id<SGNativeSpeedPlayer> observedPlayer;
static NSUInteger presentationGeneration;

static id readState(id<SGNativeSpeedPlayer> player) {
    @try {
        NSMethodSignature *signature = [(NSObject *)player methodSignatureForSelector:@selector(state)];
        if (![player isKindOfClass:NSClassFromString(@"SPTEsperantoPlayer")] || signature.numberOfArguments != 2 ||
            !signature.methodReturnType || strcmp(signature.methodReturnType, @encode(id)) != 0) return nil;
        return player.state;
    } @catch (NSException *exception) { return nil; }
}
static BOOL commandAvailable(id player) {
    @try {
        NSMethodSignature *signature = [player methodSignatureForSelector:@selector(setOptions:)];
        return [player respondsToSelector:@selector(setOptions:)] && signature.numberOfArguments == 3 &&
            signature.methodReturnType && strcmp(signature.methodReturnType, @encode(id)) == 0 &&
            strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) == 0;
    } @catch (NSException *exception) { return NO; }
}
static NSString *rateLabel(NSNumber *rate) {
    return [[NSString stringWithFormat:@"×%.2f", rate.doubleValue] stringByReplacingOccurrencesOfString:@"." withString:@","];
}
static UILabel *speedLabel(UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new]; label.font = font; label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter; label.numberOfLines = 0;
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

@interface SGPlayerNativeSpeedController : UIViewController
@property(nonatomic, strong) id<SGNativeSpeedPlayer> player;
@property(nonatomic, copy) NSDictionary *snapshot;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL stopped;
@property(nonatomic, strong) SGPlayerNativeSpeedCommandQueue *commands;
@property(nonatomic, strong) id commandTask;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UILabel *requestedLabel;
@property(nonatomic, strong) UILabel *confirmedLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, copy) NSArray<UIButton *> *presets;
@end

@implementation SGPlayerNativeSpeedController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vitesse";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Fermer"
        style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    self.commands = [SGPlayerNativeSpeedCommandQueue new];
    self.requestedLabel = speedLabel([UIFont monospacedDigitSystemFontOfSize:42 weight:UIFontWeightSemibold], UIColor.labelColor);
    self.confirmedLabel = speedLabel([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.secondaryLabelColor);
    self.confirmedLabel.accessibilityIdentifier = @"spoti.player.speed.confirmed";
    self.statusLabel = speedLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], UIColor.secondaryLabelColor);
    UILabel *track = speedLabel([UIFont preferredFontForTextStyle:UIFontTextStyleHeadline], UIColor.labelColor);
    track.text = self.snapshot[@"title"]; track.numberOfLines = 2;
    self.slider = [UISlider new]; self.slider.minimumValue = 0.5; self.slider.maximumValue = 2;
    self.slider.continuous = YES;
    self.slider.minimumTrackTintColor = [UIColor colorWithRed:0.12 green:0.84 blue:0.38 alpha:1];
    self.slider.accessibilityLabel = @"Vitesse de lecture";
    self.slider.accessibilityIdentifier = @"spoti.player.speed.slider";
    [self.slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sliderReleased:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    NSNumber *initial = SGPlayerNativeSpeedNormalizedRate(self.snapshot[@"rate"]) ?: @1;
    [self showRequested:initial moveSlider:YES];
    UILabel *minimum = speedLabel([UIFont preferredFontForTextStyle:UIFontTextStyleCaption1], UIColor.secondaryLabelColor);
    UILabel *maximum = speedLabel([UIFont preferredFontForTextStyle:UIFontTextStyleCaption1], UIColor.secondaryLabelColor);
    minimum.text = @"×0,50"; minimum.textAlignment = NSTextAlignmentLeft;
    maximum.text = @"×2,00"; maximum.textAlignment = NSTextAlignmentRight;
    UIStackView *ends = [[UIStackView alloc] initWithArrangedSubviews:@[minimum, maximum]];
    ends.distribution = UIStackViewDistributionFillEqually;
    NSMutableArray *buttons = [NSMutableArray array];
    NSArray<NSNumber *> *rates = SGPlayerNativeSpeedRates();
    for (NSUInteger index = 0; index < rates.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *config = [UIButtonConfiguration tintedButtonConfiguration];
        config.title = rateLabel(rates[index]); config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.baseForegroundColor = UIColor.labelColor;
        config.baseBackgroundColor = UIColor.secondarySystemFillColor;
        config.contentInsets = NSDirectionalEdgeInsetsMake(8, 4, 8, 4);
        button.configuration = config; button.tag = (NSInteger)index;
        button.accessibilityLabel = [@"Vitesse " stringByAppendingString:config.title];
        [button addTarget:self action:@selector(presetPressed:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:button];
    }
    self.presets = buttons;
    UIStackView *shortcuts = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    shortcuts.spacing = 6; shortcuts.distribution = UIStackViewDistributionFillEqually;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:
        @[track, self.requestedLabel, self.confirmedLabel, self.slider, ends, shortcuts, self.statusLabel]];
    content.axis = UILayoutConstraintAxisVertical; content.spacing = 12;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO; content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll]; [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:)
        name:UIApplicationWillResignActiveNotification object:nil];
    id state = [self checkedState];
    if (state) self.statusLabel.text = @"Déplace le curseur pendant l’écoute. La vitesse appliquée reste affichée séparément.";
}
- (void)dealloc {
    [_timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stop];
}
- (void)close { [self stop]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)backgrounded:(NSNotification *)notification {
    [self stop]; [self setControlsEnabled:NO];
    self.statusLabel.text = @"Rouvre Vitesse pour reprendre les réglages de la lecture actuelle.";
}
- (void)stopTimer { [self.timer invalidate]; self.timer = nil; }
- (void)stop { self.stopped = YES; [self stopTimer]; [self.commands cancel]; self.commandTask = nil; }
- (void)setControlsEnabled:(BOOL)enabled {
    self.slider.enabled = enabled;
    for (UIButton *button in self.presets) button.enabled = enabled;
}
- (void)showRequested:(NSNumber *)rate moveSlider:(BOOL)move {
    self.requestedLabel.text = rateLabel(rate);
    self.slider.accessibilityValue = [NSString stringWithFormat:@"%@ fois", [rateLabel(rate) substringFromIndex:1]];
    if (move) [self.slider setValue:rate.floatValue animated:NO];
}
- (id)checkedState {
    id state = readState(self.player);
    if (!SGPlayerNativeSpeedSamePlayback(self.snapshot, state)) {
        [self stop]; [self setControlsEnabled:NO];
        self.statusLabel.text = @"Le morceau a changé. Rouvre Vitesse pour la lecture actuelle.";
        return nil;
    }
    NSDictionary *fresh = SGPlayerNativeSpeedSnapshot(state);
    double observed = [fresh[@"rate"] doubleValue];
    self.confirmedLabel.text = [fresh[@"available"] boolValue] && observed > 0 ?
        [@"Lecture : " stringByAppendingString:rateLabel(@(observed))] : @"Vitesse actuelle non confirmée";
    NSString *reason = nil;
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SGNativeSpeedProbeDisabled"])
        reason = @"Le réglage de vitesse a été désactivé dans les options de l’application.";
    else if (![fresh[@"available"] boolValue] || !commandAvailable(self.player))
        reason = @"Ce lecteur ne fournit pas de réglage de vitesse compatible.";
    else if (![fresh[@"allowed"] boolValue])
        reason = @"Spotify n’autorise pas le changement de vitesse pour cette lecture ou cet appareil de sortie.";
    if (reason) {
        [self stop]; [self setControlsEnabled:NO]; self.statusLabel.text = reason; return nil;
    }
    [self setControlsEnabled:YES];
    return state;
}
- (BOOL)active {
    return !self.stopped && self.generation == presentationGeneration && self.viewIfLoaded.window &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}
- (void)startTimer {
    if (self.timer) return;
    __weak SGPlayerNativeSpeedController *weak = self;
    self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { [weak tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)requestRate:(NSNumber *)rate immediate:(BOOL)immediate {
    if (![self active]) return;
    NSNumber *normalized = SGPlayerNativeSpeedNormalizedRate(rate);
    if (!normalized) return;
    [self showRequested:normalized moveSlider:!self.slider.tracking];
    // Keep drag callbacks light. Native identity/permissions and the observed
    // rate are checked by the coalesced tick, before every actual command.
    [self.commands requestRate:normalized atTime:NSProcessInfo.processInfo.systemUptime immediate:immediate];
    self.statusLabel.text = @"Réglage en cours…";
    [self startTimer];
    if (immediate) [self tick];
}
- (void)sliderChanged:(UISlider *)slider { [self requestRate:@(slider.value) immediate:NO]; }
- (void)sliderReleased:(UISlider *)slider { [self requestRate:@(slider.value) immediate:YES]; }
- (void)presetPressed:(UIButton *)button {
    NSArray *rates = SGPlayerNativeSpeedRates();
    if (button.tag < 0 || (NSUInteger)button.tag >= rates.count) return;
    [self requestRate:rates[(NSUInteger)button.tag] immediate:YES];
}
- (void)tick {
    if (![self active]) { [self stop]; return; }
    id state = [self checkedState];
    if (!state) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSNumber *sent = self.commands.inFlightRate;
    if (sent) {
        if (SGPlayerNativeSpeedObserved(self.snapshot, state, sent)) {
            [self.commands complete]; self.commandTask = nil;
            if (!self.commands.pendingRate) {
                self.statusLabel.text = @"Vitesse appliquée par le lecteur.";
                [self showRequested:sent moveSlider:!self.slider.tracking];
            }
        } else if ([self.commands timedOutAtTime:now]) {
            [self.commands cancel]; self.commandTask = nil; [self stopTimer];
            NSNumber *actual = SGPlayerNativeSpeedNormalizedRate(SGPlayerNativeSpeedSnapshot(state)[@"rate"]);
            if (actual) [self showRequested:actual moveSlider:YES];
            self.statusLabel.text = [NSString stringWithFormat:@"Spotify n’a pas confirmé %@. La vitesse réellement lue est indiquée ci-dessus.", rateLabel(sent)];
            return;
        } else return;
    }
    NSNumber *next = [self.commands takeRateAtTime:now];
    if (!next) {
        if (!self.commands.pendingRate) [self stopTimer];
        return;
    }
    if (SGPlayerNativeSpeedObserved(self.snapshot, state, next)) {
        [self.commands complete]; [self stopTimer];
        self.statusLabel.text = @"Vitesse appliquée par le lecteur.";
        [self showRequested:next moveSlider:!self.slider.tracking];
        return;
    }
    id options = SGPlayerNativeSpeedOptions(state, next);
    if (!options || !commandAvailable(self.player)) {
        [self stop]; [self setControlsEnabled:NO];
        self.statusLabel.text = @"Le lecteur n’autorise plus ce réglage.";
        return;
    }
    @try { self.commandTask = [self.player setOptions:options]; }
    @catch (NSException *exception) {
        [self.commands cancel]; [self stopTimer];
        self.statusLabel.text = @"Le lecteur a refusé cette vitesse. Aucun autre réglage n’a été modifié.";
    }
}
@end

void SGPresentPlayerNativeSpeed(UIViewController *owner) {
    SGPresentPlayerNativeSpeedForTrack(owner, nil);
}
void SGPresentPlayerNativeSpeedForTrack(UIViewController *owner, NSString *expectedURI) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ SGPresentPlayerNativeSpeedForTrack(owner, expectedURI); }); return; }
    if (!owner || owner.presentedViewController) return;
    id<SGNativeSpeedPlayer> player = observedPlayer;
    NSDictionary *snapshot = SGPlayerNativeSpeedSnapshot(readState(player));
    if (!snapshot || (expectedURI && ![expectedURI isEqual:snapshot[@"trackURI"]])) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Vitesse"
            message:@"Lance un morceau, puis rouvre son lecteur pour régler sa vitesse." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [owner presentViewController:alert animated:YES completion:nil];
        return;
    }
    SGPlayerNativeSpeedController *page = [SGPlayerNativeSpeedController new];
    page.player = player; page.snapshot = snapshot; page.generation = ++presentationGeneration;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    navigation.sheetPresentationController.prefersGrabberVisible = YES;
    [owner presentViewController:navigation animated:YES completion:nil];
}

%hook SPTEsperantoPlayer
- (id)state {
    id result = %orig;
    // Capture an existing player only. No creation, commands or recurring work
    // during normal playback; the panel checks only after an explicit gesture.
    if ([result isKindOfClass:NSClassFromString(@"SPTPlayerState")]) observedPlayer = (id<SGNativeSpeedPlayer>)self;
    return result;
}
%end

%ctor { %init; }
