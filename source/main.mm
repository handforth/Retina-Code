#import "Editor.h"
#import "Chrome.h"
#import "DebugPane.h"
#import "Preferences.h"
#import "Rendering.h"
#import "Runner.h"
#import "SessionState.h"
#import "Workspace.h"

#include <algorithm>
#include <cmath>
#include <vector>

@interface ApplicationDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation>
- (IBAction)openExample:(id)sender;
- (IBAction)showPreferences:(id)sender;
- (IBAction)showFonts:(id)sender;
- (IBAction)newWindowForTab:(id)sender;
- (IBAction)closeWindow:(id)sender;
- (IBAction)debugCommand:(NSMenuItem *)sender;
- (IBAction)openFolder:(id)sender;
- (IBAction)findInFiles:(id)sender;
- (IBAction)replaceInFiles:(id)sender;
- (IBAction)toggleAutoSave:(id)sender;
- (IBAction)showCommandPalette:(id)sender;
@end

@interface EditorFontManager : NSFontManager
@end

@implementation EditorFontManager

- (void)orderFrontFontPanel:(id)sender
{
    self.target = self;
    self.action = @selector(changeEditorFont:);
    [self setSelectedFont:EditorFontPreference() isMultiple:NO];

    NSFontPanel *panel = [self fontPanel:YES];
    [panel makeKeyAndOrderFront:sender];
    // Keep AppKit's rich-text toolbar out of layout after the Fonts panel closes.
    panel.toolbar.visible = NO;
    panel.becomesKeyOnlyIfNeeded = NO;
}

- (void)changeEditorFont:(NSFontManager *)sender
{
    SetEditorFont([sender convertFont:EditorFontPreference()]);
}

@end

enum class PalettePage { Theme, TabSize, MoreTabSizes, Language, Whitespace, AutoSave, FinalNewline };

static NSMenuItem *AddItem(NSMenu *menu, NSString *title, SEL action, NSString *key, NSInteger tag = 0)
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.tag = tag;
    [menu addItem:item];
    return item;
}

static NSMenu *AddMenu(NSMenu *parent, NSString *title)
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    AddItem(parent, title, nullptr, @"").submenu = menu;
    return menu;
}

static void SetUpMenus()
{
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenu *app = AddMenu(bar, @"Retina Code");
    AddItem(app, @"About Retina Code", @selector(orderFrontStandardAboutPanel:), @"");
    [app addItem:NSMenuItem.separatorItem];
    AddItem(app, @"Preferences…", @selector(showPreferences:), @",").target = NSApp.delegate;
    [app addItem:NSMenuItem.separatorItem];
    AddItem(app, @"Hide Retina Code", @selector(hide:), @"h");
    AddItem(app, @"Quit Retina Code", @selector(terminate:), @"q");

    NSMenu *file = AddMenu(bar, @"File");
    AddItem(file, @"New Window", @selector(newDocument:), @"n");
    AddItem(file, @"New Tab", @selector(newWindowForTab:), @"t").target = NSApp.delegate;
    AddItem(file, @"Open…", @selector(openDocument:), @"o");
    AddItem(file, @"Open Folder…", @selector(openFolder:), @"O").target = NSApp.delegate;
    AddItem(file, @"Open Example", @selector(openExample:), @"").target = NSApp.delegate;
    [file addItem:NSMenuItem.separatorItem];
    AddItem(file, @"Close", @selector(performClose:), @"w");
    AddItem(file, @"Close Window", @selector(closeWindow:), @"W").target = NSApp.delegate;
    AddItem(file, @"Save", @selector(saveDocument:), @"s");
    AddItem(file, @"Save As…", @selector(saveDocumentAs:), @"S");
    AddItem(file, @"Auto Save", @selector(toggleAutoSave:), @"").target = NSApp.delegate;
    [file addItem:NSMenuItem.separatorItem];
    AddItem(file, @"Run", @selector(runDocument:), @"r");

    NSMenu *edit = AddMenu(bar, @"Edit");
    AddItem(edit, @"Undo", @selector(undo:), @"z");
    AddItem(edit, @"Redo", @selector(redo:), @"Z");
    [edit addItem:NSMenuItem.separatorItem];
    AddItem(edit, @"Cut", @selector(cut:), @"x");
    AddItem(edit, @"Copy", @selector(copy:), @"c");
    AddItem(edit, @"Paste", @selector(paste:), @"v");
    AddItem(edit, @"Select All", @selector(selectAll:), @"a");
    [edit addItem:NSMenuItem.separatorItem];
    AddItem(edit, @"Toggle Line Comment", @selector(toggleLineComment:), @"/");
    [edit addItem:NSMenuItem.separatorItem];
    NSMenu *find = AddMenu(edit, @"Find");
    AddItem(find, @"Find…", @selector(performTextFinderAction:), @"f", NSTextFinderActionShowFindInterface);
    AddItem(find, @"Find Next", @selector(performTextFinderAction:), @"g", NSTextFinderActionNextMatch);
    AddItem(find, @"Find Previous", @selector(performTextFinderAction:), @"G", NSTextFinderActionPreviousMatch);
    AddItem(find, @"Use Selection for Find", @selector(performTextFinderAction:), @"e",
            NSTextFinderActionSetSearchString);
    [find addItem:NSMenuItem.separatorItem];
    NSMenuItem *findInFiles = AddItem(find, @"Find in Files…", @selector(findInFiles:), @"f");
    findInFiles.target = NSApp.delegate;
    findInFiles.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem *replaceInFiles = AddItem(find, @"Replace in Files…", @selector(replaceInFiles:), @"h");
    replaceInFiles.target = NSApp.delegate;
    replaceInFiles.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;

    NSMenu *selection = AddMenu(bar, @"Selection");
    const unichar up = NSUpArrowFunctionKey, down = NSDownArrowFunctionKey;
    AddItem(selection, @"Add Cursor Above", @selector(addCursorAbove:),
            [NSString stringWithCharacters:&up length:1]).keyEquivalentModifierMask =
                NSEventModifierFlagCommand | NSEventModifierFlagOption;
    AddItem(selection, @"Add Cursor Below", @selector(addCursorBelow:),
            [NSString stringWithCharacters:&down length:1]).keyEquivalentModifierMask =
                NSEventModifierFlagCommand | NSEventModifierFlagOption;
    AddItem(selection, @"Add Cursors to Line Ends", @selector(addCursorsToLineEnds:), @"i").keyEquivalentModifierMask =
        NSEventModifierFlagOption | NSEventModifierFlagShift;
    [selection addItem:NSMenuItem.separatorItem];
    AddItem(selection, @"Add Next Occurrence", @selector(addNextOccurrence:), @"d");
    AddItem(selection, @"Select All Occurrences", @selector(selectAllOccurrences:), @"l").keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagShift;
    AddItem(selection, @"Undo Cursor Change", @selector(undoCursorChange:), @"u");

    NSMenu *view = AddMenu(bar, @"View");
    NSMenuItem *palette = AddItem(view, @"Command Palette…", @selector(showCommandPalette:), @"p");
    palette.target = NSApp.delegate;
    palette.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [view addItem:NSMenuItem.separatorItem];
    AddItem(view, @"Show Sidebar", @selector(toggleExplorer:), @"b");
    AddItem(view, @"Show Tab Bar", @selector(toggleTabBar:), @"");
    [view addItem:NSMenuItem.separatorItem];
    NSMenu *theme = AddMenu(view, @"Theme");
    PopulateThemeMenu(theme, @selector(selectTheme:));
    theme.delegate = (ApplicationDelegate *)NSApp.delegate;

    NSMenu *smoothing = AddMenu(view, @"Font Smoothing");
    AddItem(smoothing, @"Retina LCD", @selector(selectSmoothing:), @"", NSInteger(Smoothing::RetinaLCD));
    AddItem(smoothing, @"Retina Web", @selector(selectSmoothing:), @"", NSInteger(Smoothing::RetinaWeb));
    AddItem(smoothing, @"System", @selector(selectSmoothing:), @"", NSInteger(Smoothing::System));

    NSMenu *font = AddMenu(view, @"Font");
    NSMenuItem *fonts = AddItem(font, @"Show Fonts…", @selector(showFonts:), @"t");
    fonts.target = NSApp.delegate;
    fonts.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [font addItem:NSMenuItem.separatorItem];
    AddItem(font, @"Menlo", @selector(selectFont:), @"", 0);
    AddItem(font, @"Monaco", @selector(selectFont:), @"", 1);
    [view addItem:NSMenuItem.separatorItem];
    AddItem(view, @"Increase Text Size", @selector(changeFontSize:), @"=", 1);
    AddItem(view, @"Decrease Text Size", @selector(changeFontSize:), @"-", -1);
    AddItem(view, @"Actual Size", @selector(changeFontSize:), @"0");
    [view addItem:NSMenuItem.separatorItem];
    AddItem(view, @"Output", @selector(toggleDocumentOutput:), @"");
    NSMenuItem *vim = AddItem(view, @"Vim Mode", @selector(toggleVimMode:), @"v");
    vim.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;

    NSMenu *debug = AddMenu(bar, @"Debug");
    for (auto command : {DebugCommand::Continue, DebugCommand::Pause, DebugCommand::StepOver, DebugCommand::StepInto,
                         DebugCommand::StepOut, DebugCommand::Restart, DebugCommand::Stop,
                         DebugCommand::ToggleBreakpoint, DebugCommand::EditBreakpoint, DebugCommand::RunToCursor,
                         DebugCommand::ChooseExecutable, DebugCommand::Attach, DebugCommand::Arguments, DebugCommand::ShowPane}) {
        if (command == DebugCommand::ToggleBreakpoint || command == DebugCommand::ChooseExecutable)
            [debug addItem:NSMenuItem.separatorItem];
        NSMenuItem *item = MakeDebugMenuItem(command);
        item.target = NSApp.delegate;
        [debug addItem:item];
    }

    NSMenu *window = AddMenu(bar, @"Window");
    AddItem(window, @"Minimize", @selector(performMiniaturize:), @"m");
    AddItem(window, @"Zoom", @selector(performZoom:), @"");
    [window addItem:NSMenuItem.separatorItem];
    AddItem(window, @"Select Previous Tab", @selector(selectPreviousTab:), @"{");
    AddItem(window, @"Select Next Tab", @selector(selectNextTab:), @"}");
    AddItem(window, @"Move Tab to New Window", @selector(moveTabToNewWindow:), @"");
    AddItem(window, @"Merge All Windows", @selector(mergeAllWindows:), @"");
    [window addItem:NSMenuItem.separatorItem];
    AddItem(window, @"Bring All to Front", @selector(arrangeInFront:), @"");
    NSApp.windowsMenu = window;
    NSApp.mainMenu = bar;
}

@interface SourceDocumentController : NSDocumentController <SourceFileOpening>
- (NSWindow *)activeEditorWindow;
- (void)showOpenedDocument:(SourceDocument *)document inWindow:(NSWindow *)window replacing:(SourceDocument *)placeholder;
- (NSWindow *)openFolderAtURL:(NSURL *)url inWindow:(NSWindow *)anchor error:(NSError **)error;
- (BOOL)saveSessionForQuitDiscarding:(NSSet<SourceDocument *> *)discarded;
- (void)restoreSession;
@end

static NSArray *CaptureSessionWindows(NSSet<SourceDocument *> *discarded)
{
    NSMutableOrderedSet<NSWindow *> *ordered = [NSMutableOrderedSet orderedSet];
    if (NSApp.keyWindow)
        [ordered addObject:NSApp.keyWindow];
    [ordered addObjectsFromArray:NSApp.orderedWindows];
    [ordered addObjectsFromArray:NSApp.windows];

    NSMutableArray *windows = [NSMutableArray array];
    NSMutableSet<NSWindow *> *captured = [NSMutableSet set];
    for (NSWindow *window in ordered) {
        if ([captured containsObject:window])
            continue;
        NSArray<SourceDocument *> *tabs = EditorWindowTabs(window);
        if (!tabs)
            continue;
        FolderWorkspace *workspace = WorkspaceForEditorWindow(window);
        NSWindow *selected = window;
        if (!workspace) {
            NSWindowTabGroup *group = window.tabGroup;
            if (group.selectedWindow)
                selected = group.selectedWindow;
            if (group.windows)
                [captured addObjectsFromArray:group.windows];
        }
        [captured addObject:window];

        NSMutableArray *documents = [NSMutableArray arrayWithCapacity:tabs.count];
        NSUInteger active = 0;
        for (SourceDocument *document in tabs) {
            if (document == selected.windowController.document)
                active = documents.count;
            NSDictionary *tab = [document sessionStateDiscardingChanges:[discarded containsObject:document]];
            if (tab)
                [documents addObject:tab];
        }
        if (!documents.count && !workspace)
            continue;
        if (documents.count)
            active = std::min(active, documents.count - 1);
        NSMutableDictionary *state = [@{@"tabs":documents, @"selected":@(active),
            @"frame":NSStringFromRect(selected.frame), @"tabBar":@(EditorWindowShowsTabBar(selected)),
            @"output":@(EditorWindowOutputShown(selected)),
            @"minimized":@(selected.miniaturized)} mutableCopy];
        if (workspace) {
            state[@"folder"] = workspace.folder.path;
            state[@"sidebar"] = @(workspace.sidebarShown);
            state[@"width"] = @(workspace.sidebarWidth);
            state[@"expanded"] = workspace.sessionExpandedFolders;
        }
        [windows addObject:state];
    }
    return windows;
}

static NSURL *SessionPathURL(NSString *path)
{
    return path.isAbsolutePath ? CanonicalFileURL([NSURL fileURLWithPath:path]) : nil;
}

static FolderWorkspace *RestoreSessionWorkspace(NSDictionary *state, NSMutableDictionary<NSString *, FolderWorkspace *> *workspaces)
{
    NSURL *folder = SessionPathURL(SessionString(state[@"folder"]));
    if (!folder)
        return nil;
    if (FolderWorkspace *workspace = workspaces[folder.path])
        return workspace;
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&directory] || !directory)
        return nil;

    FolderWorkspace *workspace = [[FolderWorkspace alloc] initWithFolder:folder];
    NSNumber *sidebar = SessionNumber(state[@"sidebar"]);
    if (sidebar)
        workspace.sidebarShown = sidebar.boolValue;
    CGFloat width = [SessionNumber(state[@"width"]) doubleValue];
    if (std::isfinite(width) && width >= 140)
        workspace.sidebarWidth = width;
    [workspace restoreSessionExpandedFolders:SessionArray(state[@"expanded"])];
    workspaces[folder.path] = workspace;
    return workspace;
}

static void RestoreSessionWindowFrame(NSWindow *window, NSString *saved)
{
    if (!saved)
        return;
    NSRect frame = NSRectFromString(saved);
    if (!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y) ||
        !std::isfinite(NSWidth(frame)) || !std::isfinite(NSHeight(frame)) ||
        NSWidth(frame) < 1 || NSHeight(frame) < 1)
        return;

    NSScreen *screen = NSScreen.mainScreen;
    CGFloat largestArea = 0;
    for (NSScreen *candidate in NSScreen.screens) {
        NSRect overlap = NSIntersectionRect(candidate.visibleFrame, frame);
        CGFloat area = NSWidth(overlap) * NSHeight(overlap);
        if (area > largestArea) {
            screen = candidate;
            largestArea = area;
        }
    }
    frame.size.width = std::max(frame.size.width, window.minSize.width);
    frame.size.height = std::max(frame.size.height, window.minSize.height);
    if (screen) {
        NSRect visible = screen.visibleFrame;
        frame.size.width = std::min(frame.size.width, NSWidth(visible));
        frame.size.height = std::min(frame.size.height, NSHeight(visible));
        frame.origin.x = std::clamp(frame.origin.x, NSMinX(visible), NSMaxX(visible) - NSWidth(frame));
        frame.origin.y = std::clamp(frame.origin.y, NSMinY(visible), NSMaxY(visible) - NSHeight(frame));
    }
    [window setFrame:frame display:NO];
}

static NSWindow *RestoreNativeTabs(NSArray<SourceDocument *> *tabs, SourceDocument *selected)
{
    NSWindow *previous = nil;
    for (SourceDocument *document in tabs) {
        if (!previous || ![document joinTabsInWindow:previous])
            [document makeWindowControllers];
        previous = document.editorHostWindow;
    }
    NSWindow *window = selected.editorHostWindow;
    if (window.tabGroup.windows.count > 1)
        window.tabGroup.selectedWindow = window;
    return window;
}

@implementation SourceDocumentController {
    BOOL _sessionWrittenForQuit;
}

- (NSURL *)sessionURL
{
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    NSURL *directory = [support URLByAppendingPathComponent:identifier ? identifier : @"local.source-editor" isDirectory:YES];
    return [directory URLByAppendingPathComponent:@"Session.plist" isDirectory:NO];
}

- (BOOL)writeSessionDiscarding:(NSSet<SourceDocument *> *)discarded error:(NSError **)error
{
    NSURL *url = self.sessionURL;
    if (!url) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey:@"The editor session could not be saved."}];
        return NO;
    }
    NSDictionary *session = @{@"version":@1, @"windows":CaptureSessionWindows(discarded)};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:session format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:error];
    return data && [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error] &&
           [data writeToURL:url options:NSDataWritingAtomic error:error];
}

- (BOOL)saveSessionForQuitDiscarding:(NSSet<SourceDocument *> *)discarded
{
    if (_sessionWrittenForQuit)
        return YES;
    NSError *error = nil;
    _sessionWrittenForQuit = [self writeSessionDiscarding:discarded error:&error];
    if (!_sessionWrittenForQuit && error)
        [NSApp presentError:error];
    return _sessionWrittenForQuit;
}

- (BOOL)hasEditedDocuments
{
    if ([super hasEditedDocuments])
        return YES;
    for (NSDocument *document in self.documents) {
        if ([document isKindOfClass:SourceDocument.class] && [(SourceDocument *)document needsCloseReview])
            return YES;
    }
    return NO;
}

- (void)reviewUnsavedDocumentsWithAlertTitle:(NSString *)title cancellable:(BOOL)cancellable delegate:(id)delegate
                       didReviewAllSelector:(SEL)selector contextInfo:(void *)context
{
    NSArray<NSDocument *> *documents = self.documents;
    for (NSDocument *document in documents) {
        if (![document isKindOfClass:SourceDocument.class]) {
            [super reviewUnsavedDocumentsWithAlertTitle:title cancellable:cancellable delegate:delegate
                                   didReviewAllSelector:selector contextInfo:context];
            return;
        }
    }
    ReviewDocumentsForClosing((NSArray<SourceDocument *> *)documents, ^(NSSet<SourceDocument *> *discarded) {
        // Record the layout and the confirmed saved files before AppKit closes the windows.
        BOOL quit = discarded && [self.documents isEqualToArray:documents] &&
                    [self saveSessionForQuitDiscarding:discarded];
        if (delegate && selector) {
            using ReviewFinished = void (*)(id, SEL, NSDocumentController *, BOOL, void *);
            auto finish = reinterpret_cast<ReviewFinished>([delegate methodForSelector:selector]);
            finish(delegate, selector, self, quit, context);
        }
    });
}

- (SourceDocument *)restoreDocument:(NSDictionary *)state inWorkspace:(FolderWorkspace *)workspace
{
    NSString *path = SessionString(state[@"path"]);
    NSString *text = SessionString(state[@"text"]);
    BOOL draft = text && [SessionNumber(state[@"draft"]) boolValue];
    NSURL *url = SessionPathURL(path);
    if (url && [self documentForURL:url])
        return nil;

    SourceDocument *document = nil;
    BOOL directory = NO;
    if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory] && !directory) {
        document = (SourceDocument *)[self makeDocumentWithContentsOfURL:url ofType:@"public.source-code" error:nil];
        if (draft && ![document canApplySessionDraft:state])
            document = nil;
    }
    BOOL recovered = path.length && !document;
    if (recovered && !draft)
        return nil;
    if (document) {
        [self addDocument:document];
        [NSFileCoordinator addFilePresenter:document];
    } else {
        document = (SourceDocument *)[self openUntitledDocumentAndDisplay:NO error:nil];
    }
    [document applySessionContents:state recoveredFile:recovered];
    document.workspace = workspace;
    return document;
}

- (void)restoreSession
{
    NSURL *url = self.sessionURL;
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data)
        return;
    NSDictionary *session = SessionDictionary([NSPropertyListSerialization propertyListWithData:data
                                                options:NSPropertyListImmutable format:nullptr error:nil]);
    NSArray *savedWindows = SessionArray(session[@"windows"]);
    if ([SessionNumber(session[@"version"]) integerValue] != 1 || !savedWindows.count)
        return;
    ImportSessionIndentationPreferences(savedWindows);

    struct RestoredWindow {
        NSWindow *window;
        BOOL minimized;
        BOOL outputShown;
        NSNumber *singleTabBar;
    };
    std::vector<RestoredWindow> windows;
    windows.reserve(savedWindows.count);
    NSMutableDictionary<NSString *, FolderWorkspace *> *workspaces = [NSMutableDictionary dictionary];
    NSMapTable<SourceDocument *, NSDictionary *> *views = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray<SourceDocument *> *drafts = [NSMutableArray array];
    BOOL automaticTabbing = NSWindow.allowsAutomaticWindowTabbing;
    NSWindow.allowsAutomaticWindowTabbing = NO;
    for (id entry in savedWindows) {
        NSDictionary *state = SessionDictionary(entry);
        NSArray *savedTabs = SessionArray(state[@"tabs"]);
        if (!savedTabs)
            continue;
        FolderWorkspace *workspace = RestoreSessionWorkspace(state, workspaces);
        NSMutableArray<SourceDocument *> *tabs = [NSMutableArray arrayWithCapacity:savedTabs.count];
        NSUInteger selectedIndex = [SessionNumber(state[@"selected"]) unsignedIntegerValue];
        SourceDocument *selected = nil;
        for (NSUInteger index = 0; index < savedTabs.count; ++index) {
            NSDictionary *saved = SessionDictionary(savedTabs[index]);
            SourceDocument *document = saved ? [self restoreDocument:saved inWorkspace:workspace] : nil;
            if (!document)
                continue;
            [tabs addObject:document];
            if (index == selectedIndex)
                selected = document;
            if (NSDictionary *view = SessionDictionary(saved[@"view"]))
                [views setObject:view forKey:document];
            if ([SessionNumber(saved[@"draft"]) boolValue] && SessionString(saved[@"text"]))
                [drafts addObject:document];
        }
        if (!tabs.count && !workspace)
            continue;
        if (!selected)
            selected = tabs.firstObject;
        NSWindow *window = workspace ? RestoreWorkspaceWindow(workspace, tabs, selected) : RestoreNativeTabs(tabs, selected);
        RestoreSessionWindowFrame(window, SessionString(state[@"frame"]));
        NSNumber *output = SessionNumber(state[@"output"]);
        if (!output && selected)
            output = SessionNumber([views objectForKey:selected][@"output"]);
        windows.push_back({window, [SessionNumber(state[@"minimized"]) boolValue], output.boolValue,
                           tabs.count == 1 ? SessionNumber(state[@"tabBar"]) : nil});
    }

    for (auto entry = windows.rbegin(); entry != windows.rend(); ++entry) {
        [entry->window orderFront:nil];
        if (entry->minimized)
            [entry->window miniaturize:nil];
    }
    NSWindow.allowsAutomaticWindowTabbing = automaticTabbing;
    NSWindow *active = nil;
    for (const RestoredWindow &entry : windows) {
        NSWindow *window = entry.window;
        NSNumber *tabBar = entry.singleTabBar;
        if (tabBar && tabBar.boolValue != EditorWindowShowsTabBar(window))
            [window toggleTabBar:nil];
        RestoreEditorWindowOutput(window, entry.outputShown);
        if (!active && !entry.minimized)
            active = window;
    }
    [active makeKeyAndOrderFront:nil];
    for (SourceDocument *document in views)
        [document applySessionView:[views objectForKey:document]];
    if (active.initialFirstResponder)
        [active makeFirstResponder:active.initialFirstResponder];
    for (SourceDocument *document in drafts)
        [document markSessionDraftEdited];
}

- (NSString *)typeForContentsOfURL:(NSURL *)url error:(NSError **)error
{
    (void)url;
    (void)error;
    return @"public.source-code";
}

- (void)beginOpenPanelWithCompletionHandler:(void (^)(NSArray<NSURL *> *))completion
{
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    NSWindow *window = self.activeEditorWindow;
    NSDocument *active = window.windowController.document;
    FolderWorkspace *workspace = WorkspaceForEditorWindow(window);
    panel.directoryURL = workspace ? workspace.folder : active.fileURL.URLByDeletingLastPathComponent;
    [panel beginWithCompletionHandler:^(NSModalResponse response) {
        [panel orderOut:nil];
        completion(response == NSModalResponseOK ? panel.URLs : nil);
    }];
}

- (NSWindow *)activeEditorWindow
{
    NSWindow *window = NSApp.mainWindow;
    if (WorkspaceForEditorWindow(window) || [window.windowController.document isKindOfClass:SourceDocument.class])
        return window;
    NSDocument *active = self.currentDocument;
    if (!active) {
        NSArray<NSDocument *> *open = self.documents;
        if (open.count == 1)
            active = open.firstObject;
    }
    return [active isKindOfClass:SourceDocument.class] ? [(SourceDocument *)active editorHostWindow] : nil;
}

- (void)showOpenedDocument:(SourceDocument *)document inWindow:(NSWindow *)window replacing:(SourceDocument *)placeholder
{
    BOOL replace = placeholder != document && placeholder.isUnusedUntitled && placeholder.workspace == document.workspace &&
                   [self.documents containsObject:placeholder];
    if (!document.editorHostWindow) {
        BOOL reused = replace && [document takeWindowFromUnusedDocument:placeholder];
        if (!reused && ![document joinTabsInWindow:window])
            [document makeWindowControllers];
    }
    [document showWindows];
    if (replace)
        [placeholder close];
}

- (void)openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)display
                   completionHandler:(void (^)(NSDocument *, BOOL, NSError *))completion
{
    if (!display) {
        [super openDocumentWithContentsOfURL:url display:display completionHandler:completion];
        return;
    }
    [self openSourceURL:url inWindow:self.activeEditorWindow completionHandler:completion];
}

- (FolderWorkspace *)workspaceForFile:(NSURL *)file preferred:(FolderWorkspace *)preferred
{
    if (PathIsInFolder(file.path, preferred.folder.path))
        return preferred;
    FolderWorkspace *nearest = nil;
    for (NSWindow *window in NSApp.windows) {
        FolderWorkspace *workspace = WorkspaceForEditorWindow(window);
        if (workspace.folder.path.length > nearest.folder.path.length &&
            PathIsInFolder(file.path, workspace.folder.path))
            nearest = workspace;
    }
    return nearest;
}

- (void)openSourceURL:(NSURL *)url inWindow:(NSWindow *)anchor completionHandler:(SourceOpenCompletion)completion
{
    if (url.isFileURL)
        url = CanonicalFileURL(url);
    BOOL directory = NO;
    if (url.isFileURL && [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory] && directory) {
        NSError *error = nil;
        NSWindow *window = [self openFolderAtURL:url inWindow:anchor error:&error];
        completion(window.windowController.document, NO, error);
        return;
    }
    FolderWorkspace *preferred = WorkspaceForEditorWindow(anchor);
    FolderWorkspace *workspace = [self workspaceForFile:url preferred:preferred];
    NSWindow *window = preferred == workspace ? anchor : workspace.selectedDocument.editorHostWindow;
    if (!window && workspace) {
        for (NSWindow *candidate in NSApp.windows) {
            if (WorkspaceForEditorWindow(candidate) == workspace) {
                window = candidate;
                break;
            }
        }
    }
    SourceDocument *host = window.windowController.document;
    SourceDocument *placeholder = host.isUnusedUntitled ? host : nil;

    // Read the file before changing the untitled window. A failed open leaves it intact.
    [super openDocumentWithContentsOfURL:url display:NO
                       completionHandler:^(NSDocument *document, BOOL alreadyOpen, NSError *error) {
        if ([document isKindOfClass:SourceDocument.class]) {
            SourceDocument *source = (SourceDocument *)document;
            if (!alreadyOpen || (workspace && source.workspace != workspace)) {
                BOOL moveOpenTab = source.editorHostWindow != nil && source.workspace != workspace;
                source.workspace = workspace;
                if (moveOpenTab && workspace && WorkspaceForEditorWindow(window) == workspace &&
                    window != source.editorHostWindow && !window.attachedSheet) {
                    [source joinTabsInWindow:window];
                }
            }
            [self showOpenedDocument:source inWindow:window replacing:placeholder];
        }
        completion(document, alreadyOpen, error);
    }];
}

- (NSWindow *)openFolderAtURL:(NSURL *)url inWindow:(NSWindow *)anchor error:(NSError **)error
{
    NSURL *folder = CanonicalFileURL(url);
    BOOL directory = NO;
    if (!folder || ![NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&directory] || !directory) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError
                                     userInfo:@{NSLocalizedDescriptionKey:@"The folder could not be opened."}];
        return nil;
    }
    for (NSWindow *window in NSApp.windows) {
        FolderWorkspace *workspace = WorkspaceForEditorWindow(window);
        if ([workspace.folder.path isEqualToString:folder.path]) {
            workspace.sidebarShown = YES;
            NSWindow *target = WorkspaceForEditorWindow(anchor) == workspace ? anchor : workspace.selectedDocument.editorHostWindow;
            if (!target)
                target = window;
            [target makeKeyAndOrderFront:nil];
            return target;
        }
    }
    SourceDocument *active = anchor.windowController.document;
    BOOL inFolder = PathIsInFolder(CanonicalFileURL(active.fileURL).path, folder.path);
    BOOL canReuse = !active.workspace && active.editorHostWindow && !anchor.attachedSheet &&
                    (active.isUnusedUntitled || inFolder);
    SourceDocument *document = canReuse ? active :
        (SourceDocument *)[self openUntitledDocumentAndDisplay:NO error:error];
    if (document) {
        document.workspace = [[FolderWorkspace alloc] initWithFolder:folder];
        if (!document.editorHostWindow)
            [document makeWindowControllers];
        [document showWindows];
    }
    return document.editorHostWindow;
}

@end

static NSMenuItem *PaletteItem(NSString *title, SEL action, id target, NSInteger tag = 0, NSString *aliases = nil)
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = target;
    item.tag = tag;
    item.representedObject = aliases;
    return item;
}

static NSMenuItem *PaletteToggle(NSString *title, SEL action, id target, bool checked)
{
    NSMenuItem *item = PaletteItem(title, action, target);
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

static void AddMenuCommands(NSMutableArray<NSMenuItem *> *commands, NSMenu *menu, NSString *category)
{
    for (NSMenuItem *item in menu.itemArray) {
        if (item.hidden || item.isSeparatorItem)
            continue;
        if (item.submenu) {
            if (![item.title isEqualToString:@"Theme"])
                AddMenuCommands(commands, item.submenu, category);
            continue;
        }
        if (!item.action || item.action == @selector(showCommandPalette:) || item.action == @selector(showFonts:) ||
            item.action == @selector(makeKeyAndOrderFront:))
            continue;
        id target = [NSApp targetForAction:item.action to:item.target from:item];
        if (!target)
            continue;
        NSMenuItem *command = [item copy];
        command.target = target;
        if ([target respondsToSelector:@selector(validateMenuItem:)] && ![target validateMenuItem:command])
            continue;
        if (![target respondsToSelector:@selector(validateMenuItem:)] &&
            [target respondsToSelector:@selector(validateUserInterfaceItem:)] && ![target validateUserInterfaceItem:command])
            continue;
        command.enabled = YES;
        command.title = [NSString stringWithFormat:@"%@: %@", category, command.title];
        [commands addObject:command];
    }
}

@implementation ApplicationDelegate {
    SourceDocumentController *_documents;
    PreferencesController *_preferences;
    CommandPalette *_palette;
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    PopulateThemeMenu(menu, @selector(selectTheme:));
}

- (SourceDocument *)debugDocument
{
    if (NSApp.modalWindow)
        return nil;
    NSWindow *window = _documents.activeEditorWindow;
    NSDocument *document = window.windowController.document;
    return [document isKindOfClass:SourceDocument.class] ? (SourceDocument *)document : nil;
}

- (IBAction)debugCommand:(NSMenuItem *)sender
{
    [self.debugDocument debugCommand:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(debugCommand:))
        return [self.debugDocument validateMenuItem:item];
    if (item.action == @selector(toggleAutoSave:))
        item.state = AutoSavePreference().mode == AutoSaveMode::Off ? NSControlStateValueOff : NSControlStateValueOn;
    if (item.action == @selector(showCommandPalette:)) {
        NSWindow *window = _documents.activeEditorWindow;
        return CommandPaletteHost(window) && !window.attachedSheet;
    }
    if (item.action == @selector(closeWindow:))
        return EditorWindowTabs(NSApp.keyWindow) && !NSApp.keyWindow.attachedSheet;
    if (item.action == @selector(findInFiles:) || item.action == @selector(replaceInFiles:))
        return !NSApp.modalWindow && !_documents.activeEditorWindow.attachedSheet;
    return YES;
}

- (IBAction)closeWindow:(id)sender
{
    (void)sender;
    RequestEditorWindowClose(NSApp.keyWindow);
}

- (IBAction)toggleAutoSave:(id)sender
{
    (void)sender;
    AutoSaveSettings settings = AutoSavePreference();
    settings.mode = settings.mode == AutoSaveMode::Off ? AutoSaveMode::AfterDelay : AutoSaveMode::Off;
    SetAutoSavePreference(settings);
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    ApplyWindowAppearancePreference();
    _documents = [[SourceDocumentController alloc] init];
    SetUpMenus();
    [_documents restoreSession];
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)application
{
    for (NSWindow *window in application.windows) {
        if (EditorWindowTabs(window))
            return NO;
    }
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)application
{
    if (![_documents saveSessionForQuitDiscarding:nil])
        return NSTerminateCancel;

    dispatch_group_t jobs = dispatch_group_create();
    dispatch_group_enter(jobs);
    bool stoppingRuns = StopSourceRunsForQuit(^{ dispatch_group_leave(jobs); });
    if (!stoppingRuns)
        dispatch_group_leave(jobs);
    dispatch_group_enter(jobs);
    bool stoppingDebuggers = StopDebugSessionsForQuit(^{ dispatch_group_leave(jobs); });
    if (!stoppingDebuggers)
        dispatch_group_leave(jobs);
    if (!stoppingRuns && !stoppingDebuggers)
        return NSTerminateNow;

    dispatch_group_notify(jobs, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // AppKit waits in its modal run loop after NSTerminateLater.
        CFRunLoopRef mainLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainLoop, (__bridge CFArrayRef)@[NSDefaultRunLoopMode, NSModalPanelRunLoopMode], ^{
            [application replyToApplicationShouldTerminate:YES];
        });
        CFRunLoopWakeUp(mainLoop);
    });
    return NSTerminateLater;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)application
{
    (void)application;
    return YES;
}

- (IBAction)showPreferences:(id)sender
{
    if (!_preferences)
        _preferences = [[PreferencesController alloc] init];
    [_preferences showWindow:sender];
}

- (IBAction)showPreferencesPane:(NSMenuItem *)sender
{
    static NSArray<NSString *> *panes = @[@"Appearance", @"Rendering", @"Editing", @"Files", @"Output"];
    if (sender.tag < 0 || sender.tag >= NSInteger(panes.count))
        return;
    if (!_preferences)
        _preferences = [[PreferencesController alloc] init];
    [_preferences showPane:panes[sender.tag]];
}

- (IBAction)toggleSmoothScrolling:(id)sender
{
    (void)sender;
    SetEditorPreference(smoothScrollingKey, @(!SmoothScrollingPreference()));
}

- (IBAction)toggleBracketColorization:(id)sender
{
    (void)sender;
    SetEditorPreference(bracketColorizationKey, @(!BracketColorizationPreference()));
}

- (IBAction)toggleIndentationDetection:(id)sender
{
    (void)sender;
    auto settings = IndentationPreference();
    settings.detect = !settings.detect;
    SetIndentationPreference(settings);
}

- (IBAction)selectPaletteTheme:(NSMenuItem *)sender { SelectEditorTheme(sender.tag); }

- (IBAction)selectWhitespaceMode:(NSMenuItem *)sender
{
    auto settings = RenderingPreference();
    settings.whitespace = WhitespaceMode(sender.tag);
    SetRenderingPreference(settings);
}

- (IBAction)selectAutoSaveMode:(NSMenuItem *)sender
{
    auto settings = AutoSavePreference();
    settings.mode = AutoSaveMode(sender.tag);
    SetAutoSavePreference(settings);
}

- (IBAction)toggleTrimTrailingWhitespace:(id)sender
{
    (void)sender;
    auto settings = SaveCleanupPreference();
    settings.trimTrailingWhitespace = !settings.trimTrailingWhitespace;
    SetSaveCleanupPreference(settings);
}

- (IBAction)selectFinalNewlineMode:(NSMenuItem *)sender
{
    auto settings = SaveCleanupPreference();
    settings.finalNewline = FinalNewlineMode(sender.tag);
    SetSaveCleanupPreference(settings);
}

- (IBAction)resetRendering:(id)sender
{
    (void)sender;
    SetRenderingPreference({});
}

- (void)presentPalette:(NSArray<NSMenuItem *> *)items inWindow:(NSWindow *)window
                prompt:(NSString *)prompt mode:(CommandPaletteMode)mode rowLimit:(NSUInteger)rowLimit
         previewThemes:(BOOL)previewThemes
{
    NSView *host = CommandPaletteHost(window);
    if (!host || window.attachedSheet)
        return;
    if (!_palette)
        _palette = [[CommandPalette alloc] initWithFrame:NSZeroRect];
    CommandPreview preview = nil;
    if (previewThemes) {
        __weak NSView *previewHost = host;
        preview = ^(NSMenuItem *item) {
            PreviewEditorTheme(previewHost, item ? item.tag : -1);
        };
    }
    [window makeKeyAndOrderFront:nil];
    [_palette presentInView:host items:items placeholder:prompt mode:mode rowLimit:rowLimit preview:preview];
}

- (IBAction)showPalettePage:(NSMenuItem *)sender
{
    NSWindow *window = _documents.activeEditorWindow;
    SourceDocument *document = window.windowController.document;
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
    NSString *prompt = nil;
    NSUInteger rowLimit = defaultCommandPaletteRows;
    auto page = PalettePage(sender.tag);
    switch (page) {
        case PalettePage::Theme: {
            NSMenu *themesMenu = [[NSMenu alloc] initWithTitle:@"Color Theme"];
            PopulateThemeMenu(themesMenu, @selector(selectPaletteTheme:));
            for (NSMenuItem *entry in themesMenu.itemArray) {
                if (!entry.action)
                    continue;
                [items addObject:PaletteItem(entry.title, entry.action, self, entry.tag)];
                items.lastObject.state = entry.tag == ThemePreference() ? NSControlStateValueOn : NSControlStateValueOff;
            }
            prompt = @"Select a Color Theme";
            break;
        }
        case PalettePage::TabSize:
        case PalettePage::MoreTabSizes: {
            if (!document)
                return;
            BOOL largerSizes = PalettePage(sender.tag) == PalettePage::MoreTabSizes;
            [items addObjectsFromArray:TabSizeItems(document.tabSize, document, @selector(setTabSize:), largerSizes)];
            if (!largerSizes) {
                [items addObject:PaletteItem(@"More…", @selector(showPalettePage:), self, NSInteger(PalettePage::MoreTabSizes))];
                rowLimit = items.count;
            }
            prompt = largerSizes ? @"More Tab Sizes" : @"Select Tab Size";
            break;
        }
        case PalettePage::Language: {
            if (!document)
                return;
            [items addObject:PaletteItem(@"Auto Detect", @selector(changeLanguageMode:), document, -1)];
            items.lastObject.state = document.automaticLanguageMode ? NSControlStateValueOn : NSControlStateValueOff;
            NSArray<NSString *> *names = EditorLanguageNames();
            for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
                [items addObject:PaletteItem(name, @selector(changeLanguageMode:), document, [names indexOfObject:name])];
                items.lastObject.state = !document.automaticLanguageMode && items.lastObject.tag == document.languageMode ?
                    NSControlStateValueOn : NSControlStateValueOff;
            }
            prompt = @"Select Language Mode";
            break;
        }
        case PalettePage::Whitespace: {
            auto mode = RenderingPreference().whitespace;
            for (NSString *name in @[@"None", @"Boundary", @"Selection", @"Trailing", @"All"]) {
                [items addObject:PaletteItem(name, @selector(selectWhitespaceMode:), self, NSInteger(items.count))];
                items.lastObject.state = items.lastObject.tag == NSInteger(mode) ? NSControlStateValueOn : NSControlStateValueOff;
            }
            prompt = @"Render Whitespace";
            break;
        }
        case PalettePage::AutoSave: {
            auto mode = AutoSavePreference().mode;
            for (NSString *name in @[@"Off", @"After Delay", @"On Focus Change", @"On Window Change"]) {
                [items addObject:PaletteItem(name, @selector(selectAutoSaveMode:), self, NSInteger(items.count))];
                items.lastObject.state = items.lastObject.tag == NSInteger(mode) ? NSControlStateValueOn : NSControlStateValueOff;
            }
            prompt = @"Auto Save";
            break;
        }
        case PalettePage::FinalNewline: {
            auto mode = SaveCleanupPreference().finalNewline;
            for (NSString *name in FinalNewlineModeNames()) {
                [items addObject:PaletteItem(name, @selector(selectFinalNewlineMode:), self, NSInteger(items.count))];
                items.lastObject.state = items.lastObject.tag == NSInteger(mode) ? NSControlStateValueOn : NSControlStateValueOff;
            }
            prompt = @"Final Newline on Save";
            break;
        }
    }
    [self presentPalette:items inWindow:window prompt:prompt mode:CommandPaletteMode::Choices rowLimit:rowLimit
          previewThemes:page == PalettePage::Theme];
}

- (IBAction)showCommandPalette:(id)sender
{
    (void)sender;
    if (_palette.superview) {
        [_palette dismiss];
        return;
    }
    NSWindow *window = _documents.activeEditorWindow;
    if (!CommandPaletteHost(window) || window.attachedSheet)
        return;
    SourceDocument *document = window.windowController.document;
    NSMutableArray<NSMenuItem *> *commands = [NSMutableArray arrayWithArray:@[
        PaletteItem(@"Open Settings…", @selector(showPreferences:), self, 0, @"Open Preferences Prefs"),
        PaletteItem(@"Appearance Settings", @selector(showPreferencesPane:), self, 0, @"Appearance Preferences Window Appearance"),
        PaletteItem(@"Rendering Settings", @selector(showPreferencesPane:), self, 1, @"Rendering Preferences"),
        PaletteItem(@"Editing Settings", @selector(showPreferencesPane:), self, 2, @"Editing Preferences Editor Settings"),
        PaletteItem(@"File Settings", @selector(showPreferencesPane:), self, 3, @"Files Preferences File Preferences Files Settings"),
        PaletteItem(@"Output Settings", @selector(showPreferencesPane:), self, 4, @"Output Preferences Scrollback"),
        PaletteItem(@"Color Theme…", @selector(showPalettePage:), self, NSInteger(PalettePage::Theme)),
        PaletteItem(@"Choose Editor Font…", @selector(showFonts:), self, 0, @"Open Fonts Show Fonts Font Settings"),
    ]];
    if (document) {
        [commands addObject:PaletteItem(@"Change Tab Size…", @selector(showPalettePage:), self, NSInteger(PalettePage::TabSize))];
        [commands addObjectsFromArray:FileIndentationCommands(document)];
        [commands addObject:PaletteItem(@"Change Language Mode…", @selector(showPalettePage:), self, NSInteger(PalettePage::Language))];
    }
    [commands addObjectsFromArray:@[
        PaletteItem(@"Render Whitespace…", @selector(showPalettePage:), self, NSInteger(PalettePage::Whitespace)),
        PaletteItem(@"Auto Save Mode…", @selector(showPalettePage:), self, NSInteger(PalettePage::AutoSave)),
        PaletteItem(@"Final Newline on Save…", @selector(showPalettePage:), self, NSInteger(PalettePage::FinalNewline)),
        PaletteToggle(@"Toggle Smooth Scrolling", @selector(toggleSmoothScrolling:), self, SmoothScrollingPreference()),
        PaletteToggle(@"Toggle Bracket Pair Colorization", @selector(toggleBracketColorization:), self, BracketColorizationPreference()),
        PaletteToggle(@"Toggle Detect Indentation", @selector(toggleIndentationDetection:), self, IndentationPreference().detect),
        PaletteItem(@"Reset Rendering", @selector(resetRendering:), self),
        PaletteToggle(@"Trim Trailing Whitespace on Save", @selector(toggleTrimTrailingWhitespace:), self, SaveCleanupPreference().trimTrailingWhitespace),
    ]];
    for (NSString *section in @[@"File", @"Edit", @"Selection", @"View", @"Window"])
        AddMenuCommands(commands, [NSApp.mainMenu itemWithTitle:section].submenu, section);
    [self presentPalette:commands inWindow:window prompt:@"Type a command" mode:CommandPaletteMode::Commands
                rowLimit:defaultCommandPaletteRows previewThemes:NO];
}

- (IBAction)showFonts:(id)sender
{
    [NSFontManager.sharedFontManager orderFrontFontPanel:sender];
}

- (IBAction)newWindowForTab:(id)sender
{
    NSWindow *window = [sender isKindOfClass:NSWindow.class] ? sender : _documents.activeEditorWindow;
    NSError *error = nil;
    SourceDocument *document = (SourceDocument *)[_documents openUntitledDocumentAndDisplay:NO error:&error];
    if (!document) {
        if (error)
            [NSApp presentError:error];
        return;
    }
    document.workspace = WorkspaceForEditorWindow(window);
    if (![document joinTabsInWindow:window])
        [document makeWindowControllers];
    [document showWindows];
}

- (void)chooseFolderInWindow:(NSWindow *)window completion:(void (^)(NSWindow *))completion
{
    NSDocument *active = window.windowController.document;
    FolderWorkspace *workspace = WorkspaceForEditorWindow(window);
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = workspace ? workspace.folder : active.fileURL.URLByDeletingLastPathComponent;
    [panel beginWithCompletionHandler:^(NSModalResponse response) {
        [panel orderOut:nil];
        if (response == NSModalResponseOK) {
            NSError *error = nil;
            NSWindow *opened = [self->_documents openFolderAtURL:panel.URL inWindow:window error:&error];
            if (opened && completion)
                completion(opened);
            else if (error)
                [NSApp presentError:error];
        }
    }];
}

- (IBAction)openFolder:(id)sender
{
    (void)sender;
    [self chooseFolderInWindow:_documents.activeEditorWindow completion:nil];
}

- (void)showFolderSearchReplacing:(BOOL)replace
{
    NSWindow *window = _documents.activeEditorWindow;
    if (window.attachedSheet || NSApp.modalWindow || ShowFolderSearch(window, replace))
        return;
    [self chooseFolderInWindow:window completion:^(NSWindow *opened) { ShowFolderSearch(opened, replace); }];
}

- (IBAction)findInFiles:(id)sender
{
    (void)sender;
    [self showFolderSearchReplacing:NO];
}

- (IBAction)replaceInFiles:(id)sender
{
    (void)sender;
    [self showFolderSearchReplacing:YES];
}

- (IBAction)openExample:(id)sender
{
    (void)sender;
    NSWindow *window = _documents.activeEditorWindow;
    SourceDocument *active = window.windowController.document;
    SourceDocument *placeholder = active.isUnusedUntitled ? active : nil;
    NSError *error = nil;
    SourceDocument *document = (SourceDocument *)[_documents openUntitledDocumentAndDisplay:NO error:&error];
    if (!document) {
        if (error)
            [NSApp presentError:error];
        return;
    }
    [document loadExample];
    document.workspace = WorkspaceForEditorWindow(window);
    [_documents showOpenedDocument:document inWindow:window replacing:placeholder];
}

@end

int main()
{
    @autoreleasepool {
        [NSFontManager setFontManagerFactory:EditorFontManager.class];
        NSApplication *application = NSApplication.sharedApplication;
        ApplicationDelegate *delegate = [[ApplicationDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}