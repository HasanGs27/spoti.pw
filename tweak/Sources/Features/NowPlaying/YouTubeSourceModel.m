#import "YouTubeSourceModel.h"

static BOOL exactMatch(NSString *value, NSString *pattern) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSRange range = [value rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == value.length;
}
static NSURLComponents *components(id value) {
    NSString *text = [value isKindOfClass:NSURL.class] ? [value absoluteString] : value;
    if (![text isKindOfClass:NSString.class] || !text.length || text.length > 4096 ||
        [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    if (!parts || ![parts.scheme.lowercaseString isEqual:@"https"] || !parts.host.length ||
        parts.user != nil || parts.password != nil || (parts.port && ![parts.port isEqual:@443]) ||
        [parts.percentEncodedHost containsString:@"%"] || !parts.URL) return nil;
    return parts;
}
static BOOL videoHost(NSString *host) {
    return [@[@"youtube.com", @"www.youtube.com", @"m.youtube.com", @"music.youtube.com", @"youtu.be", @"www.youtu.be"] containsObject:host];
}
BOOL SGYouTubeNavigationURLAllowed(id value) {
    NSURLComponents *parts = components(value); NSString *host = parts.host.lowercaseString;
    return parts && (videoHost(host) || [@[@"consent.youtube.com", @"consent.google.com"] containsObject:host]);
}
NSURL *SGYouTubeCanonicalVideoURL(id value) {
    NSURLComponents *parts = components(value); NSString *host = parts.host.lowercaseString;
    if (!parts || !videoHost(host)) return nil;
    NSString *identifier = nil, *path = parts.percentEncodedPath;
    if ([host isEqual:@"youtu.be"] || [host isEqual:@"www.youtu.be"]) {
        if (!exactMatch(path, @"^/[A-Za-z0-9_-]{11}/?$")) return nil;
        identifier = [path substringWithRange:NSMakeRange(1, 11)];
    } else if ([path isEqual:@"/watch"]) {
        NSUInteger count = 0;
        for (NSURLQueryItem *item in parts.queryItems) if ([item.name isEqual:@"v"]) { identifier = item.value; count++; }
        if (count != 1) return nil;
    } else if (exactMatch(path, @"^/shorts/[A-Za-z0-9_-]{11}/?$")) {
        identifier = [path substringWithRange:NSMakeRange(8, 11)];
    } else return nil;
    if (!exactMatch(identifier, @"^[A-Za-z0-9_-]{11}$")) return nil;
    return [NSURL URLWithString:[@"https://www.youtube.com/watch?v=" stringByAppendingString:identifier]];
}
static NSString *cleanText(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || [value length] > 16384) return @"";
    NSMutableCharacterSet *separators = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [separators formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    NSArray *words = [value componentsSeparatedByCharactersInSet:separators];
    NSMutableArray *nonempty = [NSMutableArray array];
    for (NSString *word in words) if (word.length) [nonempty addObject:word];
    NSString *text = [nonempty componentsJoinedByString:@" "];
    if (text.length > limit) text = [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)]];
    return text;
}
NSURL *SGYouTubeSearchURL(NSString *query) {
    NSString *text = cleanText(query, 300);
    NSURLComponents *parts = [NSURLComponents new]; parts.scheme = @"https"; parts.host = @"m.youtube.com";
    parts.path = text.length ? @"/results" : @"/";
    if (text.length) parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"search_query" value:text]];
    return parts.URL;
}
NSString *SGYouTubeSourceTitle(id value) {
    NSString *title = cleanText(value, 240);
    for (NSString *suffix in @[@" - YouTube", @" – YouTube", @" | YouTube"]) {
        if ([title hasSuffix:suffix]) { title = [title substringToIndex:title.length - suffix.length]; break; }
    }
    return [title isEqual:@"YouTube"] ? @"" : title;
}
NSDictionary *SGYouTubeValidatedSelection(id displayedURL, id currentURL, id snapshot) {
    if (![snapshot isKindOfClass:NSDictionary.class]) return nil;
    NSURL *displayed = SGYouTubeCanonicalVideoURL(displayedURL), *current = SGYouTubeCanonicalVideoURL(currentURL);
    NSURL *observed = SGYouTubeCanonicalVideoURL(snapshot[@"href"]);
    if (!displayed || !current || !observed || ![displayed isEqual:current] || ![current isEqual:observed]) return nil;
    return @{@"url":current.absoluteString, @"title":SGYouTubeSourceTitle(snapshot[@"title"])};
}

#ifdef SG_YOUTUBE_SOURCE_TEST
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSString *canonical = @"https://www.youtube.com/watch?v=aB0_-12CD34";
        for (NSString *url in @[@"https://m.youtube.com/watch?v=aB0_-12CD34&list=PL123&t=45#fragment",
            @"https://youtu.be/aB0_-12CD34?si=tracking", @"https://www.youtube.com/shorts/aB0_-12CD34/",
            @"HTTPS://YouTube.COM:443/watch?x=1&v=aB0_-12CD34", @"https://music.youtube.com/watch?v=aB0_-12CD34"])
            assert([SGYouTubeCanonicalVideoURL(url).absoluteString isEqual:canonical]);
        for (id invalid in @[[NSNull null], @42, @"https://evil.example/watch?v=aB0_-12CD34",
            @"https://youtube.com.evil.example/watch?v=aB0_-12CD34", @"https://youtube.com@evil.example/watch?v=aB0_-12CD34",
            @"https://user@youtube.com/watch?v=aB0_-12CD34", @"https://youtube.com:8443/watch?v=aB0_-12CD34",
            @"http://youtube.com/watch?v=aB0_-12CD34", @"javascript:alert(1)", @"file:///watch?v=aB0_-12CD34",
            @"https://youtube.com/watch?v=aB0_-12CD34&v=zB0_-12CD34", @"https://youtube.com/watch?v=aB0_-12CD34&v=aB0_-12CD34",
            @"https://youtube.com/watch?v=aB0_-12CD34%0A", @"https://youtube.com/watch?v=short",
            @"https://youtube.com/shorts/aB0_-12CD34/other", @"https://youtube.com/playlist?list=aB0_-12CD34",
            @"https://youtube.com/redirect?q=https://youtu.be/aB0_-12CD34", @"https://youtu.be/aB0_-12CD34/other",
            @"https://consent.youtube.com/watch?v=aB0_-12CD34", @"https://youtube.com./watch?v=aB0_-12CD34"])
            assert(!SGYouTubeCanonicalVideoURL(invalid));
        assert(SGYouTubeNavigationURLAllowed(@"https://consent.google.com/m?continue=https%3A%2F%2Fm.youtube.com"));
        assert(SGYouTubeNavigationURLAllowed(@"https://m.youtube.com/results?search_query=music"));
        assert(!SGYouTubeNavigationURLAllowed(@"https://accounts.google.com/"));
        assert(!SGYouTubeNavigationURLAllowed(@"https://consent.google.com.evil.example/"));
        assert(!SGYouTubeNavigationURLAllowed(@"youtube://watch?v=aB0_-12CD34"));
        NSURL *search = SGYouTubeSearchURL(@"  Titre & artiste\n\"spécial\"  ");
        NSURLComponents *parts = [NSURLComponents componentsWithURL:search resolvingAgainstBaseURL:NO];
        assert([parts.host isEqual:@"m.youtube.com"] && [parts.path isEqual:@"/results"]);
        assert([parts.queryItems.firstObject.value isEqual:@"Titre & artiste \"spécial\""]);
        assert([SGYouTubeSearchURL(nil).absoluteString isEqual:@"https://m.youtube.com/"]);
        assert([SGYouTubeSourceTitle(@"  Morceau\n Artiste - YouTube ") isEqual:@"Morceau Artiste"]);
        assert([SGYouTubeSourceTitle(@42) isEqual:@""]);
        NSDictionary *snapshot = @{@"href":@"https://m.youtube.com/watch?v=aB0_-12CD34",@"title":@"Morceau - YouTube"};
        NSDictionary *selected = SGYouTubeValidatedSelection(canonical, snapshot[@"href"], snapshot);
        assert([selected[@"url"] isEqual:canonical] && [selected[@"title"] isEqual:@"Morceau"]);
        assert(!SGYouTubeValidatedSelection(canonical, @"https://m.youtube.com/watch?v=zB0_-12CD34", snapshot));
        assert(!SGYouTubeValidatedSelection(canonical, canonical, @{@"href":@"https://youtu.be/zB0_-12CD34"}));
        assert(!SGYouTubeValidatedSelection(@"https://m.youtube.com/results", canonical, snapshot));
        puts("YouTube source model: PASS");
    }
    return 0;
}
#endif
