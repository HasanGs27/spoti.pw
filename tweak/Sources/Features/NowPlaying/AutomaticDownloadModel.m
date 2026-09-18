#import "AutomaticDownloadModel.h"
#import "LocalDownloadManifest.h"
#import <math.h>

static BOOL pattern(NSString *text, NSString *expression) {
    if (![text isKindOfClass:NSString.class]) return NO;
    static NSCache *expressions; static dispatch_once_t once;
    dispatch_once(&once, ^{ expressions = [NSCache new]; expressions.countLimit = 12; });
    NSRegularExpression *regex = [expressions objectForKey:expression];
    if (!regex) { regex = [NSRegularExpression regularExpressionWithPattern:expression options:0 error:nil]; [expressions setObject:regex forKey:expression]; }
    return [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] == 1;
}
static BOOL finiteNumber(id value, double minimum, double maximum) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] >= minimum && [value doubleValue] <= maximum;
}
static NSURL *httpsURL(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 8192) return nil;
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:text];
    if (![url.scheme.lowercaseString isEqual:@"https"] || !url.host.length || url.user || url.password || url.fragment ||
        (url.port && (url.port.integerValue < 1 || url.port.integerValue > 65535))) return nil;
    return url.URL;
}
NSString *SGAutomaticSpotifyURL(id value) {
    NSString *text = [value isKindOfClass:NSURL.class] ? [value absoluteString] : value;
    if (![text isKindOfClass:NSString.class] || text.length > 1000) return nil;
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (pattern(text, @"^spotify:(track|playlist):[A-Za-z0-9]{22}$")) {
        NSArray *parts = [text componentsSeparatedByString:@":"];
        return [NSString stringWithFormat:@"https://open.spotify.com/%@/%@", parts[1], parts[2]];
    }
    NSURLComponents *url = [NSURLComponents componentsWithString:text];
    if (![url.scheme.lowercaseString isEqual:@"https"] || ![url.host.lowercaseString isEqual:@"open.spotify.com"] || url.user || url.password || url.port ||
        !pattern(url.path, @"^/(intl-[A-Za-z-]{2,12}/)?(track|playlist)/[A-Za-z0-9]{22}/?$")) return nil;
    NSString *path = [url.path hasSuffix:@"/"] ? [url.path substringToIndex:url.path.length - 1] : url.path;
    if ([path hasPrefix:@"/intl-"]) path = [path substringFromIndex:[path rangeOfString:@"/" options:0 range:NSMakeRange(1, path.length - 1)].location];
    return [@"https://open.spotify.com" stringByAppendingString:path];
}
static NSDictionary *validatedRow(id row) {
    if (![row isKindOfClass:NSDictionary.class] || !finiteNumber(row[@"position"], 1, 500) ||
        [row[@"position"] doubleValue] != [row[@"position"] unsignedIntegerValue] ||
        ![SGAutomaticSpotifyURL(row[@"spotify"]) containsString:@"/track/"] ||
        ![@[@"waiting", @"running", @"ready", @"error"] containsObject:row[@"state"]]) return nil;
    for (NSString *key in @[@"title", @"artist"])
        if (![row[key] isKindOfClass:NSString.class] || [row[key] length] > 512) return nil;
    BOOL ready = [row[@"state"] isEqual:@"ready"];
    if (ready) {
        if (!pattern(row[@"id"], @"^[a-f0-9]{64}$") || ![row[@"title"] length] || ![row[@"artist"] length] ||
            !finiteNumber(row[@"bytes"], 1024, 100 * 1024 * 1024) || [row[@"bytes"] doubleValue] != [row[@"bytes"] unsignedIntegerValue] ||
            ![row[@"album"] isKindOfClass:NSString.class] || [row[@"album"] length] > 512 ||
            !finiteNumber(row[@"seconds"], 1, 86400)) return nil;
    }
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"position", @"state", @"title", @"artist"]) item[key] = row[key];
    item[@"spotify"] = SGAutomaticSpotifyURL(row[@"spotify"]);
    if (ready) for (NSString *key in @[@"id", @"bytes", @"seconds", @"album"]) item[key] = row[key];
    if (row[@"extension"] && row[@"extension"] != NSNull.null) {
        if (![@[@"mp3", @"m4a"] containsObject:row[@"extension"]]) return nil;
        item[@"extension"] = row[@"extension"];
    }
    // Optional metadata survives retries and restart, but binary artwork stays in memory only.
    for (NSString *key in @[@"expectedTitle", @"expectedArtist", @"sourceID", @"errorMessage", @"sourceKind"]) {
        id value = row[key]; if (!value || value == NSNull.null) continue;
        NSUInteger limit = [key isEqual:@"errorMessage"] ? 2048 : 512;
        if (![value isKindOfClass:NSString.class] || [value length] > limit ||
            ([key isEqual:@"sourceKind"] && !pattern(value, @"^[A-Za-z0-9_-]{1,32}$"))) return nil;
        item[key] = value;
    }
    for (NSString *key in @[@"expectedSeconds", @"progress"]) {
        id value = row[key]; if (!value || value == NSNull.null) continue;
        BOOL progress = [key isEqual:@"progress"];
        if (!finiteNumber(value, progress ? 0 : 1, progress ? 1 : 86400)) return nil;
        item[key] = value;
    }
    if (row[@"expectedArtists"] && row[@"expectedArtists"] != NSNull.null) {
        if (![row[@"expectedArtists"] isKindOfClass:NSArray.class] || [row[@"expectedArtists"] count] > 30) return nil;
        for (id artist in row[@"expectedArtists"])
            if (![artist isKindOfClass:NSString.class] || ![artist length] || [artist length] > 512) return nil;
        item[@"expectedArtists"] = row[@"expectedArtists"];
    }
    for (NSString *key in @[@"coverURL", @"sourceURL"]) {
        id value = row[key]; if (!value || value == NSNull.null || [value isEqual:@""]) continue;
        NSURL *url = [key isEqual:@"sourceURL"] ? SGAutomaticAudioSource(value) : httpsURL(value);
        if (!url) return nil;
        item[key] = url.absoluteString;
    }
    return item;
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
    if (job[@"engine"] && ![@[@"device", @"pc"] containsObject:job[@"engine"]]) return nil;
    if (job[@"completeMetadata"] && (![job[@"completeMetadata"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)job[@"completeMetadata"]) != CFBooleanGetTypeID())) return nil;
    NSUInteger position = 0;
    NSMutableArray *items = [NSMutableArray array];
    for (id row in job[@"items"]) {
        NSDictionary *item = validatedRow(row);
        if (!item || [item[@"position"] unsignedIntegerValue] != ++position) return nil;
        [items addObject:item];
    }
    // Only property-list-safe validated fields enter UserDefaults. The wire object can contain JSON null.
    NSMutableDictionary *result = [@{@"version":@2, @"id":job[@"id"], @"url":SGAutomaticSpotifyURL(job[@"url"]), @"state":job[@"state"],
        @"name":job[@"name"], @"message":job[@"message"], @"scope":job[@"scope"], @"items":items, @"engine":job[@"engine"] ?: @"pc"} mutableCopy];
    if (job[@"completeMetadata"]) result[@"completeMetadata"] = job[@"completeMetadata"];
    return result;
}
NSString *SGAutomaticLocalURI(NSDictionary *row) {
    if (![row isKindOfClass:NSDictionary.class] || ![row[@"state"] isEqual:@"ready"] || !finiteNumber(row[@"seconds"], 1, 86400)) return nil;
    for (NSString *key in @[@"artist", @"album", @"title"])
        if (![row[key] isKindOfClass:NSString.class] || [row[key] length] > 512) return nil;
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:@"spotify", @"local", nil];
    NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    for (NSString *key in @[@"artist", @"album", @"title"])
        [parts addObject:[[row[key] stringByAddingPercentEncodingWithAllowedCharacters:unreserved]
            stringByReplacingOccurrencesOfString:@"%20" withString:@"+"] ?: @""];
    [parts addObject:[NSString stringWithFormat:@"%.0f", floor([row[@"seconds"] doubleValue])]];
    return [parts componentsJoinedByString:@":"];
}

NSURL *SGAutomaticAudioSource(id value) {
    NSURL *url = httpsURL(value);
    if (!url) return nil;
    // A Spotify page identifies a track, but is not an audio download.
    if ([url.host.lowercaseString isEqual:@"spotify.com"] || [url.host.lowercaseString hasSuffix:@".spotify.com"]) return nil;
    return url;
}

NSDictionary *SGAutomaticMergeLocalRows(NSDictionary *job, NSDictionary *localRows) {
    if (!job) return nil;
    NSMutableDictionary *merged = [job mutableCopy];
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *row in job[@"items"]) {
        NSString *identity = SGAutomaticSpotifyURL(row[@"spotify"]);
        NSDictionary *local = identity ? validatedRow(localRows[identity]) : nil;
        if (local && [local[@"state"] isEqual:@"ready"] && [local[@"spotify"] isEqual:identity]) {
            NSMutableDictionary *copy = [local mutableCopy];
            copy[@"position"] = row[@"position"];
            // Duplicate playlist entries keep their order and catalogue metadata; a repair shares only the verified file.
            for (NSString *key in @[@"expectedTitle", @"expectedArtist", @"expectedArtists", @"expectedSeconds", @"coverURL"])
                if (row[key]) copy[key] = row[key];
            [copy removeObjectForKey:@"errorMessage"]; [copy removeObjectForKey:@"progress"];
            [items addObject:copy];
        } else [items addObject:row];
    }
    merged[@"items"] = items;
    return merged;
}

BOOL SGAutomaticDurationMatches(NSDictionary *row, double actualSeconds) {
    if (!isfinite(actualSeconds) || actualSeconds < 1 || actualSeconds > 86400) return NO;
    id expected = row[@"expectedSeconds"];
    if (!expected) return YES; // Older PC jobs did not retain the catalogue duration.
    if (!finiteNumber(expected, 1, 86400)) return NO;
    return fabs(actualSeconds - [expected doubleValue]) <= fmax(3.0, [expected doubleValue] * 0.02);
}

NSString *SGAutomaticRowState(NSDictionary *row, BOOL exists, BOOL active, BOOL failed) {
    if (exists) return @"ready";
    if (active) return @"running";
    if (failed || [row[@"state"] isEqual:@"error"]) return @"error";
    return @"waiting";
}

#ifdef SG_AUTOMATIC_DOWNLOAD_TEST
#include <assert.h>
static NSData *fixture(id value) { return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; }
int main(void) { @autoreleasepool {
    assert(SGAutomaticSpotifyURL(@"spotify:playlist:1Imj2Uc2NVvyHgrAouKQo3"));
    assert([SGAutomaticSpotifyURL(@" https://open.spotify.com/intl-fr/track/3DaGnKmAAmyZGIbC0KjmxT?si=shared ")
        isEqual:@"https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT"]);
    assert(!SGAutomaticSpotifyURL(@"https://open.spotify.com.evil/track/3DaGnKmAAmyZGIbC0KjmxT"));
    assert(!SGAutomaticSpotifyURL(@"spotify:episode:3DaGnKmAAmyZGIbC0KjmxT"));
    assert(!SGAutomaticSpotifyURL(@"https://user@open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT"));
    NSDictionary *row = @{@"state":@"ready",@"artist":@"A+B & C",@"album":@"",@"title":@"T: X",@"seconds":@123.8};
    assert([SGAutomaticLocalURI(row) isEqual:@"spotify:local:A%2BB+%26+C::T%3A+X:123"]);
    assert(!SGAutomaticJob([@"{}" dataUsingEncoding:NSUTF8StringEncoding]));
    assert(SGAutomaticAudioSource(@" https://example.org/download?id=123 "));
    for (id bad in @[@"file:///song.mp3", @"javascript:alert(1)", @"http://example.org/song.mp3", @"https://user:secret@example.org/a", @"https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT", NSNull.null]) assert(!SGAutomaticAudioSource(bad));
    assert([SGAutomaticRowState(@{@"state":@"ready"}, NO, NO, NO) isEqual:@"waiting"]);
    assert([SGAutomaticRowState(@{@"state":@"error"}, YES, NO, YES) isEqual:@"ready"]);
    assert([SGAutomaticRowState(@{@"state":@"error"}, NO, YES, YES) isEqual:@"running"]);
    assert([SGAutomaticRowState(@{}, NO, NO, YES) isEqual:@"error"]);
    NSMutableDictionary *item = [@{@"position":@1, @"state":@"ready", @"title":@"A", @"artist":@"B", @"album":@"",
        @"seconds":@185.8, @"bytes":@2048, @"id":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
        @"spotify":@"https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT"} mutableCopy];
    NSMutableDictionary *job = [@{@"version":@2, @"id":@"0123456789abcdef0123456789abcdef", @"url":item[@"spotify"],
        @"state":@"complete", @"name":@"A", @"message":@"OK", @"scope":@"Un morceau", @"track_urls":NSNull.null, @"items":@[item]} mutableCopy];
    NSDictionary *parsed = SGAutomaticJob(fixture(job));
    assert(parsed && [NSPropertyListSerialization propertyList:parsed isValidForFormat:NSPropertyListBinaryFormat_v1_0]);
    assert([SGAutomaticLocalURI(parsed[@"items"][0]) isEqual:@"spotify:local:B::A:185"]);
    item[@"extension"] = @"m4a";
    assert([SGAutomaticJob(fixture(job))[@"items"][0][@"extension"] isEqual:@"m4a"]);
    item[@"extension"] = @"../mp3"; assert(!SGAutomaticJob(fixture(job))); [item removeObjectForKey:@"extension"];
    NSMutableDictionary *repair = [item mutableCopy]; repair[@"position"] = @9; repair[@"title"] = @"Repaired";
    NSDictionary *merged = SGAutomaticMergeLocalRows(parsed, @{item[@"spotify"]:repair});
    assert([merged[@"items"][0][@"position"] isEqual:@1] && [merged[@"items"][0][@"title"] isEqual:@"Repaired"]);
    assert([SGAutomaticMergeLocalRows(parsed, @{}) isEqual:parsed]);
    repair[@"spotify"] = @"https://open.spotify.com/track/4DNTHdu4F7eTNuhyLQvEzG";
    assert([SGAutomaticMergeLocalRows(parsed, @{item[@"spotify"]:repair}) isEqual:parsed]);
    repair[@"spotify"] = item[@"spotify"];
    item[@"spotify"] = @"spotify:track:3DaGnKmAAmyZGIbC0KjmxT";
    item[@"expectedTitle"] = @"Catalogue title"; item[@"expectedArtist"] = @"Catalogue artist";
    item[@"expectedArtists"] = @[@"Artist & Band", @"Guest"];
    item[@"expectedSeconds"] = @185; item[@"coverURL"] = @"https://i.scdn.co/image/cover";
    item[@"sourceURL"] = @"https://example.org/audio?id=signed"; item[@"sourceKind"] = @"direct"; item[@"sourceID"] = @"file-1";
    item[@"progress"] = @0.5; item[@"errorMessage"] = @"Try again";
    job[@"engine"] = @"device"; job[@"completeMetadata"] = @NO;
    NSDictionary *native = SGAutomaticJob(fixture(job));
    assert([native[@"engine"] isEqual:@"device"] && [native[@"completeMetadata"] isEqual:@NO]);
    NSDictionary *nativeRow = native[@"items"][0];
    assert([nativeRow[@"spotify"] isEqual:repair[@"spotify"]] && [nativeRow[@"expectedSeconds"] isEqual:@185]);
    assert([nativeRow[@"coverURL"] isEqual:item[@"coverURL"]] && [nativeRow[@"sourceID"] isEqual:@"file-1"]);
    assert([nativeRow[@"expectedArtists"] isEqual:item[@"expectedArtists"]]);
    NSData *persisted = [NSPropertyListSerialization dataWithPropertyList:native format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    id reloaded = [NSPropertyListSerialization propertyListWithData:persisted options:0 format:NULL error:nil];
    assert([SGAutomaticJob(fixture(reloaded)) isEqual:native]);
    NSMutableDictionary *second = [nativeRow mutableCopy]; second[@"position"] = @2;
    job[@"items"] = @[nativeRow, second];
    NSDictionary *duplicates = SGAutomaticMergeLocalRows(SGAutomaticJob(fixture(job)), @{repair[@"spotify"]:repair});
    assert([duplicates[@"items"] count] == 2 && [duplicates[@"items"][1][@"position"] isEqual:@2]);
    assert([duplicates[@"items"][1][@"expectedTitle"] isEqual:@"Catalogue title"] && !duplicates[@"items"][1][@"errorMessage"]);
    assert(SGAutomaticDurationMatches(nativeRow, 188) && !SGAutomaticDurationMatches(nativeRow, 200));
    assert(!SGAutomaticDurationMatches(nativeRow, NAN) && SGAutomaticDurationMatches(@{}, 185));
    job[@"items"] = @[item];
    item[@"progress"] = @1.1; assert(!SGAutomaticJob(fixture(job))); item[@"progress"] = @0;
    item[@"expectedArtists"] = @[@"Artist", @42]; assert(!SGAutomaticJob(fixture(job))); [item removeObjectForKey:@"expectedArtists"];
    item[@"sourceURL"] = @"https://user:password@example.org/file"; assert(!SGAutomaticJob(fixture(job))); [item removeObjectForKey:@"sourceURL"];
    item[@"position"] = @1.5; assert(!SGAutomaticJob(fixture(job))); item[@"position"] = @1;
    item[@"bytes"] = @(-1); assert(!SGAutomaticJob(fixture(job))); item[@"bytes"] = @2048;
    item[@"id"] = @"../test"; assert(!SGAutomaticJob(fixture(job)));
    item[@"state"] = @"error"; assert(SGAutomaticJob(fixture(job)));
    job[@"items"] = @[item, item]; assert(!SGAutomaticJob(fixture(job)));
    job[@"items"] = @[]; job[@"name"] = NSNull.null; assert(!SGAutomaticJob(fixture(job)));
    puts("Automatic download model: PASS");
} return 0; }
#endif
