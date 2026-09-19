#import "AutomaticDownloadTransfer.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>

static const unsigned long long SGTransferFileLimit = 100ULL * 1024 * 1024;
static const unsigned long long SGTransferCacheLimit = 512ULL * 1024 * 1024;
static const NSUInteger SGTransferCacheEntries = 32;
static const NSTimeInterval SGTransferTTL = 7 * 24 * 60 * 60;

static BOOL SGTransferMatches(NSString *text, NSString *pattern) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSRange match = [text rangeOfString:pattern options:NSRegularExpressionSearch];
    return match.location == 0 && match.length == text.length;
}

// The engine already validates pairing. Keep the transport independently bounded
// to the same private IPv4, port and token contract; never follow a redirect.
static NSURL *SGTransferRoot(NSURL *root) {
    if (![root isKindOfClass:NSURL.class]) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:root resolvingAgainstBaseURL:NO];
    if (![parts.scheme isEqual:@"http"] || parts.user || parts.password || parts.query || parts.fragment ||
        parts.port.integerValue < 1024 || parts.port.integerValue > 65535 ||
        !SGTransferMatches(parts.path, @"^/[A-Za-z0-9_-]{32}/?$")) return nil;
    struct in_addr address;
    if (inet_pton(AF_INET, parts.host.UTF8String ?: "", &address) != 1) return nil;
    uint32_t ip = ntohl(address.s_addr);
    if (!((ip >> 24) == 10 || (ip >> 20) == 0xac1 || (ip >> 16) == 0xc0a8)) return nil;
    if (![parts.path hasSuffix:@"/"]) parts.path = [parts.path stringByAppendingString:@"/"];
    return parts.URL;
}

static NSString *SGTransferHex(const unsigned char *digest) {
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

static NSString *SGTransferKey(NSURL *root, NSString *hash, NSNumber *bytes, NSString *extension) {
    NSData *data = [[NSString stringWithFormat:@"v1|%@|%@|%@|%@", root.absoluteString, hash, bytes, extension]
        dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return SGTransferHex(digest);
}

static BOOL SGTransferRegular(NSURL *url, struct stat *value) {
    struct stat st;
    if (lstat(url.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1) return NO;
    if (value) *value = st;
    return YES;
}

static BOOL SGTransferDirectory(NSURL *directory) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil];
    struct stat st;
    if (lstat(directory.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) ||
        ![[directory URLByResolvingSymlinksInPath].URLByDeletingLastPathComponent.path
          isEqual:[directory.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath].path]) return NO;
    [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
#if TARGET_OS_IPHONE
    [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
        ofItemAtPath:directory.path error:nil];
#endif
    return YES;
}

// Only names owned by this module can be removed. The serial caller may retain
// one completed stage while the user previews an alternative version.
static BOOL SGTransferPrune(NSURL *directory, NSString *keepName, NSURL *protectedCandidate,
                           unsigned long long reserve,
                           unsigned long long limit, NSUInteger maxEntries) {
    NSString *protectedName = nil;
    unsigned long long protectedBytes = 0;
    if (protectedCandidate) {
        // Validate before any mutation. Never turn a malformed/external path into
        // permission to prune without protecting the user's pending candidate.
        if (![protectedCandidate isKindOfClass:NSURL.class] || !protectedCandidate.isFileURL ||
            protectedCandidate.baseURL || protectedCandidate.host.length ||
            protectedCandidate.query || protectedCandidate.fragment) return NO;
        NSString *name = protectedCandidate.lastPathComponent;
        if (!SGTransferMatches(name, @"^[a-f0-9]{64}-[A-Fa-f0-9-]{36}\\.stage\\.(mp3|m4a)$") ||
            ![protectedCandidate.path isEqual:[directory.path stringByAppendingPathComponent:name]]) return NO;
        struct stat st;
        if (!SGTransferRegular(protectedCandidate, &st) || st.st_size < 1024 ||
            (unsigned long long)st.st_size > SGTransferFileLimit) return NO;
        protectedName = name;
        protectedBytes = (unsigned long long)st.st_size;
    }
    NSUInteger count = 1 + (protectedName ? 1 : 0);
    if (reserve > limit || protectedBytes > limit - reserve || count > maxEntries) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *files = [fm contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil];
    NSMutableArray *entries = [NSMutableArray array];
    unsigned long long bytes = reserve + protectedBytes;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSURL *file in files) {
        NSString *name = file.lastPathComponent;
        if ([name isEqual:keepName] || [name isEqual:protectedName]) continue;
        BOOL stage = SGTransferMatches(name, @"^[a-f0-9]{64}-[A-Fa-f0-9-]{36}\\.stage\\.(mp3|m4a)$");
        if (!stage && !SGTransferMatches(name, @"^[a-f0-9]{64}\\.part$")) continue;
        struct stat st;
        if (!SGTransferRegular(file, &st)) {
            // Unlinking this owned name never follows a symlink or removes its target.
            unlink(file.fileSystemRepresentation);
            continue;
        }
        if (stage || st.st_size < 0 || (unsigned long long)st.st_size > SGTransferFileLimit ||
            now - (NSTimeInterval)st.st_mtime > SGTransferTTL) {
            if ([fm removeItemAtURL:file error:nil]) continue;
        }
        unsigned long long size = (unsigned long long)MAX((off_t)0, st.st_size);
        bytes += size;
        [entries addObject:@{@"file":file, @"bytes":@(size), @"date":@(st.st_mtime)}];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]];
    }];
    count += entries.count;
    for (NSDictionary *entry in entries) {
        if (bytes <= limit && count <= maxEntries) break;
        if ([fm removeItemAtURL:entry[@"file"] error:nil]) {
            bytes -= [entry[@"bytes"] unsignedLongLongValue]; count--;
        }
    }
    return bytes <= limit && count <= maxEntries;
}

static BOOL SGTransferInteger(NSString *text, unsigned long long *result) {
    if (!SGTransferMatches(text, @"^[0-9]{1,20}$")) return NO;
    errno = 0;
    unsigned long long value = strtoull(text.UTF8String, NULL, 10);
    if (errno == ERANGE) return NO;
    if (result) *result = value;
    return YES;
}

typedef NS_ENUM(NSUInteger, SGTransferResponse) {
    SGTransferResponseReject, SGTransferResponseReset, SGTransferResponseAppend
};

static SGTransferResponse SGTransferValidateResponse(NSHTTPURLResponse *response, NSString *hash,
                                                     NSUInteger expected, NSUInteger offset) {
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return SGTransferResponseReject;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (id key in response.allHeaderFields) {
        id value = response.allHeaderFields[key];
        if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class] || headers[[key lowercaseString]])
            return SGTransferResponseReject;
        headers[[key lowercaseString]] = value;
    }
    NSString *encoding = [headers[@"content-encoding"] lowercaseString];
    if (encoding && ![encoding isEqual:@"identity"]) return SGTransferResponseReject;
    NSString *etag = [NSString stringWithFormat:@"\"%@\"", hash];
    if (headers[@"etag"] && ![headers[@"etag"] isEqual:etag]) return SGTransferResponseReject;
    unsigned long long length = 0;
    if (headers[@"content-length"] && !SGTransferInteger(headers[@"content-length"], &length)) return SGTransferResponseReject;
    if (response.statusCode == 200) {
        if (headers[@"content-range"] || (headers[@"content-length"] && length != expected)) return SGTransferResponseReject;
        // Old companions lack an ETag and ignore Range. Their full body is still
        // accepted, but replaces the old prefix and must pass the final SHA.
        return SGTransferResponseReset;
    }
    if (response.statusCode != 206 || !offset || offset >= expected || ![headers[@"etag"] isEqual:etag]) return SGTransferResponseReject;
    NSString *range = headers[@"content-range"];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:range ?: @"" options:0 range:NSMakeRange(0, range.length)];
    unsigned long long start = 0, end = 0, total = 0;
    if (!match || match.range.location != 0 || match.range.length != range.length ||
        !SGTransferInteger([range substringWithRange:[match rangeAtIndex:1]], &start) ||
        !SGTransferInteger([range substringWithRange:[match rangeAtIndex:2]], &end) ||
        !SGTransferInteger([range substringWithRange:[match rangeAtIndex:3]], &total) ||
        start != offset || total != expected || end != expected - 1 ||
        (headers[@"content-length"] && length != expected - offset)) return SGTransferResponseReject;
    return SGTransferResponseAppend;
}

static NSString *SGTransferHash(NSURL *file, NSUInteger expected, BOOL (^cancelled)(void)) {
    int fd = open(file.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    BOOL valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_nlink == 1 && st.st_size == (off_t)expected;
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    unsigned char buffer[65536], digest[CC_SHA256_DIGEST_LENGTH];
    NSUInteger readBytes = 0;
    while (valid && !(cancelled && cancelled())) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (!count) break;
        readBytes += (NSUInteger)count;
        if (readBytes > expected) { valid = NO; break; }
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    valid = valid && readBytes == expected && !(cancelled && cancelled());
    close(fd);
    if (!valid) return nil;
    CC_SHA256_Final(digest, &context);
    return SGTransferHex(digest);
}

@interface SGAutomaticTransferSession : NSObject <NSURLSessionDataDelegate>
@property (nonatomic) int descriptor;
@property (nonatomic) NSUInteger expected;
@property (nonatomic) NSUInteger offset;
@property (nonatomic) NSUInteger written;
@property (nonatomic) BOOL accepted;
@property (nonatomic) BOOL invalidBody;
@property (nonatomic, copy) NSString *hashValue;
@property (nonatomic, copy) NSString *failure;
@property (nonatomic, copy) BOOL (^cancelled)(void);
@property (nonatomic, copy) void (^progress)(NSUInteger, NSUInteger);
@property (nonatomic, strong) dispatch_semaphore_t completed;
@end

@implementation SGAutomaticTransferSession
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    self.failure = @"Le PC a renvoyé une redirection inattendue.";
    completionHandler(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
        completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if (self.cancelled && self.cancelled()) { completionHandler(NSURLSessionResponseCancel); return; }
    SGTransferResponse disposition = SGTransferValidateResponse((NSHTTPURLResponse *)response, self.hashValue, self.expected, self.offset);
    if (disposition == SGTransferResponseReject) {
        self.failure = @"La réponse du PC ne correspond pas au fichier demandé.";
        completionHandler(NSURLSessionResponseCancel); return;
    }
    if (disposition == SGTransferResponseReset) {
        if (ftruncate(self.descriptor, 0) || lseek(self.descriptor, 0, SEEK_SET) < 0) {
            self.failure = @"Impossible de préparer le fichier sur l’iPhone.";
            completionHandler(NSURLSessionResponseCancel); return;
        }
        self.written = 0;
    }
    self.accepted = YES;
    if (self.progress) self.progress(self.written, self.expected);
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!self.accepted || (self.cancelled && self.cancelled())) { [task cancel]; return; }
    if (data.length > self.expected - self.written) {
        self.invalidBody = YES;
        self.failure = @"Le fichier reçu dépasse la taille annoncée.";
        [task cancel]; return;
    }
    const unsigned char *buffer = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = write(self.descriptor, buffer, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { self.failure = @"L’iPhone n’a pas pu enregistrer la suite du fichier."; [task cancel]; return; }
        self.written += (NSUInteger)count; remaining -= (NSUInteger)count; buffer += count;
    }
    if (self.progress) self.progress(self.written, self.expected);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
#ifdef SG_AUTOMATIC_TRANSFER_TEST
    fprintf(stderr, "transfer-test completion: accepted=%d written=%lu expected=%lu transport=%ld\n",
        self.accepted, (unsigned long)self.written, (unsigned long)self.expected, (long)error.code);
#endif
    if (!self.failure && error && !(self.cancelled && self.cancelled()))
        self.failure = @"Transfert interrompu. La partie reçue sera reprise au prochain essai.";
    if (!self.failure && (!self.accepted || self.written != self.expected))
        self.failure = @"Le fichier reçu est incomplet. La reprise reste disponible.";
    if (self.descriptor >= 0) {
        if (fsync(self.descriptor) && !self.failure) self.failure = @"Le fichier n’a pas pu être enregistré complètement.";
        close(self.descriptor); self.descriptor = -1;
    }
    dispatch_semaphore_signal(self.completed);
}
@end

#ifdef SG_AUTOMATIC_TRANSFER_TEST
static NSURL *SGTransferTestDirectory;
static Class SGTransferTestProtocolClass;
#endif

NSURL *SGAutomaticTransferFile(NSURL *companionRoot, NSDictionary *row, BOOL (^cancelled)(void),
    void (^taskStarted)(NSURLSessionTask *task), void (^progress)(NSUInteger, NSUInteger), NSString **error) {
    return SGAutomaticTransferFilePreservingCandidate(companionRoot, row, nil, cancelled, taskStarted, progress, error);
}

NSURL *SGAutomaticTransferFilePreservingCandidate(NSURL *companionRoot, NSDictionary *row, NSURL *protectedCandidateURL,
    BOOL (^cancelled)(void), void (^taskStarted)(NSURLSessionTask *task),
    void (^progress)(NSUInteger, NSUInteger), NSString **error) {
    if (error) *error = nil;
    if (cancelled && cancelled()) return nil;
    NSURL *root = SGTransferRoot(companionRoot);
    NSString *hash = [row isKindOfClass:NSDictionary.class] ? row[@"id"] : nil;
    id byteValue = [row isKindOfClass:NSDictionary.class] ? row[@"bytes"] : nil;
    NSString *extension = [row isKindOfClass:NSDictionary.class] ? row[@"extension"] ?: @"mp3" : nil;
    if (!root || !SGTransferMatches(hash, @"^[a-f0-9]{64}$") ||
        ![byteValue isKindOfClass:NSNumber.class] || !isfinite([byteValue doubleValue]) ||
        [byteValue doubleValue] != [byteValue unsignedLongLongValue] ||
        [byteValue unsignedLongLongValue] < 1024 || [byteValue unsignedLongLongValue] > SGTransferFileLimit ||
        !([extension isEqual:@"mp3"] || [extension isEqual:@"m4a"])) {
        if (error) *error = @"Informations de transfert invalides.";
        return nil;
    }
    NSUInteger expected = [byteValue unsignedIntegerValue];
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"spotifyglass-audio-transfers-v1" isDirectory:YES];
#ifdef SG_AUTOMATIC_TRANSFER_TEST
    if (SGTransferTestDirectory) directory = SGTransferTestDirectory;
#endif
    NSString *key = SGTransferKey(root, hash, byteValue, extension);
    NSString *name = [key stringByAppendingString:@".part"];
    NSURL *file = [directory URLByAppendingPathComponent:name];
    if (!SGTransferDirectory(directory) || !SGTransferPrune(directory, name, protectedCandidateURL,
        expected, SGTransferCacheLimit, SGTransferCacheEntries)) {
        if (error) *error = @"Impossible de réserver le stockage temporaire du transfert.";
        return nil;
    }
    struct stat old;
    if (!lstat(file.fileSystemRepresentation, &old)) {
        if (!S_ISREG(old.st_mode) || old.st_nlink != 1) {
            if (error) *error = @"Le fichier temporaire n’est pas un fichier audio régulier.";
            return nil;
        }
        if (old.st_size < 0 || (unsigned long long)old.st_size > expected ||
            NSDate.date.timeIntervalSince1970 - (NSTimeInterval)old.st_mtime > SGTransferTTL)
            unlink(file.fileSystemRepresentation);
    }
    int fd = open(file.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 0 || st.st_size > (off_t)expected ||
        lseek(fd, 0, SEEK_END) < 0) {
        if (fd >= 0) close(fd);
        if (error) *error = @"Impossible d’ouvrir le fichier temporaire.";
        return nil;
    }
    NSUInteger offset = (NSUInteger)st.st_size;
    BOOL complete = offset == expected;
    if (!complete) {
        SGAutomaticTransferSession *delegate = [SGAutomaticTransferSession new];
        delegate.descriptor = fd; delegate.expected = expected; delegate.offset = offset; delegate.written = offset;
        delegate.hashValue = hash; delegate.cancelled = cancelled; delegate.progress = progress;
        delegate.completed = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.URLCache = nil; config.HTTPCookieStorage = nil; config.URLCredentialStorage = nil; config.HTTPShouldSetCookies = NO;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 150; config.allowsCellularAccess = NO;
#ifdef SG_AUTOMATIC_TRANSFER_TEST
        if (SGTransferTestProtocolClass) config.protocolClasses = @[SGTransferTestProtocolClass];
#endif
        NSOperationQueue *queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:queue];
        NSURL *url = [[root URLByAppendingPathComponent:@"file"] URLByAppendingPathComponent:hash];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        if (offset) {
            [request setValue:[NSString stringWithFormat:@"bytes=%lu-", (unsigned long)offset] forHTTPHeaderField:@"Range"];
            [request setValue:[NSString stringWithFormat:@"\"%@\"", hash] forHTTPHeaderField:@"If-Range"];
        }
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
        if (taskStarted) taskStarted(task);
        if (cancelled && cancelled()) [task cancel]; else [task resume];
        while (dispatch_semaphore_wait(delegate.completed, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC))) {
            if (cancelled && cancelled()) [task cancel];
        }
        [session finishTasksAndInvalidate];
        complete = !delegate.failure && delegate.accepted && delegate.written == expected;
        if (delegate.invalidBody) unlink(file.fileSystemRepresentation);
        if (!complete && error) *error = delegate.failure;
    } else close(fd);
    if (cancelled && cancelled()) return nil;
    if (!complete) return nil;
    if (![SGTransferHash(file, expected, cancelled) isEqual:hash]) {
        if (cancelled && cancelled()) return nil;
        unlink(file.fileSystemRepresentation);
        if (error) *error = @"Le contrôle d’intégrité a échoué. Le prochain essai repartira de zéro.";
        return nil;
    }
    if (cancelled && cancelled()) return nil;
    NSURL *staging = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.stage.%@", key, NSUUID.UUID.UUIDString, extension]];
    if (![NSFileManager.defaultManager moveItemAtURL:file toURL:staging error:nil]) {
        if (error) *error = @"Impossible de finaliser le fichier reçu.";
        return nil;
    }
    return staging;
}

#ifdef SG_AUTOMATIC_TRANSFER_TEST
#include <assert.h>

static NSInteger SGMockCode;
static NSDictionary *SGMockHeaders;
static NSData *SGMockBody;
static NSError *SGMockFailure;
static NSURLRequest *SGMockRequest;
static NSUInteger SGMockRequests;
static dispatch_semaphore_t SGMockDelivered;

@interface SGTransferMockProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@property (nonatomic, strong) dispatch_semaphore_t delivered;
@end
@implementation SGTransferMockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    SGMockRequests++; SGMockRequest = self.request;
    // Snapshot fixtures: a cancelled asynchronous producer must never read the
    // next test's body or failure after the engine has returned to its caller.
    NSData *body = SGMockBody;
    NSError *failure = SGMockFailure;
    self.delivered = SGMockDelivered;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:SGMockCode HTTPVersion:@"HTTP/1.1" headerFields:SGMockHeaders];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    for (NSUInteger offset = 0; offset < body.length; offset += 1024)
        [self.client URLProtocol:self didLoadData:[body subdataWithRange:NSMakeRange(offset, MIN((NSUInteger)1024, body.length - offset))]];
    if (!failure) { [self.client URLProtocolDidFinishLoading:self]; return; }
    // A synchronous didFail can make NSURLSession discard queued data before it
    // asks the delegate to accept the response. Inject the connection loss only
    // after the public progress callback confirms these bytes reached disk.
    // Do not block NSURLProtocol's loading thread while awaiting delegate work.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        long timedOut = dispatch_semaphore_wait(self.delivered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        if (self.stopped) return;
        if (timedOut) fprintf(stderr, "transfer-test: mock timed out waiting for delivered prefix\n");
        [self.client URLProtocol:self didFailWithError:failure];
    });
}
- (void)stopLoading {
    self.stopped = YES;
    if (self.delivered) dispatch_semaphore_signal(self.delivered);
}
@end

@interface SGTransferTestCancellation : NSObject
@property (atomic) BOOL value;
@end
@implementation SGTransferTestCancellation
@end

static NSString *SGTransferTestHash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return SGTransferHex(digest);
}
static NSHTTPURLResponse *SGTransferTestResponse(NSInteger code, NSDictionary *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://10.0.0.1:8767/"]
        statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:headers];
}
static void SGTransferMock(NSInteger code, NSDictionary *headers, NSData *body, BOOL fail) {
    SGMockCode = code; SGMockHeaders = headers; SGMockBody = body;
    SGMockFailure = fail ? [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil] : nil;
    SGMockDelivered = fail ? dispatch_semaphore_create(0) : nil;
}
static NSURL *SGTransferTestPart(NSURL *root, NSDictionary *row) {
    return [SGTransferTestDirectory URLByAppendingPathComponent:[SGTransferKey(SGTransferRoot(root), row[@"id"], row[@"bytes"], row[@"extension"] ?: @"mp3") stringByAppendingString:@".part"]];
}
static void SGTransferTestConsume(NSURL *file, NSData *body) {
    assert(file && [[NSData dataWithContentsOfURL:file] isEqual:body]);
    assert([NSFileManager.defaultManager removeItemAtURL:file error:nil]);
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *sandbox = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        assert([fm createDirectoryAtURL:sandbox withIntermediateDirectories:NO attributes:nil error:nil]);
        SGTransferTestDirectory = [sandbox URLByAppendingPathComponent:@"cache" isDirectory:YES];
        SGTransferTestProtocolClass = SGTransferMockProtocol.class;
        NSURL *root = [NSURL URLWithString:@"http://10.0.0.1:8767/abcdefghijklmnopqrstuvwx12345678/"];
        NSMutableData *data = [NSMutableData dataWithLength:8192];
        unsigned char *raw = data.mutableBytes;
        for (NSUInteger i = 0; i < data.length; i++) raw[i] = (unsigned char)((i * 13 + i / 97) % 251);
        NSString *hash = SGTransferTestHash(data), *etag = [NSString stringWithFormat:@"\"%@\"", hash];
        NSDictionary *row = @{@"id":hash, @"bytes":@(data.length), @"extension":@"m4a"};
        NSDictionary *full = @{@"Content-Length":@"8192", @"ETag":etag};
        NSDictionary *tail = @{@"Content-Length":@"6144", @"ETag":etag, @"Content-Range":@"bytes 2048-8191/8192"};
        NSString *reason = nil;

        assert(SGTransferValidateResponse(SGTransferTestResponse(200, @{}), hash, 8192, 2048) == SGTransferResponseReset);
        assert(SGTransferValidateResponse(SGTransferTestResponse(200, full), hash, 8192, 2048) == SGTransferResponseReset);
        assert(SGTransferValidateResponse(SGTransferTestResponse(206, tail), hash, 8192, 2048) == SGTransferResponseAppend);
        for (NSDictionary *change in @[@{@"ETag":@"\"other\""}, @{@"ETag":[@"W/" stringByAppendingString:etag]},
            @{@"Content-Range":@"bytes 0-8191/8192"}, @{@"Content-Range":@"bytes 2048-4095/8192"},
            @{@"Content-Range":@"bytes 2048-8191/8193"}, @{@"Content-Range":@"bytes 2048-8191/*"},
            @{@"Content-Range":@"bytes 2048-8191/8192\n"},
            @{@"Content-Length":@"6143"}, @{@"Content-Length":@"+6144"}, @{@"Content-Encoding":@"gzip"}]) {
            NSMutableDictionary *bad = [tail mutableCopy]; [bad addEntriesFromDictionary:change];
            assert(SGTransferValidateResponse(SGTransferTestResponse(206, bad), hash, 8192, 2048) == SGTransferResponseReject);
        }
        assert(SGTransferValidateResponse(SGTransferTestResponse(206, tail), hash, 8192, 0) == SGTransferResponseReject);
        assert(SGTransferValidateResponse(SGTransferTestResponse(206, @{@"Content-Range":@"bytes 2048-8191/8192"}), hash, 8192, 2048) == SGTransferResponseReject);
        assert(SGTransferValidateResponse(SGTransferTestResponse(416, @{@"Content-Range":@"bytes */8192"}), hash, 8192, 2048) == SGTransferResponseReject);
        assert(SGTransferValidateResponse(SGTransferTestResponse(302, @{}), hash, 8192, 0) == SGTransferResponseReject);
        assert(SGTransferValidateResponse(SGTransferTestResponse(200, @{@"Content-Length":@"18446744073709551616"}), hash, 8192, 0) == SGTransferResponseReject);
        assert(!SGTransferInteger(@"8192\n", NULL));
        assert(SGTransferValidateResponse(SGTransferTestResponse(200, @{@"ETag":@"bad"}), hash, 8192, 0) == SGTransferResponseReject);

        // Failure saves the exact prefix. A fresh helper call models process restart.
        SGTransferMock(200, full, [data subdataWithRange:NSMakeRange(0, 2048)], YES);
        dispatch_semaphore_t delivered = SGMockDelivered;
        NSURL *interrupted = SGAutomaticTransferFile(root, row, nil, nil, ^(NSUInteger received, NSUInteger total) {
            if (received == 2048) dispatch_semaphore_signal(delivered);
        }, &reason);
        NSURL *part = SGTransferTestPart(root, row);
        fprintf(stderr, "transfer-test interruption: reason=%s requests=%lu bytes=%lu file=%s\n",
            reason.UTF8String ?: "(nil)", (unsigned long)SGMockRequests,
            (unsigned long)[NSData dataWithContentsOfURL:part].length, part.lastPathComponent.UTF8String);
        assert(!interrupted && reason.length);
        assert([[NSData dataWithContentsOfURL:part] isEqual:[data subdataWithRange:NSMakeRange(0, 2048)]]);
        SGTransferMock(206, tail, [data subdataWithRange:NSMakeRange(2048, 6144)], NO);
        NSURL *result = SGAutomaticTransferFile(root, row, nil, nil, nil, &reason);
        assert([[SGMockRequest valueForHTTPHeaderField:@"Range"] isEqual:@"bytes=2048-"]);
        assert([[SGMockRequest valueForHTTPHeaderField:@"If-Range"] isEqual:etag]);
        assert([[SGMockRequest valueForHTTPHeaderField:@"Accept-Encoding"] isEqual:@"identity"]);
        assert([SGMockRequest.URL.path hasSuffix:[@"/file/" stringByAppendingString:hash]]);
        assert([result.pathExtension isEqual:@"m4a"] && ![fm fileExistsAtPath:part.path]);
        SGTransferTestConsume(result, data);

        // An old companion ignores Range and sends 200 without ETag: replace, do not append.
        assert([[data subdataWithRange:NSMakeRange(0, 2048)] writeToURL:part atomically:YES]);
        SGTransferMock(200, @{@"Content-Length":@"8192"}, data, NO);
        SGTransferTestConsume(SGAutomaticTransferFile(root, row, nil, nil, nil, &reason), data);
        assert(![fm fileExistsAtPath:part.path]);

        // Malformed 206 never overwrites a valid prefix; tampered complete bodies are removed.
        NSData *prefix = [data subdataWithRange:NSMakeRange(0, 2048)];
        assert([prefix writeToURL:part atomically:YES]);
        SGTransferMock(206, @{@"ETag":@"bad", @"Content-Range":@"bytes 2048-8191/8192"}, [data subdataWithRange:NSMakeRange(2048, 6144)], NO);
        assert(!SGAutomaticTransferFile(root, row, nil, nil, nil, &reason));
        assert([[NSData dataWithContentsOfURL:part] isEqual:prefix]);
        NSMutableData *tampered = [data mutableCopy]; ((unsigned char *)tampered.mutableBytes)[4096] ^= 1;
        SGTransferMock(200, full, tampered, NO);
        assert(!SGAutomaticTransferFile(root, row, nil, nil, nil, &reason));
        assert(![fm fileExistsAtPath:part.path]);

        // Truncation without a transport error still cannot become ready.
        SGTransferMock(200, full, prefix, NO);
        assert(!SGAutomaticTransferFile(root, row, nil, nil, nil, &reason));
        assert([[NSData dataWithContentsOfURL:part] isEqual:prefix]);
        assert([fm removeItemAtURL:part error:nil]);

        NSUInteger requests = SGMockRequests;
        assert(!SGAutomaticTransferFile(root, row, ^BOOL { return YES; }, nil, nil, &reason));
        assert(SGMockRequests == requests);
        SGTransferTestCancellation *cancel = [SGTransferTestCancellation new];
        assert(!SGAutomaticTransferFile(root, row, ^BOOL { return cancel.value; },
            ^(NSURLSessionTask *task) { cancel.value = YES; }, nil, &reason));
        assert(SGMockRequests == requests);
        cancel.value = NO;
        SGTransferMock(200, full, [data subdataWithRange:NSMakeRange(0, 1024)], NO);
        assert(!SGAutomaticTransferFile(root, row, ^BOOL { return cancel.value; }, nil,
            ^(NSUInteger received, NSUInteger total) { if (received >= 1024) cancel.value = YES; }, &reason));
        NSData *saved = [NSData dataWithContentsOfURL:part];
        assert(saved.length >= 1024 && saved.length < data.length && [saved isEqual:[data subdataWithRange:NSMakeRange(0, saved.length)]]);
        assert([fm removeItemAtURL:part error:nil]);
        cancel.value = NO;
        SGTransferMock(200, full, data, NO);
        assert(!SGAutomaticTransferFile(root, row, ^BOOL { return cancel.value; }, nil,
            ^(NSUInteger received, NSUInteger total) { if (received == total) cancel.value = YES; }, &reason));
        assert([[NSData dataWithContentsOfURL:part] isEqual:data]);
        requests = SGMockRequests;
        SGTransferTestConsume(SGAutomaticTransferFile(root, row, nil, nil, nil, &reason), data);
        assert(SGMockRequests == requests); // cancelled at EOF resumes without downloading again

        // A preview candidate survives subsequent transfers, even for the same
        // content hash. Only its exact UUID stage is retained; another completed
        // unowned stage is still pruned. Age must not invalidate the preview.
        SGTransferMock(200, full, data, NO);
        NSURL *candidate = SGAutomaticTransferFile(root, row, nil, nil, nil, &reason);
        assert(candidate && [[NSData dataWithContentsOfURL:candidate] isEqual:data]);
        NSURL *orphan = SGAutomaticTransferFilePreservingCandidate(root, row, candidate, nil, nil, nil, &reason);
        assert(orphan && ![orphan isEqual:candidate]);
        assert([[NSData dataWithContentsOfURL:candidate] isEqual:data]);
        assert([fm setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-(SGTransferTTL + 60)]}
            ofItemAtPath:candidate.path error:nil]);
        NSURL *independent = SGAutomaticTransferFilePreservingCandidate(root, row, candidate, nil, nil, nil, &reason);
        assert(independent && ![independent isEqual:candidate]);
        assert(![fm fileExistsAtPath:orphan.path]);
        SGTransferTestConsume(independent, data);
        assert([[NSData dataWithContentsOfURL:candidate] isEqual:data]);

        // The protected 8192-byte file counts in BOTH budgets. Evict another
        // prefix when needed; fail without deleting anything when protection
        // plus the incoming reservation alone exceeds a limit.
        NSURL *budgetOld = [SGTransferTestDirectory URLByAppendingPathComponent:
            [[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0] stringByAppendingString:@".part"]];
        NSURL *budgetNew = [SGTransferTestDirectory URLByAppendingPathComponent:
            [[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0] stringByAppendingString:@".part"]];
        assert([prefix writeToURL:budgetOld atomically:YES]);
        assert([prefix writeToURL:budgetNew atomically:YES]);
        assert([fm setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-60]}
            ofItemAtPath:budgetOld.path error:nil]);
        assert(SGTransferPrune(SGTransferTestDirectory, @"reserved.part", candidate, 2048, 12288, 3));
        assert(![fm fileExistsAtPath:budgetOld.path] && [fm fileExistsAtPath:budgetNew.path]);
        assert(!SGTransferPrune(SGTransferTestDirectory, @"reserved.part", candidate, 2048, 10239, 3));
        assert(!SGTransferPrune(SGTransferTestDirectory, @"reserved.part", candidate, 2048, 16384, 1));
        assert([fm fileExistsAtPath:budgetNew.path]);
        assert([[NSData dataWithContentsOfURL:candidate] isEqual:data]);
        // Count, independently of bytes, must also evict the remaining prefix.
        assert(SGTransferPrune(SGTransferTestDirectory, @"reserved.part", candidate, 2048, 16384, 2));
        assert(![fm fileExistsAtPath:budgetNew.path]);

        // Invalid protection is an error, not an invitation to prune without it.
        // No request starts and no existing stage, unrelated file or link target
        // is deleted. All files here belong only to this synthetic sandbox.
        NSURL *unrelated = [SGTransferTestDirectory URLByAppendingPathComponent:@"unrelated.stage.mp3"];
        NSURL *externalCandidate = [sandbox URLByAppendingPathComponent:candidate.lastPathComponent];
        NSURL *missingCandidate = [SGTransferTestDirectory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@.stage.mp3", hash, NSUUID.UUID.UUIDString]];
        NSURL *linkedCandidate = [SGTransferTestDirectory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@.stage.mp3", hash, NSUUID.UUID.UUIDString]];
        NSURL *directoryCandidate = [SGTransferTestDirectory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@.stage.mp3", hash, NSUUID.UUID.UUIDString]];
        assert([data writeToURL:unrelated atomically:YES]);
        assert([data writeToURL:externalCandidate atomically:YES]);
        assert(!symlink(externalCandidate.fileSystemRepresentation, linkedCandidate.fileSystemRepresentation));
        assert([fm createDirectoryAtURL:directoryCandidate withIntermediateDirectories:NO attributes:nil error:nil]);
        requests = SGMockRequests;
        for (NSURL *invalid in @[unrelated, externalCandidate, missingCandidate, linkedCandidate, directoryCandidate,
            [NSURL URLWithString:[candidate.absoluteString stringByAppendingString:@"?unexpected=1"]],
            [NSURL URLWithString:@"https://example.com/candidate.stage.mp3"]]) {
            assert(!SGAutomaticTransferFilePreservingCandidate(root, row, invalid, nil, nil, nil, &reason));
            assert(reason.length && SGMockRequests == requests);
            assert([[NSData dataWithContentsOfURL:candidate] isEqual:data]);
            assert([[NSData dataWithContentsOfURL:externalCandidate] isEqual:data]);
            assert([[NSData dataWithContentsOfURL:unrelated] isEqual:data]);
        }
        struct stat linked;
        assert(!lstat(linkedCandidate.fileSystemRepresentation, &linked) && S_ISLNK(linked.st_mode));
        assert(!unlink(linkedCandidate.fileSystemRepresentation));
        assert([fm removeItemAtURL:directoryCandidate error:nil]);
        assert([fm removeItemAtURL:unrelated error:nil]);
        assert([fm removeItemAtURL:externalCandidate error:nil]);
        SGTransferTestConsume(candidate, data);

        // Immutable identity protects against a different PC, size, hash or extension.
        NSString *key = SGTransferKey(root, hash, @8192, @"m4a");
        assert(![key isEqual:SGTransferKey(root, hash, @8192, @"mp3")]);
        assert(![key isEqual:SGTransferKey(root, hash, @8193, @"m4a")]);
        assert(![key isEqual:SGTransferKey(root, [@"f" stringByPaddingToLength:64 withString:@"f" startingAtIndex:0], @8192, @"m4a")]);
        assert(![key isEqual:SGTransferKey([NSURL URLWithString:[root.absoluteString stringByReplacingOccurrencesOfString:@"10.0.0.1" withString:@"10.0.0.2"]], hash, @8192, @"m4a")]);
        assert(![key isEqual:SGTransferKey([NSURL URLWithString:[root.absoluteString stringByReplacingOccurrencesOfString:@"12345678" withString:@"87654321"]], hash, @8192, @"m4a")]);
        for (NSURL *badRoot in @[[NSURL URLWithString:@"https://example.com/"], [NSURL URLWithString:[root.absoluteString stringByReplacingOccurrencesOfString:@"10.0.0.1" withString:@"8.8.8.8"]]])
            assert(!SGAutomaticTransferFile(badRoot, row, nil, nil, nil, &reason));
        for (NSDictionary *change in @[@{@"id":@"../file"}, @{@"bytes":@8192.5}, @{@"bytes":@-1}, @{@"bytes":@(SGTransferFileLimit + 1)}, @{@"extension":@"../mp3"}]) {
            NSMutableDictionary *bad = [row mutableCopy]; [bad addEntriesFromDictionary:change];
            assert(!SGAutomaticTransferFile(root, bad, nil, nil, nil, &reason));
        }

        // TTL, count/byte bounds and symlink safety are deterministic and local.
        NSURL *outside = [sandbox URLByAppendingPathComponent:@"do-not-touch"];
        assert([prefix writeToURL:outside atomically:YES]);
        assert(!symlink(outside.fileSystemRepresentation, part.fileSystemRepresentation));
        assert(!SGAutomaticTransferFile(root, row, nil, nil, nil, &reason));
        assert([[NSData dataWithContentsOfURL:outside] isEqual:prefix]);
        assert(!unlink(part.fileSystemRepresentation));
        for (NSUInteger i = 0; i < 4; i++) {
            NSString *name = [[NSString stringWithFormat:@"%064lu", (unsigned long)i] stringByAppendingString:@".part"];
            NSURL *url = [SGTransferTestDirectory URLByAppendingPathComponent:name];
            assert([prefix writeToURL:url atomically:YES]);
            NSDate *date = [NSDate dateWithTimeIntervalSinceNow:i == 0 ? -(SGTransferTTL + 60) : -60 * (4 - i)];
            assert([fm setAttributes:@{NSFileModificationDate:date} ofItemAtPath:url.path error:nil]);
        }
        assert(SGTransferPrune(SGTransferTestDirectory, @"reserved.part", nil, 2048, 6144, 3));
        NSArray *remaining = [fm contentsOfDirectoryAtPath:SGTransferTestDirectory.path error:nil];
        assert(remaining.count == 2);
        assert(([remaining containsObject:[NSString stringWithFormat:@"%064u.part", 3]]));
        for (NSString *name in remaining) assert([fm removeItemAtURL:[SGTransferTestDirectory URLByAppendingPathComponent:name] error:nil]);
        assert([fm removeItemAtURL:SGTransferTestDirectory error:nil]);
        assert(!symlink(sandbox.fileSystemRepresentation, SGTransferTestDirectory.fileSystemRepresentation));
        assert(!SGAutomaticTransferFile(root, row, nil, nil, nil, &reason));
        assert([[NSData dataWithContentsOfURL:outside] isEqual:prefix]);
        assert(!unlink(SGTransferTestDirectory.fileSystemRepresentation));
        assert([fm removeItemAtURL:sandbox error:nil]);
        puts("Resumable companion transfers: PASS (headers, interruption, cancellation, restart, integrity, cache and paths)");
    }
    return 0;
}
#endif
