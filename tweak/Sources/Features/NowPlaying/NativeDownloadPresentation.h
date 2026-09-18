#import <UIKit/UIKit.h>

// Called only by known playlist/page hosts and download wrappers. No global view hook.
void SGNativeDownloadRefreshPage(UIViewController *page);
void SGNativeDownloadRegisterView(UIView *view);
BOOL SGNativeDownloadActivateWrapper(id wrapper);
