#import <Foundation/Foundation.h>

NSDictionary *SGAudioVariantRequest(id value);
NSDictionary *SGAudioVariantJob(id value, NSDictionary *request);
NSDictionary *SGAudioVariantListing(id value);
NSArray<NSDictionary *> *SGAudioVariantRecords(id value);
// Evicts only completed history, never a pending or ambiguously accepted request.
NSArray<NSDictionary *> *SGAudioVariantStoreRecord(id records, NSDictionary *record);
NSString *SGAudioVariantKey(NSDictionary *request);
NSString *SGAudioVariantLabel(NSDictionary *request);
NSDictionary *SGAudioVariantReadyRow(id value);
