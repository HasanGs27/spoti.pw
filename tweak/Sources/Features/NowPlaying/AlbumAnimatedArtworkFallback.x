#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <math.h>

// Album animated-artwork fallback v3.4.1 — cinematic black transition
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
static NSCache<NSString *, id> *sgStaticArtworkByAlbum;
static NSCache<NSString *, UIImage *> *sgStaticImageByAlbum;
static id sgLastGoodStaticArtwork;
static UIImage *sgLastGoodStaticImage;
static dispatch_queue_t sgArtworkVideoQueue;
static NSMutableSet<NSString *> *sgSyntheticGenerationInFlight;
static NSMutableSet<NSString *> *sgDelayedAnimatedReapply;
static NSString *sgCurrentTrackKey;
static CFTimeInterval sgFallbackHoldUntil;
static BOOL sgInternalTransitionUpdate;
static BOOL sgBlackTransitionActive;
static NSString *sgBlackTransitionTrackKey;
static NSUInteger sgBlackTransitionGeneration;

static NSString *SGString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static UIImage *SGAspectFillImage(UIImage *image, CGSize target);

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
    id persistent = info[MPMediaItemPropertyPersistentID];
    if ([persistent respondsToSelector:@selector(stringValue)]) {
        NSString *v = [persistent stringValue];
        if (v.length) return [@"pid:" stringByAppendingString:v];
    }
    NSString *title = SGString(info[MPMediaItemPropertyTitle]) ?: @"";
    NSString *artist = SGString(info[MPMediaItemPropertyArtist]) ?: @"";
    // Do not include the album in the fallback key: Spotify often publishes title/artist first
    // and fills the album a few frames later during a skip. Keeping the key stable lets the
    // black waiting frame fade smoothly into the real cover instead of being treated as a new track.
    return [NSString stringWithFormat:@"%@\n%@", artist.lowercaseString, title.lowercaseString];
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

static UIImage *SGImageWithBrightness(UIImage *image, CGFloat brightness) {
    if (!SGUsableCover(image)) return nil;
    brightness = MAX(0.0, MIN(1.0, brightness));
    CGSize size = image.size;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor blackColor] setFill];
        [ctx fillRect:(CGRect){CGPointZero, size}];
        [image drawInRect:(CGRect){CGPointZero, size} blendMode:kCGBlendModeNormal alpha:brightness];
    }];
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
    sgInternalTransitionUpdate = YES;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
    sgInternalTransitionUpdate = NO;
}

static NSDictionary *SGInfoWithStaticImage(NSDictionary *info, UIImage *image) {
    if (![info isKindOfClass:NSDictionary.class] || !SGUsableCover(image)) return info;
    NSMutableDictionary *patched = [info mutableCopy];
    id artwork = SGArtworkFromImage(image);
    if (artwork) patched[MPMediaItemPropertyArtwork] = artwork;
    if (@available(iOS 26.0, *)) {
        [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
    }
    return patched;
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

static void SGStartBlackToArtworkFade(NSDictionary *finalInfo, NSString *trackKey, UIImage *cover) {
    if (![finalInfo isKindOfClass:NSDictionary.class] || trackKey.length == 0 || !SGUsableCover(cover)) return;

    NSUInteger generation = ++sgBlackTransitionGeneration;
    sgBlackTransitionActive = YES;
    sgBlackTransitionTrackKey = [trackKey copy];

    // Start from a deliberate black frame instead of iOS' generic photo placeholder.
    SGPublishTransitionInfo(SGInfoWithBlackArtwork(finalInfo));

    NSArray<NSNumber *> *brightnessSteps = @[@0.18, @0.42, @0.70, @0.90];
    NSArray<NSNumber *> *delaySteps = @[@0.055, @0.110, @0.170, @0.230];

    for (NSUInteger i = 0; i < brightnessSteps.count; i++) {
        CGFloat brightness = brightnessSteps[i].doubleValue;
        NSTimeInterval delay = delaySteps[i].doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != sgBlackTransitionGeneration) return;
            if (![sgBlackTransitionTrackKey isEqualToString:trackKey]) return;
            UIImage *frame = SGImageWithBrightness(cover, brightness);
            if (frame) SGPublishTransitionInfo(SGInfoWithStaticImage(finalInfo, frame));
        });
    }

    // Finish on the true artwork, then immediately let the normal hook restore the animation.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sgBlackTransitionGeneration) return;
        if (![sgBlackTransitionTrackKey isEqualToString:trackKey]) return;
        sgBlackTransitionActive = NO;
        sgFallbackHoldUntil = CFAbsoluteTimeGetCurrent();
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        center.nowPlayingInfo = finalInfo;
    });
}

static void SGRememberStaticArtwork(NSDictionary *info, NSString *albumKey) {
    if (albumKey.length == 0) return;
    UIImage *image = SGStaticCover(info);
    if (!SGUsableCover(image)) return;

    id originalArtwork = info[MPMediaItemPropertyArtwork];
    id stableArtwork = [originalArtwork isKindOfClass:MPMediaItemArtwork.class] ? originalArtwork : SGArtworkFromImage(image);
    if (stableArtwork) {
        [sgStaticArtworkByAlbum setObject:stableArtwork forKey:albumKey];
        sgLastGoodStaticArtwork = stableArtwork;
    }
    [sgStaticImageByAlbum setObject:image forKey:albumKey];
    sgLastGoodStaticImage = image;
}

static UIImage *SGBestStaticImage(NSDictionary *info, NSString *albumKey) {
    UIImage *current = SGStaticCover(info);
    if (SGUsableCover(current)) return current;
    UIImage *albumImage = albumKey.length ? [sgStaticImageByAlbum objectForKey:albumKey] : nil;
    return SGUsableCover(albumImage) ? albumImage : sgLastGoodStaticImage;
}

static id SGBestStaticArtwork(NSDictionary *info, NSString *albumKey) {
    UIImage *current = SGStaticCover(info);
    id original = info[MPMediaItemPropertyArtwork];
    if (SGUsableCover(current)) {
        if ([original isKindOfClass:MPMediaItemArtwork.class]) return original;
        return SGArtworkFromImage(current);
    }
    id albumArtwork = albumKey.length ? [sgStaticArtworkByAlbum objectForKey:albumKey] : nil;
    return albumArtwork ?: sgLastGoodStaticArtwork;
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

static id SGSyntheticArtworkForAlbum(NSString *albumKey, UIImage *cover, BOOL tall) {
    if (albumKey.length == 0 || !cover) return nil;

    NSCache *cache = tall ? sgSyntheticTallArtwork : sgSyntheticSquareArtwork;
    id existing = [cache objectForKey:albumKey];
    if (existing) return existing;

    if (@available(iOS 26.0, *)) {
        CGSize target = tall ? CGSizeMake(540, 720) : CGSizeMake(540, 540);
        UIImage *base = SGAspectFillImage(cover, target);
        NSString *variant = tall ? @"3x4" : @"1x1";
        NSString *token = SGSafeToken(albumKey);
        NSURL *videoURL = [SGArtworkVideoDirectory() URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"%@-%@.mp4", token, variant]];

        // Important: never publish an animated-artwork object until its video is fully ready.
        // iOS otherwise replaces the normal cover with its generic broken-image placeholder while
        // the asset is being rendered in the background.
        if (![[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) return nil;

        NSString *artworkID = [NSString stringWithFormat:@"spoti.pw.synthetic.%@.%@", token, variant];
        MPMediaItemAnimatedArtwork *animated =
            [[MPMediaItemAnimatedArtwork alloc]
                initWithArtworkID:artworkID
                previewImageRequestHandler:^(CGSize requestedSize, void (^handler)(UIImage * _Nullable)) {
                    handler(base);
                }
                videoAssetFileURLRequestHandler:^(CGSize requestedSize, void (^handler)(NSURL * _Nullable)) {
                    handler(videoURL);
                }];

        if (animated) [cache setObject:animated forKey:albumKey];
        return animated;
    }
    return nil;
}

static void SGScheduleSyntheticArtwork(NSString *albumKey, UIImage *seedCover) {
    if (albumKey.length == 0) return;

    @synchronized (sgSyntheticGenerationInFlight) {
        if ([sgSyntheticGenerationInFlight containsObject:albumKey]) return;
        [sgSyntheticGenerationInFlight addObject:albumKey];
    }

    // Give Spotify a moment to replace any temporary/placeholder artwork with the real cover.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (@available(iOS 26.0, *)) {
            MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
            NSDictionary *latest = center.nowPlayingInfo;
            if (![SGAlbumArtworkKey(latest) isEqualToString:albumKey]) {
                @synchronized (sgSyntheticGenerationInFlight) {
                    [sgSyntheticGenerationInFlight removeObject:albumKey];
                }
                return;
            }

            UIImage *cover = SGBestStaticImage(latest, albumKey);
            if (!SGUsableCover(cover)) cover = seedCover;
            if (!SGUsableCover(cover)) {
                @synchronized (sgSyntheticGenerationInFlight) {
                    [sgSyntheticGenerationInFlight removeObject:albumKey];
                }
                return;
            }

            NSString *token = SGSafeToken(albumKey);
            NSURL *squareURL = [SGArtworkVideoDirectory() URLByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@-1x1.mp4", token]];
            NSURL *tallURL = [SGArtworkVideoDirectory() URLByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@-3x4.mp4", token]];

            dispatch_group_t group = dispatch_group_create();
            __block BOOL squareOK = [[NSFileManager defaultManager] fileExistsAtPath:squareURL.path];
            __block BOOL tallOK = [[NSFileManager defaultManager] fileExistsAtPath:tallURL.path];

            if (!squareOK) {
                dispatch_group_enter(group);
                SGWriteKenBurnsVideo(cover, CGSizeMake(540, 540), squareURL, ^(NSURL *result) {
                    squareOK = (result != nil);
                    dispatch_group_leave(group);
                });
            }
            if (!tallOK) {
                dispatch_group_enter(group);
                SGWriteKenBurnsVideo(cover, CGSizeMake(540, 720), tallURL, ^(NSURL *result) {
                    tallOK = (result != nil);
                    dispatch_group_leave(group);
                });
            }

            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                @synchronized (sgSyntheticGenerationInFlight) {
                    [sgSyntheticGenerationInFlight removeObject:albumKey];
                }

                // Re-submit the current metadata only after at least one generated video exists.
                // Until this point iOS keeps Spotify's normal static cover, so there is no goofy
                // broken-image placeholder during generation.
                if (!squareOK && !tallOK) return;
                NSDictionary *current = center.nowPlayingInfo;
                if ([SGAlbumArtworkKey(current) isEqualToString:albumKey]) {
                    center.nowPlayingInfo = current;
                }
            });
        }
    });
}

static void SGScheduleAnimatedReapply(NSString *trackKey) {
    if (trackKey.length == 0) return;
    @synchronized (sgDelayedAnimatedReapply) {
        if ([sgDelayedAnimatedReapply containsObject:trackKey]) return;
        [sgDelayedAnimatedReapply addObject:trackKey];
    }

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval delay = MAX(0.05, sgFallbackHoldUntil - now);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (sgDelayedAnimatedReapply) {
            [sgDelayedAnimatedReapply removeObject:trackKey];
        }
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        NSDictionary *current = center.nowPlayingInfo;
        if (![(SGTrackArtworkKey(current) ?: @"") isEqualToString:trackKey]) return;
        center.nowPlayingInfo = current;
    });
}

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (sgInternalTransitionUpdate) {
        %orig(info);
        return;
    }

    if (![info isKindOfClass:NSDictionary.class] || info.count == 0) {
        %orig(info);
        return;
    }

    if (@available(iOS 26.0, *)) {
        NSString *albumKey = SGAlbumArtworkKey(info);
        NSString *trackKey = SGTrackArtworkKey(info);
        UIImage *incomingCover = SGStaticCover(info);
        BOOL incomingCoverUsable = SGUsableCover(incomingCover);
        BOOL topLevelTrackChanged = trackKey.length && ![sgCurrentTrackKey isEqualToString:trackKey];

        if (topLevelTrackChanged) {
            sgCurrentTrackKey = [trackKey copy];
            sgFallbackHoldUntil = CFAbsoluteTimeGetCurrent() + 0.75;
            ++sgBlackTransitionGeneration; // cancel any older scheduled transition frames

            if (!incomingCoverUsable) {
                // New song metadata arrived before its artwork. Show a deliberate black waiting
                // frame so iOS never has a reason to draw the generic photo-placeholder icon.
                sgBlackTransitionActive = YES;
                sgBlackTransitionTrackKey = [trackKey copy];
                %orig(SGInfoWithBlackArtwork(info));
                return;
            }
        }

        // The new cover has arrived while the black waiting frame is active. Fade it in over ~300 ms
        // and only then restore the real/synthetic animated artwork.
        if (sgBlackTransitionActive && trackKey.length &&
            [sgBlackTransitionTrackKey isEqualToString:trackKey] && incomingCoverUsable) {
            if (albumKey.length) SGRememberStaticArtwork(info, albumKey);
            SGStartBlackToArtworkFade(info, trackKey, incomingCover);
            return;
        }

        // If Spotify sends more incomplete packets during the wait, keep black rather than flashing
        // the system placeholder.
        if (sgBlackTransitionActive && trackKey.length &&
            [sgBlackTransitionTrackKey isEqualToString:trackKey] && !incomingCoverUsable) {
            %orig(SGInfoWithBlackArtwork(info));
            return;
        }

        // Spotify can briefly publish only title/artist when skipping, before album metadata and
        // artwork arrive. Handle that transitional packet too; otherwise iOS flashes its generic
        // photo placeholder. Keep the previous real cover until the new artwork is available.
        if (!albumKey.length) {
            UIImage *currentCover = SGStaticCover(info);
            if (SGUsableCover(currentCover)) {
                id originalArtwork = info[MPMediaItemPropertyArtwork];
                id stableArtwork = [originalArtwork isKindOfClass:MPMediaItemArtwork.class] ? originalArtwork : SGArtworkFromImage(currentCover);
                if (stableArtwork) sgLastGoodStaticArtwork = stableArtwork;
                sgLastGoodStaticImage = currentCover;
            }

            BOOL trackChanged = trackKey.length && ![sgCurrentTrackKey isEqualToString:trackKey];
            if (trackChanged) {
                sgCurrentTrackKey = [trackKey copy];
                sgFallbackHoldUntil = CFAbsoluteTimeGetCurrent() + 0.75;
            }

            NSMutableDictionary *patched = [info mutableCopy];
            BOOL changed = NO;
            if (!SGUsableCover(currentCover) && sgLastGoodStaticArtwork) {
                patched[MPMediaItemPropertyArtwork] = sgLastGoodStaticArtwork;
                changed = YES;
            }

            BOOL holdingTransition = trackKey.length &&
                                     [sgCurrentTrackKey isEqualToString:trackKey] &&
                                     CFAbsoluteTimeGetCurrent() < sgFallbackHoldUntil;
            if (holdingTransition) {
                [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
                [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
                changed = YES;
                SGScheduleAnimatedReapply(trackKey);
            }

            %orig(changed ? patched : info);
            return;
        }

        if (albumKey.length) {
            SGRememberStaticArtwork(info, albumKey);

            id square = info[MPNowPlayingInfoProperty1x1AnimatedArtwork];
            id tall = info[MPNowPlayingInfoProperty3x4AnimatedArtwork];

            // Spotify's own animation always wins and is remembered for other tracks on the album.
            if (square) [sgRealSquareArtwork setObject:square forKey:albumKey];
            if (tall) [sgRealTallArtwork setObject:tall forKey:albumKey];

            id fallbackSquare = square ?: [sgRealSquareArtwork objectForKey:albumKey];
            id fallbackTall = tall ?: [sgRealTallArtwork objectForKey:albumKey];

            UIImage *cover = SGBestStaticImage(info, albumKey);
            id staticArtwork = SGBestStaticArtwork(info, albumKey);

            if (!fallbackSquare && cover) fallbackSquare = SGSyntheticArtworkForAlbum(albumKey, cover, NO);
            if (!fallbackTall && cover) fallbackTall = SGSyntheticArtworkForAlbum(albumKey, cover, YES);
            if ((!fallbackSquare || !fallbackTall) && cover) SGScheduleSyntheticArtwork(albumKey, cover);

            BOOL trackChanged = trackKey.length && ![sgCurrentTrackKey isEqualToString:trackKey];
            if (trackChanged) {
                sgCurrentTrackKey = [trackKey copy];
                // Hold album/synthetic fallbacks briefly so iOS has a real preview image on screen
                // before it asks for the animation. Spotify-native animated artwork is not delayed.
                sgFallbackHoldUntil = CFAbsoluteTimeGetCurrent() + 0.75;
            }

            NSMutableDictionary *patched = [info mutableCopy];
            BOOL changed = NO;

            // Some Spotify updates arrive without static artwork for a few frames. Keep the last
            // known real cover (same album when possible, otherwise the previous track cover)
            // so iOS never needs to draw its generic photo icon during a skip transition.
            if (!SGUsableCover(SGStaticCover(info)) && staticArtwork) {
                patched[MPMediaItemPropertyArtwork] = staticArtwork;
                changed = YES;
            }

            // If this track has its own native animation, let Spotify/iOS handle it immediately.
            BOOL hasNativeAnimation = (square != nil || tall != nil);
            BOOL holdingFallback = !hasNativeAnimation && trackKey.length &&
                                   [sgCurrentTrackKey isEqualToString:trackKey] &&
                                   CFAbsoluteTimeGetCurrent() < sgFallbackHoldUntil;

            if (holdingFallback) {
                [patched removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
                [patched removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];
                changed = YES;
                SGScheduleAnimatedReapply(trackKey);
            } else {
                if (!square && fallbackSquare) {
                    patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = fallbackSquare;
                    changed = YES;
                }
                if (!tall && fallbackTall) {
                    patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = fallbackTall;
                    changed = YES;
                }
            }

            %orig(changed ? patched : info);
            return;
        }
    }

    %orig(info);
}
%end

%ctor {
    sgRealSquareArtwork = [NSCache new];
    sgRealTallArtwork = [NSCache new];
    sgSyntheticSquareArtwork = [NSCache new];
    sgSyntheticTallArtwork = [NSCache new];
    sgStaticArtworkByAlbum = [NSCache new];
    sgStaticImageByAlbum = [NSCache new];
    sgSyntheticGenerationInFlight = [NSMutableSet set];
    sgDelayedAnimatedReapply = [NSMutableSet set];
    sgRealSquareArtwork.countLimit = 48;
    sgRealTallArtwork.countLimit = 48;
    sgSyntheticSquareArtwork.countLimit = 12;
    sgSyntheticTallArtwork.countLimit = 12;
    sgStaticArtworkByAlbum.countLimit = 64;
    sgStaticImageByAlbum.countLimit = 32;
    sgArtworkVideoQueue = dispatch_queue_create("pw.spoti.synthetic-artwork", DISPATCH_QUEUE_SERIAL);
    %init;
}
