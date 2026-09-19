// Settings: a Mod Settings row at the end of Spotify's settings list opens the mod's own page: the
// Appearance card that styles the whole app, then a page per part of Spotify, each holding that
// part's glass, hide switches and flags (Navbar, Player, Home & Library), Premium, ads & privacy
// and Labs, All flags, a searchable list of every flag with an override per flag, and Mod, the
// build, its updates and links. The same row leads the side drawer's list (trees/test6.txt), above
// Your plan, followed by a direct Downloads shortcut. Holding Home opens settings too. The tweaks read the switches when they run, so a change
// shows after Spotify restarts; the tab editor on the Navbar page applies as soon as the bar lays
// out again.
//
// Tree (trees/settings.txt): SettingsListViewController.view > SettingsListCollectionView of
//   Element_List cells 402x56: 24pt icon at x 12, 13pt white title and 11pt grey subtitle at
//   x 48, 12pt chevron on the right. A pushed page (trees/settings notifications opened.txt) is a
//   UITableView bg #121212: header with an 11pt grey description at (16, 24), 53pt cells with the
#import "Core/SGCore.h"
#import "SGPage.h"
#import "SGPageStyle.h"
#import "SGModPage.h"
#import "Features/Appearance/Appearance.h"
#import "Features/Navbar/Navbar.h"
#import "Features/Home/Home.h"
#import "Features/NowPlaying/NowPlaying.h"
#import "Features/NowPlaying/AutomaticDownloads.h"
#import "Features/AdBlock/AdBlock.h"
#import "Features/Flags/Flags.h"
#import "Features/About/About.h"
#import <math.h>

static const CGFloat kRowHeight = 56;
static char kRowKey, kDownloadsRowKey, kInsetKey;

static SGModRow *pageRow(NSString *title, NSString *symbol, UIViewController *(^page)(void)) {
    return SGWithSymbol(SGPageRow(title, page), symbol);
}

static UIViewController *modSettingsPage(void) {
    // Opening the page is the only thing that asks; the cache keeps it to once every six hours.
    SGCheckForUpdate(NO);
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    // A build the lock screen cannot open leads the page, above the tweaks: it is the one thing here
    // that no switch can put right, and it is worth reading before anything else.
    SGModRow *signing = SGSigningWarningRow();
    if (signing) [sections addObject:SGSection(nil, @[signing])];
    SGModRow *mod = pageRow(@"Mod", @"info.circle", ^UIViewController *{ return SGAboutPage(); });
    mod.value = ^NSString *{ return @(SG_VERSION); };
    [sections addObjectsFromArray:@[
        SGAppearanceSection(),
        SGSection(nil, @[
            pageRow(@"Navbar", @"dock.rectangle", ^UIViewController *{ return SGNavbarSettingsPage(); }),
            pageRow(@"Player", @"play.circle", ^UIViewController *{ return SGNowPlayingSettingsPage(); }),
            pageRow(@"Home & Library", @"house", ^UIViewController *{ return SGHomeSettingsPage(); }),
        ]),
        SGSection(nil, @[
            pageRow(@"Premium, ads & privacy", @"crown", ^UIViewController *{ return SGAdsSettingsPage(); }),
            pageRow(@"Labs", @"testtube.2", ^UIViewController *{ return SGLabsPage(); }),
        ]),
        SGSection(nil, @[
            pageRow(@"All flags", @"flag", ^UIViewController *{ return SGAllFlagsPage(); }),
            mod,
        ]),
    ]];
    return [[SGModPage alloc] initWithTitle:@"spoti.pw" intro:nil sections:sections footer:nil];
}

#pragma mark - row in the settings list and the side drawer

// The last row of Spotify's settings list, chevron and all, or the first of the side drawer's,
// drawn like the drawer's own rows: no chevron, icon and title 4pt further in.
@interface SGModSettingsRow : UIControl
@property (nonatomic) BOOL drawer;
@property (nonatomic, readonly) BOOL downloads;
@property (nonatomic) BOOL opening;
- (instancetype)initWithFrame:(CGRect)frame downloads:(BOOL)downloads;
@end

@implementation SGModSettingsRow {
    UIImageView *_icon;
    UILabel *_title;
    UIImageView *_chevron;
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame downloads:NO];
}

- (instancetype)initWithFrame:(CGRect)frame downloads:(BOOL)downloads {
    if (!(self = [super initWithFrame:frame])) return nil;
    _downloads = downloads;
    _icon = SGSymbolView(downloads ? @"arrow.down.circle" : @"slider.horizontal.3", 20, UIImageSymbolWeightRegular, 24);
    _title = [UILabel new];
    _title.text = downloads ? @"Téléchargements" : @"Mod Settings";
    _title.textColor = UIColor.whiteColor;
    _chevron = SGSymbolView(@"chevron.right", 11, UIImageSymbolWeightSemibold, 12);
    for (UIView *v in @[_icon, _title, _chevron]) [self addSubview:v];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = _title.text;
    self.accessibilityIdentifier = downloads ? @"spoti.drawer.downloads" : @"spoti.settings.shortcut";
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _title.font = SGTitleFont();
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height, lead = self.drawer ? 4 : 0;
    _icon.frame = CGRectMake(12 + lead, (height - 24) / 2, 24, 24);
    _title.frame = CGRectMake(48 + lead, 0, width - 96, height);
    _chevron.frame = CGRectMake(width - 24, (height - 12) / 2, 12, 12);
    _chevron.hidden = self.drawer;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}

static UINavigationController *navigationIn(UIViewController *page) {
    if ([page isKindOfClass:UINavigationController.class]) return (UINavigationController *)page;
    if ([page isKindOfClass:UITabBarController.class]) return navigationIn(((UITabBarController *)page).selectedViewController);
    for (UIViewController *child in page.childViewControllers) {
        UINavigationController *found = navigationIn(child);
        if (found) return found;
    }
    return nil;
}

// The drawer is presented over the app, so its row closes it first and pushes onto the stack it
// was covering, the way the drawer's own rows open their pages.
- (void)open {
    if (self.opening) return;
    UIViewController *owner = nil;
    for (UIResponder *r = self; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    if (!owner) return;
    BOOL downloads = self.downloads;
    UIViewController *presenting = self.drawer ? owner.presentingViewController : nil;
    if (!presenting) {
        SGShowPage(owner, downloads ? SGAutomaticDownloadsPageCreate() : modSettingsPage());
        return;
    }
    self.opening = YES;
    [presenting dismissViewControllerAnimated:YES completion:^{
        SGShowPage(navigationIn(presenting).topViewController ?: presenting,
            downloads ? SGAutomaticDownloadsPageCreate() : modSettingsPage());
        self.opening = NO;
    }];
}

@end

// The tab bar's controller holds no stack itself; the selected tab's sits among its parent's children.
void SGOpenModSettings(UIView *source) {
    UIViewController *owner = nil;
    for (UIResponder *r = source; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UINavigationController *nav = nil;
    for (UIViewController *page = owner; page && !nav; page = page.parentViewController) nav = navigationIn(page);
    SGShowPage(nav.topViewController ?: SGTopController(), modSettingsPage());
}

// At the end of the settings list, or above the first row of the drawer's, with the inset for it
// added again whenever Spotify resets the inset.
static void placeRow(UICollectionView *list, SGModSettingsRow *row) {
    SGModSettingsRow *downloads = row.drawer ? objc_getAssociatedObject(list, &kDownloadsRowKey) : nil;
    // Adopt only native cell fonts, not the second shortcut's fallback font.
    if (row.drawer) for (UICollectionViewCell *cell in list.visibleCells) SGAdoptFonts(cell, row);
    else SGAdoptFonts(list, row);
    CGFloat bottom = list.contentSize.height;
    CGFloat reserved = kRowHeight * (downloads ? 2 : 1);
    row.hidden = !row.drawer && bottom <= 0;
    row.frame = CGRectMake(0, row.drawer ? -reserved : bottom, list.bounds.size.width, kRowHeight);
    if (downloads) downloads.frame = CGRectMake(0, -kRowHeight, list.bounds.size.width, kRowHeight);

    UIEdgeInsets inset = list.contentInset;
    NSValue *applied = objc_getAssociatedObject(list, &kInsetKey);
    // Changes to another edge must not add the shortcut height again.
    if (applied && (row.drawer ? inset.top == applied.UIEdgeInsetsValue.top : inset.bottom == applied.UIEdgeInsetsValue.bottom)) return;
    BOOL atTop = row.drawer && !list.dragging && !list.decelerating && !list.tracking &&
        fabs(list.contentOffset.y + list.adjustedContentInset.top) <= 1;
    if (row.drawer) inset.top += reserved;
    else inset.bottom += kRowHeight;
    objc_setAssociatedObject(list, &kInsetKey, [NSValue valueWithUIEdgeInsets:inset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    list.contentInset = inset;
    if (atTop) list.contentOffset = CGPointMake(list.contentOffset.x, -list.adjustedContentInset.top);
}

// Media quality, Playback, Account and most of the rest of settings are the same controller class
// as the list they were opened from, which is why the row turned up at the end of all of them.
// What is on the navigation stack is not that controller though: every page in the app is wrapped
// in a MusicAppPageHostingViewController (trees/settings notifications opened.txt), and Spotify
// pushes a settings sub page as a page of its own, leaving the list it came from on the stack
// underneath. So the settings list inside the lowest wrapper that holds one is the list the row
// belongs at the end of, and a controller with no stack to be found on keeps the row rather than
// losing it.
static UIViewController *settingsListIn(UIViewController *page, Class kind) {
    if ([page isKindOfClass:kind]) return page;
    for (UIViewController *child in page.childViewControllers) {
        UIViewController *found = settingsListIn(child, kind);
        if (found) return found;
    }
    return nil;
}

static BOOL isSettingsRoot(UIViewController *list) {
    for (UIViewController *page in list.navigationController.viewControllers) {
        UIViewController *found = settingsListIn(page, list.class);
        if (found) return found == list;
    }
    return YES;
}

%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    BOOL root = isSettingsRoot((UIViewController *)self);
    for (UIView *sub in ((UIViewController *)self).view.subviews) {
        if (![sub isKindOfClass:UICollectionView.class]) continue;
        SGModSettingsRow *row = objc_getAssociatedObject(sub, &kRowKey);
        // A page that laid itself out before it was on the stack looked like the list for as long
        // as that took; the row goes again as soon as it can be seen for what it is.
        if (!root) {
            [row removeFromSuperview];
            objc_setAssociatedObject(sub, &kRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }
        if (row) continue;
        row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(sub, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sub addSubview:row];
    }
}
%end

// The drawer's list (trees/test6.txt: SideDrawerListCollectionView under the profile header, Your
// plan its first cell) is one of several collection views on the page, so it is found by name.
%hook _TtC23SideDrawer_ListPageImpl18ListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGForEachView(((UIViewController *)self).view, ^(UIView *v) {
        if (![v isKindOfClass:UICollectionView.class] || ![NSStringFromClass(v.class) containsString:@"SideDrawerListCollectionView"]) return;
        if (!objc_getAssociatedObject(v, &kRowKey)) {
            SGModSettingsRow *row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
            row.drawer = YES;
            objc_setAssociatedObject(v, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [v addSubview:row];
        }
        if (!objc_getAssociatedObject(v, &kDownloadsRowKey)) {
            SGModSettingsRow *downloads = [[SGModSettingsRow alloc] initWithFrame:CGRectZero downloads:YES];
            downloads.drawer = YES;
            objc_setAssociatedObject(v, &kDownloadsRowKey, downloads, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [v addSubview:downloads];
        }
    });
}
%end

// The lists lay out after their controllers and again whenever their content changes.
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    SGModSettingsRow *row = objc_getAssociatedObject(self, &kRowKey);
    if (row) placeRow(self, row);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21Settings_PlatformImpl26SettingsListViewController", @"_TtC23SideDrawer_ListPageImpl18ListViewController"]);
    SGRegisterPages();
    SGCheckSigningOnce();
}
