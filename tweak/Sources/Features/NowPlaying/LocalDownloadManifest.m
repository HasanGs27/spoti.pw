#import "LocalDownloadManifest.h"
#import <arpa/inet.h>
#import <math.h>

static const NSUInteger SGDownloadLimit = 100 * 1024 * 1024;

NSURL *SGDownloadRoot(NSString *text) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    if (![parts.scheme isEqual:@"http"] || parts.user || parts.password || parts.query || parts.fragment ||
        !parts.host.length || parts.port.integerValue < 1024 || parts.port.integerValue > 65535) return nil;
    struct in_addr address;
    if (inet_pton(AF_INET, parts.host.UTF8String, &address) != 1) return nil;
    uint32_t ip = ntohl(address.s_addr);
    if (!((ip >> 24) == 10 || (ip >> 20) == 0xac1 || (ip >> 16) == 0xc0a8)) return nil;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^/[A-Za-z0-9_-]{32}/?$" options:0 error:nil];
    if (![pattern numberOfMatchesInString:parts.path options:0 range:NSMakeRange(0, parts.path.length)]) return nil;
    if (![parts.path hasSuffix:@"/"]) parts.path = [parts.path stringByAppendingString:@"/"];
    return parts.URL;
}

NSArray *SGDownloadManifest(NSData *data) {
    if (!data.length || data.length > 2 * 1024 * 1024) return nil;
    id manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"version"] isEqual:@1]) return nil;
    id rows = manifest[@"tracks"];
    if (![rows isKindOfClass:NSArray.class] || ![rows count] || [rows count] > 500) return nil;
    NSRegularExpression *hash = [NSRegularExpression regularExpressionWithPattern:@"^[a-f0-9]{64}$" options:0 error:nil];
    NSMutableSet *seen = [NSMutableSet set];
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) return nil;
        NSString *ident = row[@"id"], *title = row[@"title"], *artist = row[@"artist"];
        if (![ident isKindOfClass:NSString.class] || ![hash numberOfMatchesInString:ident options:0 range:NSMakeRange(0, ident.length)] ||
            [seen containsObject:ident]) return nil;
        [seen addObject:ident];
        for (id label in @[title ?: NSNull.null, artist ?: NSNull.null])
            if (![label isKindOfClass:NSString.class] || ![label length] || [label length] > 512) return nil;
        NSNumber *bytes = row[@"bytes"], *seconds = row[@"seconds"];
        if (![bytes isKindOfClass:NSNumber.class] || bytes.doubleValue != bytes.unsignedIntegerValue ||
            bytes.unsignedIntegerValue < 1024 || bytes.unsignedIntegerValue > SGDownloadLimit ||
            ![seconds isKindOfClass:NSNumber.class] || !isfinite(seconds.doubleValue) || seconds.doubleValue < 1) return nil;
    }
    return rows;
}

#ifdef SG_LOCAL_DOWNLOAD_MANIFEST_TEST
#include <assert.h>
static NSData *fixture(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }
int main(void) {
    @autoreleasepool {
        NSString *token = @"abcdefghijklmnopqrstuvwx12345678";
        NSString *good = [NSString stringWithFormat:@"http://192.168.1.148:8767/%@/", token];
        assert(SGDownloadRoot(good));
        assert(SGDownloadRoot([good substringToIndex:good.length - 1]));
        for (NSString *bad in @[@"", @"http:///", @"file:///tmp/song.mp3", @"https://example.com/",
            [good stringByReplacingOccurrencesOfString:@"192.168.1.148" withString:@"8.8.8.8"],
            [good stringByReplacingOccurrencesOfString:@"192.168.1.148" withString:@"127.0.0.1"],
            [good stringByReplacingOccurrencesOfString:@"http://" withString:@"http://user:password@"],
            [good stringByAppendingString:@"?token=anything"], [good stringByAppendingString:@"../"],
            [good stringByReplacingOccurrencesOfString:@"8767" withString:@"80"]]) assert(!SGDownloadRoot(bad));
        NSString *sha = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
        NSDictionary *track = @{@"id":sha, @"title":@"Titre", @"artist":@"Artiste", @"bytes":@2048, @"seconds":@180};
        assert(SGDownloadManifest(fixture(@{@"version":@1,@"tracks":@[track]})).count == 1);
        assert(!SGDownloadManifest(fixture(@{@"version":@2,@"tracks":@[track]})));
        assert(!SGDownloadManifest(fixture(@{@"version":@1,@"tracks":@[track,track]})));
        assert(!SGDownloadManifest(fixture(@{@"version":@1,@"tracks":@[]})));
        assert(!SGDownloadManifest([@"html" dataUsingEncoding:NSUTF8StringEncoding]));
        for (NSDictionary *change in @[@{@"id":@"../target"}, @{@"title":@[]}, @{@"artist":@""},
            @{@"bytes":@-1}, @{@"bytes":@2048.5}, @{@"bytes":@(SGDownloadLimit+1)}, @{@"seconds":@0}]) {
            NSMutableDictionary *bad = [track mutableCopy];
            [bad addEntriesFromDictionary:change];
            assert(!SGDownloadManifest(fixture(@{@"version":@1,@"tracks":@[bad]})));
        }
        puts("Local download manifest validation: PASS");
    }
    return 0;
}
#endif
