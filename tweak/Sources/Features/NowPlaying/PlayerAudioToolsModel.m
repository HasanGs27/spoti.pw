#import "PlayerAudioToolsModel.h"
#import "AutomaticDownloadModel.h"
#import "AutomaticDownloadState.h"
#import "AudioVariantModel.h"

NSDictionary *SGPlayerAudioSourceForLocalURI(NSString *uri, NSArray<NSDictionary *> *sources) {
    if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"spotify:local:"] || uri.length > 4096 ||
        ![sources isKindOfClass:NSArray.class] || sources.count > 10000) return nil;
    NSDictionary *found = nil;
    for (id candidate in sources) {
        NSDictionary *source = SGAudioVariantSourceRow(candidate);
        if (!source || ![SGAutomaticLocalURI(source) isEqual:uri]) continue;
        // Local URIs encode metadata, not a file hash. Never choose arbitrarily
        // when two different recordings share that metadata.
        if (found && (![found[@"id"] isEqual:source[@"id"]] ||
            ![(found[@"spotify"] ?: found[@"local_id"]) isEqual:(source[@"spotify"] ?: source[@"local_id"])])) return nil;
        found = source;
    }
    return found;
}
NSDictionary *SGPlayerAudioPreparedSource(id job, NSString *uri) {
    NSString *url = SGAutomaticSpotifyURL(uri);
    if (![url hasPrefix:@"https://open.spotify.com/track/"] || ![job isKindOfClass:NSDictionary.class] ||
        ![job[@"url"] isEqual:url] || ![job[@"items"] isKindOfClass:NSArray.class] || [job[@"items"] count] != 1) return nil;
    NSDictionary *row = SGAudioVariantSourceRow([job[@"items"] firstObject]);
    return [row[@"spotify"] isEqual:url] && [row[@"position"] isEqual:@1] ? row : nil;
}
NSDictionary *SGPlayerAudioPreparationRecord(id value, NSString *uri) {
    NSString *url = SGAutomaticSpotifyURL(uri);
    if (![url hasPrefix:@"https://open.spotify.com/track/"] || ![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *request = SGAutomaticDownloadIntent(@{@"version":@1, @"pending":value[@"request"] ?: @{}})[@"pending"];
    if (![request[@"url"] isEqual:url] || request[@"kind"] || request[@"track_urls"] || request[@"refresh"]) return nil;
    NSMutableDictionary *result = [@{@"request":request,@"paused":@([value[@"paused"] isEqual:@YES])} mutableCopy];
    id raw = value[@"job"];
    if (raw) {
        if (![NSJSONSerialization isValidJSONObject:raw]) return nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:raw options:0 error:nil];
        if (data.length > 128 * 1024) return nil;
        NSDictionary *job = SGAutomaticJob(data);
        if (!job || ![job[@"url"] isEqual:url] || [job[@"items"] count] > 1) return nil;
        for (NSDictionary *row in job[@"items"]) if (![row[@"spotify"] isEqual:url]) return nil;
        result[@"job"] = job;
    }
    return result;
}

#ifdef SG_PLAYER_AUDIO_TOOLS_TEST
#include <assert.h>
int main(void) { @autoreleasepool {
    NSString *a = @"https://open.spotify.com/track/0123456789012345678901";
    NSString *b = @"https://open.spotify.com/track/0123456789012345678902";
    NSString *hash = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
    NSDictionary *row = @{@"state":@"ready", @"position":@1, @"spotify":a, @"id":hash, @"bytes":@2048,
        @"seconds":@180, @"title":@"Titre", @"artist":@"Artiste", @"album":@"Album", @"extension":@"mp3"};
    NSString *local = SGAutomaticLocalURI(row);
    assert(SGPlayerAudioSourceForLocalURI(local, @[row]));
    assert(!SGPlayerAudioSourceForLocalURI(a, @[row]));
    NSMutableDictionary *other = [row mutableCopy]; other[@"id"] = [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
    assert(!SGPlayerAudioSourceForLocalURI(local, @[row, other]));
    assert(SGPlayerAudioSourceForLocalURI(local, @[row, row]));
    NSDictionary *request = SGAutomaticDownloadRequest(a, nil, NO);
    NSDictionary *job = @{@"version":@2, @"id":@"0123456789abcdef0123456789abcdef", @"url":a, @"state":@"complete",
        @"name":@"Titre", @"message":@"", @"scope":@"", @"items":@[row]};
    NSDictionary *record = SGPlayerAudioPreparationRecord(@{@"request":request, @"job":job}, a);
    assert(record && [record[@"request"][@"request_id"] isEqual:request[@"request_id"]]);
    assert(SGPlayerAudioPreparedSource(record[@"job"], a));
    assert(!SGPlayerAudioPreparedSource(job, b));
    assert(!SGPlayerAudioPreparationRecord(record, b));
    NSMutableDictionary *bad = [job mutableCopy]; bad[@"items"] = @[row, row];
    assert(!SGPlayerAudioPreparedSource(bad, a));
    assert(!SGPlayerAudioPreparationRecord(@{@"request":request,@"job":bad}, a));
    bad = [row mutableCopy]; bad[@"spotify"] = b;
    NSMutableDictionary *wrongJob = [job mutableCopy]; wrongJob[@"items"] = @[bad];
    assert(!SGPlayerAudioPreparationRecord(@{@"request":request,@"job":wrongJob}, a));
    assert(!SGPlayerAudioPreparedSource(wrongJob, a));
    assert(!SGPlayerAudioPreparationRecord(@{@"request":SGAutomaticDownloadRequest(a,nil,YES)}, a));
    assert([SGPlayerAudioPreparationRecord(@{@"request":request,@"paused":@YES},a)[@"paused"] isEqual:@YES]);
    puts("Player audio source identity and preparation: PASS");
} return 0; }
#endif
