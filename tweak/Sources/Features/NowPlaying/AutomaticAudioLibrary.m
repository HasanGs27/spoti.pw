#import "AutomaticAudioLibrary.h"
#import "AutomaticDownloadModel.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static const NSUInteger libraryLimit = 100 * 1024 * 1024;
static NSString *const pathKey = @"spotifyglass.automaticDownloads.libraryPaths";
static NSDictionary *pathSnapshot;
static BOOL lastScanLimited;
static NSCache *audioCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 10000; }); return cache;
}
static NSObject *pathLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; }); return lock;
}
#ifdef SG_AUTOMATIC_LIBRARY_TEST
static NSURL *testDocuments, *testSupport;
static NSUserDefaults *testDefaults;
#endif
static BOOL cancelledNow(BOOL (^cancelled)(void)) { return cancelled && cancelled(); }
static NSURL *documents(void) {
#ifdef SG_AUTOMATIC_LIBRARY_TEST
    if (testDocuments) return testDocuments;
#endif
    return [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByResolvingSymlinksInPath];
}
static NSUserDefaults *preferences(void) {
#ifdef SG_AUTOMATIC_LIBRARY_TEST
    if (testDefaults) return testDefaults;
#endif
    return NSUserDefaults.standardUserDefaults;
}
static BOOL validHash(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static NSString *rowKey(NSDictionary *row) {
    if (![row isKindOfClass:NSDictionary.class] || !validHash(row[@"id"])) return nil;
    NSString *ext = row[@"extension"] ?: @"mp3";
    return [@[@"mp3", @"m4a"] containsObject:ext] ? [row[@"id"] stringByAppendingPathExtension:ext] : nil;
}
static BOOL safeRelative(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 2048 || [value isAbsolutePath] ||
        [value containsString:@"\\"] || [value hasPrefix:@"~"]) return NO;
    for (NSString *part in [value pathComponents])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || [part isEqual:@"/"]) return NO;
    return [[value stringByStandardizingPath] isEqual:value];
}
static BOOL regularFile(NSURL *url, NSNumber **size) {
    NSNumber *regular = nil, *link = nil, *bytes = nil;
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    [url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
    if (size) *size = bytes;
    return regular.boolValue && !link.boolValue && bytes.unsignedLongLongValue >= 1024 && bytes.unsignedLongLongValue <= libraryLimit;
}
static NSArray *fileStamp(NSURL *url) {
    NSDictionary *attrs = url ? [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil] : nil;
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || !attrs[NSFileSize] || !attrs[NSFileModificationDate] || !attrs[NSFileSystemFileNumber]) return nil;
    return @[attrs[NSFileSize], attrs[NSFileModificationDate], attrs[NSFileSystemFileNumber], attrs[NSFileSystemNumber] ?: @0];
}
static NSURL *documentPath(NSString *relative, BOOL mustExist) {
    if (!safeRelative(relative)) return nil;
    NSURL *root = documents(), *url = [root URLByAppendingPathComponent:relative];
    if (!root || ![url.URLByStandardizingPath.path hasPrefix:[root.path stringByAppendingString:@"/"]] ||
        ![url.URLByResolvingSymlinksInPath.path isEqual:url.URLByStandardizingPath.path]) return nil;
    if (mustExist && !regularFile(url, nil)) return nil;
    return url;
}
static NSString *relativePath(NSURL *url) {
    NSString *prefix = [documents().path stringByAppendingString:@"/"];
    NSString *path = url.URLByStandardizingPath.path;
    if (![path hasPrefix:prefix]) return nil;
    NSString *relative = [path substringFromIndex:prefix.length];
    return documentPath(relative, YES) ? relative : nil;
}
NSURL *SGAutomaticLibraryFile(NSDictionary *row) {
    NSString *key = rowKey(row);
    if (!key) return nil;
    NSString *mapped;
    @synchronized(pathLock()) {
        if (!pathSnapshot) pathSnapshot = [[preferences() dictionaryForKey:pathKey] copy] ?: @{};
        mapped = pathSnapshot[key];
    }
    NSURL *file = documentPath(mapped, YES);
    return file ?: documentPath([@"Spoti Downloads" stringByAppendingPathComponent:key], NO);
}
static NSString *fileHash(NSURL *file, BOOL (^cancelled)(void)) {
    if (!regularFile(file, nil)) return nil;
    NSInputStream *stream = [NSInputStream inputStreamWithURL:file]; [stream open];
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    uint8_t data[65536]; NSInteger count = 0; NSUInteger total = 0;
    while (!cancelledNow(cancelled) && (count = [stream read:data maxLength:sizeof(data)]) > 0) {
        total += count;
        if (total > libraryLimit) { [stream close]; return nil; }
        CC_SHA256_Update(&state, data, (CC_LONG)count);
    }
    [stream close];
    if (count < 0 || cancelledNow(cancelled) || total < 1024) return nil;
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(bytes, &state);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [hash appendFormat:@"%02x", bytes[i]];
    return hash;
}
static void rememberPath(NSDictionary *fields, NSURL *file) {
    NSString *key = rowKey(fields), *relative = relativePath(file);
    if (!key || !relative) return;
    NSDictionary *snapshot;
    @synchronized(pathLock()) {
        if (!pathSnapshot) pathSnapshot = [[preferences() dictionaryForKey:pathKey] copy] ?: @{};
        if ([pathSnapshot[key] isEqual:relative]) return;
        NSMutableDictionary *paths = [pathSnapshot mutableCopy]; paths[key] = relative;
        pathSnapshot = [paths copy]; snapshot = pathSnapshot;
    }
    [preferences() setObject:snapshot forKey:pathKey];
}
void SGAutomaticLibraryRegister(NSDictionary *verifiedRow, NSURL *file) {
    NSNumber *size = nil;
    if (!rowKey(verifiedRow) || !regularFile(file, &size) || ![size isEqual:verifiedRow[@"bytes"]]) return;
    rememberPath(verifiedRow, file);
}
static NSString *strictLabel(NSString *value) {
    // Canonical Unicode composition only: no lowercasing, punctuation stripping or aliases.
    return [value isKindOfClass:NSString.class] && value.length <= 512 ? value.precomposedStringWithCanonicalMapping : nil;
}
static BOOL validCover(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length < 24 || data.length > 8 * 1024 * 1024) return NO;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
    if (!source) return NO;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSUInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    BOOL bounded = width > 0 && height > 0 && width <= 4096 && height <= 4096 && width * height <= 16 * 1024 * 1024;
    CGImageRef image = bounded ? CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES}) : NULL;
    BOOL good = image != NULL && CGImageSourceGetStatus(source) == kCGImageStatusComplete;
    if (image) CGImageRelease(image); CFRelease(source); return good;
}
static NSMutableDictionary *audioInfo(NSURL *file, NSString *extension) {
    NSNumber *size = nil;
    if (!regularFile(file, &size)) return nil;
    NSArray *stamp = fileStamp(file); if (!stamp) return nil;
    NSArray *cacheKey = @[file.path, stamp, extension];
    NSMutableDictionary *cached = [audioCache() objectForKey:cacheKey];
    if (cached) return cached; // Mutable only on the engine's serial worker.
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    double seconds = CMTimeGetSeconds(asset.duration);
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (!asset.playable || tracks.count != 1 || [asset tracksWithMediaType:AVMediaTypeVideo].count || !isfinite(seconds) || seconds < 1 || seconds > 86400) return nil;
    NSString *title = @"", *artist = @"", *album = @""; BOOL cover = NO;
    for (AVMetadataItem *item in asset.commonMetadata) {
        if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) title = item.stringValue ?: @"";
        if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) artist = item.stringValue ?: @"";
        if ([item.commonKey isEqual:AVMetadataCommonKeyAlbumName]) album = item.stringValue ?: @"";
        if ([item.commonKey isEqual:AVMetadataCommonKeyArtwork] && validCover(item.dataValue)) cover = YES;
    }
    if (!strictLabel(title).length || !strictLabel(artist).length || !strictLabel(album) || ![fileStamp(file) isEqual:stamp]) return nil;
    NSMutableDictionary *result = [@{@"url":file, @"bytes":size, @"seconds":@(seconds), @"title":title, @"artist":artist, @"album":album,
              @"extension":extension, @"cover":@(cover), @"stamp":stamp} mutableCopy];
    [audioCache() setObject:result forKey:cacheKey]; return result;
}
static NSArray *identity(NSDictionary *info) {
    return @[strictLabel(info[@"title"]) ?: @"", strictLabel(info[@"artist"]) ?: @"", strictLabel(info[@"album"]) ?: @"",
             @((long long)floor([info[@"seconds"] doubleValue]))];
}
static NSString *packetFailure(const char *stage, OSStatus status) {
#ifdef SG_AUTOMATIC_LIBRARY_TEST
    fprintf(stderr, "Packet rejection: stage=%s status=%d\n", stage, (int)status);
#endif
    return nil;
}
static NSString *mp3PacketHash(NSMutableDictionary *info, BOOL (^cancelled)(void)) {
    // AudioFile reads the original MPEG packets, including their boundaries, without
    // decoding. AVAssetReader's compressed MP3 samples do not always provide timing.
    // https://developer.apple.com/documentation/audiotoolbox/audiofilereadpacketdata(_:_:_:_:_:_:_:)
    AudioFileID file = NULL;
    OSStatus status = AudioFileOpenURL((__bridge CFURLRef)info[@"url"], kAudioFileReadPermission, 0, &file);
    if (status || !file) return packetFailure("mp3-open", status);
    @try {
        AudioStreamBasicDescription format = {0}; UInt32 size = sizeof(format);
        status = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format);
        if (status || format.mFormatID != kAudioFormatMPEGLayer3 || !isfinite(format.mSampleRate) || format.mSampleRate <= 0 ||
            !format.mChannelsPerFrame || !format.mFramesPerPacket) return packetFailure("mp3-format", status);
        UInt64 count = 0; size = sizeof(count);
        status = AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &count);
        if (status || !count || count > 4000000) return packetFailure("mp3-count", status);
        UInt32 maximum = 0; size = sizeof(maximum);
        status = AudioFileGetProperty(file, kAudioFilePropertyPacketSizeUpperBound, &size, &maximum);
        if (status || !maximum || maximum > 1024 * 1024) return packetFailure("mp3-packet-size", status);
        CC_SHA256_CTX state; CC_SHA256_Init(&state);
        NSString *signature = [NSString stringWithFormat:@"MPEG-packets-v2/%u/%u/%.17g/%u/%u/%u/%u/%u/%llu",
            (unsigned)format.mFormatID, (unsigned)format.mFormatFlags, format.mSampleRate, (unsigned)format.mChannelsPerFrame,
            (unsigned)format.mFramesPerPacket, (unsigned)format.mBytesPerFrame, (unsigned)format.mBytesPerPacket,
            (unsigned)format.mBitsPerChannel, (unsigned long long)count];
        NSData *signatureData = [signature dataUsingEncoding:NSUTF8StringEncoding];
        CC_SHA256_Update(&state, signatureData.bytes, (CC_LONG)signatureData.length);
        // Preserve all decoder configuration and trim information when provided.
        AudioFilePropertyID properties[] = {kAudioFilePropertyMagicCookieData, kAudioFilePropertyChannelLayout, kAudioFilePropertyPacketTableInfo};
        const char *propertyNames[] = {"magic-cookie", "channel-layout", "packet-table"};
        for (NSUInteger i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
            UInt32 length = 0, writable = 0; status = AudioFileGetPropertyInfo(file, properties[i], &length, &writable);
            NSMutableData *configuration = nil;
#ifdef SG_AUTOMATIC_LIBRARY_TEST
            fprintf(stderr, "MP3 optional property: name=%s id=%u status=%d bytes=%u writable=%u\n", propertyNames[i], (unsigned)properties[i], (int)status, length, writable);
#endif
            // A size-query failure is not proof of absence. Retry the actual read
            // with the known fixed packet-table size, or a bounded maximum buffer.
            if (status == kAudioFileBadPropertySizeError) {
                UInt32 capacity = properties[i] == kAudioFilePropertyPacketTableInfo ? sizeof(AudioFilePacketTableInfo) : 65536;
                configuration = [NSMutableData dataWithLength:capacity]; length = capacity;
                status = AudioFileGetProperty(file, properties[i], &length, configuration.mutableBytes);
#ifdef SG_AUTOMATIC_LIBRARY_TEST
                fprintf(stderr, "MP3 optional direct read: name=%s status=%d bytes=%u capacity=%u\n", propertyNames[i], (int)status, length, capacity);
#endif
                if (!status && length > capacity) return packetFailure("mp3-config-bound", 0);
                if (status) configuration = nil;
                else [configuration setLength:length];
            }
            BOOL missingTable = properties[i] == kAudioFilePropertyPacketTableInfo && status == kAudioFileInvalidChunkError;
            if (status && status != kAudioFileUnsupportedPropertyError && !missingTable) return packetFailure(propertyNames[i], status);
            if (status) length = 0;
            if (length > 65536) return packetFailure("mp3-config-bound", 0);
            if (length && !configuration) {
                configuration = [NSMutableData dataWithLength:length]; UInt32 actual = length;
                status = AudioFileGetProperty(file, properties[i], &actual, configuration.mutableBytes);
#ifdef SG_AUTOMATIC_LIBRARY_TEST
                fprintf(stderr, "MP3 optional value: name=%s status=%d bytes=%u\n", propertyNames[i], (int)status, actual);
#endif
                // PacketTableInfo has a known struct size even when the optional
                // chunk does not exist. Accept only that explicit absence here.
                if (properties[i] == kAudioFilePropertyPacketTableInfo && status == kAudioFileInvalidChunkError) {
                    configuration = nil; length = 0;
                } else if (status || actual != length) {
                    return packetFailure(propertyNames[i], status);
                }
            }
            // Keep an absent optional chunk distinct from successfully returned data.
            uint32_t header[3] = {CFSwapInt32HostToBig(properties[i]), CFSwapInt32HostToBig((UInt32)status), CFSwapInt32HostToBig(length)};
            CC_SHA256_Update(&state, header, sizeof(header));
            if (length) CC_SHA256_Update(&state, configuration.bytes, length);
        }
        UInt32 capacityPackets = MIN(128U, (1024U * 1024U) / maximum), capacityBytes = capacityPackets * maximum;
        NSMutableData *buffer = [NSMutableData dataWithLength:capacityBytes]; AudioStreamPacketDescription descriptions[128];
        UInt64 position = 0, frames = 0, total = 0;
        double deadline = NSProcessInfo.processInfo.systemUptime + 45;
        while (position < count) {
            if (cancelledNow(cancelled) || NSProcessInfo.processInfo.systemUptime >= deadline) return packetFailure("mp3-interrupted", 0);
            UInt32 packets = (UInt32)MIN((UInt64)capacityPackets, count - position), bytes = capacityBytes;
            memset(descriptions, 0, sizeof(descriptions));
            status = AudioFileReadPacketData(file, false, &bytes, descriptions, (SInt64)position, &packets, buffer.mutableBytes);
            if ((status && status != kAudioFileEndOfFileError) || !packets || packets > capacityPackets || packets > count - position ||
                !bytes || bytes > capacityBytes || total + bytes > libraryLimit) return packetFailure("mp3-read", status);
            UInt64 used = 0;
            for (UInt32 i = 0; i < packets; i++) {
                AudioStreamPacketDescription packet = descriptions[i];
                UInt32 packetFrames = packet.mVariableFramesInPacket ?: format.mFramesPerPacket;
                if (packet.mStartOffset < 0 || (UInt64)packet.mStartOffset != used || !packet.mDataByteSize ||
                    packet.mDataByteSize > bytes - used || !packetFrames) return packetFailure("mp3-packet-bounds", 0);
                uint32_t header[2] = {CFSwapInt32HostToBig(packet.mDataByteSize), CFSwapInt32HostToBig(packetFrames)};
                CC_SHA256_Update(&state, header, sizeof(header));
                CC_SHA256_Update(&state, (const uint8_t *)buffer.bytes + packet.mStartOffset, packet.mDataByteSize);
                used += packet.mDataByteSize; frames += packetFrames;
            }
            if (used != bytes) return packetFailure("mp3-unread-bytes", 0);
            total += bytes; position += packets;
        }
        // Confirm the declared packet range is complete, not a partial parser result.
        UInt32 extra = 1, bytes = capacityBytes;
        status = AudioFileReadPacketData(file, false, &bytes, descriptions, (SInt64)position, &extra, buffer.mutableBytes);
        double encodedSeconds = (double)frames / format.mSampleRate, expected = [info[@"seconds"] doubleValue];
        if ((status && status != kAudioFileEndOfFileError) || extra || bytes || !total ||
            !isfinite(encodedSeconds) || encodedSeconds < expected - .1 || encodedSeconds > expected + .15 ||
            cancelledNow(cancelled) || NSProcessInfo.processInfo.systemUptime >= deadline || ![fileStamp(info[@"url"]) isEqual:info[@"stamp"]]) {
#ifdef SG_AUTOMATIC_LIBRARY_TEST
            fprintf(stderr, "MP3 completion: packets=%llu declared=%llu bytes=%llu extra=%u trailing=%u duration=%.6f expected=%.6f\n",
                (unsigned long long)position, (unsigned long long)count, (unsigned long long)total, extra, bytes, encodedSeconds, expected);
#endif
            return packetFailure("mp3-incomplete", status);
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &state);
        NSMutableString *hash = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
        info[@"packets"] = hash; return hash;
    } @finally { AudioFileClose(file); }
}
static NSString *packetHash(NSMutableDictionary *info, BOOL (^cancelled)(void)) {
    if (cancelledNow(cancelled) || ![fileStamp(info[@"url"]) isEqual:info[@"stamp"]]) return nil;
    if (info[@"packets"]) return [info[@"packets"] isKindOfClass:NSString.class] ? info[@"packets"] : nil;
    if ([info[@"extension"] isEqual:@"mp3"]) return mp3PacketHash(info, cancelled);
    // Cache only success: cancellation/timeouts must remain retryable.
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:info[@"url"] options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    if (!track || !reader || cancelledNow(cancelled)) return nil;
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
    if (![reader canAddOutput:output]) return nil;
    [reader addOutput:output]; if (![reader startReading]) return nil;
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    BOOL hasFormat = NO, failed = NO; NSUInteger total = 0; CMSampleBufferRef sample;
    CMAudioFormatDescriptionRef firstFormat = NULL;
    double deadline = NSProcessInfo.processInfo.systemUptime + 45, lastEnd = 0, firstStart = INFINITY;
    while (!cancelledNow(cancelled) && NSProcessInfo.processInfo.systemUptime < deadline && (sample = [output copyNextSampleBuffer])) {
        CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
        const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
        double start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        double duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample));
        if (!asbd || asbd->mFormatID == kAudioFormatLinearPCM || !isfinite(start) || !isfinite(duration) || duration <= 0 ||
            (firstFormat && !CMFormatDescriptionEqual(firstFormat, format))) { CFRelease(sample); failed = YES; break; }
        firstStart = MIN(firstStart, start); lastEnd = MAX(lastEnd, start + duration);
        if (!hasFormat) {
            firstFormat = (CMAudioFormatDescriptionRef)CFRetain(format);
            // Include codec, sample rate, channel/layout configuration and codec cookie.
            NSString *signature = [NSString stringWithFormat:@"%u/%u/%.17g/%u/%u/%u/%u/%u", (unsigned)asbd->mFormatID,
                (unsigned)asbd->mFormatFlags, asbd->mSampleRate, (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mFramesPerPacket,
                (unsigned)asbd->mBytesPerFrame, (unsigned)asbd->mBytesPerPacket, (unsigned)asbd->mBitsPerChannel];
            NSData *signatureData = [signature dataUsingEncoding:NSUTF8StringEncoding];
            CC_SHA256_Update(&state, signatureData.bytes, (CC_LONG)signatureData.length);
            size_t cookieLength = 0, layoutLength = 0;
            const void *cookie = CMAudioFormatDescriptionGetMagicCookie(format, &cookieLength);
            const AudioChannelLayout *layout = CMAudioFormatDescriptionGetChannelLayout(format, &layoutLength);
            if (cookieLength > 65536 || layoutLength > 65536) { CFRelease(sample); failed = YES; break; }
            uint64_t lengths[2] = {CFSwapInt64HostToBig(cookieLength), CFSwapInt64HostToBig(layoutLength)};
            CC_SHA256_Update(&state, lengths, sizeof(lengths));
            if (cookieLength && cookie) CC_SHA256_Update(&state, cookie, (CC_LONG)cookieLength);
            if (layoutLength && layout) CC_SHA256_Update(&state, layout, (CC_LONG)layoutLength);
            hasFormat = YES;
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t length = block ? CMBlockBufferGetDataLength(block) : 0;
        if (!length || length > libraryLimit - total) { CFRelease(sample); failed = YES; break; }
        uint8_t bytes[65536];
        for (size_t offset = 0; offset < length; offset += sizeof(bytes)) {
            size_t count = MIN(sizeof(bytes), length - offset);
            if (CMBlockBufferCopyDataBytes(block, offset, count, bytes) != kCMBlockBufferNoErr) { failed = YES; break; }
            CC_SHA256_Update(&state, bytes, (CC_LONG)count);
        }
        total += length; CFRelease(sample); if (failed) break;
    }
    if (firstFormat) CFRelease(firstFormat);
    if (failed || cancelledNow(cancelled) || NSProcessInfo.processInfo.systemUptime >= deadline) [reader cancelReading];
    double expected = [info[@"seconds"] doubleValue];
    if (failed || cancelledNow(cancelled) || !hasFormat || !total || reader.status != AVAssetReaderStatusCompleted ||
        firstStart > .1 || lastEnd < expected - MAX(.1, expected * .001) || ![fileStamp(info[@"url"]) isEqual:info[@"stamp"]]) return nil;
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(bytes, &state);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [hash appendFormat:@"%02x", bytes[i]];
    info[@"packets"] = hash; return hash;
}
static NSArray *scan(BOOL (^cancelled)(void)) {
    lastScanLimited = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    __block NSUInteger errors = 0;
    NSDirectoryEnumerator *walker = [fm enumeratorAtURL:documents() includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants errorHandler:^BOOL(NSURL *url, NSError *error) {
            errors++; lastScanLimited = YES;
#ifdef SG_AUTOMATIC_LIBRARY_TEST
            fprintf(stderr, "Scan error: name=%s domain=%s code=%ld\n", url.lastPathComponent.UTF8String, error.domain.UTF8String, (long)error.code);
#endif
            return !cancelledNow(cancelled);
        }];
    NSMutableArray *files = [NSMutableArray array]; NSUInteger visited = 0;
#ifdef SG_AUTOMATIC_LIBRARY_TEST
    NSUInteger directories = 0, links = 0, excluded = 0, extensions = 0, unsafe = 0;
#endif
    // Advance explicitly so skipDescendants always refers to the current directory.
    NSURL *file;
    while ((file = walker.nextObject)) {
        if (cancelledNow(cancelled)) break;
        if (++visited > 20000 || files.count >= 10000) { lastScanLimited = YES; break; }
        NSNumber *directory = nil, *link = nil;
        [file getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        [file getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
#ifdef SG_AUTOMATIC_LIBRARY_TEST
        if (visited <= 20) fprintf(stderr, "Scan entry: name=%s level=%lu dir=%d link=%d relative=%d regular=%d canonical=%d\n",
            file.lastPathComponent.UTF8String, (unsigned long)walker.level, directory.boolValue, link.boolValue,
            relativePath(file) != nil, regularFile(file, nil), [file.path isEqual:file.URLByResolvingSymlinksInPath.path]);
        if (link.boolValue) links++;
#endif
        // Foundation never descends into symbolic links. skipDescendants applies to
        // the last directory, so calling it on a file link can skip unrelated files.
        if (link.boolValue) continue;
        if (directory.boolValue) {
#ifdef SG_AUTOMATIC_LIBRARY_TEST
            directories++;
#endif
            if ([@[@"cache", @"caches", @"tmp", @"temp"] containsObject:file.lastPathComponent.lowercaseString]) {
                [walker skipDescendants];
#ifdef SG_AUTOMATIC_LIBRARY_TEST
                excluded++;
#endif
            }
            continue;
        }
        NSString *ext = file.pathExtension.lowercaseString;
        if (![@[@"mp3", @"m4a"] containsObject:ext]) {
#ifdef SG_AUTOMATIC_LIBRARY_TEST
            extensions++;
#endif
            continue;
        }
        if (!relativePath(file)) {
#ifdef SG_AUTOMATIC_LIBRARY_TEST
            unsafe++;
#endif
            continue;
        }
        [files addObject:file];
    }
#ifdef SG_AUTOMATIC_LIBRARY_TEST
    fprintf(stderr, "Scan summary: enumerator=%d visited=%lu dirs=%lu links=%lu excludedDirs=%lu otherExtensions=%lu unsafe=%lu accepted=%lu errors=%lu\n",
        walker != nil, (unsigned long)visited, (unsigned long)directories, (unsigned long)links, (unsigned long)excluded,
        (unsigned long)extensions, (unsigned long)unsafe, (unsigned long)files.count, (unsigned long)errors);
#endif
    return [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path compare:b.path options:NSLiteralSearch]; }];
}
static NSComparisonResult preference(NSDictionary *a, NSDictionary *b) {
    BOOL ac = [a[@"cover"] boolValue], bc = [b[@"cover"] boolValue];
    if (ac != bc) return ac ? NSOrderedAscending : NSOrderedDescending;
    NSString *ap = relativePath(a[@"url"]), *bp = relativePath(b[@"url"]);
    BOOL managedA = [ap hasPrefix:@"Spoti Downloads/"], managedB = [bp hasPrefix:@"Spoti Downloads/"];
    if (managedA != managedB) return managedA ? NSOrderedAscending : NSOrderedDescending;
    return [ap compare:bp options:NSLiteralSearch];
}
static NSDictionary *fields(NSMutableDictionary *info, BOOL (^cancelled)(void)) {
    if (![fileStamp(info[@"url"]) isEqual:info[@"stamp"]]) return nil;
    if (!info[@"id"]) {
        NSString *hash = fileHash(info[@"url"], cancelled);
        if (!hash || ![fileStamp(info[@"url"]) isEqual:info[@"stamp"]]) return nil;
        info[@"id"] = hash;
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"id", @"bytes", @"seconds", @"title", @"artist", @"album", @"extension"]) result[key] = info[key];
    return result;
}
static BOOL equivalent(NSMutableDictionary *a, NSMutableDictionary *b, BOOL (^cancelled)(void)) {
    if (![identity(a) isEqual:identity(b)] || fabs([a[@"seconds"] doubleValue] - [b[@"seconds"] doubleValue]) > .05) return NO;
    NSDictionary *af = fields(a, cancelled), *bf = fields(b, cancelled);
    if (!af || !bf) return NO;
    if ([af[@"id"] isEqual:bf[@"id"]]) return YES;
    NSString *first = packetHash(a, cancelled), *second = packetHash(b, cancelled);
    return first && second && [first isEqual:second];
}
NSDictionary *SGAutomaticLibraryReuse(NSURL *prepared, NSDictionary *requested, BOOL (^cancelled)(void)) {
    if (![requested isKindOfClass:NSDictionary.class] || cancelledNow(cancelled)) return nil;
    NSString *spotify = SGAutomaticSpotifyURL(requested[@"spotify"]);
    if (![spotify containsString:@"/track/"]) return nil;
    NSMutableDictionary *incoming = nil; NSURL *probe = nil;
    @try {
        if (prepared) {
            if (!prepared.isFileURL || !regularFile(prepared, nil)) return nil;
            NSString *ext = prepared.pathExtension.lowercaseString;
            if (![@[@"mp3", @"m4a"] containsObject:ext]) {
                ext = requested[@"extension"];
                if (![@[@"mp3", @"m4a"] containsObject:ext]) {
                    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:prepared.path];
                    NSData *prefix = [handle readDataOfLength:12]; [handle closeFile];
                    const uint8_t *bytes = prefix.bytes;
                    ext = prefix.length >= 8 && !memcmp(bytes + 4, "ftyp", 4) ? @"m4a" : @"mp3";
                }
                probe = [prepared.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:ext]];
                if (![NSFileManager.defaultManager linkItemAtURL:prepared toURL:probe error:nil] &&
                    ![NSFileManager.defaultManager copyItemAtURL:prepared toURL:probe error:nil]) return nil;
            }
            incoming = audioInfo(probe ?: prepared, ext);
            if (!incoming || !fields(incoming, cancelled)) return nil;
        } else if (!rowKey(requested) || ![requested[@"bytes"] isKindOfClass:NSNumber.class]) return nil;
        NSMutableArray *matches = [NSMutableArray array];
        for (NSURL *file in scan(cancelled)) {
            if (cancelledNow(cancelled)) return nil;
            if ([file.path isEqual:prepared.path]) continue;
            NSNumber *size = nil; if (!regularFile(file, &size)) continue;
            if (!incoming && ![size isEqual:requested[@"bytes"]]) continue;
            NSMutableDictionary *candidate = audioInfo(file, file.pathExtension.lowercaseString);
            if (!candidate) continue;
            if (incoming && [incoming[@"cover"] boolValue] && ![candidate[@"cover"] boolValue]) continue;
            BOOL same = incoming ? equivalent(incoming, candidate, cancelled) : [fields(candidate, cancelled)[@"id"] isEqual:requested[@"id"]];
            if (same) [matches addObject:candidate];
        }
        if (cancelledNow(cancelled) || !matches.count) return nil;
        [matches sortUsingComparator:^NSComparisonResult(id a, id b) { return preference(a, b); }];
        NSMutableDictionary *keeper = matches.firstObject;
        NSDictionary *actual = fields(keeper, cancelled);
        if (!actual || cancelledNow(cancelled) || ![fileStamp(keeper[@"url"]) isEqual:keeper[@"stamp"]] ||
            ![fileHash(keeper[@"url"], cancelled) isEqual:actual[@"id"]] ||
            (incoming && (![fileStamp(incoming[@"url"]) isEqual:incoming[@"stamp"]] || ![fileHash(incoming[@"url"], cancelled) isEqual:incoming[@"id"]]))) return nil;
        rememberPath(actual, keeper[@"url"]);
        NSMutableDictionary *row = [requested mutableCopy]; [row addEntriesFromDictionary:actual];
        row[@"spotify"] = spotify; row[@"state"] = @"ready"; return row;
    } @finally {
        if (probe) [NSFileManager.defaultManager removeItemAtURL:probe error:nil];
    }
}
static NSURL *archiveDirectory(void) {
    NSURL *support;
#ifdef SG_AUTOMATIC_LIBRARY_TEST
    support = testSupport;
#else
    support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
#endif
    support = support.URLByResolvingSymlinksInPath;
    if (!support) return nil;
    NSURL *archive = [support URLByAppendingPathComponent:@"Spoti Audio Archive" isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![archive.URLByResolvingSymlinksInPath.path isEqual:archive.path]) return nil;
    if (![fm createDirectoryAtURL:archive withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) return nil;
    NSNumber *dir = nil, *link = nil; [archive getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
    [archive getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    return dir.boolValue && !link.boolValue ? archive : nil;
}
static NSMutableArray *journal(void) {
    NSURL *directory = archiveDirectory();
    if (!directory) return nil;
    NSURL *file = [directory URLByAppendingPathComponent:@"journal.json"];
    if (![file.URLByResolvingSymlinksInPath.path isEqual:file.path]) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) return [NSMutableArray array];
    NSNumber *bytes = nil; [file getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
    if (!bytes || bytes.unsignedLongLongValue > 8 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfURL:file];
    if (!data.length || data.length > 8 * 1024 * 1024) return nil;
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"version"] isEqual:@1] || ![object[@"entries"] isKindOfClass:NSArray.class] || [object[@"entries"] count] > 10000) return nil;
    return [object[@"entries"] mutableCopy];
}
static BOOL saveJournal(NSArray *entries) {
    NSURL *directory = archiveDirectory();
    if (!directory || entries.count > 10000) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"entries":entries} options:0 error:nil];
    if (!data || data.length > 8 * 1024 * 1024) return NO;
    return [data writeToURL:[directory URLByAppendingPathComponent:@"journal.json"] options:NSDataWritingAtomic error:nil];
}
static NSURL *archiveFile(NSDictionary *entry) {
    NSString *name = entry[@"archive"];
    if (!safeRelative(name) || [name pathComponents].count != 1) return nil;
    NSURL *file = [archiveDirectory() URLByAppendingPathComponent:name];
    return file && [file.URLByResolvingSymlinksInPath.path isEqual:file.path] ? file : nil;
}
static NSDictionary *validKeeper(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !rowKey(value) ||
        ![value[@"bytes"] isKindOfClass:NSNumber.class] || [value[@"bytes"] unsignedLongLongValue] < 1024 ||
        [value[@"bytes"] unsignedLongLongValue] > libraryLimit || ![value[@"seconds"] isKindOfClass:NSNumber.class] ||
        !isfinite([value[@"seconds"] doubleValue]) || [value[@"seconds"] doubleValue] < 1 ||
        !strictLabel(value[@"title"]).length || !strictLabel(value[@"artist"]).length || !strictLabel(value[@"album"])) return nil;
    return value;
}
NSDictionary *SGAutomaticLibraryReplacements(void) {
    NSMutableDictionary *raw = [NSMutableDictionary dictionary];
    NSMutableDictionary *hashes = [NSMutableDictionary dictionary];
    NSString *(^verifiedHash)(NSURL *) = ^NSString *(NSURL *file) {
        NSArray *stamp = fileStamp(file); if (!stamp) return nil;
        NSArray *key = @[file.path, stamp]; id known = hashes[key];
        if (known) return [known isKindOfClass:NSString.class] ? known : nil;
        NSString *hash = fileHash(file, nil);
        if (![fileStamp(file) isEqual:stamp]) hash = nil;
        hashes[key] = hash ?: (id)NSNull.null; return hash;
    };
    for (NSDictionary *entry in journal()) {
        if (![entry isKindOfClass:NSDictionary.class] || ![@[@"pending", @"archived", @"restored"] containsObject:entry[@"state"]]) continue;
        NSDictionary *keeper = validKeeper(entry[@"keeper"]), *original = validKeeper(entry[@"original"]);
        if (!keeper || !original) continue;
        // A pending journal entry can mean the process stopped before or after the move.
        if ([entry[@"state"] isEqual:@"pending"] && !regularFile(archiveFile(entry), nil)) continue;
        // The journal also restores a mapping lost before UserDefaults was flushed.
        NSURL *keeperFile = documentPath(entry[@"keeperRelative"], YES);
        if ([verifiedHash(keeperFile) isEqual:keeper[@"id"]]) rememberPath(keeper, keeperFile);
        if ([rowKey(keeper) isEqual:rowKey(original)]) continue;
        raw[rowKey(original)] = keeper;
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in raw) {
        NSDictionary *keeper = raw[key]; NSMutableSet *seen = [NSMutableSet setWithObject:key];
        while (raw[rowKey(keeper)] && ![seen containsObject:rowKey(keeper)]) {
            [seen addObject:rowKey(keeper)]; keeper = raw[rowKey(keeper)];
        }
        if ([seen containsObject:rowKey(keeper)]) continue;
        NSURL *file = SGAutomaticLibraryFile(keeper);
        if ([verifiedHash(file) isEqual:keeper[@"id"]]) result[key] = keeper;
    }
    return result;
}
static NSDictionary *report(NSUInteger archived, NSUInteger restored, NSUInteger skipped, NSString *message) {
    return @{@"archived":@(archived), @"restored":@(restored), @"skipped":@(skipped),
             @"replacements":SGAutomaticLibraryReplacements(), @"message":message};
}
NSDictionary *SGAutomaticLibraryClean(BOOL (^cancelled)(void), void (^progress)(NSString *)) {
    NSMutableArray *entries = journal();
    if (!entries) return report(0, 0, 0, @"L’archive des doublons est inaccessible. Aucun fichier déplacé.");
    NSArray *files = scan(cancelled); BOOL partial = lastScanLimited;
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSUInteger checked = 0, archived = 0, skipped = 0;
    for (NSURL *file in files) {
        if (cancelledNow(cancelled)) break;
        if (progress) progress([NSString stringWithFormat:@"Vérification des fichiers : %lu/%lu", (unsigned long)++checked, (unsigned long)files.count]);
        NSMutableDictionary *info = audioInfo(file, file.pathExtension.lowercaseString);
        if (!info) { skipped++; continue; }
        NSArray *key = identity(info); NSMutableArray *group = groups[key];
        if (!group) groups[key] = group = [NSMutableArray array];
        [group addObject:info];
    }
    for (NSMutableArray *group in groups.allValues) {
        if (group.count < 2 || cancelledNow(cancelled)) continue;
        [group sortUsingComparator:^NSComparisonResult(id a, id b) { return preference(a, b); }];
        NSMutableArray *keepers = [NSMutableArray array];
        for (NSMutableDictionary *candidate in group) {
            if (cancelledNow(cancelled)) break;
            NSMutableDictionary *keeper = nil;
            for (NSMutableDictionary *current in keepers) if (equivalent(current, candidate, cancelled)) { keeper = current; break; }
            if (!keeper) { [keepers addObject:candidate]; continue; }
            NSDictionary *kf = fields(keeper, cancelled), *cf = fields(candidate, cancelled);
            NSString *relative = relativePath(candidate[@"url"]);
            NSString *keeperRelative = relativePath(keeper[@"url"]);
            // Recheck both hashes immediately before an irreversible filesystem operation.
            if (!kf || !cf || !relative || !keeperRelative || cancelledNow(cancelled) ||
                ![fileHash(keeper[@"url"], cancelled) isEqual:kf[@"id"]] || ![fileHash(candidate[@"url"], cancelled) isEqual:cf[@"id"]]) { skipped++; continue; }
            rememberPath(kf, keeper[@"url"]);
            NSMutableDictionary *entry = [@{@"state":@"pending", @"relative":relative, @"keeperRelative":keeperRelative, @"archive":[NSUUID.UUID.UUIDString stringByAppendingPathExtension:cf[@"extension"]],
                @"keeper":kf, @"original":cf} mutableCopy];
            [entries addObject:entry];
            if (!saveJournal(entries)) { [entries removeLastObject]; skipped++; continue; }
            if (cancelledNow(cancelled)) break;
            NSURL *destination = archiveFile(entry);
            if (!destination || ![NSFileManager.defaultManager moveItemAtURL:candidate[@"url"] toURL:destination error:nil]) {
                [entries removeLastObject]; saveJournal(entries); skipped++; continue;
            }
            entry[@"state"] = @"archived";
            saveJournal(entries);  // The already-persisted pending record recovers a crash here.
            archived++;
            if (progress) progress([NSString stringWithFormat:@"%lu doublons mis à l’abri", (unsigned long)archived]);
        }
    }
    NSString *message = cancelledNow(cancelled) ? @"Nettoyage arrêté. Les déplacements terminés restent réversibles." :
        [NSString stringWithFormat:@"%lu doublons archivés. Aucun morceau différent supprimé.", (unsigned long)archived];
    if (partial) message = [message stringByAppendingString:@" Analyse partielle : limite de 10 000 audios ou 20 000 entrées atteinte."];
    return report(archived, 0, skipped, message);
}
NSDictionary *SGAutomaticLibraryRestore(BOOL (^cancelled)(void), void (^progress)(NSString *)) {
    NSMutableArray *entries = journal(); NSUInteger restored = 0, skipped = 0;
    if (!entries) return report(0, 0, 0, @"L’archive des doublons est inaccessible.");
    for (NSMutableDictionary *entry in entries) {
        if (cancelledNow(cancelled)) break;
        if (![entry isKindOfClass:NSMutableDictionary.class] || ![@[@"pending", @"archived"] containsObject:entry[@"state"]]) continue;
        NSDictionary *original = validKeeper(entry[@"original"]);
        NSURL *source = archiveFile(entry), *target = documentPath(entry[@"relative"], NO);
        if (!original || !source || !target || [NSFileManager.defaultManager fileExistsAtPath:target.path] ||
            ![fileHash(source, cancelled) isEqual:original[@"id"]]) { skipped++; continue; }
        if (cancelledNow(cancelled)) break;
        if (![NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil] ||
            !documentPath(entry[@"relative"], NO) || ![NSFileManager.defaultManager moveItemAtURL:source toURL:target error:nil]) { skipped++; continue; }
        entry[@"state"] = @"restored"; saveJournal(entries); restored++;
        // Exact-byte restoration can recover a missing keeper without aliasing hashes.
        NSURL *current = SGAutomaticLibraryFile(original);
        if (![fileHash(current, cancelled) isEqual:original[@"id"]]) rememberPath(original, target);
        if (progress) progress([NSString stringWithFormat:@"%lu fichiers restaurés", (unsigned long)restored]);
    }
    return report(0, restored, skipped, cancelledNow(cancelled) ? @"Restauration arrêtée." :
        [NSString stringWithFormat:@"%lu fichiers restaurés · %lu conflits ou fichiers indisponibles ignorés.", (unsigned long)restored, (unsigned long)skipped]);
}
#pragma clang diagnostic pop

#ifdef SG_AUTOMATIC_LIBRARY_TEST
#import "AutomaticAudioFixture.h"
#include <assert.h>
static void testFrame(NSMutableData *tag, const char *name, NSData *body) {
    uint32_t length = CFSwapInt32HostToBig((uint32_t)body.length); uint16_t flags = 0;
    [tag appendBytes:name length:4]; [tag appendBytes:&length length:4]; [tag appendBytes:&flags length:2]; [tag appendData:body];
}
static NSData *testTagged(NSString *title, NSString *artist, NSString *album, BOOL cover) {
    NSMutableData *tag = [NSMutableData data];
    NSArray *values = @[title, artist, album]; const char *names[] = {"TIT2", "TPE1", "TALB"};
    for (NSUInteger i = 0; i < values.count; i++) {
        uint8_t encoding = 1; NSMutableData *body = [NSMutableData dataWithBytes:&encoding length:1];
        [body appendData:[values[i] dataUsingEncoding:NSUTF16StringEncoding]]; testFrame(tag, names[i], body);
    }
    if (cover) {
        const uint8_t head[] = {0, 'i','m','a','g','e','/','p','n','g',0,3,0};
        NSMutableData *body = [NSMutableData dataWithBytes:head length:sizeof(head)];
        [body appendData:[[NSData alloc] initWithBase64EncodedString:coverFixture options:0]]; testFrame(tag, "APIC", body);
    }
    NSUInteger size = tag.length;
    uint8_t header[] = {'I','D','3',3,0,0,(size >> 21) & 127,(size >> 14) & 127,(size >> 7) & 127,size & 127};
    NSMutableData *file = [NSMutableData dataWithBytes:header length:sizeof(header)]; [file appendData:tag];
    [file appendData:[[NSData alloc] initWithBase64EncodedString:mp3Fixture options:0]]; return file;
}
static NSURL *testWrite(NSString *relative, NSData *data) {
    NSURL *url = [testDocuments URLByAppendingPathComponent:relative];
    assert([NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([data writeToURL:url atomically:YES]); return url;
}
static NSDictionary *testRequest(NSURL *file) {
    NSMutableDictionary *info = audioInfo(file, file.pathExtension.lowercaseString);
    assert(info);
    NSMutableDictionary *row = [fields(info, nil) mutableCopy];
    row[@"spotify"] = @"https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT";
    row[@"position"] = @1; row[@"state"] = @"ready"; return row;
}
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    // Match documents() in production: the trusted root is canonical before any
    // child is created. macOS NSTemporaryDirectory may itself use /var -> /private/var.
    NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByResolvingSymlinksInPath];
    NSURL *root = [temporary URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    testDocuments = [root URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    testSupport = [root URLByAppendingPathComponent:@"Application Support" isDirectory:YES];
    NSString *suite = [@"SGAutomaticLibraryTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    assert([fm createDirectoryAtURL:testDocuments withIntermediateDirectories:YES attributes:nil error:nil]);
    NSData *bare = testTagged(@"Same Song", @"Synthetic Artist", @"Album", NO);
    NSData *covered = testTagged(@"Same Song", @"Synthetic Artist", @"Album", YES);
    NSURL *old = testWrite(@"Old Imports/old.mp3", bare);
    NSDictionary *oldRow = testRequest(old);
    NSUInteger beforeLinks = scan(nil).count;
    NSURL *external = [root URLByAppendingPathComponent:@"outside.mp3"]; assert([bare writeToURL:external atomically:YES]);
    NSURL *link = [testDocuments URLByAppendingPathComponent:@"linked.mp3"];
    assert([fm createSymbolicLinkAtPath:link.path withDestinationPath:external.path error:nil]);
    NSUInteger afterLinks = scan(nil).count;
    NSURL *cache = testWrite(@"Caches/cached.mp3", bare);
    NSURL *hidden = testWrite(@".hidden/hidden.mp3", bare);
    NSError *childrenError = nil;
    NSArray *children = [fm contentsOfDirectoryAtURL:testDocuments includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsHiddenKey, NSURLIsPackageKey] options:0 error:&childrenError];
    fprintf(stderr, "Fixture root: beforeLinks=%lu afterLinks=%lu children=%lu error=%ld\n", (unsigned long)beforeLinks, (unsigned long)afterLinks, (unsigned long)children.count, (long)childrenError.code);
    for (NSURL *child in children) {
        NSDictionary *flags = [child resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsHiddenKey, NSURLIsPackageKey] error:nil];
        fprintf(stderr, "Fixture child: name=%s dir=%d link=%d hidden=%d package=%d\n", child.lastPathComponent.UTF8String,
            [flags[NSURLIsDirectoryKey] boolValue], [flags[NSURLIsSymbolicLinkKey] boolValue], [flags[NSURLIsHiddenKey] boolValue], [flags[NSURLIsPackageKey] boolValue]);
    }
    // Existing manual file is adopted by true hash, without moving or duplicating it.
    NSDictionary *reused = SGAutomaticLibraryReuse(nil, oldRow, nil);
    if (![reused[@"id"] isEqual:oldRow[@"id"]]) {
        fprintf(stderr, "Exact reuse diagnostics: canonicalRoot=%d relativePath=%d scanned=%lu regular=%d stamp=%d hash=%d request=%d\n",
            [testDocuments.path isEqual:testDocuments.URLByResolvingSymlinksInPath.path], relativePath(old) != nil,
            (unsigned long)scan(nil).count, regularFile(old, nil), fileStamp(old) != nil,
            [fileHash(old, nil) isEqual:oldRow[@"id"]], SGAutomaticSpotifyURL(oldRow[@"spotify"]) != nil);
    }
    assert([reused[@"id"] isEqual:oldRow[@"id"]]);
    assert([SGAutomaticLibraryFile(reused).path isEqual:old.path]);
    assert(!SGAutomaticLibraryReuse(nil, oldRow, ^BOOL{ return YES; }));
    // New artwork must not be discarded just because an older bare MP3 exists.
    NSURL *staging = [root URLByAppendingPathComponent:@"prepared.download"]; assert([covered writeToURL:staging atomically:YES]);
    assert(!SGAutomaticLibraryReuse(staging, oldRow, nil));
    NSURL *keeper = testWrite(@"Spoti Downloads/covered.mp3", covered);
    NSDictionary *keeperRow = testRequest(keeper);
    assert(![oldRow[@"id"] isEqual:keeperRow[@"id"]]);
    NSString *oldPackets = packetHash(audioInfo(old, @"mp3"), nil), *keeperPackets = packetHash(audioInfo(keeper, @"mp3"), nil);
    if (![oldPackets isEqual:keeperPackets]) fprintf(stderr, "Packet identity diagnostics: old=%d keeper=%d same=%d\n", oldPackets != nil, keeperPackets != nil, [oldPackets isEqual:keeperPackets]);
    assert([oldPackets isEqual:keeperPackets]);
    NSMutableDictionary *retryPackets = audioInfo(old, @"mp3"); [retryPackets removeObjectForKey:@"packets"];
    __block NSUInteger cancellationChecks = 0;
    assert(!packetHash(retryPackets, ^BOOL{ return ++cancellationChecks >= 3; }));
    assert(!retryPackets[@"packets"] && [packetHash(retryPackets, nil) isEqual:oldPackets]);
    reused = SGAutomaticLibraryReuse(staging, oldRow, nil);
    assert([reused[@"id"] isEqual:keeperRow[@"id"]] && [reused[@"bytes"] isEqual:keeperRow[@"bytes"]]);
    assert([SGAutomaticLibraryFile(reused).path isEqual:keeper.path]);
    assert([fm fileExistsAtPath:staging.path]);
    // A same-size user edit invalidates cached metadata/hash instead of yielding false green.
    NSMutableDictionary *cachedInfo = audioInfo(old, @"mp3");
    NSMutableData *changed = [bare mutableCopy]; ((uint8_t *)changed.mutableBytes)[changed.length - 40] ^= 1;
    assert([changed writeToURL:old atomically:YES]);
    assert(!fields(cachedInfo, nil));
    assert([bare writeToURL:old atomically:YES]);
    // Punctuation/version labels, album editions and artist spellings remain distinct.
    NSURL *remix = testWrite(@"Remix.mp3", testTagged(@"Same Song (Remix)", @"Synthetic Artist", @"Album", NO));
    NSURL *edition = testWrite(@"Edition.mp3", testTagged(@"Same Song", @"Synthetic Artist", @"Other Album", NO));
    NSURL *artist = testWrite(@"Artist.mp3", testTagged(@"Same Song", @"Synthetic-Artist", @"Album", NO));
    assert(!equivalent(audioInfo(old, @"mp3"), audioInfo(remix, @"mp3"), nil));
    assert(!equivalent(audioInfo(old, @"mp3"), audioInfo(edition, @"mp3"), nil));
    assert(!equivalent(audioInfo(old, @"mp3"), audioInfo(artist, @"mp3"), nil));
    // A mutation inside a compressed MPEG packet is not mistaken for a tag-only change.
    NSMutableData *different = [bare mutableCopy]; ((uint8_t *)different.mutableBytes)[different.length - 50] ^= 1;
    NSURL *alternate = testWrite(@"Different Audio.mp3", different);
    assert(!equivalent(audioInfo(old, @"mp3"), audioInfo(alternate, @"mp3"), nil));
    NSDictionary *cancelled = SGAutomaticLibraryClean(^BOOL{ return YES; }, nil);
    assert([cancelled[@"archived"] unsignedIntegerValue] == 0 && [fm fileExistsAtPath:old.path]);
    NSDictionary *clean = SGAutomaticLibraryClean(nil, nil);
    assert([clean[@"archived"] unsignedIntegerValue] == 1);
    assert(![fm fileExistsAtPath:old.path] && [fm fileExistsAtPath:keeper.path]);
    for (NSURL *untouched in @[remix, edition, artist, alternate, external, link, cache, hidden]) assert([fm fileExistsAtPath:untouched.path]);
    NSDictionary *replacement = clean[@"replacements"][rowKey(oldRow)];
    assert([replacement[@"id"] isEqual:keeperRow[@"id"]]);
    assert([replacement[@"title"] isEqual:keeperRow[@"title"]] && [replacement[@"album"] isEqual:keeperRow[@"album"]]);
    // Simulate a crash after moving the duplicate, before final journal/defaults updates.
    NSMutableArray *entries = journal(); assert(entries.count == 1);
    entries[0][@"state"] = @"pending"; assert(saveJournal(entries));
    [testDefaults removeObjectForKey:pathKey]; @synchronized(pathLock()) { pathSnapshot = nil; }
    NSDictionary *recovered = SGAutomaticLibraryReplacements();
    assert([recovered[rowKey(oldRow)][@"id"] isEqual:keeperRow[@"id"]]);
    assert([SGAutomaticLibraryFile(keeperRow).path isEqual:keeper.path]);
    // A conflicting restored path is never overwritten; the keeper remains untouched.
    NSData *conflict = testTagged(@"User File", @"Other Artist", @"Album", NO); testWrite(@"Old Imports/old.mp3", conflict);
    NSDictionary *restore = SGAutomaticLibraryRestore(nil, nil);
    assert([restore[@"restored"] unsignedIntegerValue] == 0 && [restore[@"skipped"] unsignedIntegerValue] == 1);
    assert([[NSData dataWithContentsOfURL:old] isEqual:conflict]);
    assert([fm removeItemAtURL:old error:nil]);
    restore = SGAutomaticLibraryRestore(nil, nil);
    assert([restore[@"restored"] unsignedIntegerValue] == 1);
    assert([[NSData dataWithContentsOfURL:old] isEqual:bare] && [[NSData dataWithContentsOfURL:keeper] isEqual:covered]);
    assert([SGAutomaticLibraryFile(keeperRow).path isEqual:keeper.path]);
    // Exact-byte duplicates also map to a surviving path even though the digest is unchanged.
    NSURL *exact = testWrite(@"Extra/exact.mp3", covered);
    clean = SGAutomaticLibraryClean(nil, nil);
    assert([clean[@"archived"] unsignedIntegerValue] == 2); // restored old + exact copy
    assert(![fm fileExistsAtPath:exact.path]);
    assert([SGAutomaticLibraryFile(keeperRow).path isEqual:keeper.path]);
    // A directory symlink inserted before restoration cannot redirect writes outside Documents.
    NSURL *outsideDir = [root URLByAppendingPathComponent:@"outside-dir" isDirectory:YES];
    assert([fm createDirectoryAtURL:outsideDir withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *extraDir = [testDocuments URLByAppendingPathComponent:@"Extra" isDirectory:YES];
    assert([fm removeItemAtURL:extraDir error:nil]);
    assert([fm createSymbolicLinkAtPath:extraDir.path withDestinationPath:outsideDir.path error:nil]);
    restore = SGAutomaticLibraryRestore(nil, nil);
    assert([restore[@"skipped"] unsignedIntegerValue] >= 1);
    assert(![fm fileExistsAtPath:[outsideDir URLByAppendingPathComponent:@"exact.mp3"].path]);
    // If an exact-byte keeper is manually removed, restoring its backup recovers the mapping.
    assert([fm removeItemAtURL:extraDir error:nil]);
    assert([fm removeItemAtURL:keeper error:nil]);
    restore = SGAutomaticLibraryRestore(nil, nil);
    assert([restore[@"restored"] unsignedIntegerValue] == 1);
    assert([SGAutomaticLibraryFile(keeperRow).path isEqual:exact.path]);
    assert([[NSData dataWithContentsOfURL:exact] isEqual:covered]);
    // Registering a new verified installation replaces an obsolete manual path mapping.
    NSURL *canonical = testWrite([@"Spoti Downloads" stringByAppendingPathComponent:rowKey(keeperRow)], covered);
    SGAutomaticLibraryRegister(keeperRow, canonical);
    assert([SGAutomaticLibraryFile(keeperRow).path isEqual:canonical.path]);
    // Stored traversal/symlink mappings are ignored, never followed outside Documents.
    [testDefaults setObject:@{rowKey(keeperRow):@"../outside.mp3"} forKey:pathKey];
    @synchronized(pathLock()) { pathSnapshot = nil; }
    assert(![SGAutomaticLibraryFile(keeperRow).path isEqual:external.path]);
    assert(!SGAutomaticLibraryFile(@{@"id":@"../escape", @"extension":@"mp3"}));
    [testDefaults removePersistentDomainForName:suite];
    assert([fm removeItemAtURL:root error:nil]);
    puts("Audio library: PASS (true hashes, packet identity, covers, strict versions/albums, safe paths, cancellation, archive/recovery/restore)");
} return 0; }
#endif
