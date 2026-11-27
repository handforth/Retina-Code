#import "VimView.h"
#import "Editor.h"
#import <AppKit/NSTextInsertionIndicator.h>

#include <algorithm>
#include <cmath>
#include <utility>

static Vim::Registers registers;
static constexpr NSTimeInterval yankDuration = 0.18;

struct FileMark {
    char32_t key;
    __weak VimTextView *view;
    __weak NSTextStorage *storage;
    NSURL *url;
    NSUInteger offset;
};

static std::vector<FileMark> fileMarks;
static __weak VimTextView *undoingView;

static auto FindFileMark(char32_t key)
{
    return std::find_if(fileMarks.begin(), fileMarks.end(), [key](const FileMark &mark) { return mark.key == key; });
}

struct VimScrollAnimation {
    NSPoint from;
    NSPoint destination;
    NSUInteger firstCursorRow;
    NSTimeInterval start;
    NSTimeInterval duration;
};

static bool IsScrollMotion(Vim::Key key)
{
    using Vim::Key;
    switch (char32_t(key)) {
        case 'j': case 'k': case '+': case '-': case '\n': case '\r':
        case char32_t(Key::Up): case char32_t(Key::Down): case 14: case 16:
        case 2: case 4: case 5: case 6: case 21: case 25:
        case char32_t(Key::PageUp): case char32_t(Key::PageDown):
            return true;
        default:
            return false;
    }
}

static NSString *String(Vim::Text text)
{
    return text.empty() ? @"" : [[NSString alloc] initWithCharacters:(const unichar *)text.data() length:text.size()];
}

static std::u16string Units(NSString *string)
{
    std::u16string text(string.length, 0);
    if (!text.empty())
        [string getCharacters:(unichar *)text.data() range:NSMakeRange(0, text.size())];
    return text;
}

static NSString *const cursorClipboardType = @"org.source-editor.cursor-selections";

static std::optional<Vim::Register> ReadEditorClipboard()
{
    NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
    NSString *text = [clipboard stringForType:NSPasteboardTypeString];
    if (!text)
        return {};
    Vim::Register value;
    value.text = Units(text);
    if (value.text.ends_with(u"\n"))
        value.kind = Vim::Kind::Line;
    id property = [clipboard propertyListForType:cursorClipboardType];
    if (![property isKindOfClass:NSArray.class] || [property count] > 10000)
        return value;
    NSUInteger remaining = value.text.size();
    for (id entry in property) {
        id fragment = [entry isKindOfClass:NSDictionary.class] ? entry[@"text"] : nil;
        id kind = fragment ? entry[@"kind"] : nil;
        id width = fragment ? entry[@"width"] : nil;
        if (![fragment isKindOfClass:NSString.class] || ![kind isKindOfClass:NSNumber.class] ||
            ![width isKindOfClass:NSNumber.class] || [kind unsignedIntegerValue] > NSUInteger(Vim::Kind::Block) ||
            [fragment length] > remaining) {
            value.cursors.clear();
            break;
        }
        auto part = std::make_shared<Vim::Register>();
        part->text = Units(fragment);
        remaining -= part->text.size();
        part->kind = Vim::Kind([kind unsignedIntegerValue]);
        part->width = std::min(NSUInteger(10000), [width unsignedIntegerValue]);
        value.cursors.push_back(std::move(part));
    }
    return value;
}

static void WriteEditorClipboard(NSString *text, NSArray<NSDictionary *> *metadata = nil)
{
    NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
    [clipboard clearContents];
    [clipboard setString:text forType:NSPasteboardTypeString];
    if (metadata.count)
        [clipboard setPropertyList:metadata forType:cursorClipboardType];
}

static NSRange CocoaRange(Vim::Range range)
{
    return NSMakeRange(range.first, range.size());
}

static Vim::Range ToVimRange(NSRange range)
{
    return {range.location, NSMaxRange(range)};
}

static void ReplaceEditorText(NSTextStorage *storage, NSRange range, NSString *text, NSDictionary *attributes)
{
    if (text.length) {
        NSAttributedString *inserted = [[NSAttributedString alloc] initWithString:text attributes:attributes];
        [storage replaceCharactersInRange:range withAttributedString:inserted];
    } else {
        [storage deleteCharactersInRange:range];
    }
}

static VimTextView *View(void *context)
{
    return (__bridge VimTextView *)context;
}

struct CursorPosition {
    NSUInteger anchor;
    NSUInteger head;
    NSUInteger column = Vim::NoOffset;
    Vim::Mode mode = Vim::Mode::Normal;
    bool primary = false;
    bool beforeInlay = false;

    bool visual(bool vim) const { return !vim || Vim::IsVisual(mode); }
    NSUInteger first(bool vim) const { return visual(vim) ? std::min(anchor, head) : head; }
    NSUInteger last(bool vim) const { return visual(vim) ? std::max(anchor, head) : head; }
    NSRange range(bool vim) const { return NSMakeRange(first(vim), last(vim) - first(vim)); }
};

struct EditorCursor {
    CursorPosition position;
    std::unique_ptr<Vim::State> state;
};

struct CursorSnapshot {
    std::vector<CursorPosition> cursors;
    bool vim = false;
    NSString *occurrenceText = nil;
    NSUInteger occurrenceEnd = NSNotFound;
    bool wholeWord = false;
};

struct CursorUndoStep {
    Vim::EditBatch forward;
    Vim::EditBatch backward;
};

static bool CoalesceCursorInsertions(CursorUndoStep &previous, const Vim::EditBatch &next)
{
    auto &forward = previous.forward;
    auto &backward = previous.backward;
    NSUInteger count = forward.edits.size();
    if (count != backward.edits.size() || count != next.edits.size())
        return false;
    for (NSUInteger i = 0; i < count; ++i) {
        const auto &edit = next.edits[i];
        if (!edit.range.empty() || edit.range.first != backward.edits[i].range.last)
            return false;
    }
    NSUInteger added = 0;
    for (NSUInteger i = 0; i < count; ++i) {
        const auto &text = next.edits[i].text;
        forward.edits[i].newStart += added;
        forward.edits[i].text.append(text);
        backward.edits[i].range.first += added;
        added += text.size();
        backward.edits[i].range.last += added;
    }
    return true;
}

struct CursorChange {
    CursorSnapshot before;
    CursorSnapshot after;
    std::vector<CursorUndoStep> steps;
    NSString *actionName = nil;
};

static __weak NSTextStorage *batchStorage;
static const Vim::EditBatch *storageBatch;
static BOOL batchCaretAfterInsertion = YES;
static constexpr NSUInteger cursorLimit = 10000;

static NSString *TextByApplyingEdits(NSString *source, const Vim::EditBatch &batch, Vim::Range range)
{
    std::u16string text(batch.map(range.last) - range.first, 0);
    NSUInteger before = range.first;
    NSUInteger written = 0;
    for (const auto &edit : batch.edits) {
        NSUInteger count = edit.range.first - before;
        if (count) {
            [source getCharacters:reinterpret_cast<unichar *>(text.data() + written) range:NSMakeRange(before, count)];
            written += count;
        }
        std::copy(edit.text.begin(), edit.text.end(), text.begin() + written);
        written += edit.text.size();
        before = edit.range.last;
    }
    if (before < range.last)
        [source getCharacters:reinterpret_cast<unichar *>(text.data() + written)
                        range:NSMakeRange(before, range.last - before)];
    return String(text);
}

NSString *TextByApplyingEdits(NSString *source, const Vim::EditBatch &batch)
{
    if (batch.edits.empty())
        return source;
    return TextByApplyingEdits(source, batch, {0, source.length});
}

static NSString *DenseCursorReplacement(NSString *source, const Vim::EditBatch &batch)
{
    if (batch.edits.size() < 32)
        return nil;
    Vim::Range range{batch.edits.front().range.first, batch.edits.back().range.last};
    if (range.size() > batch.edits.size() * 128 || batch.map(range.last) - range.first > 4 * 1024 * 1024)
        return nil;
    // TextKit already invalidates the enclosing range. For dense edits, send it once.
    return TextByApplyingEdits(source, batch, range);
}

static Vim::Range ClusterInString(Vim::Text text, Vim::Offset at)
{
    return ToVimRange([String(text) rangeOfComposedCharacterSequenceAtIndex:at]);
}

static std::optional<Vim::Match> RegexMatch(NSRegularExpression *expression, NSString *text, NSRange range,
                                          bool backwards, bool captures)
{
    if (!expression || NSMaxRange(range) > text.length)
        return {};
    NSMatchingOptions options = NSMatchingWithTransparentBounds | NSMatchingWithoutAnchoringBounds;
    __block NSTextCheckingResult *result = nil;
    if (backwards) {
        [expression enumerateMatchesInString:text options:options range:range
                                   usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags, BOOL *) {
            if (match)
                result = match;
        }];
    } else {
        result = [expression firstMatchInString:text options:options range:range];
    }
    if (!result)
        return {};
    Vim::Match match{ToVimRange(result.range), {}};
    if (captures) {
        for (NSUInteger group = 1; group < result.numberOfRanges; ++group) {
            NSRange part = [result rangeAtIndex:group];
            match.groups.push_back(part.location == NSNotFound ? Vim::Range{Vim::NoOffset, Vim::NoOffset} :
                                                               ToVimRange(part));
        }
    }
    return match;
}

static std::optional<Vim::Match> FindInString(Vim::Text text, Vim::Text pattern, Vim::Range range,
                                            bool backwards, bool ignoreCase, bool captures)
{
    NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
    if (ignoreCase)
        options |= NSRegularExpressionCaseInsensitive;
    auto expression = [NSRegularExpression regularExpressionWithPattern:String(pattern) options:options error:nil];
    return RegexMatch(expression, String(text), CocoaRange(range), backwards, captures);
}

API_AVAILABLE(macos(14.0))
@interface EditorInsertionIndicator : NSTextInsertionIndicator
@end

@implementation EditorInsertionIndicator
- (NSView *)hitTest:(NSPoint)point
{
    (void)point;
    return nil;
}
@end

@interface EditorInlayCaret : NSView
@property(nonatomic) NSColor *color;
@end

@implementation EditorInlayCaret
- (NSView *)hitTest:(NSPoint)point
{
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirty
{
    [self.color setFill];
    NSRectFill(dirty);
}
@end

@implementation VimTextView {
    std::unique_ptr<Vim::State> _vim;
    BOOL _vimEnabled;
    BOOL _applyingKey;
    BOOL _undoingVimKey;
    BOOL _writingVimStorage;
    BOOL _selectingWithMouse;
    BOOL _hadVimHighlight;
    BOOL _hidesNativeInsertionPoint;
    BOOL _insertionIndicatorPending;
    BOOL _plainBeforeInlay;
    NSView *_insertionIndicator;
    EditorInlayCaret *_inlayCaret;
    NSRect _vimCaretRect;
    NSFont *_caretFont;
    CGFloat _caretWidth;
    CGFloat _caretSpaceWidth;
    std::optional<NSUInteger> _requestedScrollRow;
    std::optional<VimScrollAnimation> _scrollAnimation;
    NSUInteger _displayedCursor;
    NSTimer *_scrollTimer;
    NSTimer *_flashTimer;
    NSTimer *_mappingTimer;
    NSTimeInterval _flashStart;
    std::vector<NSRect> _flashRects;
    NSString *_composition;
    NSString *_pattern;
    NSRegularExpression *_expression;
    BOOL _patternIgnoreCase;
    std::vector<EditorCursor> _cursors;
    std::vector<CursorSnapshot> _cursorHistory;
    std::shared_ptr<CursorChange> _cursorChange;
    std::vector<TypingEdit> _cursorTyping;
    BOOL _planningCursors;
    BOOL _publishingCursors;
    BOOL _foreignCursorDisplayPending;
    BOOL _skipOccurrence;
    BOOL _occurrenceWholeWord;
    NSUInteger _occurrenceEnd;
    NSString *_occurrenceText;
}

- (std::optional<Vim::Match>)findVimPattern:(NSString *)pattern
                                    range:(NSRange)range backward:(BOOL)backwards
                               ignoreCase:(BOOL)ignoreCase captures:(BOOL)captures
{
    if (![_pattern isEqualToString:pattern] || _patternIgnoreCase != ignoreCase) {
        _pattern = pattern;
        _patternIgnoreCase = ignoreCase;
        NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
        if (ignoreCase)
            options |= NSRegularExpressionCaseInsensitive;
        _expression = [NSRegularExpression regularExpressionWithPattern:pattern options:options error:nil];
    }
    return RegexMatch(_expression, self.string, range, backwards, captures);
}

- (Vim::Host)vimHost
{
    BOOL folds = [self hasVimFolds];
    return {
        .context = (__bridge void *)self,
        .length = [](void *context) { return View(context).string.length; },
        .lineCount = [](void *context) { return View(context).vimDocumentLineCount; },
        .lineAt = [](void *context, Vim::Offset at) { return [View(context) vimLineAtOffset:at]; },
        .lineStart = [](void *context, Vim::Offset line) { return [View(context) vimOffsetAtLine:line]; },
        .read = [](void *context, Vim::Range range, char16_t *output) {
            [View(context).string getCharacters:(unichar *)output range:CocoaRange(range)];
        },
        .cluster = [](void *context, Vim::Offset position) {
            return ToVimRange([View(context).string rangeOfComposedCharacterSequenceAtIndex:position]);
        },
        .structural = [](void *context, Vim::Offset position) -> bool {
            return [View(context) vimStructuralCharacterAtOffset:position];
        },
        .replace = [](void *context, Vim::Range range, Vim::Text text) {
            [View(context) replaceVimRange:CocoaRange(range) withString:String(text)];
        },
        .recordUndo = [](void *context, std::shared_ptr<Vim::Change> change) {
            [View(context) registerVimUndo:std::move(change) redo:NO];
        },
        .undo = [](void *context, bool redo) { return [View(context) performVimUndo:redo]; },
        .flash = [](void *context, const std::vector<Vim::Range> &ranges, Vim::Kind kind) {
            [View(context) flashVimRanges:ranges linewise:kind == Vim::Kind::Line];
        },
        .readClipboard = [](void *) { return ReadEditorClipboard(); },
        .writeClipboard = [](void *, Vim::Text text) { WriteEditorClipboard(String(text)); },
        .find = [](void *context, Vim::Text text, Vim::Range range, bool back, bool ignoreCase, bool captures) {
            return [View(context) findVimPattern:String(text) range:CocoaRange(range) backward:back
                                      ignoreCase:ignoreCase captures:captures];
        },
        .viewport = [](void *context) {
            VimTextView *view = View(context);
            return [view vimRowsInViewport:[view intendedVimViewport]];
        },
        .scroll = [](void *context, Vim::Offset row) { View(context)->_requestedScrollRow = row; },
        .action = [](void *context, Vim::Action action, Vim::Text value, bool force) {
            void (^callback)(Vim::Action, NSString *, BOOL) = View(context).vimAction;
            if (callback) {
                NSString *argument = String(value);
                dispatch_async(dispatch_get_main_queue(), ^{ callback(action, argument, force); });
            }
        },
        .planInsert = [](void *context, Vim::Key key, Vim::Offset at, unsigned tabWidth,
                         unsigned indentWidth, bool spaces, bool automatic) {
            return [View(context) planVimInsert:key at:at tabWidth:tabWidth indentWidth:indentWidth
                                         spaces:spaces automaticIndent:automatic];
        },
        .finishInsertEdit = [](void *context) { [View(context) finishVimInsertEdit]; },
        .indentAfter = [](void *context, Vim::Offset at, unsigned tabWidth, unsigned indentWidth, bool spaces) {
            return Units([View(context) vimIndentAfter:at tabWidth:tabWidth indentWidth:indentWidth spaces:spaces]);
        },
        .fileName = [](void *context) { return Units(View(context).vimDocument.fileURL.path); },
        .fileMark = [](void *context, char32_t key) -> Vim::Offset {
            VimTextView *view = View(context);
            auto mark = FindFileMark(key);
            return mark != fileMarks.end() && mark->storage == view.textStorage ?
                   std::min(mark->offset, view.string.length) : Vim::NoOffset;
        },
        .setFileMark = [](void *context, char32_t key, Vim::Offset at) {
            VimTextView *view = View(context);
            FileMark mark{key, view, view.textStorage, view.vimDocument.fileURL, at};
            auto previous = FindFileMark(key);
            if (previous == fileMarks.end())
                fileMarks.push_back(mark);
            else
                *previous = mark;
        },
        .comments = [](void *context) { return [View(context) vimComments]; },
        .definition = [](void *context, Vim::Offset at) { return [View(context) vimDefinitionAt:at]; },
        .fold = [](void *context, char32_t command, Vim::Offset at) { return [View(context) vimFold:command at:at]; },
        .stepRow = folds ? +[](void *context, Vim::Offset row, bool down, Vim::Offset count) {
            return [View(context) vimStepRow:row down:down count:count];
        } : nullptr,
        .hiddenRows = folds ? +[](void *context, Vim::Range rows) {
            return [View(context) vimHiddenRows:rows];
        } : nullptr,
        .writeCursorClipboard = [](void *, const Vim::Register &value) {
            NSMutableArray<NSDictionary *> *metadata = [NSMutableArray arrayWithCapacity:value.cursors.size()];
            for (const auto &part : value.cursors)
                [metadata addObject:@{@"text":String(part->text), @"kind":@(NSUInteger(part->kind)), @"width":@(part->width)}];
            WriteEditorClipboard(String(value.text), metadata);
        },
        .inlayAt = [](void *context, Vim::Offset at) {
            return [View(context) inlayWidthAtInsertion:at] > 0;
        },
    };
}

- (void)visitVimFileMark:(NSUInteger)offset exact:(BOOL)exact
{
    [self visitVimFileMark:offset exact:exact centerVertically:NO];
}

- (void)visitDefinitionAtOffset:(NSUInteger)offset
{
    [self visitVimFileMark:offset exact:YES centerVertically:YES];
}

- (void)visitVimFileMark:(NSUInteger)offset exact:(BOOL)exact centerVertically:(BOOL)center
{
    [self clearAdditionalCursors];
    [self finishVimChange];
    [self cancelVimScroll];
    offset = std::min(offset, self.string.length);
    if (!exact) {
        NSUInteger line = [self vimLineAtOffset:offset];
        offset = [self vimOffsetAtLine:line];
        while (offset < self.string.length) {
            unichar ch = [self.string characterAtIndex:offset];
            if (ch != ' ' && ch != '\t')
                break;
            ++offset;
        }
    }
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self];
    [self revealVimFoldAt:offset];
    if (_vimEnabled) {
        Vim::MouseSelection(*_vim, [self vimHost], {offset, offset});
    } else {
        self.selectedRange = NSMakeRange(offset, 0);
    }
    if (center)
        [self centerEditorAtOffset:offset];
    if (_vimEnabled)
        [self refreshVimSelection:!center];
    else if (!center)
        [self scrollRangeToVisible:self.selectedRange];
}

- (void)revealSearchMatch:(NSRange)range
{
    [self visitVimFileMark:range.location exact:YES];
    if (_vimEnabled) {
        [self flashVimRanges:{ToVimRange(range)} linewise:NO];
    } else {
        self.selectedRange = range;
        [self scrollRangeToVisible:range];
    }
}

+ (void)jumpToVimFileMark:(char32_t)key exact:(BOOL)exact inWindow:(NSWindow *)window
{
    auto found = FindFileMark(key);
    if (found == fileMarks.end())
        return;
    NSUInteger offset = found->offset;
    VimTextView *view = found->view;
    SourceDocument *source = [view.vimDocument isKindOfClass:SourceDocument.class] ? (SourceDocument *)view.vimDocument : nil;
    if (source.editorHostWindow && [source joinNavigationTabInWindow:window]) {
        [source showWindows];
        [view visitVimFileMark:offset exact:exact];
        return;
    }
    if (!source && view.window) {
        [view visitVimFileMark:offset exact:exact];
        return;
    }
    NSURL *url = view.vimDocument.fileURL;
    if (!url)
        url = found->url;
    if (url) {
        OpenSourceTab(url, window, ^(NSDocument *document, BOOL, NSError *error) {
            if (error) {
                [NSApp presentError:error];
                return;
            }
            NSWindow *targetWindow = [document isKindOfClass:SourceDocument.class] ?
                [(SourceDocument *)document editorHostWindow] : document.windowControllers.firstObject.window;
            NSResponder *responder = targetWindow.initialFirstResponder;
            if ([responder isKindOfClass:VimTextView.class]) {
                VimTextView *target = (VimTextView *)responder;
                auto mark = FindFileMark(key);
                if (mark != fileMarks.end() && [mark->url isEqual:url] && mark->offset == offset) {
                    mark->view = target;
                    mark->storage = target.textStorage;
                }
                [target visitVimFileMark:offset exact:exact];
            }
        });
    }
}

- (BOOL)vimEnabled { return _vimEnabled; }

- (void)setVimEnabled:(BOOL)enabled
{
    if (_vimEnabled == enabled)
        return;
    if (_mappingTimer)
        [self applyVimKey:Vim::Key::None text:nil];
    [self breakUndoCoalescing];
    [self clearAdditionalCursors];
    _cursorHistory.clear();
    [self finishVimChange];
    [self cancelVimScroll];
    [self cancelVimFlash];
    _composition = nil;
    _plainBeforeInlay = NO;
    _vimEnabled = enabled;
    if (enabled) {
        if (!_vim) {
            _vim = std::make_unique<Vim::State>();
            [self configureVimState:*_vim];
        }
        Vim::MouseSelection(*_vim, [self vimHost], ToVimRange(self.selectedRange));
    } else {
        if (Vim::IsVisual(_vim->mode)) {
            auto selected = Vim::Selected(*_vim, [self vimHost]);
            if (selected.ranges.size() == 1)
                self.selectedRange = CocoaRange(selected.ranges.front());
        }
        _vim.reset();
    }
    [self refreshVimSelection:NO];
    [self setNeedsDisplay:YES];
}

- (void)setSmoothScrollingEnabled:(BOOL)enabled
{
    if (_smoothScrollingEnabled == enabled)
        return;
    _smoothScrollingEnabled = enabled;
    if (!enabled)
        [self finishVimScroll];
}

- (NSUInteger)vimCursor { return _vimEnabled ? _vim->cursor : self.selectedRange.location; }
- (NSUInteger)vimDisplayedCursor { return _scrollAnimation ? _displayedCursor : self.vimCursor; }
- (NSUInteger)vimTabStop { return _vimEnabled ? _vim->tabStop : 4; }
- (Indentation)vimIndentation
{
    return _vimEnabled ? Indentation{_vim->tabStop, _vim->shiftWidth, !_vim->expandTab, true} : [self cursorIndentation];
}

- (void)setVimIndentation:(Indentation)indentation
{
    if (!_vim)
        return;
    auto update = [&](Vim::State &state) {
        if (state.tabStop != indentation.tabWidth)
            state.goalColumn = Vim::NoOffset;
        state.tabStop = unsigned(indentation.tabWidth);
        state.shiftWidth = unsigned(indentation.width);
        state.expandTab = !indentation.tabs;
    };
    update(*_vim);
    for (auto &cursor : _cursors) {
        if (cursor.state)
            update(*cursor.state);
    }
}
- (BOOL)vimCommandLine { return _vimEnabled && (_vim->mode == Vim::Mode::Command || _vim->mode == Vim::Mode::Confirm); }
- (BOOL)vimInserting { return _vimEnabled && Vim::IsInsert(_vim->mode); }
- (BOOL)trackingVimMouseSelection { return _selectingWithMouse; }
- (BOOL)vimCanComplete
{
    return _vimEnabled && _vim->mode == Vim::Mode::Insert && _vim->prefix == Vim::Prefix::None &&
           _vim->insertMirrors.empty();
}
- (NSString *)vimStatus { return _vimEnabled ? String(Vim::Status(*_vim)) : @""; }
- (NSUInteger)vimCommandCaret
{
    return _vimEnabled && _vim->mode == Vim::Mode::Command ? _vim->commandCaret + 1 : NSNotFound;
}

- (NSString *)vimLineNumber:(NSUInteger)line current:(NSUInteger)current
{
    NSUInteger value = line + 1;
    if (_vimEnabled) {
        if (!_vim->relativeNumber && !_vim->number)
            return @"";
        if (_vim->relativeNumber && (line != current || !_vim->number))
            value = line > current ? line - current : current - line;
    }
    return [NSString stringWithFormat:@"%lu", (unsigned long)value];
}

- (NSUInteger)cursorCount { return std::max(NSUInteger(1), _cursors.size()); }

- (Vim::State &)stateForCursor:(const EditorCursor &)cursor
{
    return cursor.position.primary ? *_vim : *cursor.state;
}

- (void)readVimCursorPositions
{
    if (!_vimEnabled)
        return;
    for (auto &cursor : _cursors) {
        const auto &state = [self stateForCursor:cursor];
        cursor.position.anchor = state.anchor;
        cursor.position.head = state.cursor;
        cursor.position.column = state.goalColumn;
        cursor.position.mode = state.mode;
        cursor.position.beforeInlay = state.beforeInlay;
    }
}

- (void)beginCursorSelection
{
    if (!_cursors.empty())
        return;
    NSRange range = self.selectedRange;
    CursorPosition point{range.location, NSMaxRange(range)};
    if (_vimEnabled)
        point = {_vim->anchor, _vim->cursor, _vim->goalColumn, _vim->mode};
    point.primary = true;
    point.beforeInlay = _vimEnabled ? _vim->beforeInlay : _plainBeforeInlay;
    _cursors.push_back({point, nullptr});
}

- (CursorSnapshot)cursorSnapshot
{
    CursorSnapshot saved{{}, bool(_vimEnabled), _occurrenceText, _occurrenceEnd, bool(_occurrenceWholeWord)};
    saved.cursors.reserve(_cursors.size());
    for (const auto &cursor : _cursors)
        saved.cursors.push_back(cursor.position);
    return saved;
}

- (NSArray<NSArray<NSNumber *> *> *)sessionCursors
{
    if (_cursors.empty()) {
        NSRange range = _vimEnabled ? NSMakeRange(_vim->cursor, 0) : self.selectedRange;
        return @[@[@(range.location), @(NSMaxRange(range))]];
    }
    NSMutableArray *positions = [NSMutableArray arrayWithCapacity:_cursors.size()];
    for (const auto &cursor : _cursors) {
        NSUInteger head = _vimEnabled ? [self stateForCursor:cursor].cursor : cursor.position.head;
        NSUInteger anchor = _vimEnabled ? head : cursor.position.anchor;
        NSArray *position = @[@(anchor), @(head)];
        if (cursor.position.primary)
            [positions insertObject:position atIndex:0];
        else
            [positions addObject:position];
    }
    return positions;
}

- (void)restoreSessionCursors:(NSArray *)positions
{
    CursorSnapshot snapshot{{}, bool(_vimEnabled), nil, 0, false};
    NSUInteger length = self.string.length;
    for (id value in positions) {
        if (![value isKindOfClass:NSArray.class] || [value count] != 2)
            continue;
        NSArray *pair = value;
        if (![pair[0] isKindOfClass:NSNumber.class] || ![pair[1] isKindOfClass:NSNumber.class])
            continue;
        NSUInteger head = std::min([pair[1] unsignedIntegerValue], length);
        NSUInteger anchor = _vimEnabled ? head : std::min([pair[0] unsignedIntegerValue], length);
        snapshot.cursors.push_back({anchor, head, Vim::NoOffset, Vim::Mode::Normal, snapshot.cursors.empty()});
        if (snapshot.cursors.size() == cursorLimit)
            break;
    }
    if (!snapshot.cursors.empty())
        [self restoreCursorSnapshot:snapshot];
}

- (std::unique_ptr<Vim::State>)stateForNewCursor
{
    if (!_vimEnabled)
        return nullptr;
    auto state = std::make_unique<Vim::State>();
    [self configureVimState:*state];
    state->mode = _vim->mode;
    state->finalNewline = _vim->finalNewline;
    state->repeat = _vim->repeat;
    state->lastSearch = _vim->lastSearch;
    state->searchBackwards = _vim->searchBackwards;
    state->lastFind = _vim->lastFind;
    state->lastFindCommand = _vim->lastFindCommand;
    state->ignoreCase = _vim->ignoreCase;
    state->smartCase = _vim->smartCase;
    state->wrapSearch = _vim->wrapSearch;
    state->autoIndent = _vim->autoIndent;
    state->expandTab = _vim->expandTab;
    state->tabStop = _vim->tabStop;
    state->shiftWidth = _vim->shiftWidth;
    state->scrollLines = _vim->scrollLines;
    return state;
}

- (void)setVimCursor:(Vim::State &)state fromPosition:(CursorPosition)point
{
    state.mode = point.mode;
    Vim::SetCursor(state, [self vimHost], point.head);
    if (Vim::IsVisual(point.mode))
        state.cursor = std::min(point.head, self.string.length);
    state.anchor = std::min(point.anchor, self.string.length);
    state.goalColumn = point.column;
    state.beforeInlay = state.cursor == point.head && point.beforeInlay &&
                       (point.mode == Vim::Mode::Insert || point.mode == Vim::Mode::Normal);
    if (Vim::IsInsert(point.mode)) {
        state.insertStart = state.commandStart = state.cursor;
        if (state.inputs.empty())
            state.inputs.push_back({point.mode == Vim::Mode::Replace ? Vim::Key('R') : Vim::Key('i'), {}});
    }
}

- (void)appendCursor:(CursorPosition)point
{
    auto state = [self stateForNewCursor];
    if (state) {
        [self setVimCursor:*state fromPosition:point];
        point.head = state->cursor;
        point.anchor = state->anchor;
    }
    _cursors.push_back({point, std::move(state)});
}

- (void)resetOccurrenceSearch
{
    _occurrenceText = nil;
    _skipOccurrence = NO;
    _occurrenceEnd = NSNotFound;
}

- (void)finishCursorChange
{
    if (!_cursorChange)
        return;
    if (!_cursors.empty())
        _cursorChange->after = [self cursorSnapshot];
    _cursorChange.reset();
}

- (void)saveCursorHistory
{
    NSUInteger total = _cursors.size();
    auto first = _cursorHistory.end();
    while (first != _cursorHistory.begin() && _cursorHistory.end() - first < 23 &&
           total + (first - 1)->cursors.size() <= 50000) {
        --first;
        total += first->cursors.size();
    }
    _cursorHistory.erase(_cursorHistory.begin(), first);
    _cursorHistory.push_back([self cursorSnapshot]);
}

- (void)normalizeCursors
{
    if (_cursors.size() < 2)
        return;
    bool vim = _vimEnabled;
    auto order = [vim](const EditorCursor &a, const EditorCursor &b) {
        NSUInteger first = a.position.first(vim), other = b.position.first(vim);
        if (first != other)
            return first < other;
        return a.position.last(vim) < b.position.last(vim);
    };
    if (!std::is_sorted(_cursors.begin(), _cursors.end(), order))
        std::sort(_cursors.begin(), _cursors.end(), order);
    NSUInteger count = 1;
    for (NSUInteger i = 1; i < _cursors.size(); ++i) {
        auto &previous = _cursors[count - 1];
        auto &next = _cursors[i];
        NSUInteger first = next.position.first(vim);
        NSUInteger end = previous.position.last(vim);
        bool inclusive = vim && Vim::IsVisual(previous.position.mode);
        bool touchingCaret = end == previous.position.first(vim) || first == next.position.last(vim);
        bool sameLine = vim && previous.position.mode == Vim::Mode::VisualLine &&
                        next.position.mode == Vim::Mode::VisualLine &&
                        [self vimLineAtOffset:end] == [self vimLineAtOffset:first];
        bool overlap = first < end || (first == end && (inclusive || touchingCaret));
        if (vim && previous.position.mode == Vim::Mode::VisualBlock) {
            overlap = previous.position.head == next.position.head && previous.position.anchor == next.position.anchor;
        }
        if (sameLine || overlap) {
            NSUInteger low = previous.position.first(vim);
            NSUInteger high = std::max(end, next.position.last(vim));
            if (next.position.primary)
                previous = std::move(next);
            auto &point = previous.position;
            if (point.visual(vim) && (low != point.first(vim) || high != point.last(vim))) {
                bool backwards = point.head < point.anchor;
                point.anchor = backwards ? high : low;
                point.head = backwards ? low : high;
                if (vim) {
                    auto &state = [self stateForCursor:previous];
                    state.anchor = point.anchor;
                    state.cursor = point.head;
                }
            }
            continue;
        }
        if (count != i)
            _cursors[count] = std::move(next);
        ++count;
    }
    _cursors.resize(count);
}

- (void)publishCursorSelection:(BOOL)reveal
{
    [self readVimCursorPositions];
    [self normalizeCursors];
    if (_cursors.empty())
        return;
    auto active = std::find_if(_cursors.begin(), _cursors.end(), [](const EditorCursor &cursor) {
        return cursor.position.primary;
    });
    NSAssert(active != _cursors.end(), @"A cursor selection must have a primary cursor");
    if (active == _cursors.end())
        return;
    CursorPosition point = active->position;
    _publishingCursors = YES;
    if (_vimEnabled) {
        [self refreshVimSelection:reveal];
    } else {
        self.selectedRange = point.range(false);
        [self setPlainCaretBeforeInlay:point.beforeInlay && point.anchor == point.head];
        if (reveal)
            [self revealInsertionAt:point.head];
        if (self.vimStatusChanged)
            self.vimStatusChanged();
    }
    _publishingCursors = NO;
    if (_cursors.size() == 1)
        _cursors.clear();
    [self setNeedsDisplayInRect:self.visibleRect];
}

- (void)clearAdditionalCursors
{
    [self finishCursorChange];
    if (!_cursors.empty()) {
        _cursors.clear();
        [self setNeedsDisplayInRect:self.visibleRect];
        if (self.vimStatusChanged)
            self.vimStatusChanged();
    }
    [self resetOccurrenceSearch];
}

- (void)restoreCursorSnapshot:(const CursorSnapshot &)snapshot
{
    _cursors.clear();
    if (snapshot.cursors.empty())
        return;
    _occurrenceText = snapshot.occurrenceText;
    _occurrenceEnd = snapshot.occurrenceEnd;
    _occurrenceWholeWord = snapshot.wholeWord;
    for (auto point : snapshot.cursors) {
        if (_vimEnabled != snapshot.vim) {
            point.anchor = point.head;
            point.mode = _vimEnabled ? _vim->mode : Vim::Mode::Normal;
        }
        point.head = std::min(point.head, self.string.length);
        point.anchor = std::min(point.anchor, self.string.length);
        if (point.primary) {
            if (_vimEnabled)
                [self setVimCursor:*_vim fromPosition:point];
            _cursors.push_back({point, nullptr});
        } else {
            [self appendCursor:point];
        }
    }
    [self publishCursorSelection:YES];
}

- (void)startAddingCursors
{
    [self prepareCursorBatch];
    [self breakUndoCoalescing];
    [self finishCursorChange];
    [self finishVimChange];
    [self cancelVimScroll];
    [self beginCursorSelection];
    [self saveCursorHistory];
}

- (void)addCursorsVertically:(BOOL)down
{
    if (!self.editable || self.vimCommandLine || self.hasMarkedText)
        return;
    [self startAddingCursors];
    [self resetOccurrenceSearch];
    auto host = [self vimHost];
    unsigned tabWidth = _vimEnabled ? _vim->tabStop : unsigned([self cursorIndentation].tabWidth);
    bool eof = _vimEnabled && _vim->finalNewline.value_or(true) && !Vim::IsInsert(_vim->mode);
    NSUInteger count = _cursors.size();
    NSUInteger reveal = Vim::NoOffset;
    std::vector<CursorPosition> additions;
    additions.reserve(std::min(count, cursorLimit - count));
    for (NSUInteger i = 0; i < count && count + additions.size() < cursorLimit; ++i) {
        auto &source = _cursors[i].position;
        NSUInteger row = [self vimLineAtOffset:source.head];
        NSUInteger target = [self vimStepRow:row down:down count:1];
        if (target == row || target >= self.vimDocumentLineCount)
            continue;
        if (source.column == Vim::NoOffset)
            source.column = Vim::CursorColumn(host, source.head, tabWidth, false);
        if (_vimEnabled)
            [self stateForCursor:_cursors[i]].goalColumn = source.column;
        CursorPosition point = source;
        point.primary = false;
        bool block = _vimEnabled && point.mode == Vim::Mode::Normal;
        point.head = Vim::CursorAtColumn(host, target, source.column, tabWidth, eof, block);
        if (point.head == Vim::NoOffset)
            continue;
        point.anchor = point.head;
        if (source.visual(_vimEnabled) && source.anchor != source.head) {
            NSUInteger anchorRow = [self vimLineAtOffset:source.anchor];
            NSUInteger other = [self vimStepRow:anchorRow down:down count:1];
            NSUInteger column = Vim::CursorColumn(host, source.anchor, tabWidth, false);
            NSUInteger anchor = Vim::CursorAtColumn(host, other, column, tabWidth, eof);
            if (anchor != Vim::NoOffset)
                point.anchor = anchor;
        }
        reveal = reveal == Vim::NoOffset ? point.head : down ? std::max(reveal, point.head) : std::min(reveal, point.head);
        NSUInteger start = point.first(_vimEnabled);
        auto existing = std::lower_bound(_cursors.begin(), _cursors.end(), start,
                                         [&](const EditorCursor &cursor, NSUInteger at) {
            return cursor.position.first(_vimEnabled) < at;
        });
        if (existing == _cursors.end() || existing->position.first(_vimEnabled) != start ||
            existing->position.last(_vimEnabled) != point.last(_vimEnabled)) {
            additions.push_back(point);
        }
    }
    for (auto point : additions)
        [self appendCursor:point];
    if (additions.empty() && !_cursorHistory.empty())
        _cursorHistory.pop_back();
    [self publishCursorSelection:NO];
    if (reveal != Vim::NoOffset)
        [self revealVimCaret:[self vimCaretAt:reveal] withContext:NO];
}

- (IBAction)addCursorAbove:(id)sender { (void)sender; [self addCursorsVertically:NO]; }
- (IBAction)addCursorBelow:(id)sender { (void)sender; [self addCursorsVertically:YES]; }

- (IBAction)undoCursorChange:(id)sender
{
    (void)sender;
    if (_cursorHistory.empty())
        return;
    [self finishCursorChange];
    [self finishVimChange];
    [self resetOccurrenceSearch];
    auto saved = std::move(_cursorHistory.back());
    _cursorHistory.pop_back();
    [self restoreCursorSnapshot:saved];
}

- (NSRange)selectionForCursor:(const EditorCursor &)cursor
{
    if (!_vimEnabled)
        return cursor.position.range(false);
    const auto &state = [self stateForCursor:cursor];
    if (Vim::IsVisual(state.mode)) {
        auto selection = Vim::Selected(state, [self vimHost]);
        if (selection.ranges.size() == 1)
            return CocoaRange(selection.ranges.front());
    }
    return NSMakeRange(state.cursor, 0);
}

- (void)addOccurrence:(NSRange)range primary:(BOOL)primary
{
    CursorPosition point{range.location, NSMaxRange(range)};
    if (_vimEnabled) {
        auto state = primary ? nullptr : [self stateForNewCursor];
        auto &target = primary ? *_vim : *state;
        Vim::MouseSelection(target, [self vimHost], ToVimRange(range));
        point = {target.anchor, target.cursor, target.goalColumn, target.mode, bool(primary)};
        if (!primary) {
            _cursors.push_back({point, std::move(state)});
            return;
        }
    }
    if (primary) {
        point.primary = true;
        for (auto &cursor : _cursors) {
            if (cursor.position.primary) {
                cursor.position = point;
                break;
            }
        }
    } else {
        _cursors.push_back({point, nullptr});
    }
}

- (void)selectOccurrences:(BOOL)all
{
    if (!self.editable || self.vimCommandLine || self.hasMarkedText)
        return;
    [self startAddingCursors];
    NSString *document = self.string;
    bool initialWord = false;
    if (!_occurrenceText.length) {
        auto active = std::find_if(_cursors.begin(), _cursors.end(), [](const EditorCursor &cursor) {
            return cursor.position.primary;
        });
        NSRange range = [self selectionForCursor:*active];
        initialWord = range.length == 0;
        if (initialWord)
            range = CocoaRange(Vim::WordAtCursor([self vimHost], range.location));
        if (!range.length) {
            _cursorHistory.pop_back();
            [self publishCursorSelection:NO];
            return;
        }
        _occurrenceText = [document substringWithRange:range];
        _occurrenceWholeWord = initialWord;
        _occurrenceEnd = NSMaxRange(range);
        if (initialWord) {
            [self addOccurrence:range primary:YES];
            if (!all) {
                [self publishCursorSelection:YES];
                return;
            }
        }
    }

    NSString *pattern = [NSRegularExpression escapedPatternForString:_occurrenceText];
    if (_occurrenceWholeWord)
        pattern = [NSString stringWithFormat:@"\\b%@\\b", pattern];
    NSUInteger previous = std::min(_occurrenceEnd, document.length);
    std::vector<NSRange> existing;
    existing.reserve(_cursors.size());
    for (const auto &cursor : _cursors)
        existing.push_back([self selectionForCursor:cursor]);
    std::sort(existing.begin(), existing.end(), [](NSRange a, NSRange b) { return a.location < b.location; });

    NSUInteger remaining = cursorLimit - _cursors.size();
    NSUInteger beforeCount = _cursors.size();
    NSUInteger start = all ? 0 : previous;
    NSUInteger end = document.length;
    NSUInteger reveal = Vim::NoOffset;
    for (unsigned pass = 0; remaining && pass < (all ? 1U : 2U); ++pass) {
        while (start < end && remaining) {
            auto next = [self findVimPattern:pattern range:NSMakeRange(start, end - start)
                                    backward:NO ignoreCase:NO captures:NO];
            if (!next || next->range.empty())
                break;
            const auto range = next->range;
            start = range.last;
            auto item = std::lower_bound(existing.begin(), existing.end(), range.first,
                                          [](NSRange value, NSUInteger at) { return NSMaxRange(value) <= at; });
            if (item != existing.end() && item->location < range.last)
                continue;
            [self addOccurrence:CocoaRange(range) primary:NO];
            --remaining;
            if (!all) {
                reveal = range.last;
                break;
            }
        }
        if (reveal != Vim::NoOffset)
            break;
        start = 0;
        end = previous;
    }

    if (_skipOccurrence && !all && _cursors.size() > beforeCount) {
        auto skipped = std::find_if(_cursors.begin(), _cursors.begin() + beforeCount, [&](const EditorCursor &cursor) {
            return NSMaxRange([self selectionForCursor:cursor]) == previous;
        });
        if (skipped != _cursors.begin() + beforeCount) {
            if (skipped->position.primary) {
                _cursors.back().position.primary = true;
                if (_vimEnabled)
                    _vim = std::move(_cursors.back().state);
            }
            _cursors.erase(skipped);
        }
    }
    _skipOccurrence = NO;
    if (_cursors.size() == beforeCount && reveal == Vim::NoOffset && !initialWord)
        _cursorHistory.pop_back();
    if (reveal != Vim::NoOffset)
        _occurrenceEnd = reveal;
    [self publishCursorSelection:NO];
    if (reveal != Vim::NoOffset)
        [self revealVimCaret:[self vimCaretAt:reveal] withContext:NO];
}

- (IBAction)addNextOccurrence:(id)sender { (void)sender; [self selectOccurrences:NO]; }
- (IBAction)selectAllOccurrences:(id)sender { (void)sender; [self selectOccurrences:YES]; }

- (IBAction)addCursorsToLineEnds:(id)sender
{
    (void)sender;
    if (!self.editable || self.vimCommandLine || self.hasMarkedText)
        return;
    [self startAddingCursors];
    std::vector<NSRange> ranges;
    for (const auto &cursor : _cursors)
        ranges.push_back([self selectionForCursor:cursor]);
    _cursors.clear();
    auto host = [self vimHost];
    for (NSUInteger i = 0; i < ranges.size() && _cursors.size() < cursorLimit; ++i) {
        NSRange range = ranges[i];
        NSUInteger first = [self vimLineAtOffset:range.location];
        NSUInteger last = [self vimLineAtOffset:range.length ? NSMaxRange(range) - 1 : range.location];
        for (NSUInteger row = first; row <= last && _cursors.size() < cursorLimit; ++row) {
            NSUInteger end = Vim::CursorAtColumn(host, row, Vim::NoOffset, 4, false);
            if (end == Vim::NoOffset)
                continue;
            CursorPosition point{end, end};
            point.mode = _vimEnabled && Vim::IsInsert(_vim->mode) ? _vim->mode : Vim::Mode::Normal;
            if (_cursors.empty()) {
                point.primary = true;
                if (_vimEnabled)
                    [self setVimCursor:*_vim fromPosition:point];
                _cursors.push_back({point, nullptr});
            } else {
                [self appendCursor:point];
            }
        }
    }
    [self resetOccurrenceSearch];
    [self publishCursorSelection:NO];
}

- (void)vimDocumentReplaced
{
    [self clearAdditionalCursors];
    _cursorHistory.clear();
    [_mappingTimer invalidate];
    _mappingTimer = nil;
    [self cancelVimScroll];
    [self cancelVimFlash];
    [self.undoManager removeAllActionsWithTarget:self];
    if (_vimEnabled) {
        _vim = std::make_unique<Vim::State>();
        [self configureVimState:*_vim];
        [self refreshVimSelection:NO];
    }
}

- (void)finishVimChange
{
    if (_vim) {
        Vim::FinishChange(*_vim);
        _vim->commandStart = _vim->cursor;
    }
    for (auto &cursor : _cursors) {
        if (cursor.state) {
            Vim::FinishChange(*cursor.state);
            cursor.state->commandStart = cursor.state->cursor;
        }
    }
}

- (std::vector<Vim::Offset>)editingCaretOffsets
{
    if (_cursors.empty())
        return {_vimEnabled ? _vim->cursor : NSMaxRange(self.selectedRange)};
    std::vector<Vim::Offset> carets;
    carets.reserve(_cursors.size());
    for (const auto &cursor : _cursors)
        carets.push_back(_vimEnabled ? [self stateForCursor:cursor].cursor : cursor.position.head);
    std::sort(carets.begin(), carets.end());
    return carets;
}

- (std::vector<Vim::Range>)editingSelections
{
    if (!_vimEnabled && _cursors.empty())
        return {ToVimRange(self.selectedRange)};

    std::vector<Vim::Range> selections;
    selections.reserve(self.cursorCount);
    auto append = [&](const Vim::State &state) {
        if (!Vim::IsVisual(state.mode)) {
            selections.push_back({state.cursor, state.cursor});
            return;
        }
        auto selected = Vim::Selected(state, [self vimHost], {0, 0});
        if (selected.kind == Vim::Kind::Block) {
            // A line command applies to the whole height of a visual block.
            NSUInteger after = selected.bottom + 1;
            NSUInteger end = after < [self vimDocumentLineCount] ? [self vimOffsetAtLine:after] : self.string.length;
            selections.push_back({[self vimOffsetAtLine:selected.top], end});
        } else {
            selections.insert(selections.end(), selected.ranges.begin(), selected.ranges.end());
        }
    };
    if (_cursors.empty()) {
        append(*_vim);
    } else {
        for (const auto &cursor : _cursors) {
            if (_vimEnabled)
                append([self stateForCursor:cursor]);
            else
                selections.push_back(ToVimRange(cursor.position.range(false)));
        }
    }
    return selections;
}

- (void)loadVimMappings:(NSString *)text
{
    NSUInteger count = Vim::LoadMappings(registers, Units(text));
    if (_vim) {
        _vim->message = Units([NSString stringWithFormat:@"%lu Vim mappings loaded", (unsigned long)count]);
        [self refreshVimSelection:NO];
    }
}

- (void)replaceVimRange:(NSRange)range withString:(NSString *)text
{
    if (NSMaxRange(range) > self.string.length)
        return;
    [self cancelVimScroll];
    [self cancelVimFlash];
    NSUndoManager *undo = self.undoManager;
    [undo disableUndoRegistration];
    if ([self shouldChangeTextInRange:range replacementString:text]) {
        _writingVimStorage = YES;
        ReplaceEditorText(self.textStorage, range, text, text.length ? self.typingAttributes : nil);
        _writingVimStorage = NO;
        [self didChangeText];
    }
    [undo enableUndoRegistration];
}

+ (void)vimStorage:(NSTextStorage *)storage edited:(const Vim::EditMap &)edit
{
    for (auto &mark : fileMarks) {
        if (mark.storage != storage || (!edit.batch && mark.offset < edit.range.first))
            continue;

        mark.offset = edit.map(mark.offset);
        if (!edit.batch && mark.view.vimDocument.fileURL)
            mark.url = mark.view.vimDocument.fileURL;
    }
}

+ (const Vim::EditBatch *)cursorBatchForStorage:(NSTextStorage *)storage
{
    return batchStorage == storage ? storageBatch : nullptr;
}

- (void)vimStorageEdited:(const Vim::EditMap &)edit
{
    if (_writingVimStorage)
        return;

    _plainBeforeInlay = NO;
    bool moveAll = edit.batch || _cursors.size() > 1;
    if (moveAll)
        [self finishCursorChange];

    [self resetOccurrenceSearch];
    _cursorHistory.clear();
    if (!moveAll) {
        if (_vim)
            Vim::ForeignEdit(*_vim, edit.range, edit.inserted);
        return;
    }

    if (edit.batch)
        [self beginCursorSelection];

    if (_vim)
        Vim::MoveCursorOffsets(*_vim, edit, batchCaretAfterInsertion);
    for (auto &cursor : _cursors) {
        if (cursor.state) {
            Vim::MoveCursorOffsets(*cursor.state, edit, batchCaretAfterInsertion);
        } else if (!_vimEnabled) {
            auto &position = cursor.position;
            position.anchor = edit.map(position.anchor, batchCaretAfterInsertion);
            position.head = edit.map(position.head, batchCaretAfterInsertion);
            position.beforeInlay = false;
        }
    }

    [self queueForeignCursorDisplay];
}

- (void)queueForeignCursorDisplay
{
    if (_cursors.empty() || _foreignCursorDisplayPending)
        return;
    // TextKit updates its selection after the storage delegate returns.
    _foreignCursorDisplayPending = YES;
    __weak VimTextView *view = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        VimTextView *current = view;
        if (current) {
            current->_foreignCursorDisplayPending = NO;
            [current publishCursorSelection:NO];
        }
    });
}

- (void)setSelectedRange:(NSRange)range
{
    if (_plainBeforeInlay && !NSEqualRanges(range, self.selectedRange))
        _plainBeforeInlay = NO;
    if (_cursors.size() > 1 && !_vimEnabled && !_publishingCursors && !_writingVimStorage &&
        !_foreignCursorDisplayPending && !NSEqualRanges(range, self.selectedRange)) {
        [self clearAdditionalCursors];
    }
    [super setSelectedRange:range];
}

- (void)setSelectedRanges:(NSArray<NSValue *> *)ranges affinity:(NSSelectionAffinity)affinity stillSelecting:(BOOL)stillSelecting
{
    if (_plainBeforeInlay && (ranges.count != 1 || !NSEqualRanges(ranges.firstObject.rangeValue, self.selectedRange)))
        _plainBeforeInlay = NO;
    [super setSelectedRanges:ranges affinity:affinity stillSelecting:stillSelecting];
}

- (void)didChangeText
{
    if (!_vimEnabled && _cursors.size() < 2)
        [self setPlainCaretBeforeInlay:self.selectedRange.length == 0];
    [super didChangeText];
}

- (BOOL)applyCursorBatch:(const Vim::EditBatch &)batch caretAfterInsertion:(BOOL)after
{
    if (batch.edits.empty())
        return YES;
    NSMutableArray<NSValue *> *ranges = [NSMutableArray arrayWithCapacity:batch.edits.size()];
    NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:batch.edits.size()];
    for (const auto &edit : batch.edits) {
        if (edit.range.last > self.string.length)
            return NO;
        [ranges addObject:[NSValue valueWithRange:CocoaRange(edit.range)]];
        [strings addObject:String(edit.text)];
    }
    [self cancelVimScroll];
    [self cancelVimFlash];
    NSUndoManager *undo = self.undoManager;
    [undo disableUndoRegistration];
    if (![self shouldChangeTextInRanges:ranges replacementStrings:strings]) {
        [undo enableUndoRegistration];
        return NO;
    }

    NSTextStorage *storage = self.textStorage;
    NSTextStorage *previousStorage = batchStorage;
    const Vim::EditBatch *previousBatch = storageBatch;
    BOOL previousCaretAfterInsertion = batchCaretAfterInsertion;
    batchStorage = storage;
    storageBatch = &batch;
    batchCaretAfterInsertion = after;
    _writingVimStorage = YES;
    NSDictionary *attributes = self.typingAttributes;
    NSString *dense = DenseCursorReplacement(self.string, batch);
    [storage beginEditing];
    if (dense) {
        NSUInteger first = batch.edits.front().range.first;
        NSRange range = NSMakeRange(first, batch.edits.back().range.last - first);
        NSAttributedString *inserted = [[NSAttributedString alloc] initWithString:dense attributes:attributes];
        [storage replaceCharactersInRange:range withAttributedString:inserted];
    } else {
        for (NSUInteger i = ranges.count; i > 0; --i)
            ReplaceEditorText(storage, ranges[i - 1].rangeValue, strings[i - 1], attributes);
    }
    [storage endEditing];
    batchCaretAfterInsertion = previousCaretAfterInsertion;
    storageBatch = previousBatch;
    batchStorage = previousStorage;
    [self didChangeText];
    _writingVimStorage = NO;
    [undo enableUndoRegistration];
    _cursorHistory.clear();
    [self resetOccurrenceSearch];
    return YES;
}

- (BOOL)applyCursorBatch:(const Vim::EditBatch &)batch
{
    return [self applyCursorBatch:batch caretAfterInsertion:YES];
}

- (Vim::EditBatch)inverseCursorBatch:(const Vim::EditBatch &)batch
{
    std::vector<Vim::CursorEdit> inverse;
    inverse.reserve(batch.edits.size());
    auto host = [self vimHost];
    for (NSUInteger i = 0; i < batch.edits.size(); ++i) {
        const auto &edit = batch.edits[i];
        Vim::Range range{edit.newStart, edit.newStart + edit.text.size()};
        std::u16string original(edit.range.size(), 0);
        if (!original.empty())
            host.read(host.document, edit.range, original.data());
        if (!inverse.empty() && inverse.back().range.last == range.first) {
            inverse.back().range.last = range.last;
            inverse.back().text.append(original);
        } else {
            inverse.push_back({range, std::move(original)});
        }
    }
    return Vim::EditBatch(std::move(inverse));
}

- (void)registerEditorUndo:(void (^)(VimTextView *))handler name:(NSString *)name
{
    NSUndoManager *undo = self.undoManager;
    BOOL group = undo && undo.groupingLevel == 0;
    BOOL separateGroup = group && name && undo.groupsByEvent;
    // A document-wide edit is a complete undo step, including when it runs during save.
    if (separateGroup)
        undo.groupsByEvent = NO;
    if (group)
        [undo beginUndoGrouping];
    [undo registerUndoWithTarget:self handler:handler];
    [undo setActionName:name ? name : @"Edit"];
    if (group)
        [undo endUndoGrouping];
    if (separateGroup)
        undo.groupsByEvent = YES;
}

- (void)registerCursorUndo:(std::shared_ptr<CursorChange>)change redo:(BOOL)redo
{
    [self registerEditorUndo:^(VimTextView *view) {
        [view restoreCursorChange:change redo:redo];
    } name:change->actionName];
}

- (void)syncVimFinalNewline
{
    NSUInteger lines = [self vimDocumentLineCount];
    bool trailing = lines > 1 && [self vimOffsetAtLine:lines - 1] == self.string.length;
    for (NSLayoutManager *layout in self.textStorage.layoutManagers) {
        NSTextView *textView = layout.textContainers.firstObject.textView;
        if (![textView isKindOfClass:VimTextView.class])
            continue;
        VimTextView *view = (VimTextView *)textView;
        if (view->_vim)
            view->_vim->finalNewline = trailing;
        for (auto &cursor : view->_cursors) {
            if (cursor.state)
                cursor.state->finalNewline = trailing;
        }
    }
}

- (BOOL)applyDocumentEdits:(Vim::EditBatch)batch undoName:(NSString *)name options:(DocumentEditOptions)options
{
    if (batch.edits.empty())
        return YES;
    [self breakUndoCoalescing];
    [self finishVimChange];
    [self finishCursorChange];
    [self beginCursorSelection];
    [self readVimCursorPositions];
    auto before = [self cursorSnapshot];
    auto inverse = [self inverseCursorBatch:batch];
    if (![self applyCursorBatch:batch caretAfterInsertion:NO]) {
        [self publishCursorSelection:NO];
        return NO;
    }

    [self syncVimFinalNewline];
    NSUInteger caret = options.caretAfter;
    bool placeCaret = caret != NSNotFound && _cursors.size() == 1;
    if (placeCaret)
        caret = std::min(caret, self.string.length);
    auto advanceAt = [&](Vim::Offset at) -> Vim::Offset {
        if (options.insertionAdvance) {
            const auto *edit = batch.find(at);
            if (edit && edit->range.empty())
                return options.insertionAdvance(edit->text);
        }
        return 0;
    };
    for (auto &cursor : _cursors) {
        if (_vimEnabled) {
            auto &state = [self stateForCursor:cursor];
            auto cursorAdvance = advanceAt(state.cursor);
            auto anchorAdvance = advanceAt(state.anchor);
            Vim::MoveCursorOffsets(state, {.batch = &batch}, false);
            state.cursor += cursorAdvance;
            state.anchor += anchorAdvance;
            if (placeCaret) {
                Vim::SetCursor(state, [self vimHost], caret);
                state.anchor = state.cursor;
            } else if (state.mode == Vim::Mode::Normal) {
                Vim::SetCursor(state, [self vimHost], state.cursor);
            }
        } else {
            auto &position = cursor.position;
            position.anchor = placeCaret ? caret : batch.map(position.anchor, false) + advanceAt(position.anchor);
            position.head = placeCaret ? caret : batch.map(position.head, false) + advanceAt(position.head);
        }
    }
    [self readVimCursorPositions];
    [self normalizeCursors];
    auto change = std::make_shared<CursorChange>();
    change->before = std::move(before);
    change->after = [self cursorSnapshot];
    change->steps.push_back({std::move(batch), std::move(inverse)});
    change->actionName = name;
    [self registerCursorUndo:change redo:NO];
    [self publishCursorSelection:placeCaret];
    return YES;
}

- (void)restoreCursorChange:(const std::shared_ptr<CursorChange> &)change redo:(BOOL)redo
{
    VimTextView *target = undoingView;
    if (!target || target.textStorage != self.textStorage)
        target = self;
    [target finishCursorChange];
    [target finishVimChange];
    for (NSUInteger index = 0; index < change->steps.size(); ++index) {
        const auto &step = change->steps[redo ? index : change->steps.size() - 1 - index];
        const auto &batch = redo ? step.forward : step.backward;
        [target applyCursorBatch:batch caretAfterInsertion:!change->actionName];
        if (target->_vim) {
            Vim::MoveCursorOffsets(*target->_vim, {.batch = &batch}, !change->actionName);
            target->_vim->change.reset();
        }
    }
    if (change->actionName)
        [target syncVimFinalNewline];
    auto snapshot = redo ? change->after : change->before;
    if (target.vimEnabled && snapshot.vim) {
        Vim::Mode mode = target.vimInserting ? target->_vim->mode : Vim::Mode::Normal;
        snapshot.occurrenceText = nil;
        for (auto &point : snapshot.cursors) {
            point.mode = mode;
            point.anchor = point.head;
        }
    }
    [target restoreCursorSnapshot:snapshot];
    [self registerCursorUndo:change redo:!redo];
}

- (void)recordCursorBatch:(Vim::EditBatch)batch inverse:(Vim::EditBatch)inverse
                  before:(CursorSnapshot)before coalesce:(BOOL)coalesce
{
    if (batch.edits.empty())
        return;
    if (!coalesce)
        [self finishCursorChange];
    if (!_cursorChange) {
        _cursorChange = std::make_shared<CursorChange>();
        _cursorChange->before = std::move(before);
        [self registerCursorUndo:_cursorChange redo:NO];
    }
    _cursorChange->after = [self cursorSnapshot];
    auto &steps = _cursorChange->steps;
    if (steps.empty() || !CoalesceCursorInsertions(steps.back(), batch))
        steps.push_back({std::move(batch), std::move(inverse)});
    if (!coalesce)
        _cursorChange.reset();
}

static NSUInteger PositionAfterCursorEdit(NSUInteger position, const TypingEdit &edit, const Vim::EditBatch &batch)
{
    if (position == NSNotFound)
        return position;
    const auto *result = batch.find(edit.range.location);
    if (!edit.text)
        return batch.map(position);
    NSUInteger inserted = edit.text.length;
    if (position >= edit.range.location && position <= edit.range.location + inserted &&
        result && result->range == ToVimRange(edit.range)) {
        return result->newStart + std::min(position - edit.range.location, result->text.size());
    }
    if (position > edit.range.location + inserted)
        position = position - inserted + edit.range.length;
    return batch.map(position);
}

- (BOOL)stageCursorTyping:(const TypingEdit &)edit
{
    if (!_planningCursors)
        return NO;
    if (edit.pair || edit.passedCloser != NSNotFound)
        _cursorTyping.push_back(edit);
    return YES;
}

- (void)finishCursorTyping:(const Vim::EditBatch &)batch
{
    for (auto &edit : _cursorTyping) {
        if (edit.pair) {
            auto translate = [&](TypingRange &range) {
                NSUInteger at = PositionAfterCursorEdit(range.location, edit, batch);
                NSUInteger end = PositionAfterCursorEdit(range.end(), edit, batch);
                range = {at, end >= at ? end - at : 0};
            };
            translate(edit.pair->opening);
            translate(edit.pair->closing);
            if (!edit.pair->opening.length || !edit.pair->closing.length)
                edit.pair.reset();
        }
        if (edit.passedCloser != NSNotFound)
            edit.passedCloser = batch.map(edit.passedCloser);
    }
    [self didTypeAtCursors:_cursorTyping];
    _cursorTyping.clear();
}

- (void)feedVimCursors:(Vim::Key)key text:(Vim::Text)text smart:(BOOL)smart
{
    auto host = [self vimHost];
    auto before = [self cursorSnapshot];
    Vim::Mode previousMode = _vim->mode;
    bool repeatedInsert = Vim::IsInsert(previousMode) && _vim->change;
    std::vector<Vim::State *> states;
    states.reserve(_cursors.size());
    for (const auto &cursor : _cursors)
        states.push_back(&[self stateForCursor:cursor]);
    _planningCursors = YES;
    auto run = Vim::FeedCursors(states, *_vim, host, registers, key, text, smart, ClusterInString, FindInString);
    _planningCursors = NO;
    auto inverse = [self inverseCursorBatch:run.batch];
    if (![self applyCursorBatch:run.batch]) {
        _cursorTyping.clear();
        [self restoreCursorSnapshot:before];
        return;
    }
    [self finishCursorTyping:run.batch];

    // A text object can be missing at a cursor. Keep input in a common mode
    // even when the command found a range at only some of the cursors.
    Vim::Mode mode = _vim->mode;
    if (Vim::IsInsert(previousMode) == Vim::IsInsert(mode)) {
        auto inserting = std::find_if(states.begin(), states.end(), [previousMode](const Vim::State *state) {
            return Vim::IsInsert(previousMode) != Vim::IsInsert(state->mode);
        });
        if (inserting != states.end())
            mode = (*inserting)->mode;
    }
    for (auto *state : states) {
        if (state->mode == mode || (Vim::IsVisual(state->mode) && Vim::IsVisual(mode)))
            continue;
        CursorPosition point{state->cursor, state->cursor, Vim::NoOffset, mode};
        [self setVimCursor:*state fromPosition:point];
    }
    [self readVimCursorPositions];
    [self normalizeCursors];
    if (!run.batch.edits.empty()) {
        if (!repeatedInsert && !Vim::IsInsert(previousMode))
            [self finishCursorChange];
        bool continuation = Vim::IsInsert(previousMode) || Vim::IsInsert(_vim->mode);
        [self recordCursorBatch:std::move(run.batch) inverse:std::move(inverse)
                         before:std::move(before) coalesce:continuation];
    }
    if (_cursorChange && (!Vim::IsInsert(_vim->mode) || !_vim->change))
        [self finishCursorChange];
    if (!run.flashes.empty()) {
        std::sort(run.flashes.begin(), run.flashes.end(), [](Vim::Range a, Vim::Range b) { return a.first < b.first; });
        run.flashes.erase(std::unique(run.flashes.begin(), run.flashes.end()), run.flashes.end());
        [self flashVimRanges:run.flashes linewise:run.flashKind == Vim::Kind::Line];
    }
}

- (BOOL)handleVimCursorKey:(Vim::Key)key text:(Vim::Text)text smart:(BOOL)smart
{
    if (_cursors.size() < 2)
        return NO;
    using Vim::Key;
    bool ready = _vim->prefix == Vim::Prefix::None && _vim->op == Vim::Op::None &&
                 _vim->surrounds.empty() && _vim->mappingKeys.empty();
    if (ready && _vim->mode == Vim::Mode::Normal) {
        if ((key == Key::Escape || key == Key(3)) && !_vim->count) {
            [self clearAdditionalCursors];
            return NO;
        }
        // Undo, Ex and window commands operate on the document as a whole.
        if (key == Key('u') || key == Key(18)) {
            [self finishCursorChange];
            return NO;
        }
    }
    if (ready && !Vim::IsInsert(_vim->mode) &&
        (key == Key(':') || key == Key('/') || key == Key('?') || key == Key(23) || key == Key('U'))) {
        [self clearAdditionalCursors];
        return NO;
    }
    [self feedVimCursors:key text:text smart:smart];
    return YES;
}

- (void)movePlainCursors:(Vim::Key)key extend:(BOOL)extend
{
    [self prepareCursorBatch];
    [self finishCursorChange];
    [self resetOccurrenceSearch];
    [self saveCursorHistory];
    auto host = [self vimHost];
    unsigned tab = unsigned([self cursorIndentation].tabWidth);
    for (auto &cursor : _cursors) {
        auto &point = cursor.position;
        NSRange range = point.range(false);
        bool right = key == Vim::Key::Right;
        bool horizontal = key == Vim::Key::Left || right;
        if (!extend && !range.length && horizontal && point.beforeInlay == right && [self inlayWidthAtInsertion:point.head] > 0) {
            point.beforeInlay = !right;
            point.column = Vim::NoOffset;
            continue;
        }

        point.beforeInlay = false;
        if (!extend && range.length && horizontal) {
            point.head = key == Vim::Key::Left ? range.location : NSMaxRange(range);
            point.column = Vim::NoOffset;
        } else {
            NSUInteger previous = point.head;
            point.head = Vim::MoveEditorCursor(host, key, point.head, point.column, tab);
            point.beforeInlay = !extend && right && point.head != previous && [self inlayWidthAtInsertion:point.head] > 0;
        }
        if (!extend)
            point.anchor = point.head;
    }
    [self publishCursorSelection:YES];
}

- (void)editPlainCursors:(Vim::Key)key text:(NSString *)text deletion:(Vim::Key)deletion smart:(BOOL)smart
{
    if (!self.editable || _cursors.size() < 2)
        return;
    [self prepareCursorBatch];
    auto before = [self cursorSnapshot];
    auto host = [self vimHost];
    Indentation indentation = [self cursorIndentation];
    BOOL paste = key == Vim::Key::Paste;
    auto units = paste ? Units(text) : std::u16string{};
    auto clipboard = paste ? ReadEditorClipboard() : std::nullopt;
    auto parts = paste ? Vim::ClipboardParts(units, _cursors.size(), clipboard ? &*clipboard : nullptr) : std::vector<Vim::Text>{};
    std::vector<TypingEdit> plans;
    std::vector<Vim::CursorEdit> changes;
    plans.reserve(_cursors.size());
    changes.reserve(_cursors.size());
    for (NSUInteger i = 0; i < _cursors.size(); ++i) {
        auto point = _cursors[i].position;
        NSRange range = point.range(false);
        auto plan = smart ? [self planCursorTyping:key selected:range indentation:indentation] : std::nullopt;
        if (!plan) {
            NSString *insert = parts.empty() ? text : String(parts[i]);
            if (deletion != Vim::Key::None) {
                insert = @"";
                if (!range.length) {
                    Vim::Offset column = Vim::NoOffset;
                    NSUInteger head = Vim::MoveEditorCursor(host, deletion, point.head, column, unsigned(indentation.tabWidth));
                    range = NSMakeRange(std::min(point.head, head), std::max(point.head, head) - std::min(point.head, head));
                }
            } else if (key == Vim::Key::Tab) {
                insert = @"\t";
            } else if (key == Vim::Key::Enter) {
                insert = @"\n";
            }
            plan = TypingEdit{range, insert, NSMakeRange(range.location + insert.length, 0), {}, NSNotFound};
        }
        if (plan->text && (plan->range.length || plan->text.length))
            changes.push_back({ToVimRange(plan->range), Units(plan->text)});
        if (plan->pair || plan->passedCloser != NSNotFound)
            _cursorTyping.push_back(*plan);
        plans.push_back(std::move(*plan));
    }
    Vim::EditBatch batch(std::move(changes));
    auto inverse = [self inverseCursorBatch:batch];
    if (![self applyCursorBatch:batch]) {
        _cursorTyping.clear();
        return;
    }
    for (NSUInteger i = 0; i < plans.size(); ++i) {
        const auto &plan = plans[i];
        auto &point = _cursors[i].position;
        point.anchor = PositionAfterCursorEdit(plan.selection.location, plan, batch);
        point.head = PositionAfterCursorEdit(NSMaxRange(plan.selection), plan, batch);
        point.column = Vim::NoOffset;
        if (!batch.edits.empty())
            point.beforeInlay = !plan.selection.length;
    }
    [self finishCursorTyping:batch];
    [self normalizeCursors];
    bool coalesce = !paste && (key == Vim::Key::Text || key == Vim::Key::Backspace ||
                               (char32_t(key) >= 32 && char32_t(key) <= 0xffff));
    [self recordCursorBatch:std::move(batch) inverse:std::move(inverse) before:std::move(before) coalesce:coalesce];
    [self publishCursorSelection:YES];
}

- (void)registerVimUndo:(std::shared_ptr<Vim::Change>)change redo:(BOOL)redo
{
    [self registerEditorUndo:^(VimTextView *target) {
        [target restoreVimChange:change redo:redo];
    } name:nil];
}

- (void)restoreVimChange:(std::shared_ptr<Vim::Change>)change redo:(BOOL)redo
{
    VimTextView *target = undoingView;
    if (!target || target.textStorage != self.textStorage)
        target = self;
    [target clearAdditionalCursors];
    for (std::size_t i = 0; i < change->edits.size(); ++i) {
        const auto &edit = change->edits[redo ? i : change->edits.size() - 1 - i];
        const auto &before = redo ? edit.before : edit.after;
        const auto &after = redo ? edit.after : edit.before;
        if (_vim)
            Vim::ExternalEdit(*_vim, {edit.at, edit.at + before.size()}, after.size());
        [self replaceVimRange:NSMakeRange(edit.at, before.size()) withString:String(after)];
    }
    NSUInteger position = std::min(redo ? change->after : change->before, self.string.length);
    if (target->_vim)
        target->_vim->lineUndo = redo ? change->afterLine : change->beforeLine;
    target.selectedRange = NSMakeRange(position, 0);
    if (target->_vimEnabled && !target->_undoingVimKey) {
        Vim::SetCursor(*target->_vim, [target vimHost], position);
        [target refreshVimSelection:YES];
    }
    [self registerVimUndo:std::move(change) redo:!redo];
}

- (std::optional<Vim::Offset>)performVimUndo:(BOOL)redo
{
    NSUndoManager *undo = self.undoManager;
    if (!(redo ? undo.canRedo : undo.canUndo))
        return std::nullopt;
    [self breakUndoCoalescing];
    _undoingVimKey = YES;
    undoingView = self;
    if (redo)
        [undo redo];
    else
        [undo undo];
    undoingView = nil;
    _undoingVimKey = NO;
    return self.selectedRange.location;
}

- (void)applyVimKey:(Vim::Key)key text:(NSString *)text
{
    [self applyVimKey:key text:text smart:NO];
}

- (void)applyVimKey:(Vim::Key)key text:(NSString *)text smart:(BOOL)smart
{
    if (!_vimEnabled)
        return;
    if (_cursors.size() > 1)
        [self prepareCursorBatch];
    if (key == Vim::Key('b') && _vim->prefix == Vim::Prefix::G && _vim->op == Vim::Op::None &&
        (_vim->mode == Vim::Mode::Normal || _vim->mode == Vim::Mode::Visual)) {
        unsigned count = std::clamp(_vim->count, 1U, unsigned(cursorLimit));
        _vim->prefix = Vim::Prefix::None;
        _vim->count = 0;
        _vim->inputs.clear();
        for (auto &cursor : _cursors) {
            if (cursor.state) {
                cursor.state->prefix = Vim::Prefix::None;
                cursor.state->count = 0;
                cursor.state->inputs.clear();
            }
        }
        while (count--) {
            NSUInteger before = _cursors.size();
            NSString *pattern = _occurrenceText;
            [self addNextOccurrence:nil];
            if (_cursors.size() == before && pattern == _occurrenceText)
                break;
        }
        return;
    }
    Vim::Mode previousMode = _vim->mode;
    NSUInteger previousCursor = _vim->cursor;
    NSUInteger previousAnchor = _vim->anchor;
    bool previousInlaySide = _vim->beforeInlay;
    bool hadMirrors = !_vim->insertMirrors.empty();
    NSUInteger displayedCursor = self.vimDisplayedCursor;
    bool scrollMotion = IsScrollMotion(key) && _vim->op == Vim::Op::None && _vim->prefix == Vim::Prefix::None;
    _applyingKey = YES;
    _requestedScrollRow.reset();
    bool hadCursors = _cursors.size() > 1;
    auto units = Units(text);
    if (![self handleVimCursorKey:key text:units smart:smart]) {
        if (key == Vim::Key::None)
            Vim::FlushMappings(*_vim, [self vimHost], registers);
        else
            Vim::Feed(*_vim, [self vimHost], registers, key, units, smart);
    }
    if (_mappingTimer) {
        [_mappingTimer invalidate];
        _mappingTimer = nil;
    }
    if (!_vim->mappingKeys.empty()) {
        __weak VimTextView *view = self;
        _mappingTimer = [NSTimer timerWithTimeInterval:1 repeats:NO block:^(NSTimer *) {
            [view applyVimKey:Vim::Key::None text:nil];
        }];
        [NSRunLoop.mainRunLoop addTimer:_mappingTimer forMode:NSRunLoopCommonModes];
    }

    bool visual = Vim::IsVisual(_vim->mode);
    bool leavingVisual = Vim::IsVisual(previousMode) && !visual;
    bool sameMode = _vim->mode == previousMode;
    bool moved = _vim->cursor != previousCursor;
    if (_occurrenceText && (moved || !sameMode || _vim->anchor != previousAnchor))
        [self resetOccurrenceSearch];
    if (moved && [self hasVimFolds])
        [self revealVimFoldAt:_vim->cursor];
    bool animate = sameMode && scrollMotion && (visual || _vim->mode == Vim::Mode::Normal);
    bool useViewport = animate || _requestedScrollRow.has_value() || (visual && (!sameMode || moved));
    bool cancel = key == Vim::Key::Escape || key == Vim::Key(3);
    bool clearWithoutScrolling = leavingVisual && cancel && !_scrollAnimation;
    bool keepGliding = _scrollAnimation && !cancel && !_requestedScrollRow && sameMode && !moved;
    if (!keepGliding) {
        if (useViewport) {
            NSRect caret = [self vimCaretAt:_vim->cursor];
            NSRect destination = [self vimViewport:[self intendedVimViewport]
                                    revealingCaret:caret withContext:!_requestedScrollRow];
            [self scrollVimViewport:destination caret:caret fromCursor:displayedCursor animate:animate];
        } else {
            [self cancelVimScroll];
        }
    }
    // Prefix keys and clearing a selection should leave a manually scrolled viewport alone.
    [self refreshVimSelection:!useViewport && !keepGliding && !visual && !clearWithoutScrolling];
    if (previousInlaySide != _vim->beforeInlay)
        [self updateInsertionPointStateAndRestartTimer:YES];
    if (leavingVisual)
        [self setNeedsDisplay:YES];
    if (_cursors.size() == 1)
        [self clearAdditionalCursors];
    if (hadMirrors || !_vim->insertMirrors.empty() || hadCursors || !_cursors.empty())
        [self setNeedsDisplayInRect:self.visibleRect];
    _requestedScrollRow.reset();
    _applyingKey = NO;
}

- (NSRange)selectedCharacterRange
{
    if (_cursors.size() > 1)
        return NSMakeRange(NSNotFound, 0);
    if (!_vimEnabled && self.selectedRanges.count == 1)
        return self.selectedRange;
    if (_vimEnabled && _vim->mode == Vim::Mode::Visual && _vim->occurrences.size() < 2) {
        auto selection = Vim::Selected(*_vim, [self vimHost], {0, Vim::NoOffset}, self.vimDisplayedCursor);
        return CocoaRange(selection.ranges.front());
    }
    return NSMakeRange(NSNotFound, 0);
}

- (BOOL)insertionLocationsMatch:(BOOL (^)(NSUInteger position))test
{
    for (const auto &cursor : _cursors) {
        const auto &point = cursor.position;
        if (_vimEnabled) {
            if (point.mode != Vim::Mode::Insert || [self stateForCursor:cursor].prefix != Vim::Prefix::None)
                return NO;
        } else if (point.head != point.anchor) {
            return NO;
        }
        if (!test(point.head))
            return NO;
    }
    return YES;
}

- (CGFloat)vimExtraGlyphWidthAt:(NSUInteger)position
{
    (void)position;
    return 0;
}

- (CGFloat)inlayWidthAtInsertion:(NSUInteger)position
{
    (void)position;
    return 0;
}

- (NSUInteger)inlayInsertionAtPoint:(NSPoint)point before:(BOOL *)before
{
    (void)point;
    (void)before;
    return NSNotFound;
}

- (CGFloat)insertionCaretInsetAt:(NSUInteger)position
{
    bool before = _vimEnabled ? _vim && _vim->cursor == position && _vim->beforeInlay : _plainBeforeInlay;
    if (!before)
        return 0;
    NSRange selected = self.selectedRange;
    return !selected.length && selected.location == position ? [self inlayWidthAtInsertion:position] : 0;
}

- (void)setPlainCaretBeforeInlay:(BOOL)before
{
    if (_plainBeforeInlay != before) {
        _plainBeforeInlay = before;
        [self updateInsertionPointStateAndRestartTimer:YES];
    }
}

static NSRect InlayBlockRect(NSRect caret, CGFloat inset)
{
    caret.origin.x -= inset;
    caret.size.width = std::min(caret.size.width, inset);
    return caret;
}

- (void)revealInsertionAt:(NSUInteger)position
{
    CGFloat inset = [self insertionCaretInsetAt:position];
    if (inset > 0) {
        NSRect caret = [self vimCaretAt:position];
        if (_vimEnabled && _vim->mode == Vim::Mode::Normal) {
            caret = InlayBlockRect(caret, inset);
        } else {
            caret.origin.x -= inset;
            caret.size.width = 1;
        }
        [self scrollRectToVisible:caret];
    } else {
        [self scrollRangeToVisible:NSMakeRange(position, 0)];
    }
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual
{
    NSRect rect = [super firstRectForCharacterRange:range actualRange:actual];
    if (!range.length && NSHeight(rect) > 0)
        rect.origin.x -= [self insertionCaretInsetAt:range.location];
    return rect;
}

- (NSRect)vimCaretAt:(NSUInteger)position
{
    NSLayoutManager *layout = self.layoutManager;
    NSPoint origin = self.textContainerOrigin;
    NSFont *font = [self vimFont];
    if (_caretFont != font && ![_caretFont isEqual:font]) {
        _caretFont = font;
        NSDictionary *attributes = @{NSFontAttributeName:font};
        _caretWidth = [@"M" sizeWithAttributes:attributes].width;
        _caretSpaceWidth = [@" " sizeWithAttributes:attributes].width;
    }
    CGFloat width = _caretWidth;
    NSString *text = self.string;
    NSUInteger length = text.length;
    NSRect rect;
    if (position >= length) {
        if (length)
            [layout ensureLayoutForCharacterRange:NSMakeRange(length - 1, 1)];
        rect = layout.extraLineFragmentRect;
        if (NSIsEmptyRect(rect) && length) {
            NSUInteger last = [layout glyphIndexForCharacterAtIndex:length - 1];
            rect = [layout lineFragmentRectForGlyphAtIndex:last effectiveRange:nullptr];
            rect.origin.x = NSMaxX([layout lineFragmentUsedRectForGlyphAtIndex:last effectiveRange:nullptr]);
        } else if (NSIsEmptyRect(rect)) {
            rect = NSMakeRect(0, 0, width, [layout defaultLineHeightForFont:font]);
        }
        rect.size.width = width;
    } else {
        unichar character = [text characterAtIndex:position];
        bool whitespace = [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:character];
        [layout ensureLayoutForCharacterRange:NSMakeRange(position, 1)];
        NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:position];
        NSRange fragment;
        rect = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:&fragment];
        CGFloat x = [layout locationForGlyphAtIndex:glyph].x;
        if (whitespace) {
            width = _caretSpaceWidth;
        } else if (glyph + 1 < NSMaxRange(fragment)) {
            width = std::max(1.0, [layout locationForGlyphAtIndex:glyph + 1].x - x - [self vimExtraGlyphWidthAt:position]);
        }
        rect.origin.x += x;
        rect.size.width = width;
    }
    rect.origin.x += origin.x;
    rect.origin.y += origin.y;
    return rect;
}

- (NSFont *)vimFont
{
    NSFont *font = self.font;
    if (!font)
        font = self.typingAttributes[NSFontAttributeName];
    return font ? font : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
}

- (NSRect)vimViewport:(NSRect)visible revealingCaret:(NSRect)caret withContext:(BOOL)context
{
    if (NSIsEmptyRect(visible))
        return visible;
    if (context) {
        BOOL clipped = NSMinX(caret) < NSMinX(visible) || NSMaxX(caret) > NSMaxX(visible);
        CGFloat columns = clipped ? std::clamp((NSWidth(visible) - NSWidth(caret)) / 2, 0.0, 2 * NSWidth(caret)) : 0;
        CGFloat rows = std::clamp((NSHeight(visible) - NSHeight(caret)) / 2, 0.0, 2 * NSHeight(caret));
        caret = NSInsetRect(caret, -columns, -rows);
    }
    caret = NSIntersectionRect(caret, self.bounds);
    if (!NSIsEmptyRect(caret)) {
        visible.origin.x = std::min(NSMinX(caret), std::max(NSMinX(visible), NSMaxX(caret) - NSWidth(visible)));
        visible.origin.y = std::min(NSMinY(caret), std::max(NSMinY(visible), NSMaxY(caret) - NSHeight(visible)));
    }
    return visible;
}

- (void)revealVimCaret:(NSRect)caret withContext:(BOOL)context
{
    NSRect visible = self.enclosingScrollView.documentVisibleRect;
    NSRect destination = [self vimViewport:visible revealingCaret:caret withContext:context];
    if (!NSEqualRects(visible, destination))
        [self setVimViewport:destination];
}

- (void)prepareLayoutAroundOffset:(NSUInteger)offset verticalMargin:(CGFloat)margin
{
    NSLayoutManager *layout = self.layoutManager;
    CGFloat lineHeight = std::max(1.0, [layout defaultLineHeightForFont:[self vimFont]]);
    NSUInteger rows = NSUInteger(std::ceil(margin / lineHeight)) + 2;
    NSUInteger line = [self vimLineAtOffset:offset];
    NSUInteger first = [self vimOffsetAtLine:[self vimStepRow:line down:NO count:rows]];
    NSUInteger endLine = [self vimStepRow:line down:YES count:rows] + 1;
    NSUInteger end = endLine < self.vimDocumentLineCount ? [self vimOffsetAtLine:endLine] : self.string.length;
    [layout ensureLayoutForCharacterRange:NSMakeRange(first, end - first)];
}

- (void)centerEditorAtOffset:(NSUInteger)offset
{
    [self.window.contentView layoutSubtreeIfNeeded];
    NSScrollView *scroll = self.enclosingScrollView;
    NSRect viewport = scroll.documentVisibleRect;
    if (NSIsEmptyRect(viewport))
        return;

    if (self.layoutManager.allowsNonContiguousLayout)
        [self prepareLayoutAroundOffset:offset verticalMargin:NSHeight(viewport)];

    NSRect caret = [self vimCaretAt:offset];
    NSRect destination = [self vimViewport:scroll.documentVisibleRect revealingCaret:caret withContext:NO];
    destination.origin.y = NSMidY(caret) - NSHeight(destination) / 2;
    [self setVimViewport:destination];
}

- (void)scrollRangeToVisible:(NSRange)range
{
    NSScrollView *scroll = self.enclosingScrollView;
    NSString *text = self.string;
    if (!scroll || range.location > text.length || range.length > text.length - range.location) {
        [super scrollRangeToVisible:range];
        return;
    }

    // A definition jump can arrive before a new tab's viewport has been laid out.
    if (NSIsEmptyRect(scroll.documentVisibleRect))
        [self.window.contentView layoutSubtreeIfNeeded];

    NSLayoutManager *layout = self.layoutManager;
    NSRect viewport = scroll.documentVisibleRect;
    if (layout.hasNonContiguousLayout && !NSIsEmptyRect(viewport)) {
        Vim::Range visible = [self vimCharactersInViewport:viewport];
        if (range.location < visible.first || range.location > visible.last)
            [self prepareLayoutAroundOffset:range.location verticalMargin:NSHeight(viewport)];
    }

    NSRect target = NSZeroRect;
    if (range.length) {
        // Reveal the beginning of a multiline match without measuring the entire selection.
        NSUInteger end;
        [text getLineStart:nullptr end:nullptr contentsEnd:&end forRange:NSMakeRange(range.location, 0)];
        if (end > range.location) {
            range.length = std::min(NSMaxRange(range), end) - range.location;
            NSRange glyphs = [layout glyphRangeForCharacterRange:range actualCharacterRange:nullptr];
            NSPoint origin = self.textContainerOrigin;
            target = NSOffsetRect([layout boundingRectForGlyphRange:glyphs inTextContainer:self.textContainer], origin.x, origin.y);
        }
    }
    if (NSIsEmptyRect(target))
        target = [self vimCaretAt:range.location];
    [self revealVimCaret:target withContext:NO];
}

- (void)invalidateVimCaret
{
    if (!NSIsEmptyRect(_vimCaretRect))
        [self setNeedsDisplayInRect:_vimCaretRect];
}

- (NSRect)vimDisplayedBlockCaret
{
    NSUInteger at = std::min(self.vimDisplayedCursor, self.string.length);
    NSRect caret = [self vimCaretAt:at];
    CGFloat inset = [self insertionCaretInsetAt:at];
    return inset > 0 ? InlayBlockRect(caret, inset) : caret;
}

- (void)refreshVimCaretGeometry
{
    if (NSIsEmptyRect(_vimCaretRect))
        return;
    [self invalidateVimCaret];
    _vimCaretRect = [self vimDisplayedBlockCaret];
    [self invalidateVimCaret];
}

- (void)refreshVimSelection:(BOOL)scroll
{
    [self invalidateVimCaret];
    _vimCaretRect = NSZeroRect;
    BOOL hideNative = _vimEnabled && _vim->mode != Vim::Mode::Insert;
    BOOL caretChanged = _hidesNativeInsertionPoint != hideNative;
    _hidesNativeInsertionPoint = hideNative;
    if (_vimEnabled && _vim) {
        NSUInteger cursor = std::min(_vim->cursor, self.string.length);
        if (!NSEqualRanges(self.selectedRange, NSMakeRange(cursor, 0)))
            self.selectedRange = NSMakeRange(cursor, 0);
        bool visual = Vim::IsVisual(_vim->mode);
        if (_vim->mode != Vim::Mode::Insert && _vim->mode != Vim::Mode::Command)
            _vimCaretRect = [self vimDisplayedBlockCaret];
        if (visual && scroll) {
            [self revealVimCaret:_vimCaretRect withContext:YES];
        } else if (scroll) {
            NSUInteger reveal = _vim->searchPreview == Vim::NoOffset ? cursor :
                                std::min(_vim->searchPreview, self.string.length);
            [self revealInsertionAt:reveal];
        }
        BOOL highlights = visual || _vim->showMatches || self.vimCommandLine;
        if (_hadVimHighlight && !highlights)
            [self setNeedsDisplay:YES];
        else if (highlights)
            [self setNeedsDisplayInRect:self.visibleRect];
        _hadVimHighlight = highlights;
    }
    if (caretChanged)
        [self updateInsertionPointStateAndRestartTimer:YES];
    [self invalidateVimCaret];
    if (self.vimStatusChanged)
        self.vimStatusChanged();
}

- (void)refreshVimCaret
{
    BOOL wasScrolling = _scrollAnimation.has_value();
    [self cancelVimScroll];
    [self refreshVimSelection:wasScrolling];
}

- (Vim::Range)vimCharactersInViewport:(NSRect)visible
{
    NSPoint origin = self.textContainerOrigin;
    visible.origin.x = 0;
    visible.origin.y -= origin.y;
    visible.size.width = NSWidth(self.bounds);
    NSLayoutManager *layout = self.layoutManager;
    NSRange glyphs = [layout glyphRangeForBoundingRect:visible inTextContainer:self.textContainer];
    NSRange characters = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:nullptr];
    NSUInteger size = self.string.length;
    if (characters.location == NSNotFound)
        return {0, size};
    return {std::min(characters.location, size), std::min(NSMaxRange(characters), size)};
}

- (Vim::Range)visibleVimCharacters
{
    return [self vimCharactersInViewport:self.visibleRect];
}

- (Vim::Range)vimRowsInViewport:(NSRect)visible
{
    NSLayoutManager *layout = self.layoutManager;
    if (layout.allowsNonContiguousLayout) {
        NSRect area = NSMakeRect(0, NSMinY(visible) - self.textContainerOrigin.y,
                                NSWidth(self.bounds), NSHeight(visible));
        [layout ensureLayoutForBoundingRect:area inTextContainer:self.textContainer];
    }
    Vim::Range characters = [self vimCharactersInViewport:visible];
    NSUInteger first = [self vimLineAtOffset:characters.first];
    NSUInteger last = [self vimLineAtOffset:characters.empty() ? characters.first : characters.last - 1];
    if (first < last && NSMinY([self vimCaretAt:[self vimOffsetAtLine:first]]) < NSMinY(visible))
        ++first;
    if (first < last && NSMaxY([self vimCaretAt:[self vimOffsetAtLine:last]]) > NSMaxY(visible))
        --last;
    return {first, last + 1};
}

- (NSRect)clipBoundsForVimViewport:(NSRect)viewport
{
    NSClipView *clip = self.enclosingScrollView.contentView;
    NSRect bounds = [self convertRect:viewport toView:clip];
    // A scroll frame should translate the LCD glyphs by whole backing pixels.
    NSPoint pixels = [clip convertPointToBacking:bounds.origin];
    bounds.origin = [clip convertPointFromBacking:NSMakePoint(std::round(pixels.x), std::round(pixels.y))];
    return [clip constrainBoundsRect:bounds];
}

- (NSRect)intendedVimViewport
{
    NSScrollView *scroll = self.enclosingScrollView;
    NSRect viewport = scroll.documentVisibleRect;
    if (_requestedScrollRow && scroll) {
        // AppKit can give the text view a nonzero origin inside its clip view.
        NSUInteger row = std::min(*_requestedScrollRow, self.vimDocumentLineCount - 1);
        CGFloat top = NSMinY([self vimCaretAt:[self vimOffsetAtLine:row]]);
        viewport = scroll.documentVisibleRect;
        viewport.origin.y = top - self.textContainerOrigin.y;
        return [self convertRect:[self clipBoundsForVimViewport:viewport] fromView:scroll.contentView];
    }
    if (_scrollAnimation)
        viewport.origin = _scrollAnimation->destination;
    return viewport;
}

- (void)setVimViewport:(NSRect)viewport
{
    NSScrollView *scroll = self.enclosingScrollView;
    NSClipView *clip = scroll.contentView;
    if (!clip || NSIsEmptyRect(viewport))
        return;
    NSPoint origin = [self clipBoundsForVimViewport:viewport].origin;
    if (!NSEqualPoints(origin, clip.bounds.origin)) {
        [clip scrollToPoint:origin];
        if (_scrollAnimation) {
            // A layout correction moves the whole animation with the text.
            CGFloat shift = NSMinY(clip.bounds) - origin.y;
            _scrollAnimation->from.y += shift;
            _scrollAnimation->destination.y += shift;
        }
        [scroll reflectScrolledClipView:clip];
    }
}

- (void)restoreSessionScroll:(NSPoint)origin
{
    NSRect viewport = self.enclosingScrollView.documentVisibleRect;
    viewport.origin = origin;
    [self setVimViewport:viewport];
}

- (void)cancelVimScroll
{
    [_scrollTimer invalidate];
    _scrollTimer = nil;
    _scrollAnimation.reset();
}

- (void)finishVimScroll
{
    if (!_scrollAnimation)
        return;
    NSRect destination = [self intendedVimViewport];
    [self cancelVimScroll];
    [self setVimViewport:destination];
    [self refreshVimSelection:NO];
}

- (void)advanceVimScroll
{
    NSScrollView *scroll = self.enclosingScrollView;
    if (!_scrollAnimation || !scroll) {
        [self cancelVimScroll];
        return;
    }
    const VimScrollAnimation animation = *_scrollAnimation;
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - animation.start;
    CGFloat fraction = std::clamp(elapsed / animation.duration, 0.0, 1.0);
    CGFloat remaining = 1 - fraction;
    CGFloat progress = 1 - remaining * remaining;
    NSRect viewport = scroll.documentVisibleRect;
    viewport.origin = NSMakePoint(std::lerp(animation.from.x, animation.destination.x, progress),
                                  std::lerp(animation.from.y, animation.destination.y, progress));

    NSUInteger previous = _displayedCursor;
    _displayedCursor = _vim->cursor;
    if (animation.firstCursorRow != NSNotFound && fraction < 1) {
        NSUInteger row = [self vimLineAtOffset:_vim->cursor];
        NSUInteger shown = NSUInteger(std::lround(std::lerp(double(animation.firstCursorRow), double(row), progress)));
        if (shown != row)
            _displayedCursor = Vim::CursorOnRow(*_vim, [self vimHost], shown);
    }
    if (fraction >= 1)
        [self cancelVimScroll];

    if (previous != _displayedCursor)
        [self refreshVimSelection:NO];
    [self setVimViewport:[self vimViewport:viewport revealingCaret:_vimCaretRect withContext:NO]];
}

- (void)scrollVimViewport:(NSRect)destination caret:(NSRect)caret fromCursor:(NSUInteger)fromCursor
                  animate:(BOOL)animate
{
    NSScrollView *scroll = self.enclosingScrollView;
    NSRect visible = scroll.documentVisibleRect;
    if (NSIsEmptyRect(visible))
        return;
    destination = [self convertRect:[self clipBoundsForVimViewport:destination] fromView:scroll.contentView];
    if (!animate || !_smoothScrollingEnabled || NSEqualPoints(visible.origin, destination.origin) ||
        NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [self cancelVimScroll];
        [self setVimViewport:destination];
        return;
    }

    // Keep the command's destination immediately available to Vim. During a long
    // scroll, paint the caret and any selection through the visible rows.
    BOOL caretVisible = NSContainsRect(visible, caret);
    _displayedCursor = caretVisible ? _vim->cursor : fromCursor;
    NSUInteger firstRow = caretVisible ? NSNotFound : [self vimLineAtOffset:fromCursor];
    CGFloat distance = std::abs(NSMinY(destination) - NSMinY(visible));
    NSTimeInterval duration = std::lerp(0.022, 0.048, std::clamp(distance / NSHeight(visible), 0.0, 1.0));
    _scrollAnimation = VimScrollAnimation{visible.origin, destination.origin, firstRow,
                                         NSProcessInfo.processInfo.systemUptime, duration};
    if (!_scrollTimer) {
        NSInteger frameRate = 60;
        if (@available(macOS 12.0, *))
            frameRate = std::clamp(self.window.screen.maximumFramesPerSecond, NSInteger(60), NSInteger(120));
        __weak VimTextView *view = self;
        _scrollTimer = [NSTimer timerWithTimeInterval:1.0 / frameRate repeats:YES block:^(NSTimer *timer) {
            VimTextView *editor = view;
            if (editor)
                [editor advanceVimScroll];
            else
                [timer invalidate];
        }];
        [NSRunLoop.mainRunLoop addTimer:_scrollTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)vimDidLiveScroll
{
    if (_scrollAnimation && !_applyingKey && !_selectingWithMouse) {
        // A trackpad or scrollbar moves the viewport without changing the selection.
        [self cancelVimScroll];
        [self refreshVimSelection:NO];
    }
}

- (BOOL)shouldDrawInsertionPoint
{
    // AppKit otherwise continues to blink and invalidate the hidden caret.
    return !_hidesNativeInsertionPoint && !self.usesSeparateInsertionIndicator && super.shouldDrawInsertionPoint;
}

- (void)drawInsertionPointInRect:(NSRect)rect color:(NSColor *)color turnedOn:(BOOL)on
{
    if (_hidesNativeInsertionPoint || self.usesSeparateInsertionIndicator)
        return;
    if ([self insertionCaretInsetAt:self.selectedRange.location] > 0) {
        _inlayCaret.hidden = !on;
        return;
    }
    _inlayCaret.hidden = YES;
    [super drawInsertionPointInRect:rect color:color turnedOn:on];
}

- (BOOL)usesSeparateInsertionIndicator
{
    if (@available(macOS 14.0, *))
        return self.window.screen != nil;
    return NO;
}

- (void)updateInsertionIndicator
{
    NSWindow *window = self.window;
    NSRange selection = self.selectedRange;
    BOOL separate = self.usesSeparateInsertionIndicator;
    CGFloat inset = [self insertionCaretInsetAt:selection.location];
    if (_hidesNativeInsertionPoint || (!separate && inset <= 0) || !window.isKeyWindow ||
        window.firstResponder != self || selection.location == NSNotFound || selection.length || !super.shouldDrawInsertionPoint) {
        _inlayCaret.hidden = YES;
        if (@available(macOS 14.0, *))
            ((NSTextInsertionIndicator *)_insertionIndicator).displayMode = NSTextInsertionIndicatorDisplayModeHidden;
        return;
    }

    NSRect screenRect = [self firstRectForCharacterRange:selection actualRange:nullptr];
    NSRect rect;
    if (NSHeight(screenRect) > 0) {
        rect = [self convertRect:[window convertRectFromScreen:screenRect] fromView:nil];
    } else {
        rect = [self vimCaretAt:selection.location];
        rect.origin.x -= inset;
    }
    rect.size.width = 1;
    rect = [self backingAlignedRect:rect options:NSAlignAllEdgesNearest];
    if (!separate) {
        if (!_inlayCaret) {
            // The system caret still drives blinking on systems without a separate indicator.
            _inlayCaret = [[EditorInlayCaret alloc] initWithFrame:rect];
            [self addSubview:_inlayCaret positioned:NSWindowAbove relativeTo:nil];
        } else {
            _inlayCaret.frame = rect;
        }
        _inlayCaret.color = self.insertionPointColor;
        _inlayCaret.hidden = NO;
        return;
    }

    _inlayCaret.hidden = YES;
    if (@available(macOS 14.0, *)) {
        NSTextInsertionIndicator *indicator = (NSTextInsertionIndicator *)_insertionIndicator;
        if (!indicator) {
            // Blink in a separate view so a caret tick never repaints the editor.
            indicator = [[EditorInsertionIndicator alloc] initWithFrame:rect];
            indicator.automaticModeOptions = 0;
            [self addSubview:indicator positioned:NSWindowAbove relativeTo:nil];
            _insertionIndicator = indicator;
        } else if (!NSEqualRects(indicator.frame, rect)) {
            indicator.frame = rect;
        }
        if (![indicator.color isEqual:self.insertionPointColor])
            indicator.color = self.insertionPointColor;
        if (indicator.displayMode != NSTextInsertionIndicatorDisplayModeAutomatic)
            indicator.displayMode = NSTextInsertionIndicatorDisplayModeAutomatic;
    }
}

- (void)updateInsertionPointStateAndRestartTimer:(BOOL)restartFlag
{
    [super updateInsertionPointStateAndRestartTimer:restartFlag];
    if (_insertionIndicatorPending || (!_insertionIndicator && !_inlayCaret && !self.usesSeparateInsertionIndicator &&
        [self insertionCaretInsetAt:self.selectedRange.location] <= 0))
        return;
    _insertionIndicatorPending = YES;
    __weak VimTextView *view = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        VimTextView *current = view;
        if (current) {
            current->_insertionIndicatorPending = NO;
            [current updateInsertionIndicator];
        }
    });
}

- (void)enumerateVimRects:(std::span<const Vim::Range>)ranges linewise:(BOOL)linewise
                 handler:(void (^)(NSRect))handler
{
    Vim::Range visible = [self visibleVimCharacters];
    NSLayoutManager *layout = self.layoutManager;
    NSTextContainer *container = self.textContainer;
    NSPoint origin = self.textContainerOrigin;
    for (auto range : ranges) {
        if (range.empty() && linewise && range.first >= visible.first && range.first <= visible.last) {
            NSRect caret = [self vimCaretAt:range.first];
            handler(NSMakeRect(origin.x, NSMinY(caret), NSWidth(self.bounds) - origin.x, NSHeight(caret)));
            continue;
        }
        NSUInteger first = std::max(range.first, visible.first);
        NSUInteger last = std::min(range.last, visible.last);
        if (last <= first)
            continue;
        NSRange glyphs = [layout glyphRangeForCharacterRange:NSMakeRange(first, last - first)
                                       actualCharacterRange:nullptr];
        if (linewise) {
            [layout enumerateLineFragmentsForGlyphRange:glyphs
                                             usingBlock:^(NSRect rect, NSRect, NSTextContainer *, NSRange, BOOL *) {
                handler(NSMakeRect(origin.x, NSMinY(rect) + origin.y, NSWidth(self.bounds) - origin.x, NSHeight(rect)));
            }];
        } else {
            [layout enumerateEnclosingRectsForGlyphRange:glyphs withinSelectedGlyphRange:NSMakeRange(NSNotFound, 0)
                                           inTextContainer:container usingBlock:^(NSRect rect, BOOL *) {
                handler(NSOffsetRect(rect, origin.x, origin.y));
            }];
        }
    }
}

- (void)invalidateVimFlash
{
    for (NSRect rect : _flashRects)
        [self setNeedsDisplayInRect:rect];
}

- (void)cancelVimFlash
{
    [self invalidateVimFlash];
    [_flashTimer invalidate];
    _flashTimer = nil;
    std::vector<NSRect>().swap(_flashRects);
}

- (void)flashVimRanges:(const std::vector<Vim::Range> &)ranges linewise:(BOOL)linewise
{
    [self cancelVimFlash];
    [self enumerateVimRects:ranges linewise:linewise handler:^(NSRect rect) {
        if (NSIntersectsRect(rect, self.visibleRect))
            _flashRects.push_back(rect);
    }];
    if (_flashRects.empty())
        return;
    _flashStart = NSProcessInfo.processInfo.systemUptime;
    __weak VimTextView *view = self;
    _flashTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        VimTextView *current = view;
        if (!current) {
            [timer invalidate];
        } else if (NSProcessInfo.processInfo.systemUptime - current->_flashStart >= yankDuration) {
            [current cancelVimFlash];
        } else {
            [current invalidateVimFlash];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_flashTimer forMode:NSRunLoopCommonModes];
    [self invalidateVimFlash];
}

- (void)drawVimOverlays:(NSRect)dirty selection:(NSColor *)selection flash:(NSColor *)flash
        selectedRanges:(std::vector<NSRange> *)ranges blockCarets:(std::vector<VimBlockCaret> &)blocks contrastingCaret:(BOOL)contrasting
{
    if (!_vimEnabled && _cursors.empty() && _flashRects.empty())
        return;
    if (_vimEnabled && (_vim->showMatches || self.vimCommandLine)) {
        auto matches = Vim::SearchHighlights(*_vim, [self vimHost], [self visibleVimCharacters]);
        if (!matches.empty()) {
            [[flash colorWithAlphaComponent:0.42] setFill];
            [self enumerateVimRects:matches linewise:NO handler:^(NSRect rect) {
                NSRectFillUsingOperation(NSIntersectionRect(rect, dirty), NSCompositingOperationSourceOver);
            }];
        }
    }
    auto drawSelection = [&](std::span<const Vim::Range> selected, bool linewise) {
        if (ranges) {
            for (auto range : selected) {
                if (!range.empty())
                    ranges->push_back(CocoaRange(range));
            }
        }
        [selection setFill];
        [self enumerateVimRects:selected linewise:linewise handler:^(NSRect rect) {
            NSRectFill(NSIntersectionRect(rect, dirty));
        }];
    };
    if (_vimEnabled && !_selectingWithMouse && Vim::IsVisual(_vim->mode)) {
        auto selected = Vim::Selected(*_vim, [self vimHost], [self visibleVimCharacters], self.vimDisplayedCursor);
        drawSelection(selected.ranges, selected.kind == Vim::Kind::Line);
    }
    auto drawCaret = [&](NSRect caret, NSUInteger at, Vim::Mode mode, bool atInlay) {
        if (!NSIntersectsRect(caret, dirty))
            return;

        bool thin = mode == Vim::Mode::Insert;
        if (mode == Vim::Mode::Replace) {
            caret.origin.y = NSMaxY(caret) - 3;
            caret.size.height = 3;
        } else if (thin) {
            caret.size.width = 1;
        } else if (contrasting || atInlay) {
            // Paint the virtual block after the hint so its background cannot cover it.
            blocks.push_back({caret, atInlay ? NSNotFound : at});
            return;
        }

        NSColor *color = self.insertionPointColor;
        [contrasting ? color : [color colorWithAlphaComponent:thin ? 0.9 : 0.39] setFill];
        NSRectFillUsingOperation(NSIntersectionRect(caret, dirty), NSCompositingOperationSourceOver);
    };
    BOOL focused = (self.window.isKeyWindow && self.window.firstResponder == self) || !self.window;
    if (_cursors.size() > 1) {
        auto visible = [self vimCharactersInViewport:dirty];
        auto first = _vimEnabled && _vim->mode == Vim::Mode::VisualBlock ? _cursors.begin() :
            std::lower_bound(_cursors.begin(), _cursors.end(), visible.first,
                                     [&](const EditorCursor &cursor, NSUInteger at) {
            return cursor.position.last(_vimEnabled) < at;
        });
        auto host = [self vimHost];
        for (auto it = first; it != _cursors.end() && it->position.first(_vimEnabled) <= visible.last; ++it) {
            const auto &point = it->position;
            if (point.primary)
                continue;
            if (_vimEnabled && Vim::IsVisual(point.mode)) {
                auto selected = Vim::Selected(*it->state, host, visible);
                drawSelection(selected.ranges, selected.kind == Vim::Kind::Line);
            } else if (!_vimEnabled && point.anchor != point.head) {
                Vim::Range selected = ToVimRange(point.range(false));
                drawSelection({&selected, 1}, false);
            }
            if (!focused || point.head < visible.first || point.head > visible.last)
                continue;
            NSRect caret = [self vimCaretAt:point.head];
            CGFloat inset = point.beforeInlay ? [self inlayWidthAtInsertion:point.head] : 0;
            Vim::Mode mode = _vimEnabled ? point.mode : Vim::Mode::Insert;
            if (inset > 0) {
                if (mode == Vim::Mode::Insert)
                    caret.origin.x -= inset + 1;
                else
                    caret = InlayBlockRect(caret, inset);
            }
            drawCaret(caret, point.head, mode, inset > 0);
        }
    }
    if (!_flashRects.empty()) {
        CGFloat remaining = std::clamp(1 - (NSProcessInfo.processInfo.systemUptime - _flashStart) / yankDuration, 0.0, 1.0);
        [[flash colorWithAlphaComponent:remaining * remaining * 0.84] setFill];
        for (NSRect rect : _flashRects)
            NSRectFillUsingOperation(NSIntersectionRect(rect, dirty), NSCompositingOperationSourceOver);
    }
    if (_vimEnabled && focused && !_selectingWithMouse) {
        if (NSIntersectsRect(_vimCaretRect, dirty)) {
            NSUInteger at = self.vimDisplayedCursor;
            drawCaret(_vimCaretRect, at, _vim->mode, [self insertionCaretInsetAt:at] > 0);
        }
        if (!_vim->insertMirrors.empty()) {
            auto visible = [self visibleVimCharacters];
            const auto &mirrors = _vim->insertMirrors;
            NSColor *color = self.insertionPointColor;
            [contrasting ? color : [color colorWithAlphaComponent:0.85] setFill];
            for (auto at = std::lower_bound(mirrors.begin(), mirrors.end(), visible.first);
                 at != mirrors.end() && *at <= visible.last; ++at) {
                NSRect caret = [self vimCaretAt:*at];
                caret.size.width = 1;
                NSRectFillUsingOperation(NSIntersectionRect(caret, dirty), NSCompositingOperationSourceOver);
            }
        }
    }
}

- (void)drawVimComposition:(NSRect)dirty
{
    if (!_composition.length || self.vimCommandLine)
        return;
    NSUInteger at = _vimEnabled ? _vim->cursor : self.selectedRange.location;
    NSRect caret = [self vimCaretAt:at];
    caret.origin.x -= [self insertionCaretInsetAt:at];
    NSFont *font = [self vimFont];
    NSDictionary *attrs = @{NSFontAttributeName:font, NSForegroundColorAttributeName:self.insertionPointColor,
                            NSBackgroundColorAttributeName:self.backgroundColor,
                            NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle)};
    NSSize size = [_composition sizeWithAttributes:attrs];
    caret.size.width = size.width;
    if (NSIntersectsRect(caret, dirty))
        [_composition drawAtPoint:caret.origin withAttributes:attrs];
}

static Vim::Key EventKey(NSEvent *event, bool visual)
{
    using Vim::Key;
    NSEventModifierFlags flags = event.modifierFlags;
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length ? [characters characterAtIndex:0] : 0;
    if (flags & NSEventModifierFlagControl) {
        if (key >= 'A' && key <= 'Z')
            key += 'a' - 'A';
        if (key >= 'a' && key <= 'z')
            return Key(key - 'a' + 1);
        if (key == '[')
            return Key::Escape;
    }
    switch (key) {
        case 27: return Key::Escape;
        case '\r': case NSEnterCharacter: return Key::Enter;
        case '\t': return flags & NSEventModifierFlagShift ? Key::Backtab : Key::Tab;
        case NSBackTabCharacter: return Key::Backtab;
        case NSDeleteCharacter: case NSBackspaceCharacter: return visual ? Key::Delete : Key::Backspace;
        case NSDeleteFunctionKey: return Key::Delete;
        case NSLeftArrowFunctionKey:
            return flags & NSEventModifierFlagOption ? Key::WordLeft : Key::Left;
        case NSRightArrowFunctionKey:
            return flags & NSEventModifierFlagOption ? Key::WordRight : Key::Right;
        case NSUpArrowFunctionKey: return Key::Up;
        case NSDownArrowFunctionKey: return Key::Down;
        case NSHomeFunctionKey: return Key::Home;
        case NSEndFunctionKey: return Key::End;
        case NSPageUpFunctionKey: return Key::PageUp;
        case NSPageDownFunctionKey: return Key::PageDown;
    }
    return Key::None;
}

static NSEventModifierFlags EditorModifiers(NSEvent *event)
{
    return event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl |
                                 NSEventModifierFlagOption | NSEventModifierFlagCommand);
}

- (BOOL)handleCursorShortcut:(NSEvent *)event
{
    NSEventModifierFlags flags = EditorModifiers(event);
    NSString *characters = event.charactersIgnoringModifiers.lowercaseString;
    if (characters.length != 1 || self.vimCommandLine || self.hasMarkedText || !self.editable)
        return NO;
    unichar character = [characters characterAtIndex:0];
    constexpr auto command = NSEventModifierFlagCommand;
    constexpr auto option = NSEventModifierFlagOption;
    constexpr auto shift = NSEventModifierFlagShift;
    if (_skipOccurrence && (flags != command || (character != 'd' && character != 'k')))
        _skipOccurrence = NO;
    if (flags == (command | option) && (character == NSUpArrowFunctionKey || character == NSDownArrowFunctionKey)) {
        [self addCursorsVertically:character == NSDownArrowFunctionKey];
        return YES;
    }
    if (flags == command && character == 'd') {
        [self addNextOccurrence:nil];
        return YES;
    }
    if (flags == (command | shift) && character == 'l') {
        [self selectAllOccurrences:nil];
        return YES;
    }
    if (flags == (option | shift) && character == 'i') {
        [self addCursorsToLineEnds:nil];
        return YES;
    }
    if (flags == command && character == 'u' && !_cursorHistory.empty()) {
        [self undoCursorChange:nil];
        return YES;
    }
    if (flags == command && character == 'k') {
        _skipOccurrence = YES;
        return YES;
    }
    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if (self.window.firstResponder == self && [self handleCursorShortcut:event])
        return YES;
    return [super performKeyEquivalent:event];
}

- (BOOL)handlePlainCursorKey:(Vim::Key)key modifiers:(NSEventModifierFlags)flags
{
    if (_vimEnabled || _cursors.size() < 2 || (flags & NSEventModifierFlagControl))
        return NO;

    using Vim::Key;
    bool command = flags & NSEventModifierFlagCommand;
    bool option = flags & NSEventModifierFlagOption;
    bool extend = flags & NSEventModifierFlagShift;
    switch (key) {
        case Key::Escape:
            [self clearAdditionalCursors];
            return YES;
        case Key::Backspace: case Key::Delete: {
            bool back = key == Key::Backspace;
            Key direction = command ? (back ? Key::Home : Key::End) :
                            option ? (back ? Key::WordLeft : Key::WordRight) : (back ? Key::Left : Key::Right);
            [self editPlainCursors:key text:nil deletion:direction smart:back && !option && !command];
            return YES;
        }
        case Key::Enter: case Key::Tab: case Key::Backtab:
            if (command || option)
                return NO;
            [self editPlainCursors:key text:nil deletion:Key::None smart:YES];
            return YES;
        case Key::Left: case Key::WordLeft:
            [self movePlainCursors:command ? Key::Home : key extend:extend];
            return YES;
        case Key::Right: case Key::WordRight:
            [self movePlainCursors:command ? Key::End : key extend:extend];
            return YES;
        case Key::Up: case Key::Down:
            [self movePlainCursors:command ? (key == Key::Up ? Key::DocumentStart : Key::DocumentEnd) : key extend:extend];
            return YES;
        case Key::PageUp: case Key::PageDown: case Key::Home: case Key::End:
        case Key::DocumentStart: case Key::DocumentEnd:
            [self movePlainCursors:key extend:extend];
            return YES;
        default:
            return NO;
    }
}

struct CursorCommand {
    Vim::Key key = Vim::Key::None;
    NSEventModifierFlags modifiers = 0;
    bool inVim = false;
    bool smart = false;
};

static CursorCommand CommandForSelector(SEL selector)
{
    using Vim::Key;
    static const struct {
        SEL selector;
        CursorCommand command;
    } bindings[] = {
        {@selector(cancelOperation:), {Key::Escape, 0, true}},
        {@selector(deleteBackward:), {Key::Backspace, 0, true, true}},
        {@selector(deleteForward:), {Key::Delete, 0, true}},
        {@selector(insertNewline:), {Key::Enter, 0, true, true}},
        {@selector(insertLineBreak:), {Key::Enter, 0, true, true}},
        {@selector(insertTab:), {Key::Tab, 0, true, true}},
        {@selector(insertBacktab:), {Key::Backtab, 0, true, true}},
        {@selector(moveLeft:), {Key::Left, 0, true}},
        {@selector(moveBackward:), {Key::Left, 0, true}},
        {@selector(moveRight:), {Key::Right, 0, true}},
        {@selector(moveForward:), {Key::Right, 0, true}},
        {@selector(moveUp:), {Key::Up, 0, true}},
        {@selector(moveDown:), {Key::Down, 0, true}},
        {@selector(deleteWordBackward:), {Key::Backspace, NSEventModifierFlagOption}},
        {@selector(deleteWordForward:), {Key::Delete, NSEventModifierFlagOption}},
        {@selector(deleteToBeginningOfLine:), {Key::Backspace, NSEventModifierFlagCommand}},
        {@selector(deleteToBeginningOfParagraph:), {Key::Backspace, NSEventModifierFlagCommand}},
        {@selector(deleteToEndOfLine:), {Key::Delete, NSEventModifierFlagCommand}},
        {@selector(deleteToEndOfParagraph:), {Key::Delete, NSEventModifierFlagCommand}},
        {@selector(moveWordLeft:), {Key::WordLeft}},
        {@selector(moveWordBackward:), {Key::WordLeft}},
        {@selector(moveWordRight:), {Key::WordRight}},
        {@selector(moveWordForward:), {Key::WordRight}},
        {@selector(moveToBeginningOfLine:), {Key::Home}},
        {@selector(moveToBeginningOfParagraph:), {Key::Home}},
        {@selector(moveToEndOfLine:), {Key::End}},
        {@selector(moveToEndOfParagraph:), {Key::End}},
        {@selector(moveToBeginningOfDocument:), {Key::DocumentStart}},
        {@selector(moveToEndOfDocument:), {Key::DocumentEnd}},
        {@selector(pageUp:), {Key::PageUp}},
        {@selector(pageDown:), {Key::PageDown}},
    };
    for (const auto &binding : bindings) {
        if (selector == binding.selector)
            return binding.command;
    }

    return {};
}

- (BOOL)addCursorAtMouse:(NSEvent *)event
{
    if (EditorModifiers(event) != NSEventModifierFlagOption || event.clickCount != 1 ||
        !self.editable || self.vimCommandLine || self.hasMarkedText)
        return NO;
    [self.window makeFirstResponder:self];
    [self startAddingCursors];
    [self resetOccurrenceSearch];
    NSPoint click = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL beforeInlay = NO;
    NSUInteger at = [self inlayInsertionAtPoint:click before:&beforeInlay];
    if (at == NSNotFound)
        at = std::min(self.string.length, [self characterIndexForInsertionAtPoint:click]);
    if (_vimEnabled && !self.vimInserting)
        at = Vim::ClampNormalCursor([self vimHost], at, _vim->finalNewline);
    auto previous = std::find_if(_cursors.begin(), _cursors.end(), [&](const EditorCursor &cursor) {
        NSRange range = [self selectionForCursor:cursor];
        return range.length ? NSLocationInRange(at, range) : range.location == at;
    });
    if (previous != _cursors.end()) {
        if (_cursors.size() > 1) {
            if (previous->position.primary) {
                auto next = previous == _cursors.begin() ? previous + 1 : _cursors.begin();
                next->position.primary = true;
                if (_vimEnabled)
                    _vim = std::move(next->state);
            }
            _cursors.erase(previous);
        } else {
            _cursorHistory.pop_back();
        }
    } else if (_cursors.size() < cursorLimit) {
        CursorPosition point{at, at};
        if (_vimEnabled)
            point.mode = _vim->mode;
        point.beforeInlay = beforeInlay;
        [self appendCursor:point];
    }
    [self publishCursorSelection:NO];
    return YES;
}

- (void)keyDown:(NSEvent *)event
{
    if ([self handleCursorShortcut:event])
        return;
    _skipOccurrence = NO;
    if (!_vimEnabled && _cursors.size() > 1 && !_composition.length &&
        [self handlePlainCursorKey:EventKey(event, false) modifiers:EditorModifiers(event)])
        return;
    if (!_vimEnabled && _composition.length && EventKey(event, false) == Vim::Key::Escape) {
        _composition = nil;
        [self.inputContext discardMarkedText];
        [self setNeedsDisplayInRect:self.visibleRect];
        return;
    }
    if (!_vimEnabled || (event.modifierFlags & NSEventModifierFlagCommand)) {
        [super keyDown:event];
        return;
    }
    bool visual = Vim::IsVisual(_vim->mode);
    Vim::Key key = EventKey(event, visual);
    NSEventModifierFlags modifiers = event.modifierFlags &
        (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption);
    if (key == Vim::Key(1) && modifiers == NSEventModifierFlagControl && !_composition.length &&
        _vim->prefix == Vim::Prefix::None && _vim->op == Vim::Op::None &&
        _vim->surrounds.empty() &&
        ((_vim->mode == Vim::Mode::Normal && !_vim->count) || visual)) {
        // A count prefix still reaches Vim's number increment.
        [self selectAll:nil];
        return;
    }
    if (_composition.length && key == Vim::Key::Escape) {
        _composition = nil;
        [self.inputContext discardMarkedText];
        [self setNeedsDisplayInRect:self.visibleRect];
        return;
    }
    if (_composition.length) {
        [self interpretKeyEvents:@[event]];
    } else if (key != Vim::Key::None) {
        if (_vim->mode == Vim::Mode::Normal && (event.modifierFlags & NSEventModifierFlagShift) &&
            (key == Vim::Key::Left || key == Vim::Key::Right || key == Vim::Key::Up || key == Vim::Key::Down))
            [self applyVimKey:Vim::Key('v') text:nil];
        [self applyVimKey:key text:nil smart:YES];
    } else if (Vim::IsInsert(_vim->mode) || self.vimCommandLine ||
               _vim->prefix == Vim::Prefix::Replace || _vim->prefix == Vim::Prefix::Find) {
        [self interpretKeyEvents:@[event]];
    } else if (event.characters.length) {
        auto text = Units(event.characters);
        [self applyVimKey:text.size() == 1 ? Vim::Key(text.front()) : Vim::Key::Text text:event.characters];
    }
}

- (void)doCommandBySelector:(SEL)selector
{
    using Vim::Key;
    if (!_vimEnabled) {
        if (_cursors.size() > 1) {
            auto command = CommandForSelector(selector);
            if ([self handlePlainCursorKey:command.key modifiers:command.modifiers])
                return;
        }

        bool right = selector == @selector(moveRight:) || selector == @selector(moveForward:);
        bool left = selector == @selector(moveLeft:) || selector == @selector(moveBackward:);
        NSRange selection = self.selectedRange;
        if ((!left && !right) || selection.length || selection.location == NSNotFound || self.hasMarkedText) {
            [super doCommandBySelector:selector];
            return;
        }

        if (_plainBeforeInlay == right && [self inlayWidthAtInsertion:selection.location] > 0) {
            [self setPlainCaretBeforeInlay:!right];
            [self revealInsertionAt:selection.location];
            return;
        }

        [super doCommandBySelector:selector];
        NSRange moved = self.selectedRange;
        if (right && !moved.length && moved.location != selection.location && [self inlayWidthAtInsertion:moved.location] > 0) {
            [self setPlainCaretBeforeInlay:YES];
            [self revealInsertionAt:moved.location];
        }
        return;
    }
    auto command = CommandForSelector(selector);
    if (command.inVim) {
        Key key = command.key;
        if (key == Key::Backspace && Vim::IsVisual(_vim->mode))
            key = Key::Delete;
        [self applyVimKey:key text:nil smart:command.smart];
    }
}

- (void)insertNewline:(id)sender
{
    if (![self handlePlainCursorKey:Vim::Key::Enter modifiers:0])
        [super insertNewline:sender];
}

- (void)insertLineBreak:(id)sender
{
    if (![self handlePlainCursorKey:Vim::Key::Enter modifiers:0])
        [super insertLineBreak:sender];
}

- (void)insertTab:(id)sender
{
    if (![self handlePlainCursorKey:Vim::Key::Tab modifiers:0])
        [super insertTab:sender];
}

- (void)insertBacktab:(id)sender
{
    if (![self handlePlainCursorKey:Vim::Key::Backtab modifiers:0])
        [super insertBacktab:sender];
}

- (void)deleteBackward:(id)sender
{
    if (![self handlePlainCursorKey:Vim::Key::Backspace modifiers:0])
        [super deleteBackward:sender];
}

- (void)deleteForward:(id)sender
{
    if (![self handlePlainCursorKey:Vim::Key::Delete modifiers:0])
        [super deleteForward:sender];
}

- (void)insertText:(id)string replacementRange:(NSRange)range
{
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    if (!_vimEnabled) {
        if (_cursors.size() > 1) {
            BOOL composed = _composition.length != 0;
            _composition = nil;
            Vim::Key key = text.length == 1 ? Vim::Key([text characterAtIndex:0]) : Vim::Key::Text;
            [self editPlainCursors:key text:text deletion:Vim::Key::None smart:!composed];
            return;
        }
        [super insertText:string replacementRange:range];
        return;
    }
    BOOL composed = _composition.length != 0;
    _composition = nil;
    if (text.length) {
        Vim::Key key = text.length == 1 ? Vim::Key([text characterAtIndex:0]) : Vim::Key::Text;
        [self applyVimKey:key text:key == Vim::Key::Text ? text : nil smart:!composed && text.length == 1];
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selection replacementRange:(NSRange)replacement
{
    if (!_vimEnabled && _cursors.size() < 2) {
        [super setMarkedText:string selectedRange:selection replacementRange:replacement];
        return;
    }
    _composition = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    [self setNeedsDisplayInRect:self.visibleRect];
}

- (BOOL)hasMarkedText
{
    return _vimEnabled || _cursors.size() > 1 ? _composition.length != 0 : [super hasMarkedText];
}

- (NSRange)markedRange
{
    if (!_vimEnabled && _cursors.size() < 2)
        return [super markedRange];
    return NSMakeRange(_composition.length ? self.vimCursor : NSNotFound, _composition.length);
}

- (void)unmarkText
{
    if (!_vimEnabled && _cursors.size() < 2) {
        [super unmarkText];
    } else if (_composition.length) {
        NSString *text = _composition;
        _composition = nil;
        if (_vimEnabled)
            [self applyVimKey:Vim::Key::Text text:text];
        else
            [self editPlainCursors:Vim::Key::Text text:text deletion:Vim::Key::None smart:NO];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    if (_mappingTimer)
        [self applyVimKey:Vim::Key::None text:nil];
    if (_scrollAnimation) {
        [self cancelVimScroll];
        [self refreshVimSelection:NO];
    }
    if ([self addCursorAtMouse:event])
        return;
    if (_cursors.size() > 1)
        [self saveCursorHistory];
    [self clearAdditionalCursors];
    BOOL track = _vimEnabled && !_applyingKey;
    NSUInteger anchor = 0;
    NSUInteger inlay = NSNotFound;
    BOOL beforeInlay = NO;
    NSPoint click = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.clickCount == 1 && !(event.modifierFlags & NSEventModifierFlagShift))
        inlay = [self inlayInsertionAtPoint:click before:&beforeInlay];
    if (track && event.clickCount == 1) {
        anchor = self.selectedRange.location;
        if (!(event.modifierFlags & NSEventModifierFlagShift))
            anchor = inlay == NSNotFound ? [self characterIndexForInsertionAtPoint:click] : inlay;
    }
    _selectingWithMouse = track;
    if (track) {
        [self invalidateVimCaret];
        if (Vim::IsVisual(_vim->mode))
            [self setNeedsDisplayInRect:self.visibleRect];
    }
    [super mouseDown:event];
    _selectingWithMouse = NO;
    bool hitInlay = inlay != NSNotFound && !self.selectedRange.length;
    if (hitInlay)
        self.selectedRange = NSMakeRange(inlay, 0);
    if (track && _vimEnabled) {
        NSRange selection = self.selectedRange;
        bool backwards = selection.length && anchor >= NSMaxRange(selection);
        bool oldSide = _vim->beforeInlay;
        Vim::MouseSelection(*_vim, [self vimHost], ToVimRange(selection), backwards);
        _vim->beforeInlay = hitInlay && beforeInlay && _vim->cursor == inlay &&
                           (_vim->mode == Vim::Mode::Insert || _vim->mode == Vim::Mode::Normal);
        [self refreshVimSelection:selection.length != 0];
        if (oldSide != _vim->beforeInlay)
            [self updateInsertionPointStateAndRestartTimer:YES];
    } else if (!_vimEnabled) {
        [self setPlainCaretBeforeInlay:hitInlay && beforeInlay];
    }
}

- (BOOL)becomeFirstResponder
{
    BOOL result = [super becomeFirstResponder];
    if (result) {
        [self invalidateVimCaret];
        if (_cursors.size() > 1)
            [self setNeedsDisplayInRect:self.visibleRect];
    }
    return result;
}

- (BOOL)resignFirstResponder
{
    if (_mappingTimer)
        [self applyVimKey:Vim::Key::None text:nil];
    [self finishVimScroll];
    [self finishVimChange];
    [self finishCursorChange];
    [self invalidateVimCaret];
    if (_cursors.size() > 1)
        [self setNeedsDisplayInRect:self.visibleRect];
    return [super resignFirstResponder];
}

- (void)undoOrRedo:(BOOL)redo
{
    if (_vimEnabled && !Vim::IsInsert(_vim->mode)) {
        [self applyVimKey:redo ? Vim::Key(18) : Vim::Key('u') text:nil];
        return;
    }

    [self finishVimChange];
    [self finishCursorChange];
    [self breakUndoCoalescing];
    if (redo)
        [self.undoManager redo];
    else
        [self.undoManager undo];
}

- (void)undo:(id)sender
{
    (void)sender;
    [self undoOrRedo:NO];
}

- (void)redo:(id)sender
{
    (void)sender;
    [self undoOrRedo:YES];
}

- (void)copyVimSelectionAndCut:(BOOL)cut
{
    if (_cursors.size() > 1) {
        for (const auto &cursor : _cursors) {
            auto &state = [self stateForCursor:cursor];
            state.prefix = Vim::Prefix::None;
            state.op = Vim::Op::None;
            state.count = 0;
            state.inputs.clear();
        }
        [self applyVimKey:Vim::Key('"') text:nil];
        [self applyVimKey:Vim::Key('+') text:nil];
        [self applyVimKey:Vim::Key(cut ? 'd' : 'y') text:nil];
        return;
    }
    _applyingKey = YES;
    [self cancelVimScroll];
    Vim::CopySelection(*_vim, [self vimHost], registers, cut);
    [self refreshVimSelection:cut];
    [self setNeedsDisplay:YES];
    _applyingKey = NO;
}

- (void)copyPlainCursorsAndCut:(BOOL)cut
{
    NSMutableString *text = [NSMutableString string];
    NSMutableArray<NSDictionary *> *parts = [NSMutableArray arrayWithCapacity:_cursors.size()];
    NSString *document = self.string;
    for (auto &cursor : _cursors) {
        NSRange range = cursor.position.range(false);
        bool line = !range.length;
        if (!range.length && range.location < document.length) {
            NSUInteger first, last;
            [document getLineStart:&first end:&last contentsEnd:nullptr forRange:range];
            range = NSMakeRange(first, last - first);
        }
        if (text.length && ![NSCharacterSet.newlineCharacterSet characterIsMember:[text characterAtIndex:text.length - 1]])
            [text appendString:@"\n"];
        NSString *fragment = [document substringWithRange:range];
        [text appendString:fragment];
        [parts addObject:@{@"text":fragment, @"kind":@(NSUInteger(line ? Vim::Kind::Line : Vim::Kind::Character)), @"width":@0}];
        if (cut) {
            cursor.position.anchor = range.location;
            cursor.position.head = NSMaxRange(range);
        }
    }
    if (text.length)
        WriteEditorClipboard(text, parts);
    if (cut)
        [self editPlainCursors:Vim::Key::Delete text:@"" deletion:Vim::Key::None smart:NO];
}

- (void)copy:(id)sender
{
    if (_vimEnabled && Vim::IsVisual(_vim->mode)) {
        [self copyVimSelectionAndCut:NO];
    } else if (!_vimEnabled && _cursors.size() > 1) {
        [self copyPlainCursorsAndCut:NO];
    } else {
        [super copy:sender];
    }
}

- (void)cut:(id)sender
{
    if (_vimEnabled && Vim::IsVisual(_vim->mode)) {
        [self copyVimSelectionAndCut:YES];
    } else if (!_vimEnabled && _cursors.size() > 1) {
        [self copyPlainCursorsAndCut:YES];
    } else {
        [super cut:sender];
    }
}

- (void)paste:(id)sender
{
    if (!_vimEnabled) {
        if (_cursors.size() > 1) {
            NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            if (text)
                [self editPlainCursors:Vim::Key::Paste text:text deletion:Vim::Key::None smart:NO];
        } else {
            [super paste:sender];
        }
    } else if (Vim::IsInsert(_vim->mode) || self.vimCommandLine) {
        [self applyVimKey:Vim::Key::Paste text:[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]];
    } else {
        [self applyVimKey:Vim::Key('"') text:nil];
        [self applyVimKey:Vim::Key('+') text:nil];
        [self applyVimKey:Vim::Key('p') text:nil];
    }
}

- (void)selectAll:(id)sender
{
    [self clearAdditionalCursors];
    if (_vimEnabled) {
        [_mappingTimer invalidate];
        _mappingTimer = nil;
        [self cancelVimScroll];
        Vim::SelectAll(*_vim, [self vimHost]);
        [self refreshVimSelection:NO];
    } else {
        [super selectAll:sender];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = item.action;
    if (action == @selector(addCursorAbove:) || action == @selector(addCursorBelow:) ||
        action == @selector(addNextOccurrence:) || action == @selector(selectAllOccurrences:) ||
        action == @selector(addCursorsToLineEnds:))
        return self.editable && !self.vimCommandLine && !self.hasMarkedText;
    if (action == @selector(undoCursorChange:))
        return !_cursorHistory.empty();
    if (!_vimEnabled && _cursors.size() > 1 && (action == @selector(copy:) || action == @selector(cut:)))
        return YES;
    if (_vimEnabled) {
        if (item.action == @selector(copy:) || item.action == @selector(cut:))
            return Vim::IsVisual(_vim->mode);
        if (item.action == @selector(undo:))
            return self.undoManager.canUndo;
        if (item.action == @selector(redo:))
            return self.undoManager.canRedo;
    }
    return [super validateMenuItem:item];
}

- (NSUInteger)vimDocumentLineCount { return 1; }
- (NSUInteger)vimLineAtOffset:(NSUInteger)offset { (void)offset; return 0; }
- (NSUInteger)vimOffsetAtLine:(NSUInteger)line { (void)line; return 0; }
- (BOOL)vimStructuralCharacterAtOffset:(NSUInteger)offset { (void)offset; return YES; }
- (Vim::Comments)vimComments { return {}; }
- (NSUInteger)vimDefinitionAt:(NSUInteger)position { (void)position; return Vim::NoOffset; }
- (void)configureVimState:(Vim::State &)state { (void)state; }
- (BOOL)hasVimFolds { return NO; }
- (NSUInteger)vimFold:(char32_t)command at:(NSUInteger)position { (void)command; return position; }
- (NSUInteger)vimStepRow:(NSUInteger)row down:(BOOL)down count:(NSUInteger)count
{
    return down ? row + count : row - std::min(row, count);
}
- (NSUInteger)vimHiddenRows:(Vim::Range)rows { (void)rows; return 0; }
- (void)revealVimFoldAt:(NSUInteger)position { (void)position; }
- (std::optional<Vim::InsertEdit>)planVimInsert:(Vim::Key)key at:(NSUInteger)position
                                      tabWidth:(unsigned)tabWidth indentWidth:(unsigned)indentWidth
                                        spaces:(BOOL)spaces automaticIndent:(BOOL)automatic
{
    (void)key;
    (void)position;
    (void)tabWidth;
    (void)indentWidth;
    (void)spaces;
    (void)automatic;
    return {};
}

- (void)finishVimInsertEdit {}

- (std::optional<TypingEdit>)planCursorTyping:(Vim::Key)key selected:(NSRange)range
                                indentation:(const Indentation &)indentation
{
    (void)key;
    (void)range;
    (void)indentation;
    return {};
}

- (Indentation)cursorIndentation { return {}; }
- (void)didTypeAtCursors:(const std::vector<TypingEdit> &)edits { (void)edits; }
- (void)prepareCursorBatch {}

- (NSString *)vimIndentAfter:(NSUInteger)position tabWidth:(unsigned)tabWidth
                  indentWidth:(unsigned)indentWidth spaces:(BOOL)spaces
{
    (void)tabWidth;
    (void)indentWidth;
    (void)spaces;
    NSRange line = [self.string lineRangeForRange:NSMakeRange(position, 0)];
    NSUInteger end = line.location;
    while (end < position) {
        unichar ch = [self.string characterAtIndex:end];
        if (ch != ' ' && ch != '\t')
            break;
        ++end;
    }
    return [self.string substringWithRange:NSMakeRange(line.location, end - line.location)];
}

@end
