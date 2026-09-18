#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <math.h>
#import <objc/runtime.h>

// Album animated-artwork fallback v4.0.1 — strict no-square handoff
// Transition policy: never expose a static album square or Apple's generic placeholder.
// Keep the previous animation while the next one becomes ready; if there is no previous
// animation, use deliberate black. Switch only when an animated-artwork object is ready.
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

static NSString *SGString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static UIImage *SGAspectFillImage(UIImage *image, CGSize target);
static id SGSyntheticArtworkForAlbum(NSString *albumKey, UIImage *cover, BOOL tall);
static NSString *SGTrackArtworkKey(NSDictionary *info);
#import "AlbumArtworkDebug.h"

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
        SG_DEBUG_EVENT(@"staticImage.pipeline", @"artwork=%@ requested={900,900} result=%@", SGDebugIdentity(artwork), SGDebugImage(image));
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

    if (title.length || artist.length) {
        return [NSString stringWithFormat:@"meta:%@\n%@", artist.lowercaseString, title.lowercaseString];
    }

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

static id SGStrictAnimatedArtworkInit(id self, SEL _cmd, id artworkID, id previewHandler, id videoHandler) {
    (void)previewHandler;
#if SG_ARTWORK_DEBUG
    NSUInteger objectToken = SGDebugNextID();
    NSString *createdTrack = SGDebugTrack();
    // A string identity avoids retaining self through its own stored request blocks.
    __block NSString *identity = SGDebugIdentity(self);
    SG_DEBUG_EVENT(@"animated.init.begin", @"token=%lu object=%@ artworkID=%@ createdTrack=%@ previewPresent=%d videoPresent=%d previewPolicy=black-replaces-original",
        (unsigned long)objectToken, identity, SGDebugQuote(artworkID), SGDebugQuote(createdTrack), previewHandler != nil, videoHandler != nil);
    void (^originalVideo)(CGSize, void (^)(NSURL * _Nullable)) = videoHandler;
    if (originalVideo) {
        videoHandler = [^(CGSize requestedSize, void (^handler)(NSURL * _Nullable)) {
            NSUInteger request = SGDebugNextID();
            NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
            NSString *context = [NSString stringWithFormat:@"token=%lu request=%lu object=%@ artworkID=%@ createdTrack=%@ requestedTrack=%@ requested=%@",
                (unsigned long)objectToken, (unsigned long)request, identity, SGDebugQuote(artworkID),
                SGDebugQuote(createdTrack), SGDebugQuote(SGDebugTrack()), NSStringFromCGSize(requestedSize)];
            SG_DEBUG_EVENT(@"video.request", @"%@ completionPresent=%d", context, handler != nil);
            if (!handler) {
                originalVideo(requestedSize, nil);
                return;
            }
            originalVideo(requestedSize, ^(NSURL *url) {
                SG_DEBUG_URL(@"video.return", [context stringByAppendingFormat:@" latencyMs=%.1f", (NSProcessInfo.processInfo.systemUptime - started) * 1000], url);
                handler(url);
            });
        } copy];
    }
#endif
    void (^blackPreview)(CGSize, void (^)(UIImage * _Nullable)) = ^(CGSize requestedSize, void (^handler)(UIImage * _Nullable)) {
#if SG_ARTWORK_DEBUG
        NSUInteger request = SGDebugNextID();
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
#endif
        SG_DEBUG_EVENT(@"preview.request", @"token=%lu request=%lu object=%@ artworkID=%@ createdTrack=%@ requested=%@ completionPresent=%d source=black",
            (unsigned long)objectToken, (unsigned long)request, identity, SGDebugQuote(artworkID), SGDebugQuote(createdTrack), NSStringFromCGSize(requestedSize), handler != nil);
        if (!handler) return;
        CGSize size = requestedSize;
        if (size.width < 1.0 || size.height < 1.0) size = CGSizeMake(900, 900);
        UIImage *preview = SGSolidBlackImage(size);
        SG_DEBUG_EVENT(@"preview.return", @"token=%lu request=%lu object=%@ result=%@ source=black latencyMs=%.1f", (unsigned long)objectToken, (unsigned long)request, identity, SGDebugImage(preview), (NSProcessInfo.processInfo.systemUptime - started) * 1000);
        handler(preview);
    };
    id initialized = ((id (*)(id, SEL, id, id, id))sgOriginalAnimatedArtworkInit)(self, _cmd, artworkID, blackPreview, videoHandler);
#if SG_ARTWORK_DEBUG
    identity = SGDebugIdentity(initialized);
    SG_DEBUG_EVENT(@"animated.init.end", @"token=%lu object=%@ artworkID=%@", (unsigned long)objectToken, identity, SGDebugQuote(artworkID));
#endif
    return initialized;
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
    SG_DEBUG_EVENT(@"transition.publish", @"reason=hold-timer-black track=%@", SGDebugQuote(SGTrackArtworkKey(info)));
    sgInternalTransitionUpdate = YES;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
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

        if (!square && albumKey.length) {
            square = [sgRealSquareArtwork objectForKey:albumKey] ?: [sgSyntheticSquareArtwork objectForKey:albumKey];
            if (square) patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = square;
        }
        if (!tall && albumKey.length) {
            tall = [sgRealTallArtwork objectForKey:albumKey] ?: [sgSyntheticTallArtwork objectForKey:albumKey];
            if (tall) patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = tall;
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
        if (!square && !tall) return;
        sgPresentedSquareArtwork = square;
        sgPresentedTallArtwork = tall;
    }
}

static NSDictionary *SGInfoHoldingPreviousAnimation(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return info;
    NSMutableDictionary *patched = [info mutableCopy];

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
    SG_DEBUG_EVENT(@"hold.clear", @"wasHolding=%d generation=%lu", sgHoldingPreviousAnimation, (unsigned long)sgPreviousHoldGeneration);
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
    SG_DEBUG_EVENT(@"hold.start", @"generation=%lu track=%@ square=%@ tall=%@ timeoutMs=6000", (unsigned long)generation, SGDebugQuote(trackKey), SGDebugIdentity(sgHeldSquareArtwork), SGDebugIdentity(sgHeldTallArtwork));

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SG_DEBUG_EVENT(@"hold.timer", @"generation=%lu currentGeneration=%lu holding=%d", (unsigned long)generation, (unsigned long)sgPreviousHoldGeneration, sgHoldingPreviousAnimation);
        if (generation != sgPreviousHoldGeneration || !sgHoldingPreviousAnimation) return;
        if (![sgPreviousHoldTrackKey isEqualToString:trackKey]) return;
        NSDictionary *current = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
        if (![(SGTrackArtworkKey(current) ?: @"") isEqualToString:trackKey]) return;

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
    SG_DEBUG_EVENT(@"empty.schedule", @"generation=%lu delayMs=1250", (unsigned long)generation);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SG_DEBUG_EVENT(@"empty.timer", @"generation=%lu currentGeneration=%lu sinceNonEmptyMs=%.1f", (unsigned long)generation, (unsigned long)sgEmptyPacketGeneration, (CFAbsoluteTimeGetCurrent() - sgLastNonEmptyPacketAt) * 1000);
        if (generation != sgEmptyPacketGeneration) return;
        if ((CFAbsoluteTimeGetCurrent() - sgLastNonEmptyPacketAt) < 1.20) return;

        sgLastRawNowPlayingInfo = nil;
        sgCurrentTrackKey = nil;
        sgPresentedSquareArtwork = nil;
        sgPresentedTallArtwork = nil;
        sgBlackTransitionActive = NO;
        sgBlackTransitionTrackKey = nil;
        SGClearPreviousHold();

        sgInternalTransitionUpdate = YES;
        SG_DEBUG_EVENT(@"empty.clear", @"publishing=nil generation=%lu", (unsigned long)generation);
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        sgInternalTransitionUpdate = NO;
    });
}

static void SGRememberStaticArtwork(NSDictionary *info, NSString *albumKey) {
    if (albumKey.length == 0) return;
    UIImage *image = SGStaticCover(info);
    if (!SGUsableCover(image)) return;

    [sgStaticImageByAlbum setObject:image forKey:albumKey];
}

static UIImage *SGBestStaticImage(NSDictionary *info, NSString *albumKey) {
    UIImage *current = SGStaticCover(info);
    if (SGUsableCover(current)) return current;
    UIImage *albumImage = albumKey.length ? [sgStaticImageByAlbum objectForKey:albumKey] : nil;
    return SGUsableCover(albumImage) ? albumImage : nil;
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
    SG_DEBUG_URL(@"generation.queued", [NSString stringWithFormat:@"target=%@", NSStringFromCGSize(target)], url);
    dispatch_async(sgArtworkVideoQueue, ^{
        @autoreleasepool {
            SG_DEBUG_URL(@"generation.start", [NSString stringWithFormat:@"target=%@", NSStringFromCGSize(target)], url);
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:url.path]) {
                SG_DEBUG_URL(@"generation.cacheHit", @"validation=exists-only", url);
                completion(url);
                return;
            }

            [fm removeItemAtURL:url error:nil];

            NSError *error = nil;
            AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
            if (!writer || error) {
                SG_DEBUG_EVENT(@"generation.failed", @"stage=writer-init error=%@", SGDebugQuote(error));
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
                SG_DEBUG_EVENT(@"generation.failed", @"stage=can-add-input error=%@", SGDebugQuote(writer.error));
                completion(nil);
                return;
            }
            [writer addInput:input];
            if (![writer startWriting]) {
                SG_DEBUG_EVENT(@"generation.failed", @"stage=start-writing error=%@", SGDebugQuote(writer.error));
                completion(nil);
                return;
            }
            [writer startSessionAtSourceTime:kCMTimeZero];

            UIImage *normalized = SGAspectFillImage(sourceImage, target);
            CIImage *base = [[CIImage alloc] initWithImage:normalized];
            CIContext *ciContext = [CIContext contextWithOptions:nil];
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

            BOOL ok = YES;
#if SG_ARTWORK_DEBUG
            NSTimeInterval lastWaitLog = NSProcessInfo.processInfo.systemUptime;
#endif
            for (NSInteger i = 0; i < frameCount; i++) {
                @autoreleasepool {
                    while (!input.readyForMoreMediaData) {
#if SG_ARTWORK_DEBUG
                        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                        if (now - lastWaitLog >= 5.0) {
                            lastWaitLog = now;
                            SG_DEBUG_EVENT(@"generation.wait", @"url=%@ frame=%ld status=%ld error=%@", SGDebugQuote(url.absoluteString), (long)i, (long)writer.status, SGDebugQuote(writer.error));
                        }
#endif
                        [NSThread sleepForTimeInterval:0.002];
                    }

                    CVPixelBufferRef buffer = NULL;
                    CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer);
                    if (cv != kCVReturnSuccess || !buffer) {
                        ok = NO;
                        break;
                    }

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
                SG_DEBUG_EVENT(@"generation.failed", @"stage=render-or-append status=%ld error=%@", (long)writer.status, SGDebugQuote(writer.error));
                [writer cancelWriting];
                [fm removeItemAtURL:url error:nil];
                completion(nil);
                return;
            }

            [writer finishWritingWithCompletionHandler:^{
                SG_DEBUG_URL(@"generation.finish", [NSString stringWithFormat:@"status=%ld error=%@", (long)writer.status, SGDebugQuote(writer.error)], url);
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
    SG_DEBUG_EVENT(@"synthetic.ensure", @"album=%@ cover=%@ cachedSquare=%@ cachedTall=%@", SGDebugQuote(albumKey), SGDebugImage(cover), SGDebugIdentity([sgSyntheticSquareArtwork objectForKey:albumKey]), SGDebugIdentity([sgSyntheticTallArtwork objectForKey:albumKey]));
    if ([sgSyntheticSquareArtwork objectForKey:albumKey] || [sgSyntheticTallArtwork objectForKey:albumKey]) return;

    @synchronized (sgSyntheticGenerationInFlight) {
        if ([sgSyntheticGenerationInFlight containsObject:albumKey]) {
            SG_DEBUG_EVENT(@"synthetic.inFlight", @"album=%@", SGDebugQuote(albumKey));
            return;
        }
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
            SG_DEBUG_URL(@"synthetic.complete", [NSString stringWithFormat:@"album=%@ variant=1x1", SGDebugQuote(albumKey)], result);
            if (result) SGSyntheticArtworkForAlbum(albumKey, cover, NO);
            squareDone = YES;
            finishOne();
            NSDictionary *current = sgLastRawNowPlayingInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
            SG_DEBUG_EVENT(@"synthetic.republishCheck", @"variant=1x1 album=%@ matchesCurrent=%d", SGDebugQuote(albumKey), [SGAlbumArtworkKey(current) isEqualToString:albumKey]);
            if ([SGAlbumArtworkKey(current) isEqualToString:albumKey]) [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = current;
        });
    });
    SGWriteKenBurnsVideo(cover, CGSizeMake(540, 720), tallURL, ^(NSURL *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SG_DEBUG_URL(@"synthetic.complete", [NSString stringWithFormat:@"album=%@ variant=3x4", SGDebugQuote(albumKey)], result);
            if (result) SGSyntheticArtworkForAlbum(albumKey, cover, YES);
            tallDone = YES;
            finishOne();
            NSDictionary *current = sgLastRawNowPlayingInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
            SG_DEBUG_EVENT(@"synthetic.republishCheck", @"variant=3x4 album=%@ matchesCurrent=%d", SGDebugQuote(albumKey), [SGAlbumArtworkKey(current) isEqualToString:albumKey]);
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

        SG_DEBUG_URL(@"synthetic.fileCheck", [NSString stringWithFormat:@"album=%@ variant=%@", SGDebugQuote(albumKey), variant], videoURL);
        if (![[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) return nil;

        NSString *artworkID = [NSString stringWithFormat:@"spoti.pw.synthetic.%@.%@", token, variant];
        UIImage *blackPreview = SGSolidBlackImage(target);
        MPMediaItemAnimatedArtwork *animated =
            [[MPMediaItemAnimatedArtwork alloc]
                initWithArtworkID:artworkID
                previewImageRequestHandler:^(CGSize requestedSize, void (^handler)(UIImage * _Nullable)) {
                    handler(blackPreview);
                }
                videoAssetFileURLRequestHandler:^(CGSize requestedSize, void (^handler)(NSURL * _Nullable)) {
                    handler(videoURL);
                }];

        if (animated) [cache setObject:animated forKey:albumKey];
        SG_DEBUG_EVENT(@"synthetic.cached", @"album=%@ variant=%@ object=%@", SGDebugQuote(albumKey), variant, SGDebugIdentity(animated));
        return animated;
    }
    return nil;
}

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    __unused NSUInteger debugPacket = SG_DEBUG_BEGIN(info, sgInternalTransitionUpdate);
    if (sgInternalTransitionUpdate) {
        %orig(SG_DEBUG_OUTPUT(debugPacket, @"internal-pass-through", info));
        return;
    }

    if (![info isKindOfClass:NSDictionary.class] || info.count == 0) {
        SGScheduleDeferredEmptyClear();

        NSDictionary *current = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
        if ([current isKindOfClass:NSDictionary.class] && current.count) {
            SG_DEBUG_EVENT(@"nowPlaying.suppressed", @"packet=%lu reason=empty-retain-current", (unsigned long)debugPacket);
            return;
        }

        id black = SGBlackArtwork();
        NSMutableDictionary *guard = [NSMutableDictionary dictionary];
        if (black) guard[MPMediaItemPropertyArtwork] = black;
        %orig(SG_DEBUG_OUTPUT(debugPacket, @"empty-inject-black", guard));
        return;
    }

    ++sgEmptyPacketGeneration;
    sgLastNonEmptyPacketAt = CFAbsoluteTimeGetCurrent();
    sgLastRawNowPlayingInfo = [info copy];

    if (@available(iOS 26.0, *)) {
        NSString *albumKey = SGAlbumArtworkKey(info);
        NSString *trackKey = SGTrackArtworkKey(info);
        UIImage *incomingCover = SGStaticCover(info);
        BOOL incomingCoverUsable = SGUsableCover(incomingCover);
        BOOL topLevelTrackChanged = trackKey.length && ![sgCurrentTrackKey isEqualToString:trackKey];
        SG_DEBUG_EVENT(@"pipeline.state", @"packet=%lu trackChanged=%d previousTrack=%@ coverUsable=%d albumKey=%@ holding=%d blackActive=%d presentedSquare=%@ presentedTall=%@", (unsigned long)debugPacket, topLevelTrackChanged, SGDebugQuote(sgCurrentTrackKey), incomingCoverUsable, SGDebugQuote(albumKey), sgHoldingPreviousAnimation, sgBlackTransitionActive, SGDebugIdentity(sgPresentedSquareArtwork), SGDebugIdentity(sgPresentedTallArtwork));

        if (topLevelTrackChanged) {
            sgCurrentTrackKey = [trackKey copy];
            sgBlackTransitionActive = NO;

            NSDictionary *clean = SGInfoWithoutHeldAnimation(info);
            BOOL hasReadyAnimation = NO;
            NSDictionary *next = SGInfoWithReadyAnimation(clean, albumKey, YES, &hasReadyAnimation);

            if (hasReadyAnimation) {
                NSDictionary *shown = SGInfoWithHandoffStatic(next);
                SGRememberPresentedAnimation(shown);
                SGClearPreviousHold();
                if (albumKey.length && incomingCoverUsable) SGRememberStaticArtwork(info, albumKey);
                %orig(SG_DEBUG_OUTPUT(debugPacket, @"track-change-new-animation-black-static", shown));
                return;
            }

            if (albumKey.length && incomingCoverUsable) {
                SGRememberStaticArtwork(info, albumKey);
                SGEnsureFastSyntheticArtwork(albumKey, incomingCover);
            }

            if (SGHasPresentedAnimation()) {
                SGStartPreviousHold(trackKey);
                %orig(SG_DEBUG_OUTPUT(debugPacket, @"track-change-hold-old-animation-black-static", SGInfoHoldingPreviousAnimation(info)));
                return;
            }

            sgBlackTransitionActive = YES;
            sgBlackTransitionTrackKey = [trackKey copy];
            %orig(SG_DEBUG_OUTPUT(debugPacket, @"track-change-no-animation-inject-black", SGInfoWithBlackArtwork(info)));
            return;
        }

        if (sgHoldingPreviousAnimation && trackKey.length &&
            [sgPreviousHoldTrackKey isEqualToString:trackKey]) {
            NSDictionary *clean = SGInfoWithoutHeldAnimation(info);
            BOOL hasReadyAnimation = NO;
            NSDictionary *next = SGInfoWithReadyAnimation(clean, albumKey, YES, &hasReadyAnimation);

            if (hasReadyAnimation) {
                NSDictionary *shown = SGInfoWithHandoffStatic(next);
                SGRememberPresentedAnimation(shown);
                SGClearPreviousHold();
                if (albumKey.length && incomingCoverUsable) SGRememberStaticArtwork(info, albumKey);
                %orig(SG_DEBUG_OUTPUT(debugPacket, @"hold-handoff-new-animation-black-static", shown));
                return;
            }

            if (albumKey.length && incomingCoverUsable) SGEnsureFastSyntheticArtwork(albumKey, incomingCover);

            if (CFAbsoluteTimeGetCurrent() < sgPreviousHoldUntil) {
                %orig(SG_DEBUG_OUTPUT(debugPacket, @"hold-continue-old-animation-black-static", SGInfoHoldingPreviousAnimation(info)));
                return;
            }

            sgHoldingPreviousAnimation = NO;
            sgBlackTransitionActive = YES;
            sgBlackTransitionTrackKey = [trackKey copy];
            %orig(SG_DEBUG_OUTPUT(debugPacket, @"hold-expired-inject-black", SGInfoWithBlackArtwork(clean)));
            return;
        }

        if (sgBlackTransitionActive && trackKey.length &&
            [sgBlackTransitionTrackKey isEqualToString:trackKey]) {
            NSDictionary *clean = SGInfoWithoutHeldAnimation(info);
            BOOL hasReadyAnimation = NO;
            NSDictionary *next = SGInfoWithReadyAnimation(clean, albumKey, YES, &hasReadyAnimation);
            if (hasReadyAnimation) {
                NSDictionary *shown = SGInfoWithHandoffStatic(next);
                SGRememberPresentedAnimation(shown);
                sgBlackTransitionActive = NO;
                SGClearPreviousHold();
                if (albumKey.length && incomingCoverUsable) SGRememberStaticArtwork(info, albumKey);
                %orig(SG_DEBUG_OUTPUT(debugPacket, @"black-handoff-new-animation-black-static", shown));
                return;
            }

            if (albumKey.length && incomingCoverUsable) SGEnsureFastSyntheticArtwork(albumKey, incomingCover);
            %orig(SG_DEBUG_OUTPUT(debugPacket, @"black-wait-no-ready-animation", SGInfoWithBlackArtwork(clean)));
            return;
        }

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

            if (patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] ||
                patched[MPNowPlayingInfoProperty3x4AnimatedArtwork]) {
                SGRememberPresentedAnimation(patched);
                %orig(SG_DEBUG_OUTPUT(debugPacket, @"no-album-packet-or-previous-animation-black-static", patched));
            } else {
                %orig(SG_DEBUG_OUTPUT(debugPacket, @"no-album-inject-black", SGInfoWithBlackArtwork(info)));
            }
            return;
        }

        SGRememberStaticArtwork(info, albumKey);

        id square = info[MPNowPlayingInfoProperty1x1AnimatedArtwork];
        id tall = info[MPNowPlayingInfoProperty3x4AnimatedArtwork];
        if (square) [sgRealSquareArtwork setObject:square forKey:albumKey];
        if (tall) [sgRealTallArtwork setObject:tall forKey:albumKey];

        id fallbackSquare = square ?: [sgRealSquareArtwork objectForKey:albumKey];
        id fallbackTall = tall ?: [sgRealTallArtwork objectForKey:albumKey];
        UIImage *cover = SGBestStaticImage(info, albumKey);

        if (!fallbackSquare && cover) fallbackSquare = SGSyntheticArtworkForAlbum(albumKey, cover, NO);
        if (!fallbackTall && cover) fallbackTall = SGSyntheticArtworkForAlbum(albumKey, cover, YES);
        if ((!fallbackSquare || !fallbackTall) && cover) SGEnsureFastSyntheticArtwork(albumKey, cover);

        NSMutableDictionary *patched = [info mutableCopy];
        if (!square && fallbackSquare) patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = fallbackSquare;
        if (!tall && fallbackTall) patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = fallbackTall;

        BOOL hasAnimation = (patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] != nil ||
                             patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] != nil);
        if (hasAnimation) {
            id black = SGBlackArtwork();
            if (black) patched[MPMediaItemPropertyArtwork] = black;
            SGRememberPresentedAnimation(patched);
            %orig(SG_DEBUG_OUTPUT(debugPacket, @"album-packet-or-cached-animation-black-static", patched));
            return;
        }

        if (cover) SGEnsureFastSyntheticArtwork(albumKey, cover);
        %orig(SG_DEBUG_OUTPUT(debugPacket, @"album-no-animation-inject-black", SGInfoWithBlackArtwork(info)));
        return;
    }

    %orig(SG_DEBUG_OUTPUT(debugPacket, @"pre-ios26-pass-through", info));
}
%end

%ctor {
    SG_DEBUG_START();
    sgRealSquareArtwork = [NSCache new];
    sgRealTallArtwork = [NSCache new];
    sgSyntheticSquareArtwork = [NSCache new];
    sgSyntheticTallArtwork = [NSCache new];
    sgStaticImageByAlbum = [NSCache new];
    sgSyntheticGenerationInFlight = [NSMutableSet set];
    sgRealSquareArtwork.countLimit = 48;
    sgRealTallArtwork.countLimit = 48;
    sgSyntheticSquareArtwork.countLimit = 12;
    sgSyntheticTallArtwork.countLimit = 12;
    sgStaticImageByAlbum.countLimit = 32;
    sgArtworkVideoQueue = dispatch_queue_create("pw.spoti.synthetic-artwork", DISPATCH_QUEUE_SERIAL);

    if (@available(iOS 26.0, *)) {
        Class animatedClass = objc_getClass("MPMediaItemAnimatedArtwork");
        SEL initSelector = NSSelectorFromString(@"initWithArtworkID:previewImageRequestHandler:videoAssetFileURLRequestHandler:");
        Method initMethod = animatedClass ? class_getInstanceMethod(animatedClass, initSelector) : NULL;
        if (initMethod) sgOriginalAnimatedArtworkInit = method_setImplementation(initMethod, (IMP)SGStrictAnimatedArtworkInit);
        SG_DEBUG_EVENT(@"hook.install", @"class=%@ selector=%@ found=%d installed=%d", animatedClass, NSStringFromSelector(initSelector), initMethod != NULL, sgOriginalAnimatedArtworkInit != NULL);
    }

    %init;
}
