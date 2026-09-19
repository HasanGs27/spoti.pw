#import "PlayerNativeSpeed.h"
#import "PlayerNativeSpeedModel.h"
#import "Core/SGCore.h"
#import <string.h>

// Implemented by the full-player audio tools bridge, which keeps copies separate.
extern void SGPresentPlayerAudioVersions(UIViewController *owner, NSString *capturedURI, NSString *kind);

@protocol SGNativeSpeedPlayer <NSObject>
- (id)state;
- (id)setOptions:(id)options;
@end

static __weak id<SGNativeSpeedPlayer> observedPlayer;
static NSUInteger requestGeneration;

static id readState(id<SGNativeSpeedPlayer> player) {
    @try {
        NSMethodSignature *signature = [(NSObject *)player methodSignatureForSelector:@selector(state)];
        if (![player isKindOfClass:NSClassFromString(@"SPTEsperantoPlayer")] || signature.numberOfArguments != 2 ||
            strcmp(signature.methodReturnType, @encode(id)) != 0) return nil;
        return player.state;
    } @catch (NSException *exception) { return nil; }
}
static BOOL commandAvailable(id player) {
    NSMethodSignature *signature = [player methodSignatureForSelector:@selector(setOptions:)];
    return [player respondsToSelector:@selector(setOptions:)] && signature.numberOfArguments == 3 &&
        strcmp(signature.methodReturnType, @encode(id)) == 0 &&
        strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) == 0;
}
static NSString *rateLabel(NSNumber *rate) {
    return [[NSString stringWithFormat:@"×%g", rate.doubleValue] stringByReplacingOccurrencesOfString:@"." withString:@","];
}
static void feedback(UIViewController *owner, NSString *message, NSUInteger remaining) {
    if (!owner || !owner.viewIfLoaded.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (owner.presentedViewController) {
        if (remaining && [owner.presentedViewController isKindOfClass:UIAlertController.class]) {
            __weak UIViewController *weak = owner;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                feedback(weak, message, remaining - 1);
            });
        }
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Vitesse" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}
static void afterSheet(UIViewController *owner, void (^block)(UIViewController *), NSUInteger remaining) {
    if (!owner || !owner.viewIfLoaded.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (owner.presentedViewController) {
        if (remaining && [owner.presentedViewController isKindOfClass:UIAlertController.class]) {
            __weak UIViewController *weak = owner;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                afterSheet(weak, block, remaining - 1);
            });
        }
        return;
    }
    block(owner);
}

@interface SGNativeSpeedRequest : NSObject
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic, strong) id<SGNativeSpeedPlayer> player;
@property(nonatomic, copy) NSDictionary *snapshot;
@property(nonatomic, strong) NSNumber *rate;
@property(nonatomic, strong) id commandTask;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger attempts;
- (void)check;
@end
@implementation SGNativeSpeedRequest
- (void)check {
    if (self.generation != requestGeneration || !self.owner.viewIfLoaded.window ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    id state = readState(self.player);
    if (!SGPlayerNativeSpeedSamePlayback(self.snapshot, state)) {
        feedback(self.owner, @"Le morceau a changé. Aucun réglage supplémentaire n'a été envoyé.", 8); return;
    }
    if (SGPlayerNativeSpeedObserved(self.snapshot, state, self.rate)) {
        feedback(self.owner, [NSString stringWithFormat:@"Vitesse %@ confirmée par le lecteur.", rateLabel(self.rate)], 8); return;
    }
    if (++self.attempts >= 20) {
        feedback(self.owner, @"Spotify n'a pas confirmé ce changement pour cette lecture. Tu peux créer une copie à une autre vitesse depuis le même bouton.", 8); return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self check]; });
}
@end

void SGPresentPlayerNativeSpeed(UIViewController *owner) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ SGPresentPlayerNativeSpeed(owner); }); return; }
    if (!owner || owner.presentedViewController) return;
    ++requestGeneration;
    id<SGNativeSpeedPlayer> player = observedPlayer;
    NSDictionary *snapshot = SGPlayerNativeSpeedSnapshot(readState(player));
    if (!snapshot) { feedback(owner, @"Lance un morceau, puis rouvre son lecteur pour régler sa vitesse.", 0); return; }
    BOOL disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"SGNativeSpeedProbeDisabled"];
    BOOL available = [snapshot[@"available"] boolValue] && commandAvailable(player) && !disabled;
    BOOL allowed = available && [snapshot[@"allowed"] boolValue];
    NSString *detail = allowed ? @"Choisis la vitesse. Le lecteur confirmera si le changement est accepté pour ce morceau." :
        disabled ? @"Le réglage natif a été désactivé. Une copie à une autre vitesse reste disponible." :
        available ? @"Spotify n'autorise pas le changement direct pour cette lecture. Tu peux préparer une copie à la vitesse souhaitée." :
        @"Le réglage direct n'est pas disponible dans ce lecteur. Tu peux préparer une copie à la vitesse souhaitée.";
    NSString *title = [snapshot[@"title"] length] ? [@"Vitesse · " stringByAppendingString:snapshot[@"title"]] : @"Vitesse";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIViewController *weak = owner;
    if (allowed) for (NSNumber *rate in SGPlayerNativeSpeedRates()) {
        NSString *label = rateLabel(rate);
        if (SGPlayerNativeSpeedObserved(snapshot, readState(player), rate)) label = [label stringByAppendingString:@" · actuelle"];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UIViewController *host = weak;
            id state = readState(player);
            if (!SGPlayerNativeSpeedSamePlayback(snapshot, state)) { feedback(host, @"Le morceau a changé. Rouvre Vitesse pour la lecture actuelle.", 8); return; }
            if ([NSUserDefaults.standardUserDefaults boolForKey:@"SGNativeSpeedProbeDisabled"]) return;
            id options = SGPlayerNativeSpeedOptions(state, rate);
            if (!options || !commandAvailable(player)) { feedback(host, @"Spotify n'autorise plus ce réglage. La copie à une autre vitesse reste disponible.", 8); return; }
            SGNativeSpeedRequest *request = [SGNativeSpeedRequest new];
            request.owner = host; request.player = player; request.snapshot = snapshot; request.rate = rate;
            request.generation = ++requestGeneration;
            @try { request.commandTask = [player setOptions:options]; }
            @catch (NSException *exception) { feedback(host, @"Le lecteur a refusé ce réglage. Aucun autre paramètre n'a été modifié par l'outil.", 8); return; }
            // Sending a command is not success. Bound observation to four seconds.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [request check]; });
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Créer une copie à autre vitesse" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        afterSheet(weak, ^(UIViewController *host) {
            if (!SGPlayerNativeSpeedSamePlayback(snapshot, readState(player))) { feedback(host, @"Le morceau a changé. Rouvre Vitesse pour la lecture actuelle.", 0); return; }
            SGPresentPlayerAudioVersions(host, snapshot[@"trackURI"], @"speed");
        }, 8);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = owner.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(owner.view.bounds), CGRectGetMidY(owner.view.bounds), 1, 1);
    [owner presentViewController:sheet animated:YES completion:nil];
}

%hook SPTEsperantoPlayer
- (id)state {
    id result = %orig;
    // Capture an existing player only. No creation, command, polling or state
    // mutation during normal playback; full checks happen after an explicit tap.
    if ([result isKindOfClass:NSClassFromString(@"SPTPlayerState")]) observedPlayer = (id<SGNativeSpeedPlayer>)self;
    return result;
}
%end

%ctor { %init; }
