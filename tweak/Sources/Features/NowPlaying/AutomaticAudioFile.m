#import "AutomaticAudioFile.h"
#import "AutomaticDownloadModel.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static const NSUInteger audioLimit = 100 * 1024 * 1024;
static NSDictionary *failure(NSString **reason, NSString *message) { if (reason) *reason = message; return nil; }
static BOOL stopped(BOOL (^cancelled)(void)) { return cancelled && cancelled(); }
static NSString *label(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSURL *temporarySibling(NSURL *source, NSString *extension) {
    return [source.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension]];
}
static NSString *audioHash(NSURL *url, BOOL (^cancelled)(void)) {
    NSInputStream *input = [NSInputStream inputStreamWithURL:url]; [input open];
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    uint8_t buffer[65536]; NSInteger count = 0;
    while (!stopped(cancelled) && (count = [input read:buffer maxLength:sizeof(buffer)]) > 0)
        CC_SHA256_Update(&state, buffer, (CC_LONG)count);
    [input close];
    if (count < 0 || stopped(cancelled)) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &state);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
    return hash;
}
static void frame(NSMutableData *tag, const char *name, NSData *body) {
    uint32_t size = CFSwapInt32HostToBig((uint32_t)body.length); uint16_t flags = 0;
    [tag appendBytes:name length:4]; [tag appendBytes:&size length:4];
    [tag appendBytes:&flags length:2]; [tag appendData:body];
}
static void textFrame(NSMutableData *tag, const char *name, NSString *value) {
    uint8_t encoding = 1; // UTF-16 with BOM, ID3v2.3.
    NSMutableData *body = [NSMutableData dataWithBytes:&encoding length:1];
    [body appendData:[value dataUsingEncoding:NSUTF16StringEncoding]]; frame(tag, name, body);
}
// Bound image dimensions before embedding. The cover remains optional if a provider returns HTML or a bad image.
static NSString *pictureType(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length < 24 || data.length > 8 * 1024 * 1024) return nil;
    const uint8_t *b = data.bytes; NSUInteger width = 0, height = 0;
    NSString *type = nil;
    if (!memcmp(b, "\x89PNG\r\n\x1a\n", 8) && !memcmp(b + 12, "IHDR", 4)) {
        width = ((NSUInteger)b[16] << 24) | ((NSUInteger)b[17] << 16) | (b[18] << 8) | b[19];
        height = ((NSUInteger)b[20] << 24) | ((NSUInteger)b[21] << 16) | (b[22] << 8) | b[23];
        type = @"image/png";
    } else if (b[0] == 0xff && b[1] == 0xd8) {
        NSUInteger offset = 2;
        while (offset + 4 <= data.length) {
            if (b[offset++] != 0xff) break;
            while (offset < data.length && b[offset] == 0xff) offset++;
            if (offset >= data.length) break;
            uint8_t marker = b[offset++];
            if (marker == 0xd9 || marker == 0xda) break;
            if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
            if (offset + 2 > data.length) break;
            NSUInteger length = (b[offset] << 8) | b[offset + 1];
            if (length < 2 || length > data.length - offset) break;
            BOOL startOfFrame = marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
            if (startOfFrame && length >= 8) {
                height = (b[offset + 3] << 8) | b[offset + 4];
                width = (b[offset + 5] << 8) | b[offset + 6]; type = @"image/jpeg"; break;
            }
            offset += length;
        }
    }
    return width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 16 * 1024 * 1024 ? type : nil;
}
static BOOL writeBytes(NSOutputStream *output, const uint8_t *bytes, NSUInteger length, BOOL (^cancelled)(void)) {
    while (length && !stopped(cancelled)) {
        NSInteger count = [output write:bytes maxLength:MIN(length, 65536)];
        if (count <= 0) return NO;
        bytes += count; length -= count;
    }
    return length == 0 && !stopped(cancelled);
}
static BOOL writeMP3(NSData *data, NSURL *outputURL, NSString *title, NSString *artist, NSString *album,
    NSData *artwork, BOOL (^cancelled)(void)) {
    const uint8_t *bytes = data.bytes; NSUInteger offset = 0;
    if (!memcmp(bytes, "ID3", 3)) {
        if (bytes[3] < 2 || bytes[3] > 4 || ((bytes[6] | bytes[7] | bytes[8] | bytes[9]) & 0x80)) return NO;
        offset = 10 + ((NSUInteger)bytes[6] << 21) + ((NSUInteger)bytes[7] << 14) + ((NSUInteger)bytes[8] << 7) + bytes[9];
        if (bytes[3] == 4 && (bytes[5] & 0x10)) offset += 10;
        if (offset >= data.length) return NO;
    }
    NSMutableData *tag = [NSMutableData data];
    textFrame(tag, "TIT2", title); textFrame(tag, "TPE1", artist); textFrame(tag, "TALB", album);
    NSString *mime = pictureType(artwork);
    if (mime) {
        uint8_t encoding = 0, cover = 3, terminator = 0;
        NSMutableData *body = [NSMutableData dataWithBytes:&encoding length:1];
        [body appendBytes:mime.UTF8String length:strlen(mime.UTF8String) + 1];
        [body appendBytes:&cover length:1]; [body appendBytes:&terminator length:1];
        [body appendData:artwork]; frame(tag, "APIC", body);
    }
    NSUInteger n = tag.length;
    if (n + 10 + data.length - offset > audioLimit) return NO;
    uint8_t header[] = {'I','D','3',3,0,0,(n>>21)&127,(n>>14)&127,(n>>7)&127,n&127};
    NSOutputStream *output = [NSOutputStream outputStreamWithURL:outputURL append:NO]; [output open];
    BOOL ok = writeBytes(output, header, sizeof(header), cancelled) && writeBytes(output, tag.bytes, tag.length, cancelled) &&
        writeBytes(output, bytes + offset, data.length - offset, cancelled);
    [output close];
    return ok;
}
static AVMetadataItem *metadataItem(AVMetadataIdentifier identifier, id value, NSString *type) {
    AVMutableMetadataItem *item = [AVMutableMetadataItem new];
    // Let AVFoundation choose the container's canonical key representation. Assigning the
    // textual four-character iTunes key can produce an export that silently omits its tags.
    item.identifier = identifier; item.value = value;
    item.dataType = type; return item;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static BOOL completeAudio(AVURLAsset *asset, double expectedDuration, BOOL (^cancelled)(void)) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    if (!track || !reader || stopped(cancelled)) return NO;
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;
    // Inspect compressed packets without decoding or modifying the audio. Container duration alone
    // can still claim a full song when a server returns a truncated MP3 with an intact Xing header.
    double lastEnd = 0;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 45;
    while (!stopped(cancelled) && NSProcessInfo.processInfo.systemUptime < deadline) {
        CMSampleBufferRef sample = [output copyNextSampleBuffer];
        if (!sample) break;
        double start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        double length = CMTimeGetSeconds(CMSampleBufferGetDuration(sample));
        if (isfinite(start) && isfinite(length) && length > 0) lastEnd = fmax(lastEnd, start + length);
        CFRelease(sample);
    }
    BOOL valid = reader.status == AVAssetReaderStatusCompleted && !stopped(cancelled) &&
        lastEnd >= expectedDuration - fmax(0.2, expectedDuration * 0.01);
    if (reader.status == AVAssetReaderStatusReading) [reader cancelReading];
    return valid;
}
static BOOL writeM4AItems(AVURLAsset *asset, NSURL *outputURL, NSArray *metadata, BOOL (^cancelled)(void)) {
    // Passthrough changes the container tags only. It does not convert/re-encode the AAC audio.
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (![export.supportedFileTypes containsObject:AVFileTypeAppleM4A]) return NO;
    export.outputURL = outputURL; export.outputFileType = AVFileTypeAppleM4A; export.metadata = metadata;
#ifdef SG_AUTOMATIC_AUDIO_TEST
    NSLog(@"M4A export metadata: supplied=%lu retained=%lu fileType=%@", (unsigned long)metadata.count,
        (unsigned long)export.metadata.count, export.outputFileType);
#endif
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [export exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) {
        if (stopped(cancelled) || deadline.timeIntervalSinceNow <= 0) {
            [export cancelExport];
            // Wait for the writer to release the private staging file before cleanup.
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            return NO;
        }
    }
    return export.status == AVAssetExportSessionStatusCompleted && !stopped(cancelled);
}
static BOOL writeM4A(AVURLAsset *asset, NSURL *outputURL, NSString *title, NSString *artist, NSString *album,
    NSData *artwork, BOOL (^cancelled)(void)) {
    NSMutableArray *metadata = [NSMutableArray array];
    for (AVMetadataItem *item in [asset metadataForFormat:AVMetadataFormatiTunesMetadata]) {
        if (![@[AVMetadataCommonKeyTitle, AVMetadataCommonKeyArtist, AVMetadataCommonKeyAlbumName, AVMetadataCommonKeyArtwork]
            containsObject:item.commonKey ?: @""]) [metadata addObject:item];
    }
    [metadata addObject:metadataItem(AVMetadataIdentifieriTunesMetadataSongName, title, (__bridge NSString *)kCMMetadataBaseDataType_UTF8)];
    [metadata addObject:metadataItem(AVMetadataIdentifieriTunesMetadataArtist, artist, (__bridge NSString *)kCMMetadataBaseDataType_UTF8)];
    [metadata addObject:metadataItem(AVMetadataIdentifieriTunesMetadataAlbum, album, (__bridge NSString *)kCMMetadataBaseDataType_UTF8)];
    NSString *mime = pictureType(artwork);
    if (mime) [metadata addObject:metadataItem(AVMetadataIdentifieriTunesMetadataCoverArt, artwork,
        (__bridge NSString *)([mime isEqual:@"image/png"] ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG))];
    return writeM4AItems(asset, outputURL, metadata, cancelled);
}
NSDictionary *SGAutomaticInstallAudio(NSURL *staging, NSDictionary *requested, NSString **reason) {
    return SGAutomaticInstallAudioCancellable(staging, requested, nil, reason);
}
NSDictionary *SGAutomaticInstallAudioCancellable(NSURL *staging, NSDictionary *requested, BOOL (^cancelled)(void), NSString **reason) {
    if (reason) *reason = nil;
    if (stopped(cancelled)) return failure(reason, @"Transfert arrêté.");
    if (![requested isKindOfClass:NSDictionary.class]) return failure(reason, @"Le morceau à associer au fichier est invalide.");
    NSString *spotify = SGAutomaticSpotifyURL(requested[@"spotify"]);
    NSNumber *position = requested[@"position"];
    if (!staging.isFileURL || ![spotify containsString:@"/track/"] || ![position isKindOfClass:NSNumber.class] ||
        position.doubleValue != position.unsignedIntegerValue || position.unsignedIntegerValue < 1 || position.unsignedIntegerValue > 500)
        return failure(reason, @"Le morceau à associer au fichier est invalide.");
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *size = nil, *regular = nil, *link = nil;
    [staging getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [staging getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    [staging getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    if (!regular.boolValue || link.boolValue || size.unsignedLongLongValue < 1024 || size.unsignedLongLongValue > audioLimit)
        return failure(reason, @"Le fichier doit contenir un audio de moins de 100 Mo.");
    NSData *data = [NSData dataWithContentsOfURL:staging options:NSDataReadingMappedIfSafe error:nil];
    if (data.length != size.unsignedLongLongValue) return failure(reason, @"Lecture du fichier impossible.");
    const uint8_t *bytes = data.bytes;
    BOOL mpegFrame = bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0 && (bytes[1] & 0x18) != 0x08 &&
        (bytes[1] & 0x06) == 0x02 && (bytes[2] & 0xf0) != 0xf0 && (bytes[2] & 0x0c) != 0x0c;
    BOOL mp3 = !memcmp(bytes, "ID3", 3) || mpegFrame;
    BOOL m4a = !memcmp(bytes + 4, "ftyp", 4);
    if (!mp3 && !m4a) return failure(reason, @"Ce lien ne fournit pas un MP3 ou un M4A. Choisis le fichier audio, pas la page du site.");
    NSString *ext = mp3 ? @"mp3" : @"m4a";
    NSURL *probe = temporarySibling(staging, ext), *retagged = temporarySibling(staging, ext);
    if (![fm linkItemAtURL:staging toURL:probe error:nil] && ![fm copyItemAtURL:staging toURL:probe error:nil])
        return failure(reason, @"Impossible de préparer la vérification du fichier.");
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:probe options:nil];
        double seconds = CMTimeGetSeconds(asset.duration);
        if (!asset.playable || ![asset tracksWithMediaType:AVMediaTypeAudio].count || [asset tracksWithMediaType:AVMediaTypeVideo].count ||
            !isfinite(seconds) || seconds < 1 || seconds > 86400)
            return failure(reason, @"Le fichier reçu n'est pas un morceau audio lisible.");
        if (!SGAutomaticDurationMatches(requested, seconds))
            return failure(reason, @"La durée ne correspond pas au morceau choisi. Vérifie la version ou utilise une autre source.");
        if (!completeAudio(asset, seconds, cancelled))
            return failure(reason, stopped(cancelled) ? @"Transfert arrêté." : @"Le fichier audio est incomplet ou endommagé. Essaie à nouveau ou choisis une autre source.");
        NSString *originalTitle = @"", *originalArtist = @"", *album = @""; NSData *artwork = nil;
        for (AVMetadataItem *item in asset.commonMetadata) {
            if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) originalTitle = item.stringValue ?: @"";
            if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) originalArtist = item.stringValue ?: @"";
            if ([item.commonKey isEqual:AVMetadataCommonKeyAlbumName]) album = item.stringValue ?: @"";
            if ([item.commonKey isEqual:AVMetadataCommonKeyArtwork] && pictureType(item.dataValue)) artwork = item.dataValue;
        }
        NSString *title = label(requested[@"expectedTitle"]), *artist = label(requested[@"expectedArtist"]);
        if (!title.length) title = originalTitle.length ? originalTitle : label(requested[@"title"]);
        if (!artist.length) artist = originalArtist.length ? originalArtist : label(requested[@"artist"]);
        if (!title.length || !artist.length || [title isEqual:@"Recherche du morceau..."])
            return failure(reason, @"Il manque le titre ou l'artiste. Choisis un fichier qui contient ces informations.");
        if (title.length > 512 || artist.length > 512 || album.length > 512)
            return failure(reason, @"Les informations du fichier sont trop volumineuses.");
        BOOL addedCover = !artwork && pictureType(requested[@"artworkData"]);
        if (addedCover) artwork = requested[@"artworkData"];
        BOOL retag = ![title isEqual:originalTitle] || ![artist isEqual:originalArtist] || addedCover;
        NSURL *prepared = staging;
        if (stopped(cancelled)) return failure(reason, @"Transfert arrêté.");
        if (retag) {
            BOOL written = mp3 ? writeMP3(data, retagged, title, artist, album, artwork, cancelled) :
                writeM4A(asset, retagged, title, artist, album, artwork, cancelled);
            if (!written) return failure(reason, stopped(cancelled) ? @"Transfert arrêté." : @"Impossible d'intégrer les informations du morceau sans modifier l'audio. Essaie une autre source.");
            prepared = retagged;
            AVURLAsset *check = [AVURLAsset URLAssetWithURL:prepared options:nil];
            double duration = CMTimeGetSeconds(check.duration);
            BOOL foundTitle = NO, foundArtist = NO;
            for (AVMetadataItem *item in check.commonMetadata) {
                if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) foundTitle |= [item.stringValue isEqual:title];
                if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) foundArtist |= [item.stringValue isEqual:artist];
            }
            if (!check.playable || !isfinite(duration) || fabs(duration - seconds) > 0.5 || !foundTitle || !foundArtist) {
#ifdef SG_AUTOMATIC_AUDIO_TEST
                NSLog(@"Retag validation: playable=%d duration=%.6f original=%.6f title=%d artist=%d formats=%@",
                    check.playable, duration, seconds, foundTitle, foundArtist, check.availableMetadataFormats);
                for (NSString *format in check.availableMetadataFormats)
                    for (AVMetadataItem *item in [check metadataForFormat:format])
                        NSLog(@"Retag metadata: id=%@ key=%@ (%@) common=%@ type=%@ value=%@ bytes=%lu",
                            item.identifier, item.key, [item.key class], item.commonKey, item.dataType,
                            [item.commonKey isEqual:AVMetadataCommonKeyArtwork] ? @"<artwork>" : item.stringValue,
                            (unsigned long)item.dataValue.length);
#endif
                return failure(reason, @"Les informations audio n'ont pas pu être vérifiées après l'import.");
            }
        }
        NSNumber *preparedSize = nil; [prepared getResourceValue:&preparedSize forKey:NSURLFileSizeKey error:nil];
        if (preparedSize.unsignedLongLongValue < 1024 || preparedSize.unsignedLongLongValue > audioLimit)
            return failure(reason, @"Le fichier préparé dépasse la limite de 100 Mo.");
        NSString *hash = audioHash(prepared, cancelled);
        if (!hash) return failure(reason, stopped(cancelled) ? @"Transfert arrêté." : @"La vérification du fichier a échoué.");
        NSMutableDictionary *result = [@{@"position":position, @"spotify":spotify, @"state":@"ready", @"id":hash,
            @"bytes":preparedSize, @"seconds":@(seconds), @"title":title, @"artist":artist, @"album":album, @"extension":ext} mutableCopy];
        for (NSString *key in @[@"expectedTitle", @"expectedArtist", @"expectedArtists", @"expectedSeconds", @"coverURL", @"sourceURL", @"sourceKind", @"sourceID"])
            if (requested[key] && requested[key] != NSNull.null) result[key] = requested[key];
        NSDictionary *wrapper = @{@"version":@2, @"id":@"00000000000000000000000000000000", @"url":spotify,
            @"state":@"complete", @"name":@"", @"message":@"", @"scope":@"", @"items":@[[result mutableCopy]]};
        NSMutableDictionary *validationRow = [result mutableCopy]; validationRow[@"position"] = @1;
        NSMutableDictionary *validation = [wrapper mutableCopy]; validation[@"items"] = @[validationRow];
        if (![NSJSONSerialization isValidJSONObject:validation] || !SGAutomaticJob([NSJSONSerialization dataWithJSONObject:validation options:0 error:nil]))
            return failure(reason, @"Les informations de la source sont invalides.");
        NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *directory = [docs URLByAppendingPathComponent:@"Spoti Downloads" isDirectory:YES];
        [fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil];
        NSNumber *isDir = nil, *isLink = nil;
        [directory getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        [directory getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (!isDir.boolValue || isLink.boolValue || ![directory.URLByResolvingSymlinksInPath.URLByDeletingLastPathComponent.path isEqual:docs.URLByResolvingSymlinksInPath.path])
            return failure(reason, @"Le dossier des téléchargements est inaccessible.");
        NSURL *target = [directory URLByAppendingPathComponent:[hash stringByAppendingPathExtension:ext]];
        if (stopped(cancelled)) return failure(reason, @"Transfert arrêté.");
        if ([fm fileExistsAtPath:target.path]) {
            NSNumber *targetLink = nil; [target getResourceValue:&targetLink forKey:NSURLIsSymbolicLinkKey error:nil];
            if (targetLink.boolValue || ![audioHash(target, cancelled) isEqual:hash])
                return failure(reason, stopped(cancelled) ? @"Transfert arrêté." : @"Un fichier différent occupe déjà cet emplacement.");
        } else {
            if (stopped(cancelled)) return failure(reason, @"Transfert arrêté.");
            if (![fm moveItemAtURL:prepared toURL:target error:nil])
                return failure(reason, @"L'enregistrement a échoué. Vérifie l'espace disponible.");
        }
        // Installation is the commit point: return its record even if cancellation races just afterwards.
        [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:target.path error:nil];
        return result;
    } @finally {
        [fm removeItemAtURL:probe error:nil]; [fm removeItemAtURL:retagged error:nil];
    }
}
#pragma clang diagnostic pop

#ifdef SG_AUTOMATIC_AUDIO_TEST
#import "AutomaticAudioFixture.h"
#include <assert.h>
static NSURL *testInput(NSData *data, NSString *ext) {
    NSURL *file = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:ext]];
    assert([data writeToURL:file atomically:YES]); return file;
}
static NSData *compressedAudio(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    assert(reader && track);
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
    assert([reader canAddOutput:output]); [reader addOutput:output]; assert([reader startReading]);
    NSMutableData *bytes = [NSMutableData data]; CMSampleBufferRef sample = NULL;
    while ((sample = [output copyNextSampleBuffer])) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t count = block ? CMBlockBufferGetDataLength(block) : 0;
        NSMutableData *packet = [NSMutableData dataWithLength:count];
        assert(!count || CMBlockBufferCopyDataBytes(block, 0, count, packet.mutableBytes) == kCMBlockBufferNoErr);
        [bytes appendData:packet]; CFRelease(sample);
    }
    assert(reader.status == AVAssetReaderStatusCompleted && bytes.length);
    return bytes;
}
static void diagnoseM4AMetadata(NSURL *source, NSDictionary *request) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    NSData *packets = compressedAudio(source);
    NSArray *iTunes = @[AVMetadataIdentifieriTunesMetadataSongName, AVMetadataIdentifieriTunesMetadataArtist,
        AVMetadataIdentifieriTunesMetadataCoverArt];
    NSArray *common = @[AVMetadataCommonIdentifierTitle, AVMetadataCommonIdentifierArtist, AVMetadataCommonIdentifierArtwork];
    NSArray *values = @[request[@"expectedTitle"], request[@"expectedArtist"], request[@"artworkData"]];
    for (NSUInteger mode = 0; mode < 8; mode++) {
        NSMutableArray *metadata = [NSMutableArray array];
        NSArray *identifiers = (mode & 1) ? common : iTunes;
        for (NSUInteger index = 0; index < values.count; index++) {
            AVMutableMetadataItem *item = [AVMutableMetadataItem new];
            item.identifier = identifiers[index]; item.value = values[index];
            if (mode & 2) item.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
            if (mode & 4) item.dataType = (__bridge NSString *)(index == 2 ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_UTF8);
            [metadata addObject:item];
        }
        NSURL *output = temporarySibling(source, @"m4a");
        BOOL written = writeM4AItems(asset, output, metadata, nil);
        AVURLAsset *check = [AVURLAsset URLAssetWithURL:output options:nil];
        BOOL title = NO, artist = NO, cover = NO;
        for (AVMetadataItem *item in check.commonMetadata) {
            if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) title |= [item.stringValue isEqual:values[0]];
            if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) artist |= [item.stringValue isEqual:values[1]];
            if ([item.commonKey isEqual:AVMetadataCommonKeyArtwork]) cover |= [item.dataValue isEqual:values[2]];
        }
        BOOL sameAudio = written && check.playable && [packets isEqual:compressedAudio(output)];
        NSLog(@"M4A probe: keySpace=%@ locale=%d explicitType=%d written=%d title=%d artist=%d cover=%d sameAAC=%d formats=%@",
            (mode & 1) ? @"common" : @"iTunes", !!(mode & 2), !!(mode & 4), written, title, artist, cover, sameAudio,
            check.availableMetadataFormats);
        [NSFileManager.defaultManager removeItemAtURL:output error:nil];
    }
}
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [fm createDirectoryAtURL:docs withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *request = @{@"position":@1, @"spotify":@"https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT", @"title":@"Repair fixture", @"artist":@"Synthetic test"};
    NSString *reason = nil;
    NSData *raw = [[NSData alloc] initWithBase64EncodedString:mp3Fixture options:0];
    NSURL *source = testInput(raw, @"mp3");
    NSDictionary *row = SGAutomaticInstallAudio(source, request, &reason);
    if (!row) NSLog(@"MP3 import failed: %@", reason);
    assert(row && [row[@"extension"] isEqual:@"mp3"] && [row[@"title"] isEqual:request[@"title"]]);
    double completeMP3Duration = [row[@"seconds"] doubleValue];
    NSURL *target = [[docs URLByAppendingPathComponent:@"Spoti Downloads"] URLByAppendingPathComponent:[row[@"id"] stringByAppendingPathExtension:@"mp3"]];
    NSData *installed = [NSData dataWithContentsOfURL:target];
    assert(installed.length > raw.length);
    assert([[installed subdataWithRange:NSMakeRange(installed.length - raw.length, raw.length)] isEqual:raw]);
    NSURL *duplicate = testInput(installed, @"mp3");
    NSDictionary *again = SGAutomaticInstallAudio(duplicate, request, &reason);
    assert([again[@"id"] isEqual:row[@"id"]]);
    [fm removeItemAtURL:duplicate error:nil]; [fm removeItemAtURL:target error:nil]; [fm removeItemAtURL:source error:nil];
    NSData *m4a = [[NSData alloc] initWithBase64EncodedString:m4aFixture options:0];
    source = testInput(m4a, @"download"); row = SGAutomaticInstallAudio(source, request, &reason);
    if (!row) NSLog(@"M4A import failed: %@", reason);
    assert(row && [row[@"extension"] isEqual:@"m4a"]);
    target = [[docs URLByAppendingPathComponent:@"Spoti Downloads"] URLByAppendingPathComponent:[row[@"id"] stringByAppendingPathExtension:@"m4a"]];
    assert([[NSData dataWithContentsOfURL:target] isEqual:m4a]); [fm removeItemAtURL:target error:nil];
    NSMutableDictionary *catalogue = [request mutableCopy];
    catalogue[@"expectedTitle"] = @"Catalogue title"; catalogue[@"expectedArtist"] = @"Catalogue artist";
    catalogue[@"expectedSeconds"] = @1.3; catalogue[@"sourceKind"] = @"youtube-music";
    catalogue[@"artworkData"] = [[NSData alloc] initWithBase64EncodedString:coverFixture options:0];
    NSData *bareM4A = [[NSData alloc] initWithBase64EncodedString:untaggedM4AFixture options:0];
    source = testInput(bareM4A, @"download");
    NSURL *before = testInput(bareM4A, @"m4a");
    NSData *originalPackets = compressedAudio(before);
    row = SGAutomaticInstallAudio(source, catalogue, &reason);
    if (!row) { NSLog(@"Bare M4A retag failed: %@", reason); diagnoseM4AMetadata(before, catalogue); }
    assert(row && [row[@"title"] isEqual:catalogue[@"expectedTitle"]] && [row[@"sourceKind"] isEqual:@"youtube-music"] && !row[@"artworkData"]);
    target = [[docs URLByAppendingPathComponent:@"Spoti Downloads"] URLByAppendingPathComponent:[row[@"id"] stringByAppendingPathExtension:@"m4a"]];
    assert([originalPackets isEqual:compressedAudio(target)]);
    AVURLAsset *withCover = [AVURLAsset URLAssetWithURL:target options:nil]; BOOL foundCover = NO;
    for (AVMetadataItem *metadata in withCover.commonMetadata)
        if ([metadata.commonKey isEqual:AVMetadataCommonKeyArtwork]) foundCover |= [metadata.dataValue isEqual:catalogue[@"artworkData"]];
    assert(foundCover);
    [fm removeItemAtURL:before error:nil]; [fm removeItemAtURL:source error:nil]; [fm removeItemAtURL:target error:nil];
    source = testInput(raw, @"mp3");
    assert(!SGAutomaticInstallAudioCancellable(source, request, ^BOOL { return YES; }, &reason));
    assert([fm fileExistsAtPath:source.path] && [reason isEqual:@"Transfert arrêté."]);
    __block NSUInteger checkpoints = 0;
    assert(!SGAutomaticInstallAudioCancellable(source, catalogue, ^BOOL { return ++checkpoints >= 4; }, &reason));
    assert([fm fileExistsAtPath:source.path] && [reason isEqual:@"Transfert arrêté."]);
    catalogue[@"expectedSeconds"] = @180;
    assert(!SGAutomaticInstallAudio(source, catalogue, &reason));
    assert([reason containsString:@"durée"]);
    [fm removeItemAtURL:source error:nil];
    // Keep the MP3 duration/header while removing half its media packets.
    source = testInput([raw subdataWithRange:NSMakeRange(0, raw.length / 2)], @"mp3");
    assert(!completeAudio([AVURLAsset URLAssetWithURL:source options:nil], completeMP3Duration, nil));
    assert(!SGAutomaticInstallAudio(source, request, &reason)); [fm removeItemAtURL:source error:nil];
    source = testInput([[@"<html>Not audio</html>" stringByPaddingToLength:2048 withString:@" " startingAtIndex:0] dataUsingEncoding:NSUTF8StringEncoding], @"mp3");
    assert(!SGAutomaticInstallAudio(source, request, &reason)); [fm removeItemAtURL:source error:nil];
    puts("Audio import: PASS (MP3 bytes preserved, M4A passthrough + cover, deduplication, duration check, cancellation, truncated audio/HTML rejection)");
} return 0; }
#endif
