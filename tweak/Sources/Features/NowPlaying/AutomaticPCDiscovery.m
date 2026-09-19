#import "AutomaticPCDiscovery.h"
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <arpa/inet.h>

static NSString *SGPCHex(const unsigned char *bytes, size_t length) {
    NSMutableString *value = [NSMutableString stringWithCapacity:length * 2];
    for (size_t index = 0; index < length; index++) [value appendFormat:@"%02x", bytes[index]];
    return value;
}

static BOOL SGPCPrivateHost(NSString *host) {
    if (![host isKindOfClass:NSString.class] || !host.length) return NO;
    struct in_addr address;
    if (inet_pton(AF_INET, host.UTF8String, &address) != 1) return NO;
    uint32_t value = ntohl(address.s_addr);
    return (value >> 24) == 10 || (value >> 20) == 0xac1 || (value >> 16) == 0xc0a8;
}

static NSString *SGPCToken(NSURL *root) {
    if (![root.scheme isEqualToString:@"http"] || !SGPCPrivateHost(root.host) ||
        root.user || root.password || root.query || root.fragment ||
        root.port.integerValue < 1024 || root.port.integerValue > 65535) return nil;
    NSString *token = [root.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSCharacterSet *characters = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    return token.length == 32 && [token rangeOfCharacterFromSet:characters.invertedSet].location == NSNotFound ? token : nil;
}

static NSString *SGPCIdentity(NSString *token) {
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return SGPCHex(digest, sizeof(digest));
}

static BOOL SGPCProof(NSDictionary *reply, NSString *token, NSString *nonce, NSString *host, NSInteger port) {
    if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"service"] isEqual:@"spoti-auto-downloads"] ||
        ![reply[@"version"] isEqual:@1] || ![reply[@"nonce"] isEqual:nonce] ||
        ![reply[@"host"] isEqual:host] || ![reply[@"port"] isEqual:@(port)] || !SGPCPrivateHost(host)) return NO;
    NSString *proof = reply[@"proof"];
    if (![proof isKindOfClass:NSString.class] || proof.length != 64) return NO;
    NSData *message = [[NSString stringWithFormat:@"spoti-pc-v1\n%@\n%@\n%ld", nonce, host, (long)port] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *key = [token dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, digest);
    NSData *expected = [SGPCHex(digest, sizeof(digest)) dataUsingEncoding:NSASCIIStringEncoding];
    NSData *actual = [proof dataUsingEncoding:NSASCIIStringEncoding];
    if (actual.length != expected.length) return NO;
    const unsigned char *left = expected.bytes, *right = actual.bytes;
    unsigned char difference = 0;
    for (NSUInteger index = 0; index < expected.length; index++) difference |= left[index] ^ right[index];
    return difference == 0;
}

// Foundation Bonjour works on every supported iOS version. All browse/delegate
// state lives on the main queue; the network challenge never contains the token.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface SGAutomaticPCDiscovery : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate, NSURLSessionDataDelegate>
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) NSString *savedHost;
@property(nonatomic) NSInteger savedPort;
@property(nonatomic, copy) void (^completion)(NSURL *);
@property(nonatomic, strong) NSNetServiceBrowser *browser;
@property(nonatomic, strong) NSMutableArray<NSNetService *> *services;
@property(nonatomic, strong) NSMutableSet<NSString *> *addresses;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary *> *checks;
@property(nonatomic, strong) NSURLSession *session;
- (void)start;
- (void)finish:(NSURL *)root;
- (void)checkHost:(NSString *)host port:(NSInteger)port;
@end

static NSMutableSet<SGAutomaticPCDiscovery *> *SGPCDiscoveries;

@implementation SGAutomaticPCDiscovery
- (void)start {
    self.services = [NSMutableArray array];
    self.addresses = [NSMutableSet set];
    self.checks = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 3;
    configuration.timeoutIntervalForResource = 4;
    configuration.HTTPMaximumConnectionsPerHost = 2;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    self.browser = [NSNetServiceBrowser new];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_spoti-pc._tcp." inDomain:@"local."];
    [self checkHost:self.savedHost port:self.savedPort];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf finish:nil]; });
}
- (void)finish:(NSURL *)root {
    if (!self.completion) return;
    void (^completion)(NSURL *) = self.completion;
    self.completion = nil;
    [self.browser stop]; self.browser.delegate = nil;
    for (NSNetService *service in self.services) { [service stop]; service.delegate = nil; }
    [self.session invalidateAndCancel]; self.session = nil;
    [self.checks removeAllObjects];
    [SGPCDiscoveries removeObject:self];
    completion(root);
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict {
    // A router can block Bonjour while a known private address still works.
    // Keep the direct authenticated challenge alive until the shared deadline.
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    if (!self.completion || self.services.count >= 8) return;
    NSString *prefix = [@"Spoti-PC-" stringByAppendingString:[self.identity substringToIndex:16]];
    if (![service.name hasPrefix:prefix]) return;
    [self.services addObject:service]; service.delegate = self; [service resolveWithTimeout:3];
}
- (void)netServiceDidResolveAddress:(NSNetService *)service {
    if (!self.completion || service.port < 1024 || service.port > 65535) return;
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:service.TXTRecordData ?: [NSData data]];
    if (![[[NSString alloc] initWithData:txt[@"id"] ?: [NSData data] encoding:NSUTF8StringEncoding] isEqual:self.identity]) return;
    for (NSData *data in service.addresses) {
        if (data.length < sizeof(struct sockaddr_in) || self.addresses.count >= 8) continue;
        const struct sockaddr_in *address = data.bytes;
        if (address->sin_family != AF_INET) continue;
        char buffer[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer))) continue;
        NSString *host = [NSString stringWithUTF8String:buffer];
        if (!SGPCPrivateHost(host)) continue;
        [self checkHost:host port:service.port];
    }
}
- (void)checkHost:(NSString *)host port:(NSInteger)port {
    if (!self.completion || self.addresses.count >= 8 || !SGPCPrivateHost(host) || port < 1024 || port > 65535) return;
    NSString *endpoint = [NSString stringWithFormat:@"http://%@:%ld", host, (long)port];
    if ([self.addresses containsObject:endpoint]) return;
    [self.addresses addObject:endpoint];
    NSString *nonce = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/discover?nonce=%@", endpoint, nonce]];
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url];
    self.checks[@(task.taskIdentifier)] = [@{@"host":host, @"port":@(port), @"nonce":nonce, @"data":[NSMutableData data]} mutableCopy];
    [task resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler { completionHandler(nil); }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    BOOL valid = self.completion && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode == 200 && response.expectedContentLength <= 4096;
    completionHandler(valid ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    NSMutableData *body = self.checks[@(task.taskIdentifier)][@"data"];
    if (!body || body.length + data.length > 4096) { [task cancel]; return; }
    [body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSDictionary *check = self.checks[@(task.taskIdentifier)];
    [self.checks removeObjectForKey:@(task.taskIdentifier)];
    if (error || !self.completion || !check) return;
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:check[@"data"] options:0 error:nil];
    if (SGPCProof(reply, self.token, check[@"nonce"], check[@"host"], [check[@"port"] integerValue])) {
        [self finish:[NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/%@/", check[@"host"], check[@"port"], self.token]]];
    }
}
@end
#pragma clang diagnostic pop

void SGAutomaticDiscoverPC(NSURL *pairedRoot, void (^completion)(NSURL *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *token = SGPCToken(pairedRoot);
        if (!token) { completion(nil); return; }
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGPCDiscoveries = [NSMutableSet set]; });
        SGAutomaticPCDiscovery *operation = [SGAutomaticPCDiscovery new];
        operation.token = token; operation.identity = SGPCIdentity(token); operation.completion = completion;
        operation.savedHost = pairedRoot.host; operation.savedPort = pairedRoot.port.integerValue;
        [SGPCDiscoveries addObject:operation]; [operation start];
    });
}

#if SG_AUTOMATIC_PC_DISCOVERY_TEST
int main(void) { @autoreleasepool {
    NSString *token = @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", *nonce = @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    NSCAssert(SGPCToken([NSURL URLWithString:@"http://192.168.1.8:8768/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/"]), @"paired private address");
    NSCAssert(!SGPCToken([NSURL URLWithString:@"http://8.8.8.8:8768/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/"]), @"reject public address");
    NSCAssert(!SGPCToken([NSURL URLWithString:@"http://192.168.1.8:8768/invalid/"]), @"reject invalid credential");
    NSCAssert(!SGPCToken([NSURL URLWithString:@"http:/invalid"]), @"reject absent host");
    NSCAssert([SGPCIdentity(token) isEqual:@"22a48051594c1949deed7040850c1f0f8764537f5191be56732d16a54c1d8153"], @"Python/Apple identity agreement");
    NSMutableDictionary *reply = [@{@"service":@"spoti-auto-downloads", @"version":@1, @"nonce":nonce, @"host":@"192.168.1.8", @"port":@8768,
       @"proof":@"854653b3f76ba6963e2f160e4bcad62a549f74bd6192fdfc80a872c1f7793b32"} mutableCopy];
    NSCAssert(SGPCProof(reply, token, nonce, @"192.168.1.8", 8768), @"Python/Apple challenge agreement");
    NSCAssert(!SGPCProof(reply, token, nonce, @"192.168.1.9", 8768), @"address proof binding");
    NSCAssert(!SGPCProof(reply, token, nonce, @"192.168.1.8", 8769), @"port proof binding");
    NSCAssert(!SGPCProof(reply, token, @"cccccccccccccccccccccccccccccccc", @"192.168.1.8", 8768), @"no replay with new challenge");
    reply[@"proof"] = [@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
    NSCAssert(!SGPCProof(reply, token, nonce, @"192.168.1.8", 8768), @"reject forged discovery");
    NSLog(@"PC discovery identity and authentication tests passed");
    return 0;
} }
#endif
