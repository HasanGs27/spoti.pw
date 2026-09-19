#import <UIKit/UIKit.h>

// Returns a full-screen UINavigationController, ready to present modally on main.
// Selection calls completion exactly once on main, after dismissal. Cancel does not call it.
// suggestedTitle is only an editable, untrusted display suggestion, never recording identity.
UIViewController *SGYouTubeSourceBrowserCreate(NSString *query, void (^completion)(NSURL *canonicalURL, NSString *suggestedTitle));
