#pragma once
#import <MediaPlayer/MediaPlayer.h>

// Nil: normal online pipeline. Empty: confirmed local track awaiting its cover.
// Otherwise contains only the current local track's MPMediaItemArtwork.
FOUNDATION_EXPORT NSDictionary *SGLocalLockScreenSnapshot(NSDictionary *info);
// Re-publish the latest raw system packet, not a UI-held cover or modified getter.
FOUNDATION_EXPORT void SGRefreshLocalSystemArtwork(void);
