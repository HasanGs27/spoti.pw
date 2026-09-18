// Explicit, foreground transfer of existing MP3s from the user's paired LAN PC.
// No Spotify download/entitlement hook, transcoding, or NowPlaying changes.
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "LocalDownloadManifest.h"
#import <math.h>

static NSString *const SGDownloadChanged = @"SGLocalDownloadsChanged";
static NSString *const SGDownloadPair = @"spotifyglass.localDownloads.pair";

static NSString *downloadHash(NSURL *file) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:file];
    [stream open];
    CC_SHA256_CTX state;
    CC_SHA256_Init(&state);
    uint8_t buffer[65536];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&state, buffer, (CC_LONG)count);
    [stream close];
    if (count < 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &state);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

@interface SGLocalDownloader : NSObject <NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate>
@property (atomic) BOOL busy;
@property (atomic) NSUInteger generation;
@property (atomic, copy) NSString *message;
@property (atomic, copy) NSArray *tracks;
@property (atomic, strong) NSURL *root;
@property (atomic, strong) NSURLSessionTask *active;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t worker;
+ (instancetype)shared;
- (void)connect:(NSString *)address;
- (void)importTracks:(NSArray *)tracks;
- (void)cancel;
@end

@implementation SGLocalDownloader
+ (instancetype)shared {
    static SGLocalDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [SGLocalDownloader new];
        instance.message = @"Connecte le PC pour voir ses fichiers audio.";
        instance.worker = dispatch_queue_create("pw.spoti.local-transfer", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 30;
        config.timeoutIntervalForResource = 180;
        config.allowsCellularAccess = NO;
        config.HTTPMaximumConnectionsPerHost = 1;
        config.URLCache = nil;
        config.HTTPCookieStorage = nil;
        instance.session = [NSURLSession sessionWithConfiguration:config delegate:instance delegateQueue:nil];
    });
    return instance;
}
- (void)update:(NSString *)message {
    self.message = message;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGDownloadChanged object:self];
    });
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    completion(nil); // A paired PC may not redirect requests to another source.
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes
    totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    long long maximum = task.taskDescription.longLongValue;
    if (written > maximum || expected > maximum) [task cancel];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)url {}

// The serial worker waits; neither the UI nor the session delegate queue does.
// Completion-handler download files are moved before their temporary URL expires.
- (NSURL *)fetch:(NSURL *)url maximum:(NSUInteger)maximum generation:(NSUInteger)generation {
    if (self.generation != generation) return nil;
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *staging = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"sg-import-%@.mp3", NSUUID.UUID.UUIDString]];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL copied = NO;
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
        NSNumber *size = nil;
        [temporary getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!error && self.generation == generation && [response isKindOfClass:NSHTTPURLResponse.class] &&
            ((NSHTTPURLResponse *)response).statusCode == 200 && size.unsignedLongLongValue > 0 && size.unsignedLongLongValue <= maximum)
            copied = [NSFileManager.defaultManager moveItemAtURL:temporary toURL:staging error:nil];
        dispatch_semaphore_signal(done);
    }];
    task.taskDescription = @(maximum).stringValue;
    self.active = task;
    if (self.generation != generation) [task cancel];
    else [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER); // URLSession resource timeout bounds active requests.
    self.active = nil;
    if (copied && self.generation == generation) return staging;
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    return nil;
}
- (void)connect:(NSString *)address {
    if (self.busy) return;
    NSURL *root = SGDownloadRoot(address);
    if (!root) { [self update:@"Colle le lien d’association fourni par le PC, sur le même Wi-Fi."]; return; }
    self.busy = YES;
    self.tracks = nil;
    self.root = nil;
    NSUInteger generation = ++self.generation;
    [self update:@"Connexion au PC…"];
    dispatch_async(self.worker, ^{
        NSURL *file = [self fetch:[root URLByAppendingPathComponent:@"manifest"] maximum:2 * 1024 * 1024 generation:generation];
        NSArray *rows = file ? SGDownloadManifest([NSData dataWithContentsOfURL:file]) : nil;
        if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) return;
            self.busy = NO;
            if (!rows) { [self update:@"Connexion impossible ou liste invalide. Vérifie le PC, le Wi-Fi et l’autorisation Réseau local de Spotify."]; return; }
            self.root = root;
            self.tracks = rows;
            [NSUserDefaults.standardUserDefaults setObject:root.absoluteString forKey:SGDownloadPair];
            [self update:[NSString stringWithFormat:@"%lu morceaux disponibles. Touche un titre ou importe tout.", (unsigned long)rows.count]];
        });
    });
}
- (void)cancel {
    if (!self.busy) return;
    NSUInteger cancelledGeneration = ++self.generation;
    [self.active cancel];
    // Remain busy until all worker cleanup has finished, preventing overlapping writes.
    [self update:@"Annulation…"];
    dispatch_async(self.worker, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != cancelledGeneration) return;
            self.busy = NO;
            [self update:@"Transfert arrêté. Les morceaux déjà importés sont conservés."];
        });
    });
}
- (void)importTracks:(NSArray *)tracks {
    if (self.busy || !self.root || !tracks.count) return;
    self.busy = YES;
    NSUInteger generation = ++self.generation;
    NSURL *root = self.root;
    [self update:@"Vérification des fichiers déjà présents…"];
    dispatch_async(self.worker, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *destination = [documents URLByAppendingPathComponent:@"Spoti Imports" isDirectory:YES];
        NSError *directoryError = nil;
        BOOL safe = documents && [fm createDirectoryAtURL:destination withIntermediateDirectories:NO attributes:nil error:&directoryError];
        // A previously created directory is fine; a symlink or a file is not.
        NSNumber *isDirectory = nil, *isSymlink = nil;
        [destination getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        [destination getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:nil];
        safe = (safe || isDirectory.boolValue) && !isSymlink.boolValue &&
            [[destination URLByResolvingSymlinksInPath].URLByDeletingLastPathComponent.path isEqual:[documents URLByResolvingSymlinksInPath].path];
        if (!safe) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation != generation) return;
                self.busy = NO;
                [self update:@"Le dossier d’import est inaccessible. Aucun fichier modifié."];
            });
            return;
        }
        // Detect exact duplicates anywhere in Documents, including earlier manual imports.
        NSMutableSet *sizes = [NSMutableSet set], *existing = [NSMutableSet set];
        for (NSDictionary *row in tracks) [sizes addObject:row[@"bytes"]];
        NSString *documentPrefix = [[documents URLByResolvingSymlinksInPath].path stringByAppendingString:@"/"];
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:documents includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
        for (NSURL *file in enumerator) {
            if (self.generation != generation) break;
            if (![file.pathExtension.lowercaseString isEqual:@"mp3"]) continue;
            NSNumber *size = nil, *symlink = nil, *regular = nil;
            [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            [file getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
            [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if (!regular.boolValue || symlink.boolValue || ![sizes containsObject:size] ||
                ![[file URLByResolvingSymlinksInPath].path hasPrefix:documentPrefix]) continue;
            NSString *hash = downloadHash(file);
            if (hash) [existing addObject:hash];
        }
        NSUInteger imported = 0, skipped = 0, failed = 0, index = 0;
        for (NSDictionary *row in tracks) {
            if (self.generation != generation) break;
            index++;
            NSString *ident = row[@"id"];
            if ([existing containsObject:ident]) { skipped++; continue; }
            [self update:[NSString stringWithFormat:@"%lu/%lu — %@", (unsigned long)index, (unsigned long)tracks.count, row[@"title"]]];
            NSURL *file = [self fetch:[[root URLByAppendingPathComponent:@"file"] URLByAppendingPathComponent:ident]
                maximum:[row[@"bytes"] unsignedIntegerValue] generation:generation];
            if (!file) { failed++; continue; }
            @autoreleasepool {
                NSNumber *bytes = nil;
                [file getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
                BOOL valid = [bytes isEqual:row[@"bytes"]] && [downloadHash(file) isEqual:ident];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if (valid) {
                    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
                    double duration = CMTimeGetSeconds(asset.duration);
                    valid = asset.playable && [asset tracksWithMediaType:AVMediaTypeAudio].count > 0 &&
                        isfinite(duration) && fabs(duration - [row[@"seconds"] doubleValue]) < 2;
                }
#pragma clang diagnostic pop
                // The complete hash is the filename: no untrusted path components, no replacement.
                NSURL *target = [destination URLByAppendingPathComponent:[ident stringByAppendingString:@".mp3"]];
                if (valid && self.generation == generation && [fm moveItemAtURL:file toURL:target error:nil]) {
                    imported++;
                    [existing addObject:ident];
                    [fm setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:target.path error:nil];
                } else failed++;
                [fm removeItemAtURL:file error:nil];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) return;
            self.busy = NO;
            SGLog(@"[SGMediaTools] local transfer imported=%lu existing=%lu failed=%lu", (unsigned long)imported, (unsigned long)skipped, (unsigned long)failed);
            [self update:[NSString stringWithFormat:@"%lu importés · %lu déjà présents · %lu échecs. Ouvre Fichiers locaux ; relance Spotify si nécessaire.",
                (unsigned long)imported, (unsigned long)skipped, (unsigned long)failed]];
        });
    });
}
@end

@interface SGLocalDownloadsPage : SGPage
@property (nonatomic, strong) UIView *note;
@end

@implementation SGLocalDownloadsPage
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Fichiers du PC";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.note = SGNote(@"Transfère les MP3 du PC sans ZIP ni conversion. Même Wi-Fi, PC allumé. Garde Spotify ouvert pendant le transfert. Ce bouton ne télécharge pas le catalogue Spotify.");
    self.tableView.tableHeaderView = self.note;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh:) name:SGDownloadChanged object:SGLocalDownloader.shared];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh:(NSNotification *)notification { [self.tableView reloadData]; }
- (void)viewWillLayoutSubviews { [super viewWillLayoutSubviews]; SGFitNote(self.tableView, self.note, 16, 16); }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; SGInsetForBars(self.tableView); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : SGLocalDownloader.shared.tracks.count;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"local-download");
    SGLocalDownloader *engine = SGLocalDownloader.shared;
    if (path.section == 0) {
        NSArray *titles = @[@"Connecter le PC", engine.busy ? @"Annuler le transfert" : @"Importer tous les morceaux", @"État"];
        SGFillCell(cell, titles[path.row], path.row == 2 ? engine.message : nil, nil, nil);
        cell.selectionStyle = path.row == 2 ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    } else {
        NSDictionary *row = engine.tracks[path.row];
        SGFillCell(cell, row[@"title"], row[@"artist"], nil, @"arrow.down.circle");
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
}
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return path.section == 0 && path.row == 2 ? 110 : 60;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGLocalDownloader *engine = SGLocalDownloader.shared;
    if (path.section == 1) { if (!engine.busy) [engine importTracks:@[engine.tracks[path.row]]]; return; }
    if (path.row == 1) { if (engine.busy) [engine cancel]; else [engine importTracks:engine.tracks]; return; }
    if (path.row != 0 || engine.busy) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Connecter le PC" message:@"Colle le lien d’association affiché sur le PC." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"http://192.168.…:8767/…/";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.text = [NSUserDefaults.standardUserDefaults stringForKey:SGDownloadPair];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Connecter" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [engine connect:weakAlert.textFields.firstObject.text ?: @""];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *SGLocalDownloadsPageCreate(void) { return [SGLocalDownloadsPage new]; }
