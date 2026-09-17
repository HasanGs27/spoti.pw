#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <math.h>
#import <objc/runtime.h>

// Album animated-artwork fallback v5.1 — cold-start static gate + stuck-placeholder watchdog
// Transition policy: never hand SpringBoard an animated-artwork object until its video FILE URL
// has already been resolved and exists locally. The first track of a fresh session is forced through
// a short static-only gate (real cover, else black) before animation is allowed. Tracks that begin
// without a ready animation also get a one-shot static reset watchdog so SpringBoard cannot remain
// stuck on its gray missing-image tile indefinitely.
// 1) Keep Spotify's real animated artwork when the current track has it.
// 2) Reuse real animated artwork already seen on another track of the same album.
// 3) If the album has no known animation, synthesize a gentle looping Ken Burns animation
//    from the static cover and expose it to iOS as MPMediaItemAnimatedArtwork.
//
// The synthetic video is generated lazily only when iOS actually asks for it and is cached
// in Library/Caches so subsequent requests are cheap.

static NSCache<NSString *, id> *sgRealSquareArtwork;
static NSCache<NSString *, id> *sgRealTallArtwork;
static NSCache<NSString *, id> *sgSyntheticSquareArtwork;
static NSCache<NSString *, id> *sgSyntheticTallArtwork;
static NSCache<NSString *, UIImage *> *sgStaticImageByAlbum;
static NSCache<NSString *, id> *sgStaticArtworkByAlbum;
static id sgLastGoodStaticArtwork;
static UIImage *sgLastGoodStaticImage;
static dispatch_queue_t sgArtworkVideoQueue;
static NSMutableSet<NSString *> *sgSyntheticGenerationInFlight;
static NSString *sgCurrentTrackKey;
static BOOL sgInternalTransitionUpdate;
static BOOL sgBlackTransitionActive;
static NSString *sgBlackTransitionTrackKey;

// The animation that is actually being shown. On a skip we can keep it alive briefly
// instead of exposing the next track's static square while its animation is still loading.
static id sgPresentedSquareArtwork;
static id sgPresentedTallArtwork;
static id sgHeldSquareArtwork;
static id sgHeldTallArtwork;
static BOOL sgHoldingPreviousAnimation;
static NSString *sgPreviousHoldTrackKey;
static CFTimeInterval sgPreviousHoldUntil;
static NSUInteger sgPreviousHoldGeneration;
static NSDictionary *sgLastRawNowPlayingInfo;
static NSUInteger sgEmptyPacketGeneration;
static CFTimeInterval sgLastNonEmptyPacketAt;
static IMP sgOriginalAnimatedArtworkInit;
static char sgAnimatedStateKey;
static char sgAnimatedTrustedSquareKey;
static char sgAnimatedTrustedTallKey;

// Fresh-session protection. SpringBoard is most fragile on the very first Now Playing item: it can
// enter the animated-artwork presentation before its internal static container exists. Force that
// first track through a short static-only phase, then re-run the raw packet once the UI is settled.
static BOOL sgColdStartGateActive;
static NSString *sgColdStartTrackKey;
static CFTimeInterval sgColdStartGateUntil;
static NSUInteger sgColdStartGateGeneration;

// One-shot recovery for a track that started before an animation asset was ready. If nothing ready
// supersedes it quickly, republish a static-only packet, then let the normal hook reconsider raw
// metadata. This deliberately kicks SpringBoard out of a stuck gray animated-artwork container.
static NSUInteger sgArtworkRecoveryGeneration;

// A native MPMediaItemAnimatedArtwork is not "ready" merely because the object exists.
// SpringBoard can switch to its animated-artwork container immediately and show Apple's gray
// missing-image tile while the object's video handler is still resolving the asset. Cache the
// actual local file URLs first; only then is that aspect allowed into Now Playing metadata.
static BOOL SGAnimatedURLIsReady(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL || url.path.length == 0) return NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path];
}

static NSMutableDictionary *SGAnimatedState(id artwork) {
    return artwork ? objc_getAssociatedObject(artwork, &sgAnimatedStateKey) : nil;
}

static BOOL SGAnimatedArtworkReady(id artwork, BOOL tall) {
    if (!artwork) return NO;
    if (objc_getAssociatedObject(artwork, tall ? &sgAnimatedTrustedTallKey : &sgAnimatedTrustedSquareKey)) return YES;
    NSMutableDictionary *state = SGAnimatedState(artwork);
    if (!state) return NO;
    NSString *key = tall ? @"tallURL" : @"squareURL";
    NSURL *url = nil;
    @synchronized (state) { url = state[key]; }
    return SGAnimatedURLIsReady(url);
}

static void SGReapplyRawNowPlayingWhenAssetReady(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *raw = sgLastRawNowPlayingInfo;
        if (![raw isKindOfClass:NSDictionary.class] || raw.count == 0) return;
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        center.nowPlayingInfo = raw;
    });
}

static NSString *SGString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static UIImage *SGAspectFillImage(UIImage *image, CGSize target);
static id SGSyntheticArtworkForAlbum(NSString *albumKey, UIImage *cover, BOOL tall);
static NSDictionary *SGInfoWithSafeArtworkFloor(NSDictionary *info);
static NSDictionary *SGInfoStaticOnly(NSDictionary *info);
static void SGScheduleArtworkRecovery(NSString *trackKey);

static NSString *SGAlbumArtworkKey(NSDictionary *info) {
    NSString *album = SGString(info[MPMediaItemPropertyAlbumTitle]);
    if (album.length == 0) return nil;

    NSString *albumArtist = SGString(info[MPMediaItemPropertyAlbumArtist]);
    if (albumArtist.length == 0) albumArtist = SGString(info[MPMediaItemPropertyArtist]);

    NSString *artistPart = albumArtist.length ? albumArtist.lowercaseString : @"";
    return [NSString stringWithFormat:@"%@\n%@", artistPart, album.lowercaseString];
}

static UIImage *SGStaticCover(NSDictionary *info) {
    id artwork = info[MPMediaItemPropertyArtwork];
    if ([artwork isKindOfClass:UIImage.class]) return (UIImage *)artwork;

    if ([artwork isKindOfClass:MPMediaItemArtwork.class]) {
        UIImage *image = [(MPMediaItemArtwork *)artwork imageWithSize:CGSizeMake(900, 900)];
        if (image) return image;
    }
    return nil;
}

static BOOL SGUsableCover(UIImage *image) {
    return image && image.size.width >= 96.0 && image.size.height >= 96.0;
}

static NSString *SGTrackArtworkKey(NSDictionary *info) {
    NSString *title = SGString(info[MPMediaItemPropertyTitle]) ?: @"";
    NSString *artist = SGString(info[MPMediaItemPropertyArtist]) ?: @"";

    // Title/artist update before Spotify's persistent ID during some skips. If we key on the
    // persistent ID first, the tweak can miss the first packet of the new song and iOS briefly
    // draws its generic photo placeholder. Prefer the visible metadata so the black guard starts
    // on the very first frame of a track change.
    if (title.length || artist.length) {
        return [NSString stringWithFormat:@"meta:%@\n%@", artist.lowercaseString, title.lowercaseString];
    }

    // Last-resort key for rare packets that do not contain title/artist yet.
    id persistent = info[MPMediaItemPropertyPersistentID];
    if ([persistent respondsToSelector:@selector(stringValue)]) {
        NSString *v = [persistent stringValue];
        if (v.length) return [@"pid:" stringByAppendingString:v];
    }
    return nil;
}

static MPMediaItemArtwork *SGArtworkFromImage(UIImage *image) {
    if (!SGUsableCover(image)) return nil;
    CGSize bounds = image.size;
    return [[MPMediaItemArtwork alloc] initWithBoundsSize:bounds requestHandler:^UIImage * _Nonnull(CGSize requestedSize) {
        if (requestedSize.width < 1 || requestedSize.height < 1) return image;
        return SGAspectFillImage(image, requestedSize);
    }];
}

static UIImage *SGSolidBlackImage(CGSize size) {
    if (size.width < 1.0 || size.height < 1.0) size = CGSizeMake(900, 900);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor blackColor] setFill];
        [ctx fillRect:(CGRect){CGPointZero, size}];
    }];
}

static id SGStrictAnimatedArtworkInit(id self, SEL _cmd, id artworkID, __unused id previewHandler, id videoHandler) {
    // Never make SpringBoard wait on Spotify's preview callback. A concrete black UIImage is
    // returned synchronously; the normal static artwork slot underneath remains the real cover
    // when we have one. This removes another route to the gray system placeholder.
    void (^safePreview)(CGSize, void (^)(UIImage * _Nullable)) = ^(CGSize requestedSize, void (^handler)(UIImage * _Nullable)) {
        if (!handler) return;
        CGSize size = requestedSize;
        if (size.width < 1.0 || size.height < 1.0) size = CGSizeMake(900, 900);
        handler(SGSolidBlackImage(size));
    };

    void (^originalVideo)(CGSize, void (^)(NSURL * _Nullable)) =
        (void (^)(CGSize, void (^)(NSURL * _Nullable)))videoHandler;
    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    // The handler seen by iOS first serves the pre-resolved local URL. If an unexpected size is
    // requested, it can still ask Spotify, but a valid result is cached for subsequent requests.
    void (^safeVideo)(CGSize, void (^)(NSURL * _Nullable)) = ^(CGSize requestedSize, void (^handler)(NSURL * _Nullable)) {
        if (!handler) return;
        BOOL tall = requestedSize.height > requestedSize.width * 1.15;
        NSString *key = tall ? @"tallURL" : @"squareURL";
        NSURL *cached = nil;
        @synchronized (state) { cached = state[key]; }
        if (SGAnimatedURLIsReady(cached)) {
            handler(cached);
            return;
        }
        if (!originalVideo) {
            handler(nil);
            return;
        }
        originalVideo(requestedSize, ^(NSURL *url) {
            if (SGAnimatedURLIsReady(url)) {
                @synchronized (state) { state[key] = url; }
            }
            handler(SGAnimatedURLIsReady(url) ? url : nil);
        });
    };

    id animated = ((id (*)(id, SEL, id, id, id))sgOriginalAnimatedArtworkInit)(self, _cmd, artworkID, safePreview, safeVideo);
    if (!animated) return animated;
    objc_setAssociatedObject(animated, &sgAnimatedStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Prime BOTH known lock-screen aspects before this object is ever allowed into Now Playing.
    // Native handlers may answer asynchronously; until they do, setNowPlayingInfo strips the
    // corresponding key and leaves the previous animation / cover / black on screen.
    if (originalVideo) {
        void (^prime)(CGSize, NSString *) = ^(CGSize size, NSString *key) {
            originalVideo(size, ^(NSURL *url) {
                if (!SGAnimatedURLIsReady(url)) return;
                BOOL becameReady = NO;
                @synchronized (state) {
                    if (!state[key]) {
                        state[key] = url;
                        becameReady = YES;
                    }
                }
                if (becameReady) SGReapplyRawNowPlayingWhenAssetReady();
            });
        };
        prime(CGSizeMake(540, 540), @"squareURL");
        prime(CGSizeMake(540, 720), @"tallURL");
    }
    return animated;
}

static id SGBlackArtwork(void) {
    static id artwork;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        artwork = SGArtworkFromImage(SGSolidBlackImage(CGSizeMake(900, 900)));
    });
    return artwork;
}

static void SGPublishTransitionInfo(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return;
    NSDictionary *safe = info.count ? SGInfoWithSafeArtworkFloor(info) : info;
    sgInternalTransitionUpdate = YES;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = safe;
    sgInternalTransitionUpdate = NO;
}

static NSDictionary *SGInfoWithBlackArtwork(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return info;
    NSMutableDictionary *patched = [info mutableCopy];
    id black = SGBlackArtwork();
    if (black) patched[MPMediaItemPropertyArtwork] = black;
    if (@available(iOS 26.0, *)) {
        [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
    }
    return patched;
}

// Preserve Spotify's native animation and, when already cached, inject the album fallback
// immediately. This never waits for the static cover. The static slot can therefore be black
// while the animated artwork starts on the very first usable metadata packet.
static NSDictionary *SGInfoWithReadyAnimation(NSDictionary *info, NSString *albumKey, BOOL blackStaticPreview, BOOL *hasReadyAnimation) {
    if (hasReadyAnimation) *hasReadyAnimation = NO;
    if (![info isKindOfClass:NSDictionary.class]) return info;

    NSMutableDictionary *patched = [info mutableCopy];
    if (blackStaticPreview) {
        id black = SGBlackArtwork();
        if (black) patched[MPMediaItemPropertyArtwork] = black;
    }

    if (@available(iOS 26.0, *)) {
        id square = patched[MPNowPlayingInfoProperty1x1AnimatedArtwork];
        id tall = patched[MPNowPlayingInfoProperty3x4AnimatedArtwork];
        if (square && !SGAnimatedArtworkReady(square, NO)) {
            [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
            square = nil;
        }
        if (tall && !SGAnimatedArtworkReady(tall, YES)) {
            [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
            tall = nil;
        }

        if (!square && albumKey.length) {
            id candidate = [sgRealSquareArtwork objectForKey:albumKey] ?: [sgSyntheticSquareArtwork objectForKey:albumKey];
            if (SGAnimatedArtworkReady(candidate, NO)) {
                square = candidate;
                patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = square;
            }
        }
        if (!tall && albumKey.length) {
            id candidate = [sgRealTallArtwork objectForKey:albumKey] ?: [sgSyntheticTallArtwork objectForKey:albumKey];
            if (SGAnimatedArtworkReady(candidate, YES)) {
                tall = candidate;
                patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = tall;
            }
        }

        if (hasReadyAnimation) *hasReadyAnimation = (square != nil || tall != nil);
    }
    return patched;
}


static BOOL SGHasPresentedAnimation(void) {
    return sgPresentedSquareArtwork != nil || sgPresentedTallArtwork != nil;
}

static NSDictionary *SGInfoWithoutHeldAnimation(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return info;
    if (!sgHeldSquareArtwork && !sgHeldTallArtwork) return info;
    NSMutableDictionary *patched = [info mutableCopy];
    if (@available(iOS 26.0, *)) {
        id square = patched[MPNowPlayingInfoProperty1x1AnimatedArtwork];
        id tall = patched[MPNowPlayingInfoProperty3x4AnimatedArtwork];
        if (square && square == sgHeldSquareArtwork) [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        if (tall && tall == sgHeldTallArtwork) [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
    }
    return patched;
}

static void SGRememberPresentedAnimation(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return;
    if (@available(iOS 26.0, *)) {
        id square = info[MPNowPlayingInfoProperty1x1AnimatedArtwork];
        id tall = info[MPNowPlayingInfoProperty3x4AnimatedArtwork];
        if (square && !SGAnimatedArtworkReady(square, NO)) square = nil;
        if (tall && !SGAnimatedArtworkReady(tall, YES)) tall = nil;
        if (!square && !tall) return;
        sgPresentedSquareArtwork = square;
        sgPresentedTallArtwork = tall;
    }
}

static NSDictionary *SGInfoHoldingPreviousAnimation(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return info;
    NSMutableDictionary *patched = [info mutableCopy];

    // Strict no-square rule: the static slot is always black during a handoff. The old
    // animated object stays alive, so SpringBoard can keep playing it without ever getting
    // an album-cover frame to flash between videos.
    id black = SGBlackArtwork();
    if (black) patched[MPMediaItemPropertyArtwork] = black;
    if (@available(iOS 26.0, *)) {
        if (sgHeldSquareArtwork) patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = sgHeldSquareArtwork;
        else [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        if (sgHeldTallArtwork) patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = sgHeldTallArtwork;
        else [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
    }
    return patched;
}

static NSDictionary *SGInfoWithHandoffStatic(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return info;
    NSMutableDictionary *patched = [info mutableCopy];
    id black = SGBlackArtwork();
    if (black) patched[MPMediaItemPropertyArtwork] = black;
    return patched;
}

static void SGClearPreviousHold(void) {
    sgHoldingPreviousAnimation = NO;
    sgPreviousHoldTrackKey = nil;
    sgPreviousHoldUntil = 0;
    sgHeldSquareArtwork = nil;
    sgHeldTallArtwork = nil;
    ++sgPreviousHoldGeneration;
}

static void SGStartPreviousHold(NSString *trackKey) {
    if (!trackKey.length || !SGHasPresentedAnimation()) return;
    sgHeldSquareArtwork = sgPresentedSquareArtwork;
    sgHeldTallArtwork = sgPresentedTallArtwork;
    sgHoldingPreviousAnimation = YES;
    sgPreviousHoldTrackKey = [trackKey copy];
    sgPreviousHoldUntil = CFAbsoluteTimeGetCurrent() + 6.0;
    NSUInteger generation = ++sgPreviousHoldGeneration;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sgPreviousHoldGeneration || !sgHoldingPreviousAnimation) return;
        if (![sgPreviousHoldTrackKey isEqualToString:trackKey]) return;
        NSDictionary *current = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
        if (![(SGTrackArtworkKey(current) ?: @"") isEqualToString:trackKey]) return;

        // Failsafe only: if the next animation still did not become ready after six seconds,
        // stop showing the old track and fall back to black until a real/new animation arrives.
        sgHoldingPreviousAnimation = NO;
        sgPreviousHoldUntil = 0;
        sgBlackTransitionActive = YES;
        sgBlackTransitionTrackKey = [trackKey copy];
        ++sgPreviousHoldGeneration;
        SGPublishTransitionInfo(SGInfoWithBlackArtwork(current));
    });
}

static void SGScheduleDeferredEmptyClear(void) {
    NSUInteger generation = ++sgEmptyPacketGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sgEmptyPacketGeneration) return;
        if ((CFAbsoluteTimeGetCurrent() - sgLastNonEmptyPacketAt) < 1.20) return;

        // Never clear Now Playing because of an empty packet while Spotify is inactive/backgrounded.
        // Locking the phone can suspend Spotify right after such a packet; clearing here hands
        // SpringBoard an empty artwork state and produces Apple's gray photo placeholder.
        UIApplicationState state = UIApplication.sharedApplication.applicationState;
        if (state != UIApplicationStateActive) return;

        // Only an empty packet that remains empty while Spotify is foreground-active is treated
        // as a real stop. Transient skip/lock packets keep the previous protected artwork.
        sgLastRawNowPlayingInfo = nil;
        sgCurrentTrackKey = nil;
        sgPresentedSquareArtwork = nil;
        sgPresentedTallArtwork = nil;
        sgBlackTransitionActive = NO;
        sgBlackTransitionTrackKey = nil;
        SGClearPreviousHold();

        sgInternalTransitionUpdate = YES;
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        sgInternalTransitionUpdate = NO;
    });
}

static void SGRememberStaticArtwork(NSDictionary *info, NSString *albumKey) {
    UIImage *image = SGStaticCover(info);
    if (!SGUsableCover(image)) return;

    id rawArtwork = info[MPMediaItemPropertyArtwork];
    id stableArtwork = [rawArtwork isKindOfClass:MPMediaItemArtwork.class] ? rawArtwork : SGArtworkFromImage(image);
    if (albumKey.length) {
        [sgStaticImageByAlbum setObject:image forKey:albumKey];
        if (stableArtwork) [sgStaticArtworkByAlbum setObject:stableArtwork forKey:albumKey];
    }
    sgLastGoodStaticImage = image;
    if (stableArtwork) sgLastGoodStaticArtwork = stableArtwork;
}

static UIImage *SGBestStaticImage(NSDictionary *info, NSString *albumKey) {
    UIImage *current = SGStaticCover(info);
    if (SGUsableCover(current)) return current;
    UIImage *albumImage = albumKey.length ? [sgStaticImageByAlbum objectForKey:albumKey] : nil;
    if (SGUsableCover(albumImage)) return albumImage;
    return SGUsableCover(sgLastGoodStaticImage) ? sgLastGoodStaticImage : nil;
}

static id SGBestStaticArtwork(NSDictionary *info, NSString *albumKey) {
    UIImage *current = SGStaticCover(info);
    id rawArtwork = info[MPMediaItemPropertyArtwork];
    if (SGUsableCover(current)) {
        if ([rawArtwork isKindOfClass:MPMediaItemArtwork.class]) return rawArtwork;
        id made = SGArtworkFromImage(current);
        if (made) return made;
    }
    id albumArtwork = albumKey.length ? [sgStaticArtworkByAlbum objectForKey:albumKey] : nil;
    return albumArtwork ?: sgLastGoodStaticArtwork ?: SGBlackArtwork();
}

// Hard invariant for v4.3: every non-empty packet handed to iOS owns a valid artwork object.
// Current real cover wins; then same-album cache; then last known real cover; black is the floor.
static NSDictionary *SGInfoWithSafeArtworkFloor(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class] || info.count == 0) return info;
    NSMutableDictionary *patched = [info mutableCopy];
    NSString *albumKey = SGAlbumArtworkKey(info);
    id safe = SGBestStaticArtwork(info, albumKey);
    if (safe) patched[MPMediaItemPropertyArtwork] = safe;

    // Crucial v5 rule: an animated-artwork OBJECT is not enough. If its aspect-specific local
    // video file has not been resolved yet, remove that key entirely so SpringBoard stays in the
    // normal static-artwork path instead of drawing Apple's animated-artwork placeholder tile.
    if (@available(iOS 26.0, *)) {
        id square = patched[MPNowPlayingInfoProperty1x1AnimatedArtwork];
        id tall = patched[MPNowPlayingInfoProperty3x4AnimatedArtwork];
        if (square && !SGAnimatedArtworkReady(square, NO))
            [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        if (tall && !SGAnimatedArtworkReady(tall, YES))
            [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
    }
    return patched;
}

static NSDictionary *SGInfoStaticOnly(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class] || info.count == 0) return info;
    NSMutableDictionary *patched = [SGInfoWithSafeArtworkFloor(info) mutableCopy];
    if (@available(iOS 26.0, *)) {
        [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
    }
    return patched;
}

static void SGScheduleColdStartRelease(NSString *trackKey, NSUInteger generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.38 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sgColdStartGateGeneration || !sgColdStartGateActive) return;
        if (![sgColdStartTrackKey isEqualToString:trackKey]) return;
        NSDictionary *raw = sgLastRawNowPlayingInfo;
        if (![(SGTrackArtworkKey(raw) ?: @"") isEqualToString:trackKey]) return;
        sgColdStartGateActive = NO;
        sgColdStartGateUntil = 0;
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = raw;
    });
}

static void SGScheduleArtworkRecovery(NSString *trackKey) {
    if (!trackKey.length) return;
    NSUInteger generation = ++sgArtworkRecoveryGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sgArtworkRecoveryGeneration) return;
        NSDictionary *raw = sgLastRawNowPlayingInfo;
        if (![(SGTrackArtworkKey(raw) ?: @"") isEqualToString:trackKey]) return;

        NSString *albumKey = SGAlbumArtworkKey(raw);
        BOOL ready = NO;
        if (@available(iOS 26.0, *)) {
            id square = raw[MPNowPlayingInfoProperty1x1AnimatedArtwork];
            id tall = raw[MPNowPlayingInfoProperty3x4AnimatedArtwork];
            ready = SGAnimatedArtworkReady(square, NO) || SGAnimatedArtworkReady(tall, YES);
            if (!ready && albumKey.length) {
                id cachedSquare = [sgRealSquareArtwork objectForKey:albumKey] ?: [sgSyntheticSquareArtwork objectForKey:albumKey];
                id cachedTall = [sgRealTallArtwork objectForKey:albumKey] ?: [sgSyntheticTallArtwork objectForKey:albumKey];
                ready = SGAnimatedArtworkReady(cachedSquare, NO) || SGAnimatedArtworkReady(cachedTall, YES);
            }
        }
        if (ready) return;

        // Force a real static presentation now. This is intentionally a separate publication from
        // the animated packet: it resets SpringBoard's artwork presentation state instead of merely
        // changing keys inside the already-stuck animated container.
        SGPublishTransitionInfo(SGInfoStaticOnly(raw));

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != sgArtworkRecoveryGeneration) return;
            NSDictionary *latest = sgLastRawNowPlayingInfo;
            if (![(SGTrackArtworkKey(latest) ?: @"") isEqualToString:trackKey]) return;
            [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = latest;
        });
    });
}

static NSString *SGSafeToken(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *token = [data base64EncodedStringWithOptions:0];
    token = [token stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    token = [token stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    token = [token stringByReplacingOccurrencesOfString:@"=" withString:@""];
    if (token.length > 80) token = [token substringToIndex:80];
    return [NSString stringWithFormat:@"%@-%08lx", token, (unsigned long)text.hash];
}

static NSURL *SGArtworkVideoDirectory(void) {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
    NSURL *dir = [[urls firstObject] URLByAppendingPathComponent:@"spoti.pw-generated-artwork" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static UIImage *SGAspectFillImage(UIImage *image, CGSize target) {
    if (!image || target.width <= 0 || target.height <= 0) return image;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor blackColor] setFill];
        [ctx fillRect:(CGRect){CGPointZero, target}];
        CGFloat scale = MAX(target.width / image.size.width, target.height / image.size.height);
        CGSize s = CGSizeMake(image.size.width * scale, image.size.height * scale);
        CGRect r = CGRectMake((target.width - s.width) / 2.0, (target.height - s.height) / 2.0, s.width, s.height);
        [image drawInRect:r];
    }];
}

static void SGWriteKenBurnsVideo(UIImage *sourceImage, CGSize target, NSURL *url, void (^completion)(NSURL *result)) {
    dispatch_async(sgArtworkVideoQueue, ^{
        @autoreleasepool {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:url.path]) {
                completion(url);
                return;
            }

            [fm removeItemAtURL:url error:nil];

            NSError *error = nil;
            AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
            if (!writer || error) {
                completion(nil);
                return;
            }

            const NSInteger fps = 24;
            const NSInteger seconds = 4;
            const NSInteger frameCount = fps * seconds;
            NSInteger width = (NSInteger)target.width;
            NSInteger height = (NSInteger)target.height;

            NSDictionary *compression = @{
                AVVideoAverageBitRateKey: @(2200000),
                AVVideoExpectedSourceFrameRateKey: @(fps),
                AVVideoMaxKeyFrameIntervalKey: @(fps * 2),
            };
            NSDictionary *settings = @{
                AVVideoCodecKey: AVVideoCodecTypeH264,
                AVVideoWidthKey: @(width),
                AVVideoHeightKey: @(height),
                AVVideoCompressionPropertiesKey: compression,
            };

            AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
            input.expectsMediaDataInRealTime = NO;

            NSDictionary *attrs = @{
                (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (NSString *)kCVPixelBufferWidthKey: @(width),
                (NSString *)kCVPixelBufferHeightKey: @(height),
                (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            AVAssetWriterInputPixelBufferAdaptor *adaptor =
                [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:input sourcePixelBufferAttributes:attrs];

            if (![writer canAddInput:input]) {
                completion(nil);
                return;
            }
            [writer addInput:input];
            if (![writer startWriting]) {
                completion(nil);
                return;
            }
            [writer startSessionAtSourceTime:kCMTimeZero];

            UIImage *normalized = SGAspectFillImage(sourceImage, target);
            CIImage *base = [[CIImage alloc] initWithImage:normalized];
            CIContext *ciContext = [CIContext contextWithOptions:nil];
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

            BOOL ok = YES;
            for (NSInteger i = 0; i < frameCount; i++) {
                @autoreleasepool {
                    while (!input.readyForMoreMediaData) {
                        [NSThread sleepForTimeInterval:0.002];
                    }

                    CVPixelBufferRef buffer = NULL;
                    CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer);
                    if (cv != kCVReturnSuccess || !buffer) {
                        ok = NO;
                        break;
                    }

                    // Perfectly looping motion: gentle zoom + tiny pan.
                    double phase = (2.0 * M_PI * (double)i) / (double)frameCount;
                    CGFloat zoom = 1.015 + 0.045 * (0.5 - 0.5 * cos(phase));
                    CGFloat panX = sin(phase) * target.width * 0.012;
                    CGFloat panY = sin(phase + M_PI_2) * target.height * 0.008;

                    CIImage *frame = [base imageByApplyingTransform:CGAffineTransformMakeScale(zoom, zoom)];
                    CGRect e = frame.extent;
                    CGFloat tx = (target.width - e.size.width) / 2.0 - e.origin.x + panX;
                    CGFloat ty = (target.height - e.size.height) / 2.0 - e.origin.y + panY;
                    frame = [frame imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];
                    frame = [frame imageByCroppingToRect:CGRectMake(0, 0, target.width, target.height)];

                    [ciContext render:frame
                      toCVPixelBuffer:buffer
                              bounds:CGRectMake(0, 0, target.width, target.height)
                          colorSpace:colorSpace];

                    CMTime time = CMTimeMake((int64_t)i, (int32_t)fps);
                    if (![adaptor appendPixelBuffer:buffer withPresentationTime:time]) ok = NO;
                    CVPixelBufferRelease(buffer);
                    if (!ok) break;
                }
            }

            CGColorSpaceRelease(colorSpace);
            [input markAsFinished];

            if (!ok) {
                [writer cancelWriting];
                [fm removeItemAtURL:url error:nil];
                completion(nil);
                return;
            }

            [writer finishWritingWithCompletionHandler:^{
                if (writer.status == AVAssetWriterStatusCompleted) completion(url);
                else {
                    [fm removeItemAtURL:url error:nil];
                    completion(nil);
                }
            }];
        }
    });
}


static void SGEnsureFastSyntheticArtwork(NSString *albumKey, UIImage *cover) {
    if (!albumKey.length || !SGUsableCover(cover)) return;
    if ([sgSyntheticSquareArtwork objectForKey:albumKey] || [sgSyntheticTallArtwork objectForKey:albumKey]) return;

    @synchronized (sgSyntheticGenerationInFlight) {
        if ([sgSyntheticGenerationInFlight containsObject:albumKey]) return;
        [sgSyntheticGenerationInFlight addObject:albumKey];
    }

    NSString *token = SGSafeToken(albumKey);
    NSURL *squareURL = [SGArtworkVideoDirectory() URLByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@-1x1.mp4", token]];
    NSURL *tallURL = [SGArtworkVideoDirectory() URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@-3x4.mp4", token]];

    __block BOOL squareDone = NO, tallDone = NO;
    void (^finishOne)(void) = ^{
        if (!squareDone || !tallDone) return;
        @synchronized (sgSyntheticGenerationInFlight) {
            [sgSyntheticGenerationInFlight removeObject:albumKey];
        }
    };

    SGWriteKenBurnsVideo(cover, CGSizeMake(540, 540), squareURL, ^(NSURL *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) SGSyntheticArtworkForAlbum(albumKey, cover, NO);
            squareDone = YES;
            finishOne();
            NSDictionary *current = sgLastRawNowPlayingInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
            if ([SGAlbumArtworkKey(current) isEqualToString:albumKey]) [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = current;
        });
    });
    SGWriteKenBurnsVideo(cover, CGSizeMake(540, 720), tallURL, ^(NSURL *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) SGSyntheticArtworkForAlbum(albumKey, cover, YES);
            tallDone = YES;
            finishOne();
            NSDictionary *current = sgLastRawNowPlayingInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
            if ([SGAlbumArtworkKey(current) isEqualToString:albumKey]) [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = current;
        });
    });
}


static id SGSyntheticArtworkForAlbum(NSString *albumKey, UIImage *cover, BOOL tall) {
    if (albumKey.length == 0 || !cover) return nil;

    NSCache *cache = tall ? sgSyntheticTallArtwork : sgSyntheticSquareArtwork;
    id existing = [cache objectForKey:albumKey];
    if (existing) return existing;

    if (@available(iOS 26.0, *)) {
        CGSize target = tall ? CGSizeMake(540, 720) : CGSizeMake(540, 540);
        NSString *variant = tall ? @"3x4" : @"1x1";
        NSString *token = SGSafeToken(albumKey);
        NSURL *videoURL = [SGArtworkVideoDirectory() URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"%@-%@.mp4", token, variant]];

        // Important: never publish an animated-artwork object until its video is fully ready.
        // iOS otherwise replaces the normal cover with its generic broken-image placeholder while
        // the asset is being rendered in the background.
        if (![[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) return nil;

        NSString *artworkID = [NSString stringWithFormat:@"spoti.pw.synthetic.%@.%@", token, variant];
        UIImage *blackPreview = SGSolidBlackImage(target);
        MPMediaItemAnimatedArtwork *animated =
            [[MPMediaItemAnimatedArtwork alloc]
                initWithArtworkID:artworkID
                previewImageRequestHandler:^(CGSize requestedSize, void (^handler)(UIImage * _Nullable)) {
                    // Never let iOS use the album square while the video asset is starting.
                    // The preview is deliberate black; the animation replaces it as soon as ready.
                    handler(blackPreview);
                }
                videoAssetFileURLRequestHandler:^(CGSize requestedSize, void (^handler)(NSURL * _Nullable)) {
                    handler(videoURL);
                }];

        if (animated) {
            objc_setAssociatedObject(animated, tall ? &sgAnimatedTrustedTallKey : &sgAnimatedTrustedSquareKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [cache setObject:animated forKey:albumKey];
        }
        return animated;
    }
    return nil;
}


static NSDictionary *SGStrictProtectedInfo(NSDictionary *raw) {
    if (![raw isKindOfClass:NSDictionary.class] || raw.count == 0) return nil;

    NSMutableDictionary *patched = [SGInfoWithSafeArtworkFloor(raw) mutableCopy] ?: [raw mutableCopy];

    if (@available(iOS 26.0, *)) {
        id square = patched[MPNowPlayingInfoProperty1x1AnimatedArtwork];
        id tall = patched[MPNowPlayingInfoProperty3x4AnimatedArtwork];

        // During lock/background handoff Spotify sometimes republishes metadata without the
        // animated-artwork keys. Keep the animation already known to be on screen instead.
        if (!square && sgPresentedSquareArtwork)
            patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = sgPresentedSquareArtwork;
        if (!tall && sgPresentedTallArtwork)
            patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = sgPresentedTallArtwork;
    }
    return patched;
}

static void SGRepublishStrictNowPlaying(void) {
    NSDictionary *raw = sgLastRawNowPlayingInfo;
    if (![raw isKindOfClass:NSDictionary.class] || raw.count == 0) {
        NSDictionary *current = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
        if ([current isKindOfClass:NSDictionary.class] && current.count) raw = current;
    }

    NSDictionary *protected = SGStrictProtectedInfo(raw);
    if (!protected) {
        // Cold/edge case: even with no metadata, publish a real black MPMediaItemArtwork rather
        // than let SpringBoard manufacture its gray "missing image" tile.
        protected = SGInfoWithBlackArtwork(@{});
    }
    SGPublishTransitionInfo(protected);
}

static void SGScheduleStrictBackgroundRefresh(void) {
    // Spotify can issue one last metadata packet just after WillResignActive. Re-assert our safe
    // packet a couple of times while the app still has execution time so the final state inherited
    // by SpringBoard is animation-or-black, never an empty/static square.
    SGRepublishStrictNowPlaying();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
            SGRepublishStrictNowPlaying();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
            SGRepublishStrictNowPlaying();
    });
}

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (sgInternalTransitionUpdate) {
        %orig(info.count ? SGInfoWithSafeArtworkFloor(info) : info);
        return;
    }

    if (![info isKindOfClass:NSDictionary.class] || info.count == 0) {
        // Spotify emits transient empty packets during skips. Passing them through makes
        // SpringBoard forget the animated artwork and draw its generic gray image placeholder.
        // Keep whatever is currently shown and only honour the clear if it remains empty long
        // enough to look like a real playback stop.
        SGScheduleDeferredEmptyClear();

        NSDictionary *current = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
        if ([current isKindOfClass:NSDictionary.class] && current.count) return;

        // Cold-start guard: if the very first packet is empty there is nothing to preserve.
        // Publish a valid black artwork briefly instead of allowing Apple's gray placeholder.
        // No prior packet exists. Publish a concrete artwork object anyway; prefer the last
        // known real cover if one exists, otherwise black. Never hand SpringBoard an empty slot.
        id floor = sgLastGoodStaticArtwork ?: SGBlackArtwork();
        NSMutableDictionary *guard = [NSMutableDictionary dictionary];
        if (floor) guard[MPMediaItemPropertyArtwork] = floor;
        %orig(guard);
        return;
    }

    ++sgEmptyPacketGeneration; // cancels a deferred clear from a transient empty packet
    sgLastNonEmptyPacketAt = CFAbsoluteTimeGetCurrent();

    // Keep Spotify's untouched packet. Generated-animation completion must re-run the hook with
    // this raw metadata, never with one of our temporary A->B handoff dictionaries.
    sgLastRawNowPlayingInfo = [info copy];

    if (@available(iOS 26.0, *)) {
        NSString *albumKey = SGAlbumArtworkKey(info);
        NSString *trackKey = SGTrackArtworkKey(info);
        UIImage *incomingCover = SGStaticCover(info);
        BOOL incomingCoverUsable = SGUsableCover(incomingCover);
        BOOL topLevelTrackChanged = trackKey.length && ![sgCurrentTrackKey isEqualToString:trackKey];
        BOOL firstTrackOfSession = topLevelTrackChanged && sgCurrentTrackKey.length == 0;

        if (firstTrackOfSession) {
            sgCurrentTrackKey = [trackKey copy];
            sgColdStartGateActive = YES;
            sgColdStartTrackKey = [trackKey copy];
            sgColdStartGateUntil = CFAbsoluteTimeGetCurrent() + 0.38;
            NSUInteger generation = ++sgColdStartGateGeneration;
            ++sgArtworkRecoveryGeneration;

            if (albumKey.length && incomingCoverUsable) {
                SGRememberStaticArtwork(info, albumKey);
                SGEnsureFastSyntheticArtwork(albumKey, incomingCover);
            }

            %orig(SGInfoStaticOnly(info));
            SGScheduleColdStartRelease(trackKey, generation);
            SGScheduleArtworkRecovery(trackKey);
            return;
        }

        if (sgColdStartGateActive && trackKey.length && [sgColdStartTrackKey isEqualToString:trackKey] &&
            CFAbsoluteTimeGetCurrent() < sgColdStartGateUntil) {
            if (albumKey.length && incomingCoverUsable) {
                SGRememberStaticArtwork(info, albumKey);
                SGEnsureFastSyntheticArtwork(albumKey, incomingCover);
            }
            %orig(SGInfoStaticOnly(info));
            return;
        }

        if (sgColdStartGateActive && trackKey.length && [sgColdStartTrackKey isEqualToString:trackKey]) {
            sgColdStartGateActive = NO;
            sgColdStartGateUntil = 0;
        }

        if (topLevelTrackChanged) {
            sgCurrentTrackKey = [trackKey copy];
            sgBlackTransitionActive = NO;

            // Do not mistake the animation we injected for the previous track for B's own animation.
            NSDictionary *clean = SGInfoWithoutHeldAnimation(info);
            BOOL hasReadyAnimation = NO;
            NSDictionary *next = SGInfoWithReadyAnimation(clean, albumKey, YES, &hasReadyAnimation);

            if (hasReadyAnimation) {
                ++sgArtworkRecoveryGeneration;
                // Best case: B is already ready. Keep A's static preview only for the handoff frame,
                // while B's animation itself starts immediately.
                NSDictionary *shown = SGInfoWithHandoffStatic(next);
                SGRememberPresentedAnimation(shown);
                SGClearPreviousHold();
                if (albumKey.length && incomingCoverUsable) SGRememberStaticArtwork(info, albumKey);
                %orig(shown);
                return;
            }

            // B is not ready. Cache its real cover for generation, but never publish that square.
            // The cover is data only; visually we keep A (or black on a cold start).
            if (albumKey.length && incomingCoverUsable) {
                SGRememberStaticArtwork(info, albumKey);
                SGEnsureFastSyntheticArtwork(albumKey, incomingCover);
            }

            SGScheduleArtworkRecovery(trackKey);

            if (SGHasPresentedAnimation()) {
                SGStartPreviousHold(trackKey);
                %orig(SGInfoHoldingPreviousAnimation(info));
                return;
            }

            // Cold start: there is no previous animation to hold. Use the real cover as a
            // valid waiting frame when available; otherwise the hard floor becomes black.
            sgBlackTransitionActive = YES;
            sgBlackTransitionTrackKey = [trackKey copy];
            %orig(SGInfoWithSafeArtworkFloor(info));
            return;
        }

        // During the A->B hold, B's animation gets absolute priority the instant it becomes ready.
        if (sgHoldingPreviousAnimation && trackKey.length &&
            [sgPreviousHoldTrackKey isEqualToString:trackKey]) {
            NSDictionary *clean = SGInfoWithoutHeldAnimation(info);
            BOOL hasReadyAnimation = NO;
            NSDictionary *next = SGInfoWithReadyAnimation(clean, albumKey, YES, &hasReadyAnimation);

            if (hasReadyAnimation) {
                ++sgArtworkRecoveryGeneration;
                NSDictionary *shown = SGInfoWithHandoffStatic(next);
                SGRememberPresentedAnimation(shown);
                SGClearPreviousHold();
                if (albumKey.length && incomingCoverUsable) SGRememberStaticArtwork(info, albumKey);
                %orig(shown);
                return;
            }

            if (albumKey.length && incomingCoverUsable) SGEnsureFastSyntheticArtwork(albumKey, incomingCover);

            if (CFAbsoluteTimeGetCurrent() < sgPreviousHoldUntil) {
                %orig(SGInfoHoldingPreviousAnimation(info));
                return;
            }

            // The timer normally performs this switch; this is the synchronous safety path.
            sgHoldingPreviousAnimation = NO;
            sgBlackTransitionActive = YES;
            sgBlackTransitionTrackKey = [trackKey copy];
            %orig(SGInfoWithBlackArtwork(clean));
            return;
        }

        // If the hold expired, black stays in place until B's animation is actually ready.
        if (sgBlackTransitionActive && trackKey.length &&
            [sgBlackTransitionTrackKey isEqualToString:trackKey]) {
            NSDictionary *clean = SGInfoWithoutHeldAnimation(info);
            BOOL hasReadyAnimation = NO;
            NSDictionary *next = SGInfoWithReadyAnimation(clean, albumKey, YES, &hasReadyAnimation);
            if (hasReadyAnimation) {
                ++sgArtworkRecoveryGeneration;
                NSDictionary *shown = SGInfoWithHandoffStatic(next);
                SGRememberPresentedAnimation(shown);
                sgBlackTransitionActive = NO;
                SGClearPreviousHold();
                if (albumKey.length && incomingCoverUsable) SGRememberStaticArtwork(info, albumKey);
                %orig(shown);
                return;
            }

            if (albumKey.length && incomingCoverUsable) SGEnsureFastSyntheticArtwork(albumKey, incomingCover);
            %orig(SGInfoWithSafeArtworkFloor(clean));
            return;
        }

        // Transitional packets without album metadata are a common source of the square flash.
        // Never expose their static artwork. If an animation is already being shown, keep it;
        // otherwise publish deliberate black until album/animation metadata catches up.
        if (!albumKey.length) {
            NSMutableDictionary *patched = [info mutableCopy];
            id black = SGBlackArtwork();
            if (black) patched[MPMediaItemPropertyArtwork] = black;

            id packetSquare = patched[MPNowPlayingInfoProperty1x1AnimatedArtwork];
            id packetTall = patched[MPNowPlayingInfoProperty3x4AnimatedArtwork];
            if (!packetSquare && sgPresentedSquareArtwork)
                patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = sgPresentedSquareArtwork;
            if (!packetTall && sgPresentedTallArtwork)
                patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = sgPresentedTallArtwork;

            NSDictionary *safePatched = SGInfoWithSafeArtworkFloor(patched);
            if (safePatched[MPNowPlayingInfoProperty1x1AnimatedArtwork] ||
                safePatched[MPNowPlayingInfoProperty3x4AnimatedArtwork])
                SGRememberPresentedAnimation(safePatched);
            %orig(safePatched);
            return;
        }

        // Steady-state album handling: preserve Spotify's native animation, then reuse/generate
        // the album fallback exactly as before. There is no artificial animation delay here.
        SGRememberStaticArtwork(info, albumKey);

        id rawSquare = info[MPNowPlayingInfoProperty1x1AnimatedArtwork];
        id rawTall = info[MPNowPlayingInfoProperty3x4AnimatedArtwork];
        if (rawSquare) [sgRealSquareArtwork setObject:rawSquare forKey:albumKey];
        if (rawTall) [sgRealTallArtwork setObject:rawTall forKey:albumKey];

        id square = SGAnimatedArtworkReady(rawSquare, NO) ? rawSquare : nil;
        id tall = SGAnimatedArtworkReady(rawTall, YES) ? rawTall : nil;
        id cachedSquare = [sgRealSquareArtwork objectForKey:albumKey];
        id cachedTall = [sgRealTallArtwork objectForKey:albumKey];
        id fallbackSquare = square ?: (SGAnimatedArtworkReady(cachedSquare, NO) ? cachedSquare : nil);
        id fallbackTall = tall ?: (SGAnimatedArtworkReady(cachedTall, YES) ? cachedTall : nil);
        UIImage *cover = SGBestStaticImage(info, albumKey);

        if (!fallbackSquare && cover) fallbackSquare = SGSyntheticArtworkForAlbum(albumKey, cover, NO);
        if (!fallbackTall && cover) fallbackTall = SGSyntheticArtworkForAlbum(albumKey, cover, YES);
        if ((!fallbackSquare || !fallbackTall) && cover) SGEnsureFastSyntheticArtwork(albumKey, cover);

        NSMutableDictionary *patched = [info mutableCopy];
        if (!square) [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        if (!tall) [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
        if (!square && fallbackSquare) patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = fallbackSquare;
        if (!tall && fallbackTall) patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = fallbackTall;

        BOOL hasAnimation = (patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] != nil ||
                             patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] != nil);
        if (hasAnimation) {
            ++sgArtworkRecoveryGeneration;
            // If iOS asks for the static slot while the video opens/restarts, give it a real album
            // cover when available; otherwise last-good cover, then black. Never an empty slot.
            NSDictionary *shown = SGInfoWithSafeArtworkFloor(patched);
            SGRememberPresentedAnimation(shown);
            %orig(shown);
            return;
        }

        // No animation object is ready yet. A valid real cover is allowed as the waiting frame;
        // black is used only if no usable cover exists. This is the anti-placeholder floor.
        if (cover) SGEnsureFastSyntheticArtwork(albumKey, cover);
        SGScheduleArtworkRecovery(trackKey);
        %orig(SGInfoStaticOnly(info));
        return;
    }

    %orig(info);
}
%end



%ctor {
    sgRealSquareArtwork = [NSCache new];
    sgRealTallArtwork = [NSCache new];
    sgSyntheticSquareArtwork = [NSCache new];
    sgSyntheticTallArtwork = [NSCache new];
    sgStaticImageByAlbum = [NSCache new];
    sgStaticArtworkByAlbum = [NSCache new];
    sgSyntheticGenerationInFlight = [NSMutableSet set];
    sgRealSquareArtwork.countLimit = 48;
    sgRealTallArtwork.countLimit = 48;
    sgSyntheticSquareArtwork.countLimit = 12;
    sgSyntheticTallArtwork.countLimit = 12;
    sgStaticImageByAlbum.countLimit = 32;
    sgStaticArtworkByAlbum.countLimit = 64;
    sgArtworkVideoQueue = dispatch_queue_create("pw.spoti.synthetic-artwork", DISPATCH_QUEUE_SERIAL);

    if (@available(iOS 26.0, *)) {
        Class animatedClass = objc_getClass("MPMediaItemAnimatedArtwork");
        SEL initSelector = NSSelectorFromString(@"initWithArtworkID:previewImageRequestHandler:videoAssetFileURLRequestHandler:");
        Method initMethod = animatedClass ? class_getInstanceMethod(animatedClass, initSelector) : NULL;
        if (initMethod) sgOriginalAnimatedArtworkInit = method_setImplementation(initMethod, (IMP)SGStrictAnimatedArtworkInit);
    }

    NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
    [notifications addObserverForName:UIApplicationWillResignActiveNotification
                               object:nil
                                queue:[NSOperationQueue mainQueue]
                           usingBlock:^(__unused NSNotification *note) { SGScheduleStrictBackgroundRefresh(); }];
    [notifications addObserverForName:UIApplicationDidEnterBackgroundNotification
                               object:nil
                                queue:[NSOperationQueue mainQueue]
                           usingBlock:^(__unused NSNotification *note) { SGScheduleStrictBackgroundRefresh(); }];

    %init;
}
