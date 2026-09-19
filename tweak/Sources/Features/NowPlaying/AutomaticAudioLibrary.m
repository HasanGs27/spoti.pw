#import "AutomaticAudioLibrary.h"
#import "AutomaticDownloadModel.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

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
static NSURL *testDocuments;
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
        [value containsString:@"\\"] || [value hasPrefix:@"~"] ||
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound) return NO;
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
NSArray<NSDictionary *> *SGAutomaticLibraryItems(BOOL (^cancelled)(void)) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *file in scan(cancelled)) {
        if (cancelledNow(cancelled)) return @[];
        @autoreleasepool {
            NSString *path = relativePath(file);
            NSArray *stamp = fileStamp(file);
            if (!path || !stamp) continue;
            // Listing must also permit removing an incomplete/untagged local file.
            // Never request playable tracks, image decoding or an audio digest here.
            NSString *title = file.lastPathComponent.stringByDeletingPathExtension;
            NSString *artist = @"", *album = @"";
            @try {
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
                for (AVMetadataItem *metadata in asset.commonMetadata) {
                    if (![@[AVMetadataCommonKeyTitle, AVMetadataCommonKeyArtist, AVMetadataCommonKeyAlbumName] containsObject:metadata.commonKey ?: @""]) continue;
                    NSString *value = strictLabel(metadata.stringValue);
                    if (!value.length) continue;
                    if ([metadata.commonKey isEqual:AVMetadataCommonKeyTitle]) title = value;
                    else if ([metadata.commonKey isEqual:AVMetadataCommonKeyArtist]) artist = value;
                    else if ([metadata.commonKey isEqual:AVMetadataCommonKeyAlbumName]) album = value;
                }
            } @catch (__unused NSException *exception) { }
            if (cancelledNow(cancelled)) return @[];
            if (![fileStamp(file) isEqual:stamp] || !documentPath(path, YES)) continue;
            [items addObject:@{@"path":[path copy], @"title":[title copy], @"artist":[artist copy],
                @"album":[album copy], @"bytes":stamp[0], @"extension":file.pathExtension.lowercaseString,
                @"stamp":[stamp copy]}];
        }
    }
    if (cancelledNow(cancelled)) return @[];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"title"] localizedStandardCompare:b[@"title"]];
        return order == NSOrderedSame ? [a[@"path"] compare:b[@"path"] options:NSLiteralSearch] : order;
    }];
    return [items copy];
}
static BOOL deletionError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"SpotiAudioLibrary" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL validStamp(id stamp) {
    return [stamp isKindOfClass:NSArray.class] && [stamp count] == 4 &&
        [stamp[0] isKindOfClass:NSNumber.class] && [stamp[1] isKindOfClass:NSDate.class] &&
        [stamp[2] isKindOfClass:NSNumber.class] && [stamp[3] isKindOfClass:NSNumber.class];
}
static BOOL statMatchesStamp(const struct stat *status, NSArray *stamp) {
    double modified = status->st_mtimespec.tv_sec + status->st_mtimespec.tv_nsec / 1e9;
    return S_ISREG(status->st_mode) && status->st_size >= 1024 && status->st_size <= libraryLimit &&
        (unsigned long long)status->st_size == [stamp[0] unsignedLongLongValue] &&
        (unsigned long long)status->st_ino == [stamp[2] unsignedLongLongValue] &&
        (unsigned long long)status->st_dev == [stamp[3] unsignedLongLongValue] &&
        fabs(modified - [stamp[1] timeIntervalSince1970]) < 0.000001;
}
static BOOL sameStat(const struct stat *a, const struct stat *b) {
    return S_ISREG(b->st_mode) && a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}
BOOL SGAutomaticLibraryDelete(NSDictionary *item, NSError **error) {
    if (error) *error = nil;
    if (![item isKindOfClass:NSDictionary.class]) return deletionError(error, EINVAL, @"Ce fichier local n'est pas valide.");
    NSString *path = item[@"path"];
    NSArray *stamp = item[@"stamp"];
    if (!safeRelative(path) || !validStamp(stamp) || ![@[@"mp3", @"m4a"] containsObject:path.pathExtension.lowercaseString])
        return deletionError(error, EINVAL, @"Ce fichier local n'est pas valide.");
    NSURL *file = documentPath(path, YES);
    if (!file || ![fileStamp(file) isEqual:stamp])
        return deletionError(error, ESTALE, @"Le fichier a changé ou a déjà été supprimé. Actualisez la liste.");
    // Keep descriptors for the exact directory and file. Each parent component is
    // opened without following a link; unlinkat can only remove this single leaf.
    int parent = open(documents().fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent < 0) return deletionError(error, errno, @"Le dossier des fichiers locaux est inaccessible.");
    NSArray<NSString *> *parts = path.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        int child = openat(parent, parts[i].fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int failure = errno; close(parent); parent = child;
        if (parent < 0) return deletionError(error, failure, @"Le dossier a changé. Actualisez la liste.");
    }
    const char *leaf = parts.lastObject.fileSystemRepresentation;
    int descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (descriptor < 0) {
        int failure = errno; close(parent);
        return deletionError(error, failure, @"Le fichier est inaccessible ou a déjà été supprimé.");
    }
    struct stat opened, latest;
    BOOL unchanged = fstat(descriptor, &opened) == 0 && statMatchesStamp(&opened, stamp) &&
        [fileStamp(file) isEqual:stamp] && documentPath(path, YES) != nil &&
        fstatat(parent, leaf, &latest, AT_SYMLINK_NOFOLLOW) == 0 && sameStat(&opened, &latest);
    if (!unchanged) {
        close(descriptor); close(parent);
        return deletionError(error, ESTALE, @"Le fichier a changé. Actualisez la liste avant de le supprimer.");
    }
    int removed = unlinkat(parent, leaf, 0), failure = errno;
    close(descriptor); close(parent);
    if (removed != 0) return deletionError(error, failure, @"La suppression a échoué. Le fichier a été conservé.");
    @synchronized(pathLock()) {
        if (!pathSnapshot) pathSnapshot = [[preferences() dictionaryForKey:pathKey] copy] ?: @{};
        NSMutableDictionary *paths = [pathSnapshot mutableCopy];
        for (NSString *key in pathSnapshot) if ([pathSnapshot[key] isEqual:path]) [paths removeObjectForKey:key];
        pathSnapshot = [paths copy];
        [preferences() setObject:pathSnapshot forKey:pathKey];
    }
    [audioCache() removeAllObjects];
    return YES;
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
static NSDictionary *testItem(NSArray *items, NSString *path) {
    for (NSDictionary *item in items) if ([item[@"path"] isEqual:path]) return item;
    return nil;
}
static unsigned long long testDiskBytes(void) {
    unsigned long long bytes = 0;
    for (NSURL *file in scan(nil)) bytes += [fileStamp(file)[0] unsignedLongLongValue];
    return bytes;
}
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    // Match documents() in production: the trusted root is canonical before any
    // child is created. macOS NSTemporaryDirectory may itself use /var -> /private/var.
    NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByResolvingSymlinksInPath];
    NSURL *root = [temporary URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    testDocuments = [root URLByAppendingPathComponent:@"Documents" isDirectory:YES];
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
    // Listings describe physical paths, including identical copies and incomplete files.
    NSURL *exact = testWrite(@"Extra/exact.mp3", covered);
    NSURL *incomplete = testWrite(@"Incomplete.mp3", [NSMutableData dataWithLength:2048]);
    NSArray *listed = SGAutomaticLibraryItems(nil);
    assert(listed.count == scan(nil).count);
    assert(SGAutomaticLibraryItems(^BOOL{ return YES; }).count == 0);
    NSDictionary *selected = testItem(listed, @"Extra/exact.mp3");
    NSDictionary *otherCopy = testItem(listed, @"Spoti Downloads/covered.mp3");
    assert(selected && otherCopy && [selected[@"bytes"] isEqual:otherCopy[@"bytes"]]);
    assert([selected[@"title"] isEqual:@"Same Song"] && [selected[@"artist"] isEqual:@"Synthetic Artist"]);
    assert([selected[@"album"] isEqual:@"Album"] && [selected[@"extension"] isEqual:@"mp3"]);
    assert(!selected[@"id"] && validStamp(selected[@"stamp"]));
    assert([testItem(listed, @"Incomplete.mp3")[@"title"] isEqual:@"Incomplete"]);
    assert(!testItem(listed, @"linked.mp3") && !testItem(listed, @"Caches/cached.mp3") && !testItem(listed, @".hidden/hidden.mp3"));
    // All references to the selected physical path are removed; unrelated references stay.
    NSString *selectedPath = selected[@"path"], *keeperPath = otherCopy[@"path"];
    @synchronized(pathLock()) {
        pathSnapshot = @{rowKey(keeperRow):selectedPath, rowKey(oldRow):selectedPath, @"unrelated.mp3":keeperPath};
        [testDefaults setObject:pathSnapshot forKey:pathKey];
    }
    unsigned long long beforeBytes = testDiskBytes();
    NSError *deletion = nil;
    assert(SGAutomaticLibraryDelete(selected, &deletion) && !deletion);
    assert(![fm fileExistsAtPath:exact.path] && [[NSData dataWithContentsOfURL:keeper] isEqual:covered]);
    assert(beforeBytes - testDiskBytes() == [selected[@"bytes"] unsignedLongLongValue]);
    assert(!pathSnapshot[rowKey(keeperRow)] && !pathSnapshot[rowKey(oldRow)] && [pathSnapshot[@"unrelated.mp3"] isEqual:keeperPath]);
    assert([[testDefaults dictionaryForKey:pathKey] isEqual:pathSnapshot]);
    assert([fm fileExistsAtPath:exact.URLByDeletingLastPathComponent.path]); // no recursive directory removal
    deletion = nil; assert(!SGAutomaticLibraryDelete(selected, &deletion) && deletion);
    for (NSURL *untouched in @[old, keeper, remix, edition, artist, alternate, external, link, cache, hidden, incomplete])
        assert([fm fileExistsAtPath:untouched.path]);
    // In-place edits invalidate the listing even though the inode and length are unchanged.
    NSURL *stale = testWrite(@"Stale.mp3", bare);
    NSDictionary *staleItem = testItem(SGAutomaticLibraryItems(nil), @"Stale.mp3");
    assert([changed writeToURL:stale atomically:NO]);
    NSDate *later = [staleItem[@"stamp"][1] dateByAddingTimeInterval:2];
    assert([fm setAttributes:@{NSFileModificationDate:later} ofItemAtPath:stale.path error:nil]);
    assert(!SGAutomaticLibraryDelete(staleItem, &deletion));
    assert([[NSData dataWithContentsOfURL:stale] isEqual:changed]);
    // Replacing the path with another file is refused even with equal size and mtime.
    NSURL *replaced = testWrite(@"Replaced.mp3", bare);
    NSDictionary *replacedItem = testItem(SGAutomaticLibraryItems(nil), @"Replaced.mp3");
    assert([changed writeToURL:replaced atomically:YES]);
    assert([fm setAttributes:@{NSFileModificationDate:replacedItem[@"stamp"][1]} ofItemAtPath:replaced.path error:nil]);
    assert(!SGAutomaticLibraryDelete(replacedItem, &deletion));
    assert([[NSData dataWithContentsOfURL:replaced] isEqual:changed]);
    // A final symlink or a parent swapped for a symlink never reaches its target.
    NSMutableDictionary *forged = [selected mutableCopy]; forged[@"path"] = @"linked.mp3"; forged[@"stamp"] = fileStamp(external);
    assert(!SGAutomaticLibraryDelete(forged, &deletion) && [fm fileExistsAtPath:external.path]);
    NSURL *nested = testWrite(@"MovedParent/inside.mp3", bare);
    NSDictionary *nestedItem = testItem(SGAutomaticLibraryItems(nil), @"MovedParent/inside.mp3");
    NSURL *outsideDir = [root URLByAppendingPathComponent:@"moved-parent" isDirectory:YES];
    assert([fm moveItemAtURL:nested.URLByDeletingLastPathComponent toURL:outsideDir error:nil]);
    assert([fm createSymbolicLinkAtPath:nested.URLByDeletingLastPathComponent.path withDestinationPath:outsideDir.path error:nil]);
    assert(!SGAutomaticLibraryDelete(nestedItem, &deletion));
    assert([[NSData dataWithContentsOfURL:[outsideDir URLByAppendingPathComponent:@"inside.mp3"]] isEqual:bare]);
    // Traversal, directories and malformed stamps cannot authorize any deletion.
    forged[@"path"] = @"../outside.mp3"; assert(!SGAutomaticLibraryDelete(forged, &deletion));
    forged[@"path"] = @"Spoti Downloads"; assert(!SGAutomaticLibraryDelete(forged, &deletion));
    forged[@"path"] = @"Spoti Downloads/covered.mp3"; forged[@"stamp"] = @[@1];
    assert(!SGAutomaticLibraryDelete(forged, &deletion));
    assert(!SGAutomaticLibraryDelete(nil, &deletion));
    assert([[NSData dataWithContentsOfURL:keeper] isEqual:covered]);
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
    puts("Audio library: PASS (true hashes, packet identity, covers, strict versions/albums, listing, cancellation, exact file deletion, stale and symlink protection)");
} return 0; }
#endif
