#import <UIKit/UIKit.h>
// Views can appear before the engine singleton registers defaults. Preserve an
// explicit opt-out while making a fresh installation's arrow available immediately.
static inline BOOL SGAutomaticDownloadIsEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:@"SGAutomaticDownloadsEnabled"] == nil ||
        [defaults boolForKey:@"SGAutomaticDownloadsEnabled"];
}
UIViewController *SGAutomaticDownloadsPageCreate(void);
BOOL SGAutomaticDownloadEntity(id entity, UIView *source);
void SGAutomaticDownloadObservePlayer(id player);
// Standalone derived copies share the serial file importer, but never replace the
// canonical downloaded recording or its playlist associations. Call from main.
void SGAutomaticPrepareAudioToolsPC(void (^completion)(NSURL *root, NSString *error));
void SGAutomaticImportAudioVersion(NSURL *root, NSDictionary *row,
    BOOL (^cancelled)(void), void (^taskStarted)(NSURLSessionTask *task),
    void (^progress)(NSUInteger received, NSUInteger total),
    void (^completion)(NSDictionary *installedRow, NSString *error));
// A user-chosen source has its own identity. Optional target is an existing
// catalogue history reference; absent target means a standalone local file.
void SGAutomaticImportLocalSource(NSURL *root, NSDictionary *row, NSDictionary *target,
    BOOL (^cancelled)(void), void (^taskStarted)(NSURLSessionTask *task),
    void (^progress)(NSUInteger received, NSUInteger total),
    void (^completion)(NSDictionary *installedRow, NSString *error));
// Main-thread snapshot. Green is reserved for files verified by the download engine.
// Keys: state (idle/queued/running/ready/incomplete/error/partial/paused), completed, total, progress.
// queuePosition is one-based for queued collections, otherwise zero.
NSDictionary *SGAutomaticDownloadStatus(id entity);
// Immutable, verified snapshots, safe from the native player's dispatch queue.
NSDictionary *SGAutomaticDownloadedRow(id track);
NSArray<NSDictionary *> *SGAutomaticDownloadedRows(id playlist);
void SGAutomaticDownloadRegisterTracks(id entity, NSArray *tracks);
// Local file management. Completion always runs on the main queue; nil items means unavailable.
void SGAutomaticListLocalFiles(void (^completion)(NSArray<NSDictionary *> *items, NSString *message));
// Call only after the user confirms permanent deletion of this exact listed file.
void SGAutomaticDeleteLocalFile(NSDictionary *item, void (^completion)(BOOL success, NSString *message));
