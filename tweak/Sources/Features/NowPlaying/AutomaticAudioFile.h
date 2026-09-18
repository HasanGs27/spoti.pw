#import <Foundation/Foundation.h>
// Runs on the download worker. The input is a private staging copy, never the user's original.
NSDictionary *SGAutomaticInstallAudio(NSURL *staging, NSDictionary *requested, NSString **reason);
