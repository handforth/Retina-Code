#import "Editor.h"
#import "Workspace.h"
#import "Chrome.h"
#import "DebugPane.h"
#import "EditorHover.h"
#import "FolderSearch.h"
#import "LanguageServer.h"
#import "Output.h"
#import "Preferences.h"
#import "Rendering.h"
#import "SessionState.h"
#import "Typing.h"
#import "VimView.h"
#include "../Comments.hpp"
#include "../Completion.hpp"
#include "../Lexer.hpp"
#include "../PopupColors.h"
#include "../Themes.h"

#import <CoreText/CoreText.h>
#import <objc/runtime.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <functional>
#include <iterator>
#include <map>
#include <memory>
#include <tuple>
#include <sys/stat.h>

static constexpr CGFloat editorPadding = 4;
static constexpr CGFloat editorLineSpacing = 3;
static constexpr CGFloat gutterInset = 9;
static constexpr CGFloat breakpointLane = 18;
static constexpr CGFloat statusHeight = 23;
static constexpr CGFloat minimumExplorerWidth = 140;
static constexpr CGFloat containerLimit = 10000000;
static constexpr NSUInteger largeDocumentLength = 64 * 1024;

static Indentation DefaultIndentation(IndentationSettings settings)
{
    return {settings.tabSize, settings.tabSize, settings.tabs, true};
}

NSArray<NSString *> *EditorLanguageNames()
{
    static NSArray<NSString *> *names = [] {
        NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:size_t(Language::Count)];
        for (size_t index = 0; index < size_t(Language::Count); ++index)
            [list addObject:@(InfoForLanguage(Language(index)).name)];
        return [list copy];
    }();
    return names;
}

void OpenSourceTab(NSURL *url, NSWindow *window, SourceOpenCompletion completion)
{
    if (!window) {
        completion(nil, NO, nil);
        return;
    }
    NSDocumentController *controller = NSDocumentController.sharedDocumentController;
    if ([controller respondsToSelector:@selector(openSourceURL:inWindow:asTab:completionHandler:)]) {
        [(id<SourceFileOpening>)controller openSourceURL:url inWindow:window asTab:YES completionHandler:completion];
    } else {
        [controller openDocumentWithContentsOfURL:url display:YES completionHandler:completion];
    }
}

NSString *DecodeSourceText(NSData *data, BOOL *hasBOM)
{
    if (!data)
        return nil;
    static const uint8_t bom[] = {0xEF, 0xBB, 0xBF};
    const auto *bytes = static_cast<const uint8_t *>(data.bytes);
    NSUInteger length = data.length;
    BOOL startsWithBOM = length >= sizeof(bom) && std::memcmp(bytes, bom, sizeof(bom)) == 0;
    if (hasBOM)
        *hasBOM = startsWithBOM;
    if (startsWithBOM) {
        bytes += sizeof(bom);
        length -= sizeof(bom);
    }
    if (!length)
        return @"";
    if (std::memchr(bytes, 0, length))
        return nil;
    return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
}

static NSData *EncodeSourceText(NSString *text, BOOL hasBOM)
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!hasBOM || !data)
        return data;
    const uint8_t bom[] = {0xEF, 0xBB, 0xBF};
    NSMutableData *withBOM = [NSMutableData dataWithBytes:bom length:sizeof(bom)];
    [withBOM appendData:data];
    return withBOM;
}

static Language LanguageForSource(NSURL *url, NSString *text = nil)
{
    const char *path = url.fileSystemRepresentation;
    NSString *beginning = [text substringToIndex:std::min<NSUInteger>(text.length, 512)];
    const char *prefix = beginning.UTF8String;
    return DetectLanguage(path ? path : "", prefix ? prefix : "");
}

static Language LegacyFileLanguage(NSURL *url)
{
    Language language = LanguageForSource(url);
    if (language == Language::JSX)
        return Language::JavaScript;
    if (language == Language::Python && [url.pathExtension.lowercaseString isEqualToString:@"pyx"])
        return Language::Plain;
    return language <= Language::JavaScript ? language : Language::Plain;
}

using NameCounts = std::map<std::u16string, size_t, std::less<>>;

struct LineStart {
    NSUInteger offset;
    size_t firstName;
    std::shared_ptr<const LexState> state;
};

template<class Row>
static void ReplaceIndexRows(std::vector<Row> &rows, size_t first, size_t past, std::span<Row> changed)
{
    size_t common = std::min(past - first, changed.size());
    auto start = rows.begin() + first;
    std::move(changed.begin(), changed.begin() + common, start);
    if (changed.size() < past - first) {
        rows.erase(start + common, rows.begin() + past);
    } else if (changed.size() > common) {
        rows.insert(rows.begin() + past, std::make_move_iterator(changed.begin() + common), std::make_move_iterator(changed.end()));
    }
}

enum class HighlightPass { Edit, Document, Appearance };

static const LexState defaultLexState;

struct BracketNode {
    uint32_t parent = 0;
    uint32_t depth = 0;
    std::array<uint32_t, 3> children{};
    uint8_t kind = 0;
};

static int BracketKind(char16_t character)
{
    switch (character) {
        case u'(': case u')': return 0;
        case u'[': case u']': return 1;
        case u'{': case u'}': return 2;
        default: return -1;
    }
}

static const LexState &IncomingState(const LineStart &line)
{
    return line.state ? *line.state : defaultLexState;
}

static constexpr CGFloat inlayInset = 3;
static constexpr CGFloat inlayGap = 2;
static constexpr NSTimeInterval inlayDebounce = 0.18;
static constexpr NSTimeInterval inlayRefreshDelay = 0.03;
static constexpr NSTimeInterval inlayRetryDelay = 0.4;
static constexpr NSTimeInterval inlayStartupWindow = 8;

struct InlayLabel {
    NSUInteger at;
    CGFloat textWidth;
    CGFloat left, right;
    id line; // Shaped Core Text line, shared by identical labels in this reply.
    bool startsWithColon = false;

    CGFloat width() const { return textWidth + inlayInset * 2 + left + right; }
};

static id ShapeInlayLine(NSString *text, NSDictionary *attributes, CGFloat &width)
{
    NSAttributedString *styled = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)styled);
    width = std::ceil(CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr));
    return (__bridge_transfer id)line;
}

static NSRange InlayLayoutRange(std::span<const InlayGap> gaps, NSUInteger textLength)
{
    if (gaps.empty())
        return {};
    NSUInteger start = gaps.front().lineStart;
    NSUInteger end = std::min(textLength, gaps.back().lineEnd + 1);
    return NSMakeRange(start, end - start);
}

static void InvalidateInlayLayout(NSLayoutManager *layout, NSRange range)
{
    if (!range.length)
        return;
    [layout invalidateGlyphsForCharacterRange:range changeInLength:0 actualCharacterRange:nullptr];
    [layout invalidateLayoutForCharacterRange:range actualCharacterRange:nullptr];
    [layout invalidateDisplayForCharacterRange:range];
}

static void RemoveInlayKerns(NSMutableAttributedString *contents, std::span<const InlayGap> gaps)
{
    for (const auto &gap : gaps) {
        if (gap.kind == InlayGapKind::Glyph)
            [contents removeAttribute:NSKernAttributeName range:NSMakeRange(gap.glyphStart, gap.at - gap.glyphStart)];
    }
}

static size_t BuildInlayGaps(NSMutableAttributedString *contents, std::span<const InlayLabel> labels, std::span<InlayGap> gaps)
{
    NSString *text = contents.string;
    NSUInteger lineStart = NSNotFound, lineEnd = 0;
    CGFloat preceding = 0;
    size_t count = 0;
    for (size_t i = 0; i < labels.size();) {
        NSUInteger at = labels[i].at;
        CGFloat width = 0;
        do {
            width += labels[i++].width();
        } while (i < labels.size() && labels[i].at == at);

        if (lineStart == NSNotFound || at > lineEnd) {
            [text getLineStart:&lineStart end:nullptr contentsEnd:&lineEnd forRange:NSMakeRange(at, 0)];
            preceding = 0;
        }

        InlayGap gap{at, lineStart, lineEnd, at, width, preceding, InlayGapKind::Leading};
        if (at != lineStart) {
            gap.glyphStart = [text rangeOfComposedCharacterSequenceAtIndex:at - 1].location;
            if ([text characterAtIndex:at - 1] == '\t') {
                gap.kind = InlayGapKind::Tab;
            } else {
                gap.kind = InlayGapKind::Glyph;
                [contents addAttribute:NSKernAttributeName value:@(width) range:NSMakeRange(gap.glyphStart, at - gap.glyphStart)];
            }
            preceding += width;
        }
        gaps[count++] = gap;
    }
    return count;
}

@interface EditorTextStorage : NSTextStorage <EditorInlaySpacing>
@property(nonatomic, copy) void (^beforeCharacterEdit)(NSRange, NSString *);
- (std::span<const InlayLabel>)inlayLabels;
- (void)replaceInlayLabels:(std::vector<InlayLabel>)labels;
- (void)applyAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes
               removing:(NSAttributedStringKey)key inRange:(NSRange)range;
- (void)styleTokens:(NSDictionary<NSAttributedStringKey, id> *)attributes inRange:(NSRange)range;
@end

@implementation EditorTextStorage {
    NSMutableAttributedString *_contents;
    std::vector<InlayLabel> _inlayLabels;
    std::vector<InlayGap> _inlayGaps;
    BOOL _introducedInlays;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _contents = [[NSMutableAttributedString alloc] init];
    return self;
}

- (NSString *)string { return _contents.string; }

- (std::span<const InlayLabel>)inlayLabels { return _inlayLabels; }
- (std::span<const InlayGap>)inlayGaps { return _inlayGaps; }

- (void)replaceInlayLabels:(std::vector<InlayLabel>)labels
{
    if (_inlayLabels.empty() && labels.empty())
        return;

    NSString *text = _contents.string;
    NSRange old = InlayLayoutRange(_inlayGaps, text.length);
    RemoveInlayKerns(_contents, _inlayGaps);
    _inlayLabels = std::move(labels);
    if (_inlayLabels.empty()) {
        std::vector<InlayGap>().swap(_inlayGaps);
    } else {
        _introducedInlays = YES;
        _inlayGaps.resize(_inlayLabels.size());
        _inlayGaps.resize(BuildInlayGaps(_contents, _inlayLabels, _inlayGaps));
    }

    NSRange current = InlayLayoutRange(_inlayGaps, text.length);
    if (NSIntersectionRange(old, current).length) {
        current = NSUnionRange(old, current);
        old = {};
    }
    for (CodeLayoutManager *layout in self.layoutManagers) {
        [layout setInlaySpacingSource:_inlayGaps.empty() ? nil : self];
        InvalidateInlayLayout(layout, old);
        InvalidateInlayLayout(layout, current);
        VimTextView *view = (VimTextView *)layout.textContainers.firstObject.textView;
        [view refreshVimCaretGeometry];
        [view updateInsertionPointStateAndRestartTimer:NO];
        [view setNeedsDisplayInRect:view.visibleRect];
    }
}

- (void)replaceContents:(NSRange)range text:(NSString *)text attributed:(NSAttributedString *)styled
{
    if (styled) {
        [_contents replaceCharactersInRange:range withAttributedString:styled];
        if (_introducedInlays && text.length)
            [_contents removeAttribute:NSKernAttributeName range:NSMakeRange(range.location, text.length)];
    } else {
        [_contents replaceCharactersInRange:range withString:text];
    }
}

- (void)editRange:(NSRange)range text:(NSString *)text attributed:(NSAttributedString *)styled
{
    if (_beforeCharacterEdit)
        _beforeCharacterEdit(range, text);
    NSUInteger oldEnd = NSMaxRange(range);
    NSInteger delta = NSInteger(text.length) - NSInteger(range.length);
    bool changedKerns = false;
    if (!_inlayGaps.empty()) {
        NSString *source = _contents.string;
        NSUInteger start, end;
        [source getLineStart:&start end:nullptr contentsEnd:nullptr forRange:NSMakeRange(range.location, 0)];
        [source getLineStart:nullptr end:&end contentsEnd:nullptr forRange:NSMakeRange(oldEnd, 0)];
        end += end == source.length;

        auto firstGap = std::ranges::lower_bound(_inlayGaps, start, {}, &InlayGap::at);
        auto pastGap = std::ranges::lower_bound(firstGap, _inlayGaps.end(), end, {}, &InlayGap::at);
        auto firstLabel = std::ranges::lower_bound(_inlayLabels, start, {}, &InlayLabel::at);
        auto pastLabel = std::ranges::lower_bound(firstLabel, _inlayLabels.end(), end, {}, &InlayLabel::at);
        changedKerns = firstGap != pastGap;
        RemoveInlayKerns(_contents, {firstGap, pastGap});

        if (firstLabel != pastLabel) {
            auto space = [](unichar ch) { return ch == ' ' || ch == '\t'; };
            NSUInteger first = 0;
            while (first < text.length && space([text characterAtIndex:first]))
                ++first;
            bool explicitType = first < text.length && [text characterAtIndex:first] == ':';
            NSUInteger annotation = range.location;
            if (explicitType) {
                while (annotation > start && space([source characterAtIndex:annotation - 1]))
                    --annotation;
            }
            bool splitLine = !range.length && [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound;
            auto kept = firstLabel;
            for (auto label = firstLabel; label != pastLabel; ++label) {
                NSUInteger at = label->at;
                if (at > range.location && at < oldEnd)
                    continue;
                if (explicitType && label->startsWithColon && at >= annotation && at <= range.location)
                    continue;
                // A separator leaves a type hint attached to the name on its left.
                bool stays = at == range.location && (splitLine || (label->startsWithColon && first == text.length));
                if (at >= oldEnd && !stays)
                    at += delta;
                label->at = at;
                if (kept != label)
                    *kept = std::move(*label);
                ++kept;
            }

            // The new anchors use the same labels while the server checks the edit.
            [self replaceContents:range text:text attributed:styled];
            NSUInteger length = _contents.length;
            if (!length) {
                kept = firstLabel;
            } else if ([NSCharacterSet.newlineCharacterSet characterIsMember:[_contents.string characterAtIndex:length - 1]]) {
                while (kept != firstLabel && (kept - 1)->at == length)
                    --kept;
            }
            size_t count = BuildInlayGaps(_contents, {firstLabel, kept}, {firstGap, pastGap});
            pastGap = _inlayGaps.erase(firstGap + count, pastGap);
            pastLabel = _inlayLabels.erase(kept, pastLabel);
        } else {
            [self replaceContents:range text:text attributed:styled];
        }

        if (delta) {
            for (auto gap = pastGap; gap != _inlayGaps.end(); ++gap) {
                gap->at += delta;
                gap->lineStart += delta;
                gap->lineEnd += delta;
                gap->glyphStart += delta;
            }
            for (auto label = pastLabel; label != _inlayLabels.end(); ++label)
                label->at += delta;
        }
        if (_inlayGaps.empty()) {
            for (CodeLayoutManager *layout in self.layoutManagers)
                [layout setInlaySpacingSource:nil];
        }
    } else {
        [self replaceContents:range text:text attributed:styled];
    }

    NSTextStorageEditActions actions = NSTextStorageEditedCharacters;
    if (styled || changedKerns)
        actions |= NSTextStorageEditedAttributes;
    [self edited:actions range:range changeInLength:delta];
}

- (void)fixAttributesInRange:(NSRange)range
{
    if (!_contents.length)
        return;
    // Validate the changed paragraphs without walking equal attribute runs across the file.
    NSRange paragraph = [_contents.string paragraphRangeForRange:range];
    if (!paragraph.length)
        return;
    if (paragraph.length > 4096 || paragraph.length == _contents.length) {
        [super fixAttributesInRange:range];
        return;
    }
    NSAttributedString *before = [_contents attributedSubstringFromRange:paragraph];
    NSMutableAttributedString *fixed = [before mutableCopy];
    [fixed fixAttributesInRange:NSMakeRange(0, fixed.length)];
    if (![before isEqualToAttributedString:fixed]) {
        [_contents replaceCharactersInRange:paragraph withAttributedString:fixed];
        [self edited:NSTextStorageEditedAttributes range:paragraph changeInLength:0];
    }
}


- (NSDictionary<NSAttributedStringKey, id> *)attributesAtIndex:(NSUInteger)index effectiveRange:(NSRangePointer)range
{
    return [_contents attributesAtIndex:index effectiveRange:range];
}

- (NSDictionary<NSAttributedStringKey, id> *)attributesAtIndex:(NSUInteger)index
                                        longestEffectiveRange:(NSRangePointer)range inRange:(NSRange)limit
{
    return [_contents attributesAtIndex:index longestEffectiveRange:range inRange:limit];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)text
{
    [self editRange:range text:text attributed:nil];
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)text
{
    [self editRange:range text:text.string attributed:text];
}

- (void)setAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes range:(NSRange)range
{
    [_contents setAttributes:attributes range:range];
    if (!_inlayGaps.empty() && range.length) {
        auto first = std::ranges::upper_bound(_inlayGaps, range.location, {}, &InlayGap::at);
        for (auto gap = first; gap != _inlayGaps.end() && gap->glyphStart < NSMaxRange(range); ++gap) {
            if (gap->kind != InlayGapKind::Glyph)
                continue;
            NSRange kern = NSMakeRange(gap->glyphStart, gap->at - gap->glyphStart);
            [_contents addAttribute:NSKernAttributeName value:@(gap->width) range:NSIntersectionRange(range, kern)];
        }
    }
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (void)addAttribute:(NSAttributedStringKey)key value:(id)value range:(NSRange)range
{
    [_contents addAttribute:key value:value range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (void)addAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes range:(NSRange)range
{
    [_contents addAttributes:attributes range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (void)removeAttribute:(NSAttributedStringKey)key range:(NSRange)range
{
    [_contents removeAttribute:key range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (void)applyAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes
               removing:(NSAttributedStringKey)key inRange:(NSRange)range
{
    if (!range.length)
        return;
    struct AttributeRewrite {
        NSDictionary *original;
        NSDictionary *updated;
    };
    std::array<AttributeRewrite, 16> recent{};
    size_t next = 0;
    NSDictionary *pending = nil;
    NSRange pendingRange{};
    // Merge equal runs from the end so collapsing a run never shifts the remaining input.
    for (NSUInteger end = NSMaxRange(range); end > range.location;) {
        @autoreleasepool {
            NSRange run;
            NSDictionary *original = [_contents attributesAtIndex:end - 1 effectiveRange:&run];
            auto cached = std::find_if(recent.begin(), recent.end(),
                [&](const AttributeRewrite &entry) { return entry.original == original; });
            NSDictionary *current;
            if (cached != recent.end()) {
                current = cached->updated;
            } else {
                NSMutableDictionary *updated = [original mutableCopy];
                [updated addEntriesFromDictionary:attributes];
                if (key)
                    [updated removeObjectForKey:key];
                current = [updated isEqualToDictionary:pending] ? pending : updated;
                recent[next++ % recent.size()] = {original, current};
            }
            NSUInteger start = std::max(run.location, range.location);
            if (current == pending || [current isEqualToDictionary:pending]) {
                pendingRange.length += end - start;
                pendingRange.location = start;
            } else {
                if (pendingRange.length)
                    [_contents setAttributes:pending range:pendingRange];
                pending = current;
                pendingRange = NSMakeRange(start, end - start);
            }
            end = start;
        }
    }
    [_contents setAttributes:pending range:pendingRange];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (void)styleTokens:(NSDictionary<NSAttributedStringKey, id> *)attributes inRange:(NSRange)range
{
    // The base style already marked this range as edited.
    [_contents addAttributes:attributes range:range];
}

@end

struct BuildError {
    NSRange range;
    NSString *message = nil;
    bool warning = false;
    NSString *label = nil;
    RunLocation location{};
    bool fromOutput = false;
    bool unusedWarning = false;
};

static std::optional<LSPPosition> LSPReadPosition(id value)
{
    NSDictionary *position = LSPDict(value);
    NSNumber *line = LSPNumber(position[@"line"]);
    NSNumber *column = LSPNumber(position[@"character"]);
    if (!line || !column || line.unsignedLongLongValue > INT32_MAX || column.unsignedLongLongValue > INT32_MAX)
        return {};
    return LSPPosition{line.unsignedIntegerValue, column.unsignedIntegerValue};
}

static NSCharacterSet *NonLSPLineBreaks()
{
    static NSCharacterSet *const characters = [NSCharacterSet characterSetWithCharactersInString:@"\u0085\u2028\u2029"];
    return characters;
}

struct LSPTextLines {
    std::vector<NSRange> lines;

    explicit LSPTextLines(NSString *text)
    {
        CFStringInlineBuffer buffer;
        CFStringInitInlineBuffer((__bridge CFStringRef)text, &buffer, CFRangeMake(0, text.length));
        NSUInteger start = 0, length = text.length;
        for (NSUInteger i = 0; i < length; ++i) {
            unichar ch = CFStringGetCharacterFromInlineBuffer(&buffer, i);
            if (ch != '\r' && ch != '\n')
                continue;
            lines.push_back(NSMakeRange(start, i - start));
            if (ch == '\r' && i + 1 < length && CFStringGetCharacterFromInlineBuffer(&buffer, i + 1) == '\n')
                ++i;
            start = i + 1;
        }
        lines.push_back(NSMakeRange(start, length - start));
    }

    NSUInteger offset(LSPPosition position) const
    {
        if (position.line >= lines.size())
            return NSNotFound;
        NSRange line = lines[position.line];
        return line.location + std::min(position.character, line.length);
    }

    LSPPosition position(NSUInteger offset) const
    {
        auto line = std::upper_bound(lines.begin(), lines.end(), offset,
            [](NSUInteger character, NSRange range) { return character < range.location; }) - 1;
        return {NSUInteger(line - lines.begin()), std::min(offset - line->location, line->length)};
    }
};

static NSRange LSPReadRange(id value, auto offsetAt)
{
    NSDictionary *range = LSPDict(value);
    auto first = LSPReadPosition(range[@"start"]), last = LSPReadPosition(range[@"end"]);
    if (!first || !last)
        return NSMakeRange(NSNotFound, 0);
    NSUInteger start = offsetAt(*first), end = offsetAt(*last);
    return start != NSNotFound && end != NSNotFound && start <= end ? NSMakeRange(start, end - start) : NSMakeRange(NSNotFound, 0);
}

static std::u16string LSPText(NSString *text)
{
    std::u16string result(text.length, 0);
    if (text.length)
        [text getCharacters:reinterpret_cast<unichar *>(result.data()) range:NSMakeRange(0, text.length)];
    return result;
}

static bool AddLSPTextEdits(id values, auto rangeInText, std::vector<Vim::CursorEdit> &edits)
{
    NSArray *items = LSPArray(values);
    if (!items || items.count > 50000)
        return false;
    edits.reserve(edits.size() + items.count);
    for (id item in items) {
        NSDictionary *edit = LSPDict(item);
        NSString *text = LSPString(edit[@"newText"]);
        NSRange range = rangeInText(edit[@"range"]);
        if (!text || range.location == NSNotFound)
            return false;
        edits.push_back({{range.location, NSMaxRange(range)}, LSPText(text)});
    }
    return true;
}

static NSURL *LSPFile(id uri)
{
    NSString *text = LSPString(uri);
    return text.length ? CanonicalFileURL([NSURL URLWithString:text]) : nil;
}

static NSString *ApplyWorkspaceLanguageEdit(id value, NSURL *root, NSString *name)
{
    NSDictionary *workspaceEdit = LSPDict(value);
    if (!workspaceEdit)
        return @"The language server returned an invalid edit.";
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    NSArray *changes = LSPArray(workspaceEdit[@"documentChanges"]);
    if (changes) {
        for (id item in changes) {
            NSDictionary *change = LSPDict(item);
            if (!LSPDict(change[@"textDocument"]) || !LSPArray(change[@"edits"]))
                return @"This edit includes a file operation.";
            [files addObject:change];
        }
    } else {
        NSDictionary *plain = LSPDict(workspaceEdit[@"changes"]);
        for (NSString *uri in plain)
            [files addObject:@{@"textDocument":@{@"uri":uri}, @"edits":plain[uri]}];
    }
    struct PlannedEdit {
        SourceDocument *document;
        Vim::EditBatch batch;
    };
    std::vector<PlannedEdit> plans;
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    NSDocumentController *documents = NSDocumentController.sharedDocumentController;
    for (NSDictionary *file in files) {
        NSDictionary *identifier = file[@"textDocument"];
        NSURL *url = LSPFile(identifier[@"uri"]);
        if (!url || !PathIsInFolder(url.path, root.path))
            return @"The edit refers to a file outside the workspace.";
        if ([paths containsObject:url.path])
            return @"The language server returned overlapping file edits.";
        [paths addObject:url.path];
        NSDocument *open = [documents documentForURL:url];
        if (!open) {
            for (NSDocument *candidate in documents.documents) {
                if ([CanonicalFileURL(candidate.fileURL).path isEqualToString:url.path]) {
                    open = candidate;
                    break;
                }
            }
        }
        if (open && ![open isKindOfClass:SourceDocument.class])
            return @"An affected file is open in a different document type.";
        NSNumber *version = LSPNumber(identifier[@"version"]);
        SourceDocument *document = (SourceDocument *)open;
        if (version && (!document || document.languageVersion != version.unsignedIntegerValue))
            return @"A file changed before the language server could edit it.";
        if (!document) {
            NSError *error = nil;
            document = [[SourceDocument alloc] initWithContentsOfURL:url ofType:@"public.source-code" error:&error];
            if (!document)
                return error.localizedDescription ? error.localizedDescription : @"An affected file could not be opened.";
        }
        LSPTextLines index(document.sourceText);
        std::vector<Vim::CursorEdit> edits;
        if (!AddLSPTextEdits(file[@"edits"], [&](id bounds) {
                return LSPReadRange(bounds, [&](LSPPosition position) { return index.offset(position); });
            }, edits))
            return @"The language server returned an invalid text range.";
        Vim::EditBatch batch;
        if (!batch.assign(std::move(edits), Vim::EditOrder::Server))
            return @"The language server returned overlapping text edits.";
        plans.push_back({document, std::move(batch)});
    }
    for (auto &plan : plans) {
        NSError *error = nil;
        if (![plan.document applySourceEdits:std::move(plan.batch) undoName:name error:&error])
            return error.localizedDescription ? error.localizedDescription : @"An affected file could not be edited.";
    }
    return nil;
}

@class SyntaxBuffer;

@interface SourceDocument (LanguageLocations)
- (void)revealLanguagePosition:(LSPPosition)position;
@end

@interface CodeView : VimTextView
@property(nonatomic) const Theme *theme;
@property(nonatomic) RenderSettings rendering;
@property(nonatomic) NSRect currentLine;
@property(nonatomic, copy) NSString *debugPath;
@property(nonatomic) NSUInteger debugLine;
@property(nonatomic, copy) NSString *debugException;
- (void)showDebugLine:(NSUInteger)line exception:(NSString *)exception;
@property(nonatomic, weak) SyntaxBuffer *syntax;
@property(nonatomic, readonly) NSFont *editorFont;
@property(nonatomic, copy) void (^revealError)(const BuildError &);
@property(nonatomic, readonly) BOOL hoverHasFocus;
@property(nonatomic, readonly) BOOL hasHoveredError;
- (void)applyAppearance;
- (void)applyAppearanceWithTheme:(const ThemeRef &)palette;
- (void)applyAppearanceWithTheme:(const ThemeRef &)palette font:(NSFont *)font hintFont:(NSFont *)hintFont;
- (void)loadText:(NSString *)text;
- (void)prepareDocumentAppearance:(NSString *)text;
- (void)refreshBracketMatch;
- (void)refreshWordSelection;
- (void)dismissCompletion;
- (void)dismissServerCompletion;
- (void)completionViewportChanged;
- (BOOL)validateCompletion;
- (void)diagnosticsChanged;
- (void)enumerateBuildErrorsInRect:(NSRect)area usingBlock:(void (^)(const BuildError &, NSRect))block;
- (BOOL)viewErrorAtCursor;
- (void)updateLanguageTracking;
- (void)updateLanguageHoverModifiers:(NSEventModifierFlags)flags atWindowPoint:(NSPoint)point;
- (void)updateLanguageHoverAtWindowPoint:(NSPoint)point modifiers:(NSEventModifierFlags)modifiers;
- (void)dismissLanguageInformation;
- (void)dismissPointerInformation;
- (void)scheduleSignatureHelp;
- (void)presentLanguageError:(NSString *)message;
- (IBAction)languageCommand:(NSMenuItem *)sender;
@end

@interface SyntaxBuffer : NSObject <NSTextStorageDelegate>
@property(nonatomic, readonly) EditorTextStorage *storage;
@property(nonatomic, copy) NSString *breakpointPath;
@property(nonatomic, readonly) Indentation indentation;
@property(nonatomic, readonly) BOOL hasFileIndentation;
@property(nonatomic) Language language;
@property(nonatomic) LSPDocument *languageDocument;
- (NSUInteger)lineForOffset:(NSUInteger)offset;
- (NSUInteger)offsetForLine:(NSUInteger)line;
- (NSUInteger)lineCount;
- (BOOL)codeAtOffset:(NSUInteger)offset;
- (LexState)contextAtOffset:(NSUInteger)offset;
- (size_t)completionWords:(std::u16string_view)prefix language:(Language)language results:(std::span<std::u16string_view>)results;
@property(nonatomic, readonly) NSUInteger textVersion;
- (const std::vector<TypedPair> &)typedPairs;
- (void)didType:(const TypingEdit &)edit;
- (void)didTypeInBatch:(const std::vector<TypingEdit> &)edits;
- (void)forgetTypedPairs;
- (void)setTheme:(const Theme *)theme;
- (void)setPalette:(const ThemeRef &)theme font:(NSFont *)font restyle:(BOOL)restyle
         brackets:(BOOL)brackets;
- (BOOL)hasPendingHighlighting;
- (void)finishHighlighting;
- (void)resolveIndentation:(NSString *)text;
- (void)refreshIndentationDefaults;
- (void)setFileIndentation:(Indentation)indentation;
- (void)resetFileIndentation;
- (const std::vector<BuildError> &)buildErrors;
- (void)refreshBuildErrorViews;
- (void)addBuildErrors:(const std::vector<BuildError> &)errors;
- (void)replaceCheckErrors:(const std::vector<BuildError> &)errors;
- (void)clearBuildErrors;
- (const std::vector<BuildError> &)languageErrors;
- (void)setLanguageErrors:(std::vector<BuildError>)errors;
- (LSPPosition)languagePosition:(NSUInteger)offset;
- (NSUInteger)languageOffset:(LSPPosition)position;
- (NSRange)languageRange:(id)range;
- (void)scheduleInlayHints;
- (void)scheduleInlayHintsAfter:(NSTimeInterval)delay;
- (void)refreshInlayHintsAfter:(NSTimeInterval)delay;
- (void)resetInlayHints;
- (void)suspendInlayHintsIfHidden;
@end

static NSRange LineContents(NSString *text, NSUInteger start)
{
    NSUInteger end = start;
    if (start < text.length)
        [text getLineStart:nullptr end:nullptr contentsEnd:&end forRange:NSMakeRange(start, 0)];
    return NSMakeRange(start, end - start);
}

@implementation SyntaxBuffer {
    ThemeRef _theme;
    NSArray<NSColor *> *_colors;
    std::array<NSDictionary *, size_t(Ink::Count) * 2> _tokenStyles;
    NSArray<NSColor *> *_bracketColors;
    std::vector<uint32_t> _bracketStarts;
    std::vector<BracketNode> _bracketNodes;
    NSFont *_font;
    NSFont *_italicFont;
    std::vector<TypedPair> _typedPairs;
    std::vector<BuildError> _buildErrors;
    std::vector<BuildError> _languageErrors;
    std::optional<LSPTextChange> _languageEdit;
    BOOL _languageReplacing;
    BOOL _languageHasOtherLineBreaks;
    NSTimer *_inlayTimer;
    NSInteger _inlayRequest;
    NSRange _inlayRows;
    NSTimeInterval _inlayRetryUntil; // Negative until the first visible request.
    std::vector<LineStart> _lines;
    std::vector<NameCounts::iterator> _lineNames;
    NameCounts _names;
    IndentationSettings _indentationDefaults;
    Indentation _indentation;
    bool _fileIndentationSet;
    NSRange _pendingRange;
    NSInteger _pendingDelta;
    BOOL _pending;
    BOOL _fullHighlightPending;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _storage = [[EditorTextStorage alloc] init];
        _storage.delegate = self;
        [self setTheme:&themes[0]];
    }
    return self;
}

- (NSUInteger)lineForOffset:(NSUInteger)offset
{
    auto past = std::upper_bound(_lines.begin(), _lines.end(), offset,
                                 [](NSUInteger value, const LineStart &line) { return value < line.offset; });
    return NSUInteger(past - _lines.begin() - 1);
}

- (void)resolveIndentation:(NSString *)text
{
    _indentationDefaults = IndentationPreference();
    if (!_fileIndentationSet) {
        _indentation = DefaultIndentation(_indentationDefaults);
        if (_indentationDefaults.detect)
            _indentation = DetectIndentation(text, _indentation);
    }
}

- (void)refreshIndentationDefaults
{
    if (_indentationDefaults != IndentationPreference())
        [self resolveIndentation:_storage.string];
}

- (void)setFileIndentation:(Indentation)indentation
{
    _fileIndentationSet = true;
    _indentation = indentation;
}

- (BOOL)hasFileIndentation { return _fileIndentationSet; }

- (void)resetFileIndentation
{
    _fileIndentationSet = false;
    [self resolveIndentation:_storage.string];
}

- (NSUInteger)offsetForLine:(NSUInteger)line
{
    return _lines[line].offset;
}

- (NSUInteger)lineCount
{
    return _lines.size();
}

- (BOOL)codeAtOffset:(NSUInteger)offset
{
    return ![_storage attribute:EditorNonCodeAttribute atIndex:offset effectiveRange:nullptr];
}

- (LexState)contextAtOffset:(NSUInteger)offset
{
    [self finishHighlighting];
    NSUInteger line = [self lineForOffset:offset];
    NSUInteger start = _lines[line].offset;
    std::u16string prefix(offset - start, 0);
    if (offset > start)
        [_storage.string getCharacters:reinterpret_cast<unichar *>(prefix.data())
                                 range:NSMakeRange(start, offset - start)];
    LexState state = IncomingState(_lines[line]);
    std::vector<Token> tokens;
    TokenizeLine(prefix, _language == Language::Plain ? Language::C : _language, state, tokens, false);
    return state;
}

- (size_t)completionWords:(std::u16string_view)prefix language:(Language)language results:(std::span<std::u16string_view>)results
{
    [self finishHighlighting];
    std::array<std::u16string_view, WordCompletionLimit> names;
    size_t count = 0;
    for (auto name = _names.upper_bound(prefix); name != _names.end() && count < names.size(); ++name) {
        if (!name->first.starts_with(prefix))
            break;
        names[count++] = name->first;
    }
    return MergeCompletionWords(prefix, language, std::span(names).first(count), results);
}

- (const std::vector<TypedPair> &)typedPairs { return _typedPairs; }

- (void)didType:(const TypingEdit &)edit
{
    RememberTypedPair(_typedPairs, edit.pair, edit.passedCloser == NSNotFound ? typingNotFound : edit.passedCloser,
                      _storage.length);
}

- (void)didTypeInBatch:(const std::vector<TypingEdit> &)edits
{
    if (edits.empty())
        return;
    std::vector<NSUInteger> passed;
    for (const auto &edit : edits) {
        if (edit.passedCloser != NSNotFound)
            passed.push_back(edit.passedCloser);
    }
    std::sort(passed.begin(), passed.end());
    if (!passed.empty()) {
        std::erase_if(_typedPairs, [&](const TypedPair &pair) {
            return std::binary_search(passed.begin(), passed.end(), pair.closing.end() - 1);
        });
    }
    for (const auto &edit : edits) {
        if (edit.pair && edit.pair->closing.end() <= _storage.length)
            _typedPairs.push_back(*edit.pair);
    }
    constexpr NSUInteger maxBatchPairs = 20000;
    if (_typedPairs.size() > maxBatchPairs)
        _typedPairs.erase(_typedPairs.begin(), _typedPairs.end() - maxBatchPairs);
}

- (void)forgetTypedPairs
{
    _typedPairs.clear();
}

- (NSDictionary *)tokenStyle:(Ink)ink nonCode:(bool)nonCode
{
    NSMutableDictionary *style = [NSMutableDictionary dictionaryWithCapacity:3];
    if (_language != Language::Plain && _theme->ink[size_t(ink)] != _theme->ink[size_t(Ink::Text)])
        style[NSForegroundColorAttributeName] = _colors[size_t(ink)];
    if (nonCode) {
        style[EditorNonCodeAttribute] = @(NSInteger(TypingRole(ink)));
    }
    if (_language != Language::Plain && _italicFont &&
        ((ink == Ink::Type && _theme->italicTypes) || (ink == Ink::Comment && _theme->italicComments)))
        style[NSFontAttributeName] = _italicFont;
    return [style copy];
}

- (uint32_t)colorBracketsInLine:(std::u16string_view)line tokens:(const std::vector<Token> &)tokens
                        offset:(NSUInteger)offset stack:(uint32_t)stack
                         local:(std::vector<uint8_t> &)local
{
    local.clear();
    size_t colorCount = _bracketColors.count;
    auto colorRange = [&](size_t first, size_t last) {
        for (size_t index = first; index < last; ++index) {
            char16_t ch = line[index];
            int kind = BracketKind(ch);
            if (kind < 0)
                continue;
            bool opening = ch == u'(' || ch == u'[' || ch == u'{';
            if (!opening) {
                if (!local.empty()) {
                    if (local.back() != kind)
                        continue;
                    local.pop_back();
                } else {
                    if (!stack || _bracketNodes[stack].kind != kind)
                        continue;
                    stack = _bracketNodes[stack].parent;
                }
            }
            size_t depth = _bracketNodes[stack].depth + local.size();
            [_storage addAttribute:NSForegroundColorAttributeName value:_bracketColors[depth % colorCount]
                             range:NSMakeRange(offset + index, 1)];
            if (opening)
                local.push_back(uint8_t(kind));
        }
    };

    // Brackets live between lexer tokens. String, comment, and escape spans stay intact.
    size_t start = 0;
    for (const auto &token : tokens) {
        colorRange(start, token.start);
        start = token.start + token.length;
    }
    colorRange(start, line.size());

    // Intern only nesting that crosses a line. Identical stacks reuse one index.
    for (uint8_t kind : local) {
        uint32_t next = _bracketNodes[stack].children[kind];
        if (!next) {
            next = uint32_t(_bracketNodes.size());
            uint32_t depth = _bracketNodes[stack].depth + 1;
            _bracketNodes[stack].children[kind] = next;
            _bracketNodes.push_back({stack, depth, {}, kind});
        }
        stack = next;
    }
    return stack;
}

- (void)highlightFrom:(NSUInteger)firstLine oldEnd:(NSUInteger)oldEnd delta:(NSInteger)delta
                 pass:(HighlightPass)pass restoreFont:(BOOL)restoreFont
{
    bool full = pass != HighlightPass::Edit;
    bool updateIndex = pass != HighlightPass::Appearance;
    NSString *text = _storage.string;
    NSUInteger length = text.length;
    NSUInteger offset = full ? 0 : _lines[firstLine].offset;
    LexState state = full ? defaultLexState : IncomingState(_lines[firstLine]);
    std::shared_ptr<const LexState> savedState = full ? nullptr : _lines[firstLine].state;
    std::array<std::shared_ptr<const LexState>, 8> recentStates{};
    size_t nextState = 0;
    bool plain = _language == Language::Plain;
    NSUInteger resume = full ? _lines.size() : [self lineForOffset:oldEnd] + 1;
    std::vector<LineStart> updated;
    bool colorize = _bracketColors.count != 0;
    uint32_t bracketStack = colorize && !full ? _bracketStarts[firstLine] : 0;
    std::vector<uint32_t> updatedBracketStarts;
    std::vector<uint8_t> localBrackets;
    std::u16string line;
    std::vector<Token> tokens;
    std::vector<NameCounts::iterator> names;
    NSColor *inkColor = _colors[size_t(Ink::Text)];
    NSDictionary *baseAttributes = (_italicFont || restoreFont) && _font ?
        @{NSForegroundColorAttributeName:inkColor, NSFontAttributeName:_font} :
        @{NSForegroundColorAttributeName:inkColor};
    if (full) {
        if (updateIndex) {
            updated.swap(_lines);
            updated.clear();
            names.swap(_lineNames);
            names.clear();
            if (length < names.capacity() / 2)
                names.shrink_to_fit();
            if (length >= largeDocumentLength) {
                // Size the line index without allocating substrings or growing the vector repeatedly.
                __block size_t count = 1;
                [text enumerateSubstringsInRange:NSMakeRange(0, length)
                    options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                    usingBlock:^(NSString *, NSRange, NSRange, BOOL *) { ++count; }];
                if (count < updated.capacity() / 2)
                    updated.shrink_to_fit();
                updated.reserve(count + count / 16);
            } else if (length < updated.capacity() / 2) {
                updated.shrink_to_fit();
            }
            _names.clear();
        }
        if (colorize) {
            updatedBracketStarts.swap(_bracketStarts);
            updatedBracketStarts.clear();
            _bracketNodes.clear();
            if (length < _bracketNodes.capacity() / 2)
                _bracketNodes.shrink_to_fit();
            _bracketNodes.emplace_back();
            size_t lineCapacity = updateIndex ? updated.capacity() : _lines.size();
            if (lineCapacity < updatedBracketStarts.capacity() / 2)
                updatedBracketStarts.shrink_to_fit();
            updatedBracketStarts.reserve(lineCapacity);
        }
        [_storage applyAttributes:baseAttributes removing:EditorNonCodeAttribute inRange:NSMakeRange(0, length)];
    }

    // A line beyond the edit can keep its colors once both incoming states match.
    for (;;) {
        while (resume < _lines.size() && NSInteger(_lines[resume].offset) + delta < NSInteger(offset))
            ++resume;
        if (resume < _lines.size() && NSInteger(_lines[resume].offset) + delta == NSInteger(offset) &&
            IncomingState(_lines[resume]) == state && (!colorize || _bracketStarts[resume] == bracketStack))
            break;

        if (updateIndex) {
            if (state == defaultLexState)
                savedState.reset();
            else if (!savedState || *savedState != state) {
                auto previous = std::find_if(recentStates.begin(), recentStates.end(),
                    [&](const auto &candidate) { return candidate && *candidate == state; });
                if (previous != recentStates.end()) {
                    savedState = *previous;
                } else {
                    // Reuse common states such as the same brace depth in consecutive functions.
                    savedState = std::make_shared<const LexState>(state);
                    recentStates[nextState++ % recentStates.size()] = savedState;
                }
            }
            updated.push_back({offset, names.size(), savedState});
        }
        if (colorize)
            updatedBracketStarts.push_back(bracketStack);
        if (offset == length) {
            resume = _lines.size();
            break;
        }

        NSUInteger end, contentsEnd;
        [text getLineStart:nullptr end:&end contentsEnd:&contentsEnd forRange:NSMakeRange(offset, 0)];
        line.resize(contentsEnd - offset);
        [text getCharacters:reinterpret_cast<unichar *>(line.data()) range:NSMakeRange(offset, line.size())];
        TokenizeLine(line, plain ? Language::C : _language, state, tokens);

        @autoreleasepool {
            if (!full)
                [_storage applyAttributes:baseAttributes removing:EditorNonCodeAttribute
                                  inRange:NSMakeRange(offset, end - offset)];
            for (const Token &token : tokens) {
                size_t ink = size_t(token.ink);
                NSRange range = NSMakeRange(offset + token.start, token.length);
                if (updateIndex && IsCompletionName(line, token, plain)) {
                    std::u16string_view word = std::u16string_view(line).substr(token.start, token.length);
                    auto name = _names.lower_bound(word);
                    if (name == _names.end() || name->first != word)
                        name = _names.emplace_hint(name, word, 0);
                    ++name->second;
                    names.push_back(name);
                }
                bool nonCode = IsNonCodeToken(token);
                auto &style = _tokenStyles[ink * 2 + nonCode];
                if (!style)
                    style = [self tokenStyle:token.ink nonCode:nonCode];
                if (style.count)
                    [_storage styleTokens:style inRange:range];
            }
            if (colorize)
                bracketStack = [self colorBracketsInLine:line tokens:tokens offset:offset stack:bracketStack local:localBrackets];
        }

        offset = end;
        if (offset == length && offset == contentsEnd) {
            resume = _lines.size();
            break;
        }
    }

    if (full) {
        if (updateIndex) {
            _lines = std::move(updated);
            _lineNames = std::move(names);
        }
        if (colorize)
            _bracketStarts = std::move(updatedBracketStarts);
    } else {
        // Each line points into one array of word uses. Replace the edited span.
        size_t firstName = _lines[firstLine].firstName;
        size_t pastName = resume < _lines.size() ? _lines[resume].firstName : _lineNames.size();
        for (size_t i = firstName; i < pastName; ++i) {
            auto name = _lineNames[i];
            if (--name->second == 0)
                _names.erase(name);
        }
        size_t replaced = pastName - firstName;
        ReplaceIndexRows(_lineNames, firstName, pastName, std::span(names));
        if (_lineNames.size() < _lineNames.capacity() / 4)
            _lineNames.shrink_to_fit();
        for (auto &line : updated)
            line.firstName += firstName;
        if (delta || names.size() != replaced) {
            for (size_t i = resume; i < _lines.size(); ++i) {
                _lines[i].offset = NSUInteger(NSInteger(_lines[i].offset) + delta);
                _lines[i].firstName = _lines[i].firstName - replaced + names.size();
            }
        }
        ReplaceIndexRows(_lines, firstLine, resume, std::span(updated));
        if (colorize)
            ReplaceIndexRows(_bracketStarts, firstLine, resume, std::span(updatedBracketStarts));
    }
}

- (void)highlightAll:(HighlightPass)pass restoreFont:(BOOL)restoreFont
{
    _pending = NO;
    [_storage beginEditing];
    [self highlightFrom:0 oldEnd:0 delta:0 pass:pass restoreFont:restoreFont];
    [_storage endEditing];
}

- (BOOL)hasPendingHighlighting
{
    return _pending;
}

- (const std::vector<BuildError> &)buildErrors { return _buildErrors; }
- (const std::vector<BuildError> &)languageErrors { return _languageErrors; }

- (void)refreshBuildErrorViews
{
    for (NSLayoutManager *layout in _storage.layoutManagers) {
        NSTextView *view = layout.textContainers.firstObject.textView;
        if ([view isKindOfClass:CodeView.class])
            [(CodeView *)view diagnosticsChanged];
        [view setNeedsDisplayInRect:view.visibleRect];
    }
}

- (void)addBuildErrors:(const std::vector<BuildError> &)errors
{
    if (errors.empty())
        return;
    _buildErrors.insert(_buildErrors.end(), errors.begin(), errors.end());
    std::stable_sort(_buildErrors.begin(), _buildErrors.end(), [](const BuildError &a, const BuildError &b) {
        return a.range.location < b.range.location ||
               (a.range.location == b.range.location && a.range.length < b.range.length);
    });
    auto end = std::unique(_buildErrors.begin(), _buildErrors.end(), [](const BuildError &a, const BuildError &b) {
        return NSEqualRanges(a.range, b.range);
    });
    _buildErrors.erase(end, _buildErrors.end());
    if (_buildErrors.size() > outputScrollbackLines)
        _buildErrors.resize(outputScrollbackLines);
    NSUInteger messageCharacters = outputScrollbackCharacters;
    for (auto &error : _buildErrors) {
        if (error.message.length > messageCharacters)
            error.message = nil;
        else
            messageCharacters -= error.message.length;
    }
    [self refreshBuildErrorViews];
}

- (void)clearBuildErrors
{
    if (!_buildErrors.empty()) {
        _buildErrors.clear();
        [self refreshBuildErrorViews];
    }
}

- (void)replaceCheckErrors:(const std::vector<BuildError> &)errors
{
    size_t removed = std::erase_if(_buildErrors, [](const BuildError &error) { return !error.fromOutput; });
    if (!errors.empty())
        [self addBuildErrors:errors];
    else if (removed)
        [self refreshBuildErrorViews];
}

- (void)setLanguageErrors:(std::vector<BuildError>)errors
{
    if (errors.empty() && _languageErrors.empty())
        return;
    std::stable_sort(errors.begin(), errors.end(), [](const BuildError &first, const BuildError &second) {
        return first.range.location < second.range.location;
    });
    _languageErrors = std::move(errors);
    [self refreshBuildErrorViews];
}

- (void)setLanguageDocument:(LSPDocument *)document
{
    [self resetInlayHints];
    _languageDocument = document;
    _inlayRetryUntil = document ? -1 : 0;
    _languageEdit.reset();
    _languageReplacing = NO;
    _languageHasOtherLineBreaks = document && [_storage.string rangeOfCharacterFromSet:NonLSPLineBreaks()].location != NSNotFound;
    if (document) {
        __weak SyntaxBuffer *buffer = self;
        _storage.beforeCharacterEdit = ^(NSRange range, NSString *text) { [buffer recordLanguageEdit:range text:text]; };
    } else {
        _storage.beforeCharacterEdit = nil;
    }
}

- (void)cancelInlayRequest
{
    if (_inlayRequest)
        [_languageDocument cancelRequest:std::exchange(_inlayRequest, 0)];
    _inlayRows = {};
}

- (void)resetInlayHints
{
    [_inlayTimer invalidate];
    _inlayTimer = nil;
    [self cancelInlayRequest];
    [_storage replaceInlayLabels:{}];
}

- (void)suspendInlayHintsIfHidden
{
    if (!_inlayRows.length && !_inlayTimer && [_storage inlayLabels].empty())
        return;
    for (NSLayoutManager *layout in _storage.layoutManagers) {
        if (layout.textContainers.firstObject.textView.window)
            return;
    }
    [self resetInlayHints];
}

- (void)refreshInlayHintsAfter:(NSTimeInterval)delay
{
    [_inlayTimer invalidate];
    _inlayTimer = nil;
    [self cancelInlayRequest];
    [self scheduleInlayHintsAfter:delay];
}

- (void)scheduleInlayHints
{
    [self scheduleInlayHintsAfter:inlayDebounce];
}

- (void)scheduleInlayHintsAfter:(NSTimeInterval)delay
{
    if (!ShowInlayHints() || _inlayTimer || !_storage.length ||
        ![_languageDocument supports:@"inlayHintProvider"])
        return;
    __weak SyntaxBuffer *buffer = self;
    _inlayTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *) {
        SyntaxBuffer *target = buffer;
        if (target) {
            target->_inlayTimer = nil;
            [target requestInlayViewport];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_inlayTimer forMode:NSRunLoopCommonModes];
}

- (void)requestInlayViewport
{
    if (!ShowInlayHints() || !_storage.length || ![_languageDocument supports:@"inlayHintProvider"])
        return;

    constexpr NSUInteger maxRows = 256;
    constexpr NSUInteger margin = 24;
    NSRange visible{};
    bool focused = false;
    [self finishHighlighting];
    for (NSLayoutManager *layout in _storage.layoutManagers) {
        CodeView *view = (CodeView *)layout.textContainers.firstObject.textView;
        if (!view.window.isKeyWindow || view.isHiddenOrHasHiddenAncestor || NSIsEmptyRect(view.visibleRect))
            continue;
        auto characters = [view vimCharactersInViewport:view.visibleRect];
        NSUInteger first = [self lineForOffset:characters.first];
        NSUInteger last = [self lineForOffset:characters.last];
        NSRange rows = NSMakeRange(first, std::min(last - first + 1, maxRows));
        NSRange both = visible.length ? NSUnionRange(visible, rows) : rows;
        bool active = view.window.firstResponder == view;
        if (both.length <= maxRows)
            visible = both;
        else if (active || !focused)
            visible = rows;
        focused |= active;
    }
    if (!visible.length || NSEqualRanges(NSIntersectionRange(visible, _inlayRows), visible))
        return;

    [self cancelInlayRequest];
    NSUInteger before = std::min({visible.location, margin, (maxRows - visible.length) / 2});
    NSUInteger after = std::min({NSUInteger(_lines.size()) - NSMaxRange(visible), margin,
                                 maxRows - visible.length - before});
    NSRange rows = NSMakeRange(visible.location - before, visible.length + before + after);
    NSUInteger past = NSMaxRange(rows);
    LSPPosition start = [self languagePosition:_lines[rows.location].offset];
    LSPPosition end = [self languagePosition:past < _lines.size() ? _lines[past].offset : _storage.length];
    NSUInteger version = _textVersion;
    if (_inlayRetryUntil < 0)
        _inlayRetryUntil = NSProcessInfo.processInfo.systemUptime + inlayStartupWindow;

    __weak SyntaxBuffer *buffer = self;
    _inlayRequest = [_languageDocument requestInlayHintsFrom:start to:end reply:^(lsp::InlayHints hints, BOOL succeeded) {
        SyntaxBuffer *target = buffer;
        if (!target || version != target->_textVersion)
            return;
        target->_inlayRequest = 0;
        if (succeeded) {
            [target placeInlayHints:hints inRows:rows];
            if (!hints.items.empty())
                target->_inlayRetryUntil = 0;
        } else {
            target->_inlayRows = {};
        }

        // Startup analysis can leave hints empty or invalidate an in-flight request.
        if (target->_inlayRetryUntil && NSProcessInfo.processInfo.systemUptime + inlayRetryDelay < target->_inlayRetryUntil) {
            target->_inlayRows = {};
            [target scheduleInlayHintsAfter:inlayRetryDelay];
        }
    }];
    if (_inlayRequest)
        _inlayRows = rows;
}

- (void)placeInlayHints:(lsp::InlayHints &)hints inRows:(NSRange)rows
{
    if (hints.items.empty() || !_font || !_storage.length) {
        [_storage replaceInlayLabels:{}];
        return;
    }

    NSFont *font = InlayFont(_font);
    NSDictionary *attributes = @{NSFontAttributeName:font, (id)kCTForegroundColorFromContextAttributeName:@YES};

    NSString *text = _storage.string;
    std::optional<LSPTextLines> otherLineBreaks;
    if (_languageHasOtherLineBreaks)
        otherLineBreaks.emplace(text);
    struct Shape {
        std::string_view label;
        id line = nil;
        CGFloat width = 0;
    };
    std::array<Shape, 64> shapes{};
    std::ranges::sort(hints.items, [](const auto &first, const auto &second) {
        return std::tie(first.line, first.character, first.labelOffset) <
               std::tie(second.line, second.character, second.labelOffset);
    });
    std::vector<InlayLabel> labels;
    labels.reserve(hints.items.size());
    NSUInteger row = NSNotFound, start = 0, end = 0;
    for (const auto &hint : hints.items) {
        if (hint.line != row) {
            row = hint.line;
            if (row >= (otherLineBreaks ? otherLineBreaks->lines.size() : _lines.size()))
                break;

            NSRange line = otherLineBreaks ? otherLineBreaks->lines[row] : LineContents(text, _lines[row].offset);
            start = line.location;
            end = NSMaxRange(line);
        }
        NSUInteger at = start + hint.character;
        if (start >= text.length || at > end || !NSLocationInRange([self lineForOffset:at], rows))
            continue;
        if (at < text.length && at != [text rangeOfComposedCharacterSequenceAtIndex:at].location)
            continue;

        @autoreleasepool {
            auto label = std::string_view(hints.labels).substr(hint.labelOffset, hint.labelLength);
            auto &shape = shapes[std::hash<std::string_view>{}(label) % shapes.size()];
            if (shape.label != label) {
                NSString *string = [[NSString alloc] initWithBytes:label.data() length:label.size() encoding:NSUTF8StringEncoding];
                if (!string)
                    continue;

                CGFloat width;
                id line = ShapeInlayLine(string, attributes, width);
                shape = {label, line, width};
            }
            labels.push_back({at, shape.width, hint.paddingLeft ? inlayGap : 0,
                              hint.paddingRight ? inlayGap : 0, shape.line, label.starts_with(':')});
        }
    }
    [_storage replaceInlayLabels:std::move(labels)];
}

- (LSPPosition)languagePosition:(NSUInteger)offset
{
    [self finishHighlighting];
    NSString *text = _storage.string;
    offset = std::min(offset, text.length);
    if (_languageHasOtherLineBreaks)
        return LSPTextLines(text).position(offset);
    NSUInteger line = [self lineForOffset:offset];
    return {line, offset - _lines[line].offset};
}

- (NSUInteger)languageOffset:(LSPPosition)position
{
    [self finishHighlighting];
    NSString *text = _storage.string;
    if (_languageHasOtherLineBreaks)
        return LSPTextLines(text).offset(position);
    if (position.line >= _lines.size())
        return NSNotFound;
    NSRange line = LineContents(text, _lines[position.line].offset);
    return line.location + std::min(position.character, line.length);
}

- (NSRange)languageRange:(id)range
{
    if (_languageHasOtherLineBreaks) {
        LSPTextLines lines(_storage.string);
        return LSPReadRange(range, [&](LSPPosition position) { return lines.offset(position); });
    }
    return LSPReadRange(range, [&](LSPPosition position) { return [self languageOffset:position]; });
}

- (void)recordLanguageEdit:(NSRange)range text:(NSString *)replacement
{
    for (NSLayoutManager *layout in _storage.layoutManagers) {
        NSTextView *view = layout.textContainers.firstObject.textView;
        if ([view isKindOfClass:CodeView.class])
            [(CodeView *)view dismissPointerInformation];
    }
    NSString *text = _storage.string;
    auto splitsNewline = [&](NSUInteger offset) {
        return offset && offset < text.length && [text characterAtIndex:offset] == '\n' &&
            [text characterAtIndex:offset - 1] == '\r';
    };
    if (_languageDocument.sendingChanges && !_languageReplacing && !_pending && !_lines.empty() &&
        !_languageHasOtherLineBreaks && !splitsNewline(range.location) && !splitsNewline(NSMaxRange(range))) {
        NSUInteger first = [self lineForOffset:range.location], last = [self lineForOffset:NSMaxRange(range)];
        _languageEdit = LSPTextChange{{first, range.location - _lines[first].offset},
                                      {last, NSMaxRange(range) - _lines[last].offset}, [replacement copy]};
    } else {
        _languageEdit.reset();
    }
    _languageReplacing = YES;
    if (!_languageHasOtherLineBreaks && [replacement rangeOfCharacterFromSet:NonLSPLineBreaks()].location != NSNotFound)
        _languageHasOtherLineBreaks = YES;
}

- (void)finishHighlighting
{
    if (!_pending)
        return;
    if (_fullHighlightPending) {
        [self highlightAll:HighlightPass::Document restoreFont:NO];
        return;
    }

    _pending = NO;
    NSUInteger first = [self lineForOffset:_pendingRange.location];
    if (first > 0 && _pendingRange.location == _lines[first].offset)
        --first;
    NSUInteger oldEnd = NSUInteger(NSInteger(NSMaxRange(_pendingRange)) - _pendingDelta);
    [_storage beginEditing];
    [self highlightFrom:first oldEnd:oldEnd delta:_pendingDelta pass:HighlightPass::Edit restoreFont:NO];
    [_storage endEditing];
}

- (void)setTheme:(const Theme *)theme
{
    [self setPalette:StaticTheme(theme) font:_font restyle:NO brackets:BracketColorizationPreference()];
}

- (void)setPalette:(const ThemeRef &)theme font:(NSFont *)font restyle:(BOOL)restyle
         brackets:(BOOL)brackets
{
    bool paletteChanged = !_theme || _theme->ink != theme->ink;
    bool italicChanged = !_theme || _theme->italicTypes != theme->italicTypes ||
                         _theme->italicComments != theme->italicComments;
    auto previousBrackets = _bracketColors.count ? _theme->bracketColors : std::span<const Col32>{};
    auto nextBrackets = brackets ? theme->bracketColors : std::span<const Col32>{};
    bool bracketsChanged = !std::ranges::equal(previousBrackets, nextBrackets);
    _theme = theme;
    if (!paletteChanged && !italicChanged && !bracketsChanged && _font == font && !restyle)
        return;
    _tokenStyles.fill(nil);
    NSFont *previousItalicFont = _italicFont;
    BOOL inlayFontChanged = ![_font isEqual:font];
    _font = font;
    NSFont *italic = (theme->italicTypes || theme->italicComments) && font ?
                     [NSFontManager.sharedFontManager convertFont:font toHaveTrait:NSItalicFontMask] : nil;
    _italicFont = [italic isEqual:font] ? nil : italic;
    BOOL restoreFont = previousItalicFont && !_italicFont;
    if (paletteChanged) {
        NSMutableArray<NSColor *> *colors = [NSMutableArray arrayWithCapacity:size_t(Ink::Count)];
        for (Col32 color : theme->ink)
            [colors addObject:SRGBColor(color)];
        _colors = colors;
    }
    if (bracketsChanged) {
        if (nextBrackets.empty()) {
            _bracketColors = nil;
            _bracketStarts.clear();
            _bracketStarts.shrink_to_fit();
            _bracketNodes.clear();
            _bracketNodes.shrink_to_fit();
        } else {
            NSMutableArray<NSColor *> *colors = [NSMutableArray arrayWithCapacity:nextBrackets.size()];
            for (Col32 color : nextBrackets)
                [colors addObject:SRGBColor(color)];
            _bracketColors = colors;
        }
    }
    if (paletteChanged || bracketsChanged || _italicFont) {
        HighlightPass pass = _pending || _lines.empty() ? HighlightPass::Document : HighlightPass::Appearance;
        [self highlightAll:pass restoreFont:restoreFont];
    } else if (restoreFont && font) {
        [_storage applyAttributes:@{NSFontAttributeName:font} removing:nil inRange:NSMakeRange(0, _storage.length)];
    }
    if (inlayFontChanged && ShowInlayHints()) {
        [self resetInlayHints];
        [self scheduleInlayHints];
    }
}

- (void)setLanguage:(Language)language
{
    if (_language != language) {
        if (_language == Language::Plain || language == Language::Plain)
            _tokenStyles.fill(nil);
        _language = language;
        ++_textVersion;
        [self clearBuildErrors];
        [self forgetTypedPairs];
        [self highlightAll:HighlightPass::Document restoreFont:NO];
    }
}

- (void)textStorage:(NSTextStorage *)storage willProcessEditing:(NSTextStorageEditActions)actions
             range:(NSRange)range changeInLength:(NSInteger)delta
{
    if (storage != _storage || !(actions & NSTextStorageEditedCharacters))
        return;
    ++_textVersion;
    [self clearBuildErrors];
    if (_languageDocument) {
        [_languageDocument changed:std::exchange(_languageEdit, std::nullopt)];
        if (ShowInlayHints())
            [self refreshInlayHintsAfter:inlayDebounce];
    }
    _languageReplacing = NO;
    NSUInteger oldLength = NSUInteger(NSInteger(range.length) - delta);
    NSRange previous = NSMakeRange(range.location, oldLength);
    // The line index still describes the old text at the start of an edit.
    if (!_pending && !_lines.empty() && DebugBreakpoints(_breakpointPath).count) {
        NSUInteger first = [self lineForOffset:previous.location];
        NSUInteger last = [self lineForOffset:NSMaxRange(previous)];
        NSUInteger oldLines = last - first;
        NSUInteger newLines = 0;
        NSString *text = storage.string;
        for (NSUInteger position = range.location; position < NSMaxRange(range);) {
            NSUInteger next, contentsEnd;
            [text getLineStart:nullptr end:&next contentsEnd:&contentsEnd forRange:NSMakeRange(position, 0)];
            if (next <= NSMaxRange(range) && contentsEnd < next)
                ++newLines;
            position = next;
        }
        // Inserting text at the start of a line moves its breakpoint with the original text.
        NSUInteger firstAffected = first + (previous.location == _lines[first].offset ? 1 : 2);
        ShiftDebugBreakpoints(_breakpointPath, firstAffected, oldLines, newLines);
    }
    const auto *batch = [VimTextView cursorBatchForStorage:storage];
    Vim::EditMap edit{{previous.location, NSMaxRange(previous)}, range.length, batch};
    AdjustTypedPairs(_typedPairs, edit);
    [VimTextView vimStorage:storage edited:edit];
    for (NSLayoutManager *layout in storage.layoutManagers) {
        NSTextView *view = layout.textContainers.firstObject.textView;
        if ([view isKindOfClass:VimTextView.class])
            [(VimTextView *)view vimStorageEdited:edit];
    }

    // Applying color separately keeps TextKit's character edit and caret movement intact.
    _fullHighlightPending = _pending || (range.location == 0 && range.length == storage.length) ||
        (batch && batch->edits.size() >= 32 && range.length >= storage.length - storage.length / 4);
    if (!_pending) {
        _pending = YES;
        __weak SyntaxBuffer *buffer = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [buffer finishHighlighting]; });
    }
    _pendingRange = range;
    _pendingDelta = delta;
}

@end

static bool LispSymbols(Language language)
{
    return language == Language::CommonLisp || language == Language::Clojure;
}

static bool WordCharacterAt(NSString *text, NSUInteger offset, bool lisp = false)
{
    unichar character = [text characterAtIndex:offset];
    if (lisp)
        return IsLispSymbolPart(character);
    if (character < 0x80)
        return IsASCIIIdentifierPart(character);

    UTF32Char scalar = character;
    if (CFStringIsSurrogateHighCharacter(character) && offset + 1 < text.length) {
        unichar next = [text characterAtIndex:offset + 1];
        if (CFStringIsSurrogateLowCharacter(next))
            scalar = CFStringGetLongCharacterForSurrogatePair(character, next);
    } else if (CFStringIsSurrogateLowCharacter(character) && offset > 0) {
        unichar previous = [text characterAtIndex:offset - 1];
        if (CFStringIsSurrogateHighCharacter(previous))
            scalar = CFStringGetLongCharacterForSurrogatePair(previous, character);
    }
    static NSCharacterSet *const wordCharacters = NSCharacterSet.alphanumericCharacterSet;
    return [wordCharacters longCharacterIsMember:scalar];
}

static bool AtWordBoundaries(NSString *text, NSRange range, bool lisp)
{
    return (range.location == 0 || !WordCharacterAt(text, range.location - 1, lisp)) &&
           (NSMaxRange(range) == text.length || !WordCharacterAt(text, NSMaxRange(range), lisp));
}

bool IsWholeSourceWord(NSString *text, NSRange range)
{
    return AtWordBoundaries(text, range, false);
}

static NSRange SourceLine(SyntaxBuffer *buffer, NSUInteger line)
{
    if (!line || line > buffer.lineCount)
        return NSMakeRange(NSNotFound, 0);
    return LineContents(buffer.storage.string, [buffer offsetForLine:line - 1]);
}

static NSUInteger SourceColumn(NSString *text, NSRange line, NSUInteger column, bool byteColumns, bool hasBOM)
{
    // Clang's columns count UTF-8 bytes. Rust's columns count Unicode characters.
    NSUInteger remaining = column ? column - 1 : 0;
    if (line.location == 0 && byteColumns && hasBOM)
        remaining -= std::min(remaining, NSUInteger(3));
    NSUInteger at = line.location;
    NSUInteger end = NSMaxRange(line);
    while (remaining && at < end) {
        UTF32Char scalar = [text characterAtIndex:at];
        NSUInteger length = 1;
        if (CFStringIsSurrogateHighCharacter(scalar) && at + 1 < end) {
            unichar low = [text characterAtIndex:at + 1];
            if (CFStringIsSurrogateLowCharacter(low)) {
                scalar = CFStringGetLongCharacterForSurrogatePair(scalar, low);
                length = 2;
            }
        }
        NSUInteger width = !byteColumns || scalar < 0x80 ? 1 : scalar < 0x800 ? 2 : scalar < 0x10000 ? 3 : 4;
        if (remaining < width)
            break;
        remaining -= width;
        at += length;
    }
    return at;
}

static NSUInteger DiagnosticColumn(NSString *text, NSRange line, NSUInteger column, const RunLocation &location, bool hasBOM)
{
    if (location.utf16Columns)
        return line.location + std::min(line.length, column ? column - 1 : 0);

    return SourceColumn(text, line, column, location.byteColumns, hasBOM);
}

static NSRange BuildErrorRange(SyntaxBuffer *buffer, const RunLocation &location, BOOL hasBOM)
{
    NSRange line = SourceLine(buffer, location.line);
    if (line.location == NSNotFound && location.line == buffer.lineCount + 1)
        return NSMakeRange(buffer.storage.length, 0);
    if (!line.length)
        return line;

    NSString *text = buffer.storage.string;
    if (location.endColumn > location.firstColumn) {
        NSUInteger start = DiagnosticColumn(text, line, location.firstColumn, location, hasBOM);
        NSUInteger end = DiagnosticColumn(text, line, location.endColumn, location, hasBOM);
        if (end > start)
            return NSMakeRange(start, end - start);
    }
    NSUInteger at = DiagnosticColumn(text, line, location.column, location, hasBOM);
    NSRange token = [text rangeOfComposedCharacterSequenceAtIndex:std::min(at, NSMaxRange(line) - 1)];
    while (NSMaxRange(token) < NSMaxRange(line) && WordCharacterAt(text, token.location) &&
           WordCharacterAt(text, NSMaxRange(token))) {
        NSRange next = [text rangeOfComposedCharacterSequenceAtIndex:NSMaxRange(token)];
        token.length += next.length;
    }
    return token;
}

static bool DiagnosticContains(NSString *text, NSString *fragment)
{
    return [text rangeOfString:fragment options:NSCaseInsensitiveSearch].length != 0;
}

static bool IsHideableUnusedWarning(SyntaxBuffer *buffer, NSUInteger offset, NSString *code, NSString *message)
{
    bool unused = DiagnosticContains(code, @"unused") || DiagnosticContains(code, @"dead_code") || DiagnosticContains(code, @"dead-code");
    if (!unused && message.length) {
        // The LSP Unnecessary tag also covers unrelated warnings, so use the diagnostic text when the code is generic.
        static NSRegularExpression *const pattern = [NSRegularExpression regularExpressionWithPattern:@"(?<!['\"`])\\b(?:unused|unreferenced)\\b|\\bnever (?:be )?(?:used|read|referenced|called|constructed|accessed)\\b|\\bnot (?:used|read|referenced|accessed)\\b" options:NSRegularExpressionCaseInsensitive error:nil];
        unused = [pattern rangeOfFirstMatchInString:message options:0 range:NSMakeRange(0, message.length)].length != 0;
    }
    if (!unused)
        return false;

    if (DiagnosticContains(code, @"import") || DiagnosticContains(code, @"include") || DiagnosticContains(code, @"extern_crate") || DiagnosticContains(code, @"extern-crate") || DiagnosticContains(code, @"using-decl") || [code isEqualToString:@"F401"])
        return false;

    static NSString *const importPhrases[] = {@"unused import", @"unused include", @"included header", @"imported but", @"imported and", @"import declaration", @"using declaration"};
    for (NSString *phrase : importPhrases) {
        if (DiagnosticContains(message, phrase))
            return false;
    }

    if (JavaScriptFamily(buffer.language)) {
        // TypeScript uses the same code and message for unused bindings and individual imports.
        static NSRegularExpression *const importPrefix = [NSRegularExpression regularExpressionWithPattern:@"(?m)(?:^|;)\\h*import\\b\\s*(?:(?:type\\s+)?(?:[$\\w]+\\s*,\\s*)?\\{[^{};]*|[\\w$*][^\\r\\n;{}]*)?\\z" options:0 error:nil];
        NSUInteger length = std::min(offset, NSUInteger(2048));
        NSRange prefix = NSMakeRange(offset - length, length);
        if ([importPrefix rangeOfFirstMatchInString:buffer.storage.string options:0 range:prefix].length)
            return false;
    }
    return true;
}

static constexpr CGFloat completionInset = 2;
static constexpr CGFloat completionKindWidth = 19;
static constexpr NSUInteger completionLimit = WordCompletionLimit;
static constexpr size_t completionCacheLimit = 256;

enum class CompletionKind { Word, Function, Type, Variable, Field, Module, Keyword, Value };
enum class CallParameters : uint8_t { Unknown, None, Arguments, Receiver };

struct CompletionItem {
    NSString *label = nil;
    NSString *text = nil;
    NSString *filter = nil;
    NSString *order = nil;
    NSDictionary *replaceRange = nil;
    NSArray *additionalEdits = nil;
    CompletionKind kind = CompletionKind::Word;
    NSString *detail = nil;
    NSString *labelDetail = nil;
};

struct CompletionEdit {
    NSRange range;
    std::u16string text;
    NSUInteger caret;
    NSUInteger existingCaret = NSNotFound;
    NSUInteger newPair = NSNotFound;
};

static NSFont *PopupCodeFont(NSFont *font)
{
    CGFloat size = std::clamp(font.pointSize, 11.0, 14.0);
    if (font && size == font.pointSize)
        return font;

    NSFont *resized = font ? [NSFont fontWithName:font.fontName size:size] : nil;
    return resized ? resized : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}

static std::u16string_view TrimSignature(std::u16string_view text)
{
    size_t first = text.find_first_not_of(u" \t\r\n");
    if (first == text.npos)
        return {};
    return text.substr(first, text.find_last_not_of(u" \t\r\n") - first + 1);
}

static bool RustReceiverOnly(std::u16string_view parameters)
{
    if (parameters.starts_with(u"&"))
        parameters = TrimSignature(parameters.substr(1));
    if (parameters.starts_with(u"'")) {
        size_t end = parameters.find_first_of(u" \t");
        if (end == parameters.npos)
            return false;
        parameters = TrimSignature(parameters.substr(end));
    }
    if (parameters.starts_with(u"mut ") || parameters.starts_with(u"mut\t"))
        parameters = TrimSignature(parameters.substr(3));
    if (!parameters.starts_with(u"self"))
        return false;
    parameters = TrimSignature(parameters.substr(4));
    if (!parameters.empty() && parameters.back() == u',')
        parameters = TrimSignature(parameters.substr(0, parameters.size() - 1));
    if (parameters.empty())
        return true;
    if (!parameters.starts_with(u":"))
        return false;
    // An explicit receiver type can contain commas of its own.
    unsigned nesting = 0;
    for (char16_t character : parameters) {
        if (character == u',' && !nesting)
            return false;
        if (character == u'<' || character == u'(' || character == u'[' || character == u'{')
            ++nesting;
        else if (nesting && (character == u'>' || character == u')' || character == u']' || character == u'}'))
            --nesting;
    }
    return true;
}

static CallParameters ParametersInSignature(NSString *signature, Language language, NSUInteger *argumentStart = nullptr)
{
    if (!signature.length || signature.length > 1024)
        return CallParameters::Unknown;
    auto text = LSPText(signature);
    unsigned angles = 0, parentheses = 0;
    size_t opening = 0;
    for (size_t i = 0; i < text.size(); ++i) {
        char16_t character = text[i];
        if (character == u'(' && (parentheses || !angles)) {
            if (parentheses++ == 0)
                opening = i;
        } else if (character == u')' && parentheses && --parentheses == 0) {
            if (argumentStart)
                *argumentStart = opening;
            auto parameters = TrimSignature(std::u16string_view(text).substr(opening + 1, i - opening - 1));
            if (parameters.empty() || (CFamily(language) && parameters == u"void"))
                return CallParameters::None;
            return language == Language::Rust && RustReceiverOnly(parameters) ? CallParameters::Receiver : CallParameters::Arguments;
        } else if (!parentheses && character == u'<') {
            ++angles;
        } else if (!parentheses && angles && character == u'>' && (i == 0 || text[i - 1] != u'-')) {
            --angles;
        }
    }
    return CallParameters::Unknown;
}

static CallParameters CompletionParameters(const CompletionItem &item, Language language)
{
    for (NSString *signature : {language == Language::Rust ? item.detail : item.labelDetail,
                               language == Language::Rust ? item.labelDetail : item.label,
                               language == Language::Rust ? item.label : item.detail}) {
        CallParameters result = ParametersInSignature(signature, language);
        if (result != CallParameters::Unknown)
            return result;
    }
    return CallParameters::Unknown;
}

static bool CompletionTakesArguments(const CompletionItem &item, Language language, bool boundReceiver)
{
    CallParameters parameters = CompletionParameters(item, language);
    return parameters != CallParameters::None && (parameters != CallParameters::Receiver || !boundReceiver);
}

static NSString *CompletionDisplayLabel(const CompletionItem &item, Language language, bool boundReceiver)
{
    if (item.kind != CompletionKind::Function)
        return item.label;

    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *name = [item.label stringByTrimmingCharactersInSet:whitespace];
    if (CFamily(language) && [name hasPrefix:@"operator"] && (name.length == 8 || !IsASCIIIdentifierPart([name characterAtIndex:8])))
        return name;
    if ([name containsString:@"("]) {
        NSUInteger opening = NSNotFound;
        ParametersInSignature(name, language, &opening);
        if (opening == NSNotFound || opening == 0)
            return name;
        name = [[name substringToIndex:opening] stringByTrimmingCharactersInSet:whitespace];
    }

    boundReceiver |= language == Language::Rust && [item.text hasPrefix:@"self."];
    return [name stringByAppendingString:CompletionTakesArguments(item, language, boundReceiver) ? @"(...)" : @"()"];
}

static bool SameCompletionLabel(const CompletionItem &a, const CompletionItem &b)
{
    if (a.kind != b.kind || ![a.label isEqualToString:b.label])
        return false;
    if (a.kind != CompletionKind::Function)
        return true;

    return (a.detail == b.detail || [a.detail isEqualToString:b.detail]) &&
           (a.labelDetail == b.labelDetail || [a.labelDetail isEqualToString:b.labelDetail]) &&
           [a.text hasPrefix:@"self."] == [b.text hasPrefix:@"self."];
}

static bool CallHasReceiver(NSString *source, NSUInteger before)
{
    while (before) {
        unichar previous = [source characterAtIndex:before - 1];
        if (previous != ' ' && previous != '\t')
            return previous == '.';
        --before;
    }
    return false;
}

static NSUInteger SkipCallSpaces(NSString *source, NSUInteger offset, bool acrossLines = false)
{
    while (offset < source.length) {
        unichar character = [source characterAtIndex:offset];
        if (character != ' ' && character != '\t' && !(acrossLines && (character == '\r' || character == '\n')))
            break;
        ++offset;
    }
    return offset;
}

static bool ImportStatementAt(NSString *source, NSUInteger offset, Language language)
{
    NSUInteger start;
    [source getLineStart:&start end:nullptr contentsEnd:nullptr forRange:NSMakeRange(offset, 0)];
    start = SkipCallSpaces(source, start);
    NSUInteger end = start;
    while (end < offset && WordCharacterAt(source, end))
        ++end;
    if (end == start || end == offset)
        return false;
    NSRange word = NSMakeRange(start, end - start);
    if ((CFamily(language) || language == Language::CSharp) &&
        [source compare:@"using" options:NSLiteralSearch range:word] == NSOrderedSame)
        return true;
    if (language == Language::Python && [source compare:@"from" options:NSLiteralSearch range:word] == NSOrderedSame)
        return true;
    if ([source compare:@"import" options:NSLiteralSearch range:word] != NSOrderedSame)
        return false;
    NSUInteger next = SkipCallSpaces(source, end);
    return next == source.length || [source characterAtIndex:next] != '(';
}

static NSUInteger CallTypeArgumentsEnd(NSString *source, NSUInteger offset, Language language)
{
    NSUInteger start = offset;
    unichar open = '<', close = '>';
    switch (language) {
    case Language::Rust:
        if (source.length - start < 3 || [source compare:@"::<" options:NSLiteralSearch range:NSMakeRange(start, 3)] != NSOrderedSame)
            return offset;
        start += 2;
        break;

    case Language::Go:
        open = '[';
        close = ']';
        break;

    case Language::Cpp: case Language::ObjectiveCpp: case Language::TypeScript: case Language::TSX:
    case Language::CSharp: case Language::Kotlin: case Language::Dart: case Language::Swift:
        break;

    default:
        return offset;
    }

    if (start >= source.length || [source characterAtIndex:start] != open)
        return offset;

    unsigned depth = 1;
    for (NSUInteger end = start + 1; end < source.length; ++end) {
        unichar character = [source characterAtIndex:end];
        if (character == '\n' || character == '\r' || character == ';')
            break;

        if (character == open) {
            ++depth;
        } else if (character == close && (close != '>' || [source characterAtIndex:end - 1] != '-')) {
            if (--depth == 0)
                return end + 1;
        }
    }

    return offset;
}

static NSUInteger LastCallOpening(std::u16string_view text)
{
    unsigned depth = 0;
    for (size_t i = text.size(); i > 0; --i) {
        if (text[i - 1] == u')')
            ++depth;
        else if (text[i - 1] == u'(' && depth && --depth == 0)
            return i - 1;
    }
    return NSNotFound;
}

static NSUInteger CallOpeningAt(NSAttributedString *storage, NSUInteger caret, Language language)
{
    NSString *text = storage.string;
    NSUInteger start = caret - std::min(caret, NSUInteger(4096));
    NSUInteger depth = 0;
    bool lisp = LispSymbols(language);
    while (caret > start) {
        NSRange bracket = NextCodeBracket(storage, NSMakeRange(start, caret - start), true);
        if (bracket.location == NSNotFound)
            break;

        caret = bracket.location;
        unichar ch = [text characterAtIndex:caret];
        if (ch == ')' || ch == ']' || ch == '}') {
            ++depth;
        } else if (depth) {
            --depth;
        } else if (ch == '(') {
            if (lisp)
                return caret;

            NSUInteger name = caret;
            while (name && [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[text characterAtIndex:name - 1]])
                --name;
            if (!name)
                continue;

            unichar tail = [text characterAtIndex:name - 1];
            if (tail == ')' || tail == ']' || tail == '>' || (tail == '!' && language == Language::Rust) ||
                (tail == '.' && name > 1 && [text characterAtIndex:name - 2] == '?') || WordCharacterAt(text, name - 1))
                return caret;
        }
    }
    return NSNotFound;
}

static NSUInteger ActiveSignatureIndex(NSDictionary *response, NSUInteger count)
{
    NSUInteger index = LSPNumber(response[@"activeSignature"]).unsignedIntegerValue;
    return index < count ? index : 0;
}

static SignatureLabel ReadSignatureLabel(NSDictionary *response, NSArray *signatures, NSUInteger choice, Language language, id *documentation)
{
    NSUInteger activeSignature = ActiveSignatureIndex(response, signatures.count);
    NSUInteger selected = choice < signatures.count ? choice : activeSignature;
    NSDictionary *entry = LSPDict(signatures[selected]);
    SignatureLabel signature{.text = LSPString(entry[@"label"]), .index = selected, .count = signatures.count};
    *documentation = entry[@"documentation"];
    NSArray *parameters = LSPArray(entry[@"parameters"]);
    id index = entry[@"activeParameter"];
    if (!index)
        index = response[@"activeParameter"];
    NSUInteger active = LSPNumber(index).unsignedIntegerValue;
    if (active >= parameters.count)
        active = selected == activeSignature ? 0 : NSNotFound;
    if (index == NSNull.null)
        active = NSNotFound;

    NSUInteger search = 0, opening = NSNotFound;
    NSUInteger length = signature.text.length;
    for (NSUInteger i = 0; i < parameters.count; ++i) {
        NSDictionary *parameter = LSPDict(parameters[i]);
        id label = parameter[@"label"];
        NSRange range = {};
        if (NSArray *offsets = LSPArray(label); offsets.count == 2) {
            NSNumber *first = LSPNumber(offsets[0]), *end = LSPNumber(offsets[1]);
            NSUInteger a = first.unsignedIntegerValue, b = end.unsignedIntegerValue;
            if (first && end && a < b && b <= length)
                range = NSMakeRange(a, b - a);
        } else if (NSString *name = LSPString(label); name.length) {
            if (!search) {
                ParametersInSignature(signature.text, language, &opening);
                if (opening != NSNotFound)
                    search = opening + 1;
            }
            NSRange match = [signature.text rangeOfString:name options:NSLiteralSearch range:NSMakeRange(search, length - search)];
            if (match.location != NSNotFound)
                range = match;
        }
        if (range.length) {
            search = std::max(search, NSMaxRange(range));
            signature.parameters = signature.parameters.length ? NSUnionRange(signature.parameters, range) : range;
            if (i == active)
                signature.active = range;
        }
        if (i == active && parameter[@"documentation"])
            *documentation = parameter[@"documentation"];
    }
    return signature;
}

struct PopupSpace {
    CGFloat top, bottom, above, below;
};

static PopupSpace SpaceForPopup(NSRect visible, NSRect anchor, CGFloat gap, NSRect other, CGFloat minimum)
{
    CGFloat top = NSMinY(anchor) - gap;
    CGFloat bottom = NSMaxY(anchor) + gap;
    CGFloat first = NSMinY(visible), last = NSMaxY(visible);
    if (!NSIsEmptyRect(other)) {
        if (NSMinY(other) < top) {
            CGFloat past = NSMaxY(other) + gap;
            if (top - past >= minimum)
                first = std::max(first, past);
            else
                top = NSMinY(other) - gap;
        }
        if (NSMaxY(other) > bottom) {
            CGFloat before = NSMinY(other) - gap;
            if (before - bottom >= minimum)
                last = std::min(last, before);
            else
                bottom = NSMaxY(other) + gap;
        }
    }
    return {top, bottom, std::max(0.0, top - first), std::max(0.0, last - bottom)};
}

struct SignatureSession {
    NSTimer *timer = nil;
    NSDictionary *overloads = nil;
    NSUInteger opening = NSNotFound;
    NSUInteger offset = NSNotFound;
    NSUInteger version = 0;
    NSUInteger dismissed = NSNotFound;
    NSUInteger choice = NSNotFound;
    bool manual = false;
};

static CompletionKind CompletionKindForLSP(NSInteger kind)
{
    switch (kind) {
        case 2: case 3: case 4: return CompletionKind::Function;
        case 7: case 8: case 13: case 22: case 25: return CompletionKind::Type;
        case 6: return CompletionKind::Variable;
        case 5: case 10: return CompletionKind::Field;
        case 9: return CompletionKind::Module;
        case 14: return CompletionKind::Keyword;
        case 12: case 20: case 21: return CompletionKind::Value;
        default: return CompletionKind::Word;
    }
}

enum class LanguageCommand { Definition, References, Hover, Signature, Rename, Format, CodeActions, Symbols, Completion, QuickFix };

struct LanguageFeature {
    NSString *title;
    NSString *capability;
    NSString *method;
};

static const LanguageFeature languageFeatures[] = {
    {@"Go to Definition", @"definitionProvider", @"textDocument/definition"},
    {@"Find References", @"referencesProvider", @"textDocument/references"},
    {@"Show Documentation", @"hoverProvider", @"textDocument/hover"},
    {@"Show Signature", @"signatureHelpProvider", @"textDocument/signatureHelp"},
    {@"Rename Symbol…", @"renameProvider", @"textDocument/rename"},
    {@"Format Document", @"documentFormattingProvider", @"textDocument/formatting"},
    {@"Code Actions…", @"codeActionProvider", @"textDocument/codeAction"},
    {@"Go to Symbol…", @"documentSymbolProvider", @"textDocument/documentSymbol"},
    {@"Show Completions", @"completionProvider", @"textDocument/completion"},
    {@"Quick Fix…", @"codeActionProvider", @"textDocument/codeAction"},
};

static bool SupportsLanguageFeature(LSPDocument *document, LanguageCommand command)
{
    return [document supports:languageFeatures[size_t(command)].capability] ||
           (command == LanguageCommand::Format && [document supports:@"documentRangeFormattingProvider"]);
}

static NSDictionary *LanguageActionParams(SyntaxBuffer *buffer, NSRange selection, BOOL quickFix, BOOL automatic)
{
    LSPDocument *document = buffer.languageDocument;
    LSPPosition start = [buffer languagePosition:selection.location];
    LSPPosition end = [buffer languagePosition:NSMaxRange(selection)];
    LSPPosition requestStart = start;
    auto before = [](LSPPosition a, LSPPosition b) {
        return a.line < b.line || (a.line == b.line && a.character < b.character);
    };
    NSMutableArray *diagnostics = [NSMutableArray array];
    for (NSDictionary *diagnostic in document.diagnostics) {
        NSDictionary *range = LSPDict(diagnostic[@"range"]);
        auto first = LSPReadPosition(range[@"start"]), last = LSPReadPosition(range[@"end"]);
        if (!first || !last || before(*last, start) || before(end, *first))
            continue;
        [diagnostics addObject:diagnostic];
        // A caret immediately after a diagnostic still belongs to that diagnostic.
        if (quickFix && !selection.length && !before(start, *last) && before(*first, requestStart))
            requestStart = *first;
    }
    NSMutableDictionary *context = [@{@"diagnostics":diagnostics, @"triggerKind":@(automatic ? 2 : 1)} mutableCopy];
    if (quickFix)
        context[@"only"] = @[@"quickfix"];
    return @{@"textDocument":@{@"uri":document.file.absoluteString}, @"context":context,
             @"range":@{@"start":LSPPositionValue(requestStart), @"end":LSPPositionValue(end)}};
}

static NSDictionary *LanguageActionCommand(NSDictionary *action)
{
    return LSPString(action[@"command"]).length ? action : LSPDict(action[@"command"]);
}

static NSArray<NSDictionary *> *UsableLanguageActions(id result, LSPDocument *document, BOOL quickFix)
{
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    BOOL resolves = document.resolvesCodeActions;
    for (id value in LSPArray(result)) {
        NSDictionary *action = LSPDict(value);
        if (!LSPString(action[@"title"]).length || LSPDict(action[@"disabled"]))
            continue;
        NSString *kind = LSPString(action[@"kind"]);
        if (quickFix && kind.length && ![kind isEqualToString:@"quickfix"] && ![kind hasPrefix:@"quickfix."])
            continue;
        if (!resolves && !LSPDict(action[@"edit"]) && !LSPString(LanguageActionCommand(action)[@"command"]).length)
            continue;
        [actions addObject:action];
        if (actions.count == 80)
            break;
    }
    return actions;
}

static bool DefinitionModifier(NSEventModifierFlags flags)
{
    constexpr NSEventModifierFlags modifiers = NSEventModifierFlagCommand | NSEventModifierFlagOption |
        NSEventModifierFlagShift | NSEventModifierFlagControl;
    return (flags & modifiers) == NSEventModifierFlagCommand;
}

static id LocationURI(NSDictionary *location)
{
    return location[@"targetUri"] ? location[@"targetUri"] : location[@"uri"];
}

static id LocationRange(NSDictionary *location)
{
    return location[@"targetSelectionRange"] ? location[@"targetSelectionRange"] : location[@"range"];
}

static bool HasDefinitionLocation(id result)
{
    NSArray *locations = LSPArray(result);
    if (!locations && LSPDict(result))
        locations = @[result];
    for (id item in locations) {
        NSDictionary *location = LSPDict(item);
        NSString *uri = LSPString(LocationURI(location));
        if (uri.length && [NSURL URLWithString:uri].isFileURL && LSPReadPosition(LSPDict(LocationRange(location))[@"start"]))
            return true;
    }
    return false;
}

static NSMenuItem *MakeLanguageCommand(LanguageCommand command)
{
    const LanguageFeature &feature = languageFeatures[size_t(command)];
    unichar key = 0;
    NSEventModifierFlags modifiers = 0;
    if (command == LanguageCommand::Definition || command == LanguageCommand::References) {
        key = NSF12FunctionKey;
        modifiers = command == LanguageCommand::References ? NSEventModifierFlagShift : 0;
    } else if (command == LanguageCommand::Rename) {
        key = NSF2FunctionKey;
    } else if (command == LanguageCommand::Signature) {
        key = ' ';
        modifiers = NSEventModifierFlagControl | NSEventModifierFlagShift;
    } else if (command == LanguageCommand::QuickFix) {
        key = '.';
        modifiers = NSEventModifierFlagCommand;
    }
    NSString *equivalent = key ? [NSString stringWithCharacters:&key length:1] : @"";
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:feature.title action:@selector(languageCommand:) keyEquivalent:equivalent];
    item.keyEquivalentModifierMask = modifiers;
    item.tag = NSInteger(command);
    return item;
}

NSArray<NSMenuItem *> *LanguageFeatureCommands()
{
    NSMutableArray<NSMenuItem *> *commands = [NSMutableArray arrayWithCapacity:std::size(languageFeatures)];
    for (size_t index = 0; index < std::size(languageFeatures); ++index)
        [commands addObject:MakeLanguageCommand(LanguageCommand(index))];
    return commands;
}

@interface CompletionList : NSView
@property(nonatomic) NSUInteger selectedRow;
@property(nonatomic, copy) void (^accept)(void);
- (const std::vector<CompletionItem> &)items;
- (NSSize)setItems:(std::span<const CompletionItem>)items theme:(const ThemeRef &)theme font:(NSFont *)font rowHeight:(CGFloat)height
          language:(Language)language boundReceiver:(BOOL)boundReceiver;
- (void)clear;
@end

@implementation CompletionList {
    ThemeRef _theme;
    PopupColors _colors;
    NSTextFieldCell *_label;
    NSTextFieldCell *_kind;
    std::vector<CompletionItem> _items;
    std::array<NSString *, completionLimit> _displayLabels;
    NSDictionary *_labelAttributes;
    NSSize _itemsSize;
    CGFloat _rowHeight;
    Language _language;
    BOOL _boundReceiver;
    BOOL _showsKinds;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _label = [[NSTextFieldCell alloc] initTextCell:@""];
        _label.drawsBackground = NO;
        _label.bordered = NO;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _kind = [[NSTextFieldCell alloc] initTextCell:@""];
        _kind.font = [NSFont boldSystemFontOfSize:10];
        _kind.alignment = NSTextAlignmentCenter;
        _kind.drawsBackground = NO;
        _kind.bordered = NO;
        self.accessibilityLabel = @"Completions";
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (const std::vector<CompletionItem> &)items { return _items; }

- (void)clear
{
    self.hidden = YES;
    _items.clear();
    _displayLabels.fill(nil);
}

- (NSSize)setItems:(std::span<const CompletionItem>)items theme:(const ThemeRef &)theme font:(NSFont *)font rowHeight:(CGFloat)height
          language:(Language)language boundReceiver:(BOOL)boundReceiver
{
    bool themeChanged = _theme != theme || _items.empty();
    bool fontChanged = !_labelAttributes || ![_label.font isEqual:font];
    bool sameLabels = !themeChanged && !fontChanged && _language == language && _boundReceiver == boundReceiver &&
        _rowHeight == height && std::equal(items.begin(), items.end(), _items.begin(), _items.end(), SameCompletionLabel);
    NSString *selected = !self.hidden && _selectedRow < _items.size() ? _items[_selectedRow].label : nil;
    _items.assign(items.begin(), items.end());
    if (sameLabels)
        return _itemsSize;

    if (themeChanged) {
        _theme = theme;
        _colors = EditorPopupColors(*theme);
    }
    if (fontChanged) {
        _label.font = font;
        _labelAttributes = @{NSFontAttributeName:font};
    }
    _language = language;
    _boundReceiver = boundReceiver;
    _rowHeight = height;
    auto row = std::find_if(_items.begin(), _items.end(), [&](const CompletionItem &item) {
        return [item.label isEqualToString:selected];
    });
    _selectedRow = row == _items.end() ? 0 : NSUInteger(row - _items.begin());
    _showsKinds = std::any_of(_items.begin(), _items.end(), [](const CompletionItem &item) {
        return item.kind != CompletionKind::Word;
    });
    CGFloat width = 140;
    CGFloat padding = 18 + (_showsKinds ? completionKindWidth : 0);
    for (NSUInteger i = 0; i < _displayLabels.size(); ++i) {
        NSString *label = i < _items.size() ? CompletionDisplayLabel(_items[i], language, boundReceiver) : nil;
        _displayLabels[i] = label;
        if (label)
            width = std::max(width, std::ceil([label sizeWithAttributes:_labelAttributes].width) + padding);
    }
    _itemsSize = NSMakeSize(std::min(width, 300.0), _items.size() * height + 2 * completionInset);
    self.needsDisplay = YES;
    return _itemsSize;
}

- (void)setSelectedRow:(NSUInteger)row
{
    if (_selectedRow != row) {
        for (NSUInteger changed : {_selectedRow, row})
            [self setNeedsDisplayInRect:NSMakeRect(0, completionInset + changed * _rowHeight,
                                                 NSWidth(self.bounds), _rowHeight)];
    }
    _selectedRow = row;
}

- (void)drawRect:(NSRect)dirty
{
    DrawPopupFrame(self.bounds, dirty, _colors.paper, _colors.border);
    NSColor *text = SRGBColor(_colors.text);
    NSColor *selectedText = SRGBColor(_colors.selectedText);
    static NSString *const symbols[] = {nil, @"ƒ", @"T", @"x", @"▪", @"▣", @"K", @"#"};
    static constexpr Ink inks[] = {Ink::Text, Ink::Function, Ink::Type, Ink::Name, Ink::Name,
                                   Ink::Type, Ink::Keyword, Ink::Constant};
    for (NSUInteger i = 0; i < _items.size(); ++i) {
        NSRect row = NSMakeRect(completionInset, completionInset + i * _rowHeight,
                                NSWidth(self.bounds) - 2 * completionInset, _rowHeight);
        if (!NSIntersectsRect(dirty, row))
            continue;
        bool selected = i == _selectedRow;
        if (selected) {
            [SRGBColor(_colors.selection) setFill];
            NSRectFill(row);
        }

        size_t kind = size_t(_items[i].kind);
        if (symbols[kind]) {
            Col32 ink = selected ? _colors.selectedText : _colors.text;
            _kind.stringValue = symbols[kind];
            _kind.textColor = SRGBColor(BlendColor(ink, _theme->ink[size_t(inks[kind])], 38));
            NSRect mark = NSMakeRect(NSMaxX(row) - completionKindWidth - 3, NSMinY(row), completionKindWidth, NSHeight(row));
            [_kind drawInteriorWithFrame:mark inView:self];
        }
        NSRect label = NSInsetRect(row, 5, 0);
        if (_showsKinds)
            label.size.width -= completionKindWidth;
        _label.stringValue = _displayLabels[i];
        _label.textColor = selected ? selectedText : text;
        [_label drawInteriorWithFrame:label inView:self];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    CGFloat y = [self convertPoint:event.locationInWindow fromView:nil].y - completionInset;
    if (y >= 0 && y < _items.size() * _rowHeight) {
        self.selectedRow = NSUInteger(y / _rowHeight);
        if (self.accept)
            self.accept();
    }
}

@end

@implementation CodeView {
    BOOL _preparingViewport;
    BOOL _fittingDocument;
    ThemeRef _palette;
    NSFont *_editorFont;
    NSUInteger _fontTabStop;
    CGFloat _minimumLineHeight;
    std::optional<TypingEdit> _vimTypingEdit;
    BOOL _pasting;
    BracketMatch _brackets;
    NSRange _bracketSelection;
    NSUInteger _bracketVersion;
    bool _bracketUnderCursor;
    NSTimeInterval _bracketFlashStart;
    NSTimer *_bracketTimer;
    CompletionList *_completion;
    NSRange _completionPrefix;
    NSUInteger _completionVersion;
    BOOL _completionActive;
    BOOL _editingCompletionPrefix;
    BOOL _completionIncomplete;
    BOOL _completionTriggered;
    std::vector<CompletionItem> _serverCompletions;
    NSTimer *_languageCompletionTimer;
    __weak LSPDocument *_completionDocument;
    NSInteger _languageCompletionRequest;
    NSUInteger _completionGeneration;
    NSTrackingArea *_languageTracking;
    NSTimer *_languageHoverTimer;
    NSTimer *_hoverLeaveTimer;
    EditorHover *_languageInformation;
    SignatureSession _signature;
    std::optional<BuildError> _hoveredError;
    NSArray<NSDictionary *> *_hoverQuickFixes;
    BOOL _commandHover;
    NSRange _languageHoverRange;
    NSRect _languageHoverHighlight;
    NSUInteger _languageInformationGeneration;
    NSInteger _languageInformationRequest;
    NSInteger _definitionRequest;
    __weak LSPDocument *_informationDocument;
    NSUInteger _languageActionsGeneration;
    NSRange _wordSelection;
    NSString *_selectedWord;
    NSUInteger _wordVersion;
}

- (NSUInteger)vimDocumentLineCount { return self.syntax.lineCount; }
- (NSUInteger)vimLineAtOffset:(NSUInteger)offset { return [self.syntax lineForOffset:offset]; }
- (NSUInteger)vimOffsetAtLine:(NSUInteger)line { return [self.syntax offsetForLine:line]; }
- (BOOL)vimStructuralCharacterAtOffset:(NSUInteger)offset { return [self.syntax codeAtOffset:offset]; }

- (CommentSyntax)commentsAtOffset:(NSUInteger)offset
{
    const Language language = self.syntax.language;
    if (CommentContextDependsOnLexer(language))
        return CommentsInContext(language, [self.syntax contextAtOffset:offset]);
    return InfoForLanguage(language).comments;
}

- (Vim::Comments)vimComments
{
    const auto comments = [self commentsAtOffset:std::min(self.selectedRange.location, self.string.length)];
    return {comments.line, comments.open, comments.close};
}

- (BOOL)canToggleLineComment
{
    const auto &comments = InfoForLanguage(self.syntax.language).comments;
    return self.editable && !self.hasMarkedText && !self.vimCommandLine &&
           (!comments.line.empty() || !comments.open.empty());
}

- (IBAction)toggleLineComment:(id)sender
{
    (void)sender;
    if (![self canToggleLineComment])
        return;

    NSString *text = self.string;
    auto ranges = CommentLineRanges(text, [self editingSelections]);
    auto indentation = self.syntax.indentation;
    std::vector<Vim::CursorEdit> edits;
    for (auto range : ranges)
        AppendLineCommentEdits(text, range, [self commentsAtOffset:range.first], indentation, edits);
    if (edits.empty())
        return;
    [self dismissCompletion];
    [self applyDocumentEdits:Vim::EditBatch(std::move(edits)) undoName:@"Toggle Line Comment"
                    options:{.insertionAdvance = CommentInsertionAdvance}];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(toggleLineComment:))
        return [self canToggleLineComment];
    return [super validateMenuItem:item];
}

- (void)configureVimState:(Vim::State &)state
{
    Indentation indentation = self.syntax.indentation;
    state.expandTab = !indentation.tabs;
    state.tabStop = unsigned(indentation.tabWidth);
    state.shiftWidth = unsigned(indentation.width);
}

static bool IdentifierAt(NSString *text, NSUInteger offset)
{
    return offset < text.length && IsASCIIIdentifierPart([text characterAtIndex:offset]);
}

- (NSUInteger)vimDefinitionAt:(NSUInteger)position
{
    NSString *text = self.string;
    if (!IdentifierAt(text, position) || ![self.syntax codeAtOffset:position])
        return Vim::NoOffset;
    NSUInteger first = position, last = position + 1;
    while (first && IdentifierAt(text, first - 1))
        --first;
    while (IdentifierAt(text, last))
        ++last;
    NSString *name = [text substringWithRange:NSMakeRange(first, last - first)];
    NSCharacterSet *spaces = NSCharacterSet.whitespaceCharacterSet;
    NSUInteger best = Vim::NoOffset;
    NSUInteger distance = NSUIntegerMax;
    Language language = self.syntax.language;
    for (NSUInteger scan = 0; scan < text.length;) {
        NSRange hit = [text rangeOfString:name options:NSLiteralSearch range:NSMakeRange(scan, text.length - scan)];
        if (hit.location == NSNotFound)
            break;
        if (hit.location >= first && hit.location - first >= distance)
            break;
        scan = NSMaxRange(hit);
        if ((hit.location && IdentifierAt(text, hit.location - 1)) || IdentifierAt(text, scan) ||
            ![self.syntax codeAtOffset:hit.location])
            continue;

        NSUInteger wordEnd = hit.location;
        while (wordEnd && ([spaces characterIsMember:[text characterAtIndex:wordEnd - 1]] ||
               (CFamily(language) &&
                ([text characterAtIndex:wordEnd - 1] == '*' || [text characterAtIndex:wordEnd - 1] == '&'))))
            --wordEnd;
        NSUInteger wordStart = wordEnd;
        while (wordStart && IdentifierAt(text, wordStart - 1))
            --wordStart;
        NSString *previous = [text substringWithRange:NSMakeRange(wordStart, wordEnd - wordStart)];
        bool declaration = [previous isEqualToString:@"class"] || [previous isEqualToString:@"struct"] ||
                           [previous isEqualToString:@"enum"];
        if (JavaScriptFamily(language)) {
            declaration |= [@[@"function", @"const", @"let", @"var", @"type", @"interface", @"namespace"]
                            containsObject:previous];
        } else if (language == Language::Python) {
            declaration |= [previous isEqualToString:@"def"];
        } else if (language == Language::Rust) {
            declaration |= [@[@"fn", @"trait", @"let", @"mut", @"const", @"static", @"mod", @"type"]
                            containsObject:previous];
        } else if (CFamily(language)) {
            declaration |= [@[@"using", @"namespace", @"union", @"void", @"bool", @"char", @"short", @"int",
                              @"long", @"signed", @"unsigned", @"float", @"double", @"auto", @"size_t"]
                            containsObject:previous] || [previous hasSuffix:@"_t"];
        } else {
            declaration |= [@[@"actor", @"def", @"defn", @"defp", @"func", @"fun", @"fn", @"function", @"interface",
                              @"let", @"local", @"module", @"protocol", @"record", @"sub", @"trait", @"type",
                              @"typealias", @"val", @"var"] containsObject:previous];
        }
        if (language == Language::Python || language == Language::Plain) {
            NSUInteger row = [self.syntax lineForOffset:hit.location];
            NSUInteger indent = [self.syntax offsetForLine:row];
            while (indent < hit.location && [spaces characterIsMember:[text characterAtIndex:indent]])
                ++indent;
            NSUInteger after = scan;
            while (after < text.length && [spaces characterIsMember:[text characterAtIndex:after]])
                ++after;
            if (indent == hit.location && after < text.length) {
                unichar next = [text characterAtIndex:after];
                declaration |= next == ':' || (next == '=' && (after + 1 == text.length ||
                                                       [text characterAtIndex:after + 1] != '='));
            }
        }
        NSUInteger delta = first > hit.location ? first - hit.location : hit.location - first;
        if (declaration && delta < distance) {
            best = hit.location;
            distance = delta;
        }
    }
    return best;
}

- (std::vector<EditorFold>)foldRegions
{
    NSString *text = self.string;
    std::vector<EditorFold> folds;
    if (self.syntax.language == Language::Python) {
        struct Suite { NSUInteger row; NSUInteger indent; };
        std::vector<Suite> suites;
        NSUInteger rows = self.syntax.lineCount;
        auto finish = [&](Suite suite, NSUInteger end) {
            NSUInteger first = [self.syntax offsetForLine:suite.row + 1];
            if (end > first)
                folds.push_back({[self.syntax offsetForLine:suite.row], NSMakeRange(first, end - first)});
        };
        for (NSUInteger row = 0; row < rows; ++row) {
            NSRange line = LineContents(text, [self.syntax offsetForLine:row]);
            NSUInteger start = line.location, end = NSMaxRange(line);
            if (start >= text.length)
                break;

            NSUInteger first = start, indent = 0;
            while (first < end) {
                unichar unit = [text characterAtIndex:first];
                if (unit == ' ')
                    ++indent;
                else if (unit == '\t')
                    indent += self.vimTabStop - indent % self.vimTabStop;
                else
                    break;
                ++first;
            }
            if (first == end || ![self.syntax codeAtOffset:first])
                continue;
            while (!suites.empty() && indent <= suites.back().indent) {
                finish(suites.back(), start);
                suites.pop_back();
            }
            while (end > first && ([text characterAtIndex:end - 1] == ' ' ||
                                   [text characterAtIndex:end - 1] == '\t' ||
                                   ![self.syntax codeAtOffset:end - 1]))
                --end;
            if (end > first && row + 1 < rows && [text characterAtIndex:end - 1] == ':')
                suites.push_back({row, indent});
        }
        while (!suites.empty()) {
            finish(suites.back(), text.length);
            suites.pop_back();
        }
    } else {
        NSCharacterSet *braces = [NSCharacterSet characterSetWithCharactersInString:@"{}"];
        std::vector<NSUInteger> opens;
        for (NSUInteger at = 0; at < text.length;) {
            NSRange found = [text rangeOfCharacterFromSet:braces options:0 range:NSMakeRange(at, text.length - at)];
            if (found.location == NSNotFound)
                break;
            at = found.location + 1;
            if (![self.syntax codeAtOffset:found.location])
                continue;
            if ([text characterAtIndex:found.location] == '{') {
                opens.push_back(found.location);
            } else if (!opens.empty()) {
                NSUInteger first = [self.syntax lineForOffset:opens.back()];
                NSUInteger last = [self.syntax lineForOffset:found.location];
                opens.pop_back();
                if (last > first + 1) {
                    NSUInteger begin = [self.syntax offsetForLine:first + 1];
                    NSUInteger end = [self.syntax offsetForLine:last];
                    folds.push_back({[self.syntax offsetForLine:first], NSMakeRange(begin, end - begin)});
                }
            }
        }
    }
    return folds;
}

- (BOOL)hasVimFolds
{
    return ![(CodeLayoutManager *)self.layoutManager editorFolds].empty();
}

- (void)displayFolds:(std::vector<EditorFold>)folds
{
    [(CodeLayoutManager *)self.layoutManager setEditorFolds:std::move(folds)];
    [self sizeToFit];
    [self dismissLanguageInformation];
    [self setNeedsDisplayInRect:self.visibleRect];
}

- (NSUInteger)vimFold:(char32_t)command at:(NSUInteger)position
{
    auto closed = [(CodeLayoutManager *)self.layoutManager editorFolds];
    if (command == 'R') {
        [self displayFolds:{}];
        return position;
    }
    if (command == 'v') {
        [self revealVimFoldAt:position];
        return position;
    }
    auto regions = [self foldRegions];
    if (command == 'M') {
        closed = std::move(regions);
    } else {
        const EditorFold *region = nullptr;
        for (const auto &candidate : regions) {
            if (candidate.header <= position && position < NSMaxRange(candidate.hidden) &&
                (!region || candidate.header > region->header ||
                 (candidate.header == region->header && candidate.hidden.length > region->hidden.length)))
                region = &candidate;
        }
        if (!region)
            return position;
        auto isClosed = [&](const EditorFold &fold) {
            return std::any_of(closed.begin(), closed.end(), [&](const EditorFold &other) {
                return NSEqualRanges(fold.hidden, other.hidden);
            });
        };
        bool open = command == 'o' || command == 'O' || ((command == 'a' || command == 'A') && isClosed(*region));
        bool recursive = command == 'A' || command == 'O' || command == 'C';
        auto inRegion = [&](const EditorFold &fold) {
            return NSEqualRanges(fold.hidden, region->hidden) || (recursive && fold.header >= region->header &&
                   NSMaxRange(fold.hidden) <= NSMaxRange(region->hidden));
        };
        if (open) {
            std::erase_if(closed, inRegion);
        } else {
            for (const auto &fold : regions) {
                if (inRegion(fold) && !isClosed(fold))
                    closed.push_back(fold);
            }
        }
    }
    for (const auto &fold : closed) {
        if (NSLocationInRange(position, fold.hidden))
            position = fold.header;
    }
    [self displayFolds:std::move(closed)];
    return position;
}

- (void)revealVimFoldAt:(NSUInteger)position
{
    auto folds = [(CodeLayoutManager *)self.layoutManager editorFolds];
    if (std::erase_if(folds, [position](const EditorFold &fold) {
            return NSLocationInRange(position, fold.hidden);
        }))
        [self displayFolds:std::move(folds)];
}

- (Vim::Range)foldedRows:(NSRange)hidden
{
    NSUInteger end = NSMaxRange(hidden);
    NSUInteger after = [self.syntax lineForOffset:end];
    if (end == self.string.length)
        after = self.syntax.lineCount;
    else if ([self.syntax offsetForLine:after] < end)
        ++after;
    return {[self.syntax lineForOffset:hidden.location], after};
}

- (NSUInteger)vimHiddenRows:(Vim::Range)visible
{
    NSUInteger count = 0;
    for (NSRange hidden : [(CodeLayoutManager *)self.layoutManager hiddenEditorRanges]) {
        auto rows = [self foldedRows:hidden];
        NSUInteger first = std::max(rows.first, visible.first);
        NSUInteger last = std::min(rows.last, visible.last);
        if (last > first)
            count += last - first;
    }
    return count;
}

- (NSUInteger)vimStepRow:(NSUInteger)row down:(BOOL)down count:(NSUInteger)count
{
    const auto &hidden = [(CodeLayoutManager *)self.layoutManager hiddenEditorRanges];
    if (down) {
        for (NSRange range : hidden) {
            auto fold = [self foldedRows:range];
            if (fold.first <= row)
                continue;
            NSUInteger steps = fold.first - 1 - row;
            if (count <= steps)
                break;
            if (fold.last >= self.syntax.lineCount)
                return fold.first - 1;
            count -= steps + 1;
            row = fold.last;
        }
        return row + count;
    }
    for (auto it = hidden.rbegin(); it != hidden.rend(); ++it) {
        auto fold = [self foldedRows:*it];
        if (fold.last > row)
            continue;
        NSUInteger steps = row - fold.last;
        if (count <= steps)
            break;
        count -= steps + 1;
        row = fold.first - 1;
    }
    return row - std::min(row, count);
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)prepareDocumentAppearance:(NSString *)text
{
    // Keep distant glyph ranges lazy for large files.
    self.layoutManager.allowsNonContiguousLayout = text.length >= largeDocumentLength;
    [self applyAppearance];
}

- (void)loadText:(NSString *)text
{
    [self.syntax forgetTypedPairs];
    [self.syntax resolveIndentation:text];
    [self prepareDocumentAppearance:text];
    NSAttributedString *content = [[NSAttributedString alloc] initWithString:text attributes:self.typingAttributes];
    [self.textStorage setAttributedString:content];
    [self.syntax finishHighlighting];
    self.selectedRange = NSMakeRange(0, 0);
}

- (BOOL)allowsCompletion
{
    return self.editable && !self.hasMarkedText && self.selectedRanges.count == 1 &&
           (!self.vimEnabled || self.vimCanComplete);
}

- (BOOL)cursorsShareCompletionPrefix:(NSRange)range
{
    if (self.cursorCount == 1)
        return YES;
    NSString *source = self.string;
    if (!range.length || NSMaxRange(range) > source.length)
        return NO;
    NSString *prefix = [source substringWithRange:range];
    bool lisp = LispSymbols(self.syntax.language);
    return [self insertionLocationsMatch:^BOOL(NSUInteger at) {
        if (at < range.length || at > source.length || (at < source.length && WordCharacterAt(source, at, lisp)))
            return NO;
        NSUInteger start = at - range.length;
        return (!start || !WordCharacterAt(source, start - 1, lisp)) && [self.syntax codeAtOffset:at - 1] &&
            [source compare:prefix options:NSLiteralSearch range:NSMakeRange(start, range.length)] == NSOrderedSame;
    }];
}

- (void)cancelCompletionRequest
{
    [_languageCompletionTimer invalidate];
    _languageCompletionTimer = nil;
    if (_languageCompletionRequest)
        [_completionDocument cancelRequest:_languageCompletionRequest];
    _languageCompletionRequest = 0;
    ++_completionGeneration;
}

- (void)dismissCompletion
{
    [self cancelCompletionRequest];
    [_completion clear];
    _serverCompletions.clear();
    _completionActive = NO;
    _completionIncomplete = NO;
    _completionTriggered = NO;
}

- (BOOL)completionAtCaret
{
    if (!_completionActive || _editingCompletionPrefix)
        return NO;
    if (_completionVersion != self.syntax.textVersion || ![self allowsCompletion] ||
        !NSEqualRanges(self.selectedRange, NSMakeRange(NSMaxRange(_completionPrefix), 0)) ||
        ![self cursorsShareCompletionPrefix:_completionPrefix]) {
        [self dismissCompletion];
        return NO;
    }
    return YES;
}

- (BOOL)validateCompletion
{
    return [self completionAtCaret] && _completion && !_completion.hidden;
}

- (void)completionViewportChanged
{
    if (!_editingCompletionPrefix)
        [self dismissCompletion];
}

- (void)dismissServerCompletion
{
    if (_completionTriggered || !_serverCompletions.empty() || _languageCompletionTimer || _languageCompletionRequest)
        [self dismissCompletion];
}

- (void)completeCall:(const CompletionItem &)item edit:(CompletionEdit &)edit
{
    Language language = self.syntax.language;
    if (LispSymbols(language))
        return;

    NSString *source = self.string;
    NSUInteger at = self.selectedRange.location;
    if (at && ![self.syntax codeAtOffset:at - 1])
        return;
    if (language == Language::Rust ? [self.syntax contextAtOffset:at].names.rustImport :
        ImportStatementAt(source, at, language))
        return;

    auto inserted = TrimSignature(edit.text);
    if (inserted.empty() || inserted.find_first_of(u"\r\n") != inserted.npos)
        return;
    if (CFamily(language) && inserted.starts_with(u"operator") &&
        (inserted.size() == 8 || !IsASCIIIdentifierPart(inserted[8])))
        return;
    NSUInteger call = inserted.back() == u')' ? LastCallOpening(inserted) : NSNotFound;
    if (call != NSNotFound)
        call += inserted.data() - edit.text.data();
    else if (!IsASCIIIdentifierPart(inserted.back()) && inserted.back() < 0x80 && inserted.back() != u'>')
        return;

    bool boundReceiver = CallHasReceiver(source, edit.range.location) || inserted.starts_with(u"self.");
    bool takesArguments = CompletionTakesArguments(item, language, boundReceiver);

    NSUInteger nameEnd = at;
    while (nameEnd < source.length && WordCharacterAt(source, nameEnd))
        ++nameEnd;
    bool acrossLines = language == Language::Rust || CFamily(language);
    NSUInteger afterName = SkipCallSpaces(source, nameEnd, acrossLines);
    NSUInteger typeEnd = CallTypeArgumentsEnd(source, afterName, language);
    NSUInteger opening = SkipCallSpaces(source, typeEnd, acrossLines);
    if (opening < source.length && [source characterAtIndex:opening] == '(') {
        // Preserve an existing argument list, including any arguments already typed.
        edit.range.length = nameEnd - edit.range.location;
        if (call != NSNotFound)
            edit.text.resize(call);
        NSUInteger closing = takesArguments ? typingNotFound :
            BracketsAtSelection(self.textStorage, NSMakeRange(opening, 1), false).mate;
        edit.existingCaret = closing == typingNotFound ? opening + 1 : closing + 1;
        return;
    }
    if (typeEnd != afterName)
        return;
    edit.range.length = std::max(nameEnd, NSMaxRange(edit.range)) - edit.range.location;
    NSUInteger afterCall = inserted.data() - edit.text.data() + inserted.size();
    if (call == NSNotFound) {
        call = afterCall;
        edit.text.insert(call, u"()");
        edit.newPair = call;
        afterCall += 2;
    } else if (call + 1 < edit.text.size() && edit.text[call + 1] == u')') {
        edit.newPair = call;
    }
    edit.caret = takesArguments ? call + 1 : afterCall;
}

- (BOOL)acceptCompletion
{
    if (![self validateCompletion])
        return NO;
    CompletionItem item = [_completion items][_completion.selectedRow];
    if (item.text) {
        NSRange range = item.replaceRange ? [self.syntax languageRange:item.replaceRange] : _completionPrefix;
        NSUInteger at = self.selectedRange.location;
        if (range.location == NSNotFound || range.location > at || NSMaxRange(range) < at) {
            [self dismissCompletion];
            return NO;
        }
        CompletionEdit edit{range, LSPText(item.text), item.text.length};
        if (item.kind == CompletionKind::Function)
            [self completeCall:item edit:edit];
        std::vector<Vim::CursorEdit> edits{{{edit.range.location, NSMaxRange(edit.range)}, std::move(edit.text)}};
        if (item.additionalEdits && !AddLSPTextEdits(item.additionalEdits,
                [&](id bounds) { return [self.syntax languageRange:bounds]; }, edits)) {
            [self dismissCompletion];
            return NO;
        }
        Vim::EditBatch batch;
        bool valid = batch.assign(std::move(edits), Vim::EditOrder::Server);
        [self dismissCompletion];
        if (!valid)
            return NO;

        NSUInteger start = batch.map(edit.range.location, false);
        NSUInteger caret = edit.existingCaret == NSNotFound ? start + edit.caret : batch.map(edit.existingCaret, false);
        if (![self applyDocumentEdits:std::move(batch) undoName:@"Complete" options:{.caretAfter = caret}])
            return NO;
        if (edit.newPair != NSNotFound) {
            NSUInteger opening = start + edit.newPair;
            TypingEdit pair{};
            pair.pair = TypedPair{{opening, 1}, {opening + 1, 1}};
            [self.syntax didType:pair];
        }
        return YES;
    }

    NSString *suffix = [item.label substringFromIndex:_completionPrefix.length];
    [self dismissCompletion];
    if (self.vimEnabled) {
        [self applyVimKey:Vim::Key::Text text:suffix];
    } else {
        [self breakUndoCoalescing];
        [super insertText:suffix replacementRange:self.selectedRange];
        [self breakUndoCoalescing];
    }
    return YES;
}

- (BOOL)presentCompletions:(std::span<const CompletionItem>)items
{
    NSScrollView *scroll = self.enclosingScrollView;
    NSView *host = scroll.superview;
    if (items.empty() || !host || !self.theme || self.window.firstResponder != self)
        return NO;

    NSRect visible = NSInsetRect(self.visibleRect, 2, 2);
    NSRect anchor = [self vimCaretAt:_completionPrefix.location];
    NSFont *font = PopupCodeFont(self.editorFont);
    CGFloat rowHeight = std::max(18.0, std::ceil(font.ascender - font.descender + 4));
    NSRect signature = _signature.opening != NSNotFound && !_languageInformation.hidden
        ? [self convertRect:_languageInformation.frame fromView:host] : NSZeroRect;
    PopupSpace space = SpaceForPopup(visible, anchor, 1, signature, rowHeight + 2 * completionInset);
    CGFloat available = std::max(space.below, space.above) - 2 * completionInset;
    if (available < rowHeight || NSWidth(visible) < 48 ||
        NSMaxY(anchor) <= NSMinY(visible) || NSMinY(anchor) >= NSMaxY(visible))
        return NO;
    NSUInteger limit = std::min(items.size(), NSUInteger(available / rowHeight));

    [self dismissPointerInformation];
    if (!_completion) {
        _completion = [[CompletionList alloc] initWithFrame:NSZeroRect];
        __weak CodeView *view = self;
        _completion.accept = ^{ [view acceptCompletion]; };
    }
    Language language = self.syntax.language;
    bool boundReceiver = language == Language::Rust && CallHasReceiver(self.string, _completionPrefix.location);
    NSSize size = [_completion setItems:items.first(limit) theme:_palette font:font rowHeight:rowHeight
                               language:language boundReceiver:boundReceiver];
    size.width = std::min(size.width, NSWidth(visible));
    CGFloat x = std::clamp(NSMinX(anchor), NSMinX(visible), NSMaxX(visible) - size.width);
    CGFloat y = space.below >= size.height ? space.bottom : space.top - size.height;
    NSRect frame = [self convertRect:NSMakeRect(x, y, size.width, size.height) toView:host];
    if (!NSEqualRects(_completion.frame, frame))
        _completion.frame = frame;
    if (_completion.superview != host)
        [host addSubview:_completion positioned:NSWindowAbove relativeTo:scroll];
    _completion.hidden = NO;
    return YES;
}

- (BOOL)presentServerCompletions:(NSString *)prefix refining:(BOOL)refining
{
    std::array<CompletionItem, completionLimit> matches;
    size_t count = 0;
    for (const auto &item : _serverCompletions) {
        // Reuse edits confined to the typed prefix while the server refreshes the list.
        if (refining && (item.replaceRange || item.additionalEdits.count))
            continue;
        if (prefix.length && [item.filter rangeOfString:prefix options:NSAnchoredSearch | NSCaseInsensitiveSearch].location == NSNotFound)
            continue;
        matches[count++] = item;
        if (count == matches.size())
            break;
    }
    return [self presentCompletions:std::span(matches).first(count)];
}

- (BOOL)presentWordCompletions:(NSString *)prefix language:(Language)language
{
    if (_completionTriggered)
        return NO;
    NSUInteger end = NSMaxRange(_completionPrefix);
    BOOL lisp = LispSymbols(language);
    if (!prefix.length || (end < self.string.length && WordCharacterAt(self.string, end, lisp)) ||
        ![self.syntax codeAtOffset:end - 1] || ![self cursorsShareCompletionPrefix:_completionPrefix])
        return NO;
    if (language == Language::HTML || language == Language::Markdown || language == Language::PHP)
        language = LanguageInContext(language, [self.syntax contextAtOffset:end]);
    std::array<std::u16string_view, completionLimit> words;
    size_t count = [self.syntax completionWords:LSPText(prefix) language:language results:words];
    std::array<CompletionItem, completionLimit> items;
    std::vector<Token> tokens;
    for (size_t i = 0; i < count; ++i) {
        std::u16string_view word = words[i];
        LexState state;
        TokenizeLine(word, language, state, tokens);
        CompletionKind kind = CompletionKind::Word;
        if (tokens.size() == 1) {
            switch (tokens.front().ink) {
                case Ink::Type: kind = CompletionKind::Type; break;
                case Ink::Keyword: case Ink::Control: kind = CompletionKind::Keyword; break;
                case Ink::Constant: kind = CompletionKind::Value; break;
                default: break;
            }
        }
        items[i].label = [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(word.data()) length:word.size()];
        items[i].kind = kind;
    }
    return [self presentCompletions:std::span(items).first(count)];
}

- (void)useLanguageCompletions:(id)result
{
    NSDictionary *list = LSPDict(result);
    NSArray *items = LSPArray(result);
    if (!items)
        items = LSPArray(list[@"items"]);
    _completionIncomplete = [LSPNumber(list[@"isIncomplete"]) boolValue];
    _serverCompletions.clear();
    _serverCompletions.reserve(std::min(completionCacheLimit, items.count));
    LSPPosition start = [self.syntax languagePosition:_completionPrefix.location];
    LSPPosition end = [self.syntax languagePosition:NSMaxRange(_completionPrefix)];
    for (id value in items) {
        NSDictionary *item = LSPDict(value);
        NSString *label = LSPString(item[@"label"]);
        if (!label.length || label.length > 256 || [LSPNumber(item[@"insertTextFormat"]) integerValue] == 2)
            continue;
        NSDictionary *edit = LSPDict(item[@"textEdit"]);
        NSString *text = LSPString(edit[@"newText"]);
        if (!text)
            text = LSPString(item[@"insertText"]);
        if (!text)
            text = label;
        if (text.length > 4096)
            continue;
        NSDictionary *bounds = LSPDict(edit[@"range"] ? edit[@"range"] : edit[@"replace"]);
        if (edit && !bounds)
            continue;
        auto first = LSPReadPosition(bounds[@"start"]), last = LSPReadPosition(bounds[@"end"]);
        if (first && last && first->line == start.line && first->character == start.character &&
            last->line == end.line && last->character == end.character)
            bounds = nil;
        NSString *filter = LSPString(item[@"filterText"]);
        NSString *order = LSPString(item[@"sortText"]);
        CompletionKind kind = CompletionKindForLSP([LSPNumber(item[@"kind"]) integerValue]);
        NSString *detail = kind == CompletionKind::Function ? LSPString(item[@"detail"]) : nil;
        NSString *labelDetail = kind == CompletionKind::Function ? LSPString(LSPDict(item[@"labelDetails"])[@"detail"]) : nil;
        _serverCompletions.push_back({label, text, filter.length ? filter : label, order.length ? order : label,
            bounds, LSPArray(item[@"additionalTextEdits"]), kind, detail.length <= 1024 ? detail : nil,
            labelDetail.length <= 1024 ? labelDetail : nil});
        if (_serverCompletions.size() == completionCacheLimit)
            break;
    }
    std::stable_sort(_serverCompletions.begin(), _serverCompletions.end(), [](const CompletionItem &a, const CompletionItem &b) {
        return [a.order compare:b.order options:NSLiteralSearch] == NSOrderedAscending;
    });
    NSString *prefix = [self.string substringWithRange:_completionPrefix];
    if (![self presentServerCompletions:prefix refining:NO] && _completion &&
        ![_completion items].empty() && [_completion items].front().text &&
        ![self presentWordCompletions:prefix language:self.syntax.language])
        [_completion clear];
}

- (void)showCompletionsWithMinimumPrefix:(NSUInteger)minimum trigger:(NSString *)trigger continuing:(BOOL)continuing
{
    if (!self.enclosingScrollView.superview || !self.theme || self.window.firstResponder != self || ![self allowsCompletion]) {
        [self dismissCompletion];
        return;
    }
    LSPDocument *document = self.syntax.languageDocument;
    BOOL languageCompletion = self.cursorCount == 1 && [document supports:@"completionProvider"];
    NSString *text = self.string;
    NSRange caret = self.selectedRange;
    NSUInteger end = caret.location;
    if (caret.length || end > text.length) {
        [self dismissCompletion];
        return;
    }
    Language language = self.syntax.language;
    bool lisp = LispSymbols(language);
    NSUInteger start = end;
    while (start && WordCharacterAt(text, start - 1, lisp))
        --start;
    NSRange range = NSMakeRange(start, end - start);
    continuing = continuing && _completionActive && range.location == _completionPrefix.location;
    if (continuing) {
        minimum = 1;
        [self cancelCompletionRequest];
    } else {
        [self dismissCompletion];
    }

    if (range.length < minimum && !(languageCompletion && (trigger || continuing || minimum == 1))) {
        [self dismissCompletion];
        return;
    }
    if (range.length) {
        unichar first = [text characterAtIndex:start];
        if (!lisp && first < 0x80 && !IsASCIIIdentifierStart(first)) {
            [self dismissCompletion];
            return;
        }
    }

    [self.syntax finishHighlighting];
    _completionPrefix = range;
    _completionVersion = self.syntax.textVersion;
    _completionActive = YES;
    _completionTriggered = languageCompletion && (trigger || _completionTriggered);
    NSString *prefix = [text substringWithRange:range];
    if (!(continuing && languageCompletion && [self presentServerCompletions:prefix refining:YES]) &&
        !(range.length >= minimum && [self presentWordCompletions:prefix language:language]))
        [_completion clear];
    if (!languageCompletion) {
        if (!_completion || _completion.hidden)
            _completionActive = NO;
        return;
    }

    NSUInteger generation = _completionGeneration;
    NSUInteger version = _completionVersion;
    BOOL retrigger = continuing && _completionIncomplete;
    __weak CodeView *view = self;
    __weak LSPDocument *openDocument = document;
    _languageCompletionTimer = [NSTimer scheduledTimerWithTimeInterval:0.025 repeats:NO block:^(NSTimer *) {
        CodeView *editor = view;
        if (!editor || editor->_completionGeneration != generation)
            return;
        editor->_languageCompletionTimer = nil;
        LSPDocument *file = openDocument;
        if (!file || editor.syntax.languageDocument != file || ![editor completionAtCaret])
            return;
        NSDictionary *context = trigger ? @{@"triggerKind":@2, @"triggerCharacter":trigger} : @{@"triggerKind":@(retrigger ? 3 : 1)};
        NSDictionary *params = @{@"textDocument":@{@"uri":file.file.absoluteString},
            @"position":LSPPositionValue([editor.syntax languagePosition:end]), @"context":context};
        editor->_completionDocument = file;
        editor->_languageCompletionRequest = [file request:@"textDocument/completion" params:params reply:^(id result, NSString *error) {
            CodeView *target = view;
            if (!target || target->_completionGeneration != generation)
                return;
            target->_languageCompletionRequest = 0;
            if (!error && target.window.firstResponder == target && target.syntax.textVersion == version &&
                [target completionAtCaret])
                [target useLanguageCompletions:result];
        }];
    }];
}

- (void)showCompletionsWithMinimumPrefix:(NSUInteger)minimum
{
    [self showCompletionsWithMinimumPrefix:minimum trigger:nil continuing:NO];
}

- (BOOL)hoverHasFocus
{
    return [_languageInformation containsResponder:self.window.firstResponder];
}

- (BOOL)hasHoveredError
{
    return _hoveredError.has_value() && _languageInformation && !_languageInformation.hidden;
}

- (void)cancelLanguageInformationRequests
{
    [_languageHoverTimer invalidate];
    _languageHoverTimer = nil;
    if (_languageInformationRequest)
        [_informationDocument cancelRequest:_languageInformationRequest];
    if (_definitionRequest)
        [_informationDocument cancelRequest:_definitionRequest];
    _languageInformationRequest = 0;
    _definitionRequest = 0;
    ++_languageInformationGeneration;
}

- (void)clearLanguageInformation
{
    [self cancelLanguageInformationRequests];
    _signature.overloads = nil;
    _signature.choice = NSNotFound;
    [_hoverLeaveTimer invalidate];
    _hoverLeaveTimer = nil;
    if (_languageHoverRange.length)
        [(CodeLayoutManager *)self.layoutManager setDefinitionLinkRange:NSMakeRange(0, 0)];
    if (!NSIsEmptyRect(_languageHoverHighlight)) {
        [self setNeedsDisplayInRect:_languageHoverHighlight];
        _languageHoverHighlight = NSZeroRect;
    }
    _languageHoverRange = NSMakeRange(0, 0);
    _hoveredError.reset();
    _hoverQuickFixes = nil;
    _commandHover = NO;
    if (self.hoverHasFocus)
        [self.window makeFirstResponder:self];
    [_languageInformation clear];
}

- (void)dismissLanguageInformation
{
    [_signature.timer invalidate];
    _signature.timer = nil;
    _signature.opening = NSNotFound;
    _signature.manual = false;
    [self clearLanguageInformation];
}

- (void)dismissPointerInformation
{
    if (_signature.opening == NSNotFound)
        [self clearLanguageInformation];
}

- (void)cancelLanguageInformation
{
    if (_signature.opening != NSNotFound)
        _signature.dismissed = _signature.opening;
    [self dismissLanguageInformation];
}

static bool PointBetweenHoverRects(NSPoint point, NSRect source, NSRect popup)
{
    if (NSIsEmptyRect(source))
        return false;
    if (NSPointInRect(point, NSInsetRect(source, -4, -3)))
        return true;
    if (NSMinY(source) > NSMinY(popup))
        std::swap(source, popup);

    CGFloat first = NSMaxY(source), last = NSMinY(popup);
    if (last <= first || point.y < first || point.y > last)
        return false;

    CGFloat t = (point.y - first) / (last - first);
    return point.x >= std::lerp(NSMinX(source), NSMinX(popup), t) - 4 &&
           point.x <= std::lerp(NSMaxX(source), NSMaxX(popup), t) + 4;
}

- (BOOL)keepsLanguageHoverAtPoint:(NSPoint)point
{
    if (!_languageInformation || _languageInformation.hidden)
        return NO;
    if (self.hoverHasFocus)
        return YES;

    NSRect popup = [self convertRect:_languageInformation.bounds fromView:_languageInformation];
    NSPoint local = [self convertPoint:point fromView:nil];
    return NSPointInRect(local, NSInsetRect(popup, -2, -2)) ||
           (_hoveredError && PointBetweenHoverRects(local, _languageHoverHighlight, popup));
}

- (void)scheduleLanguageInformationDismissal
{
    if (_signature.opening != NSNotFound)
        return;
    if (!_languageInformation || _languageInformation.hidden) {
        [self dismissPointerInformation];
        return;
    }
    if (_hoverLeaveTimer)
        return;
    __weak CodeView *view = self;
    _hoverLeaveTimer = [NSTimer scheduledTimerWithTimeInterval:0.17 repeats:NO block:^(NSTimer *) {
        CodeView *editor = view;
        if (!editor)
            return;
        editor->_hoverLeaveTimer = nil;
        NSPoint point = editor.window.mouseLocationOutsideOfEventStream;
        if (![editor keepsLanguageHoverAtPoint:point]) {
            [editor dismissPointerInformation];
            [editor updateLanguageHoverAtWindowPoint:point modifiers:NSEvent.modifierFlags];
        }
    }];
}

- (void)showLanguageInformation:(id)markup signature:(const SignatureLabel *)signature error:(const BuildError *)error
                            at:(NSUInteger)offset
{
    NSScrollView *scroll = self.enclosingScrollView;
    NSView *host = scroll.superview;
    if ((!markup && !signature && !error) || !host || !self.theme || !self.window.isKeyWindow ||
        self.window.attachedSheet || (!signature && _completion && !_completion.hidden))
        return;
    NSRect visible = NSInsetRect(self.visibleRect, 4, 4);
    NSRect anchor = [self vimCaretAt:std::min(offset, self.string.length)];
    if (NSMaxY(anchor) < NSMinY(visible) || NSMinY(anchor) > NSMaxY(visible)) {
        if (signature)
            [self dismissLanguageInformation];
        return;
    }

    NSRect suggestions = signature && _completion && !_completion.hidden
        ? [self convertRect:_completion.frame fromView:host] : NSZeroRect;
    CGFloat minimum = signature ? 28 : 54;
    PopupSpace space = SpaceForPopup(visible, anchor, 2, suggestions, minimum);
    NSSize limit = NSMakeSize(std::min(580.0, NSWidth(visible)), std::min(306.0, std::max(space.above, space.below)));
    if (limit.width < 75 || limit.height < minimum) {
        if (signature)
            [self dismissLanguageInformation];
        return;
    }
    if (!_languageInformation) {
        _languageInformation = [[EditorHover alloc] initWithFrame:NSZeroRect];
        _languageInformation.hidden = YES;
        __weak CodeView *view = self;
        _languageInformation.pointerExited = ^{ [view scheduleLanguageInformationDismissal]; };
        _languageInformation.viewError = ^{ [view viewErrorAtCursor]; };
        _languageInformation.quickFix = ^{ [view showHoveredQuickFixes]; };
        _languageInformation.cancel = ^{ [view cancelLanguageInformation]; };
    }
    NSFont *font = PopupCodeFont(self.editorFont);
    NSSize size = error
        ? [_languageInformation showMessage:error->message diagnosticLabel:error->label showsQuickFix:_hoverQuickFixes.count != 0
                                      font:font theme:*self.theme limit:limit]
        : [_languageInformation showDocumentation:markup signature:signature language:self.syntax.language
                                              font:font theme:*self.theme limit:limit];
    if (size.height == 0)
        return;

    CGFloat left = NSMinX(anchor);
    if (signature && _signature.opening <= offset) {
        NSUInteger line = [self.syntax lineForOffset:offset];
        if ([self.syntax lineForOffset:_signature.opening] == line)
            left = NSMinX([self vimCaretAt:_signature.opening]);
    }
    CGFloat x = std::clamp(left, NSMinX(visible), NSMaxX(visible) - size.width);
    bool above = size.height > space.below || (signature && size.height <= space.above);
    CGFloat y = above ? space.top - size.height : space.bottom;
    NSRect frame = [self convertRect:NSMakeRect(x, y, size.width, size.height) toView:host];
    if (!NSEqualRects(_languageInformation.frame, frame))
        _languageInformation.frame = frame;
    if (_languageInformation.superview != host)
        [host addSubview:_languageInformation positioned:NSWindowAbove relativeTo:scroll];
    _languageInformation.hidden = NO;

    NSRange span = error ? error->range : _languageHoverRange;
    if (span.length && NSMaxRange(span) <= self.string.length) {
        NSLayoutManager *layout = self.layoutManager;
        NSRange glyphs = [layout glyphRangeForCharacterRange:span actualCharacterRange:nullptr];
        NSRect rect = [layout boundingRectForGlyphRange:glyphs inTextContainer:self.textContainer];
        NSPoint origin = self.textContainerOrigin;
        _languageHoverHighlight = NSIntersectionRect(self.visibleRect, NSOffsetRect(rect, origin.x, origin.y));
        [self setNeedsDisplayInRect:_languageHoverHighlight];
    }
}

- (void)showLanguageInformation:(NSString *)message at:(NSUInteger)offset
{
    [self showLanguageInformation:@{@"kind":@"plaintext", @"value":message} signature:nullptr error:nullptr at:offset];
}

- (NSMutableDictionary *)languageParamsAt:(NSUInteger)offset
{
    LSPDocument *document = self.syntax.languageDocument;
    return [@{@"textDocument":@{@"uri":document.file.absoluteString},
              @"position":LSPPositionValue([self.syntax languagePosition:offset])} mutableCopy];
}

- (NSUInteger)signatureCaret
{
    if (!self.window.isKeyWindow || self.window.firstResponder != self || self.window.attachedSheet ||
        self.cursorCount != 1 || ![self allowsCompletion])
        return NSNotFound;

    NSRange caret = self.selectedRange;
    return !caret.length && caret.location <= self.string.length ? caret.location : NSNotFound;
}

- (void)refreshSignatureHelpAt:(NSUInteger)caret manual:(BOOL)manual
{
    _signature.offset = self.selectedRange.location;
    _signature.version = self.syntax.textVersion;
    [self.syntax finishHighlighting];
    NSUInteger opening = CallOpeningAt(self.textStorage, caret, self.syntax.language);
    if (manual) {
        _signature.dismissed = NSNotFound;
        if (opening == NSNotFound)
            opening = caret;
    } else if (opening != _signature.dismissed) {
        _signature.dismissed = NSNotFound;
    }
    if (opening == NSNotFound || opening == _signature.dismissed) {
        if (_signature.opening != NSNotFound)
            [self dismissLanguageInformation];
        return;
    }

    if (opening == _signature.opening)
        [self cancelLanguageInformationRequests];
    else
        [self clearLanguageInformation];

    _signature.opening = opening;
    _signature.manual = manual;
    [self requestSignatureHelpAt:caret retry:YES];
}

- (void)queueSignatureHelpAfter:(NSTimeInterval)delay retryAt:(NSUInteger)retryOffset
{
    __weak CodeView *view = self;
    _signature.timer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *) {
        CodeView *editor = view;
        if (!editor)
            return;

        auto &signature = editor->_signature;
        signature.timer = nil;
        if (retryOffset != NSNotFound && signature.version == editor.syntax.textVersion &&
            signature.offset == editor.selectedRange.location && editor.window.firstResponder == editor) {
            [editor requestSignatureHelpAt:retryOffset retry:NO];
        } else {
            NSUInteger at = [editor signatureCaret];
            if (at == NSNotFound)
                [editor dismissLanguageInformation];
            else
                [editor refreshSignatureHelpAt:at manual:NO];
        }
    }];
}

- (void)scheduleSignatureHelp
{
    LSPDocument *document = self.syntax.languageDocument;
    if (!document || _signature.timer)
        return;

    NSUInteger version = self.syntax.textVersion;
    if (_signature.manual && _signature.version == version && self.selectedRange.location == _signature.offset)
        return;

    NSUInteger caret = [self signatureCaret];
    if (caret == NSNotFound) {
        if (_signature.opening != NSNotFound)
            [self dismissLanguageInformation];
        _signature.offset = NSNotFound;
        return;
    }
    if ((_signature.version == version && _signature.offset == caret) || ![document supports:@"signatureHelpProvider"])
        return;

    BOOL justOpened = _signature.opening == NSNotFound && caret && [self.string characterAtIndex:caret - 1] == '(';
    [self queueSignatureHelpAfter:justOpened ? 0 : 0.04 retryAt:NSNotFound];
}

- (void)showSignatureHelp:(NSDictionary *)response at:(NSUInteger)offset
{
    NSArray *signatures = LSPArray(response[@"signatures"]);
    if (!signatures.count)
        return;

    NSUInteger choice = _signature.choice;
    if (choice != NSNotFound && response != _signature.overloads) {
        NSArray *previous = LSPArray(_signature.overloads[@"signatures"]);
        NSString *label = LSPString(LSPDict(previous[choice])[@"label"]);
        // Servers can reorder overloads as the arguments change.
        if (choice >= signatures.count || ![label isEqualToString:LSPString(LSPDict(signatures[choice])[@"label"])]) {
            choice = NSNotFound;
            for (NSUInteger i = 0; i < signatures.count; ++i) {
                if ([label isEqualToString:LSPString(LSPDict(signatures[i])[@"label"])]) {
                    choice = i;
                    break;
                }
            }
        }
    }

    id documentation = nil;
    SignatureLabel signature = ReadSignatureLabel(response, signatures, choice, self.syntax.language, &documentation);
    if (!signature.text.length)
        return;

    [self showLanguageInformation:documentation signature:&signature error:nullptr at:offset];
    if (_languageInformation && !_languageInformation.hidden) {
        _signature.overloads = signatures.count > 1 ? response : nil;
        _signature.choice = _signature.overloads ? choice : NSNotFound;
    }
}

- (void)requestSignatureHelpAt:(NSUInteger)offset retry:(BOOL)retry
{
    LSPDocument *document = self.syntax.languageDocument;
    if (![document supports:@"signatureHelpProvider"] || !self.window.isKeyWindow || self.window.attachedSheet)
        return;

    NSRange selection = self.selectedRange;
    NSUInteger version = self.syntax.textVersion;
    NSUInteger generation = _languageInformationGeneration;
    __weak CodeView *view = self;
    _informationDocument = document;
    _languageInformationRequest = [document request:@"textDocument/signatureHelp" params:[self languageParamsAt:offset]
        reply:^(id result, NSString *error) {
        CodeView *editor = view;
        if (!editor || editor->_languageInformationGeneration != generation)
            return;
        editor->_languageInformationRequest = 0;
        if (editor.syntax.languageDocument != editor->_informationDocument || editor.syntax.textVersion != version ||
            !NSEqualRanges(editor.selectedRange, selection) || editor.window.firstResponder != editor)
            return;

        if (error && retry && !editor->_signature.timer) {
            // A server can cancel while it catches up with the edit that opened the call.
            [editor queueSignatureHelpAfter:0.10 retryAt:offset];
            return;
        }
        if (!error)
            [editor showSignatureHelp:LSPDict(result) at:offset];
        if (!editor->_languageInformation || editor->_languageInformation.hidden)
            editor->_signature.opening = NSNotFound;
    }];
    if (!_languageInformationRequest && (!_languageInformation || _languageInformation.hidden))
        _signature.opening = NSNotFound;
}

- (void)requestLanguageInformation:(LanguageCommand)kind at:(NSUInteger)offset
{
    LSPDocument *document = self.syntax.languageDocument;
    const LanguageFeature &feature = languageFeatures[size_t(kind)];
    if (![document supports:feature.capability] || !self.window.isKeyWindow || self.window.attachedSheet)
        return;
    BOOL definition = kind == LanguageCommand::Definition;
    NSUInteger generation = _languageInformationGeneration;
    __weak CodeView *view = self;
    _informationDocument = document;
    NSInteger request = [document request:feature.method params:[self languageParamsAt:offset] reply:^(id result, NSString *error) {
        CodeView *editor = view;
        if (!editor || editor->_languageInformationGeneration != generation)
            return;
        if (definition) {
            editor->_definitionRequest = 0;
            if (!error && editor->_commandHover && HasDefinitionLocation(result))
                [(CodeLayoutManager *)editor.layoutManager setDefinitionLinkRange:editor->_languageHoverRange];
            return;
        }
        editor->_languageInformationRequest = 0;
        if (error)
            return;
        [editor showLanguageInformation:LSPDict(result)[@"contents"] signature:nullptr error:nullptr at:offset];
    }];
    if (definition)
        _definitionRequest = request;
    else
        _languageInformationRequest = request;
}

- (void)requestHoveredQuickFixes
{
    LSPDocument *document = self.syntax.languageDocument;
    if (!self.hasHoveredError || ![document supports:@"codeActionProvider"])
        return;
    NSUInteger generation = _languageInformationGeneration;
    _informationDocument = document;
    NSDictionary *params = LanguageActionParams(self.syntax, _hoveredError->range, YES, YES);
    __weak CodeView *view = self;
    _languageInformationRequest = [document request:@"textDocument/codeAction" params:params reply:^(id result, NSString *error) {
        CodeView *editor = view;
        if (!editor || editor->_languageInformationGeneration != generation)
            return;
        editor->_languageInformationRequest = 0;
        if (error || !editor.hasHoveredError || !editor.window.isKeyWindow)
            return;
        LSPDocument *file = editor->_informationDocument;
        if (!file || editor.syntax.languageDocument != file)
            return;
        NSArray *actions = UsableLanguageActions(result, file, YES);
        if (!actions.count)
            return;
        editor->_hoverQuickFixes = actions;
        const BuildError &mark = *editor->_hoveredError;
        [editor showLanguageInformation:nil signature:nullptr error:&mark at:mark.range.location];
    }];
}

- (void)updateLanguageTracking
{
    SyntaxBuffer *buffer = self.syntax;
    LSPDocument *document = buffer.languageDocument;
    BOOL track = self.window && buffer && (!buffer.buildErrors.empty() || !buffer.languageErrors.empty() ||
        [document supports:@"definitionProvider"] || [document supports:@"hoverProvider"]);
    if (track && !_languageTracking) {
        NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
            NSTrackingInVisibleRect | NSTrackingActiveInKeyWindow;
        _languageTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil];
        [self addTrackingArea:_languageTracking];
    } else if (!track && _languageTracking) {
        [self removeTrackingArea:_languageTracking];
        _languageTracking = nil;
        [self dismissPointerInformation];
    }
}

- (NSRange)languageWordAtWindowPoint:(NSPoint)point
{
    point = [self convertPoint:point fromView:nil];
    NSString *text = self.string;
    if (!text.length || !NSPointInRect(point, self.visibleRect))
        return NSMakeRange(0, 0);

    NSPoint origin = self.textContainerOrigin;
    NSPoint local = NSMakePoint(point.x - origin.x, point.y - origin.y);
    NSLayoutManager *layout = self.layoutManager;
    NSTextContainer *container = self.textContainer;
    NSUInteger glyph = [layout glyphIndexForPoint:local inTextContainer:container];
    if (glyph == NSNotFound || ![layout isValidGlyphIndex:glyph] ||
        !NSPointInRect(local, [layout boundingRectForGlyphRange:NSMakeRange(glyph, 1) inTextContainer:container]))
        return NSMakeRange(0, 0);

    NSUInteger offset = [layout characterIndexForGlyphAtIndex:glyph];
    if (NSLocationInRange(offset, _languageHoverRange))
        return _languageHoverRange;
    bool lisp = LispSymbols(self.syntax.language);
    if (offset >= text.length || !WordCharacterAt(text, offset, lisp))
        return NSMakeRange(0, 0);
    NSUInteger first = offset, end = offset + 1;
    while (first && WordCharacterAt(text, first - 1, lisp))
        --first;
    while (end < text.length && WordCharacterAt(text, end, lisp))
        ++end;
    return NSMakeRange(first, end - first);
}

- (void)updateLanguageHoverAtWindowPoint:(NSPoint)point modifiers:(NSEventModifierFlags)flags
{
    if (!_languageTracking)
        return;
    NSWindow *window = self.window;
    if (!window.isKeyWindow || window.attachedSheet || (_completion && !_completion.hidden)) {
        [self dismissPointerInformation];
        return;
    }
    BOOL open = _languageInformation && !_languageInformation.hidden;
    BOOL command = DefinitionModifier(flags);
    BOOL pressedCommand = command && !_commandHover;
    if (_commandHover && !command) {
        if (_definitionRequest)
            [_informationDocument cancelRequest:_definitionRequest];
        _definitionRequest = 0;
        [(CodeLayoutManager *)self.layoutManager setDefinitionLinkRange:NSMakeRange(0, 0)];
    }
    _commandHover = command;
    if (open && [self keepsLanguageHoverAtPoint:point]) {
        [_hoverLeaveTimer invalidate];
        _hoverLeaveTimer = nil;
        return;
    }
    if (open && _hoveredError) {
        [self scheduleLanguageInformationDismissal];
        return;
    }

    LSPDocument *document = self.syntax.languageDocument;
    bool signature = _signature.opening != NSNotFound;
    BOOL documentation = !signature && [document supports:@"hoverProvider"];
    BOOL definition = !signature && command && [document supports:@"definitionProvider"];
    NSRange word = documentation || definition
        ? [self languageWordAtWindowPoint:point] : NSMakeRange(0, 0);
    __block std::optional<BuildError> error;
    NSPoint local = [self convertPoint:point fromView:nil];
    if ((!word.length || !definition) && NSPointInRect(local, self.visibleRect)) {
        NSRect hit = NSMakeRect(local.x - 1, local.y - 1, 2, 2);
        [self enumerateBuildErrorsInRect:hit usingBlock:^(const BuildError &mark, NSRect) {
            if (mark.message.length && (!error || (error->warning && !mark.warning) ||
                (error->warning == mark.warning && mark.range.length <= error->range.length)))
                error = mark;
        }];
    }
    if (signature) {
        if (!error)
            return;
        [self dismissLanguageInformation];
    }
    if (!error && !word.length) {
        if (_languageHoverRange.length || _hoveredError) {
            if (_languageHoverTimer || _definitionRequest || (_languageInformationRequest && (!open || !_hoveredError)))
                [self cancelLanguageInformationRequests];
            [self scheduleLanguageInformationDismissal];
        }
        return;
    }

    [_hoverLeaveTimer invalidate];
    _hoverLeaveTimer = nil;
    if (error && _hoveredError && error->message == _hoveredError->message &&
        NSEqualRanges(error->range, _hoveredError->range) && (open || _languageHoverTimer))
        return;
    if (!error && word.length && NSEqualRanges(word, _languageHoverRange)) {
        if (pressedCommand && definition && !_languageHoverTimer)
            [self requestLanguageInformation:LanguageCommand::Definition at:word.location];
        return;
    }

    [self dismissPointerInformation];
    _commandHover = command;
    _hoveredError = error;
    if (!error)
        _languageHoverRange = word;
    __weak CodeView *view = self;
    NSTimeInterval delay = error ? 0.16 : definition ? 0.12 : 0.24;
    _languageHoverTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *) {
        CodeView *editor = view;
        if (!editor)
            return;
        editor->_languageHoverTimer = nil;
        if (editor->_hoveredError) {
            const BuildError &mark = *editor->_hoveredError;
            [editor showLanguageInformation:nil signature:nullptr error:&mark at:mark.range.location];
            [editor requestHoveredQuickFixes];
        } else {
            if (editor->_commandHover)
                [editor requestLanguageInformation:LanguageCommand::Definition at:word.location];
            if (documentation)
                [editor requestLanguageInformation:LanguageCommand::Hover at:word.location];
        }
    }];
}

- (void)updateLanguageHoverModifiers:(NSEventModifierFlags)flags atWindowPoint:(NSPoint)point
{
    if (DefinitionModifier(flags) != _commandHover)
        [self updateLanguageHoverAtWindowPoint:point modifiers:flags];
}

- (void)mouseMoved:(NSEvent *)event
{
    if (_languageTracking)
        [self updateLanguageHoverAtWindowPoint:event.locationInWindow modifiers:event.modifierFlags];
    else
        [super mouseMoved:event];
}

- (void)mouseEntered:(NSEvent *)event
{
    if (event.trackingArea == _languageTracking)
        [self updateLanguageHoverAtWindowPoint:event.locationInWindow modifiers:event.modifierFlags];
    [super mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event
{
    if (event.trackingArea == _languageTracking)
        [self scheduleLanguageInformationDismissal];
    [super mouseExited:event];
}

- (BOOL)viewErrorAtCursor
{
    const BuildError *target = self.hasHoveredError ? &*_hoveredError : nullptr;
    SyntaxBuffer *buffer = self.syntax;
    if (!target && buffer) {
        NSUInteger cursor = std::min(self.vimDisplayedCursor, self.string.length);
        NSUInteger line = [buffer offsetForLine:[buffer lineForOffset:cursor]];
        const BuildError *next = nullptr, *first = nullptr;
        auto find = [&](const std::vector<BuildError> &errors) {
            auto begin = std::lower_bound(errors.begin(), errors.end(), line,
                [](const BuildError &error, NSUInteger offset) { return error.range.location < offset; });
            for (auto it = begin; it != errors.end(); ++it) {
                if (it->range.location > cursor) {
                    if (!next || it->range.location <= next->range.location)
                        next = &*it;
                    break;
                }
                if (cursor == it->range.location || NSLocationInRange(cursor, it->range)) {
                    if (!target || (target->warning && !it->warning))
                        target = &*it;
                }
            }
            if (!errors.empty() && (!first || errors.front().range.location <= first->range.location))
                first = &errors.front();
        };
        find(buffer.buildErrors);
        find(buffer.languageErrors);
        if (!target)
            target = next ? next : first;
    }
    if (!target || !self.revealError)
        return NO;
    BuildError error = *target;
    [self dismissLanguageInformation];
    [self.window makeFirstResponder:self];
    [self visitVimFileMark:error.range.location exact:YES];
    self.revealError(error);
    return YES;
}

- (void)presentLanguageError:(NSString *)message
{
    if (message.length && self.window)
        [self.window presentError:[NSError errorWithDomain:@"RetinaCode.LanguageServer" code:1
                                                  userInfo:@{NSLocalizedDescriptionKey:message}]];
}

- (IBAction)openLanguageLocation:(NSMenuItem *)sender
{
    NSDictionary *location = LSPDict(sender.representedObject);
    NSURL *file = LSPFile(location[@"uri"]);
    auto position = LSPReadPosition(LSPDict(location[@"range"])[@"start"]);
    if (!file || !position)
        return;
    if ([file isEqual:self.syntax.languageDocument.file]) {
        NSUInteger offset = [self.syntax languageOffset:*position];
        if (offset != NSNotFound)
            [self visitDefinitionAtOffset:offset];
        return;
    }
    LSPPosition target = *position;
    __weak CodeView *view = self;
    OpenSourceTab(file, self.window, ^(NSDocument *opened, BOOL, NSError *error) {
        if ([opened isKindOfClass:SourceDocument.class])
            [(SourceDocument *)opened revealLanguagePosition:target];
        else if (error)
            [view presentLanguageError:error.localizedDescription];
    });
}

- (void)popupLanguageMenu:(NSMenu *)menu at:(NSUInteger)offset
{
    if (!menu.numberOfItems || self.window.firstResponder != self)
        return;
    NSRect anchor = [self vimCaretAt:std::min(offset, self.string.length)];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(anchor), NSMaxY(anchor)) inView:self];
}

- (void)showLanguageLocations:(id)result kind:(LanguageCommand)kind at:(NSUInteger)offset
{
    NSArray *locations = LSPArray(result);
    if (!locations)
        locations = LSPDict(result) ? @[result] : @[];
    NSMenu *menu = [[NSMenu alloc] init];
    for (id value in locations) {
        NSDictionary *location = LSPDict(value);
        id uri = LocationURI(location);
        id range = LocationRange(location);
        NSURL *file = LSPFile(uri);
        auto position = LSPReadPosition(LSPDict(range)[@"start"]);
        if (!file || !position)
            continue;
        NSString *relative = RelativeWorkspacePath(file.path, self.syntax.languageDocument.root.path);
        NSString *title = [NSString stringWithFormat:@"%@:%lu:%lu", relative ? relative : file.lastPathComponent,
                           (unsigned long)position->line + 1, (unsigned long)position->character + 1];
        NSMenuItem *item = [menu addItemWithTitle:title action:@selector(openLanguageLocation:) keyEquivalent:@""];
        item.target = self;
        item.toolTip = file.path;
        item.representedObject = @{@"uri":uri, @"range":range};
        if (menu.numberOfItems == 150)
            break;
    }
    if (kind == LanguageCommand::Definition && menu.numberOfItems == 1)
        [self openLanguageLocation:menu.itemArray.firstObject];
    else if (menu.numberOfItems)
        [self popupLanguageMenu:menu at:offset];
    else
        [self showLanguageInformation:kind == LanguageCommand::Definition ? @"No definition found." : @"No references found." at:offset];
}

- (void)addLanguageSymbols:(NSArray *)symbols toMenu:(NSMenu *)menu depth:(NSUInteger)depth
{
    if (depth == 24)
        return;
    NSString *uri = self.syntax.languageDocument.file.absoluteString;
    for (id value in symbols) {
        if (menu.numberOfItems == 150)
            return;
        NSDictionary *symbol = LSPDict(value);
        NSString *name = LSPString(symbol[@"name"]);
        NSDictionary *location = LSPDict(symbol[@"location"]);
        id range = symbol[@"selectionRange"] ? symbol[@"selectionRange"] : symbol[@"range"];
        if (!location && range)
            location = @{@"uri":uri, @"range":range};
        if (name.length && location) {
            NSMenuItem *item = [menu addItemWithTitle:name action:@selector(openLanguageLocation:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = location;
            item.indentationLevel = std::min(depth, NSUInteger(10));
        }
        [self addLanguageSymbols:LSPArray(symbol[@"children"]) toMenu:menu depth:depth + 1];
    }
}

- (void)applyResolvedLanguageAction:(NSDictionary *)action name:(NSString *)title
{
    LSPDocument *document = self.syntax.languageDocument;
    NSString *failure = nil;
    if (LSPDict(action[@"edit"]))
        failure = ApplyWorkspaceLanguageEdit(action[@"edit"], document.root, title);
    if (failure) {
        [self presentLanguageError:failure];
        return;
    }
    NSDictionary *command = LanguageActionCommand(action);
    if (NSString *name = LSPString(command[@"command"])) {
        NSMutableDictionary *params = [@{@"command":name} mutableCopy];
        if (NSArray *arguments = LSPArray(command[@"arguments"]))
            params[@"arguments"] = arguments;
        __weak CodeView *view = self;
        NSURL *root = document.root;
        [document executeCommand:params applyEdit:^NSString *(id edit) {
            return ApplyWorkspaceLanguageEdit(edit, root, title);
        } reply:^(id, NSString *error) {
            [view presentLanguageError:error];
        }];
    }
}

- (IBAction)applyLanguageAction:(NSMenuItem *)sender
{
    LSPDocument *document = self.syntax.languageDocument;
    NSDictionary *selection = LSPDict(sender.representedObject);
    NSUInteger version = [LSPNumber(selection[@"version"]) unsignedIntegerValue];
    if (document != selection[@"document"] || document.state != LSPState::Ready || self.syntax.textVersion != version)
        return;
    NSDictionary *action = LSPDict(selection[@"action"]);
    NSString *title = sender.title;
    if (!LSPDict(action[@"edit"]) && !LSPString(LanguageActionCommand(action)[@"command"]).length && document.resolvesCodeActions) {
        __weak CodeView *view = self;
        __weak LSPDocument *file = document;
        [document request:@"codeAction/resolve" params:action reply:^(id result, NSString *error) {
            CodeView *editor = view;
            if (!editor || !file || editor.syntax.languageDocument != file || editor.syntax.textVersion != version)
                return;
            if (error)
                [editor presentLanguageError:error];
            else if (NSDictionary *resolved = LSPDict(result)) {
                if (!LSPDict(resolved[@"disabled"]))
                    [editor applyResolvedLanguageAction:resolved name:title];
            }
        }];
    } else {
        [self applyResolvedLanguageAction:action name:title];
    }
}

- (void)showLanguageActions:(NSArray<NSDictionary *> *)actions at:(NSUInteger)offset
{
    LSPDocument *document = self.syntax.languageDocument;
    if (!actions.count || document.state != LSPState::Ready)
        return;
    NSNumber *version = @(self.syntax.textVersion);
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSDictionary *action in actions) {
        NSMenuItem *item = [menu addItemWithTitle:action[@"title"] action:@selector(applyLanguageAction:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{@"action":action, @"document":document, @"version":version};
    }
    [self popupLanguageMenu:menu at:offset];
}

- (void)showHoveredQuickFixes
{
    NSArray *actions = _hoverQuickFixes;
    if (!actions.count || !self.hasHoveredError || !self.window.isKeyWindow || self.window.attachedSheet)
        return;
    NSUInteger offset = _hoveredError->range.location;
    if (![self.window makeFirstResponder:self])
        return;
    ++_languageActionsGeneration;
    [self dismissLanguageInformation];
    [self showLanguageActions:actions at:offset];
}

- (void)requestLanguageActions:(NSRange)selection at:(NSUInteger)offset quickFix:(BOOL)quickFix
{
    LSPDocument *document = self.syntax.languageDocument;
    NSUInteger version = self.syntax.textVersion;
    NSUInteger generation = ++_languageActionsGeneration;
    NSRange originalSelection = self.selectedRange;
    NSUInteger caret = self.vimDisplayedCursor;
    NSDictionary *params = LanguageActionParams(self.syntax, selection, quickFix, NO);
    __weak CodeView *view = self;
    __weak LSPDocument *file = document;
    [document request:@"textDocument/codeAction" params:params reply:^(id result, NSString *error) {
        CodeView *editor = view;
        LSPDocument *open = file;
        if (!editor || !open || editor.syntax.languageDocument != open || editor.syntax.textVersion != version ||
            editor->_languageActionsGeneration != generation || editor.window.firstResponder != editor ||
            !editor.window.isKeyWindow || editor.window.attachedSheet || editor.vimDisplayedCursor != caret ||
            !NSEqualRanges(editor.selectedRange, originalSelection))
            return;
        if (error) {
            [editor presentLanguageError:error];
            return;
        }
        NSArray *actions = UsableLanguageActions(result, open, quickFix);
        [editor dismissLanguageInformation];
        if (actions.count)
            [editor showLanguageActions:actions at:offset];
        else
            [editor showLanguageInformation:quickFix ? @"No quick fixes available." : @"No code actions available." at:offset];
    }];
}

- (void)renameLanguageSymbolAt:(NSUInteger)offset
{
    LSPDocument *document = self.syntax.languageDocument;
    NSUInteger version = document.version;
    NSString *text = self.string;
    NSUInteger start = offset, end = offset;
    bool lisp = LispSymbols(self.syntax.language);
    while (start && WordCharacterAt(text, start - 1, lisp))
        --start;
    while (end < text.length && WordCharacterAt(text, end, lisp))
        ++end;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rename Symbol";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = [text substringWithRange:NSMakeRange(start, end - start)];
    field.placeholderString = @"New name";
    field.cell.scrollable = YES;
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak CodeView *view = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        CodeView *editor = view;
        if (response != NSAlertFirstButtonReturn || !editor || !field.stringValue.length ||
            editor.syntax.languageDocument != document || document.version != version)
            return;
        NSMutableDictionary *params = [editor languageParamsAt:offset];
        params[@"newName"] = field.stringValue;
        [document request:@"textDocument/rename" params:params reply:^(id result, NSString *error) {
            NSString *failure = error;
            if (!error && result)
                failure = ApplyWorkspaceLanguageEdit(result, document.root, @"Rename Symbol");
            [view presentLanguageError:failure];
        }];
    }];
    [alert.window makeFirstResponder:field];
    [field selectText:nil];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    if (item.action == @selector(languageCommand:)) {
        NSInteger tag = item.tag;
        if (tag < 0 || NSUInteger(tag) >= std::size(languageFeatures) ||
            !SupportsLanguageFeature(self.syntax.languageDocument, LanguageCommand(tag)))
            return NO;
        return LanguageCommand(tag) != LanguageCommand::Completion || ([self allowsCompletion] && self.cursorCount == 1);
    }
    return [super validateUserInterfaceItem:item];
}

- (IBAction)languageCommand:(NSMenuItem *)sender
{
    NSWindow *window = self.window;
    if (!window || window.attachedSheet || ![self validateUserInterfaceItem:sender] ||
        (window.firstResponder != self && ![window makeFirstResponder:self]))
        return;
    [self dismissLanguageInformation];
    LanguageCommand kind = LanguageCommand(sender.tag);
    if (kind == LanguageCommand::Completion) {
        [self complete:sender];
        return;
    }
    [self dismissCompletion];
    NSNumber *clicked = LSPNumber(sender.representedObject);
    NSUInteger offset = std::min(clicked ? clicked.unsignedIntegerValue : self.vimDisplayedCursor, self.string.length);
    if (kind == LanguageCommand::Signature) {
        [self refreshSignatureHelpAt:offset manual:YES];
        return;
    }
    if (kind == LanguageCommand::Hover) {
        [self requestLanguageInformation:kind at:offset];
        return;
    }
    if (kind == LanguageCommand::Rename) {
        [self renameLanguageSymbolAt:offset];
        return;
    }
    if (kind == LanguageCommand::CodeActions || kind == LanguageCommand::QuickFix) {
        NSRange selection = !clicked && self.selectedRange.length ? self.selectedRange : NSMakeRange(offset, 0);
        [self requestLanguageActions:selection at:offset quickFix:kind == LanguageCommand::QuickFix];
        return;
    }
    LSPDocument *document = self.syntax.languageDocument;
    NSMutableDictionary *params = [self languageParamsAt:offset];
    NSString *method = languageFeatures[size_t(kind)].method;
    if (kind == LanguageCommand::References) {
        params[@"context"] = @{@"includeDeclaration":@YES};
    } else if (kind == LanguageCommand::Format) {
        [params removeObjectForKey:@"position"];
        Indentation style = self.syntax.indentation;
        params[@"options"] = @{@"tabSize":@(style.tabs ? style.tabWidth : style.width), @"insertSpaces":@(!style.tabs)};
        if (![document supports:@"documentFormattingProvider"]) {
            method = @"textDocument/rangeFormatting";
            LSPPosition end = [self.syntax languagePosition:self.string.length];
            params[@"range"] = @{@"start":LSPPositionValue({}), @"end":LSPPositionValue(end)};
        }
    } else if (kind == LanguageCommand::Symbols) {
        [params removeObjectForKey:@"position"];
    }
    __weak CodeView *view = self;
    [document request:method params:params reply:^(id result, NSString *error) {
        CodeView *editor = view;
        if (!editor.window || editor.window.firstResponder != editor)
            return;
        if (error) {
            [editor presentLanguageError:error];
        } else if (kind == LanguageCommand::Definition || kind == LanguageCommand::References) {
            [editor showLanguageLocations:result kind:kind at:offset];
        } else if (kind == LanguageCommand::Symbols) {
            NSMenu *menu = [[NSMenu alloc] init];
            [editor addLanguageSymbols:LSPArray(result) toMenu:menu depth:0];
            [editor popupLanguageMenu:menu at:offset];
        } else if (result) {
            std::vector<Vim::CursorEdit> edits;
            Vim::EditBatch batch;
            if (AddLSPTextEdits(result, [&](id range) { return [editor.syntax languageRange:range]; }, edits) &&
                batch.assign(std::move(edits), Vim::EditOrder::Server)) {
                [editor applyDocumentEdits:std::move(batch) undoName:@"Format Document" options:{}];
                return;
            }
            [editor presentLanguageError:@"The formatter returned invalid edits."];
        }
    }];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSMenu *menu = [super menuForEvent:event];
    LSPDocument *document = self.syntax.languageDocument;
    if (document.state != LSPState::Ready)
        return menu;

    NSInteger index = 0;
    NSNumber *offset = nil;
    for (auto kind : {LanguageCommand::Definition, LanguageCommand::References, LanguageCommand::Rename,
                      LanguageCommand::CodeActions, LanguageCommand::Format}) {
        if (!SupportsLanguageFeature(document, kind))
            continue;

        if (!index) {
            menu = menu ? [menu copy] : [[NSMenu alloc] init];
            NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
            offset = @([self characterIndexForInsertionAtPoint:point]);
        }

        NSMenuItem *item = MakeLanguageCommand(kind);
        item.target = self;
        item.representedObject = offset;
        [menu insertItem:item atIndex:index++];
    }

    if (index && index < menu.numberOfItems && ![menu itemAtIndex:index].isSeparatorItem)
        [menu insertItem:NSMenuItem.separatorItem atIndex:index];
    return menu;
}

- (void)complete:(id)sender
{
    (void)sender;
    [self showCompletionsWithMinimumPrefix:1];
}

- (void)moveCompletionSelectionUp:(BOOL)up
{
    NSUInteger count = [_completion items].size();
    _completion.selectedRow = (_completion.selectedRow + (up ? count - 1 : 1)) % count;
}

- (BOOL)moveSignatureSelectionUp:(BOOL)up
{
    if (!_signature.overloads || _languageInformation.hidden)
        return NO;

    NSUInteger count = LSPArray(_signature.overloads[@"signatures"]).count;
    NSUInteger index = _signature.choice < count ? _signature.choice : ActiveSignatureIndex(_signature.overloads, count);
    _signature.choice = (index + (up ? count - 1 : 1)) % count;
    [self showSignatureHelp:_signature.overloads at:self.selectedRange.location];
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSWindow *window = self.window;
    if (DefinitionModifier(event.modifierFlags) && [event.charactersIgnoringModifiers isEqualToString:@"."] &&
        !window.attachedSheet && (window.firstResponder == self || self.hoverHasFocus) &&
        [self.syntax.languageDocument supports:@"codeActionProvider"]) {
        if (self.hoverHasFocus && _hoverQuickFixes.count)
            [self showHoveredQuickFixes];
        else
            [self languageCommand:MakeLanguageCommand(LanguageCommand::QuickFix)];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event
{
    NSString *keys = event.charactersIgnoringModifiers;
    unichar key = keys.length == 1 ? [keys characterAtIndex:0] : 0;
    NSEventModifierFlags modifiers = event.modifierFlags &
        (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand);
    BOOL open = [self validateCompletion];
    if (key == 27) {
        BOOL closeSuggestions = open && !modifiers;
        BOOL keepSignature = closeSuggestions && _signature.opening != NSNotFound && _languageInformation && !_languageInformation.hidden;
        if (!keepSignature)
            [self cancelLanguageInformation];
        if (closeSuggestions && (keepSignature || !self.vimEnabled)) {
            [self dismissCompletion];
            return;
        }
    } else {
        [self dismissPointerInformation];
    }

    if (!modifiers) {
        if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
            BOOL up = key == NSUpArrowFunctionKey;
            if (open) {
                [self moveCompletionSelectionUp:up];
                return;
            }
            if ([self moveSignatureSelectionUp:up])
                return;
        }

        bool accept = key == '\t' || key == '\r' || key == '\n' || key == NSEnterCharacter;
        if (open && accept && [self acceptCompletion])
            return;
    }
    if (self.vimCanComplete && modifiers == NSEventModifierFlagControl && (key == 'n' || key == 'p')) {
        if (open) {
            [self moveCompletionSelectionUp:key == 'p'];
            return;
        }
        [self showCompletionsWithMinimumPrefix:1];
        if ([self validateCompletion]) {
            if (key == 'p')
                [self moveCompletionSelectionUp:YES];
            return;
        }
    }

    BOOL backspace = !modifiers && (key == NSDeleteCharacter || key == NSBackspaceCharacter);
    NSString *typed = event.characters;
    BOOL word = !(modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
        typed.length && WordCharacterAt(typed, 0, LispSymbols(self.syntax.language));
    if (!backspace && !word)
        [self dismissCompletion];
    BOOL refine = backspace && (self.vimEnabled || self.cursorCount > 1) &&
        [self completionAtCaret] && _completionPrefix.length;
    NSUInteger version = self.syntax.textVersion;
    _editingCompletionPrefix = refine;
    [super keyDown:event];
    _editingCompletionPrefix = NO;
    if (refine && version != self.syntax.textVersion)
        [self showCompletionsWithMinimumPrefix:2 trigger:nil continuing:YES];
}

- (void)mouseDown:(NSEvent *)event
{
    [self dismissCompletion];
    [self dismissPointerInformation];
    if (DefinitionModifier(event.modifierFlags) && [self.syntax.languageDocument supports:@"definitionProvider"]) {
        NSRange word = [self languageWordAtWindowPoint:event.locationInWindow];
        if (word.length) {
            [self.window makeFirstResponder:self];
            NSMenuItem *item = MakeLanguageCommand(LanguageCommand::Definition);
            item.representedObject = @(word.location);
            [self languageCommand:item];
            return;
        }
    }
    [super mouseDown:event];
}

- (BOOL)resignFirstResponder
{
    [self dismissCompletion];
    if (_languageInformation && !_languageInformation.hidden) {
        __weak CodeView *view = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CodeView *editor = view;
            if (editor && editor.window.firstResponder != editor && !editor.hoverHasFocus)
                [editor dismissLanguageInformation];
        });
    } else {
        [self dismissLanguageInformation];
    }
    return [super resignFirstResponder];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selection replacementRange:(NSRange)replacement
{
    [self dismissCompletion];
    [self dismissLanguageInformation];
    [super setMarkedText:string selectedRange:selection replacementRange:replacement];
}

- (std::optional<TypingEdit>)planTyping:(TypingKey)key character:(unichar)character
                              selected:(NSRange)selection indentation:(const Indentation &)indentation
{
    if (!self.editable || selection.location == NSNotFound || NSMaxRange(selection) > self.string.length ||
        (key == TypingKey::Character && !MayCompleteCharacter(character)))
        return {};
    LexState context;
    if (key == TypingKey::Character || key == TypingKey::Enter)
        context = [self.syntax contextAtOffset:selection.location];
    return PlanTyping(self.textStorage, self.syntax.language, context, indentation, [self.syntax typedPairs],
                      selection, key, character);
}

- (BOOL)applyTyping:(TypingKey)key character:(unichar)character selected:(NSRange)selection
{
    if (self.vimEnabled || _pasting || self.hasMarkedText || self.cursorCount != 1 || self.selectedRanges.count != 1)
        return NO;
    auto edit = [self planTyping:key character:character selected:selection indentation:self.syntax.indentation];
    if (!edit)
        return NO;

    if (edit->text && ![[self.string substringWithRange:edit->range] isEqualToString:edit->text]) {
        NSUInteger version = self.syntax.textVersion;
        [super insertText:edit->text replacementRange:edit->range];
        if (version == self.syntax.textVersion)
            return YES;
    }
    if (NSMaxRange(edit->selection) <= self.string.length) {
        [self.syntax didType:*edit];
        self.selectedRange = edit->selection;
        [self scrollRangeToVisible:edit->selection];
    }
    return YES;
}

- (void)insertText:(id)string replacementRange:(NSRange)range
{
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    NSRange selected = range.location == NSNotFound ? self.selectedRange : range;
    BOOL singleCharacter = text.length == 1 ||
        (text.length == 2 && [text rangeOfComposedCharacterSequenceAtIndex:0].length == 2);
    bool lisp = LispSymbols(self.syntax.language);
    BOOL suggest = !_pasting && singleCharacter &&
                   WordCharacterAt(text, 0, lisp) && [self allowsCompletion];
    LSPDocument *document = self.syntax.languageDocument;
    BOOL trigger = !_pasting && singleCharacter && [document triggersCompletion:text];
    BOOL refine = suggest && !selected.length && NSEqualRanges(selected, self.selectedRange) && [self completionAtCaret];
    NSUInteger version = self.syntax.textVersion;
    _editingCompletionPrefix = refine;
    if (text.length != 1 || ![self applyTyping:TypingKey::Character character:[text characterAtIndex:0] selected:selected])
        [super insertText:string replacementRange:range];
    _editingCompletionPrefix = NO;
    if (version != self.syntax.textVersion && (trigger || suggest))
        [self showCompletionsWithMinimumPrefix:2 trigger:trigger ? text : nil continuing:refine];
}

- (void)insertNewline:(id)sender
{
    if (![self acceptCompletion] && ![self applyTyping:TypingKey::Enter character:0 selected:self.selectedRange])
        [super insertNewline:sender];
}

- (void)insertLineBreak:(id)sender
{
    if (![self applyTyping:TypingKey::Enter character:0 selected:self.selectedRange])
        [super insertLineBreak:sender];
}

- (void)deleteBackward:(id)sender
{
    BOOL wasEditing = _editingCompletionPrefix;
    BOOL refine = [self completionAtCaret] && _completionPrefix.length;
    NSUInteger version = self.syntax.textVersion;
    _editingCompletionPrefix = wasEditing || refine;
    if (![self applyTyping:TypingKey::Backspace character:0 selected:self.selectedRange])
        [super deleteBackward:sender];
    _editingCompletionPrefix = wasEditing;
    if (refine && version != self.syntax.textVersion)
        [self showCompletionsWithMinimumPrefix:2 trigger:nil continuing:YES];
}

- (void)insertTab:(id)sender
{
    if (![self acceptCompletion] && ![self applyTyping:TypingKey::Tab character:0 selected:self.selectedRange])
        [super insertTab:sender];
}

- (void)insertBacktab:(id)sender
{
    if (![self applyTyping:TypingKey::Backtab character:0 selected:self.selectedRange])
        [super insertBacktab:sender];
}

- (void)paste:(id)sender
{
    [self dismissCompletion];
    _pasting = YES;
    [super paste:sender];
    _pasting = NO;
}

- (std::optional<TypingEdit>)planCursorTyping:(Vim::Key)key selected:(NSRange)selection
                                indentation:(const Indentation &)indentation
{
    TypingKey action;
    char32_t character = char32_t(key);
    switch (character) {
        case char32_t(Vim::Key::Enter): case '\n': action = TypingKey::Enter; break;
        case char32_t(Vim::Key::Backspace): action = TypingKey::Backspace; break;
        case char32_t(Vim::Key::Tab): action = TypingKey::Tab; break;
        case char32_t(Vim::Key::Backtab): action = TypingKey::Backtab; break;
        default:
            if (character > 0xFFFF || !MayCompleteCharacter(unichar(character)))
                return {};
            action = TypingKey::Character;
            break;
    }
    return [self planTyping:action character:unichar(character) selected:selection
                         indentation:indentation];
}

- (std::optional<Vim::InsertEdit>)planVimInsert:(Vim::Key)key at:(NSUInteger)position
                                      tabWidth:(unsigned)tabWidth indentWidth:(unsigned)indentWidth
                                        spaces:(BOOL)spaces automaticIndent:(BOOL)automatic
{
    Indentation indentation{tabWidth, indentWidth, !spaces, bool(automatic)};
    _vimTypingEdit = [self planCursorTyping:key selected:NSMakeRange(position, 0) indentation:indentation];
    if (!_vimTypingEdit)
        return {};
    const TypingEdit &edit = *_vimTypingEdit;
    std::u16string text(edit.text.length, 0);
    if (!text.empty())
        [edit.text getCharacters:reinterpret_cast<unichar *>(text.data()) range:NSMakeRange(0, text.size())];
    return Vim::InsertEdit{{edit.range.location, NSMaxRange(edit.range)}, std::move(text), edit.selection.location};
}

- (void)finishVimInsertEdit
{
    if (_vimTypingEdit) {
        if (![self stageCursorTyping:*_vimTypingEdit])
            [self.syntax didType:*_vimTypingEdit];
        _vimTypingEdit.reset();
    }
}

- (Indentation)cursorIndentation { return self.syntax.indentation; }
- (void)prepareCursorBatch { [self.syntax finishHighlighting]; }

- (void)didTypeAtCursors:(const std::vector<TypingEdit> &)edits
{
    [self.syntax didTypeInBatch:edits];
}

- (NSString *)vimIndentAfter:(NSUInteger)position tabWidth:(unsigned)tabWidth
                  indentWidth:(unsigned)indentWidth spaces:(BOOL)spaces
{
    Indentation indentation{tabWidth, indentWidth, !spaces, true};
    auto edit = [self planTyping:TypingKey::Enter character:0 selected:NSMakeRange(position, 0)
                    indentation:indentation];
    if (edit) {
        NSUInteger end = std::min(edit->text.length, edit->selection.location - edit->range.location);
        NSRange newline = [edit->text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet
                                                      options:0 range:NSMakeRange(0, end)];
        if (newline.location != NSNotFound) {
            NSUInteger start = NSMaxRange(newline);
            if (start < end && [edit->text characterAtIndex:newline.location] == '\r' &&
                [edit->text characterAtIndex:start] == '\n')
                ++start;
            return [edit->text substringWithRange:NSMakeRange(start, end - start)];
        }
    }
    return [super vimIndentAfter:position tabWidth:tabWidth indentWidth:indentWidth spaces:spaces];
}

- (void)refreshWordSelection
{
    NSRange selection = [self selectedCharacterRange];
    NSUInteger version = self.syntax.textVersion;
    if (NSEqualRanges(selection, _wordSelection) && version == _wordVersion)
        return;
    _wordSelection = selection;
    _wordVersion = version;

    NSString *word = nil;
    NSString *text = self.string;
    bool lisp = LispSymbols(self.syntax.language);
    if (selection.length && selection.length < text.length && selection.location <= text.length &&
        selection.length <= text.length - selection.location && AtWordBoundaries(text, selection, lisp)) {
        NSUInteger end = NSMaxRange(selection);
        NSUInteger at = selection.location;
        while (at < end && WordCharacterAt(text, at, lisp))
            ++at;
        if (at == end)
            word = [text substringWithRange:selection];
    }
    if (_selectedWord || word)
        [self setNeedsDisplayInRect:self.visibleRect];
    _selectedWord = word;
}

- (void)drawWordOccurrences:(NSRect)dirty
{
    if (!_selectedWord || _wordVersion != self.syntax.textVersion)
        return;
    NSRect area = NSIntersectionRect(dirty, self.visibleRect);
    if (NSIsEmptyRect(area))
        return;
    NSLayoutManager *layout = self.layoutManager;
    NSTextContainer *container = self.textContainer;
    NSPoint origin = self.textContainerOrigin;
    NSRange glyphs = [layout glyphRangeForBoundingRect:NSOffsetRect(area, -origin.x, -origin.y)
                                      inTextContainer:container];
    NSRange characters = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:nullptr];
    if (!characters.length)
        return;

    NSString *text = self.string;
    // Include the rest of a word clipped by a horizontal scroll or a partial redraw.
    NSUInteger padding = _selectedWord.length - 1;
    NSUInteger start = characters.location - std::min(characters.location, padding);
    NSUInteger end = std::min(NSMaxRange(characters) + padding, text.length);
    const Theme &theme = *self.theme;
    bool lisp = LispSymbols(self.syntax.language);
    [[SRGBColor(theme.accents.wordMatch) colorWithAlphaComponent:theme.dark ? 0.19 : 0.15] setFill];
    while (start < end && end - start >= _selectedWord.length) {
        NSRange match = [text rangeOfString:_selectedWord options:NSLiteralSearch range:NSMakeRange(start, end - start)];
        if (match.location == NSNotFound)
            break;
        start = NSMaxRange(match);
        if (NSEqualRanges(match, _wordSelection) || !AtWordBoundaries(text, match, lisp))
            continue;
        NSRange span = [layout glyphRangeForCharacterRange:match actualCharacterRange:nullptr];
        [layout enumerateEnclosingRectsForGlyphRange:span withinSelectedGlyphRange:NSMakeRange(NSNotFound, 0)
                                     inTextContainer:container usingBlock:^(NSRect rect, BOOL *) {
            rect = NSInsetRect(NSOffsetRect(rect, origin.x, origin.y), 0, 1);
            NSRectFillUsingOperation(NSIntersectionRect(rect, area), NSCompositingOperationSourceOver);
        }];
    }
}

- (NSRect)visibleBracketRect:(NSUInteger)position
{
    if (position >= self.string.length)
        return NSZeroRect;
    NSLayoutManager *layout = self.layoutManager;
    NSPoint origin = self.textContainerOrigin;
    NSRect visible = NSOffsetRect(self.visibleRect, -origin.x, -origin.y);
    NSRange glyphs = [layout glyphRangeForBoundingRect:visible inTextContainer:self.textContainer];
    NSRange characters = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:nullptr];
    return NSLocationInRange(position, characters) ? [self vimCaretAt:position] : NSZeroRect;
}

- (void)invalidateBrackets:(BracketMatch)brackets
{
    for (NSUInteger position : {brackets.at, brackets.mate}) {
        NSRect rect = [self visibleBracketRect:position];
        if (!NSIsEmptyRect(rect))
            [self setNeedsDisplayInRect:NSInsetRect(rect, -1, -1)];
    }
}

- (void)refreshBracketMatch
{
    if (!self.editable)
        return;
    bool under = self.vimEnabled && !self.vimInserting;
    NSRange selection = under ? NSMakeRange(self.vimDisplayedCursor, 0) : self.selectedRange;
    if (NSEqualRanges(selection, _bracketSelection) && _bracketVersion == self.syntax.textVersion &&
        _bracketUnderCursor == under)
        return;
    _bracketSelection = selection;
    _bracketVersion = self.syntax.textVersion;
    _bracketUnderCursor = under;

    BracketMatch match = BracketsAtSelection(self.textStorage, selection, under);
    if (match == _brackets)
        return;
    [self invalidateBrackets:_brackets];
    _brackets = match;
    [self invalidateBrackets:match];
    [_bracketTimer invalidate];
    _bracketTimer = nil;
    if (match.mate == typingNotFound)
        return;
    _bracketFlashStart = NSProcessInfo.processInfo.systemUptime;
    __weak CodeView *view = self;
    _bracketTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        CodeView *editor = view;
        if (!editor) {
            [timer invalidate];
        } else {
            [editor invalidateBrackets:editor->_brackets];
            if (NSProcessInfo.processInfo.systemUptime - editor->_bracketFlashStart >= 0.22) {
                [timer invalidate];
                editor->_bracketTimer = nil;
            }
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_bracketTimer forMode:NSRunLoopCommonModes];
}

- (void)drawBracketMatch:(NSRect)dirty flash:(BOOL)flash
{
    if (_brackets.mate == typingNotFound)
        return;
    const Theme &theme = *self.theme;
    if (flash) {
        if (!_bracketTimer)
            return;
        NSRect rect = NSIntersectionRect([self visibleBracketRect:_brackets.mate], dirty);
        if (!NSIsEmptyRect(rect)) {
            CGFloat fade = std::clamp(1 - (NSProcessInfo.processInfo.systemUptime - _bracketFlashStart) / 0.22, 0.0, 1.0);
            [[SRGBColor(theme.accents.bracketMatch) colorWithAlphaComponent:0.32 * fade * fade] setFill];
            NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
        }
        return;
    }

    NSColor *outline = theme.dark || theme.blockCaretText ? SRGBColor(theme.accents.bracketMatch) : self.insertionPointColor;
    [[outline colorWithAlphaComponent:theme.dark ? 0.48 : 0.38] setStroke];
    CGFloat scale = std::abs(CGContextGetCTM(NSGraphicsContext.currentContext.CGContext).d);
    for (NSUInteger position : {_brackets.at, _brackets.mate}) {
        NSRect rect = [self visibleBracketRect:position];
        if (!NSIntersectsRect(dirty, rect))
            continue;
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.4, 1.1)
                                                            xRadius:1.5 yRadius:1.5];
        path.lineWidth = 1.0 / std::max<CGFloat>(1, scale);
        [path stroke];
    }
}

static NSColor *ContrastingSelectionColor(Col32 background)
{
    auto linear = [](uint8_t channel) {
        double value = channel / 255.0;
        return value <= 0.04045 ? value / 12.92 : std::pow((value + 0.055) / 1.055, 2.4);
    };
    double luminance = 0.2126 * linear(ColorRed(background)) +
                       0.7152 * linear(ColorGreen(background)) + 0.0722 * linear(ColorBlue(background));
    // At this luminance black and white have the same contrast.
    return SRGBColor(luminance >= 0.17913 ? rgb(0, 0, 0) : rgb(255, 255, 255));
}

- (void)applyAppearance
{
    [self applyAppearanceWithTheme:SelectedTheme()];
}

- (void)applyAppearanceWithTheme:(const ThemeRef &)palette
{
    NSFont *font = EditorFontPreference();
    [self applyAppearanceWithTheme:palette font:font hintFont:ShowInlayHints() ? InlayFont(font) : nil];
}

- (void)applyAppearanceWithTheme:(const ThemeRef &)palette font:(NSFont *)font hintFont:(NSFont *)hintFont
{
    [self dismissLanguageInformation];
    [self dismissCompletion];
    _palette = palette;
    const Theme *theme = _palette.get();
    self.theme = theme;
    self.rendering = RenderingPreference();
    self.backgroundColor = SRGBColor(theme->paper);
    self.insertionPointColor = SRGBColor(theme->caret.value_or(theme->ink[size_t(Ink::Text)]));
    NSColor *selection = SRGBColor(theme->selection);
    if (theme->contrastingSelectionText) {
        self.selectedTextAttributes = @{NSBackgroundColorAttributeName:selection,
                                        NSForegroundColorAttributeName:ContrastingSelectionColor(theme->selection)};
    } else {
        self.selectedTextAttributes = @{NSBackgroundColorAttributeName:selection};
    }

    [self.syntax refreshIndentationDefaults];
    Indentation indentation = self.syntax.indentation;
    [self setVimIndentation:indentation];
    NSUInteger tabStop = indentation.tabWidth;
    EditorTextStorage *storage = self.syntax.storage;
    CGFloat lineHeight = std::ceil(font.ascender - font.descender + font.leading);
    if (hintFont)
        lineHeight = std::max(lineHeight, std::ceil(hintFont.ascender - hintFont.descender));

    bool typographyChanged = ![_editorFont isEqual:font] || _fontTabStop != tabStop || _minimumLineHeight != lineHeight;
    if (typographyChanged) {
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        paragraph.baseWritingDirection = NSWritingDirectionLeftToRight;
        paragraph.minimumLineHeight = lineHeight;
        // Put the extra space below the glyphs so diagnostic marks clear descenders.
        paragraph.lineSpacing = editorLineSpacing;
        paragraph.tabStops = @[];
        paragraph.defaultTabInterval = tabStop * [@" " sizeWithAttributes:@{NSFontAttributeName:font}].width;
        if (storage.length) {
            [storage applyAttributes:@{NSFontAttributeName:font, NSParagraphStyleAttributeName:paragraph,
                                       NSLigatureAttributeName:@0} removing:nil inRange:NSMakeRange(0, storage.length)];
        } else {
            self.font = font;
        }
        self.typingAttributes = @{NSFontAttributeName:font, NSParagraphStyleAttributeName:paragraph,
                                  NSForegroundColorAttributeName:SRGBColor(theme->ink[size_t(Ink::Text)]),
                                  NSLigatureAttributeName:@0};
        _editorFont = font;
        _fontTabStop = tabStop;
        _minimumLineHeight = lineHeight;
    } else {
        NSMutableDictionary *typing = [self.typingAttributes mutableCopy];
        typing[NSFontAttributeName] = _editorFont;
        typing[NSForegroundColorAttributeName] = SRGBColor(theme->ink[size_t(Ink::Text)]);
        self.typingAttributes = typing;
    }
    [self.syntax setPalette:_palette font:_editorFont restyle:typographyChanged
                   brackets:BracketColorizationPreference()];
    if (typographyChanged) {
        if (self.vimEnabled)
            [self refreshVimCaret];
    }
    [self updateInsertionPointStateAndRestartTimer:NO];
    [self setNeedsDisplay:YES];
}

- (void)drawFoldMarks:(NSRect)dirty
{
    CodeLayoutManager *layout = (CodeLayoutManager *)self.layoutManager;
    const auto &folds = [layout editorFolds];
    if (folds.empty())
        return;
    NSPoint origin = self.textContainerOrigin;
    NSRange glyphs = [layout glyphRangeForBoundingRect:NSOffsetRect(dirty, -origin.x, -origin.y)
                                        inTextContainer:self.textContainer];
    NSRange characters = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:nullptr];
    NSUInteger last = NSNotFound;
    const auto &hidden = [layout hiddenEditorRanges];
    NSDictionary *ink = @{NSFontAttributeName:self.editorFont, NSForegroundColorAttributeName:SRGBColor(self.theme->lineNumber)};
    for (const auto &fold : folds) {
        if (fold.header >= NSMaxRange(characters))
            break;
        if (fold.header < characters.location || fold.header == last)
            continue;
        auto region = std::upper_bound(hidden.begin(), hidden.end(), fold.header,
                                       [](NSUInteger at, NSRange range) { return at < range.location; });
        if (region != hidden.begin() && NSLocationInRange(fold.header, *(region - 1)))
            continue;
        NSUInteger end;
        [self.string getLineStart:nullptr end:nullptr contentsEnd:&end forRange:NSMakeRange(fold.header, 0)];
        NSRect caret = [self vimCaretAt:end];
        CGFloat height = [@"…" sizeWithAttributes:ink].height;
        [@"…" drawAtPoint:NSMakePoint(NSMaxX(caret), NSMidY(caret) - height / 2) withAttributes:ink];
        last = fold.header;
    }
}

- (void)enumerateBuildErrorsInRect:(NSRect)area usingBlock:(void (^)(const BuildError &, NSRect))block
{
    SyntaxBuffer *buffer = self.syntax;
    if (!buffer)
        return;
    const auto &errors = [buffer buildErrors];
    const auto &languageErrors = [buffer languageErrors];
    if (errors.empty() && languageErrors.empty())
        return;
    CodeLayoutManager *layout = (CodeLayoutManager *)self.layoutManager;
    NSTextContainer *container = self.textContainer;
    NSPoint origin = self.textContainerOrigin;
    NSRect search = NSInsetRect(NSOffsetRect(area, -origin.x, -origin.y), 0, -2);
    NSRange glyphs = [layout glyphRangeForBoundingRect:search inTextContainer:container];
    NSRange visible = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:nullptr];
    NSUInteger visibleEnd = NSMaxRange(visible);
    if (layout.extraLineFragmentTextContainer == container && NSIntersectsRect(search, layout.extraLineFragmentRect))
        visibleEnd = self.string.length;
    const auto &hidden = [layout hiddenEditorRanges];
    NSUInteger start = [buffer offsetForLine:[buffer lineForOffset:visible.location]];
    bool showUnusedWarnings = ShowUnusedWarnings();
    auto drawErrors = [&](const std::vector<BuildError> &items) {
        auto first = std::lower_bound(items.begin(), items.end(), start,
            [](const BuildError &error, NSUInteger offset) { return error.range.location < offset; });
        for (auto item = first; item != items.end(); ++item) {
            const BuildError &error = *item;
            NSRange span = error.range;
            if (span.location > visibleEnd)
                break;
            if ((error.unusedWarning && !showUnusedWarnings) || NSMaxRange(span) < visible.location)
                continue;
            auto next = std::upper_bound(hidden.begin(), hidden.end(), span.location,
                                        [](NSUInteger at, NSRange range) { return at < range.location; });
            if (next != hidden.begin() && NSLocationInRange(span.location, *(next - 1)))
                continue;
            NSRect rect;
            if (span.length) {
                NSRange range = [layout glyphRangeForCharacterRange:span actualCharacterRange:nullptr];
                rect = [layout boundingRectForGlyphRange:range inTextContainer:container];
                NSRange fragment;
                NSRect line = [layout lineFragmentRectForGlyphAtIndex:range.location effectiveRange:&fragment];
                if (NSMaxRange(range) <= NSMaxRange(fragment))
                    rect.size.width = std::max(0.0, NSWidth(rect) - [layout inlayWidthAfterCharacter:NSMaxRange(span) - 1]);
                rect.origin.y = NSMinY(line);
                rect.size.height = NSHeight(line);
                rect = NSOffsetRect(rect, origin.x, origin.y);
            } else {
                rect = [self vimCaretAt:span.location];
            }
            if (NSIntersectsRect(rect, area))
                block(error, rect);
        }
    };
    drawErrors(errors);
    drawErrors(languageErrors);
}

- (void)diagnosticsChanged
{
    if (_hoveredError) {
        const BuildError &previous = *_hoveredError;
        const BuildError *current = nullptr;
        for (const auto *errors : {&self.syntax.buildErrors, &self.syntax.languageErrors}) {
            auto item = std::lower_bound(errors->begin(), errors->end(), previous.range.location,
                [](const BuildError &error, NSUInteger at) { return error.range.location < at; });
            for (; item != errors->end() && item->range.location == previous.range.location; ++item) {
                if (NSEqualRanges(item->range, previous.range) && item->warning == previous.warning &&
                    (!item->unusedWarning || ShowUnusedWarnings()) && [item->message isEqualToString:previous.message] &&
                    (item->label == previous.label || [item->label isEqualToString:previous.label])) {
                    current = &*item;
                    break;
                }
            }
            if (current)
                break;
        }
        if (current)
            _hoveredError = *current;
        else
            [self dismissPointerInformation];
    }
    [self updateLanguageTracking];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self dismissLanguageInformation];
    [self updateLanguageTracking];
    if (self.window)
        [self.syntax scheduleInlayHints];
    else
        [self.syntax suspendInlayHintsIfHidden];
}

- (BOOL)becomeFirstResponder
{
    BOOL focused = [super becomeFirstResponder];
    if (focused)
        [self.syntax scheduleInlayHints];
    return focused;
}

- (void)drawBuildErrors:(NSRect)dirty
{
    [self enumerateBuildErrorsInRect:dirty usingBlock:^(const BuildError &error, NSRect rect) {
        NSRect underline = NSMakeRect(NSMinX(rect), NSMaxY(rect) - 2, NSWidth(rect), 2);
        if (!NSIntersectsRect(underline, dirty))
            return;
        Col32 color = error.warning ? (self.theme->dark ? rgb(233, 182, 69) : rgb(168, 107, 0)) :
            (self.theme->dark ? rgb(255, 83, 83) : rgb(210, 25, 35));
        [SRGBColor(color) setStroke];
        constexpr CGFloat amplitude = 0.5;
        CGFloat y = NSMidY(underline);
        CGFloat start = NSMinX(rect);
        CGFloat x = start + 4 * std::max<CGFloat>(0, std::floor((NSMinX(dirty) - start) / 4));
        CGFloat end = std::min(NSMaxX(rect), NSMaxX(dirty) + 2);
        NSBezierPath *wave = [NSBezierPath bezierPath];
        wave.lineWidth = 0.85;
        wave.lineJoinStyle = NSLineJoinStyleRound;
        [wave moveToPoint:NSMakePoint(x, y - amplitude)];
        for (bool tip = true; x < end; tip = !tip) {
            x = std::min(x + 2, end);
            [wave lineToPoint:NSMakePoint(x, y + (tip ? amplitude : -amplitude))];
        }
        [wave stroke];
    }];
}

- (void)showDebugLine:(NSUInteger)line exception:(NSString *)exception
{
    if (_debugLine == line && (_debugException == exception || [_debugException isEqualToString:exception]))
        return;
    _debugLine = line;
    _debugException = exception;
    [self setNeedsDisplayInRect:self.visibleRect];
}

- (NSRect)debugLineInRect:(NSRect)dirty used:(NSRect *)used
{
    if (!self.debugLine || self.debugLine > self.syntax.lineCount)
        return NSZeroRect;
    NSLayoutManager *layout = self.layoutManager;
    NSPoint origin = self.textContainerOrigin;
    NSRect row = NSMakeRect(0, NSMinY(dirty) - origin.y, NSWidth(self.bounds), NSHeight(dirty));
    NSRange visible = [layout glyphRangeForBoundingRect:row inTextContainer:self.textContainer];
    NSUInteger offset = [self.syntax offsetForLine:self.debugLine - 1];
    NSRect fragment = NSZeroRect;
    if (offset == self.string.length) {
        if (layout.extraLineFragmentTextContainer == self.textContainer)
            fragment = layout.extraLineFragmentRect;
    } else if (visible.length) {
        NSRange characters = [layout characterRangeForGlyphRange:visible actualGlyphRange:nullptr];
        if (!NSLocationInRange(offset, characters))
            return NSZeroRect;
        NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:offset];
        fragment = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr];
        *used = NSOffsetRect([layout lineFragmentUsedRectForGlyphAtIndex:glyph effectiveRange:nullptr], origin.x, origin.y);
    }
    return NSMakeRect(NSMinX(dirty), NSMinY(fragment) + origin.y, NSWidth(dirty), NSHeight(fragment));
}

- (void)drawDebugExceptionInRect:(NSRect)line used:(NSRect)used
{
    NSString *message = self.debugException;
    if (!message.length || NSIsEmptyRect(line))
        return;
    NSRect visible = self.visibleRect;
    constexpr CGFloat inset = 8;
    CGFloat end = NSMaxX(visible) - inset;
    CGFloat maximum = std::min(NSWidth(visible) - 2 * inset, std::clamp(NSWidth(visible) * 0.48, 100.0, 460.0));
    if (maximum <= 0)
        return;

    NSRange newline = [message rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
    if (newline.location != NSNotFound)
        message = [message substringToIndex:newline.location];
    BOOL dark = self.theme->dark;
    NSColor *ink = SRGBColor(dark ? rgb(255, 187, 183) : rgb(140, 27, 26));
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentRight;
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSFont *font = [NSFont systemFontOfSize:std::min(12.0, self.editorFont.pointSize)];
    NSDictionary *attributes = @{NSForegroundColorAttributeName:ink, NSFontAttributeName:font, NSParagraphStyleAttributeName:style};
    CGFloat width = std::min(maximum, std::ceil([message sizeWithAttributes:attributes].width) + 1);
    CGFloat x = end - width;
    if (x < NSMaxX(used) + inset) {
        // Keep the message visible when source text reaches the right edge.
        [SRGBColor(dark ? rgb(98, 42, 40) : rgb(251, 222, 220)) setFill];
        NSRectFill(NSMakeRect(x - 5, NSMinY(line), width + inset + 5, NSHeight(line)));
    }
    CGFloat y = NSMidY(line) - (font.ascender - font.descender) / 2;
    [message drawInRect:NSMakeRect(x, y, width, NSHeight(line)) withAttributes:attributes];
}

static void AddInlayOutline(CGContextRef context, NSRect rect, CGFloat radius)
{
    CGFloat left = NSMinX(rect), right = NSMaxX(rect);
    CGFloat top = NSMinY(rect), bottom = NSMaxY(rect);
    CGContextMoveToPoint(context, left + radius, top);
    CGContextAddArcToPoint(context, right, top, right, bottom, radius);
    CGContextAddArcToPoint(context, right, bottom, left, bottom, radius);
    CGContextAddArcToPoint(context, left, bottom, left, top, radius);
    CGContextAddArcToPoint(context, left, top, right, top, radius);
    CGContextClosePath(context);
}

- (CGFloat)vimExtraGlyphWidthAt:(NSUInteger)position
{
    return [(CodeLayoutManager *)self.layoutManager inlayWidthAfterCharacter:position];
}

static bool InlayGapIsHidden(CodeLayoutManager *layout, const InlayGap &gap)
{
    const auto &hidden = [layout hiddenEditorRanges];
    auto fold = std::upper_bound(hidden.begin(), hidden.end(), gap.glyphStart,
        [](NSUInteger index, NSRange range) { return index < range.location; });
    return fold != hidden.begin() && NSLocationInRange(gap.glyphStart, *(fold - 1));
}

static NSRect InlayGapRect(CodeLayoutManager *layout, NSTextContainer *container, NSPoint origin, const InlayGap &gap)
{
    if (InlayGapIsHidden(layout, gap))
        return NSZeroRect;

    NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:gap.glyphStart];
    NSRect row = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr];
    CGFloat right;
    if (gap.kind == InlayGapKind::Leading) {
        right = NSMinX(row) + [layout locationForGlyphAtIndex:glyph].x;
    } else {
        NSRange anchor = [layout glyphRangeForCharacterRange:NSMakeRange(gap.glyphStart, gap.at - gap.glyphStart) actualCharacterRange:nullptr];
        right = NSMaxX([layout boundingRectForGlyphRange:anchor inTextContainer:container]);
    }
    return NSMakeRect(origin.x + right - gap.width, origin.y + NSMinY(row), gap.width, NSHeight(row));
}

- (CGFloat)inlayWidthAtInsertion:(NSUInteger)position
{
    auto gaps = [self.syntax.storage inlayGaps];
    auto gap = std::ranges::lower_bound(gaps, position, {}, &InlayGap::at);
    if (gap == gaps.end() || gap->at != position || InlayGapIsHidden((CodeLayoutManager *)self.layoutManager, *gap))
        return 0;
    return gap->width;
}

- (NSUInteger)inlayInsertionAtPoint:(NSPoint)point before:(BOOL *)before
{
    auto gaps = [self.syntax.storage inlayGaps];
    if (gaps.empty())
        return NSNotFound;

    CodeLayoutManager *layout = (CodeLayoutManager *)self.layoutManager;
    NSTextContainer *container = self.textContainer;
    NSPoint origin = self.textContainerOrigin;
    auto characters = [self vimCharactersInViewport:NSMakeRect(point.x, point.y, 1, 1)];
    auto gap = std::ranges::lower_bound(gaps, characters.first, {}, &InlayGap::at);
    for (; gap != gaps.end() && gap->at <= characters.last; ++gap) {
        NSRect rect = InlayGapRect(layout, container, origin, *gap);
        if (NSPointInRect(point, rect)) {
            *before = point.x < NSMidX(rect);
            return gap->at;
        }
    }
    return NSNotFound;
}

- (void)drawInlayHints:(NSRect)dirty foreground:(NSColor *)foreground
{
    auto labels = [self.syntax.storage inlayLabels];
    if (labels.empty())
        return;

    CodeLayoutManager *layout = (CodeLayoutManager *)self.layoutManager;
    NSTextContainer *container = self.textContainer;
    auto characters = [self vimCharactersInViewport:dirty];
    auto gaps = [self.syntax.storage inlayGaps];
    auto gap = std::ranges::lower_bound(gaps, characters.first, {}, &InlayGap::at);
    if (gap == gaps.end() || gap->at > characters.last)
        return;
    auto label = std::ranges::lower_bound(labels, gap->at, {}, &InlayLabel::at);
    NSPoint origin = self.textContainerOrigin;
    auto colors = self.theme->inlay;
    NSColor *text = foreground ? foreground : SRGBColor(colors.text);
    NSColor *background = foreground ? nil : SRGBColor(colors.background);
    NSColor *border = !foreground && ColorAlpha(colors.border) ? SRGBColor(colors.border) : nil;
    CGFloat pixel = 1 / std::max(1.0, self.window.backingScaleFactor);
    auto snap = [pixel](CGFloat value) { return std::round(value / pixel) * pixel; };

    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextClipToRect(context, dirty);
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    CGContextSetShouldAntialias(context, true);
    CGContextSetShouldSmoothFonts(context, false);
    CGContextSetLineWidth(context, pixel);
    if (border)
        CGContextSetStrokeColorWithColor(context, border.CGColor);
    for (; gap != gaps.end() && gap->at <= characters.last; ++gap) {
        auto first = label;
        while (label != labels.end() && label->at == gap->at)
            ++label;

        NSRect row = InlayGapRect(layout, container, origin, *gap);
        if (NSIsEmptyRect(row))
            continue;

        CGFloat x = NSMinX(row);
        CGFloat midY = NSMidY(row) - editorLineSpacing / 2;
        for (auto item = first; item != label; ++item) {
            CGFloat left = snap(x + item->left);
            x += item->width();
            if (x <= NSMinX(dirty) || left >= NSMaxX(dirty))
                continue;

            CTLineRef line = (__bridge CTLineRef)item->line;
            CGFloat ascent, descent;
            CTLineGetTypographicBounds(line, &ascent, &descent, nullptr);
            if (background) {
                CGFloat height = std::min(NSHeight(row) - pixel, std::ceil(ascent + descent) + 1);
                NSRect rect = NSMakeRect(left, snap(midY - height / 2), item->textWidth + 2 * inlayInset, height);
                CGContextSetFillColorWithColor(context, background.CGColor);
                CGContextBeginPath(context);
                AddInlayOutline(context, rect, 2);
                CGContextFillPath(context);
                if (border) {
                    CGContextBeginPath(context);
                    AddInlayOutline(context, NSInsetRect(rect, pixel / 2, pixel / 2), 2 - pixel / 2);
                    CGContextStrokePath(context);
                }
            }
            NSPoint baseline = NSMakePoint(left + inlayInset, snap(midY + (ascent - descent) / 2));
            [layout drawShapedLine:line atPoint:baseline color:text];
        }
    }
    CGContextRestoreGState(context);
}

- (void)drawVimBlockCarets:(const std::vector<VimBlockCaret> &)carets dirty:(NSRect)dirty
{
    CodeLayoutManager *layout = (CodeLayoutManager *)self.layoutManager;
    NSPoint origin = self.textContainerOrigin;
    NSString *source = self.string;
    NSColor *fill = self.insertionPointColor;
    auto caretText = self.theme->blockCaretText;
    NSColor *ink = caretText ? SRGBColor(*caretText) : nil;
    NSColor *inlayInk = ink;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    for (const auto &caret : carets) {
        NSRect box = [self backingAlignedRect:caret.rect options:NSAlignAllEdgesNearest];
        box = NSIntersectionRect(box, dirty);
        if (NSIsEmptyRect(box))
            continue;
        [fill setFill];
        NSRectFill(box);
        if (caret.position == NSNotFound) {
            if (!inlayInk)
                inlayInk = ContrastingSelectionColor(self.theme->caret.value_or(self.theme->ink[size_t(Ink::Text)]));
            [self drawInlayHints:box foreground:inlayInk];
        } else if (ink && caret.position < source.length) {
            NSRange characters = [source rangeOfComposedCharacterSequenceAtIndex:caret.position];
            NSRange glyphs = [layout glyphRangeForCharacterRange:characters actualCharacterRange:nullptr];
            CGContextSaveGState(context);
            CGContextClipToRect(context, box);
            [layout drawGlyphsForGlyphRange:glyphs atPoint:origin color:ink];
            CGContextRestoreGState(context);
        }
    }
}

- (void)sizeToFit
{
    BOOL fitting = _fittingDocument;
    _fittingDocument = YES;
    [super sizeToFit];
    _fittingDocument = fitting;
}

- (void)setFrameSize:(NSSize)size
{
    if (!_fittingDocument && self.layoutManager.hasNonContiguousLayout &&
        self.enclosingScrollView && !self.syntax.hasPendingHighlighting) {
        NSSize current = self.frame.size;
        NSRect visible = self.visibleRect;
        // Small changes to the estimated height can wait while both sizes cover the viewport.
        // Resizing on each estimate makes AppKit discard the existing scroll pixels.
        if (size.width == current.width && std::abs(size.height - current.height) < NSHeight(visible) &&
            NSMaxY(visible) + NSHeight(visible) < std::min(size.height, current.height))
            return;
    }

    [super setFrameSize:size];
}

- (void)prepareContentInRect:(NSRect)rect
{
    NSRect visible = self.visibleRect;
    NSLayoutManager *layout = self.layoutManager;
    SyntaxBuffer *buffer = self.syntax;
    if (_preparingViewport || !layout.hasNonContiguousLayout || NSIsEmptyRect(visible) ||
        !buffer || buffer.hasPendingHighlighting) {
        [super prepareContentInRect:NSIntersectionRect(rect, visible)];
        return;
    }

    NSTextContainer *container = self.textContainer;
    NSRect area = NSMakeRect(0, NSMinY(visible) - self.textContainerOrigin.y, NSWidth(self.bounds), NSHeight(visible));
    NSRange glyphs = [layout glyphRangeForBoundingRectWithoutAdditionalLayout:area inTextContainer:container];
    NSRect before = glyphs.length ?
        [layout lineFragmentRectForGlyphAtIndex:glyphs.location effectiveRange:nullptr withoutAdditionalLayout:YES] : NSZeroRect;
    NSUInteger character = NSIsEmptyRect(before) ? NSNotFound : [layout characterIndexForGlyphAtIndex:glyphs.location];
    NSClipView *clip = self.enclosingScrollView.contentView;
    NSRect target = clip.bounds;
    _preparingViewport = YES;
    if (character == NSNotFound || [self hasVimFolds]) {
        [layout ensureLayoutForBoundingRect:area inTextContainer:container];
    } else {
        // Fill the same group of nearby rows until the viewport reaches the next group.
        NSUInteger row = [buffer lineForOffset:character];
        CGFloat lineHeight = std::max(1.0, [layout defaultLineHeightForFont:self.editorFont]);
        NSUInteger group = std::clamp(NSUInteger(NSHeight(visible) / lineHeight), NSUInteger(1), NSUInteger(32));
        NSUInteger offset = [buffer offsetForLine:row - row % group];
        [self prepareLayoutAroundOffset:offset verticalMargin:2 * NSHeight(visible)];
    }

    if (character != NSNotFound) {
        NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:character];
        NSRect after = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr withoutAdditionalLayout:YES];
        if (!NSIsEmptyRect(after)) {
            // Preserve the visible row's screen position when filling a hole moves its layout.
            target.origin.y += NSMinY(after) - NSMinY(before);
            if (std::abs(NSMinY(target) - NSMinY(clip.bounds)) > 0.01)
                [clip scrollToPoint:[clip constrainBoundsRect:target].origin];
        }
    }
    [super prepareContentInRect:NSIntersectionRect(rect, self.visibleRect)];
    _preparingViewport = NO;
}

- (void)drawRect:(NSRect)dirty
{
    // AppKit also paints rows just outside the viewport for scrolling.
    dirty = NSIntersectionRect(dirty, self.bounds);
    if (NSIsEmptyRect(dirty))
        return;
    RenderSettings settings = self.rendering;
    CodeLayoutManager *layout = (CodeLayoutManager *)self.layoutManager;
    NSColor *selectionColor = self.theme && self.theme->contrastingSelectionText ?
        self.selectedTextAttributes[NSForegroundColorAttributeName] : nil;
    DrawEditorSurface(self, dirty, settings, self.backgroundColor, layout, ^(NSRect rect) {
        [self.backgroundColor setFill];
        NSRectFill(rect);
        if (self.theme && NSIntersectsRect(self.currentLine, rect)) {
            [SRGBColor(self.theme->line) setFill];
            NSRectFill(NSIntersectionRect(self.currentLine, rect));
        }
        NSRect debugUsed = NSZeroRect;
        NSRect debugLine = [self debugLineInRect:rect used:&debugUsed];
        if (NSIntersectsRect(debugLine, rect)) {
            NSColor *tone = self.debugException.length ? SRGBColor(rgb(212, 57, 52)) :
                self.theme->dark ? SRGBColor(rgb(222, 185, 63)) : SRGBColor(rgb(245, 195, 49));
            [[tone colorWithAlphaComponent:self.debugException.length ? 0.32 : 0.19] setFill];
            NSRectFillUsingOperation(NSIntersectionRect(debugLine, rect), NSCompositingOperationSourceOver);
        }
        [self drawWordOccurrences:rect];
        if (NSIntersectsRect(_languageHoverHighlight, rect)) {
            const Theme &theme = *self.theme;
            [[SRGBColor(theme.accents.wordMatch) colorWithAlphaComponent:theme.dark ? 0.20 : 0.14] setFill];
            NSRectFillUsingOperation(NSIntersectionRect(_languageHoverHighlight, rect), NSCompositingOperationSourceOver);
        }
        std::vector<NSRange> selections;
        std::vector<NSRange> inactiveSelections;
        std::vector<VimBlockCaret> blockCarets;
        bool showWhitespace = self.theme && settings.whitespace != WhitespaceMode::None;
        bool focused = self.window.isKeyWindow && self.window.firstResponder == self;
        bool activeSelection = selectionColor && focused;
        if (activeSelection || (showWhitespace && (!self.vimEnabled || self.trackingVimMouseSelection))) {
            auto &nativeSelections = focused ? selections : inactiveSelections;
            for (NSValue *value in self.selectedRanges) {
                NSRange range = value.rangeValue;
                if (range.length && range.location != NSNotFound)
                    nativeSelections.push_back(range);
            }
        }
        size_t firstColoredRange = activeSelection ? 0 : selections.size();
        if (self.vimEnabled || self.cursorCount > 1) {
            NSColor *flash = SRGBColor(self.theme->accents.vimFlash);
            [self drawVimOverlays:rect selection:SRGBColor(self.theme->selection) flash:flash
                   selectedRanges:showWhitespace || selectionColor ? &selections : nullptr
                      blockCarets:blockCarets contrastingCaret:self.theme->blockCaretText.has_value()];
        }
        [self drawBracketMatch:rect flash:YES];
        bool recolor = selectionColor && selections.size() > firstColoredRange;
        if (recolor)
            [layout setSelectionColor:selectionColor characterRanges:std::span(selections).subspan(firstColoredRange)];
        [super drawRect:rect];
        if (recolor)
            [layout setSelectionColor:nil characterRanges:std::span<const NSRange>{}];
        if (showWhitespace)
            DrawEditorWhitespace(self, rect, self.editorFont, settings.whitespace, self.theme->whitespace,
                                 self.theme->selection, selections, inactiveSelections);
        [self drawInlayHints:rect foreground:nil];
        [self drawFoldMarks:rect];
        [self drawBracketMatch:rect flash:NO];
        [self drawBuildErrors:rect];
        [self drawDebugExceptionInRect:debugLine used:debugUsed];
        if (!blockCarets.empty())
            [self drawVimBlockCarets:blockCarets dirty:rect];
        if (self.vimEnabled || self.cursorCount > 1)
            [self drawVimComposition:rect];
    });
}

@end

static CodeView *CreateCodeView(SyntaxBuffer *buffer, NSString *text)
{
    CodeLayoutManager *layout = [[CodeLayoutManager alloc] init];
    layout.backgroundLayoutEnabled = NO;
    [buffer.storage addLayoutManager:layout];
    if (![buffer.storage inlayGaps].empty())
        [layout setInlaySpacingSource:buffer.storage];
    NSTextContainer *container = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(containerLimit, containerLimit)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];

    CodeView *editor = [[CodeView alloc] initWithFrame:NSMakeRect(0, 0, 784, 596) textContainer:container];
    editor.syntax = buffer;
    // Start without a minimum. AppKit tracks the actual clip area once attached.
    editor.minSize = NSZeroSize;
    editor.maxSize = NSMakeSize(containerLimit, containerLimit);
    editor.verticallyResizable = YES;
    editor.horizontallyResizable = YES;
    editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    editor.textContainerInset = NSMakeSize(editorPadding, 8);
    editor.richText = NO;
    editor.importsGraphics = NO;
    editor.drawsBackground = NO;
    editor.smartInsertDeleteEnabled = NO;
    editor.continuousSpellCheckingEnabled = NO;
    editor.automaticSpellingCorrectionEnabled = NO;
    editor.automaticTextReplacementEnabled = NO;
    editor.automaticQuoteSubstitutionEnabled = NO;
    editor.automaticDashSubstitutionEnabled = NO;
    editor.automaticLinkDetectionEnabled = NO;
    editor.automaticDataDetectionEnabled = NO;
    if (text)
        [editor loadText:text];
    else
        [editor prepareDocumentAppearance:buffer.storage.string];
    return editor;
}

@interface EditorPreview : NSScrollView
- (instancetype)initWithCompactSample:(BOOL)compact;
@end

@implementation EditorPreview {
    SyntaxBuffer *_buffer;
    CodeView *_editor;
    NSFont *_hintFont;
    NSUInteger _hintOffset;
}

- (instancetype)initWithCompactSample:(BOOL)compact
{
    self = [super initWithFrame:NSMakeRect(0, 0, 516, 190)];
    if (!self)
        return nil;

    _buffer = [[SyntaxBuffer alloc] init];
    _buffer.language = Language::C;
    NSString *sample = compact ? @"printf(\"Hello, world!\\n\");" : @"#include <stdio.h>\n\n"
                         "enum { WIDTH = 64, HEIGHT = 64 };\n\n"
                         "int main(void)\n{\n"
                         "\t/* P6 is the binary PPM format. */\n"
                         "    printf(\"P6\\n%d %d\\n255\\n\", WIDTH, HEIGHT);  \n"
                         "    for (int i = 0; i < WIDTH * HEIGHT; ++i) {\n"
                         "        unsigned char rgb[] = {i & 255, 64, 255};\n"
                         "        fwrite(rgb, 1, sizeof rgb, stdout);\n"
                         "    }\n"
                         "    return 0;\n}";
    _hintOffset = NSMaxRange([sample rangeOfString:@"printf("]);
    _editor = CreateCodeView(_buffer, sample);
    _editor.editable = NO;
    _editor.selectable = NO;
    self.borderType = NSBezelBorder;
    self.scrollerStyle = NSScrollerStyleLegacy;
    self.hasVerticalScroller = YES;
    self.hasHorizontalScroller = YES;
    self.autohidesScrollers = YES;
    _editor.frame = NSMakeRect(0, 0, self.contentSize.width, self.contentSize.height);
    self.documentView = _editor;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged:)
                                               name:EditorPreferencesChanged object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged:)
                                               name:InlayPreferencesChanged object:nil];
    [self preferencesChanged:nil];
    return self;
}

- (void)preferencesChanged:(NSNotification *)notification
{
    (void)notification;
    NSFont *font = EditorFontPreference();
    NSFont *hintFont = InlayFont(font);
    [_editor applyAppearanceWithTheme:SelectedTheme() font:font hintFont:hintFont];
    if (![_hintFont isEqual:hintFont] || [_buffer.storage inlayLabels].empty()) {
        _hintFont = hintFont;
        NSDictionary *attributes = @{NSFontAttributeName:hintFont, (id)kCTForegroundColorFromContextAttributeName:@YES};
        CGFloat width;
        id line = ShapeInlayLine(@"format:", attributes, width);
        [_buffer.storage replaceInlayLabels:{{_hintOffset, width, 0, inlayGap, line}}];
    }

    [_editor sizeToFit];
    self.backgroundColor = RenderedEditorColor(_editor.theme->paper, _editor.rendering);
    self.appearance = [NSAppearance appearanceNamed:_editor.theme->dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

@end

NSView *CreateEditorPreview(bool compact)
{
    return [[EditorPreview alloc] initWithCompactSample:compact];
}

struct GutterBreakpointHit {
    NSUInteger line = 0;
    NSRect dot = NSZeroRect;
};

static CGFloat GutterLineCenter(NSRect fragment, CGFloat originY)
{
    return originY + NSMidY(fragment) - editorLineSpacing / 2;
}

@interface Gutter : NSView
@property(nonatomic, weak) CodeView *editor;
@property(nonatomic, weak) SyntaxBuffer *buffer;
@property(nonatomic) NSFont *numberFont;
@property(nonatomic, weak) DebugSession *debugSession;
@property(nonatomic, copy) void (^editBreakpoint)(NSString *, NSUInteger);
- (void)refreshBreakpointHover;
@end

@implementation Gutter {
    GutterBreakpointHit _hoveredBreakpoint;
    BOOL _mouseInGutter;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
            NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
    }
    return self;
}

- (NSRect)breakpointArea
{
    NSRect area = self.bounds;
    area.size.width = std::min(breakpointLane, NSWidth(area) / 2);
    return area;
}

- (NSRect)breakpointDotAtY:(CGFloat)y
{
    constexpr CGFloat radius = 4;
    return NSMakeRect(NSMidX([self breakpointArea]) - radius, y - radius, 2 * radius, 2 * radius);
}

- (GutterBreakpointHit)breakpointHitAtPoint:(NSPoint)point
{
    CodeView *editor = self.editor;
    if (!editor.debugPath.length ||
        !NSPointInRect(point, NSIntersectionRect([self breakpointArea], self.visibleRect)))
        return {};

    SyntaxBuffer *buffer = self.buffer;
    [buffer finishHighlighting];
    NSLayoutManager *layout = editor.layoutManager;
    NSTextContainer *container = editor.textContainer;
    CGFloat originY = [self convertPoint:editor.textContainerOrigin fromView:editor].y;
    CGFloat y = point.y - originY;
    NSRect fragment = layout.extraLineFragmentRect;
    if (layout.extraLineFragmentTextContainer == container && y >= NSMinY(fragment) && y < NSMaxY(fragment)) {
        return {buffer.lineCount, [self breakpointDotAtY:GutterLineCenter(fragment, originY)]};
    }
    if (!editor.string.length)
        return {};
    NSUInteger glyph = [layout glyphIndexForPoint:NSMakePoint(0, y) inTextContainer:container];
    if (![layout isValidGlyphIndex:glyph])
        return {};
    NSRange fragmentGlyphs;
    fragment = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:&fragmentGlyphs];
    if (y < NSMinY(fragment) || y >= NSMaxY(fragment))
        return {};
    NSUInteger offset = [layout characterIndexForGlyphAtIndex:fragmentGlyphs.location];
    NSUInteger line = [buffer lineForOffset:offset];
    if ([buffer offsetForLine:line] != offset)
        return {};
    return {line + 1, [self breakpointDotAtY:GutterLineCenter(fragment, originY)]};
}

- (void)setHoveredBreakpoint:(GutterBreakpointHit)hit
{
    if (hit.line == _hoveredBreakpoint.line && NSEqualRects(hit.dot, _hoveredBreakpoint.dot))
        return;
    if (_hoveredBreakpoint.line)
        [self setNeedsDisplayInRect:NSInsetRect(_hoveredBreakpoint.dot, -1, -1)];
    _hoveredBreakpoint = hit;
    if (hit.line)
        [self setNeedsDisplayInRect:NSInsetRect(hit.dot, -1, -1)];
}

- (void)updateBreakpointHoverAtWindowPoint:(NSPoint)windowPoint
{
    NSPoint point = [self convertPoint:windowPoint fromView:nil];
    _mouseInGutter = NSPointInRect(point, self.visibleRect);
    GutterBreakpointHit hit = [self breakpointHitAtPoint:point];
    [self setHoveredBreakpoint:hit];
    if (_mouseInGutter)
        [(hit.line ? NSCursor.pointingHandCursor : NSCursor.arrowCursor) set];
}

- (void)refreshBreakpointHover
{
    if (!_mouseInGutter)
        return;
    if (self.window.isKeyWindow)
        [self updateBreakpointHoverAtWindowPoint:self.window.mouseLocationOutsideOfEventStream];
    else
        [self setHoveredBreakpoint:GutterBreakpointHit{}];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self refreshBreakpointHover];
}

- (void)mouseMoved:(NSEvent *)event
{
    [self updateBreakpointHoverAtWindowPoint:event.locationInWindow];
}

- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)cursorUpdate:(NSEvent *)event { [self mouseMoved:event]; }

- (void)mouseExited:(NSEvent *)event
{
    (void)event;
    _mouseInGutter = NO;
    [self setHoveredBreakpoint:GutterBreakpointHit{}];
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger line = [self breakpointHitAtPoint:point].line;
    NSString *path = self.editor.debugPath;
    if (line)
        SetDebugBreakpoint(path, line, DebugBreakpoints(path)[@(line)] ? nil : @{});
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger line = [self breakpointHitAtPoint:point].line;
    if (!line)
        return nil;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *item = [menu addItemWithTitle:@"Edit Breakpoint…" action:@selector(editBreakpointFromMenu:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = @[self.editor.debugPath, @(line)];
    return menu;
}

- (void)editBreakpointFromMenu:(NSMenuItem *)sender
{
    NSArray *location = sender.representedObject;
    if (self.editBreakpoint)
        self.editBreakpoint(location[0], [location[1] unsignedIntegerValue]);
}

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)drawRect:(NSRect)dirty
{
    dirty = NSIntersectionRect(dirty, self.bounds);
    const Theme *theme = self.editor.theme;
    if (!theme || NSIsEmptyRect(dirty))
        return;
    RenderSettings settings{.smoothing = Smoothing::System, .saturation = self.editor.rendering.saturation,
                            .brightness = self.editor.rendering.brightness};
    DrawEditorSurface(self, dirty, settings, SRGBColor(theme->gutter), nil, ^(NSRect rect) {
        [self drawNumbersInRect:rect];
    });
}

- (void)drawNumbersInRect:(NSRect)dirty
{
    CodeView *editor = self.editor;
    SyntaxBuffer *buffer = self.buffer;
    const Theme &theme = *editor.theme;
    [SRGBColor(theme.gutter) setFill];
    NSRectFill(dirty);
    [SRGBColor(theme.rule) setFill];
    NSRectFill(NSMakeRect(NSWidth(self.bounds) - 1, NSMinY(dirty), 1, NSHeight(dirty)));

    NSLayoutManager *layout = editor.layoutManager;
    NSTextContainer *container = editor.textContainer;
    NSPoint origin = editor.textContainerOrigin;
    CGFloat originY = [self convertPoint:origin fromView:editor].y;
    NSRect visible = editor.visibleRect;
    NSRect area = NSMakeRect(0, NSMinY(visible) - origin.y, NSWidth(editor.bounds), NSHeight(visible));
    NSRange glyphs = [layout glyphRangeForBoundingRect:area inTextContainer:container];
    NSUInteger current = [buffer lineForOffset:std::min(editor.vimDisplayedCursor, editor.string.length)];
    NSFont *font = self.numberFont;
    NSDictionary *numberInk = @{NSFontAttributeName:font, NSForegroundColorAttributeName:SRGBColor(theme.lineNumber)};
    NSDictionary *activeInk = @{NSFontAttributeName:font, NSForegroundColorAttributeName:SRGBColor(theme.activeNumber)};
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGFloat scale = std::abs(CGContextGetCTM(context).d);
    NSString *path = editor.debugPath;
    NSDictionary *breakpoints = DebugBreakpoints(path);

    void (^drawNumber)(NSUInteger, NSRect) = ^(NSUInteger line, NSRect fragment) {
        CGFloat center = GutterLineCenter(fragment, originY);
        CGFloat halfHeight = NSHeight(fragment) / 2;
        if (center + halfHeight < NSMinY(dirty) || center - halfHeight > NSMaxY(dirty))
            return;
        NSDictionary *options = breakpoints.count ? breakpoints[@(line + 1)] : nil;
        if (options || _hoveredBreakpoint.line == line + 1) {
            BOOL disabled = [options[@"disabled"] boolValue];
            NSColor *ink = disabled ? NSColor.tertiaryLabelColor : SRGBColor(rgb(224, 63, 58));
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:[self breakpointDotAtY:center]];
            if (options && (disabled || (self.debugSession && ![self.debugSession breakpointResolved:path line:line + 1]))) {
                [ink setStroke];
                dot.lineWidth = 1.5;
                [dot stroke];
            } else {
                [(options ? ink : [ink colorWithAlphaComponent:0.36]) setFill];
                [dot fill];
            }
        }
        NSString *number = [editor vimLineNumber:line current:current];
        if (!number.length)
            return;
        NSAttributedString *label = [[NSAttributedString alloc] initWithString:number
                                      attributes:line == current ? activeInk : numberInk];
        CTLineRef text = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)label);
        CGRect ink = CTLineGetBoundsWithOptions(text, kCTLineBoundsUseGlyphPathBounds);
        // In a flipped view, the baseline sits below the center of the numeral's ink.
        CGFloat y = center + CGRectGetMidY(ink);
        CGFloat x = NSWidth(self.bounds) - gutterInset - CTLineGetTypographicBounds(text, nullptr, nullptr, nullptr);
        CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
        CGContextSetTextPosition(context, std::round(x * scale) / scale, std::round(y * scale) / scale);
        CTLineDraw(text, context);
        CFRelease(text);
    };

    if (glyphs.length) {
        [layout enumerateLineFragmentsForGlyphRange:glyphs
                                         usingBlock:^(NSRect rect, NSRect, NSTextContainer *, NSRange range, BOOL *) {
            NSUInteger offset = [layout characterIndexForGlyphAtIndex:range.location];
            NSUInteger line = [buffer lineForOffset:offset];
            if ([buffer offsetForLine:line] == offset)
                drawNumber(line, rect);
        }];
    }
    NSUInteger last = buffer.lineCount - 1;
    if ([buffer offsetForLine:last] == editor.string.length && layout.extraLineFragmentTextContainer == container)
        drawNumber(last, layout.extraLineFragmentRect);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
}

@end

@interface WindowStatusBar : NSView
@end

@implementation WindowStatusBar

- (BOOL)isOpaque { return YES; }

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty
{
    NSRect bounds = self.bounds;
    DrawWindowBarGradient(bounds, self.effectiveAppearance);
    NSRect rule = NSMakeRect(0, NSMaxY(bounds) - 1, NSWidth(bounds), 1);
    [NSColor.separatorColor setFill];
    NSRectFillUsingOperation(NSIntersectionRect(dirty, rule), NSCompositingOperationSourceOver);
}

@end

static NSTextField *StatusLabel(NSString *title)
{
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.textColor = NSColor.secondaryLabelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static bool HasEnabledBreakpoint(NSDictionary<NSNumber *, NSDictionary *> *lines)
{
    for (NSDictionary *options in lines.objectEnumerator) {
        if (![options[@"disabled"] boolValue])
            return true;
    }
    return false;
}

static bool RunHasBreakpoint(RunProject project, Language language, NSURL *file)
{
    if (!file || !DebuggableLanguage(language, file))
        return false;
    if (HasEnabledBreakpoint(DebugBreakpoints(file.path)))
        return true;

    NSURL *root = project.manifest ? project.manifest.URLByDeletingLastPathComponent : project.folder;
    NSString *folder = root.path;
    if (!folder.length)
        return false;
    auto *breakpoints = DebugAllBreakpoints();
    for (NSString *path in breakpoints) {
        if (!PathIsInFolder(path, folder) || !HasEnabledBreakpoint(breakpoints[path]))
            continue;
        NSURL *source = [NSURL fileURLWithPath:path];
        Language sourceLanguage = LanguageForSource(source);
        if ((sourceLanguage == language || (CFamily(language) && CFamily(sourceLanguage))) &&
            [NSFileManager.defaultManager fileExistsAtPath:path])
            return true;
    }
    return false;
}

enum class RunButtonAction { Run, Continue, Stop };
static constexpr NSInteger titleDebugButtonTag = 1;

static NSString *RunCommandTitle(RunButtonAction command)
{
    if (command == RunButtonAction::Continue)
        return @"Continue";
    return command == RunButtonAction::Stop ? @"Stop" : @"Run";
}

static NSImage *ContinueButtonImage()
{
    static NSImage *image = [] {
        NSImage *symbol = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:YES drawingHandler:^BOOL(NSRect) {
            [NSColor.blackColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.5, 2, 3.5, 14) xRadius:0.65 yRadius:0.65] fill];

            NSBezierPath *triangle = [NSBezierPath bezierPath];
            [triangle moveToPoint:NSMakePoint(7.5, 2)];
            [triangle lineToPoint:NSMakePoint(17, 9)];
            [triangle lineToPoint:NSMakePoint(7.5, 16)];
            [triangle closePath];
            [triangle fill];
            return YES;
        }];
        [symbol setTemplate:YES];
        symbol.accessibilityDescription = @"Continue";
        return symbol;
    }();
    return image;
}

static void SetRunButton(NSButton *button, RunButtonAction command)
{
    NSString *title = RunCommandTitle(command);
    if (!button || [button.accessibilityLabel isEqualToString:title])
        return;
    bool stop = command == RunButtonAction::Stop;
    if (command == RunButtonAction::Continue) {
        button.image = ContinueButtonImage();
    } else {
        NSImage *symbol = [NSImage imageWithSystemSymbolName:stop ? @"stop.fill" : @"play.fill" accessibilityDescription:title];
        NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightRegular];
        button.image = [symbol imageWithSymbolConfiguration:size];
    }
    button.contentTintColor = stop ? nil : SRGBColor(rgb(46, 148, 69));
    button.accessibilityLabel = title;
    button.toolTip = command == RunButtonAction::Continue ? DebugCommandToolTip(DebugCommand::Continue, title) :
        [title stringByAppendingString:@" (⌘R)"];
}

static void SetTitleDebugButton(NSButton *runButton, DebugPhase phase)
{
    NSView *container = runButton.superview;
    NSButton *button = (NSButton *)[container viewWithTag:titleDebugButtonTag];
    if (!button)
        return;

    bool paused = phase == DebugPhase::Paused;
    BOOL hidden = !paused && phase != DebugPhase::Running;
    if (!hidden) {
        SEL action = paused ? @selector(stopDebugging:) : @selector(pauseDebugging:);
        if (button.action != action) {
            DebugCommand command = paused ? DebugCommand::Stop : DebugCommand::Pause;
            NSString *title = paused ? @"Stop Debugging" : @"Pause";
            NSImage *symbol = [NSImage imageWithSystemSymbolName:paused ? @"stop.fill" : @"pause.fill" accessibilityDescription:title];
            static NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
            button.image = [symbol imageWithSymbolConfiguration:size];
            button.accessibilityLabel = title;
            button.toolTip = DebugCommandToolTip(command, title);
            button.action = action;
        }
    }

    if (button.hidden != hidden) {
        button.hidden = hidden;
        NSSize size = container.frame.size;
        size.width += hidden ? -NSWidth(button.frame) : NSWidth(button.frame);
        [container setFrameSize:size];
    }
}

static NSButton *MakeTitleRunControl(NSRect frame, SEL action)
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.action = action;
    return button;
}

@interface SourceDocument (VimActions)
- (void)performVimAction:(Vim::Action)action argument:(NSString *)argument force:(BOOL)force;
@end

@interface SourceDocument (Output)
- (BOOL)hasUTF8BOM;
- (void)revealRunLocation:(const RunLocation &)location;
- (void)cancelRun;
- (NSUInteger)beginBuildDiagnostics;
- (NSUInteger)diagnosticVersion;
- (void)applyBuildMessages:(const std::vector<RunMessage> &)messages version:(NSUInteger)version
                     owner:(BOOL)owner fromOutput:(BOOL)fromOutput;
@end

@interface SourceDocument (LanguageDetection)
- (Language)inferredLanguageForText:(NSString *)text;
@end

@interface SourceDocument (AutoSave)
- (void)scheduleAutoSaveAfterEdit;
- (void)requestAutoSave:(AutoSaveMode)mode;
- (void)resumePendingAutoSave;
- (NSError *)autoSaveError;
@end

struct BuildTarget {
    __weak SourceDocument *document;
    NSUInteger version;
    bool owner;
    NSURL *file = nil;
};

static void SaveBuildDocuments(NSArray<SourceDocument *> *documents, NSUInteger next, SourceRunner *runner,
                                void (^complete)(NSError *))
{
    if (runner.isStopped) {
        complete(nil);
        return;
    }
    while (next < documents.count) {
        SourceDocument *document = documents[next++];
        NSURL *file = document.fileURL;
        if (!file || !document.isDocumentEdited)
            continue;
        NSString *type = document.fileType;
        [document saveToURL:file ofType:type ? type : @"public.source-code" forSaveOperation:NSSaveOperation
           completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    complete(error);
                } else {
                    SaveBuildDocuments(documents, next, runner, complete);
                }
            });
        }];
        return;
    }
    for (SourceDocument *document in documents) {
        if (document.fileURL && document.isDocumentEdited) {
            NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ changed while saving. Run again.",
                                                                      document.displayName]
            }];
            complete(error);
            return;
        }
    }
    complete(nil);
}

static Vim::EditBatch IndentationConversion(NSString *text, Indentation style)
{
    std::vector<Vim::CursorEdit> edits;
    NSUInteger length = text.length;
    CFStringInlineBuffer characters;
    CFStringInitInlineBuffer((__bridge CFStringRef)text, &characters, CFRangeMake(0, length));
    for (NSUInteger start = 0; start < length;) {
        NSUInteger end, next;
        [text getLineStart:nullptr end:&next contentsEnd:&end forRange:NSMakeRange(start, 0)];
        NSUInteger at = start, column = 0, tabs = 0, spaces = 0;
        bool mixedOrder = false;
        for (; at < end; ++at) {
            unichar character = CFStringGetCharacterFromInlineBuffer(&characters, at);
            if (character == ' ') {
                ++spaces;
                ++column;
            } else if (character == '\t') {
                mixedOrder |= spaces != 0;
                ++tabs;
                column += style.tabWidth - column % style.tabWidth;
            } else {
                break;
            }
        }
        NSUInteger wantedTabs = style.tabs ? column / style.tabWidth : 0;
        NSUInteger wantedSpaces = column - wantedTabs * style.tabWidth;
        if (mixedOrder || tabs != wantedTabs || spaces != wantedSpaces) {
            std::u16string indent(wantedTabs, u'\t');
            indent.append(wantedSpaces, u' ');
            edits.push_back({{start, at}, std::move(indent)});
        }
        start = next;
    }
    return Vim::EditBatch(std::move(edits));
}

@class EditorWindow;

static void SyncNativeTabOutput(NSWindow *window);
static char selectedOutputTabContext;

@interface WindowOutput : NSView
@property(nonatomic) OutputPane *pane;
@property(nonatomic) OutputPane *errorsPane;
@property(nonatomic) DebugPane *debugPane;
@property(nonatomic) DebugSession *debugSession;
@property(nonatomic) SourceRunner *debugBuilder;
@property(nonatomic) DebugExecutable *externalExecutable;
@property(nonatomic, copy) NSArray<NSString *> *debugArguments;
@property(nonatomic, weak) SourceDocument *debugDocument;
@property(nonatomic) NSURL *debugFile;
@property(nonatomic) NSURL *debugFolder;
@property(nonatomic) Language debugLanguage;
@property(nonatomic) BOOL restartDebug;
@property(nonatomic, copy) NSString *debugStatus;
@property(nonatomic, weak) NSDictionary *navigatedFrame;
@property(nonatomic, readonly) BOOL debugging;
- (void)stopDebug;
@property(nonatomic, weak) EditorWindow *host;
@property(nonatomic, weak) EditorWindow *otherEditor;
@property(nonatomic, weak) SourceDocument *source;
@property(nonatomic) SourceRunner *runner;
@property(nonatomic) FolderWorkspace *runWorkspace;
@property(nonatomic) BOOL shown;
@property(nonatomic) BOOL returnFocus;
@property(nonatomic, readonly) NSTimer *checkTimer;
@property(nonatomic) SourceRunner *checkRunner;
@property(nonatomic) RustCheckCache *checkCache;
- (void)observeTabGroup:(NSWindowTabGroup *)group;
- (void)attachTo:(NSView *)content editorPane:(NSView *)editorPane;
- (void)showDockPage:(DockPage)page;
- (void)toggleDockPage:(DockPage)page;
- (void)updateEditorStatus;
- (void)updateEditorSettings;
- (void)updateLanguageStatus;
- (void)updateConsoleAppearance;
- (void)refreshDebugControls;
- (void)debugUpdated;
- (void)finishRun;
- (void)armCheckTimer:(NSTimeInterval)delay;
- (void)cancelCheck;
- (void)setCheckResult:(CheckResult)result source:(SourceDocument *)source;
- (void)presentDiagnostics;
@end

@interface EditorWindow : NSView <NSTextViewDelegate>
- (instancetype)initWithDocument:(SourceDocument *)document text:(NSString *)text language:(Language)language;
@property(nonatomic, readonly) CodeView *editor;
@property(nonatomic, readonly) CodeView *activeEditor;
@property(nonatomic, readonly) BOOL hasSplit;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) BOOL canRun;
@property(nonatomic, readonly) Indentation indentation;
@property(nonatomic, readonly) BOOL hasFileIndentation;
@property(nonatomic, readonly) NSInteger languageMode;
@property(nonatomic, readonly) BOOL automaticLanguageMode;
- (void)setFileIndentation:(Indentation)indentation;
- (void)detectFileIndentation;
- (void)resetFileIndentation;
- (void)convertIndentationToTabs:(BOOL)tabs;
- (void)rememberTabFocus;
- (NSView *)tabFocus;
- (void)setWindowOutput:(WindowOutput *)output;
- (void)updateLanguageDiagnostics;
- (void)scheduleLanguageCheck;
- (void)resumeLanguageCheck;
- (void)refreshLanguageServices;
- (void)closeLanguageServices;
- (void)updateLanguageHoverModifiers:(NSEvent *)event;
- (BOOL)hasDiagnostics;
- (BOOL)viewErrorAtCursor;
- (NSArray<NSMenuItem *> *)languagePaletteCommands;
- (void)cancelLanguageCheck;
- (void)startPendingLanguageCheck;
- (NSDictionary *)sessionView;
- (void)restoreSessionView:(NSDictionary *)state;
- (void)replaceDocumentText:(NSString *)text;
- (void)applyPreferences;
- (void)applyPreferencesWithTheme:(const ThemeRef &)palette;
- (void)updateEditorStatus;
- (BOOL)hasBuildErrors;
- (BOOL)hasMarkedEditorText;
- (void)finishEditingForClose;
- (void)setLanguage:(Language)language;
- (void)useAutomaticLanguage;
- (void)refreshDetectedLanguage;
- (IBAction)runSource:(id)sender;
- (void)performDebugCommand:(DebugCommand)command;
- (BOOL)canDebugCommand:(DebugCommand)command;
- (void)refreshDebugLocation;
- (void)startDebugTarget;
- (void)editBreakpoint:(NSString *)path line:(NSUInteger)line;
- (RunButtonAction)runCommand;
- (BOOL)canRunCommand;
- (void)refreshRunButton;
- (BOOL)isRunSource;
- (void)stopRun;
- (void)revealRunLocation:(const RunLocation &)location;
@property(nonatomic, weak) NSButton *runButton;
@end

static BOOL MoveFocusInDocumentSplit(EditorWindow *from, unichar key);

@implementation WindowOutput {
    __weak NSWindowTabGroup *_tabGroup;
    __weak SourceDocument *_diagnosticsSource;
    std::optional<std::vector<RunMessage>> _pendingDiagnostics;
    NSUInteger _errorCount, _warningCount;
    __weak NSView *_editorPane;
    WindowStatusBar *_statusBar;
    NSTextField *_position;
    NSTextField *_encoding;
    NSPopUpButton *_language;
    NSButton *_indentationButton;
    NSButton *_languageStatus;
    DockTab *_outputTab;
    DockTab *_errorsTab;
    DockTab *_debugTab;
    DockRail *_outputRail;
    DockDivider *_outputDivider;
    DockDropTarget *_dropTarget;
    DockSide _dockSide;
    DockPage _page;
    CGFloat _dockWidth;
    CGFloat _dockHeight;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _statusBar = [[WindowStatusBar alloc] init];
    [self addSubview:_statusBar];
    _position = StatusLabel(@"");
    _encoding = StatusLabel(@"UTF-8");
    _encoding.alignment = NSTextAlignmentCenter;
    [_statusBar addSubview:_position];
    [_statusBar addSubview:_encoding];
    _indentationButton = [NSButton buttonWithTitle:@"" target:nil action:@selector(showIndentationMenu:)];
    _indentationButton.bordered = NO;
    _indentationButton.refusesFirstResponder = YES;
    _indentationButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _indentationButton.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    _indentationButton.toolTip = @"Indentation";
    [_statusBar addSubview:_indentationButton];
    _languageStatus = [NSButton buttonWithTitle:@"LSP" target:nil action:@selector(showLanguageStatus:)];
    _languageStatus.bordered = NO;
    _languageStatus.refusesFirstResponder = YES;
    _languageStatus.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _languageStatus.contentTintColor = NSColor.textColor;
    _languageStatus.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    [_statusBar addSubview:_languageStatus];

    _outputRail = [[DockRail alloc] init];
    _outputRail.clipsToBounds = YES;
    [self addSubview:_outputRail];
    __weak WindowOutput *view = self;
    NSMenu *dockMenu = [[NSMenu alloc] initWithTitle:@"Output"];
    for (NSString *title in @[@"Dock Bottom", @"Dock Left", @"Dock Right", @"Dock Top"]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(chooseOutputDock:) keyEquivalent:@""];
        item.target = self;
        item.tag = dockMenu.numberOfItems;
        [dockMenu addItem:item];
    }
    _outputTab = [self addDockTab:@"Output" page:DockPage::Output menu:dockMenu];
    _errorsTab = [self addDockTab:@"0 Errors" page:DockPage::Errors menu:dockMenu];
    _debugTab = [self addDockTab:@"Debug" page:DockPage::Debug menu:dockMenu];
    _outputDivider = [[DockDivider alloc] init];
    _outputDivider.resize = ^(CGFloat delta, BOOL finished) { [view resizeOutputBy:delta finished:finished]; };
    _outputDivider.hidden = YES;
    [self addSubview:_outputDivider];
    [self readDockPlacement];

    _language = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_language addItemWithTitle:@"Auto Detect"];
    _language.lastItem.tag = -1;
    NSMenuItem *separator = NSMenuItem.separatorItem;
    separator.tag = -2;
    [_language.menu addItem:separator];
    NSArray<NSString *> *names = EditorLanguageNames();
    [_language addItemWithTitle:names.firstObject];
    for (NSString *name in [[names subarrayWithRange:NSMakeRange(1, names.count - 1)]
                           sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        [_language addItemWithTitle:name];
        _language.lastItem.tag = [names indexOfObject:name];
    }
    _language.bordered = NO;
    _language.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _language.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    _language.action = @selector(chooseLanguage:);
    _language.accessibilityLabel = @"Language";
    _language.toolTip = @"Language (Auto Detect)";
    [_statusBar addSubview:_language];

    [self updateEditorSettings];
    return self;
}

- (void)attachTo:(NSView *)content editorPane:(NSView *)editorPane
{
    if (self.superview == content)
        return;

    [self removeFromSuperview];
    _editorPane = editorPane;
    self.frame = content.bounds;
    [content addSubview:self positioned:NSWindowAbove relativeTo:editorPane];
    self.needsLayout = YES;
}

- (NSView *)hitTest:(NSPoint)point
{
    NSView *view = [super hitTest:point];
    return view == self ? nil : view;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    (void)oldSize;
    self.needsLayout = YES;
}

- (void)setHost:(EditorWindow *)host
{
    if (_host == host)
        return;

    [self cancelCheck];
    CodeView *previous = _host.editor;
    _host = host;
    [self updateEditorStatus];
    [self updateEditorSettings];
    [self updateLanguageStatus];
    CodeView *editor = host.editor;
    if (editor && (previous.theme != editor.theme || ![previous.editorFont isEqual:editor.editorFont]))
        [self updateConsoleAppearance];
    [self refreshDebugControls];
    if (!host)
        [self setCheckResult:{} source:nil];
}

- (void)updateEditorSettings
{
    EditorWindow *host = _host;
    _language.target = host;
    _languageStatus.target = host;
    _indentationButton.target = host;
    _language.hidden = !host;
    _languageStatus.hidden = !host;
    _indentationButton.hidden = !host;
    _encoding.hidden = !host;
    if (host) {
        [_language selectItemWithTag:host.languageMode];
        _language.toolTip = host.automaticLanguageMode ? @"Language (Auto Detect)" : @"Language";
        Indentation indentation = host.indentation;
        NSUInteger width = indentation.tabs ? indentation.tabWidth : indentation.width;
        _indentationButton.title = [NSString stringWithFormat:indentation.tabs ? @"Tabs: %lu" : @"Spaces: %lu", (unsigned long)width];
        _indentationButton.toolTip = host.hasFileIndentation ? @"Indentation saved for this file." : @"Indentation for this file.";
    }
    self.needsLayout = YES;
}

- (void)updateConsoleAppearance
{
    if (CodeView *editor = _host.editor) {
        for (OutputPane *pane : {_pane, _errorsPane, _debugPane.console})
            [pane applyFont:editor.editorFont rendering:editor.rendering dark:editor.theme->dark];
    }
}

- (void)updateEditorStatus
{
    CodeView *editor = _host.activeEditor;
    if (!editor) {
        _position.stringValue = @"";
        _position.toolTip = nil;
        return;
    }

    SyntaxBuffer *buffer = editor.syntax;
    NSUInteger caret = std::min(editor.vimDisplayedCursor, editor.string.length);
    NSUInteger line = [buffer lineForOffset:caret];
    NSUInteger start = [buffer offsetForLine:line];
    NSString *position = [NSString stringWithFormat:@"Line %lu, Col %lu",
                          (unsigned long)line + 1, (unsigned long)(caret - start + 1)];
    if (editor.cursorCount > 1)
        position = [NSString stringWithFormat:@"%@     %lu cursors", position, (unsigned long)editor.cursorCount];
    NSError *saveError = [(SourceDocument *)editor.vimDocument autoSaveError];
    if (saveError || _position.toolTip)
        _position.toolTip = saveError.localizedDescription;
    if (saveError)
        position = [position stringByAppendingString:@"     Auto Save Failed"];
    NSUInteger promptCaret = editor.vimCommandCaret;
    if (promptCaret != NSNotFound) {
        NSString *text = [editor.vimStatus stringByAppendingString:@" "];
        NSMutableAttributedString *prompt = [[NSMutableAttributedString alloc] initWithString:text
            attributes:@{NSFontAttributeName:[NSFont fontWithName:@"Menlo" size:10],
                         NSForegroundColorAttributeName:_position.textColor}];
        if (promptCaret < prompt.length)
            [prompt addAttribute:NSBackgroundColorAttributeName
                           value:SRGBColor(editor.theme->accents.commandCaret) range:NSMakeRange(promptCaret, 1)];
        _position.attributedStringValue = prompt;
    } else if (editor.vimCommandLine)
        _position.stringValue = editor.vimStatus;
    else if (editor.vimEnabled)
        _position.stringValue = [NSString stringWithFormat:@"%@     %@", editor.vimStatus, position];
    else
        _position.stringValue = position;
}

- (void)updateLanguageStatus
{
    LSPDocument *document = _host.editor.syntax.languageDocument;
    NSString *detail = document.status;
    NSString *title = @"LSP";
    NSColor *ink = NSColor.textColor;
    if (document) {
        switch (document.state) {
        case LSPState::Starting: title = @"LSP: Starting…"; break;
        case LSPState::Ready: title = @"LSP: Ready"; break;
        case LSPState::Missing: title = document.canInstall ? @"Install LSP" : @"Configure LSP…"; break;
        case LSPState::Installing: title = [detail hasPrefix:@"Downloading"] ? @"Downloading LSP…" : @"Installing LSP…"; break;
        case LSPState::Uninstalling: title = @"Uninstalling LSP…"; break;
        case LSPState::Failed:
            title = document.failureTitle;
            if (!title)
                title = @"LSP: Failed";
            ink = NSColor.systemRedColor;
            break;
        case LSPState::Stopped: title = @"LSP: Stopped"; break;
        }
    }
    if (![_languageStatus.title isEqualToString:title]) {
        _languageStatus.title = title;
        self.needsLayout = YES;
    }
    _languageStatus.contentTintColor = ink;
    _languageStatus.toolTip = document ? [NSString stringWithFormat:@"%@ — %@", document.serverName, detail ? detail : title] :
        @"Save the file to connect a language server.";
    _languageStatus.accessibilityLabel = title;
}

- (void)readDockPlacement
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger edge = [defaults integerForKey:@"OutputDockEdge"];
    _dockSide = edge >= 0 && edge <= NSInteger(DockSide::Top) ? DockSide(edge) : DockSide::Bottom;
    CGFloat width = [defaults doubleForKey:@"OutputDockWidth"];
    CGFloat height = [defaults doubleForKey:@"OutputDockHeight"];
    _dockWidth = std::isfinite(width) && width >= 74 ? width : 282;
    _dockHeight = std::isfinite(height) && height >= 74 ? height : 172;
}

- (DockTab *)addDockTab:(NSString *)title page:(DockPage)page menu:(NSMenu *)menu
{
    DockTab *tab = [[DockTab alloc] initWithFrame:NSZeroRect];
    tab.title = title;
    tab.target = self;
    tab.action = @selector(toggleDockTab:);
    tab.tag = NSInteger(page);
    [tab setButtonType:NSButtonTypePushOnPushOff];
    tab.bezelStyle = NSBezelStyleAccessoryBar;
    tab.controlSize = NSControlSizeSmall;
    tab.clipsToBounds = YES;
    tab.menu = menu;
    __weak WindowOutput *view = self;
    tab.track = ^(NSPoint point, BOOL finished) { [view dragOutputTab:point finished:finished]; };
    [_outputRail addSubview:tab];
    return tab;
}

- (void)moveOutputDock:(DockSide)side
{
    if (_dockSide != side) {
        _dockSide = side;
        [NSUserDefaults.standardUserDefaults setInteger:NSInteger(side) forKey:@"OutputDockEdge"];
        self.needsLayout = YES;
        [self.superview layoutSubtreeIfNeeded];
    }
}

- (IBAction)chooseOutputDock:(NSMenuItem *)sender
{
    [self moveOutputDock:DockSide(sender.tag)];
}

- (void)dragOutputTab:(NSPoint)point finished:(BOOL)finished
{
    NSRect body = [self editorBody];
    NSPoint local = [self convertPoint:point fromView:nil];
    std::optional<DockSide> side;
    if (NSPointInRect(local, NSInsetRect(self.bounds, -5, -5))) {
        local.x = std::clamp(local.x, NSMinX(body), NSMaxX(body));
        local.y = std::clamp(local.y, NSMinY(body), NSMaxY(body));
        side = DockSideAtPoint(body, local);
    }
    if (finished) {
        _dropTarget.hidden = YES;
        if (side)
            [self moveOutputDock:*side];
        return;
    }
    if (side && !_dropTarget) {
        _dropTarget = [[DockDropTarget alloc] init];
        [self addSubview:_dropTarget positioned:NSWindowAbove relativeTo:nil];
    }
    _dropTarget.hidden = !side;
    if (side) {
        DockPage page = _page == DockPage::Hidden ? DockPage::Output : _page;
        _dropTarget.frame = LayoutDock(body, *side, page, DockIsSide(*side) ? _dockWidth : _dockHeight).output;
    }
}

- (void)resizeOutputBy:(CGFloat)delta finished:(BOOL)finished
{
    bool horizontal = DockIsSide(_dockSide);
    CGFloat &extent = horizontal ? _dockWidth : _dockHeight;
    NSRect body = [self editorBody];
    NSRect pane = LayoutDock(body, _dockSide, _page, extent).output;
    CGFloat shown = horizontal ? NSWidth(pane) : NSHeight(pane);
    if (!shown)
        return;

    CGFloat sign = (_dockSide == DockSide::Top || _dockSide == DockSide::Right) ? -1 : 1;
    if (delta) {
        DockFrames next = LayoutDock(body, _dockSide, _page, shown + sign * delta);
        extent = horizontal ? NSWidth(next.output) : NSHeight(next.output);
        self.needsLayout = YES;
        [self.superview layoutSubtreeIfNeeded];
    }
    if (finished)
        [NSUserDefaults.standardUserDefaults setDouble:extent forKey:horizontal ? @"OutputDockWidth" : @"OutputDockHeight"];
}

- (void)updateErrorsTab
{
    NSUInteger count = _errorCount;
    NSUInteger warnings = _warningCount;
    NSString *title = count ? [NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? @"Error" : @"Errors"] :
        warnings ? [NSString stringWithFormat:@"%lu %@", (unsigned long)warnings, warnings == 1 ? @"Warning" : @"Warnings"] : @"0 Errors";
    if (![_errorsTab.title isEqualToString:title]) {
        _errorsTab.title = title;
        self.needsLayout = YES;
    }
}

- (void)attachDockView:(NSView *)view console:(OutputPane *)console shown:(BOOL)shown
{
    view.hidden = !shown;
    if (!view || view.superview == self)
        return;

    [view removeFromSuperview];
    [self addSubview:view positioned:NSWindowBelow relativeTo:_outputRail];
    if (CodeView *editor = _host.editor)
        [console applyFont:editor.editorFont rendering:editor.rendering dark:editor.theme->dark];
}

- (void)attachDockPanes
{
    for (DockPage page : {DockPage::Output, DockPage::Errors}) {
        bool diagnostics = page == DockPage::Errors;
        BOOL shown = _page == page;
        OutputPane *pane = diagnostics ? _errorsPane : _pane;
        if (!pane && shown) {
            pane = [[OutputPane alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(self.bounds), 160) diagnostics:diagnostics];
            __weak WindowOutput *output = self;
            pane.openLocation = ^(const RunLocation &location, SourceDocument *source) {
                [output openRunLocation:location source:source];
            };
            if (diagnostics) {
                _errorsPane = pane;
            } else {
                pane.sendInput = ^BOOL(NSString *line) { return [output.runner sendInput:line]; };
                _pane = pane;
            }
        }
        [self attachDockView:pane console:pane shown:shown];
    }
    BOOL showDebugger = _page == DockPage::Debug;
    DebugPane *debugger = _debugPane;
    if (showDebugger && !debugger) {
        debugger = [[DebugPane alloc] initWithFrame:NSZeroRect];
        __weak WindowOutput *output = self;
        debugger.command = ^(DebugCommand command) {
            if (EditorWindow *host = output.host) {
                [host performDebugCommand:command];
            } else if (command == DebugCommand::Stop) {
                [output stopDebug];
            } else {
                [output.debugSession performCommand:command];
            }
        };
        debugger.openLocation = ^(NSString *path, NSUInteger line) {
            [output openDebugLocation:path line:line column:1];
        };
        debugger.editBreakpoint = ^(NSString *path, NSUInteger line) { [output.host editBreakpoint:path line:line]; };
        debugger.console.openLocation = ^(const RunLocation &location, SourceDocument *source) {
            [output openRunLocation:location source:source];
        };
        _debugPane = debugger;
    }
    [self attachDockView:debugger console:debugger.console shown:showDebugger];
    _debugTab.state = showDebugger ? NSControlStateValueOn : NSControlStateValueOff;
    if (_page == DockPage::Errors)
        [self presentDiagnostics];
    _outputTab.state = self.shown ? NSControlStateValueOn : NSControlStateValueOff;
    _errorsTab.state = _page == DockPage::Errors ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshDebugControls];
}

- (IBAction)toggleDockTab:(NSButton *)sender
{
    [self toggleDockPage:DockPage(sender.tag)];
}

- (void)toggleDockPage:(DockPage)page
{
    [self showDockPage:_page == page ? DockPage::Hidden : page];
    if (self.shown && _runner && [_pane focusInput])
        _returnFocus = YES;
}

- (void)showDockPage:(DockPage)page
{
    if (_page == page)
        return;

    CodeView *source = _host.activeEditor;
    NSUInteger offset = std::min(source.vimDisplayedCursor, source.string.length);
    NSRect caret = source && page != DockPage::Hidden ? [source vimCaretAt:offset] : NSZeroRect;
    BOOL keepCaretVisible = !NSIsEmptyRect(caret) && NSIntersectsRect(caret, source.visibleRect);
    if (_pane.hasKeyboardFocus || _errorsPane.hasKeyboardFocus || _debugPane.hasKeyboardFocus)
        [self.window makeFirstResponder:source];

    _page = page;
    [self attachDockPanes];
    self.needsLayout = YES;
    [self.superview layoutSubtreeIfNeeded];
    if (keepCaretVisible && !NSContainsRect(source.visibleRect, caret))
        [source scrollRangeToVisible:NSMakeRange(offset, 0)];
}

- (void)openRunLocation:(const RunLocation &)location source:(SourceDocument *)source
{
    NSWindow *window = self.window;
    if (!window)
        return;

    if (source && source == _host.editor.vimDocument) {
        [source revealRunLocation:location];
        return;
    }
    if (source.editorHostWindow && [NSDocumentController.sharedDocumentController.documents containsObject:source]) {
        if (![source joinNavigationTabInWindow:window])
            return;
        [source showWindows];
        [source revealRunLocation:location];
        return;
    }
    if (location.file) {
        RunLocation target = location;
        __weak NSWindow *anchor = window;
        OpenSourceTab(target.file, window, ^(NSDocument *opened, BOOL, NSError *error) {
            if ([opened isKindOfClass:SourceDocument.class])
                [(SourceDocument *)opened revealRunLocation:target];
            else if (error)
                [anchor presentError:error];
        });
    }
}

- (void)openDebugLocation:(NSString *)path line:(NSUInteger)line column:(NSUInteger)column
{
    if (!path.isAbsolutePath || !line || ![NSFileManager.defaultManager fileExistsAtPath:path])
        return;
    NSURL *file = CanonicalFileURL([NSURL fileURLWithPath:path]);
    RunLocation location{file, line, column, 0, 0, false, false};
    CodeView *editor = _host.editor;
    SourceDocument *source = [editor.debugPath isEqualToString:file.path] ? (SourceDocument *)editor.vimDocument : nil;
    [self openRunLocation:location source:source];
}

- (void)refreshDebugControls
{
    EditorWindow *host = _host;
    [host refreshRunButton];
    _debugPane.session = _debugSession;
    SourceDocument *document = (SourceDocument *)host.editor.vimDocument;
    BOOL restartable = host && (_debugFile || _externalExecutable) && !document.workspace.runningDocument;
    [_debugPane updateStatus:_debugStatus building:_debugBuilder != nil restartable:restartable];
}

- (void)debugUpdated
{
    [self refreshDebugControls];
    [_host refreshDebugLocation];
    [_otherEditor refreshDebugLocation];
    NSDictionary *frame = _debugSession.frame;
    if (frame && frame != _navigatedFrame) {
        _navigatedFrame = frame;
        [self openDebugLocation:frame[@"source"][@"path"] line:[frame[@"line"] unsignedIntegerValue]
                         column:[frame[@"column"] unsignedIntegerValue]];
    } else if (_debugSession && _debugSession.phase == DebugPhase::Finished) {
        _navigatedFrame = nil;
        if (_restartDebug) {
            _restartDebug = NO;
            [_host startDebugTarget];
        } else {
            [_host resumeLanguageCheck];
        }
    }
}

static void PlaceDockTab(DockTab *button, NSRect frame, bool vertical)
{
    button.frameRotation = 0;
    if (vertical) {
        button.frame = NSMakeRect(NSMaxX(frame), NSMinY(frame), NSHeight(frame), NSWidth(frame));
        button.frameRotation = 90;
    } else {
        button.frame = frame;
    }
}

static NSRect NextDockTab(NSRect tab, CGFloat length, CGFloat railWidth, bool vertical)
{
    if (vertical) {
        CGFloat end = std::max(0.0, NSMinY(tab) - 3);
        tab.size.height = std::min(length, end);
        tab.origin.y = end - tab.size.height;
    } else {
        tab.origin.x = NSMaxX(tab) + 3;
        tab.size.width = std::clamp(railWidth - tab.origin.x, 0.0, length);
    }
    return tab;
}

- (NSRect)editorBody
{
    NSRect body = self.bounds;
    CGFloat height = std::min(statusHeight, NSHeight(body));
    body.origin.y += height;
    body.size.height -= height;
    return body;
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    bool vertical = DockIsSide(_dockSide);
    DockFrames dock = LayoutDock([self editorBody], _dockSide, _page, vertical ? _dockWidth : _dockHeight);
    if (!NSEqualRects(_editorPane.frame, dock.editor))
        _editorPane.frame = dock.editor;
    CGFloat chromeHeight = statusHeight + (_dockSide == DockSide::Bottom ? NSHeight(dock.rail) : 0);
    _statusBar.frame = NSMakeRect(0, 0, width, chromeHeight);
    if (_outputRail.side != _dockSide) {
        _outputRail.side = _dockSide;
        [_outputRail setNeedsDisplay:YES];
    }
    _outputRail.frame = dock.rail;
    NSRect tab = NSOffsetRect(dock.tab, -NSMinX(dock.rail), -NSMinY(dock.rail));
    CGFloat railWidth = NSWidth(dock.rail);
    NSRect errors = NextDockTab(tab, std::max(74.0, std::ceil(_errorsTab.fittingSize.width)), railWidth, vertical);
    NSRect debug = NextDockTab(errors, 68, railWidth, vertical);
    PlaceDockTab(_outputTab, tab, vertical);
    PlaceDockTab(_errorsTab, errors, vertical);
    PlaceDockTab(_debugTab, debug, vertical);
    _outputDivider.hidden = NSIsEmptyRect(dock.divider);
    _outputDivider.vertical = vertical;
    _outputDivider.frame = dock.divider;
    switch (_page) {
    case DockPage::Output:
        _pane.frame = dock.output;
        break;
    case DockPage::Errors:
        _errorsPane.frame = dock.output;
        break;
    case DockPage::Debug:
        _debugPane.frame = dock.output;
        break;
    case DockPage::Hidden:
        break;
    }

    if (!_host)
        return;

    CGFloat languageWidth = [_language.titleOfSelectedItem sizeWithAttributes:@{NSFontAttributeName:_language.font}].width;
    languageWidth = std::clamp(std::ceil(languageWidth) + 30, 97.0, 166.0);
    CGFloat indentationWidth = 80;
    CGFloat lspWidth = std::clamp(std::ceil(_languageStatus.fittingSize.width) + 10, 54.0, 129.0);
    CGFloat languageRight = width - 59;
    constexpr CGFloat positionSpace = 90;
    CGFloat scale = std::clamp((languageRight - positionSpace) / (languageWidth + indentationWidth + lspWidth), 0.0, 1.0);
    languageWidth = std::floor(languageWidth * scale);
    indentationWidth = std::floor(indentationWidth * scale);
    lspWidth = std::floor(lspWidth * scale);

    CGFloat languageLeft = languageRight - languageWidth;
    CGFloat indentationLeft = languageLeft - indentationWidth - 3;
    CGFloat lspLeft = indentationLeft - lspWidth - 3;
    _position.frame = NSMakeRect(9, 2, std::max(0.0, lspLeft - 13), 15);
    _languageStatus.frame = NSMakeRect(lspLeft, 1, lspWidth, 20);
    _indentationButton.frame = NSMakeRect(indentationLeft, 1, indentationWidth, 20);
    _encoding.frame = NSMakeRect(width - 57, 4, 50, 14);
    _language.frame = NSMakeRect(languageLeft, 1, languageWidth, 20);
}

- (BOOL)shown { return _page == DockPage::Output; }
- (BOOL)debugging { return _debugBuilder || (_debugSession && _debugSession.phase != DebugPhase::Finished); }

- (void)stopDebug
{
    _restartDebug = NO;
    [_debugBuilder stop];
    [_debugSession stop];
}

- (void)setShown:(BOOL)shown
{
    if (shown || self.shown)
        [self showDockPage:shown ? DockPage::Output : DockPage::Hidden];
}

- (void)observeTabGroup:(NSWindowTabGroup *)group
{
    if (_tabGroup == group)
        return;
    [_tabGroup removeObserver:self forKeyPath:@"selectedWindow" context:&selectedOutputTabContext];
    _tabGroup = group;
    [group addObserver:self forKeyPath:@"selectedWindow" options:0 context:&selectedOutputTabContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &selectedOutputTabContext)
        SyncNativeTabOutput([(NSWindowTabGroup *)object selectedWindow]);
    else
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)finishRun
{
    EditorWindow *host = self.host;
    [_pane setInputEnabled:NO];
    if (_returnFocus && _pane.hasKeyboardFocus)
        [self.window makeFirstResponder:host.activeEditor];
    _runner = nil;
    if (_runWorkspace.runningDocument == _source)
        _runWorkspace.runningDocument = nil;
    _runWorkspace = nil;
    [self refreshDebugControls];
    [host resumeLanguageCheck];
}

- (void)armCheckTimer:(NSTimeInterval)delay
{
    if (_checkTimer) {
        _checkTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:delay];
        return;
    }
    __weak WindowOutput *output = self;
    _checkTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        WindowOutput *dock = output;
        if (dock && dock->_checkTimer == timer) {
            dock->_checkTimer = nil;
            [dock.host startPendingLanguageCheck];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_checkTimer forMode:NSRunLoopCommonModes];
}

- (void)cancelCheck
{
    [_checkTimer invalidate];
    _checkTimer = nil;
    [_checkRunner stop];
}

- (void)setCheckResult:(CheckResult)result source:(SourceDocument *)source
{
    _errorCount = result.errors;
    _warningCount = result.warnings;
    _diagnosticsSource = source;
    _pendingDiagnostics = std::move(result.diagnostics);
    if (_page == DockPage::Errors)
        [self presentDiagnostics];
    [self updateErrorsTab];
}

- (void)presentDiagnostics
{
    if (_errorsPane && _pendingDiagnostics) {
        [_errorsPane showDiagnostics:*_pendingDiagnostics source:_diagnosticsSource];
        _pendingDiagnostics.reset();
    }
}

- (void)dealloc
{
    [_tabGroup removeObserver:self forKeyPath:@"selectedWindow" context:&selectedOutputTabContext];
    [_runner stop];
    [self stopDebug];
    [self cancelCheck];
}

@end

@implementation EditorWindow {
    __weak SourceDocument *_document;
    SyntaxBuffer *_buffer;
    NSScrollView *_scroll;
    Gutter *_gutter;
    NSView *_paneContent;
    NSSplitView *_splitView;
    EditorWindow *_secondPane;
    __weak EditorWindow *_splitParent;
    DockSide _splitSide;
    __weak WindowOutput *_windowOutput;
    __weak WindowOutput *_runningOutput;
    __weak NSView *_tabFocus;
    NSURL *_languageWorkspace;
    NSUInteger _laidOutLineCount;
    BOOL _scrollUpdatePending;
    BOOL _automaticLanguageMode;
    BOOL _detectLanguageFromContent;
    BOOL _needsLanguageCheck;
    std::optional<CheckResult> _languageCheckResult;
    NSUInteger _languageCheckVersion;
}

- (instancetype)initWithDocument:(SourceDocument *)document text:(NSString *)text language:(Language)language
{
    return [self initWithDocument:document text:text language:language buffer:nil parent:nil];
}

- (instancetype)initWithDocument:(SourceDocument *)document text:(NSString *)text language:(Language)language
                         buffer:(SyntaxBuffer *)buffer parent:(EditorWindow *)parent
{
    self = [super initWithFrame:NSMakeRect(0, 0, 840, 648)];
    if (!self)
        return nil;

    _document = document;
    _splitParent = parent;
    _automaticLanguageMode = YES;
    _detectLanguageFromContent = LanguageForSource(document.fileURL) == Language::Plain;
    _buffer = buffer ? buffer : [[SyntaxBuffer alloc] init];
    if (!buffer) {
        if (auto indentation = FileIndentationPreference(document.fileURL))
            [_buffer setFileIndentation:*indentation];
    }
    _buffer.language = language;
    _editor = CreateCodeView(_buffer, text);
    _editor.vimDocument = document;
    _editor.allowsUndo = YES;
    _editor.usesFindBar = YES;
    _editor.delegate = self;
    __weak EditorWindow *pane = self;
    _editor.revealError = ^(const BuildError &error) { [pane showDiagnostic:error]; };

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.borderType = NSNoBorder;
    _scroll.scrollerStyle = NSScrollerStyleLegacy;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.documentView = _editor;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [self addSubview:_scroll];

    _gutter = [[Gutter alloc] initWithFrame:NSZeroRect];
    _gutter.editor = _editor;
    _gutter.buffer = _buffer;
    _editor.debugPath = DebugSourcePath(document.fileURL);
    _buffer.breakpointPath = _editor.debugPath;
    __weak EditorWindow *debugEditor = parent ? parent : self;
    _gutter.editBreakpoint = ^(NSString *path, NSUInteger line) { [debugEditor editBreakpoint:path line:line]; };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(breakpointChanged:)
                                               name:DebugBreakpointsChanged object:nil];
    [self addSubview:_gutter];

    if (!parent)
        _needsLanguageCheck = CheckableLanguage(language);

    __weak EditorWindow *root = self;
    _editor.vimStatusChanged = ^{
        [root vimStatusChanged];
    };
    _editor.vimAction = ^(Vim::Action action, NSString *argument, BOOL force) {
        [root performEditorAction:action argument:argument force:force];
    };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrollMoved:)
                                               name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrollTracking:)
                                               name:NSScrollViewDidLiveScrollNotification object:_scroll];
    if (!parent) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged:)
                                                   name:EditorPreferencesChanged object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(unusedWarningsChanged:)
                                                   name:UnusedWarningsPreferencesChanged object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inlaySettingsChanged:)
                                                   name:InlayPreferencesChanged object:nil];
    }
    [self applyPreferences];
    self.needsLayout = YES;
    return self;
}

- (CodeView *)activeEditor
{
    CodeView *second = _secondPane.editor;
    NSResponder *focus = self.window.firstResponder;
    BOOL useSecond = focus == second || second.hoverHasFocus || (focus != _editor && _tabFocus == second);
    return _splitView && useSecond ? second : _editor;
}

- (BOOL)isRunning { return _windowOutput.runner != nil; }
- (BOOL)canRun
{
    Language language = _buffer.language;
    NSString *name = _document.fileURL.lastPathComponent.lowercaseString;
    if ((language == Language::TypeScript && ([name hasSuffix:@".d.ts"] || [name hasSuffix:@".d.mts"] ||
                                              [name hasSuffix:@".d.cts"])) ||
        (language == Language::Python && [name hasSuffix:@".pyi"]))
        return NO;
    if (language == Language::VisualBasic)
        return [_document.fileURL.pathExtension.lowercaseString isEqualToString:@"vb"];
    if (language == Language::Assembly)
        return !_document.fileURL || DebuggableLanguage(language, _document.fileURL);
    if (RunnableLanguage(language))
        return YES;
    return language == Language::Plain && _document.workspace && !_document.fileURL && !_buffer.storage.length;
}
- (Indentation)indentation { return _buffer.indentation; }
- (BOOL)hasFileIndentation { return _buffer.hasFileIndentation; }
- (NSInteger)languageMode { return NSInteger(_buffer.language); }
- (BOOL)automaticLanguageMode { return _automaticLanguageMode; }

- (void)setFileIndentation:(Indentation)indentation
{
    [_buffer setFileIndentation:indentation];
    SetFileIndentationPreference(_document.fileURL, indentation);
    [self applyPreferences];
}

- (void)detectFileIndentation
{
    [self setFileIndentation:DetectIndentation(_buffer.storage.string, DefaultIndentation(IndentationPreference()))];
}

- (void)resetFileIndentation
{
    SetFileIndentationPreference(_document.fileURL, std::nullopt);
    [_buffer resetFileIndentation];
    [self applyPreferences];
}

- (void)convertIndentationToTabs:(BOOL)tabs
{
    CodeView *editor = self.activeEditor;
    if (!editor.editable || self.hasMarkedEditorText)
        return;
    Indentation indentation = _buffer.indentation;
    indentation.tabs = tabs;
    auto edits = IndentationConversion(_buffer.storage.string, indentation);
    if ([editor applyDocumentEdits:std::move(edits) undoName:@"Convert Indentation" options:{}])
        [self setFileIndentation:indentation];
}

- (IBAction)showIndentationMenu:(NSButton *)sender
{
    SourceDocument *document = _document;
    if (!document)
        return;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Indentation"];
    for (NSMenuItem *item in FileIndentationCommands(document)) {
        if (item.action == @selector(setIndentationAsDefault:))
            [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:item];
    }
    [menu insertItem:NSMenuItem.separatorItem atIndex:2];
    NSMenuItem *size = [[NSMenuItem alloc] initWithTitle:@"Tab Size" action:nullptr keyEquivalent:@""];
    size.submenu = TabSizeMenu(document.tabSize, document, @selector(setTabSize:));
    [menu insertItem:size atIndex:2];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(sender.bounds)) inView:sender];
}

- (void)rememberTabFocus
{
    NSResponder *focus = self.window.firstResponder;
    if ([focus isKindOfClass:NSView.class] && [(NSView *)focus isDescendantOf:self])
        _tabFocus = (NSView *)focus;
}

- (NSView *)tabFocus
{
    return _tabFocus && _tabFocus.window == self.window && !_tabFocus.hiddenOrHasHiddenAncestor ? _tabFocus : _editor;
}

- (void)setWindowOutput:(WindowOutput *)output
{
    if (_windowOutput == output)
        return;

    _windowOutput = output;
    [self refreshDebugLocation];
}

- (void)showDiagnostic:(const BuildError &)error
{
    EditorWindow *root = _splitParent ? _splitParent : self;
    WindowOutput *output = root->_windowOutput;
    if (output.host != root)
        [self.window makeFirstResponder:_editor];
    [output showDockPage:error.fromOutput ? DockPage::Output : DockPage::Errors];
    OutputPane *pane = error.fromOutput ? output.pane : output.errorsPane;
    [pane revealDiagnostic:error.location source:_document];
}

- (BOOL)hasDiagnostics
{
    return !_buffer.buildErrors.empty() || !_buffer.languageErrors.empty();
}

- (BOOL)viewErrorAtCursor
{
    if (_editor.hasHoveredError)
        return [_editor viewErrorAtCursor];
    if (_secondPane.editor.hasHoveredError)
        return [_secondPane.editor viewErrorAtCursor];
    return [self.activeEditor viewErrorAtCursor];
}

- (void)revealRunLocation:(const RunLocation &)location
{
    [_buffer finishHighlighting];
    if (location.utf16Columns) {
        NSUInteger offset = [_buffer languageOffset:{location.line ? location.line - 1 : 0, location.column ? location.column - 1 : 0}];
        if (offset != NSNotFound)
            [self.activeEditor visitVimFileMark:offset exact:YES];
        return;
    }
    NSRange line = SourceLine(_buffer, location.line);
    if (line.location == NSNotFound && location.line == _buffer.lineCount + 1) {
        [self.activeEditor visitVimFileMark:_buffer.storage.length exact:YES];
        return;
    }

    if (line.location != NSNotFound) {
        NSUInteger offset = DiagnosticColumn(_buffer.storage.string, line, location.column, location, _document.hasUTF8BOM);
        [self.activeEditor visitVimFileMark:offset exact:YES];
    }
}

- (BOOL)isRunSource
{
    WindowOutput *output = _runningOutput;
    return output.runner && output.source == _document;
}

- (void)stopRun
{
    if (self.isRunSource)
        [_runningOutput.runner stop];
}

- (NSUInteger)beginBuildDiagnostics
{
    [_buffer finishHighlighting];
    [_buffer clearBuildErrors];
    [_document resumePendingAutoSave];
    return _buffer.textVersion;
}

- (BOOL)hasBuildErrors
{
    auto isError = [](const BuildError &error) { return !error.warning; };
    return std::ranges::any_of(_buffer.buildErrors, isError) || std::ranges::any_of(_buffer.languageErrors, isError);
}
- (BOOL)hasMarkedEditorText { return _editor.hasMarkedText || _secondPane.editor.hasMarkedText; }

- (void)finishEditingForClose
{
    if (_editor.hasMarkedText)
        [_editor unmarkText];
    [_editor finishVimChange];
    [_editor breakUndoCoalescing];
    [_secondPane finishEditingForClose];
}

- (void)applyBuildMessages:(const std::vector<RunMessage> &)messages version:(NSUInteger)version
                     owner:(BOOL)owner fromOutput:(BOOL)fromOutput
{
    if (version != _buffer.textVersion)
        return;
    [_buffer finishHighlighting];
    NSURL *file = CanonicalFileURL(_document.fileURL);
    std::vector<BuildError> errors;
    BOOL hasBOM = _document.hasUTF8BOM;
    for (const auto &message : messages) {
        bool warning = !fromOutput && message.tone == OutputTone::Warning;
        if ((!message.diagnostic.length && fromOutput) || (message.tone != OutputTone::Error && !warning) ||
            !((owner && message.location.currentSource) || [file.path isEqualToString:message.location.file.path]))
            continue;
        NSRange range = BuildErrorRange(_buffer, message.location, hasBOM);
        if (range.location == NSNotFound)
            continue;
        bool unused = warning && IsHideableUnusedWarning(_buffer, range.location, message.diagnosticLabel, message.diagnostic);
        errors.push_back({range, message.diagnostic, warning, message.diagnosticLabel, message.location, fromOutput != NO, unused});
    }
    if (fromOutput)
        [_buffer addBuildErrors:errors];
    else
        [_buffer replaceCheckErrors:errors];
}

- (NSArray<SourceDocument *> *)documentsForBuild:(RunProject)project
{
    SourceDocument *document = _document;
    if (project.kind == RunKind::Source || project.kind == RunKind::Script)
        return document ? @[document] : @[];
    NSMutableArray<SourceDocument *> *documents = [NSMutableArray array];
    for (NSDocument *open in NSDocumentController.sharedDocumentController.documents) {
        if ([open isKindOfClass:SourceDocument.class] &&
            PathIsInFolder(CanonicalFileURL(open.fileURL).path, project.folder.path))
            [documents addObject:(SourceDocument *)open];
    }
    if (document && ![documents containsObject:document])
        [documents addObject:document];
    return documents;
}

- (void)scheduleLanguageCheck
{
    if (_languageCheckResult) {
        _languageCheckResult.reset();
        [_buffer replaceCheckErrors:{}];
        [self updateLanguageDiagnostics];
    }
    _needsLanguageCheck = CheckableLanguage(_buffer.language);
    WindowOutput *dock = _windowOutput;
    if (dock.host != self)
        return;
    if (![self canQueueLanguageCheck]) {
        [dock cancelCheck];
        return;
    }
    [dock.checkRunner stop];
    [dock armCheckTimer:1];
}

- (BOOL)usesLocalCheck
{
    Language language = _buffer.language;
    if (!CheckableLanguage(language))
        return NO;

    LSPDocument *server = _buffer.languageDocument;
    if (server && server.state == LSPState::Starting)
        return NO;

    if (!server.handlesDiagnostics)
        return YES;

    // Cargo supplies compiler errors while rust-analyzer is still checking unsaved text.
    return language == Language::Rust && (server.changedSinceSave || _document.isDocumentEdited);
}

- (BOOL)canQueueLanguageCheck
{
    WindowOutput *dock = _windowOutput;
    return _needsLanguageCheck && dock.host == self && self.window.isKeyWindow && [self usesLocalCheck] &&
           !dock.runner && !dock.debugging && !_document.workspace.runningDocument;
}

- (void)resumeLanguageCheck
{
    WindowOutput *dock = _windowOutput;
    if ([self canQueueLanguageCheck] && !dock.checkTimer && (!dock.checkRunner || dock.checkRunner.isStopped))
        [dock armCheckTimer:1];
}

- (void)cancelLanguageCheck
{
    _needsLanguageCheck = NO;
    if (_windowOutput.host == self)
        [_windowOutput cancelCheck];
}

- (void)startPendingLanguageCheck
{
    WindowOutput *dock = _windowOutput;
    SourceDocument *owner = _document;
    if (!owner || ![self canQueueLanguageCheck] || dock.checkRunner || self.hasMarkedEditorText)
        return;

    NSURL *file = CanonicalFileURL(owner.fileURL);
    Language language = _buffer.language;
    bool odin = language == Language::Odin && file;
    RunProject project = language == Language::Rust || odin ? LocateRunProject(language, file, file ? owner.workspace.folder : nil) : RunProject{};
    bool cargo = project.kind == RunKind::Cargo;
    // Non-Cargo Rust projects are checked by their configured language server.
    if (language == Language::Rust && _buffer.languageDocument.handlesDiagnostics && !cargo) {
        _needsLanguageCheck = NO;
        return;
    }

    NSArray<SourceDocument *> *documents = cargo ? [self documentsForBuild:project] : @[owner];
    if (odin) {
        NSMutableArray<SourceDocument *> *package = [NSMutableArray arrayWithObject:owner];
        NSString *directory = file.URLByDeletingLastPathComponent.path;
        for (NSDocument *open in NSDocumentController.sharedDocumentController.documents) {
            if (open == owner || ![open isKindOfClass:SourceDocument.class])
                continue;

            NSURL *path = CanonicalFileURL(open.fileURL);
            if (LanguageForSource(path) == Language::Odin && [path.URLByDeletingLastPathComponent.path isEqualToString:directory])
                [package addObject:(SourceDocument *)open];
        }

        documents = package;
    }

    std::vector<CheckSource> sources;
    std::vector<BuildTarget> targets;
    sources.reserve(documents.count);
    targets.reserve(documents.count);
    for (SourceDocument *document in documents) {
        NSURL *path = CanonicalFileURL(document.fileURL);
        bool active = document == owner;
        targets.push_back({document, document.diagnosticVersion, active, path});
        if (active || (path && document.isDocumentEdited)) {
            NSString *text = document.sourceText;
            sources.push_back({path, document.hasUTF8BOM ? [@"\uFEFF" stringByAppendingString:text] : [text copy], !document.isDocumentEdited});
        }
    }

    SourceRunner *checker = [[SourceRunner alloc] init];
    dock.checkRunner = checker;
    if (cargo && !dock.checkCache)
        dock.checkCache = [[RustCheckCache alloc] init];
    __weak WindowOutput *output = dock;
    __weak EditorWindow *view = self;
    [checker checkProject:project language:language file:file name:file ? file.lastPathComponent : owner.displayName
                       sources:std::move(sources) cache:dock.checkCache finished:^(CheckResult result) {
        WindowOutput *console = output;
        if (console.checkRunner != checker)
            return;
        console.checkRunner = nil;
        EditorWindow *root = view;
        if (!checker.isStopped && root && console.host == root && root->_buffer.language == language &&
            [root usesLocalCheck]) {
            bool current = std::ranges::all_of(targets, [](const BuildTarget &target) {
                SourceDocument *source = target.document;
                NSURL *path = CanonicalFileURL(source.fileURL);
                return source && source.diagnosticVersion == target.version && (path == target.file || [path isEqual:target.file]);
            });
            if (current) {
                root->_needsLanguageCheck = NO;
                if (root->_buffer.languageDocument.handlesDiagnostics) {
                    // The language server can keep checking when Cargo cannot start, e.g. offline dependencies.
                    std::erase_if(result.diagnostics, [](const RunMessage &message) { return !message.location.line; });
                    result.errors = std::ranges::count_if(result.diagnostics, [](const RunMessage &message) {
                        return message.tone == OutputTone::Error;
                    });
                    result.warnings = result.diagnostics.size() - result.errors;
                }
                for (const auto &target : targets) {
                    if (target.owner || odin || (cargo && [target.file.pathExtension.lowercaseString isEqualToString:@"rs"]))
                        [target.document applyBuildMessages:result.diagnostics version:target.version owner:target.owner fromOutput:NO];
                }
                root->_languageCheckResult = std::move(result);
                root->_languageCheckVersion = root->_buffer.textVersion;
                [root updateLanguageDiagnostics];
            }
        }
        [console.host resumeLanguageCheck];
    }];
}

- (void)launchRun:(RunProject)project language:(Language)language file:(NSURL *)file output:(WindowOutput *)output
        documents:(NSArray<SourceDocument *> *)documents startingFocus:(NSResponder *)focus
{
    SourceRunner *runner = output.runner;
    NSString *name = file ? file.lastPathComponent : _document.displayName;
    NSString *text = nil;
    if (project.kind == RunKind::Source && (!file || _document.isDocumentEdited || language == Language::Odin)) {
        text = _buffer.storage.string;
        if (_document.hasUTF8BOM)
            text = [@"\uFEFF" stringByAppendingString:text];
    }
    std::vector<BuildTarget> targets;
    targets.reserve(documents.count);
    for (SourceDocument *document in documents)
        targets.push_back({document, [document beginBuildDiagnostics], document == _document});

    NSUInteger version = _buffer.textVersion;
    __weak EditorWindow *view = self;
    __weak WindowOutput *windowOutput = output;
    __weak SourceDocument *source = _document;
    __weak NSResponder *startingFocus = focus;
    runner.inputReady = ^{
        WindowOutput *console = windowOutput;
        [console.pane setInputEnabled:YES];
        EditorWindow *root = view;
        if (root && console.host == root && root.window.isKeyWindow && root->_buffer.textVersion == version &&
            (root.window.firstResponder == root.activeEditor || root.window.firstResponder == startingFocus))
            console.returnFocus = [console.pane focusInput];
    };
    [runner startProject:project language:language file:file name:name ? name : @"Untitled" workingText:text
                  output:^(const std::vector<RunMessage> &messages) {
        [windowOutput.pane appendMessages:messages source:source];
        if (std::ranges::any_of(messages, [](const RunMessage &message) {
            return message.tone == OutputTone::Error && message.location.line;
        })) {
            for (const auto &target : targets)
                [target.document applyBuildMessages:messages version:target.version owner:target.owner fromOutput:YES];
        }
    } finished:^{
        [windowOutput finishRun];
    }];
}

- (RunButtonAction)runCommand
{
    if (_windowOutput.debugSession.phase == DebugPhase::Paused)
        return RunButtonAction::Continue;
    if (self.running || self.isRunSource || _document.workspace.runningDocument || _windowOutput.debugging)
        return RunButtonAction::Stop;
    return RunButtonAction::Run;
}

- (BOOL)canRunCommand
{
    DebugSession *session = _windowOutput.debugSession;
    switch (self.runCommand) {
    case RunButtonAction::Continue:
        return session.threadID != nil;
    case RunButtonAction::Stop:
        return session.phase != DebugPhase::Stopping;
    case RunButtonAction::Run:
        return self.canRun || (DebuggableLanguage(_buffer.language, _document.fileURL) &&
                              HasEnabledBreakpoint(DebugBreakpoints(_editor.debugPath)));
    }
}

- (void)refreshRunButton
{
    NSButton *button = self.runButton;
    if (button) {
        SetRunButton(button, self.runCommand);
        SetTitleDebugButton(button, _windowOutput.debugSession.phase);
        button.enabled = self.canRunCommand;
    }
}

- (NSUInteger)debugCursorLine
{
    [_buffer finishHighlighting];
    CodeView *editor = self.activeEditor;
    return [_buffer lineForOffset:std::min(editor.vimDisplayedCursor, editor.string.length)] + 1;
}

- (BOOL)canDebugCommand:(DebugCommand)command
{
    WindowOutput *dock = _windowOutput;
    if (!dock || self.window.attachedSheet)
        return NO;
    DebugSession *session = dock.debugSession;
    BOOL available = !dock.runner && !_document.workspace.runningDocument;
    BOOL paused = session && session.phase == DebugPhase::Paused;
    BOOL stopping = session && session.phase == DebugPhase::Stopping;
    BOOL hasTarget = dock.debugFile || dock.externalExecutable;
    switch (command) {
    case DebugCommand::Continue:
        return paused || (!dock.debugging && available && (DebuggableLanguage(_buffer.language, _document.fileURL) || hasTarget));
    case DebugCommand::StepOver:
    case DebugCommand::StepInto:
    case DebugCommand::StepOut:
        return paused && session.threadID;
    case DebugCommand::Pause:
        return session && session.phase == DebugPhase::Running;
    case DebugCommand::Restart:
        return available && hasTarget && !stopping && !session.attached;
    case DebugCommand::Stop:
        return dock.debugging && !stopping;
    case DebugCommand::ToggleBreakpoint:
    case DebugCommand::EditBreakpoint:
        return _editor.debugPath.length > 0;
    case DebugCommand::RunToCursor:
        return paused && session.threadID && _editor.debugPath.length > 0;
    case DebugCommand::ChooseExecutable:
    case DebugCommand::Attach:
    case DebugCommand::Arguments:
        return available && !dock.debugging;
    case DebugCommand::ShowPane:
        return YES;
    }
}

- (void)breakpointChanged:(NSNotification *)notification
{
    NSString *path = notification.object;
    if ([_editor.debugPath isEqualToString:path]) {
        [_gutter setNeedsDisplay:YES];
        [self refreshRunButton];
    }
    if (_windowOutput.host == self) {
        [_windowOutput.debugSession sendBreakpoints:path];
        [_windowOutput.debugPane breakpointsChanged];
    }
}

- (void)refreshDebugLocation
{
    DebugSession *session = _windowOutput.debugSession;
    NSString *file = DebugSourcePath(_document.fileURL);
    _editor.debugPath = file;
    _buffer.breakpointPath = file;
    _secondPane.editor.debugPath = file;
    NSDictionary *frame = session.frame;
    NSString *path = frame[@"source"][@"path"];
    NSUInteger line = 0;
    if (session.phase == DebugPhase::Paused && path.isAbsolutePath &&
        [file isEqualToString:DebugSourcePath([NSURL fileURLWithPath:path])]) {
        line = [frame[@"line"] unsignedIntegerValue];
    }
    [_editor showDebugLine:line exception:line ? session.exception : nil];
    [_secondPane.editor showDebugLine:line exception:line ? session.exception : nil];
    _gutter.debugSession = _windowOutput.debugging ? session : nil;
    [_gutter refreshBreakpointHover];
    [_gutter setNeedsDisplay:YES];
    if (_secondPane) {
        _secondPane->_gutter.debugSession = _gutter.debugSession;
        [_secondPane->_gutter refreshBreakpointHover];
        [_secondPane->_gutter setNeedsDisplay:YES];
    }
}

- (void)startDebugSession:(DebugExecutable *)executable pid:(pid_t)pid
{
    WindowOutput *dock = _windowOutput;
    DebugSession *session = [[DebugSession alloc] initWithExecutable:executable arguments:dock.debugArguments
                                                           language:dock.debugLanguage pid:pid];
    dock.debugSession = session;
    dock.debugStatus = nil;
    dock.navigatedFrame = nil;
    __weak WindowOutput *weak = dock;
    __weak DebugSession *weakSession = session;
    session.output = ^(NSString *text, OutputTone tone) {
        [weak.debugPane.console appendMessages:{{text, tone, {}}} source:nil];
    };
    session.changed = ^{
        WindowOutput *output = weak;
        DebugSession *current = weakSession;
        if (output.debugSession != current)
            return;
        if (current.phase == DebugPhase::Finished && ([current.status isEqualToString:@"Debugging failed"] ||
            [current.status isEqualToString:@"Could not start LLDB"] || [current.status isEqualToString:@"Disconnected"]))
            [output.debugPane showConsole];
        [output debugUpdated];
    };

    [dock debugUpdated];
    [session start];
}

- (void)startDebugTarget
{
    WindowOutput *dock = _windowOutput;
    [dock cancelCheck];
    [dock showDockPage:DockPage::Debug];
    [dock.debugPane prepare];
    dock.debugSession = nil;
    dock.debugStatus = nil;
    if (dock.externalExecutable) {
        [self startDebugSession:dock.externalExecutable pid:0];
        return;
    }
    SourceDocument *source = dock.debugDocument;
    NSURL *file = source.fileURL ? CanonicalFileURL(source.fileURL) : dock.debugFile;
    Language language = dock.debugLanguage;
    RunProject project = LocateRunProject(language, file, dock.debugFolder);
    NSMutableArray<SourceDocument *> *documents = [[self documentsForBuild:project] mutableCopy];
    if (project.kind == RunKind::Source)
        [documents removeAllObjects];
    if (source && ![documents containsObject:source])
        [documents addObject:source];
    SourceRunner *runner = [[SourceRunner alloc] init];
    dock.debugBuilder = runner;
    dock.debugStatus = @"Building…";
    [dock refreshDebugControls];
    __weak WindowOutput *weak = dock;
    __weak SourceDocument *weakSource = source;
    SaveBuildDocuments(documents, 0, runner, ^(NSError *error) {
        WindowOutput *output = weak;
        if (!output || output.debugBuilder != runner)
            return;
        if (error || runner.isStopped) {
            output.debugBuilder = nil;
            if (output.restartDebug) {
                output.restartDebug = NO;
                [output.host startDebugTarget];
                return;
            }
            output.debugStatus = error ? @"Build failed" : @"Stopped";
            if (error) {
                [output.debugPane.console appendMessages:{{[error.localizedDescription stringByAppendingString:@"\n"],
                                                          OutputTone::Error, {}}} source:nil];
                [output.debugPane showConsole];
            }
            [output debugUpdated];
            [output.host resumeLanguageCheck];
            return;
        }
        [runner buildDebugProject:project language:language file:file output:^(const std::vector<RunMessage> &messages) {
            [weak.debugPane.console appendMessages:messages source:weakSource];
        } finished:^(DebugExecutable *executable) {
            WindowOutput *current = weak;
            if (!current || current.debugBuilder != runner)
                return;
            current.debugBuilder = nil;
            if (current.restartDebug) {
                current.restartDebug = NO;
                [current.host startDebugTarget];
            } else if (executable && !runner.isStopped && current.host) {
                [current.host startDebugSession:executable pid:0];
            } else {
                current.debugStatus = runner.isStopped ? @"Stopped" : @"Build failed";
                if (!runner.isStopped)
                    [current.debugPane showConsole];
                [current debugUpdated];
                [current.host resumeLanguageCheck];
            }
        }];
    });
}

- (void)debugAfterSave:(NSDocument *)document didSave:(BOOL)saved contextInfo:(void *)context
{
    (void)context;
    if (saved && document == _document && self.window)
        [self performDebugCommand:DebugCommand::Continue];
}

- (void)chooseDebugExecutable
{
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.title = @"Debug Executable";
    panel.prompt = @"Debug";
    panel.directoryURL = _document.workspace ? _document.workspace.folder : _document.fileURL.URLByDeletingLastPathComponent;
    __weak EditorWindow *weak = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        EditorWindow *editor = weak;
        if (response != NSModalResponseOK || !editor)
            return;
        NSURL *file = panel.URL;
        if ([file.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame)
            file = [NSBundle bundleWithURL:file].executableURL;
        if (!file || ![NSFileManager.defaultManager isExecutableFileAtPath:file.path]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Choose an executable file.";
            [alert beginSheetModalForWindow:editor.window completionHandler:nil];
            return;
        }
        WindowOutput *dock = editor->_windowOutput;
        dock.debugDocument = nil;
        dock.debugFile = nil;
        dock.debugLanguage = Language::Plain;
        dock.externalExecutable = [[DebugExecutable alloc] initWithFile:file directory:file.URLByDeletingLastPathComponent];
        [editor startDebugTarget];
    }];
}

- (void)attachDebugger
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Attach to Process";
    alert.informativeText = @"Enter the process ID.";
    [alert addButtonWithTitle:@"Attach"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 230, 24)];
    field.cell.scrollable = YES;
    field.placeholderString = @"PID";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    __weak EditorWindow *weak = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        EditorWindow *editor = weak;
        if (response != NSAlertFirstButtonReturn || !editor)
            return;
        NSScanner *scanner = [NSScanner scannerWithString:field.stringValue];
        int pid = 0;
        if (![scanner scanInt:&pid] || !scanner.isAtEnd || pid <= 1 || pid == NSProcessInfo.processInfo.processIdentifier) {
            NSAlert *invalid = [[NSAlert alloc] init];
            invalid.messageText = @"Enter a valid process ID.";
            [invalid beginSheetModalForWindow:editor.window completionHandler:nil];
            return;
        }
        WindowOutput *dock = editor->_windowOutput;
        dock.debugFile = nil;
        dock.debugDocument = nil;
        dock.debugLanguage = Language::Plain;
        dock.externalExecutable = nil;
        [dock cancelCheck];
        [dock showDockPage:DockPage::Debug];
        [dock.debugPane prepare];
        [editor startDebugSession:nil pid:pid];
    }];
}

- (void)editDebugArguments
{
    WindowOutput *dock = _windowOutput;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Program Arguments";
    alert.informativeText = @"Enter one argument per line.";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 280, 90)];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    NSTextView *field = [[NSTextView alloc] initWithFrame:scroll.bounds];
    field.autoresizingMask = NSViewWidthSizable;
    field.richText = NO;
    field.automaticQuoteSubstitutionEnabled = NO;
    field.automaticDashSubstitutionEnabled = NO;
    field.string = dock.debugArguments.count ? [dock.debugArguments componentsJoinedByString:@"\n"] : @"";
    scroll.documentView = field;
    alert.accessoryView = scroll;
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn)
            return;
        NSMutableArray *arguments = [[field.string componentsSeparatedByString:@"\n"] mutableCopy];
        if (arguments.count && ![arguments.lastObject length])
            [arguments removeLastObject];
        dock.debugArguments = arguments;
    }];
}

- (void)editBreakpoint:(NSString *)path line:(NSUInteger)line
{
    if (!path.length || !line || self.window.attachedSheet)
        return;
    NSDictionary *options = DebugBreakpoints(path)[@(line)];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@:%lu", path.lastPathComponent, line];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 290, 82)];
    NSTextField *condition = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 59, 289, 22)];
    condition.cell.scrollable = YES;
    condition.placeholderString = @"Condition";
    condition.stringValue = options[@"condition"] ? options[@"condition"] : @"";
    condition.accessibilityLabel = @"Condition";
    NSTextField *hits = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 31, 289, 22)];
    hits.cell.scrollable = YES;
    hits.placeholderString = @"Hit Count";
    hits.stringValue = options[@"hitCondition"] ? options[@"hitCondition"] : @"";
    hits.accessibilityLabel = @"Hit Count";
    NSButton *enabled = [NSButton checkboxWithTitle:@"Enabled" target:nil action:nil];
    enabled.frame = NSMakeRect(0, 3, 120, 20);
    enabled.state = [options[@"disabled"] boolValue] ? NSControlStateValueOff : NSControlStateValueOn;
    [fields addSubview:condition];
    [fields addSubview:hits];
    [fields addSubview:enabled];
    alert.accessoryView = fields;
    alert.window.initialFirstResponder = condition;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn)
            return;
        NSMutableDictionary *updated = [NSMutableDictionary dictionary];
        if (condition.stringValue.length)
            updated[@"condition"] = condition.stringValue;
        if (hits.stringValue.length)
            updated[@"hitCondition"] = hits.stringValue;
        if (enabled.state == NSControlStateValueOff)
            updated[@"disabled"] = @YES;
        SetDebugBreakpoint(path, line, updated);
    }];
}

- (void)performDebugCommand:(DebugCommand)command
{
    if (![self canDebugCommand:command])
        return;
    WindowOutput *dock = _windowOutput;
    switch (command) {
    case DebugCommand::Continue:
        if (dock.debugging) {
            [dock.debugSession performCommand:command];
        } else if (DebuggableLanguage(_buffer.language, _document.fileURL)) {
            if (!_document.fileURL) {
                [_document saveDocumentWithDelegate:self didSaveSelector:@selector(debugAfterSave:didSave:contextInfo:) contextInfo:nullptr];
                return;
            }
            dock.externalExecutable = nil;
            dock.debugDocument = _document;
            dock.debugFile = CanonicalFileURL(_document.fileURL);
            dock.debugFolder = _document.workspace.folder;
            dock.debugLanguage = _buffer.language;
            [self startDebugTarget];
        } else {
            [self startDebugTarget];
        }
        break;
    case DebugCommand::Pause:
    case DebugCommand::StepOver:
    case DebugCommand::StepInto:
    case DebugCommand::StepOut:
        [dock.debugSession performCommand:command];
        break;
    case DebugCommand::Restart:
        if (dock.debugging) {
            dock.restartDebug = YES;
            [dock.debugBuilder stop];
            [dock.debugSession stop];
        } else {
            [self startDebugTarget];
        }
        break;
    case DebugCommand::Stop:
        [dock stopDebug];
        break;
    case DebugCommand::ToggleBreakpoint: {
        NSString *path = _editor.debugPath;
        NSUInteger line = [self debugCursorLine];
        SetDebugBreakpoint(path, line, DebugBreakpoints(path)[@(line)] ? nil : @{});
        break;
    }
    case DebugCommand::EditBreakpoint:
        [self editBreakpoint:_editor.debugPath line:[self debugCursorLine]];
        break;
    case DebugCommand::RunToCursor:
        [dock.debugSession runToLine:[self debugCursorLine] path:_editor.debugPath];
        break;
    case DebugCommand::ChooseExecutable:
        [self chooseDebugExecutable];
        break;
    case DebugCommand::Attach:
        [self attachDebugger];
        break;
    case DebugCommand::Arguments:
        [self editDebugArguments];
        break;
    case DebugCommand::ShowPane:
        [dock toggleDockPage:DockPage::Debug];
        break;
    }
}

- (IBAction)runSource:(id)sender
{
    (void)sender;
    if (!self.canRunCommand)
        return;
    WindowOutput *output = _windowOutput;
    FolderWorkspace *workspace = _document.workspace;
    switch (self.runCommand) {
    case RunButtonAction::Continue:
        [output.debugSession performCommand:DebugCommand::Continue];
        return;
    case RunButtonAction::Stop:
        if (output.runner)
            [output.runner stop];
        else if (output.debugging)
            [output stopDebug];
        else if (SourceDocument *running = workspace.runningDocument)
            [running cancelRun];
        else
            [self stopRun];
        return;
    case RunButtonAction::Run:
        break;
    }

    NSURL *file = CanonicalFileURL(_document.fileURL);
    Language language = _buffer.language;
    NSURL *folder = file || !_buffer.storage.length ? workspace.folder : nil;
    RunProject project = LocateRunProject(language, file, folder);
    if (RunHasBreakpoint(project, language, file)) {
        [self performDebugCommand:DebugCommand::Continue];
        return;
    }
    if (!self.canRun)
        return;
    [output cancelCheck];
    output.shown = YES;
    [output.pane prepareForRun];
    NSArray<SourceDocument *> *documents = [self documentsForBuild:project];
    SourceRunner *runner = [[SourceRunner alloc] init];
    output.source = _document;
    output.runner = runner;
    output.runWorkspace = workspace;
    output.returnFocus = NO;
    _runningOutput = output;
    workspace.runningDocument = _document;
    [self refreshRunButton];

    NSResponder *focus = self.window.firstResponder;
    if (project.kind == RunKind::Source) {
        [self launchRun:project language:language file:file output:output documents:documents startingFocus:focus];
        return;
    }
    __weak EditorWindow *view = self;
    __weak WindowOutput *windowOutput = output;
    __weak NSResponder *startingFocus = focus;
    SaveBuildDocuments(documents, 0, runner, ^(NSError *error) {
        WindowOutput *console = windowOutput;
        if (console.runner != runner)
            return;
        EditorWindow *root = view;
        BOOL stopped = !root || runner.isStopped;
        if (error || stopped) {
            NSString *message = stopped ? @"Stopped.\n" :
                [NSString stringWithFormat:@"%@\n", error.localizedDescription];
            [console.pane appendMessages:{{message, stopped ? OutputTone::Text : OutputTone::Error, {}}} source:nil];
            [console finishRun];
        } else {
            [root launchRun:project language:language file:file output:console documents:documents startingFocus:startingFocus];
        }
    });
}

- (void)dealloc
{
    [self stopRun];
    [self cancelLanguageCheck];
    [self closeLanguageServices];
}

- (void)splitResized:(NSNotification *)notification
{
    (void)notification;
    [self layoutPane];
    [_secondPane setNeedsLayout:YES];
}

- (void)installSplitAtSide:(DockSide)side fraction:(CGFloat)fraction
{
    if (!_secondPane)
        _secondPane = [[EditorWindow alloc] initWithDocument:_document text:nil language:_buffer.language
                                                    buffer:_buffer parent:self];
    if (!_splitView) {
        _paneContent = [[NSView alloc] initWithFrame:NSUnionRect(_scroll.frame, _gutter.frame)];
        [_scroll removeFromSuperview];
        [_gutter removeFromSuperview];
        [_paneContent addSubview:_scroll];
        [_paneContent addSubview:_gutter];
        _splitView = [[NSSplitView alloc] initWithFrame:_paneContent.frame];
        _splitView.dividerStyle = NSSplitViewDividerStyleThin;
        [self addSubview:_splitView];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(splitResized:)
                      name:NSSplitViewDidResizeSubviewsNotification object:_splitView];
    }

    _splitSide = side;
    ArrangeEditorSplit(_splitView, _paneContent, _secondPane, side, fraction);
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
}

- (void)showSplitRight:(BOOL)vertical from:(EditorWindow *)pane
{
    [self installSplitAtSide:vertical ? DockSide::Right : DockSide::Bottom fraction:0.5];
    EditorWindow *target = pane == self ? _secondPane : self;
    [target.editor visitVimFileMark:pane.editor.vimCursor exact:YES];
    [self updateEditorStatus];
}

- (void)splitTabAtSide:(DockSide)side
{
    BOOL newSplit = !_splitView;
    if (newSplit || _splitSide != side)
        [self installSplitAtSide:side fraction:0.5];
    if (newSplit)
        [_secondPane.editor visitVimFileMark:_editor.vimCursor exact:YES];
    else
        [self.window makeFirstResponder:_secondPane.editor];
    [self updateEditorStatus];
}

- (void)closeSplitFrom:(EditorWindow *)pane
{
    BOOL keepRight = pane == self;
    NSUInteger cursor = _secondPane.editor.vimCursor;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSSplitViewDidResizeSubviewsNotification
                                               object:_splitView];
    [_secondPane removeFromSuperview];
    [_scroll removeFromSuperview];
    [_gutter removeFromSuperview];
    [_paneContent removeFromSuperview];
    [_splitView removeFromSuperview];
    _splitView = nil;
    _paneContent = nil;
    [self addSubview:_scroll];
    [self addSubview:_gutter];
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
    if (keepRight)
        [_editor visitVimFileMark:cursor exact:YES];
    else
        [self.window makeFirstResponder:_editor];

    self.window.initialFirstResponder = _editor;
    _secondPane = nil;
    [self updateEditorStatus];
}

- (BOOL)hasSplit { return _splitView != nil; }

- (void)closeTabSplit
{
    if (_splitView)
        [self closeSplitFrom:_secondPane];
}

- (void)performEditorAction:(Vim::Action)action argument:(NSString *)argument force:(BOOL)force
{
    using Vim::Action;
    EditorWindow *root = _splitParent;
    if (!root)
        root = self;
    if (action == Action::SplitRight || action == Action::SplitBelow) {
        if (!argument.length || [argument isEqualToString:@"%"])
            [root showSplitRight:action == Action::SplitRight from:self];
        else
            [_document performVimAction:Action::Open argument:argument force:NO];
        return;
    }
    if (action == Action::WindowCommand && argument.length) {
        unichar key = [argument characterAtIndex:0];
        if (key == 's' || key == 'v')
            [root showSplitRight:key == 'v' from:self];
        else if (root->_splitView) {
            if (key == 'c' || key == 'q')
                [root closeSplitFrom:self];
            else if (key == 'o')
                [root closeSplitFrom:self == root ? root->_secondPane : root];
            else {
                CodeView *target = self == root ? root->_secondPane.editor : root.editor;
                bool along = root->_splitView.isVertical ? key == 'h' || key == 'l' : key == 'k' || key == 'j';
                bool forward = key == 'l' || key == 'j';
                bool toward = forward == ((self == root) != SplitDockFirst(root->_splitSide));
                if ((along && toward) || key == 'w' || key == 'W' || key == 'p')
                    [root.window makeFirstResponder:target];
                [root updateEditorStatus];
            }
        } else if (MoveFocusInDocumentSplit(self, key)) {
            return;
        } else if (key == 'c' || key == 'q') {
            [_document performVimAction:Action::Close argument:@"" force:NO];
        } else if (key != 'o') {
            bool backwards = key == 'W' || key == 'h' || key == 'k' || key == 'p';
            [_document performVimAction:backwards ? Action::PreviousWindow : Action::NextWindow argument:@"" force:NO];
        }
        return;
    }
    if (action == Action::Close && root->_splitView) {
        [root closeSplitFrom:self];
        return;
    }
    [_document performVimAction:action argument:argument force:force];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [center removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    if (self.window) {
        [center addObserver:self selector:@selector(keyWindowChanged:)
                       name:NSWindowDidBecomeKeyNotification object:self.window];
        [center addObserver:self selector:@selector(keyWindowChanged:)
                       name:NSWindowDidResignKeyNotification object:self.window];
        [_buffer scheduleInlayHints];
    }
}

- (void)keyWindowChanged:(NSNotification *)notification
{
    (void)notification;
    [_editor invalidateVimCaret];
    [_editor updateInsertionPointStateAndRestartTimer:YES];
    [_gutter refreshBreakpointHover];
    if (!self.window.isKeyWindow) {
        [_editor dismissCompletion];
        [_editor dismissLanguageInformation];
    } else if (!_splitParent) {
        [self refreshLanguageServices];
        [_buffer scheduleInlayHints];
        [self resumeLanguageCheck];
    }
}

- (void)updateLanguageHoverModifiers:(NSEvent *)event
{
    NSPoint point = self.window.mouseLocationOutsideOfEventStream;
    [_editor updateLanguageHoverModifiers:event.modifierFlags atWindowPoint:point];
    [_secondPane.editor updateLanguageHoverModifiers:event.modifierFlags atWindowPoint:point];
}

- (void)layout
{
    [super layout];
    if (_splitView && !NSEqualRects(_splitView.frame, self.bounds)) {
        _splitView.frame = self.bounds;
        [_splitView adjustSubviews];
    }
    [self layoutPane];
}

- (void)layoutPane
{
    NSRect area = _paneContent ? _paneContent.bounds : self.bounds;
    CGFloat x = NSMinX(area), width = NSWidth(area), height = NSHeight(area);
    NSUInteger lineCount = std::max(NSUInteger(1), _buffer.lineCount);
    CGFloat digits = std::floor(std::log10(double(lineCount))) + 1;
    CGFloat digitWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName:_gutter.numberFont}].width;
    CGFloat gutterWidth = std::min(std::max(42.0, std::ceil(digits * digitWidth + gutterInset + breakpointLane)),
                                  std::floor(width / 3));
    NSRect viewport = NSMakeRect(x + gutterWidth, NSMinY(area), width - gutterWidth, height);
    bool viewportChanged = !NSEqualRects(_scroll.frame, viewport);
    _scroll.frame = viewport;
    _gutter.frame = NSMakeRect(x, NSMinY(area), gutterWidth, height);

    // Refit after edits and clip changes so AppKit can clamp both scroll axes.
    [_editor sizeToFit];
    [self updateCursor];
    if (viewportChanged)
        [_buffer scheduleInlayHints];
    if (_laidOutLineCount != lineCount) {
        _laidOutLineCount = lineCount;
        // AppKit may reuse backing pixels while moving the existing line fragments.
        [_editor setNeedsDisplayInRect:_editor.visibleRect];
    }
}

- (void)replaceDocumentText:(NSString *)text
{
    [_editor dismissCompletion];
    [_editor loadText:text];
    [_editor vimDocumentReplaced];
    [_secondPane.editor dismissCompletion];
    [_secondPane.editor prepareDocumentAppearance:text];
    [_secondPane.editor vimDocumentReplaced];
    [self applyPreferences];
    [self layoutSubtreeIfNeeded];
    [_editor scrollRangeToVisible:NSMakeRange(0, 0)];
    [self scheduleLanguageCheck];
}

- (NSDictionary *)sessionPane
{
    NSMutableArray *folds = [NSMutableArray array];
    for (const auto &fold : [(CodeLayoutManager *)_editor.layoutManager editorFolds])
        [folds addObject:@[@(fold.header), @(fold.hidden.location), @(fold.hidden.length)]];
    return @{@"cursors":_editor.sessionCursors, @"scroll":NSStringFromPoint(_scroll.documentVisibleRect.origin), @"folds":folds};
}

- (NSDictionary *)sessionView
{
    NSMutableDictionary *state = [@{@"pane":[self sessionPane], @"language":@(self.languageMode),
                                    @"languageAutomatic":@(self.automaticLanguageMode)} mutableCopy];
    if (_buffer.hasFileIndentation)
        state[@"indentation"] = EncodeIndentation(_buffer.indentation);
    if (_splitView) {
        BOOL vertical = _splitView.isVertical;
        NSRect firstFrame = _splitView.arrangedSubviews.firstObject.frame;
        CGFloat first = vertical ? NSWidth(firstFrame) : NSHeight(firstFrame);
        CGFloat extent = vertical ? NSWidth(_splitView.bounds) : NSHeight(_splitView.bounds);
        NSResponder *focus = self.window.firstResponder;
        BOOL second = focus == _secondPane.editor || (focus != _editor && _tabFocus == _secondPane.editor);
        state[@"split"] = @{@"vertical":@(vertical), @"side":@(NSInteger(_splitSide)), @"fraction":@(extent > 0 ? first / extent : 0.5),
                            @"secondActive":@(second), @"pane":[_secondPane sessionPane]};
    }
    return state;
}

- (void)restoreSessionPane:(NSDictionary *)state
{
    NSUInteger length = _editor.string.length;
    std::vector<EditorFold> folds;
    for (id entry in SessionArray(state[@"folds"])) {
        NSArray *fold = SessionArray(entry);
        if (fold.count != 3 || !SessionNumber(fold[0]) || !SessionNumber(fold[1]) || !SessionNumber(fold[2]))
            continue;
        NSUInteger header = [fold[0] unsignedIntegerValue], start = [fold[1] unsignedIntegerValue];
        NSUInteger count = [fold[2] unsignedIntegerValue];
        if (header < start && start < length && count && count <= length - start)
            folds.push_back({header, NSMakeRange(start, count)});
    }
    if (!folds.empty())
        [_editor displayFolds:std::move(folds)];
    [_editor restoreSessionCursors:SessionArray(state[@"cursors"])];
    NSString *saved = SessionString(state[@"scroll"]);
    if (saved) {
        NSPoint origin = NSPointFromString(saved);
        if (std::isfinite(origin.x) && std::isfinite(origin.y))
            [_editor restoreSessionScroll:origin];
    }
    [self updateCursor];
}

- (void)restoreSessionView:(NSDictionary *)state
{
    NSNumber *language = SessionNumber(state[@"language"]);
    NSNumber *automatic = SessionNumber(state[@"languageAutomatic"]);
    if (language && language.unsignedIntegerValue < size_t(Language::Count)) {
        Language saved = Language(language.integerValue);
        if (automatic ? !automatic.boolValue : saved != Language::Plain && saved != LegacyFileLanguage(_document.fileURL))
            [self setLanguage:saved];
    }
    if (!_document.fileURL) {
        if (auto indentation = DecodeIndentation(state[@"indentation"]))
            [self setFileIndentation:*indentation];
    }
    NSDictionary *split = SessionDictionary(state[@"split"]);
    if (split) {
        BOOL vertical = [SessionNumber(split[@"vertical"]) boolValue];
        NSNumber *savedSide = SessionNumber(split[@"side"]);
        DockSide side = vertical ? DockSide::Right : DockSide::Bottom;
        if (savedSide && savedSide.unsignedIntegerValue <= size_t(DockSide::Top))
            side = DockSide(savedSide.integerValue);
        NSNumber *ratio = SessionNumber(split[@"fraction"]);
        CGFloat fraction = ratio ? ratio.doubleValue : 0.5;
        [self installSplitAtSide:side fraction:std::isfinite(fraction) ? std::clamp(fraction, 0.0, 1.0) : 0.5];
        if ([SessionNumber(split[@"secondActive"]) boolValue])
            _tabFocus = _secondPane.editor;
    }
    [self layoutSubtreeIfNeeded];
    [self restoreSessionPane:SessionDictionary(state[@"pane"])];
    if (split)
        [_secondPane restoreSessionPane:SessionDictionary(split[@"pane"])];
}

- (void)scrollMoved:(NSNotification *)notification
{
    (void)notification;
    [_editor completionViewportChanged];
    [_editor dismissPointerInformation];
    if (_scrollUpdatePending)
        return;
    _scrollUpdatePending = YES;
    __weak EditorWindow *view = self;
    // Keep gutter work out of the clip view's layout callbacks.
    [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes] block:^{
        EditorWindow *root = view;
        if (root) {
            root->_scrollUpdatePending = NO;
            CodeView *editor = root->_editor;
            if (editor.debugException.length) {
                NSRect used;
                [editor setNeedsDisplayInRect:[editor debugLineInRect:editor.visibleRect used:&used]];
            }
            [root->_gutter refreshBreakpointHover];
            [root->_gutter setNeedsDisplay:YES];
            [root->_buffer scheduleInlayHints];
        }
    }];
}

- (void)scrollTracking:(NSNotification *)notification
{
    (void)notification;
    [_editor dismissLanguageInformation];
    [_editor vimDidLiveScroll];
}

- (void)chooseLanguage:(NSPopUpButton *)sender
{
    NSInteger tag = sender.selectedTag;
    if (tag == -1)
        [self useAutomaticLanguage];
    else
        [self setLanguage:Language(tag)];
}

- (void)setLanguage:(Language)language
{
    _automaticLanguageMode = NO;
    [self applyLanguage:language];
}

- (void)useAutomaticLanguage
{
    _automaticLanguageMode = YES;
    [self refreshDetectedLanguage];
}

- (void)refreshDetectedLanguage
{
    if (!_automaticLanguageMode)
        return;
    _detectLanguageFromContent = LanguageForSource(_document.fileURL) == Language::Plain;
    [self applyLanguage:[_document inferredLanguageForText:_buffer.storage.string]];
}

static NSString *LanguageDiagnosticLabel(NSDictionary *diagnostic)
{
    NSString *source = LSPString(diagnostic[@"source"]);
    id value = diagnostic[@"code"];
    NSString *code = LSPString(value);
    if (!code)
        code = [LSPNumber(value) stringValue];
    if (source.length && code.length)
        return [NSString stringWithFormat:@"%@(%@)", source, code];
    return source.length ? source : code;
}

- (void)updateLanguageDiagnostics
{
    LSPDocument *document = _buffer.languageDocument;
    std::vector<BuildError> marks;
    CheckResult result;
    BOOL active = _windowOutput.host == self;
    bool hasCheck = _languageCheckResult && _languageCheckVersion == _buffer.textVersion;
    if (active && hasCheck)
        result = *_languageCheckResult;
    for (NSDictionary *diagnostic in document.diagnostics) {
        NSInteger severity = [LSPNumber(diagnostic[@"severity"]) integerValue];
        if (severity > 2)
            continue;
        BOOL warning = severity == 2;
        NSRange range = [_buffer languageRange:diagnostic[@"range"]];
        if (range.location == NSNotFound)
            continue;
        NSString *message = LSPString(diagnostic[@"message"]);
        NSString *code = LSPString(diagnostic[@"code"]);
        if (!code)
            code = [LSPNumber(diagnostic[@"code"]) stringValue];
        NSString *diagnostic_label = LanguageDiagnosticLabel(diagnostic);
        LSPPosition start = [_buffer languagePosition:range.location];
        NSRange line = SourceLine(_buffer, [_buffer lineForOffset:range.location] + 1);
        if (line.location != NSNotFound && NSMaxRange(line) >= range.location)
            range.length = std::min(range.length, NSMaxRange(line) - range.location);
        if (hasCheck) {
            const auto &checked = _buffer.buildErrors;
            auto mark = std::lower_bound(checked.begin(), checked.end(), line.location,
                [](const BuildError &error, NSUInteger offset) { return error.range.location < offset; });
            NSString *compilerLabel = diagnostic_label;
            for (; mark != checked.end() && mark->range.location <= NSMaxRange(range); ++mark) {
                if (mark->warning == (warning != NO) &&
                    (mark->range.location == range.location || NSIntersectionRange(mark->range, range).length) &&
                    ([mark->label isEqualToString:compilerLabel] || [mark->message isEqualToString:message]))
                    break;
            }
            if (mark != checked.end() && mark->range.location <= NSMaxRange(range))
                continue;
        }
        RunLocation location{document.file, start.line + 1, start.character + 1, 0, 0, true, false, true};
        bool unused = warning && IsHideableUnusedWarning(_buffer, range.location, code, message);
        marks.push_back({range, message, warning != NO, diagnostic_label, location, false, unused});
        if (!active)
            continue;
        NSString *path = document.file.lastPathComponent;
        NSString *label = [NSString stringWithFormat:@"%@:%lu:%lu", path, (unsigned long)location.line,
                           (unsigned long)location.column];
        NSString *text = [NSString stringWithFormat:@"%@: %@: %@\n", label, warning ? @"warning" : @"error", message];
        RunMessage output{text, warning ? OutputTone::Warning : OutputTone::Error, location, message};
        output.linkRange = NSMakeRange(0, label.length);
        result.diagnostics.push_back(std::move(output));
        if (warning)
            ++result.warnings;
        else
            ++result.errors;
    }
    [_buffer setLanguageErrors:std::move(marks)];
    if (active)
        [_windowOutput setCheckResult:std::move(result) source:_document];
    [_document resumePendingAutoSave];
}

- (void)updateLanguageStatus
{
    if (_windowOutput.host == self)
        [_windowOutput updateLanguageStatus];

    LSPDocument *document = _buffer.languageDocument;
    [_editor updateLanguageTracking];
    [_secondPane.editor updateLanguageTracking];
    if ([document supports:@"inlayHintProvider"])
        [_buffer scheduleInlayHintsAfter:0];
    else
        [_buffer resetInlayHints];
}

- (void)closeLanguageServices
{
    LSPDocument *document = _buffer.languageDocument;
    if (_splitParent || !document)
        return;
    document.updated = nil;
    document.diagnosticsChanged = nil;
    document.inlayHintsChanged = nil;
    [document close];
    _buffer.languageDocument = nil;
    _languageWorkspace = nil;
    [_editor dismissLanguageInformation];
    [_secondPane.editor dismissLanguageInformation];
    [_editor dismissCompletion];
    [_secondPane.editor dismissCompletion];
    [self updateLanguageDiagnostics];
    [self updateLanguageStatus];
}

- (void)refreshLanguageServices
{
    if (_splitParent)
        return;
    NSURL *file = CanonicalFileURL(_document.fileURL);
    NSURL *workspace = _document.workspace.folder;
    LSPDocument *existing = _buffer.languageDocument;
    BOOL sameWorkspace = workspace == _languageWorkspace || [workspace isEqual:_languageWorkspace];
    if (existing && [existing.file isEqual:file] && existing.language == _buffer.language && sameWorkspace)
        return;
    [self closeLanguageServices];
    if (!file || !self.window.isKeyWindow)
        return;
    LSPDocument *document = [[LSPDocument alloc] initWithFile:file workspace:workspace language:_buffer.language];
    __weak EditorWindow *root = self;
    __weak SyntaxBuffer *buffer = _buffer;
    document.sourceText = ^NSString *{
        NSString *text = [buffer.storage.string copy];
        return text ? text : @"";
    };
    document.endPosition = ^LSPPosition {
        return [buffer languagePosition:buffer.storage.length];
    };
    document.updated = ^{
        EditorWindow *editor = root;
        if (!editor)
            return;
        if (editor->_buffer.languageDocument.state != LSPState::Ready) {
            [editor->_editor dismissServerCompletion];
            [editor->_secondPane.editor dismissServerCompletion];
            [editor->_editor dismissLanguageInformation];
            [editor->_secondPane.editor dismissLanguageInformation];
        }
        [editor updateLanguageStatus];
        if (editor->_buffer.language != Language::Rust && editor->_buffer.languageDocument.handlesDiagnostics &&
            editor->_languageCheckResult) {
            editor->_languageCheckResult.reset();
            editor->_needsLanguageCheck = CheckableLanguage(editor->_buffer.language);
            [editor->_buffer replaceCheckErrors:{}];
        }

        if (editor->_windowOutput.host == editor && ![editor canQueueLanguageCheck])
            [editor->_windowOutput cancelCheck];
        [editor updateLanguageDiagnostics];
        [editor resumeLanguageCheck];
    };
    document.diagnosticsChanged = ^{ [root updateLanguageDiagnostics]; };
    document.inlayHintsChanged = ^{
        [buffer refreshInlayHintsAfter:inlayRefreshDelay];
    };
    _languageWorkspace = workspace;
    _buffer.languageDocument = document;
    [document start];
}

enum class LanguageStatusAction { Install, CancelInstall, Start, Restart, Stop, Configure, Default, Error, Uninstall };

static bool CanUseLanguageStatusAction(LSPDocument *document, LanguageStatusAction action)
{
    if (action != LanguageStatusAction::Configure && (!document || document.state == LSPState::Uninstalling))
        return false;
    LSPState state = document.state;
    switch (action) {
    case LanguageStatusAction::Install:
        return (state == LSPState::Missing || state == LSPState::Failed) && document.canInstall;
    case LanguageStatusAction::CancelInstall:
        return state == LSPState::Installing;
    case LanguageStatusAction::Start:
        return state == LSPState::Stopped || state == LSPState::Failed;
    case LanguageStatusAction::Restart:
    case LanguageStatusAction::Stop:
        return state == LSPState::Ready || state == LSPState::Starting;
    case LanguageStatusAction::Configure:
        return true;
    case LanguageStatusAction::Default:
        return state != LSPState::Installing && document.customServer;
    case LanguageStatusAction::Error:
        return state == LSPState::Failed;
    case LanguageStatusAction::Uninstall:
        return state != LSPState::Installing && document.canUninstall;
    }
    return false;
}

- (IBAction)languageStatusAction:(NSMenuItem *)sender
{
    LSPDocument *document = _buffer.languageDocument;
    auto action = LanguageStatusAction(sender.tag);
    if (!self.window || self.window.attachedSheet || !CanUseLanguageStatusAction(document, action))
        return;
    switch (action) {
    case LanguageStatusAction::Install: [document install]; break;
    case LanguageStatusAction::CancelInstall: [document cancelInstall]; break;
    case LanguageStatusAction::Start: [document start]; break;
    case LanguageStatusAction::Restart: [document restart]; break;
    case LanguageStatusAction::Stop: [document stop]; break;
    case LanguageStatusAction::Configure: [[PreferencesController sharedController] showLSPPaneForLanguage:_buffer.language]; break;
    case LanguageStatusAction::Default: SetLanguageServerConfiguration(document.language, nil, nil); break;
    case LanguageStatusAction::Error: [self.editor presentLanguageError:document.status]; break;
    case LanguageStatusAction::Uninstall: [document uninstall]; break;
    }
}

- (NSMutableArray<NSMenuItem *> *)languageStatusCommandsForPalette:(BOOL)palette
{
    static const struct {
        LanguageStatusAction action;
        NSString *title;
        NSString *menuTitle;
    } commands[] = {
        {LanguageStatusAction::CancelInstall, @"Cancel Installation", @"Cancel Installation"},
        {LanguageStatusAction::Restart, @"Restart Language Server", @"Restart Server"},
        {LanguageStatusAction::Stop, @"Stop Language Server", @"Stop Server"},
        {LanguageStatusAction::Start, @"Start Language Server", @"Start Server"},
        {LanguageStatusAction::Install, @"Install Language Tools", nil},
        {LanguageStatusAction::Uninstall, @"Uninstall Language Tools", @"Uninstall Language Tools"},
        {LanguageStatusAction::Error, @"Show Error…", @"Show Error…"},
        {LanguageStatusAction::Configure, nil, @"Configure Server…"},
        {LanguageStatusAction::Default, @"Use Default Language Server", @"Use Default Server"},
    };
    LSPDocument *document = _buffer.languageDocument;
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
    for (const auto &command : commands) {
        if ((palette && !command.title) || !CanUseLanguageStatusAction(document, command.action))
            continue;
        NSString *title = command.menuTitle;
        if (palette)
            title = [@"LSP: " stringByAppendingString:command.title];
        else if (command.action == LanguageStatusAction::Install)
            title = [NSString stringWithFormat:@"Install %@…", document.serverName];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(languageStatusAction:) keyEquivalent:@""];
        item.target = self;
        item.tag = NSInteger(command.action);
        [items addObject:item];
    }
    return items;
}

- (NSArray<NSMenuItem *> *)languagePaletteCommands
{
    NSMutableArray<NSMenuItem *> *items = [self languageStatusCommandsForPalette:YES];
    if (_buffer.languageDocument.state != LSPState::Ready)
        return items;
    CodeView *editor = self.activeEditor;
    for (NSMenuItem *command in LanguageFeatureCommands()) {
        if (![editor validateUserInterfaceItem:command])
            continue;
        command.title = [@"LSP: " stringByAppendingString:command.title];
        command.target = editor;
        [items addObject:command];
    }
    return items;
}

- (IBAction)showLanguageStatus:(NSButton *)sender
{
    if (self.window.attachedSheet)
        return;
    [self refreshLanguageServices];
    LSPDocument *document = _buffer.languageDocument;
    if (document && document.state == LSPState::Missing && !document.canInstall) {
        [[PreferencesController sharedController] showLSPPaneForLanguage:_buffer.language];
        return;
    }
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    NSString *status = document.failureTitle ? document.failureTitle : document.status;
    if (!status.length)
        status = @"Save the file to use LSP.";
    NSRange newline = [status rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
    if (newline.location != NSNotFound)
        status = [status substringToIndex:newline.location];
    if (status.length > 96)
        status = [[status substringToIndex:96] stringByAppendingString:@"…"];
    NSMenuItem *heading = [menu addItemWithTitle:status action:nil keyEquivalent:@""];
    heading.enabled = NO;
    NSArray<NSMenuItem *> *commands = [self languageStatusCommandsForPalette:NO];
    if (commands.count) {
        [menu addItem:NSMenuItem.separatorItem];
        for (NSMenuItem *command in commands)
            [menu addItem:command];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)applyLanguage:(Language)language
{
    BOOL changed = _buffer.language != language;
    if (changed)
        _buffer.language = language;
    if (_windowOutput.host == self) {
        [_windowOutput updateEditorSettings];
        [_windowOutput refreshDebugControls];
    }
    if (!changed)
        return;
    [self refreshLanguageServices];
    [self scheduleLanguageCheck];
    [_document resumePendingAutoSave];
    [_editor dismissCompletion];
    [_editor refreshWordSelection];
    self.needsLayout = YES;
    [_editor setNeedsDisplay:YES];
}

- (void)preferencesChanged:(NSNotification *)notification
{
    (void)notification;
    [self applyPreferences];
}

- (void)unusedWarningsChanged:(NSNotification *)notification
{
    (void)notification;
    if (self.hasDiagnostics)
        [_buffer refreshBuildErrorViews];
}

- (void)inlaySettingsChanged:(NSNotification *)notification
{
    (void)notification;
    [_buffer resetInlayHints];
    [_editor applyAppearance];
    [_secondPane.editor applyAppearance];
    [_buffer scheduleInlayHints];
}

- (void)applyPreferences
{
    [self applyPreferencesWithTheme:SelectedTheme()];
}

- (void)applyPreferencesWithTheme:(const ThemeRef &)palette
{
    BOOL vimEnabled = [NSUserDefaults.standardUserDefaults boolForKey:vimModeKey];
    [_buffer refreshIndentationDefaults];
    if (_editor.vimEnabled != vimEnabled)
        _editor.vimEnabled = vimEnabled;
    _editor.smoothScrollingEnabled = SmoothScrollingPreference();
    [_editor applyAppearanceWithTheme:palette];
    _scroll.appearance = [NSAppearance appearanceNamed:_editor.theme->dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    _scroll.backgroundColor = RenderedEditorColor(_editor.theme->paper, _editor.rendering);
    if (_windowOutput.host == self) {
        [_windowOutput updateEditorSettings];
        [_windowOutput updateConsoleAppearance];
    }

    NSFont *font = _editor.editorFont;
    CGFloat numberSize = std::max(1.0, std::round(font.pointSize * (5.0 / 6.0)));
    NSFont *numberFont = [NSFont fontWithDescriptor:font.fontDescriptor size:numberSize];
    if (![_gutter.numberFont isEqual:numberFont])
        _gutter.numberFont = numberFont ? numberFont : font;
    self.needsLayout = YES;
    [self updateCursor];
    [_gutter setNeedsDisplay:YES];
    if (_splitView)
        [_secondPane applyPreferencesWithTheme:palette];
}

- (void)vimStatusChanged
{
    if (_editor.vimEnabled && [_editor vimIndentation] != _buffer.indentation) {
        EditorWindow *root = _splitParent ? _splitParent : self;
        [root setFileIndentation:[_editor vimIndentation]];
        return;
    }
    [self updateCursor];
}

- (void)updateEditorStatus
{
    if (_windowOutput.host == self)
        [_windowOutput updateEditorStatus];
}

- (void)updateCursor
{
    EditorWindow *root = _splitParent;
    [(root ? root : self) updateEditorStatus];
    NSUInteger caret = std::min(_editor.vimDisplayedCursor, _editor.string.length);
    NSUInteger start = [_buffer offsetForLine:[_buffer lineForOffset:caret]];
    NSLayoutManager *layout = _editor.layoutManager;
    NSRect rect;
    if (start < _editor.string.length) {
        NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:start];
        rect = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr];
    } else {
        rect = layout.extraLineFragmentRect;
        if (NSIsEmptyRect(rect))
            rect = NSMakeRect(0, 0, 1, [layout defaultLineHeightForFont:_editor.font]);
    }
    rect.origin.y += _editor.textContainerOrigin.y;
    rect.origin.x = 0;
    rect.size.width = NSWidth(_editor.bounds);

    if (!NSEqualRects(rect, _editor.currentLine)) {
        [_editor setNeedsDisplayInRect:_editor.currentLine];
        _editor.currentLine = rect;
        [_editor setNeedsDisplayInRect:rect];
    }
    [_editor refreshBracketMatch];
    [_editor refreshWordSelection];
    [_editor validateCompletion];
    [_editor scheduleSignatureHelp];
    [_gutter refreshBreakpointHover];
    [_gutter setNeedsDisplay:YES];
}

- (void)textDidChange:(NSNotification *)notification
{
    (void)notification;
    EditorWindow *root = _splitParent ? _splitParent : self;
    if (root->_automaticLanguageMode && root->_detectLanguageFromContent &&
        _editor.selectedRange.location <= 512 &&
        (_buffer.language != Language::Plain || [_buffer.storage.string hasPrefix:@"#!"] ||
         [_buffer.storage.string hasPrefix:@"<?"]))
        [root refreshDetectedLanguage];
    [_buffer finishHighlighting];
    [self updateCursor];
    [self setNeedsLayout:YES];
    EditorWindow *other = _splitParent ? _splitParent : (_splitView ? _secondPane : nil);
    [other updateCursor];
    [other setNeedsLayout:YES];
    [_document scheduleAutoSaveAfterEdit];
    [root scheduleLanguageCheck];
}

- (void)textViewDidChangeSelection:(NSNotification *)notification
{
    (void)notification;
    if (!_buffer.hasPendingHighlighting)
        [self updateCursor];
}

- (NSUndoManager *)undoManagerForTextView:(NSTextView *)view
{
    (void)view;
    return _document.undoManager;
}

@end

@interface WindowHeader : NSView <NSDraggingSource>
- (void)updateTitle;
@end

@implementation WindowHeader {
    NSTextField *_title;
    NSImageView *_documentIcon;
    NSURL *_representedURL;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.clipsToBounds = YES;
    _title = [NSTextField labelWithString:@""];
    _title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    _title.textColor = NSColor.windowFrameTextColor;
    _title.alignment = NSTextAlignmentCenter;
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _title.accessibilityElement = NO;
    [self addSubview:_title];
    _documentIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _documentIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    _documentIcon.accessibilityElement = NO;
    [self addSubview:_documentIcon];
    return self;
}

- (void)updateTitle
{
    NSString *title = self.window.title;
    _title.stringValue = title ? title : @"";
    NSURL *url = self.window.representedURL;
    if (_representedURL != url && ![_representedURL isEqual:url]) {
        _representedURL = url;
        _documentIcon.image = url.isFileURL ? [NSWorkspace.sharedWorkspace iconForFile:url.path] : nil;
    }
    self.needsLayout = YES;
}

- (void)layout
{
    [super layout];
    NSButton *close = [self.window standardWindowButton:NSWindowCloseButton];
    NSRect closeFrame = [self convertRect:close.bounds fromView:close];
    CGFloat y = NSMidY(closeFrame) + 1;
    _title.hidden = !close || close.hiddenOrHasHiddenAncestor || y < 0 || y >= NSHeight(self.bounds);
    _documentIcon.hidden = _title.hidden || !_documentIcon.image;

    constexpr CGFloat sideInset = 76;
    constexpr CGFloat titleHeight = 18;
    constexpr CGFloat iconSize = 16;
    CGFloat iconSpace = _documentIcon.hidden ? 0 : iconSize + 3;
    CGFloat available = std::max<CGFloat>(0, NSWidth(self.bounds) - 2 * sideInset - iconSpace);
    CGFloat width = std::min(available, std::ceil(_title.cell.cellSize.width));
    CGFloat left = std::round(NSMidX(self.bounds) - (width + iconSpace) / 2);
    _title.frame = NSMakeRect(left + iconSpace, y - titleHeight / 2, width, titleHeight);
    _documentIcon.frame = NSMakeRect(left, y - iconSize / 2, iconSize, iconSize);
}

- (NSView *)hitTest:(NSPoint)point
{
    if (_documentIcon.hidden)
        return nil;
    NSPoint local = [self convertPoint:point fromView:self.superview];
    NSEvent *event = NSApp.currentEvent;
    BOOL pathClick = event.type == NSEventTypeLeftMouseDown && (event.modifierFlags & NSEventModifierFlagCommand);
    return NSPointInRect(local, _documentIcon.frame) || (pathClick && NSPointInRect(local, _title.frame)) ? self : nil;
}

- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    (void)event;
    if (!_representedURL.isFileURL)
        return nil;
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSURL *url = _representedURL.URLByStandardizingPath; url.path.length; url = url.URLByDeletingLastPathComponent) {
        NSString *name = [NSFileManager.defaultManager displayNameAtPath:url.path];
        NSMenuItem *item = [menu addItemWithTitle:name action:@selector(revealInFinder:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = url;
        if ([url.path isEqualToString:@"/"])
            break;
    }
    return menu;
}

- (void)mouseDown:(NSEvent *)event
{
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        NSMenu *menu = [self menuForEvent:event];
        if (menu)
            [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    }
}

- (IBAction)revealInFinder:(NSMenuItem *)sender
{
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[sender.representedObject]];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (!_representedURL.isFileURL || self.window.documentEdited)
        return;
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:_representedURL];
    [item setDraggingFrame:_documentIcon.frame contents:_documentIcon.image];
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    (void)session;
    (void)context;
    return NSDragOperationCopy;
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty
{
    NSString *appearance = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua
    ]];
    BOOL dark = [appearance isEqualToString:NSAppearanceNameDarkAqua];
    NSRect bounds = self.bounds;
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:SRGBColor(dark ? rgb(72, 73, 76) : rgb(245, 245, 245))
                                                        endingColor:SRGBColor(dark ? rgb(41, 41, 44) : rgb(199, 199, 202))];
    [gradient drawInRect:bounds angle:-90];
    [SRGBColor(dark ? rgb(24, 24, 26) : rgb(164, 164, 168)) setFill];
    NSRectFill(NSIntersectionRect(dirty, NSMakeRect(0, 0, NSWidth(bounds), 1)));
}

@end

@class SourceWindow, SourceWindowController;

@interface SourceDocument (ProjectTabs)
- (SourceWindowController *)tabWindowController;
- (void)setTabWindowController:(SourceWindowController *)controller;
- (void)installEditor:(SourceWindowController *)controller;
- (void)requestTabClose;
- (void)splitTabRight;
- (void)copyTabIntoWindow:(NSWindow *)window;
- (EditorWindow *)editorView;
- (EditorWindow *)loadEditor;
@end

@interface SourceDocument (CloseReview)
- (void)beginCloseReview;
- (void)endCloseReview;
- (BOOL)waitForSaveBeforeClosing:(void (^)(void))resume;
- (NSUInteger)closeReviewRevision;
@end

@interface DocumentCloseReview : NSObject
- (instancetype)initWithDocuments:(NSArray<SourceDocument *> *)documents completion:(CloseReviewCompletion)completion;
- (void)advance;
@end

static DocumentCloseReview *activeCloseReview;

@implementation DocumentCloseReview {
    NSArray<SourceDocument *> *_documents;
    NSMapTable<SourceDocument *, NSNumber *> *_discarded;
    CloseReviewCompletion _completion;
    NSUInteger _next;
}

- (instancetype)initWithDocuments:(NSArray<SourceDocument *> *)documents completion:(CloseReviewCompletion)completion
{
    self = [super init];
    if (self) {
        _documents = [documents copy];
        _completion = [completion copy];
        _discarded = [NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}

- (void)finish:(NSSet<SourceDocument *> *)discarded
{
    _completion(discarded);
    for (SourceDocument *document in _documents)
        [document endCloseReview];
    activeCloseReview = nil;
}

- (void)advance
{
    while (_next < _documents.count) {
        SourceDocument *document = _documents[_next];
        if ([document waitForSaveBeforeClosing:^{
            self->_next = 0;
            [self advance];
        }])
            return;
        ++_next;
        if (![document needsCloseReview] || !document.isDocumentEdited) {
            [_discarded removeObjectForKey:document];
            continue;
        }
        NSUInteger revision = document.closeReviewRevision;
        NSNumber *approved = [_discarded objectForKey:document];
        if (approved && approved.unsignedIntegerValue == revision)
            continue;

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Save changes to “%@”?", document.displayName];
        if (document.fileURL)
            alert.informativeText = document.fileURL.URLByDeletingLastPathComponent.path.stringByAbbreviatingWithTildeInPath;
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"].keyEquivalent = @"\x1b";
        [alert addButtonWithTitle:@"Discard"].hasDestructiveAction = YES;
        NSModalResponse answer = [alert runModal];
        [alert.window orderOut:nil];
        if (answer == NSAlertFirstButtonReturn) {
            [document saveDocumentWithDelegate:self didSaveSelector:@selector(document:didSave:contextInfo:)
                                    contextInfo:nullptr];
            return;
        }
        if (answer != NSAlertThirdButtonReturn) {
            [self finish:nil];
            return;
        }
        [_discarded setObject:@(revision) forKey:document];
    }
    [self finish:[NSSet setWithArray:_discarded.keyEnumerator.allObjects]];
}

- (void)document:(NSDocument *)document didSave:(BOOL)saved contextInfo:(void *)context
{
    (void)document;
    (void)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (saved) {
            // A different editor may have changed while a save was in progress.
            self->_next = 0;
            [self advance];
        } else {
            [self finish:nil];
        }
    });
}

@end

void ReviewDocumentsForClosing(NSArray<SourceDocument *> *documents, CloseReviewCompletion completion)
{
    if (activeCloseReview || NSApp.modalWindow) {
        completion(nil);
        return;
    }
    for (SourceDocument *document in documents) {
        NSWindow *window = document.editorHostWindow;
        if (window.attachedSheet || window.tabGroup.selectedWindow.attachedSheet) {
            completion(nil);
            return;
        }
    }
    activeCloseReview = [[DocumentCloseReview alloc] initWithDocuments:documents completion:completion];
    for (SourceDocument *document in documents)
        [document beginCloseReview];
    [activeCloseReview advance];
}

@interface SourceDocument (FolderSearch)
- (BOOL)revealFolderSearchMatch:(NSRange)range pattern:(FolderSearchPattern *)pattern;
@end

struct EditorTabGroup {
    std::vector<__weak SourceDocument *> tabs;
    __weak SourceDocument *selected = nil;
    __weak EditorWindow *editor = nil;
    ProjectTabBar *bar = nil;
    NSView *container = nil;
};

struct EditorTabLocation {
    NSUInteger group = NSNotFound;
    NSUInteger index = NSNotFound;
};

@interface SourceWindowController : NSWindowController <NSSplitViewDelegate>
@property(nonatomic, readonly) NSButton *runButton;
@property(nonatomic, readonly) FolderWorkspace *workspace;
@property(nonatomic, readonly) BOOL windowClosed;
@property(nonatomic, readonly) BOOL usesPaneTabs;
@property(nonatomic, readonly) NSUInteger projectTabCount;
@property(nonatomic, readonly) BOOL projectTabBarShown;
- (instancetype)initWithSourceWindow:(SourceWindow *)window;
- (NSView *)commandPaletteHost;
- (void)installEditorView:(EditorWindow *)editor;
- (void)layoutEditorPane;
- (WindowOutput *)windowOutput;
- (void)syncWindowOutput;
- (void)restoreOutputShown:(BOOL)shown;
- (void)updateWorkspace;
- (void)restoreWorkspace:(FolderWorkspace *)workspace tabs:(NSArray<SourceDocument *> *)tabs selected:(SourceDocument *)selected;
- (NSArray<SourceDocument *> *)projectTabs;
- (NSArray<SourceDocument *> *)tabsInGroupOfDocument:(SourceDocument *)document;
- (void)revealCurrentFile;
- (void)showFolderSearchReplacing:(BOOL)replace;
- (void)updateLanguageHoverModifiers:(NSEvent *)event;
- (BOOL)hasDiagnostics;
- (BOOL)viewErrorAtCursor;
- (BOOL)editorHoverHasFocus;
- (void)addProjectDocument:(SourceDocument *)document;
- (void)addProjectDocument:(SourceDocument *)document inGroup:(NSUInteger)group;
- (BOOL)replaceProjectDocument:(SourceDocument *)document withDocument:(SourceDocument *)replacement;
- (void)removeProjectDocument:(SourceDocument *)document;
- (BOOL)selectProjectDocument:(SourceDocument *)document;
- (void)selectProjectTabAtIndex:(NSUInteger)index;
- (void)requestCloseProjectDocument:(SourceDocument *)document;
- (void)requestCloseEditorWindow;
- (void)cycleProjectTabs:(NSInteger)direction;
- (void)toggleProjectTabBar;
- (void)detachProjectDocument:(SourceDocument *)document;
- (SourceDocument *)projectDocumentAtWindowPoint:(NSPoint)point tabView:(NSView **)tabView;
- (EditorTabLocation)tabLocation:(SourceDocument *)document;
- (EditorTabLocation)tabInsertionAtWindowPoint:(NSPoint)point marker:(NSRect *)marker;
- (NSUInteger)editorGroupAtWindowPoint:(NSPoint)point;
- (NSRect)frameForEditorGroup:(NSUInteger)group;
- (BOOL)moveProjectDocument:(SourceDocument *)document to:(EditorTabLocation)location;
- (std::optional<DockSide>)editorDockSideAtPoint:(NSPoint)point;
- (void)showTabDropPreview:(NSRect)rect style:(DropPreviewStyle)style;
- (void)clearTabDropPreview;
- (BOOL)splitWithDocument:(SourceDocument *)document atSide:(DockSide)side;
- (void)endDocumentSplit;
- (void)editorFocusChanged;
- (SourceDocument *)focusedDocument;
- (BOOL)hasDocumentSplit;
- (BOOL)moveFocusInDocumentSplitFrom:(EditorWindow *)from key:(unichar)key;
- (void)mergeProjectWindows;
- (IBAction)toggleWorkspaceSidebar:(id)sender;
@end

static void SyncNativeTabOutput(NSWindow *window)
{
    NSWindowController *controller = window.windowController;
    if ([controller isKindOfClass:SourceWindowController.class])
        [(SourceWindowController *)controller syncWindowOutput];
}

SourceDocument *FocusedEditorDocument(NSWindow *window)
{
    NSWindowController *controller = window.windowController;
    if ([controller isKindOfClass:SourceWindowController.class])
        return [(SourceWindowController *)controller focusedDocument];
    return nil;
}

static BOOL MoveFocusInDocumentSplit(EditorWindow *from, unichar key)
{
    NSWindowController *controller = from.window.windowController;
    return [controller isKindOfClass:SourceWindowController.class] &&
        [(SourceWindowController *)controller moveFocusInDocumentSplitFrom:from key:key];
}

FolderWorkspace *WorkspaceForEditorWindow(NSWindow *window)
{
    NSWindowController *controller = window.windowController;
    return [controller isKindOfClass:SourceWindowController.class] ? ((SourceWindowController *)controller).workspace : nil;
}

BOOL ShowFolderSearch(NSWindow *window, BOOL replace)
{
    SourceWindowController *controller = (SourceWindowController *)window.windowController;
    if (![controller isKindOfClass:SourceWindowController.class] ||
        !controller.workspace || controller.windowClosed || window.attachedSheet)
        return NO;
    [controller showFolderSearchReplacing:replace];
    return YES;
}

NSArray<SourceDocument *> *EditorWindowTabs(NSWindow *window)
{
    SourceWindowController *controller = (SourceWindowController *)window.windowController;
    if (![controller isKindOfClass:SourceWindowController.class] || controller.windowClosed)
        return nil;
    if (controller.usesPaneTabs)
        return controller.projectTabs;
    NSMutableArray<SourceDocument *> *documents = [NSMutableArray array];
    NSArray<NSWindow *> *tabs = window.tabGroup.windows;
    for (NSWindow *tab in tabs.count ? tabs : @[window]) {
        NSDocument *document = tab.windowController.document;
        if ([document isKindOfClass:SourceDocument.class])
            [documents addObject:(SourceDocument *)document];
    }
    return documents.count ? documents : nil;
}

BOOL EditorWindowShowsTabBar(NSWindow *window)
{
    SourceWindowController *controller = (SourceWindowController *)window.windowController;
    return controller.usesPaneTabs ? controller.projectTabBarShown : window.tabGroup.isTabBarVisible;
}

BOOL EditorWindowOutputShown(NSWindow *window)
{
    SourceWindowController *controller = (SourceWindowController *)window.windowController;
    return controller.windowOutput.shown;
}

void RestoreEditorWindowOutput(NSWindow *window, BOOL shown)
{
    SourceWindowController *controller = (SourceWindowController *)window.windowController;
    [controller restoreOutputShown:shown];
}

void RequestEditorWindowClose(NSWindow *window)
{
    NSWindowController *controller = window.windowController;
    if ([controller isKindOfClass:SourceWindowController.class])
        [(SourceWindowController *)controller requestCloseEditorWindow];
}

NSView *CommandPaletteHost(NSWindow *window)
{
    NSWindowController *controller = window.windowController;
    if ([controller isKindOfClass:SourceWindowController.class])
        return [(SourceWindowController *)controller commandPaletteHost];
    return nil;
}

static NSMutableSet<SourceWindowController *> *EmptyProjectWindows()
{
    static NSMutableSet<SourceWindowController *> *windows = [[NSMutableSet alloc] init];
    return windows;
}

enum class TabCommand {
    Close, CloseOthers, CloseRight, CloseAll, CopyPath, CopyRelativePath, RevealInFinder, SplitRight,
    MoveToWindow, CopyToWindow, CopyToTab, Count
};

struct TabMenuEntry {
    NSString *title;
    unichar key;
    NSEventModifierFlags modifiers;
    bool separatorBefore;
};

static const TabMenuEntry tabMenuEntries[] = {
    {@"Close", 'w', 0, false},
    {@"Close Others", 't', NSEventModifierFlagOption | NSEventModifierFlagShift, false},
    {@"Close to the Right", 0, 0, false},
    {@"Close All", 'w', NSEventModifierFlagOption, false},
    {@"Copy Path", 'c', NSEventModifierFlagOption, true},
    {@"Copy Relative Path", 'c', NSEventModifierFlagOption | NSEventModifierFlagShift, false},
    {@"Reveal in Finder", 'r', NSEventModifierFlagOption, true},
    {@"Split Right", '\\', 0, true},
    {@"Move Into New Window", 0, 0, true},
    {@"Copy Into New Window", 'o', NSEventModifierFlagOption, false},
    {@"Copy Into New Tab", 0, 0, false},
};
static_assert(std::size(tabMenuEntries) == size_t(TabCommand::Count));

static BOOL TabActionsBlocked(NSWindow *window)
{
    return !window || window.attachedSheet || window.tabGroup.selectedWindow.attachedSheet ||
        activeCloseReview || NSApp.modalWindow;
}

static NSString *TabRelativePath(SourceDocument *document)
{
    return RelativeWorkspacePath(document.fileURL.path, document.workspace.folder.path);
}

static BOOL CanUseTabCommand(TabCommand command, SourceDocument *document, NSUInteger index, NSUInteger count)
{
    if (index == NSNotFound)
        return NO;

    switch (command) {
        case TabCommand::CloseOthers: return count > 1;
        case TabCommand::CloseRight: return index + 1 < count;
        case TabCommand::CopyPath:
        case TabCommand::RevealInFinder: return document.fileURL.isFileURL;
        case TabCommand::CopyRelativePath: return TabRelativePath(document) != nil;
        case TabCommand::MoveToWindow: {
            SourceWindowController *host = document.tabWindowController;
            return host ? host.workspace || host.projectTabCount > 1 : count > 1;
        }
        default: return YES;
    }
}

static NSString *const editorTabDragType = @"org.retina-code.editor-tab";

static NSView *NativeTabStripAtPoint(NSWindow *window, NSPoint point, NSView **button, BOOL *overControl)
{
    NSWindowTabGroup *group = window.tabGroup;
    if (!group.isTabBarVisible || NSPointInRect(point, window.contentLayoutRect))
        return nil;

    for (NSView *view = [window.contentView.superview hitTest:point]; view; view = view.superview) {
        NSString *role = view.accessibilityRole;
        if ([role isEqualToString:NSAccessibilityTabGroupRole])
            return view;
        if (button && [role isEqualToString:NSAccessibilityRadioButtonRole])
            *button = view;
        else if (overControl && (!button || !*button) &&
                 ([role isEqualToString:NSAccessibilityButtonRole] || [view isKindOfClass:NSButton.class]))
            *overControl = YES;
    }
    return nil;
}

static SourceDocument *NativeTabAtWindowPoint(NSWindow *window, NSPoint point, NSView **tabView = nullptr)
{
    NSView *button = nil;
    BOOL overControl = NO;
    NSView *strip = NativeTabStripAtPoint(window, point, &button, &overControl);
    if (!strip || !button)
        return nil;

    // AppKit lists its tab buttons and windows in the same order.
    NSArray *buttons = strip.accessibilityTabs;
    NSArray<NSWindow *> *windows = window.tabGroup.windows;
    NSUInteger index = [buttons indexOfObjectIdenticalTo:button];
    if (buttons.count != windows.count || index >= windows.count)
        return nil;
    if (tabView)
        *tabView = overControl ? nil : button;
    return (SourceDocument *)windows[index].windowController.document;
}

static TabInsertion NativeTabInsertionAtPoint(NSWindow *window, NSPoint point)
{
    NSView *strip = NativeTabStripAtPoint(window, point, nullptr, nullptr);
    if (!strip)
        return {};

    NSArray *tabs = strip.accessibilityTabs;
    if (tabs.count != window.tabGroup.windows.count)
        return {};

    NSRect viewport = [strip convertRect:strip.visibleRect toView:nil];
    NSUInteger index = 0;
    CGFloat screenX = [window convertPointToScreen:point].x;
    CGFloat edge = NSMinX([window convertRectToScreen:viewport]);
    for (id tab in tabs) {
        NSRect frame = [tab accessibilityFrame];
        if (screenX < NSMidX(frame)) {
            edge = NSMinX(frame);
            break;
        }
        edge = NSMaxX(frame);
        ++index;
    }

    CGFloat position = [window convertPointFromScreen:NSMakePoint(edge, 0)].x;
    return {index, TabInsertionMarker(window, viewport, position)};
}

struct TabDrop {
    EditorTabLocation insertion;
    std::optional<DockSide> side;
    NSRect preview = NSZeroRect;
    DropPreviewStyle style = DropPreviewStyle::Outline;
};

@interface SourceWindow : NSWindow <NSDraggingSource, NSDraggingDestination>
@property(nonatomic, weak) WindowHeader *header;
- (void)hideNativeTabBar;
- (IBAction)closeEditorWindow:(id)sender;
@end

static NSArray<SourceDocument *> *TabMenuDocuments(SourceDocument *document)
{
    SourceWindowController *host = document.tabWindowController;
    return host ? [host tabsInGroupOfDocument:document] : EditorWindowTabs(document.editorHostWindow);
}

@implementation SourceWindow {
    __weak SourceDocument *_pressedTab;
    __weak NSView *_pressedTabView;
    __weak SourceDocument *_draggedTab;
    __weak NSDraggingSession *_tabDragSession;
    NSPoint _tabPressPoint;
}

- (void)updateTabTitle
{
    if (!self.isDocumentEdited) {
        self.tab.attributedTitle = nil;
        self.tab.toolTip = nil;
        return;
    }
    NSString *title = self.title;
    NSMutableAttributedString *label = [[NSMutableAttributedString alloc] initWithString:@"●  "];
    [label addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:7] range:NSMakeRange(0, 1)];
    [label appendAttributedString:[[NSAttributedString alloc] initWithString:title]];
    self.tab.attributedTitle = label;
    self.tab.toolTip = [title stringByAppendingString:@" — Modified"];
}

- (void)setTitle:(NSString *)title
{
    [super setTitle:title];
    [self.header updateTitle];
    [self updateTabTitle];
}

- (void)setDocumentEdited:(BOOL)edited
{
    [super setDocumentEdited:edited];
    [self updateTabTitle];
}

- (void)setRepresentedURL:(NSURL *)url
{
    [super setRepresentedURL:url];
    [self.header updateTitle];
}

- (void)hideNativeTabBar
{
    if (self.tabGroup.isTabBarVisible && self.tabGroup.windows.count <= 1)
        [super toggleTabBar:nil];
}

- (SourceWindowController *)sourceController
{
    return (SourceWindowController *)self.windowController;
}

- (BOOL)makeFirstResponder:(NSResponder *)responder
{
    SourceWindowController *controller = self.sourceController;
    BOOL saveOnBlur = AutoSavePreference().mode == AutoSaveMode::OnFocusChange &&
        ([self.firstResponder isKindOfClass:CodeView.class] || controller.editorHoverHasFocus);
    if (responder != self.firstResponder)
        [[controller.focusedDocument editorView] rememberTabFocus];
    BOOL changed = [super makeFirstResponder:responder];
    if (changed) {
        if (saveOnBlur && !controller.editorHoverHasFocus && ![self.firstResponder isKindOfClass:CodeView.class])
            [controller.focusedDocument requestAutoSave:AutoSaveMode::OnFocusChange];
        [controller editorFocusChanged];
    }
    return changed;
}

- (void)performClose:(id)sender
{
    (void)sender;
    SourceWindowController *controller = self.sourceController;
    SourceDocument *document = controller.focusedDocument;
    if (document)
        [document requestTabClose];
    else
        [controller requestCloseEditorWindow];
}

- (IBAction)closeEditorWindow:(id)sender
{
    (void)sender;
    [self.sourceController requestCloseEditorWindow];
}

- (IBAction)selectNextTab:(id)sender
{
    if (self.sourceController.usesPaneTabs)
        [self.sourceController cycleProjectTabs:1];
    else
        [super selectNextTab:sender];
}

- (IBAction)selectPreviousTab:(id)sender
{
    if (self.sourceController.usesPaneTabs)
        [self.sourceController cycleProjectTabs:-1];
    else
        [super selectPreviousTab:sender];
}

- (IBAction)toggleTabBar:(id)sender
{
    if (self.sourceController.usesPaneTabs)
        [self.sourceController toggleProjectTabBar];
    else
        [super toggleTabBar:sender];
}

- (IBAction)moveTabToNewWindow:(id)sender
{
    if (self.sourceController.usesPaneTabs)
        [self.sourceController detachProjectDocument:self.sourceController.document];
    else
        [super moveTabToNewWindow:sender];
}

- (IBAction)mergeAllWindows:(id)sender
{
    if (self.sourceController.usesPaneTabs)
        [self.sourceController mergeProjectWindows];
    else
        [super mergeAllWindows:sender];
}

- (BOOL)performTabCommand:(TabCommand)command document:(SourceDocument *)document
{
    NSWindow *window = document.editorHostWindow;
    if (TabActionsBlocked(window))
        return NO;

    NSArray<SourceDocument *> *tabs = TabMenuDocuments(document);
    NSUInteger index = tabs ? [tabs indexOfObjectIdenticalTo:document] : NSNotFound;
    if (!CanUseTabCommand(command, document, index, tabs.count))
        return NO;

    switch (command) {
        case TabCommand::Close:
            [document requestTabClose];
            break;
        case TabCommand::CloseOthers:
        case TabCommand::CloseRight:
        case TabCommand::CloseAll: {
            NSArray<SourceDocument *> *closing = tabs;
            if (command == TabCommand::CloseOthers) {
                NSMutableArray *others = [tabs mutableCopy];
                [others removeObjectAtIndex:index];
                closing = others;
            } else if (command == TabCommand::CloseRight) {
                closing = [tabs subarrayWithRange:NSMakeRange(index + 1, tabs.count - index - 1)];
            }

            ReviewDocumentsForClosing(closing, ^(NSSet<SourceDocument *> *discarded) {
                if (!discarded || ![TabMenuDocuments(document) isEqualToArray:tabs])
                    return;
                for (SourceDocument *tab in closing)
                    [tab close];
            });
            break;
        }
        case TabCommand::CopyPath:
        case TabCommand::CopyRelativePath: {
            NSString *path = command == TabCommand::CopyPath ? document.fileURL.path : TabRelativePath(document);
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            [board clearContents];
            [board setString:path forType:NSPasteboardTypeString];
            break;
        }
        case TabCommand::RevealInFinder:
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[document.fileURL]];
            break;
        case TabCommand::SplitRight:
            [document splitTabRight];
            break;
        case TabCommand::MoveToWindow:
            if (document.tabWindowController)
                [document.tabWindowController detachProjectDocument:document];
            else
                [(SourceWindow *)window moveTabToNewWindow:nil];
            break;
        case TabCommand::CopyToWindow:
        case TabCommand::CopyToTab:
            [document copyTabIntoWindow:command == TabCommand::CopyToTab ? window : nil];
            break;
        case TabCommand::Count:
            return NO;
    }
    return YES;
}

- (IBAction)tabMenuCommand:(NSMenuItem *)item
{
    [self performTabCommand:TabCommand(item.tag) document:item.representedObject];
}

- (NSMenu *)contextMenuForTab:(SourceDocument *)document
{
    NSArray<SourceDocument *> *tabs = TabMenuDocuments(document);
    if (!tabs)
        return nil;

    NSUInteger index = [tabs indexOfObjectIdenticalTo:document];
    if (index == NSNotFound)
        return nil;

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    for (NSUInteger i = 0; i < std::size(tabMenuEntries); ++i) {
        const auto &entry = tabMenuEntries[i];
        if (entry.separatorBefore)
            [menu addItem:NSMenuItem.separatorItem];

        NSString *key = entry.key ? [NSString stringWithCharacters:&entry.key length:1] : @"";
        NSMenuItem *item = [menu addItemWithTitle:entry.title action:@selector(tabMenuCommand:) keyEquivalent:key];
        item.keyEquivalentModifierMask = NSEventModifierFlagCommand | entry.modifiers;
        item.tag = i;
        item.target = self;
        item.representedObject = document;
        item.enabled = CanUseTabCommand(TabCommand(i), document, index, tabs.count);
    }
    return menu;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSEventModifierFlags mask = NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                NSEventModifierFlagControl | NSEventModifierFlagShift;
    NSEventModifierFlags modifiers = event.modifierFlags & mask;
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length == 1 ? [characters characterAtIndex:0] : 0;
    SourceWindowController *controller = self.sourceController;
    if (key && (modifiers & NSEventModifierFlagCommand) && controller.focusedDocument) {
        unichar lower = key >= 'A' && key <= 'Z' ? key + ('a' - 'A') : key;
        // Cmd+W is already handled by the File menu.
        for (NSUInteger i = 1; i < std::size(tabMenuEntries); ++i) {
            const auto &entry = tabMenuEntries[i];
            if (lower == entry.key && modifiers == (NSEventModifierFlagCommand | entry.modifiers) &&
                [self performTabCommand:TabCommand(i) document:controller.focusedDocument])
                return YES;
        }
    }

    if (modifiers == NSEventModifierFlagCommand && key >= '1' && key <= '9' && !self.attachedSheet) {
        NSUInteger index = key - '1';
        if (controller.usesPaneTabs) {
            [controller selectProjectTabAtIndex:index];
        } else {
            NSWindowTabGroup *group = self.tabGroup;
            NSArray<NSWindow *> *tabs = group.windows;
            if (index < tabs.count)
                group.selectedWindow = tabs[index];
        }
        return YES;
    }
    if (controller.projectTabCount > 1 && !self.attachedSheet &&
        (modifiers == NSEventModifierFlagControl || modifiers == (NSEventModifierFlagControl | NSEventModifierFlagShift)) &&
        (key == NSTabCharacter || key == NSBackTabCharacter)) {
        [controller cycleProjectTabs:modifiers & NSEventModifierFlagShift ? -1 : 1];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (SourceDocument *)tabAtPoint:(NSPoint)point view:(NSView **)view
{
    SourceWindowController *controller = self.sourceController;
    return controller.usesPaneTabs ? [controller projectDocumentAtWindowPoint:point tabView:view] :
        NativeTabAtWindowPoint(self, point, view);
}

- (void)beginDraggingTab:(SourceDocument *)document view:(NSView *)tab event:(NSEvent *)event
{
    NSRect bounds = tab.bounds;
    NSBitmapImageRep *bitmap = [tab bitmapImageRepForCachingDisplayInRect:bounds];
    if (!bitmap)
        return;

    [tab cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
    NSImage *snapshot = [[NSImage alloc] initWithSize:bounds.size];
    [snapshot addRepresentation:bitmap];
    NSImage *ghost = [NSImage imageWithSize:bounds.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor.controlBackgroundColor colorWithAlphaComponent:0.72] setFill];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
        [snapshot drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.60];
        return YES;
    }];

    NSPasteboardItem *marker = [[NSPasteboardItem alloc] init];
    [marker setString:@"tab" forType:editorTabDragType];
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:marker];
    NSView *content = self.contentView;
    [item setDraggingFrame:[tab convertRect:bounds toView:content] contents:ghost];
    _draggedTab = document;
    NSDraggingSession *session = [content beginDraggingSessionWithItems:@[item] event:event source:self];
    session.animatesToStartingPositionsOnCancelOrFail = YES;
    _tabDragSession = session;
}

- (BOOL)trackTabEvent:(NSEvent *)event
{
    if (event.type == NSEventTypeLeftMouseDown && !TabActionsBlocked(self)) {
        NSView *tabView = nil;
        SourceDocument *document = [self tabAtPoint:event.locationInWindow view:&tabView];
        if (tabView && document) {
            _pressedTab = document;
            _pressedTabView = tabView;
            _tabPressPoint = event.locationInWindow;
            return YES;
        }
    }

    SourceDocument *document = _pressedTab;
    if (!document)
        return NO;
    if (event.type == NSEventTypeLeftMouseDragged) {
        NSPoint point = event.locationInWindow;
        if (std::hypot(point.x - _tabPressPoint.x, point.y - _tabPressPoint.y) >= 5) {
            NSView *tab = _pressedTabView;
            _pressedTab = nil;
            _pressedTabView = nil;
            if (tab.window == self && !TabActionsBlocked(self))
                [self beginDraggingTab:document view:tab event:event];
        }
        return YES;
    }
    if (event.type == NSEventTypeLeftMouseUp ||
        (event.type == NSEventTypeKeyDown && event.keyCode == 53)) {
        _pressedTab = nil;
        _pressedTabView = nil;
        if (event.type == NSEventTypeLeftMouseUp && [self tabAtPoint:event.locationInWindow view:nullptr] == document)
            [document showWindows];
        return YES;
    }
    return NO;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    (void)session;
    return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session
{
    (void)session;
    return YES;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation
{
    (void)session;
    (void)point;
    (void)operation;
    _draggedTab = nil;
    _tabDragSession = nil;
    [self.sourceController clearTabDropPreview];
}

- (SourceDocument *)tabFromDrag:(id<NSDraggingInfo>)info
{
    if (TabActionsBlocked(self) || ![info.draggingSource isKindOfClass:SourceWindow.class])
        return nil;
    SourceWindow *source = info.draggingSource;
    SourceDocument *document = source->_draggedTab;
    if (!document || document.workspace != self.sourceController.workspace || TabActionsBlocked(document.editorHostWindow))
        return nil;
    return document;
}

- (TabDrop)tabDropAtPoint:(NSPoint)point document:(SourceDocument *)document
{
    TabDrop drop;
    SourceWindowController *controller = self.sourceController;
    if (controller.usesPaneTabs) {
        drop.insertion = [controller tabInsertionAtWindowPoint:point marker:&drop.preview];
        if (drop.insertion.group != NSNotFound) {
            drop.style = DropPreviewStyle::Insertion;
            return drop;
        }

        if (controller.hasDocumentSplit) {
            NSUInteger group = [controller editorGroupAtWindowPoint:point];
            if (group != NSNotFound && group != [controller tabLocation:document].group) {
                drop.insertion = {group, NSNotFound};
                drop.preview = [controller frameForEditorGroup:group];
            }
            return drop;
        }
    } else {
        TabInsertion insertion = NativeTabInsertionAtPoint(self, point);
        if (insertion.index != NSNotFound) {
            drop.insertion = {0, insertion.index};
            drop.preview = insertion.marker;
            drop.style = DropPreviewStyle::Insertion;
            return drop;
        }
    }

    NSWindow *source = document.editorHostWindow;
    BOOL sameWindow = source == self || (source.tabGroup && source.tabGroup == self.tabGroup);
    NSUInteger count = controller.usesPaneTabs ? controller.projectTabCount : self.tabGroup.windows.count;
    if (!sameWindow || count > 1) {
        drop.side = [controller editorDockSideAtPoint:point];
        if (drop.side)
            drop.preview = SplitDockRect([controller frameForEditorGroup:0], *drop.side);
    }
    return drop;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    return [self draggingUpdated:info];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info
{
    SourceDocument *document = [self tabFromDrag:info];
    TabDrop drop = document ? [self tabDropAtPoint:info.draggingLocation document:document] : TabDrop{};
    [self.sourceController showTabDropPreview:drop.preview style:drop.style];
    return drop.side || drop.insertion.group != NSNotFound ? NSDragOperationMove : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)info
{
    (void)info;
    [self.sourceController clearTabDropPreview];
}

- (void)draggingEnded:(id<NSDraggingInfo>)info
{
    [self draggingExited:info];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
    return [self draggingUpdated:info] == NSDragOperationMove;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    [self draggingExited:info];
    SourceDocument *document = [self tabFromDrag:info];
    return document && [self dropTab:document atPoint:info.draggingLocation];
}

- (BOOL)dropTab:(SourceDocument *)document atPoint:(NSPoint)point
{
    SourceWindowController *controller = self.sourceController;
    if (TabActionsBlocked(self) || document.workspace != controller.workspace)
        return NO;

    TabDrop drop = [self tabDropAtPoint:point document:document];
    if (!drop.side && drop.insertion.group == NSNotFound)
        return NO;

    NSArray<SourceDocument *> *tabs = EditorWindowTabs(self);
    NSUInteger previous = tabs ? [tabs indexOfObjectIdenticalTo:document] : NSNotFound;
    if (previous == NSNotFound && ![document joinNavigationTabInWindow:self])
        return NO;

    if (drop.side)
        return [controller splitWithDocument:document atSide:*drop.side];
    if (controller.usesPaneTabs)
        return [controller moveProjectDocument:document to:drop.insertion];

    NSUInteger index = drop.insertion.index - (previous != NSNotFound && previous < drop.insertion.index);
    if (index != previous)
        [self.tabGroup insertWindow:document.editorHostWindow atIndex:index];
    [document showWindows];
    return YES;
}

- (void)sendEvent:(NSEvent *)event
{
    if (event.type == NSEventTypeKeyDown && event.keyCode == 53 && _draggedTab) {
        _draggedTab = nil;
        [self.sourceController clearTabDropPreview];
        return;
    }
    if (event.type == NSEventTypeLeftMouseUp && _draggedTab) {
        // A quick release can reach the window before AppKit enters drag tracking.
        SourceDocument *document = _draggedTab;
        _draggedTab = nil;
        [self.sourceController clearTabDropPreview];
        if ([self dropTab:document atPoint:event.locationInWindow])
            _tabDragSession.animatesToStartingPositionsOnCancelOrFail = NO;
        return;
    }

    BOOL contextClick = event.type == NSEventTypeRightMouseDown ||
        (event.type == NSEventTypeLeftMouseDown && (event.modifierFlags & NSEventModifierFlagControl));
    if (contextClick && !TabActionsBlocked(self)) {
        NSPoint point = event.locationInWindow;
        SourceDocument *tab = [self tabAtPoint:point view:nullptr];
        if (tab) {
            if (NSMenu *menu = [self contextMenuForTab:tab]) {
                [NSMenu popUpContextMenu:menu withEvent:event forView:self.contentView];
                return;
            }
        }
    }

    if (!contextClick && [self trackTabEvent:event])
        return;

    if (event.type == NSEventTypeKeyDown && !self.attachedSheet) {
        constexpr NSEventModifierFlags modifiers = NSEventModifierFlagShift | NSEventModifierFlagControl |
            NSEventModifierFlagOption | NSEventModifierFlagCommand;
        if ((event.modifierFlags & modifiers) == NSEventModifierFlagOption) {
            NSString *key = event.charactersIgnoringModifiers;
            if (key.length == 1 && [key characterAtIndex:0] == NSF8FunctionKey && [self.sourceController viewErrorAtCursor])
                return;
        }
    }
    [super sendEvent:event];
    if (event.type == NSEventTypeFlagsChanged)
        [self.sourceController updateLanguageHoverModifiers:event];
}

- (IBAction)toggleExplorer:(id)sender
{
    [self.sourceController toggleWorkspaceSidebar:sender];
}

- (IBAction)toggleDocumentOutput:(id)sender
{
    (void)sender;
    [self.sourceController.windowOutput toggleDockPage:DockPage::Output];
}

- (IBAction)viewError:(id)sender
{
    (void)sender;
    [self.sourceController viewErrorAtCursor];
}

- (IBAction)closeEditorSplit:(id)sender
{
    SourceWindowController *controller = self.sourceController;
    if (!TabActionsBlocked(self) && controller.hasDocumentSplit)
        [controller endDocumentSplit];
    else
        [controller.document closeEditorSplit:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SourceWindowController *controller = self.sourceController;
    FolderWorkspace *workspace = controller.workspace;
    SEL action = item.action;
    if (action == @selector(closeEditorSplit:))
        return !TabActionsBlocked(self) && (controller.hasDocumentSplit || [controller.document validateMenuItem:item]);
    if (action == @selector(viewError:))
        return !self.attachedSheet && controller.hasDiagnostics;
    if (action == @selector(toggleDocumentOutput:)) {
        item.state = controller.windowOutput.shown ? NSControlStateValueOn : NSControlStateValueOff;
        return !self.attachedSheet;
    }
    if (action == @selector(toggleExplorer:)) {
        item.title = workspace.sidebarShown ? @"Hide Sidebar" : @"Show Sidebar";
        return workspace != nil;
    }
    if (controller.usesPaneTabs) {
        if (action == @selector(toggleTabBar:)) {
            item.title = controller.projectTabBarShown ? @"Hide Tab Bar" : @"Show Tab Bar";
            return controller.projectTabCount == 1;
        }
        if (action == @selector(moveTabToNewWindow:))
            return (workspace ? controller.projectTabCount > 0 : controller.projectTabCount > 1) && !TabActionsBlocked(self);
        if (action == @selector(selectNextTab:) || action == @selector(selectPreviousTab:))
            return controller.projectTabCount > 1 && !self.attachedSheet;
        if (action == @selector(mergeAllWindows:)) {
            NSArray *documents = workspace ? workspace.documents : NSDocumentController.sharedDocumentController.documents;
            for (SourceDocument *document in documents) {
                if ([document isKindOfClass:SourceDocument.class] && document.workspace == workspace &&
                    document.editorHostWindow && document.editorHostWindow != self)
                    return YES;
            }
            return NO;
        }
    }
    return [super validateMenuItem:item];
}

@end

@interface ExplorerSplitView : NSSplitView
@end

@implementation ExplorerSplitView
- (void)drawDividerInRect:(NSRect)rect
{
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(rect);
    [NSColor.separatorColor setFill];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
}
@end

@interface WorkspaceEditorPane : NSView <NSDraggingDestination>
- (void)setThemePreview:(const ThemeRef &)palette;
@end

@implementation WorkspaceEditorPane {
    ThemeRef _themePreview;
}

- (BOOL)isOpaque { return YES; }

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    [super resizeSubviewsWithOldSize:oldSize];
    [((SourceWindow *)self.window).sourceController layoutEditorPane];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [(SourceWindow *)self.window draggingEntered:info]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return [(SourceWindow *)self.window draggingUpdated:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { [(SourceWindow *)self.window draggingExited:info]; }
- (void)draggingEnded:(id<NSDraggingInfo>)info { [(SourceWindow *)self.window draggingEnded:info]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { return [(SourceWindow *)self.window prepareForDragOperation:info]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info { return [(SourceWindow *)self.window performDragOperation:info]; }

- (void)setThemePreview:(const ThemeRef &)palette
{
    if (_themePreview != palette) {
        _themePreview = palette;
        self.needsDisplay = YES;
    }
}

- (void)drawRect:(NSRect)dirty
{
    auto palette = _themePreview ? _themePreview : SelectedTheme();
    [SRGBColor(palette->paper) setFill];
    NSRectFill(dirty);
}

@end

void PreviewEditorTheme(NSView *host, NSInteger index)
{
    if (!host)
        return;
    ThemeRef palette = index >= 0 ? ThemeAt(index) : ThemeRef{};
    if ([host isKindOfClass:EditorWindow.class]) {
        EditorWindow *editor = (EditorWindow *)host;
        if (!palette)
            palette = SelectedTheme();
        if (editor.editor.theme != palette.get())
            [editor applyPreferencesWithTheme:palette];
    } else if ([host isKindOfClass:WorkspaceEditorPane.class]) {
        [(WorkspaceEditorPane *)host setThemePreview:palette];
    }
}

static char windowOutputKey;

@implementation SourceWindowController {
    __weak EditorWindow *_installedEditor;
    WindowOutput *_windowOutput;
    __weak WindowOutput *_attachedOutput;
    FolderWorkspace *_workspace;
    FolderSidebar *_sidebar;
    NSSplitView *_editorSplit;
    NSView *_editorContent;
    NSView *_editorPane;
    EditorTabGroup _groups[2];
    NSSplitView *_documentSplit;
    DockDropTarget *_tabDropPreview;
    DockSide _documentSplitSide;
    BOOL _usesPaneTabs;
    BOOL _updatingEditorGroups;
    BOOL _hideSingleProjectTab;
    BOOL _restoringProject;
    NSTitlebarAccessoryViewController *_sidebarAccessory;
    NSButton *_sidebarButton;
    BOOL _layingOutExplorer;
    CGFloat _splitWidth;
}

- (instancetype)initWithSourceWindow:(SourceWindow *)window
{
    self = [super initWithWindow:window];
    if (!self)
        return nil;

    // Paint behind AppKit's controls and keep the editor inside its usable content area.
    NSRect frame = window.frame;
    window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    [window setFrame:frame display:NO];
    NSButton *close = [window standardWindowButton:NSWindowCloseButton];
    close.target = window;
    close.action = @selector(closeEditorWindow:);

    NSRect runFrame = NSMakeRect(0, 0, 28, 24);
    NSView *runContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSMaxX(runFrame) + 4, NSHeight(runFrame))];
    _runButton = MakeTitleRunControl(runFrame, @selector(runDocument:));
    _runButton.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    SetRunButton(_runButton, RunButtonAction::Run);
    [runContainer addSubview:_runButton];

    NSButton *debugButton = MakeTitleRunControl(runFrame, nullptr);
    debugButton.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    debugButton.target = self;
    debugButton.tag = titleDebugButtonTag;
    debugButton.contentTintColor = NSColor.secondaryLabelColor;
    debugButton.hidden = YES;
    [runContainer addSubview:debugButton];

    NSTitlebarAccessoryViewController *runAccessory = [[NSTitlebarAccessoryViewController alloc] init];
    runAccessory.layoutAttribute = NSLayoutAttributeRight;
    runAccessory.view = runContainer;
    [window addTitlebarAccessoryViewController:runAccessory];

    _sidebarButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 26, 24)];
    [_sidebarButton setButtonType:NSButtonTypeMomentaryPushIn];
    _sidebarButton.bordered = NO;
    _sidebarButton.imagePosition = NSImageOnly;
    _sidebarButton.target = self;
    _sidebarButton.action = @selector(toggleWorkspaceSidebar:);
    NSImage *sidebar = [NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:@"Sidebar"];
    _sidebarButton.image = [sidebar imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]];
    _sidebarAccessory = [[NSTitlebarAccessoryViewController alloc] init];
    _sidebarAccessory.layoutAttribute = NSLayoutAttributeLeft;
    _sidebarAccessory.view = _sidebarButton;

    NSView *content = window.contentView;
    NSLayoutGuide *layout = window.contentLayoutGuide;
    WindowHeader *header = [[WindowHeader alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:header];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:content.topAnchor],
        [header.bottomAnchor constraintEqualToAnchor:layout.topAnchor]
    ]];
    window.header = header;
    [header updateTitle];
    [window registerForDraggedTypes:@[editorTabDragType]];

    _editorSplit = [[ExplorerSplitView alloc] initWithFrame:[content convertRect:window.contentLayoutRect fromView:nil]];
    _editorSplit.translatesAutoresizingMaskIntoConstraints = NO;
    _editorSplit.vertical = YES;
    _editorSplit.dividerStyle = NSSplitViewDividerStyleThin;
    _editorSplit.delegate = self;
    [content addSubview:_editorSplit];
    [NSLayoutConstraint activateConstraints:@[
        [_editorSplit.leadingAnchor constraintEqualToAnchor:layout.leadingAnchor],
        [_editorSplit.trailingAnchor constraintEqualToAnchor:layout.trailingAnchor],
        [_editorSplit.topAnchor constraintEqualToAnchor:layout.topAnchor],
        [_editorSplit.bottomAnchor constraintEqualToAnchor:layout.bottomAnchor]
    ]];

    _editorContent = [[NSView alloc] initWithFrame:_editorSplit.bounds];
    _editorContent.clipsToBounds = YES;
    [_editorSplit addArrangedSubview:_editorContent];
    _editorPane = [[WorkspaceEditorPane alloc] initWithFrame:_editorContent.bounds];
    _editorPane.clipsToBounds = YES;
    [_editorPane registerForDraggedTypes:@[editorTabDragType]];
    [_editorContent addSubview:_editorPane];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(workspaceWindowActivated:)
                                               name:NSWindowDidBecomeKeyNotification object:window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorWindowResignedKey:)
                                               name:NSWindowDidResignKeyNotification object:window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorWindowEndedSheet:)
                                               name:NSWindowDidEndSheetNotification object:window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorWindowClosed:)
                                               name:NSWindowWillCloseNotification object:window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorPreferencesChanged:)
                                               name:EditorPreferencesChanged object:nil];
    return self;
}

- (FolderWorkspace *)workspace { return _windowClosed ? nil : _workspace; }

- (void)editorWindowClosed:(NSNotification *)notification
{
    (void)notification;
    _windowClosed = YES;
    if (_usesPaneTabs || self.window.tabGroup.windows.count <= 1)
        [[self windowOutput] stopDebug];
    [EmptyProjectWindows() removeObject:self];
}

- (void)editorPreferencesChanged:(NSNotification *)notification
{
    (void)notification;
    if (!self.primaryEditor)
        _editorPane.needsDisplay = YES;
}

- (void)editorWindowResignedKey:(NSNotification *)notification
{
    (void)notification;
    AutoSaveMode mode = AutoSavePreference().mode;
    if (mode == AutoSaveMode::OnFocusChange || mode == AutoSaveMode::OnWindowChange) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self autoSaveOnWindowChangeTo:NSApp.keyWindow];
        });
    }
}

- (void)autoSaveOnWindowChangeTo:(NSWindow *)nextWindow
{
    NSWindow *window = self.window;
    AutoSaveMode mode = AutoSavePreference().mode;
    if (_windowClosed || nextWindow == window || nextWindow.sheetParent == window ||
        (mode != AutoSaveMode::OnFocusChange && mode != AutoSaveMode::OnWindowChange))
        return;
    if (_usesPaneTabs) {
        for (const auto &group : _groups)
            for (SourceDocument *document : group.tabs)
                [document requestAutoSave:mode];
    } else {
        NSArray<NSWindow *> *tabs = window.tabGroup.windows;
        if (nextWindow && [tabs containsObject:nextWindow]) {
            [(SourceDocument *)self.document requestAutoSave:AutoSaveMode::OnFocusChange];
        } else if (tabs.count) {
            for (NSWindow *tab in tabs)
                [(SourceDocument *)tab.windowController.document requestAutoSave:mode];
        } else {
            [(SourceDocument *)self.document requestAutoSave:mode];
        }
    }
}

- (void)editorWindowEndedSheet:(NSNotification *)notification
{
    (void)notification;
    if (_usesPaneTabs) {
        for (const auto &group : _groups)
            for (SourceDocument *document : group.tabs)
                [document resumePendingAutoSave];
    } else {
        [(SourceDocument *)self.document resumePendingAutoSave];
    }
}

- (void)installEditorView:(EditorWindow *)editor
{
    if (_installedEditor != editor) {
        [_installedEditor rememberTabFocus];
        _installedEditor.runButton = nil;
        [_installedEditor setWindowOutput:nil];
        [_installedEditor removeFromSuperview];
    }
    if (!_documentSplit && editor.superview != _editorPane)
        [_editorPane addSubview:editor];

    editor.translatesAutoresizingMaskIntoConstraints = YES;
    editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.initialFirstResponder = editor.tabFocus;
    _installedEditor = editor;
    [self updateWorkspace];
}

- (WindowOutput *)windowOutput
{
    // AppKit gives each native tab its own NSWindow, with one tab group for the window on screen.
    NSWindowTabGroup *group = _usesPaneTabs ? nil : self.window.tabGroup;
    if (!group) {
        if (!_windowOutput)
            _windowOutput = [[WindowOutput alloc] initWithFrame:NSZeroRect];
        return _windowOutput;
    }
    WindowOutput *output = objc_getAssociatedObject(group, &windowOutputKey);
    if (!output) {
        output = _windowOutput ? _windowOutput : [[WindowOutput alloc] initWithFrame:NSZeroRect];
        objc_setAssociatedObject(group, &windowOutputKey, output, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [output observeTabGroup:group];
    }
    _windowOutput = nil;
    return output;
}

- (void)syncWindowOutput
{
    if (_windowClosed)
        return;

    WindowOutput *output = self.windowOutput;
    WindowOutput *mounted = _attachedOutput;
    if (mounted != output && mounted.superview == _editorContent) {
        mounted.host = nil;
        [mounted removeFromSuperview];
        _attachedOutput = nil;
    }

    EditorWindow *primary = self.primaryEditor;
    EditorWindow *secondary = _groups[1].editor;
    [primary setWindowOutput:output];
    [secondary setWindowOutput:output];
    NSWindow *selected = _usesPaneTabs ? nil : self.window.tabGroup.selectedWindow;
    if (selected && selected != self.window)
        return;

    _attachedOutput = output;
    [output attachTo:_editorContent editorPane:_editorPane];
    EditorWindow *active = [self.focusedDocument editorView];
    output.otherEditor = active == primary ? secondary : primary;
    if (output.host != active) {
        output.host = active;
        [active refreshLanguageServices];
        [active updateLanguageDiagnostics];
    }
    [active resumeLanguageCheck];
    [self workspaceRunChanged:nil];
}

- (void)restoreOutputShown:(BOOL)shown
{
    [self syncWindowOutput];
    self.windowOutput.shown = shown;
}

- (NSView *)commandPaletteHost
{
    EditorWindow *editor = [self.focusedDocument editorView];
    return editor ? editor : _editorPane;
}

- (void)updateLanguageHoverModifiers:(NSEvent *)event
{
    [self.primaryEditor updateLanguageHoverModifiers:event];
    [_groups[1].editor updateLanguageHoverModifiers:event];
}

- (BOOL)hasDiagnostics { return [self.focusedDocument editorView].hasDiagnostics; }
- (BOOL)viewErrorAtCursor { return [[self.focusedDocument editorView] viewErrorAtCursor]; }
- (BOOL)editorHoverHasFocus { return [self.focusedDocument editorView].activeEditor.hoverHasFocus; }

- (BOOL)usesPaneTabs { return _usesPaneTabs; }
- (BOOL)hasDocumentSplit { return _documentSplit != nil; }
- (SourceDocument *)focusedDocument { return self.document; }

- (NSUInteger)projectTabCount
{
    return _groups[0].tabs.size() + _groups[1].tabs.size();
}

- (EditorTabLocation)tabLocation:(SourceDocument *)document
{
    for (NSUInteger group = 0; group < std::size(_groups); ++group) {
        const auto &tabs = _groups[group].tabs;
        for (NSUInteger index = 0; index < tabs.size(); ++index) {
            if (tabs[index] == document)
                return {group, index};
        }
    }
    return {};
}

static void AppendGroupTabs(NSMutableArray<SourceDocument *> *list, const EditorTabGroup &group)
{
    for (SourceDocument *document : group.tabs) {
        if (document)
            [list addObject:document];
    }
}

- (NSArray<SourceDocument *> *)projectTabs
{
    NSMutableArray<SourceDocument *> *tabs = [NSMutableArray arrayWithCapacity:self.projectTabCount];
    BOOL secondaryFirst = _documentSplit && SplitDockFirst(_documentSplitSide);
    AppendGroupTabs(tabs, _groups[secondaryFirst ? 1 : 0]);
    AppendGroupTabs(tabs, _groups[secondaryFirst ? 0 : 1]);
    return tabs;
}

- (NSArray<SourceDocument *> *)tabsInGroupOfDocument:(SourceDocument *)document
{
    EditorTabLocation location = [self tabLocation:document];
    if (location.group == NSNotFound)
        return nil;

    const auto &group = _groups[location.group];
    NSMutableArray<SourceDocument *> *tabs = [NSMutableArray arrayWithCapacity:group.tabs.size()];
    AppendGroupTabs(tabs, group);
    return tabs;
}

- (BOOL)projectTabBarShown
{
    return _documentSplit || self.projectTabCount > 1 || (self.projectTabCount && !_hideSingleProjectTab);
}

- (EditorWindow *)primaryEditor
{
    return _usesPaneTabs ? _groups[0].editor : _installedEditor;
}

- (NSView *)containerForGroup:(NSUInteger)group
{
    return _documentSplit ? _groups[group].container : _editorPane;
}

- (void)layoutEditorPane
{
    if (!_usesPaneTabs) {
        _installedEditor.frame = _editorPane.bounds;
        return;
    }

    if (_documentSplit && !NSEqualRects(_documentSplit.frame, _editorPane.bounds)) {
        _documentSplit.frame = _editorPane.bounds;
        [_documentSplit adjustSubviews];
    }

    NSUInteger count = _documentSplit ? 2 : 1;
    for (NSUInteger index = 0; index < count; ++index) {
        auto &group = _groups[index];
        NSRect body = [self containerForGroup:index].bounds;
        CGFloat height = self.projectTabBarShown ? std::min(projectTabBarHeight, NSHeight(body)) : 0;
        body.size.height -= height;
        group.bar.hidden = height == 0;
        group.bar.frame = NSMakeRect(0, NSMaxY(body), NSWidth(body), height);
        group.editor.frame = body;
    }
}

- (BOOL)moveFocusInDocumentSplitFrom:(EditorWindow *)from key:(unichar)key
{
    if (!_documentSplit)
        return NO;

    BOOL first = from == _groups[0].editor;
    SourceDocument *other = _groups[first ? 1 : 0].selected;
    if (key == 'c' || key == 'q' || key == 'o') {
        SourceDocument *keep = key == 'o' ? self.focusedDocument : other;
        [self endDocumentSplit];
        [self selectProjectDocument:keep];
        return YES;
    }

    bool horizontal = key == 'h' || key == 'l';
    bool vertical = key == 'j' || key == 'k';
    if (horizontal || vertical) {
        bool forward = key == 'l' || key == 'j';
        bool toward = forward == (first != SplitDockFirst(_documentSplitSide));
        if (DockIsSide(_documentSplitSide) == horizontal && toward)
            [self selectProjectDocument:other];
        return YES;
    }
    if (key == 'w' || key == 'W' || key == 'p')
        return [self selectProjectDocument:other];
    return NO;
}

- (void)activateTabDocument:(SourceDocument *)document
{
    SourceDocument *previous = self.document;
    EditorWindow *editor = [document editorView];
    if (document != previous) {
        [previous requestAutoSave:AutoSaveMode::OnFocusChange];
        [previous editorView].runButton = nil;
        [document addWindowController:self];
        [self synchronizeWindowTitleWithDocumentName];
        self.window.documentEdited = document.isDocumentEdited;
    }

    editor.runButton = _runButton;
    _runButton.target = document;
    self.window.initialFirstResponder = editor.tabFocus;
    [EmptyProjectWindows() removeObject:self];
    [self syncWindowOutput];
    if (document != previous) {
        _workspace.selectedDocument = document;
        [self revealCurrentFile];
    }
}

- (void)editorFocusChanged
{
    if (_updatingEditorGroups)
        return;

    NSResponder *responder = self.window.firstResponder;
    if (_documentSplit && [responder isKindOfClass:NSView.class]) {
        for (const auto &group : _groups) {
            if (group.editor && self.document != group.selected && [(NSView *)responder isDescendantOf:group.editor]) {
                [self activateTabDocument:group.selected];
                return;
            }
        }
    }
    [[self.focusedDocument editorView] updateEditorStatus];
}

- (NSUInteger)editorGroupAtWindowPoint:(NSPoint)point
{
    NSUInteger count = _documentSplit ? 2 : 1;
    for (NSUInteger group = 0; group < count; ++group) {
        EditorWindow *editor = _usesPaneTabs ? _groups[group].editor : _installedEditor;
        if (editor && NSPointInRect(point, [editor convertRect:editor.bounds toView:nil]))
            return group;
    }
    return NSNotFound;
}

- (NSRect)frameForEditorGroup:(NSUInteger)group
{
    NSView *view = [self containerForGroup:group];
    NSRect frame = view.bounds;
    if (!_documentSplit && _usesPaneTabs && self.projectTabBarShown)
        frame.size.height -= std::min(projectTabBarHeight, NSHeight(frame));
    return [view convertRect:frame toView:nil];
}

- (std::optional<DockSide>)editorDockSideAtPoint:(NSPoint)point
{
    EditorWindow *editor = self.primaryEditor;
    if (!editor)
        return {};
    NSRect frame = [editor convertRect:editor.bounds toView:nil];
    return NSPointInRect(point, frame) ? DockSideAtPoint(frame, point) : std::nullopt;
}

- (void)showTabDropPreview:(NSRect)rect style:(DropPreviewStyle)style
{
    if (NSIsEmptyRect(rect)) {
        _tabDropPreview.hidden = YES;
        return;
    }

    NSView *container = style == DropPreviewStyle::Insertion && !_usesPaneTabs ? self.window.contentView.superview : _editorPane;
    if (!_tabDropPreview)
        _tabDropPreview = [[DockDropTarget alloc] init];
    if (_tabDropPreview.superview != container) {
        [_tabDropPreview removeFromSuperview];
        [container addSubview:_tabDropPreview positioned:NSWindowAbove relativeTo:nil];
    }

    NSRect frame = [container convertRect:rect fromView:nil];
    if (_tabDropPreview.style != style || !NSEqualRects(_tabDropPreview.frame, frame)) {
        _tabDropPreview.style = style;
        _tabDropPreview.frame = frame;
        _tabDropPreview.needsDisplay = YES;
    }
    _tabDropPreview.hidden = NO;
}

- (void)clearTabDropPreview
{
    [_tabDropPreview removeFromSuperview];
    _tabDropPreview = nil;
}

- (void)refreshProjectTabs
{
    NSUInteger count = _documentSplit ? 2 : 1;
    for (NSUInteger index = 0; index < count; ++index) {
        auto &group = _groups[index];
        if (!group.bar)
            continue;

        NSMutableArray<SourceDocument *> *tabs = [NSMutableArray arrayWithCapacity:group.tabs.size()];
        AppendGroupTabs(tabs, group);
        [group.bar showDocuments:tabs selected:group.selected];
    }
    [self layoutEditorPane];
}

- (void)projectDocumentsChanged:(NSNotification *)notification
{
    (void)notification;
    [self refreshProjectTabs];
}

- (ProjectTabBar *)makeTabBar:(NSUInteger)index
{
    ProjectTabBar *bar = [[ProjectTabBar alloc] initWithFrame:NSZeroRect];
    bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    __weak SourceWindowController *controller = self;
    bar.selectDocument = ^(SourceDocument *document) { [controller selectProjectDocument:document]; };
    bar.closeDocument = ^(SourceDocument *document) { [controller requestCloseProjectDocument:document]; };
    bar.activateGroup = ^{
        SourceWindowController *window = controller;
        if (window)
            [window selectProjectDocument:window->_groups[index].selected];
    };
    return bar;
}

- (void)presentEditorGroups:(SourceDocument *)active
{
    _updatingEditorGroups = YES;
    for (auto &group : _groups) {
        EditorWindow *previous = group.editor;
        if (previous && previous != [group.selected editorView]) {
            [previous rememberTabFocus];
            previous.runButton = nil;
            [previous setWindowOutput:nil];
            [previous removeFromSuperview];
            group.editor = nil;
        }
    }

    if (!_groups[1].tabs.empty() && !_documentSplit) {
        NSRect bounds = _editorPane.bounds;
        _documentSplit = [[NSSplitView alloc] initWithFrame:bounds];
        _documentSplit.dividerStyle = NSSplitViewDividerStyleThin;
        // AppKit needs nonzero pane sizes to position the divider.
        for (auto &group : _groups)
            group.container = [[NSView alloc] initWithFrame:bounds];
        [_editorPane addSubview:_documentSplit positioned:NSWindowBelow relativeTo:nil];
        ArrangeEditorSplit(_documentSplit, _groups[0].container, _groups[1].container, _documentSplitSide, 0.5);
    } else if (_groups[1].tabs.empty() && _documentSplit) {
        [_documentSplit removeFromSuperview];
        _documentSplit = nil;
        [_groups[1].bar removeFromSuperview];
        _groups[1].bar = nil;
    }

    NSUInteger count = _documentSplit ? 2 : 1;
    for (NSUInteger index = 0; index < count; ++index) {
        auto &group = _groups[index];
        NSView *container = [self containerForGroup:index];
        if (!group.bar)
            group.bar = [self makeTabBar:index];
        if (group.bar.superview != container)
            [container addSubview:group.bar];

        EditorWindow *editor = [group.selected loadEditor];
        group.editor = editor;
        if (editor && editor.superview != container) {
            editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [container addSubview:editor positioned:NSWindowBelow relativeTo:group.bar];
        }
    }
    if (!_documentSplit) {
        for (auto &group : _groups)
            group.container = nil;
    }

    [self refreshProjectTabs];
    if (active)
        [self activateTabDocument:active];
    else
        [self syncWindowOutput];
    for (const auto &group : _groups)
        [group.selected applySessionView:nil];

    if (active)
        [self.window makeFirstResponder:[active editorView].tabFocus];
    _updatingEditorGroups = NO;
    [[active editorView] updateEditorStatus];
}

- (void)manageNativeTabs
{
    if (_usesPaneTabs)
        return;

    NSArray<SourceDocument *> *tabs = EditorWindowTabs(self.window);
    NSWindowTabGroup *native = self.window.tabGroup;
    _windowOutput = self.windowOutput;
    [_windowOutput observeTabGroup:nil];
    if (native)
        objc_setAssociatedObject(native, &windowOutputKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _usesPaneTabs = YES;

    for (SourceDocument *document in tabs) {
        NSWindowController *previous = document.windowControllers.firstObject;
        if (previous && previous != self) {
            [[document editorView] setWindowOutput:nil];
            [native removeWindow:previous.window];
            [document removeWindowController:previous];
            [previous close];
        }
        _groups[0].tabs.push_back(document);
        [document setTabWindowController:self];
    }

    [((SourceWindow *)self.window) hideNativeTabBar];
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    _groups[0].selected = self.document;
    _groups[0].editor = _installedEditor;
    _installedEditor = nil;
}

- (void)collapseEmptyGroup
{
    if (_groups[0].tabs.empty() && !_groups[1].tabs.empty()) {
        _groups[0].tabs.swap(_groups[1].tabs);
        _groups[0].selected = _groups[1].selected;
        _groups[1].selected = nil;
    }
}

- (void)endDocumentSplit
{
    if (!_documentSplit)
        return;

    SourceDocument *active = self.focusedDocument;
    _groups[0].tabs.insert(_groups[0].tabs.end(), _groups[1].tabs.begin(), _groups[1].tabs.end());
    _groups[1].tabs.clear();
    _groups[0].selected = active;
    _groups[1].selected = nil;
    [self presentEditorGroups:active];
}

- (BOOL)splitWithDocument:(SourceDocument *)document atSide:(DockSide)side
{
    if (_documentSplit || !document)
        return NO;

    NSUInteger count = _usesPaneTabs ? self.projectTabCount : self.window.tabGroup.windows.count;
    if (count < 2)
        return NO;

    [self manageNativeTabs];
    [self.primaryEditor closeTabSplit];
    [[document editorView] closeTabSplit];
    _documentSplitSide = side;
    return [self moveProjectDocument:document to:{1, 0}];
}

- (void)addProjectDocument:(SourceDocument *)document inGroup:(NSUInteger)group
{
    if ([self tabLocation:document].group != NSNotFound)
        return;

    _groups[group].tabs.push_back(document);
    [document setTabWindowController:self];
    [self refreshProjectTabs];
}

- (void)addProjectDocument:(SourceDocument *)document
{
    NSUInteger group = [self tabLocation:self.document].group;
    [self addProjectDocument:document inGroup:group == 1 ? 1 : 0];
}

- (BOOL)selectProjectDocument:(SourceDocument *)document
{
    EditorTabLocation location = [self tabLocation:document];
    if (location.group == NSNotFound || self.window.attachedSheet)
        return NO;

    auto &group = _groups[location.group];
    if (group.selected != document || !group.editor) {
        group.selected = document;
        [self presentEditorGroups:document];
    } else {
        [self activateTabDocument:document];
        [self.window makeFirstResponder:group.editor.tabFocus];
    }
    return YES;
}

- (void)selectProjectTabAtIndex:(NSUInteger)index
{
    NSArray<SourceDocument *> *tabs = self.projectTabs;
    if (index < tabs.count)
        [self selectProjectDocument:tabs[index]];
}

- (BOOL)replaceProjectDocument:(SourceDocument *)document withDocument:(SourceDocument *)replacement
{
    EditorTabLocation location = [self tabLocation:document];
    if (location.group == NSNotFound || self.window.attachedSheet)
        return NO;

    _groups[location.group].tabs[location.index] = replacement;
    [document setTabWindowController:nil];
    [replacement setTabWindowController:self];
    return [self selectProjectDocument:replacement];
}

- (void)removeProjectDocument:(SourceDocument *)document
{
    EditorTabLocation location = [self tabLocation:document];
    if (location.group == NSNotFound)
        return;

    auto &group = _groups[location.group];
    group.tabs.erase(group.tabs.begin() + location.index);
    BOOL wasSelected = group.selected == document;
    [document setTabWindowController:nil];
    if (!wasSelected) {
        [self refreshProjectTabs];
        return;
    }
    group.selected = group.tabs.empty() ? nil : group.tabs[std::min(location.index, group.tabs.size() - 1)];

    SourceDocument *active = self.document;
    if (active == document) {
        active = group.selected;
        if (!active)
            active = _groups[1 - location.group].selected;
        if (!active) {
            if (!_windowClosed)
                [EmptyProjectWindows() addObject:self];
            [document removeWindowController:self];
        }
    }

    [self collapseEmptyGroup];
    [self presentEditorGroups:active];

    if (!active && !_windowClosed) {
        if (_workspace)
            [self showEmptyProject];
        else
            [self.window close];
    }
}

- (void)showEmptyProject
{
    _runButton.target = nil;
    self.window.documentEdited = NO;
    self.window.representedURL = _workspace.folder;
    self.window.title = _workspace.folder.lastPathComponent.length ? _workspace.folder.lastPathComponent : _workspace.folder.path;
    if (!_sidebar.explorer.hidden)
        [_sidebar.explorer focusFiles];
    [self workspaceRunChanged:nil];
}

- (void)requestCloseProjectDocument:(SourceDocument *)document
{
    if (self.window.attachedSheet || [self tabLocation:document].group == NSNotFound)
        return;
    [document requestTabClose];
}

- (void)requestCloseEditorWindow
{
    if (_windowClosed || self.window.attachedSheet)
        return;

    NSArray<SourceDocument *> *documents = EditorWindowTabs(self.window);
    ReviewDocumentsForClosing(documents, ^(NSSet<SourceDocument *> *discarded) {
        if (!discarded || ![EditorWindowTabs(self.window) isEqualToArray:documents])
            return;

        if (self->_usesPaneTabs) {
            for (SourceDocument *document in documents)
                [document setTabWindowController:nil];
            [(SourceDocument *)self.document removeWindowController:self];
            [self.window close];
        } else if (!documents.count) {
            [self.window close];
        }

        for (SourceDocument *document in documents)
            [document close];
    });
}

- (void)cycleProjectTabs:(NSInteger)direction
{
    EditorTabLocation current = [self tabLocation:self.document];
    if (current.group == NSNotFound)
        return;

    const auto &tabs = _groups[current.group].tabs;
    if (tabs.size() > 1) {
        NSUInteger next = (current.index + (direction < 0 ? tabs.size() - 1 : 1)) % tabs.size();
        [self selectProjectDocument:tabs[next]];
    } else if (_documentSplit) {
        [self selectProjectDocument:_groups[1 - current.group].selected];
    }
}

- (void)toggleProjectTabBar
{
    if (self.projectTabCount != 1)
        return;

    _hideSingleProjectTab = !_hideSingleProjectTab;
    [self layoutEditorPane];
}

- (BOOL)moveProjectDocument:(SourceDocument *)document to:(EditorTabLocation)destination
{
    EditorTabLocation source = [self tabLocation:document];
    if (source.group == NSNotFound || destination.group >= std::size(_groups))
        return NO;

    auto &from = _groups[source.group];
    auto &to = _groups[destination.group];
    NSUInteger index = std::min(destination.index, to.tabs.size());
    if (source.group == destination.group && index > source.index)
        --index;

    BOOL changedGroup = source.group != destination.group;
    if (!changedGroup && index == source.index)
        return [self selectProjectDocument:document];

    from.tabs.erase(from.tabs.begin() + source.index);
    to.tabs.insert(to.tabs.begin() + index, document);
    if (changedGroup && from.selected == document)
        from.selected = from.tabs.empty() ? nil : from.tabs[std::min(source.index, from.tabs.size() - 1)];

    to.selected = document;
    [self collapseEmptyGroup];
    [self presentEditorGroups:document];
    return YES;
}

- (SourceDocument *)projectDocumentAtWindowPoint:(NSPoint)point tabView:(NSView **)tabView
{
    for (const auto &group : _groups) {
        if (SourceDocument *document = [group.bar documentAtWindowPoint:point tabView:tabView])
            return document;
    }
    return nil;
}

- (EditorTabLocation)tabInsertionAtWindowPoint:(NSPoint)point marker:(NSRect *)marker
{
    for (NSUInteger group = 0; group < std::size(_groups); ++group) {
        ProjectTabBar *bar = _groups[group].bar;
        if (bar) {
            TabInsertion insertion = [bar insertionAtWindowPoint:point];
            if (insertion.index != NSNotFound) {
                *marker = insertion.marker;
                return {group, insertion.index};
            }
        }
    }
    return {};
}

- (void)detachProjectDocument:(SourceDocument *)document
{
    if (TabActionsBlocked(self.window) || [self tabLocation:document].group == NSNotFound)
        return;

    NSRect frame = self.window.frame;
    [self removeProjectDocument:document];
    [document makeWindowControllers];
    [document.editorHostWindow setFrame:NSOffsetRect(frame, 18, -18) display:NO];
    [document showWindows];
}

- (void)mergeProjectWindows
{
    if (self.window.attachedSheet)
        return;

    NSArray *documents = _workspace ? _workspace.documents : NSDocumentController.sharedDocumentController.documents;
    SourceDocument *selected = self.document;
    for (SourceDocument *document in documents) {
        if ([document isKindOfClass:SourceDocument.class] && document.workspace == _workspace &&
            document.editorHostWindow && document.editorHostWindow != self.window &&
            [document joinNavigationTabInWindow:self.window] && !selected)
            selected = document;
    }
    if (!self.document && selected)
        [selected showWindows];
}

- (void)updateWorkspace
{
    [self configureWorkspace:[(SourceDocument *)self.document workspace]];
}

- (void)restoreWorkspace:(FolderWorkspace *)workspace tabs:(NSArray<SourceDocument *> *)tabs selected:(SourceDocument *)selected
{
    _restoringProject = YES;
    [EmptyProjectWindows() addObject:self];
    [self configureWorkspace:workspace];
    for (SourceDocument *document in tabs)
        [self addProjectDocument:document];
    if (selected)
        [self selectProjectDocument:selected];
    else
        [self showEmptyProject];
    _restoringProject = NO;
}

- (void)configureWorkspace:(FolderWorkspace *)workspace
{
    if (workspace != _workspace) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        if (_workspace) {
            [center removeObserver:self name:FolderSidebarChanged object:_workspace];
            [center removeObserver:self name:FolderDocumentsChanged object:_workspace];
            [center removeObserver:self name:FolderRunChanged object:_workspace];
        }
        [_sidebar removeFromSuperview];
        _sidebar = nil;
        _workspace = workspace;
        NSArray *accessories = self.window.titlebarAccessoryViewControllers;
        NSUInteger index = [accessories indexOfObjectIdenticalTo:_sidebarAccessory];
        if (_workspace) {
            [center addObserver:self selector:@selector(workspaceSidebarChanged:)
                           name:FolderSidebarChanged object:_workspace];
            [center addObserver:self selector:@selector(projectDocumentsChanged:)
                           name:FolderDocumentsChanged object:_workspace];
            [center addObserver:self selector:@selector(workspaceRunChanged:) name:FolderRunChanged object:_workspace];
            [self manageNativeTabs];
            [self presentEditorGroups:self.document];
            if (index == NSNotFound)
                [self.window addTitlebarAccessoryViewController:_sidebarAccessory];
        } else if (index != NSNotFound) {
            [self.window removeTitlebarAccessoryViewControllerAtIndex:index];
        }
    }
    [self updateExplorerLayout];
    [self refreshProjectTabs];
    [self revealCurrentFile];
    [self syncWindowOutput];
}

- (void)workspaceRunChanged:(NSNotification *)notification
{
    (void)notification;
    if (EditorWindow *editor = [self.focusedDocument editorView]) {
        [editor refreshRunButton];
    } else {
        _runButton.enabled = NO;
        SetRunButton(_runButton, RunButtonAction::Run);
        SetTitleDebugButton(_runButton, DebugPhase::Finished);
    }
}

- (IBAction)pauseDebugging:(id)sender
{
    (void)sender;
    [[self.focusedDocument editorView] performDebugCommand:DebugCommand::Pause];
}

- (IBAction)stopDebugging:(id)sender
{
    (void)sender;
    [[self.focusedDocument editorView] performDebugCommand:DebugCommand::Stop];
}

- (void)updateExplorerLayout
{
    _layingOutExplorer = YES;
    BOOL shown = _workspace.sidebarShown;
    if (shown) {
        if (!_sidebar) {
            _sidebar = [[FolderSidebar alloc] initWithWorkspace:_workspace];
            __weak SourceWindowController *controller = self;
            _sidebar.explorer.openFile = ^(NSURL *url) {
                if (NSWindow *window = controller.window) {
                    OpenSourceTab(url, window, ^(NSDocument *, BOOL, NSError *error) {
                        if (error)
                            [window presentError:error];
                    });
                }
            };
            _sidebar.openMatch = ^(NSURL *file, SourceDocument *document, FolderSearchPattern *pattern, NSRange range) {
                [controller openFolderSearchFile:file document:document pattern:pattern range:range];
            };
        }
        if (!_sidebar.superview)
            [_editorSplit insertArrangedSubview:_sidebar atIndex:0];
    } else {
        NSResponder *focus = self.window.firstResponder;
        if (_sidebar && [focus isKindOfClass:NSView.class] && [(NSView *)focus isDescendantOf:_sidebar])
            [self.window makeFirstResponder:[self.focusedDocument editorView].activeEditor];
        [_sidebar removeFromSuperview];
    }
    _sidebarButton.accessibilityLabel = shown ? @"Hide Sidebar" : @"Show Sidebar";
    _sidebarButton.toolTip = shown ? @"Hide Sidebar (⌘B)" : @"Show Sidebar (⌘B)";
    [_editorSplit adjustSubviews];
    if (_sidebar.superview && NSWidth(_editorSplit.bounds) >= minimumExplorerWidth) {
        CGFloat width = std::clamp(_workspace.sidebarWidth, minimumExplorerWidth, [self maximumExplorerWidth]);
        [_editorSplit setPosition:width ofDividerAtIndex:0];
    }
    _layingOutExplorer = NO;
}

- (void)showFolderSearchReplacing:(BOOL)replace
{
    CodeView *editor = [self.focusedDocument editorView].activeEditor;
    NSString *selection = nil;
    if (editor && self.window.firstResponder == editor) {
        NSRange range = [editor selectedCharacterRange];
        if (range.location != NSNotFound && range.length && range.length <= 512) {
            NSString *text = [editor.string substringWithRange:range];
            if ([text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
                selection = text;
        }
    }
    _workspace.sidebarShown = YES;
    [_sidebar showSearch:selection replace:replace];
}

- (void)openFolderSearchFile:(NSURL *)file document:(SourceDocument *)document pattern:(FolderSearchPattern *)pattern range:(NSRange)range
{
    if (self.window.attachedSheet || _windowClosed)
        return;
    FolderWorkspace *workspace = _workspace;
    if (document.workspace == workspace && document.editorHostWindow) {
        if (![document joinNavigationTabInWindow:self.window])
            return;
        [document showWindows];
        if (![document revealFolderSearchMatch:range pattern:pattern])
            [_sidebar refreshSearch];
        return;
    }
    if (!file) {
        [_sidebar refreshSearch];
        return;
    }
    // A result can outlive a rename, replacement, or edit to the file.
    NSNumber *regularFile = nil;
    NSURL *currentFile = [NSURL fileURLWithPath:file.path];
    [currentFile getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:nullptr];
    if (!regularFile.boolValue) {
        [_sidebar refreshSearch];
        return;
    }
    __weak SourceWindowController *controller = self;
    OpenSourceTab(currentFile, self.window, ^(NSDocument *opened, BOOL, NSError *error) {
        SourceWindowController *current = controller;
        if (!current || current.windowClosed || current.workspace != workspace)
            return;
        if ([opened isKindOfClass:SourceDocument.class] &&
            [(SourceDocument *)opened revealFolderSearchMatch:range pattern:pattern])
            return;
        if (error && error.code != NSFileReadNoSuchFileError && error.code != NSFileNoSuchFileError)
            [current.window presentError:error];
        [current->_sidebar refreshSearch];
    });
}

- (IBAction)toggleWorkspaceSidebar:(id)sender
{
    (void)sender;
    _workspace.sidebarShown = !_workspace.sidebarShown;
}

- (void)workspaceSidebarChanged:(NSNotification *)notification
{
    (void)notification;
    [self updateExplorerLayout];
    if (_sidebar.superview)
        [self revealCurrentFile];
}

- (void)workspaceWindowActivated:(NSNotification *)notification
{
    (void)notification;
    [self syncWindowOutput];
    _workspace.selectedDocument = self.document;
    [self updateExplorerLayout];
}

- (void)revealCurrentFile
{
    if (_sidebar.superview && self.document)
        [_sidebar.explorer revealFile:[(SourceDocument *)self.document fileURL] expandingFolders:!_restoringProject];
}

- (CGFloat)maximumExplorerWidth
{
    return std::clamp(NSWidth(_editorSplit.bounds) - 280, minimumExplorerWidth, 420.0);
}

- (void)splitView:(NSSplitView *)split resizeSubviewsWithOldSize:(NSSize)oldSize
{
    (void)oldSize;
    NSRect body = split.bounds;
    if (_sidebar.superview == split) {
        CGFloat width = std::min(NSWidth(body), std::clamp(_workspace.sidebarWidth, minimumExplorerWidth, [self maximumExplorerWidth]));
        _sidebar.frame = NSMakeRect(0, 0, width, NSHeight(body));
        CGFloat start = std::min(NSWidth(body), width + split.dividerThickness);
        body.origin.x = start;
        body.size.width -= start;
    }
    _editorContent.frame = body;
}

- (CGFloat)splitView:(NSSplitView *)split constrainMinCoordinate:(CGFloat)minimum ofSubviewAt:(NSInteger)index
{
    (void)split;
    (void)index;
    return std::max(minimum, minimumExplorerWidth);
}

- (CGFloat)splitView:(NSSplitView *)split constrainMaxCoordinate:(CGFloat)maximum ofSubviewAt:(NSInteger)index
{
    (void)split;
    (void)index;
    return std::min(maximum, [self maximumExplorerWidth]);
}

- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
    (void)notification;
    CGFloat width = NSWidth(_editorSplit.bounds);
    if (!_layingOutExplorer && self.window.isKeyWindow && _sidebar.superview &&
        width == _splitWidth) {
        _workspace.sidebarWidth = NSWidth(_sidebar.frame);
    }
    _splitWidth = width;
}

@end

static NSString *const example = @"#include <stdint.h>\n"
    "#include <stdio.h>\n"
    "\n"
    "enum { WIDTH = 64, HEIGHT = 64, TILE = 8 };\n"
    "\n"
    "typedef struct {\n"
    "    uint8_t red, green, blue;\n"
    "} Pixel;\n"
    "\n"
    "static Pixel checkerboard(int x, int y)\n"
    "{\n"
    "    const int row = y / TILE;\n"
    "    const int col = x / TILE;\n"
    "\n"
    "    if ((row + col) % 2 == 0)\n"
    "        return (Pixel){ 240, 235, 216 };\n"
    "    return (Pixel){ 44, 58, 78 };\n"
    "}\n"
    "\n"
    "int main(void)\n"
    "{\n"
    "    /* P6 is the binary PPM format. */\n"
    "    printf(\"P6\\n%d %d\\n255\\n\", WIDTH, HEIGHT);\n"
    "\n"
    "    for (int y = 0; y < HEIGHT; ++y) {\n"
    "        for (int x = 0; x < WIDTH; ++x) {\n"
    "            const Pixel pixel = checkerboard(x, y);\n"
    "            putchar(pixel.red);\n"
    "            putchar(pixel.green);\n"
    "            putchar(pixel.blue);\n"
    "        }\n"
    "    }\n"
    "\n"
    "    return ferror(stdout) ? 1 : 0;\n"
    "}\n";

struct FileStamp {
    dev_t device = 0;
    ino_t inode = 0;
    off_t size = 0;
    time_t seconds = 0;
    long nanoseconds = 0;
    bool valid = false;

    bool operator==(const FileStamp &) const = default;
};

static FileStamp ReadFileStamp(NSURL *url)
{
    struct stat info;
    if (!url.isFileURL || stat(url.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode))
        return {};
    return {info.st_dev, info.st_ino, info.st_size, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, true};
}

static NSArray *SessionFileStamp(const FileStamp &stamp)
{
    if (!stamp.valid)
        return nil;
    return @[@(stamp.device), @(stamp.inode), @(stamp.size), @(stamp.seconds), @(stamp.nanoseconds)];
}

static Vim::EditBatch PlanSaveCleanup(NSString *text, SaveCleanupSettings settings, std::span<const Vim::Offset> carets)
{
    const auto mode = settings.finalNewline;
    const bool insertEnding = mode == FinalNewlineMode::InsertIfMissing || mode == FinalNewlineMode::KeepExactlyOne;
    const bool trimEndings = mode == FinalNewlineMode::TrimExtras || mode == FinalNewlineMode::KeepExactlyOne;
    const NSUInteger length = text.length;
    if (!length || (!settings.trimTrailingWhitespace && mode == FinalNewlineMode::Preserve))
        return Vim::EditBatch();

    if (!settings.trimTrailingWhitespace) {
        NSUInteger last;
        [text getLineStart:nullptr end:nullptr contentsEnd:&last forRange:NSMakeRange(length - 1, 0)];
        if (last == length ? !insertEnding : mode == FinalNewlineMode::InsertIfMissing)
            return Vim::EditBatch();
        if (trimEndings && last && last < length) {
            NSUInteger previous;
            [text getLineStart:nullptr end:nullptr contentsEnd:&previous forRange:NSMakeRange(last - 1, 0)];
            if (previous == last)
                return Vim::EditBatch();
        }
    }

    std::vector<Vim::CursorEdit> edits;
    NSUInteger contentEnd = 0;
    NSUInteger firstEndingEnd = 0;
    NSRange lastEnding = NSMakeRange(0, 0);
    auto caret = carets.begin();
    for (NSUInteger start = 0; start < length;) {
        NSUInteger end, next;
        [text getLineStart:nullptr end:&next contentsEnd:&end forRange:NSMakeRange(start, 0)];
        NSUInteger trimmed = end;
        if (settings.trimTrailingWhitespace) {
            while (trimmed > start) {
                unichar character = [text characterAtIndex:trimmed - 1];
                if (character != ' ' && character != '\t')
                    break;
                --trimmed;
            }
            while (caret != carets.end() && *caret <= end)
                trimmed = std::max(trimmed, *caret++);
            if (trimmed < end)
                edits.push_back({{trimmed, end}, {}});
        }
        if (trimmed > start) {
            contentEnd = trimmed;
            firstEndingEnd = 0;
        }
        if (next > end) {
            if (!firstEndingEnd)
                firstEndingEnd = next;
            lastEnding = NSMakeRange(end, next - end);
        }
        start = next;
    }

    if (firstEndingEnd && (trimEndings || mode == FinalNewlineMode::RemoveAll)) {
        NSUInteger from = trimEndings ? firstEndingEnd : contentEnd;
        if (!carets.empty())
            from = std::max(from, carets.back());
        if (from < length && from && [text characterAtIndex:from - 1] == '\r' && [text characterAtIndex:from] == '\n')
            ++from;
        if (from < length) {
            while (!edits.empty() && edits.back().range.last >= from) {
                from = std::min(from, edits.back().range.first);
                edits.pop_back();
            }
            edits.push_back({{from, length}, {}});
        }
    } else if (!firstEndingEnd && insertEnding && contentEnd) {
        std::u16string ending = u"\n";
        if (lastEnding.length) {
            ending.resize(lastEnding.length);
            [text getCharacters:reinterpret_cast<unichar *>(ending.data()) range:lastEnding];
        }
        edits.push_back({{length, length}, std::move(ending)});
    }
    return Vim::EditBatch(std::move(edits));
}

NSData *SourceDataWithFinalNewline(NSData *data, FinalNewlineMode mode)
{
    if (!data.length || mode == FinalNewlineMode::Preserve)
        return data;
    BOOL hasBOM = NO;
    NSString *text = DecodeSourceText(data, &hasBOM);
    auto edits = PlanSaveCleanup(text, {.finalNewline = mode}, {});
    if (edits.edits.empty())
        return data;
    return EncodeSourceText(TextByApplyingEdits(text, edits), hasBOM);
}

static SourceWindowController *MakeSourceWindowController(FolderWorkspace *workspace)
{
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable;
    SourceWindow *window = [[SourceWindow alloc] initWithContentRect:NSMakeRect(0, 0, 840, 648) styleMask:style
                                                            backing:NSBackingStoreBuffered defer:NO];
    window.tabbingIdentifier = workspace ? workspace.tabbingIdentifier : @"RetinaCodeDocuments";
    if (workspace)
        window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.restorable = NO;
    window.minSize = NSMakeSize(500, 330);
    window.colorSpace = NSColorSpace.sRGBColorSpace;
    [window center];
    return [[SourceWindowController alloc] initWithSourceWindow:window];
}

NSWindow *RestoreWorkspaceWindow(FolderWorkspace *workspace, NSArray<SourceDocument *> *tabs, SourceDocument *selected)
{
    SourceWindowController *controller = MakeSourceWindowController(workspace);
    [controller restoreWorkspace:workspace tabs:tabs selected:selected];
    return controller.window;
}

@implementation SourceDocument {
    NSString *_initialText;
    NSDictionary *_pendingSessionView;
    NSString *_textBeingSaved;
    id _saveCleanupChangeToken;
    EditorWindow *_editorWindow;
    BOOL _isExample;
    BOOL _hasBOM;
    NSURL *_explorerRenamedURL;
    id _explorerFileIdentifier;
    NSURL *_savedFileURL;
    FileStamp _savedFileStamp;
    NSUInteger _savedEditorLength;
    NSTimer *_autoSaveTimer;
    AutoSaveMode _pendingAutoSave;
    NSError *_autoSaveError;
    NSUInteger _fileSavesInProgress;
    BOOL _savingAutomatically;
    BOOL _trackingCoalescedEdits;
    BOOL _changeCheckQueued;
    BOOL _closing;
    BOOL _reviewingClose;
    void (^_afterSaveForClose)(void);
    __weak SourceWindowController *_tabWindowController;
}

- (BOOL)hasUTF8BOM { return _hasBOM; }

- (NSUInteger)tabSize
{
    if (_editorWindow)
        return _editorWindow.indentation.tabWidth;
    auto indentation = self.fileURL ? FileIndentationPreference(self.fileURL) :
        DecodeIndentation(_pendingSessionView[@"indentation"]);
    return indentation ? indentation->tabWidth : IndentationPreference().tabSize;
}

- (NSInteger)languageMode { return _editorWindow.languageMode; }
- (BOOL)automaticLanguageMode { return _editorWindow.automaticLanguageMode; }

- (NSArray<NSMenuItem *> *)languagePaletteCommands
{
    return _editorWindow ? [_editorWindow languagePaletteCommands] : @[];
}

- (IBAction)changeLanguageMode:(NSMenuItem *)sender
{
    if (sender.tag == -1)
        [_editorWindow useAutomaticLanguage];
    else if (sender.tag >= 0 && sender.tag < NSInteger(Language::Count))
        [_editorWindow setLanguage:Language(sender.tag)];
}

- (IBAction)setIndentationKind:(NSMenuItem *)sender
{
    Indentation indentation = _editorWindow.indentation;
    indentation.tabs = sender.tag != 0;
    [_editorWindow setFileIndentation:indentation];
}

- (IBAction)setTabSize:(NSMenuItem *)sender
{
    if (sender.tag < 1 || sender.tag > NSInteger(maximumTabSize))
        return;
    Indentation indentation = _editorWindow.indentation;
    indentation.tabWidth = indentation.width = NSUInteger(sender.tag);
    [_editorWindow setFileIndentation:indentation];
}

- (IBAction)convertIndentation:(NSMenuItem *)sender
{
    [_editorWindow convertIndentationToTabs:sender.tag != 0];
}

- (IBAction)detectFileIndentation:(id)sender
{
    (void)sender;
    [_editorWindow detectFileIndentation];
}

- (IBAction)resetFileIndentation:(id)sender
{
    (void)sender;
    [_editorWindow resetFileIndentation];
}

- (IBAction)setIndentationAsDefault:(id)sender
{
    (void)sender;
    if (!_editorWindow)
        return;
    Indentation indentation = _editorWindow.indentation;
    auto settings = IndentationPreference();
    settings.tabSize = indentation.tabs ? indentation.tabWidth : indentation.width;
    settings.tabs = indentation.tabs;
    SetIndentationPreference(settings);
}

- (NSError *)autoSaveError { return _autoSaveError; }

- (void)setAutoSaveError:(NSError *)error
{
    if (_autoSaveError != error) {
        _autoSaveError = error;
        [_editorWindow updateEditorStatus];
    }
}

- (void)cancelAutoSave
{
    [_autoSaveTimer invalidate];
    _autoSaveTimer = nil;
    _pendingAutoSave = AutoSaveMode::Off;
}

- (BOOL)canRequestAutoSave:(AutoSaveMode)mode
{
    return mode != AutoSaveMode::Off && mode == AutoSavePreference().mode && !_closing &&
        !_reviewingClose && !_autoSaveError && _editorWindow && self.fileURL.isFileURL;
}

- (void)armAutoSaveTimer:(NSTimeInterval)delay
{
    if (_autoSaveTimer) {
        _autoSaveTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:delay];
        return;
    }
    __weak SourceDocument *document = self;
    _autoSaveTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [document runPendingAutoSave:timer];
    }];
    [NSRunLoop.mainRunLoop addTimer:_autoSaveTimer forMode:NSRunLoopCommonModes];
}

- (void)scheduleAutoSaveAfterEdit
{
    [self queueChangeCheckAfterAutoSave];
    AutoSaveSettings settings = AutoSavePreference();
    if (settings.mode != AutoSaveMode::AfterDelay) {
        [self resumePendingAutoSave];
    } else if ([self canRequestAutoSave:settings.mode]) {
        _pendingAutoSave = settings.mode;
        [self armAutoSaveTimer:settings.delayMilliseconds / 1000.0];
    }
}

- (void)queueChangeCheckAfterAutoSave
{
    if (!_trackingCoalescedEdits || _changeCheckQueued || _closing || self.isDocumentEdited)
        return;
    // Let AppKit account for undo registration before checking coalesced edits.
    _changeCheckQueued = YES;
    __weak SourceDocument *document = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [document checkCoalescedEditsAfterAutoSave];
    });
}

- (void)checkCoalescedEditsAfterAutoSave
{
    if (!_changeCheckQueued)
        return;
    _changeCheckQueued = NO;
    if (!_trackingCoalescedEdits || _closing || self.isDocumentEdited || _editorWindow.hasMarkedEditorText)
        return;
    if (_editorWindow.editor.string.length == _savedEditorLength && _savedFileStamp.valid &&
        ReadFileStamp(_savedFileURL) == _savedFileStamp) {
        NSData *disk = [NSData dataWithContentsOfURL:_savedFileURL];
        if (disk && [disk isEqualToData:[self dataOfType:self.fileType error:nil]])
            return;
    }
    [self updateChangeCount:NSChangeDone];
}

- (void)requestAutoSave:(AutoSaveMode)mode
{
    if ([self canRequestAutoSave:mode] && self.isDocumentEdited) {
        _pendingAutoSave = mode;
        [self armAutoSaveTimer:0];
    }
}

- (void)resumePendingAutoSave
{
    if (!_reviewingClose && _pendingAutoSave != AutoSaveMode::Off && !_autoSaveTimer && !_fileSavesInProgress)
        [self armAutoSaveTimer:0];
}

- (void)autoSavePreferencesChanged:(NSNotification *)notification
{
    (void)notification;
    [self cancelAutoSave];
    [self requestAutoSave:AutoSavePreference().mode];
}

- (BOOL)isEligibleForAutoSave:(AutoSaveSettings)settings
{
    if (![self canRequestAutoSave:settings.mode] || !self.isDocumentEdited || self.isDraft || self.isLocked)
        return NO;
    return !settings.workspaceFilesOnly || PathIsInFolder(CanonicalFileURL(self.fileURL).path, _workspace.folder.path);
}

- (BOOL)autoSaveMustWait:(AutoSaveSettings)settings
{
    return _fileSavesInProgress || self.editorHostWindow.attachedSheet ||
           (settings.whenNoErrors && _editorWindow.hasBuildErrors);
}

- (void)runPendingAutoSave:(NSTimer *)timer
{
    if (_autoSaveTimer != timer)
        return;
    _autoSaveTimer = nil;
    if (_reviewingClose)
        return;
    AutoSaveSettings settings = AutoSavePreference();
    if (_pendingAutoSave != settings.mode || ![self isEligibleForAutoSave:settings]) {
        [self cancelAutoSave];
        return;
    }
    if ([self autoSaveMustWait:settings])
        return;
    if (_editorWindow.hasMarkedEditorText) {
        [self armAutoSaveTimer:0.15];
        return;
    }
    [self saveAutomatically:nil];
}

- (void)saveAutomatically:(void (^)(void))completion
{
    [self cancelAutoSave];
    _savingAutomatically = YES;
    NSString *type = self.fileType;
    [self saveToURL:self.fileURL ofType:type ? type : @"public.source-code" forSaveOperation:NSSaveOperation
       completionHandler:^(NSError *error) {
        self->_savingAutomatically = NO;
        [self setAutoSaveError:error];
        if (completion)
            completion();
    }];
}

- (void)rememberSavedFile:(NSURL *)url
{
    NSURL *path = url.URLByStandardizingPath;
    if (path && ![path isEqual:_savedFileURL] && _editorWindow) {
        std::optional<Indentation> indentation;
        if (_editorWindow.hasFileIndentation)
            indentation = _editorWindow.indentation;
        SetFileIndentationPreference(url, indentation);
    }
    _savedFileURL = path;
    _savedFileStamp = ReadFileStamp(url);
    _savedEditorLength = _editorWindow.editor.string.length;
    _trackingCoalescedEdits = _savingAutomatically;
    [self setAutoSaveError:nil];
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)type error:(NSError **)error
{
    FileStamp stamp = ReadFileStamp(url);
    if (![super readFromURL:url ofType:type error:error])
        return NO;
    _savedFileURL = url.URLByStandardizingPath;
    _savedFileStamp = stamp;
    _trackingCoalescedEdits = NO;
    [self setAutoSaveError:nil];
    return YES;
}

- (void)loadExample
{
    _initialText = example;
    _isExample = YES;
    self.displayName = @"checker.c";
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)type error:(NSError **)error
{
    (void)type;
    BOOL hasBOM = NO;
    if (NSString *text = DecodeSourceText(data, &hasBOM)) {
        _hasBOM = hasBOM;
        if (_editorWindow)
            [_editorWindow replaceDocumentText:text];
        else
            _initialText = text;
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInapplicableStringEncodingError
                                 userInfo:@{NSLocalizedDescriptionKey:@"The file contains invalid UTF-8 or binary data."}];
    }
    return NO;
}

- (NSString *)sourceText
{
    NSString *text = _editorWindow ? _editorWindow.editor.string : _initialText;
    return text ? text : @"";
}

- (BOOL)revealFolderSearchMatch:(NSRange)range pattern:(FolderSearchPattern *)pattern
{
    CodeView *editor = _editorWindow.activeEditor;
    NSString *text = editor.string;
    if (!editor || !FolderSearchRangeMatches(text, range, pattern))
        return NO;
    [editor revealSearchMatch:range];
    return YES;
}

- (NSDictionary *)sessionStateDiscardingChanges:(BOOL)discard
{
    [self checkCoalescedEditsAfterAutoSave];
    NSURL *file = self.fileURL;
    if (discard && !file)
        return nil;
    BOOL edited = self.isDocumentEdited && !discard;
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    if (file)
        state[@"path"] = file.path;
    if (!file || edited) {
        state[@"text"] = [self.sourceText copy];
        state[@"bom"] = @(_hasBOM);
        state[@"name"] = self.displayName;
    }
    if (edited) {
        state[@"draft"] = @YES;
        if ([_savedFileURL isEqual:file.URLByStandardizingPath])
            state[@"stamp"] = SessionFileStamp(_savedFileStamp);
    }
    if (_isExample)
        state[@"example"] = @YES;
    state[@"view"] = _editorWindow ? [_editorWindow sessionView] : _pendingSessionView;
    return state;
}

- (BOOL)canApplySessionDraft:(NSDictionary *)state
{
    NSArray *stamp = SessionArray(state[@"stamp"]);
    return stamp && [stamp isEqualToArray:SessionFileStamp(_savedFileStamp)];
}

- (void)applySessionContents:(NSDictionary *)state recoveredFile:(BOOL)recoveredFile
{
    if (NSString *text = SessionString(state[@"text"])) {
        _initialText = [text copy];
        _hasBOM = [SessionNumber(state[@"bom"]) boolValue];
    }
    if (!self.fileURL) {
        _isExample = [SessionNumber(state[@"example"]) boolValue];
        NSString *name = SessionString(state[@"name"]);
        if (recoveredFile) {
            if (!name.length)
                name = [SessionString(state[@"path"]) lastPathComponent];
            name = [name stringByAppendingString:@" (Recovered)"];
        }
        if (name.length)
            self.displayName = name;
    }
}

- (void)applySessionView:(NSDictionary *)state
{
    if (state)
        _pendingSessionView = [state copy];
    if (!_editorWindow || !_pendingSessionView)
        return;
    NSWindow *window = self.editorHostWindow;
    [window.contentView layoutSubtreeIfNeeded];
    [_editorWindow restoreSessionView:_pendingSessionView];
    if (_editorWindow.window == window && FocusedEditorDocument(window) == self)
        window.initialFirstResponder = _editorWindow.tabFocus;
    _pendingSessionView = nil;
}

- (void)updateTabAppearance
{
    if (_workspace)
        [_workspace documentChanged];
    else
        [_tabWindowController refreshProjectTabs];
}

- (void)markSessionDraftEdited
{
    [super updateChangeCount:NSChangeDone];
    [self updateTabAppearance];
}

- (NSData *)dataForSourceText:(NSString *)text error:(NSError **)error
{
    NSData *data = EncodeSourceText(text, _hasBOM);
    if (!data && error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil];
    return data;
}

- (NSData *)dataOfType:(NSString *)type error:(NSError **)error
{
    (void)type;
    return [self dataForSourceText:_textBeingSaved ? _textBeingSaved : self.sourceText error:error];
}

- (BOOL)applyFolderSearchEdits:(Vim::EditBatch)batch error:(NSError **)error
{
    return [self applySourceEdits:std::move(batch) undoName:@"Replace in Files" error:error];
}

- (BOOL)applySourceEdits:(Vim::EditBatch)batch undoName:(NSString *)name error:(NSError **)error
{
    NSURL *file = self.fileURL;
    NSString *failure = nil;
    if (_closing || _fileSavesInProgress || _reviewingClose || _editorWindow.hasMarkedEditorText) {
        failure = @"The document is busy.";
    } else if (self.isLocked) {
        failure = @"The file is locked.";
    } else if (_editorWindow) {
        if (_editorWindow.activeEditor.editable &&
            [_editorWindow.activeEditor applyDocumentEdits:std::move(batch) undoName:name options:{}])
            return YES;
        failure = @"The document cannot be edited.";
    } else if (!_savedFileStamp.valid || ReadFileStamp(file) != _savedFileStamp || ![file isEqual:CanonicalFileURL(file)]) {
        failure = @"The file changed on disk.";
    } else if (![NSFileManager.defaultManager isWritableFileAtPath:file.path]) {
        failure = @"The file is read-only.";
    } else {
        NSData *data = [self dataForSourceText:TextByApplyingEdits(self.sourceText, batch) error:error];
        if (!data)
            return NO;

        // Coordinate the write with other editors and recheck the file inside the accessor.
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:self];
        __block BOOL written = NO;
        __block NSError *writeError = nil;
        NSError *coordinationError = nil;
        [coordinator coordinateWritingItemAtURL:file options:NSFileCoordinatorWritingForReplacing
            error:&coordinationError byAccessor:^(NSURL *url) {
                if ([url isEqual:file] && [url isEqual:CanonicalFileURL(url)] && ReadFileStamp(url) == self->_savedFileStamp)
                    written = [data writeToURL:url options:NSDataWritingAtomic error:&writeError];
            }];
        if (written)
            return YES;
        if (writeError || coordinationError) {
            if (error)
                *error = writeError ? writeError : coordinationError;
            return NO;
        }
        failure = @"The file changed on disk.";
    }
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
                                 userInfo:@{NSLocalizedDescriptionKey:failure}];
    return NO;
}

- (Vim::EditBatch)saveCleanupEditsForText:(NSString *)text
{
    SaveCleanupSettings settings = SaveCleanupPreference();
    if ((!settings.trimTrailingWhitespace && settings.finalNewline == FinalNewlineMode::Preserve) ||
        _editorWindow.hasMarkedEditorText)
        return Vim::EditBatch();
    std::vector<Vim::Offset> carets;
    if (_savingAutomatically && AutoSavePreference().mode == AutoSaveMode::AfterDelay) {
        CodeView *editor = _editorWindow.activeEditor;
        if (editor && editor.window.isKeyWindow && editor.window.firstResponder == editor)
            carets = [editor editingCaretOffsets];
    }
    return PlanSaveCleanup(text, settings, carets);
}

- (void)applyWrittenSaveCleanup:(Vim::EditBatch)batch
{
    if (batch.edits.empty())
        return;
    if (_editorWindow)
        [_editorWindow.activeEditor applyDocumentEdits:std::move(batch) undoName:@"Save Cleanup" options:{}];
    else
        _initialText = TextByApplyingEdits(self.sourceText, batch);
}

- (BOOL)isUnusedUntitled
{
    NSWindow *window = self.editorHostWindow;
    SourceWindowController *controller = (SourceWindowController *)window.windowController;
    if (self.fileURL || self.isDocumentEdited || _isExample || !window || _editorWindow.isRunSource ||
        window.attachedSheet || controller.hasDocumentSplit || _editorWindow.hasSplit || _editorWindow.editor.string.length ||
        _editorWindow.activeEditor.hasMarkedText)
        return NO;

    return !self.undoManager.canUndo && !self.undoManager.canRedo;
}

- (NSWindow *)editorHostWindow
{
    SourceWindowController *project = _tabWindowController;
    return project ? project.window : self.windowControllers.firstObject.window;
}

- (NSWindow *)windowForSheet
{
    if (_reviewingClose)
        return nil;
    NSWindow *window = [super windowForSheet];
    return window ? window : _tabWindowController.window;
}

- (SourceWindowController *)tabWindowController { return _tabWindowController; }
- (void)setTabWindowController:(SourceWindowController *)controller { _tabWindowController = controller; }
- (EditorWindow *)editorView { return _editorWindow; }

- (void)setWorkspace:(FolderWorkspace *)workspace
{
    if (_workspace == workspace)
        return;
    if (_workspace.runningDocument == self)
        [_editorWindow stopRun];
    [_tabWindowController removeProjectDocument:self];
    [_workspace removeDocument:self];
    _workspace = workspace;
    [_workspace addDocument:self];
    SourceWindow *window = (SourceWindow *)self.windowControllers.firstObject.window;
    if (window.tabGroup.windows.count > 1)
        [window.tabGroup removeWindow:window];
    if (workspace)
        [window hideNativeTabBar];
    window.tabbingMode = workspace ? NSWindowTabbingModeDisallowed : NSWindowTabbingModeAutomatic;
    window.tabbingIdentifier = workspace ? workspace.tabbingIdentifier : @"RetinaCodeDocuments";
    [(SourceWindowController *)window.windowController updateWorkspace];
    [_editorWindow refreshLanguageServices];
}

- (EditorWindow *)loadEditor
{
    if (!_editorWindow) {
        Language language = [self inferredLanguageForText:_initialText];
        _editorWindow = [[EditorWindow alloc] initWithDocument:self text:_initialText ? _initialText : @""
                                                     language:language];
        _initialText = nil;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(autoSavePreferencesChanged:)
                                                   name:AutoSavePreferencesChanged object:nil];
    }
    return _editorWindow;
}

- (void)installEditor:(SourceWindowController *)controller
{
    [self loadEditor];
    controller.runButton.target = self;
    _editorWindow.runButton = controller.runButton;
    [controller installEditorView:_editorWindow];
    [self applySessionView:nil];
}

- (Language)inferredLanguageForText:(NSString *)text
{
    return _isExample && !self.fileURL ? Language::C : LanguageForSource(self.fileURL, text);
}

- (BOOL)takeWindowFromUnusedDocument:(SourceDocument *)document
{
    if (!document.isUnusedUntitled || self.windowControllers.count)
        return NO;
    NSWindowController *old = document.windowControllers.firstObject;
    if (![old isKindOfClass:SourceWindowController.class])
        return NO;
    SourceWindowController *controller = (SourceWindowController *)old;
    if (document.tabWindowController == controller)
        return [controller replaceProjectDocument:document withDocument:self];
    NSWindow *window = controller.window;
    [window makeFirstResponder:nil];
    // The same window remains in the same native tab slot.
    [self addWindowController:controller];
    [self installEditor:controller];
    [controller synchronizeWindowTitleWithDocumentName];
    window.documentEdited = self.isDocumentEdited;
    [window makeFirstResponder:_editorWindow.editor];
    return YES;
}

- (BOOL)joinTabsInWindow:(NSWindow *)window
{
    SourceWindowController *target = (SourceWindowController *)window.windowController;
    if (window.attachedSheet || ![target isKindOfClass:SourceWindowController.class] || target.windowClosed ||
        target.workspace != self.workspace)
        return NO;

    if (_tabWindowController == target || self.editorHostWindow == window)
        return YES;

    [_tabWindowController removeProjectDocument:self];
    if (target.usesPaneTabs) {
        NSWindowController *previous = self.windowControllers.firstObject;
        if (previous && previous != target) {
            [self removeWindowController:previous];
            [previous close];
        }
        [target addProjectDocument:self];
        return YES;
    }

    NSWindow *tab = self.editorHostWindow;
    if (!tab) {
        [self makeWindowControllers];
        tab = self.editorHostWindow;
    }
    NSWindowTabGroup *previousGroup = tab.tabGroup;
    if (previousGroup && previousGroup == window.tabGroup)
        return YES;
    if (previousGroup.windows.count > 1)
        [previousGroup removeWindow:tab];
    [window addTabbedWindow:tab ordered:NSWindowAbove];
    [target syncWindowOutput];
    [(SourceWindowController *)tab.windowController syncWindowOutput];
    return YES;
}

- (BOOL)joinNavigationTabInWindow:(NSWindow *)window
{
    SourceWindowController *target = (SourceWindowController *)window.windowController;
    if (![target isKindOfClass:SourceWindowController.class] || target.windowClosed || window.attachedSheet ||
        window.tabGroup.selectedWindow.attachedSheet)
        return NO;

    NSWindow *previous = self.editorHostWindow;
    if (previous == window || (previous.tabGroup && previous.tabGroup == window.tabGroup))
        return YES;
    if (_closing || _reviewingClose || _fileSavesInProgress || previous.attachedSheet ||
        previous.tabGroup.selectedWindow.attachedSheet)
        return NO;
    if (previous) {
        SourceWindowController *controller = (SourceWindowController *)previous.windowController;
        WindowOutput *output = controller.windowOutput;
        if (output.runner || output.debugging)
            return NO;
        if (_tabWindowController) {
            [_tabWindowController removeProjectDocument:self];
        } else if (target.usesPaneTabs) {
            [self removeWindowController:controller];
            [controller close];
        }
    }
    self.workspace = target.workspace;
    return [self joinTabsInWindow:window];
}

- (void)makeWindowControllers
{
    if (self.windowControllers.count || _tabWindowController)
        return;
    SourceWindowController *controller = MakeSourceWindowController(_workspace);
    [self addWindowController:controller];
    [self installEditor:controller];
}

- (void)showWindows
{
    if (_tabWindowController && ![_tabWindowController selectProjectDocument:self])
        return;
    self.workspace.selectedDocument = self;
    NSWindow *window = self.editorHostWindow;
    NSWindowTabGroup *group = window.tabGroup;
    if (group.windows.count > 1)
        group.selectedWindow = window;
    [super showWindows];
}

- (void)requestTabClose
{
    if (_closing || !self.editorHostWindow)
        return;
    [self canCloseDocumentWithDelegate:self shouldCloseSelector:@selector(tabDocument:shouldClose:contextInfo:)
                           contextInfo:nullptr];
}

- (void)splitTabRight
{
    [self showWindows];
    [_editorWindow splitTabAtSide:DockSide::Right];
}

- (IBAction)closeEditorSplit:(id)sender
{
    (void)sender;
    if (!TabActionsBlocked(self.editorHostWindow))
        [_editorWindow closeTabSplit];
}

- (void)copyTabIntoWindow:(NSWindow *)window
{
    SourceDocument *copy = [[SourceDocument alloc] init];
    copy.fileType = self.fileType;
    copy->_initialText = [self.sourceText copy];
    copy->_hasBOM = _hasBOM;

    NSString *name = self.displayName;
    NSString *extension = name.pathExtension;
    name = [[name stringByDeletingPathExtension] stringByAppendingString:@" Copy"];
    copy.displayName = extension.length ? [name stringByAppendingPathExtension:extension] : name;

    NSDictionary *view = _editorWindow ? [_editorWindow sessionView] : _pendingSessionView;
    Language language = _editorWindow ? Language(_editorWindow.languageMode) : [self inferredLanguageForText:copy->_initialText];
    NSNumber *automatic = SessionNumber(view[@"languageAutomatic"]);
    if ((!automatic || automatic.boolValue) && [copy inferredLanguageForText:copy->_initialText] != language) {
        NSMutableDictionary *overrides = view ? [view mutableCopy] : [NSMutableDictionary dictionary];
        overrides[@"language"] = @(NSInteger(language));
        overrides[@"languageAutomatic"] = @NO;
        view = overrides;
    }
    copy->_pendingSessionView = view;
    copy.workspace = WorkspaceForEditorWindow(window);

    BOOL automaticTabbing = NSWindow.allowsAutomaticWindowTabbing;
    NSWindow.allowsAutomaticWindowTabbing = NO;
    [NSDocumentController.sharedDocumentController addDocument:copy];
    SourceWindowController *host = self.tabWindowController;
    if (host && host.window == window)
        [host addProjectDocument:copy inGroup:[host tabLocation:self].group];
    else if (![copy joinTabsInWindow:window])
        [copy makeWindowControllers];

    [copy markSessionDraftEdited];
    [copy showWindows];
    NSWindow.allowsAutomaticWindowTabbing = automaticTabbing;
}

- (void)tabDocument:(NSDocument *)document shouldClose:(BOOL)close contextInfo:(void *)context
{
    (void)document;
    (void)context;
    if (close)
        [self close];
}

- (void)shouldCloseWindowController:(NSWindowController *)controller delegate:(id)delegate
                shouldCloseSelector:(SEL)selector contextInfo:(void *)context
{
    SourceWindowController *project = _tabWindowController;
    if (!project || project != controller || !delegate || !selector) {
        [super shouldCloseWindowController:controller delegate:delegate shouldCloseSelector:selector contextInfo:context];
        return;
    }

    // AppKit can ask the active document to close its project window.
    auto complete = reinterpret_cast<void (*)(id, SEL, NSDocument *, BOOL, void *)>([delegate methodForSelector:selector]);
    complete(delegate, selector, self, NO, context);
    [project requestCloseEditorWindow];
}

- (void)setFileURL:(NSURL *)url
{
    NSURL *before = self.fileURL;
    [super setFileURL:url];
    if (_editorWindow && ![url isEqual:before]) {
        [_editorWindow refreshDebugLocation];
        [_editorWindow refreshDetectedLanguage];
        [_editorWindow refreshLanguageServices];
        [_editorWindow scheduleLanguageCheck];
        [_workspace refresh];
        [self updateTabAppearance];
        if (self.editorHostWindow.windowController.document == self)
            [(SourceWindowController *)self.editorHostWindow.windowController revealCurrentFile];
    }
}

- (void)setFileURLFromExplorer:(NSURL *)url
{
    NSURL *old = self.fileURL;
    NSString *oldPath = DebugSourcePath(old);
    NSDate *date = self.fileModificationDate;
    [super setFileURL:url];
    MoveDebugBreakpoints(oldPath, DebugSourcePath(url));
    [_editorWindow refreshDebugLocation];
    if ([_savedFileURL isEqual:old.URLByStandardizingPath])
        _savedFileURL = url.URLByStandardizingPath;
    id identifier = nil;
    [url getResourceValue:&identifier forKey:NSURLFileResourceIdentifierKey error:nil];
    _explorerRenamedURL = identifier ? url : nil;
    _explorerFileIdentifier = identifier;
    if (url) {
        self.fileModificationDate = date;
        [_editorWindow refreshDetectedLanguage];
    } else {
        [self cancelAutoSave];
        [self setAutoSaveError:nil];
        self.displayName = old.lastPathComponent;
        self.fileModificationDate = nil;
        if (!self.isDocumentEdited)
            [self updateChangeCount:NSChangeDone];
    }
    [_editorWindow scheduleLanguageCheck];
    [_editorWindow refreshLanguageServices];
    NSWindowController *controller = self.windowControllers.firstObject;
    [controller synchronizeWindowTitleWithDocumentName];
}

- (void)updateChangeCount:(NSDocumentChangeType)change
{
    BOOL edited = self.isDocumentEdited;
    [super updateChangeCount:change];
    if (edited != self.isDocumentEdited) {
        [self updateTabAppearance];
        if (!self.isDocumentEdited)
            [self cancelAutoSave];
        else if (!_autoSaveTimer && AutoSavePreference().mode == AutoSaveMode::AfterDelay)
            [self scheduleAutoSaveAfterEdit];
    }
    if (change == NSChangeUndone || change == NSChangeRedone)
        [self queueChangeCheckAfterAutoSave];
}

- (void)updateChangeCountWithToken:(id)token forSaveOperation:(NSSaveOperationType)operation
{
    if ((operation == NSSaveOperation || operation == NSSaveAsOperation) && _saveCleanupChangeToken)
        token = _saveCleanupChangeToken;
    BOOL edited = self.isDocumentEdited;
    [super updateChangeCountWithToken:token forSaveOperation:operation];
    if (operation == NSSaveOperation || operation == NSSaveAsOperation) {
        _explorerRenamedURL = nil;
        _explorerFileIdentifier = nil;
    }
    if (edited != self.isDocumentEdited)
        [self updateTabAppearance];
}

- (IBAction)selectTheme:(NSMenuItem *)sender
{
    SelectEditorTheme(sender.tag);
}

- (IBAction)runDocument:(id)sender
{
    [_editorWindow runSource:sender];
}

- (IBAction)debugCommand:(NSMenuItem *)sender
{
    [_editorWindow performDebugCommand:static_cast<DebugCommand>(sender.tag)];
}

- (IBAction)toggleExplorer:(id)sender
{
    (void)sender;
    _workspace.sidebarShown = !_workspace.sidebarShown;
}

- (void)revealRunLocation:(const RunLocation &)location
{
    [_editorWindow revealRunLocation:location];
}

- (void)revealLanguagePosition:(LSPPosition)position
{
    CodeView *editor = _editorWindow.activeEditor;
    NSUInteger offset = [editor.syntax languageOffset:position];
    if (offset != NSNotFound)
        [editor visitDefinitionAtOffset:offset];
}

- (NSUInteger)languageVersion { return _editorWindow.editor.syntax.languageDocument.version; }

- (void)cancelRun { [_editorWindow stopRun]; }
- (NSUInteger)beginBuildDiagnostics { return [_editorWindow beginBuildDiagnostics]; }
- (NSUInteger)diagnosticVersion { return _editorWindow.editor.syntax.textVersion; }

- (void)applyBuildMessages:(const std::vector<RunMessage> &)messages version:(NSUInteger)version
                     owner:(BOOL)owner fromOutput:(BOOL)fromOutput
{
    [_editorWindow applyBuildMessages:messages version:version owner:owner fromOutput:fromOutput];
}

- (void)close
{
    if (_closing)
        return;
    _closing = YES;
    [self cancelAutoSave];
    [_editorWindow stopRun];
    [_editorWindow cancelLanguageCheck];
    [_editorWindow closeLanguageServices];
    [_tabWindowController removeProjectDocument:self];
    [_workspace removeDocument:self];
    [super close];
}

- (IBAction)selectSmoothing:(NSMenuItem *)sender
{
    SetEditorPreference(smoothingKey, @(sender.tag));
}

- (IBAction)selectFont:(NSMenuItem *)sender
{
    NSString *name = sender.tag == 1 ? @"Monaco" : @"Menlo-Regular";
    SetEditorFont([NSFont fontWithName:name size:FontSizePreference()]);
}

- (IBAction)changeFontSize:(NSMenuItem *)sender
{
    CGFloat size = sender.tag ? std::max(1.0, FontSizePreference() + sender.tag) : defaultFontSize;
    SetEditorPreference(sizeKey, @(size));
}

- (IBAction)toggleVimMode:(NSMenuItem *)sender
{
    (void)sender;
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:vimModeKey];
    SetEditorPreference(vimModeKey, @(!enabled));
    [_editorWindow.window makeFirstResponder:_editorWindow.editor];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = item.action;
    if (action == @selector(setIndentationKind:)) {
        item.state = _editorWindow.indentation.tabs == (item.tag != 0) ? NSControlStateValueOn : NSControlStateValueOff;
        return _editorWindow != nil;
    }
    if (action == @selector(setTabSize:) || action == @selector(detectFileIndentation:) ||
        action == @selector(resetFileIndentation:) || action == @selector(setIndentationAsDefault:))
        return _editorWindow != nil;
    if (action == @selector(convertIndentation:))
        return _editorWindow.activeEditor.editable && !_editorWindow.hasMarkedEditorText;
    if (action == @selector(debugCommand:))
        return [_editorWindow canDebugCommand:static_cast<DebugCommand>(item.tag)];
    if (action == @selector(runDocument:)) {
        item.title = RunCommandTitle(_editorWindow.runCommand);
        return _editorWindow.canRunCommand;
    }
    if (action == @selector(closeEditorSplit:))
        return _editorWindow.hasSplit && !TabActionsBlocked(self.editorHostWindow);
    if (action == @selector(toggleExplorer:)) {
        item.title = _workspace.sidebarShown ? @"Hide Sidebar" : @"Show Sidebar";
        return _workspace != nil;
    }
    if (action == @selector(toggleVimMode:)) {
        item.state = [NSUserDefaults.standardUserDefaults boolForKey:vimModeKey] ?
                     NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(selectTheme:) || action == @selector(selectSmoothing:) ||
        action == @selector(selectFont:)) {
        bool selected;
        if (action == @selector(selectTheme:))
            selected = ThemePreference() == item.tag;
        else if (action == @selector(selectSmoothing:))
            selected = NSInteger(SmoothingPreference()) == item.tag;
        else
            selected = [EditorFontPreference().fontName isEqualToString:item.tag == 1 ? @"Monaco" : @"Menlo-Regular"];
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(changeFontSize:))
        return YES;
    return [super validateMenuItem:item];
}

- (void)saveDocumentWithDelegate:(id)delegate didSaveSelector:(SEL)selector contextInfo:(void *)context
{
    NSURL *url = self.fileURL;
    // AppKit treats an Explorer rename as an external move until the next save.
    if ([_explorerRenamedURL isEqual:url] && self.fileType && !self.isDraft && !self.isLocked) {
        NSURL *file = [NSURL fileURLWithPath:url.path isDirectory:NO];
        NSDictionary *info = [file resourceValuesForKeys:@[NSURLFileResourceIdentifierKey, NSURLContentModificationDateKey] error:nil];
        if ([info[NSURLFileResourceIdentifierKey] isEqual:_explorerFileIdentifier] &&
            [info[NSURLContentModificationDateKey] isEqual:self.fileModificationDate]) {
            [self saveToURL:url ofType:self.fileType forSaveOperation:NSSaveOperation
                  delegate:delegate didSaveSelector:selector contextInfo:context];
            return;
        }
    }
    [super saveDocumentWithDelegate:delegate didSaveSelector:selector contextInfo:context];
}

- (void)saveToURL:(NSURL *)url ofType:(NSString *)type forSaveOperation:(NSSaveOperationType)operation
completionHandler:(void (^)(NSError *))completion
{
    if (!_savingAutomatically)
        [_editorWindow.editor finishVimChange];
    if (operation != NSSaveOperation && operation != NSSaveAsOperation) {
        [super saveToURL:url ofType:type forSaveOperation:operation completionHandler:completion];
        return;
    }
    ++_fileSavesInProgress;
    [super saveToURL:url ofType:type forSaveOperation:operation completionHandler:^(NSError *error) {
        --self->_fileSavesInProgress;
        self->_saveCleanupChangeToken = nil;
        if (!error) {
            [self rememberSavedFile:self.fileURL];
            [self->_editorWindow.editor.syntax.languageDocument saved];
            if (!self.isDocumentEdited)
                [self cancelAutoSave];
        }
        if (completion)
            completion(error);
        [self resumePendingAutoSave];
        if (!self->_fileSavesInProgress && self->_afterSaveForClose) {
            void (^resume)(void) = self->_afterSaveForClose;
            self->_afterSaveForClose = nil;
            dispatch_async(dispatch_get_main_queue(), resume);
        }
    }];
}

- (BOOL)writeSafelyToURL:(NSURL *)url ofType:(NSString *)type forSaveOperation:(NSSaveOperationType)operation
                  error:(NSError **)error
{
    if (_savingAutomatically && operation == NSSaveOperation) {
        FileStamp current = ReadFileStamp(url);
        if (!current.valid || current != _savedFileStamp || ![_savedFileURL isEqual:url.URLByStandardizingPath]) {
            if (error) {
                NSString *message = current.valid ? @"The file changed on disk." : @"The file is no longer on disk.";
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
                                          userInfo:@{NSLocalizedDescriptionKey:message, NSURLErrorKey:url}];
            }
            return NO;
        }
    }
    if (operation != NSSaveOperation && operation != NSSaveAsOperation && operation != NSSaveToOperation)
        return [super writeSafelyToURL:url ofType:type forSaveOperation:operation error:error];
    NSString *text = self.sourceText;
    auto cleanup = [self saveCleanupEditsForText:text];
    if (cleanup.edits.empty())
        return [super writeSafelyToURL:url ofType:type forSaveOperation:operation error:error];

    // Commit buffer edits only after the cleaned copy made it to disk.
    _textBeingSaved = TextByApplyingEdits(text, cleanup);
    BOOL written = [super writeSafelyToURL:url ofType:type forSaveOperation:operation error:error];
    _textBeingSaved = nil;
    if (written && operation != NSSaveToOperation) {
        [self applyWrittenSaveCleanup:std::move(cleanup)];
        _saveCleanupChangeToken = [self changeCountTokenForSaveOperation:operation];
    }
    return written;
}

- (BOOL)needsCloseReview
{
    if (_reviewingClose && _editorWindow.hasMarkedEditorText)
        [_editorWindow finishEditingForClose];
    [self checkCoalescedEditsAfterAutoSave];
    return !_closing && (self.isDocumentEdited || _fileSavesInProgress || _editorWindow.hasMarkedEditorText);
}

- (NSUInteger)closeReviewRevision { return _editorWindow.editor.syntax.textVersion; }

- (void)beginCloseReview
{
    _reviewingClose = YES;
    [_editorWindow finishEditingForClose];
    [self checkCoalescedEditsAfterAutoSave];
}

- (void)endCloseReview
{
    _reviewingClose = NO;
    [self resumePendingAutoSave];
}

- (BOOL)waitForSaveBeforeClosing:(void (^)(void))resume
{
    if (!_fileSavesInProgress)
        return NO;
    _afterSaveForClose = [resume copy];
    return YES;
}

- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    if (!delegate || !selector)
        return;
    ReviewDocumentsForClosing(@[self], ^(NSSet<SourceDocument *> *discarded) {
        using CloseFinished = void (*)(id, SEL, NSDocument *, BOOL, void *);
        auto finish = reinterpret_cast<CloseFinished>([delegate methodForSelector:selector]);
        finish(delegate, selector, self, discarded != nil, contextInfo);
    });
}

- (void)vimDidSave:(NSDocument *)document didSave:(BOOL)saved contextInfo:(void *)context
{
    (void)document;
    (void)context;
    if (saved)
        [self requestTabClose];
}

- (NSURL *)vimURL:(NSString *)argument
{
    if (!argument.length)
        return nil;
    NSString *path = [[argument stringByReplacingOccurrencesOfString:@"\\ " withString:@" "] stringByExpandingTildeInPath];
    if (path.isAbsolutePath)
        return [NSURL fileURLWithPath:path];
    NSURL *directory = self.fileURL ? self.fileURL.URLByDeletingLastPathComponent : self.workspace.folder;
    if (!directory)
        directory = [NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath isDirectory:YES];
    return [directory URLByAppendingPathComponent:path];
}

- (void)performVimAction:(Vim::Action)action argument:(NSString *)argument force:(BOOL)force
{
    using Vim::Action;
    NSURL *url = [self vimURL:argument];
    NSDocumentController *controller = NSDocumentController.sharedDocumentController;
    switch (action) {
        case Action::Save:
            [self saveDocument:nil];
            return;
        case Action::Close:
            if (force)
                [self close];
            else
                [self requestTabClose];
            return;
        case Action::Open:
            if (url) {
                OpenSourceTab(url, self.editorHostWindow, ^(NSDocument *, BOOL, NSError *error) {
                    if (error)
                        [self presentError:error];
                });
            }
            return;
        case Action::Revert:
            if (self.fileURL && force) {
                NSError *error = nil;
                if (![self revertToContentsOfURL:self.fileURL ofType:self.fileType error:&error] && error)
                    [self presentError:error];
                else
                    [self updateChangeCount:NSChangeCleared];
            } else if (self.fileURL) {
                [self revertDocumentToSaved:nil];
            }
            return;
        case Action::JumpFileMark:
            if (argument.length)
                [VimTextView jumpToVimFileMark:[argument characterAtIndex:0] exact:force inWindow:self.editorHostWindow];
            return;
        case Action::SourceMappings: {
            if (!url)
                return;
            NSError *error = nil;
            NSString *config = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
            if (config)
                [_editorWindow.activeEditor loadVimMappings:config];
            else if (error)
                [self presentError:error];
            return;
        }
        case Action::SplitBelow: case Action::SplitRight: case Action::WindowCommand:
            return;
        case Action::NextWindow: case Action::PreviousWindow: {
            NSArray<NSDocument *> *documents = controller.documents;
            NSUInteger index = [documents indexOfObjectIdenticalTo:self];
            if (index != NSNotFound && documents.count > 1) {
                index = (index + (action == Action::NextWindow ? 1 : documents.count - 1)) % documents.count;
                [documents[index] showWindows];
            }
            return;
        }
        case Action::SaveClose:
            if (!url) {
                [self saveDocumentWithDelegate:self didSaveSelector:@selector(vimDidSave:didSave:contextInfo:)
                                    contextInfo:nullptr];
                return;
            }
            break;
        case Action::SaveAs:
            if (!url) {
                [self saveDocumentAs:nil];
                return;
            }
            break;
        case Action::WriteCopy:
            break;
    }
    if (!url)
        return;
    BOOL sameFile = [url.URLByStandardizingPath isEqual:self.fileURL.URLByStandardizingPath];
    NSString *type = self.fileType ? self.fileType : @"public.source-code";
    NSError *error = nil;
    [_editorWindow.editor finishVimChange];
    NSString *text = self.sourceText;
    auto cleanup = [self saveCleanupEditsForText:text];
    NSData *data = [self dataForSourceText:TextByApplyingEdits(text, cleanup) error:&error];
    NSDataWritingOptions options = force || sameFile ? NSDataWritingAtomic : NSDataWritingWithoutOverwriting;
    if (!data || ![data writeToURL:url options:options error:&error]) {
        if (error)
            [self presentError:error];
        return;
    }
    if (sameFile || !self.fileURL || action != Action::WriteCopy) {
        [self applyWrittenSaveCleanup:std::move(cleanup)];
        self.fileType = type;
        self.fileURL = url;
        id modificationDate = nil;
        if ([url getResourceValue:&modificationDate forKey:NSURLContentModificationDateKey error:nil])
            self.fileModificationDate = modificationDate;
        [self rememberSavedFile:url];
        [self updateChangeCount:NSChangeCleared];
        [self cancelAutoSave];
    }
    if (action == Action::SaveClose)
        [self requestTabClose];
}

@end

NSArray<NSMenuItem *> *FileIndentationCommands(SourceDocument *document)
{
    if (!document)
        return @[];
    static const struct {
        NSString *title;
        SEL action;
        NSInteger tag;
    } commands[] = {
        {@"Indent Using Spaces", @selector(setIndentationKind:), 0},
        {@"Indent Using Tabs", @selector(setIndentationKind:), 1},
        {@"Convert Indentation to Spaces", @selector(convertIndentation:), 0},
        {@"Convert Indentation to Tabs", @selector(convertIndentation:), 1},
        {@"Detect Indentation from Content", @selector(detectFileIndentation:), 0},
        {@"Reset Indentation", @selector(resetFileIndentation:), 0},
        {@"Use Indentation as Default", @selector(setIndentationAsDefault:), 0},
    };
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray arrayWithCapacity:std::size(commands)];
    for (const auto &command : commands) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:command.title action:command.action keyEquivalent:@""];
        item.target = document;
        item.tag = command.tag;
        item.enabled = [document validateMenuItem:item];
        [items addObject:item];
    }
    return items;
}
