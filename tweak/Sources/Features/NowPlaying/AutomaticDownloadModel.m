#import "AutomaticDownloadModel.h"
#import "LocalDownloadManifest.h"
#import <math.h>

static BOOL pattern(NSString *text, NSString *expression) {
    if (![text isKindOfClass:NSString.class]) return NO;
    return [[NSRegularExpression regularExpressionWithPattern:expression options:0 error:nil]
        numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] == 1;
}
NSString *SGAutomaticSpotifyURL(id value) {
    NSString *text = [value isKindOfClass:NSURL.class] ? [value absoluteString] : value;
    if (![text isKindOfClass:NSString.class] || text.length > 1000) return nil;
    if (pattern(text, @"^spotify:(track|playlist):[A-Za-z0-9]{22}$")) {
        NSArray *parts = [text componentsSeparatedByString:@":"];
        return [NSString stringWithFormat:@"https://open.spotify.com/%@/%@", parts[1], parts[2]];
    }
    NSURLComponents *url = [NSURLComponents componentsWithString:text];
    if (![url.scheme isEqual:@"https"] || ![url.host isEqual:@"open.spotify.com"] || url.user || url.password || url.port ||
        !pattern(url.path, @"^/(track|playlist)/[A-Za-z0-9]{22}/?$")) return nil;
    NSString *path = [url.path hasSuffix:@"/"] ? [url.path substringToIndex:url.path.length - 1] : url.path;
    return [@"https://open.spotify.com" stringByAppendingString:path];
}
NSDictionary *SGAutomaticJob(NSData *data) {
    if (!data.length || data.length > 2 * 1024 * 1024) return nil;
    id job = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![job isKindOfClass:NSDictionary.class] || ![job[@"version"] isEqual:@2] ||
        !pattern(job[@"id"], @"^[a-f0-9]{32}$") || !SGAutomaticSpotifyURL(job[@"url"])) return nil;
    NSArray *states = @[@"queued", @"resolving", @"running", @"complete", @"partial", @"error", @"interrupted"];
    if (![states containsObject:job[@"state"]] || ![job[@"items"] isKindOfClass:NSArray.class] || [job[@"items"] count] > 500) return nil;
    for (NSString *key in @[@"name", @"message", @"scope"])
        if (![job[key] isKindOfClass:NSString.class] || [job[key] length] > 4096) return nil;
    NSUInteger position = 0;
    NSMutableArray *items = [NSMutableArray array];
    for (id row in job[@"items"]) {
        if (![row isKindOfClass:NSDictionary.class] || ![row[@"position"] isKindOfClass:NSNumber.class] ||
            [row[@"position"] doubleValue] != ++position ||
            ![SGAutomaticSpotifyURL(row[@"spotify"]) containsString:@"/track/"] ||
            ![@[@"waiting", @"running", @"ready", @"error"] containsObject:row[@"state"]]) return nil;
        for (NSString *key in @[@"title", @"artist"])
            if (![row[key] isKindOfClass:NSString.class] || [row[key] length] > 512) return nil;
        if ([row[@"state"] isEqual:@"ready"]) {
            NSData *single = [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"tracks":@[row]} options:0 error:nil];
            if (!SGDownloadManifest(single) || ![row[@"album"] isKindOfClass:NSString.class] || [row[@"album"] length] > 512) return nil;
        }
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"position", @"state", @"spotify", @"title", @"artist"])
            item[key] = row[key];
        if ([row[@"state"] isEqual:@"ready"])
            for (NSString *key in @[@"id", @"bytes", @"seconds", @"album"]) item[key] = row[key];
        [items addObject:item];
    }
    // Only property-list-safe validated fields enter UserDefaults. The wire object can contain JSON null.
    return @{@"version":@2, @"id":job[@"id"], @"url":SGAutomaticSpotifyURL(job[@"url"]), @"state":job[@"state"],
        @"name":job[@"name"], @"message":job[@"message"], @"scope":job[@"scope"], @"items":items};
}
NSString *SGAutomaticLocalURI(NSDictionary *row) {
    if (![row[@"state"] isEqual:@"ready"]) return nil;
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:@"spotify", @"local", nil];
    NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    for (NSString *key in @[@"artist", @"album", @"title"])
        [parts addObject:[[row[key] stringByAddingPercentEncodingWithAllowedCharacters:unreserved]
            stringByReplacingOccurrencesOfString:@"%20" withString:@"+"] ?: @""];
    [parts addObject:[NSString stringWithFormat:@"%.0f", floor([row[@"seconds"] doubleValue])]];
    return [parts componentsJoinedByString:@":"];
}

#ifdef SG_AUTOMATIC_DOWNLOAD_TEST
#include <assert.h>
static NSData *fixture(id value) { return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; }
int main(void) { @autoreleasepool {
    assert(SGAutomaticSpotifyURL(@"spotify:playlist:1Imj2Uc2NVvyHgrAouKQo3"));
    assert(!SGAutomaticSpotifyURL(@"https://open.spotify.com.evil/track/3DaGnKmAAmyZGIbC0KjmxT"));
    assert(!SGAutomaticSpotifyURL(@"spotify:episode:3DaGnKmAAmyZGIbC0KjmxT"));
    assert(!SGAutomaticSpotifyURL(@"https://user@open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT"));
    NSDictionary *row = @{@"state":@"ready",@"artist":@"A+B & C",@"album":@"",@"title":@"T: X",@"seconds":@123.8};
    assert([SGAutomaticLocalURI(row) isEqual:@"spotify:local:A%2BB+%26+C::T%3A+X:123"]);
    assert(!SGAutomaticJob([@"{}" dataUsingEncoding:NSUTF8StringEncoding]));
    NSMutableDictionary *item = [@{@"position":@1, @"state":@"ready", @"title":@"A", @"artist":@"B", @"album":@"",
        @"seconds":@185.8, @"bytes":@2048, @"id":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
        @"spotify":@"https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT"} mutableCopy];
    NSMutableDictionary *job = [@{@"version":@2, @"id":@"0123456789abcdef0123456789abcdef", @"url":item[@"spotify"],
        @"state":@"complete", @"name":@"A", @"message":@"OK", @"scope":@"Un morceau", @"track_urls":NSNull.null, @"items":@[item]} mutableCopy];
    NSDictionary *parsed = SGAutomaticJob(fixture(job));
    assert(parsed && [NSPropertyListSerialization propertyList:parsed isValidForFormat:NSPropertyListBinaryFormat_v1_0]);
    assert([SGAutomaticLocalURI(parsed[@"items"][0]) isEqual:@"spotify:local:B::A:185"]);
    item[@"position"] = @1.5; assert(!SGAutomaticJob(fixture(job))); item[@"position"] = @1;
    item[@"bytes"] = @(-1); assert(!SGAutomaticJob(fixture(job))); item[@"bytes"] = @2048;
    item[@"id"] = @"../test"; assert(!SGAutomaticJob(fixture(job)));
    item[@"state"] = @"error"; assert(SGAutomaticJob(fixture(job)));
    job[@"items"] = @[item, item]; assert(!SGAutomaticJob(fixture(job)));
    job[@"items"] = @[]; job[@"name"] = NSNull.null; assert(!SGAutomaticJob(fixture(job)));
    puts("Automatic download model: PASS");
} return 0; }
#endif
