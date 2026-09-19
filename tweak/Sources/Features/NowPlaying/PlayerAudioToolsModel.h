#import <Foundation/Foundation.h>

NSDictionary *SGPlayerAudioSourceForLocalURI(NSString *uri, NSArray<NSDictionary *> *sources);
NSDictionary *SGPlayerAudioPreparationRecord(id value, NSString *uri);
NSDictionary *SGPlayerAudioPreparedSource(id job, NSString *uri);
