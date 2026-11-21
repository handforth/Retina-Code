#import "FolderSearch.h"
#import "Editor.h"
#import "Workspace.h"
#include "VimMulti.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <vector>

static constexpr NSUInteger searchMatchLimit = 5000;
static constexpr CGFloat searchOptionSegmentWidth = 26;

@interface FolderSearchPattern : NSObject
@property(nonatomic, copy) NSString *query;
@property(nonatomic) NSStringCompareOptions literalOptions;
@property(nonatomic) BOOL wholeWord;
@property(nonatomic) NSRegularExpression *expression;
@end

@implementation FolderSearchPattern
@end

static bool FolderMatchHasBoundaries(NSString *text, NSRange range, BOOL wholeWord)
{
    // An insertion point between CR and LF would split a single line ending.
    if (!range.length && range.location > 0 && range.location < text.length &&
        [text characterAtIndex:range.location - 1] == '\r' && [text characterAtIndex:range.location] == '\n')
        return false;
    return !wholeWord || IsWholeSourceWord(text, range);
}

static bool CheckFolderMatch(NSString *text, NSRange range, FolderSearchPattern *pattern, NSTextCheckingResult **checking)
{
    if (!pattern || range.location > text.length || range.length > text.length - range.location)
        return false;
    if (!FolderMatchHasBoundaries(text, range, pattern.wholeWord))
        return false;
    if (pattern.expression) {
        NSMatchingOptions options = NSMatchingAnchored | NSMatchingWithTransparentBounds | NSMatchingWithoutAnchoringBounds;
        NSRange remaining = NSMakeRange(range.location, text.length - range.location);
        *checking = [pattern.expression firstMatchInString:text options:options range:remaining];
        return *checking && NSEqualRanges((*checking).range, range);
    }
    return NSEqualRanges([text rangeOfString:pattern.query options:pattern.literalOptions | NSAnchoredSearch range:range], range);
}

bool FolderSearchRangeMatches(NSString *text, NSRange range, FolderSearchPattern *pattern)
{
    NSTextCheckingResult *checking = nil;
    return CheckFolderMatch(text, range, pattern, &checking);
}

static NSArray<NSString *> *FolderMatchCaptures(NSString *text, NSTextCheckingResult *checking)
{
    NSMutableArray<NSString *> *captures = [NSMutableArray arrayWithCapacity:checking.numberOfRanges];
    for (NSUInteger index = 0; index < checking.numberOfRanges; ++index) {
        NSRange part = [checking rangeAtIndex:index];
        [captures addObject:part.location == NSNotFound ? @"" : [text substringWithRange:part]];
    }
    return captures;
}

static NSString *FolderReplacement(NSString *replacement, NSArray<NSString *> *captures)
{
    static NSCharacterSet *const templateCharacters = [NSCharacterSet characterSetWithCharactersInString:@"$\\"];
    if (!captures || [replacement rangeOfCharacterFromSet:templateCharacters].location == NSNotFound)
        return replacement;
    NSMutableString *expanded = [NSMutableString string];
    NSUInteger length = replacement.length;
    for (NSUInteger index = 0; index < length; ++index) {
        unichar character = [replacement characterAtIndex:index];
        unichar next = index + 1 < length ? [replacement characterAtIndex:index + 1] : 0;
        if (character == '$') {
            if (next == '$') {
                [expanded appendString:@"$"];
                ++index;
                continue;
            }
            if (next >= '0' && next <= '9' && NSUInteger(next - '0') < captures.count) {
                NSUInteger group = next - '0';
                ++index;
                if (index + 1 < length) {
                    unichar digit = [replacement characterAtIndex:index + 1];
                    if (digit >= '0' && digit <= '9' && group * 10 + digit - '0' < captures.count) {
                        group = group * 10 + digit - '0';
                        ++index;
                    }
                }
                [expanded appendString:captures[group]];
                continue;
            }
        } else if (character == '\\') {
            NSString *escape = nil;
            switch (next) {
                case 'n': escape = @"\n"; break;
                case 'r': escape = @"\r"; break;
                case 't': escape = @"\t"; break;
                case '\\': escape = @"\\"; break;
            }
            if (escape) {
                [expanded appendString:escape];
                ++index;
                continue;
            }
        }
        NSUInteger start = index;
        if (CFStringIsSurrogateHighCharacter(character) && CFStringIsSurrogateLowCharacter(next))
            ++index;
        [expanded appendString:[replacement substringWithRange:NSMakeRange(start, index - start + 1)]];
    }
    return expanded;
}

@interface FolderSearchMatch : NSObject
@property(nonatomic) NSRange range;
@property(nonatomic) NSRange emphasis;
@property(nonatomic) NSUInteger line;
@property(nonatomic, copy) NSString *preview;
@property(nonatomic, copy) NSString *original;
@property(nonatomic) NSArray<NSString *> *captures;
@end

@implementation FolderSearchMatch
@end

@interface FolderSearchFile : NSObject
@property(nonatomic) NSURL *url;
@property(nonatomic, weak) SourceDocument *document;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) NSMutableArray<FolderSearchMatch *> *matches;
@property(nonatomic) BOOL incomplete;
@end

@implementation FolderSearchFile
@end

struct SearchBuffer {
    NSURL *url;
    FolderSearchFile *file;
    NSString *text;
};

struct FolderSearchResults {
    NSMutableArray<FolderSearchFile *> *files = [NSMutableArray array];
    NSUInteger count = 0;
    bool limited = false;
    bool unreadable = false;
};

static FolderSearchMatch *MakeSearchMatch(NSString *text, NSRange range, NSUInteger line,
                                         NSUInteger lineStart, NSUInteger lineEnd, NSTextCheckingResult *checking)
{
    constexpr NSUInteger leadingContext = 8;
    constexpr NSUInteger previewLength = 152;
    NSUInteger start = range.location - std::min(range.location - lineStart, leadingContext);
    bool leadingEllipsis = start > lineStart;
    while (start < range.location) {
        unichar character = [text characterAtIndex:start];
        if (character != ' ' && character != '\t')
            break;
        ++start;
    }
    NSUInteger end = std::min(start + previewLength, lineEnd);
    NSRange excerpt = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(start, end - start)];
    NSString *preview = [[text substringWithRange:excerpt] stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    if (leadingEllipsis && excerpt.location > lineStart)
        preview = [@"…" stringByAppendingString:preview];
    else
        leadingEllipsis = false;
    if (NSMaxRange(excerpt) < lineEnd)
        preview = [preview stringByAppendingString:@"…"];

    NSRange emphasis = NSIntersectionRange(excerpt, range);
    FolderSearchMatch *match = [[FolderSearchMatch alloc] init];
    match.range = range;
    match.line = line;
    match.preview = preview;
    match.emphasis = NSMakeRange(range.location - excerpt.location + (leadingEllipsis ? 1 : 0), emphasis.length);
    match.captures = checking ? FolderMatchCaptures(text, checking) : nil;
    match.original = checking ? match.captures.firstObject : [text substringWithRange:range];
    return match;
}

static void SearchText(FolderSearchResults &results, const SearchBuffer &buffer, FolderSearchPattern *pattern,
                       NSString *rootPrefix, const std::atomic_bool &cancelled)
{
    NSString *text = buffer.text;
    NSUInteger length = text.length;
    NSUInteger line = 0, lineStart = 0, lineEnd = 0, nextLine = 0;
    FolderSearchFile *file = nil;
    auto record = [&](NSRange range, NSTextCheckingResult *checking) {
        if (!FolderMatchHasBoundaries(text, range, pattern.wholeWord))
            return true;
        if (results.count == searchMatchLimit) {
            results.limited = true;
            file.incomplete = YES;
            return false;
        }
        while (nextLine <= range.location) {
            if (cancelled.load(std::memory_order_relaxed))
                return false;
            NSUInteger previous = nextLine;
            [text getLineStart:&lineStart end:&nextLine contentsEnd:&lineEnd forRange:NSMakeRange(previous, 0)];
            if (nextLine == previous && lineStart != previous)
                break;
            ++line;
            if (nextLine == previous)
                break;
        }
        if (!file) {
            file = buffer.file;
            if (!file) {
                file = [[FolderSearchFile alloc] init];
                file.url = buffer.url;
                file.path = [buffer.url.path substringFromIndex:rootPrefix.length];
            }
            file.matches = [NSMutableArray array];
            [results.files addObject:file];
        }
        [file.matches addObject:MakeSearchMatch(text, range, line, lineStart, std::max(lineEnd, range.location), checking)];
        ++results.count;
        return true;
    };
    if (pattern.expression) {
        [pattern.expression enumerateMatchesInString:text options:NSMatchingReportProgress range:NSMakeRange(0, length)
            usingBlock:^(NSTextCheckingResult *checking, NSMatchingFlags, BOOL *stop) {
                if (cancelled.load(std::memory_order_relaxed) || (checking && !record(checking.range, checking)))
                    *stop = YES;
            }];
    } else {
        for (NSUInteger start = 0; start < length && !cancelled.load(std::memory_order_relaxed);) {
            NSRange range = [text rangeOfString:pattern.query options:pattern.literalOptions range:NSMakeRange(start, length - start)];
            if (range.location == NSNotFound || !record(range, nil))
                break;
            start = NSMaxRange(range);
        }
    }
}

static FolderSearchResults SearchFolder(NSURL *root, FolderSearchPattern *pattern, const std::vector<SearchBuffer> &buffers,
                                        const std::atomic_bool &cancelled)
{
    FolderSearchResults results;
    NSString *rootPrefix = [root.path hasSuffix:@"/"] ? root.path : [root.path stringByAppendingString:@"/"];
    NSMutableSet<NSString *> *openPaths = [NSMutableSet set];
    for (const SearchBuffer &buffer : buffers) {
        if (results.limited || cancelled.load(std::memory_order_relaxed))
            break;
        if (buffer.url) {
            NSString *path = buffer.url.path;
            if (![path hasPrefix:rootPrefix] || [openPaths containsObject:path])
                continue;
            [openPaths addObject:path];
        }
        SearchText(results, buffer, pattern, rootPrefix, cancelled);
    }

    if (!results.limited && !cancelled.load(std::memory_order_relaxed)) {
        NSArray *keys = @[NSURLIsRegularFileKey, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey];
        __block bool unreadable = false;
        NSDirectoryEnumerator<NSURL *> *entries = [NSFileManager.defaultManager enumeratorAtURL:root
            includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsPackageDescendants
            errorHandler:^BOOL(NSURL *, NSError *) {
                unreadable = true;
                return !cancelled.load(std::memory_order_relaxed);
            }];
        // Keep only the snippets from each file after scanning it.
        while (!results.limited && !cancelled.load(std::memory_order_relaxed)) {
            @autoreleasepool {
                NSURL *url = entries.nextObject;
                if (!url)
                    break;
                NSDictionary *attributes = [url resourceValuesForKeys:keys error:nullptr];
                if ([attributes[NSURLIsSymbolicLinkKey] boolValue] || HiddenWorkspaceItem(url.lastPathComponent)) {
                    if ([attributes[NSURLIsDirectoryKey] boolValue])
                        [entries skipDescendants];
                    continue;
                }
                if (![attributes[NSURLIsRegularFileKey] boolValue] || [openPaths containsObject:url.path])
                    continue;
                NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nullptr];
                if (!data) {
                    unreadable = true;
                    continue;
                }
                NSString *text = DecodeSourceText(data);
                if (text)
                    SearchText(results, {url, nil, text}, pattern, rootPrefix, cancelled);
            }
        }
        results.unreadable = unreadable || !entries;
    }
    if (!cancelled.load(std::memory_order_relaxed)) {
        [results.files sortUsingComparator:^NSComparisonResult(FolderSearchFile *first, FolderSearchFile *second) {
            return [first.path localizedStandardCompare:second.path];
        }];
    }
    return results;
}

static NSURL *CurrentSearchFile(NSURL *file)
{
    if (!file)
        return nil;
    NSURL *url = [NSURL fileURLWithPath:file.path isDirectory:NO];
    if (![CanonicalFileURL(url).path isEqualToString:url.path])
        return nil;
    NSNumber *regular = nil;
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    return regular.boolValue ? url : nil;
}

struct FolderReplaceReport {
    NSUInteger replacements = 0;
    NSUInteger files = 0;
    NSUInteger skipped = 0;
    NSString *firstError = nil;
};

@interface FolderReplace : NSObject
@property(nonatomic) NSArray<FolderSearchFile *> *files;
@property(nonatomic) FolderSearchMatch *onlyMatch;
@property(nonatomic) FolderSearchPattern *pattern;
@property(nonatomic, copy) NSString *replacement;
@property(nonatomic, copy) void (^completion)(const FolderReplaceReport &);
- (void)advance;
@end

@implementation FolderReplace {
    NSUInteger _position;
    FolderReplaceReport _report;
}

- (void)advance
{
    if (_position == _files.count) {
        _completion(_report);
        return;
    }
    FolderSearchFile *file = _files[_position++];
    SourceDocument *document = file.document;
    if (document.editorHostWindow && (!file.url || [document.fileURL.path isEqualToString:file.url.path])) {
        [self replaceFile:file document:document error:nil];
        return;
    }
    NSURL *url = CurrentSearchFile(file.url);
    if (!url) {
        [self replaceFile:file document:nil error:nil];
        return;
    }
    // Let AppKit resolve any tab that has opened since the results were collected.
    [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:url display:NO
        completionHandler:^(NSDocument *opened, BOOL alreadyOpen, NSError *error) {
            SourceDocument *source = [opened isKindOfClass:SourceDocument.class] ? (SourceDocument *)opened : nil;
            [self replaceFile:file document:source error:error];
            if (source && !alreadyOpen && !source.editorHostWindow)
                [source close];
        }];
}

- (void)replaceFile:(FolderSearchFile *)file document:(SourceDocument *)document error:(NSError *)error
{
    NSString *text = document.sourceText;
    NSString *failure = error.localizedDescription;
    if (!failure && (!document || (file.url && ![file.url.path isEqualToString:document.fileURL.path])))
        failure = @"The file has moved or closed.";
    std::vector<Vim::CursorEdit> edits;
    if (!failure) {
        NSArray<FolderSearchMatch *> *matches = _onlyMatch ? @[_onlyMatch] : file.matches;
        edits.reserve(matches.count);
        for (FolderSearchMatch *match in matches) {
            NSTextCheckingResult *checking = nil;
            if (!CheckFolderMatch(text, match.range, _pattern, &checking) ||
                ![[text substringWithRange:match.range] isEqualToString:match.original] ||
                (checking && ![FolderMatchCaptures(text, checking) isEqualToArray:match.captures])) {
                failure = @"Matches changed. Search again before replacing.";
                break;
            }
            NSString *replacement = FolderReplacement(_replacement, match.captures);
            if ([replacement isEqualToString:match.original])
                continue;
            std::u16string units(replacement.length, u'\0');
            [replacement getCharacters:reinterpret_cast<unichar *>(units.data()) range:NSMakeRange(0, units.size())];
            edits.push_back({{match.range.location, NSMaxRange(match.range)}, std::move(units)});
        }
    }
    if (!failure && !edits.empty()) {
        NSUInteger count = edits.size();
        if ([document applyFolderSearchEdits:Vim::EditBatch(std::move(edits)) error:&error]) {
            _report.replacements += count;
            ++_report.files;
        } else {
            failure = error ? error.localizedDescription : @"The file could not be changed.";
        }
    }
    if (failure) {
        ++_report.skipped;
        if (!_report.firstError)
            _report.firstError = [NSString stringWithFormat:@"%@\n%@", file.path, failure];
    }
    // Yield between files so opening, scrolling, and typing stay responsive.
    dispatch_async(dispatch_get_main_queue(), ^{ [self advance]; });
}

@end

@interface SearchResultCell : NSTableCellView
@property(nonatomic, readonly) NSTextField *detail;
@end

@implementation SearchResultCell

- (instancetype)init
{
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        NSTextField *label = [NSTextField labelWithString:@""];
        label.usesSingleLineMode = YES;
        label.maximumNumberOfLines = 1;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:label];
        self.textField = label;

        _detail = [NSTextField labelWithString:@""];
        _detail.alignment = NSTextAlignmentRight;
        _detail.usesSingleLineMode = YES;
        _detail.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
        _detail.textColor = NSColor.secondaryLabelColor;
        [self addSubview:_detail];
    }
    return self;
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    NSSize labelSize = self.textField.intrinsicContentSize;
    NSSize detailSize = _detail.intrinsicContentSize;
    CGFloat detailWidth = std::ceil(detailSize.width) + 6;
    CGFloat detailX = std::max<CGFloat>(0, width - detailWidth - 8);
    self.textField.frame = NSMakeRect(2, std::floor((height - labelSize.height) / 2),
                                      std::max<CGFloat>(0, detailX - 7), labelSize.height);
    _detail.frame = NSMakeRect(detailX, std::floor((height - detailSize.height) / 2), detailWidth, detailSize.height);
}

@end

@interface SearchOutline : NSOutlineView
@property(nonatomic, copy) void (^openSelection)(void);
@property(nonatomic, copy) NSMenu *(^resultMenu)(NSInteger row);
@end

@implementation SearchOutline

- (void)keyDown:(NSEvent *)event
{
    if (self.openSelection && (event.keyCode == 36 || event.keyCode == 76))
        self.openSelection();
    else
        [super keyDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    return self.resultMenu ? self.resultMenu(row) : nil;
}

@end

static NSImage *WholeWordIcon()
{
    NSFont *font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
    NSAttributedString *label = [[NSAttributedString alloc] initWithString:@"ab" attributes:@{
        NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.blackColor,
        NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle)}];
    NSSize size = NSMakeSize(std::ceil(label.size.width), std::ceil(label.size.height));
    NSImage *image = [NSImage imageWithSize:size flipped:YES drawingHandler:^BOOL(NSRect rect) {
        [label drawInRect:rect];
        return YES;
    }];
    [image setTemplate:YES];
    image.accessibilityDescription = @"Whole Word";
    return image;
}

@interface FolderSearchView : NSView <NSSearchFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>
- (instancetype)initWithWorkspace:(FolderWorkspace *)workspace;
- (void)focusSearch:(NSString *)selection replace:(BOOL)replace;
- (void)refreshSearch;
- (void)stopSearch;
@property(nonatomic, copy) FolderSearchOpenMatch openMatch;
@end

@implementation FolderSearchView {
    FolderWorkspace *_workspace;
    NSSearchField *_field;
    NSButton *_replaceToggle;
    NSSegmentedControl *_options;
    NSTextField *_replacement;
    NSSegmentedControl *_replaceActions;
    NSTextField *_summary;
    SearchOutline *_outline;
    NSScrollView *_scroll;
    NSArray<FolderSearchFile *> *_files;
    FolderSearchPattern *_pattern;
    NSString *_replaceStatus;
    NSString *_nextMatchPath;
    NSUInteger _nextMatchOffset;
    BOOL _showsReplace;
    BOOL _replacing;
    BOOL _limited;
    NSTimer *_debounce;
    dispatch_queue_t _searchQueue;
    std::shared_ptr<std::atomic_bool> _cancelled;
}

- (instancetype)initWithWorkspace:(FolderWorkspace *)workspace
{
    self = [super initWithFrame:NSZeroRect];
    if (!self)
        return nil;
    _workspace = workspace;
    _searchQueue = dispatch_queue_create("retina-code.folder-search", DISPATCH_QUEUE_SERIAL);

    _field = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _field.placeholderString = @"Find in Files";
    _field.accessibilityLabel = @"Find in Files";
    _field.sendsWholeSearchString = YES;
    _field.delegate = self;
    _field.target = self;
    _field.action = @selector(submitSearch:);
    [self addSubview:_field];

    _replaceToggle = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleReplace:)];
    _replaceToggle.bezelStyle = NSBezelStyleDisclosure;
    [_replaceToggle setButtonType:NSButtonTypeOnOff];
    _replaceToggle.accessibilityLabel = @"Show Replace";
    _replaceToggle.toolTip = @"Show Replace";
    [self addSubview:_replaceToggle];

    _options = [NSSegmentedControl segmentedControlWithLabels:@[@"Aa", @"", @".*"]
        trackingMode:NSSegmentSwitchTrackingSelectAny target:self action:@selector(changeSearchOptions:)];
    _options.controlSize = NSControlSizeSmall;
    _options.segmentStyle = NSSegmentStyleRounded;
    [_options setImage:WholeWordIcon() forSegment:1];
    [_options setToolTip:@"Match Case" forSegment:0];
    [_options setToolTip:@"Whole Word" forSegment:1];
    [_options setToolTip:@"Regular Expression" forSegment:2];
    for (NSInteger index = 0; index < _options.segmentCount; ++index)
        [_options setWidth:searchOptionSegmentWidth forSegment:index];
    [self addSubview:_options];

    _replacement = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _replacement.placeholderString = @"Replace";
    _replacement.accessibilityLabel = @"Replace";
    _replacement.usesSingleLineMode = YES;
    _replacement.delegate = self;
    _replacement.target = self;
    _replacement.action = @selector(replaceSelectedMatch:);
    _replacement.hidden = YES;
    [self addSubview:_replacement];

    _replaceActions = [NSSegmentedControl segmentedControlWithLabels:@[@"Replace", @"All"]
        trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(performReplaceAction:)];
    _replaceActions.controlSize = NSControlSizeSmall;
    _replaceActions.segmentStyle = NSSegmentStyleRounded;
    [_replaceActions setWidth:62 forSegment:0];
    [_replaceActions setWidth:30 forSegment:1];
    [_replaceActions setToolTip:@"Replace Match" forSegment:0];
    [_replaceActions setToolTip:@"Replace All in Folder" forSegment:1];
    _replaceActions.hidden = YES;
    [self addSubview:_replaceActions];

    _summary = [NSTextField labelWithString:@""];
    _summary.font = [NSFont systemFontOfSize:11];
    _summary.textColor = NSColor.secondaryLabelColor;
    _summary.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_summary];

    _outline = [[SearchOutline alloc] initWithFrame:NSZeroRect];
    _outline.accessibilityLabel = @"Search Results";
    _outline.style = NSTableViewStylePlain;
    _outline.headerView = nil;
    _outline.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    _outline.rowHeight = 19;
    _outline.indentationPerLevel = 12;
    _outline.intercellSpacing = NSMakeSize(2, 1);
    _outline.backgroundColor = NSColor.controlBackgroundColor;
    _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _outline.autoresizesOutlineColumn = NO;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"Match"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_outline addTableColumn:column];
    _outline.outlineTableColumn = column;
    _outline.dataSource = self;
    _outline.delegate = self;
    _outline.target = self;
    _outline.action = @selector(openClickedMatch:);
    __weak FolderSearchView *view = self;
    _outline.openSelection = ^{ [view activateSelection]; };
    _outline.resultMenu = ^NSMenu *(NSInteger row) { return [view menuForResultRow:row]; };

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.documentView = _outline;
    [self addSubview:_scroll];
    return self;
}

- (void)dealloc
{
    [self stopSearch];
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    const CGFloat left = 25, right = 8, gap = 5;
    const CGFloat optionsWidth = 3 * searchOptionSegmentWidth + 2, actionsWidth = 94;
    CGFloat fieldWidth = std::max<CGFloat>(0, width - left - right);
    BOOL wrapOptions = fieldWidth < optionsWidth + gap + 80;
    BOOL wrapReplace = fieldWidth < actionsWidth + gap + 78;
    CGFloat y = height - 30;
    _replaceToggle.frame = NSMakeRect(5, y + 3, 16, 16);
    _field.frame = NSMakeRect(left, y, wrapOptions ? fieldWidth : fieldWidth - optionsWidth - gap, 23);
    if (wrapOptions)
        y -= 24;
    _options.frame = NSMakeRect(width - right - optionsWidth, y + 1, optionsWidth, 21);
    if (_showsReplace) {
        y -= 27;
        _replacement.frame = NSMakeRect(left, y, wrapReplace ? fieldWidth : fieldWidth - actionsWidth - gap, 22);
        if (wrapReplace)
            y -= 24;
        _replaceActions.frame = NSMakeRect(width - right - actionsWidth, y, actionsWidth, 21);
    }
    _summary.frame = NSMakeRect(9, y - 20, std::max<CGFloat>(0, width - 18), 15);
    _scroll.frame = NSMakeRect(0, 0, width, std::max<CGFloat>(0, y - 24));
    [_outline sizeLastColumnToFit];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (!self.window)
        [self stopSearch];
    else if (!self.hidden)
        [self refreshSearch];
}

- (void)focusSearch:(NSString *)selection replace:(BOOL)replace
{
    if (selection.length && (!replace || !_field.stringValue.length)) {
        _field.stringValue = [_options isSelectedForSegment:2] ? [NSRegularExpression escapedPatternForString:selection] : selection;
    }
    if (replace)
        [self setShowsReplace:YES];
    NSTextField *focus = replace && _field.stringValue.length ? _replacement : _field;
    [focus selectText:nil];
    [self refreshSearch];
}

- (void)stopSearch
{
    [_debounce invalidate];
    _debounce = nil;
    if (_cancelled) {
        _cancelled->store(true, std::memory_order_relaxed);
        _cancelled.reset();
    }
}

- (void)refreshSearch
{
    [self stopSearch];
    if (_replacing)
        return;
    _pattern = nil;
    if (_files.count) {
        _files = nil;
        [_outline reloadData];
    }
    NSString *query = _field.stringValue;
    _summary.stringValue = @"";
    _summary.toolTip = nil;
    [self updateReplaceActions];
    if (!query.length || !self.window || self.hidden)
        return;
    __weak FolderSearchView *view = self;
    _debounce = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:NO block:^(NSTimer *) {
        [view startSearch:query];
    }];
}

- (void)startSearch:(NSString *)query
{
    _debounce = nil;
    FolderSearchPattern *pattern = [[FolderSearchPattern alloc] init];
    pattern.query = query;
    BOOL matchCase = [_options isSelectedForSegment:0];
    pattern.literalOptions = NSLiteralSearch | (matchCase ? 0 : NSCaseInsensitiveSearch);
    pattern.wholeWord = [_options isSelectedForSegment:1];
    if ([_options isSelectedForSegment:2]) {
        NSError *error = nil;
        NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
        if (!matchCase)
            options |= NSRegularExpressionCaseInsensitive;
        pattern.expression = [NSRegularExpression regularExpressionWithPattern:query options:options error:&error];
        if (!pattern.expression) {
            _summary.stringValue = @"Invalid regular expression";
            _summary.toolTip = error.localizedDescription;
            return;
        }
    }
    _summary.stringValue = @"Searching…";
    std::vector<SearchBuffer> buffers;
    NSURL *root = _workspace.folder;
    NSString *rootPrefix = [root.path hasSuffix:@"/"] ? root.path : [root.path stringByAppendingString:@"/"];
    for (NSDocument *open in NSDocumentController.sharedDocumentController.documents) {
        if (![open isKindOfClass:SourceDocument.class])
            continue;
        SourceDocument *document = (SourceDocument *)open;
        NSURL *url = document.fileURL.URLByStandardizingPath;
        if (url ? ![url.path hasPrefix:rootPrefix] || !document.isDocumentEdited : document.workspace != _workspace)
            continue;
        NSString *text = [document.sourceText copy];
        if (!url && !text.length)
            continue;
        FolderSearchFile *file = [[FolderSearchFile alloc] init];
        file.url = url;
        file.path = url ? [url.path substringFromIndex:rootPrefix.length] : document.displayName;
        file.document = document;
        buffers.push_back({url, file, text});
    }
    auto cancelled = std::make_shared<std::atomic_bool>(false);
    _cancelled = cancelled;
    __weak FolderSearchView *view = self;
    dispatch_async(_searchQueue, ^{
        FolderSearchResults results = SearchFolder(root, pattern, buffers, *cancelled);
        if (cancelled->load(std::memory_order_relaxed))
            return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!cancelled->load(std::memory_order_relaxed))
                [view showResults:results pattern:pattern];
        });
    });
}

- (void)showResults:(const FolderSearchResults &)results pattern:(FolderSearchPattern *)pattern
{
    _files = results.files;
    _pattern = pattern;
    _limited = results.limited;
    if (results.limited) {
        NSString *limit = [NSNumberFormatter localizedStringFromNumber:@(searchMatchLimit) numberStyle:NSNumberFormatterDecimalStyle];
        _summary.stringValue = [NSString stringWithFormat:@"Showing %@ matches", limit];
    } else if (results.count) {
        _summary.stringValue = [NSString stringWithFormat:@"%lu %@ in %lu %@", results.count,
            results.count == 1 ? @"match" : @"matches", _files.count, _files.count == 1 ? @"file" : @"files"];
    } else {
        _summary.stringValue = results.unreadable ? @"Couldn’t search some files" : @"No matches";
    }
    if (results.unreadable && results.count)
        _summary.toolTip = @"Some files couldn’t be read.";
    if (_replaceStatus.length) {
        _summary.toolTip = _summary.stringValue;
        _summary.stringValue = _replaceStatus;
    }
    [_outline reloadData];
    [_outline expandItem:nil expandChildren:YES];
    if (_nextMatchPath) {
        [self selectNextMatch];
        _nextMatchPath = nil;
    } else if (_outline.numberOfRows) {
        [_outline scrollRowToVisible:0];
    }
    [self updateReplaceActions];
}

- (void)selectNextMatch
{
    FolderSearchMatch *next = nil;
    for (FolderSearchFile *file in _files) {
        NSComparisonResult comparison = [file.path localizedStandardCompare:_nextMatchPath];
        if (comparison == NSOrderedAscending)
            continue;
        for (FolderSearchMatch *match in file.matches) {
            if (comparison == NSOrderedDescending || match.range.location >= _nextMatchOffset) {
                next = match;
                break;
            }
        }
        if (next)
            break;
    }
    if (!next)
        next = _files.firstObject.matches.firstObject;
    NSInteger row = next ? [_outline rowForItem:next] : -1;
    if (row >= 0) {
        [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_outline scrollRowToVisible:row];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    if (notification.object == _replacement) {
        [self refreshPreviews];
    } else {
        _replaceStatus = nil;
        _nextMatchPath = nil;
        [self refreshSearch];
    }
}

- (void)submitSearch:(id)sender
{
    (void)sender;
    _replaceStatus = nil;
    _nextMatchPath = nil;
    [self refreshSearch];
}

- (void)setShowsReplace:(BOOL)shown
{
    if (_showsReplace == shown)
        return;
    _showsReplace = shown;
    _replaceToggle.state = shown ? NSControlStateValueOn : NSControlStateValueOff;
    _replaceToggle.toolTip = shown ? @"Hide Replace" : @"Show Replace";
    _replaceToggle.accessibilityLabel = _replaceToggle.toolTip;
    _replacement.hidden = !shown;
    _replaceActions.hidden = !shown;
    self.needsLayout = YES;
    [self refreshPreviews];
    [self updateReplaceActions];
}

- (void)toggleReplace:(NSButton *)sender
{
    BOOL shown = sender.state == NSControlStateValueOn;
    [self setShowsReplace:shown];
    NSTextField *focus = shown && _field.stringValue.length ? _replacement : _field;
    [focus selectText:nil];
}

- (void)changeSearchOptions:(id)sender
{
    (void)sender;
    _replaceStatus = nil;
    _nextMatchPath = nil;
    [self refreshSearch];
}

- (void)refreshPreviews
{
    NSInteger rows = _outline.numberOfRows;
    if (rows > 0) {
        [_outline reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, rows)]
                           columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

- (void)updateReplaceActions
{
    BOOL ready = _showsReplace && !_replacing && _pattern && _files.count;
    [_replaceActions setEnabled:ready forSegment:0];
    [_replaceActions setEnabled:ready && !_limited forSegment:1];
    [_replaceActions setToolTip:_limited ? @"Narrow the search to replace all matches" : @"Replace All in Folder" forSegment:1];
}

- (void)performReplaceAction:(NSSegmentedControl *)sender
{
    if (sender.selectedSegment == 0) {
        [self replaceSelectedMatch:sender];
    } else if (!_limited) {
        [self replaceFiles:_files onlyMatch:nil];
    }
}

- (void)replaceSelectedMatch:(id)sender
{
    (void)sender;
    if (!_showsReplace || !_pattern || !_files.count || _replacing)
        return;
    id selected = _outline.selectedRow < 0 ? nil : [_outline itemAtRow:_outline.selectedRow];
    if ([selected isKindOfClass:FolderSearchMatch.class]) {
        FolderSearchFile *file = [_outline parentForItem:selected];
        if (file)
            [self replaceFiles:@[file] onlyMatch:selected];
    } else {
        FolderSearchFile *file = selected ? selected : _files.firstObject;
        [self replaceFiles:@[file] onlyMatch:file.matches.firstObject];
    }
}

- (NSMenu *)menuForResultRow:(NSInteger)row
{
    if (!_showsReplace || _replacing || !_pattern || row < 0)
        return nil;
    id item = [_outline itemAtRow:row];
    BOOL isMatch = [item isKindOfClass:FolderSearchMatch.class];
    FolderSearchFile *file = isMatch ? [_outline parentForItem:item] : item;
    if (!file)
        return nil;
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    if (isMatch) {
        NSMenuItem *replace = [menu addItemWithTitle:@"Replace Match" action:@selector(replaceResultFromMenu:) keyEquivalent:@""];
        replace.target = self;
        replace.representedObject = @[file, item];
    }
    NSMenuItem *all = [menu addItemWithTitle:@"Replace All in File…" action:@selector(replaceResultFromMenu:) keyEquivalent:@""];
    all.target = self;
    all.representedObject = @[file];
    all.enabled = !file.incomplete;
    return menu;
}

- (void)replaceResultFromMenu:(NSMenuItem *)sender
{
    NSArray *target = sender.representedObject;
    FolderSearchFile *file = target.firstObject;
    if ([_files indexOfObjectIdenticalTo:file] != NSNotFound)
        [self replaceFiles:@[file] onlyMatch:target.count == 2 ? target[1] : nil];
}

- (void)replaceFiles:(NSArray<FolderSearchFile *> *)files onlyMatch:(FolderSearchMatch *)match
{
    if (!_pattern || !_showsReplace || !files.count || _replacing || !self.window || self.window.attachedSheet)
        return;
    FolderReplace *task = [[FolderReplace alloc] init];
    task.files = files;
    task.onlyMatch = match;
    task.pattern = _pattern;
    task.replacement = _replacement.stringValue;
    if (match) {
        [self startReplacement:task];
        return;
    }

    NSUInteger count = 0;
    for (FolderSearchFile *file in files) {
        if (file.incomplete)
            return;
        count += file.matches.count;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Replace %lu %@ in %lu %@?", count,
                         count == 1 ? @"match" : @"matches", files.count, files.count == 1 ? @"file" : @"files"];
    alert.informativeText = @"Open files will be edited. Closed files will be saved.";
    [alert addButtonWithTitle:@"Replace All"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak FolderSearchView *view = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn)
            [view startReplacement:task];
    }];
}

- (void)startReplacement:(FolderReplace *)task
{
    _replacing = YES;
    _nextMatchPath = nil;
    if (FolderSearchMatch *match = task.onlyMatch) {
        _nextMatchPath = task.files.firstObject.path;
        NSString *replacement = FolderReplacement(task.replacement, match.captures);
        _nextMatchOffset = match.range.location + (match.range.length ? replacement.length : std::max<NSUInteger>(1, replacement.length));
    } else {
        _field.enabled = NO;
        _replacement.enabled = NO;
    }
    _options.enabled = NO;
    _replaceToggle.enabled = NO;
    _summary.stringValue = @"Replacing…";
    [self updateReplaceActions];
    __weak FolderSearchView *view = self;
    task.completion = ^(const FolderReplaceReport &report) { [view finishReplacement:report]; };
    [task advance];
}

- (void)finishReplacement:(const FolderReplaceReport &)report
{
    _replacing = NO;
    _field.enabled = YES;
    _options.enabled = YES;
    _replacement.enabled = YES;
    _replaceToggle.enabled = YES;
    _replaceStatus = report.replacements ? [NSString stringWithFormat:@"Replaced %lu in %lu %@", report.replacements,
        report.files, report.files == 1 ? @"file" : @"files"] : @"No changes";
    if (report.skipped && !report.replacements)
        _replaceStatus = [NSString stringWithFormat:@"Skipped %lu %@", report.skipped, report.skipped == 1 ? @"file" : @"files"];
    [self refreshSearch];
    if (report.skipped && self.window && !self.window.attachedSheet) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Skipped %lu %@", report.skipped, report.skipped == 1 ? @"file" : @"files"];
        alert.informativeText = report.firstError;
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
    (void)control;
    (void)textView;
    if (command != @selector(moveDown:) || !_outline.numberOfRows)
        return NO;
    NSInteger row = 0;
    for (NSInteger index = 0; index < _outline.numberOfRows; ++index) {
        if ([[_outline itemAtRow:index] isKindOfClass:FolderSearchMatch.class]) {
            row = index;
            break;
        }
    }
    [self.window makeFirstResponder:_outline];
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_outline scrollRowToVisible:row];
    return YES;
}

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item
{
    (void)outline;
    if (!item)
        return _files.count;
    return [item isKindOfClass:FolderSearchFile.class] ? [(FolderSearchFile *)item matches].count : 0;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item
{
    (void)outline;
    return item ? [(FolderSearchFile *)item matches][index] : _files[index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item
{
    (void)outline;
    return [item isKindOfClass:FolderSearchFile.class];
}

- (NSAttributedString *)resultPreview:(FolderSearchMatch *)match
{
    NSFont *font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    NSMutableAttributedString *label = [[NSMutableAttributedString alloc] initWithString:match.preview
        attributes:@{NSFontAttributeName:font}];
    NSRange emphasis = match.emphasis;
    NSString *replacement = _showsReplace ? FolderReplacement(_replacement.stringValue, match.captures) : nil;
    BOOL previewReplacement = replacement && ![replacement isEqualToString:match.original];
    if (previewReplacement && replacement.length) {
        if (replacement.length > 80) {
            NSRange excerpt = [replacement rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 80)];
            replacement = [[replacement substringWithRange:excerpt] stringByAppendingString:@"…"];
        }
        NSMutableString *visible = [replacement mutableCopy];
        [visible replaceOccurrencesOfString:@"\r\n" withString:@"↵" options:NSLiteralSearch range:NSMakeRange(0, visible.length)];
        [visible replaceOccurrencesOfString:@"\n" withString:@"↵" options:NSLiteralSearch range:NSMakeRange(0, visible.length)];
        [visible replaceOccurrencesOfString:@"\r" withString:@"↵" options:NSLiteralSearch range:NSMakeRange(0, visible.length)];
        [visible replaceOccurrencesOfString:@"\t" withString:@"⇥" options:NSLiteralSearch range:NSMakeRange(0, visible.length)];
        NSUInteger separation = emphasis.length ? 1 : 0;
        if (separation)
            [visible insertString:@" " atIndex:0];
        NSMutableAttributedString *inserted = [[NSMutableAttributedString alloc] initWithString:visible
            attributes:@{NSFontAttributeName:font}];
        [inserted addAttribute:NSBackgroundColorAttributeName value:[NSColor.systemGreenColor colorWithAlphaComponent:0.30]
            range:NSMakeRange(separation, inserted.length - separation)];
        [label insertAttributedString:inserted atIndex:NSMaxRange(emphasis)];
    }
    if (!emphasis.length && !previewReplacement) {
        [label replaceCharactersInRange:emphasis withString:@"│"];
        emphasis.length = 1;
    }
    if (emphasis.length) {
        NSColor *background = previewReplacement ? NSColor.systemRedColor : NSColor.systemYellowColor;
        [label addAttribute:NSBackgroundColorAttributeName value:[background colorWithAlphaComponent:0.30] range:emphasis];
        if (previewReplacement)
            [label addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:emphasis];
    }
    return label;
}

- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(id)item
{
    SearchResultCell *cell = [outline makeViewWithIdentifier:column.identifier owner:self];
    if (!cell) {
        cell = [[SearchResultCell alloc] init];
        cell.identifier = column.identifier;
    }
    if ([item isKindOfClass:FolderSearchFile.class]) {
        FolderSearchFile *file = item;
        NSString *name = file.url ? file.path.lastPathComponent : file.path;
        NSString *parent = file.url ? file.path.stringByDeletingLastPathComponent : nil;
        NSMutableAttributedString *label = [[NSMutableAttributedString alloc] initWithString:name attributes:@{
            NSFontAttributeName:[NSFont boldSystemFontOfSize:11]}];
        if (parent.length) {
            [label appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:parent]
                attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10], NSForegroundColorAttributeName:NSColor.secondaryLabelColor}]];
        }
        cell.textField.attributedStringValue = label;
        cell.detail.stringValue = @(file.matches.count).stringValue;
        cell.toolTip = file.path;
    } else {
        FolderSearchMatch *match = item;
        NSAttributedString *preview = [self resultPreview:match];
        cell.textField.attributedStringValue = preview;
        cell.detail.stringValue = @(match.line).stringValue;
        cell.toolTip = preview.string;
    }
    cell.needsLayout = YES;
    return cell;
}

- (void)openClickedMatch:(NSOutlineView *)outline
{
    NSInteger row = outline.clickedRow;
    if (row >= 0 && [[outline itemAtRow:row] isKindOfClass:FolderSearchMatch.class])
        [self openMatchAtRow:row];
}

- (void)activateSelection
{
    NSInteger row = _outline.selectedRow;
    if (row < 0)
        return;
    id item = [_outline itemAtRow:row];
    if ([item isKindOfClass:FolderSearchFile.class]) {
        if ([_outline isItemExpanded:item])
            [_outline collapseItem:item];
        else
            [_outline expandItem:item];
    } else {
        [self openMatchAtRow:row];
    }
}

- (void)openMatchAtRow:(NSInteger)row
{
    FolderSearchMatch *match = [_outline itemAtRow:row];
    FolderSearchFile *file = [_outline parentForItem:match];
    if (file && _openMatch && _pattern && !_replacing)
        _openMatch(file.url, file.document, _pattern, match.range);
}

@end

@implementation FolderSidebar {
    FolderWorkspace *_workspace;
    FolderSearchView *_search;
    NSSegmentedControl *_switcher;
    NSBox *_rule;
}

- (instancetype)initWithWorkspace:(FolderWorkspace *)workspace
{
    self = [super initWithFrame:NSZeroRect];
    if (!self)
        return nil;
    _workspace = workspace;
    self.autoresizingMask = NSViewHeightSizable;
    _switcher = [NSSegmentedControl segmentedControlWithLabels:@[@"Explorer", @"Search"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(switchPane:)];
    _switcher.segmentStyle = NSSegmentStyleRounded;
    _switcher.controlSize = NSControlSizeSmall;
    _switcher.selectedSegment = 0;
    [self addSubview:_switcher];
    _rule = [[NSBox alloc] initWithFrame:NSZeroRect];
    _rule.boxType = NSBoxSeparator;
    [self addSubview:_rule];
    _explorer = [[FolderExplorer alloc] initWithWorkspace:workspace];
    [self addSubview:_explorer positioned:NSWindowBelow relativeTo:_switcher];
    return self;
}

- (void)drawRect:(NSRect)dirty
{
    [NSColor.controlBackgroundColor setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    constexpr CGFloat switcherHeight = 28;
    CGFloat segmentWidth = std::max<CGFloat>(0, (width - 18) / 2);
    [_switcher setWidth:segmentWidth forSegment:0];
    [_switcher setWidth:segmentWidth forSegment:1];
    _switcher.frame = NSMakeRect(8, 4, std::max<CGFloat>(0, width - 16), 21);
    _rule.frame = NSMakeRect(0, switcherHeight - 1, width, 1);
    _explorer.frame = NSMakeRect(0, switcherHeight, width, std::max<CGFloat>(0, height - switcherHeight));
    _search.frame = _explorer.frame;
}

- (void)switchPane:(NSSegmentedControl *)sender
{
    if (sender.selectedSegment == 1) {
        [self showSearch:nil replace:NO];
    } else {
        [_search stopSearch];
        _search.hidden = YES;
        _explorer.hidden = NO;
        [_explorer focusFiles];
    }
}

- (void)showSearch:(NSString *)selection replace:(BOOL)replace
{
    if (!_search) {
        _search = [[FolderSearchView alloc] initWithWorkspace:_workspace];
        _search.openMatch = _openMatch;
        _search.frame = _explorer.frame;
        [self addSubview:_search positioned:NSWindowBelow relativeTo:_switcher];
    }
    _switcher.selectedSegment = 1;
    _explorer.hidden = YES;
    _search.hidden = NO;
    [_search focusSearch:selection replace:replace];
}

- (void)refreshSearch
{
    [_search refreshSearch];
}

@end