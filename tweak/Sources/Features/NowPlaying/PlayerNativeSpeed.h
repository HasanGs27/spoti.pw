#import <UIKit/UIKit.h>

// Explicit native rate request for the captured current track. Availability and
// the observed result are checked. No download or PC-copy request is made.
void SGPresentPlayerNativeSpeed(UIViewController *owner);
// Menu actions must still match this exact track when the sheet is presented.
void SGPresentPlayerNativeSpeedForTrack(UIViewController *owner, NSString *expectedURI);
