#import <Foundation/Foundation.h>

// Property-list-safe intent. The first request retains its request_id until a
// confirmed server job is durably saved; queue entries never replace it.
NSDictionary *SGAutomaticDownloadIntent(id stored);
NSDictionary *SGAutomaticDownloadRequest(NSString *url, NSArray *tracks, BOOL refresh);
NSTimeInterval SGAutomaticDownloadRetryDelay(NSUInteger attempt);
// Build a single-track selection from a ready row whose file the caller verified.
// This reuses a playlist's local copy without contacting either server.
NSDictionary *SGAutomaticSingleTrackSelection(NSDictionary *verifiedRow);
// Pure replacement by Spotify identity; repeated playlist positions retain their
// catalogue fields and position. No file is deleted and unrelated tracks survive.
NSDictionary *SGAutomaticDownloadReplaceVersion(NSDictionary *history, NSDictionary *locals, NSDictionary *replacement);
