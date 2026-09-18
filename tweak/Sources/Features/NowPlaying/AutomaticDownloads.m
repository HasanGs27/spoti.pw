// One durable queue for on-device preparation, optional PC preparation, and manual repairs.
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "AutomaticAudioFile.h"
#import "NativeDownloadCollection.h"
#import "NativeAudioResolver.h"
#import "LocalDownloadManifest.h"
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const changed = @"SGAutomaticDownloadsDidChange";
static NSString *const pairKey = @"spotifyglass.automaticDownloads.pair";
static NSString *const modeKey = @"spotifyglass.automaticDownloads.mode";
static NSString *const queueKey = @"spotifyglass.automaticDownloads.queue";
static __weak id observedPlayer;

static NSCache *verifiedFiles(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 10000; });
    return cache;
}
static NSCache *statusCounts(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 200; });
    return cache;
}

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
    return [downloadsDirectory() URLByAppendingPathComponent:[row[@"id"] stringByAppendingPathExtension:row[@"extension"] ?: @"mp3"]];
}
static BOOL onPhone(NSDictionary *row) {
    NSURL *file = rowFile(row);
    if (!file || !row[@"id"]) return NO;
    NSDictionary *stamp = [verifiedFiles() objectForKey:row[@"id"]];
    if (!stamp) return NO;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    return [attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] isEqual:row[@"bytes"]] &&
        [attrs[NSFileModificationDate] isEqual:stamp[NSFileModificationDate]] && [attrs[NSFileSystemFileNumber] isEqual:stamp[NSFileSystemFileNumber]];
}
static void markVerified(NSDictionary *row) {
    NSURL *file = rowFile(row);
    NSDictionary *attrs = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    if (row[@"id"] && [attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] isEqual:row[@"bytes"]])
        [verifiedFiles() setObject:attrs forKey:row[@"id"]];
    [statusCounts() removeAllObjects];
}
static BOOL verifyRow(NSDictionary *row) {
    if (onPhone(row)) return YES;
    NSURL *file = rowFile(row);
    NSDictionary *attrs = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || ![attrs[NSFileSize] isEqual:row[@"bytes"]] || ![fileHash(file) isEqual:row[@"id"]]) return NO;
    markVerified(row); return onPhone(row);
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
@property (atomic, copy) NSDictionary *localRows;
@property (atomic, copy) NSDictionary *importErrors;
@property (atomic, copy) NSString *activeSpotify;
@property (atomic, copy) NSString *activeCollection;
@property (atomic, copy) NSArray *queuedURLs;
@property (atomic, copy) NSDictionary *registeredTracks;
@property (atomic, copy) NSDictionary *collectionErrors;
@property (atomic, copy) NSString *devicePendingURL;
@property (atomic) double transferProgress;
@property (atomic) BOOL userPaused;
@property (atomic) BOOL preparingAudio;
@property (atomic, strong) id resolverToken;
@property (nonatomic) CFTimeInterval lastProgressNotification;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, strong) NSCache *covers;
@property (atomic, strong) NSURL *root;
@property (atomic, strong) NSURLSessionTask *active;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSession *audioSession;
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
- (void)importAudio:(NSURL *)source row:(NSDictionary *)row selection:(NSDictionary *)selection;
- (NSDictionary *)merged:(NSDictionary *)job;
- (void)remember:(NSDictionary *)row;
- (void)startDevice:(NSString *)url;
- (void)followDevice:(NSDictionary *)job generation:(NSUInteger)generation;
- (void)runDeviceRow:(NSDictionary *)row selection:(NSDictionary *)job source:(NSURL *)source generation:(NSUInteger)generation;
- (NSDictionary *)resolve:(NSDictionary *)row source:(NSURL *)source generation:(NSUInteger)generation error:(NSString **)reason;
- (void)saveError:(NSString *)reason row:(NSDictionary *)row;
- (void)setRow:(NSDictionary *)row inJob:(NSDictionary *)job;
- (void)beginBackgroundAllowance;
- (void)advanceQueue;
- (void)selectJob:(NSDictionary *)job;
- (void)repairRow:(NSDictionary *)row selection:(NSDictionary *)selection source:(NSURL *)source;
@end

@implementation SGAutomaticDownloads
+ (instancetype)shared {
    static SGAutomaticDownloads *engine; static dispatch_once_t once;
    dispatch_once(&once, ^{
        engine = [self new];
        [NSUserDefaults.standardUserDefaults registerDefaults:@{@"SGAutomaticDownloadsEnabled":@YES, modeKey:@"device"}];
        engine.worker = dispatch_queue_create("pw.spoti.automatic-downloads", DISPATCH_QUEUE_SERIAL);
        engine.message = @"Utilise la flèche d'une playlist pour enregistrer ses morceaux sur cet iPhone.";
        engine.covers = [NSCache new]; engine.covers.countLimit = 150;
        engine.backgroundTask = UIBackgroundTaskInvalid;
        NSMutableArray *queued = [NSMutableArray array];
        for (id value in [NSUserDefaults.standardUserDefaults arrayForKey:queueKey]) {
            NSString *url = SGAutomaticSpotifyURL(value);
            if (url && ![queued containsObject:url] && queued.count < 10) [queued addObject:url];
        }
        engine.queuedURLs = queued;
        engine.registeredTracks = @{};
        engine.collectionErrors = @{};
        engine.devicePendingURL = SGAutomaticSpotifyURL([NSUserDefaults.standardUserDefaults stringForKey:@"spotifyglass.automaticDownloads.pendingDevice"]);
        engine.root = SGDownloadRoot([NSUserDefaults.standardUserDefaults stringForKey:pairKey]);
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"spotifyglass.automaticDownloads.history"];
        NSMutableDictionary *valid = [NSMutableDictionary dictionary];
        for (id key in stored) {
            NSData *data = [NSJSONSerialization isValidJSONObject:stored[key]] ? [NSJSONSerialization dataWithJSONObject:stored[key] options:0 error:nil] : nil;
            NSDictionary *job = SGAutomaticJob(data);
            if (job && [key isEqual:job[@"url"]]) valid[key] = job;
        }
        engine.history = valid;
        engine.importErrors = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"spotifyglass.automaticDownloads.errors"] ?: @{};
        NSDictionary *savedLocal = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"spotifyglass.automaticDownloads.localRows"];
        NSMutableDictionary *local = [NSMutableDictionary dictionary];
        for (NSString *key in savedLocal) {
            NSDictionary *row = savedLocal[key];
            NSDictionary *wrapper = @{@"version":@2, @"id":@"00000000000000000000000000000000", @"url":key,
                @"state":@"complete", @"name":@"Local", @"message":@"", @"scope":@"", @"items":@[row]};
            NSData *json = [NSJSONSerialization isValidJSONObject:wrapper] ? [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil] : nil;
            NSDictionary *parsed = SGAutomaticJob(json);
            if (parsed && [parsed[@"items"][0][@"spotify"] isEqual:key]) local[key] = parsed[@"items"][0];
        }
        engine.localRows = local;
        NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:@"spotifyglass.automaticDownloads.last"];
        engine.job = last ? [engine merged:valid[last]] : nil;
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 150;
        config.allowsCellularAccess = NO; config.URLCache = nil; config.HTTPCookieStorage = nil;
        engine.session = [NSURLSession sessionWithConfiguration:config delegate:engine delegateQueue:nil];
        NSURLSessionConfiguration *audioConfig = [config copy];
        audioConfig.allowsCellularAccess = YES;
        engine.audioSession = [NSURLSession sessionWithConfiguration:audioConfig delegate:engine delegateQueue:nil];
        dispatch_async(engine.worker, ^{
            // Hashes are checked off the UI thread after launch; an old green state is not trusted.
            NSMutableDictionary *candidates = [engine.localRows mutableCopy];
            for (NSDictionary *job in engine.history.allValues)
                for (NSDictionary *row in job[@"items"])
                    if ([row[@"state"] isEqual:@"ready"] && !candidates[row[@"spotify"]]) candidates[row[@"spotify"]] = row;
            for (NSDictionary *row in candidates.allValues) if (verifyRow(row)) [engine remember:row];
            [engine update:engine.message];
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (!engine.busy) dispatch_async(engine.worker, ^{
                for (NSDictionary *row in engine.localRows.allValues) verifyRow(row);
                [engine update:engine.message];
            });
        }];
    });
    return engine;
}
- (void)update:(NSString *)message {
    if (message) self.message = message;
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:changed object:self]; });
}
- (void)selectJob:(NSDictionary *)job {
    if (self.busy || !job) return;
    self.pending = nil; self.devicePendingURL = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.automaticDownloads.pendingDevice"];
    self.job = [self merged:job];
    [NSUserDefaults.standardUserDefaults setObject:job[@"url"] forKey:@"spotifyglass.automaticDownloads.last"];
}
- (void)saveJob:(NSDictionary *)job {
    job = [self merged:job];
    self.job = job;
    NSMutableDictionary *history = [self.history mutableCopy] ?: [NSMutableDictionary dictionary];
    history[job[@"url"]] = job;
    self.history = history;
    [NSUserDefaults.standardUserDefaults setObject:history forKey:@"spotifyglass.automaticDownloads.history"];
    [NSUserDefaults.standardUserDefaults setObject:job[@"url"] forKey:@"spotifyglass.automaticDownloads.last"];
}
- (NSDictionary *)merged:(NSDictionary *)job {
    NSMutableDictionary *available = [NSMutableDictionary dictionary];
    for (NSString *key in self.localRows) if (onPhone(self.localRows[key])) available[key] = self.localRows[key];
    return SGAutomaticMergeLocalRows(job, available);
}
- (void)remember:(NSDictionary *)row {
    if (!onPhone(row)) return;
    NSMutableDictionary *record = [row mutableCopy]; record[@"position"] = @1;
    NSMutableDictionary *local = [self.localRows mutableCopy] ?: [NSMutableDictionary dictionary];
    local[SGAutomaticSpotifyURL(row[@"spotify"])] = record; self.localRows = local;
    [NSUserDefaults.standardUserDefaults setObject:local forKey:@"spotifyglass.automaticDownloads.localRows"];
    NSMutableDictionary *errors = [self.importErrors mutableCopy]; [errors removeObjectForKey:row[@"spotify"]];
    self.importErrors = errors; [NSUserDefaults.standardUserDefaults setObject:errors forKey:@"spotifyglass.automaticDownloads.errors"];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))done {
    // The paired PC stays on its exact endpoint. Audio sources may use an HTTPS CDN redirect.
    BOOL metadata = [task.originalRequest.URL.host isEqual:@"open.spotify.com"] && [task.originalRequest.URL.path hasPrefix:@"/embed/"] &&
        [request.URL.scheme isEqual:@"https"] && [request.URL.host isEqual:@"open.spotify.com"] && [request.URL.path hasPrefix:@"/embed/"];
    done(session == self.audioSession && (metadata || SGAutomaticAudioSource(request.URL.absoluteString)) ? request : nil);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes
    totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    if (written > task.taskDescription.longLongValue || expected > task.taskDescription.longLongValue) [task cancel];
    if (self.preparingAudio && expected > 0) {
        self.transferProgress = MIN(0.98, (double)written / (double)expected);
        CFTimeInterval now = CACurrentMediaTime();
        if (now - self.lastProgressNotification > 0.4) { self.lastProgressNotification = now; [self update:nil]; }
    }
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)url {}
- (NSURL *)fetch:(NSURLRequest *)request limit:(NSUInteger)limit generation:(NSUInteger)generation {
    if (generation != self.generation) return nil;
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *staging = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"sg-auto-%@.mp3", NSUUID.UUID.UUIDString]];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL copied = NO;
    NSURLSession *session = [request.URL.scheme.lowercaseString isEqual:@"https"] ? self.audioSession : self.session;
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request completionHandler:^(NSURL *file, NSURLResponse *response, NSError *error) {
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
        self.busy = NO; self.activeSpotify = nil; self.activeCollection = nil;
        self.preparingAudio = NO; self.transferProgress = 0; self.resolverToken = nil;
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask]; self.backgroundTask = UIBackgroundTaskInvalid;
        }
        [self update:message];
        if (!self.userPaused) [self advanceQueue];
    });
}
- (void)beginBackgroundAllowance {
    if (self.backgroundTask != UIBackgroundTaskInvalid) return;
    __weak typeof(self) weak = self;
    self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Spoti téléchargement" expirationHandler:^{
        UIBackgroundTaskIdentifier task = weak.backgroundTask;
        weak.backgroundTask = UIBackgroundTaskInvalid;
        if (task != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:task];
        [weak pause];
        [weak update:@"Mis en pause par iOS. Reviens dans Spotify et touche Reprendre."];
    }];
}
- (void)advanceQueue {
    if (self.busy || self.userPaused || !self.queuedURLs.count) return;
    NSMutableArray *queue = [self.queuedURLs mutableCopy]; NSString *next = queue.firstObject; [queue removeObjectAtIndex:0];
    self.queuedURLs = queue; [NSUserDefaults.standardUserDefaults setObject:queue forKey:queueKey];
    [self start:next];
}
- (void)saveError:(NSString *)reason row:(NSDictionary *)row {
    if (!row[@"spotify"]) return;
    NSMutableDictionary *errors = [self.importErrors mutableCopy] ?: [NSMutableDictionary dictionary];
    errors[row[@"spotify"]] = reason.length > 512 ? [reason substringToIndex:512] : (reason ?: @"Téléchargement impossible. Tu peux ajouter une autre source.");
    self.importErrors = errors;
    [NSUserDefaults.standardUserDefaults setObject:errors forKey:@"spotifyglass.automaticDownloads.errors"];
}
- (void)setRow:(NSDictionary *)row inJob:(NSDictionary *)job {
    if (!job || !row) return;
    NSMutableDictionary *next = [job mutableCopy];
    NSMutableArray *rows = [job[@"items"] mutableCopy];
    NSUInteger index = [row[@"position"] unsignedIntegerValue];
    if (!index || index > rows.count || ![rows[index - 1][@"spotify"] isEqual:row[@"spotify"]]) return;
    rows[index - 1] = [row copy]; next[@"items"] = [rows copy]; [self saveJob:next];
    [self update:nil];
}
- (NSDictionary *)resolve:(NSDictionary *)row source:(NSURL *)source generation:(NSUInteger)generation error:(NSString **)reason {
    if (generation != self.generation) return nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    __block NSString *failure = nil;
    SGNativeAudioRequest *token = [SGNativeAudioResolver resolveTrack:row sourceURL:source completion:^(NSDictionary *resolved, NSError *error) {
        result = resolved; failure = error.localizedDescription;
        dispatch_semaphore_signal(done);
    }];
    self.resolverToken = token;
    if (generation != self.generation) [token cancel];
    long timeout = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
    self.resolverToken = nil;
    if (timeout) { [token cancel]; if (reason) *reason = @"La recherche a pris trop de temps. Tu peux réessayer ou ajouter une source."; return nil; }
    if (generation != self.generation) return nil;
    if (!result && reason) *reason = failure ?: @"Aucune source suffisamment fiable trouvée. Ajoute un fichier ou un lien.";
    return result;
}
- (void)startDevice:(NSString *)url {
    self.busy = YES; self.activeCollection = url; self.pending = nil;
    self.devicePendingURL = url;
    [NSUserDefaults.standardUserDefaults setObject:url forKey:@"spotifyglass.automaticDownloads.pendingDevice"];
    NSUInteger generation = ++self.generation; [self beginBackgroundAllowance];
    [self update:@"Ouverture de la sélection sur cet iPhone…"];
    NSDictionary *existing = [self merged:self.history[url]];
    NSArray *registered = self.registeredTracks[url];
    NSMutableDictionary *errors = [self.collectionErrors mutableCopy]; [errors removeObjectForKey:url]; self.collectionErrors = errors;
    dispatch_async(self.worker, ^{
        NSURL *metadata = SGNativeMetadataURL(url);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:metadata];
        [request setValue:@"fr,en;q=0.8" forHTTPHeaderField:@"Accept-Language"];
        NSURL *file = [self fetch:request limit:8 * 1024 * 1024 generation:generation];
        NSData *html = file ? [NSData dataWithContentsOfURL:file] : nil;
        if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        if (generation != self.generation) return;
        NSString *reason = nil;
        NSDictionary *job = SGNativeCollectionJob(html, url, &reason);
        if (registered.count) {
            NSMutableDictionary *native = [job mutableCopy] ?: [@{@"version":@2, @"id":[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString],
                @"url":url, @"name":existing[@"name"] ?: @"Playlist", @"state":@"queued", @"engine":@"device", @"message":@""} mutableCopy];
            NSMutableDictionary *known = [NSMutableDictionary dictionary];
            for (NSDictionary *row in job[@"items"]) known[row[@"spotify"]] = row;
            NSMutableArray *rows = [NSMutableArray array];
            for (NSString *track in registered) {
                NSMutableDictionary *row = [known[track] mutableCopy] ?: [@{@"spotify":track, @"title":@"Morceau", @"artist":@"", @"state":@"waiting"} mutableCopy];
                row[@"position"] = @(rows.count + 1); [rows addObject:row];
            }
            native[@"items"] = rows; native[@"completeMetadata"] = @YES;
            native[@"scope"] = @"Liste transmise par Spotify lors de la demande."; job = native;
        }
        if ((!job || (!registered.count && ![job[@"completeMetadata"] boolValue] && [existing[@"items"] count] > [job[@"items"] count])) && [existing[@"items"] count]) {
            NSMutableDictionary *cached = [existing mutableCopy]; cached[@"engine"] = @"device"; job = cached;
        }
        if (!job) {
            NSMutableDictionary *failures = [self.collectionErrors mutableCopy]; failures[url] = reason ?: @"Connexion indisponible."; self.collectionErrors = failures;
            [self finish:reason ?: @"Connexion indisponible. Réessaie avec du réseau." generation:generation]; return;
        }
        [self saveJob:job];
        self.devicePendingURL = nil; [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.automaticDownloads.pendingDevice"];
        [self followDevice:self.job generation:generation];
    });
}
- (void)repairRow:(NSDictionary *)row selection:(NSDictionary *)selection source:(NSURL *)source {
    if (self.busy || !row || !selection) return;
    self.busy = YES; self.userPaused = NO; self.activeCollection = selection[@"url"];
    NSUInteger generation = ++self.generation; [self beginBackgroundAllowance];
    dispatch_async(self.worker, ^{
        [self saveJob:selection];
        [self runDeviceRow:row selection:self.job source:source generation:generation];
        if (generation != self.generation) return;
        NSUInteger ready = 0; for (NSDictionary *item in self.job[@"items"]) ready += onPhone(item);
        NSMutableDictionary *done = [self.job mutableCopy];
        done[@"state"] = ready == [done[@"items"] count] && ([done[@"completeMetadata"] boolValue] || ![done[@"engine"] isEqual:@"device"]) ? @"complete" : @"partial"; [self saveJob:done];
        [self finish:onPhone(self.localRows[row[@"spotify"]]) ? @"Morceau enregistré sur l'iPhone." : self.importErrors[row[@"spotify"]] generation:generation];
    });
}
- (void)runDeviceRow:(NSDictionary *)input selection:(NSDictionary *)selection source:(NSURL *)source generation:(NSUInteger)generation {
    NSMutableDictionary *row = [input mutableCopy];
    self.activeSpotify = row[@"spotify"]; self.transferProgress = 0;
    row[@"state"] = @"running"; [row removeObjectForKey:@"errorMessage"];
    [self setRow:row inJob:selection];
    [self update:[@"Recherche : " stringByAppendingString:row[@"expectedTitle"] ?: row[@"title"]]];
    NSString *reason = nil;
    // Fetch full artist names and cover for each track; playlist rows alone do not include covers.
    if (!row[@"coverURL"] || ![row[@"expectedArtists"] count]) {
        NSURL *file = [self fetch:[NSURLRequest requestWithURL:SGNativeMetadataURL(row[@"spotify"])] limit:2 * 1024 * 1024 generation:generation];
        NSData *html = file ? [NSData dataWithContentsOfURL:file] : nil;
        if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        NSDictionary *entity = SGNativeMetadataEntity(html, row[@"spotify"]);
        NSDictionary *details = entity ? SGNativeTrackMetadata(entity, [row[@"position"] unsignedIntegerValue]) : nil;
        if (details) { [row addEntriesFromDictionary:details]; row[@"state"] = @"running"; [self setRow:row inJob:self.job]; }
    }
    if (generation != self.generation) return;
    NSDictionary *resolved = [self resolve:row source:source generation:generation error:&reason];
    if (generation != self.generation) return;
    NSURL *audio = SGAutomaticAudioSource(resolved[@"url"]);
    if (resolved && audio) {
        for (NSString *key in @[@"sourceURL", @"sourceKind", @"sourceID"]) if (resolved[key]) row[key] = resolved[key];
        [self update:[@"Téléchargement : " stringByAppendingString:row[@"expectedTitle"] ?: row[@"title"]]];
        NSDictionary *space = [NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
        if (space[NSFileSystemFreeSize] && [space[NSFileSystemFreeSize] unsignedLongLongValue] < 120 * 1024 * 1024) {
            reason = @"Espace insuffisant sur l'iPhone. Libère au moins 120 Mo et réessaie.";
        } else {
            NSData *coverData = nil;
            NSURL *cover = SGAutomaticAudioSource(row[@"coverURL"]);
            if (cover) {
                NSURL *imageFile = [self fetch:[NSURLRequest requestWithURL:cover] limit:8 * 1024 * 1024 generation:generation];
                coverData = imageFile ? [NSData dataWithContentsOfURL:imageFile] : nil;
                if (imageFile) [NSFileManager.defaultManager removeItemAtURL:imageFile error:nil];
                UIImage *image = coverData ? [UIImage imageWithData:coverData] : nil;
                if (image && image.size.width <= 4096 && image.size.height <= 4096) [self.covers setObject:image forKey:row[@"spotify"]];
                else coverData = nil;
            }
            self.preparingAudio = YES;
            NSURL *file = [self fetch:[NSURLRequest requestWithURL:audio] limit:100 * 1024 * 1024 generation:generation];
            self.preparingAudio = NO;
            if (generation != self.generation) { if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil]; return; }
            NSMutableDictionary *request = [row mutableCopy]; if (coverData) request[@"artworkData"] = coverData;
            [self update:[@"Vérification : " stringByAppendingString:row[@"expectedTitle"] ?: row[@"title"]]];
            NSDictionary *installed = file ? SGAutomaticInstallAudioCancellable(file, request, ^BOOL{ return generation != self.generation; }, &reason) : nil;
            if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
            if (installed) {
                markVerified(installed); [self remember:installed];
            }
            if (generation != self.generation) return;
            if (installed) {
                [self setRow:installed inJob:self.job];
                self.activeSpotify = nil; self.transferProgress = 0; return;
            }
            if (!reason) reason = @"Le fichier audio n'a pas pu être récupéré. Réessaie ou choisis une autre source.";
        }
    }
    row[@"state"] = @"error"; row[@"errorMessage"] = reason ?: @"Aucune source fiable disponible.";
    [self saveError:row[@"errorMessage"] row:row]; [self setRow:row inJob:self.job];
    self.activeSpotify = nil; self.transferProgress = 0;
}
- (void)followDevice:(NSDictionary *)initial generation:(NSUInteger)generation {
    NSMutableDictionary *running = [[self merged:initial] mutableCopy]; running[@"state"] = @"running"; running[@"engine"] = @"device";
    [self saveJob:running];
    NSUInteger count = [running[@"items"] count];
    for (NSUInteger i = 0; i < count; i++) {
        if (generation != self.generation) return;
        NSDictionary *job = [self merged:self.job]; NSDictionary *row = job[@"items"][i];
        if (verifyRow(row)) { [self remember:row]; continue; }
        [self runDeviceRow:row selection:job source:nil generation:generation];
    }
    if (generation != self.generation) return;
    NSMutableDictionary *done = [[self merged:self.job] mutableCopy];
    NSUInteger ready = 0; for (NSDictionary *row in done[@"items"]) ready += onPhone(row);
    BOOL complete = ready == count && [done[@"completeMetadata"] boolValue];
    done[@"state"] = complete ? @"complete" : ready ? @"partial" : @"error";
    done[@"message"] = [NSString stringWithFormat:@"%lu/%lu sur l'iPhone%@", (unsigned long)ready, (unsigned long)count,
        complete ? @" · prêt hors ligne" : ready == count ? @" · titres accessibles enregistrés ; liste possiblement incomplète" : @" · touche une flèche rouge pour compléter"];
    [self saveJob:done]; [self finish:done[@"message"] generation:generation];
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
            [NSUserDefaults.standardUserDefaults setObject:@"pc" forKey:modeKey];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SGAutomaticDownloadsEnabled"];
            [self update:@"PC connecté. La flèche d’une playlist peut lancer sa préparation."];
            if (self.pending) [self submitPending];
        });
    });
}
- (void)start:(NSString *)url {
    NSString *canonical = SGAutomaticSpotifyURL(url);
    if (!canonical) return;
    if (self.busy) {
        if (![canonical isEqual:self.activeCollection] && ![self.queuedURLs containsObject:canonical]) {
            if (self.queuedURLs.count >= 10) { [self update:@"Dix sélections sont déjà en attente."]; return; }
            self.queuedURLs = [self.queuedURLs arrayByAddingObject:canonical];
            [NSUserDefaults.standardUserDefaults setObject:self.queuedURLs forKey:queueKey];
        }
        [self update:@"Sélection ajoutée à la file. Le téléchargement en cours continue."]; return;
    }
    self.userPaused = NO;
    if (![[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"]) { [self startDevice:canonical]; return; }
    self.pending = @{@"url":canonical, @"request_id":NSUUID.UUID.UUIDString};
    if (!self.root) { [self update:@"Connecte le PC ci-dessus : la sélection sera ensuite envoyée automatiquement."]; return; }
    [self submitPending];
}
- (void)submitPending {
    if (self.busy || !self.pending || !self.root) return;
    self.busy = YES; NSUInteger generation = ++self.generation;
    self.activeCollection = self.pending[@"url"]; [self beginBackgroundAllowance];
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
    if (verifyRow(row)) return YES;
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
    if (imported) markVerified(row);
    [fm removeItemAtURL:file error:nil];
    return imported;
}
- (void)follow:(NSDictionary *)initial root:(NSURL *)root generation:(NSUInteger)generation {
    NSDictionary *job = initial;
    NSMutableSet *checked = [NSMutableSet set];
    while (generation == self.generation) {
        job = [self merged:job];
        [self saveJob:job];
        for (NSDictionary *row in job[@"items"]) {
            if (generation != self.generation) return;
            if (![row[@"state"] isEqual:@"ready"] || [checked containsObject:row[@"id"]]) continue;
            self.activeSpotify = row[@"spotify"];
            [self update:[@"Enregistrement sur l’iPhone : " stringByAppendingString:row[@"title"]]];
            if (![self importRow:row root:root generation:generation]) {
                if (generation == self.generation) {
                    NSMutableDictionary *errors = [self.importErrors mutableCopy] ?: [NSMutableDictionary dictionary];
                    errors[row[@"spotify"]] = @"Transfert échoué · toucher pour réessayer ou ajouter un fichier";
                    self.importErrors = errors;
                    [NSUserDefaults.standardUserDefaults setObject:errors forKey:@"spotifyglass.automaticDownloads.errors"];
                }
                if (generation != self.generation) return;
                [checked addObject:row[@"id"]]; self.activeSpotify = nil; continue;
            }
            [checked addObject:row[@"id"]];
            [self remember:row];
            self.activeSpotify = nil;
        }
        NSUInteger local = 0, failures = 0;
        for (NSDictionary *row in job[@"items"]) {
            BOOL exists = onPhone(row); local += exists;
            failures += !exists && ([row[@"state"] isEqual:@"error"] || self.importErrors[row[@"spotify"]] != nil);
        }
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
- (void)importAudio:(NSURL *)source row:(NSDictionary *)row selection:(NSDictionary *)selection {
    if (self.busy) { tell(@"Arrête le transfert en cours avant d'ajouter un fichier."); return; }
    if (!source.isFileURL && !SGAutomaticAudioSource(source.absoluteString)) return;
    self.busy = YES; self.activeSpotify = row[@"spotify"];
    self.activeCollection = selection[@"url"]; self.userPaused = NO; [self beginBackgroundAllowance];
    NSUInteger generation = ++self.generation;
    [self update:@"Récupération du fichier audio sur l'iPhone…"];
    dispatch_async(self.worker, ^{
        NSURL *staging = nil;
        NSString *reason = @"Le fichier n'a pas pu être récupéré. Vérifie le lien, la connexion et l'accès au fichier.";
        if (source.isFileURL) {
            BOOL scoped = [source startAccessingSecurityScopedResource];
            NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *copy = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"sg-source-%@.%@", NSUUID.UUID.UUIDString, source.pathExtension]];
            __block BOOL copied = NO;
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            [coordinator coordinateReadingItemAtURL:source options:0 error:nil byAccessor:^(NSURL *readURL) {
                NSNumber *size = nil; [readURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                if (size.unsignedLongLongValue >= 1024 && size.unsignedLongLongValue <= 100 * 1024 * 1024)
                    copied = [NSFileManager.defaultManager copyItemAtURL:readURL toURL:copy error:nil];
            }];
            if (scoped) [source stopAccessingSecurityScopedResource];
            if (copied) staging = copy;
        } else {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:source];
            [request setValue:@"audio/mpeg, audio/mp4, application/octet-stream;q=0.8" forHTTPHeaderField:@"Accept"];
            staging = [self fetch:request limit:100 * 1024 * 1024 generation:generation];
        }
        if (generation != self.generation) {
            if (staging) [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            return;
        }
        NSDictionary *installed = staging ? SGAutomaticInstallAudioCancellable(staging, row, ^BOOL{ return generation != self.generation; }, &reason) : nil;
        if (staging) [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        if (installed) { markVerified(installed); [self remember:installed]; }
        if (generation != self.generation) return;
        if (installed) {
            [self saveJob:selection];
        } else {
            NSMutableDictionary *errors = [self.importErrors mutableCopy] ?: [NSMutableDictionary dictionary];
            errors[row[@"spotify"]] = reason;
            self.importErrors = errors;
            [NSUserDefaults.standardUserDefaults setObject:errors forKey:@"spotifyglass.automaticDownloads.errors"];
        }
        [self finish:installed ? @"Fichier enregistré sur l'iPhone. La flèche verte confirme la copie locale." : reason generation:generation];
    });
}
- (void)resume {
    if (self.busy) return;
    self.userPaused = NO;
    if (self.pending) { [self submitPending]; return; }
    if (self.devicePendingURL) { [self startDevice:self.devicePendingURL]; return; }
    if ([self.job[@"engine"] isEqual:@"device"]) {
        self.busy = YES; self.activeCollection = self.job[@"url"];
        NSUInteger generation = ++self.generation; NSDictionary *job = self.job; [self beginBackgroundAllowance];
        dispatch_async(self.worker, ^{ [self followDevice:job generation:generation]; }); return;
    }
    if (!self.job && self.queuedURLs.count) { [self advanceQueue]; return; }
    if (!self.job || !self.root) { [self update:@"Connecte le PC puis utilise une flèche de téléchargement."]; return; }
    self.busy = YES; NSUInteger generation = ++self.generation;
    self.activeCollection = self.job[@"url"]; [self beginBackgroundAllowance];
    NSDictionary *job = self.job; NSURL *root = self.root;
    dispatch_async(self.worker, ^{ [self follow:job root:root generation:generation]; });
}
- (void)pause {
    self.userPaused = YES;
    if (!self.busy) return;
    NSUInteger generation = ++self.generation;
    [self.active cancel];
    [(SGNativeAudioRequest *)self.resolverToken cancel];
    [self update:@"Arrêt du transfert iPhone…"];
    dispatch_async(self.worker, ^{
        if ([self.job[@"engine"] isEqual:@"device"] && [self.job[@"url"] isEqual:self.activeCollection]) {
            NSMutableDictionary *paused = [self.job mutableCopy]; paused[@"state"] = @"interrupted"; [self saveJob:paused];
        }
        [self finish:@"En pause. Les fichiers terminés sont conservés ; Reprendre continue les titres restants." generation:generation];
    });
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

@interface SGAutomaticDownloadsPage : SGPage <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIView *note;
@property (nonatomic, copy) NSArray *historyURLs;
@property (nonatomic, copy) NSDictionary *displayJob;
@property (nonatomic, copy) NSDictionary *displayHistory;
@property (nonatomic, copy) NSDictionary *pickedRow;
@property (nonatomic, copy) NSDictionary *pickedSelection;
- (void)chooseMode:(UITableViewCell *)cell;
@end
@implementation SGAutomaticDownloadsPage
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Téléchargements automatiques"; return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.note = SGNote(@"La flèche d'une playlist lance la recherche sur cet iPhone. Vert : fichier vérifié et enregistré. Rouge : touche le titre pour réessayer, choisir un fichier ou coller un lien. Garde Spotify ouvert pendant la préparation. Les morceaux disponibles dépendent des sources trouvées.");
    self.tableView.tableHeaderView = self.note;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh:) name:changed object:SGAutomaticDownloads.shared];
    [self refresh:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh:(NSNotification *)note {
    // A coherent main-thread snapshot prevents row counts changing underneath table callbacks.
    self.displayJob = [SGAutomaticDownloads.shared merged:SGAutomaticDownloads.shared.job];
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
    cell.accessoryView = nil;
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    if (path.section == 0) {
        BOOL phone = ![[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"];
        NSArray *titles = @[phone ? @"Cet iPhone · autonome" : @"PC associé", @"Ajouter un lien Spotify", engine.busy ? @"Mettre en pause" : @"Reprendre", @"Réessayer les titres manquants", @"État"];
        NSString *detail = path.row == 4 ? engine.message : path.row == 0 ? @"Choisir le mode de préparation" : nil;
        if (path.row == 4 && engine.queuedURLs.count) detail = [detail stringByAppendingFormat:@"\n%lu sélection(s) en attente.", (unsigned long)engine.queuedURLs.count];
        SGFillCell(cell, titles[path.row], detail, nil, nil);
    } else if (path.section == 1) {
        NSDictionary *row = self.displayJob[@"items"][path.row];
        BOOL active = engine.busy && ([row[@"spotify"] isEqual:engine.activeSpotify] ||
            ([engine.job[@"id"] isEqual:self.displayJob[@"id"]] && [row[@"state"] isEqual:@"running"]));
        NSString *error = engine.importErrors[row[@"spotify"]];
        NSString *state = SGAutomaticRowState(row, onPhone(row), active, error.length > 0);
        BOOL ready = [state isEqual:@"ready"], failed = [state isEqual:@"error"], running = [state isEqual:@"running"];
        NSString *status = ready ? @"Sur l'iPhone · toucher pour lire" : failed ? (error ?: @"Échec · toucher pour ajouter une source") :
            running ? @"En cours…" : @"En attente · toucher pour ajouter un fichier";
        SGFillCell(cell, row[@"title"], [NSString stringWithFormat:@"%@ · %@", row[@"artist"], status], nil, ready ? @"arrow.down.circle.fill" : @"arrow.down.circle");
        UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
        content.imageProperties.tintColor = ready ? SGGreen() : failed ? SGRed() : SGGrey();
        cell.contentConfiguration = content;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", row[@"title"], status];
        if (running) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating]; cell.accessoryView = spinner;
        }
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
        if ([engine.job[@"id"] isEqual:self.displayJob[@"id"]]) {
            NSDictionary *row = self.displayJob[@"items"][path.row];
            if (onPhone(row)) [engine play:path.row];
            else [self repair:row selection:self.displayJob cell:[table cellForRowAtIndexPath:path]];
        }
        else [self refresh:nil];
        return;
    }
    if (path.section == 2) {
        if (engine.busy) { tell(@"Arrête d’abord le transfert iPhone pour changer de sélection."); return; }
        [engine selectJob:self.displayHistory[self.historyURLs[path.row]]]; [self refresh:nil]; return;
    }
    if (path.row == 2) { if (engine.busy) [engine pause]; else [engine resume]; return; }
    if (path.row == 3) { if (engine.job && !engine.busy) [engine resume]; return; }
    if (path.row > 1 || engine.busy) return;
    if (path.row == 0) { [self chooseMode:[table cellForRowAtIndexPath:path]]; return; }
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
- (void)chooseMode:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Préparer les morceaux" message:@"Le mode iPhone fonctionne sans PC. Le réseau mobile peut être utilisé." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cet iPhone · sans PC" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setObject:@"device" forKey:modeKey]; [self refresh:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Utiliser le PC associé" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Connecter le PC" message:@"Colle le lien d'association fourni par le PC." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.keyboardType = UIKeyboardTypeURL; field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.text = [NSUserDefaults.standardUserDefaults stringForKey:pairKey];
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weak = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Connecter" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [SGAutomaticDownloads.shared connect:weak.textFields.firstObject.text ?: @""]; }]];
        [self presentViewController:alert animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)repair:(NSDictionary *)row selection:(NSDictionary *)selection cell:(UITableViewCell *)cell {
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    if (engine.busy) { tell(@"Arrête d'abord le transfert en cours. Les fichiers déjà enregistrés seront conservés."); return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row[@"title"]
        message:@"Ajoute le fichier correspondant à ce morceau. La flèche passera au vert après vérification et enregistrement."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choisir un fichier audio" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.pickedRow = row; self.pickedSelection = selection;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
        picker.allowsMultipleSelection = NO; picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Coller un lien audio ou YouTube" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Lien du fichier audio"
            message:@"Lien direct vers un MP3/M4A, ou lien d'une vidéo YouTube / YouTube Music correspondant au morceau. Le titre, l'artiste et la durée seront vérifiés. Le réseau mobile peut être utilisé."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.keyboardType = UIKeyboardTypeURL; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo; field.placeholder = @"https://…/morceau.mp3";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weak = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Importer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *text = [weak.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURL *candidate = [NSURL URLWithString:text];
            BOOL youtube = [candidate.scheme.lowercaseString isEqual:@"https"] && !candidate.user && !candidate.password &&
                [@[@"youtube.com", @"www.youtube.com", @"music.youtube.com", @"youtu.be"] containsObject:candidate.host.lowercaseString];
            NSURL *url = SGAutomaticAudioSource(text);
            if (youtube) [engine repairRow:row selection:selection source:candidate];
            else if (url) [engine importAudio:url row:row selection:selection];
            else [engine update:@"Lien invalide : utilise l'adresse HTTPS du fichier audio, sans identifiants de connexion."];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rechercher à nouveau sur l'iPhone" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [engine repairRow:row selection:selection source:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSDictionary *row = self.pickedRow, *selection = self.pickedSelection;
    self.pickedRow = nil; self.pickedSelection = nil;
    if (urls.count == 1 && row && selection) [SGAutomaticDownloads.shared importAudio:urls.firstObject row:row selection:selection];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.pickedRow = nil; self.pickedSelection = nil;
}
@end

UIViewController *SGAutomaticDownloadsPageCreate(void) { return [SGAutomaticDownloadsPage new]; }
void SGAutomaticDownloadObservePlayer(id player) { observedPlayer = player; }
NSDictionary *SGAutomaticDownloadedRow(id entity) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    NSDictionary *row = url ? SGAutomaticDownloads.shared.localRows[url] : nil;
    return onPhone(row) ? row : nil;
}
NSArray<NSDictionary *> *SGAutomaticDownloadedRows(id entity) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    if (!url) return @[];
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    NSDictionary *history = engine.history, *locals = engine.localRows;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *item in history[url][@"items"]) {
        NSDictionary *row = locals[item[@"spotify"]];
        if (!onPhone(row)) continue;
        NSMutableDictionary *copy = [row mutableCopy]; copy[@"position"] = item[@"position"]; [rows addObject:[copy copy]];
    }
    return [rows copy];
}
void SGAutomaticDownloadRegisterTracks(id entity, NSArray *tracks) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    if (!url || ![url containsString:@"/playlist/"] || ![tracks isKindOfClass:NSArray.class] || !tracks.count || tracks.count > 500) return;
    NSMutableArray *canonical = [NSMutableArray array];
    for (id value in tracks) {
        NSString *track = SGAutomaticSpotifyURL(value);
        if (!track || ![track containsString:@"/track/"]) return;
        [canonical addObject:track];
    }
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    @synchronized (engine) {
        NSMutableDictionary *registered = [engine.registeredTracks mutableCopy]; registered[url] = [canonical copy]; engine.registeredTracks = registered;
    }
}
NSDictionary *SGAutomaticDownloadStatus(id entity) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    if (!url) return @{@"state":@"idle", @"completed":@0, @"total":@0, @"progress":@0};
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    NSDictionary *job = engine.history[url], *locals = engine.localRows, *errors = engine.importErrors;
    NSArray *items = job[@"items"];
    if ([url containsString:@"/track/"] && !items.count) items = @[@{@"spotify":url}];
    NSUInteger total = items.count, ready = 0, failed = 0;
    NSDictionary *cached = [statusCounts() objectForKey:url];
    CFTimeInterval now = CACurrentMediaTime();
    if (cached && now - [cached[@"time"] doubleValue] < 1.0 && cached[@"job"] == job && cached[@"locals"] == locals && cached[@"errors"] == errors) {
        ready = [cached[@"ready"] unsignedIntegerValue]; failed = [cached[@"failed"] unsignedIntegerValue];
    } else {
        for (NSDictionary *row in items) {
            BOOL exists = onPhone(locals[row[@"spotify"]]) || onPhone(row);
            ready += exists; failed += !exists && ([row[@"state"] isEqual:@"error"] || errors[row[@"spotify"]] != nil);
        }
        [statusCounts() setObject:@{@"time":@(now), @"job":job ?: NSNull.null, @"locals":locals, @"errors":errors, @"ready":@(ready), @"failed":@(failed)} forKey:url];
    }
    BOOL running = engine.busy && ([url isEqual:engine.activeCollection] || [url isEqual:engine.activeSpotify]);
    BOOL queued = [engine.queuedURLs containsObject:url];
    BOOL complete = ![job[@"engine"] isEqual:@"device"] || [job[@"completeMetadata"] boolValue];
    NSString *state = running || queued ? @"running" : total && ready == total ? (complete ? @"ready" : @"incomplete") :
        [job[@"state"] isEqual:@"interrupted"] ? @"paused" : ready ? @"partial" : failed || engine.collectionErrors[url] ? @"error" : @"idle";
    double progress = total ? ((double)ready + (running ? engine.transferProgress : 0)) / total : 0;
    return @{@"state":state, @"completed":@(ready), @"total":@(total), @"progress":@(MIN(1, MAX(0, progress))),
        @"completeMetadata":job[@"completeMetadata"] ?: @NO};
}
BOOL SGAutomaticDownloadEntity(id entity, UIView *source) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    if (!url || ![NSUserDefaults.standardUserDefaults boolForKey:@"SGAutomaticDownloadsEnabled"]) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *saved = engine.history[url];
        BOOL current = engine.busy && [url isEqual:engine.activeCollection];
        if (!saved && !current && ![engine.queuedURLs containsObject:url]) {
            [engine start:url]; [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred]; return;
        }
        UIViewController *owner = SGTopController();
        if (!owner || owner.presentedViewController) return;
        NSDictionary *status = SGAutomaticDownloadStatus(url);
        NSString *message = [NSString stringWithFormat:@"%@/%@ morceaux sur l'iPhone", status[@"completed"], status[@"total"]];
        if (saved && ![saved[@"completeMetadata"] boolValue] && [saved[@"engine"] isEqual:@"device"])
            message = [message stringByAppendingString:@"\nLa page publique peut ne fournir qu'une partie de la playlist."];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:saved[@"name"] ?: @"Téléchargement" message:message preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Voir les téléchargements" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (!engine.busy && saved) [engine selectJob:saved];
            if (![owner isKindOfClass:SGAutomaticDownloadsPage.class]) SGShowPage(owner, SGAutomaticDownloadsPageCreate());
        }]];
        if (current) [sheet addAction:[UIAlertAction actionWithTitle:@"Mettre en pause" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine pause]; }]];
        else if (![status[@"state"] isEqual:@"ready"]) [sheet addAction:[UIAlertAction actionWithTitle:engine.busy ? @"Ajouter à la file" : @"Reprendre les titres manquants" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (engine.busy || !saved) [engine start:url];
            else { [engine selectJob:saved]; [engine resume]; }
        }]];
        if ([status[@"completed"] unsignedIntegerValue] && !engine.busy) [sheet addAction:[UIAlertAction actionWithTitle:@"Écouter les copies hors ligne" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [engine selectJob:saved];
            NSArray *rows = engine.job[@"items"]; for (NSUInteger i = 0; i < rows.count; i++) if (onPhone(rows[i])) { [engine play:i]; break; }
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = source ?: owner.view;
        sheet.popoverPresentationController.sourceRect = source ? source.bounds : owner.view.bounds;
        [owner presentViewController:sheet animated:YES completion:nil];
    });
    return YES;
}
