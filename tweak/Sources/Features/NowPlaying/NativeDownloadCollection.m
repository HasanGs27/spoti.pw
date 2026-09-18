#import "NativeDownloadCollection.h"
#import "AutomaticDownloadModel.h"
#import <math.h>

static NSString *label(id value) { return [value isKindOfClass:NSString.class] && [value length] <= 512 ? value : @""; }
static NSDictionary *dictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static NSArray *array(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }

NSURL *SGNativeMetadataURL(id spotify) {
    NSString *canonical = SGAutomaticSpotifyURL(spotify);
    if (!canonical) return nil;
    NSString *path = [NSURL URLWithString:canonical].path;
    return [NSURL URLWithString:[@"https://open.spotify.com/embed" stringByAppendingString:path]];
}

NSDictionary *SGNativeMetadataEntity(NSData *data, id spotify) {
    NSString *canonical = SGAutomaticSpotifyURL(spotify);
    if (!canonical || !data.length || data.length > 8 * 1024 * 1024) return nil;
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<script\\b[^>]*\\bid=[\"']__NEXT_DATA__[\"'][^>]*>([\\s\\S]*?)</script\\s*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!match) return nil;
    NSData *json = [[html substringWithRange:[match rangeAtIndex:1]] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *root = dictionary([NSJSONSerialization JSONObjectWithData:json options:0 error:nil]);
    NSDictionary *entity = dictionary(dictionary(dictionary(dictionary(dictionary(root[@"props"])[@"pageProps"])[@"state"])[@"data"])[@"entity"]);
    NSArray *path = [NSURL URLWithString:canonical].pathComponents;
    if (path.count != 3 || ![entity[@"type"] isEqual:path[1]] || ![entity[@"id"] isEqual:path[2]]) return nil;
    return entity;
}

NSDictionary *SGNativeTrackMetadata(NSDictionary *entity, NSUInteger position) {
    if (![entity[@"type"] isEqual:@"track"]) return nil;
    NSString *spotify = SGAutomaticSpotifyURL(entity[@"uri"]);
    NSString *title = label(entity[@"title"]);
    NSMutableArray *artists = [NSMutableArray array];
    for (id artist in array(entity[@"artists"])) {
        NSString *name = label(dictionary(artist)[@"name"]);
        if (name.length) [artists addObject:name];
    }
    NSString *artist = [artists componentsJoinedByString:@", "];
    double seconds = [entity[@"duration"] isKindOfClass:NSNumber.class] ? [entity[@"duration"] doubleValue] / 1000 : 0;
    if (!spotify || ![spotify containsString:@"/track/"] || !title.length || !artist.length || artist.length > 512 ||
        !isfinite(seconds) || seconds < 1 || seconds > 24 * 3600) return nil;
    NSString *cover = nil; double width = 0;
    for (id candidate in array(dictionary(entity[@"visualIdentity"])[@"image"])) {
        NSDictionary *image = dictionary(candidate);
        NSURL *url = SGAutomaticAudioSource(image[@"url"]);
        double candidateWidth = [image[@"maxWidth"] isKindOfClass:NSNumber.class] ? [image[@"maxWidth"] doubleValue] : 0;
        if (url && candidateWidth > width) { cover = url.absoluteString; width = candidateWidth; }
    }
    NSMutableDictionary *row = [@{@"position":@(position), @"spotify":spotify, @"title":title, @"artist":artist, @"state":@"waiting",
        @"expectedTitle":title, @"expectedArtist":artist, @"expectedArtists":artists, @"expectedSeconds":@(seconds)} mutableCopy];
    if (cover) row[@"coverURL"] = cover;
    return row;
}

NSDictionary *SGNativeCollectionJob(NSData *html, id spotify, NSString **reason) {
    NSString *url = SGAutomaticSpotifyURL(spotify);
    NSDictionary *entity = SGNativeMetadataEntity(html, url);
    if (!entity) { if (reason) *reason = @"La sélection n'est pas accessible pour le moment. Ouvre-la dans Spotify puis réessaie."; return nil; }
    NSMutableArray *rows = [NSMutableArray array];
    if ([entity[@"type"] isEqual:@"track"]) {
        NSDictionary *row = SGNativeTrackMetadata(entity, 1);
        if (row) [rows addObject:row];
    } else {
        for (id value in array(entity[@"trackList"])) {
            NSDictionary *item = dictionary(value);
            NSString *track = SGAutomaticSpotifyURL(item[@"uri"]);
            if (!track || ![track containsString:@"/track/"] || rows.count >= 500) {
                if (reason) *reason = @"Cette sélection contient un élément non pris en charge ou dépasse 500 titres. Essaie une sélection plus petite.";
                return nil;
            }
            NSString *title = label(item[@"title"]), *artist = label(item[@"subtitle"]);
            NSMutableDictionary *row = [@{@"position":@(rows.count + 1), @"spotify":track, @"title":title.length ? title : @"Morceau",
                @"artist":artist, @"state":@"waiting"} mutableCopy];
            if (title.length) row[@"expectedTitle"] = title;
            if (artist.length) row[@"expectedArtist"] = artist;
            double seconds = [item[@"duration"] isKindOfClass:NSNumber.class] ? [item[@"duration"] doubleValue] / 1000 : 0;
            if (isfinite(seconds) && seconds >= 1 && seconds <= 24 * 3600) row[@"expectedSeconds"] = @(seconds);
            [rows addObject:row];
        }
    }
    if (!rows.count) { if (reason) *reason = @"Aucun morceau accessible dans cette sélection. Tu peux aussi importer un fichier depuis Téléchargements."; return nil; }
    NSString *name = label(entity[@"title"]); if (!name.length) name = label(entity[@"name"]);
    return @{@"version":@2, @"engine":@"device", @"id":[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString],
        @"url":url, @"name":name.length ? name : @"Sélection", @"state":@"queued", @"message":@"Prêt sur cet iPhone", @"items":rows,
        @"completeMetadata":@([entity[@"type"] isEqual:@"track"]),
        @"scope":[entity[@"type"] isEqual:@"track"] ? @"Un morceau." : @"Titres accessibles sur la page publique. Spotify peut limiter la liste fournie."};
}

#ifdef SG_NATIVE_COLLECTION_TEST
#include <assert.h>
static NSData *html(id entity) {
    NSDictionary *root = @{@"props":@{@"pageProps":@{@"state":@{@"data":@{@"entity":entity}}}}};
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:root options:0 error:nil] encoding:NSUTF8StringEncoding];
    return [[NSString stringWithFormat:@"<script id=\"__NEXT_DATA__\" type=\"application/json\">%@</script>", json] dataUsingEncoding:NSUTF8StringEncoding];
}
int main(void) { @autoreleasepool {
    NSString *uri = @"spotify:track:4DNTHdu4F7eTNuhyLQvEzG";
    NSDictionary *track = @{@"type":@"track", @"id":@"4DNTHdu4F7eTNuhyLQvEzG", @"uri":uri, @"title":@"Synthetic song",
        @"artists":@[@{@"name":@"Artist"}], @"duration":@123000, @"audioPreview":@{@"url":@"https://example.org/preview.mp3"},
        @"visualIdentity":@{@"image":@[@{@"url":@"https://example.org/cover.jpg", @"maxWidth":@640}]}};
    NSDictionary *job = SGNativeCollectionJob(html(track), uri, nil);
    assert(job && [job[@"items"] count] == 1 && [job[@"items"][0][@"expectedSeconds"] isEqual:@123]);
    assert(!job[@"items"][0][@"sourceURL"]); // Never substitute a preview for a full track.
    assert(!SGNativeCollectionJob(html(track), @"spotify:track:5aIp2IBhStp31hkyLG6ssZ", nil));
    assert(!SGNativeCollectionJob([@"<html>Unavailable</html>" dataUsingEncoding:NSUTF8StringEncoding], uri, nil));
    NSDictionary *list = @{@"type":@"playlist", @"id":@"1Imj2Uc2NVvyHgrAouKQo3", @"title":@"Test", @"trackList":@[
        @{@"uri":uri, @"title":@"First", @"subtitle":@"Artist", @"duration":@123000},
        @{@"uri":uri, @"title":@"Duplicate", @"subtitle":@"Artist", @"duration":@123000}]};
    job = SGNativeCollectionJob(html(list), @"spotify:playlist:1Imj2Uc2NVvyHgrAouKQo3", nil);
    assert([job[@"items"] count] == 2 && [job[@"items"][1][@"position"] isEqual:@2]);
    assert(!SGNativeMetadataEntity(html(@{@"props":NSNull.null}), uri));
    puts("Native collection metadata: PASS");
} return 0; }
#endif
