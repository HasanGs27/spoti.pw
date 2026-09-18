// Opt-in manual speed test. Method encodings checked against
// the current Spotify IPA. No flag/restriction override and no automatic command.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"

@protocol SGNativeSpeedStatus <NSObject>
- (BOOL)isAvailable;
- (BOOL)isAllowed;
@end

@protocol SGNativeSpeedOption <NSObject>
- (NSString *)translation;
@end

@protocol SGNativeSpeedManager <NSObject>
- (id<SGNativeSpeedStatus>)settingPlaybackSpeedAllowedStatus;
- (NSArray *)providePodcastPlaybackSpeedsWithRequestReducedSet:(BOOL)reduced;
- (void)setCurrentPlaybackSpeed:(id)speed;
@end

@protocol SGNativeSpeedService <NSObject>
- (id<SGNativeSpeedManager>)providePodcastPlaybackSpeedManager;
@end

static __weak id<SGNativeSpeedService> sg_speedService;
static NSString *const sg_speedManagerClass = @"_TtC33PodcastPlaybackSpeed_PlatformImpl41PodcastPlaybackSpeedManagerImplementation";

static void speedMessage(UIViewController *owner, NSString *message) {
    if (!owner || owner.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Vitesse — test"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

static BOOL speedAllowed(id<SGNativeSpeedManager> manager) {
    id<SGNativeSpeedStatus> status = [manager settingPlaybackSpeedAllowedStatus];
    if (![status respondsToSelector:@selector(isAvailable)] ||
        ![status respondsToSelector:@selector(isAllowed)]) return NO;
    BOOL available = status.isAvailable, allowed = status.isAllowed;
    SGLog(@"[SGMediaTools] speed capability available=%d allowed=%d", available, allowed);
    return available && allowed;
}

// Call from a dedicated experimental settings action, on the main thread.
// Use Spotify's returned option objects verbatim: no guessed units or enum values.
void SGPresentNativeSpeedTest(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGPresentNativeSpeedTest(); });
        return;
    }
    UIViewController *owner = SGTopController();
    if (!owner || owner.presentedViewController) return;
    id<SGNativeSpeedService> service = sg_speedService;
    if (![service respondsToSelector:@selector(providePodcastPlaybackSpeedManager)]) {
        speedMessage(owner, @"Le service de vitesse n’a pas encore été observé dans cette session.");
        return;
    }
    id<SGNativeSpeedManager> manager = [service providePodcastPlaybackSpeedManager];
    if (![NSStringFromClass([(id)manager class]) isEqualToString:sg_speedManagerClass] ||
        ![manager respondsToSelector:@selector(settingPlaybackSpeedAllowedStatus)] ||
        ![manager respondsToSelector:@selector(providePodcastPlaybackSpeedsWithRequestReducedSet:)] ||
        ![manager respondsToSelector:@selector(setCurrentPlaybackSpeed:)]) {
        speedMessage(owner, @"Cette version du lecteur n’est pas reconnue par le test.");
        return;
    }
    if (!speedAllowed(manager)) {
        speedMessage(owner, @"Spotify ne propose pas le changement de vitesse pour la lecture actuelle.");
        return;
    }
    NSArray *options = [manager providePodcastPlaybackSpeedsWithRequestReducedSet:NO];
    if (![options isKindOfClass:NSArray.class] || !options.count || options.count > 50) {
        speedMessage(owner, @"Spotify n’a renvoyé aucune liste de vitesses exploitable.");
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Vitesse — test"
        message:@"Choisis une valeur native. Vérifie ensuite à l’écoute que le changement est effectif."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger added = 0;
    for (id option in options) {
        if (![option respondsToSelector:@selector(translation)]) continue;
        NSString *label = [(id<SGNativeSpeedOption>)option translation];
        if (![label isKindOfClass:NSString.class] || !label.length) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // The track may have changed while the chooser was visible. Recheck
            // availability and fetch a fresh native option before issuing anything.
            if (!speedAllowed(manager)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    speedMessage(SGTopController(), @"La vitesse n’est plus disponible pour la lecture actuelle.");
                });
                return;
            }
            NSArray *fresh = [manager providePodcastPlaybackSpeedsWithRequestReducedSet:NO];
            if (![fresh isKindOfClass:NSArray.class] || fresh.count > 50) return;
            for (id candidate in fresh) {
                if (![candidate respondsToSelector:@selector(translation)]) continue;
                if (![[(id<SGNativeSpeedOption>)candidate translation] isEqualToString:label]) continue;
                [manager setCurrentPlaybackSpeed:candidate];
                SGLog(@"[SGMediaTools] speed request sent label=%@; playback effect not yet verified", label);
                return;
            }
        }]];
        added++;
    }
    if (!added) {
        speedMessage(owner, @"Aucune vitesse avec un libellé reconnu.");
        return;
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = owner.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(owner.view.bounds),
        CGRectGetMidY(owner.view.bounds), 1, 1);
    [owner presentViewController:sheet animated:YES completion:nil];
}

%hook _TtC33PodcastPlaybackSpeed_PlatformImpl35PodcastPlaybackSpeedPlatformService
- (void)_injectDependenciesWithProvider:(id)provider {
    %orig;
    sg_speedService = (id<SGNativeSpeedService>)self;
}
%end

%ctor {
    // Capturing the service does not alter playback. Commands only follow a tap.
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SGNativeSpeedProbeDisabled"]) return;
    %init;
}
