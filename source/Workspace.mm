#import "Workspace.h"
#import "Editor.h"
#import "Preferences.h"
#import <CoreServices/CoreServices.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <fcntl.h>
#include <span>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

NSNotificationName const FolderSidebarChanged = @"FolderSidebarChanged";
NSNotificationName const FolderDocumentsChanged = @"FolderDocumentsChanged";
NSNotificationName const FolderRunChanged = @"FolderRunChanged";
static NSNotificationName const FolderContentsChanged = @"FolderContentsChanged";
static NSPasteboardType const FolderItemDragType = @"local.retina-code.explorer-item";

@interface FolderEntry : NSObject
@property(nonatomic) NSURL *url;
@property(nonatomic) BOOL directory;
@property(nonatomic) BOOL expandable;
@property(nonatomic) NSArray<FolderEntry *> *children;
@property(nonatomic) NSImage *icon;
@end

@implementation FolderEntry
@end

@interface FolderWorkspace ()
@property(nonatomic, readonly) FolderEntry *root;
@property(nonatomic, readonly) NSMutableSet<NSString *> *expandedPaths;
- (NSArray<FolderEntry *> *)childrenOf:(FolderEntry *)entry;
- (void)refreshDirectories:(NSArray<NSURL *> *)directories;
- (void)moveExpandedPathsFrom:(NSURL *)oldURL to:(NSURL *)newURL;
- (void)didChangePaths:(NSArray<NSString *> *)paths flags:(const FSEventStreamEventFlags *)flags;
@end

static void FolderEvents(ConstFSEventStreamRef, void *info, size_t, void *paths,
                         const FSEventStreamEventFlags flags[], const FSEventStreamEventId[])
{
    FolderWorkspace *workspace = (__bridge FolderWorkspace *)info;
    [workspace didChangePaths:(__bridge NSArray<NSString *> *)paths flags:flags];
}

@implementation FolderWorkspace {
    NSHashTable<SourceDocument *> *_documents;
    NSMapTable<NSString *, FolderEntry *> *_loadedFolders;
    FSEventStreamRef _stream;
}

- (instancetype)initWithFolder:(NSURL *)folder
{
    self = [super init];
    if (!self)
        return nil;
    _folder = CanonicalFileURL(folder);
    _tabbingIdentifier = [@"RetinaCodeFolder:" stringByAppendingString:_folder.path];
    _sidebarWidth = 212;
    _sidebarShown = YES;
    _documents = [NSHashTable weakObjectsHashTable];
    _loadedFolders = [NSMapTable strongToWeakObjectsMapTable];
    _expandedPaths = [[NSMutableSet alloc] init];

    _root = [[FolderEntry alloc] init];
    _root.url = _folder;
    _root.directory = YES;
    _root.expandable = YES;

    FSEventStreamContext context = {0, (__bridge void *)self, nullptr, nullptr, nullptr};
    _stream = FSEventStreamCreate(kCFAllocatorDefault, FolderEvents, &context,
        (__bridge CFArrayRef)@[_folder.path], kFSEventStreamEventIdSinceNow, 0.18,
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot);
    if (_stream) {
        FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
        if (!FSEventStreamStart(_stream)) {
            FSEventStreamInvalidate(_stream);
            FSEventStreamRelease(_stream);
            _stream = nullptr;
        }
    }
    return self;
}

- (void)dealloc
{
    if (_stream) {
        FSEventStreamStop(_stream);
        FSEventStreamInvalidate(_stream);
        FSEventStreamRelease(_stream);
    }
}

- (NSArray<SourceDocument *> *)documents { return _documents.allObjects; }

- (NSArray<NSString *> *)sessionExpandedFolders { return _expandedPaths.allObjects; }

- (void)restoreSessionExpandedFolders:(NSArray *)paths
{
    [_expandedPaths removeAllObjects];
    for (id path in paths) {
        if ([path isKindOfClass:NSString.class] && PathIsInFolder(path, _folder.path))
            [_expandedPaths addObject:path];
    }
}

- (void)addDocument:(SourceDocument *)document
{
    [_documents addObject:document];
    [self documentChanged];
}

- (void)removeDocument:(SourceDocument *)document
{
    if (_selectedDocument == document)
        _selectedDocument = nil;
    if (_runningDocument == document)
        self.runningDocument = nil;
    [_documents removeObject:document];
    [self documentChanged];
}

- (void)documentChanged
{
    [NSNotificationCenter.defaultCenter postNotificationName:FolderDocumentsChanged object:self];
}

- (void)setSidebarShown:(BOOL)shown
{
    if (_sidebarShown == shown)
        return;
    _sidebarShown = shown;
    [NSNotificationCenter.defaultCenter postNotificationName:FolderSidebarChanged object:self];
}

- (void)setRunningDocument:(SourceDocument *)document
{
    if (_runningDocument == document)
        return;
    _runningDocument = document;
    [NSNotificationCenter.defaultCenter postNotificationName:FolderRunChanged object:self];
}

- (BOOL)readChildrenOf:(FolderEntry *)folder
{
    NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsPackageKey];
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder.url
         includingPropertiesForKeys:keys options:0 error:nil];
    NSMutableDictionary<NSString *, FolderEntry *> *existing = [NSMutableDictionary dictionary];
    for (FolderEntry *entry in folder.children)
        existing[entry.url.lastPathComponent] = entry;

    NSMutableArray<FolderEntry *> *children = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSString *name = url.lastPathComponent;
        if (HiddenWorkspaceItem(name))
            continue;
        NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
        BOOL directory = [values[NSURLIsDirectoryKey] boolValue];
        BOOL link = [values[NSURLIsSymbolicLinkKey] boolValue];
        if (link)
            [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory];
        BOOL expandable = directory && !link && ![values[NSURLIsPackageKey] boolValue];
        FolderEntry *entry = existing[name];
        if (!entry || entry.directory != directory || entry.expandable != expandable) {
            entry = [[FolderEntry alloc] init];
            entry.url = url;
            entry.directory = directory;
            entry.expandable = expandable;
        }
        [children addObject:entry];
    }
    [children sortUsingComparator:^NSComparisonResult(FolderEntry *a, FolderEntry *b) {
        if (a.directory != b.directory)
            return a.directory ? NSOrderedAscending : NSOrderedDescending;
        return [a.url.lastPathComponent localizedStandardCompare:b.url.lastPathComponent];
    }];
    if ([folder.children isEqualToArray:children])
        return NO;
    folder.children = children;
    return YES;
}

- (NSArray<FolderEntry *> *)childrenOf:(FolderEntry *)entry
{
    FolderEntry *folder = entry ? entry : self.root;
    if (!folder.children && folder.expandable) {
        [self readChildrenOf:folder];
        [_loadedFolders setObject:folder forKey:folder.url.path];
    }
    return folder.children;
}

- (void)refreshFolders:(NSArray<FolderEntry *> *)folders
{
    BOOL changed = NO;
    for (FolderEntry *folder in folders)
        changed |= [self readChildrenOf:folder];
    if (changed)
        [NSNotificationCenter.defaultCenter postNotificationName:FolderContentsChanged object:self];
}

- (void)refresh
{
    [self refreshFolders:_loadedFolders.objectEnumerator.allObjects];
}

- (void)refreshDirectories:(NSArray<NSURL *> *)directories
{
    NSMutableSet<FolderEntry *> *folders = [NSMutableSet set];
    for (NSURL *directory in directories) {
        FolderEntry *entry = [_loadedFolders objectForKey:directory.path];
        if (entry)
            [folders addObject:entry];
    }
    [self refreshFolders:folders.allObjects];
}

- (void)moveExpandedPathsFrom:(NSURL *)oldURL to:(NSURL *)newURL
{
    for (NSString *path in _expandedPaths.allObjects) {
        if (!PathIsInFolder(path, oldURL.path))
            continue;
        [_expandedPaths removeObject:path];
        if (newURL)
            [_expandedPaths addObject:[newURL.path stringByAppendingString:[path substringFromIndex:oldURL.path.length]]];
    }
}

- (void)didChangePaths:(NSArray<NSString *> *)paths flags:(const FSEventStreamEventFlags *)flags
{
    NSMutableSet<FolderEntry *> *pending = [NSMutableSet set];
    for (NSUInteger i = 0; i < paths.count; ++i) {
        if (flags[i] & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)) {
            [self refresh];
            return;
        }
        NSString *path = paths[i].stringByStandardizingPath;
        FolderEntry *folder = [_loadedFolders objectForKey:path];
        if (folder)
            [pending addObject:folder];
        FolderEntry *parent = [_loadedFolders objectForKey:path.stringByDeletingLastPathComponent];
        if (parent)
            [pending addObject:parent];
    }
    [self refreshFolders:pending.allObjects];
}

@end

struct ExplorerDragItem {
    FolderEntry *entry;
    id fileIdentifier;
};

struct ExplorerMove {
    NSURL *source;
    NSURL *destination;
    id fileIdentifier;
    bool subtree;
    bool moved = false;
};

@interface FolderOutline : NSOutlineView {
@public
    std::vector<ExplorerDragItem> _draggedItems;
}
@property(nonatomic, weak) FolderWorkspace *workspace;
@property(nonatomic, copy) void (^openSelection)(void);
@property(nonatomic, copy) void (^renameSelection)(void);
@property(nonatomic, copy) void (^trashSelection)(void);
@property(nonatomic, copy) NSMenu *(^menuForRow)(NSInteger row);
@end

@implementation FolderOutline

- (BOOL)shouldCollapseAutoExpandedItemsForDeposited:(BOOL)deposited
{
    return !deposited;
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row >= 0)
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    return self.menuForRow ? self.menuForRow(row) : nil;
}

- (void)keyDown:(NSEvent *)event
{
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length == 1 ? [characters characterAtIndex:0] : 0;
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                                              NSEventModifierFlagControl | NSEventModifierFlagOption);
    if (self.selectedRow < 0) {
        [super keyDown:event];
        return;
    }
    if (!modifiers && (key == NSCarriageReturnCharacter || key == NSEnterCharacter || key == NSF2FunctionKey)) {
        if (self.renameSelection)
            self.renameSelection();
    } else if (modifiers == NSEventModifierFlagCommand && key == NSDownArrowFunctionKey) {
        if (self.openSelection)
            self.openSelection();
    } else if ((modifiers == NSEventModifierFlagCommand && (key == NSDeleteCharacter || key == NSBackspaceCharacter)) ||
               (!modifiers && key == NSDeleteFunctionKey)) {
        if (self.trashSelection)
            self.trashSelection();
    } else {
        [super keyDown:event];
    }
}
@end

@interface FolderCell : NSTableCellView
@property(nonatomic) BOOL edited;
- (instancetype)initWithIcon:(BOOL)icon;
@end

@implementation FolderCell {
    NSView *_dot;
}

- (instancetype)initWithIcon:(BOOL)icon
{
    self = [super initWithFrame:NSZeroRect];
    if (!self)
        return nil;
    if (icon) {
        NSImageView *image = [[NSImageView alloc] initWithFrame:NSZeroRect];
        image.imageScaling = NSImageScaleProportionallyDown;
        [self addSubview:image];
        self.imageView = image;
    }
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [NSFont systemFontOfSize:12];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.usesSingleLineMode = YES;
    label.maximumNumberOfLines = 1;
    [self addSubview:label];
    self.textField = label;
    if (icon) {
        _dot = [[NSView alloc] initWithFrame:NSZeroRect];
        _dot.wantsLayer = YES;
        _dot.layer.cornerRadius = 2.5;
        _dot.hidden = YES;
        [self addSubview:_dot];
    }
    return self;
}

- (void)setEdited:(BOOL)edited
{
    _edited = edited;
    _dot.hidden = !edited;
    self.accessibilityValue = edited ? @"Modified" : nil;
    if (edited)
        _dot.layer.backgroundColor = NSColor.secondaryLabelColor.CGColor;
    self.needsLayout = YES;
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    _dot.layer.backgroundColor = NSColor.secondaryLabelColor.CGColor;
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    CGFloat start = self.imageView ? 21 : 0;
    self.imageView.frame = NSMakeRect(1, floor((height - 16) / 2), 16, 16);
    CGFloat labelHeight = ceil(self.textField.intrinsicContentSize.height);
    self.textField.frame = NSMakeRect(start, floor((height - labelHeight) / 2),
                                      std::max<CGFloat>(0, width - start - 10), labelHeight);
    _dot.frame = NSMakeRect(std::max<CGFloat>(0, width - 6), floor((height - 5) / 2), 5, 5);
}

@end

enum class ExplorerEdit { None, NewFile, NewFolder, Rename };

static NSError *ExplorerError(NSURL *url, NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:NSCocoaErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey:description, NSURLErrorKey:url}];
}

static NSError *ValidateExplorerName(NSString *name, NSURL *folder)
{
    if (![name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
        return ExplorerError(folder, NSFileWriteInvalidFileNameError, @"Enter a name.");
    const unichar zero = 0;
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"] ||
        [name containsString:[NSString stringWithCharacters:&zero length:1]])
        return ExplorerError(folder, NSFileWriteInvalidFileNameError, @"Enter a single name without a slash.");
    return nil;
}

static id ExplorerFileIdentifier(NSURL *url)
{
    NSURL *file = [NSURL fileURLWithPath:url.path isDirectory:url.hasDirectoryPath];
    id identifier = nil;
    [file getResourceValue:&identifier forKey:NSURLFileResourceIdentifierKey error:nil];
    return identifier;
}

static BOOL ExplorerItemIsSubtree(FolderEntry *item)
{
    if (!item.directory)
        return NO;
    NSNumber *link = nil;
    [item.url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    return !link.boolValue;
}

static BOOL MatchesExplorerItem(NSURL *file, NSURL *item, BOOL includesChildren)
{
    NSString *path = file.URLByStandardizingPath.path;
    return includesChildren ? PathIsInFolder(path, item.path) : [path isEqualToString:item.path];
}

static NSArray<SourceDocument *> *DocumentsForExplorerItem(NSURL *item, BOOL includesChildren)
{
    NSMutableArray<SourceDocument *> *matches = [NSMutableArray array];
    for (NSDocument *document in NSDocumentController.sharedDocumentController.documents) {
        if ([document isKindOfClass:SourceDocument.class] && MatchesExplorerItem(document.fileURL, item, includesChildren))
            [matches addObject:(SourceDocument *)document];
    }
    return matches;
}

static void RefreshDocumentWorkspaces(NSArray<SourceDocument *> *documents)
{
    NSMutableSet<FolderWorkspace *> *workspaces = [NSMutableSet set];
    for (SourceDocument *document in documents) {
        if (document.workspace)
            [workspaces addObject:document.workspace];
    }
    for (FolderWorkspace *workspace in workspaces)
        [workspace documentChanged];
}

static void WithDocumentFileAccess(NSArray<SourceDocument *> *documents, NSUInteger index, void (^access)(void))
{
    if (index == documents.count) {
        access();
        return;
    }
    [documents[index] performSynchronousFileAccessUsingBlock:^{
        WithDocumentFileAccess(documents, index + 1, access);
    }];
}

@interface FolderExplorer () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSDraggingDestination>
@end

@implementation FolderExplorer {
    FolderWorkspace *_workspace;
    FolderOutline *_outline;
    NSScrollView *_scroll;
    FolderCell *_heading;
    NSBox *_rule;
    NSSet<NSString *> *_editedPaths;
    BOOL _restoring;
    FolderEntry *_namingItem;
    FolderEntry *_newItem;
    NSArray<FolderEntry *> *_selectionBeforeNaming;
    FolderCell *_nameCell;
    NSTextField *_nameField;
    ExplorerEdit _nameOperation;
    BOOL _reloadAfterNaming;
    BOOL _headingDropTarget;
}

- (instancetype)initWithWorkspace:(FolderWorkspace *)workspace
{
    self = [super initWithFrame:NSZeroRect];
    if (!self)
        return nil;
    _workspace = workspace;
    self.autoresizingMask = NSViewHeightSizable;
    self.accessibilityLabel = @"Explorer";

    _heading = [[FolderCell alloc] initWithIcon:YES];
    _heading.textField.font = [NSFont boldSystemFontOfSize:11];
    _heading.textField.stringValue = workspace.folder.lastPathComponent.length ?
        workspace.folder.lastPathComponent : workspace.folder.path;
    _heading.imageView.image = [NSWorkspace.sharedWorkspace iconForFile:workspace.folder.path];
    _heading.toolTip = workspace.folder.path;
    [self addSubview:_heading];

    _rule = [[NSBox alloc] initWithFrame:NSZeroRect];
    _rule.boxType = NSBoxSeparator;
    [self addSubview:_rule];

    _outline = [[FolderOutline alloc] initWithFrame:NSZeroRect];
    _outline.workspace = workspace;
    _outline.style = NSTableViewStylePlain;
    _outline.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    _outline.rowHeight = 20;
    _outline.indentationPerLevel = 14;
    _outline.intercellSpacing = NSMakeSize(2, 1);
    _outline.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _outline.autoresizesOutlineColumn = NO;
    _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _outline.headerView = nil;
    _outline.allowsMultipleSelection = YES;
    _outline.allowsEmptySelection = YES;
    _outline.accessibilityLabel = @"Files";
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"File"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_outline addTableColumn:column];
    _outline.outlineTableColumn = column;
    _outline.dataSource = self;
    _outline.delegate = self;
    _outline.target = self;
    _outline.doubleAction = @selector(openClickedRow:);
    [_outline registerForDraggedTypes:@[FolderItemDragType]];
    [_outline setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    [self registerForDraggedTypes:@[FolderItemDragType]];
    __weak FolderExplorer *view = self;
    _outline.openSelection = ^{ [view openSelectedRow]; };
    _outline.renameSelection = ^{ [view beginNameEdit:ExplorerEdit::Rename item:[view selectedItem]]; };
    _outline.trashSelection = ^{ [view trashItem:[view selectedItem]]; };
    _outline.menuForRow = ^NSMenu *(NSInteger row) { return [view menuForItem:[view itemAtRow:row]]; };

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.borderType = NSNoBorder;
    _scroll.documentView = _outline;
    [self addSubview:_scroll];
    NSMenu *rootMenu = [self menuForItem:_workspace.root];
    self.menu = rootMenu;
    _heading.menu = rootMenu;
    _heading.textField.menu = rootMenu;
    _heading.imageView.menu = rootMenu;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(contentsChanged:) name:FolderContentsChanged object:workspace];
    [center addObserver:self selector:@selector(documentsChanged:) name:FolderDocumentsChanged object:workspace];
    [self documentsChanged:nil];
    [_outline reloadData];
    [self restoreExpandedFolders];
    return self;
}

- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirty
{
    [NSColor.controlBackgroundColor setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
    if (_headingDropTarget) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.22] setFill];
        [NSBezierPath fillRect:[self workspaceHeadingRect]];
    }
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    _outline.backgroundColor = NSColor.controlBackgroundColor;
    self.needsDisplay = YES;
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    CGFloat top = std::max<CGFloat>(0, height - 26);
    _heading.frame = NSMakeRect(9, top, std::max<CGFloat>(0, width - 18), 26);
    _rule.frame = NSMakeRect(0, top, width, 1);
    _scroll.frame = NSMakeRect(0, 0, width, top);
}

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item
{
    (void)outline;
    return [_workspace childrenOf:item].count + ((_newItem && (item ? item : _workspace.root) == _namingItem) ? 1 : 0);
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item
{
    (void)outline;
    if (_newItem && (item ? item : _workspace.root) == _namingItem) {
        if (index == 0)
            return _newItem;
        --index;
    }
    return [_workspace childrenOf:item][index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(FolderEntry *)item
{
    (void)outline;
    return item.expandable;
}

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)outline pasteboardWriterForItem:(FolderEntry *)item
{
    (void)outline;
    if (!item || item == _newItem || _nameField || self.window.attachedSheet)
        return nil;
    NSPasteboardItem *pasteboardItem = [[NSPasteboardItem alloc] init];
    [pasteboardItem setString:@"" forType:FolderItemDragType];
    return pasteboardItem;
}

- (void)outlineView:(NSOutlineView *)outline draggingSession:(NSDraggingSession *)session
   willBeginAtPoint:(NSPoint)point forItems:(NSArray *)items
{
    (void)session;
    (void)point;
    FolderOutline *source = (FolderOutline *)outline;
    source->_draggedItems.clear();
    source->_draggedItems.reserve(items.count);
    NSSet *selected = [NSSet setWithArray:items];
    for (FolderEntry *item in items) {
        FolderEntry *parent = [outline parentForItem:item];
        while (parent && ![selected containsObject:parent])
            parent = [outline parentForItem:parent];
        if (!parent)
            source->_draggedItems.push_back({item, ExplorerFileIdentifier(item.url)});
    }
}

- (void)outlineView:(NSOutlineView *)outline draggingSession:(NSDraggingSession *)session
       endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation
{
    (void)session;
    (void)point;
    (void)operation;
    ((FolderOutline *)outline)->_draggedItems.clear();
}

- (FolderOutline *)dragSourceForInfo:(id<NSDraggingInfo>)info toFolder:(FolderEntry *)folder
{
    if (!folder.expandable || _nameField || self.window.attachedSheet ||
        !(info.draggingSourceOperationMask & NSDragOperationMove))
        return nil;
    id source = info.draggingSource;
    if (![source isKindOfClass:FolderOutline.class])
        return nil;
    FolderOutline *outline = source;
    if (outline.workspace != _workspace)
        return nil;
    NSString *destination = folder.url.path;
    BOOL canMove = NO;
    for (const ExplorerDragItem &drag : outline->_draggedItems) {
        NSString *path = drag.entry.url.path;
        if (PathIsInFolder(destination, path))
            return nil;
        if (![destination isEqualToString:path.stringByDeletingLastPathComponent])
            canMove = YES;
    }
    return canMove ? outline : nil;
}

- (BOOL)acceptExplorerDrop:(id<NSDraggingInfo>)info toFolder:(FolderEntry *)folder
{
    FolderOutline *source = [self dragSourceForInfo:info toFolder:folder];
    if (!source)
        return NO;
    NSError *error = [self validateActionFolder:folder.url];
    std::vector<ExplorerMove> moves;
    moves.reserve(source->_draggedItems.size());
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    if (!error)
        error = [self planDrop:source->_draggedItems intoFolder:folder moves:moves selectedPaths:paths];
    if (!error)
        error = [self moveExplorerItems:moves];
    if (error) {
        [self presentExplorerError:error title:source->_draggedItems.size() == 1 ? @"Couldn’t Move Item" : @"Couldn’t Move Items"];
        return NO;
    }

    if (folder != _workspace.root)
        [_outline expandItem:folder];
    NSMutableArray<FolderEntry *> *selected = [NSMutableArray arrayWithCapacity:paths.count];
    for (FolderEntry *child in [_workspace childrenOf:folder]) {
        if ([paths containsObject:child.url.path])
            [selected addObject:child];
    }
    [self selectItems:selected scroll:YES];
    return YES;
}

- (NSError *)planDrop:(std::span<const ExplorerDragItem>)items intoFolder:(FolderEntry *)folder
                moves:(std::vector<ExplorerMove> &)moves selectedPaths:(NSMutableSet<NSString *> *)paths
{
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSMutableSet<NSURL *> *checkedParents = [NSMutableSet set];
    NSNumber *caseSensitive = nil;
    [folder.url getResourceValue:&caseSensitive forKey:NSURLVolumeSupportsCaseSensitiveNamesKey error:nil];
    for (const ExplorerDragItem &drag : items) {
        FolderEntry *item = drag.entry;
        NSURL *parent = item.url.URLByDeletingLastPathComponent;
        if ([folder.url.path isEqualToString:parent.path]) {
            [paths addObject:item.url.path];
            continue;
        }
        if (![checkedParents containsObject:parent]) {
            if (NSError *error = [self validateActionFolder:parent])
                return error;
            [checkedParents addObject:parent];
        }
        NSString *name = item.url.lastPathComponent;
        NSURL *destination = [folder.url URLByAppendingPathComponent:name isDirectory:item.directory];
        NSString *key = name.precomposedStringWithCanonicalMapping;
        if (!caseSensitive.boolValue)
            key = [key stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:nil];
        if ([names containsObject:key]) {
            NSString *message = [NSString stringWithFormat:@"Two selected items are named “%@”.", name];
            return ExplorerError(destination, NSFileWriteFileExistsError, message);
        }
        struct stat entry;
        if (lstat(destination.fileSystemRepresentation, &entry) == 0) {
            NSString *message = [NSString stringWithFormat:@"An item named “%@” already exists in “%@”.", name, folder.url.lastPathComponent];
            return ExplorerError(destination, NSFileWriteFileExistsError, message);
        }
        if (errno != ENOENT)
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSURLErrorKey:destination}];
        [names addObject:key];
        [paths addObject:destination.path];
        moves.push_back({item.url, destination, drag.fileIdentifier, ExplorerItemIsSubtree(item) != NO});
    }
    return nil;
}

- (NSDragOperation)outlineView:(NSOutlineView *)outline validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(FolderEntry *)item proposedChildIndex:(NSInteger)index
{
    (void)item;
    (void)index;
    NSPoint point = [outline convertPoint:info.draggingLocation fromView:nil];
    FolderEntry *folder = nil;
    if (FolderEntry *hovered = [self itemAtRow:[outline rowAtPoint:point]])
        folder = hovered.directory ? hovered : [outline parentForItem:hovered];
    if (!folder)
        folder = _workspace.root;
    if (![self dragSourceForInfo:info toFolder:folder])
        return NSDragOperationNone;
    [outline setDropItem:folder == _workspace.root ? nil : folder dropChildIndex:NSOutlineViewDropOnItemIndex];
    return NSDragOperationMove;
}

- (void)outlineView:(NSOutlineView *)outline updateDraggingItemsForDrag:(id<NSDraggingInfo>)info
{
    (void)outline;
    id source = info.draggingSource;
    if ([source isKindOfClass:FolderOutline.class] && [(FolderOutline *)source workspace] == _workspace)
        info.numberOfValidItemsForDrop = ((FolderOutline *)source)->_draggedItems.size();
}

- (BOOL)outlineView:(NSOutlineView *)outline acceptDrop:(id<NSDraggingInfo>)info
               item:(FolderEntry *)item childIndex:(NSInteger)index
{
    (void)outline;
    if (index != NSOutlineViewDropOnItemIndex)
        return NO;
    return [self acceptExplorerDrop:info toFolder:item ? item : _workspace.root];
}

- (NSRect)workspaceHeadingRect
{
    return NSMakeRect(0, NSMinY(_heading.frame), NSWidth(self.bounds), NSHeight(_heading.frame));
}

- (void)setHeadingDropTarget:(BOOL)target
{
    if (_headingDropTarget == target)
        return;
    _headingDropTarget = target;
    [self setNeedsDisplayInRect:[self workspaceHeadingRect]];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    return [self draggingUpdated:info];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info
{
    NSPoint point = [self convertPoint:info.draggingLocation fromView:nil];
    FolderOutline *source = NSPointInRect(point, [self workspaceHeadingRect]) ? [self dragSourceForInfo:info toFolder:_workspace.root] : nil;
    [self setHeadingDropTarget:source != nil];
    if (!source)
        return NSDragOperationNone;
    info.numberOfValidItemsForDrop = source->_draggedItems.size();
    return NSDragOperationMove;
}

- (void)draggingExited:(id<NSDraggingInfo>)info
{
    (void)info;
    [self setHeadingDropTarget:NO];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    [self setHeadingDropTarget:NO];
    NSPoint point = [self convertPoint:info.draggingLocation fromView:nil];
    return NSPointInRect(point, [self workspaceHeadingRect]) && [self acceptExplorerDrop:info toFolder:_workspace.root];
}

- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(FolderEntry *)item
{
    FolderCell *cell = [outline makeViewWithIdentifier:column.identifier owner:self];
    if (!cell) {
        cell = [[FolderCell alloc] initWithIcon:YES];
        cell.identifier = column.identifier;
    }
    if (!item.icon)
        item.icon = [NSWorkspace.sharedWorkspace iconForFile:item.url.path];
    cell.objectValue = item;
    cell.textField.stringValue = item == _newItem ? @"" : item.url.lastPathComponent;
    cell.imageView.image = item.icon;
    cell.edited = [_editedPaths containsObject:item.url.path];
    cell.toolTip = cell.edited ? [@"Modified — " stringByAppendingString:item.url.lastPathComponent] :
                                item.url.lastPathComponent;
    return cell;
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification
{
    FolderEntry *entry = notification.userInfo[@"NSObject"];
    if (!_restoring && entry)
        [_workspace.expandedPaths addObject:entry.url.path];
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification
{
    FolderEntry *entry = notification.userInfo[@"NSObject"];
    if (!_restoring && entry)
        [_workspace.expandedPaths removeObject:entry.url.path];
}

- (void)restoreExpandedFolders
{
    _restoring = YES;
    for (NSInteger row = 0; row < _outline.numberOfRows; ++row) {
        FolderEntry *item = [_outline itemAtRow:row];
        if (!item.expandable)
            continue;
        if ([_workspace.expandedPaths containsObject:item.url.path]) {
            [_outline expandItem:item];
        } else if ([_outline isItemExpanded:item]) {
            [_outline collapseItem:item collapseChildren:YES];
        }
    }
    _restoring = NO;
}

- (void)documentsChanged:(NSNotification *)notification
{
    (void)notification;
    NSMutableSet<NSString *> *edited = [NSMutableSet set];
    for (SourceDocument *document in _workspace.documents) {
        NSString *path = CanonicalFileURL(document.fileURL).path;
        if (document.isDocumentEdited && path.length)
            [edited addObject:path];
    }
    if ([edited isEqualToSet:_editedPaths])
        return;
    _editedPaths = edited;
    [_outline enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *, NSInteger row) {
        if (row < 0 || row >= self->_outline.numberOfRows)
            return;
        FolderCell *cell = [self->_outline viewAtColumn:0 row:row makeIfNecessary:NO];
        FolderEntry *item = [self->_outline itemAtRow:row];
        cell.edited = [edited containsObject:item.url.path];
        cell.toolTip = cell.edited ? [@"Modified — " stringByAppendingString:item.url.lastPathComponent] :
                                    item.url.lastPathComponent;
    }];
}

- (void)contentsChanged:(NSNotification *)notification
{
    (void)notification;
    if (_nameField) {
        _reloadAfterNaming = YES;
        return;
    }
    NSArray<FolderEntry *> *selected = [self selectedItems];
    [_outline reloadData];
    [self restoreExpandedFolders];
    [self selectItems:selected scroll:NO];
}

- (void)focusFiles
{
    if (self.superview)
        [self.window makeFirstResponder:_outline];
}

- (void)revealFile:(NSURL *)file expandingFolders:(BOOL)expand
{
    [self revealPath:CanonicalFileURL(file).path expandingFolders:expand];
}

- (void)revealPath:(NSString *)path expandingFolders:(BOOL)expand
{
    if (_nameField)
        return;
    [self restoreExpandedFolders];
    if (!PathIsInFolder(path, _workspace.folder.path)) {
        [_outline deselectAll:nil];
        return;
    }
    NSArray<NSString *> *parts = path.pathComponents;
    FolderEntry *folder = _workspace.root;
    for (NSUInteger depth = _workspace.folder.path.pathComponents.count; depth < parts.count; ++depth) {
        FolderEntry *match = nil;
        for (FolderEntry *entry in [_workspace childrenOf:folder]) {
            if ([entry.url.lastPathComponent isEqualToString:parts[depth]]) {
                match = entry;
                break;
            }
        }
        if (!match) {
            [_outline deselectAll:nil];
            return;
        }
        folder = match;
        if (depth + 1 < parts.count && ![_outline isItemExpanded:folder]) {
            if (!expand) {
                [_outline deselectAll:nil];
                return;
            }
            [_outline expandItem:folder];
        }
    }
    NSInteger row = [_outline rowForItem:folder];
    if (row >= 0) {
        [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_outline scrollRowToVisible:row];
    }
}

- (FolderEntry *)itemAtRow:(NSInteger)row
{
    return row >= 0 && row < _outline.numberOfRows ? [_outline itemAtRow:row] : nil;
}

- (NSArray<FolderEntry *> *)selectedItems
{
    NSMutableArray<FolderEntry *> *items = [NSMutableArray arrayWithCapacity:_outline.numberOfSelectedRows];
    [_outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *) {
        if (FolderEntry *item = [self itemAtRow:row])
            [items addObject:item];
    }];
    return items;
}

- (FolderEntry *)selectedItem
{
    return _outline.numberOfSelectedRows == 1 ? [self itemAtRow:_outline.selectedRow] : nil;
}

- (void)addAction:(SEL)action title:(NSString *)title toMenu:(NSMenu *)menu item:(FolderEntry *)entry
{
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = entry;
}

- (NSMenu *)menuForItem:(FolderEntry *)entry
{
    if (_newItem && entry == _newItem)
        return nil;
    if (!entry)
        entry = _workspace.root;
    NSMenu *menu = [[NSMenu alloc] init];
    if (entry.expandable) {
        [self addAction:@selector(newFile:) title:@"New File" toMenu:menu item:entry];
        [self addAction:@selector(newFolder:) title:@"New Folder" toMenu:menu item:entry];
    } else {
        [self addAction:@selector(openItem:) title:@"Open" toMenu:menu item:entry];
    }
    if (entry != _workspace.root) {
        [menu addItem:NSMenuItem.separatorItem];
        [self addAction:@selector(renameItem:) title:@"Rename" toMenu:menu item:entry];
        [self addAction:@selector(moveItemToTrash:) title:@"Move to Trash" toMenu:menu item:entry];
    }
    return menu;
}

- (IBAction)newFile:(NSMenuItem *)sender
{
    [self beginNameEdit:ExplorerEdit::NewFile item:sender.representedObject];
}

- (IBAction)newFolder:(NSMenuItem *)sender
{
    [self beginNameEdit:ExplorerEdit::NewFolder item:sender.representedObject];
}

- (IBAction)renameItem:(NSMenuItem *)sender { [self beginNameEdit:ExplorerEdit::Rename item:sender.representedObject]; }
- (IBAction)moveItemToTrash:(NSMenuItem *)sender { [self trashItem:sender.representedObject]; }
- (IBAction)openItem:(NSMenuItem *)sender { [self openRow:[_outline rowForItem:sender.representedObject]]; }

- (void)selectItems:(NSArray<FolderEntry *> *)items scroll:(BOOL)scroll
{
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (FolderEntry *item in items) {
        NSInteger row = [_outline rowForItem:item];
        if (row >= 0)
            [rows addIndex:row];
    }
    [_outline selectRowIndexes:rows byExtendingSelection:NO];
    if (scroll && rows.count)
        [_outline scrollRowToVisible:rows.firstIndex];
}

- (void)beginNameEdit:(ExplorerEdit)operation item:(FolderEntry *)item
{
    if (!item || !self.window || self.window.attachedSheet || item == _newItem)
        return;
    BOOL renaming = operation == ExplorerEdit::Rename;
    if (renaming ? item == _workspace.root : !item.expandable)
        return;
    [self endNameEdit];

    _selectionBeforeNaming = [self selectedItems];
    _namingItem = item;
    _nameOperation = operation;
    if (!renaming) {
        _newItem = [[FolderEntry alloc] init];
        _newItem.directory = operation == ExplorerEdit::NewFolder;
        _newItem.url = [item.url URLByAppendingPathComponent:@".retina-code-name" isDirectory:_newItem.directory];
        _newItem.icon = [NSImage imageWithSystemSymbolName:_newItem.directory ? @"folder" : @"doc"
                                  accessibilityDescription:nil];
        if (item != _workspace.root)
            [_workspace.expandedPaths addObject:item.url.path];
        [self contentsChanged:nil];
    }

    FolderEntry *editingItem = renaming ? item : _newItem;
    [self selectItems:@[editingItem] scroll:YES];
    NSInteger row = [_outline rowForItem:editingItem];
    _nameCell = row < 0 ? nil : [_outline viewAtColumn:0 row:row makeIfNecessary:YES];
    if (!_nameCell) {
        [self endNameEdit];
        return;
    }
    [_nameCell layoutSubtreeIfNeeded];
    NSString *name = renaming ? item.url.lastPathComponent : @"";
    _nameField = [NSTextField textFieldWithString:name];
    _nameField.placeholderString = operation == ExplorerEdit::NewFolder ? @"Folder name" : @"File name";
    _nameField.accessibilityLabel = renaming ? @"Rename" : _nameField.placeholderString;
    _nameField.font = _nameCell.textField.font;
    _nameField.delegate = self;
    _nameField.usesSingleLineMode = YES;
    _nameField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat x = std::max<CGFloat>(0, NSMinX(_nameCell.textField.frame) - 2);
    _nameField.frame = NSMakeRect(x, 0, std::max<CGFloat>(0, NSWidth(_nameCell.bounds) - x - 3), NSHeight(_nameCell.bounds));
    _nameCell.textField.hidden = YES;
    [_nameCell addSubview:_nameField];
    [_nameField selectText:nil];

    NSUInteger length = name.length;
    if (renaming && !item.directory) {
        NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location != NSNotFound && dot.location > 0)
            length = dot.location;
    }
    _nameField.currentEditor.selectedRange = NSMakeRange(0, length);
}

- (void)endNameEdit
{
    NSArray<FolderEntry *> *selected = _selectionBeforeNaming;
    BOOL reload = _newItem != nil || _reloadAfterNaming;
    NSTextField *field = _nameField;
    BOOL editing = field && (self.window.firstResponder == field || self.window.firstResponder == field.currentEditor);
    _nameField = nil;
    field.delegate = nil;
    if (editing)
        [self.window makeFirstResponder:_outline];
    [field removeFromSuperview];
    _nameCell.textField.hidden = NO;
    _nameCell = nil;
    _newItem = nil;
    _namingItem = nil;
    _selectionBeforeNaming = nil;
    _reloadAfterNaming = NO;
    _nameOperation = ExplorerEdit::None;
    if (reload)
        [self contentsChanged:nil];
    if (selected || reload)
        [self selectItems:selected scroll:YES];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
    if (control != _nameField)
        return NO;
    if (command == @selector(insertNewline:) || command == @selector(insertNewlineIgnoringFieldEditor:)) {
        [self commitName:textView.string];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        [self endNameEdit];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
    if (notification.object != _nameField)
        return;
    NSTextMovement movement = (NSTextMovement)[notification.userInfo[NSTextMovementUserInfoKey] integerValue];
    if (movement == NSTextMovementReturn)
        [self commitName:_nameField.stringValue];
    else
        [self endNameEdit];
}

- (NSError *)validateActionFolder:(NSURL *)directory
{
    BOOL folder = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory.path isDirectory:&folder] || !folder)
        return ExplorerError(directory, NSFileNoSuchFileError, @"The folder no longer exists.");
    if (!PathIsInFolder(CanonicalFileURL(directory).path, _workspace.folder.path))
        return ExplorerError(directory, NSFileWriteNoPermissionError, @"The folder is outside this workspace.");
    return nil;
}

- (void)presentExplorerError:(NSError *)error title:(NSString *)title
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = error.localizedDescription;
    [alert addButtonWithTitle:@"OK"];
    if (self.window)
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (NSError *)createItemAtURL:(NSURL *)url directory:(BOOL)directory
{
    if (directory) {
        NSError *error = nil;
        [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO attributes:nil error:&error];
        return error;
    }
    int file = open(url.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0666);
    if (file < 0)
        return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSURLErrorKey:url}];
    close(file);
    return nil;
}

- (NSError *)moveExplorerItem:(FolderEntry *)item toURL:(NSURL *)destination
{
    ExplorerMove move{item.url, destination, nil, ExplorerItemIsSubtree(item) != NO};
    return [self moveExplorerItems:std::span(&move, 1)];
}

- (NSError *)moveExplorerItems:(std::span<ExplorerMove>)moves
{
    NSMutableArray<SourceDocument *> *documents = [NSMutableArray array];
    for (NSDocument *document in NSDocumentController.sharedDocumentController.documents) {
        if (![document isKindOfClass:SourceDocument.class])
            continue;
        for (const ExplorerMove &move : moves) {
            if (MatchesExplorerItem(document.fileURL, move.source, move.subtree)) {
                [documents addObject:(SourceDocument *)document];
                break;
            }
        }
    }
    NSMutableSet<NSURL *> *parents = [NSMutableSet set];
    __block NSError *error = nil;
    WithDocumentFileAccess(documents, 0, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        size_t completed = 0;
        for (ExplorerMove &move : moves) {
            if (move.fileIdentifier && ![move.fileIdentifier isEqual:ExplorerFileIdentifier(move.source)]) {
                error = ExplorerError(move.source, NSFileWriteUnknownError, @"An item changed while you were dragging it.");
                break;
            }
            NSError *failure = nil;
            if (![files moveItemAtURL:move.source toURL:move.destination error:&failure]) {
                error = failure ? failure : ExplorerError(move.source, NSFileWriteUnknownError, @"The item couldn’t be moved.");
                break;
            }
            move.moved = true;
            ++completed;
        }

        if (error) {
            BOOL incompleteRollback = NO;
            while (completed) {
                ExplorerMove &move = moves[--completed];
                if ([files moveItemAtURL:move.destination toURL:move.source error:nil])
                    move.moved = false;
                else
                    incompleteRollback = YES;
            }
            if (incompleteRollback) {
                NSString *message = [error.localizedDescription stringByAppendingString:@"\n\nSome items stayed at their new locations."];
                error = ExplorerError(moves.front().source, NSFileWriteUnknownError, message);
            }
        }

        for (const ExplorerMove &move : moves) {
            if (!move.moved)
                continue;
            MoveFileIndentationPreferences(move.source, move.destination, move.subtree);
            [parents addObject:move.source.URLByDeletingLastPathComponent];
            [parents addObject:move.destination.URLByDeletingLastPathComponent];
            if (move.subtree)
                [self->_workspace moveExpandedPathsFrom:move.source to:move.destination];
            for (SourceDocument *document in documents) {
                if (!MatchesExplorerItem(document.fileURL, move.source, move.subtree))
                    continue;
                NSString *suffix = [document.fileURL.URLByStandardizingPath.path substringFromIndex:move.source.path.length];
                NSURL *newFile = [NSURL fileURLWithPath:[move.destination.path stringByAppendingString:suffix]];
                [document setFileURLFromExplorer:newFile];
            }
        }
    });
    if (parents.count) {
        RefreshDocumentWorkspaces(documents);
        [_workspace refreshDirectories:parents.allObjects];
    }
    return error;
}

- (void)commitName:(NSString *)name
{
    if (!_nameField)
        return;
    name = [name copy];
    FolderEntry *entry = _namingItem;
    ExplorerEdit operation = _nameOperation;
    BOOL renaming = operation == ExplorerEdit::Rename;
    BOOL directory = renaming ? entry.directory : operation == ExplorerEdit::NewFolder;
    NSURL *parent = renaming ? entry.url.URLByDeletingLastPathComponent : entry.url;
    [self endNameEdit];
    if (renaming && [entry.url.lastPathComponent compare:name options:NSLiteralSearch] == NSOrderedSame)
        return;
    NSError *error = ValidateExplorerName(name, parent);
    if (!error)
        error = [self validateActionFolder:parent];
    if (error) {
        [self presentExplorerError:error title:renaming ? @"Couldn’t Rename Item" : @"Couldn’t Create Item"];
        return;
    }
    NSURL *destination = [parent URLByAppendingPathComponent:name isDirectory:directory];
    error = renaming ? [self moveExplorerItem:entry toURL:destination] : [self createItemAtURL:destination directory:directory];
    if (error) {
        [self presentExplorerError:error title:renaming ? @"Couldn’t Rename Item" : @"Couldn’t Create Item"];
        return;
    }

    if (!renaming)
        [_workspace refreshDirectories:@[parent]];
    [self revealPath:destination.path expandingFolders:YES];
    if (operation == ExplorerEdit::NewFile && self.openFile)
        self.openFile(destination);
}

- (void)trashItem:(FolderEntry *)item
{
    if (!item || item == _workspace.root || item == _newItem || self.window.attachedSheet)
        return;
    [self endNameEdit];
    NSURL *parent = item.url.URLByDeletingLastPathComponent;
    NSError *unavailable = [self validateActionFolder:parent];
    if (unavailable) {
        [self presentExplorerError:unavailable title:@"Couldn’t Move Item to Trash"];
        return;
    }
    BOOL subtree = ExplorerItemIsSubtree(item);
    auto documents = DocumentsForExplorerItem(item.url, subtree);
    NSMutableArray<SourceDocument *> *close = [NSMutableArray array];
    __block NSError *error = nil;
    WithDocumentFileAccess(documents, 0, ^{
        NSError *failure = nil;
        if (![NSFileManager.defaultManager trashItemAtURL:item.url resultingItemURL:nil error:&failure]) {
            error = failure;
            return;
        }
        MoveFileIndentationPreferences(item.url, nil, subtree);
        if (subtree)
            [self->_workspace moveExpandedPathsFrom:item.url to:nil];
        for (SourceDocument *document in documents) {
            if (!MatchesExplorerItem(document.fileURL, item.url, subtree))
                continue;
            if (document.isDocumentEdited)
                [document setFileURLFromExplorer:nil];
            else
                [close addObject:document];
        }
    });
    if (error) {
        [self presentExplorerError:error title:@"Couldn’t Move Item to Trash"];
        return;
    }
    [_workspace refreshDirectories:@[parent]];
    for (SourceDocument *document in close)
        [document close];
    RefreshDocumentWorkspaces(documents);
    [self revealPath:parent.path expandingFolders:YES];
}

- (void)openRow:(NSInteger)row
{
    if (row < 0 || row >= _outline.numberOfRows)
        return;
    FolderEntry *item = [_outline itemAtRow:row];
    if (item.expandable) {
        if ([_outline isItemExpanded:item])
            [_outline collapseItem:item];
        else
            [_outline expandItem:item];
    } else if (item.directory) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[item.url]];
    } else if (self.openFile) {
        self.openFile(item.url);
    }
}

- (void)openSelectedRow
{
    if (_outline.numberOfSelectedRows == 1)
        [self openRow:_outline.selectedRow];
}
- (IBAction)openClickedRow:(id)sender { (void)sender; [self openRow:_outline.clickedRow]; }

@end