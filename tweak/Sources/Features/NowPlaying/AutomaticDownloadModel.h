#import <Foundation/Foundation.h>
NSString *SGAutomaticSpotifyURL(id value);
NSDictionary *SGAutomaticJob(NSData *data);
NSString *SGAutomaticLocalURI(NSDictionary *row);
NSURL *SGAutomaticAudioSource(id value);
NSDictionary *SGAutomaticMergeLocalRows(NSDictionary *job, NSDictionary *localRows);
// Caller supplies only files already verified on disk. No file is deleted or inspected here.
NSDictionary *SGAutomaticClearUnfinishedHistory(NSDictionary *history, NSDictionary *verifiedLocalRows);
// Stable, zero-based indexes: untried/interrupted rows first, previous errors last.
// Includes ready rows so the caller can verify their files and repair missing ones.
NSArray<NSNumber *> *SGAutomaticPreparationOrder(NSArray<NSDictionary *> *items);
NSString *SGAutomaticRowState(NSDictionary *row, BOOL exists, BOOL active, BOOL failed);
// expectedSeconds is the catalogue duration; seconds is the measured installed duration.
BOOL SGAutomaticDurationMatches(NSDictionary *row, double actualSeconds);
