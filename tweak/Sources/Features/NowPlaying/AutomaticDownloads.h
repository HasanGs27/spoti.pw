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
// Main-thread snapshot. Green is reserved for files verified by the download engine.
// Keys: state (idle/running/ready/incomplete/error/partial/paused), completed, total, progress.
NSDictionary *SGAutomaticDownloadStatus(id entity);
// Immutable, verified snapshots, safe from the native player's dispatch queue.
NSDictionary *SGAutomaticDownloadedRow(id track);
NSArray<NSDictionary *> *SGAutomaticDownloadedRows(id playlist);
void SGAutomaticDownloadRegisterTracks(id entity, NSArray *tracks);
