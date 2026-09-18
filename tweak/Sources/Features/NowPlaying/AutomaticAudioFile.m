#import "AutomaticAudioFile.h"
#import "AutomaticDownloadModel.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSDictionary *failure(NSString **reason, NSString *message) { if (reason) *reason = message; return nil; }
static void frame(NSMutableData *tag, const char *name, NSData *body) {
    uint32_t size = CFSwapInt32HostToBig((uint32_t)body.length);
    uint16_t flags = 0;
    [tag appendBytes:name length:4]; [tag appendBytes:&size length:4];
    [tag appendBytes:&flags length:2]; [tag appendData:body];
}
static void textFrame(NSMutableData *tag, const char *name, NSString *value) {
    uint8_t encoding = 1; // UTF-16 with BOM, ID3v2.3.
    NSMutableData *body = [NSMutableData dataWithBytes:&encoding length:1];
    [body appendData:[value dataUsingEncoding:NSUTF16StringEncoding]];
    frame(tag, name, body);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
NSDictionary *SGAutomaticInstallAudio(NSURL *staging, NSDictionary *requested, NSString **reason) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *size = nil; [staging getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue < 1024 || size.unsignedLongLongValue > 100 * 1024 * 1024)
        return failure(reason, @"Le fichier doit contenir un audio de moins de 100 Mo.");
    NSData *data = [NSData dataWithContentsOfURL:staging options:NSDataReadingMappedIfSafe error:nil];
    if (data.length != size.unsignedLongLongValue) return failure(reason, @"Lecture du fichier impossible.");
    const uint8_t *bytes = data.bytes;
    BOOL mp3 = !memcmp(bytes, "ID3", 3) || (bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0);
    BOOL m4a = !memcmp(bytes + 4, "ftyp", 4);
    if (!mp3 && !m4a) return failure(reason, @"Ce lien ne fournit pas un MP3 ou un M4A. Choisis le fichier audio, pas la page du site.");
    // CDN links often have no extension; give AVFoundation the detected format, not the URL's suffix.
    NSURL *probe = [staging.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:mp3 ? @"mp3" : @"m4a"]];
    if (![fm linkItemAtURL:staging toURL:probe error:nil]) return failure(reason, @"Impossible de préparer la vérification du fichier.");
    @try {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:probe options:nil];
    double seconds = CMTimeGetSeconds(asset.duration);
    if (!asset.playable || ![asset tracksWithMediaType:AVMediaTypeAudio].count ||
        [asset tracksWithMediaType:AVMediaTypeVideo].count || !isfinite(seconds) || seconds < 1)
        return failure(reason, @"Le fichier reçu n'est pas un morceau audio lisible.");
    NSString *title = @"", *artist = @"", *album = @""; NSData *artwork = nil;
    for (AVMetadataItem *item in asset.commonMetadata) {
        if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) title = item.stringValue ?: @"";
        if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) artist = item.stringValue ?: @"";
        if ([item.commonKey isEqual:AVMetadataCommonKeyAlbumName]) album = item.stringValue ?: @"";
        if ([item.commonKey isEqual:AVMetadataCommonKeyArtwork]) artwork = item.dataValue;
    }
    // Preserve tagged files and their original audio bytes. An untagged MP3 gets only ID3 metadata.
    if (!title.length || !artist.length) {
        if (!mp3) return failure(reason, @"Ce M4A n'a pas de titre/artiste intégrés. Choisis un fichier avec ces informations ou un MP3.");
        if (!title.length) title = requested[@"title"];
        if (!artist.length) artist = requested[@"artist"];
        if (!title.length || !artist.length || [title isEqual:@"Recherche du morceau..."])
            return failure(reason, @"Il manque le titre ou l'artiste. Choisis un fichier qui contient ces informations.");
        NSUInteger offset = 0;
        if (!memcmp(bytes, "ID3", 3)) {
            if (bytes[3] < 2 || bytes[3] > 4 || ((bytes[6] | bytes[7] | bytes[8] | bytes[9]) & 0x80))
                return failure(reason, @"Les informations du MP3 sont endommagées.");
            offset = 10 + ((NSUInteger)bytes[6] << 21) + ((NSUInteger)bytes[7] << 14) + ((NSUInteger)bytes[8] << 7) + bytes[9];
            if (bytes[3] == 4 && (bytes[5] & 0x10)) offset += 10;
            if (offset >= data.length) return failure(reason, @"Les informations du MP3 sont incomplètes.");
        }
        NSMutableData *tag = [NSMutableData data];
        textFrame(tag, "TIT2", title); textFrame(tag, "TPE1", artist); textFrame(tag, "TALB", album);
        if (artwork.length && artwork.length <= 8 * 1024 * 1024) {
            const uint8_t *picture = artwork.bytes;
            const char *mime = artwork.length > 8 && picture[0] == 0x89 ? "image/png" : "image/jpeg";
            uint8_t encoding = 0, cover = 3, terminator = 0;
            NSMutableData *body = [NSMutableData dataWithBytes:&encoding length:1];
            [body appendBytes:mime length:strlen(mime) + 1]; [body appendBytes:&cover length:1];
            [body appendBytes:&terminator length:1]; [body appendData:artwork]; frame(tag, "APIC", body);
        }
        NSUInteger n = tag.length;
        uint8_t header[] = {'I','D','3',3,0,0,(n>>21)&127,(n>>14)&127,(n>>7)&127,n&127};
        NSMutableData *retagged = [NSMutableData dataWithBytes:header length:10];
        [retagged appendData:tag]; [retagged appendBytes:bytes + offset length:data.length - offset];
        if (![retagged writeToURL:staging options:NSDataWritingAtomic error:nil]) return failure(reason, @"Impossible d'enregistrer les informations du morceau.");
        data = retagged;
    }
    if (title.length > 512 || artist.length > 512 || album.length > 512 || data.length > 100 * 1024 * 1024)
        return failure(reason, @"Les informations du fichier sont trop volumineuses.");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
    NSString *ext = mp3 ? @"mp3" : @"m4a";
    NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [docs URLByAppendingPathComponent:@"Spoti Downloads" isDirectory:YES];
    [fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil];
    NSNumber *isDir = nil, *link = nil;
    [directory getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
    [directory getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    if (!isDir.boolValue || link.boolValue) return failure(reason, @"Le dossier des téléchargements est inaccessible.");
    NSURL *target = [directory URLByAppendingPathComponent:[hash stringByAppendingPathExtension:ext]];
    if ([fm fileExistsAtPath:target.path]) {
        NSNumber *isLink = nil; [target getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (isLink.boolValue || ![[NSData dataWithContentsOfURL:target options:NSDataReadingMappedIfSafe error:nil] isEqual:data])
            return failure(reason, @"Un fichier différent occupe déjà cet emplacement.");
    } else if (![fm moveItemAtURL:staging toURL:target error:nil]) return failure(reason, @"L'enregistrement a échoué. Vérifie l'espace disponible.");
    [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:target.path error:nil];
    return @{@"position":requested[@"position"], @"spotify":SGAutomaticSpotifyURL(requested[@"spotify"]), @"state":@"ready",
        @"id":hash, @"bytes":@(data.length), @"seconds":@(seconds), @"title":title, @"artist":artist, @"album":album, @"extension":ext};
    } @finally {
        [fm removeItemAtURL:probe error:nil];
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
    NSURL *target = [[docs URLByAppendingPathComponent:@"Spoti Downloads"] URLByAppendingPathComponent:[row[@"id"] stringByAppendingPathExtension:@"mp3"]];
    NSData *installed = [NSData dataWithContentsOfURL:target];
    assert(installed.length > raw.length);
    assert([[installed subdataWithRange:NSMakeRange(installed.length - raw.length, raw.length)] isEqual:raw]);
    NSURL *duplicate = testInput(installed, @"mp3");
    NSDictionary *again = SGAutomaticInstallAudio(duplicate, request, &reason);
    assert([again[@"id"] isEqual:row[@"id"]]);
    [fm removeItemAtURL:duplicate error:nil]; [fm removeItemAtURL:target error:nil];
    NSData *m4a = [[NSData alloc] initWithBase64EncodedString:m4aFixture options:0];
    source = testInput(m4a, @"download"); row = SGAutomaticInstallAudio(source, request, &reason);
    if (!row) NSLog(@"M4A import failed: %@", reason);
    assert(row && [row[@"extension"] isEqual:@"m4a"]);
    target = [[docs URLByAppendingPathComponent:@"Spoti Downloads"] URLByAppendingPathComponent:[row[@"id"] stringByAppendingPathExtension:@"m4a"]];
    assert([[NSData dataWithContentsOfURL:target] isEqual:m4a]); [fm removeItemAtURL:target error:nil];
    source = testInput([[@"<html>Not audio</html>" stringByPaddingToLength:2048 withString:@" " startingAtIndex:0] dataUsingEncoding:NSUTF8StringEncoding], @"mp3");
    assert(!SGAutomaticInstallAudio(source, request, &reason)); [fm removeItemAtURL:source error:nil];
    puts("Manual audio import: PASS (MP3 metadata, unchanged audio, M4A, deduplication, HTML rejection)");
} return 0; }
#endif
