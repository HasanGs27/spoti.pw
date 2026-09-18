// Local files can have an embedded cover visible in the library while Spotify's
// mini/full player shows its missing-image glyph. Read that same cover from Documents.
// Isolated from MPNowPlayingInfoCenter, Canvas and lock-screen animated artwork.
// Revert by removing this file, or set SGLocalArtworkFallbackDisabled = YES.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>

static NSObject *sg_localLock;
static NSString *sg_localObserved, *sg_localURI, *sg_localTitle;
static NSUInteger sg_localGeneration;
static UIImage *sg_localImage;
static NSCache<NSString *, UIImage *> *sg_localCovers;
static NSCache<NSString *, NSDictionary *> *sg_localFileRecords;
static BOOL sg_localPending;
static dispatch_queue_t sg_localQueue;
static __weak UIView *sg_localBar;
static __weak UIImageView *sg_localOverlay;
static __weak UIScrollView *sg_localFullList;
static __weak UIImageView *sg_localFullOverlay;
static CGRect sg_localFullViewportFrame;
static __weak UIScrollView *sg_localMaskedList;
static CALayer *sg_localPreviousMask;
static CAShapeLayer *sg_localArtworkMask;
static NSString *localNormalized(NSString *value);

static UIImage *localBlackCover(void) {
    static UIImage *black;
    if (!black) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)];
        black = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [UIColor.blackColor setFill];
            [context fillRect:CGRectMake(0, 0, 8, 8)];
        }];
    }
    return black;
}

static void localPinFullOverlay(UIScrollView *list) {
    if (!list || !sg_localFullOverlay || sg_localFullOverlay.superview != list) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    sg_localFullOverlay.frame = CGRectOffset(sg_localFullViewportFrame, list.bounds.origin.x, list.bounds.origin.y);
    if (sg_localMaskedList == list && list.layer.mask == sg_localArtworkMask) {
        // Clip the artwork carousel, including its moving native placeholders,
        // to the existing cover rectangle. The cover itself is not resized.
        sg_localArtworkMask.frame = list.bounds;
        sg_localArtworkMask.path = [UIBezierPath bezierPathWithRoundedRect:sg_localFullViewportFrame
            cornerRadius:sg_localFullOverlay.layer.cornerRadius].CGPath;
    }
    [CATransaction commit];
    [list bringSubviewToFront:sg_localFullOverlay];
}

static void localRemoveFullOverlay(void) {
    if (sg_localMaskedList && sg_localMaskedList.layer.mask == sg_localArtworkMask) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        sg_localMaskedList.layer.mask = sg_localPreviousMask;
        [CATransaction commit];
    }
    sg_localMaskedList = nil;
    sg_localPreviousMask = nil;
    sg_localArtworkMask = nil;
    [sg_localFullOverlay removeFromSuperview];
    sg_localFullOverlay = nil;
}

// Reuse the embedded image only inside the full player's artwork collection.
// Keep one viewport overlay above reused cells during local-to-local switches.
// Queued cells are never changed. Returning to a non-local track removes it.
static void localApplyFullPlayer(UIScrollView *list) {
    if (!list.window || !sg_localImage || ![sg_localURI hasPrefix:@"spotify:local:"]) {
        localRemoveFullOverlay();
        return;
    }
    localPinFullOverlay(list);
    if (list.dragging || list.decelerating || list.tracking) return;
    // Match the title in this player's controller tree, not the mini-player below.
    UIResponder *responder = list;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    UIViewController *controller = (UIViewController *)responder;
    BOOL titleMatches = NO;
    for (NSUInteger depth = 0; controller && depth < 5; depth++, controller = controller.parentViewController) {
        __block BOOL found = NO;
        SGForEachView(controller.viewIfLoaded, ^(UIView *view) {
            if ([view isKindOfClass:UILabel.class] && !view.hidden && view.alpha > 0 &&
                [localNormalized(((UILabel *)view).text) isEqualToString:localNormalized(sg_localTitle)]) found = YES;
        });
        if (found) { titleMatches = YES; break; }
    }
    if (!titleMatches) return; // Keep the outgoing cover until the title catches up.

    CGFloat middle = CGRectGetMidX(list.bounds);
    __block UIView *host = nil;
    for (UIView *cell in list.subviews) {
        if (fabs(CGRectGetMidX(cell.frame) - middle) > 1.0) continue;
        SGForEachView(cell, ^(UIView *view) {
            CGSize size = view.bounds.size;
            if (host || view.hidden || view.alpha <= 0 || size.width < 200 ||
                fabs(size.width - size.height) > 2 ||
                ![NSStringFromClass(view.class) containsString:@"CoverArtTiltView"]) return;
            host = view;
        });
    }
    if (!host) return;
    UIImageView *overlay = sg_localFullOverlay;
    if (!overlay || overlay.superview != list) {
        localRemoveFullOverlay();
        overlay = [[UIImageView alloc] initWithFrame:host.bounds];
        overlay.userInteractionEnabled = NO;
        overlay.isAccessibilityElement = NO;
        overlay.contentMode = UIViewContentModeScaleAspectFit;
        overlay.clipsToBounds = YES;
        overlay.backgroundColor = UIColor.blackColor;
        [list addSubview:overlay];
        sg_localFullOverlay = overlay;
        SGLog(@"[SGLocalArtwork] full-player cover applied: %@", sg_localTitle);
    }
    overlay.image = sg_localImage;
    CGRect frame = [host convertRect:host.bounds toView:list];
    sg_localFullViewportFrame = CGRectOffset(frame, -list.bounds.origin.x, -list.bounds.origin.y);
    overlay.layer.cornerRadius = host.layer.cornerRadius > 0 ? host.layer.cornerRadius : 12;
    overlay.layer.cornerCurve = kCACornerCurveContinuous;
    if (!sg_localArtworkMask) {
        sg_localMaskedList = list;
        sg_localPreviousMask = list.layer.mask;
        sg_localArtworkMask = [CAShapeLayer layer];
        sg_localArtworkMask.fillColor = UIColor.blackColor.CGColor;
        sg_localArtworkMask.frame = list.bounds;
        sg_localArtworkMask.path = [UIBezierPath bezierPathWithRoundedRect:sg_localFullViewportFrame
            cornerRadius:overlay.layer.cornerRadius].CGPath;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        list.layer.mask = sg_localArtworkMask;
        [CATransaction commit];
        SGLog(@"[SGLocalArtwork] local carousel edge mask applied");
    }
    localPinFullOverlay(list);
}

static NSString *localText(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *localNormalized(NSString *value) {
    return [[localText(value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        precomposedStringWithCanonicalMapping].lowercaseString;
}

static NSString *localDecoded(NSString *value) {
    NSString *decoded = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return decoded.stringByRemovingPercentEncoding ?: decoded;
}

static BOOL localCurrent(NSUInteger generation) {
    @synchronized (sg_localLock) { return generation == sg_localGeneration; }
}

static void localRemoveOverlay(void) {
    [sg_localOverlay removeFromSuperview];
    sg_localOverlay = nil;
}

static void localApplyBar(UIView *bar) {
    if (!bar || !bar.window || !sg_localImage || ![sg_localURI hasPrefix:@"spotify:local:"]) {
        localRemoveOverlay();
        return;
    }
    // Keep its existing overlay while Spotify updates the title/layout.
    __block BOOL titleMatches = NO;
    SGForEachView(bar, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] && !view.hidden && view.alpha > 0 &&
            [localNormalized(((UILabel *)view).text) isEqualToString:localNormalized(sg_localTitle)]) titleMatches = YES;
    });
    if (!titleMatches) return;

    // The existing mini-player layout has one leading 40pt artwork container.
    // Restrict to that bar, with an image descendant, never playlist cells/buttons.
    __block UIView *host = nil;
    SGForEachView(bar, ^(UIView *view) {
        CGSize size = view.bounds.size;
        if (host || view == sg_localOverlay || view.hidden || view.alpha <= 0 ||
            size.width < 36 || size.width > 48 || fabs(size.width - size.height) > 1 ||
            CGRectGetMinX(SGFrameIn(view, bar)) > bar.bounds.size.width * 0.25) return;
        NSString *name = NSStringFromClass(view.class);
        if (view.layer.cornerRadius <= 0 && ![name containsString:@"CoverArtTiltView"]) return;
        __block BOOL hasImage = NO;
        SGForEachView(view, ^(UIView *child) {
            if ([child isKindOfClass:UIImageView.class] && child != sg_localOverlay) hasImage = YES;
        });
        if (hasImage) host = view;
    });
    if (!host) return;

    UIImageView *overlay = sg_localOverlay;
    if (!overlay || overlay.superview != bar) {
        localRemoveOverlay();
        overlay = [[UIImageView alloc] initWithFrame:host.bounds];
        overlay.userInteractionEnabled = NO;
        overlay.isAccessibilityElement = NO;
        overlay.contentMode = UIViewContentModeScaleAspectFill;
        overlay.clipsToBounds = YES;
        overlay.backgroundColor = UIColor.blackColor;
        [bar addSubview:overlay];
        sg_localOverlay = overlay;
        SGLog(@"[SGLocalArtwork] mini-player cover applied: %@", sg_localTitle);
    }
    overlay.image = sg_localImage;
    overlay.frame = [host convertRect:host.bounds toView:bar];
    overlay.layer.cornerRadius = host.layer.cornerRadius;
    overlay.layer.cornerCurve = kCACornerCurveContinuous;
    [bar bringSubviewToFront:overlay];
}

// Only local disk I/O on the serial worker. No network and no modifications to
// audio files. A matching title + artist is required; album/duration narrow it.
// If different covers share the same identity, return no image (black fallback).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static UIImage *localReadCover(NSString *title, NSString *artist, NSString *album,
                               double seconds, NSUInteger generation) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!documents) return nil;
    NSString *root = [[documents URLByResolvingSymlinksInPath].path stringByAppendingString:@"/"];
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:documents
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLContentModificationDateKey, NSURLFileSizeKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
    NSSet *extensions = [NSSet setWithArray:@[@"mp3", @"m4a", @"mp4", @"flac", @"aif", @"aiff", @"wav"]];
    NSData *chosen = nil;
    NSUInteger scanned = 0;
    for (NSURL *url in files) {
        if (!localCurrent(generation)) return nil;
        @autoreleasepool {
            if (![extensions containsObject:url.pathExtension.lowercaseString]) continue;
            NSNumber *regular = nil, *symlink = nil;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
            if (!regular.boolValue || symlink.boolValue || ![[url URLByResolvingSymlinksInPath].path hasPrefix:root]) continue;
            if (++scanned > 2000) {
                SGLog(@"[SGLocalArtwork] local scan limit reached; no guessed cover");
                return nil;
            }
            NSDate *modified = nil;
            NSNumber *fileSize = nil;
            [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
            [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            NSString *recordKey = modified && fileSize ? [NSString stringWithFormat:@"%@|%.6f|%@",
                url.path, modified.timeIntervalSince1970, fileSize] : nil;
            NSDictionary *record = recordKey ? [sg_localFileRecords objectForKey:recordKey] : nil;
            if (!record) {
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
                NSString *fileTitle = @"", *fileArtist = @"", *fileAlbum = @"";
                NSData *artwork = nil;
                for (AVMetadataItem *item in asset.commonMetadata) {
                    if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) fileTitle = localNormalized(item.stringValue);
                    else if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) fileArtist = localNormalized(item.stringValue);
                    else if ([item.commonKey isEqual:AVMetadataCommonKeyAlbumName]) fileAlbum = localNormalized(item.stringValue);
                    else if ([item.commonKey isEqual:AVMetadataCommonKeyArtwork]) artwork = item.dataValue;
                }
                if (artwork.length > 8 * 1024 * 1024) artwork = nil;
                record = @{@"title": fileTitle, @"artist": fileArtist, @"album": fileAlbum,
                    @"duration": @(CMTimeGetSeconds(asset.duration)), @"artwork": artwork ?: NSData.data};
                // The existing scan also warms the next tracks, with a bounded cache.
                // Modified/replaced files get a different key; no disk writes.
                if (recordKey) [sg_localFileRecords setObject:record forKey:recordKey cost:artwork.length + 512];
            }
            if (![record[@"title"] isEqualToString:localNormalized(title)] || ![record[@"artist"] isEqualToString:localNormalized(artist)]) continue;
            if (album.length && ![record[@"album"] isEqualToString:localNormalized(album)]) continue;
            double duration = [record[@"duration"] doubleValue];
            if (seconds > 0 && (!isfinite(duration) || fabs(duration - seconds) > 2.5)) continue;
            NSData *data = record[@"artwork"];
            if (!data.length || data.length > 8 * 1024 * 1024) continue;
            if (chosen && ![chosen isEqualToData:data]) {
                SGLog(@"[SGLocalArtwork] ambiguous embedded covers for %@", title);
                return nil;
            }
            chosen = data;
        }
    }
    UIImage *image = chosen ? [UIImage imageWithData:chosen] : nil;
    SGLog(@"[SGLocalArtwork] scanned %lu local files; %@: %@", (unsigned long)scanned,
        image ? @"embedded cover found" : @"no matching cover", title);
    return image;
}
#pragma clang diagnostic pop

static void localObserveState(id state) {
    SPTPlayerTrack *track = [state respondsToSelector:@selector(track)] ? [state track] : nil;
    id rawURI = [track respondsToSelector:@selector(URI)] ? track.URI : nil;
    NSString *uri = [rawURI isKindOfClass:NSURL.class] ? [rawURI absoluteString] : localText([rawURI description]);
    BOOL local = [uri hasPrefix:@"spotify:local:"];
    NSString *title = local && [track respondsToSelector:@selector(trackTitle)] ? localText(track.trackTitle) : @"";
    NSString *artist = local && [track respondsToSelector:@selector(artistName)] ? localText(track.artistName) : @"";
    NSString *album = @"";
    double seconds = 0;
    NSArray<NSString *> *parts = local ? [uri componentsSeparatedByString:@":"] : @[];
    if (parts.count == 6) {
        if (!title.length) title = localDecoded(parts[4]);
        if (!artist.length) artist = localDecoded(parts[2]);
        album = localDecoded(parts[3]);
        seconds = [parts[5] doubleValue];
    }
    NSString *identity = [@[uri ?: @"", title, artist] componentsJoinedByString:@"\n"];
    __block NSUInteger generation;
    @synchronized (sg_localLock) {
        if ([identity isEqualToString:sg_localObserved]) return;
        sg_localObserved = identity.copy;
        generation = ++sg_localGeneration;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!localCurrent(generation)) return;
        BOOL holdingLocal = [sg_localURI hasPrefix:@"spotify:local:"] && sg_localImage != nil;
        sg_localURI = uri.copy;
        sg_localTitle = title.copy;
        sg_localPending = NO;
        if (!local) {
            sg_localImage = nil;
            localRemoveOverlay();
            localRemoveFullOverlay();
            return;
        }
        if (!holdingLocal) sg_localImage = localBlackCover();
        if (!title.length || !artist.length) {
            sg_localImage = localBlackCover();
            sg_localOverlay.image = sg_localImage;
            sg_localFullOverlay.image = sg_localImage;
            localApplyBar(sg_localBar);
            localApplyFullPlayer(sg_localFullList);
            return;
        }
        SGLog(@"[SGLocalArtwork] local track: %@ — %@", title, artist);
        UIImage *cached = [sg_localCovers objectForKey:uri];
        if (cached) {
            sg_localImage = cached;
            sg_localOverlay.image = cached;
            sg_localFullOverlay.image = cached;
            localApplyBar(sg_localBar);
            localApplyFullPlayer(sg_localFullList);
            return;
        }
        sg_localPending = YES;
        localApplyBar(sg_localBar);
        localApplyFullPlayer(sg_localFullList);
        SGLog(@"[SGLocalArtwork] transition hold: %@", title);
        // A missing/slow cover must not leave the previous track's image forever.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!localCurrent(generation) || !sg_localPending) return;
            sg_localImage = localBlackCover();
            sg_localOverlay.image = sg_localImage;
            sg_localFullOverlay.image = sg_localImage;
            localApplyBar(sg_localBar);
            localApplyFullPlayer(sg_localFullList);
        });
        dispatch_async(sg_localQueue, ^{
            if (!localCurrent(generation)) return;
            UIImage *image = localReadCover(title, artist, album, seconds, generation);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!localCurrent(generation) || ![uri isEqualToString:sg_localURI]) return;
                sg_localPending = NO;
                sg_localImage = image ?: localBlackCover();
                if (image) {
                    NSUInteger cost = (NSUInteger)(image.size.width * image.scale * image.size.height * image.scale * 4);
                    [sg_localCovers setObject:image forKey:uri cost:cost];
                }
                sg_localOverlay.image = sg_localImage;
                sg_localFullOverlay.image = sg_localImage;
                localApplyBar(sg_localBar);
                localApplyFullPlayer(sg_localFullList);
            });
        });
    });
}

%hook SPTEsperantoPlayer
- (id)state {
    id state = %orig;
    localObserveState(state);
    return state;
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    sg_localBar = ((UIViewController *)self).viewIfLoaded;
    localApplyBar(sg_localBar);
}
%end

%group SGLocalFullPlayer
%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    sg_localFullList = (UIScrollView *)self;
    localApplyFullPlayer(sg_localFullList);
}
- (void)setContentOffset:(CGPoint)offset {
    %orig;
    localPinFullOverlay((UIScrollView *)self);
}
- (void)didMoveToWindow {
    %orig;
    UIScrollView *list = (UIScrollView *)self;
    if (list.window) {
        sg_localFullList = list;
        localApplyFullPlayer(list);
    } else if (sg_localFullList == list) {
        localRemoveFullOverlay();
        sg_localFullList = nil;
    }
}
%end
%end

%ctor {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SGLocalArtworkFallbackDisabled"]) return;
    sg_localLock = [NSObject new];
    sg_localCovers = [NSCache new];
    sg_localCovers.countLimit = 16;
    sg_localCovers.totalCostLimit = 16 * 1024 * 1024;
    sg_localFileRecords = [NSCache new];
    sg_localFileRecords.countLimit = 2000;
    sg_localFileRecords.totalCostLimit = 32 * 1024 * 1024;
    sg_localQueue = dispatch_queue_create("spoti.local-artwork", DISPATCH_QUEUE_SERIAL);
    %init;
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"SGLocalFullPlayerArtworkDisabled"]) {
        %init(SGLocalFullPlayer);
    }
    SGRequireClasses(@[@"SPTEsperantoPlayer", @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController"]);
}
