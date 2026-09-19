// One durable queue for on-device preparation, optional PC preparation, and manual repairs.
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "AutomaticDownloadTransfer.h"
#import "AutomaticDownloadState.h"
#import "AudioVariantsPage.h"
#import "AutomaticPCDiscovery.h"
#import "AutomaticAudioFile.h"
#import "AutomaticAudioLibrary.h"
#import "AutomaticLocalFilesPage.h"
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
static NSString *const intentKey = @"spotifyglass.automaticDownloads.intent.v1";
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
    return SGAutomaticLibraryFile(row);
}
static BOOL onPhone(NSDictionary *row) {
    NSURL *file = rowFile(row);
    if (!file || !row[@"id"]) return NO;
    NSString *key = [row[@"id"] stringByAppendingPathExtension:row[@"extension"] ?: @"mp3"];
    NSDictionary *stamp = [verifiedFiles() objectForKey:key];
    if (!stamp) return NO;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    return [attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] isEqual:row[@"bytes"]] &&
        [attrs[NSFileModificationDate] isEqual:stamp[NSFileModificationDate]] && [attrs[NSFileSystemFileNumber] isEqual:stamp[NSFileSystemFileNumber]];
}
static void markVerified(NSDictionary *row) {
    NSURL *file = rowFile(row);
    NSDictionary *attrs = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    if (row[@"id"] && [attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] isEqual:row[@"bytes"]])
        [verifiedFiles() setObject:attrs forKey:[row[@"id"] stringByAppendingPathExtension:row[@"extension"] ?: @"mp3"]];
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

@interface SGAutomaticDownloads : NSObject <NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate, UIDocumentInteractionControllerDelegate>
@property (atomic) BOOL busy;
@property (atomic) BOOL clearing;
@property (atomic) NSUInteger generation;
@property (atomic) NSUInteger verificationRevision;
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
@property (atomic) BOOL waitingForPC;
@property (atomic) BOOL pcIdentityVerified;
@property (atomic) BOOL transportUnavailable;
@property (atomic) BOOL interrupted;
@property (atomic, copy) NSString *resumeURL;
@property (nonatomic) NSUInteger reconnectAttempt;
@property (nonatomic) NSUInteger reconnectTicket;
@property (nonatomic) NSUInteger reconnectPendingTicket;
@property (atomic, copy) NSDictionary *alternativeJob;
@property (atomic) BOOL alternativeAcceptRequested;
@property (atomic, copy) NSDictionary *candidateRow;
@property (atomic, strong) NSURL *candidateFile;
@property (nonatomic, strong) UIDocumentInteractionController *candidatePreview;
@property (atomic, strong) id resolverToken;
@property (nonatomic) CFTimeInterval lastProgressNotification;
@property (nonatomic) BOOL notificationPending;
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
- (void)clearUnfinished;
- (void)deleteLocalFile:(NSDictionary *)item completion:(void (^)(BOOL, NSString *))completion;
- (void)removeQueued:(NSString *)url;
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
- (void)persistIntent;
- (void)waitForPC:(NSUInteger)generation;
- (void)scheduleReconnect;
- (void)attemptReconnect;
- (void)refreshSelection:(NSString *)url;
- (void)startAlternative:(NSDictionary *)row;
- (void)followAlternative:(NSDictionary *)job root:(NSURL *)root generation:(NSUInteger)generation;
- (void)showAlternative;
- (void)acceptAlternative;
- (void)cancelAlternative;
- (void)showPCStorage;
- (void)cleanupPCStorage;
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
        NSDictionary *storedIntent = [NSUserDefaults.standardUserDefaults dictionaryForKey:intentKey];
        NSDictionary *intent = SGAutomaticDownloadIntent(storedIntent);
        if (storedIntent) engine.queuedURLs = intent[@"queue"];
        engine.pending = intent[@"pending"];
        engine.alternativeAcceptRequested = [intent[@"acceptRequested"] boolValue];
        engine.userPaused = [intent[@"paused"] boolValue];
        engine.resumeURL = intent[@"activeURL"] ?: engine.pending[@"url"];
        engine.registeredTracks = intent[@"tracks"] ?: @{};
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
        engine.job = [engine merged:valid[engine.resumeURL ?: last ?: @""]];
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
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!engine.userPaused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                    (engine.pending || engine.resumeURL || engine.devicePendingURL || engine.queuedURLs.count)) [engine resume];
            });
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (!engine.busy) engine.pcIdentityVerified = NO;
            if (!engine.busy) dispatch_async(engine.worker, ^{
                for (NSDictionary *row in engine.localRows.allValues) verifyRow(row);
                engine.verificationRevision += 1;
                [engine update:engine.message];
            });
            if (!engine.busy && !engine.userPaused && (!engine.candidateFile || engine.alternativeAcceptRequested)) {
                if (engine.waitingForPC) [engine scheduleReconnect];
                else if (engine.pending || engine.resumeURL || engine.devicePendingURL || engine.queuedURLs.count) [engine resume];
            }
        }];
    });
    return engine;
}
- (void)persistIntent {
    void (^save)(void) = ^{
        NSMutableDictionary *intent = [@{@"version":@1, @"queue":self.queuedURLs ?: @[], @"paused":@(self.userPaused), @"tracks":self.registeredTracks ?: @{}} mutableCopy];
        if (self.pending) intent[@"pending"] = self.pending;
        if (self.alternativeAcceptRequested) intent[@"acceptRequested"] = @YES;
        if (self.resumeURL) intent[@"activeURL"] = self.resumeURL;
        [NSUserDefaults.standardUserDefaults setObject:SGAutomaticDownloadIntent(intent) forKey:intentKey];
    };
    if (NSThread.isMainThread) save(); else dispatch_sync(dispatch_get_main_queue(), save);
}
- (void)waitForPC:(NSUInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.generation != generation) return;
        self.waitingForPC = YES; self.busy = NO; self.activeSpotify = nil; self.preparingAudio = NO; self.transferProgress = 0;
        self.pcIdentityVerified = NO;
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask]; self.backgroundTask = UIBackgroundTaskInvalid;
        }
        [self persistIntent]; [self update:@"En attente du PC. La demande est conservée ; la connexion reprendra automatiquement quand Spotify est ouvert."];
        [self scheduleReconnect];
    });
}
- (void)scheduleReconnect {
    if (self.busy || self.userPaused || !self.waitingForPC || !self.root ||
        ![[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"] ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (self.reconnectPendingTicket && self.reconnectPendingTicket == self.reconnectTicket) return;
    NSUInteger ticket = ++self.reconnectTicket;
    self.reconnectPendingTicket = ticket;
    NSTimeInterval delay = SGAutomaticDownloadRetryDelay(self.reconnectAttempt);
    self.reconnectAttempt = MIN((NSUInteger)5, self.reconnectAttempt + 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.reconnectPendingTicket == ticket) self.reconnectPendingTicket = 0;
        if (ticket != self.reconnectTicket || self.busy || self.userPaused || !self.waitingForPC ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        [self attemptReconnect];
    });
}
- (void)attemptReconnect {
    if (self.busy || self.userPaused || !self.root) return;
    self.busy = YES; self.waitingForPC = YES; NSUInteger generation = ++self.generation;
    // Discovery challenges the saved address too. Never send the private URL to
    // a reused DHCP address until the companion has proved its identity.
    SGAutomaticDiscoverPC(self.root, ^(NSURL *found) {
        if (generation != self.generation) return;
        self.busy = NO;
        if (!found) { [self update:@"En attente du PC. La demande reste enregistrée."]; [self scheduleReconnect]; return; }
        self.root = found; self.pcIdentityVerified = YES;
        [NSUserDefaults.standardUserDefaults setObject:found.absoluteString forKey:pairKey];
        self.waitingForPC = NO; self.reconnectAttempt = 0;
        if (!self.userPaused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self resume];
        else if (!self.userPaused) self.waitingForPC = YES;
    });
}
- (void)update:(NSString *)message {
    if (message) self.message = message;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.notificationPending) return;
        self.notificationPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            self.notificationPending = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:changed object:self];
        });
    });
}
- (void)selectJob:(NSDictionary *)job {
    if (self.busy || !job || self.pending || self.waitingForPC) return;
    self.devicePendingURL = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.automaticDownloads.pendingDevice"];
    self.job = [self merged:job];
    [NSUserDefaults.standardUserDefaults setObject:job[@"url"] forKey:@"spotifyglass.automaticDownloads.last"];
    if (self.userPaused) { self.resumeURL = job[@"url"]; [self persistIntent]; }
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
    if (!job) return nil;
    NSMutableDictionary *available = [NSMutableDictionary dictionary];
    NSMutableSet *checked = [NSMutableSet set];
    NSDictionary *locals = self.localRows;
    for (NSDictionary *row in job[@"items"]) {
        NSString *key = row[@"spotify"];
        if (!key || [checked containsObject:key]) continue;
        [checked addObject:key];
        if (onPhone(locals[key])) available[key] = locals[key];
    }
    return SGAutomaticMergeLocalRows(job, available);
}
- (void)remember:(NSDictionary *)row {
    if (!onPhone(row)) return;
    NSMutableDictionary *record = [row mutableCopy]; record[@"position"] = @1;
    NSMutableDictionary *local = [self.localRows mutableCopy] ?: [NSMutableDictionary dictionary];
    local[SGAutomaticSpotifyURL(row[@"spotify"])] = record; self.localRows = local;
    self.verificationRevision += 1;
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
    self.transportUnavailable = NO;
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *staging = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"sg-auto-%@.mp3", NSUUID.UUID.UUIDString]];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL copied = NO;
    NSURLSession *session = [request.URL.scheme.lowercaseString isEqual:@"https"] ? self.audioSession : self.session;
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request completionHandler:^(NSURL *file, NSURLResponse *response, NSError *error) {
        NSNumber *size = nil; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        self.transportUnavailable = (error && [error.domain isEqual:NSURLErrorDomain] && error.code != NSURLErrorCancelled) ||
            code == 502 || code == 503 || code == 504;
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
        self.busy = NO; self.clearing = NO; self.activeSpotify = nil; self.activeCollection = nil;
        self.preparingAudio = NO; self.transferProgress = 0; self.resolverToken = nil;
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask]; self.backgroundTask = UIBackgroundTaskInvalid;
        }
        if (!self.interrupted && !self.waitingForPC && !self.pending) self.resumeURL = nil;
        [self persistIntent]; [self update:message];
        if (self.waitingForPC && !self.userPaused) [self scheduleReconnect];
        else if (!self.userPaused && !self.interrupted && !self.pending) [self advanceQueue];
    });
}
- (void)beginBackgroundAllowance {
    if (self.backgroundTask != UIBackgroundTaskInvalid) return;
    __weak typeof(self) weak = self;
    self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Spoti téléchargement" expirationHandler:^{
        UIBackgroundTaskIdentifier task = weak.backgroundTask;
        weak.backgroundTask = UIBackgroundTaskInvalid;
        if (task != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:task];
        BOOL explicitlyPaused = weak.userPaused;
        [weak pause];
        weak.userPaused = explicitlyPaused; [weak persistIntent];
        [weak update:@"Interrompu par iOS. La préparation reprendra au retour dans Spotify."];
    }];
}
- (void)advanceQueue {
    if (self.busy || self.userPaused || self.pending || self.waitingForPC || !self.queuedURLs.count ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSMutableArray *queue = [self.queuedURLs mutableCopy]; NSString *next = queue.firstObject; [queue removeObjectAtIndex:0];
    self.queuedURLs = queue;
    // start: saves the popped head as the first durable request together with the
    // remaining queue. A crash before that save leaves the old head in the queue.
    [self start:next];
}
- (void)removeQueued:(NSString *)url {
    if (self.clearing || ![self.queuedURLs containsObject:url]) return;
    NSMutableArray *queue = [self.queuedURLs mutableCopy]; [queue removeObject:url];
    self.queuedURLs = queue;
    [NSUserDefaults.standardUserDefaults setObject:queue forKey:queueKey];
    [self persistIntent];
    [self update:@"Sélection retirée de la file. Tes fichiers sont conservés."];
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
    self.resumeURL = url; self.waitingForPC = NO; self.interrupted = NO; [self persistIntent];
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
            NSString *failure = reason ?: @"Connexion indisponible. Réessaie avec du réseau.";
            [self finish:failure generation:generation];
            return;
        }
        [self saveJob:job];
        self.devicePendingURL = nil; [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.automaticDownloads.pendingDevice"];
        [self followDevice:self.job generation:generation];
    });
}
- (void)repairRow:(NSDictionary *)row selection:(NSDictionary *)selection source:(NSURL *)source {
    if ([self.pending[@"kind"] isEqual:@"alternative"]) { tell(@"Choisis ou annule d’abord la version proposée. La copie actuelle est conservée."); return; }
    if (self.busy || !row || !selection) return;
    self.busy = YES; self.userPaused = NO; self.activeCollection = selection[@"url"];
    NSUInteger generation = ++self.generation; [self beginBackgroundAllowance];
    dispatch_async(self.worker, ^{
        [self saveJob:selection];
        [self runDeviceRow:row selection:self.job source:source generation:generation];
        if (generation != self.generation) return;
        NSUInteger ready = 0; for (NSDictionary *item in self.job[@"items"]) ready += onPhone(item);
        NSMutableDictionary *done = [self.job mutableCopy];
        BOOL complete = done[@"completeMetadata"] ? [done[@"completeMetadata"] boolValue] : ![done[@"engine"] isEqual:@"device"];
        done[@"state"] = ready == [done[@"items"] count] && complete ? @"complete" : @"partial"; [self saveJob:done];
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
    for (NSNumber *position in SGAutomaticPreparationOrder(running[@"items"])) {
        NSUInteger i = position.unsignedIntegerValue;
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
            if (!valid) {
                if ([root.absoluteString isEqual:self.root.absoluteString] && (self.pending || self.resumeURL)) [self waitForPC:generation];
                else { [self update:@"PC inaccessible. Vérifie le même Wi-Fi et l’autorisation Réseau local de Spotify."]; [self scheduleReconnect]; }
                return;
            }
            self.root = root;
            self.pcIdentityVerified = YES;
            [NSUserDefaults.standardUserDefaults setObject:root.absoluteString forKey:pairKey];
            [NSUserDefaults.standardUserDefaults setObject:@"pc" forKey:modeKey];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SGAutomaticDownloadsEnabled"];
            [self update:@"PC connecté. La flèche d’une playlist peut lancer sa préparation."];
            self.waitingForPC = NO; self.reconnectAttempt = 0;
            if (!self.userPaused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                (self.pending || self.resumeURL || self.queuedURLs.count)) [self resume];
        });
    });
}
- (void)start:(NSString *)url {
    if (self.clearing) { [self update:@"Nettoyage en cours. Les fichiers téléchargés sont conservés."]; return; }
    NSString *canonical = SGAutomaticSpotifyURL(url);
    if (!canonical) return;
    if (self.busy || self.pending || self.waitingForPC) {
        if ([canonical isEqual:self.pending[@"url"]] || [canonical isEqual:self.resumeURL]) {
            if (!self.busy) [self resume]; else [self update:@"Cette sélection est déjà en cours."];
            return;
        }
        if ([canonical isEqual:self.activeCollection]) { [self update:@"Cette sélection est déjà en cours."]; return; }
        if ([self.queuedURLs containsObject:canonical]) { [self update:@"Cette sélection est déjà dans la file d'attente."]; return; }
        if (![canonical isEqual:self.activeCollection] && ![self.queuedURLs containsObject:canonical]) {
            if (self.queuedURLs.count >= 10) { [self update:@"Dix sélections sont déjà en attente."]; return; }
            self.queuedURLs = [self.queuedURLs arrayByAddingObject:canonical];
            [NSUserDefaults.standardUserDefaults setObject:self.queuedURLs forKey:queueKey];
            [self persistIntent];
        }
        [self update:@"Sélection ajoutée à la file. Le téléchargement en cours continue."]; return;
    }
    self.userPaused = NO; self.interrupted = NO; self.reconnectTicket++;
    if (![[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"]) { self.pending = nil; [self startDevice:canonical]; return; }
    self.devicePendingURL = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.automaticDownloads.pendingDevice"];
    self.pending = SGAutomaticDownloadRequest(canonical, self.registeredTracks[canonical], NO);
    self.resumeURL = canonical;
    [self persistIntent]; // before the first POST, including its idempotency key
    if (!self.root) { [self update:@"Associe le PC dans Options et nettoyage : la sélection sera ensuite envoyée automatiquement."]; return; }
    [self submitPending];
}
- (void)submitPending {
    if (self.busy || self.userPaused || !self.pending || !self.root) return;
    if (!self.pcIdentityVerified) { self.waitingForPC = YES; [self attemptReconnect]; return; }
    self.interrupted = NO; self.waitingForPC = NO;
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
            if (self.transportUnavailable) { [self waitForPC:generation]; return; }
            [self finish:@"Le PC n’a pas confirmé la demande. Reprendre réessaiera sans créer de doublon." generation:generation]; return;
        }
        if (generation != self.generation) return;
        if ([pending[@"kind"] isEqual:@"alternative"]) {
            if (![job[@"kind"] isEqual:@"alternative"]) { [self finish:@"Le PC n’a pas confirmé la recherche d’une autre version." generation:generation]; return; }
            [self followAlternative:job root:root generation:generation]; return;
        }
        [self saveJob:job];
        dispatch_sync(dispatch_get_main_queue(), ^{ if (generation == self.generation) { self.pending = nil; [self persistIntent]; } });
        if (generation != self.generation) return;
        [self follow:job root:root generation:generation];
    });
}
- (void)refreshSelection:(NSString *)url {
    if (self.busy || self.pending || self.waitingForPC) { tell(@"Termine ou mets la demande actuelle en pause avant d’actualiser cette sélection."); return; }
    NSString *canonical = SGAutomaticSpotifyURL(url); if (!canonical) return;
    if (![[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"]) {
        tell(@"L’actualisation complète utilise le PC associé. Choisis le mode PC dans les options."); return;
    }
    self.userPaused = NO; self.interrupted = NO; self.resumeURL = canonical;
    NSMutableDictionary *registered = [self.registeredTracks mutableCopy]; [registered removeObjectForKey:canonical]; self.registeredTracks = registered;
    self.pending = SGAutomaticDownloadRequest(canonical, nil, YES);
    [self persistIntent];
    [self update:@"Nouvelle lecture de la sélection. Les fichiers déjà vérifiés seront réutilisés."];
    if (self.root) [self submitPending]; else [self update:@"Associe le PC pour mettre à jour la sélection. Les fichiers actuels sont conservés."];
}
- (void)startAlternative:(NSDictionary *)row {
    if (self.busy || self.pending || self.waitingForPC) { tell(@"Termine la demande actuelle ou annule-la avant de chercher une autre version."); return; }
    if (!self.root || ![[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"]) { tell(@"Le choix d’une autre version utilise le PC associé. Choisis le PC dans les options."); return; }
    NSString *url = SGAutomaticSpotifyURL(row[@"spotify"]); if (![url containsString:@"/track/"]) return;
    NSMutableDictionary *request = [SGAutomaticDownloadRequest(url, nil, NO) mutableCopy];
    request[@"kind"] = @"alternative";
    NSString *source = row[@"source"];
    if (!source && [row[@"sourceID"] isKindOfClass:NSString.class] && [row[@"sourceID"] length] == 11 &&
        [row[@"sourceID"] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet]].location == NSNotFound)
        source = [@"https://music.youtube.com/watch?v=" stringByAppendingString:row[@"sourceID"]];
    NSDictionary *validated = SGAutomaticDownloadIntent(@{@"version":@1, @"pending":@{@"url":url,
        @"request_id":request[@"request_id"], @"kind":@"alternative", @"avoid_sources":source ? @[source] : @[]}});
    request = [validated[@"pending"] mutableCopy];
    if (!request) { tell(@"La source actuelle n’a pas pu être identifiée correctement."); return; }
    self.pending = request; self.resumeURL = url; self.userPaused = NO; self.interrupted = NO; self.alternativeAcceptRequested = NO;
    [self persistIntent]; [self update:@"Recherche d’une autre version. La copie actuelle reste disponible."];
    [self submitPending];
}
- (void)followAlternative:(NSDictionary *)initial root:(NSURL *)root generation:(NSUInteger)generation {
    NSDictionary *job = initial;
    while (generation == self.generation) {
        self.alternativeJob = job;
        NSDictionary *row = [job[@"items"] firstObject];
        if ([job[@"state"] isEqual:@"complete"] && [job[@"items"] count] == 1 &&
            [row[@"state"] isEqual:@"ready"] && [row[@"spotify"] isEqual:self.pending[@"url"]]) {
            self.activeSpotify = row[@"spotify"]; self.preparingAudio = YES;
            NSString *reason = nil;
            NSURL *file = SGAutomaticTransferFile(root, row, ^BOOL { return generation != self.generation; },
                ^(NSURLSessionTask *task) { self.active = task; }, ^(NSUInteger received, NSUInteger total) {
                    if (generation == self.generation && total) { self.transferProgress = MIN(0.98, (double)received / total); [self update:nil]; }
                }, &reason);
            self.active = nil; self.preparingAudio = NO;
            if (generation != self.generation) { if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil]; return; }
            if (!file) {
                NSURLRequest *probe = [NSURLRequest requestWithURL:[root URLByAppendingPathComponent:@"hello"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
                [self json:probe generation:generation];
                if (self.transportUnavailable) { [self waitForPC:generation]; return; }
                [self finish:reason ?: @"La nouvelle version n’a pas été reçue. La copie actuelle est conservée." generation:generation]; return;
            }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
            double seconds = CMTimeGetSeconds(asset.duration);
            BOOL valid = asset.playable && [asset tracksWithMediaType:AVMediaTypeAudio].count && isfinite(seconds) && fabs(seconds - [row[@"seconds"] doubleValue]) < 2;
#pragma clang diagnostic pop
            if (!valid || generation != self.generation) {
                [NSFileManager.defaultManager removeItemAtURL:file error:nil];
                if (generation == self.generation) [self finish:@"Cette version n’est pas lisible. La copie actuelle est conservée." generation:generation];
                return;
            }
            self.candidateRow = row; self.candidateFile = file;
            [self finish:@"Une nouvelle version est prête à écouter. La version actuelle n’a pas été remplacée." generation:generation];
            dispatch_async(dispatch_get_main_queue(), ^{ if (generation == self.generation) {
                if (self.alternativeAcceptRequested) [self acceptAlternative]; else [self showAlternative];
            } });
            return;
        }
        if ([@[@"complete", @"partial", @"error", @"interrupted"] containsObject:job[@"state"]]) {
            NSString *reason = row[@"errorMessage"] ?: job[@"message"];
            dispatch_sync(dispatch_get_main_queue(), ^{ if (generation == self.generation) { self.pending = nil; self.resumeURL = nil; self.alternativeJob = nil; [self persistIntent]; } });
            [self finish:[NSString stringWithFormat:@"Aucune autre version prête. %@ La copie actuelle est conservée.", reason ?: @""] generation:generation]; return;
        }
        [self update:@"Recherche d’une autre version sur le PC. Tu pourras l’écouter avant de choisir."];
        [NSThread sleepForTimeInterval:2];
        if (generation != self.generation) return;
        NSURL *url = [[root URLByAppendingPathComponent:@"jobs"] URLByAppendingPathComponent:job[@"id"]];
        NSDictionary *next = SGAutomaticJob([self json:[NSURLRequest requestWithURL:url] generation:generation]);
        if (!next || ![next[@"id"] isEqual:job[@"id"]] || ![next[@"kind"] isEqual:@"alternative"] || ![next[@"url"] isEqual:job[@"url"]]) {
            if (self.transportUnavailable) [self waitForPC:generation];
            else [self finish:@"Le suivi de la version est interrompu. La copie actuelle est conservée." generation:generation];
            return;
        }
        job = next;
    }
}
- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller { return SGTopController(); }
- (void)documentInteractionControllerDidEndPreview:(UIDocumentInteractionController *)controller {
    self.candidatePreview = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self showAlternative]; });
}
- (void)showAlternative {
    UIViewController *owner = SGTopController();
    if (!self.candidateFile || !self.candidateRow || self.busy || !owner || owner.presentedViewController) return;
    if (self.alternativeAcceptRequested) {
        UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:@"Confirmation en attente"
            message:@"Ton choix a été enregistré. La connexion au PC permettra de terminer la confirmation et d'associer cette version à tes sélections locales."
            preferredStyle:UIAlertControllerStyleAlert];
        [confirmation addAction:[UIAlertAction actionWithTitle:@"Terminer la confirmation" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self resume]; }]];
        [confirmation addAction:[UIAlertAction actionWithTitle:@"Mettre en pause" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [self pause]; }]];
        [owner presentViewController:confirmation animated:YES completion:nil]; return;
    }
    NSString *message = [NSString stringWithFormat:@"Écoute cette version avant de choisir. La copie actuelle reste disponible.\n\nAlbum : %@\nLe repère « Version » distingue cette copie de l’ancienne.", self.candidateRow[@"album"] ?: @""];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:self.candidateRow[@"title"] message:message
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Écouter cette version" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.candidatePreview = [UIDocumentInteractionController interactionControllerWithURL:self.candidateFile];
        self.candidatePreview.delegate = self;
        if (![self.candidatePreview presentPreviewAnimated:YES]) { self.candidatePreview = nil; tell(@"L’aperçu audio n’a pas pu s’ouvrir. La version actuelle est conservée."); }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Utiliser cette version" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Utiliser cette version ?"
            message:@"Les sélections locales utiliseront cette version du morceau. L’ancien fichier sera conservé ; tu pourras le supprimer séparément dans Gérer les fichiers locaux."
            preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { [self showAlternative]; }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Confirmer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self acceptAlternative]; }]];
        [owner presentViewController:confirm animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Garder la version actuelle" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self cancelAlternative]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choisir plus tard" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = owner.view; sheet.popoverPresentationController.sourceRect = owner.view.bounds;
    [owner presentViewController:sheet animated:YES completion:nil];
}
- (void)cancelAlternative {
    if (self.busy || self.alternativeAcceptRequested || ![self.pending[@"kind"] isEqual:@"alternative"]) return;
    NSURL *file = self.candidateFile; self.candidateFile = nil; self.candidateRow = nil; self.alternativeJob = nil;
    self.pending = nil; self.resumeURL = nil; self.waitingForPC = NO; self.reconnectTicket++; self.alternativeAcceptRequested = NO;
    [self persistIntent];
    if (file) dispatch_async(self.worker, ^{ [NSFileManager.defaultManager removeItemAtURL:file error:nil]; });
    [self update:@"Version actuelle conservée."]; if (!self.userPaused) [self advanceQueue];
}
- (void)acceptAlternative {
    if (self.busy || !self.candidateFile || !self.candidateRow || !self.alternativeJob || !self.root) return;
    self.alternativeAcceptRequested = YES; self.userPaused = NO; [self persistIntent];
    if (!self.pcIdentityVerified || self.waitingForPC) {
        self.userPaused = NO; self.waitingForPC = YES; [self persistIntent]; [self attemptReconnect]; return;
    }
    self.busy = YES; self.interrupted = NO; self.userPaused = NO;
    NSDictionary *candidate = self.candidateRow, *job = self.alternativeJob;
    NSURL *file = self.candidateFile, *root = self.root;
    NSUInteger generation = ++self.generation; [self beginBackgroundAllowance];
    [self update:@"Vérification et confirmation de la nouvelle version."];
    dispatch_async(self.worker, ^{
        if (![fileHash(file) isEqual:candidate[@"id"]]) { [self finish:@"Le fichier de préécoute a changé. La version actuelle est conservée." generation:generation]; return; }
        NSURL *directory = downloadsDirectory(); NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil];
        NSNumber *link = nil, *dir = nil;
        [directory getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil]; [directory getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        if (!dir.boolValue || link.boolValue || ![[directory URLByResolvingSymlinksInPath].URLByDeletingLastPathComponent.path isEqual:[directory.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath].path]) {
            [self finish:@"Le dossier local n’est pas disponible. La version actuelle est conservée." generation:generation]; return;
        }
        NSURL *target = [directory URLByAppendingPathComponent:[candidate[@"id"] stringByAppendingPathExtension:candidate[@"extension"] ?: @"mp3"]];
        NSDictionary *attrs = [fm attributesOfItemAtPath:target.path error:nil];
        BOOL installed = [attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] isEqual:candidate[@"bytes"]] && [fileHash(target) isEqual:candidate[@"id"]];
        if (!installed && generation == self.generation) installed = [fm copyItemAtURL:file toURL:target error:nil];
        if (!installed || generation != self.generation) { if (generation == self.generation) [self finish:@"La nouvelle version n’a pas pu être enregistrée. La copie actuelle reste active." generation:generation]; return; }
        [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:target.path error:nil];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[root URLByAppendingPathComponent:@"accept-version"]];
        request.HTTPMethod = @"POST"; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"job_id":job[@"id"], @"sha256":candidate[@"id"]} options:0 error:nil];
        NSData *response = [self json:request generation:generation];
        id accepted = response ? [NSJSONSerialization JSONObjectWithData:response options:0 error:nil] : nil;
        if (generation != self.generation) return;
        if (![accepted isKindOfClass:NSDictionary.class] || ![accepted[@"accepted"] isEqual:@YES] ||
            ![accepted[@"sha256"] isEqual:candidate[@"id"]] || ![SGAutomaticSpotifyURL(accepted[@"spotify"]) isEqual:candidate[@"spotify"]]) {
            if (self.transportUnavailable) { [self waitForPC:generation]; return; }
            [self finish:@"Le PC n’a pas confirmé le choix. La copie actuelle reste active ; tu peux confirmer à nouveau sans créer de doublon." generation:generation]; return;
        }
        SGAutomaticLibraryRegister(candidate, target); markVerified(candidate);
        NSDictionary *replacement = onPhone(candidate) ? SGAutomaticDownloadReplaceVersion(self.history, self.localRows, candidate) : nil;
        if (!replacement) { [self finish:@"La nouvelle version n’a pas pu être associée. La copie actuelle reste disponible." generation:generation]; return; }
        __block BOOL committed = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.localRows = replacement[@"locals"]; self.history = replacement[@"history"];
            if (self.job[@"url"]) self.job = self.history[self.job[@"url"]] ?: self.job;
            NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
            // The local association is authoritative on restart. Save it before
            // history, which may still contain the previous hash after a crash.
            [prefs setObject:self.localRows forKey:@"spotifyglass.automaticDownloads.localRows"];
            [prefs setObject:self.history forKey:@"spotifyglass.automaticDownloads.history"];
            [self remember:candidate]; [self.covers removeObjectForKey:candidate[@"spotify"]];
            self.candidateFile = nil; self.candidateRow = nil; self.alternativeJob = nil; self.pending = nil; self.resumeURL = nil;
            self.alternativeAcceptRequested = NO; committed = YES;
            [self persistIntent];
        });
        if (!committed) return;
        [fm removeItemAtURL:file error:nil];
        [self finish:@"Nouvelle version choisie pour tes sélections locales. L’ancien fichier est conservé." generation:generation];
    });
}
- (void)showPCStorage {
    if (self.busy || !self.root) { tell(self.root ? @"Mets le transfert en pause pour consulter le stockage du PC." : @"Associe d’abord le PC dans les options."); return; }
    self.busy = YES; self.reconnectTicket++; NSUInteger generation = ++self.generation;
    if (!self.pcIdentityVerified) {
        SGAutomaticDiscoverPC(self.root, ^(NSURL *found) {
            if (generation != self.generation) return;
            self.busy = NO;
            if (!found) { [self update:@"Le PC n’est pas disponible. Le stockage de l’iPhone est inchangé."]; [self scheduleReconnect]; return; }
            self.root = found; self.pcIdentityVerified = YES;
            [NSUserDefaults.standardUserDefaults setObject:found.absoluteString forKey:pairKey];
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self showPCStorage];
        });
        return;
    }
    NSURL *root = self.root;
    [self update:@"Lecture du stockage du PC."];
    dispatch_async(self.worker, ^{
        NSData *data = [self json:[NSURLRequest requestWithURL:[root URLByAppendingPathComponent:@"storage"]] generation:generation];
        id storage = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL valid = [storage isKindOfClass:NSDictionary.class] && [storage[@"version"] isEqual:@1];
        for (NSString *key in @[@"audio_bytes", @"audio_files", @"reclaimable_bytes", @"reclaimable_files", @"active_jobs"])
            valid = valid && [storage[key] isKindOfClass:NSNumber.class] && isfinite([storage[key] doubleValue]) && [storage[key] doubleValue] >= 0 && [storage[key] doubleValue] <= 1e16;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.busy = NO; [self update:nil];
            if (!valid) { tell(@"Le stockage n’a pas pu être lu. Vérifie le PC et la version du compagnon."); [self scheduleReconnect]; return; }
            UIViewController *owner = SGTopController(); if (!owner || owner.presentedViewController) { [self scheduleReconnect]; return; }
            NSString *message = [NSString stringWithFormat:@"%@ fichiers audio · %@\n\nEspace récupérable : %@\n\nLe nettoyage conserve les fichiers liés aux sélections terminées. Aucun fichier de l’iPhone n’est supprimé.", storage[@"audio_files"],
                [NSByteCountFormatter stringFromByteCount:[storage[@"audio_bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile],
                [NSByteCountFormatter stringFromByteCount:[storage[@"reclaimable_bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Stockage du PC" message:message preferredStyle:UIAlertControllerStyleAlert];
            if ([storage[@"cleanup_available"] isEqual:@YES] && [storage[@"reclaimable_files"] unsignedIntegerValue])
                [sheet addAction:[UIAlertAction actionWithTitle:@"Libérer les fichiers inutilisés" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self cleanupPCStorage]; }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [self scheduleReconnect]; }]];
            [owner presentViewController:sheet animated:YES completion:nil];
        });
    });
}
- (void)cleanupPCStorage {
    if (self.busy || !self.root || !self.pcIdentityVerified) return;
    self.busy = YES; NSUInteger generation = ++self.generation; NSURL *root = self.root;
    [self update:@"Nettoyage des fichiers inutilisés sur le PC."];
    dispatch_async(self.worker, ^{
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[root URLByAppendingPathComponent:@"storage/cleanup"]];
        request.HTTPMethod = @"POST"; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *data = [self json:request generation:generation];
        id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL valid = [result isKindOfClass:NSDictionary.class] && [result[@"removed_bytes"] isKindOfClass:NSNumber.class] &&
            isfinite([result[@"removed_bytes"] doubleValue]) && [result[@"removed_bytes"] doubleValue] >= 0 && [result[@"removed_bytes"] doubleValue] <= 1e16;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.busy = NO;
            NSString *message = valid ? [NSString stringWithFormat:@"%@ libérés sur le PC. Les fichiers de l’iPhone sont conservés.",
                [NSByteCountFormatter stringFromByteCount:[result[@"removed_bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]] : @"Le PC n’a pas confirmé le nettoyage. Aucun fichier de l’iPhone n’a été supprimé.";
            [self update:message]; tell(message); [self scheduleReconnect];
        });
    });
}
- (NSDictionary *)importRow:(NSDictionary *)row root:(NSURL *)root generation:(NSUInteger)generation failure:(NSString **)failure {
    if (verifyRow(row)) return row;
    BOOL (^cancelled)(void) = ^BOOL { return generation != self.generation; };
    NSDictionary *existing = SGAutomaticLibraryReuse(nil, row, cancelled);
    if (existing) { markVerified(existing); return existing; }
    if (cancelled()) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = downloadsDirectory();
    [fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil];
    NSNumber *dir = nil, *link = nil;
    [directory getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
    [directory getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    if (!dir.boolValue || link.boolValue || ![[directory URLByResolvingSymlinksInPath].URLByDeletingLastPathComponent.path
        isEqual:[directory.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath].path]) return nil;
    // New writes always use our own canonical destination, never an old mapping
    // to a manually imported file which the user may since have replaced.
    NSURL *target = [directory URLByAppendingPathComponent:[row[@"id"] stringByAppendingPathExtension:row[@"extension"] ?: @"mp3"]];
    self.preparingAudio = YES; self.transferProgress = 0;
    NSURL *file = SGAutomaticTransferFile(root, row, cancelled, ^(NSURLSessionTask *task) {
        self.active = task;
    }, ^(NSUInteger received, NSUInteger total) {
        if (cancelled() || !total) return;
        self.transferProgress = MIN(0.98, (double)received / (double)total);
        CFTimeInterval now = CACurrentMediaTime();
        if (now - self.lastProgressNotification > 0.4) { self.lastProgressNotification = now; [self update:nil]; }
    }, failure);
    self.active = nil;
    self.preparingAudio = NO; self.transferProgress = 0;
    if (!file) return nil;
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
    if (valid && !cancelled()) {
        existing = SGAutomaticLibraryReuse(file, row, cancelled);
        if (existing) {
            markVerified(existing);
            [fm removeItemAtURL:file error:nil];
            return existing;
        }
    }
    BOOL imported = valid && generation == self.generation && [fm moveItemAtURL:file toURL:target error:nil];
    if (imported) [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:target.path error:nil];
    if (imported) { SGAutomaticLibraryRegister(row, target); markVerified(row); }
    [fm removeItemAtURL:file error:nil];
    return imported ? row : nil;
}
- (void)follow:(NSDictionary *)initial root:(NSURL *)root generation:(NSUInteger)generation {
    NSDictionary *job = initial;
    NSMutableSet *checked = [NSMutableSet set];
    while (generation == self.generation) {
        job = [self merged:job];
        [self saveJob:job];
        for (NSDictionary *row in job[@"items"]) {
            if (generation != self.generation) return;
            NSString *attempt = [NSString stringWithFormat:@"%@|%@", row[@"spotify"], row[@"id"]];
            if (![row[@"state"] isEqual:@"ready"] || [checked containsObject:attempt]) continue;
            self.activeSpotify = row[@"spotify"];
            [self update:[@"Enregistrement sur l’iPhone : " stringByAppendingString:row[@"title"]]];
            NSString *transferFailure = nil;
            NSDictionary *installed = [self importRow:row root:root generation:generation failure:&transferFailure];
            if (!installed) {
                if (generation == self.generation) {
                    NSURLRequest *probe = [NSURLRequest requestWithURL:[root URLByAppendingPathComponent:@"hello"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
                    [self json:probe generation:generation];
                    if (self.transportUnavailable) { [self waitForPC:generation]; return; }
                }
                if (generation == self.generation) {
                    NSMutableDictionary *errors = [self.importErrors mutableCopy] ?: [NSMutableDictionary dictionary];
                    errors[row[@"spotify"]] = transferFailure ?: @"Transfert échoué · toucher pour réessayer ou ajouter un fichier";
                    self.importErrors = errors;
                    [NSUserDefaults.standardUserDefaults setObject:errors forKey:@"spotifyglass.automaticDownloads.errors"];
                }
                if (generation != self.generation) return;
                [checked addObject:attempt]; self.activeSpotify = nil; continue;
            }
            [checked addObject:attempt];
            [self remember:installed];
            self.activeSpotify = nil;
        }
        job = [self merged:job];
        [self saveJob:job];
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
            if (self.transportUnavailable) { [self waitForPC:generation]; return; }
            self.interrupted = YES;
            [self finish:@"Suivi interrompu. Le PC peut continuer ; touche Reprendre pour récupérer les fichiers." generation:generation]; return;
        }
        job = next;
    }
}
- (void)importAudio:(NSURL *)source row:(NSDictionary *)row selection:(NSDictionary *)selection {
    if ([self.pending[@"kind"] isEqual:@"alternative"]) { tell(@"Choisis ou annule d’abord la version proposée. La copie actuelle est conservée."); return; }
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
    self.userPaused = NO; self.interrupted = NO; self.reconnectTicket++;
    [self persistIntent];
    if (self.candidateFile) {
        if (!self.pcIdentityVerified || self.waitingForPC) { self.waitingForPC = YES; [self attemptReconnect]; }
        else if (self.alternativeAcceptRequested) [self acceptAlternative]; else [self showAlternative];
        return;
    }
    BOOL pc = [[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"];
    NSString *selection = self.pending[@"url"] ?: self.devicePendingURL ?: self.resumeURL ?: self.job[@"url"];
    BOOL switchMode = (self.pending && !pc) || (self.devicePendingURL && pc) ||
        (!self.pending && !self.devicePendingURL && self.job && pc == [self.job[@"engine"] isEqual:@"device"]);
    if (selection && switchMode) {
        if ([self.pending[@"kind"] isEqual:@"alternative"]) { tell(@"Le choix d’une autre version utilise le PC. Annule cette recherche avant de changer de mode."); return; }
        self.pending = nil; self.waitingForPC = NO; [self persistIntent]; [self start:selection]; return;
    }
    if (pc && self.root && (!self.pcIdentityVerified || self.waitingForPC) && (selection || self.resumeURL || self.queuedURLs.count)) {
        self.waitingForPC = YES; [self attemptReconnect]; return;
    }
    if (self.pending) { [self submitPending]; return; }
    if (self.devicePendingURL) { [self startDevice:self.devicePendingURL]; return; }
    if (!self.resumeURL && self.queuedURLs.count) { [self advanceQueue]; return; }
    if (!self.job && self.resumeURL) { [self start:self.resumeURL]; return; }
    if ([self.job[@"engine"] isEqual:@"device"]) {
        // Cleanup retains only downloaded rows. Reload the playlist on an
        // explicit retry instead of repeatedly processing that ready subset.
        BOOL allReady = [self.job[@"items"] count] > 0;
        for (NSDictionary *row in self.job[@"items"]) allReady = allReady && onPhone(row);
        if (allReady && ![self.job[@"completeMetadata"] boolValue]) { [self startDevice:self.job[@"url"]]; return; }
        self.busy = YES; self.activeCollection = self.job[@"url"];
        NSUInteger generation = ++self.generation; NSDictionary *job = self.job; [self beginBackgroundAllowance];
        dispatch_async(self.worker, ^{ [self followDevice:job generation:generation]; }); return;
    }
    if (!self.job && self.queuedURLs.count) { [self advanceQueue]; return; }
    if (!self.job || !self.root) { [self update:@"Connecte le PC puis utilise une flèche de téléchargement."]; return; }
    BOOL needsPreparation = NO;
    for (NSDictionary *row in self.job[@"items"]) if (!onPhone(row) && ![row[@"state"] isEqual:@"ready"]) needsPreparation = YES;
    if (needsPreparation && [@[@"partial", @"error", @"complete", @"interrupted"] containsObject:self.job[@"state"]]) {
        // A completed server job cannot retry itself. A fresh request reuses
        // verified PC files and asks the worker to prepare only missing ones.
        [self start:self.job[@"url"]]; return;
    }
    self.busy = YES; NSUInteger generation = ++self.generation;
    self.activeCollection = self.job[@"url"]; self.resumeURL = self.job[@"url"]; [self persistIntent]; [self beginBackgroundAllowance];
    NSDictionary *job = self.job; NSURL *root = self.root;
    dispatch_async(self.worker, ^{ [self follow:job root:root generation:generation]; });
}
- (void)pause {
    if (self.clearing) return;
    self.userPaused = YES; self.interrupted = YES; self.reconnectTicket++;
    [self persistIntent];
    if (!self.busy) { [self update:@"En pause. La demande et les fichiers reçus sont conservés."]; return; }
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
- (void)clearUnfinished {
    if (self.clearing) return;
    if (self.alternativeAcceptRequested && [self.pending[@"kind"] isEqual:@"alternative"]) {
        tell(@"Une version a déjà été confirmée. Termine cette confirmation avec Reprendre avant de nettoyer les attentes ; tu peux la laisser en pause."); return;
    }
    // Keep the engine unavailable until the cancelled worker has drained. This
    // prevents a late resolver/import completion from restoring deleted jobs.
    self.clearing = YES; self.busy = YES; self.userPaused = YES;
    NSUInteger generation = ++self.generation;
    [self.active cancel]; [(SGNativeAudioRequest *)self.resolverToken cancel];
    NSURL *candidateFile = self.candidateFile;
    self.candidateFile = nil; self.candidateRow = nil; self.alternativeJob = nil; self.alternativeAcceptRequested = NO;
    self.queuedURLs = @[]; self.pending = nil; self.devicePendingURL = nil;
    self.resumeURL = nil; self.waitingForPC = NO; self.interrupted = YES; self.reconnectTicket++;
    [self persistIntent];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:queueKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.automaticDownloads.pendingDevice"];
    [self update:@"Nettoyage des attentes et des échecs…"];
    dispatch_async(self.worker, ^{
        if (candidateFile) [NSFileManager.defaultManager removeItemAtURL:candidateFile error:nil];
        NSMutableDictionary *available = [NSMutableDictionary dictionary];
        for (NSString *key in self.localRows) if (verifyRow(self.localRows[key])) available[key] = self.localRows[key];
        NSDictionary *history = SGAutomaticClearUnfinishedHistory(self.history, available);
        NSString *last = self.job[@"url"];
        if (!history[last ?: @""]) last = [[history.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
        self.history = history; self.job = last ? history[last] : nil;
        self.importErrors = @{}; self.collectionErrors = @{};
        [statusCounts() removeAllObjects];
        NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
        [prefs setObject:history forKey:@"spotifyglass.automaticDownloads.history"];
        [prefs removeObjectForKey:@"spotifyglass.automaticDownloads.errors"];
        if (last) [prefs setObject:last forKey:@"spotifyglass.automaticDownloads.last"];
        else [prefs removeObjectForKey:@"spotifyglass.automaticDownloads.last"];
        [self finish:@"Attentes et échecs retirés. Tes morceaux téléchargés sont conservés." generation:generation];
    });
}
- (void)deleteLocalFile:(NSDictionary *)item completion:(void (^)(BOOL, NSString *))completion {
    if (self.busy || self.clearing) { completion(NO, @"Mets les téléchargements en pause avant de supprimer un fichier."); return; }
    self.busy = YES; self.clearing = YES; self.userPaused = YES;
    self.reconnectTicket++; [self persistIntent];
    NSUInteger generation = ++self.generation;
    [self update:@"Suppression du fichier sélectionné."];
    dispatch_async(self.worker, ^{
        NSURL *documents = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByResolvingSymlinksInPath];
        NSString *relative = [item[@"path"] isKindOfClass:NSString.class] ? item[@"path"] : @"";
        NSString *selected = [documents URLByAppendingPathComponent:relative].URLByStandardizingPath.path;
        // Snapshot associations BEFORE the library removes its path mapping.
        NSMutableSet *keys = [NSMutableSet set];
        void (^collect)(NSDictionary *) = ^(NSDictionary *row) {
            if (![row[@"state"] isEqual:@"ready"] || !row[@"id"]) return;
            if ([rowFile(row).URLByResolvingSymlinksInPath.path isEqual:selected])
                [keys addObject:[row[@"id"] stringByAppendingPathExtension:row[@"extension"] ?: @"mp3"]];
        };
        for (NSDictionary *row in self.localRows.allValues) collect(row);
        for (NSDictionary *job in self.history.allValues) for (NSDictionary *row in job[@"items"]) collect(row);
        NSError *error = nil;
        BOOL removed = SGAutomaticLibraryDelete(item, &error);
        if (removed) {
            BOOL (^matches)(NSDictionary *) = ^BOOL(NSDictionary *row) {
                return row[@"id"] && [keys containsObject:[row[@"id"] stringByAppendingPathExtension:row[@"extension"] ?: @"mp3"]];
            };
            NSMutableDictionary *locals = [self.localRows mutableCopy];
            NSMutableDictionary *errors = [self.importErrors mutableCopy];
            for (NSString *identity in self.localRows) if (matches(self.localRows[identity])) {
                [locals removeObjectForKey:identity]; [errors removeObjectForKey:identity];
                [self.covers removeObjectForKey:identity];
            }
            NSMutableDictionary *history = [NSMutableDictionary dictionary];
            for (NSString *url in self.history) {
                NSMutableDictionary *job = [self.history[url] mutableCopy];
                NSMutableArray *rows = [NSMutableArray array]; BOOL affected = NO;
                for (NSDictionary *row in job[@"items"]) {
                    if (!matches(row)) { [rows addObject:row]; continue; }
                    NSMutableDictionary *copy = [row mutableCopy];
                    copy[@"state"] = @"waiting";
                    if (!copy[@"expectedSeconds"] && copy[@"seconds"]) copy[@"expectedSeconds"] = copy[@"seconds"];
                    for (NSString *key in @[@"id", @"bytes", @"progress", @"errorMessage"]) [copy removeObjectForKey:key];
                    [errors removeObjectForKey:copy[@"spotify"]];
                    [rows addObject:copy]; affected = YES;
                }
                if (affected) { job[@"items"] = rows; job[@"state"] = @"partial"; job[@"message"] = @"Un fichier a été supprimé de cet iPhone."; }
                history[url] = job;
            }
            self.localRows = locals; self.history = history; self.importErrors = errors;
            if (self.job[@"url"]) self.job = history[self.job[@"url"]] ?: self.job;
            NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
            [prefs setObject:locals forKey:@"spotifyglass.automaticDownloads.localRows"];
            [prefs setObject:history forKey:@"spotifyglass.automaticDownloads.history"];
            [prefs setObject:errors forKey:@"spotifyglass.automaticDownloads.errors"];
            for (NSString *key in keys) [verifiedFiles() removeObjectForKey:key];
            [statusCounts() removeAllObjects];
            self.verificationRevision += 1;
        }
        NSString *message = removed ? @"Fichier supprimé définitivement de cet iPhone. Si une ancienne ligne reste dans Fichiers locaux, rouvre Spotify." : error.localizedDescription ?: @"Le fichier n’a pas été supprimé. Actualise la liste puis réessaie.";
        [self finish:message generation:generation];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(removed, message); });
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

@interface SGDownloadProgressCell : UITableViewCell
@property(nonatomic, strong) UIProgressView *progress;
@end
@implementation SGDownloadProgressCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progress.progressTintColor = SGGreen(); _progress.trackTintColor = [UIColor colorWithWhite:1 alpha:0.12];
        _progress.isAccessibilityElement = NO; [self.contentView addSubview:_progress];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.progress.frame = CGRectMake(16, self.contentView.bounds.size.height - 18, MAX(0, self.contentView.bounds.size.width - 32), 3);
    [self.contentView bringSubviewToFront:self.progress];
}
@end

@interface SGAutomaticDownloadsPage : SGPage <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIView *note;
@property (nonatomic, strong) UISegmentedControl *filter;
@property (nonatomic, strong) UIView *filterHeader;
@property (nonatomic, strong) UILabel *filterTitle;
@property (nonatomic, copy) NSArray *historyURLs;
@property (nonatomic, copy) NSArray *queuedURLs;
@property (nonatomic, copy) NSArray<NSNumber *> *positions;
@property (nonatomic, copy) NSDictionary *displayJob;
@property (nonatomic, copy) NSDictionary *displayHistory;
@property (nonatomic, copy) NSDictionary *summary;
@property (nonatomic, copy) NSSet *readyURLs;
@property (nonatomic, copy) NSSet *failedURLs;
@property (nonatomic, strong) NSDictionary *rawJob;
@property (nonatomic, strong) NSDictionary *rawLocals;
@property (nonatomic, strong) NSDictionary *rawErrors;
@property (nonatomic, copy) NSDictionary *pickedRow;
@property (nonatomic, copy) NSDictionary *pickedSelection;
@property (nonatomic) CFTimeInterval lastInsetCheck;
@property (nonatomic) NSUInteger verificationRevision;
- (void)chooseMode:(UITableViewCell *)cell;
- (void)addLink;
- (void)showActions:(UITableViewCell *)cell;
- (void)fillCell:(UITableViewCell *)cell at:(NSIndexPath *)path;
@end
@implementation SGAutomaticDownloadsPage
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Téléchargements"; return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.note = SGNote(@"Garde Spotify ouvert pendant la préparation. Les fichiers terminés restent disponibles hors ligne.");
    self.tableView.tableHeaderView = self.note;
    self.filter = [[UISegmentedControl alloc] initWithItems:@[@"Tout", @"À compléter", @"Téléchargés"]];
    self.filter.selectedSegmentIndex = 0; self.filter.accessibilityLabel = @"Afficher les morceaux";
    [self.filter addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    self.filterHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 82)];
    self.filterTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 4, self.tableView.bounds.size.width - 32, 25)];
    self.filterTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.filterTitle.textColor = UIColor.whiteColor;
    self.filterTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.filter.frame = CGRectMake(16, 37, self.tableView.bounds.size.width - 32, 32);
    self.filter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.filterHeader addSubview:self.filterTitle]; [self.filterHeader addSubview:self.filter];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh:) name:changed object:SGAutomaticDownloads.shared];
    [self refresh:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh:nil]; }
- (void)filterChanged:(UISegmentedControl *)sender { [self refresh:nil]; }
- (void)refresh:(NSNotification *)note {
    if (note && !self.viewIfLoaded.window) return;
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    NSString *oldURL = self.displayJob[@"url"];
    NSArray *oldPositions = self.positions, *oldHistory = self.historyURLs, *oldQueue = self.queuedURLs;
    // Progress ticks reuse immutable snapshots and never re-scan every audio file.
    if (!self.summary || self.rawJob != engine.job || self.rawLocals != engine.localRows || self.rawErrors != engine.importErrors || self.verificationRevision != engine.verificationRevision || !note) {
        self.rawJob = engine.job; self.rawLocals = engine.localRows; self.rawErrors = engine.importErrors;
        self.verificationRevision = engine.verificationRevision;
        self.displayJob = [engine merged:engine.job];
        NSMutableSet *ready = [NSMutableSet set], *checked = [NSMutableSet set];
        for (NSDictionary *row in self.displayJob[@"items"]) {
            NSString *url = row[@"spotify"];
            if ([checked containsObject:url]) continue;
            [checked addObject:url]; if (onPhone(row)) [ready addObject:url];
        }
        self.readyURLs = ready; self.failedURLs = [NSSet setWithArray:engine.importErrors.allKeys];
    }
    self.summary = SGAutomaticDownloadSummary(self.displayJob[@"items"], self.readyURLs, self.failedURLs, engine.busy ? engine.activeSpotify : nil);
    NSMutableArray *positions = [NSMutableArray array];
    NSArray *items = self.displayJob[@"items"];
    for (NSUInteger i = 0; i < items.count; i++) {
        BOOL ready = [self.readyURLs containsObject:items[i][@"spotify"]];
        if (self.filter.selectedSegmentIndex == 0 || (self.filter.selectedSegmentIndex == 1 && !ready) || (self.filter.selectedSegmentIndex == 2 && ready)) [positions addObject:@(i)];
    }
    self.positions = positions; self.queuedURLs = engine.queuedURLs ?: @[];
    self.displayHistory = engine.history;
    NSMutableArray *history = [[engine.history.allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    [history removeObject:self.displayJob[@"url"] ?: @""]; self.historyURLs = history;
    self.filterTitle.text = self.displayJob[@"name"] ?: @"Mes morceaux";
    BOOL sameSelection = [(oldURL ?: @"") isEqual:(self.displayJob[@"url"] ?: @"")];
    BOOL structural = !sameSelection || ![oldPositions isEqual:self.positions] || ![oldHistory isEqual:self.historyURLs] || ![oldQueue isEqual:self.queuedURLs];
    if (structural) {
        CGPoint offset = self.tableView.contentOffset;
        [UIView performWithoutAnimation:^{ [self.tableView reloadData]; [self.tableView layoutIfNeeded]; }];
        if (sameSelection) {
            CGFloat minimum = -self.tableView.adjustedContentInset.top;
            CGFloat maximum = MAX(minimum, self.tableView.contentSize.height - self.tableView.bounds.size.height + self.tableView.adjustedContentInset.bottom);
            offset.y = MIN(maximum, MAX(minimum, offset.y)); [self.tableView setContentOffset:offset animated:NO];
        }
    } else {
        // Keep the scroll position, selection and gestures during transfer progress.
        for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) [self fillCell:[self.tableView cellForRowAtIndexPath:path] at:path];
    }
}
- (void)viewWillLayoutSubviews { [super viewWillLayoutSubviews]; SGFitNote(self.tableView, self.note, 10, 8); }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (CACurrentMediaTime() - self.lastInsetCheck > 0.7) { self.lastInsetCheck = CACurrentMediaTime(); SGInsetForBars(self.tableView); }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 4 : section == 1 ? MAX(1, self.positions.count) : section == 2 ? self.queuedURLs.count : self.historyURLs.count;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 2 && self.queuedURLs.count ? @"À suivre" : section == 3 && self.historyURLs.count ? @"Mes sélections" : nil;
}
- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    if (section == 1) return self.filterHeader;
    NSString *title = [self tableView:table titleForHeaderInSection:section];
    return title ? SGSectionHeader(table, title) : nil;
}
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return section == 1 ? 82 : [self tableView:table titleForHeaderInSection:section] ? SGSectionHeaderHeight : 12;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 2 && self.queuedURLs.count) return @"Glisse une sélection vers la gauche pour la retirer de la file.";
    if (section != 1 || ![self.displayJob[@"items"] count]) return nil;
    return self.displayJob[@"completeMetadata"] && ![self.displayJob[@"completeMetadata"] boolValue] ?
        @"La liste accessible peut être incomplète. Glisse un titre téléchargé vers la gauche pour changer de version." :
        @"Glisse un titre téléchargé vers la gauche pour chercher une autre version et l’écouter avant de choisir.";
}
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path { return path.section == 0 && path.row == 0 ? 142 : 70; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell;
    if (path.section == 0 && path.row == 0) cell = [table dequeueReusableCellWithIdentifier:@"download-status"] ?: [[SGDownloadProgressCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"download-status"];
    else cell = SGDequeueCell(table, @"auto-download");
    [self fillCell:cell at:path]; return cell;
}
- (void)fillCell:(UITableViewCell *)cell at:(NSIndexPath *)path {
    if (!cell) return;
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    UIActivityIndicatorView *previousSpinner = [cell.accessoryView isKindOfClass:UIActivityIndicatorView.class] ? (id)cell.accessoryView : nil;
    cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessibilityLabel = nil; cell.accessibilityHint = nil; cell.accessibilityValue = nil;
    NSUInteger total = [self.summary[@"total"] unsignedIntegerValue], ready = [self.summary[@"ready"] unsignedIntegerValue];
    NSUInteger failed = [self.summary[@"failed"] unsignedIntegerValue], processed = [self.summary[@"processed"] unsignedIntegerValue];
    if (path.section == 0) {
        if (path.row == 0) {
            BOOL opening = engine.busy && engine.activeCollection && ![self.displayJob[@"url"] isEqual:engine.activeCollection];
            NSString *title = total && !opening ? [NSString stringWithFormat:@"%lu / %lu sur l’iPhone", (unsigned long)ready, (unsigned long)total] : engine.busy ? @"Préparation en cours" : @"Prêt à télécharger";
            if (engine.waitingForPC) title = engine.userPaused ? @"En pause" : @"En attente du PC";
            else if (engine.candidateFile) title = @"Une version à écouter";
            NSString *mode = [[NSUserDefaults.standardUserDefaults stringForKey:modeKey] isEqual:@"pc"] ? @"Préparation sur le PC" : @"Préparation sur cet iPhone";
            NSString *counts = total && !opening ? [NSString stringWithFormat:@"%lu traités · %lu à vérifier", (unsigned long)processed, (unsigned long)failed] : @"Utilise la flèche d'une playlist ou ajoute un lien.";
            SGFillCell(cell, title, [NSString stringWithFormat:@"%@\n%@\n%@", mode, counts, engine.message ?: @""], nil, nil);
            UIListContentConfiguration *content = (id)cell.contentConfiguration;
            content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            content.secondaryTextProperties.numberOfLines = 4;
            content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 16, 28, 16); cell.contentConfiguration = content;
            double activeProgress = engine.busy && engine.activeSpotify ? MIN(0.98, MAX(0, engine.transferProgress)) : 0;
            SGDownloadProgressCell *status = (id)cell; status.progress.hidden = total == 0 || opening;
            [status.progress setProgress:total ? MIN(1, ((double)processed + activeProgress) / total) : 0 animated:!UIAccessibilityIsReduceMotionEnabled() && self.view.window != nil];
            status.progress.progressTintColor = failed ? UIColor.systemOrangeColor : SGGreen();
            cell.accessibilityLabel = [NSString stringWithFormat:@"%@. %@. %@", title, counts, engine.message ?: @""];
        } else if (path.row == 1) {
            BOOL allReady = total && ready == total;
            NSString *title = engine.clearing ? @"Nettoyage en cours…" : engine.busy ? @"Mettre en pause" : allReady ? @"Écouter hors ligne" : self.displayJob || engine.devicePendingURL || engine.pending || engine.queuedURLs.count ? @"Reprendre la préparation" : @"Télécharger une sélection";
            if (!engine.busy && engine.candidateFile) title = @"Écouter et choisir la version";
            else if (!engine.busy && engine.waitingForPC) title = engine.userPaused ? @"Reprendre la connexion" : @"Mettre l’attente en pause";
            SGFillCell(cell, title, engine.busy ? @"Les morceaux terminés seront conservés" : nil, SGGreen(), engine.busy ? @"pause.circle.fill" : allReady ? @"play.circle.fill" : @"arrow.down.circle.fill");
        } else if (path.row == 2) SGFillCell(cell, @"Ajouter un lien Spotify", engine.busy ? @"Ajouter une sélection à la suite" : @"Un morceau ou une playlist", nil, @"plus.circle");
        else SGFillCell(cell, @"Options et nettoyage", @"Mode PC / iPhone · réessayer · nettoyer", nil, @"slider.horizontal.3");
    } else if (path.section == 1) {
        if (!self.positions.count) {
            NSString *title = !total ? @"Aucun morceau pour le moment" : self.filter.selectedSegmentIndex == 2 ? @"Pas encore de fichier terminé" : @"Tout est disponible sur l'iPhone";
            SGFillCell(cell, title, !total ? @"Lance une playlist avec sa flèche de téléchargement." : nil, SGGrey(), @"music.note"); return;
        }
        NSDictionary *row = self.displayJob[@"items"][[self.positions[path.row] unsignedIntegerValue]];
        BOOL active = engine.busy && [row[@"spotify"] isEqual:engine.activeSpotify] && ![self.readyURLs containsObject:row[@"spotify"]];
        NSString *state = SGAutomaticRowState(row, [self.readyURLs containsObject:row[@"spotify"]], active, [self.failedURLs containsObject:row[@"spotify"]]);
        BOOL downloaded = [state isEqual:@"ready"], error = [state isEqual:@"error"];
        NSString *status = downloaded ? @"Disponible hors ligne" : error ? @"À compléter · toucher pour choisir une source" : active ? engine.preparingAudio ? [NSString stringWithFormat:@"Téléchargement · %.0f %%", engine.transferProgress * 100] : @"Recherche et préparation…" : engine.userPaused ? @"En pause" : @"En attente";
        SGFillCell(cell, row[@"title"], [NSString stringWithFormat:@"%@\n%@", row[@"artist"], status], nil, downloaded ? @"arrow.down.circle.fill" : error ? @"exclamationmark.circle" : @"clock");
        UIListContentConfiguration *content = (id)cell.contentConfiguration;
        content.imageProperties.tintColor = downloaded ? SGGreen() : error ? SGRed() : SGGrey();
        content.secondaryTextProperties.numberOfLines = 2; cell.contentConfiguration = content;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@", row[@"title"], row[@"artist"], status];
        if (active) {
            UIActivityIndicatorView *spinner = previousSpinner ?: [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating]; cell.accessoryView = spinner;
        }
    } else if (path.section == 2) {
        NSString *url = self.queuedURLs[path.row];
        SGFillCell(cell, self.displayHistory[url][@"name"] ?: @"Sélection en attente", [NSString stringWithFormat:@"Position %lu · toucher pour retirer", (unsigned long)path.row + 1], nil, @"clock");
    } else {
        NSDictionary *job = self.displayHistory[self.historyURLs[path.row]];
        SGFillCell(cell, job[@"name"], @"Ouvrir cette sélection", nil, @"music.note.list"); cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 1 && path.row < self.positions.count) {
        NSUInteger index = [self.positions[path.row] unsignedIntegerValue];
        if (index >= [self.displayJob[@"items"] count]) return nil;
        NSDictionary *row = self.displayJob[@"items"][index];
        if (!onPhone(row)) return nil;
        UIContextualAction *version = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Changer de version" handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            done(NO); [SGAutomaticDownloads.shared startAlternative:row];
        }];
        version.backgroundColor = UIColor.systemIndigoColor;
        UIContextualAction *audio = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Versions audio" handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            done(YES);
            dispatch_async(dispatch_get_main_queue(), ^{ SGShowPage(self, SGAudioVariantsPageCreate(row)); });
        }];
        audio.backgroundColor = SGGreen();
        UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[audio, version]];
        configuration.performsFirstActionWithFullSwipe = NO; return configuration;
    }
    if (path.section != 2 || path.row >= self.queuedURLs.count) return nil;
    NSString *url = self.queuedURLs[path.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Retirer" handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        [SGAutomaticDownloads.shared removeQueued:url]; done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    if (engine.clearing) return;
    if (path.section == 1) {
        if (path.row >= self.positions.count) return;
        NSUInteger index = [self.positions[path.row] unsignedIntegerValue];
        if (index >= [self.displayJob[@"items"] count]) return;
        if ([engine.job[@"id"] isEqual:self.displayJob[@"id"]] && index < [engine.job[@"items"] count] &&
            [engine.job[@"items"][index][@"spotify"] isEqual:self.displayJob[@"items"][index][@"spotify"]]) {
            NSDictionary *row = self.displayJob[@"items"][index];
            if (onPhone(row)) [engine play:index]; else [self repair:row selection:self.displayJob cell:[table cellForRowAtIndexPath:path]];
        } else [self refresh:nil];
        return;
    }
    if (path.section == 2) { if (path.row < self.queuedURLs.count) [engine removeQueued:self.queuedURLs[path.row]]; return; }
    if (path.section == 3) {
        if (path.row >= self.historyURLs.count) return;
        if (engine.busy) { tell(@"Mets la préparation en pause pour ouvrir une autre sélection."); return; }
        [engine selectJob:self.displayHistory[self.historyURLs[path.row]]]; [self refresh:nil]; return;
    }
    if (path.row == 0) return;
    if (path.row == 2) { [self addLink]; return; }
    if (path.row == 3) { [self showActions:[table cellForRowAtIndexPath:path]]; return; }
    if (engine.candidateFile && !engine.busy) { [engine resume]; return; }
    if (engine.waitingForPC && !engine.userPaused && !engine.busy) { [engine pause]; return; }
    if (engine.busy) [engine pause];
    else if ([self.summary[@"total"] unsignedIntegerValue] && [self.summary[@"ready"] isEqual:self.summary[@"total"]]) [engine play:0];
    else if (engine.job || engine.devicePendingURL || engine.pending || engine.queuedURLs.count) [engine resume];
    else [self addLink];
}
- (void)addLink {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ajouter une sélection" message:@"Colle le lien Spotify d'un morceau ou d'une playlist." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.keyboardType = UIKeyboardTypeURL; field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.placeholder = @"https://open.spotify.com/…"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = alert;
    [alert addAction:[UIAlertAction actionWithTitle:SGAutomaticDownloads.shared.busy ? @"Ajouter à la file" : @"Télécharger" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *url = SGAutomaticSpotifyURL(weak.textFields.firstObject.text);
        if (url) [SGAutomaticDownloads.shared start:url]; else [SGAutomaticDownloads.shared update:@"Lien invalide : utilise un lien de morceau ou de playlist Spotify."];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showActions:(UITableViewCell *)cell {
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Options" message:@"Le PC est conseillé pour préparer les grandes playlists. Les copies restent sur l'iPhone." preferredStyle:UIAlertControllerStyleActionSheet];
    UIAlertAction *mode = [UIAlertAction actionWithTitle:@"Choisir PC ou iPhone" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self chooseMode:cell]; }];
    mode.enabled = !engine.busy && ![engine.pending[@"kind"] isEqual:@"alternative"]; [sheet addAction:mode];
    UIAlertAction *retry = [UIAlertAction actionWithTitle:@"Réessayer les titres manquants" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine resume]; }];
    retry.enabled = !engine.busy && self.displayJob != nil; [sheet addAction:retry];
    UIAlertAction *refresh = [UIAlertAction actionWithTitle:@"Mettre à jour la sélection" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine refreshSelection:self.displayJob[@"url"]]; }];
    refresh.enabled = !engine.busy && !engine.pending && self.displayJob != nil; [sheet addAction:refresh];
    UIAlertAction *storage = [UIAlertAction actionWithTitle:@"Stockage du PC" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine showPCStorage]; }];
    storage.enabled = !engine.busy && engine.root != nil; [sheet addAction:storage];
    if ([engine.pending[@"kind"] isEqual:@"alternative"]) {
        if (engine.candidateFile) [sheet addAction:[UIAlertAction actionWithTitle:@"Écouter la version proposée" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine showAlternative]; }]];
        if (!engine.alternativeAcceptRequested) {
            UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Garder la version actuelle" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine cancelAlternative]; }];
            cancel.enabled = !engine.busy; [sheet addAction:cancel];
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Nettoyer les téléchargements" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine clearUnfinished]; }]];
    UIAlertAction *files = [UIAlertAction actionWithTitle:@"Gérer les fichiers locaux" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        SGShowPage(self, [SGAutomaticLocalFilesPage new]);
    }];
    files.enabled = !engine.busy; [sheet addAction:files];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)chooseMode:(UITableViewCell *)cell {
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Préparer les morceaux" message:@"PC conseillé : laisse-le allumé et accessible pendant la préparation. L'écoute hors ligne fonctionne ensuite sans PC." preferredStyle:UIAlertControllerStyleActionSheet];
    if (engine.root) [sheet addAction:[UIAlertAction actionWithTitle:@"Utiliser le PC associé" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [engine connect:[NSUserDefaults.standardUserDefaults stringForKey:pairKey] ?: @""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:engine.root ? @"Associer un autre PC" : @"Associer le PC — conseillé" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cet iPhone — mode de secours" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setObject:@"device" forKey:modeKey]; [self refresh:nil];
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
        message:engine.importErrors[row[@"spotify"]] ?: @"Choisis une source pour ce morceau. La flèche passera au vert après vérification."
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rechercher à nouveau sur l’iPhone" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [engine repairRow:row selection:selection source:nil];
    }]];
    if (engine.root) [sheet addAction:[UIAlertAction actionWithTitle:@"Chercher une autre version sur le PC" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [engine startAlternative:row]; }]];
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
        if ([engine.registeredTracks[url] isEqual:canonical]) return;
        NSMutableDictionary *registered = [engine.registeredTracks mutableCopy]; registered[url] = [canonical copy]; engine.registeredTracks = registered;
    }
    [engine persistIntent];
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
    BOOL waitingPC = engine.waitingForPC && ([url isEqual:engine.pending[@"url"]] || [url isEqual:engine.resumeURL]);
    BOOL complete = job[@"completeMetadata"] ? [job[@"completeMetadata"] boolValue] : ![job[@"engine"] isEqual:@"device"];
    NSString *state = waitingPC ? (engine.userPaused ? @"paused" : @"queued") : running ? @"running" : queued ? @"queued" : total && ready == total ? (complete ? @"ready" : @"incomplete") :
        engine.userPaused && [url isEqual:engine.resumeURL] ? @"paused" :
        [job[@"state"] isEqual:@"interrupted"] ? @"paused" : ready ? @"partial" : failed || engine.collectionErrors[url] ? @"error" : @"idle";
    double progress = total ? ((double)ready + (running ? engine.transferProgress : 0)) / total : 0;
    return @{@"state":state, @"completed":@(ready), @"total":@(total), @"progress":@(MIN(1, MAX(0, progress))),
        @"queuePosition":@(queued ? [engine.queuedURLs indexOfObject:url] + 1 : 0),
        @"waitingForPC":@(waitingPC),
        @"completeMetadata":job[@"completeMetadata"] ?: @NO};
}
BOOL SGAutomaticDownloadEntity(id entity, UIView *source) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    if (!url || ![NSUserDefaults.standardUserDefaults boolForKey:@"SGAutomaticDownloadsEnabled"]) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *saved = engine.history[url];
        NSDictionary *local = engine.localRows[url];
        if (!saved && [url containsString:@"/track/"] && onPhone(local)) saved = SGAutomaticSingleTrackSelection(local);
        if (engine.clearing) return;
        BOOL current = (engine.busy && [url isEqual:engine.activeCollection]) || [url isEqual:engine.pending[@"url"]] ||
            (engine.waitingForPC && [url isEqual:engine.resumeURL]);
        BOOL queued = [engine.queuedURLs containsObject:url];
        if (!saved && !current && !queued && !engine.collectionErrors[url]) {
            [engine start:url]; [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred]; return;
        }
        UIViewController *owner = SGTopController();
        if (!owner || owner.presentedViewController) return;
        NSDictionary *status = SGAutomaticDownloadStatus(url);
        NSString *message = engine.collectionErrors[url] ?: [NSString stringWithFormat:@"%@/%@ morceaux sur l'iPhone", status[@"completed"], status[@"total"]];
        if (queued) message = [message stringByAppendingFormat:@"\nPosition %@ dans la file", status[@"queuePosition"]];
        if ([status[@"waitingForPC"] boolValue]) message = [message stringByAppendingString:@"\nEn attente du PC. La demande est enregistrée."];
        if (saved[@"completeMetadata"] && ![saved[@"completeMetadata"] boolValue])
            message = [message stringByAppendingString:@"\nLa page publique peut ne fournir qu'une partie de la playlist."];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:saved[@"name"] ?: @"Téléchargement" message:message preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Voir les téléchargements" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (!engine.busy && saved) [engine selectJob:saved];
            if (![owner isKindOfClass:SGAutomaticDownloadsPage.class]) SGShowPage(owner, SGAutomaticDownloadsPageCreate());
        }]];
        if (current) [sheet addAction:[UIAlertAction actionWithTitle:engine.userPaused ? @"Reprendre" : @"Mettre en pause" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (engine.userPaused) [engine resume]; else [engine pause];
        }]];
        else if (queued) [sheet addAction:[UIAlertAction actionWithTitle:@"Retirer de la file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine removeQueued:url]; }]];
        else if (![status[@"state"] isEqual:@"ready"]) [sheet addAction:[UIAlertAction actionWithTitle:engine.busy ? @"Ajouter à la file" : @"Reprendre les titres manquants" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (engine.busy || engine.pending || engine.waitingForPC || !saved) [engine start:url];
            else { [engine selectJob:saved]; [engine resume]; }
        }]];
        BOOL canSelect = !engine.pending && !engine.waitingForPC;
        if ([status[@"completed"] unsignedIntegerValue] && !engine.busy && (canSelect || [engine.job[@"url"] isEqual:url])) [sheet addAction:[UIAlertAction actionWithTitle:@"Écouter les copies hors ligne" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [engine selectJob:saved];
            if (![engine.job[@"url"] isEqual:url]) return;
            NSArray *rows = engine.job[@"items"]; for (NSUInteger i = 0; i < rows.count; i++) if (onPhone(rows[i])) { [engine play:i]; break; }
        }]];
        if (saved && !engine.busy && !engine.pending && !queued) [sheet addAction:[UIAlertAction actionWithTitle:@"Mettre à jour la sélection" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [engine refreshSelection:url]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = source ?: owner.view;
        sheet.popoverPresentationController.sourceRect = source ? source.bounds : owner.view.bounds;
        [owner presentViewController:sheet animated:YES completion:nil];
    });
    return YES;
}

void SGAutomaticListLocalFiles(void (^completion)(NSArray<NSDictionary *> *, NSString *)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
        if (engine.busy || engine.clearing) { completion(nil, @"Mets les téléchargements en pause pour gérer les fichiers locaux."); return; }
        engine.busy = YES; engine.clearing = YES;
        dispatch_async(engine.worker, ^{
            NSArray *items = SGAutomaticLibraryItems(nil);
            dispatch_async(dispatch_get_main_queue(), ^{
                engine.busy = NO; engine.clearing = NO;
                [engine update:engine.message];
                completion(items, items.count ? @"Touche un fichier ou glisse vers la gauche pour le supprimer de l'iPhone." : @"Aucun fichier audio local trouvé.");
                [engine scheduleReconnect];
            });
        });
    });
}
void SGAutomaticDeleteLocalFile(NSDictionary *item, void (^completion)(BOOL, NSString *)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [SGAutomaticDownloads.shared deleteLocalFile:item completion:completion];
    });
}

void SGAutomaticPrepareAudioToolsPC(void (^completion)(NSURL *, NSString *)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
        NSURL *paired = engine.root;
        if (!paired) { completion(nil, @"Associe ton PC dans les options des téléchargements."); return; }
        SGAutomaticDiscoverPC(paired, ^(NSURL *found) {
            if (![engine.root isEqual:paired]) { completion(nil, @"L’association du PC a changé. Réessaie."); return; }
            if (!found) { completion(nil, @"PC injoignable. Allume-le et utilise le même réseau local."); return; }
            engine.root = found; engine.pcIdentityVerified = YES;
            [NSUserDefaults.standardUserDefaults setObject:found.absoluteString forKey:pairKey];
            completion(found, nil);
        });
    });
}

void SGAutomaticImportAudioVersion(NSURL *root, NSDictionary *row,
    BOOL (^cancelled)(void), void (^taskStarted)(NSURLSessionTask *),
    void (^progress)(NSUInteger, NSUInteger), void (^completion)(NSDictionary *, NSString *)) {
    if (!completion) return;
    SGAutomaticDownloads *engine = SGAutomaticDownloads.shared;
    NSDictionary *selection = SGAutomaticSingleTrackSelection(row);
    NSDictionary *validated = [selection[@"items"] firstObject];
    NSURL *endpoint = SGDownloadRoot(root.absoluteString);
    // Use the same serial worker as normal/alternative imports: its transfer
    // cache may prune a previous .stage only after the previous caller used it.
    dispatch_async(engine.worker, ^{
        NSString *error = nil;
        NSDictionary *installed = nil;
        BOOL (^stopped)(void) = ^BOOL { return (cancelled && cancelled()) || ![engine.root isEqual:endpoint]; };
        if (!validated || !endpoint || stopped()) error = @"Transfert arrêté ou informations de version invalides.";
        else if (engine.candidateFile || [engine.pending[@"kind"] isEqual:@"alternative"])
            error = @"Termine le choix de l’autre enregistrement avant d’importer cette copie.";
        else {
            installed = SGAutomaticLibraryReuse(nil, validated, stopped);
            NSURL *staging = installed ? nil : SGAutomaticTransferFile(endpoint, validated, stopped, taskStarted, progress, &error);
            if (staging) {
                // Bind validation and tags to the derivative, not the original
                // catalogue duration/title. No canonical track mapping is saved.
                NSMutableDictionary *request = [validated mutableCopy];
                for (NSString *key in @[@"expectedArtists", @"expectedTitle", @"expectedArtist", @"expectedSeconds"])
                    [request removeObjectForKey:key];
                request[@"expectedTitle"] = validated[@"title"];
                request[@"expectedArtist"] = validated[@"artist"];
                request[@"expectedSeconds"] = validated[@"seconds"];
                installed = SGAutomaticInstallAudioCancellable(staging, request, stopped, &error);
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(installed, installed ? nil : error ?: @"La copie n’a pas pu être enregistrée. Réessaie.");
        });
    });
}
