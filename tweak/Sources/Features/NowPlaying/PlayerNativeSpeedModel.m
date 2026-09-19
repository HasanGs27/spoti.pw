#import "PlayerNativeSpeedModel.h"
#import <math.h>
#import <string.h>

// Selectors and encodings verified in the Spotify executable shipped in the
// 18387b56 IPA. No guessed enum, restriction override or PCM interception.
@protocol SGNativeSpeedTrack <NSObject>
- (id)URI;
- (NSString *)trackTitle;
@end
@protocol SGNativeSpeedRestrictions <NSObject>
- (BOOL)disallowSettingPlaybackSpeed;
- (BOOL)disallowRemoteControl;
@end
@protocol SGNativeSpeedOptions <NSObject>
- (NSNumber *)playbackSpeed;
@end
@protocol SGNativeSpeedOverrides <SGNativeSpeedOptions>
- (void)setPlaybackSpeed:(NSNumber *)value;
- (NSNumber *)shufflingContext;
- (NSNumber *)repeatingContext;
- (NSNumber *)repeatingTrack;
- (NSDictionary *)modes;
@end
@protocol SGNativeSpeedState <NSObject>
- (id<SGNativeSpeedTrack>)track;
- (NSString *)playbackId;
- (NSString *)sessionID;
- (double)playbackSpeed;
- (id<SGNativeSpeedOptions>)options;
- (id<SGNativeSpeedRestrictions>)restrictions;
- (id<SGNativeSpeedRestrictions>)contextRestrictions;
@end

static BOOL nativeClass(id value, NSString *name) {
    Class type = NSClassFromString(name);
    return type && [value isKindOfClass:type];
}
static BOOL getter(id value, SEL selector, const char *type) {
    NSMethodSignature *signature = [value methodSignatureForSelector:selector];
    return [value respondsToSelector:selector] && signature.numberOfArguments == 2 &&
        signature.methodReturnType && strcmp(signature.methodReturnType, type) == 0;
}
static BOOL optionSetter(id value) {
    NSMethodSignature *signature = [value methodSignatureForSelector:@selector(setPlaybackSpeed:)];
    return [value respondsToSelector:@selector(setPlaybackSpeed:)] && signature.numberOfArguments == 3 &&
        strcmp(signature.methodReturnType, @encode(void)) == 0 &&
        strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) == 0;
}
static BOOL validOptions(id value) {
    return nativeClass(value, @"SPTPlayerOptions") && getter(value, @selector(playbackSpeed), @encode(id));
}
static BOOL validOverrides(id value) {
    return nativeClass(value, @"SPTPlayerOptionOverrides") && getter(value, @selector(playbackSpeed), @encode(id)) &&
        getter(value, @selector(shufflingContext), @encode(id)) && getter(value, @selector(repeatingContext), @encode(id)) &&
        getter(value, @selector(repeatingTrack), @encode(id)) && getter(value, @selector(modes), @encode(id)) && optionSetter(value);
}
static BOOL validRestrictions(id value) {
    return nativeClass(value, @"SPTPlayerRestrictions") &&
        getter(value, @selector(disallowSettingPlaybackSpeed), @encode(BOOL)) &&
        getter(value, @selector(disallowRemoteControl), @encode(BOOL));
}
static BOOL rateValue(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [SGPlayerNativeSpeedRates() containsObject:value];
}
static NSString *identityString(id value) {
    if (!value) return @"";
    return [value isKindOfClass:NSString.class] && [value length] <= 512 ? value : nil;
}
NSArray<NSNumber *> *SGPlayerNativeSpeedRates(void) {
    return @[@0.75, @1, @1.25, @1.5, @2];
}
NSDictionary *SGPlayerNativeSpeedSnapshot(id object) {
    if (!nativeClass(object, @"SPTPlayerState") || !getter(object, @selector(track), @encode(id))) return nil;
    @try {
        id<SGNativeSpeedState> state = object;
        id<SGNativeSpeedTrack> track = state.track;
        if (!nativeClass(track, @"SPTPlayerTrack") || !getter(track, @selector(URI), @encode(id))) return nil;
        id rawURI = track.URI;
        NSString *uri = [rawURI isKindOfClass:NSURL.class] ? [rawURI absoluteString] : rawURI;
        if (![uri isKindOfClass:NSString.class] || uri.length > 4096 ||
            (![uri hasPrefix:@"spotify:track:"] && ![uri hasPrefix:@"spotify:local:"] &&
             ![uri hasPrefix:@"spotify:episode:"] && ![uri hasPrefix:@"spotify:chapter:"])) return nil;
        if (!getter(state, @selector(playbackId), @encode(id)) || !getter(state, @selector(sessionID), @encode(id))) return nil;
        NSString *playback = identityString(state.playbackId), *session = identityString(state.sessionID);
        if (!playback || !session) return nil;
        BOOL available = getter(state, @selector(playbackSpeed), @encode(double)) &&
            getter(state, @selector(options), @encode(id)) && getter(state, @selector(restrictions), @encode(id)) &&
            getter(state, @selector(contextRestrictions), @encode(id));
        double rate = available ? state.playbackSpeed : 0;
        available = available && isfinite(rate) && rate >= 0 && rate <= 32;
        BOOL allowed = NO;
        if (available) {
            id<SGNativeSpeedRestrictions> restrictions = state.restrictions, context = state.contextRestrictions;
            available = validOptions(state.options) && validRestrictions(restrictions) && (!context || validRestrictions(context));
            if (available) allowed = !restrictions.disallowSettingPlaybackSpeed && !restrictions.disallowRemoteControl &&
                (!context || (!context.disallowSettingPlaybackSpeed && !context.disallowRemoteControl));
        }
        NSString *title = getter(track, @selector(trackTitle), @encode(id)) ? track.trackTitle : nil;
        if (![title isKindOfClass:NSString.class] || title.length > 1024) title = @"";
        return @{@"trackURI":uri, @"playbackID":playback, @"sessionID":session, @"title":title ?: @"",
                 @"rate":@(isfinite(rate) && rate >= 0 && rate <= 32 ? rate : 0),
                 @"available":@(available), @"allowed":@(available && allowed)};
    } @catch (NSException *exception) { return nil; }
}
BOOL SGPlayerNativeSpeedSamePlayback(NSDictionary *snapshot, id state) {
    if (![snapshot isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *fresh = SGPlayerNativeSpeedSnapshot(state);
    if (!fresh) return NO;
    for (NSString *key in @[@"trackURI", @"playbackID", @"sessionID"]) if (![fresh[key] isEqual:snapshot[key]]) return NO;
    return YES;
}
BOOL SGPlayerNativeSpeedObserved(NSDictionary *snapshot, id state, NSNumber *rate) {
    if (!rateValue(rate) || !SGPlayerNativeSpeedSamePlayback(snapshot, state)) return NO;
    NSDictionary *fresh = SGPlayerNativeSpeedSnapshot(state);
    return [fresh[@"available"] boolValue] && fabs([fresh[@"rate"] doubleValue] - rate.doubleValue) < 0.001;
}
id SGPlayerNativeSpeedOptions(id object, NSNumber *rate) {
    NSDictionary *snapshot = SGPlayerNativeSpeedSnapshot(object);
    if (!rateValue(rate) || ![snapshot[@"allowed"] boolValue]) return nil;
    @try {
        // Extended protocol metadata explicitly identifies this argument class:
        // setOptions: -> <SPTPlayerTask>, argument SPTPlayerOptionOverrides.
        id<SGNativeSpeedOverrides> options = [[NSClassFromString(@"SPTPlayerOptionOverrides") alloc] init];
        if (!validOverrides(options) || options.shufflingContext || options.repeatingContext || options.repeatingTrack || options.modes) return nil;
        [options setPlaybackSpeed:rate];
        if (![options.playbackSpeed isEqual:rate]) return nil;
        return options;
    } @catch (NSException *exception) { return nil; }
}

#ifdef SG_PLAYER_NATIVE_SPEED_TEST
#include <assert.h>
@interface SPTPlayerTrack : NSObject <SGNativeSpeedTrack>
@property(nonatomic, strong) id URI;
@property(nonatomic, copy) NSString *trackTitle;
@end
@implementation SPTPlayerTrack @end
@interface SPTPlayerRestrictions : NSObject <SGNativeSpeedRestrictions>
@property(nonatomic) BOOL disallowSettingPlaybackSpeed;
@property(nonatomic) BOOL disallowRemoteControl;
@end
@implementation SPTPlayerRestrictions @end
@interface SPTPlayerOptions : NSObject <SGNativeSpeedOptions>
@property(nonatomic, strong) NSNumber *playbackSpeed;
@property(nonatomic, copy) NSDictionary *unrelated;
@end
@implementation SPTPlayerOptions
@end
@interface SPTPlayerOptionOverrides : NSObject <SGNativeSpeedOverrides>
@property(nonatomic, strong) NSNumber *playbackSpeed;
@property(nonatomic, strong) NSNumber *shufflingContext;
@property(nonatomic, strong) NSNumber *repeatingContext;
@property(nonatomic, strong) NSNumber *repeatingTrack;
@property(nonatomic, copy) NSDictionary *modes;
@end
@implementation SPTPlayerOptionOverrides @end
@interface SPTPlayerState : NSObject <SGNativeSpeedState>
@property(nonatomic, strong) id<SGNativeSpeedTrack> track;
@property(nonatomic, copy) NSString *playbackId;
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic) double playbackSpeed;
@property(nonatomic, strong) id<SGNativeSpeedOptions> options;
@property(nonatomic, strong) id<SGNativeSpeedRestrictions> restrictions;
@property(nonatomic, strong) id<SGNativeSpeedRestrictions> contextRestrictions;
@end
@implementation SPTPlayerState @end
int main(void) {
    @autoreleasepool {
        SPTPlayerTrack *track = [SPTPlayerTrack new]; track.URI = [NSURL URLWithString:@"spotify:track:0123456789012345678901"]; track.trackTitle = @"Morceau";
        SPTPlayerOptions *options = [SPTPlayerOptions new]; options.playbackSpeed = @1;
        options.unrelated = @{@"shuffle":@YES, @"repeat":@NO, @"modes":@{@"retain":@"exact"}};
        NSDictionary *unrelatedSnapshot = [options.unrelated copy];
        SPTPlayerRestrictions *restrictions = [SPTPlayerRestrictions new], *context = [SPTPlayerRestrictions new];
        SPTPlayerState *state = [SPTPlayerState new]; state.track = track; state.options = options;
        state.restrictions = restrictions; state.contextRestrictions = context;
        state.playbackId = @"play-1"; state.sessionID = @"session-1"; state.playbackSpeed = 1;
        NSDictionary *snapshot = SGPlayerNativeSpeedSnapshot(state);
        assert([snapshot[@"available"] boolValue] && [snapshot[@"allowed"] boolValue]);
        for (NSNumber *rate in SGPlayerNativeSpeedRates()) {
            SPTPlayerOptionOverrides *override = SGPlayerNativeSpeedOptions(state, rate);
            assert([override isKindOfClass:SPTPlayerOptionOverrides.class] && [override.playbackSpeed isEqual:rate]);
            assert(!override.shufflingContext && !override.repeatingContext && !override.repeatingTrack && !override.modes);
            assert([options.playbackSpeed isEqual:@1] && state.playbackSpeed == 1 &&
                   [options.unrelated isEqual:unrelatedSnapshot]);
        }
        for (id invalid in @[@YES, @0, @(-1), @1.1, @3, @(NAN), @(INFINITY), @"1.25", NSNull.null])
            assert(!SGPlayerNativeSpeedOptions(state, invalid));
        restrictions.disallowSettingPlaybackSpeed = YES; assert(!SGPlayerNativeSpeedOptions(state, @1.25)); restrictions.disallowSettingPlaybackSpeed = NO;
        context.disallowSettingPlaybackSpeed = YES; assert(!SGPlayerNativeSpeedOptions(state, @1.25)); context.disallowSettingPlaybackSpeed = NO;
        restrictions.disallowRemoteControl = YES; assert(!SGPlayerNativeSpeedOptions(state, @1.25)); restrictions.disallowRemoteControl = NO;
        assert(!SGPlayerNativeSpeedObserved(snapshot, state, @1.25));
        state.playbackSpeed = 1.25; assert(SGPlayerNativeSpeedObserved(snapshot, state, @1.25));
        state.playbackId = @"play-2"; assert(!SGPlayerNativeSpeedSamePlayback(snapshot, state) && !SGPlayerNativeSpeedObserved(snapshot, state, @1.25)); state.playbackId = @"play-1";
        state.sessionID = @"session-2"; assert(!SGPlayerNativeSpeedSamePlayback(snapshot, state)); state.sessionID = @"session-1";
        track.URI = @"spotify:local:Artist:Album:Track:180"; assert(!SGPlayerNativeSpeedSamePlayback(snapshot, state));
        assert([SGPlayerNativeSpeedSnapshot(state)[@"allowed"] boolValue]);
        snapshot = SGPlayerNativeSpeedSnapshot(state); assert(SGPlayerNativeSpeedObserved(snapshot, state, @1.25));
        state.options = (id)@{}; assert(![SGPlayerNativeSpeedSnapshot(state)[@"available"] boolValue] && !SGPlayerNativeSpeedOptions(state, @1.25)); state.options = options;
        state.restrictions = nil; assert(!SGPlayerNativeSpeedOptions(state, @1.25)); state.restrictions = restrictions;
        state.playbackSpeed = NAN; assert(![SGPlayerNativeSpeedSnapshot(state)[@"available"] boolValue]); state.playbackSpeed = 1;
        track.URI = @"https://example.com/song"; assert(!SGPlayerNativeSpeedSnapshot(state));
        assert(!SGPlayerNativeSpeedSnapshot(@{}) && !SGPlayerNativeSpeedSamePlayback(snapshot, nil));
        puts("Native player speed options and playback identity: PASS");
    }
    return 0;
}
#endif
