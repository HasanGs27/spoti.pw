#import "LocalImportsPage.h"
#import "LocalImportModel.h"
#import "YouTubeSourceBrowser.h"
#import "AutomaticDownloads.h"
#import "AutomaticAudioLibrary.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import <sys/stat.h>
#import <math.h>

static NSString *const localImportsKey = @"spotifyglass.localImports.records.v1";
static NSString *localStamp(NSDictionary *row) {
    NSURL *file = SGAutomaticLibraryFile(row); struct stat info;
    if (!file || lstat(file.path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size != [row[@"bytes"] longLongValue]) return nil;
    return [NSString stringWithFormat:@"%llu:%llu:%lld:%lld:%ld:%lld:%ld", (unsigned long long)info.st_dev,
        (unsigned long long)info.st_ino, (long long)info.st_size, (long long)info.st_mtimespec.tv_sec,
        info.st_mtimespec.tv_nsec, (long long)info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec];
}
static BOOL localInstalled(NSDictionary *record) {
    NSString *stamp = record[@"installed"] ? localStamp(record[@"installed"]) : nil;
    return stamp && [stamp isEqual:record[@"stamp"]];
}
static BOOL terminal(NSDictionary *job) { return [@[@"error", @"cancelled", @"interrupted"] containsObject:job[@"state"] ?: @""]; }
static NSString *safeMessage(id value, NSString *fallback) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 1024 ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return fallback;
    return value;
}
static void afterImportAlert(UIAlertController *alert, void (^completion)(void)) {
    if (!completion) return;
    if (!alert.presentingViewController) { completion(); return; }
    id<UIViewControllerTransitionCoordinator> transition = alert.transitionCoordinator;
    if (alert.isBeingDismissed && transition && [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) { completion(); }]) return;
    [alert dismissViewControllerAnimated:YES completion:completion];
}

@interface SGLocalImportsPage : SGPage <NSURLSessionDataDelegate>
@property(nonatomic, copy) NSArray<NSDictionary *> *records;
@property(nonatomic, copy) NSDictionary *initial;
@property(nonatomic, copy) NSString *selectedID;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) UIView *note;
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *httpTask;
@property(nonatomic, strong) NSMutableData *responseData;
@property(nonatomic, copy) void (^responseCompletion)(id, NSInteger);
@property(nonatomic) NSInteger responseCode;
@property(atomic, strong) NSURLSessionTask *transferTask;
@property(atomic) NSUInteger generation;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL importing;
@property(nonatomic) BOOL transferStarted;
@property(nonatomic) BOOL skipAppearanceResume;
@property(nonatomic) double progress;
@property(nonatomic) NSTimeInterval lastProgress;
@property(nonatomic) NSUInteger retryAttempt;
- (void)loadRecords;
- (NSDictionary *)record:(NSString *)key;
- (BOOL)save:(NSDictionary *)record replacing:(NSString *)oldKey;
- (void)refresh;
- (void)suspend;
- (void)connect;
- (void)run:(NSDictionary *)record;
- (void)handle:(NSDictionary *)job key:(NSString *)key generation:(NSUInteger)generation;
- (void)fail:(NSString *)message key:(NSString *)key;
- (void)waitForPC;
- (void)later:(NSTimeInterval)delay block:(void (^)(SGLocalImportsPage *page))block;
- (void)confirmSource:(NSURL *)source title:(NSString *)title;
- (void)addSource:(NSURL *)source title:(NSString *)title artist:(NSString *)artist target:(NSDictionary *)target;
- (void)chooseRecord:(NSDictionary *)record;
@end

@implementation SGLocalImportsPage
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Ajouter un morceau";
        self.message = @"Choisis une vidéo ou un lien audio. Le PC prépare le fichier, puis l’iPhone l’enregistre.";
        [self loadRecords];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self.session invalidateAndCancel]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 78;
    self.note = SGNote(@"Pour les morceaux absents de Spotify, l’ajout reste un fichier local indépendant. Garde cette page ouverte pendant le transfert. Le PC associé doit être allumé sur le même réseau.");
    self.tableView.tableHeaderView = self.note;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.visible = YES; [self loadRecords]; [self refresh]; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.skipAppearanceResume) { self.skipAppearanceResume = NO; return; }
    if (self.initial) {
        NSDictionary *initial = self.initial; self.initial = nil;
        [self addSource:[NSURL URLWithString:initial[@"source_url"]] title:initial[@"title"] artist:initial[@"artist"] target:initial[@"target"]];
    } else [self connect];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated]; self.visible = NO; [self suspend]; [self.session invalidateAndCancel]; self.session = nil;
}
- (void)viewWillLayoutSubviews { [super viewWillLayoutSubviews]; SGFitNote(self.tableView, self.note, 12, 12); }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; SGInsetForBars(self.tableView); }
- (void)becameInactive:(NSNotification *)note { self.root = nil; [self suspend]; }
- (void)becameActive:(NSNotification *)note { if (self.visible) [self connect]; }
- (void)suspend {
    self.generation++; [self.httpTask cancel]; self.httpTask = nil; self.responseCompletion = nil; self.responseData = nil;
    [self.transferTask cancel]; self.transferTask = nil; self.busy = NO; self.importing = NO; self.progress = 0;
}
- (void)loadRecords { self.records = SGLocalImportRecords([NSUserDefaults.standardUserDefaults arrayForKey:localImportsKey]); }
- (NSDictionary *)record:(NSString *)key {
    for (NSDictionary *record in self.records) if ([record[@"request"][@"request_id"] isEqual:key]) return record;
    return nil;
}
- (BOOL)save:(NSDictionary *)record replacing:(NSString *)oldKey {
    NSMutableArray *entries = [SGLocalImportRecords([NSUserDefaults.standardUserDefaults arrayForKey:localImportsKey]) mutableCopy];
    if (oldKey) {
        NSIndexSet *indexes = [entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) { return [entry[@"request"][@"request_id"] isEqual:oldKey]; }];
        [entries removeObjectsAtIndexes:indexes];
    }
    NSArray *next = SGLocalImportStoreRecord(entries, record);
    if (!next) { self.message = @"Termine un des ajouts en attente avant d’en créer un autre. Tes fichiers sont conservés."; [self refresh]; return NO; }
    [NSUserDefaults.standardUserDefaults setObject:next forKey:localImportsKey]; [self loadRecords]; return YES;
}
- (NSDictionary *)pendingRecord {
    NSDictionary *selected = [self record:self.selectedID];
    if (selected && !selected[@"installed"] && !selected[@"error"] && ![selected[@"paused"] boolValue] && !terminal(selected[@"job"])) return selected;
    for (NSDictionary *record in self.records)
        if (!record[@"installed"] && !record[@"error"] && ![record[@"paused"] boolValue] && !terminal(record[@"job"])) return record;
    return nil;
}
- (void)refresh { if (self.isViewLoaded) [self.tableView reloadData]; }
- (void)later:(NSTimeInterval)delay block:(void (^)(SGLocalImportsPage *))block {
    NSUInteger generation = self.generation; __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGLocalImportsPage *page = weak;
        if (page && page.generation == generation && page.visible && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) block(page);
    });
}
- (void)ensureSession {
    if (self.session) return;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40;
    config.allowsCellularAccess = NO; config.URLCache = nil; config.HTTPCookieStorage = nil;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
}
- (void)json:(NSString *)path body:(NSDictionary *)body completion:(void (^)(id, NSInteger))completion {
    [self ensureSession]; self.responseData = [NSMutableData data]; self.responseCode = 0; self.responseCompletion = completion;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self.root URLByAppendingPathComponent:path] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    if (body) { request.HTTPMethod = @"POST"; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil]; }
    self.httpTask = [self.session dataTaskWithRequest:request]; [self.httpTask resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion { completion(nil); }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if (task != self.httpTask) { completion(NSURLSessionResponseCancel); return; }
    self.responseCode = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    completion(response.expectedContentLength > 2 * 1024 * 1024 ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (task != self.httpTask) return;
    if (data.length > 2 * 1024 * 1024 - self.responseData.length) { [task cancel]; return; }
    [self.responseData appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task != self.httpTask) return;
    void (^completion)(id, NSInteger) = self.responseCompletion;
    id value = !error && self.responseData.length ? [NSJSONSerialization JSONObjectWithData:self.responseData options:0 error:nil] : nil;
    NSInteger code = error ? 0 : self.responseCode;
    self.httpTask = nil; self.responseCompletion = nil; self.responseData = nil;
    if (completion) completion(value, code);
}
- (void)waitForPC {
    self.busy = NO; self.importing = NO; self.root = nil;
    self.message = @"En attente du PC. L’ajout est conservé ; garde cette page ouverte pour reprendre automatiquement."; [self refresh];
    if ([self pendingRecord]) [self later:MIN(60., 3. * pow(2., MIN(self.retryAttempt++, (NSUInteger)5))) block:^(SGLocalImportsPage *page) { [page connect]; }];
}
- (void)connect {
    if (self.busy || !self.visible || self.presentedViewController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSDictionary *record = [self pendingRecord]; if (!record) return;
    NSString *key = record[@"request"][@"request_id"];
    self.selectedID = key; self.busy = YES; self.message = @"Connexion au PC associé…"; [self refresh];
    NSUInteger generation = ++self.generation; __weak typeof(self) weak = self;
    SGAutomaticPrepareAudioToolsPC(^(NSURL *root, NSString *error) {
        SGLocalImportsPage *page = weak; if (!page || page.generation != generation) return;
        if (!root) { [page waitForPC]; if (error.length) { page.message = error; [page refresh]; } return; }
        page.root = root; page.busy = NO;
        [page run:[page record:key]];
    });
}
- (void)fail:(NSString *)message key:(NSString *)key {
    self.busy = NO; self.importing = NO; self.message = safeMessage(message, @"Ajout interrompu. Touche le morceau pour réessayer.");
    NSMutableDictionary *record = [[self record:key] mutableCopy];
    if (record) { record[@"error"] = self.message; record[@"paused"] = @YES; [self save:record replacing:nil]; }
    [self refresh];
}
- (void)run:(NSDictionary *)record {
    if (!record || self.busy || !self.root) return;
    NSString *key = record[@"request"][@"request_id"]; self.selectedID = key;
    self.busy = YES; self.message = @"Préparation de la source choisie sur le PC…";
    NSUInteger generation = ++self.generation; [self refresh];
    if (record[@"job"]) { [self handle:record[@"job"] key:key generation:generation]; return; }
    NSDictionary *request = record[@"request"]; __weak typeof(self) weak = self;
    [self json:@"local-imports" body:request completion:^(id value, NSInteger code) {
        SGLocalImportsPage *page = weak; if (!page || page.generation != generation) return;
        NSDictionary *job = (code == 200 || code == 201 || code == 202) ? SGLocalImportJob(value, request) : nil;
        if (!job) {
            if (!code || code >= 500) { [page waitForPC]; return; }
            NSString *error = code == 404 ? @"Mets à jour le compagnon PC pour utiliser les ajouts personnels." : @"Le PC n’a pas accepté cet ajout. Vérifie la source puis réessaie.";
            [page fail:safeMessage([value isKindOfClass:NSDictionary.class] ? value[@"error"] : nil, error) key:key]; return;
        }
        page.retryAttempt = 0; [page handle:job key:key generation:generation];
    }];
}
- (void)handle:(NSDictionary *)job key:(NSString *)key generation:(NSUInteger)generation {
    if (self.generation != generation) return;
    NSMutableDictionary *record = [[self record:key] mutableCopy]; if (!record) { self.busy = NO; return; }
    record[@"job"] = job; [record removeObjectForKey:@"error"];
    if (![self save:record replacing:nil]) { [self fail:@"Le suivi de l’ajout n’a pas pu être enregistré." key:key]; return; }
    if (terminal(job)) { [self fail:safeMessage(job[@"message"], @"Ajout interrompu. Touche le morceau pour réessayer.") key:key]; return; }
    if ([job[@"state"] isEqual:@"ready"]) {
        self.importing = YES; self.transferStarted = NO; self.progress = 0;
        self.message = @"Fichier prêt sur le PC. En attente du transfert vers l’iPhone…"; [self refresh];
        __weak typeof(self) weak = self;
        SGAutomaticImportLocalSource(self.root, job[@"row"], record[@"target"], ^BOOL {
            SGLocalImportsPage *page = weak; return !page || page.generation != generation;
        }, ^(NSURLSessionTask *task) {
            SGLocalImportsPage *page = weak;
            if (!page || page.generation != generation) [task cancel]; else page.transferTask = task;
            dispatch_async(dispatch_get_main_queue(), ^{ SGLocalImportsPage *active = weak; if (active && active.generation == generation) { active.transferStarted = YES; [active refresh]; } });
        }, ^(NSUInteger received, NSUInteger total) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLocalImportsPage *page = weak; if (!page || page.generation != generation || !total) return;
                page.progress = MIN(.99, (double)received / total);
                NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
                if (now - page.lastProgress > .25) { page.lastProgress = now; [page refresh]; }
            });
        }, ^(NSDictionary *installed, NSString *error) {
            SGLocalImportsPage *page = weak; if (!page) return;
            [page loadRecords]; NSMutableDictionary *current = [[page record:key] mutableCopy];
            if (installed && current) {
                NSString *stamp = localStamp(installed);
                if (stamp) { current[@"installed"] = installed; current[@"stamp"] = stamp; [current removeObjectForKey:@"error"]; [page save:current replacing:nil]; }
            }
            if (page.generation != generation) return;
            page.busy = NO; page.importing = NO; page.transferTask = nil;
            if (!localInstalled([page record:key])) { [page fail:error key:key]; return; }
            page.message = current[@"target"] ? @"Morceau complété. Sa copie locale est disponible hors ligne." : @"Morceau enregistré dans Bibliothèque → Fichiers locaux.";
            [page refresh]; [page connect];
        });
        return;
    }
    self.message = safeMessage(job[@"message"], @"Préparation sur le PC…"); [self refresh];
    [self later:2 block:^(SGLocalImportsPage *page) {
        __weak SGLocalImportsPage *weak = page;
        [page json:[@"local-imports/" stringByAppendingString:job[@"id"]] body:nil completion:^(id value, NSInteger code) {
            SGLocalImportsPage *result = weak; if (!result || result.generation != generation) return;
            NSDictionary *next = code == 200 ? SGLocalImportJob(value, [result record:key][@"request"]) : nil;
            if (!next || ![next[@"id"] isEqual:job[@"id"]]) {
                if (!code || code >= 500) [result waitForPC];
                else {
                    if (code == 404) { NSMutableDictionary *missing = [[result record:key] mutableCopy]; [missing removeObjectForKey:@"job"]; [result save:missing replacing:nil]; }
                    [result fail:@"Le suivi est indisponible. Touche l’ajout pour le reprendre." key:key];
                }
                return;
            }
            result.retryAttempt = 0; [result handle:next key:key generation:generation];
        }];
    }];
}
- (void)addSource:(NSURL *)source title:(NSString *)title artist:(NSString *)artist target:(NSDictionary *)target {
    NSDictionary *request = SGLocalImportRequest(@{@"request_id":NSUUID.UUID.UUIDString, @"source_url":source.absoluteString ?: @"", @"title":title ?: @"", @"artist":artist ?: @""});
    if (!request || (target && !SGLocalImportTarget(target))) { self.message = @"Utilise un lien vidéo YouTube ou audio HTTPS et un titre de 200 caractères maximum."; [self refresh]; return; }
    for (NSDictionary *old in self.records) {
        BOOL same = YES; for (NSString *field in @[@"source_url", @"title", @"artist", @"album"]) same &= [old[@"request"][field] isEqual:request[field]];
        same &= (!old[@"target"] && !target) || [old[@"target"] isEqual:target];
        if (same) { [self chooseRecord:old]; return; }
    }
    NSMutableDictionary *record = [@{@"request":request,@"paused":@NO} mutableCopy]; if (target) record[@"target"] = target;
    if (![self save:record replacing:nil]) return;
    if (!self.busy) self.selectedID = request[@"request_id"];
    [self refresh]; [self connect];
}
- (void)chooseRecord:(NSDictionary *)record {
    if (self.busy) { self.message = @"Mets l’ajout en cours en pause pour en ouvrir un autre."; [self refresh]; return; }
    if (localInstalled(record)) { self.message = @"Ce fichier est déjà enregistré. Retrouve-le dans Bibliothèque → Fichiers locaux."; [self refresh]; return; }
    NSMutableDictionary *next = [record mutableCopy]; NSString *oldKey = nil;
    if (terminal(record[@"job"])) {
        oldKey = record[@"request"][@"request_id"];
        NSMutableDictionary *request = [record[@"request"] mutableCopy]; request[@"request_id"] = NSUUID.UUID.UUIDString;
        next[@"request"] = request; [next removeObjectForKey:@"job"];
    }
    next[@"paused"] = @NO; [next removeObjectForKey:@"error"]; [next removeObjectForKey:@"installed"]; [next removeObjectForKey:@"stamp"];
    if (![self save:next replacing:oldKey]) return;
    self.selectedID = next[@"request"][@"request_id"]; [self connect];
}
- (void)confirmSource:(NSURL *)source title:(NSString *)title {
    if (!SGLocalImportSource(source)) { self.message = @"Ouvre une vidéo YouTube ou utilise un lien audio HTTPS direct."; [self refresh]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ajouter ce morceau" message:@"Vérifie son nom. Le fichier apparaîtra dans Fichiers locaux après sa préparation sur le PC." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Titre"; field.text = [title substringToIndex:MIN(title.length, (NSUInteger)200)]; field.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Artiste (facultatif)"; field.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    __weak UIAlertController *weakAlert = alert; __weak typeof(self) weak = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { afterImportAlert(weakAlert, ^{ [weak connect]; }); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Ajouter" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *title = weakAlert.textFields[0].text, *artist = weakAlert.textFields[1].text;
        afterImportAlert(weakAlert, ^{ [weak addSource:source title:title artist:artist target:nil]; });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)pasteSource {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Lien audio ou YouTube" message:@"Colle le lien d’une vidéo YouTube ou l’adresse HTTPS directe d’un fichier MP3/M4A." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"https://…"; field.keyboardType = UIKeyboardTypeURL; field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    __weak UIAlertController *weakAlert = alert; __weak typeof(self) weak = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { afterImportAlert(weakAlert, ^{ [weak connect]; }); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continuer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSURL *source = SGLocalImportSource(weakAlert.textFields.firstObject.text);
        afterImportAlert(weakAlert, ^{ [weak confirmSource:source title:@""]; });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? 4 : self.records.count; }
- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section { return section == 1 && self.records.count ? SGSectionHeader(table, @"Mes ajouts") : nil; }
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section { return section == 1 && self.records.count ? SGSectionHeaderHeight : SGSectionGap; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"personal-import"); cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    if (path.section == 0) {
        if (path.row == 0) SGFillCell(cell, self.busy ? self.importing ? @"Enregistrement" : @"Préparation" : @"Ajouts personnels", self.message, nil, @"arrow.down.circle");
        else if (path.row == 1) SGFillCell(cell, self.busy ? @"Mettre en pause" : @"Reprendre / actualiser", @"Le PC peut continuer sa préparation pendant la pause.", SGGreen(), self.busy ? @"pause.circle" : @"arrow.clockwise");
        else if (path.row == 2) SGFillCell(cell, @"Rechercher sur YouTube", @"Écouter, choisir, puis utiliser cette vidéo", nil, @"magnifyingglass");
        else SGFillCell(cell, @"Coller un lien audio ou YouTube", @"Un fichier MP3/M4A ou une vidéo précise", nil, @"link");
    } else {
        NSDictionary *record = self.records[self.records.count - 1 - path.row];
        BOOL installed = localInstalled(record), active = self.busy && [record[@"request"][@"request_id"] isEqual:self.selectedID];
        NSString *status = installed ? @"Disponible hors ligne" : record[@"installed"] ? @"Fichier absent · toucher pour récupérer" : record[@"error"] ? record[@"error"] : [record[@"paused"] boolValue] ? @"En pause · toucher pour reprendre" : @"En attente";
        if (active) status = self.importing ? self.transferStarted ? [NSString stringWithFormat:@"Transfert vers l’iPhone · %.0f %%", self.progress * 100] : @"Prêt sur le PC · en attente du transfert" : self.message;
        SGFillCell(cell, record[@"request"][@"title"], [NSString stringWithFormat:@"%@\n%@", record[@"request"][@"artist"], status], nil, installed ? @"checkmark.circle.fill" : record[@"error"] ? @"exclamationmark.circle" : @"clock");
        UIListContentConfiguration *content = (id)cell.contentConfiguration;
        content.imageProperties.tintColor = installed ? SGGreen() : record[@"error"] ? SGRed() : SGGrey(); cell.contentConfiguration = content;
    }
    UIListContentConfiguration *content = (id)cell.contentConfiguration; content.secondaryTextProperties.numberOfLines = 0; cell.contentConfiguration = content;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) { if ((NSUInteger)path.row < self.records.count) [self chooseRecord:self.records[self.records.count - 1 - path.row]]; return; }
    if (path.row == 0) return;
    if (path.row == 1) {
        if (self.busy) {
            NSMutableDictionary *record = [[self record:self.selectedID] mutableCopy];
            if (record) { record[@"paused"] = @YES; [self save:record replacing:nil]; }
            [self suspend]; self.message = @"Ajout en pause. Les fichiers déjà enregistrés restent disponibles."; [self refresh];
        } else {
            NSDictionary *record = [self record:self.selectedID];
            if (!record) for (NSDictionary *entry in self.records) if (!localInstalled(entry)) { record = entry; break; }
            if (record) [self chooseRecord:record]; else { self.message = @"Choisis une vidéo ou colle un lien audio pour ajouter un morceau."; [self refresh]; }
        }
        return;
    }
    if (self.busy) { self.message = @"Mets l’ajout en cours en pause pour choisir un autre morceau."; [self refresh]; return; }
    if (path.row == 2) {
        __weak typeof(self) weak = self;
        self.skipAppearanceResume = YES;
        [self presentViewController:SGYouTubeSourceBrowserCreate(@"", ^(NSURL *source, NSString *title) { [weak confirmSource:source title:title]; }) animated:YES completion:nil];
    } else [self pasteSource];
}
@end

UIViewController *SGLocalImportsPageCreate(NSURL *source, NSString *title, NSString *artist, NSDictionary *target) {
    SGLocalImportsPage *page = [SGLocalImportsPage new];
    if (source) {
        NSMutableDictionary *initial = [@{@"source_url":source.absoluteString, @"title":title ?: @"", @"artist":artist ?: @""} mutableCopy];
        if (target) initial[@"target"] = target; page.initial = initial;
    }
    return page;
}
