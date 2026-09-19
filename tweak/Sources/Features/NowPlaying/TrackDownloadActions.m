#import "TrackDownloadActions.h"
#import "AutomaticDownloadModel.h"
#import <objc/message.h>
#import <objc/runtime.h>

#ifndef SG_TRACK_DOWNLOAD_ACTION_TEST
#import "AutomaticDownloads.h"
#import "Core/SGCore.h"
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
static BOOL completionAvailable(void) {
    Class type = NSClassFromString(@"SPTaskCompletionSource");
    return type && [type instancesRespondToSelector:@selector(task)] &&
        [type instancesRespondToSelector:@selector(completeWithValue:)];
}

#ifdef SG_TRACK_DOWNLOAD_ACTION_TEST
static NSString *performedURL;
static NSUInteger performedCount;
static BOOL testEnabled = YES;
static BOOL downloadEnabled(void) { return testEnabled; }
static NSDictionary *downloadStatus(NSString *url) { return @{@"state":@"idle"}; }
static void downloadTrack(NSString *url) { performedURL = url; performedCount++; }
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
#endif

@interface SGTrackDownloadAction : NSObject <SPTContextMenuAction, SPTDismissContextMenuAction>
@property(nonatomic, copy) NSString *targetURL;
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
    return [UIImage systemImageNamed:symbol];
}
- (UIColor *)iconColor {
    NSString *state = downloadStatus(self.targetURL)[@"state"];
    if ([state isEqual:@"ready"]) return [UIColor colorWithRed:.114 green:.843 blue:.376 alpha:1];
    if ([state isEqual:@"error"] || [state isEqual:@"partial"]) return UIColor.systemRedColor;
    return UIColor.labelColor;
}
#endif
@end

id SGTrackDownloadMenuActions(id actions, id entity) {
    if (!downloadEnabled() || !completionAvailable() || (actions && ![actions isKindOfClass:NSArray.class])) return actions;
    NSString *url = trackURL(entity);
    if (!url || [actions count] > 128) return actions;
    NSMutableArray *result = [NSMutableArray array];
    // Both presenter factories may be called for one menu. Replace only our own
    // entry, also preventing a reused menu from retaining a previous track URI.
    for (id action in actions) if (![action isKindOfClass:SGTrackDownloadAction.class]) [result addObject:action];
    SGTrackDownloadAction *action = [SGTrackDownloadAction new]; action.targetURL = url;
    [result insertObject:action atIndex:0];
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
        NSObject *native = [NSObject new]; NSArray *original = @[native];
        NSArray *first = SGTrackDownloadMenuActions(original, a);
        assert(first.count == 2 && first[1] == native && original.count == 1);
        assert(performedCount == 0); // Opening any menu never starts a download.
        NSArray *twice = SGTrackDownloadMenuActions(first, a);
        assert(twice.count == 2 && twice[1] == native);
        NSArray *reused = SGTrackDownloadMenuActions(first, b);
        assert([[(SGTrackDownloadAction *)reused[0] targetURL] isEqual:SGAutomaticSpotifyURL(b)]);
        assert([(SGTrackDownloadAction *)first[0] performAction]);
        assert(performedCount == 1 && [performedURL isEqual:SGAutomaticSpotifyURL(a)]);
        assert(SGTrackDownloadMenuActions(original, @"spotify:playlist:0123456789012345678901") == original);
        assert(SGTrackDownloadMenuActions(original, @"spotify:episode:0123456789012345678901") == original);
        assert(SGTrackDownloadMenuActions(original, @"spotify:local:Artist:Album:Title:180") == original);
        assert(SGTrackDownloadMenuActions(original, @"https://evil.example/track/0123456789012345678901") == original);
        assert(SGTrackDownloadMenuActions(native, a) == native);
        testEnabled = NO;
        assert(SGTrackDownloadMenuActions(original, a) == original);
        assert([(SGTrackDownloadAction *)first[0] performAction]);
        assert(performedCount == 1); // An already-open menu respects a later opt-out.
        puts("Single-track native actions: PASS");
    }
    return 0;
}
#endif
