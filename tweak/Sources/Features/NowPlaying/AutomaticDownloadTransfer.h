#import <Foundation/Foundation.h>

// Synchronous; call only from the downloads engine's serial background worker.
// cancelled may be read on the session delegate queue. taskStarted is called on
// the worker before resume; progress is called on the serial delegate queue.
// Only authenticated companion audio is supported, never arbitrary source URLs.
// The returned staging file has the exact manifest length and SHA-256. The caller
// owns it and must move/remove it. Interrupted prefixes stay in a bounded cache.
NSURL *SGAutomaticTransferFile(NSURL *companionRoot, NSDictionary *row,
    BOOL (^cancelled)(void), void (^taskStarted)(NSURLSessionTask *task),
    void (^progress)(NSUInteger received, NSUInteger total), NSString **error);

// An alternative version awaiting the user's choice may still own a completed
// stage from an earlier call. Preserve exactly that stage during cache pruning;
// it counts toward both cache limits. Pass nil when there is no pending candidate.
// An invalid/nonexistent candidate fails before pruning or starting a transfer.
NSURL *SGAutomaticTransferFilePreservingCandidate(NSURL *companionRoot, NSDictionary *row,
    NSURL *protectedCandidateURL, BOOL (^cancelled)(void),
    void (^taskStarted)(NSURLSessionTask *task),
    void (^progress)(NSUInteger received, NSUInteger total), NSString **error);
