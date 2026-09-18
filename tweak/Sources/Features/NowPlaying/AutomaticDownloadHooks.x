// Only an explicit download-button action can start the custom queue.
// Unknown page, podcast, album, or unpaired mode: retain the native action.
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import <objc/message.h>

static __thread NSUInteger sg_downloadTapDepth;

static id objectGetter(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static BOOL customButton(id button) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"SGAutomaticDownloadsEnabled"]) return NO;
    id candidate = objectGetter(button, @"uiView");
    if (![candidate isKindOfClass:UIView.class]) return NO;
    UIView *view = candidate;
    // Read the page owning this button, never the currently playing song or an unrelated tab.
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 24; depth++, responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        NSString *url = SGAutomaticSpotifyURL(objectGetter(responder, @"spt_pageURI"));
        if (!url) url = SGAutomaticSpotifyURL(objectGetter(responder, @"pageURI"));
        if (url) {
            SGLog(@"[SGAutoDownloads] download button resolved page=%@", url);
            return SGAutomaticDownloadEntity(url, view);
        }
    }
    SGLog(@"[SGAutoDownloads] download button page unresolved; native action retained");
    return NO;
}

%hook _TtCOOOE32EncoreConsumerMobile_ElementsKitO19LegacyUI_ECMCoreKit10Components22GranularDownloadButton2UI7Private22GranularDownloadButton
- (void)performAction {
    if (customButton(self)) return;
    sg_downloadTapDepth++;
    @try { %orig; } @finally { sg_downloadTapDepth--; }
}
%end

%hook _TtC28EncoreConsumerMobile_BaseKitP33_B18AD9CFD34D2E2EF5BE4AC1DDAEB28B14DownloadButton
- (void)performAction {
    if (customButton(self)) return;
    sg_downloadTapDepth++;
    @try { %orig; } @finally { sg_downloadTapDepth--; }
}
%end

%hook SPTOfflineManagerImplementation
- (void)makeEntityAvailableOfflineWithURL:(id)url {
    if (sg_downloadTapDepth && SGAutomaticDownloadEntity(url, nil)) return;
    %orig;
}
- (void)makeEntityAvailableOfflineWithURL:(id)url trackURLs:(id)tracks {
    if (sg_downloadTapDepth && SGAutomaticDownloadEntity(url, nil)) return;
    %orig;
}
%end

%hook SPTEsperantoPlayer
- (id)state {
    id state = %orig;
    SGAutomaticDownloadObservePlayer(self);
    return state;
}
%end

%ctor { %init; }
