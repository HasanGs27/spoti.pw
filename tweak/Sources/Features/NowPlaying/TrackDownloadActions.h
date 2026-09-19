#import <Foundation/Foundation.h>

// Preserve the exact menu target. Catalogue tracks receive download and audio
// actions; local tracks receive audio actions only. Native actions stay intact.
id SGTrackDownloadMenuActions(id actions, id entity);
