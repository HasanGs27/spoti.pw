// Keep Spotify's player/session/artwork pipeline. Only an explicit play request
// made offline may be redirected to verified copies from that same playlist.
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "Core/SGCore.h"
#import <Network/Network.h>
#import <os/lock.h>

@interface NSObject (SGOfflinePlaybackModel)
- (id)initWithDictionary:(NSDictionary *)dictionary;
- (id)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
- (NSURL *)URI;
- (void)setURI:(NSURL *)uri;
- (void)setURL:(NSURL *)url;
- (NSArray *)pages;
- (void)setPages:(NSArray *)pages;
- (void)setFallbackPages:(NSArray *)pages;
- (NSArray *)tracks;
- (void)setTracks:(NSArray *)tracks;
- (NSString *)UID;
- (NSString *)provider;
- (void)setProvider:(NSString *)provider;
- (NSDictionary *)metadata;
- (void)setMetadata:(NSDictionary *)metadata;
- (NSURL *)albumURI;
- (NSURL *)artistURI;
- (id)skipTo;
- (void)setSkipTo:(id)skip;
- (NSURL *)trackUri;
- (void)setTrackUri:(NSURL *)uri;
- (NSString *)trackUid;
- (void)setTrackUid:(NSString *)uid;
- (NSNumber *)trackIndex;
- (void)setTrackIndex:(NSNumber *)index;
- (NSNumber *)pageIndex;
- (void)setPageIndex:(NSNumber *)index;
- (NSURL *)pageUrl;
- (void)setPageUrl:(NSURL *)url;
@end

static os_unfair_lock pathLock = OS_UNFAIR_LOCK_INIT;
static BOOL pathKnown, pathUnavailable, forcedOffline;
static nw_path_monitor_t pathMonitor;
static dispatch_queue_t pathQueue;

static BOOL shouldUseLocalCopies(void) {
    os_unfair_lock_lock(&pathLock);
    BOOL offline = forcedOffline || (pathKnown && pathUnavailable);
    os_unfair_lock_unlock(&pathLock);
    return offline && SGAutomaticDownloadIsEnabled();
}

static void observedForcedOffline(BOOL value) {
    os_unfair_lock_lock(&pathLock); forcedOffline = value; os_unfair_lock_unlock(&pathLock);
}

static NSArray *loadedTracks(id context) {
    NSArray *pages = [context pages];
    if (!pages) return @[];
    if (![pages isKindOfClass:NSArray.class] || pages.count > 100) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    Class pageClass = NSClassFromString(@"SPTPlayerContextPage"), trackClass = NSClassFromString(@"SPTPlayerTrack");
    for (id page in pages) {
        if (![page isKindOfClass:pageClass]) return nil;
        NSArray *pageTracks = [page tracks];
        if (![pageTracks isKindOfClass:NSArray.class] || pageTracks.count + tracks.count > 1000) return nil;
        for (id track in pageTracks) if (![track isKindOfClass:trackClass]) return nil;
        [tracks addObjectsFromArray:pageTracks];
    }
    return tracks;
}

static NSString *requestedTrack(id context, id options, NSArray *loaded, NSArray<NSDictionary *> *savedRows) {
    id skip = [options skipTo];
    if (skip && ![skip isKindOfClass:NSClassFromString(@"SPTSkipToTrack")]) return nil;
    NSURL *uri = [skip trackUri];
    if (uri) return SGAutomaticSpotifyURL(uri); // Local/already-converted URI fails closed.
    NSString *uid = [skip trackUid];
    if (uid.length) {
        NSString *found;
        for (id track in loaded) if ([[track UID] isEqual:uid]) {
            if (found) return nil;
            found = SGAutomaticSpotifyURL([track URI]);
        }
        return found;
    }
    NSNumber *index = [skip trackIndex];
    if (index) {
        // A bare index is meaningful only in the actual supplied page. Cached order
        // might differ after sorting/filtering, so never guess from it.
        if (![index isKindOfClass:NSNumber.class] || index.integerValue < 0) return nil;
        NSArray *pages = [context pages];
        NSUInteger pageIndex = [[skip pageIndex] unsignedIntegerValue];
        if ([skip pageUrl] || ![pages isKindOfClass:NSArray.class] || pageIndex >= pages.count) return nil;
        id page = pages[pageIndex];
        if (![page isKindOfClass:NSClassFromString(@"SPTPlayerContextPage")]) return nil;
        NSArray *tracks = [page tracks];
        NSUInteger trackIndex = index.unsignedIntegerValue;
        if (![tracks isKindOfClass:NSArray.class] || trackIndex >= tracks.count) return nil;
        id track = tracks[trackIndex];
        return [track isKindOfClass:NSClassFromString(@"SPTPlayerTrack")] ? SGAutomaticSpotifyURL([track URI]) : nil;
    }
    if ([skip pageUrl] || [skip pageIndex]) return nil;
    NSString *contextURL = SGAutomaticSpotifyURL([context URI]);
    if ([contextURL hasPrefix:@"https://open.spotify.com/track/"]) return contextURL;
    if (loaded.count) return SGAutomaticSpotifyURL([loaded.firstObject URI]);
    // A playlist Play request without skip identity starts its first original item.
    // Partial downloads must not silently substitute an arbitrary later song.
    for (NSDictionary *row in savedRows) if ([row[@"position"] unsignedIntegerValue] == 1) return row[@"spotify"];
    return nil;
}

static void playbackDiagnostic(NSString *playlist, NSString *track, NSUInteger count) {
    NSDictionary *record = @{@"event":@"offline-native-play", @"playlist":playlist ?: @"", @"track":track ?: @"", @"localCount":@(count)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *cache = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *file = [cache URLByAppendingPathComponent:@"spoti-offline-playback.json"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [data writeToURL:file options:NSDataWritingAtomic error:nil]; });
}

static void prepareLocalPlayback(id originalContext, id originalOptions, id *resultContext, id *resultOptions) {
    if (!shouldUseLocalCopies()) return;
    Class contextClass = NSClassFromString(@"SPTPlayerContext"), optionsClass = NSClassFromString(@"SPTPlayOptions");
    Class trackClass = NSClassFromString(@"SPTPlayerTrack"), pageClass = NSClassFromString(@"SPTPlayerContextPage");
    Class skipClass = NSClassFromString(@"SPTSkipToTrack");
    if (![originalContext isKindOfClass:contextClass] || (originalOptions && ![originalOptions isKindOfClass:optionsClass]) ||
        !trackClass || !pageClass || !skipClass) return;
    @try {
        NSString *contextURL = SGAutomaticSpotifyURL([originalContext URI]);
        if (!contextURL) return; // Local contexts are idempotent across the overloads below.
        BOOL playlist = [contextURL hasPrefix:@"https://open.spotify.com/playlist/"];
        NSArray<NSDictionary *> *rows;
        if (playlist) rows = SGAutomaticDownloadedRows(contextURL);
        else {
            NSDictionary *row = SGAutomaticDownloadedRow(contextURL);
            rows = row ? @[row] : @[];
        }
        if (!rows.count || rows.count > 1000) return;
        NSArray *loaded = loadedTracks(originalContext);
        if (!loaded) return;
        NSString *requested = requestedTrack(originalContext, originalOptions, loaded, rows);
        if (!requested) return;
        NSDictionary *selected;
        for (NSDictionary *row in rows) if ([row[@"spotify"] isEqual:requested]) { selected = row; break; }
        if (!selected) return;
        NSMutableDictionary *originalTracks = [NSMutableDictionary dictionary];
        for (id track in loaded) {
            NSString *url = SGAutomaticSpotifyURL([track URI]);
            if (url && !originalTracks[url]) originalTracks[url] = track;
        }
        NSMutableArray *tracks = [NSMutableArray array];
        NSMutableSet *usedUIDs = [NSMutableSet set];
        NSString *selectedUID;
        NSURL *selectedURI;
        for (NSDictionary *row in rows) {
            // The engine rechecks file identity/stat before handing out each snapshot.
            NSString *local = SGAutomaticLocalURI(row);
            NSURL *uri = local ? [NSURL URLWithString:local] : nil;
            if (!uri) return;
            id old = originalTracks[row[@"spotify"]];
            NSString *uid = [old UID];
            if (!uid.length || [usedUIDs containsObject:uid]) uid = [NSString stringWithFormat:@"spoti-local-%@-%@", row[@"position"], row[@"spotify"]];
            [usedUIDs addObject:uid];
            id track = [[trackClass alloc] initWithURI:uri albumURI:[old albumURI] artistURI:[old artistURI] andUID:uid];
            if (!track) return;
            // UIKit also declares a metadata selector returning LPLinkMetadata.
            // Keep the dynamic result untyped until its dictionary shape is checked.
            id originalMetadata = [old metadata];
            NSMutableDictionary *metadata = [originalMetadata isKindOfClass:NSDictionary.class] ?
                [(NSDictionary *)originalMetadata mutableCopy] : [NSMutableDictionary dictionary];
            metadata[@"title"] = row[@"title"] ?: @"";
            metadata[@"artist_name"] = row[@"artist"] ?: @"";
            metadata[@"album_title"] = row[@"album"] ?: @"";
            metadata[@"duration"] = [NSString stringWithFormat:@"%.0f", [row[@"seconds"] doubleValue] * 1000];
            [track setMetadata:metadata];
            // Do not copy an online stream provider onto a spotify:local track.
            [tracks addObject:track];
            if (!selectedURI && [row[@"spotify"] isEqual:requested]) { selectedURI = uri; selectedUID = uid; }
        }
        if (!selectedURI) return;
        id page = [pageClass new]; [page setTracks:tracks];
        id context = [originalContext copy];
        // A local URI prevents a server context resolver from replacing the supplied
        // pages. The queue consists only of verified copies from this exact playlist.
        [context setURI:selectedURI]; [context setURL:nil];
        [context setPages:@[page]]; [context setFallbackPages:@[page]];
        id options = originalOptions ? [originalOptions copy] : [optionsClass new];
        id skip = [skipClass new]; [skip setTrackUri:selectedURI]; [skip setTrackUid:selectedUID];
        [options setSkipTo:skip];
        *resultContext = context; *resultOptions = options;
        playbackDiagnostic(playlist ? contextURL : nil, requested, tracks.count);
        SGLog(@"[SGAutoDownloads] native offline playback redirected count=%lu", (unsigned long)tracks.count);
    } @catch (NSException *error) {
        SGLog(@"[SGAutoDownloads] offline redirect passed through after %@", error.name);
    }
}

%hook SPTEsperantoPlayer
- (id)playContext:(id)context options:(id)options {
    id localContext = context, localOptions = options;
    prepareLocalPlayback(context, options, &localContext, &localOptions);
    return %orig(localContext, localOptions);
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)loggingParams {
    id localContext = context, localOptions = options;
    prepareLocalPlayback(context, options, &localContext, &localOptions);
    return %orig(localContext, localOptions, loggingParams);
}
- (id)playContext:(id)context options:(id)options viewURI:(id)viewURI {
    id localContext = context, localOptions = options;
    prepareLocalPlayback(context, options, &localContext, &localOptions);
    return %orig(localContext, localOptions, viewURI);
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)loggingParams viewURI:(id)viewURI {
    id localContext = context, localOptions = options;
    prepareLocalPlayback(context, options, &localContext, &localOptions);
    return %orig(localContext, localOptions, loggingParams, viewURI);
}
- (id)playContext:(id)context options:(id)options externalReferrer:(id)referrer {
    id localContext = context, localOptions = options;
    prepareLocalPlayback(context, options, &localContext, &localOptions);
    return %orig(localContext, localOptions, referrer);
}
- (id)playContext:(id)context options:(id)options origin:(id)origin {
    id localContext = context, localOptions = options;
    prepareLocalPlayback(context, options, &localContext, &localOptions);
    return %orig(localContext, localOptions, origin);
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)loggingParams origin:(id)origin {
    id localContext = context, localOptions = options;
    prepareLocalPlayback(context, options, &localContext, &localOptions);
    return %orig(localContext, localOptions, loggingParams, origin);
}
%end

%hook _TtC29Connectivity_ReachabilityImpl28ForcedOfflineModeManagerImpl
- (BOOL)isForcedOfflineModeOn {
    BOOL value = %orig;
    observedForcedOffline(value);
    return value;
}
- (void)setForcedOfflineMode:(BOOL)value {
    %orig;
    observedForcedOffline(value);
}
%end

%ctor {
    %init;
    pathQueue = dispatch_queue_create("pw.spoti.local-playback-path", DISPATCH_QUEUE_SERIAL);
    pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(pathMonitor, pathQueue);
    nw_path_monitor_set_update_handler(pathMonitor, ^(nw_path_t path) {
        os_unfair_lock_lock(&pathLock);
        pathKnown = YES;
        pathUnavailable = nw_path_get_status(path) == nw_path_status_unsatisfied;
        os_unfair_lock_unlock(&pathLock);
    });
    nw_path_monitor_start(pathMonitor);
}
