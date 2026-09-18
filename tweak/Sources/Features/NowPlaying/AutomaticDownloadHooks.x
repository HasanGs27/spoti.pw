// Only an explicit download-button action can start the custom queue.
// Unknown page, podcast, album, or disabled mode: retain the native action.
#import "AutomaticDownloads.h"
#import "AutomaticDownloadModel.h"
#import "NativeDownloadPresentation.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import <objc/message.h>

static __thread NSUInteger sg_downloadTapDepth;

static BOOL customButton(id button) {
    if (!SGAutomaticDownloadIsEnabled()) return NO;
    return SGNativeDownloadActivateWrapper(button);
}

%hook _TtCOOOE32EncoreConsumerMobile_ElementsKitO19LegacyUI_ECMCoreKit10Components22GranularDownloadButton2UI7Private22GranularDownloadButton
- (id)uiView {
    id view = %orig;
    SGNativeDownloadRegisterView(view);
    return view;
}
- (void)performAction {
    if (customButton(self)) return;
    sg_downloadTapDepth++;
    @try {
        %orig;
    } @finally {
        sg_downloadTapDepth--;
    }
}
%end

%hook _TtC28EncoreConsumerMobile_BaseKitP33_B18AD9CFD34D2E2EF5BE4AC1DDAEB28B14DownloadButton
- (id)uiView {
    id view = %orig;
    SGNativeDownloadRegisterView(view);
    return view;
}
- (void)performAction {
    if (customButton(self)) return;
    sg_downloadTapDepth++;
    @try {
        %orig;
    } @finally {
        sg_downloadTapDepth--;
    }
}
%end

// These exact hosts exist in the inspected IPA. Scanning only their loaded views
// catches Swift closure-based buttons that never call the ObjC performAction bridge.
%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl17FTPViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGNativeDownloadRefreshPage((UIViewController *)self);
}
- (void)viewWillLayoutSubviews {
    %orig;
    SGNativeDownloadRefreshPage((UIViewController *)self);
}
%end

%hook _TtC33Navigation_PageAPIIntegrationImpl35IdentifiedPageHostingViewController
- (void)setCurrentPageController:(id)controller {
    %orig;
    SGNativeDownloadRefreshPage((UIViewController *)self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGNativeDownloadRefreshPage((UIViewController *)self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    SGNativeDownloadRefreshPage((UIViewController *)self);
}
%end

%hook SPTHubViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGNativeDownloadRefreshPage((UIViewController *)self);
}
- (void)headerView:(id)header componentViewWillAppear:(id)component {
    %orig;
    SGNativeDownloadRefreshPage((UIViewController *)self);
}
%end

%hook SPTOfflineManagerImplementation
- (void)makeEntityAvailableOfflineWithURL:(id)url {
    if (sg_downloadTapDepth && SGAutomaticDownloadEntity(url, nil)) return;
    %orig;
}
- (void)makeEntityAvailableOfflineWithURL:(id)url trackURLs:(id)tracks {
    if (sg_downloadTapDepth) {
        SGAutomaticDownloadRegisterTracks(url, tracks);
        if (SGAutomaticDownloadEntity(url, nil)) return;
    }
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
