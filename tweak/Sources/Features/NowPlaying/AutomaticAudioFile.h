#import <Foundation/Foundation.h>
// Runs on the download worker. The input is a private staging copy, never the user's original.
NSDictionary *SGAutomaticInstallAudio(NSURL *staging, NSDictionary *requested, NSString **reason);
// Cancellation is checked during metadata export, writes and hashing, and immediately before installation.
NSDictionary *SGAutomaticInstallAudioCancellable(NSURL *staging, NSDictionary *requested,
    BOOL (^cancelled)(void), NSString **reason);
