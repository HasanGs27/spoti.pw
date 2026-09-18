// Suppress the offline notice before presentation, so Spotify never allocates its
// bottom attachment. Do not change connectivity, safe areas, or player transforms.
#import "Core/SGCore.h"

static BOOL SGIsOfflineNotice(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *text = [(NSString *)value lowercaseString];
    return [text isEqualToString:@"vous êtes en mode hors connexion"]
        || [text isEqualToString:@"vous êtes hors connexion"]
        || [text isEqualToString:@"you're offline"]
        || [text isEqualToString:@"you’re offline"]
        || [text isEqualToString:@"spotify is offline"]
        || [text isEqualToString:@"spotify is in offline mode"]
        || [text isEqualToString:@"sLimitedExperienceIndicatorSpotifyIsOffline".lowercaseString]
        || [text isEqualToString:@"sLimitedExperienceIndicatorSpotifyIsInOfflineMode".lowercaseString];
}

// Verified against the bundled Spotify executable's Objective-C metadata.
@interface SPTMessageBarItem : NSObject
@property (nonatomic, copy) NSString *message;
@end

%hook _TtC44LimitedExperienceIndicator_MessageBarRuntime15MessageBarModel
- (void)presentMessageBarItem:(SPTMessageBarItem *)item animated:(BOOL)animated {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"SGOfflineMessageBarDisabled"] &&
        [item respondsToSelector:@selector(message)] && SGIsOfflineNotice(item.message)) {
        SGLog(@"offline message suppressed before presentation");
        return;
    }
    %orig;
}
%end
