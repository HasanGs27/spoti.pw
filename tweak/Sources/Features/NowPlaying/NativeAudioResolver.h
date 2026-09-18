#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Implemented in Swift with an explicit ObjC runtime name. No generated header
// or Swift package runtime resources are needed by the injected dylib.
@interface SGNativeAudioRequest : NSObject
- (void)cancel;
@end

@interface SGNativeAudioResolver : NSObject
// expectedTitle, expectedArtist, expectedSeconds are required. title/artist/
// seconds are also accepted. Optional expectedArtists preserves collaboration
// artist names instead of guessing separators in a display string.
// sourceURL, when provided, is a specific YouTube/YouTube Music video to verify.
// Completion is called exactly once on the main queue, including cancellation.
// A resolved URL is NOT a completed download: validate the received audio before
// displaying green. URLs expire and must be resolved again after a stale failure.
+ (SGNativeAudioRequest *)resolveTrack:(NSDictionary *)track
                            sourceURL:(nullable NSURL *)sourceURL
                           completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
