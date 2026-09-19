#import <UIKit/UIKit.h>

// Supply an immutable, verified downloaded-row snapshot. The original's SHA is
// the PC source identity; this page never changes its catalogue association.
UIViewController *SGAudioVariantsPageCreate(NSDictionary *downloadedRow);
