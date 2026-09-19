#import "AutomaticDownloadState.h"
#import "AutomaticDownloadModel.h"

static BOOL SGIntentMatch(id value, NSString *pattern) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSRange match = [value rangeOfString:pattern options:NSRegularExpressionSearch];
    return match.location == 0 && match.length == [value length];
}
static NSDictionary *SGIntentRequest(id input) {
    if (![input isKindOfClass:NSDictionary.class]) return nil;
    NSString *url = SGAutomaticSpotifyURL(input[@"url"]);
    if (!url || !SGIntentMatch(input[@"request_id"], @"^[A-Za-z0-9-]{16,64}$")) return nil;
    NSMutableDictionary *request = [@{@"url":url, @"request_id":input[@"request_id"]} mutableCopy];
    if ([input[@"refresh"] isEqual:@YES]) request[@"refresh"] = @YES;
    if ([input[@"kind"] isEqual:@"alternative"]) {
        if (![url containsString:@"/track/"]) return nil;
        request[@"kind"] = @"alternative";
        NSMutableArray *avoid = [NSMutableArray array];
        if (input[@"avoid_sources"] && ![input[@"avoid_sources"] isKindOfClass:NSArray.class]) return nil;
        for (id source in input[@"avoid_sources"]) {
            if (!SGIntentMatch(source, @"^https://music\\.youtube\\.com/watch\\?v=[A-Za-z0-9_-]{11}$") || avoid.count >= 8) return nil;
            if (![avoid containsObject:source]) [avoid addObject:source];
        }
        request[@"avoid_sources"] = avoid;
    } else if (input[@"kind"]) return nil;
    if (input[@"track_urls"]) {
        if (request[@"refresh"] || request[@"kind"] || ![input[@"track_urls"] isKindOfClass:NSArray.class] || [input[@"track_urls"] count] > 500) return nil;
        NSMutableArray *tracks = [NSMutableArray array];
        for (id value in input[@"track_urls"]) {
            NSString *track = SGAutomaticSpotifyURL(value);
            if (![track containsString:@"/track/"]) return nil;
            [tracks addObject:track];
        }
        if (tracks.count) request[@"track_urls"] = tracks;
    }
    return [request copy];
}
NSDictionary *SGAutomaticDownloadIntent(id stored) {
    if (![stored isKindOfClass:NSDictionary.class] || ![stored[@"version"] isEqual:@1]) stored = @{};
    NSMutableDictionary *intent = [@{@"version":@1, @"paused":@([stored[@"paused"] isEqual:@YES])} mutableCopy];
    NSDictionary *pending = SGIntentRequest(stored[@"pending"]);
    if (pending) intent[@"pending"] = pending;
    if ([pending[@"kind"] isEqual:@"alternative"] && [stored[@"acceptRequested"] isEqual:@YES]) intent[@"acceptRequested"] = @YES;
    NSString *active = SGAutomaticSpotifyURL(stored[@"activeURL"]);
    if (active) intent[@"activeURL"] = active;
    NSMutableArray *queue = [NSMutableArray array];
    if ([stored[@"queue"] isKindOfClass:NSArray.class]) for (id value in stored[@"queue"]) {
        NSString *url = SGAutomaticSpotifyURL(value);
        if (url && ![queue containsObject:url] && ![url isEqual:pending[@"url"]] && ![url isEqual:active] && queue.count < 10) [queue addObject:url];
    }
    intent[@"queue"] = queue;
    NSMutableArray *allowed = [queue mutableCopy];
    for (NSString *url in @[active ?: @"", pending[@"url"] ?: @""])
        if (url.length && ![allowed containsObject:url] && allowed.count < 11) [allowed addObject:url];
    NSMutableDictionary *registered = [NSMutableDictionary dictionary];
    if ([stored[@"tracks"] isKindOfClass:NSDictionary.class]) for (NSString *url in allowed) {
        id values = stored[@"tracks"][url];
        if (![values isKindOfClass:NSArray.class] || ![values count] || [values count] > 500) continue;
        NSMutableArray *tracks = [NSMutableArray array]; BOOL valid = YES;
        for (id value in values) {
            NSString *track = SGAutomaticSpotifyURL(value);
            if (![track containsString:@"/track/"]) { valid = NO; break; }
            [tracks addObject:track]; // repeated playlist positions are intentional
        }
        if (valid) registered[url] = tracks;
    }
    intent[@"tracks"] = registered;
    return [intent copy];
}
NSDictionary *SGAutomaticDownloadRequest(NSString *url, NSArray *tracks, BOOL refresh) {
    NSMutableDictionary *request = [@{@"url":url ?: @"", @"request_id":NSUUID.UUID.UUIDString} mutableCopy];
    if (refresh) request[@"refresh"] = @YES;
    else if (tracks.count) request[@"track_urls"] = tracks;
    return SGIntentRequest(request);
}
NSTimeInterval SGAutomaticDownloadRetryDelay(NSUInteger attempt) {
    static const NSTimeInterval delays[] = {2, 4, 8, 16, 30, 60};
    return delays[MIN(attempt, (NSUInteger)5)];
}
NSDictionary *SGAutomaticDownloadReplaceVersion(NSDictionary *history, NSDictionary *locals, NSDictionary *replacement) {
    if (![history isKindOfClass:NSDictionary.class] || ![locals isKindOfClass:NSDictionary.class] || ![replacement isKindOfClass:NSDictionary.class]) return nil;
    NSString *url = SGAutomaticSpotifyURL(replacement[@"spotify"]);
    if (![url containsString:@"/track/"]) return nil;
    NSMutableDictionary *row = [replacement mutableCopy]; row[@"position"] = @1;
    NSDictionary *wrapper = @{@"version":@2, @"id":@"00000000000000000000000000000000", @"url":url,
        @"state":@"complete", @"name":@"Version", @"message":@"", @"scope":@"", @"items":@[row]};
    NSData *json = [NSJSONSerialization isValidJSONObject:wrapper] ? [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil] : nil;
    NSDictionary *validated = SGAutomaticJob(json);
    NSDictionary *ready = [validated[@"items"] firstObject];
    if (![ready[@"state"] isEqual:@"ready"]) return nil;
    NSMutableDictionary *nextLocals = [locals mutableCopy]; nextLocals[url] = ready;
    NSMutableDictionary *nextHistory = [history mutableCopy];
    for (NSString *key in history) nextHistory[key] = SGAutomaticMergeLocalRows(history[key], @{url:ready});
    return @{@"history":[nextHistory copy], @"locals":[nextLocals copy]};
}

NSDictionary *SGAutomaticSingleTrackSelection(NSDictionary *verifiedRow) {
    if (![verifiedRow isKindOfClass:NSDictionary.class] || ![verifiedRow[@"state"] isEqual:@"ready"]) return nil;
    NSString *url = SGAutomaticSpotifyURL(verifiedRow[@"spotify"]);
    if (![url containsString:@"/track/"]) return nil;
    NSMutableDictionary *row = [verifiedRow mutableCopy]; row[@"position"] = @1;
    NSDictionary *job = @{@"version":@2, @"id":@"00000000000000000000000000000000", @"url":url,
        @"state":@"complete", @"name":row[@"title"] ?: @"Morceau", @"message":@"", @"scope":@"Un morceau déjà sur cet iPhone.",
        @"completeMetadata":@YES, @"engine":@"device", @"items":@[row]};
    if (![NSJSONSerialization isValidJSONObject:job]) return nil;
    return SGAutomaticJob([NSJSONSerialization dataWithJSONObject:job options:0 error:nil]);
}

#ifdef SG_AUTOMATIC_STATE_TEST
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSString *a = @"https://open.spotify.com/track/0123456789012345678901", *b = @"https://open.spotify.com/playlist/0123456789012345678902";
        NSDictionary *request = SGAutomaticDownloadRequest(a, nil, NO);
        NSDictionary *snapshot = SGAutomaticDownloadIntent(@{@"version":@1, @"pending":request, @"queue":@[a,b,b], @"paused":@YES, @"activeURL":a, @"tracks":@{b:@[a,a], @"unrelated":@[a]}});
        assert([snapshot[@"pending"] isEqual:request]); assert([snapshot[@"queue"] isEqual:@[b]]); assert([snapshot[@"paused"] boolValue]);
        NSData *serialized = [NSPropertyListSerialization dataWithPropertyList:snapshot format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        NSDictionary *restored = SGAutomaticDownloadIntent([NSPropertyListSerialization propertyListWithData:serialized options:0 format:NULL error:nil]);
        assert([snapshot isEqual:restored]); // restart/ambiguous POST retains exactly the original id
        assert([restored[@"tracks"][b] count] == 2 && [restored[@"tracks"] count] == 1);
        NSMutableDictionary *alternative = [request mutableCopy]; alternative[@"kind"] = @"alternative"; alternative[@"avoid_sources"] = @[@"https://music.youtube.com/watch?v=abcdefghijk"];
        NSDictionary *confirmed = SGAutomaticDownloadIntent(@{@"version":@1,@"pending":alternative,@"acceptRequested":@YES,@"paused":@YES});
        assert([confirmed[@"acceptRequested"] boolValue] && [confirmed[@"paused"] boolValue]);
        assert([confirmed[@"pending"][@"request_id"] isEqual:request[@"request_id"]]);
        assert(!SGAutomaticDownloadIntent(@{@"version":@1,@"pending":request,@"acceptRequested":@YES})[@"acceptRequested"]);
        NSDictionary *refresh = SGAutomaticDownloadRequest(b, @[a], YES);
        assert([refresh[@"refresh"] boolValue] && !refresh[@"track_urls"]);
        assert(SGAutomaticDownloadRetryDelay(0) == 2 && SGAutomaticDownloadRetryDelay(5) == 60 && SGAutomaticDownloadRetryDelay(1000) == 60);
        assert(!SGAutomaticDownloadIntent(@{@"version":@1,@"pending":@{@"url":a,@"request_id":@"bad\n"}})[@"pending"]);
        assert(!SGAutomaticDownloadIntent(@{@"version":@1,@"pending":@{@"url":a,@"request_id":@"12345678_12345678"}})[@"pending"]);
        assert(!SGAutomaticDownloadIntent(@{@"version":@1,@"pending":@{@"url":a,@"request_id":@"123456789012345"}})[@"pending"]);
        assert(!SGAutomaticDownloadIntent(@{@"version":@1,@"pending":@{@"url":a,@"request_id":[@"a" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0]}})[@"pending"]);
        NSString *oldHash = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0], *newHash = [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
        NSDictionary *old = @{@"spotify":a,@"position":@1,@"title":@"Titre",@"artist":@"Artiste",@"album":@"Album",@"state":@"ready",@"id":oldHash,@"bytes":@2048,@"seconds":@180};
        NSMutableDictionary *playlistCopy = [old mutableCopy]; playlistCopy[@"position"] = @17;
        NSDictionary *single = SGAutomaticSingleTrackSelection(playlistCopy);
        assert([single[@"url"] isEqual:a] && [single[@"items"] count] == 1 && [single[@"completeMetadata"] boolValue]);
        assert([single[@"items"][0][@"position"] isEqual:@1] && [single[@"items"][0][@"id"] isEqual:oldHash]);
        assert([playlistCopy[@"position"] isEqual:@17]);
        playlistCopy[@"spotify"] = b; assert(!SGAutomaticSingleTrackSelection(playlistCopy));
        playlistCopy[@"spotify"] = a; playlistCopy[@"state"] = @"waiting"; assert(!SGAutomaticSingleTrackSelection(playlistCopy));
        playlistCopy[@"state"] = @"ready"; playlistCopy[@"id"] = @"bad"; assert(!SGAutomaticSingleTrackSelection(playlistCopy));
        NSMutableDictionary *duplicate = [old mutableCopy]; duplicate[@"position"] = @2; duplicate[@"expectedTitle"] = @"Titre catalogue";
        NSDictionary *job = @{@"items":@[old,duplicate]};
        NSMutableDictionary *replacement = [old mutableCopy]; replacement[@"id"] = newHash; replacement[@"bytes"] = @4096;
        NSDictionary *changed = SGAutomaticDownloadReplaceVersion(@{b:job}, @{a:old}, replacement);
        assert([changed[@"locals"][a][@"id"] isEqual:newHash]);
        assert([changed[@"history"][b][@"items"][1][@"id"] isEqual:newHash]);
        assert([changed[@"history"][b][@"items"][1][@"position"] isEqual:@2]);
        assert([changed[@"history"][b][@"items"][1][@"expectedTitle"] isEqual:@"Titre catalogue"]);
        assert([old[@"id"] isEqual:oldHash]); // immutable old file and rows remain untouched
        replacement[@"id"] = @"invalid";
        assert(!SGAutomaticDownloadReplaceVersion(@{b:job}, @{a:old}, replacement));
        puts("Download intent/reconnect/replacement state: PASS");
    }
    return 0;
}
#endif
