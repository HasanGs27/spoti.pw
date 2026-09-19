#import "YouTubeSourceBrowser.h"
#import "YouTubeSourceModel.h"
#import <WebKit/WebKit.h>

static char sourceBrowserObservation;
static NSArray<NSString *> *observedKeys(void) {
    return @[@"URL", @"title", @"loading", @"estimatedProgress", @"canGoBack", @"canGoForward"];
}

@interface SGYouTubeSourceBrowser : UIViewController <WKNavigationDelegate, WKUIDelegate, UISearchBarDelegate>
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) void (^completion)(NSURL *, NSString *);
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) WKNavigation *activeNavigation;
@property(nonatomic, strong) UISearchBar *search;
@property(nonatomic, strong) UILabel *pageTitle;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIProgressView *progress;
@property(nonatomic, strong) UIBarButtonItem *backItem;
@property(nonatomic, strong) UIBarButtonItem *forwardItem;
@property(nonatomic, strong) UIBarButtonItem *reloadItem;
@property(nonatomic, strong) UIBarButtonItem *useItem;
@property(nonatomic, copy) NSURL *observedURL;
@property(nonatomic, copy) NSString *statusMessage;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) BOOL observing;
@property(nonatomic) BOOL navigating;
@property(nonatomic) BOOL documentReady;
@property(nonatomic) BOOL failed;
@property(nonatomic) BOOL selecting;
@property(nonatomic) BOOL closed;
- (void)refresh;
- (void)navigate:(NSURL *)url;
- (void)invalidateSelection;
- (void)tearDown;
- (void)finishWithURL:(NSURL *)url title:(NSString *)title;
@end

@implementation SGYouTubeSourceBrowser
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choisir une vidéo";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Annuler"
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];

    self.search = [UISearchBar new]; self.search.delegate = self;
    self.search.placeholder = @"Rechercher un titre, un artiste…"; self.search.text = self.query;
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.searchTextField.returnKeyType = UIReturnKeySearch;
    self.search.accessibilityLabel = @"Rechercher sur YouTube";
    self.pageTitle = [UILabel new]; self.pageTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.pageTitle.adjustsFontForContentSizeCategory = YES; self.pageTitle.numberOfLines = 2;
    self.pageTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statusLabel = [UILabel new]; self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.statusLabel.adjustsFontForContentSizeCategory = YES; self.statusLabel.numberOfLines = 2;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[self.pageTitle, self.statusLabel]];
    labels.axis = UILayoutConstraintAxisVertical; labels.spacing = 3;
    labels.layoutMargins = UIEdgeInsetsMake(0, 16, 8, 16); labels.layoutMarginsRelativeArrangement = YES;
    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progress.tintColor = UIColor.systemGreenColor;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.search, labels, self.progress]];
    header.axis = UILayoutConstraintAxisVertical; header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.allowsInlineMediaPlayback = YES;
    configuration.allowsPictureInPictureMediaPlayback = NO;
    configuration.allowsAirPlayForMediaPlayback = NO;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    configuration.defaultWebpagePreferences.preferredContentMode = WKContentModeMobile;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self; self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES; self.webView.allowsLinkPreview = NO;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    self.backItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
        style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    self.forwardItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"]
        style:UIBarButtonItemStylePlain target:self action:@selector(forward)];
    self.reloadItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
        style:UIBarButtonItemStylePlain target:self action:@selector(reload)];
    self.backItem.accessibilityLabel = @"Page précédente";
    self.forwardItem.accessibilityLabel = @"Page suivante";
    self.useItem = [[UIBarButtonItem alloc] initWithTitle:@"Utiliser cette vidéo"
        style:UIBarButtonItemStyleDone target:self action:@selector(useVideo)];
    self.useItem.tintColor = UIColor.systemGreenColor;
    self.useItem.accessibilityHint = @"Choisir le lien de la vidéo actuellement ouverte";
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[self.backItem, self.forwardItem, self.reloadItem, space, self.useItem];
    [self.navigationController setToolbarHidden:NO animated:NO];
    for (NSString *key in observedKeys()) [self.webView addObserver:self forKeyPath:key options:0 context:&sourceBrowserObservation];
    self.observing = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self navigate:SGYouTubeSearchURL(self.query)];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Fullscreen video may cover this controller. Only actual dismissal tears it down.
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed || self.isMovingFromParentViewController) {
        self.closed = YES; self.completion = nil; [self tearDown];
    }
}
- (void)dealloc { [self tearDown]; }
- (void)tearDown {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    WKWebView *web = self.webView;
    if (self.observing) {
        for (NSString *key in observedKeys()) [web removeObserver:self forKeyPath:key context:&sourceBrowserObservation];
        self.observing = NO;
    }
    web.navigationDelegate = nil; web.UIDelegate = nil;
    // Public iOS 15+ APIs stop playback, including any fullscreen presentation.
    [web setAllMediaPlaybackSuspended:YES completionHandler:nil];
    [web closeAllMediaPresentationsWithCompletionHandler:nil];
    [web stopLoading]; [web loadHTMLString:@"" baseURL:nil];
    [web removeFromSuperview]; self.webView = nil; self.activeNavigation = nil;
}
- (void)backgrounded:(NSNotification *)notification {
    [self invalidateSelection];
    [self.webView pauseAllMediaPlaybackWithCompletionHandler:nil]; [self refresh];
}
- (void)becameActive:(NSNotification *)notification { [self refresh]; }
- (void)invalidateSelection {
    self.revision++; self.selecting = NO; self.webView.userInteractionEnabled = YES;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &sourceBrowserObservation) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    if (self.closed || object != self.webView) return;
    if ([keyPath isEqual:@"URL"] && ![self.observedURL isEqual:self.webView.URL]) {
        self.observedURL = self.webView.URL; self.statusMessage = nil; [self invalidateSelection];
    }
    [self refresh];
}
- (void)refresh {
    if (!self.isViewLoaded || self.closed) return;
    WKWebView *web = self.webView; NSURL *canonical = SGYouTubeCanonicalVideoURL(web.URL);
    BOOL loading = web.loading || self.navigating;
    BOOL available = canonical && self.documentReady && !loading && !self.failed && !self.selecting &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    self.backItem.enabled = web.canGoBack && !self.selecting;
    self.forwardItem.enabled = web.canGoForward && !self.selecting;
    self.reloadItem.enabled = !self.selecting; self.search.userInteractionEnabled = !self.selecting;
    self.reloadItem.image = [UIImage systemImageNamed:loading ? @"xmark" : @"arrow.clockwise"];
    self.reloadItem.accessibilityLabel = loading ? @"Arrêter le chargement" : @"Réessayer ou actualiser";
    self.useItem.enabled = available;
    self.progress.progress = (float)web.estimatedProgress;
    self.progress.hidden = !loading;
    NSString *title = SGYouTubeSourceTitle(web.title);
    self.pageTitle.text = title.length ? title : @"YouTube";
    self.statusLabel.textColor = self.failed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
    self.statusLabel.text = self.selecting ? @"Vérification de la vidéo affichée…" : self.statusMessage.length ? self.statusMessage :
        loading ? @"Chargement de la page…" : available ? @"Écoute la vidéo, puis touche « Utiliser cette vidéo »." : @"Ouvre une vidéo pour pouvoir la sélectionner.";
    self.useItem.accessibilityValue = available ? canonical.absoluteString : @"Ouvre une vidéo YouTube";
}
- (void)navigate:(NSURL *)url {
    if (self.closed || !SGYouTubeNavigationURLAllowed(url)) return;
    [self.view endEditing:YES]; [self invalidateSelection];
    self.failed = NO; self.documentReady = NO; self.statusMessage = nil; self.navigating = YES;
    self.activeNavigation = [self.webView loadRequest:[NSURLRequest requestWithURL:url]]; [self refresh];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    NSURL *video = SGYouTubeCanonicalVideoURL(searchBar.text);
    [self navigate:video ?: SGYouTubeSearchURL(searchBar.text)];
}
- (void)back {
    if (self.selecting || !self.webView.canGoBack) return;
    [self invalidateSelection]; self.failed = NO; self.statusMessage = nil;
    // History within a SPA may update only URL/KVO, without a new document load.
    // didStartProvisionalNavigation invalidates documentReady when one does begin.
    self.activeNavigation = [self.webView goBack]; [self refresh];
}
- (void)forward {
    if (self.selecting || !self.webView.canGoForward) return;
    [self invalidateSelection]; self.failed = NO; self.statusMessage = nil;
    self.activeNavigation = [self.webView goForward]; [self refresh];
}
- (void)reload {
    if (self.selecting) return;
    if (self.webView.loading || self.navigating) {
        [self.webView stopLoading]; [self invalidateSelection]; self.navigating = NO; self.documentReady = NO;
        self.statusMessage = @"Chargement arrêté. Touche actualiser pour réessayer."; [self refresh]; return;
    }
    NSURL *url = SGYouTubeNavigationURLAllowed(self.webView.URL) ? self.webView.URL : SGYouTubeSearchURL(self.search.text);
    [self navigate:url];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (self.closed || !SGYouTubeNavigationURLAllowed(action.request.URL)) {
        decisionHandler(WKNavigationActionPolicyCancel);
        if (!self.closed && (!action.targetFrame || action.targetFrame.mainFrame)) {
            // A refused top-level redirect ends its provisional load. Its later
            // NSURLErrorCancelled is intentionally ignored, so clear the spinner here.
            if (self.navigating || self.webView.loading) {
                self.navigating = NO; self.documentReady = NO; [self invalidateSelection];
            }
            self.statusMessage = @"Ce lien ne s’ouvre pas ici. Choisis une vidéo sur YouTube."; [self refresh];
        }
        return;
    }
    if (!action.targetFrame) {
        decisionHandler(WKNavigationActionPolicyCancel); [self navigate:action.request.URL]; return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!action.targetFrame && SGYouTubeNavigationURLAllowed(action.request.URL)) [self navigate:action.request.URL];
    return nil;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSHTTPURLResponse *http = [response.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response.response : nil;
    if (self.closed || (response.forMainFrame && (!SGYouTubeNavigationURLAllowed(response.response.URL) || !response.canShowMIMEType || http.statusCode >= 400))) {
        decisionHandler(WKNavigationResponsePolicyCancel);
        if (!self.closed) { self.navigating = NO; self.documentReady = NO; self.failed = YES; self.statusMessage = @"Cette page est indisponible. Essaie une autre vidéo ou actualise."; [self refresh]; }
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (self.closed) return;
    [self invalidateSelection]; self.activeNavigation = navigation; self.navigating = YES;
    self.documentReady = NO; self.failed = NO; self.statusMessage = nil; [self refresh];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.closed || navigation != self.activeNavigation) return;
    self.navigating = NO; self.documentReady = YES; self.failed = NO; self.statusMessage = nil; [self refresh];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (self.closed || navigation != self.activeNavigation || ([error.domain isEqual:NSURLErrorDomain] && error.code == NSURLErrorCancelled)) return;
    [self invalidateSelection]; self.navigating = NO; self.documentReady = NO; self.failed = YES;
    self.statusMessage = @"Impossible de charger YouTube. Vérifie la connexion, puis touche actualiser."; [self refresh];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailProvisionalNavigation:navigation withError:error];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self invalidateSelection]; self.navigating = NO; self.documentReady = NO; self.failed = YES;
    self.statusMessage = @"La page s’est arrêtée. Touche actualiser pour la rouvrir."; [self refresh];
}
- (void)webView:(WKWebView *)webView requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin initiatedByFrame:(WKFrameInfo *)frame type:(WKMediaCaptureType)type decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {
    decisionHandler(WKPermissionDecisionDeny);
}
- (void)useVideo {
    if (!self.useItem.enabled || self.closed) return;
    NSURL *displayedURL = self.webView.URL;
    if (!SGYouTubeCanonicalVideoURL(displayedURL)) return;
    [self.view endEditing:YES]; self.selecting = YES; self.webView.userInteractionEnabled = NO; [self refresh];
    NSUInteger revision = self.revision; __weak typeof(self) weak = self;
    // Read only public location/title, in an isolated JS world. Never inspect page
    // requests, media URLs, credentials, cookies, localStorage or account data.
    [self.webView evaluateJavaScript:@"({href: window.location.href, title: document.title})" inFrame:nil
        inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id snapshot, NSError *error) {
        SGYouTubeSourceBrowser *page = weak;
        if (!page || page.closed || page.revision != revision || !page.selecting) return;
        page.selecting = NO; page.webView.userInteractionEnabled = YES;
        NSDictionary *selection = !error && !page.webView.loading && !page.navigating && page.documentReady && !page.failed &&
            UIApplication.sharedApplication.applicationState == UIApplicationStateActive ?
            SGYouTubeValidatedSelection(displayedURL, page.webView.URL, snapshot) : nil;
        if (!selection) { page.statusMessage = @"La vidéo a changé ou n’est pas encore prête. Réessaie sur la page ouverte."; [page refresh]; return; }
        [page finishWithURL:[NSURL URLWithString:selection[@"url"]] title:selection[@"title"]];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SGYouTubeSourceBrowser *page = weak;
        if (page && !page.closed && page.selecting && page.revision == revision) {
            [page invalidateSelection]; page.statusMessage = @"La page ne répond pas. Actualise-la puis réessaie."; [page refresh];
        }
    });
}
- (void)cancel { [self finishWithURL:nil title:nil]; }
- (void)finishWithURL:(NSURL *)url title:(NSString *)title {
    if (self.closed) return;
    self.closed = YES; [self invalidateSelection];
    void (^completion)(NSURL *, NSString *) = self.completion; self.completion = nil;
    [self tearDown];
    UIViewController *container = self.navigationController ?: self;
    [container dismissViewControllerAnimated:YES completion:^{ if (url && completion) completion(url, title ?: @""); }];
}
@end

UIViewController *SGYouTubeSourceBrowserCreate(NSString *query, void (^completion)(NSURL *, NSString *)) {
    SGYouTubeSourceBrowser *browser = [SGYouTubeSourceBrowser new]; browser.query = query ?: @""; browser.completion = completion;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:browser];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen; navigation.modalInPresentation = YES;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigation.navigationBar.tintColor = UIColor.labelColor; navigation.toolbar.tintColor = UIColor.labelColor;
    return navigation;
}
