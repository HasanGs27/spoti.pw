// v4.0.2 experiment: resolve assets before publishing; retain v4.0.1's handoff pipeline.
// Included after the debug helpers and forward declarations in the .x file.
static char sgPreparedArtworkStateKey;

// The provider blocks retain this lease through their state. Eviction of an inactive
// artwork releases its owned file after a grace period, not during an active handoff.
@interface SGPreparedVideoLease : NSObject
@property (nonatomic, strong) NSURL *url;
@end
@implementation SGPreparedVideoLease
- (void)dealloc {
    NSURL *owned = _url;
    if (owned) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [NSFileManager.defaultManager removeItemAtURL:owned error:nil]; });
}
@end

static NSMutableDictionary *SGPreparedState(id artwork) {
    return artwork ? objc_getAssociatedObject(artwork, &sgPreparedArtworkStateKey) : nil;
}

static BOOL SGLocalVideoFile(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL || !url.path.length) return NO;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    return [attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] unsignedLongLongValue] > 0 &&
           [NSFileManager.defaultManager isReadableFileAtPath:url.path];
}

static dispatch_queue_t SGPrepareQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("pw.spoti.prepare-artwork", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void SGReapplyLatestArtwork(void) {
    // Coalesce aspect completions. Never republish the packet that initiated an old request.
    dispatch_async(dispatch_get_main_queue(), ^{
        static BOOL scheduled;
        if (scheduled) return;
        scheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            scheduled = NO;
            NSDictionary *latest = sgLastRawNowPlayingInfo;
            if (latest.count && [SGTrackArtworkKey(latest) isEqualToString:sgCurrentTrackKey]) {
                SG_DEBUG_EVENT(@"ready.republish", @"track=%@", SGDebugQuote(sgCurrentTrackKey));
                MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = latest;
            }
        });
    });
}

static NSDictionary *SGPreparedResult(NSMutableDictionary *state, CGSize size) {
    if (!state) return nil;
    @synchronized (state) {
        NSString *variant = size.height > size.width * 1.15 ? @"tall" : @"square";
        NSDictionary *entry = state[variant];
        if (!entry[@"url"]) entry = state[@"tall"][@"url"] ? state[@"tall"] : state[@"square"];
        NSURL *url = entry[@"url"];
        UIImage *image = entry[@"image"];
        return SGLocalVideoFile(url) && image ? @{@"url": url, @"image": image} : nil;
    }
}

static NSURL *SGPinVideoFile(NSURL *source, NSError **error) {
    if (!SGLocalVideoFile(source)) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    // Keep our own copy: Spotify may evict its original as soon as the track changes.
    // Files are not removed while this process can still hand their URLs to iOS.
    static NSURL *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        directory = [[support URLByAppendingPathComponent:@"spoti.pw-ready-artwork" isDirectory:YES]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    });
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSString *extension = source.pathExtension.length ? source.pathExtension : @"mp4";
    NSURL *destination = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension]];
    if (![fm copyItemAtURL:source toURL:destination error:error]) return nil;
    if (![fm setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:destination.path error:error]) {
        [fm removeItemAtURL:destination error:nil];
        return nil;
    }
    return destination;
}

static BOOL SGFinishPreparing(NSMutableDictionary *state, NSString *variant, NSUInteger generation,
                              NSURL *url, UIImage *image, NSString *failure) {
    BOOL retry = NO;
    @synchronized (state) {
        NSMutableDictionary *entry = state[variant];
        if (![entry[@"busy"] boolValue] || [entry[@"generation"] unsignedIntegerValue] != generation) return NO;
        entry[@"busy"] = @NO;
        if (url && image) {
            SGPreparedVideoLease *lease = [SGPreparedVideoLease new];
            lease.url = url;
            entry[@"url"] = url;
            entry[@"image"] = image;
            entry[@"lease"] = lease;
        } else {
            entry[@"retryAt"] = @(NSProcessInfo.processInfo.systemUptime + 1.0);
            retry = [entry[@"attempts"] unsignedIntegerValue] < 3;
        }
    }
    SG_DEBUG_URL(url ? @"ready.validated" : @"ready.failed",
        [NSString stringWithFormat:@"variant=%@ generation=%lu reason=%@", variant, (unsigned long)generation, failure ?: @"decoded-first-frame"], url);
    if (url) SGReapplyLatestArtwork();
    else if (retry) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SGReapplyLatestArtwork(); });
    return YES;
}

static id SGReadyArtwork(id artwork, BOOL tall) {
    NSMutableDictionary *state = SGPreparedState(artwork);
    if (!state) return nil; // Unobserved initializers cannot establish a playable-asset guarantee.
    NSString *variant = tall ? @"tall" : @"square";
    void (^provider)(CGSize, void (^)(NSURL *)) = nil;
    NSUInteger generation;
    @synchronized (state) {
        NSMutableDictionary *entry = state[variant];
        if (!entry) state[variant] = entry = [NSMutableDictionary dictionary];
        if (SGLocalVideoFile(entry[@"url"]) && entry[@"image"]) return artwork;
        if ([entry[@"busy"] boolValue]) return nil;
        NSString *track = sgCurrentTrackKey ?: @"";
        if (![entry[@"track"] isEqual:track]) {
            entry[@"track"] = track;
            entry[@"attempts"] = @0;
            entry[@"retryAt"] = @0;
        }
        if ([entry[@"attempts"] unsignedIntegerValue] >= 3 ||
            [entry[@"retryAt"] doubleValue] > NSProcessInfo.processInfo.systemUptime) return nil;
        provider = state[@"provider"];
        if (!provider) return nil;
        [entry removeObjectForKey:@"url"];
        [entry removeObjectForKey:@"image"];
        [entry removeObjectForKey:@"lease"];
        entry[@"busy"] = @YES;
        entry[@"received"] = @NO;
        entry[@"startedAt"] = @(NSProcessInfo.processInfo.systemUptime);
        entry[@"fallbackScheduled"] = @NO;
        entry[@"attempts"] = @([entry[@"attempts"] unsignedIntegerValue] + 1);
        generation = [entry[@"generation"] unsignedIntegerValue] + 1;
        entry[@"generation"] = @(generation);
    }
    CGSize target = tall ? CGSizeMake(540, 720) : CGSizeMake(540, 540);
    dispatch_async(dispatch_get_main_queue(), ^{
        SG_DEBUG_EVENT(@"ready.request", @"object=%@ variant=%@ generation=%lu", SGDebugIdentity(artwork), variant, (unsigned long)generation);
        // A dead/missing completion must not strand a hold forever without a fallback attempt.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SGFinishPreparing(state, variant, generation, nil, nil, @"timeout");
        });
        provider(target, ^(NSURL *source) {
            @synchronized (state) {
                NSMutableDictionary *entry = state[variant];
                if (![entry[@"busy"] boolValue] || [entry[@"generation"] unsignedIntegerValue] != generation || [entry[@"received"] boolValue]) return;
                entry[@"received"] = @YES;
            }
            dispatch_async(SGPrepareQueue(), ^{
                @autoreleasepool {
                    NSError *error = nil;
                    NSURL *pinned = SGPinVideoFile(source, &error);
                    UIImage *preview = nil;
                    if (pinned) {
                        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:pinned options:nil];
                        AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
                        generator.appliesPreferredTrackTransform = YES;
                        generator.maximumSize = target;
                        // Decode on the preparation queue, never on a NowPlaying / media callback.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        Float64 seconds = CMTimeGetSeconds(asset.duration);
                        CGImageRef frame = asset.playable && isfinite(seconds) && seconds > 0 ?
                            [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error] : NULL;
#pragma clang diagnostic pop
                        if (frame) {
                            // iOS ignores artwork with the wrong ratio, including 9:16 under 3x4.
                            double ratio = (double)CGImageGetWidth(frame) / CGImageGetHeight(frame);
                            double expectedRatio = tall ? 0.75 : 1.0;
                            if (fabs(ratio - expectedRatio) <= 0.01) preview = [UIImage imageWithCGImage:frame];
                            CGImageRelease(frame);
                        }
                    }
                    BOOL accepted = SGFinishPreparing(state, variant, generation, preview ? pinned : nil,
                        preview, preview ? nil : (error.localizedDescription ?: @"no-readable-video-with-required-ratio"));
                    // Only an unpublished failed/stale copy can be deleted here.
                    if (pinned && (!accepted || !preview)) [NSFileManager.defaultManager removeItemAtURL:pinned error:nil];
                }
            });
        });
    });
    return nil;
}

// Pre-encoded H.264 baseline, 24 black frames / 1 second, yuv420p, faststart.
static NSString *const SGBlackSquareVideoBase64 =
    @"AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANybW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAA"
    @"AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA"
    @"Apx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA"
    @"AAAAAAAAAAAAAABAAAAAAKAAAACgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAIUbWRpYQAAACBtZGhk"
    @"AAAAAAAAAAAAAAAAAAAwAAAAMABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABv21p"
    @"bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAX9zdGJsAAAAp3N0c2QA"
    @"AAAAAAAAAQAAAJdhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAKAAoABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAA"
    @"AAAAAAAAAAAAAAAAAAAAGP//AAAALWF2Y0MBQsAL/+EAFWdCwAvZgoVoQAAAAwBAAAAMA8UKmgEABWjJYJLIAAAAFGJ0cnQAAAAA"
    @"AAAmsAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAGAAAAgAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAA"
    @"GAAAAAEAAAB0c3RzegAAAAAAAAAAAAAAGAAAAtgAAAAXAAAAFwAAABcAAAAXAAAAFgAAABYAAAAWAAAAFgAAABYAAAAWAAAAFgAA"
    @"ABYAAAAWAAAAFgAAABYAAAAWAAAAFgAAABYAAAAWAAAAFgAAABYAAAAWAAAAFgAAABRzdGNvAAAAAAAAAAEAAAOiAAAAYnVkdGEA"
    @"AABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAA"
    @"AExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAABN5tZGF0AAACbAYF//9o3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAtIEgu"
    @"MjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0"
    @"bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj01IGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTgg"
    @"cHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTIgOHg4ZGN0"
    @"PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0yIGxvb2thaGVh"
    @"ZF90aHJlYWRzPTIgc2xpY2VkX3RocmVhZHM9MSBzbGljZXM9MiBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9j"
    @"b21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTI0IHNj"
    @"ZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NTAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yOC4wIHFjb21wPTAu"
    @"NjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAL2WIhAy8mKAAJr9999999999"
    @"dddddddddddddddddddddddddddddddddddddddeAAAAMWUGYiEDLyYoAAmv3333333331111111111111111111111111111111"
    @"1111111114AAAAAHQZo4GXgzgAAAAAhBBmaOBl4M4AAAAAdBmlQGXgzgAAAACEEGZpUBl4M4AAAAB0GadgZeDOAAAAAIQQZmnYGX"
    @"gzgAAAAHQZqSAZeDOAAAAAhBBmakgGXgzgAAAAZBmqAy8GcAAAAIQQZmqAy8GcAAAAAGQZrAMvBnAAAACEEGZrAMvBnAAAAABkGa"
    @"4DLwZwAAAAhBBma4DLwZwAAAAAZBmwAy8GcAAAAIQQZmwAy8GcAAAAAGQZsgMvBnAAAACEEGZsgMvBnAAAAABkGbQDLwZwAAAAhB"
    @"BmbQDLwZwAAAAAZBm2Ay8GcAAAAIQQZm2Ay8GcAAAAAGQZuAMvBnAAAACEEGZuAMvBnAAAAABkGboDLwZwAAAAhBBmboDLwZwAAA"
    @"AAZBm8Ay8GcAAAAIQQZm8Ay8GcAAAAAGQZvgMvBnAAAACEEGZvgMvBnAAAAABkGaADLwZwAAAAhBBmaADLwZwAAAAAZBmiAy8GcA"
    @"AAAIQQZmiAy8GcAAAAAGQZpAMvBnAAAACEEGZpAMvBnAAAAABkGaYDLwZwAAAAhBBmaYDLwZwAAAAAZBmoAy8GcAAAAIQQZmoAy8"
    @"GcAAAAAGQZqgMvBnAAAACEEGZqgMvBnAAAAABkGawC7wZwAAAAhBBmawC7wZwAAAAAZBmuAq8GcAAAAIQQZmuAq8GcA=";

static NSString *const SGBlackTallVideoBase64 =
    @"AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANzbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAA"
    @"AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA"
    @"Ap10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA"
    @"AAAAAAAAAAAAAABAAAAAAHgAAACgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAIVbWRpYQAAACBtZGhk"
    @"AAAAAAAAAAAAAAAAAAAwAAAAMABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABwG1p"
    @"bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYBzdGJsAAAAqHN0c2QA"
    @"AAAAAAAAAQAAAJhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAHgAoABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAA"
    @"AAAAAAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAL/+EAFmdCwAvZggV5eEAAAAMAQAAADAPFCpoBAAVoyWCSyAAAABRidHJ0AAAA"
    @"AAAAJjgAAAAAAAAAGHN0dHMAAAAAAAAAAQAAABgAAAIAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAcc3RzYwAAAAAAAAABAAAAAQAA"
    @"ABgAAAABAAAAdHN0c3oAAAAAAAAAAAAAABgAAALJAAAAFwAAABcAAAAXAAAAFwAAABYAAAAWAAAAFgAAABYAAAAWAAAAFgAAABYA"
    @"AAAWAAAAFgAAABYAAAAWAAAAFgAAABYAAAAWAAAAFgAAABYAAAAWAAAAFgAAABYAAAAUc3RjbwAAAAAAAAABAAADowAAAGJ1ZHRh"
    @"AAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAA"
    @"AABMYXZmNjIuMTIuMTAyAAAACGZyZWUAAATPbWRhdAAAAmwGBf//aNxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgLSBI"
    @"LjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5o"
    @"dG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9NSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT04"
    @"IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0yIDh4OGRj"
    @"dD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MiBsb29rYWhl"
    @"YWRfdGhyZWFkcz0yIHNsaWNlZF90aHJlYWRzPTEgc2xpY2VzPTIgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlf"
    @"Y29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0yNCBz"
    @"Y2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTUwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjguMCBxY29tcD0w"
    @"LjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAChliIQMvJigACa/fffffffX"
    @"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgAAAAKWUFIiEDLyYoAAmv3333333111111111111111111111111111111114AAAAB0Ga"
    @"OBl4KYAAAAAIQQUmjgZeCmAAAAAHQZpUBl4KYAAAAAhBBSaVAZeCmAAAAAdBmnYGXgpgAAAACEEFJp2Bl4KYAAAAB0GakgGXgpgA"
    @"AAAIQQUmpIBl4KYAAAAGQZqgMvBTAAAACEEFJqgMvBTAAAAABkGawDLwUwAAAAhBBSawDLwUwAAAAAZBmuAy8FMAAAAIQQUmuAy8"
    @"FMAAAAAGQZsAMvBTAAAACEEFJsAMvBTAAAAABkGbIDLwUwAAAAhBBSbIDLwUwAAAAAZBm0Ay8FMAAAAIQQUm0Ay8FMAAAAAGQZtg"
    @"MvBTAAAACEEFJtgMvBTAAAAABkGbgDLwUwAAAAhBBSbgDLwUwAAAAAZBm6Ay8FMAAAAIQQUm6Ay8FMAAAAAGQZvAMvBTAAAACEEF"
    @"JvAMvBTAAAAABkGb4DLwUwAAAAhBBSb4DLwUwAAAAAZBmgAy8FMAAAAIQQUmgAy8FMAAAAAGQZogMvBTAAAACEEFJogMvBTAAAAA"
    @"BkGaQDLwUwAAAAhBBSaQDLwUwAAAAAZBmmAy8FMAAAAIQQUmmAy8FMAAAAAGQZqAMvBTAAAACEEFJqAMvBTAAAAABkGaoDLwUwAA"
    @"AAhBBSaoDLwUwAAAAAZBmsAu8FMAAAAIQQUmsAu8FMAAAAAGQZrgKvBTAAAACEEFJrgKvBTA";
