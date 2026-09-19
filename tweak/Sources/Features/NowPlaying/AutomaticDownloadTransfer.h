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
