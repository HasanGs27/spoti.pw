#import <Foundation/Foundation.h>

// These functions inspect the observed native state without modifying it. A
// snapshot keeps the exact playback identity, including local Spotify URIs.
NSArray<NSNumber *> *SGPlayerNativeSpeedRates(void);
NSDictionary *SGPlayerNativeSpeedSnapshot(id state);
BOOL SGPlayerNativeSpeedSamePlayback(NSDictionary *snapshot, id state);
BOOL SGPlayerNativeSpeedObserved(NSDictionary *snapshot, id state, NSNumber *rate);
// Creates SPTPlayerOptionOverrides containing only its rate. Unrelated native
// options are deliberately absent, so a concurrent shuffle/repeat change stays.
id SGPlayerNativeSpeedOptions(id state, NSNumber *rate);
