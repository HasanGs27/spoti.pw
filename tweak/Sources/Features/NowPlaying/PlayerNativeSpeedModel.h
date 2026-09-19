#import <Foundation/Foundation.h>

// These functions inspect the observed native state without modifying it. A
// snapshot keeps the exact playback identity, including local Spotify URIs.
NSArray<NSNumber *> *SGPlayerNativeSpeedRates(void);
// Continuous slider requests are bounded to 0.50...2.00 and rounded to 0.01.
// Invalid types, Booleans and nonfinite/out-of-range values are rejected.
NSNumber *SGPlayerNativeSpeedNormalizedRate(id value);
NSDictionary *SGPlayerNativeSpeedSnapshot(id state);
BOOL SGPlayerNativeSpeedSamePlayback(NSDictionary *snapshot, id state);
BOOL SGPlayerNativeSpeedObserved(NSDictionary *snapshot, id state, NSNumber *rate);
// Creates SPTPlayerOptionOverrides containing only its rate. Unrelated native
// options are deliberately absent, so a concurrent shuffle/repeat change stays.
id SGPlayerNativeSpeedOptions(id state, NSNumber *rate);

// Main-thread coordinator; no player calls or timers. Intermediate drag values
// are replaced by the newest one, with at most one command awaiting observation.
@interface SGPlayerNativeSpeedCommandQueue : NSObject
@property(nonatomic, readonly, strong) NSNumber *pendingRate;
@property(nonatomic, readonly, strong) NSNumber *inFlightRate;
- (BOOL)requestRate:(NSNumber *)rate atTime:(NSTimeInterval)time immediate:(BOOL)immediate;
- (NSNumber *)takeRateAtTime:(NSTimeInterval)time;
- (BOOL)timedOutAtTime:(NSTimeInterval)time;
- (void)complete;
- (void)cancel;
@end
