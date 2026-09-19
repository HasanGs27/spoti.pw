#import "AutomaticDownloadModel.h"
#import "LocalDownloadManifest.h"
#import <math.h>

static BOOL pattern(NSString *text, NSString *expression) {
    if (![text isKindOfClass:NSString.class]) return NO;
    static NSCache *expressions; static dispatch_once_t once;
    dispatch_once(&once, ^{ expressions = [NSCache new]; expressions.countLimit = 12; });
    NSRegularExpression *regex = [expressions objectForKey:expression];
    if (!regex) { regex = [NSRegularExpression regularExpressionWithPattern:expression options:0 error:nil]; [expressions setObject:regex forKey:expression]; }
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match && match.range.location == 0 && match.range.length == text.length;
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
    if (row[@"source"] && row[@"source"] != NSNull.null && ![row[@"source"] isEqual:@""]) {
        if (!pattern(row[@"source"], @"^https://music\\.youtube\\.com/watch\\?v=[A-Za-z0-9_-]{11}$")) return nil;
        item[@"source"] = row[@"source"];
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
    if (job[@"kind"] && ![@[@"download", @"alternative"] containsObject:job[@"kind"]]) return nil;
    if (job[@"kind"]) result[@"kind"] = job[@"kind"];
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

NSDictionary *SGAutomaticClearUnfinishedHistory(NSDictionary *history, NSDictionary *verifiedLocalRows) {
    if (![history isKindOfClass:NSDictionary.class] || ![verifiedLocalRows isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *available = [NSMutableDictionary dictionary];
    for (id key in verifiedLocalRows) {
        NSDictionary *row = validatedRow(verifiedLocalRows[key]);
        if (row && [row[@"state"] isEqual:@"ready"] && [key isEqual:row[@"spotify"]]) available[key] = row;
    }
    NSMutableDictionary *kept = [NSMutableDictionary dictionary];
    for (id key in history) {
        id stored = history[key];
        NSData *data = [NSJSONSerialization isValidJSONObject:stored] ? [NSJSONSerialization dataWithJSONObject:stored options:0 error:nil] : nil;
        NSDictionary *job = SGAutomaticJob(data);
        if (!job || ![key isEqual:job[@"url"]]) continue;
        NSMutableDictionary *clean = [SGAutomaticMergeLocalRows(job, available) mutableCopy];
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *row in clean[@"items"]) {
            if (!available[row[@"spotify"]]) continue; // A persisted ready flag alone is not proof of a local file.
            NSMutableDictionary *copy = [row mutableCopy]; copy[@"position"] = @(rows.count + 1);
            [copy removeObjectForKey:@"errorMessage"]; [copy removeObjectForKey:@"progress"];
            [rows addObject:[copy copy]];
        }
        if (!rows.count) continue;
        if (rows.count < [job[@"items"] count]) clean[@"completeMetadata"] = @NO;
        BOOL complete = clean[@"completeMetadata"] ? [clean[@"completeMetadata"] boolValue] : ![clean[@"engine"] isEqual:@"device"];
        clean[@"items"] = [rows copy]; clean[@"state"] = complete ? @"complete" : @"partial";
        clean[@"message"] = @""; // Do not restore a stale "searching" or transfer error after relaunch.
        kept[key] = [clean copy];
    }
    return [kept copy];
}

NSArray<NSNumber *> *SGAutomaticPreparationOrder(NSArray<NSDictionary *> *items) {
    if (![items isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *untried = [NSMutableArray array], *failed = [NSMutableArray array];
    for (NSUInteger index = 0; index < items.count; index++) {
        NSDictionary *row = items[index];
        BOOL error = [row isKindOfClass:NSDictionary.class] && [row[@"state"] isEqual:@"error"];
        [(error ? failed : untried) addObject:@(index)];
    }
    [untried addObjectsFromArray:failed]; return [untried copy];
}

static NSString *summaryTrackURL(id value) {
    NSString *url = SGAutomaticSpotifyURL(value);
    return [url containsString:@"/track/"] ? url : nil;
}
static NSSet *summaryTrackURLs(NSSet *values) {
    NSMutableSet *urls = [NSMutableSet set];
    if ([values isKindOfClass:NSSet.class]) for (id value in values) {
        NSString *url = summaryTrackURL(value); if (url) [urls addObject:url];
    }
    return urls;
}
NSDictionary<NSString *, NSNumber *> *SGAutomaticDownloadSummary(NSArray<NSDictionary *> *items,
    NSSet<NSString *> *verifiedReadyURLs, NSSet<NSString *> *failedURLs, NSString *activeSpotifyURL) {
    if (![items isKindOfClass:NSArray.class]) items = @[];
    NSSet *readyURLs = summaryTrackURLs(verifiedReadyURLs), *errors = summaryTrackURLs(failedURLs);
    NSString *active = summaryTrackURL(activeSpotifyURL);
    NSMutableArray *identities = [NSMutableArray arrayWithCapacity:items.count];
    NSUInteger activeIndex = NSNotFound, ready = 0, failed = 0, waiting = 0, running = 0;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *row = [items[i] isKindOfClass:NSDictionary.class] ? items[i] : @{};
        NSString *identity = summaryTrackURL(row[@"spotify"]); [identities addObject:identity ?: NSNull.null];
        if (active && [identity isEqual:active] && ![readyURLs containsObject:identity]) {
            if (activeIndex == NSNotFound || (![items[activeIndex][@"state"] isEqual:@"running"] && [row[@"state"] isEqual:@"running"]))
                activeIndex = i;
        }
    }
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *row = [items[i] isKindOfClass:NSDictionary.class] ? items[i] : @{};
        id identity = identities[i];
        if ([readyURLs containsObject:identity]) ready++;
        else if (i == activeIndex) running++;
        else if ([errors containsObject:identity] || [row[@"state"] isEqual:@"error"]) failed++;
        else waiting++;
    }
    return @{@"total":@(items.count), @"ready":@(ready), @"failed":@(failed), @"waiting":@(waiting),
        @"running":@(running), @"processed":@(ready + failed)};
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
static void summaryTests(void) {
    NSString *a = @"https://open.spotify.com/track/aaaaaaaaaaaaaaaaaaaaaa";
    NSString *b = @"https://open.spotify.com/track/bbbbbbbbbbbbbbbbbbbbbb";
    NSString *c = @"https://open.spotify.com/track/cccccccccccccccccccccc";
    NSString *d = @"https://open.spotify.com/track/dddddddddddddddddddddd";
    NSString *e = @"https://open.spotify.com/track/eeeeeeeeeeeeeeeeeeeeee";
    NSString *f = @"https://open.spotify.com/track/ffffffffffffffffffffff";
    NSArray *items = @[@{@"spotify":a, @"state":@"ready"}, @{@"spotify":b, @"state":@"error"},
        @{@"spotify":b, @"state":@"waiting"}, @{@"spotify":c, @"state":@"error"}, @{@"spotify":c, @"state":@"running"},
        @{@"spotify":d, @"state":@"running"}, @{@"spotify":e, @"state":@"waiting"}, @{@"spotify":f, @"state":@"error"},
        @{@"spotify":@"https://open.spotify.com.evil/track/aaaaaaaaaaaaaaaaaaaaaa", @"state":@"ready"}];
    NSSet *ready = [NSSet setWithArray:@[@" spotify:track:bbbbbbbbbbbbbbbbbbbbbb ",
        @"https://open.spotify.com.evil/track/aaaaaaaaaaaaaaaaaaaaaa", @"https://open.spotify.com/playlist/aaaaaaaaaaaaaaaaaaaaaa"]];
    NSSet *errors = [NSSet setWithArray:@[[e stringByAppendingString:@"?si=shared"], c]];
    NSDictionary *summary = SGAutomaticDownloadSummary(items, ready, errors, @"spotify:track:cccccccccccccccccccccc");
    assert(([summary isEqual:@{@"total":@9, @"ready":@2, @"failed":@3, @"waiting":@3, @"running":@1, @"processed":@5}]));
    // Persisted running states are not active after a restart, and errors never count as saved music.
    NSDictionary *paused = SGAutomaticDownloadSummary(items, ready, errors, nil);
    assert([paused[@"running"] isEqual:@0] && [paused[@"waiting"] isEqual:@3] && [paused[@"failed"] isEqual:@4]);
    assert([paused[@"ready"] isEqual:@2] && [paused[@"processed"] isEqual:@6]);
    // A verified shared file satisfies every occurrence, even if one was active or had an older error.
    NSDictionary *savedActive = SGAutomaticDownloadSummary(items, ready, errors, b);
    assert([savedActive[@"running"] isEqual:@0] && [savedActive[@"ready"] isEqual:@2]);
    NSArray *duplicates = @[@{@"spotify":a, @"state":@"waiting"}, @{@"spotify":a, @"state":@"waiting"}];
    NSDictionary *singleActive = SGAutomaticDownloadSummary(duplicates, nil, nil, a);
    assert([singleActive[@"running"] isEqual:@1] && [singleActive[@"waiting"] isEqual:@1] && [singleActive[@"processed"] isEqual:@0]);
    assert(([SGAutomaticDownloadSummary(@[], nil, nil, nil) isEqual:@{@"total":@0, @"ready":@0, @"failed":@0, @"waiting":@0, @"running":@0, @"processed":@0}]));
    for (NSDictionary *counts in @[summary, paused, singleActive]) {
        assert([counts[@"total"] unsignedIntegerValue] == [counts[@"ready"] unsignedIntegerValue] + [counts[@"failed"] unsignedIntegerValue] +
            [counts[@"waiting"] unsignedIntegerValue] + [counts[@"running"] unsignedIntegerValue]);
        assert([counts[@"processed"] unsignedIntegerValue] == [counts[@"ready"] unsignedIntegerValue] + [counts[@"failed"] unsignedIntegerValue]);
    }
}
static void clearHistoryTests(void) {
    NSString *a = @"https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT";
    NSString *b = @"https://open.spotify.com/track/4DNTHdu4F7eTNuhyLQvEzG";
    NSString *missing = @"https://open.spotify.com/track/aaaaaaaaaaaaaaaaaaaaaa";
    NSString *playlist = @"https://open.spotify.com/playlist/1Imj2Uc2NVvyHgrAouKQo3";
    NSMutableDictionary *localA = [@{@"position":@1, @"state":@"ready", @"spotify":a, @"title":@"Saved A", @"artist":@"Artist",
        @"album":@"Album", @"seconds":@123, @"bytes":@2048, @"extension":@"m4a", @"sourceKind":@"manual",
        @"id":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]} mutableCopy];
    NSMutableDictionary *localB = [localA mutableCopy]; localB[@"spotify"] = b; localB[@"title"] = @"Saved B";
    localB[@"id"] = [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
    NSDictionary *waiting = @{@"position":@1, @"state":@"waiting", @"spotify":missing, @"title":@"Missing", @"artist":@"Artist"};
    NSDictionary *error = @{@"position":@2, @"state":@"error", @"spotify":a, @"title":@"Old A", @"artist":@"Artist",
        @"expectedTitle":@"Catalogue A", @"errorMessage":@"Failed earlier", @"progress":@0.4};
    NSMutableDictionary *stale = [localA mutableCopy]; stale[@"spotify"] = missing; stale[@"position"] = @3;
    NSMutableDictionary *fourth = [localB mutableCopy]; fourth[@"position"] = @4;
    NSMutableDictionary *duplicate = [error mutableCopy]; duplicate[@"position"] = @5;
    NSDictionary *mixed = @{@"version":@2, @"id":@"0123456789abcdef0123456789abcdef", @"url":playlist,
        @"state":@"interrupted", @"name":@"Mixed", @"message":@"Searching", @"scope":@"Original selection", @"engine":@"device",
        @"completeMetadata":@YES, @"items":@[waiting, error, stale, fourth, duplicate]};
    NSMutableDictionary *pc = [mixed mutableCopy]; pc[@"url"] = b; pc[@"engine"] = @"pc";
    pc[@"items"] = @[localB]; [pc removeObjectForKey:@"completeMetadata"];
    NSMutableDictionary *empty = [mixed mutableCopy]; empty[@"url"] = missing; empty[@"items"] = @[waiting];
    NSMutableDictionary *partial = [mixed mutableCopy]; partial[@"url"] = a; partial[@"items"] = @[localA]; partial[@"completeMetadata"] = @NO;
    NSDictionary *history = @{playlist:mixed, b:pc, missing:empty, a:partial};
    NSDictionary *available = @{a:localA, b:localB};
    NSDictionary *clean = SGAutomaticClearUnfinishedHistory(history, available);
    assert(clean.count == 3 && !clean[missing]);
    NSDictionary *kept = clean[playlist]; NSArray *rows = kept[@"items"];
    assert(rows.count == 3 && [kept[@"completeMetadata"] isEqual:@NO] && [kept[@"state"] isEqual:@"partial"]);
    assert([rows[0][@"position"] isEqual:@1] && [rows[1][@"position"] isEqual:@2] && [rows[2][@"position"] isEqual:@3]);
    assert([rows[0][@"spotify"] isEqual:a] && [rows[1][@"spotify"] isEqual:b] && [rows[2][@"spotify"] isEqual:a]);
    assert([rows[0][@"id"] isEqual:localA[@"id"]] && [rows[0][@"extension"] isEqual:@"m4a"] && [rows[0][@"sourceKind"] isEqual:@"manual"]);
    assert([rows[0][@"expectedTitle"] isEqual:@"Catalogue A"] && !rows[0][@"errorMessage"] && !rows[0][@"progress"]);
    assert([kept[@"message"] isEqual:@""] && [kept[@"name"] isEqual:@"Mixed"]);
    assert([clean[b][@"state"] isEqual:@"complete"] && [clean[a][@"state"] isEqual:@"partial"]);
    assert([clean[b][@"items"][0][@"id"] isEqual:rows[1][@"id"]]); // Same installed file can remain in several playlists.
    assert([mixed[@"items"] count] == 5 && [mixed[@"message"] isEqual:@"Searching"] && available.count == 2);
    assert([SGAutomaticClearUnfinishedHistory(clean, available) isEqual:clean]);
    assert(!SGAutomaticClearUnfinishedHistory(history, @{}).count);
    assert(!SGAutomaticClearUnfinishedHistory(@{a:partial}, @{a:localB}).count); // Never trust a wrong Spotify identity.
    for (NSDictionary *job in clean.allValues) assert([SGAutomaticJob(fixture(job)) isEqual:job]);
    NSMutableDictionary *complete = [mixed mutableCopy]; complete[@"items"] = @[localA];
    NSDictionary *full = SGAutomaticClearUnfinishedHistory(@{playlist:complete}, available)[playlist];
    assert([full[@"state"] isEqual:@"complete"] && [full[@"completeMetadata"] isEqual:@YES]);
    NSMutableDictionary *prunedPC = [mixed mutableCopy]; prunedPC[@"engine"] = @"pc"; [prunedPC removeObjectForKey:@"completeMetadata"];
    NSDictionary *trimmedPC = SGAutomaticClearUnfinishedHistory(@{playlist:prunedPC}, available)[playlist];
    assert([trimmedPC[@"state"] isEqual:@"partial"] && [trimmedPC[@"completeMetadata"] isEqual:@NO]);
    NSArray *order = SGAutomaticPreparationOrder(@[@{@"state":@"error"}, @{@"state":@"error"}, @{@"state":@"waiting"},
        @{@"state":@"ready"}, @{@"state":@"running"}, @{@"state":@"error"}]);
    assert(([order isEqual:@[@2, @3, @4, @0, @1, @5]] && !SGAutomaticPreparationOrder(@[]).count));
}
int main(void) { @autoreleasepool {
    summaryTests();
    clearHistoryTests();
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
