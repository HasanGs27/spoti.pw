#import <Foundation/Foundation.h>
NSString *SGAutomaticSpotifyURL(id value);
NSDictionary *SGAutomaticJob(NSData *data);
NSString *SGAutomaticLocalURI(NSDictionary *row);
NSURL *SGAutomaticAudioSource(id value);
NSDictionary *SGAutomaticMergeLocalRows(NSDictionary *job, NSDictionary *localRows);
NSString *SGAutomaticRowState(NSDictionary *row, BOOL exists, BOOL active, BOOL failed);
// expectedSeconds is the catalogue duration; seconds is the measured installed duration.
BOOL SGAutomaticDurationMatches(NSDictionary *row, double actualSeconds);
