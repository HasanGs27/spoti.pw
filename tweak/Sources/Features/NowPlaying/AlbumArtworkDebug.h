#import "Core/SGLog.h"

// Diagnostic overlay on v4.0.1. Set to 0 to remove probes and handler wrappers.
#ifndef SG_ARTWORK_DEBUG
#define SG_ARTWORK_DEBUG 1
#endif
#ifndef SG_ARTWORK_DEBUG_IMAGE_PROBES
#define SG_ARTWORK_DEBUG_IMAGE_PROBES 1
#endif

#if SG_ARTWORK_DEBUG
static NSObject *SGDebugLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *sgDebugTrack;
static NSTimeInterval sgDebugTrackAt;
static NSUInteger sgDebugSerial;
static NSInteger sgDebugApplicationState = -1;

static NSString *SGDebugQuote(id value) {
    NSString *s = value ? [value description] : @"<nil>";
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return [NSString stringWithFormat:@"\"%@\"", s];
}

static NSString *SGDebugIdentity(id object) {
    return object ? [NSString stringWithFormat:@"%@@%p", NSStringFromClass([object class]), (__bridge void *)object] : @"nil";
}

static NSUInteger SGDebugNextID(void) {
    @synchronized (SGDebugLock()) { return ++sgDebugSerial; }
}

static NSString *SGDebugTrack(void) {
    @synchronized (SGDebugLock()) { return [sgDebugTrack copy]; }
}

static void SGDebugLog(NSString *event, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void SGDebugLog(NSString *event, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *detail = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    @synchronized (SGDebugLock()) {
        static NSString *session;
        if (!session) session = NSUUID.UUID.UUIDString;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (NSThread.isMainThread) sgDebugApplicationState = UIApplication.sharedApplication.applicationState;
        NSString *state = sgDebugApplicationState == 0 ? @"active" :
                          sgDebugApplicationState == 1 ? @"inactive" :
                          sgDebugApplicationState == 2 ? @"background" : @"unknown";
        NSString *body = [NSString stringWithFormat:@"event=%@ applicationState=%@(%ld) stateSample=main-thread/cached main=%d currentTrack=%@ dtMs=%.1f %@",
            event, state, (long)sgDebugApplicationState, NSThread.isMainThread,
            SGDebugQuote(sgDebugTrack), sgDebugTrackAt ? (now - sgDebugTrackAt) * 1000 : -1, detail];
        // Bound each UTF-8 payload below unified logging's cap, including non-ASCII metadata.
        NSUInteger record = ++sgDebugSerial;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSUInteger offset = 0; offset < body.length;) {
            NSUInteger length = MIN((NSUInteger)160, body.length - offset);
            // Keep UTF-16 surrogate pairs together without allowing an unbounded combining sequence.
            unichar last = [body characterAtIndex:offset + length - 1];
            if (last >= 0xD800 && last <= 0xDBFF && offset + length < body.length) --length;
            [parts addObject:[body substringWithRange:NSMakeRange(offset, length)]];
            offset += length;
        }
        NSTimeInterval wall = NSDate.date.timeIntervalSince1970;
        for (NSUInteger i = 0; i < parts.count; ++i) {
            NSString *part = parts[i];
            SGLog(@"[SGArtworkDebug] session=%@ pid=%d ts=%.3f mono=%.3f record=%lu part=%lu/%lu %@",
                session, NSProcessInfo.processInfo.processIdentifier, wall, now,
                (unsigned long)record, (unsigned long)i + 1, (unsigned long)parts.count, part);
        }
    }
}

static NSString *SGDebugImage(UIImage *image) {
    if (![image isKindOfClass:UIImage.class]) return SGDebugIdentity(image);
    CGImageRef cg = image.CGImage;
    return [NSString stringWithFormat:@"%@ points=%@ scale=%.2f pixels=%zux%zu cgImage=%d",
        SGDebugIdentity(image), NSStringFromCGSize(image.size), image.scale,
        cg ? CGImageGetWidth(cg) : 0, cg ? CGImageGetHeight(cg) : 0, cg != NULL];
}

static void SGDebugURL(NSString *event, NSString *context, NSURL *url) {
    BOOL valid = [url isKindOfClass:NSURL.class];
    BOOL local = valid && url.isFileURL;
    BOOL directory = NO;
    BOOL exists = local && [[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&directory];
    NSError *error = nil;
    NSDictionary *attrs = local ? [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:&error] : nil;
    SGDebugLog(event, @"%@ url=%@ isFileURL=%d exists=%d directory=%d bytes=%@ protection=%@ statError=%@",
        context, SGDebugQuote(valid ? url.absoluteString : SGDebugIdentity(url)), local, exists, directory,
        attrs[NSFileSize] ?: @"unknown", attrs[NSFileProtectionKey] ?: @"unknown", SGDebugQuote(error));
}

static void SGDebugPacket(NSUInteger packet, NSString *stage, NSString *reason, NSDictionary *info) {
    BOOL dictionary = [info isKindOfClass:NSDictionary.class];
    SGDebugLog(@"nowPlaying", @"packet=%lu stage=%@ reason=%@ dictionary=%d empty=%d count=%lu track=%@ title=%@ artist=%@ album=%@",
        (unsigned long)packet, stage, reason, dictionary, !dictionary || info.count == 0,
        (unsigned long)(dictionary ? info.count : 0), SGDebugQuote(dictionary ? SGTrackArtworkKey(info) : nil),
        SGDebugQuote(dictionary ? info[MPMediaItemPropertyTitle] : nil),
        SGDebugQuote(dictionary ? info[MPMediaItemPropertyArtist] : nil),
        SGDebugQuote(dictionary ? info[MPMediaItemPropertyAlbumTitle] : nil));
    id artwork = dictionary ? info[MPMediaItemPropertyArtwork] : nil;
    SGDebugLog(@"staticArtwork", @"packet=%lu stage=%@ present=%d object=%@",
        (unsigned long)packet, stage, artwork != nil, SGDebugIdentity(artwork));
    // Explicit diagnostic probe: never substituted into the real packet or cover cache.
    // This can warm a lazy image provider; do not invoke animated handlers speculatively.
#if SG_ARTWORK_DEBUG_IMAGE_PROBES
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    @try {
        UIImage *image = nil;
        BOOL invoked = [artwork isKindOfClass:MPMediaItemArtwork.class];
        if (invoked) image = [(MPMediaItemArtwork *)artwork imageWithSize:CGSizeMake(900, 900)];
        else if ([artwork isKindOfClass:UIImage.class]) image = artwork;
        SGDebugLog(@"staticImage.probe", @"packet=%lu stage=%@ imageWithSizeCalled=%d requested={900,900} result=%@ durationMs=%.1f",
            (unsigned long)packet, stage, invoked, SGDebugImage(image),
            (NSProcessInfo.processInfo.systemUptime - started) * 1000);
    } @catch (NSException *exception) {
        SGDebugLog(@"staticImage.probeException", @"packet=%lu stage=%@ exception=%@", (unsigned long)packet, stage, SGDebugQuote(exception));
    }
#else
    SGDebugLog(@"staticImage.probeDisabled", @"packet=%lu stage=%@", (unsigned long)packet, stage);
#endif
    if (@available(iOS 26.0, *)) {
        for (NSString *key in @[MPNowPlayingInfoProperty1x1AnimatedArtwork, MPNowPlayingInfoProperty3x4AnimatedArtwork]) {
            id animated = dictionary ? info[key] : nil;
            SGDebugLog(@"animatedArtwork", @"packet=%lu stage=%@ key=%@ present=%d object=%@",
                (unsigned long)packet, stage, key, animated != nil, SGDebugIdentity(animated));
        }
    }
}

static NSUInteger SGDebugBegin(NSDictionary *info, BOOL internal) {
    NSUInteger packet = SGDebugNextID();
    if (!internal && [info isKindOfClass:NSDictionary.class] && info.count) {
        NSString *track = SGTrackArtworkKey(info);
        @synchronized (SGDebugLock()) {
            if (track.length && ![sgDebugTrack isEqualToString:track]) {
                NSString *previous = sgDebugTrack;
                sgDebugTrack = [track copy];
                sgDebugTrackAt = NSProcessInfo.processInfo.systemUptime;
                SGDebugLog(@"track.change", @"packet=%lu previous=%@ next=%@", (unsigned long)packet, SGDebugQuote(previous), SGDebugQuote(track));
            }
        }
    }
    SGDebugPacket(packet, @"in", internal ? @"internal-transition" : @"external-or-synthetic-republish", info);
    if (internal && !info) {
        @synchronized (SGDebugLock()) {
            SGDebugLog(@"track.reset", @"packet=%lu deferred-empty-clear", (unsigned long)packet);
            sgDebugTrack = nil;
            sgDebugTrackAt = 0;
        }
    }
    return packet;
}

static NSDictionary *SGDebugOutput(NSUInteger packet, NSString *reason, NSDictionary *info) {
    SGDebugPacket(packet, @"out-before-orig", reason, info);
    return info;
}

static void SGDebugStart(void) {
    // Notification observations update only diagnostic state; no dispatch_sync in media callbacks.
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification, UIApplicationWillEnterForegroundNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            SGDebugLog(@"application.lifecycle", @"notification=%@", note.name);
        }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SGDebugLog(@"session.start", @"baseline=54d961f7b647b924a9a67f02bcc7c4490784c96d policy=v4.0.1-strict-no-square-handoff diagnostics=1 imageProbes=%d", SG_ARTWORK_DEBUG_IMAGE_PROBES);
    });
}

#define SG_DEBUG_BEGIN(info, internal) SGDebugBegin(info, internal)
#define SG_DEBUG_OUTPUT(packet, reason, info) SGDebugOutput(packet, reason, info)
#define SG_DEBUG_EVENT(...) SGDebugLog(__VA_ARGS__)
#define SG_DEBUG_URL(...) SGDebugURL(__VA_ARGS__)
#define SG_DEBUG_START() SGDebugStart()
#else
#define SG_DEBUG_BEGIN(info, internal) 0
#define SG_DEBUG_OUTPUT(packet, reason, info) (info)
#define SG_DEBUG_EVENT(...) do {} while (0)
#define SG_DEBUG_URL(...) do {} while (0)
#define SG_DEBUG_START() do {} while (0)
#endif
