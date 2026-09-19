#import "PlayerAudioTools.h"
#import "PlayerAudioToolsModel.h"
#import "PlayerNativeSpeed.h"
#import "AudioVariantsPage.h"
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "AutomaticDownloadState.h"
#import "LocalImportsPage.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Core/SGCore.h"

static NSString *const preparationKey = @"spotifyglass.playerAudio.preparations.v1";
@interface SGPlayerToolsNavigation : UINavigationController
- (void)closeTools;
@end
@implementation SGPlayerToolsNavigation
- (void)closeTools { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

@interface SGPlayerAudioPreparationPage : SGPage <NSURLSessionDataDelegate>
@property(nonatomic, copy) NSString *uri;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSDictionary *record;
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) UIView *note;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, copy) void (^reply)(id, NSInteger);
@property(nonatomic) NSInteger responseCode;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger retryAttempt;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL wantsOpen;
- (void)connect;
- (void)handleJob:(NSDictionary *)job;
@end

@implementation SGPlayerAudioPreparationPage
- (instancetype)initWithURI:(NSString *)uri kind:(NSString *)kind title:(NSString *)title {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.uri = uri; self.kind = kind; self.title = [kind isEqual:@"speed"] ? @"Vitesse — copie audio" : @"Sans voix";
        self.record = SGPlayerAudioPreparationRecord([NSUserDefaults.standardUserDefaults dictionaryForKey:preparationKey][uri], uri);
        self.message = SGAutomaticSpotifyURL(uri) ? @"Le PC prépare ce morceau, puis la version choisie. La lecture actuelle continue ; aucun effet n'est encore appliqué." :
            @"La copie d'origine de ce fichier local n'a pas été retrouvée sur le PC. Ajoute sa source dans les ajouts personnels pour pouvoir la traiter.";
        self.note = SGNote([NSString stringWithFormat:@"%@\n%@", title.length ? title : @"Morceau sélectionné",
            [kind isEqual:@"speed"] ? @"Le PC crée une copie à la vitesse choisie, en conservant la hauteur de la voix. Ce réglage ne change pas instantanément la lecture actuelle." :
                @"La séparation de la voix utilise le PC associé. Une copie distincte est créée ; le résultat dépend de l'enregistrement."]);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    } return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self.session invalidateAndCancel]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 82;
    self.tableView.tableHeaderView = self.note;
    [self ensureSession];
}
- (void)ensureSession {
    if (self.session) return;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40; config.allowsCellularAccess = NO;
    config.URLCache = nil; config.HTTPCookieStorage = nil;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; self.visible = YES; [self ensureSession];
    if (self.record && ![self.record[@"paused"] boolValue] && !SGPlayerAudioPreparedSource(self.record[@"job"], self.uri) &&
        ![@[@"error", @"partial", @"interrupted", @"complete"] containsObject:self.record[@"job"][@"state"] ?: @""]) [self connect];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated]; self.visible = NO; [self suspend];
    [self.session invalidateAndCancel]; self.session = nil;
}
- (void)viewWillLayoutSubviews { [super viewWillLayoutSubviews]; SGFitNote(self.tableView, self.note, 12, 12); }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; SGInsetForBars(self.tableView); }
- (void)suspend { self.generation++; [self.task cancel]; self.task = nil; self.reply = nil; self.body = nil; self.busy = NO; self.wantsOpen = NO; }
- (void)inactive:(NSNotification *)note { [self suspend]; }
- (void)active:(NSNotification *)note {
    if (self.visible && self.record && ![self.record[@"paused"] boolValue] && !SGPlayerAudioPreparedSource(self.record[@"job"], self.uri) &&
        ![@[@"error", @"partial", @"interrupted", @"complete"] containsObject:self.record[@"job"][@"state"] ?: @""]) [self connect];
}
- (BOOL)save:(NSDictionary *)record {
    NSDictionary *valid = SGPlayerAudioPreparationRecord(record, self.uri); if (!valid) return NO;
    id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:preparationKey];
    NSMutableDictionary *all = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    if (!all[self.uri] && all.count >= 40) {
        for (NSString *key in [all.allKeys copy]) {
            NSDictionary *old = SGPlayerAudioPreparationRecord(all[key], key);
            if (!old || [@[@"complete", @"error", @"partial", @"interrupted"] containsObject:old[@"job"][@"state"] ?: @""]) [all removeObjectForKey:key];
            if (all.count < 40) break;
        }
        if (all.count >= 40) { self.message = @"Trop de préparations attendent encore. Termine une demande avant d'en ajouter une nouvelle."; return NO; }
    }
    all[self.uri] = valid; [NSUserDefaults.standardUserDefaults setObject:all forKey:preparationKey]; self.record = valid; return YES;
}
- (void)json:(NSString *)path request:(NSDictionary *)body reply:(void (^)(id, NSInteger))reply {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self.root URLByAppendingPathComponent:path]];
    if (body) { request.HTTPMethod = @"POST"; request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil]; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; }
    self.body = [NSMutableData data]; self.responseCode = 0; self.reply = reply;
    self.task = [self.session dataTaskWithRequest:request]; [self.task resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion { completion(nil); }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if (task != self.task) { completion(NSURLSessionResponseCancel); return; }
    self.responseCode = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    completion(response.expectedContentLength > 128 * 1024 ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (task != self.task) return;
    if (data.length > 128 * 1024 - self.body.length) { [task cancel]; return; } [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task != self.task) return;
    void (^reply)(id, NSInteger) = self.reply;
    id value = !error && self.body.length ? [NSJSONSerialization JSONObjectWithData:self.body options:0 error:nil] : nil;
    NSInteger code = error ? 0 : self.responseCode;
    self.task = nil; self.reply = nil; self.body = nil; if (reply) reply(value, code);
}
- (void)later:(NSTimeInterval)delay block:(void (^)(SGPlayerAudioPreparationPage *))block {
    NSUInteger generation = self.generation; __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGPlayerAudioPreparationPage *page = weak;
        if (page && page.visible && page.generation == generation && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) block(page);
    });
}
- (void)unavailable {
    self.busy = NO; self.message = @"En attente du PC. Ta demande est conservée. Allume-le sur le même réseau et garde cette page ouverte.";
    [self.tableView reloadData];
    [self later:SGAutomaticDownloadRetryDelay(self.retryAttempt++) block:^(SGPlayerAudioPreparationPage *page) { [page connect]; }];
}
- (void)connect {
    if (self.busy || !self.record || [self.record[@"paused"] boolValue] || !self.visible || self.presentedViewController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.busy = YES; self.message = @"Connexion au PC associé."; [self.tableView reloadData];
    NSUInteger generation = ++self.generation; __weak typeof(self) weak = self;
    SGAutomaticPrepareAudioToolsPC(^(NSURL *root, NSString *error) {
        SGPlayerAudioPreparationPage *page = weak; if (!page || page.generation != generation) return;
        if (!root) { [page unavailable]; return; } page.root = root;
        NSString *jobID = page.record[@"job"][@"id"];
        [page json:jobID ? [@"jobs/" stringByAppendingString:jobID] : @"jobs" request:jobID ? nil : page.record[@"request"] reply:^(id value, NSInteger code) {
            SGPlayerAudioPreparationPage *active = weak; if (!active || active.generation != generation) return;
            if (!code || code >= 500) { [active unavailable]; return; }
            NSDictionary *next = (code == 200 || code == 201 || code == 202) ? SGPlayerAudioPreparationRecord(@{@"request":active.record[@"request"], @"job":value ?: @{}}, active.uri) : nil;
            if (!next || (jobID && ![next[@"job"][@"id"] isEqual:jobID])) {
                active.busy = NO; active.message = @"Le PC n'a pas confirmé ce morceau. Touche Réessayer, ou choisis une source dans les téléchargements.";
                if (code == 404) [active save:@{@"request":active.record[@"request"]}];
                [active.tableView reloadData]; return;
            }
            active.retryAttempt = 0; [active handleJob:next[@"job"]];
        }];
    });
}
- (void)openSource:(NSDictionary *)source {
    self.wantsOpen = NO;
    SGShowPage(self, SGAudioVariantsPageCreateForKind(source, self.kind));
}
- (void)handleJob:(NSDictionary *)job {
    self.busy = NO;
    if (![self save:@{@"request":self.record[@"request"],@"job":job}]) { self.message = @"Le suivi n'a pas pu être enregistré. Réessaie."; [self.tableView reloadData]; return; }
    NSDictionary *source = SGPlayerAudioPreparedSource(job, self.uri);
    if (source) {
        self.message = @"Morceau prêt sur le PC. Choisis maintenant la version à préparer.";
        [self.tableView reloadData]; if (self.wantsOpen && self.visible && !self.presentedViewController) [self openSource:source]; return;
    }
    if ([@[@"complete",@"partial",@"error",@"interrupted"] containsObject:job[@"state"] ?: @""]) {
        self.message = @"Aucune source audio vérifiée n'a été préparée. Tu peux réessayer ou compléter ce morceau dans les téléchargements.";
        [self.tableView reloadData]; return;
    }
    self.message = [job[@"message"] length] ? job[@"message"] : @"Préparation de ce morceau sur le PC.";
    self.busy = YES; [self.tableView reloadData];
    [self later:2 block:^(SGPlayerAudioPreparationPage *page) { page.busy = NO; [page connect]; }];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(tableView, @"player-audio-preparation");
    BOOL supported = [SGAutomaticSpotifyURL(self.uri) hasPrefix:@"https://open.spotify.com/track/"];
    NSDictionary *ready = SGPlayerAudioPreparedSource(self.record[@"job"], self.uri);
    if (path.row == 0) SGFillCell(cell, self.busy ? @"Préparation sur le PC" : ready ? @"Morceau prêt" : @"Préparer la version", self.message, nil, @"waveform");
    else if (path.row == 1) SGFillCell(cell, ready ? @"Choisir la version" : self.busy ? @"Mettre le suivi en pause" : self.record ? @"Réessayer / reprendre" : @"Préparer ce morceau", @"Le PC doit être allumé sur le même réseau.", SGGreen(), self.busy ? @"pause.circle" : @"play.circle");
    else SGFillCell(cell, supported ? @"Choisir une source / voir les téléchargements" : @"Ajouter la source de ce fichier", @"Pour compléter un morceau introuvable.", nil, @"arrow.down.circle");
    cell.selectionStyle = path.row == 0 || (path.row == 1 && !supported) ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *content = [cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class] ? (UIListContentConfiguration *)cell.contentConfiguration : nil;
    content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 0; cell.contentConfiguration = content;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.row == 0) return;
    BOOL supported = [SGAutomaticSpotifyURL(self.uri) hasPrefix:@"https://open.spotify.com/track/"];
    if (path.row == 2) {
        if (supported) { SGAutomaticDownloadEntity(self.uri, self.view); }
        else SGShowPage(self, SGLocalImportsPageCreate(nil,nil,nil,nil));
        return;
    }
    if (!supported) return;
    NSDictionary *source = SGPlayerAudioPreparedSource(self.record[@"job"], self.uri);
    if (source) { [self openSource:source]; return; }
    if (self.busy) {
        NSMutableDictionary *paused = [self.record mutableCopy]; paused[@"paused"] = @YES; [self save:paused];
        [self suspend]; self.message = @"Suivi en pause. La préparation sur le PC peut continuer."; [self.tableView reloadData]; return;
    }
    if (!self.record || [@[@"complete",@"partial",@"error",@"interrupted"] containsObject:self.record[@"job"][@"state"] ?: @""]) {
        if (![self save:@{@"request":SGAutomaticDownloadRequest(self.uri,nil,NO)}]) { [self.tableView reloadData]; return; }
    }
    NSMutableDictionary *resumed = [self.record mutableCopy]; resumed[@"paused"] = @NO;
    if (![self save:resumed]) { [self.tableView reloadData]; return; }
    self.wantsOpen = YES; [self connect];
}
@end

void SGPresentPlayerAudioVersions(UIViewController *owner, NSString *capturedURI, NSString *kind) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ SGPresentPlayerAudioVersions(owner,capturedURI,kind); }); return; }
    if (!owner || owner.presentedViewController || ![@[@"speed",@"instrumental"] containsObject:kind]) return;
    NSDictionary *playing = SGAutomaticPlayingTrack(); NSString *uri = capturedURI ?: playing[@"uri"];
    if (![uri isKindOfClass:NSString.class] || !uri.length) return;
    NSDictionary *source = SGAutomaticAudioToolsSource(uri);
    UIViewController *page = source ? SGAudioVariantsPageCreateForKind(source,kind) :
        [[SGPlayerAudioPreparationPage alloc] initWithURI:uri kind:kind title:[uri isEqual:playing[@"uri"]] ? playing[@"title"] : nil];
    SGPlayerToolsNavigation *navigation = [[SGPlayerToolsNavigation alloc] initWithRootViewController:page];
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    page.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:navigation action:@selector(closeTools)];
    [owner presentViewController:navigation animated:YES completion:nil];
}

@interface SGPlayerAudioButtons : UIView
@property(nonatomic, strong) UIButton *speed;
@property(nonatomic, strong) UIButton *vocals;
@property(nonatomic, weak) UIStackView *row;
@property(nonatomic, strong) NSLayoutConstraint *widthConstraint;
@end
@implementation SGPlayerAudioButtons
- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.title = title; config.image = [UIImage systemImageNamed:symbol]; config.imagePlacement = NSDirectionalRectEdgeTop;
    config.imagePadding = 2; config.baseForegroundColor = [UIColor colorWithWhite:.70 alpha:1];
    config.contentInsets = NSDirectionalEdgeInsetsMake(2,2,2,2);
    config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy]; result[NSFontAttributeName] = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; return result;
    };
    button.configuration = config; button.accessibilityLabel = title; [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; [self addSubview:button]; return button;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.speed = [self button:@"Vitesse" symbol:@"speedometer" action:@selector(openSpeed)];
        self.vocals = [self button:@"Sans voix" symbol:@"mic.slash" action:@selector(openVocals)];
        self.speed.accessibilityIdentifier = @"spoti.player.speed"; self.vocals.accessibilityIdentifier = @"spoti.player.vocals";
        self.speed.accessibilityHint = @"Régler la vitesse de lecture du morceau.";
        self.vocals.accessibilityHint = @"Réduction en direct indisponible.";
        UIButtonConfiguration *vocalsStyle = self.vocals.configuration;
        vocalsStyle.baseForegroundColor = [UIColor colorWithWhite:.48 alpha:1];
        self.vocals.configuration = vocalsStyle;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self setContentCompressionResistancePriority:UILayoutPriorityRequired - 1 forAxis:UILayoutConstraintAxisHorizontal];
        // A hidden arranged view receives a required zero-width constraint from
        // UIKit. Keep our own width one point below required so it can collapse.
        self.widthConstraint = [self.widthAnchor constraintEqualToConstant:104];
        self.widthConstraint.priority = UILayoutPriorityRequired - 1;
        self.widthConstraint.active = YES;
    } return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(104,44); }
- (void)layoutSubviews {
    [super layoutSubviews]; CGFloat width = self.bounds.size.width / 2.;
    CGFloat height = MIN((CGFloat)44,self.bounds.size.height), y = (self.bounds.size.height-height)/2.;
    self.speed.frame = CGRectMake(0,y,width,height); self.vocals.frame = CGRectMake(width,y,width,height);
}
- (void)openSpeed { SGPresentPlayerNativeSpeed(SGTopController()); }
- (void)openVocals {
    UIViewController *owner = SGTopController(); if (!owner || owner.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Réduction de voix indisponible"
        message:@"La réduction de voix en direct n’est pas disponible dans ce lecteur. Le morceau continue avec sa voix d’origine."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Compris" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}
@end

static char buttonsKey;
static BOOL SGPlayerAudioFixedWidth(UIView *view, UIView *host) {
    for (UIView *owner = view; owner; owner = owner.superview) {
        for (NSLayoutConstraint *constraint in owner.constraints) {
            if (!constraint.active || constraint.relation != NSLayoutRelationEqual ||
                constraint.priority < UILayoutPriorityRequired - 1) continue;
            if ((constraint.firstItem == view && constraint.firstAttribute == NSLayoutAttributeWidth) ||
                (constraint.secondItem == view && constraint.secondAttribute == NSLayoutAttributeWidth)) return YES;
        }
        if (owner == host) break;
    }
    return NO;
}
static UIStackView *SGPlayerAudioInformationRow(UIView *host) {
    __block UIStackView *found = nil;
    SGForEachView(host, ^(UIView *view) {
        if (found || ![view isKindOfClass:UIStackView.class]) return;
        UIStackView *row = (UIStackView *)view;
        if (row.axis != UILayoutConstraintAxisHorizontal || row.distribution != UIStackViewDistributionFill ||
            row.arrangedSubviews.count < 2 || row.arrangedSubviews.count > 5) return;
        BOOL text = NO, addTo = NO;
        for (UIView *item in row.arrangedSubviews) {
            text |= SGHasClass(item,@"TrackInfoContainerView");
            addTo |= SGHasClass(item,@"AddToButton");
        }
        if (text && addTo) found = row;
    });
    return found;
}
void SGPlayerAudioToolsLayout(UIViewController *information) {
    UIView *host = information.viewIfLoaded; if (!host) return;
    SGPlayerAudioButtons *buttons = objc_getAssociatedObject(host,&buttonsKey);
    UIStackView *row = buttons.row;
    if (!row || ![row isDescendantOfView:host]) row = SGPlayerAudioInformationRow(host);
    if (!row || !host.window || row.bounds.size.height < 44 || row.bounds.size.width < 240) { buttons.hidden = YES; return; }
    UIView *text = nil, *addTo = nil;
    CGFloat occupied = 0; NSUInteger count = 0;
    for (UIView *item in row.arrangedSubviews) {
        if (item == buttons) continue;
        if (SGHasClass(item,@"TrackInfoContainerView")) { if (text) { buttons.hidden = YES; return; } text = item; }
        else {
            if (SGHasClass(item,@"AddToButton")) addTo = item;
            if (!item.hidden) occupied += item.bounds.size.width;
        }
        if (!item.hidden) count++;
    }
    // The row, not an overlay, reserves space before the native AddTo button.
    // Long titles retain Spotify's existing marquee/truncation behaviour.
    CGFloat margins = row.layoutMarginsRelativeArrangement ? row.layoutMargins.left + row.layoutMargins.right : 0;
    CGFloat available = row.bounds.size.width - margins - occupied - MAX((CGFloat)0,row.spacing) * count - 104;
    if (!text || !addTo || text.hidden || SGPlayerAudioFixedWidth(text,host) || available < 92 ||
        ([text contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisHorizontal] >= UILayoutPriorityRequired &&
            text.intrinsicContentSize.width > available)) { buttons.hidden = YES; return; }
    if (!buttons) {
        buttons = [[SGPlayerAudioButtons alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(host,&buttonsKey,buttons,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSUInteger position = [row.arrangedSubviews indexOfObjectIdenticalTo:addTo];
    NSUInteger current = [row.arrangedSubviews indexOfObjectIdenticalTo:buttons];
    if (buttons.superview != row || current == NSNotFound || current + 1 != position) {
        [buttons.row removeArrangedSubview:buttons]; [buttons removeFromSuperview];
        [row insertArrangedSubview:buttons atIndex:[row.arrangedSubviews indexOfObjectIdenticalTo:addTo]]; buttons.row = row;
    }
    buttons.hidden = NO;
}
