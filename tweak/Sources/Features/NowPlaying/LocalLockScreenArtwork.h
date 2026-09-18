#pragma once
#import <MediaPlayer/MediaPlayer.h>

// A snapshot only for a confirmed spotify:local: player state whose metadata
// matches this Now Playing packet. Nil means the normal animated path applies.
// An empty dictionary means a local track whose cover is still unavailable.
FOUNDATION_EXPORT NSDictionary *SGLocalLockScreenSnapshot(NSDictionary *info);
