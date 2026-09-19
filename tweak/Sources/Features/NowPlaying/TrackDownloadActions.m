#import "TrackDownloadActions.h"
#import "AutomaticDownloadModel.h"
#import <objc/message.h>
#import <objc/runtime.h>

#ifndef SG_TRACK_DOWNLOAD_ACTION_TEST
#import "AutomaticDownloads.h"
#import "PlayerAudioTools.h"
#import "PlayerNativeSpeed.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#endif

// Required methods and encodings are taken from this IPA's Objective-C
// protocols. The Swift legacy adapter checks this protocol when bridging actions.
@protocol SPTContextMenuAction <NSObject>
- (NSString *)title;
- (id)performAction;
@end
@protocol SPTDismissContextMenuAction <NSObject>
- (BOOL)shouldDismissContextMenuBeforePerformingAction;
@end
@protocol SGTrackDownloadCompletion <NSObject>
- (id)task;
- (void)completeWithValue:(id)value;
@end

static NSString *trackURL(id entity) {
    NSString *url = SGAutomaticSpotifyURL(entity);
    return [url hasPrefix:@"https://open.spotify.com/track/"] ? url : nil;
}
static NSString *audioURI(id entity) {
    NSString *url = trackURL(entity);
    if (url) return [@"spotify:track:" stringByAppendingString:url.lastPathComponent];
    NSString *uri = [entity isKindOfClass:NSURL.class] ? [entity absoluteString] : entity;
    if (![uri isKindOfClass:NSString.class] || uri.length > 4096 ||
        ![uri hasPrefix:@"spotify:local:"] || [uri componentsSeparatedByString:@":"].count != 6 ||
        [uri rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return uri;
}
static BOOL audioTargetMatches(NSString *uri, id playing) {
    return uri.length && [uri isEqual:audioURI(playing)];
}
static BOOL completionAvailable(void) {
    Class type = NSClassFromString(@"SPTaskCompletionSource");
    return type && [type instancesRespondToSelector:@selector(task)] &&
        [type instancesRespondToSelector:@selector(completeWithValue:)];
}

#ifdef SG_TRACK_DOWNLOAD_ACTION_TEST
static NSString *performedURL;
static NSUInteger performedCount;
static NSString *playingURI, *performedAudioURI;
static NSUInteger speedCount, vocalsCount, wrongTrackCount;
static BOOL testEnabled = YES;
static BOOL downloadEnabled(void) { return testEnabled; }
static NSDictionary *downloadStatus(NSString *url) { return @{@"state":@"idle"}; }
static void downloadTrack(NSString *url) { performedURL = url; performedCount++; }
static void openAudioTools(NSString *uri, BOOL vocals) {
    if (vocals) { vocalsCount++; return; }
    if (!audioTargetMatches(uri, playingURI)) { wrongTrackCount++; return; }
    performedAudioURI = uri; speedCount++;
}
#else
static BOOL downloadEnabled(void) { return SGAutomaticDownloadIsEnabled(); }
static NSDictionary *downloadStatus(NSString *url) {
    return NSThread.isMainThread ? SGAutomaticDownloadStatus(url) : @{@"state":@"idle"};
}
static void downloadTrack(NSString *url) {
    // The native presenter dismisses its menu first. Starting a download is an
    // explicit action; constructing a menu must never enqueue anything.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *owner = SGTopController();
        id<UIViewControllerTransitionCoordinator> transition = owner.transitionCoordinator;
        if (transition && [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            SGAutomaticDownloadEntity(url, nil);
        }]) return;
        SGAutomaticDownloadEntity(url, nil);
    });
}
static void openAudioTools(NSString *uri, BOOL vocals) {
    // The native action adapter dismisses its menu first. Resolve the presenter
    // and playing identity again after that transition, never the menu owner.
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^present)(void) = ^{
            UIViewController *owner = SGTopController();
            if (!owner || owner.presentedViewController || owner.isBeingDismissed) return;
            if (vocals) { SGPresentPlayerVocalReduction(owner); return; }
            if (!audioTargetMatches(uri, SGAutomaticPlayingTrack()[@"uri"])) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Vitesse de lecture"
                    message:@"Lance ce morceau, puis rouvre son menu pour régler sa vitesse."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                [owner presentViewController:alert animated:YES completion:nil];
                return;
            }
            SGPresentPlayerNativeSpeedForTrack(owner, uri);
        };
        id<UIViewControllerTransitionCoordinator> transition = SGTopController().transitionCoordinator;
        if (transition && [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if (!context.isCancelled) present();
        }]) return;
        present();
    });
}
#endif

@interface SGTrackDownloadAction : NSObject <SPTContextMenuAction, SPTDismissContextMenuAction>
@property(nonatomic, copy) NSString *targetURL;
#ifndef SG_TRACK_DOWNLOAD_ACTION_TEST
- (UIColor *)iconColor;
#endif
@end
@implementation SGTrackDownloadAction
- (NSString *)identifier { return @"spoti.download.track"; }
- (NSString *)accessibilityIdentifier { return self.identifier; }
- (NSString *)title {
    NSString *state = downloadStatus(self.targetURL)[@"state"];
    if ([state isEqual:@"ready"]) return @"Morceau téléchargé sur cet iPhone";
    if ([state isEqual:@"queued"]) return @"Morceau en attente de téléchargement";
    if ([state isEqual:@"running"]) return @"Suivre le téléchargement du morceau";
    if ([state isEqual:@"paused"]) return @"Reprendre le téléchargement du morceau";
    if ([state isEqual:@"error"] || [state isEqual:@"partial"]) return @"Réessayer ce morceau";
    return @"Télécharger ce morceau";
}
- (NSString *)accessibilityHint { return @"Enregistrer uniquement ce morceau pour l'écoute hors ligne"; }
- (BOOL)isDisabled { return !downloadEnabled(); }
- (BOOL)shouldDismissContextMenuBeforePerformingAction { return YES; }
- (id)performAction {
    id<SGTrackDownloadCompletion> completion = [[NSClassFromString(@"SPTaskCompletionSource") alloc] init];
    if (!completionAvailable() || !completion) return nil;
    id task = [completion task];
    if (downloadEnabled() && trackURL(self.targetURL)) downloadTrack(self.targetURL);
    [completion completeWithValue:@YES];
    return task;
}
#ifndef SG_TRACK_DOWNLOAD_ACTION_TEST
- (UIImage *)iconImage {
    NSString *state = downloadStatus(self.targetURL)[@"state"];
    NSString *symbol = [state isEqual:@"ready"] ? @"arrow.down.circle.fill" : [state isEqual:@"queued"] ? @"clock" :
        [state isEqual:@"paused"] ? @"pause.circle" : @"arrow.down.circle";
    // Spotify's dark menu can retain light UIKit traits. Bake the action tint
    // into the symbol so both native adapters display it consistently, even
    // when a reused image view ignores iconColor or has a default black tint.
    return [[UIImage systemImageNamed:symbol] imageWithTintColor:self.iconColor
                                                 renderingMode:UIImageRenderingModeAlwaysOriginal];
}
- (UIColor *)iconColor {
    NSString *state = downloadStatus(self.targetURL)[@"state"];
    if ([state isEqual:@"ready"]) return [UIColor colorWithRed:.114 green:.843 blue:.376 alpha:1];
    if ([state isEqual:@"error"] || [state isEqual:@"partial"]) return UIColor.systemRedColor;
    return [UIColor colorWithWhite:0.70 alpha:1];
}
#endif
@end

@interface SGTrackPlayerAudioAction : NSObject <SPTContextMenuAction, SPTDismissContextMenuAction>
@property(nonatomic, copy) NSString *targetURI;
@property(nonatomic) BOOL vocals;
@property(nonatomic) BOOL performed;
@end
@implementation SGTrackPlayerAudioAction
- (NSString *)identifier { return self.vocals ? @"spoti.player.vocals" : @"spoti.player.speed"; }
- (NSString *)accessibilityIdentifier { return self.identifier; }
- (NSString *)title { return self.vocals ? @"Sans voix · indisponible" : @"Vitesse de lecture"; }
- (NSString *)accessibilityHint {
    return self.vocals ? @"La réduction de voix en direct n'est pas disponible." : @"Ouvrir le curseur de vitesse pour ce morceau en cours de lecture.";
}
- (BOOL)isDisabled { return NO; }
- (BOOL)shouldDismissContextMenuBeforePerformingAction { return YES; }
- (id)performAction {
    id<SGTrackDownloadCompletion> completion = [[NSClassFromString(@"SPTaskCompletionSource") alloc] init];
    if (!completionAvailable() || !completion) return nil;
    id task = completion.task;
    if (!self.performed && audioURI(self.targetURI)) {
        self.performed = YES;
        openAudioTools(self.targetURI, self.vocals);
    }
    [completion completeWithValue:@YES];
    return task;
}
#ifndef SG_TRACK_DOWNLOAD_ACTION_TEST
- (UIColor *)iconColor { return [UIColor colorWithWhite:.70 alpha:1]; }
- (UIImage *)iconImage {
    return [[UIImage systemImageNamed:self.vocals ? @"mic.slash" : @"speedometer"]
        imageWithTintColor:self.iconColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}
#endif
@end

id SGTrackDownloadMenuActions(id actions, id entity) {
    if (!completionAvailable() || (actions && ![actions isKindOfClass:NSArray.class]) || [actions count] > 128) return actions;
    NSMutableArray *result = [NSMutableArray array];
    // Both presenter factories may be called for one menu. Replace only our own
    // entry, also preventing a reused menu from retaining a previous track URI.
    for (id action in actions) if (![action isKindOfClass:SGTrackDownloadAction.class] &&
        ![action isKindOfClass:SGTrackPlayerAudioAction.class]) [result addObject:action];
    NSUInteger position = 0;
    NSString *url = trackURL(entity), *uri = audioURI(entity);
    if (downloadEnabled() && url) {
        SGTrackDownloadAction *download = [SGTrackDownloadAction new]; download.targetURL = url;
        [result insertObject:download atIndex:position++];
    }
    if (uri) for (NSNumber *vocals in @[@NO, @YES]) {
        SGTrackPlayerAudioAction *audio = [SGTrackPlayerAudioAction new];
        audio.targetURI = uri; audio.vocals = vocals.boolValue;
        [result insertObject:audio atIndex:position++];
    }
    if (!position && result.count == [actions count]) return actions;
    return [result copy];
}

#ifdef SG_TRACK_DOWNLOAD_ACTION_TEST
#include <assert.h>
@interface SPTaskCompletionSource : NSObject <SGTrackDownloadCompletion>
@property(nonatomic, strong) NSObject *value;
@end
@implementation SPTaskCompletionSource
- (id)task { if (!self.value) self.value = [NSObject new]; return self.value; }
- (void)completeWithValue:(id)value {}
@end
int main(void) {
    @autoreleasepool {
        NSString *a = @"spotify:track:0123456789012345678901";
        NSString *b = @"spotify:track:0123456789012345678902";
        NSString *local = @"spotify:local:Artist:Album:Title:180";
        playingURI = a;
        NSObject *native = [NSObject new]; NSArray *original = @[native];
        NSArray *first = SGTrackDownloadMenuActions(original, a);
        assert(first.count == 4 && first[3] == native && original.count == 1);
        assert(performedCount == 0 && speedCount == 0 && vocalsCount == 0);
        NSArray *twice = SGTrackDownloadMenuActions(first, a);
        assert(twice.count == 4 && twice[3] == native);
        NSArray *reused = SGTrackDownloadMenuActions(first, b);
        assert([[(SGTrackDownloadAction *)reused[0] targetURL] isEqual:SGAutomaticSpotifyURL(b)]);
        assert([[(SGTrackPlayerAudioAction *)reused[1] targetURI] isEqual:b]);
        assert([(SGTrackDownloadAction *)first[0] performAction]);
        assert(performedCount == 1 && [performedURL isEqual:SGAutomaticSpotifyURL(a)]);
        assert([(SGTrackPlayerAudioAction *)first[1] performAction]);
        assert(speedCount == 1 && [performedAudioURI isEqual:a]);
        assert([(SGTrackPlayerAudioAction *)first[1] performAction]);
        assert(speedCount == 1); // Duplicate selection cannot open a second sheet.
        assert([(SGTrackPlayerAudioAction *)first[2] performAction]);
        assert(vocalsCount == 1 && performedCount == 1);
        playingURI = b;
        assert([(SGTrackPlayerAudioAction *)twice[1] performAction]);
        assert(speedCount == 1 && wrongTrackCount == 1); // Stale menu cannot adjust B.
        NSArray *localMenu = SGTrackDownloadMenuActions(first, [NSURL URLWithString:local]);
        assert(localMenu.count == 3 && localMenu[2] == native);
        assert([localMenu[0] isKindOfClass:SGTrackPlayerAudioAction.class]);
        assert([[(SGTrackPlayerAudioAction *)localMenu[0] targetURI] isEqual:local]);
        playingURI = local;
        assert([(SGTrackPlayerAudioAction *)localMenu[0] performAction]);
        assert(speedCount == 2 && [performedAudioURI isEqual:local] && performedCount == 1);
        assert(SGTrackDownloadMenuActions(original, @"spotify:playlist:0123456789012345678901") == original);
        assert(SGTrackDownloadMenuActions(original, @"spotify:episode:0123456789012345678901") == original);
        assert(SGTrackDownloadMenuActions(original, @"https://evil.example/track/0123456789012345678901") == original);
        assert(SGTrackDownloadMenuActions(original, @"spotify:local:invalid") == original);
        for (id invalid in @[@"spotify:playlist:0123456789012345678901", @"spotify:episode:0123456789012345678901", NSNull.null]) {
            NSArray *cleaned = SGTrackDownloadMenuActions(first, invalid);
            assert(cleaned.count == 1 && cleaned[0] == native);
        }
        assert(SGTrackDownloadMenuActions(native, a) == native);
        testEnabled = NO;
        NSArray *audioOnly = SGTrackDownloadMenuActions(first, a);
        assert(audioOnly.count == 3 && audioOnly[2] == native);
        playingURI = a;
        assert([(SGTrackPlayerAudioAction *)audioOnly[0] performAction]);
        assert(speedCount == 3 && [performedAudioURI isEqual:a]);
        assert(SGTrackDownloadMenuActions(audioOnly, nil) && [SGTrackDownloadMenuActions(audioOnly, nil) count] == 1);
        assert([(SGTrackDownloadAction *)first[0] performAction]);
        assert(performedCount == 1); // An already-open menu respects a later opt-out.
        puts("Native track download and audio menu actions: PASS");
    }
    return 0;
}
#endif
