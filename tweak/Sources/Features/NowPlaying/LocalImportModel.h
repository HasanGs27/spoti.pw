#import <Foundation/Foundation.h>

NSURL *SGLocalImportSource(id value);
NSDictionary *SGLocalImportRequest(id value);
NSDictionary *SGLocalImportTarget(id value);
NSDictionary *SGLocalImportTargetRow(id job, id target);
NSDictionary *SGLocalImportReadyRow(id value);
NSDictionary *SGLocalImportJob(id value, NSDictionary *request);
NSArray<NSDictionary *> *SGLocalImportRecords(id value);
NSArray<NSDictionary *> *SGLocalImportStoreRecord(id entries, NSDictionary *entry);
