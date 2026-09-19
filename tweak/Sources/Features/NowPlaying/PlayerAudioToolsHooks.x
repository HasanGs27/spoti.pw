#import "PlayerAudioTools.h"

// The title/artist unit is attested in this Spotify binary and already used by
// Declutter. Only its own horizontal stack may receive the two shortcuts.
%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    SGPlayerAudioToolsLayout((UIViewController *)self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGPlayerAudioToolsLayout((UIViewController *)self);
}
%end
%ctor { %init; }
