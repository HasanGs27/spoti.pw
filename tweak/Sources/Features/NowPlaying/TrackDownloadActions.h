#import <Foundation/Foundation.h>

// Preserve the exact menu target: a playlist, episode or local-file URI never
// falls back to the playing track. Unknown input leaves native actions intact.
id SGTrackDownloadMenuActions(id actions, id entity);
