#import "AudioVariantModel.h"
#import "AutomaticDownloadModel.h"
#import "LocalImportModel.h"
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
static BOOL number(id value, double minimum, double maximum) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] >= minimum && [value doubleValue] <= maximum;
}
static BOOL boolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static NSDictionary *identity(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !match(value[@"source_id"], @"^[a-f0-9]{64}$")) return nil;
    NSMutableDictionary *result = [@{@"source_id":value[@"source_id"]} mutableCopy];
    if (value[@"source_local_id"]) {
        if (value[@"spotify"] || !match(value[@"source_local_id"], @"^[a-f0-9]{32}$")) return nil;
        result[@"source_local_id"] = value[@"source_local_id"];
    } else {
        NSString *url = SGAutomaticSpotifyURL(value[@"spotify"]);
        if (![url hasPrefix:@"https://open.spotify.com/track/"]) return nil;
        result[@"spotify"] = url;
    }
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
    if (value[@"local_id"] || value[@"source_local_id"]) {
        if (value[@"spotify"] || ![value[@"state"] isEqual:@"ready"] ||
            !match(value[@"id"], @"^[a-f0-9]{64}$") || !match(value[@"local_id"], @"^[a-f0-9]{32}$") ||
            !match(value[@"source_id"], @"^[a-f0-9]{64}$") || !match(value[@"source_local_id"], @"^[a-f0-9]{32}$") ||
            [value[@"local_id"] isEqual:value[@"source_local_id"]] || [value[@"id"] isEqual:value[@"source_id"]] ||
            ![@[@"mp3", @"m4a"] containsObject:value[@"extension"] ?: @""] ||
            !number(value[@"bytes"], 1024, 100 * 1024 * 1024) || [value[@"bytes"] doubleValue] != floor([value[@"bytes"] doubleValue]) ||
            !number(value[@"seconds"], 1, 2701)) return nil;
        BOOL rate = [value[@"variant_kind"] isEqual:@"speed"];
        if (!(rate ? speed(value[@"variant_speed"]) : [value[@"variant_kind"] isEqual:@"instrumental"] && !value[@"variant_speed"])) return nil;
        NSURL *source = SGLocalImportSource(value[@"source_url"]);
        if (!source) return nil;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"title", @"artist", @"album"]) {
            id label = value[key];
            if (![label isKindOfClass:NSString.class] || ![label length] || [label length] > 512 ||
                [label rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
            row[key] = label;
        }
        for (NSString *key in @[@"state", @"id", @"local_id", @"source_id", @"source_local_id", @"bytes", @"seconds", @"extension", @"variant_kind"])
            row[key] = value[key];
        if (rate) row[@"variant_speed"] = value[@"variant_speed"];
        row[@"position"] = @1; row[@"source_url"] = source.absoluteString; row[@"sourceURL"] = source.absoluteString;
        NSString *host = source.host.lowercaseString;
        row[@"sourceKind"] = [host isEqual:@"www.youtube.com"] ? @"youtube" : @"direct";
        row[@"expectedTitle"] = row[@"title"]; row[@"expectedArtist"] = row[@"artist"]; row[@"expectedSeconds"] = row[@"seconds"];
        return [row copy];
    }
    NSMutableDictionary *row = [value mutableCopy]; row[@"position"] = @1;
    NSString *url = SGAutomaticSpotifyURL(row[@"spotify"]);
    if (!url) return nil;
    NSDictionary *wrapper = @{@"version":@2, @"id":@"00000000000000000000000000000000", @"url":url,
        @"name":@"", @"message":@"", @"scope":@"", @"state":@"complete", @"items":@[row]};
    if (![NSJSONSerialization isValidJSONObject:wrapper]) return nil;
    NSDictionary *job = SGAutomaticJob([NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil]);
    row = [[job[@"items"] firstObject] mutableCopy];
    if (![row[@"state"] isEqual:@"ready"]) return nil;
    // Older catalogue responses omit these annotations. Keep them when present
    // so a derived copy cannot later masquerade as its original recording.
    if (value[@"variant_kind"] || value[@"variant_speed"]) {
        BOOL rate = [value[@"variant_kind"] isEqual:@"speed"];
        if (!(rate ? speed(value[@"variant_speed"]) : [value[@"variant_kind"] isEqual:@"instrumental"] && !value[@"variant_speed"])) return nil;
        row[@"variant_kind"] = value[@"variant_kind"];
        if (rate) row[@"variant_speed"] = value[@"variant_speed"];
    }
    // Catalogue expectations describe the original, not this derived recording.
    for (NSString *key in @[@"expectedTitle", @"expectedArtist", @"expectedArtists", @"expectedSeconds"])
        [row removeObjectForKey:key];
    row[@"expectedTitle"] = row[@"title"]; row[@"expectedArtist"] = row[@"artist"];
    row[@"expectedSeconds"] = row[@"seconds"];
    return [row copy];
}
NSDictionary *SGAudioVariantSourceRow(id value) {
    if (![value isKindOfClass:NSDictionary.class] || value[@"variant_kind"] || value[@"variant_speed"] ||
        value[@"source_local_id"] || value[@"source_id"]) return nil;
    return value[@"local_id"] ? SGLocalImportReadyRow(value) : SGAudioVariantReadyRow(value);
}
BOOL SGAudioVariantMatchesSource(NSDictionary *request, NSDictionary *sourceRow) {
    // The page validates its source once. Comparing listing/history identities
    // should not serialize that entire row again for every server job.
    NSDictionary *validated = identity(request);
    if (!validated || ![sourceRow isKindOfClass:NSDictionary.class] ||
        sourceRow[@"variant_kind"] || sourceRow[@"variant_speed"] || sourceRow[@"source_id"] || sourceRow[@"source_local_id"] ||
        ![validated[@"source_id"] isEqual:sourceRow[@"id"]]) return NO;
    if (sourceRow[@"local_id"]) return !sourceRow[@"spotify"] &&
        [validated[@"source_local_id"] isEqual:sourceRow[@"local_id"]];
    return [validated[@"spotify"] isEqual:SGAutomaticSpotifyURL(sourceRow[@"spotify"])];
}
NSDictionary *SGAudioVariantJob(id value, NSDictionary *request) {
    NSDictionary *target = identity(value);
    if (!target || !number(value[@"version"], 1, 1) || !match(value[@"id"], @"^[a-f0-9]{32}$") ||
        ![@[@"queued", @"running", @"ready", @"error", @"interrupted"] containsObject:value[@"state"]] ||
        ![value[@"message"] isKindOfClass:NSString.class] || [value[@"message"] length] > 4096) return nil;
    if (request && ![target isEqual:identity(request)]) return nil;
    NSMutableDictionary *job = [target mutableCopy];
    for (NSString *key in @[@"version", @"id", @"state", @"message"]) job[key] = value[key];
    if ([job[@"state"] isEqual:@"ready"]) {
        NSDictionary *row = SGAudioVariantReadyRow(value[@"row"]);
        if (!row || [row[@"id"] isEqual:job[@"source_id"]]) return nil;
        if (job[@"source_local_id"]) {
            if (row[@"spotify"] || ![row[@"local_id"] isEqual:job[@"id"]] ||
                ![row[@"source_local_id"] isEqual:job[@"source_local_id"]] || ![row[@"source_id"] isEqual:job[@"source_id"]] ||
                ![row[@"variant_kind"] isEqual:job[@"kind"]] ||
                (job[@"speed"] && ![row[@"variant_speed"] isEqual:job[@"speed"]])) return nil;
        } else if (![row[@"spotify"] isEqual:job[@"spotify"]] || row[@"local_id"]) return nil;
        if (row[@"variant_kind"] && (![row[@"variant_kind"] isEqual:job[@"kind"]] ||
            (job[@"speed"] && ![row[@"variant_speed"] isEqual:job[@"speed"]]))) return nil;
        job[@"row"] = row;
    }
    return [job copy];
}
NSDictionary *SGAudioVariantListing(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !number(value[@"version"], 1, 1) ||
        ![value[@"capabilities"] isKindOfClass:NSDictionary.class] ||
        ![value[@"jobs"] isKindOfClass:NSArray.class] || [value[@"jobs"] count] > 200) return nil;
    NSDictionary *caps = value[@"capabilities"];
    if (![caps[@"speeds"] isKindOfClass:NSArray.class] || [caps[@"speeds"] count] > 4 ||
        !boolean(caps[@"instrumental"]) || (caps[@"localSources"] && !boolean(caps[@"localSources"]))) return nil;
    NSMutableArray *speeds = [NSMutableArray array], *jobs = [NSMutableArray array];
    for (id rate in caps[@"speeds"]) { if (!speed(rate) || [speeds containsObject:rate]) return nil; [speeds addObject:rate]; }
    for (id valueJob in value[@"jobs"]) { NSDictionary *job = SGAudioVariantJob(valueJob, nil); if (!job) return nil; [jobs addObject:job]; }
    return @{@"capabilities":@{@"speeds":speeds, @"instrumental":caps[@"instrumental"], @"localSources":caps[@"localSources"] ?: @NO}, @"jobs":jobs};
}
NSString *SGAudioVariantKey(NSDictionary *request) {
    NSDictionary *validated = identity(request); if (!validated) return nil;
    NSString *source = validated[@"spotify"] ?: [@"local:" stringByAppendingString:validated[@"source_local_id"]];
    return [NSString stringWithFormat:@"%@|%@|%@|%@", validated[@"source_id"], source,
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
        BOOL sameSource = ready[@"source_local_id"] ?
            [installed[@"local_id"] isEqual:ready[@"local_id"]] && [installed[@"source_id"] isEqual:ready[@"source_id"]] &&
            [installed[@"source_local_id"] isEqual:ready[@"source_local_id"]] && [installed[@"variant_kind"] isEqual:ready[@"variant_kind"]] &&
            (!ready[@"variant_speed"] || [installed[@"variant_speed"] isEqual:ready[@"variant_speed"]]) &&
            [installed[@"source_url"] isEqual:ready[@"source_url"]] : [installed[@"spotify"] isEqual:ready[@"spotify"]];
        if (installed && ready && sameSource &&
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
        // A personal source has its own identity and must never borrow a
        // catalogue association, even when its file bytes happen to match.
        NSString *localID = @"11111111111111111111111111111111";
        NSString *variantID = @"22222222222222222222222222222222";
        NSString *otherID = @"33333333333333333333333333333333";
        NSDictionary *personalSource = @{@"state":@"ready", @"local_id":localID, @"id":hash,
            @"bytes":@2048, @"seconds":@1800, @"extension":@"m4a", @"title":@"Mon morceau",
            @"artist":@"Mon artiste", @"album":@"Mes imports", @"source_url":@"https://www.youtube.com/watch?v=abcdefghijk"};
        NSDictionary *personalRequest = SGAudioVariantRequest(@{@"request_id":NSUUID.UUID.UUIDString, @"source_id":hash,
            @"source_local_id":localID, @"kind":@"speed", @"speed":@0.75});
        assert(personalRequest && !personalRequest[@"spotify"] && SGAudioVariantSourceRow(personalSource));
        assert(SGAudioVariantMatchesSource(personalRequest, personalSource));
        assert(!SGAudioVariantMatchesSource(request, personalSource));
        assert(![SGAudioVariantKey(personalRequest) isEqual:SGAudioVariantKey(request)]);
        bad = [personalRequest mutableCopy]; bad[@"spotify"] = url; assert(!SGAudioVariantRequest(bad));
        bad = [personalRequest mutableCopy]; bad[@"source_local_id"] = otherID;
        assert(!SGAudioVariantMatchesSource(bad, personalSource));
        bad = [personalRequest mutableCopy]; bad[@"source_id"] = derivedHash;
        assert(!SGAudioVariantMatchesSource(bad, personalSource));
        bad = [personalRequest mutableCopy]; bad[@"source_local_id"] = [localID stringByAppendingString:@"\n"];
        assert(!SGAudioVariantRequest(bad));
        NSMutableDictionary *personalRow = [personalSource mutableCopy];
        personalRow[@"local_id"] = variantID; personalRow[@"id"] = derivedHash;
        personalRow[@"source_id"] = hash; personalRow[@"source_local_id"] = localID;
        personalRow[@"variant_kind"] = @"speed"; personalRow[@"variant_speed"] = @0.75;
        personalRow[@"seconds"] = @2400; personalRow[@"title"] = @"Mon morceau · Vitesse ×0,75";
        personalRow[@"album"] = @"Mes imports · Vitesse ×0,75";
        NSMutableDictionary *personalJob = [personalRequest mutableCopy];
        [personalJob addEntriesFromDictionary:@{@"version":@1, @"id":variantID, @"state":@"ready", @"message":@"", @"row":personalRow}];
        NSDictionary *personalReady = SGAudioVariantJob(personalJob, personalRequest);
        assert(personalReady && !personalReady[@"row"][@"spotify"]);
        assert([personalReady[@"row"][@"expectedSeconds"] isEqual:@2400]);
        assert(!SGAudioVariantSourceRow(personalReady[@"row"])); // Never chain a derivative as an original.
        assert(!SGAudioVariantJob(personalJob, request));
        badJob = [personalJob mutableCopy]; badJob[@"version"] = @YES; assert(!SGAudioVariantJob(badJob,personalRequest));
        for (NSString *field in @[@"local_id", @"source_local_id", @"source_id", @"variant_speed", @"spotify"]) {
            badRow = [personalRow mutableCopy];
            badRow[field] = [field isEqual:@"source_id"] ? derivedHash : [field isEqual:@"variant_speed"] ? @1.25 : [field isEqual:@"spotify"] ? url : otherID;
            badJob = [personalJob mutableCopy]; badJob[@"row"] = badRow;
            assert(!SGAudioVariantJob(badJob, personalRequest));
        }
        badRow = [personalRow mutableCopy]; badRow[@"seconds"] = @2701; assert(SGAudioVariantReadyRow(badRow));
        badRow[@"seconds"] = @2701.1; assert(!SGAudioVariantReadyRow(badRow));
        badRow = [personalRow mutableCopy]; badRow[@"bytes"] = @2048.5; assert(!SGAudioVariantReadyRow(badRow));
        badRow = [personalRow mutableCopy]; badRow[@"source_url"] = @"file:///etc/passwd"; assert(!SGAudioVariantReadyRow(badRow));
        badRow = [personalRow mutableCopy]; badRow[@"source_url"] = @"https://www.youtube.com/results?search_query=test"; assert(!SGAudioVariantReadyRow(badRow));
        NSDictionary *receipt = @{@"request":personalRequest, @"job":personalJob, @"installed":personalRow, @"stamp":@"1:2:2048:3:4:5:6", @"paused":@YES};
        NSArray *personalRecords = SGAudioVariantRecords(@[receipt]);
        assert(personalRecords.count == 1 && personalRecords[0][@"installed"]);
        plist = [NSPropertyListSerialization dataWithPropertyList:personalRecords format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        assert([personalRecords isEqual:SGAudioVariantRecords([NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:nil])]);
        bad = [receipt mutableCopy]; badRow = [personalRow mutableCopy]; badRow[@"local_id"] = otherID; bad[@"installed"] = badRow;
        assert(!SGAudioVariantRecords(@[bad])[0][@"installed"]);
        bad = [receipt mutableCopy]; badRow = [personalRow mutableCopy]; badRow[@"source_local_id"] = otherID; bad[@"installed"] = badRow;
        assert(!SGAudioVariantRecords(@[bad])[0][@"installed"]);
        NSDictionary *personalCaps = @{@"speeds":@[@0.75, @1.25, @1.5, @2], @"instrumental":@YES, @"localSources":@YES};
        assert(SGAudioVariantListing(@{@"version":@1, @"capabilities":personalCaps, @"jobs":@[job, personalJob]}));
        bad = [personalCaps mutableCopy]; bad[@"localSources"] = @1;
        assert(!SGAudioVariantListing(@{@"version":@1, @"capabilities":bad, @"jobs":@[]}));
        assert(![SGAudioVariantListing(@{@"version":@1, @"capabilities":@{@"speeds":@[], @"instrumental":@NO}, @"jobs":@[]})[@"capabilities"][@"localSources"] boolValue]);
        NSMutableDictionary *instrumentalRequest = [personalRequest mutableCopy];
        instrumentalRequest[@"kind"] = @"instrumental"; [instrumentalRequest removeObjectForKey:@"speed"];
        badRow = [personalRow mutableCopy]; badRow[@"variant_kind"] = @"instrumental"; [badRow removeObjectForKey:@"variant_speed"];
        badJob = [personalJob mutableCopy]; badJob[@"kind"] = @"instrumental"; [badJob removeObjectForKey:@"speed"]; badJob[@"row"] = badRow;
        assert(SGAudioVariantJob(badJob, instrumentalRequest));
        badRow[@"variant_speed"] = @0.75; assert(!SGAudioVariantJob(badJob, instrumentalRequest));
        puts("Audio variants model: PASS");
    }
    return 0;
}
#endif
