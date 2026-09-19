#import <Foundation/Foundation.h>
// Runs on the download worker. The input is a private staging copy, never the user's original.
NSDictionary *SGAutomaticInstallAudio(NSURL *staging, NSDictionary *requested, NSString **reason);
// Cancellation is checked during metadata export, writes and hashing, and immediately before installation.
NSDictionary *SGAutomaticInstallAudioCancellable(NSURL *staging, NSDictionary *requested,
    BOOL (^cancelled)(void), NSString **reason);
// Independent local import: no Spotify identity or playlist position is accepted or created.
// Embedded labels/artwork are preserved; title/artist/album may fill missing labels.
// Optional expectedSeconds checks the source duration. The returned ready row is content-addressed.
NSDictionary *SGAutomaticInstallLocalAudioCancellable(NSURL *staging, NSDictionary *requested,
    BOOL (^cancelled)(void), NSString **reason);
