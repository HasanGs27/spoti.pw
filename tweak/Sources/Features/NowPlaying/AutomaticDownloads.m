// Foreground automatic preparation on a paired PC, followed by verified local import.
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "LocalDownloadManifest.h"
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSString *const changed = @"SGAutomaticDownloadsChanged";
static NSString *const pairKey = @"spotifyglass.automaticDownloads.pair";
static __weak id observedPlayer;

@interface NSObject (SGDownloadNative)
- (id)initWithDictionary:(NSDictionary *)dictionary;
- (id)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
- (void)setURI:(NSURL *)uri;
- (void)setPages:(NSArray *)pages;
- (void)setTracks:(NSArray *)tracks;
- (void)setMetadata:(NSDictionary *)metadata;
- (id)playContext:(id)context options:(id)options;
@end

static NSString *fileHash(NSURL *file) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:file];
    [stream open];
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    uint8_t bytes[65536]; NSInteger read;
    while ((read = [stream read:bytes maxLength:sizeof(bytes)]) > 0) CC_SHA256_Update(&state, bytes, (CC_LONG)read);
    [stream close];
    if (read < 0) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(hash, &state);
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(hash); i++) [text appendFormat:@"%02x", hash[i]];
    return text;
}
static NSURL *downloadsDirectory(void) {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [docs URLByAppendingPathComponent:@"Spoti Downloads" isDirectory:YES];
}
static NSURL *rowFile(NSDictionary *row) {
    if (![row[@"state"] isEqual:@"ready"]) return nil;
    return [downloadsDirectory() URLByAppendingPathComponent:[row[@"id"] stringByAppendingString:@".mp3"]];
}
static BOOL onPhone(NSDictionary *row) {
    NSURL *file = rowFile(row);
    NSNumber *size = nil, *link = nil;
    [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [file getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    return file && !link.boolValue && [size isEqual:row[@"bytes"]];
}
static void tell(NSString *message) {
    UIViewController *owner = SGTopController();
    if (!owner || owner.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Téléchargements" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

@interface SGAutomaticDownloads : NSObject <NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate>
@property (atomic) BOOL busy;
@property (atomic) NSUInteger generation;
@property (atomic, copy) NSString *message;
@property (atomic, copy) NSDictionary *job;
@property (atomic, copy) NSDictionary *history;
@property (atomic, copy) NSDictionary *pending;
@property (atomic, strong) NSURL *root;
@property (atomic, strong) NSURLSessionTask *active;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t worker;
@property (nonatomic, strong) id playTask;
+ (instancetype)shared;
- (void)update:(NSString *)message;
- (void)connect:(NSString *)address;
- (void)start:(NSString *)url;
- (void)resume;
- (void)pause;
- (void)play:(NSUInteger)position;
- (void)submitPending;
- (void)follow:(NSDictionary *)initial root:(NSURL *)root generation:(NSUInteger)generation;
@end

@implementation SGAutomaticDownloads
+ (instancetype)shared {
    static SGAutomaticDownloads *engine; static dispatch_once_t once;
    dispatch_once(&once, ^{
        engine = [self new];
        engine.worker = dispatch_queue_create("pw.spoti.automatic-downloads", DISPATCH_QUEUE_SERIAL);
        engine.message = @"Connecte le PC une fois, puis utilise la flèche d’une playlist.";
        engine.root = SGDownloadRoot([NSUserDefaults.standardUserDefaults stringForKey:pairKey]);
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"spotifyglass.automaticDownloads.history"];
        NSMutableDictionary *valid = [NSMutableDictionary dictionary];
        for (id key in stored) {
            NSData *data = [NSJSONSerialization isValidJSONObject:stored[key]] ? [NSJSONSerialization dataWithJSONObject:stored[key] options:0 error:nil] : nil;
            NSDictionary *job = SGAutomaticJob(data);
            if (job && [key isEqual:job[@"url"]]) valid[key] = job;
        }
        engine.history = valid;
        NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:@"spotifyglass.automaticDownloads.last"];
        engine.job = last ? valid[last] : nil;
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 150;
        config.allowsCellularAccess = NO; config.URLCache = nil; config.HTTPCookieStorage = nil;
        engine.session = [NSURLSession sessionWithConfiguration:config delegate:engine delegateQueue:nil];
    });
    return engine;
}
- (void)update:(NSString *)message {
    self.message = message;
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:changed object:self]; });
}
- (void)saveJob:(NSDictionary *)job {
    self.job = job;
    NSMutableDictionary *history = [self.history mutableCopy] ?: [NSMutableDictionary dictionary];
    history[job[@"url"]] = job;
    self.history = history;
    [NSUserDefaults.standardUserDefaults setObject:history forKey:@"spotifyglass.automaticDownloads.history"];
    [NSUserDefaults.standardUserDefaults setObject:job[@"url"] forKey:@"spotifyglass.automaticDownloads.last"];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))done { done(nil); }
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes
    totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    if (written > task.taskDescription.longLongValue || expected > task.taskDescription.longLongValue) [task cancel];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)url {}
- (NSURL *)fetch:(NSURLRequest *)request limit:(NSUInteger)limit generation:(NSUInteger)generation {
    if (generation != self.generation) return nil;
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *staging = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"sg-auto-%@.mp3", NSUUID.UUID.UUIDString]];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL copied = NO;
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:request completionHandler:^(NSURL *file, NSURLResponse *response, NSError *error) {
        NSNumber *size = nil; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && generation == self.generation && (code == 200 || code == 202) && size.unsignedIntegerValue > 0 && size.unsignedIntegerValue <= limit)
            copied = [NSFileManager.defaultManager moveItemAtURL:file toURL:staging error:nil];
        dispatch_semaphore_signal(done);
    }];
    task.taskDescription = @(limit).stringValue;
    self.active = task;
    if (generation == self.generation) [task resume]; else [task cancel];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    self.active = nil;
    if (copied && generation == self.generation) return staging;
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    return nil;
}
- (NSData *)json:(NSURLRequest *)request generation:(NSUInteger)generation {
    NSURL *file = [self fetch:request limit:2 * 1024 * 1024 generation:generation];
    NSData *data = file ? [NSData dataWithContentsOfURL:file] : nil;
    if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return data;
}
- (void)finish:(NSString *)message generation:(NSUInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.generation != generation) return;
        self.busy = NO; [self update:message];
    });
}
- (void)connect:(NSString *)address {
    if (self.busy) return;
    NSURL *root = SGDownloadRoot(address);
    if (!root) { [self update:@"Lien du PC invalide."]; return; }
    self.busy = YES; NSUInteger generation = ++self.generation;
    [self update:@"Connexion au PC…"];
    dispatch_async(self.worker, ^{
        NSData *data = [self json:[NSURLRequest requestWithURL:[root URLByAppendingPathComponent:@"hello"]] generation:generation];
        id hello = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL valid = [hello isKindOfClass:NSDictionary.class] && [hello[@"version"] isEqual:@2] && [hello[@"service"] isEqual:@"spoti-auto-downloads"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) return;
            self.busy = NO;
            if (!valid) { [self update:@"PC inaccessible. Vérifie le même Wi-Fi et l’autorisation Réseau local de Spotify."]; return; }
            self.root = root;
            [NSUserDefaults.standardUserDefaults setObject:root.absoluteString forKey:pairKey];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SGAutomaticDownloadsEnabled"];
            [self update:@"PC connecté. La flèche d’une playlist peut lancer sa préparation."];
            if (self.pending) [self submitPending];
        });
    });
}
- (void)start:(NSString *)url {
    if (self.busy) { [self update:@"Un transfert est déjà en cours. Tu peux le suivre ici."]; return; }
    NSString *canonical = SGAutomaticSpotifyURL(url);
    if (!canonical) return;
    self.pending = @{@"url":canonical, @"request_id":NSUUID.UUID.UUIDString};
    if (!self.root) { [self update:@"Connecte le PC ci-dessus : la sélection sera ensuite envoyée automatiquement."]; return; }
    [self submitPending];
}
- (void)submitPending {
    if (self.busy || !self.pending || !self.root) return;
    self.busy = YES; NSUInteger generation = ++self.generation;
    NSURL *root = self.root;
    NSDictionary *pending = self.pending;
    [self update:@"Envoi de la sélection au PC…"];
    dispatch_async(self.worker, ^{
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[root URLByAppendingPathComponent:@"jobs"]];
        request.HTTPMethod = @"POST"; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:pending options:0 error:nil];
        NSDictionary *job = SGAutomaticJob([self json:request generation:generation]);
        if (!job || ![job[@"url"] isEqual:pending[@"url"]]) {
            [self finish:@"Le PC n’a pas confirmé la demande. Reprendre réessaiera sans créer de doublon." generation:generation]; return;
        }
        self.pending = nil;
        [self saveJob:job];
        [self follow:job root:root generation:generation];
    });
}
- (BOOL)importRow:(NSDictionary *)row root:(NSURL *)root generation:(NSUInteger)generation {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = downloadsDirectory();
    [fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil];
    NSNumber *dir = nil, *link = nil;
    [directory getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
    [directory getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    if (!dir.boolValue || link.boolValue || ![[directory URLByResolvingSymlinksInPath].URLByDeletingLastPathComponent.path
        isEqual:[directory.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath].path]) return NO;
    NSURL *target = rowFile(row);
    if (onPhone(row)) return [fileHash(target) isEqual:row[@"id"]];
    NSURL *url = [[root URLByAppendingPathComponent:@"file"] URLByAppendingPathComponent:row[@"id"]];
    NSURL *file = [self fetch:[NSURLRequest requestWithURL:url] limit:[row[@"bytes"] unsignedIntegerValue] generation:generation];
    if (!file) return NO;
    NSNumber *bytes = nil; [file getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
    BOOL valid = [bytes isEqual:row[@"bytes"]] && [fileHash(file) isEqual:row[@"id"]];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (valid) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
        double duration = CMTimeGetSeconds(asset.duration);
        valid = asset.playable && [asset tracksWithMediaType:AVMediaTypeAudio].count && isfinite(duration) && fabs(duration - [row[@"seconds"] doubleValue]) < 2;
    }
#pragma clang diagnostic pop
    BOOL imported = valid && generation == self.generation && [fm moveItemAtURL:file toURL:target error:nil];
    if (imported) [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:target.path error:nil];
    [fm removeItemAtURL:file error:nil];
    return imported;
}
- (void)follow:(NSDictionary *)initial root:(NSURL *)root generation:(NSUInteger)generation {
    NSDictionary *job = initial;
    NSMutableSet *checked = [NSMutableSet set];
    while (generation == self.generation) {
        [self saveJob:job];
        for (NSDictionary *row in job[@"items"]) {
            if (generation != self.generation) return;
            if (![row[@"state"] isEqual:@"ready"] || [checked containsObject:row[@"id"]]) continue;
            [self update:[@"Enregistrement sur l’iPhone : " stringByAppendingString:row[@"title"]]];
            if (![self importRow:row root:root generation:generation]) {
                [self finish:@"Transfert interrompu ou fichier invalide. Les copies terminées sont conservées ; touche Reprendre." generation:generation]; return;
            }
            [checked addObject:row[@"id"]];
        }
        NSUInteger local = 0, failures = 0;
        for (NSDictionary *row in job[@"items"]) { local += onPhone(row); failures += [row[@"state"] isEqual:@"error"]; }
        NSString *status = [NSString stringWithFormat:@"%lu/%lu sur l’iPhone · %lu introuvables. %@", (unsigned long)local,
            (unsigned long)[job[@"items"] count], (unsigned long)failures, job[@"message"]];
        if (![@[@"queued", @"resolving", @"running"] containsObject:job[@"state"]]) {
            [self finish:status generation:generation]; return;
        }
        [self update:status];
        [NSThread sleepForTimeInterval:2]; // Dedicated worker, never the UI thread.
        if (generation != self.generation) return;
        NSURL *url = [[root URLByAppendingPathComponent:@"jobs"] URLByAppendingPathComponent:job[@"id"]];
        NSDictionary *next = SGAutomaticJob([self json:[NSURLRequest requestWithURL:url] generation:generation]);
        if (!next || ![next[@"id"] isEqual:job[@"id"]] || ![next[@"url"] isEqual:job[@"url"]]) {
            [self finish:@"Suivi interrompu. Le PC peut continuer ; touche Reprendre pour récupérer les fichiers." generation:generation]; return;
        }
        job = next;
    }
}
- (void)resume {
    if (self.busy) return;
    if (self.pending) { [self submitPending]; return; }
    if (!self.job || !self.root) { [self update:@"Connecte le PC puis utilise une flèche de téléchargement."]; return; }
    self.busy = YES; NSUInteger generation = ++self.generation;
    NSDictionary *job = self.job; NSURL *root = self.root;
    dispatch_async(self.worker, ^{ [self follow:job root:root generation:generation]; });
}
- (void)pause {
    if (!self.busy) return;
    NSUInteger generation = ++self.generation;
    [self.active cancel];
    [self update:@"Arrêt du transfert iPhone…"];
    dispatch_async(self.worker, ^{ [self finish:@"Transfert iPhone arrêté. Le PC poursuit la préparation ; Reprendre récupérera la suite." generation:generation]; });
}
- (void)play:(NSUInteger)position {
    NSArray *rows = self.job[@"items"];
    if (position >= rows.count || !onPhone(rows[position])) return;
    id player = observedPlayer;
    Class contextClass = NSClassFromString(@"SPTPlayerContext"), pageClass = NSClassFromString(@"SPTPlayerContextPage");
    Class trackClass = NSClassFromString(@"SPTPlayerTrack"), optionsClass = NSClassFromString(@"SPTPlayOptions");
    if (![player respondsToSelector:@selector(playContext:options:)] || !contextClass || !pageClass || !trackClass || !optionsClass) {
        tell(@"Le lecteur natif n’a pas encore été observé. Lance une fois un morceau dans Spotify, ou ouvre Fichiers locaux."); return;
    }
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSUInteger i = position; i < rows.count; i++) {
        NSDictionary *row = rows[i]; if (!onPhone(row)) continue;
        NSURL *uri = [NSURL URLWithString:SGAutomaticLocalURI(row)];
        id track = [[trackClass alloc] initWithURI:uri albumURI:nil artistURI:nil andUID:NSUUID.UUID.UUIDString];
        [track setMetadata:@{@"title":row[@"title"], @"artist_name":row[@"artist"], @"album_title":row[@"album"],
            @"duration":[NSString stringWithFormat:@"%.0f", [row[@"seconds"] doubleValue] * 1000]}];
        if (track) [tracks addObject:track];
    }
    if (!tracks.count) return;
    id page = [pageClass new]; [page setTracks:tracks];
    id context = [[contextClass alloc] initWithDictionary:@{}];
    [context setURI:[NSURL URLWithString:SGAutomaticLocalURI(rows[position])]];
    [context setPages:@[page]];
    self.playTask = [player playContext:context options:[optionsClass new]];
    SGLog(@"[SGAutoDownloads] native local playback requested count=%lu", (unsigned long)tracks.count);
    [self update:@"Lecture locale demandée. Si Spotify n’a pas encore indexé le fichier, ouvre Fichiers locaux ou relance l’app."];
}
@end

@interface SGAutomaticDownloadsPage : SGPage
@property (nonatomic, strong) UIView *note;
@property (nonatomic, copy) NSArray *historyURLs;
@property (nonatomic, copy) NSDictionary *displayJob;
@property (nonatomic, copy) NSDictionary *displayHistory;
@end
@implementation SGAutomaticDownloadsPage
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Téléchargements automatiques"; return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.note = SGNote(@"Associe le PC une fois. La flèche d’une playlist lance ensuite sa recherche et son transfert. Même Wi-Fi, PC allumé, Spotify ouvert. Les titres sans source fiable restent en échec. Tes copies sont accessibles ici et dans Fichiers locaux.");
    self.tableView.tableHeaderView = self.note;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh:) name:changed object:SGAutomaticDownloads.shared];
    [self refresh:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh:(NSNotification *)note {
    // A coherent main-thread snapshot prevents row counts changing underneath table callbacks.
    self.displayJob = SGAutomaticDownloads.shared.job;
    self.displayHistory = SGAutomaticDownloads.shared.history;
    self.historyURLs = [self.displayHistory.allKeys sortedArrayUsingSelector:@selector(compare:)];
    [self.tableView reloadData];
}
- (void)viewWillLayoutSubviews { [super viewWillLayoutSubviews]; SGFitNote(self.tableView, self.note, 16, 16); }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; SGInsetForBars(self.tableView); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 5 : section == 1 ? [self.displayJob[@"items"] count] : self.historyURLs.count;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? (self.displayJob[@"name"] ?: @"Sélection") : section == 2 ? @"Sélections enregistrées" : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return section == 1 ? self.displayJob[@"scope"] : nil;
}
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path { return path.section == 0 && path.row == 4 ? 140 : 70; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"auto-download");
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    if (path.section == 0) {
        NSArray *titles = @[@"Connecter le PC", @"Télécharger un lien", engine.busy ? @"Arrêter le transfert iPhone" : @"Reprendre le transfert", @"Réessayer cette sélection", @"État"];
        SGFillCell(cell, titles[path.row], path.row == 4 ? engine.message : nil, nil, nil);
    } else if (path.section == 1) {
        NSDictionary *row = self.displayJob[@"items"][path.row];
        NSString *status = onPhone(row) ? @"Sur l’iPhone — toucher pour lire" : [row[@"state"] isEqual:@"error"] ? @"Source introuvable ou refusée" : [row[@"state"] isEqual:@"ready"] ? @"Prêt sur le PC" : @"Recherche en cours";
        SGFillCell(cell, row[@"title"], [NSString stringWithFormat:@"%@ · %@", row[@"artist"], status], nil, onPhone(row) ? @"play.circle" : @"arrow.down.circle");
    } else {
        NSDictionary *job = self.displayHistory[self.historyURLs[path.row]];
        SGFillCell(cell, job[@"name"], @"Ouvrir les copies de cette sélection", nil, @"music.note.list");
    }
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    if (path.section == 1) {
        if ([engine.job[@"id"] isEqual:self.displayJob[@"id"]]) [engine play:path.row];
        else [self refresh:nil];
        return;
    }
    if (path.section == 2) {
        if (engine.busy) { tell(@"Arrête d’abord le transfert iPhone pour changer de sélection."); return; }
        engine.job = self.displayHistory[self.historyURLs[path.row]]; [self refresh:nil]; return;
    }
    if (path.row == 2) { if (engine.busy) [engine pause]; else [engine resume]; return; }
    if (path.row == 3) { if (engine.job && !engine.busy) [engine start:engine.job[@"url"]]; return; }
    if (path.row > 1 || engine.busy) return;
    BOOL pairing = path.row == 0;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:pairing ? @"Connecter le PC" : @"Télécharger un lien"
        message:pairing ? @"Colle le lien d’association fourni par le PC." : @"Lien Spotify d’un morceau ou d’une playlist publique. La flèche évite cette saisie quand elle reconnaît la page."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeURL; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        if (pairing) field.text = [NSUserDefaults.standardUserDefaults stringForKey:pairKey];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = alert;
    [alert addAction:[UIAlertAction actionWithTitle:pairing ? @"Connecter" : @"Télécharger" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (pairing) [engine connect:weak.textFields.firstObject.text ?: @""];
        else {
            NSString *url = SGAutomaticSpotifyURL(weak.textFields.firstObject.text);
            if (url) [engine start:url]; else [engine update:@"Lien de morceau ou playlist Spotify invalide."];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *SGAutomaticDownloadsPageCreate(void) { return [SGAutomaticDownloadsPage new]; }
void SGAutomaticDownloadObservePlayer(id player) { observedPlayer = player; }
BOOL SGAutomaticDownloadEntity(id entity, UIView *source) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    if (!url || ![NSUserDefaults.standardUserDefaults boolForKey:@"SGAutomaticDownloadsEnabled"]) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
        NSDictionary *saved = engine.history[url];
        if (!engine.busy && saved) { engine.job = saved; [engine update:@"Sélection enregistrée. Touche un morceau pour lire, ou Reprendre pour terminer le transfert."]; }
        else if (!engine.busy) [engine start:url];
        UIViewController *owner = SGTopController();
        if (![owner isKindOfClass:SGAutomaticDownloadsPage.class]) SGShowPage(owner, SGAutomaticDownloadsPageCreate());
    });
    return YES;
}
