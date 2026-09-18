#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlaying.h"
#import "Features/Declutter/Declutter.h"
#import "Features/Gestures/Gestures.h"
#import "Features/ArtistBlock/ArtistBlock.h"
#import "Features/Karaoke/Karaoke.h"
#import "Features/LockScreenLyrics/LockScreenLyrics.h"
#import "Features/LyricsSources/LyricsSources.h"
#import "AutomaticDownloads.h"

extern UIViewController *SGLocalDownloadsPageCreate(void);
extern void SGPresentNativeSpeedTest(void);

static UIViewController *nowPlayingBarPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Now playing bar" intro:SGRestartNote sections:@[
        SGSection(nil, @[
            SGOptionRow(@"Glass now playing bar", @"Glass card with round artwork", SGKeyNowPlayingBar),
            SGHideRow(@"Hide the device button", @"The speaker icon in the bar", SGHideBarConnect),
        ]),
        SGSection(@"Spotify's flags", @[
            SGFlagRow(@"Two lines of track info", @"ios-feature-nowplayingbar.two_lines_information_unit"),
            SGFlagRow(@"Save button", @"ios-feature-nowplayingbar.add_button"),
            SGFlagRow(@"Queue badge", @"ios-feature-nowplayingbar.queue_badge"),
            SGFlagRow(@"Hold and drag to resize", @"ios-feature-nowplayingbar.hold_and_drag_to_resize"),
            SGFlagRow(@"Video in the mini player", @"ios-feature-nowplaying.video_in_miniplayer"),
            SGFlagRow(@"Bar to cover art animation", @"ios-feature-nowplaying.bartocoverart_animation_enabled"),
            SGFlagRow(@"Mini player transition animations", @"ios-feature-nowplaying.miniplayer_transition_animations"),
        ]),
    ] footer:nil];
}

static UIViewController *lyricsPage(void) {
    // The row reads the order out, so which sources are on is visible without opening it.
    SGModRow *sources = SGPageRow(@"Lyrics sources", ^UIViewController *{ return SGLyricsSourcesPage(); });
    sources.subtitle = @"BiniLyrics, Musixmatch, Unison, NetEase and LRCLIB, in the order you put them";
    sources.value = ^NSString *{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *key in SGLyricsOrder()) [names addObject:SGLyricsProviderFor(key).name];
        return names.count ? [names componentsJoinedByString:@", "] : @"Off";
    };

    return [[SGModPage alloc] initWithTitle:@"Lyrics" intro:SGRestartNote sections:@[
        SGSection(nil, @[
            SGOptionRow(@"Apple Music style", @"Word by word on the full screen page; timing inside a line is estimated unless Musixmatch has it", SGKeyKaraokeLyrics),
            SGOptionRow(@"Glass lyrics", @"Glass card, and the page it expands into", SGKeyLyricsCard),
            SGOptionRow(@"Lyrics on the lock screen", @"The line being sung in place of the artist, also in the Dynamic Island, Control Center and CarPlay", SGKeyLockScreenLyrics),
        ]),
        SGNotedSection(@"Where lyrics come from", @[
            sources,
            SGOptionRow(@"Lyrics for every track", @"Offers the lyrics card on tracks Spotify has no lyrics for; needs a source above", SGKeyLyricsAllTracks),
            SGOptionRow(@"Name the source", @"Reads out which source the lines on the full screen page came from", SGKeyLyricsCredit),
        ], @"With no source on, Spotify's own lyrics are left alone."),
        SGSection(@"Hide in the player", @[
            SGHideRow(@"Lyrics card", @"The lyrics card below the player", SGHideLyricsCard),
            SGHideRow(@"Lyrics preview", @"The lyric lines shown under the artwork", SGHideLyricsInline),
        ]),
        SGSection(@"Spotify's flags", @[
            SGFlagRow(@"Translations in the player", @"ios-feature-lyrics.enable_lyrics_multilanguage_npv"),
            SGFlagRow(@"Translations full screen", @"ios-feature-lyrics.enable_lyrics_multilanguage_fullscreen"),
            SGFlagRow(@"Keep lyrics offline", @"ios-feature-lyrics.lyrics_offline_enabled"),
            SGFlagRow(@"Dynamic colours", @"ios-feature-lyrics.enable_dynamic_colors"),
            SGFlagRow(@"Centre a single line", @"ios-feature-lyrics.is_single_line_centering_enabled"),
            SGFlagRow(@"Full screen on track change", @"ios-feature-lyrics.enable_fullscreen_track_change"),
            SGFlagRow(@"Lyrics toggle in the context menu", @"ios-feature-lyrics.lyrics_context_menu_toggle_enabled"),
        ]),
    ] footer:nil];
}

// Flag rows show the flag's name as their subtitle by default.
static SGModRow *bare(SGModRow *row) {
    row.subtitle = nil;
    return row;
}

static UIViewController *queuePage(void) {
    return [[SGModPage alloc] initWithTitle:@"Queue & devices" intro:SGRestartNote sections:@[
        SGNotedSection(@"Bottom sheets", @[
            bare(SGFlagRow(@"Queue as a bottom sheet", @"ios-feature-nowplaying.bottom_sheet_queue_enabled")),
            bare(SGFlagRow(@"Connect as a bottom sheet", @"ios-feature-nowplaying-elements.enable_connect_bottom_sheet")),
            bare(SGFlagRow(@"Connect sheet from the video switcher", @"ios-playbackcontrol-audiovideoswitcher-impl.enable_connect_bottom_sheet")),
        ], @"Locked on while Liquid Glass UI is on."),
        SGSection(@"Queue", @[
            bare(SGFlagRow(@"Queue flip transition", @"ios-feature-nowplaying.queue_flip_transition_enabled")),
            bare(SGFlagRow(@"Play next in the context menu", @"ios-feature-queue.is_play_next_context_menu_enabled")),
        ]),
    ] footer:nil];
}

static UIViewController *lockScreenPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Lock screen widget" intro:SGRestartNote sections:@[
        SGSection(@"Controls", @[
            bare(SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled")),
            bare(SGFlagRow(@"Skip button on podcasts", @"ios-feature-lockscreen.skip_button_on_podcasts")),
            bare(SGFlagRow(@"Chapter skip controls", @"ios-feature-lockscreen.enable_chapter_skip_controls")),
            bare(SGFlagRow(@"Burst skip", @"ios-feature-lockscreen.burst_skip_enabled")),
        ]),
        SGSection(@"Artwork", @[
            bare(SGFlagRow(@"Animated artwork", @"ios-feature-lockscreen.animated_artwork_enabled")),
            bare(SGFlagRow(@"Video artwork", @"ios-feature-lockscreen.vit_artwork_enabled")),
            bare(SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled")),
        ]),
    ] footer:nil];
}

UIViewController *SGNowPlayingSettingsPage(void) {
    SGModRow *blocked = SGPageRow(@"Blocked artists", ^UIViewController *{ return SGArtistBlockSettingsPage(); });
    blocked.value = ^NSString *{
        return SGFlag(SGKeyArtistBlock, NO) ? @(SGBlockedArtists().count).stringValue : @"Off";
    };

    return [[SGModPage alloc] initWithTitle:@"Player" intro:@"Changes apply after you restart Spotify. Gestures and Blocked artists apply straight away." sections:@[
        SGSection(nil, @[
            SGWithSymbol(SGPageRow(@"Téléchargements automatiques", ^UIViewController *{ return SGAutomaticDownloadsPageCreate(); }), @"arrow.down.circle.fill"),
            SGOptionRow(@"Flèche : téléchargements locaux", @"Prépare et vérifie les copies sur cet iPhone", @"SGAutomaticDownloadsEnabled"),
            SGWithSymbol(SGPageRow(@"Importer des fichiers existants", ^UIViewController *{ return SGLocalDownloadsPageCreate(); }), @"folder"),
            SGWithSymbol(SGActionRow(@"Vitesse native — test", @"Propose uniquement les vitesses autorisées par Spotify pour la lecture actuelle", ^{ SGPresentNativeSpeedTest(); }), @"speedometer"),
            SGWithSymbol(SGPageRow(@"Gestures", ^UIViewController *{ return SGGesturesSettingsPage(); }), @"hand.tap"),
            SGWithSymbol(SGPageRow(@"Lyrics", ^UIViewController *{ return lyricsPage(); }), @"quote.bubble"),
            SGWithSymbol(blocked, @"person.crop.circle.badge.xmark"),
        ]),
        SGSection(nil, @[
            SGWithSymbol(SGPageRow(@"Now playing bar", ^UIViewController *{ return nowPlayingBarPage(); }), @"rectangle.bottomthird.inset.filled"),
            SGWithSymbol(SGPageRow(@"Queue & devices", ^UIViewController *{ return queuePage(); }), @"text.line.first.and.arrowtriangle.forward"),
            SGWithSymbol(SGPageRow(@"Lock screen widget", ^UIViewController *{ return lockScreenPage(); }), @"lock"),
        ]),
        SGNotedSection(@"Player screen", @[
            SGOptionRow(@"Artwork background", @"The cover blurred and dimmed behind the player instead of the flat album colour", SGKeyPlayerBackdrop),
            SGOptionRow(@"Glass header buttons", nil, SGKeyPlayer),
            bare(SGKillRow(@"Disable Canvas", @"ios-feature-canvas.canvas_enabled")),
            bare(SGFlagRow(@"Sheet style player", @"ios-feature-nowplaying.sheet_style_npv")),
            bare(SGFlagRow(@"Redesigned header", @"ios-feature-nowplaying.new_redesign_header_with_context_menu_enabled")),
            bare(SGFlagRow(@"New progress slider", @"ios-feature-encoreexperiments.new_npv_slider_enabled")),
            bare(SGFlagRow(@"Expand the sticky header on tap", @"ios-feature-nowplaying.expand_sticky_header_on_tap")),
        ], @"Liquid Glass UI turns the first two on or off with it, and locks the sheet, header and slider on."),
        SGNotedSection(@"Hide cards below the player", @[
            SGHideRow(@"About the artist", nil, SGHideAboutArtist),
            SGHideRow(@"Related videos", nil, SGHideRelatedVideos),
            SGHideRow(@"SongDNA", nil, SGHideSongDNA),
            SGHideRow(@"Live events", nil, SGHideLiveEvents),
            SGHideRow(@"Explore the artist", nil, SGHideExploreArtist),
            SGHideRow(@"Credits", nil, SGHideCredits),
            SGHideRow(@"Merch", nil, SGHideMerch),
            SGHideRow(@"Recommendations", nil, SGHideRecommendations),
        ], @"The lyrics card is hidden from the Lyrics page."),
        SGSection(@"Hide player buttons", @[
            SGHideRow(@"Shuffle", nil, SGHideShuffle),
            SGHideRow(@"Repeat", nil, SGHideRepeat),
            SGHideRow(@"Add to playlist", nil, SGHideAddTo),
            SGHideRow(@"Queue", nil, SGHideQueue),
            SGHideRow(@"Share", nil, SGHideShare),
            SGHideRow(@"Connect to a device", nil, SGHideConnect),
        ]),
    ] footer:nil];
}
