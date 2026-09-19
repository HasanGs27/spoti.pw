#import "AutomaticLocalFilesPage.h"
#import "AutomaticDownloads.h"
#import "Settings/SGPageStyle.h"

static NSString *localFileText(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static NSString *localFileTitle(NSDictionary *item) {
    NSString *title = localFileText(item[@"title"]);
    return title.length ? title : localFileText(item[@"path"]).lastPathComponent;
}
static NSString *localFileSize(NSDictionary *item) {
    NSNumber *bytes = [item[@"bytes"] isKindOfClass:NSNumber.class] ? item[@"bytes"] : @0;
    return [NSByteCountFormatter stringFromByteCount:MAX(0, bytes.longLongValue) countStyle:NSByteCountFormatterCountStyleFile];
}

@interface SGAutomaticLocalFilesPage () <UISearchBarDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic, copy) NSArray<NSDictionary *> *shown;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UIView *note;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIActivityIndicatorView *activity;
@property (nonatomic, copy) NSString *feedback;
@property (nonatomic, copy) NSString *listMessage;
@property (nonatomic) BOOL feedbackFailed;
@property (nonatomic) BOOL listFailed;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL deleting;
@property (nonatomic) BOOL confirming;
@property (nonatomic) NSUInteger loadGeneration;
- (void)reloadFiles;
- (void)reloadTapped;
- (void)filterRows;
- (void)updateControls;
- (void)confirmDelete:(NSDictionary *)item;
@end

@implementation SGAutomaticLocalFilesPage
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Fichiers sur l’iPhone";
        self.items = @[]; self.shown = @[];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 96;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.note = SGNote(@"Chaque ligne correspond à un fichier. Le nom et le dossier permettent de distinguer les copies. Tu choisis toi-même le fichier à supprimer.");
    self.search = [UISearchBar new];
    self.search.delegate = self;
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.placeholder = @"Titre, artiste ou nom du fichier";
    self.search.accessibilityLabel = @"Rechercher un fichier local";
    self.search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.search.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.note addSubview:self.search];
    self.tableView.tableHeaderView = self.note;
    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadTapped)];
    self.refreshButton.accessibilityLabel = @"Actualiser les fichiers locaux";
    self.activity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.activity.color = SGGrey();
    [self updateControls];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.deleting && !self.confirming) [self reloadFiles];
}
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    self.search.frame = CGRectMake(8, 4, MAX(0, self.tableView.bounds.size.width - 16), 44);
    SGFitNote(self.tableView, self.note, 54, 12);
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}
- (void)updateControls {
    BOOL busy = self.loading || self.deleting;
    self.search.userInteractionEnabled = !self.deleting;
    if (busy) {
        self.activity.accessibilityLabel = self.deleting ? @"Suppression en cours" : @"Lecture des fichiers en cours";
        [self.activity startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.activity];
    } else {
        [self.activity stopAnimating];
        self.navigationItem.rightBarButtonItem = self.refreshButton;
    }
}
- (void)reloadTapped {
    if (self.loading || self.deleting || self.confirming) return;
    self.feedback = nil; self.feedbackFailed = NO;
    [self reloadFiles];
}
- (void)reloadFiles {
    if (self.loading || self.deleting || self.confirming) return;
    self.loading = YES; self.listMessage = nil; self.listFailed = NO;
    NSUInteger generation = ++self.loadGeneration;
    [self updateControls]; [self.tableView reloadData];
    __weak typeof(self) weak = self;
    SGAutomaticListLocalFiles(^(NSArray<NSDictionary *> *items, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SGAutomaticLocalFilesPage *page = weak;
            if (!page || page.loadGeneration != generation) return;
            page.loading = NO;
            page.listFailed = ![items isKindOfClass:NSArray.class];
            page.listMessage = localFileText(message);
            if (!page.listFailed) {
                NSMutableArray *valid = [NSMutableArray array];
                for (id item in items) {
                    if ([item isKindOfClass:NSDictionary.class] && localFileText(item[@"path"]).length)
                        [valid addObject:[item copy]];
                }
                [valid sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    NSComparisonResult title = [localFileTitle(a) localizedStandardCompare:localFileTitle(b)];
                    return title == NSOrderedSame ? [localFileText(a[@"path"]) localizedStandardCompare:localFileText(b[@"path"])] : title;
                }];
                page.items = [valid copy];
            } else if (!page.listMessage.length) {
                page.listMessage = @"La liste est indisponible. Mets les téléchargements en pause, puis actualise.";
            }
            [page filterRows]; [page updateControls];
        });
    });
}
- (void)filterRows {
    NSArray<NSString *> *words = [(self.search.text ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *shown = [NSMutableArray array];
    for (NSDictionary *item in self.items) {
        NSString *text = [@[localFileTitle(item), localFileText(item[@"artist"]), localFileText(item[@"album"]), localFileText(item[@"path"])] componentsJoinedByString:@"\n"];
        BOOL matches = YES;
        for (NSString *word in words) {
            if (word.length && [text rangeOfString:word options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) {
                matches = NO; break;
            }
        }
        if (matches) [shown addObject:item];
    }
    self.shown = [shown copy]; [self.tableView reloadData];
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText { [self filterRows]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.shown.count;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 0) return nil;
    return SGSectionHeader(tableView, [NSString stringWithFormat:@"%lu fichiers affichés sur %lu", (unsigned long)self.shown.count, (unsigned long)self.items.count]);
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? SGSectionGap : SGSectionHeaderHeight;
}
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return section == 1 ? SGSectionFooter(tableView, @"Supprimer un fichier retire cette copie hors ligne pour toutes les playlists qui l’utilisent. Le titre reste dans tes playlists Spotify.") : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return section == 1 ? SGSectionFooterHeight(tableView, @"Supprimer un fichier retire cette copie hors ligne pour toutes les playlists qui l’utilisent. Le titre reste dans tes playlists Spotify.") : CGFLOAT_MIN;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = SGDequeueCell(tableView, indexPath.section == 0 ? @"local-file-status" : @"local-file");
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.section == 0) {
        NSString *title = self.deleting ? @"Suppression en cours…" : self.loading ? @"Lecture des fichiers…" :
            self.feedback.length ? (self.feedbackFailed ? @"Suppression impossible" : @"Fichier supprimé") :
            self.listFailed ? @"Liste indisponible" : !self.items.count ? @"Aucun fichier audio trouvé" :
            !self.shown.count ? @"Aucun résultat" : @"Choisis le fichier à supprimer";
        NSMutableArray *notes = [NSMutableArray array];
        if (self.feedback.length) [notes addObject:self.feedback];
        if (self.listMessage.length) [notes addObject:self.listMessage];
        if (!notes.count) [notes addObject:self.loading ? @"Recherche dans les fichiers de cette app, sans téléchargement." :
            self.search.text.length && !self.shown.count ? @"Essaie un autre titre, artiste ou nom de fichier." :
            @"Touche une ligne ou glisse-la vers la gauche. Une confirmation sera demandée."];
        SGFillCell(cell, title, [notes componentsJoinedByString:@"\n"], self.feedbackFailed || self.listFailed ? SGRed() : nil, @"internaldrive");
        cell.accessibilityTraits = UIAccessibilityTraitStaticText;
        cell.accessibilityHint = nil;
    } else if ((NSUInteger)indexPath.row < self.shown.count) {
        NSDictionary *item = self.shown[(NSUInteger)indexPath.row];
        NSString *artist = localFileText(item[@"artist"]);
        NSString *detail = [NSString stringWithFormat:@"%@ · %@ · %@\n%@", artist.length ? artist : @"Artiste non renseigné",
            localFileSize(item), localFileText(item[@"extension"]).uppercaseString, localFileText(item[@"path"])];
        SGFillCell(cell, localFileTitle(item), detail, nil, @"music.note");
        cell.selectionStyle = self.loading || self.deleting ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        cell.accessibilityHint = @"Affiche la confirmation de suppression définitive de ce fichier.";
    }
    UIListContentConfiguration *content = [cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class] ? (UIListContentConfiguration *)cell.contentConfiguration : nil;
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    cell.contentConfiguration = content;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || (NSUInteger)indexPath.row >= self.shown.count) return;
    [self confirmDelete:self.shown[(NSUInteger)indexPath.row]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.loading || self.deleting || indexPath.section != 1 || (NSUInteger)indexPath.row >= self.shown.count) return nil;
    NSDictionary *item = [self.shown[(NSUInteger)indexPath.row] copy];
    __weak typeof(self) weak = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Supprimer" handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
        // No optimistic row deletion: a swipe only opens the confirmation for this snapshot.
        completion(NO);
        dispatch_async(dispatch_get_main_queue(), ^{ [weak confirmDelete:item]; });
    }];
    remove.image = [UIImage systemImageNamed:@"trash"]; remove.backgroundColor = SGRed();
    UISwipeActionsConfiguration *actions = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    actions.performsFirstActionWithFullSwipe = NO;
    return actions;
}
- (void)confirmDelete:(NSDictionary *)item {
    if (self.loading || self.deleting || self.confirming || self.presentedViewController || !self.viewIfLoaded.window) return;
    if (self.isBeingDismissed || self.isMovingFromParentViewController ||
        (self.navigationController && self.navigationController.topViewController != self)) return;
    [self.search resignFirstResponder];
    NSDictionary *selected = [item copy]; // Preserve the path and file stamp shown at confirmation.
    NSString *message = [NSString stringWithFormat:@"%@\n%@\n%@ · %@\n%@\n\nCette suppression est définitive. Toutes les playlists qui utilisent ce fichier perdront cette copie hors ligne.",
        localFileTitle(selected), localFileText(selected[@"artist"]), localFileSize(selected),
        localFileText(selected[@"extension"]).uppercaseString, localFileText(selected[@"path"])];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Supprimer définitivement de l’iPhone ?" message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weak = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { weak.confirming = NO; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Supprimer définitivement" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGAutomaticLocalFilesPage *page = weak;
        if (!page) return;
        page.confirming = NO;
        if (page.loading || page.deleting) return;
        page.deleting = YES; page.feedback = nil; page.feedbackFailed = NO;
        page.listMessage = nil; [page updateControls]; [page.tableView reloadData];
        SGAutomaticDeleteLocalFile(selected, ^(BOOL success, NSString *result) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGAutomaticLocalFilesPage *finishedPage = weak;
                if (!finishedPage) return;
                finishedPage.deleting = NO;
                finishedPage.feedbackFailed = !success;
                finishedPage.feedback = localFileText(result).length ? result : success ? @"Le fichier a été supprimé de cet iPhone." : @"Le fichier n’a pas été supprimé. Actualise la liste et réessaie.";
                [finishedPage reloadFiles];
            });
        });
    }]];
    self.confirming = YES;
    [self presentViewController:alert animated:YES completion:nil];
}
@end
