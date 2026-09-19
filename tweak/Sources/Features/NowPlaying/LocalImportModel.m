#import "LocalImportModel.h"
#import "YouTubeSourceModel.h"
#import "AutomaticDownloadModel.h"
#import <math.h>

static BOOL matches(id value, NSString *pattern) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSRange range = [value rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == [value length];
}
static BOOL number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}
static NSString *label(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 200 ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
NSURL *SGLocalImportSource(id value) {
    NSString *text = [value isKindOfClass:NSURL.class] ? [value absoluteString] : value;
    if (![text isKindOfClass:NSString.class] || [text length] > 4096) return nil;
    NSURL *youtube = SGYouTubeCanonicalVideoURL(text);
    if (youtube) return youtube;
    NSURL *url = SGAutomaticAudioSource(text);
    NSString *host = url.host.lowercaseString;
    if (!host.length || [@[@"youtube.com", @"youtu.be"] containsObject:host] ||
        [host hasSuffix:@".youtube.com"] || [host hasSuffix:@".youtu.be"]) return nil;
    // The companion additionally resolves and pins a public IP before fetching.
    if (url.fragment || (url.port && url.port.integerValue != 443)) return nil;
    return url;
}
NSDictionary *SGLocalImportRequest(id value) {
    if (![value isKindOfClass:NSDictionary.class] || value[@"spotify"] ||
        !matches(value[@"request_id"], @"^[A-Za-z0-9-]{16,64}$")) return nil;
    NSURL *source = SGLocalImportSource(value[@"source_url"]);
    NSString *title = label(value[@"title"]), *artist = label(value[@"artist"] ?: @""), *album = label(value[@"album"] ?: @"");
    if (!source || !title.length || !artist || !album) return nil;
    return @{@"request_id":value[@"request_id"], @"source_url":source.absoluteString, @"title":title,
        @"artist":artist.length ? artist : @"Import personnel", @"album":album.length ? album : @"Imports personnels"};
}
NSDictionary *SGLocalImportTarget(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSString *selection = SGAutomaticSpotifyURL(value[@"selection"]), *track = SGAutomaticSpotifyURL(value[@"track"]);
    NSNumber *position = value[@"position"];
    if (!selection || ![track hasPrefix:@"https://open.spotify.com/track/"] || !number(position) ||
        position.doubleValue != floor(position.doubleValue) || position.integerValue < 1 || position.integerValue > 500) return nil;
    return @{@"selection":selection, @"track":track, @"position":position};
}
NSDictionary *SGLocalImportReadyRow(id value) {
    if (![value isKindOfClass:NSDictionary.class] || value[@"spotify"] || ![value[@"state"] isEqual:@"ready"] ||
        !matches(value[@"id"], @"^[a-f0-9]{64}$") || !matches(value[@"local_id"], @"^[a-f0-9]{32}$") ||
        ![@[@"mp3", @"m4a"] containsObject:value[@"extension"] ?: @""] || !number(value[@"bytes"]) ||
        [value[@"bytes"] doubleValue] != floor([value[@"bytes"] doubleValue]) || [value[@"bytes"] longLongValue] < 1024 ||
        [value[@"bytes"] longLongValue] > 100 * 1024 * 1024 || !number(value[@"seconds"]) ||
        [value[@"seconds"] doubleValue] < 1 || [value[@"seconds"] doubleValue] > 1801) return nil;
    NSString *title = label(value[@"title"]), *artist = label(value[@"artist"]), *album = label(value[@"album"]);
    NSURL *source = SGLocalImportSource(value[@"source_url"]);
    if (!title.length || !artist.length || !album.length || !source) return nil;
    NSMutableDictionary *row = [@{@"state":@"ready", @"position":@1, @"local_id":value[@"local_id"], @"id":value[@"id"],
        @"bytes":value[@"bytes"], @"seconds":value[@"seconds"], @"extension":value[@"extension"],
        @"title":title, @"artist":artist, @"album":album, @"source_url":source.absoluteString,
        @"sourceURL":source.absoluteString, @"sourceKind":SGYouTubeCanonicalVideoURL(source) ? @"youtube" : @"direct"} mutableCopy];
    row[@"expectedTitle"] = title; row[@"expectedArtist"] = artist; row[@"expectedSeconds"] = value[@"seconds"];
    return [row copy];
}
NSDictionary *SGLocalImportTargetRow(id job, id target) {
    NSDictionary *reference = SGLocalImportTarget(target);
    if (!reference || ![job isKindOfClass:NSDictionary.class] || ![job[@"url"] isEqual:reference[@"selection"]] ||
        ![job[@"items"] isKindOfClass:NSArray.class]) return nil;
    NSUInteger index = [reference[@"position"] unsignedIntegerValue]; NSArray *items = job[@"items"];
    if (!index || index > items.count || ![items[index - 1] isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *row = items[index - 1];
    return [row[@"spotify"] isEqual:reference[@"track"]] && [row[@"position"] isEqual:reference[@"position"]] ? row : nil;
}
NSDictionary *SGLocalImportJob(id value, NSDictionary *request) {
    NSDictionary *identity = SGLocalImportRequest(value);
    if (!identity || !number(value[@"version"]) || ![value[@"version"] isEqual:@1] ||
        !matches(value[@"id"], @"^[a-f0-9]{32}$") ||
        ![@[@"queued", @"running", @"ready", @"error", @"cancelled", @"interrupted"] containsObject:value[@"state"] ?: @""] ||
        ![value[@"message"] isKindOfClass:NSString.class] || [value[@"message"] length] > 4096 ||
        (request && ![identity isEqual:SGLocalImportRequest(request)])) return nil;
    NSMutableDictionary *job = [identity mutableCopy];
    for (NSString *key in @[@"version", @"id", @"state", @"message"]) job[key] = value[key];
    if ([job[@"state"] isEqual:@"ready"]) {
        NSDictionary *row = SGLocalImportReadyRow(value[@"row"]);
        if (!row || ![row[@"local_id"] isEqual:job[@"id"]]) return nil;
        for (NSString *key in @[@"source_url", @"title", @"artist", @"album"]) if (![row[key] isEqual:job[key]]) return nil;
        job[@"row"] = row;
    }
    return [job copy];
}
NSArray<NSDictionary *> *SGLocalImportRecords(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count] > 80) return @[];
    NSMutableArray *records = [NSMutableArray array]; NSMutableSet *keys = [NSMutableSet set];
    for (id entry in value) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *request = SGLocalImportRequest(entry[@"request"]), *target = SGLocalImportTarget(entry[@"target"]);
        if (!request || (entry[@"target"] && !target) || [keys containsObject:request[@"request_id"]]) continue;
        NSMutableDictionary *record = [@{@"request":request, @"paused":@([entry[@"paused"] isEqual:@YES])} mutableCopy];
        if (target) record[@"target"] = target;
        NSDictionary *job = SGLocalImportJob(entry[@"job"], request);
        if (job) record[@"job"] = job;
        // Receipt is a local file identity only. It never attests a catalogue mapping.
        id installed = entry[@"installed"];
        if ([installed isKindOfClass:NSDictionary.class] && matches(installed[@"id"], @"^[a-f0-9]{64}$") &&
            [@[@"mp3", @"m4a"] containsObject:installed[@"extension"] ?: @""] && number(installed[@"bytes"]) &&
            [installed[@"bytes"] doubleValue] == floor([installed[@"bytes"] doubleValue]) &&
            [installed[@"bytes"] longLongValue] >= 1024 && [installed[@"bytes"] longLongValue] <= 100 * 1024 * 1024 &&
            matches(entry[@"stamp"], @"^[0-9:.-]{1,256}$")) {
            record[@"installed"] = @{@"id":installed[@"id"], @"bytes":installed[@"bytes"], @"extension":installed[@"extension"]};
            record[@"stamp"] = entry[@"stamp"];
        }
        if ([entry[@"error"] isKindOfClass:NSString.class] && [entry[@"error"] length] <= 1024) record[@"error"] = entry[@"error"];
        [records addObject:[record copy]]; [keys addObject:request[@"request_id"]];
    }
    return [records copy];
}
NSArray<NSDictionary *> *SGLocalImportStoreRecord(id entries, NSDictionary *entry) {
    NSArray *single = SGLocalImportRecords(entry ? @[entry] : @[]);
    if (single.count != 1) return nil;
    NSDictionary *record = single.firstObject; NSString *key = record[@"request"][@"request_id"];
    NSMutableArray *records = [SGLocalImportRecords(entries) mutableCopy];
    NSUInteger existing = [records indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        return [item[@"request"][@"request_id"] isEqual:key];
    }];
    if (existing != NSNotFound) [records removeObjectAtIndex:existing];
    while (records.count >= 80) {
        NSUInteger oldest = [records indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            return item[@"installed"] || [@[@"error", @"cancelled", @"interrupted"] containsObject:item[@"job"][@"state"] ?: @""];
        }];
        if (oldest == NSNotFound) return nil;
        [records removeObjectAtIndex:oldest];
    }
    [records addObject:record]; return [records copy];
}

#ifdef SG_LOCAL_IMPORT_TEST
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSDictionary *request = SGLocalImportRequest(@{@"request_id":NSUUID.UUID.UUIDString, @"source_url":@"https://m.youtube.com/watch?v=abcdefghijk&list=abc", @"title":@"Titre choisi"});
        assert(request && [request[@"source_url"] isEqual:@"https://www.youtube.com/watch?v=abcdefghijk"] && [request[@"artist"] isEqual:@"Import personnel"]);
        NSMutableDictionary *bad = [request mutableCopy]; bad[@"spotify"] = @"https://open.spotify.com/track/0123456789012345678901"; assert(!SGLocalImportRequest(bad));
        bad = [request mutableCopy]; bad[@"title"] = @"\nTitre"; assert(!SGLocalImportRequest(bad));
        assert(!SGLocalImportSource(@"https://www.youtube.com/results?search_query=music"));
        assert(!SGLocalImportSource(@"https://user:pass@example.com/track.mp3"));
        assert(!SGLocalImportSource(@"file:///track.mp3"));
        assert(!SGLocalImportSource(@"https://example.com:8080/track.mp3"));
        NSString *jobID = @"12345678901234567890123456789012";
        NSMutableDictionary *row = [request mutableCopy]; [row removeObjectForKey:@"request_id"];
        [row addEntriesFromDictionary:@{@"state":@"ready", @"local_id":jobID, @"id":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0], @"bytes":@2048, @"seconds":@180, @"extension":@"m4a"}];
        assert(SGLocalImportReadyRow(row));
        NSMutableDictionary *job = [request mutableCopy]; [job addEntriesFromDictionary:@{@"version":@1,@"id":jobID,@"state":@"ready",@"message":@"Prêt",@"row":row}];
        assert(SGLocalImportJob(job, request));
        bad = [request mutableCopy]; bad[@"request_id"] = NSUUID.UUID.UUIDString; assert(!SGLocalImportJob(job, bad));
        NSMutableDictionary *badRow = [row mutableCopy]; badRow[@"bytes"] = @YES; assert(!SGLocalImportReadyRow(badRow));
        badRow = [row mutableCopy]; badRow[@"seconds"] = @(NAN); assert(!SGLocalImportReadyRow(badRow));
        badRow = [row mutableCopy]; badRow[@"spotify"] = @"anything"; assert(!SGLocalImportReadyRow(badRow));
        badRow = [row mutableCopy]; badRow[@"title"] = @"Autre titre"; job[@"row"] = badRow; assert(!SGLocalImportJob(job, request)); job[@"row"] = row;
        NSDictionary *target = @{@"selection":@"https://open.spotify.com/playlist/0123456789012345678901",@"track":@"https://open.spotify.com/track/0123456789012345678901",@"position":@2};
        assert(SGLocalImportTarget(target)); bad = [target mutableCopy]; bad[@"position"] = @YES; assert(!SGLocalImportTarget(bad));
        NSDictionary *catalogueRow = @{@"spotify":target[@"track"],@"position":@2,@"expectedSeconds":@187,@"title":@"Titre catalogue"};
        NSDictionary *selection = @{@"url":target[@"selection"],@"items":@[@{},catalogueRow]};
        assert(SGLocalImportTargetRow(selection, target) == catalogueRow);
        bad = [target mutableCopy]; bad[@"position"] = @1; assert(!SGLocalImportTargetRow(selection,bad));
        bad = [target mutableCopy]; bad[@"track"] = @"https://open.spotify.com/track/ABCDEFGHIJKL0123456789"; assert(!SGLocalImportTargetRow(selection,bad));
        bad = [selection mutableCopy]; bad[@"url"] = target[@"track"]; assert(!SGLocalImportTargetRow(bad,target));
        assert(!SGLocalImportTargetRow(@{@"url":target[@"selection"],@"items":@[@{},@"invalid"]}, target));
        NSArray *records = SGLocalImportRecords(@[@{@"request":request,@"job":job,@"target":target,@"paused":@YES}]);
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:records format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        assert(records.count == 1 && [records isEqual:SGLocalImportRecords([NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:nil])]);
        NSMutableDictionary *receipt = [row mutableCopy]; receipt[@"bytes"] = @2048.5;
        NSArray *invalidReceipt = SGLocalImportRecords(@[@{@"request":request,@"installed":receipt,@"stamp":@"1:2:3"}]);
        assert(invalidReceipt.count == 1 && !invalidReceipt[0][@"installed"]);
        NSMutableArray *full = [NSMutableArray array];
        for (NSUInteger i = 0; i < 80; i++) { NSMutableDictionary *next = [request mutableCopy]; next[@"request_id"] = NSUUID.UUID.UUIDString; [full addObject:@{@"request":next,@"paused":@YES}]; }
        assert(!SGLocalImportStoreRecord(full, @{@"request":request}));
        NSMutableDictionary *done = [full[0][@"request"] mutableCopy]; [done addEntriesFromDictionary:@{@"version":@1,@"id":jobID,@"state":@"error",@"message":@"Erreur"}];
        full[0] = @{@"request":full[0][@"request"],@"job":done};
        assert(SGLocalImportStoreRecord(full, @{@"request":request}).count == 80);
        puts("Independent local imports model: PASS");
    }
    return 0;
}
#endif
