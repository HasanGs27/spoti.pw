#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

// Proof of concept for iOS animated lock-screen artwork:
// when a track has animated artwork, remember it for that album.
// If another track from the same album has no animated artwork,
// reuse the remembered 1:1 / 3:4 artwork instead of falling back to static art.
//
// v1 is intentionally memory-only: play one animated track from the album once,
// then other tracks from the same album can inherit it until Spotify is restarted.

static NSCache<NSString *, id> *sgAlbumSquareArtwork;
static NSCache<NSString *, id> *sgAlbumTallArtwork;

static NSString *SGArtworkString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static NSString *SGAlbumArtworkKey(NSDictionary *info) {
    NSString *album = SGArtworkString(info[MPMediaItemPropertyAlbumTitle]);
    if (album.length == 0) return nil;

    NSString *albumArtist = SGArtworkString(info[MPMediaItemPropertyAlbumArtist]);
    if (albumArtist.length == 0) {
        albumArtist = SGArtworkString(info[MPMediaItemPropertyArtist]);
    }

    NSString *artistPart = albumArtist.length ? albumArtist.lowercaseString : @"";
    return [NSString stringWithFormat:@"%@\n%@", artistPart, album.lowercaseString];
}

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (![info isKindOfClass:NSDictionary.class] || info.count == 0) {
        %orig(info);
        return;
    }

    if (@available(iOS 26.0, *)) {
        NSString *albumKey = SGAlbumArtworkKey(info);
        if (albumKey.length) {
            id square = info[MPNowPlayingInfoProperty1x1AnimatedArtwork];
            id tall = info[MPNowPlayingInfoProperty3x4AnimatedArtwork];

            // Keep the first animated artwork seen for each variant of an album.
            if (square && ![sgAlbumSquareArtwork objectForKey:albumKey]) {
                [sgAlbumSquareArtwork setObject:square forKey:albumKey];
            }
            if (tall && ![sgAlbumTallArtwork objectForKey:albumKey]) {
                [sgAlbumTallArtwork setObject:tall forKey:albumKey];
            }

            id fallbackSquare = square ?: [sgAlbumSquareArtwork objectForKey:albumKey];
            id fallbackTall = tall ?: [sgAlbumTallArtwork objectForKey:albumKey];

            if ((!square && fallbackSquare) || (!tall && fallbackTall)) {
                NSMutableDictionary *patched = [info mutableCopy];
                if (!square && fallbackSquare) {
                    patched[MPNowPlayingInfoProperty1x1AnimatedArtwork] = fallbackSquare;
                }
                if (!tall && fallbackTall) {
                    patched[MPNowPlayingInfoProperty3x4AnimatedArtwork] = fallbackTall;
                }
                %orig(patched);
                return;
            }
        }
    }

    %orig(info);
}

%end

%ctor {
    sgAlbumSquareArtwork = [NSCache new];
    sgAlbumTallArtwork = [NSCache new];
    sgAlbumSquareArtwork.countLimit = 48;
    sgAlbumTallArtwork.countLimit = 48;
    %init;
}
