#import <Foundation/Foundation.h>
NSURL *SGNativeMetadataURL(id spotify);
NSDictionary *SGNativeMetadataEntity(NSData *html, id spotify);
NSDictionary *SGNativeTrackMetadata(NSDictionary *entity, NSUInteger position);
NSDictionary *SGNativeCollectionJob(NSData *html, id spotify, NSString **reason);
