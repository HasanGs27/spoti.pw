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

// Persisted selection-local exclusions, never file deletion. Nil storage is an
// empty map; malformed or oversized storage returns nil rather than dropping
// previous exclusions. Keys and stored tracks must be canonical Spotify URLs.
// At most 200 selections, each {all:YES} or {tracks:[up to 500 URLs]}.
NSDictionary *SGAutomaticSelectionEdits(id stored);
// A nil track means the whole selection. Inputs are canonicalized; failure or
// capacity exhaustion returns nil. An existing whole-selection exclusion wins.
NSDictionary *SGAutomaticSelectionEdit(NSDictionary *edits, NSString *selectionURL, NSString *trackURL);
// No applicable exclusion returns the original job. A whole-selection exclusion
// or invalid edited job returns nil. Track exclusions remove all occurrences,
// preserve validated wire fields and renumber immutable rows from one. An empty
// result remains a valid job with items:[]; it does not delete any local audio.
NSDictionary *SGAutomaticApplySelectionEdits(NSDictionary *job, NSDictionary *edits);
