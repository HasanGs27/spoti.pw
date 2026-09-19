#import "AudioVariantsPage.h"
#import "AudioVariantModel.h"
#import "AutomaticDownloads.h"
#import "AutomaticAudioLibrary.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import <sys/stat.h>
#import <math.h>

static NSString *const variantsKey = @"spotifyglass.audioVariants.records.v1";
static NSString *fileStamp(NSDictionary *row) {
    NSURL *file = SGAutomaticLibraryFile(row); struct stat info;
    if (!file || lstat(file.path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
        info.st_size != [row[@"bytes"] longLongValue]) return nil;
    return [NSString stringWithFormat:@"%llu:%llu:%lld:%lld:%ld:%lld:%ld",
        (unsigned long long)info.st_dev, (unsigned long long)info.st_ino, (long long)info.st_size,
        (long long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec,
        (long long)info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec];
}
static BOOL isInstalled(NSDictionary *record) {
    NSString *stamp = record[@"installed"] ? fileStamp(record[@"installed"]) : nil;
    return stamp && [stamp isEqual:record[@"stamp"]];
}
static NSString *requestError(id value, NSString *fallback) {
    id error = [value isKindOfClass:NSDictionary.class] ? value[@"error"] : nil;
    if (![error isKindOfClass:NSString.class] || ![error length] || [error length] > 1024) return fallback;
    if ([error rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return fallback;
    NSString *message = [error stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return message.length ? message : fallback;
}

@interface SGAudioVariantsPage : SGPage <NSURLSessionDataDelegate>
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, copy) NSDictionary *capabilities;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *records;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *serverJobs;
@property(nonatomic, copy) NSString *selectedKey;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) UIView *note;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *httpTask;
@property(nonatomic, strong) NSMutableData *responseData;
@property(nonatomic) NSInteger responseCode;
@property(nonatomic, copy) void (^responseCompletion)(id, NSInteger);
@property(atomic, strong) NSURLSessionTask *transferTask;
@property(atomic) NSUInteger generation;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL importing;
@property(nonatomic) BOOL transferStarted;
@property(nonatomic) BOOL failed;
@property(nonatomic) double progress;
@property(nonatomic) NSTimeInterval lastProgress;
@property(nonatomic) NSUInteger retryAttempt;
- (instancetype)initWithRow:(NSDictionary *)row;
- (void)loadRecords;
- (BOOL)saveRecord:(NSDictionary *)record;
- (NSDictionary *)option:(NSNumber *)rate;
- (NSArray *)options;
- (NSString *)pendingKey;
- (void)json:(NSString *)path body:(NSDictionary *)body completion:(void (^)(id, NSInteger))completion;
- (void)later:(NSTimeInterval)delay block:(void (^)(SGAudioVariantsPage *))block;
- (void)waitForPC;
- (void)choose:(NSDictionary *)option;
- (void)connect;
- (void)refreshUI;
- (void)suspend;
- (void)continuePending;
- (void)runRecord:(NSDictionary *)record;
- (void)handleJob:(NSDictionary *)job key:(NSString *)key generation:(NSUInteger)generation;
- (void)fail:(NSString *)message key:(NSString *)key;
@end

@implementation SGAudioVariantsPage
- (instancetype)initWithRow:(NSDictionary *)row {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Versions audio"; self.source = SGAudioVariantReadyRow(row);
        self.records = @{}; self.serverJobs = @{};
        self.message = self.source ? @"Connexion au PC associé…" : @"Choisis d'abord un morceau téléchargé sur cet iPhone.";
        [self loadRecords];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self.session invalidateAndCancel]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 74;
    self.note = SGNote(self.source ? [NSString stringWithFormat:@"%@ — %@\nChaque choix crée une copie avec sa pochette dans Fichiers locaux. L’original reste inchangé. La préparation sur le PC continue si tu quittes cette page ; le transfert reprend à ton retour.", self.source[@"title"], self.source[@"artist"]] : self.message);
    self.tableView.tableHeaderView = self.note;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; self.visible = YES; [self loadRecords];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self connect];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated]; self.visible = NO; [self suspend];
    [self.session invalidateAndCancel]; self.session = nil;
}
- (void)viewWillLayoutSubviews { [super viewWillLayoutSubviews]; SGFitNote(self.tableView, self.note, 12, 12); }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; SGInsetForBars(self.tableView); }
- (void)becameInactive:(NSNotification *)note { self.root = nil; [self suspend]; }
- (void)becameActive:(NSNotification *)note { if (self.visible) [self connect]; }
- (void)suspend {
    self.generation++; [self.httpTask cancel]; self.httpTask = nil; self.responseCompletion = nil; self.responseData = nil;
    [self.transferTask cancel]; self.transferTask = nil; self.busy = NO; self.importing = NO; self.progress = 0;
}
- (void)loadRecords {
    NSMutableDictionary *records = [NSMutableDictionary dictionary];
    for (NSDictionary *record in SGAudioVariantRecords([NSUserDefaults.standardUserDefaults arrayForKey:variantsKey])) {
        NSDictionary *request = record[@"request"];
        if ([request[@"source_id"] isEqual:self.source[@"id"]] && [request[@"spotify"] isEqual:self.source[@"spotify"]])
            records[SGAudioVariantKey(request)] = record;
    }
    self.records = records;
}
- (BOOL)saveRecord:(NSDictionary *)record {
    NSArray *validated = SGAudioVariantStoreRecord([NSUserDefaults.standardUserDefaults arrayForKey:variantsKey], record);
    if (!validated) { self.message = @"Trop de demandes attendent encore. Termine une copie avant d'en ajouter une nouvelle. Les fichiers existants sont conservés."; return NO; }
    [NSUserDefaults.standardUserDefaults setObject:validated forKey:variantsKey]; [self loadRecords]; return YES;
}

- (NSDictionary *)option:(NSNumber *)rate {
    if (!self.source) return nil;
    NSMutableDictionary *value = [@{@"source_id":self.source[@"id"], @"spotify":self.source[@"spotify"], @"kind":rate ? @"speed" : @"instrumental"} mutableCopy];
    if (rate) value[@"speed"] = rate; return value;
}
- (NSArray *)options {
    if (!self.source) return @[];
    NSMutableArray *options = [NSMutableArray array];
    for (NSNumber *rate in @[@0.75, @1.25, @1.5, @2]) [options addObject:[self option:rate]];
    NSDictionary *instrumental = [self option:nil]; NSString *key = SGAudioVariantKey(instrumental);
    if ([self.capabilities[@"instrumental"] boolValue] || self.records[key] || self.serverJobs[key]) [options addObject:instrumental];
    return options;
}
- (NSString *)pendingKey {
    NSMutableArray *keys = [NSMutableArray array]; if (self.selectedKey) [keys addObject:self.selectedKey];
    for (NSDictionary *option in [self options]) { NSString *key = SGAudioVariantKey(option); if (![keys containsObject:key]) [keys addObject:key]; }
    for (NSString *key in keys) {
        NSDictionary *record = self.records[key]; NSString *state = record[@"job"][@"state"];
        if (record && ![record[@"paused"] boolValue] && !record[@"installed"] && !record[@"error"] &&
            ![@[@"error", @"interrupted"] containsObject:state ?: @""]) return key;
    }
    return nil;
}
- (void)ensureSession {
    if (self.session) return;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40;
    configuration.allowsCellularAccess = NO; configuration.URLCache = nil; configuration.HTTPCookieStorage = nil;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
}
- (void)json:(NSString *)path body:(NSDictionary *)body completion:(void (^)(id, NSInteger))completion {
    [self ensureSession]; self.responseData = [NSMutableData data]; self.responseCode = 0; self.responseCompletion = completion;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self.root URLByAppendingPathComponent:path]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
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
- (void)later:(NSTimeInterval)delay block:(void (^)(SGAudioVariantsPage *))block {
    NSUInteger generation = self.generation; __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGAudioVariantsPage *page = weak;
        if (page && page.generation == generation && page.visible && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) block(page);
    });
}
- (void)waitForPC {
    self.busy = NO; self.importing = NO; self.root = nil; self.failed = NO;
    self.message = @"En attente du PC. Ta demande est conservée ; garde cette page ouverte pour reprendre automatiquement.";
    [self refreshUI];
    if ([self pendingKey]) {
        NSTimeInterval delay = MIN(60., 3. * pow(2., MIN(self.retryAttempt++, (NSUInteger)5)));
        [self later:delay block:^(SGAudioVariantsPage *page) { [page connect]; }];
    }
}
- (void)connect {
    if (self.busy || !self.source || !self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.busy = YES; self.failed = NO; self.message = @"Vérification du PC associé…";
    NSUInteger generation = ++self.generation; [self refreshUI]; __weak typeof(self) weak = self;
    SGAutomaticPrepareAudioToolsPC(^(NSURL *root, NSString *error) {
        SGAudioVariantsPage *page = weak; if (!page || page.generation != generation) return;
        if (!root) { [page waitForPC]; if (error.length) { page.message = error; [page refreshUI]; } return; }
        page.root = root;
        [page json:@"audio-variants" body:nil completion:^(id value, NSInteger code) {
            SGAudioVariantsPage *result = weak; if (!result || result.generation != generation) return;
            NSDictionary *listing = code == 200 ? SGAudioVariantListing(value) : nil;
            if (!listing) {
                if (!code || code >= 500) { [result waitForPC]; return; }
                result.busy = NO; result.failed = YES; result.message = @"Le compagnon PC doit être mis à jour pour créer ces copies."; [result refreshUI]; return;
            }
            result.retryAttempt = 0; result.capabilities = listing[@"capabilities"];
            NSMutableDictionary *jobs = [NSMutableDictionary dictionary];
            for (NSDictionary *job in listing[@"jobs"]) {
                NSString *key = SGAudioVariantKey(job);
                if ([job[@"source_id"] isEqual:result.source[@"id"]] && [job[@"spotify"] isEqual:result.source[@"spotify"]] && !jobs[key]) jobs[key] = job;
            }
            result.serverJobs = jobs; result.busy = NO; result.message = @"PC connecté. Choisis une copie à créer.";
            [result continuePending]; [result refreshUI];
        }];
    });
}
- (void)continuePending {
    if (self.busy || !self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSString *key = [self pendingKey]; if (!key) return;
    if (!self.root) { [self connect]; return; }
    [self runRecord:self.records[key]];
}
- (void)fail:(NSString *)message key:(NSString *)key {
    self.busy = NO; self.importing = NO; self.failed = YES; self.message = message;
    NSMutableDictionary *record = [self.records[key] mutableCopy];
    if (record) { record[@"error"] = message; record[@"paused"] = @YES; [self saveRecord:record]; }
    [self refreshUI];
}
- (void)runRecord:(NSDictionary *)record {
    NSDictionary *request = record[@"request"]; NSString *key = SGAudioVariantKey(request);
    if (!request || self.busy || !self.root) return;
    self.selectedKey = key; self.busy = YES; self.failed = NO;
    self.message = @"Préparation de la copie sur le PC…"; NSUInteger generation = ++self.generation; [self refreshUI];
    if (record[@"job"]) { [self handleJob:record[@"job"] key:key generation:generation]; return; }
    __weak typeof(self) weak = self;
    [self json:@"audio-variants" body:request completion:^(id value, NSInteger code) {
        SGAudioVariantsPage *page = weak; if (!page || page.generation != generation) return;
        NSDictionary *job = (code == 200 || code == 201 || code == 202) ? SGAudioVariantJob(value, request) : nil;
        if (!job) {
            if (!code || code >= 500) { [page waitForPC]; return; }
            NSString *fallback = @"Le PC n'a pas pu préparer cette copie. Il doit encore posséder exactement le fichier original sélectionné.";
            [page fail:code == 400 ? requestError(value, fallback) : fallback key:key]; return;
        }
        [page handleJob:job key:key generation:generation];
    }];
}
- (void)handleJob:(NSDictionary *)job key:(NSString *)key generation:(NSUInteger)generation {
    if (self.generation != generation) return;
    NSMutableDictionary *record = [self.records[key] mutableCopy]; if (!record) { self.busy = NO; return; }
    record[@"job"] = job; [record removeObjectForKey:@"error"];
    if (![self saveRecord:record]) { [self fail:@"Le suivi de cette copie n’a pas pu être enregistré." key:key]; return; }
    NSString *state = job[@"state"];
    if ([state isEqual:@"error"] || [state isEqual:@"interrupted"]) {
        NSString *reason = [job[@"message"] length] ? job[@"message"] : @"La préparation a été interrompue. Touche cette version pour réessayer.";
        [self fail:[reason substringToIndex:MIN(reason.length, (NSUInteger)1024)] key:key]; return;
    }
    if ([state isEqual:@"ready"]) {
        NSDictionary *row = job[@"row"];
        if ([row[@"title"] isEqual:self.source[@"title"]] || [row[@"album"] isEqual:self.source[@"album"]]) {
            [self fail:@"Cette copie n’a pas reçu son nom distinct. L’original est conservé." key:key]; return;
        }
        double expected = [self.source[@"seconds"] doubleValue] / ([job[@"kind"] isEqual:@"speed"] ? [job[@"speed"] doubleValue] : 1.);
        if (fabs([row[@"seconds"] doubleValue] - expected) > fmax(3., expected * .03)) {
            [self fail:@"La durée de cette copie ne correspond pas à l’option choisie." key:key]; return;
        }
        self.importing = YES; self.transferStarted = NO; self.progress = 0; self.message = @"Copie prête sur le PC. En attente du transfert vers l’iPhone…"; [self refreshUI];
        NSString *requestID = record[@"request"][@"request_id"]; __weak typeof(self) weak = self;
        SGAutomaticImportAudioVersion(self.root, row, ^BOOL {
            SGAudioVariantsPage *page = weak; return !page || page.generation != generation;
        }, ^(NSURLSessionTask *task) {
            SGAudioVariantsPage *page = weak;
            if (!page || page.generation != generation) [task cancel]; else page.transferTask = task;
            dispatch_async(dispatch_get_main_queue(), ^{
                SGAudioVariantsPage *active = weak;
                if (!active || active.generation != generation) return;
                active.transferStarted = YES; active.message = @"Enregistrement de la copie sur l'iPhone."; [active refreshUI];
            });
        }, ^(NSUInteger received, NSUInteger total) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGAudioVariantsPage *page = weak; if (!page || page.generation != generation || !total) return;
                page.progress = MIN(.99, (double)received / total);
                NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
                if (now - page.lastProgress > .25) { page.lastProgress = now; page.message = @"Enregistrement de la copie sur l’iPhone…"; [page refreshUI]; }
            });
        }, ^(NSDictionary *installed, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGAudioVariantsPage *page = weak; if (!page) return;
                // A physical installation may commit just before cancellation.
                // Record that success for its own request without resuming work.
                [page loadRecords];
                NSMutableDictionary *current = [page.records[key] mutableCopy];
                if (installed && [current[@"request"][@"request_id"] isEqual:requestID]) {
                    NSString *stamp = fileStamp(installed);
                    if (stamp) { current[@"installed"] = installed; current[@"stamp"] = stamp; [current removeObjectForKey:@"error"]; [page saveRecord:current]; }
                }
                if (page.generation != generation) return;
                page.transferTask = nil; page.busy = NO; page.importing = NO;
                if (!isInstalled(page.records[key])) { [page fail:error.length ? [error substringToIndex:MIN(error.length, (NSUInteger)1024)] : @"Le transfert n’a pas abouti. Touche cette version pour le reprendre." key:key]; return; }
                page.progress = 1; page.message = @"Copie enregistrée. Retrouve-la dans Bibliothèque → Fichiers locaux. L’original est conservé.";
                [page refreshUI]; [page continuePending];
            });
        });
        return;
    }
    self.message = [job[@"message"] length] ? job[@"message"] : @"Préparation sur le PC…"; [self refreshUI];
    [self later:2 block:^(SGAudioVariantsPage *page) {
        __weak SGAudioVariantsPage *weak = page; NSString *path = [@"audio-variants/" stringByAppendingString:job[@"id"]];
        [page json:path body:nil completion:^(id value, NSInteger code) {
            SGAudioVariantsPage *result = weak; if (!result || result.generation != generation) return;
            NSDictionary *next = code == 200 ? SGAudioVariantJob(value, result.records[key][@"request"]) : nil;
            if (!next || ![next[@"id"] isEqual:job[@"id"]]) {
                if (!code || code >= 500) [result waitForPC];
                else {
                    if (code == 404) {
                        NSMutableDictionary *missing = [result.records[key] mutableCopy];
                        [missing removeObjectForKey:@"job"]; [result saveRecord:missing];
                    }
                    [result fail:@"Le suivi est indisponible. La copie originale est conservée ; touche la version pour réessayer." key:key];
                }
                return;
            }
            [result handleJob:next key:key generation:generation];
        }];
    }];
}
- (void)choose:(NSDictionary *)option {
    if (self.busy) return;
    NSString *key = SGAudioVariantKey(option); NSDictionary *old = self.records[key];
    if (isInstalled(old)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:old[@"installed"][@"title"]
            message:@"Cette copie est disponible dans Bibliothèque → Fichiers locaux. Le morceau original reste inchangé."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil]; return;
    }
    NSDictionary *job = old[@"job"] ?: self.serverJobs[key];
    BOOL terminal = [@[@"error", @"interrupted"] containsObject:job[@"state"] ?: @""];
    BOOL supported = [option[@"kind"] isEqual:@"instrumental"] ? [self.capabilities[@"instrumental"] boolValue] : [self.capabilities[@"speeds"] containsObject:option[@"speed"]];
    if ((!job || terminal) && !supported) { self.message = @"Cette option n’est pas disponible sur le PC associé."; [self refreshUI]; return; }
    NSMutableDictionary *request = [old[@"request"] mutableCopy] ?: [option mutableCopy];
    if (!request[@"request_id"] || terminal) request[@"request_id"] = NSUUID.UUID.UUIDString;
    request = [SGAudioVariantRequest(request) mutableCopy]; if (!request) return;
    NSMutableDictionary *record = [@{@"request":request,@"paused":@NO} mutableCopy]; if (job && !terminal) record[@"job"] = job;
    // Persist before any POST. A timeout always retries this same idempotent request.
    if (![self saveRecord:record]) { [self refreshUI]; return; }
    self.selectedKey = key; self.failed = NO;
    if (self.root) [self continuePending]; else [self connect];
}
- (void)refreshUI { if (self.isViewLoaded) [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 2 : [self options].count; }
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section { return section == 1 ? SGSectionHeader(tableView, @"Créer une copie") : nil; }
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return section == 1 ? SGSectionHeaderHeight : SGSectionGap; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(tableView, @"audio-variant"); cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = nil;
    if (path.section == 0) {
        NSString *title = path.row == 0 ? (self.failed ? @"Action interrompue" : self.busy ? (self.importing ? @"Enregistrement" : @"Préparation") : @"Copies audio") : self.busy ? @"Mettre en pause" : @"Reprendre / actualiser le PC";
        NSString *detail = path.row == 0 ? self.message : self.busy ? @"La préparation sur le PC peut continuer. L’original reste disponible." : @"Reprendre une demande conservée ou vérifier les options du PC.";
        SGFillCell(cell, title, detail, self.failed && path.row == 0 ? SGRed() : nil, path.row == 0 ? @"waveform" : self.busy ? @"pause.circle" : @"arrow.clockwise");
        cell.selectionStyle = path.row == 0 ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = path.row == 0 ? UIAccessibilityTraitStaticText : UIAccessibilityTraitButton;
    } else {
        NSArray *options = [self options]; if ((NSUInteger)path.row >= options.count) return cell;
        NSDictionary *option = options[path.row]; NSString *key = SGAudioVariantKey(option); NSDictionary *record = self.records[key], *job = record[@"job"] ?: self.serverJobs[key];
        BOOL installed = isInstalled(record), current = self.busy && [self.selectedKey isEqual:key];
        NSString *detail = [option[@"kind"] isEqual:@"instrumental"] ? @"Créer une copie instrumentale ; la préparation peut prendre plusieurs minutes" : @"Créer une copie en conservant la hauteur de la voix";
        if (installed) detail = @"Disponible dans Fichiers locaux";
        else if (current && self.importing) detail = self.transferStarted ? [NSString stringWithFormat:@"Transfert vers l'iPhone · %.0f %%", self.progress * 100] : @"Prête sur le PC · en attente du transfert vers l'iPhone";
        else if (record[@"error"]) detail = record[@"error"];
        else if ([record[@"paused"] boolValue]) detail = @"En pause · toucher pour reprendre";
        else if ([job[@"state"] isEqual:@"ready"]) detail = @"Prête sur le PC · toucher pour enregistrer";
        else if (current) detail = @"Préparation en cours sur le PC";
        else if (record) detail = @"Demande conservée · toucher pour reprendre";
        SGFillCell(cell, SGAudioVariantLabel(option), detail, installed ? SGGreen() : record[@"error"] ? SGRed() : nil,
            installed ? @"checkmark.circle.fill" : [option[@"kind"] isEqual:@"instrumental"] ? @"waveform" : @"speedometer");
        cell.selectionStyle = self.busy ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton;
    }
    UIListContentConfiguration *content = [cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class] ? (UIListContentConfiguration *)cell.contentConfiguration : nil;
    content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 0; cell.contentConfiguration = content;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) { NSArray *options = [self options]; if ((NSUInteger)path.row < options.count) [self choose:options[path.row]]; return; }
    if (path.row != 1) return;
    if (self.busy) {
        NSString *key = self.selectedKey ?: [self pendingKey];
        NSMutableDictionary *record = [self.records[key ?: @""] mutableCopy];
        if (record) { record[@"paused"] = @YES; [self saveRecord:record]; }
        [self suspend]; self.message = @"En pause. Ta demande et les octets reçus sont conservés."; [self refreshUI]; return;
    }
    for (NSDictionary *option in [self options]) {
        NSString *key = SGAudioVariantKey(option); NSMutableDictionary *record = [self.records[key] mutableCopy];
        if ([record[@"paused"] boolValue] && !record[@"error"]) { record[@"paused"] = @NO; [self saveRecord:record]; self.selectedKey = key; break; }
    }
    [self connect];
}
@end

UIViewController *SGAudioVariantsPageCreate(NSDictionary *downloadedRow) { return [[SGAudioVariantsPage alloc] initWithRow:downloadedRow]; }
