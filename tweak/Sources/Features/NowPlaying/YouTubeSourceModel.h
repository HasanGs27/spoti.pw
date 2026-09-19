#import <Foundation/Foundation.h>

// Navigation policy, not a resource filter. Cookies and media bodies are never read.
BOOL SGYouTubeNavigationURLAllowed(id value);
NSURL *SGYouTubeCanonicalVideoURL(id value);
NSURL *SGYouTubeSearchURL(NSString *query);
NSString *SGYouTubeSourceTitle(id value);
// Reject a stale selection if any of the displayed/current/JS-snapshot video identities differ.
// Returns {url:canonical HTTPS watch URL, title:bounded suggestion} or nil.
NSDictionary *SGYouTubeValidatedSelection(id displayedURL, id currentURL, id snapshot);
