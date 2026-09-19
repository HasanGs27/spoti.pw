#import <Foundation/Foundation.h>

// Property-list-safe intent. The first request retains its request_id until a
// confirmed server job is durably saved; queue entries never replace it.
NSDictionary *SGAutomaticDownloadIntent(id stored);
NSDictionary *SGAutomaticDownloadRequest(NSString *url, NSArray *tracks, BOOL refresh);
NSTimeInterval SGAutomaticDownloadRetryDelay(NSUInteger attempt);
// Pure replacement by Spotify identity; repeated playlist positions retain their
// catalogue fields and position. No file is deleted and unrelated tracks survive.
NSDictionary *SGAutomaticDownloadReplaceVersion(NSDictionary *history, NSDictionary *locals, NSDictionary *replacement);
