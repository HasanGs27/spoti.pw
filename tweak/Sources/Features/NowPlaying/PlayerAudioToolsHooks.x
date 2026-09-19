#import "PlayerAudioTools.h"

// This exact footer is already used by the player styling and declutter hooks.
// No playback row, system-wide view or animation is intercepted.
%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    SGPlayerAudioToolsLayout((UIViewController *)self);
}
%end
%ctor { %init; }
