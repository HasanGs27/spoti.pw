#import "AudioVariantModel.h"
#import "AutomaticDownloadModel.h"
#import <math.h>

static BOOL match(id value, NSString *pattern) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSRange range = [value rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == [value length];
}
static BOOL speed(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [@[@0.75, @1.25, @1.5, @2] containsObject:value];
}
static NSDictionary *identity(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !match(value[@"source_id"], @"^[a-f0-9]{64}$")) return nil;
    NSString *url = SGAutomaticSpotifyURL(value[@"spotify"]);
    if (![url hasPrefix:@"https://open.spotify.com/track/"]) return nil;
    NSMutableDictionary *result = [@{@"source_id":value[@"source_id"], @"spotify":url} mutableCopy];
    if ([value[@"kind"] isEqual:@"speed"] && speed(value[@"speed"])) {
        result[@"kind"] = @"speed"; result[@"speed"] = value[@"speed"];
    } else if ([value[@"kind"] isEqual:@"instrumental"] && !value[@"speed"]) result[@"kind"] = @"instrumental";
    else return nil;
    return result;
}
NSDictionary *SGAudioVariantRequest(id value) {
    NSMutableDictionary *result = [identity(value) mutableCopy];
    if (!result || !match(value[@"request_id"], @"^[A-Za-z0-9-]{16,64}$")) return nil;
    result[@"request_id"] = value[@"request_id"]; return [result copy];
}
NSDictionary *SGAudioVariantReadyRow(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *row = [value mutableCopy]; row[@"position"] = @1;
    NSString *url = SGAutomaticSpotifyURL(row[@"spotify"]);
    if (!url) return nil;
    NSDictionary *wrapper = @{@"version":@2, @"id":@"00000000000000000000000000000000", @"url":url,
        @"name":@"", @"message":@"", @"scope":@"", @"state":@"complete", @"items":@[row]};
    if (![NSJSONSerialization isValidJSONObject:wrapper]) return nil;
    NSDictionary *job = SGAutomaticJob([NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil]);
    row = [[job[@"items"] firstObject] mutableCopy];
    if (![row[@"state"] isEqual:@"ready"]) return nil;
    // Catalogue expectations describe the original, not this derived recording.
    for (NSString *key in @[@"expectedTitle", @"expectedArtist", @"expectedArtists", @"expectedSeconds"])
        [row removeObjectForKey:key];
    row[@"expectedTitle"] = row[@"title"]; row[@"expectedArtist"] = row[@"artist"];
    row[@"expectedSeconds"] = row[@"seconds"];
    return [row copy];
}
NSDictionary *SGAudioVariantJob(id value, NSDictionary *request) {
    NSDictionary *target = identity(value);
    if (!target || ![value[@"version"] isEqual:@1] || !match(value[@"id"], @"^[a-f0-9]{32}$") ||
        ![@[@"queued", @"running", @"ready", @"error", @"interrupted"] containsObject:value[@"state"]] ||
        ![value[@"message"] isKindOfClass:NSString.class] || [value[@"message"] length] > 4096) return nil;
    if (request && ![target isEqual:identity(request)]) return nil;
    NSMutableDictionary *job = [target mutableCopy];
    for (NSString *key in @[@"version", @"id", @"state", @"message"]) job[key] = value[key];
    if ([job[@"state"] isEqual:@"ready"]) {
        NSDictionary *row = SGAudioVariantReadyRow(value[@"row"]);
        if (!row || ![row[@"spotify"] isEqual:job[@"spotify"]] || [row[@"id"] isEqual:job[@"source_id"]]) return nil;
        job[@"row"] = row;
    }
    return [job copy];
}
NSDictionary *SGAudioVariantListing(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"version"] isEqual:@1] ||
        ![value[@"capabilities"] isKindOfClass:NSDictionary.class] ||
        ![value[@"jobs"] isKindOfClass:NSArray.class] || [value[@"jobs"] count] > 200) return nil;
    NSDictionary *caps = value[@"capabilities"];
    if (![caps[@"speeds"] isKindOfClass:NSArray.class] || [caps[@"speeds"] count] > 4 ||
        ![caps[@"instrumental"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)caps[@"instrumental"]) != CFBooleanGetTypeID()) return nil;
    NSMutableArray *speeds = [NSMutableArray array], *jobs = [NSMutableArray array];
    for (id rate in caps[@"speeds"]) { if (!speed(rate) || [speeds containsObject:rate]) return nil; [speeds addObject:rate]; }
    for (id valueJob in value[@"jobs"]) { NSDictionary *job = SGAudioVariantJob(valueJob, nil); if (!job) return nil; [jobs addObject:job]; }
    return @{@"capabilities":@{@"speeds":speeds, @"instrumental":caps[@"instrumental"]}, @"jobs":jobs};
}
NSString *SGAudioVariantKey(NSDictionary *request) {
    NSDictionary *validated = identity(request); if (!validated) return nil;
    return [NSString stringWithFormat:@"%@|%@|%@|%@", validated[@"source_id"], validated[@"spotify"],
        validated[@"kind"], validated[@"speed"] ?: @""];
}
NSString *SGAudioVariantLabel(NSDictionary *request) {
    if ([request[@"kind"] isEqual:@"instrumental"]) return @"Sans voix";
    NSString *rate = [request[@"speed"] stringValue] ?: @"";
    return [@"Vitesse ×" stringByAppendingString:[rate stringByReplacingOccurrencesOfString:@"." withString:@","]];
}
NSArray<NSDictionary *> *SGAudioVariantRecords(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count] > 80) return @[];
    NSMutableArray *records = [NSMutableArray array]; NSMutableSet *keys = [NSMutableSet set];
    for (id entry in value) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *request = SGAudioVariantRequest(entry[@"request"]); NSString *key = SGAudioVariantKey(request);
        if (!request || [keys containsObject:key]) continue;
        NSMutableDictionary *record = [@{@"request":request, @"paused":@([entry[@"paused"] isEqual:@YES])} mutableCopy];
        NSDictionary *job = SGAudioVariantJob(entry[@"job"], request);
        if (job) record[@"job"] = job;
        NSDictionary *installed = SGAudioVariantReadyRow(entry[@"installed"]), *ready = job[@"row"];
        if (installed && ready && [installed[@"spotify"] isEqual:ready[@"spotify"]] &&
            [installed[@"title"] isEqual:ready[@"title"]] && [installed[@"artist"] isEqual:ready[@"artist"]] &&
            [installed[@"album"] isEqual:ready[@"album"]] && fabs([installed[@"seconds"] doubleValue] - [ready[@"seconds"] doubleValue]) <= .5 &&
            match(entry[@"stamp"], @"^[0-9:.-]{1,256}$")) {
            record[@"installed"] = installed; record[@"stamp"] = entry[@"stamp"];
        }
        if ([entry[@"error"] isKindOfClass:NSString.class] && [entry[@"error"] length] <= 1024) record[@"error"] = entry[@"error"];
        [records addObject:[record copy]]; [keys addObject:key];
    }
    return [records copy];
}

NSArray<NSDictionary *> *SGAudioVariantStoreRecord(id entries, NSDictionary *entry) {
    NSArray *single = SGAudioVariantRecords(entry ? @[entry] : @[]);
    if (single.count != 1) return nil;
    NSDictionary *record = single.firstObject;
    NSString *key = SGAudioVariantKey(record[@"request"]);
    NSMutableArray *records = [SGAudioVariantRecords(entries) mutableCopy];
    NSUInteger existing = [records indexOfObjectPassingTest:^BOOL(NSDictionary *value, NSUInteger idx, BOOL *stop) {
        return [SGAudioVariantKey(value[@"request"]) isEqual:key];
    }];
    if (existing != NSNotFound) [records removeObjectAtIndex:existing];
    while (records.count >= 80) {
        NSUInteger oldest = [records indexOfObjectPassingTest:^BOOL(NSDictionary *value, NSUInteger idx, BOOL *stop) {
            return value[@"installed"] != nil || [@[@"error", @"interrupted"] containsObject:value[@"job"][@"state"] ?: @""];
        }];
        if (oldest == NSNotFound) return nil;
        [records removeObjectAtIndex:oldest];
    }
    [records addObject:record];
    return [records copy];
}

#ifdef SG_AUDIO_VARIANT_TEST
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSString *url = @"https://open.spotify.com/track/0123456789012345678901";
        NSString *hash = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
        NSString *derivedHash = [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
        NSDictionary *request = SGAudioVariantRequest(@{@"request_id":NSUUID.UUID.UUIDString,@"source_id":hash,@"spotify":url,@"kind":@"speed",@"speed":@1.25});
        assert(request);
        NSMutableDictionary *bad = [request mutableCopy]; bad[@"speed"] = @YES; assert(!SGAudioVariantRequest(bad));
        bad[@"speed"] = @3; assert(!SGAudioVariantRequest(bad)); bad = [request mutableCopy]; bad[@"source_id"] = [hash stringByAppendingString:@"\n"]; assert(!SGAudioVariantRequest(bad));
        NSDictionary *row = @{@"spotify":url,@"state":@"ready",@"position":@1,@"id":derivedHash,@"bytes":@2048,@"seconds":@144,
            @"title":@"Titre (×1,25)",@"artist":@"Artiste",@"album":@"Album · Vitesse ×1,25",@"expectedTitle":@"Titre",@"expectedSeconds":@180};
        NSDictionary *job = @{@"version":@1,@"id":@"00000000000000000000000000000000",@"state":@"ready",@"message":@"",@"kind":@"speed",@"speed":@1.25,@"source_id":hash,@"spotify":url,@"row":row};
        NSDictionary *valid = SGAudioVariantJob(job, request); assert(valid);
        assert([valid[@"row"][@"expectedTitle"] isEqual:row[@"title"]] && [valid[@"row"][@"expectedSeconds"] isEqual:@144]);
        bad = [request mutableCopy]; bad[@"source_id"] = derivedHash; assert(!SGAudioVariantJob(job,bad));
        NSMutableDictionary *badJob = [job mutableCopy]; NSMutableDictionary *badRow = [row mutableCopy]; badRow[@"id"] = hash; badJob[@"row"] = badRow; assert(!SGAudioVariantJob(badJob,request));
        NSArray *records = SGAudioVariantRecords(@[@{@"request":request,@"job":job,@"paused":@YES}]);
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:records format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        assert([records isEqual:SGAudioVariantRecords([NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:nil])]);
        assert([records[0][@"request"][@"request_id"] isEqual:request[@"request_id"]] && [records[0][@"paused"] boolValue]);
        assert(SGAudioVariantListing(@{@"version":@1,@"capabilities":@{@"speeds":@[@0.75,@1.25,@1.5,@2],@"instrumental":@NO},@"jobs":@[job]}));
        assert(!SGAudioVariantListing(@{@"version":@1,@"capabilities":@{@"speeds":@[@1.25],@"instrumental":@1},@"jobs":@[]}));
        NSMutableArray *full = [NSMutableArray array];
        for (NSUInteger index = 0; index < 80; index++) {
            NSMutableDictionary *pending = [request mutableCopy]; pending[@"source_id"] = [NSString stringWithFormat:@"%064lu", (unsigned long)index];
            [full addObject:@{@"request":pending,@"paused":@YES}];
        }
        NSDictionary *newEntry = @{@"request":request,@"paused":@NO};
        assert(!SGAudioVariantStoreRecord(full, newEntry)); // All 80 are durable pending requests.
        NSMutableDictionary *finished = [job mutableCopy];
        finished[@"source_id"] = full[0][@"request"][@"source_id"]; finished[@"state"] = @"interrupted";
        full[0] = @{@"request":full[0][@"request"],@"job":finished,@"paused":@YES};
        NSArray *pruned = SGAudioVariantStoreRecord(full, newEntry);
        assert(pruned.count == 80 && [pruned[0][@"request"] isEqual:full[1][@"request"]]);
        assert([pruned.lastObject[@"request"] isEqual:request]);
        puts("Audio variants model: PASS");
    }
    return 0;
}
#endif
