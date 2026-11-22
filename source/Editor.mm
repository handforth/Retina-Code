#import "Editor.h"
#import "Workspace.h"
#import "Chrome.h"
#import "FolderSearch.h"
#import "Output.h"
#import "Preferences.h"
#import "Rendering.h"
#import "SessionState.h"
#import "Typing.h"
#import "VimView.h"
#include "Lexer.hpp"
#include "Themes.h"

#import <CoreText/CoreText.h>
#import <objc/runtime.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iterator>
#include <map>
#include <memory>
#include <sys/stat.h>

static constexpr CGFloat editorPadding = 4;
static constexpr CGFloat editorLineSpacing = 3;
static constexpr CGFloat gutterInset = 9;
static constexpr CGFloat statusHeight = 23;
static constexpr CGFloat containerLimit = 10000000;
static constexpr NSUInteger largeDocumentLength = 256 * 1024;

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

static void OpenRelatedFile(NSURL *url, NSWindow *window, SourceOpenCompletion completion)
{
    NSDocumentController *controller = NSDocumentController.sharedDocumentController;
    if ([controller respondsToSelector:@selector(openSourceURL:inWindow:completionHandler:)]) {
        [(id<SourceFileOpening>)controller openSourceURL:url inWindow:window completionHandler:completion];
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

@interface EditorTextStorage : NSTextStorage
- (void)applyAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes
               removing:(NSAttributedStringKey)key inRange:(NSRange)range;
@end

@implementation EditorTextStorage {
    NSMutableAttributedString *_contents;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _contents = [[NSMutableAttributedString alloc] init];
    return self;
}

- (NSString *)string { return _contents.string; }

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
    NSInteger delta = NSInteger(text.length) - NSInteger(range.length);
    [_contents replaceCharactersInRange:range withString:text];
    [self edited:NSTextStorageEditedCharacters range:range changeInLength:delta];
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)text
{
    NSInteger delta = NSInteger(text.length) - NSInteger(range.length);
    [_contents replaceCharactersInRange:range withAttributedString:text];
    [self edited:NSTextStorageEditedCharacters | NSTextStorageEditedAttributes range:range changeInLength:delta];
}

- (void)setAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes range:(NSRange)range
{
    [_contents setAttributes:attributes range:range];
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

@end

struct BuildError {
    NSRange range;
    NSString *message = nil;
};

@class SyntaxBuffer;

@interface CodeView : VimTextView
@property(nonatomic) const Theme *theme;
@property(nonatomic) RenderSettings rendering;
@property(nonatomic) NSRect currentLine;
@property(nonatomic, weak) SyntaxBuffer *syntax;
@property(nonatomic, readonly) NSFont *editorFont;
- (void)applyAppearance;
- (void)applyAppearanceWithTheme:(const ThemeRef &)palette;
- (void)loadText:(NSString *)text;
- (void)prepareDocumentAppearance:(NSString *)text;
- (void)refreshBracketMatch;
- (void)refreshWordSelection;
- (void)dismissCompletion;
- (BOOL)validateCompletion;
- (void)refreshBuildErrorToolTips;
@end

@interface SyntaxBuffer : NSObject <NSTextStorageDelegate>
@property(nonatomic, readonly) EditorTextStorage *storage;
@property(nonatomic, readonly) Indentation indentation;
@property(nonatomic, readonly) BOOL hasFileIndentation;
@property(nonatomic) Language language;
- (NSUInteger)lineForOffset:(NSUInteger)offset;
- (NSUInteger)offsetForLine:(NSUInteger)line;
- (NSUInteger)lineCount;
- (BOOL)codeAtOffset:(NSUInteger)offset;
- (LexState)contextAtOffset:(NSUInteger)offset;
- (NSArray<NSString *> *)completionsForPrefix:(std::u16string_view)prefix limit:(NSUInteger)limit;
- (NSArray<NSString *> *)completionsForPrefix:(std::u16string_view)prefix limit:(NSUInteger)limit
                                   language:(Language)language;
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
- (void)addBuildErrors:(const std::vector<BuildError> &)errors;
- (void)clearBuildErrors;
@end

@implementation SyntaxBuffer {
    ThemeRef _theme;
    NSArray<NSColor *> *_colors;
    NSArray<NSColor *> *_bracketColors;
    std::vector<uint32_t> _bracketStarts;
    std::vector<BracketNode> _bracketNodes;
    NSFont *_font;
    NSFont *_italicFont;
    std::vector<TypedPair> _typedPairs;
    std::vector<BuildError> _buildErrors;
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

- (NSArray<NSString *> *)completionsForPrefix:(std::u16string_view)prefix limit:(NSUInteger)limit
{
    return [self completionsForPrefix:prefix limit:limit language:_language];
}

- (NSArray<NSString *> *)completionsForPrefix:(std::u16string_view)prefix limit:(NSUInteger)limit
                                   language:(Language)language
{
    [self finishHighlighting];
    const auto &words = CompletionWords(language);
    auto keyword = std::upper_bound(words.begin(), words.end(), prefix);
    auto name = _names.upper_bound(prefix);
    NSMutableArray<NSString *> *results = [NSMutableArray arrayWithCapacity:limit];
    while (results.count < limit) {
        bool hasKeyword = keyword != words.end() && keyword->starts_with(prefix);
        bool hasName = name != _names.end() && name->first.starts_with(prefix);
        if (!hasKeyword && !hasName)
            break;
        std::u16string_view word = hasKeyword && (!hasName || *keyword <= name->first) ?
                                   *keyword : std::u16string_view(name->first);
        [results addObject:[[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(word.data())
                                                       length:word.size()]];
        if (hasKeyword && *keyword == word)
            ++keyword;
        if (hasName && name->first == word)
            ++name;
    }
    return results;
}

- (const std::vector<TypedPair> &)typedPairs { return _typedPairs; }

- (void)didType:(const TypingEdit &)edit
{
    if (edit.passedCloser != NSNotFound) {
        std::erase_if(_typedPairs, [&](const TypedPair &pair) {
            return edit.passedCloser == NSMaxRange(pair.closing) - 1;
        });
    }
    if (edit.pair && NSMaxRange(edit.pair->closing) <= _storage.length) {
        if (_typedPairs.size() >= 512)
            _typedPairs.erase(_typedPairs.begin());
        _typedPairs.push_back(*edit.pair);
    }
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
            return std::binary_search(passed.begin(), passed.end(), NSMaxRange(pair.closing) - 1);
        });
    }
    for (const auto &edit : edits) {
        if (edit.pair && NSMaxRange(edit.pair->closing) <= _storage.length)
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
                bool nameToken = updateIndex &&
                    (token.ink == Ink::Text || token.ink == Ink::Name || token.ink == Ink::Type ||
                     token.ink == Ink::Function || token.ink == Ink::Constant ||
                     (plain && (token.ink == Ink::Keyword || token.ink == Ink::Control)));
                if (nameToken && !token.nonCode && token.length > 1 && line[token.start] != u'\'') {
                    std::u16string_view word = std::u16string_view(line).substr(token.start, token.length);
                    auto name = _names.lower_bound(word);
                    if (name == _names.end() || name->first != word)
                        name = _names.emplace_hint(name, word, 0);
                    ++name->second;
                    names.push_back(name);
                }
                if (!plain && _theme->ink[ink] != _theme->ink[size_t(Ink::Text)])
                    [_storage addAttribute:NSForegroundColorAttributeName value:_colors[ink] range:range];
                if (token.nonCode || token.ink == Ink::Comment || token.ink == Ink::String || token.ink == Ink::Escape) {
                    Ink role = token.ink == Ink::Comment || token.ink == Ink::Escape ? token.ink : Ink::String;
                    [_storage addAttribute:EditorNonCodeAttribute value:@(NSInteger(role)) range:range];
                }
                if (!plain && _italicFont &&
                    ((token.ink == Ink::Type && _theme->italicTypes) ||
                     (token.ink == Ink::Comment && _theme->italicComments)))
                    [_storage addAttribute:NSFontAttributeName value:_italicFont range:range];
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
        size_t common = std::min(replaced, names.size());
        std::copy_n(names.begin(), common, _lineNames.begin() + firstName);
        if (names.size() < replaced)
            _lineNames.erase(_lineNames.begin() + firstName + common, _lineNames.begin() + pastName);
        else if (names.size() > replaced)
            _lineNames.insert(_lineNames.begin() + pastName, names.begin() + common, names.end());
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
        if (updated.size() == resume - firstLine) {
            std::move(updated.begin(), updated.end(), _lines.begin() + firstLine);
            if (colorize)
                std::copy(updatedBracketStarts.begin(), updatedBracketStarts.end(), _bracketStarts.begin() + firstLine);
        } else {
            auto insertion = _lines.erase(_lines.begin() + firstLine, _lines.begin() + resume);
            _lines.insert(insertion, std::make_move_iterator(updated.begin()), std::make_move_iterator(updated.end()));
            if (colorize) {
                auto start = _bracketStarts.erase(_bracketStarts.begin() + firstLine, _bracketStarts.begin() + resume);
                _bracketStarts.insert(start, updatedBracketStarts.begin(), updatedBracketStarts.end());
            }
        }
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

- (void)refreshBuildErrorViews
{
    for (NSLayoutManager *layout in _storage.layoutManagers) {
        NSTextView *view = layout.textContainers.firstObject.textView;
        if ([view isKindOfClass:CodeView.class])
            [(CodeView *)view refreshBuildErrorToolTips];
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
    NSUInteger tooltipCharacters = outputScrollbackCharacters;
    for (auto &error : _buildErrors) {
        if (error.message.length > tooltipCharacters)
            error.message = nil;
        else
            tooltipCharacters -= error.message.length;
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
    NSFont *previousItalicFont = _italicFont;
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
}

- (void)setLanguage:(Language)language
{
    if (_language != language) {
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
    NSUInteger oldLength = NSUInteger(NSInteger(range.length) - delta);
    NSRange previous = NSMakeRange(range.location, oldLength);
    const auto *batch = [VimTextView cursorBatchForStorage:storage];
    if (batch) {
        auto adjust = [&](NSRange &part) {
            if (batch->overlaps({part.location, NSMaxRange(part)}))
                return false;
            part.location = batch->map(part.location);
            return true;
        };
        std::erase_if(_typedPairs, [&](TypedPair &pair) {
            return !adjust(pair.opening) || !adjust(pair.closing);
        });
        [VimTextView vimStorage:storage editedBatch:*batch];
    } else {
        AdjustTypedPairs(_typedPairs, previous, range.length);
        [VimTextView vimStorage:storage edited:previous newLength:range.length];
    }
    for (NSLayoutManager *layout in storage.layoutManagers) {
        NSTextView *view = layout.textContainers.firstObject.textView;
        if ([view isKindOfClass:VimTextView.class]) {
            if (batch)
                [(VimTextView *)view vimStorageEditedBatch:*batch];
            else
                [(VimTextView *)view vimStorageEdited:previous newLength:range.length];
        }
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
    NSUInteger start = [buffer offsetForLine:line - 1], end = start;
    NSString *source = buffer.storage.string;
    if (start < source.length)
        [source getLineStart:nullptr end:nullptr contentsEnd:&end forRange:NSMakeRange(start, 0)];
    return NSMakeRange(start, end - start);
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

static NSRange BuildErrorRange(SyntaxBuffer *buffer, const RunLocation &location, BOOL hasBOM)
{
    NSRange line = SourceLine(buffer, location.line);
    if (!line.length)
        return line;
    NSString *text = buffer.storage.string;
    if (location.endColumn > location.firstColumn) {
        NSUInteger start = SourceColumn(text, line, location.firstColumn, location.byteColumns, hasBOM);
        NSUInteger end = SourceColumn(text, line, location.endColumn, location.byteColumns, hasBOM);
        if (end > start)
            return NSMakeRange(start, end - start);
    }
    NSUInteger at = SourceColumn(text, line, location.column, location.byteColumns, hasBOM);
    NSRange token = [text rangeOfComposedCharacterSequenceAtIndex:std::min(at, NSMaxRange(line) - 1)];
    while (NSMaxRange(token) < NSMaxRange(line) && WordCharacterAt(text, token.location) &&
           WordCharacterAt(text, NSMaxRange(token))) {
        NSRange next = [text rangeOfComposedCharacterSequenceAtIndex:NSMaxRange(token)];
        token.length += next.length;
    }
    return token;
}

static constexpr CGFloat completionRowHeight = 18;
static constexpr CGFloat completionInset = 2;
static constexpr NSUInteger completionLimit = 8;

@interface CompletionList : NSView
@property(nonatomic, readonly) NSArray<NSString *> *items;
@property(nonatomic) NSUInteger selectedRow;
@property(nonatomic, copy) void (^accept)(void);
- (NSSize)setItems:(NSArray<NSString *> *)items theme:(const ThemeRef &)theme;
@end

@implementation CompletionList {
    ThemeRef _theme;
    NSTextFieldCell *_label;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _label = [[NSTextFieldCell alloc] initTextCell:@""];
        NSFont *font = [NSFont fontWithName:@"Menlo-Regular" size:11];
        _label.font = font ? font : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        _label.drawsBackground = NO;
        _label.bordered = NO;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        self.accessibilityLabel = @"Completions";
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (NSSize)setItems:(NSArray<NSString *> *)items theme:(const ThemeRef &)theme
{
    _items = items;
    _theme = theme;
    self.selectedRow = 0;
    CGFloat width = 140;
    NSDictionary *attributes = @{NSFontAttributeName:_label.font};
    for (NSString *item in items)
        width = std::max(width, std::ceil([item sizeWithAttributes:attributes].width) + 18);
    return NSMakeSize(std::min(width, 300.0), items.count * completionRowHeight + 2 * completionInset);
}

- (void)setSelectedRow:(NSUInteger)row
{
    _selectedRow = row;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    const EditorAccents &accents = _theme->accents;
    [SRGBColor(accents.completionBorder) setFill];
    NSRectFill(self.bounds);
    [SRGBColor(accents.completionPaper) setFill];
    NSRectFill(NSInsetRect(self.bounds, 1, 1));
    for (NSUInteger i = 0; i < _items.count; ++i) {
        NSRect row = NSMakeRect(completionInset, completionInset + i * completionRowHeight,
                                NSWidth(self.bounds) - 2 * completionInset, completionRowHeight);
        if (!NSIntersectsRect(dirty, row))
            continue;
        if (i == _selectedRow) {
            [SRGBColor(accents.completionSelection) setFill];
            NSRectFill(row);
        }
        _label.stringValue = _items[i];
        _label.textColor = SRGBColor(i == _selectedRow ? accents.completionSelectedText : _theme->ink[size_t(Ink::Text)]);
        [_label drawInteriorWithFrame:NSInsetRect(row, 5, 0) inView:self];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    CGFloat y = [self convertPoint:event.locationInWindow fromView:nil].y - completionInset;
    if (y >= 0 && y < _items.count * completionRowHeight) {
        self.selectedRow = NSUInteger(y / completionRowHeight);
        if (self.accept)
            self.accept();
    }
}

@end

@implementation CodeView {
    ThemeRef _palette;
    NSFont *_editorFont;
    NSUInteger _fontTabStop;
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
    NSRange _wordSelection;
    NSString *_selectedWord;
    NSUInteger _wordVersion;
    std::vector<NSToolTipTag> _buildErrorToolTips;
}

- (NSUInteger)vimDocumentLineCount { return self.syntax.lineCount; }
- (NSUInteger)vimLineAtOffset:(NSUInteger)offset { return [self.syntax lineForOffset:offset]; }
- (NSUInteger)vimOffsetAtLine:(NSUInteger)line { return [self.syntax offsetForLine:line]; }
- (BOOL)vimStructuralCharacterAtOffset:(NSUInteger)offset { return [self.syntax codeAtOffset:offset]; }

- (Vim::Comments)commentsAtOffset:(NSUInteger)offset
{
    Language language = self.syntax.language;
    if (language == Language::HTML || language == Language::Markdown || language == Language::PHP ||
        language == Language::JSX || language == Language::TSX) {
        LexState context = [self.syntax contextAtOffset:offset];
        language = LanguageInContext(language, context);
        if (context.mode == LexMode::MarkupText) {
            if (language == Language::JSX || language == Language::TSX)
                return {{}, u"{/*", u"*/}"};
            if (language == Language::PHP)
                language = Language::HTML;
        }
    }
    const auto &style = InfoForLanguage(language).comments;
    return {style.line, style.open, style.close};
}

- (Vim::Comments)vimComments
{
    return [self commentsAtOffset:std::min(self.selectedRange.location, self.string.length)];
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
            insertionAdvance:[](Vim::Text inserted) {
        // Keep the selection with the code and put an empty block caret between its markers.
        auto space = inserted.find(u' ');
        return space == 0 || space == Vim::Text::npos ? Vim::Offset(0) : space + 1;
    }];
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
            NSUInteger start = [self.syntax offsetForLine:row];
            if (start >= text.length)
                break;
            NSUInteger end;
            [text getLineStart:nullptr end:nullptr contentsEnd:&end forRange:NSMakeRange(start, 0)];
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
    [self refreshBuildErrorToolTips];
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
    bool lisp = self.syntax.language == Language::CommonLisp;
    return [self insertionLocationsMatch:^BOOL(NSUInteger at) {
        if (at < range.length || at > source.length || (at < source.length && WordCharacterAt(source, at, lisp)))
            return NO;
        NSUInteger start = at - range.length;
        return (!start || !WordCharacterAt(source, start - 1, lisp)) && [self.syntax codeAtOffset:at - 1] &&
            [source compare:prefix options:NSLiteralSearch range:NSMakeRange(start, range.length)] == NSOrderedSame;
    }];
}

- (void)dismissCompletion
{
    _completion.hidden = YES;
}

- (BOOL)validateCompletion
{
    if (!_completion || _completion.hidden)
        return NO;
    if (_completionVersion != self.syntax.textVersion || ![self allowsCompletion] ||
        !NSEqualRanges(self.selectedRange, NSMakeRange(NSMaxRange(_completionPrefix), 0)) ||
        ![self cursorsShareCompletionPrefix:_completionPrefix]) {
        [self dismissCompletion];
        return NO;
    }
    return YES;
}

- (BOOL)acceptCompletion
{
    if (![self validateCompletion])
        return NO;
    NSString *word = _completion.items[_completion.selectedRow];
    NSString *suffix = [word substringFromIndex:_completionPrefix.length];
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

- (void)showCompletionsWithMinimumPrefix:(NSUInteger)minimum
{
    [self dismissCompletion];
    NSScrollView *scroll = self.enclosingScrollView;
    NSView *host = scroll.superview;
    if (!host || !self.theme || self.window.firstResponder != self || ![self allowsCompletion])
        return;

    NSString *text = self.string;
    NSRange caret = self.selectedRange;
    NSUInteger end = caret.location;
    Language language = self.syntax.language;
    bool lisp = language == Language::CommonLisp;
    if (caret.length || end == 0 || end > text.length ||
        (end < text.length && WordCharacterAt(text, end, lisp)))
        return;
    NSUInteger start = end;
    while (start > 0 && WordCharacterAt(text, start - 1, lisp))
        --start;
    if (end - start < minimum)
        return;
    unichar first = [text characterAtIndex:start];
    if (!lisp && first < 0x80 && !IsASCIIIdentifierStart(first))
        return;
    [self.syntax finishHighlighting];
    if (![self.syntax codeAtOffset:end - 1])
        return;

    NSRect visible = NSInsetRect(self.visibleRect, 2, 2);
    NSRect anchor = [self vimCaretAt:start];
    CGFloat below = NSMaxY(visible) - NSMaxY(anchor) - 1;
    CGFloat above = NSMinY(anchor) - NSMinY(visible) - 1;
    CGFloat available = std::max(below, above) - 2 * completionInset;
    if (available < completionRowHeight || NSWidth(visible) < 48 ||
        NSMaxY(anchor) <= NSMinY(visible) || NSMinY(anchor) >= NSMaxY(visible))
        return;
    NSUInteger limit = std::min(completionLimit, NSUInteger(available / completionRowHeight));
    NSRange range = NSMakeRange(start, end - start);
    if (![self cursorsShareCompletionPrefix:range])
        return;
    std::u16string prefix(range.length, 0);
    [text getCharacters:reinterpret_cast<unichar *>(prefix.data()) range:range];
    if (language == Language::HTML || language == Language::Markdown || language == Language::PHP)
        language = LanguageInContext(language, [self.syntax contextAtOffset:end]);
    NSArray<NSString *> *items = [self.syntax completionsForPrefix:prefix limit:limit language:language];
    if (!items.count)
        return;

    if (!_completion) {
        _completion = [[CompletionList alloc] initWithFrame:NSZeroRect];
        __weak CodeView *view = self;
        _completion.accept = ^{ [view acceptCompletion]; };
    }
    NSSize size = [_completion setItems:items theme:_palette];
    size.width = std::min(size.width, NSWidth(visible));
    CGFloat x = std::clamp(NSMinX(anchor), NSMinX(visible), NSMaxX(visible) - size.width);
    CGFloat y = below >= size.height ? NSMaxY(anchor) + 1 : NSMinY(anchor) - size.height - 1;
    _completion.frame = [self convertRect:NSMakeRect(x, y, size.width, size.height) toView:host];
    _completionPrefix = range;
    _completionVersion = self.syntax.textVersion;
    if (_completion.superview != host)
        [host addSubview:_completion positioned:NSWindowAbove relativeTo:scroll];
    _completion.hidden = NO;
}

- (void)complete:(id)sender
{
    (void)sender;
    [self showCompletionsWithMinimumPrefix:1];
}

- (void)moveCompletionSelectionUp:(BOOL)up
{
    NSUInteger count = _completion.items.count;
    _completion.selectedRow = (_completion.selectedRow + (up ? count - 1 : 1)) % count;
}

- (void)keyDown:(NSEvent *)event
{
    NSString *keys = event.charactersIgnoringModifiers;
    unichar key = keys.length == 1 ? [keys characterAtIndex:0] : 0;
    NSEventModifierFlags modifiers = event.modifierFlags &
        (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand);
    BOOL open = [self validateCompletion];
    if (open && !modifiers) {
        if (key == '\t' && [self acceptCompletion])
            return;
        if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
            [self moveCompletionSelectionUp:key == NSUpArrowFunctionKey];
            return;
        }
        if (key == 27 && !self.vimEnabled) {
            [self dismissCompletion];
            return;
        }
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
    if (!backspace)
        [self dismissCompletion];
    [super keyDown:event];
    if (open && backspace && (self.vimEnabled || self.cursorCount > 1))
        [self showCompletionsWithMinimumPrefix:2];
}

- (void)mouseDown:(NSEvent *)event
{
    [self dismissCompletion];
    [super mouseDown:event];
}

- (BOOL)resignFirstResponder
{
    [self dismissCompletion];
    return [super resignFirstResponder];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selection replacementRange:(NSRange)replacement
{
    [self dismissCompletion];
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
    bool lisp = self.syntax.language == Language::CommonLisp;
    BOOL suggest = !_pasting && singleCharacter &&
                   WordCharacterAt(text, 0, lisp) && [self allowsCompletion];
    NSUInteger version = self.syntax.textVersion;
    if (text.length == 1 && [self applyTyping:TypingKey::Character character:[text characterAtIndex:0] selected:selected])
        return;
    [super insertText:string replacementRange:range];
    if (suggest && version != self.syntax.textVersion)
        [self showCompletionsWithMinimumPrefix:2];
}

- (void)insertNewline:(id)sender
{
    if (![self applyTyping:TypingKey::Enter character:0 selected:self.selectedRange])
        [super insertNewline:sender];
}

- (void)insertLineBreak:(id)sender
{
    if (![self applyTyping:TypingKey::Enter character:0 selected:self.selectedRange])
        [super insertLineBreak:sender];
}

- (void)deleteBackward:(id)sender
{
    BOOL update = !self.vimEnabled && [self validateCompletion];
    if (![self applyTyping:TypingKey::Backspace character:0 selected:self.selectedRange])
        [super deleteBackward:sender];
    if (update)
        [self showCompletionsWithMinimumPrefix:2];
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
    bool lisp = self.syntax.language == Language::CommonLisp;
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
    bool lisp = self.syntax.language == Language::CommonLisp;
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
    if (position == NSNotFound || position >= self.string.length)
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
    if (match.mate == NSNotFound)
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
    if (_brackets.mate == NSNotFound)
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

    NSFont *font = EditorFontPreference();
    [self.syntax refreshIndentationDefaults];
    Indentation indentation = self.syntax.indentation;
    [self setVimIndentation:indentation];
    NSUInteger tabStop = indentation.tabWidth;
    EditorTextStorage *storage = self.syntax.storage;
    bool typographyChanged = ![_editorFont isEqual:font] || _fontTabStop != tabStop;
    if (typographyChanged) {
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        paragraph.baseWritingDirection = NSWritingDirectionLeftToRight;
        paragraph.minimumLineHeight = std::ceil(font.ascender - font.descender + font.leading);
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
        [self refreshBuildErrorToolTips];
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
    if (errors.empty())
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
    for (const BuildError &error : errors) {
        NSRange span = error.range;
        if (span.location > visibleEnd)
            break;
        if (NSMaxRange(span) < visible.location)
            continue;
        auto next = std::upper_bound(hidden.begin(), hidden.end(), span.location,
                                    [](NSUInteger at, NSRange range) { return at < range.location; });
        if (next != hidden.begin() && NSLocationInRange(span.location, *(next - 1)))
            continue;
        NSRect rect;
        if (span.length) {
            NSRange range = [layout glyphRangeForCharacterRange:span actualCharacterRange:nullptr];
            rect = [layout boundingRectForGlyphRange:range inTextContainer:container];
            NSRect line = [layout lineFragmentRectForGlyphAtIndex:range.location effectiveRange:nullptr];
            rect.origin.y = NSMinY(line);
            rect.size.height = NSHeight(line);
            rect = NSOffsetRect(rect, origin.x, origin.y);
        } else {
            rect = [self vimCaretAt:span.location];
        }
        if (NSIntersectsRect(rect, area))
            block(error, rect);
    }
}

- (void)refreshBuildErrorToolTips
{
    for (NSToolTipTag tag : _buildErrorToolTips)
        [self removeToolTip:tag];
    _buildErrorToolTips.clear();
    if (!self.window)
        return;
    NSRect visible = self.visibleRect;
    if (NSIsEmptyRect(visible))
        return;
    [self enumerateBuildErrorsInRect:visible usingBlock:^(const BuildError &error, NSRect rect) {
        if (!error.message.length)
            return;
        NSToolTipTag tag = [self addToolTipRect:NSIntersectionRect(rect, visible) owner:error.message userData:nullptr];
        if (tag)
            _buildErrorToolTips.push_back(tag);
    }];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self refreshBuildErrorToolTips];
}

- (void)drawBuildErrors:(NSRect)dirty
{
    [self enumerateBuildErrorsInRect:dirty usingBlock:^(const BuildError &, NSRect rect) {
        NSRect underline = NSMakeRect(NSMinX(rect), NSMaxY(rect) - 2, NSWidth(rect), 2);
        if (!NSIntersectsRect(underline, dirty))
            return;
        [SRGBColor(self.theme->dark ? rgb(255, 83, 83) : rgb(210, 25, 35)) setStroke];
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

- (void)drawVimBlockCarets:(const std::vector<VimBlockCaret> &)carets dirty:(NSRect)dirty
{
    CodeLayoutManager *layout = (CodeLayoutManager *)self.layoutManager;
    NSPoint origin = self.textContainerOrigin;
    NSString *source = self.string;
    NSColor *fill = self.insertionPointColor;
    NSColor *ink = SRGBColor(*self.theme->blockCaretText);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    for (const auto &caret : carets) {
        NSRect box = [self backingAlignedRect:caret.rect options:NSAlignAllEdgesNearest];
        box = NSIntersectionRect(box, dirty);
        if (NSIsEmptyRect(box))
            continue;
        [fill setFill];
        NSRectFill(box);
        if (caret.position < source.length) {
            NSRange characters = [source rangeOfComposedCharacterSequenceAtIndex:caret.position];
            NSRange glyphs = [layout glyphRangeForCharacterRange:characters actualCharacterRange:nullptr];
            CGContextSaveGState(context);
            CGContextClipToRect(context, box);
            [layout drawGlyphsForGlyphRange:glyphs atPoint:origin color:ink];
            CGContextRestoreGState(context);
        }
    }
}

- (void)drawRect:(NSRect)dirty
{
    dirty = NSIntersectionRect(dirty, self.visibleRect);
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
        [self drawWordOccurrences:rect];
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
                      blockCarets:self.theme->blockCaretText ? &blockCarets : nullptr];
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
        [self drawFoldMarks:rect];
        [self drawBracketMatch:rect flash:NO];
        [self drawBuildErrors:rect];
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
@end

@implementation EditorPreview {
    SyntaxBuffer *_buffer;
    CodeView *_editor;
}

- (instancetype)init
{
    self = [super initWithFrame:NSMakeRect(0, 0, 516, 190)];
    if (!self)
        return nil;
    _buffer = [[SyntaxBuffer alloc] init];
    _buffer.language = Language::C;
    _editor = CreateCodeView(_buffer, @"#include <stdio.h>\n\n"
                            "enum { WIDTH = 64, HEIGHT = 64 };\n\n"
                            "int main(void)\n{\n"
                            "\t/* P6 is the binary PPM format. */\n"
                            "    printf(\"P6\\n%d %d\\n255\\n\", WIDTH, HEIGHT);  \n"
                            "    for (int i = 0; i < WIDTH * HEIGHT; ++i) {\n"
                            "        unsigned char rgb[] = {i & 255, 64, 255};\n"
                            "        fwrite(rgb, 1, sizeof rgb, stdout);\n"
                            "    }\n"
                            "    return 0;\n}");
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
    [self preferencesChanged:nil];
    return self;
}

- (void)preferencesChanged:(NSNotification *)notification
{
    (void)notification;
    [_editor applyAppearance];
    [_editor sizeToFit];
    self.backgroundColor = RenderedEditorColor(_editor.theme->paper, _editor.rendering);
    self.appearance = [NSAppearance appearanceNamed:_editor.theme->dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

@end

NSView *CreateEditorPreview()
{
    return [[EditorPreview alloc] init];
}

@interface Gutter : NSView
@property(nonatomic, weak) CodeView *editor;
@property(nonatomic, weak) SyntaxBuffer *buffer;
@property(nonatomic) NSFont *numberFont;
@end

@implementation Gutter

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
    NSRect visible = editor.visibleRect;
    NSRect area = NSMakeRect(0, NSMinY(visible) - origin.y, NSWidth(editor.bounds), NSHeight(visible));
    NSRange glyphs = [layout glyphRangeForBoundingRect:area inTextContainer:container];
    NSUInteger current = [buffer lineForOffset:std::min(editor.vimDisplayedCursor, editor.string.length)];
    NSFont *font = self.numberFont;
    NSDictionary *numberInk = @{NSFontAttributeName:font, NSForegroundColorAttributeName:SRGBColor(theme.lineNumber)};
    NSDictionary *activeInk = @{NSFontAttributeName:font, NSForegroundColorAttributeName:SRGBColor(theme.activeNumber)};
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGFloat scale = std::abs(CGContextGetCTM(context).d);

    void (^drawNumber)(NSUInteger, NSRect) = ^(NSUInteger line, NSRect fragment) {
        CGFloat textCenter = NSMidY(fragment) - editorLineSpacing / 2;
        CGFloat center = [self convertPoint:NSMakePoint(0, origin.y + textCenter) fromView:editor].y;
        CGFloat halfHeight = NSHeight(fragment) / 2;
        if (center + halfHeight < NSMinY(dirty) || center - halfHeight > NSMaxY(dirty))
            return;
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

@implementation WindowStatusBar {
    NSGradient *_gradient;
}

- (BOOL)isOpaque { return YES; }

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    _gradient = nil;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty
{
    if (!_gradient) {
        NSString *appearance = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[
            NSAppearanceNameAqua, NSAppearanceNameDarkAqua
        ]];
        BOOL dark = [appearance isEqualToString:NSAppearanceNameDarkAqua];
        _gradient = [[NSGradient alloc] initWithStartingColor:SRGBColor(dark ? rgb(54, 55, 58) : rgb(242, 242, 243))
                                                   endingColor:SRGBColor(dark ? rgb(41, 42, 45) : rgb(225, 225, 228))];
    }
    NSRect bounds = self.bounds;
    [_gradient drawInRect:bounds angle:-90];
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

static void SetRunButton(NSButton *button, BOOL running)
{
    NSString *title = running ? @"Stop" : @"Run";
    if (!button || [button.toolTip isEqualToString:title])
        return;
    NSImage *symbol = [NSImage imageWithSystemSymbolName:running ? @"stop.fill" : @"play.fill" accessibilityDescription:title];
    NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightRegular];
    button.image = [symbol imageWithSymbolConfiguration:size];
    button.contentTintColor = running ? nil : SRGBColor(rgb(46, 148, 69));
    button.accessibilityLabel = title;
    button.toolTip = title;
}

@interface SourceDocument (VimActions)
- (void)performVimAction:(Vim::Action)action argument:(NSString *)argument force:(BOOL)force;
@end

@interface SourceDocument (Output)
- (BOOL)hasUTF8BOM;
- (void)revealRunLocation:(const RunLocation &)location;
- (void)cancelRun;
- (NSUInteger)beginBuildDiagnostics;
- (void)applyBuildMessages:(const std::vector<RunMessage> &)messages version:(NSUInteger)version owner:(BOOL)owner;
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

@interface WindowOutput : NSObject
@property(nonatomic) OutputPane *pane;
@property(nonatomic, weak) EditorWindow *host;
@property(nonatomic, weak) SourceDocument *source;
@property(nonatomic) SourceRunner *runner;
@property(nonatomic) FolderWorkspace *runWorkspace;
@property(nonatomic) BOOL shown;
@property(nonatomic) BOOL returnFocus;
- (void)observeTabGroup:(NSWindowTabGroup *)group;
- (void)finishRun;
@end

@interface EditorWindow : NSView <NSTextViewDelegate>
- (instancetype)initWithDocument:(SourceDocument *)document text:(NSString *)text language:(Language)language;
@property(nonatomic, readonly) CodeView *editor;
@property(nonatomic, readonly) CodeView *activeEditor;
@property(nonatomic, readonly) BOOL outputShown;
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
- (void)setWindowOutput:(WindowOutput *)output attach:(BOOL)attach;
- (void)detachWindowOutput;
- (void)showOutput:(BOOL)show;
- (CodeView *)editorForOutput;
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
- (IBAction)toggleOutput:(id)sender;
- (BOOL)isRunSource;
- (void)stopRun;
- (void)revealRunLocation:(const RunLocation &)location;
@property(nonatomic, weak) NSButton *runButton;
@end

@implementation WindowOutput {
    __weak NSWindowTabGroup *_tabGroup;
}

- (void)observeTabGroup:(NSWindowTabGroup *)group
{
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
        [host.window makeFirstResponder:[host editorForOutput]];
    _runner = nil;
    if (_runWorkspace.runningDocument == _source)
        _runWorkspace.runningDocument = nil;
    BOOL running = _runWorkspace.runningDocument != nil;
    SetRunButton(host.runButton, running);
    host.runButton.enabled = running || host.canRun;
    _runWorkspace = nil;
}

- (void)dealloc
{
    [_tabGroup removeObserver:self forKeyPath:@"selectedWindow" context:&selectedOutputTabContext];
    [_runner stop];
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
    WindowStatusBar *_statusBar;
    NSTextField *_position;
    NSTextField *_encoding;
    NSPopUpButton *_language;
    NSButton *_indentationButton;
    DockTab *_outputTab;
    DockRail *_outputRail;
    DockDivider *_outputDivider;
    DockDropTarget *_dropTarget;
    WindowOutput *_windowOutput;
    __weak WindowOutput *_runningOutput;
    __weak CodeView *_outputSource;
    __weak NSView *_tabFocus;
    DockSide _dockSide;
    CGFloat _dockWidth;
    CGFloat _dockHeight;
    NSUInteger _laidOutLineCount;
    BOOL _scrollRepaintPending;
    BOOL _automaticLanguageMode;
    BOOL _detectLanguageFromContent;
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

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.borderType = NSNoBorder;
    _scroll.scrollerStyle = NSScrollerStyleLegacy;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.documentView = _editor;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [self addSubview:_scroll];

    _gutter = [[Gutter alloc] init];
    _gutter.editor = _editor;
    _gutter.buffer = _buffer;
    [self addSubview:_gutter];

    if (!parent) {
        _windowOutput = [[WindowOutput alloc] init];
        _windowOutput.host = self;
        _statusBar = [[WindowStatusBar alloc] init];
        [self addSubview:_statusBar];
        _position = StatusLabel(@"");
        _encoding = StatusLabel(@"UTF-8");
        _encoding.alignment = NSTextAlignmentCenter;
        [_statusBar addSubview:_position];
        [_statusBar addSubview:_encoding];
        _indentationButton = [NSButton buttonWithTitle:@"" target:self action:@selector(showIndentationMenu:)];
        _indentationButton.bordered = NO;
        _indentationButton.refusesFirstResponder = YES;
        _indentationButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        _indentationButton.toolTip = @"Indentation";
        [_statusBar addSubview:_indentationButton];
        _outputRail = [[DockRail alloc] init];
        _outputRail.clipsToBounds = YES;
        [self addSubview:_outputRail];
        _outputTab = [[DockTab alloc] initWithFrame:NSZeroRect];
        _outputTab.title = @"Output";
        _outputTab.target = self;
        _outputTab.action = @selector(toggleOutput:);
        [_outputTab setButtonType:NSButtonTypePushOnPushOff];
        _outputTab.bezelStyle = NSBezelStyleAccessoryBar;
        _outputTab.controlSize = NSControlSizeSmall;
        _outputTab.clipsToBounds = YES;
        __weak EditorWindow *view = self;
        _outputTab.track = ^(NSPoint point, BOOL finished) { [view dragOutputTab:point finished:finished]; };
        NSMenu *dockMenu = [[NSMenu alloc] initWithTitle:@"Output"];
        for (NSString *title in @[@"Dock Bottom", @"Dock Left", @"Dock Right", @"Dock Top"]) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(chooseOutputDock:) keyEquivalent:@""];
            item.target = self;
            item.tag = dockMenu.numberOfItems;
            [dockMenu addItem:item];
        }
        _outputTab.menu = dockMenu;
        [_outputRail addSubview:_outputTab];
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
        [_language selectItemWithTag:NSInteger(language)];
        _language.bordered = NO;
        _language.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        _language.target = self;
        _language.action = @selector(chooseLanguage:);
        _language.accessibilityLabel = @"Language";
        _language.toolTip = @"Language (Auto Detect)";
        [_statusBar addSubview:_language];
    }

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
    if (!parent)
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged:)
                                                   name:EditorPreferencesChanged object:nil];
    [self applyPreferences];
    self.needsLayout = YES;
    return self;
}

- (CodeView *)activeEditor
{
    return _splitView && self.window.firstResponder == _secondPane.editor ? _secondPane.editor : _editor;
}

- (BOOL)outputShown { return _windowOutput.shown; }
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
    if ([editor applyDocumentEdits:std::move(edits) undoName:@"Convert Indentation"])
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
    if (!(_windowOutput.host == self && _windowOutput.pane.hasKeyboardFocus) &&
        [focus isKindOfClass:NSView.class] && [(NSView *)focus isDescendantOf:self])
        _tabFocus = (NSView *)focus;
}

- (NSView *)tabFocus
{
    return _tabFocus && _tabFocus.window == self.window && !_tabFocus.hiddenOrHasHiddenAncestor ? _tabFocus : _editor;
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

- (void)moveOutputDock:(DockSide)side
{
    if (_dockSide != side) {
        _dockSide = side;
        [NSUserDefaults.standardUserDefaults setInteger:NSInteger(side) forKey:@"OutputDockEdge"];
        [self setNeedsLayout:YES];
        [self layoutSubtreeIfNeeded];
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
    if (side)
        _dropTarget.frame = LayoutDock(body, *side, YES, DockIsSide(*side) ? _dockWidth : _dockHeight).output;
}

- (void)resizeOutputBy:(CGFloat)delta finished:(BOOL)finished
{
    bool horizontal = DockIsSide(_dockSide);
    CGFloat &extent = horizontal ? _dockWidth : _dockHeight;
    NSRect body = [self editorBody];
    NSRect pane = [self dockFrames].output;
    CGFloat shown = horizontal ? NSWidth(pane) : NSHeight(pane);
    CGFloat sign = (_dockSide == DockSide::Top || _dockSide == DockSide::Right) ? -1 : 1;
    if (delta) {
        auto next = LayoutDock(body, _dockSide, YES, shown + sign * delta);
        extent = horizontal ? NSWidth(next.output) : NSHeight(next.output);
        [self setNeedsLayout:YES];
        [self layoutSubtreeIfNeeded];
    }
    if (finished)
        [NSUserDefaults.standardUserDefaults setDouble:extent forKey:horizontal ? @"OutputDockWidth" : @"OutputDockHeight"];
}

- (CodeView *)editorForOutput
{
    CodeView *editor = _outputSource;
    return editor && editor.window == self.window ? editor : self.activeEditor;
}

- (void)attachOutputPane
{
    OutputPane *pane = _windowOutput.pane;
    if (!pane && _windowOutput.shown) {
        pane = [[OutputPane alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(self.bounds), 160)];
        __weak WindowOutput *output = _windowOutput;
        pane.openLocation = ^(const RunLocation &location, SourceDocument *source) {
            [output.host openRunLocation:location source:source];
        };
        pane.sendInput = ^BOOL(NSString *line) {
            return [output.runner sendInput:line];
        };
        _windowOutput.pane = pane;
    }
    if (pane && pane.superview != self) {
        [pane removeFromSuperview];
        [self addSubview:pane positioned:NSWindowBelow relativeTo:_outputRail];
        [pane applyFont:_editor.editorFont rendering:_editor.rendering dark:_editor.theme->dark];
    }
    pane.hidden = !_windowOutput.shown;
    _outputTab.state = _windowOutput.shown ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setWindowOutput:(WindowOutput *)output attach:(BOOL)attach
{
    if (_windowOutput != output) {
        [self detachWindowOutput];
        _windowOutput = output;
        self.needsLayout = YES;
    }
    if (attach && output.host != self) {
        output.host = self;
        [self readDockPlacement];
        [self attachOutputPane];
        self.needsLayout = YES;
    }
}

- (void)detachWindowOutput
{
    if (_windowOutput.host == self) {
        _windowOutput.host = nil;
        [_windowOutput.pane removeFromSuperview];
    }
}

- (void)showOutput:(BOOL)show
{
    if (show == self.outputShown)
        return;
    CodeView *source = [self editorForOutput];
    NSUInteger offset = std::min(source.vimDisplayedCursor, source.string.length);
    NSRect caret = show ? [source vimCaretAt:offset] : NSZeroRect;
    BOOL keepCaretVisible = show && NSIntersectsRect(caret, source.visibleRect);
    if (!show && _windowOutput.pane.hasKeyboardFocus)
        [self.window makeFirstResponder:[self editorForOutput]];
    _windowOutput.shown = show;
    [self attachOutputPane];
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
    if (keepCaretVisible && !NSContainsRect(source.visibleRect, caret))
        [source scrollRangeToVisible:NSMakeRange(offset, 0)];
}

- (IBAction)toggleOutput:(id)sender
{
    (void)sender;
    if (!self.outputShown)
        _outputSource = self.activeEditor;
    [self showOutput:!self.outputShown];
    if (self.outputShown && self.running && [_windowOutput.pane focusInput])
        _windowOutput.returnFocus = YES;
}

- (void)openRunLocation:(const RunLocation &)location source:(SourceDocument *)source
{
    RunLocation target = location;
    if (source && source == _document) {
        [self revealRunLocation:target];
        return;
    }
    if (source.editorHostWindow && [NSDocumentController.sharedDocumentController.documents containsObject:source]) {
        [source showWindows];
        [source revealRunLocation:target];
        return;
    }
    if (target.file) {
        __weak SourceDocument *document = _document;
        OpenRelatedFile(target.file, self.window, ^(NSDocument *opened, BOOL, NSError *error) {
            if ([opened isKindOfClass:SourceDocument.class])
                [(SourceDocument *)opened revealRunLocation:target];
            else if (error)
                [document presentError:error];
        });
    }
}

- (void)revealRunLocation:(const RunLocation &)location
{
    [_buffer finishHighlighting];
    NSRange line = SourceLine(_buffer, location.line);
    if (line.location == NSNotFound)
        return;
    NSUInteger offset = SourceColumn(_buffer.storage.string, line, location.column, location.byteColumns,
                                     _document.hasUTF8BOM);
    [[self editorForOutput] visitVimFileMark:offset exact:YES];
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

- (BOOL)hasBuildErrors { return !_buffer.buildErrors.empty(); }
- (BOOL)hasMarkedEditorText { return _editor.hasMarkedText || _secondPane.editor.hasMarkedText; }

- (void)finishEditingForClose
{
    if (_editor.hasMarkedText)
        [_editor unmarkText];
    [_editor finishVimChange];
    [_editor breakUndoCoalescing];
    [_secondPane finishEditingForClose];
}

- (void)applyBuildMessages:(const std::vector<RunMessage> &)messages version:(NSUInteger)version owner:(BOOL)owner
{
    if (version != _buffer.textVersion)
        return;
    NSURL *file = CanonicalFileURL(_document.fileURL);
    std::vector<BuildError> errors;
    BOOL hasBOM = _document.hasUTF8BOM;
    for (const auto &message : messages) {
        if (message.tone != OutputTone::Error ||
            !((owner && message.location.currentSource) || [file.path isEqualToString:message.location.file.path]))
            continue;
        NSRange range = BuildErrorRange(_buffer, message.location, hasBOM);
        if (range.location != NSNotFound)
            errors.push_back({range, message.diagnostic});
    }
    [_buffer addBuildErrors:errors];
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
            (root.window.firstResponder == [root editorForOutput] || root.window.firstResponder == startingFocus))
            console.returnFocus = [console.pane focusInput];
    };
    [runner startProject:project language:language file:file name:name ? name : @"Untitled" workingText:text
                  output:^(const std::vector<RunMessage> &messages) {
        [windowOutput.pane appendMessages:messages source:source];
        if (std::ranges::any_of(messages, [](const RunMessage &message) {
            return message.tone == OutputTone::Error && message.location.line;
        })) {
            for (const auto &target : targets)
                [target.document applyBuildMessages:messages version:target.version owner:target.owner];
        }
    } finished:^{
        [windowOutput finishRun];
    }];
}

- (IBAction)runSource:(id)sender
{
    (void)sender;
    WindowOutput *output = _windowOutput;
    if (output.runner) {
        [output.runner stop];
        return;
    }
    FolderWorkspace *workspace = _document.workspace;
    SourceDocument *running = workspace.runningDocument;
    if (running) {
        [running cancelRun];
        return;
    }
    if (self.isRunSource) {
        [self stopRun];
        return;
    }
    if (!self.canRun)
        return;
    if (!output.pane.hasKeyboardFocus)
        _outputSource = self.activeEditor;
    [self showOutput:YES];
    [output.pane prepareForRun];

    NSURL *file = CanonicalFileURL(_document.fileURL);
    Language language = _buffer.language;
    NSURL *folder = file || !_buffer.storage.length ? workspace.folder : nil;
    RunProject project = LocateRunProject(language, file, folder);
    NSArray<SourceDocument *> *documents = [self documentsForBuild:project];
    SourceRunner *runner = [[SourceRunner alloc] init];
    output.source = _document;
    output.runner = runner;
    output.runWorkspace = workspace;
    output.returnFocus = NO;
    _runningOutput = output;
    workspace.runningDocument = _document;
    SetRunButton(self.runButton, YES);

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
}

- (void)splitResized:(NSNotification *)notification
{
    (void)notification;
    [self layoutPane];
    [_secondPane setNeedsLayout:YES];
}

- (void)installSplitVertical:(BOOL)vertical
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
        _splitView.vertical = vertical;
        [_splitView addArrangedSubview:_paneContent];
        [_splitView addArrangedSubview:_secondPane];
        [self addSubview:_splitView];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(splitResized:)
                      name:NSSplitViewDidResizeSubviewsNotification object:_splitView];
    } else {
        _splitView.vertical = vertical;
    }
    [_secondPane applyPreferences];
    [_splitView adjustSubviews];
    CGFloat extent = vertical ? NSWidth(_splitView.bounds) : NSHeight(_splitView.bounds);
    [_splitView setPosition:extent / 2 ofDividerAtIndex:0];
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
}

- (void)showSplitRight:(BOOL)vertical from:(EditorWindow *)pane
{
    [self installSplitVertical:vertical];
    EditorWindow *target = pane == self ? _secondPane : self;
    [target.editor visitVimFileMark:pane.editor.vimCursor exact:YES];
    [self updateEditorStatus];
}

- (void)closeSplitFrom:(EditorWindow *)pane
{
    NSUInteger cursor = pane == self ? _secondPane.editor.vimCursor : _editor.vimCursor;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSSplitViewDidResizeSubviewsNotification
                                               object:_splitView];
    [_secondPane removeFromSuperview];
    [_scroll removeFromSuperview];
    [_gutter removeFromSuperview];
    [_paneContent removeFromSuperview];
    [_splitView removeFromSuperview];
    _splitView = nil;
    _paneContent = nil;
    [self addSubview:_scroll positioned:NSWindowBelow relativeTo:_statusBar];
    [self addSubview:_gutter positioned:NSWindowBelow relativeTo:_statusBar];
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
    [_editor visitVimFileMark:cursor exact:YES];
    [self updateEditorStatus];
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
                bool toward = self == root ? key == 'l' || key == 'j' : key == 'h' || key == 'k';
                if ((along && toward) || key == 'w' || key == 'W' || key == 'p')
                    [root.window makeFirstResponder:target];
                [root updateEditorStatus];
            }
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
    }
}

- (void)keyWindowChanged:(NSNotification *)notification
{
    (void)notification;
    [_editor invalidateVimCaret];
    [_editor updateInsertionPointStateAndRestartTimer:YES];
    if (!self.window.isKeyWindow)
        [_editor dismissCompletion];
    else if (_outputRail) {
        [self readDockPlacement];
        [self setNeedsLayout:YES];
    }
    [_statusBar setNeedsDisplay:YES];
    [_outputRail setNeedsDisplay:YES];
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    NSRect content = [self editorArea];
    if (!_splitParent) {
        auto dock = [self dockFrames];
        CGFloat chromeHeight = statusHeight + (_dockSide == DockSide::Bottom ? NSHeight(dock.rail) : 0);
        _statusBar.frame = NSMakeRect(0, 0, width, chromeHeight);
        if (_outputRail.side != _dockSide) {
            _outputRail.side = _dockSide;
            [_outputRail setNeedsDisplay:YES];
        }
        _outputRail.frame = dock.rail;
        NSRect tab = NSOffsetRect(dock.tab, -NSMinX(dock.rail), -NSMinY(dock.rail));
        _outputTab.frameRotation = 0;
        if (DockIsSide(_dockSide)) {
            _outputTab.frame = NSMakeRect(NSMaxX(tab), NSMinY(tab), NSHeight(tab), NSWidth(tab));
            _outputTab.frameRotation = 90;
        } else {
            _outputTab.frame = tab;
        }
        _outputDivider.hidden = NSIsEmptyRect(dock.divider);
        _outputDivider.vertical = DockIsSide(_dockSide);
        _outputDivider.frame = dock.divider;
        if (_windowOutput.host == self && self.outputShown)
            _windowOutput.pane.frame = dock.output;
    }
    if (_splitView) {
        if (!NSEqualRects(_splitView.frame, content)) {
            _splitView.frame = content;
            [_splitView adjustSubviews];
        }
    }
    CGFloat languageWidth = _language ?
        std::clamp(std::ceil([_language.titleOfSelectedItem sizeWithAttributes:@{NSFontAttributeName:_language.font}].width) + 30,
                   97.0, 166.0) : 97;
    CGFloat languageLeft = width - 59 - languageWidth;
    _position.frame = NSMakeRect(9, 2, std::max(0.0, languageLeft - 95), 15);
    _indentationButton.frame = NSMakeRect(languageLeft - 83, 1, 80, 20);
    _encoding.frame = NSMakeRect(width - 57, 4, 50, 14);
    _language.frame = NSMakeRect(languageLeft, 1, languageWidth, 20);
    [self layoutPane];
}

- (NSRect)editorBody
{
    return NSMakeRect(0, statusHeight, NSWidth(self.bounds),
                      std::max<CGFloat>(0, NSHeight(self.bounds) - statusHeight));
}

- (DockFrames)dockFrames
{
    return LayoutDock([self editorBody], _dockSide, self.outputShown, DockIsSide(_dockSide) ? _dockWidth : _dockHeight);
}

- (NSRect)editorArea
{
    if (_splitParent)
        return self.bounds;
    return [self dockFrames].editor;
}

- (void)layoutPane
{
    NSRect area = _paneContent ? _paneContent.bounds : [self editorArea];
    CGFloat x = NSMinX(area), width = NSWidth(area), height = NSHeight(area);
    NSUInteger lineCount = std::max(NSUInteger(1), _buffer.lineCount);
    CGFloat digits = std::floor(std::log10(double(lineCount))) + 1;
    CGFloat digitWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName:_gutter.numberFont}].width;
    CGFloat gutterWidth = std::min(std::max(42.0, std::ceil(digits * digitWidth + 2 * gutterInset)),
                                  std::floor(width / 3));
    _scroll.frame = NSMakeRect(x + gutterWidth, NSMinY(area), width - gutterWidth, height);
    _gutter.frame = NSMakeRect(x, NSMinY(area), gutterWidth, height);

    // Refit after edits and clip changes so AppKit can clamp both scroll axes.
    [_editor sizeToFit];
    [self updateCursor];
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
                                    @"languageAutomatic":@(self.automaticLanguageMode),
                                    @"output":@(self.outputShown)} mutableCopy];
    if (_buffer.hasFileIndentation)
        state[@"indentation"] = EncodeIndentation(_buffer.indentation);
    if (_splitView) {
        BOOL vertical = _splitView.isVertical;
        CGFloat first = vertical ? NSWidth(_paneContent.frame) : NSHeight(_paneContent.frame);
        CGFloat extent = vertical ? NSWidth(_splitView.bounds) : NSHeight(_splitView.bounds);
        NSResponder *focus = self.window.firstResponder;
        BOOL second = focus == _secondPane.editor || (focus != _editor && _tabFocus == _secondPane.editor);
        state[@"split"] = @{@"vertical":@(vertical), @"fraction":@(extent > 0 ? first / extent : 0.5),
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
        [self installSplitVertical:vertical];
        NSNumber *ratio = SessionNumber(split[@"fraction"]);
        CGFloat fraction = ratio ? ratio.doubleValue : 0.5;
        if (std::isfinite(fraction)) {
            CGFloat extent = vertical ? NSWidth(_splitView.bounds) : NSHeight(_splitView.bounds);
            [_splitView setPosition:extent * std::clamp(fraction, 0.0, 1.0) ofDividerAtIndex:0];
        }
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
    [_editor dismissCompletion];
    if (_scrollRepaintPending)
        return;
    _scrollRepaintPending = YES;
    __weak EditorWindow *view = self;
    // Repaint at the latest clip origin after AppKit finishes each scroll update.
    [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes] block:^{
        EditorWindow *root = view;
        if (root) {
            root->_scrollRepaintPending = NO;
            [root->_editor refreshBuildErrorToolTips];
            [root->_editor setNeedsDisplayInRect:root->_scroll.documentVisibleRect];
            [root->_gutter setNeedsDisplay:YES];
        }
    }];
}

- (void)scrollTracking:(NSNotification *)notification
{
    (void)notification;
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

- (void)applyLanguage:(Language)language
{
    [_language selectItemWithTag:NSInteger(language)];
    _language.toolTip = _automaticLanguageMode ? @"Language (Auto Detect)" : @"Language";
    BOOL changed = _buffer.language != language;
    if (changed)
        _buffer.language = language;
    self.runButton.enabled = self.canRun || self.running || _document.workspace.runningDocument != nil;
    if (!changed)
        return;
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
    if (_indentationButton) {
        Indentation indentation = _buffer.indentation;
        _indentationButton.title = [NSString stringWithFormat:indentation.tabs ? @"Tabs: %lu" : @"Spaces: %lu",
            (unsigned long)(indentation.tabs ? indentation.tabWidth : indentation.width)];
        _indentationButton.toolTip = _buffer.hasFileIndentation && _document.fileURL ?
            @"Indentation saved for this file." : @"Indentation for this file.";
    }
    _scroll.appearance = [NSAppearance appearanceNamed:_editor.theme->dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    _scroll.backgroundColor = RenderedEditorColor(_editor.theme->paper, _editor.rendering);
    if (_windowOutput.host == self)
        [_windowOutput.pane applyFont:_editor.editorFont rendering:_editor.rendering dark:_editor.theme->dark];

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
    CodeView *editor = self.activeEditor;
    NSUInteger caret = std::min(editor.vimDisplayedCursor, editor.string.length);
    NSUInteger line = [_buffer lineForOffset:caret];
    NSUInteger start = [_buffer offsetForLine:line];
    NSString *position = [NSString stringWithFormat:@"Line %lu, Col %lu",
                          (unsigned long)line + 1, (unsigned long)(caret - start + 1)];
    if (editor.cursorCount > 1)
        position = [NSString stringWithFormat:@"%@     %lu cursors", position, (unsigned long)editor.cursorCount];
    NSError *saveError = _document.autoSaveError;
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
- (SourceWindowController *)projectWindowController;
- (void)setProjectWindowController:(SourceWindowController *)controller;
- (void)installEditor:(SourceWindowController *)controller;
- (void)requestTabClose;
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

@interface SourceWindowController : NSWindowController <NSSplitViewDelegate>
@property(nonatomic, readonly) NSButton *runButton;
@property(nonatomic, readonly) FolderWorkspace *workspace;
@property(nonatomic, readonly) BOOL windowClosed;
@property(nonatomic, readonly) NSUInteger projectTabCount;
@property(nonatomic, readonly) BOOL projectTabBarShown;
- (instancetype)initWithSourceWindow:(SourceWindow *)window;
- (NSView *)commandPaletteHost;
- (void)installEditorView:(EditorWindow *)editor;
- (WindowOutput *)windowOutput;
- (void)syncWindowOutput;
- (void)restoreOutputShown:(BOOL)shown;
- (void)updateWorkspace;
- (void)restoreWorkspace:(FolderWorkspace *)workspace tabs:(NSArray<SourceDocument *> *)tabs selected:(SourceDocument *)selected;
- (NSArray<SourceDocument *> *)projectTabs;
- (void)revealCurrentFile;
- (void)showFolderSearchReplacing:(BOOL)replace;
- (void)addProjectDocument:(SourceDocument *)document;
- (BOOL)replaceProjectDocument:(SourceDocument *)document withDocument:(SourceDocument *)replacement;
- (void)removeProjectDocument:(SourceDocument *)document;
- (void)closeProjectDocument:(SourceDocument *)document;
- (BOOL)selectProjectDocument:(SourceDocument *)document;
- (void)selectProjectTabAtIndex:(NSUInteger)index;
- (void)requestCloseProjectDocument:(SourceDocument *)document;
- (void)requestCloseEditorWindow;
- (void)cycleProjectTabs:(NSInteger)direction;
- (void)toggleProjectTabBar;
- (void)detachProjectTab;
- (void)mergeProjectWindows;
- (IBAction)toggleWorkspaceSidebar:(id)sender;
@end

static void SyncNativeTabOutput(NSWindow *window)
{
    NSWindowController *controller = window.windowController;
    if ([controller isKindOfClass:SourceWindowController.class])
        [(SourceWindowController *)controller syncWindowOutput];
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
    if (controller.workspace)
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
    return WorkspaceForEditorWindow(window) ? controller.projectTabBarShown : window.tabGroup.isTabBarVisible;
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

@interface SourceWindow : NSWindow
@property(nonatomic, weak) WindowHeader *header;
- (void)hideNativeTabBar;
- (IBAction)closeEditorWindow:(id)sender;
@end

@implementation SourceWindow

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
    if (AutoSavePreference().mode != AutoSaveMode::OnFocusChange || ![self.firstResponder isKindOfClass:CodeView.class])
        return [super makeFirstResponder:responder];
    SourceDocument *document = self.sourceController.document;
    BOOL changed = [super makeFirstResponder:responder];
    if (changed && ![self.firstResponder isKindOfClass:CodeView.class])
        [document requestAutoSave:AutoSaveMode::OnFocusChange];
    return changed;
}

- (void)performClose:(id)sender
{
    (void)sender;
    SourceWindowController *controller = self.sourceController;
    SourceDocument *document = controller.document;
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
    if (self.sourceController.workspace)
        [self.sourceController cycleProjectTabs:1];
    else
        [super selectNextTab:sender];
}

- (IBAction)selectPreviousTab:(id)sender
{
    if (self.sourceController.workspace)
        [self.sourceController cycleProjectTabs:-1];
    else
        [super selectPreviousTab:sender];
}

- (IBAction)toggleTabBar:(id)sender
{
    if (self.sourceController.workspace)
        [self.sourceController toggleProjectTabBar];
    else
        [super toggleTabBar:sender];
}

- (IBAction)moveTabToNewWindow:(id)sender
{
    if (self.sourceController.workspace)
        [self.sourceController detachProjectTab];
    else
        [super moveTabToNewWindow:sender];
}

- (IBAction)mergeAllWindows:(id)sender
{
    if (self.sourceController.workspace)
        [self.sourceController mergeProjectWindows];
    else
        [super mergeAllWindows:sender];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSEventModifierFlags mask = NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                NSEventModifierFlagControl | NSEventModifierFlagShift;
    NSEventModifierFlags modifiers = event.modifierFlags & mask;
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length == 1 ? [characters characterAtIndex:0] : 0;
    SourceWindowController *controller = self.sourceController;
    if (modifiers == NSEventModifierFlagCommand && key >= '1' && key <= '9' && !self.attachedSheet) {
        NSUInteger index = key - '1';
        if (controller.workspace) {
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

- (IBAction)toggleExplorer:(id)sender
{
    [self.sourceController toggleWorkspaceSidebar:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SourceWindowController *controller = self.sourceController;
    FolderWorkspace *workspace = controller.workspace;
    SEL action = item.action;
    if (action == @selector(toggleExplorer:)) {
        item.title = workspace.sidebarShown ? @"Hide Sidebar" : @"Show Sidebar";
        return workspace != nil;
    }
    if (workspace) {
        if (action == @selector(toggleTabBar:)) {
            item.title = controller.projectTabBarShown ? @"Hide Tab Bar" : @"Show Tab Bar";
            return controller.projectTabCount == 1;
        }
        if (action == @selector(selectNextTab:) || action == @selector(selectPreviousTab:) ||
            action == @selector(moveTabToNewWindow:))
            return controller.projectTabCount > 1 && !self.attachedSheet;
        if (action == @selector(mergeAllWindows:)) {
            for (SourceDocument *document in workspace.documents) {
                if (document.projectWindowController && document.projectWindowController != controller)
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

@interface WorkspaceEditorPane : NSView
- (void)setThemePreview:(const ThemeRef &)palette;
@end

@implementation WorkspaceEditorPane {
    ThemeRef _themePreview;
}

- (BOOL)isOpaque { return YES; }

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
    FolderWorkspace *_workspace;
    FolderSidebar *_sidebar;
    NSSplitView *_editorSplit;
    NSView *_editorPane;
    ProjectTabBar *_projectTabs;
    std::vector<__weak SourceDocument *> _projectDocuments;
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
    NSView *runContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(runFrame) + 4, NSHeight(runFrame))];
    _runButton = [[NSButton alloc] initWithFrame:runFrame];
    _runButton.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    [_runButton setButtonType:NSButtonTypeMomentaryPushIn];
    _runButton.bordered = NO;
    _runButton.imagePosition = NSImageOnly;
    _runButton.action = @selector(runDocument:);
    SetRunButton(_runButton, NO);
    [runContainer addSubview:_runButton];

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

    _editorSplit = [[ExplorerSplitView alloc] initWithFrame:
        [content convertRect:window.contentLayoutRect fromView:nil]];
    _editorSplit.vertical = YES;
    _editorSplit.dividerStyle = NSSplitViewDividerStyleThin;
    _editorSplit.delegate = self;
    _editorPane = [[WorkspaceEditorPane alloc] initWithFrame:_editorSplit.bounds];
    _editorPane.clipsToBounds = YES;
    [_editorSplit addArrangedSubview:_editorPane];
    _editorSplit.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_editorSplit];
    [NSLayoutConstraint activateConstraints:@[
        [_editorSplit.leadingAnchor constraintEqualToAnchor:layout.leadingAnchor],
        [_editorSplit.trailingAnchor constraintEqualToAnchor:layout.trailingAnchor],
        [_editorSplit.topAnchor constraintEqualToAnchor:layout.topAnchor],
        [_editorSplit.bottomAnchor constraintEqualToAnchor:layout.bottomAnchor]
    ]];
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
    [EmptyProjectWindows() removeObject:self];
}

- (void)editorPreferencesChanged:(NSNotification *)notification
{
    (void)notification;
    if (!_installedEditor)
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
    if (_workspace) {
        for (SourceDocument *document : _projectDocuments)
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
    if (_workspace) {
        for (SourceDocument *document : _projectDocuments)
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
        [_installedEditor detachWindowOutput];
        [_installedEditor removeFromSuperview];
        [_editorPane addSubview:editor];
    }
    editor.translatesAutoresizingMaskIntoConstraints = YES;
    editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.initialFirstResponder = editor.tabFocus;
    _installedEditor = editor;
    [self updateWorkspace];
}

- (WindowOutput *)windowOutput
{
    // AppKit gives each native tab its own NSWindow, with one tab group for the window on screen.
    NSWindowTabGroup *group = _workspace ? nil : self.window.tabGroup;
    if (!group) {
        if (!_windowOutput)
            _windowOutput = [[WindowOutput alloc] init];
        return _windowOutput;
    }
    WindowOutput *output = objc_getAssociatedObject(group, &windowOutputKey);
    if (!output) {
        output = _windowOutput ? _windowOutput : [[WindowOutput alloc] init];
        objc_setAssociatedObject(group, &windowOutputKey, output, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [output observeTabGroup:group];
        _windowOutput = nil;
    }
    return output;
}

- (void)syncWindowOutput
{
    NSWindow *selected = _workspace ? nil : self.window.tabGroup.selectedWindow;
    [_installedEditor setWindowOutput:self.windowOutput attach:!selected || selected == self.window];
    [self workspaceRunChanged:nil];
}

- (void)restoreOutputShown:(BOOL)shown
{
    [self syncWindowOutput];
    if (_installedEditor)
        [_installedEditor showOutput:shown];
    else
        self.windowOutput.shown = shown;
}

- (NSView *)commandPaletteHost
{
    return _installedEditor ? _installedEditor : _editorPane;
}

- (NSUInteger)projectTabCount { return _projectDocuments.size(); }

- (NSArray<SourceDocument *> *)projectTabs
{
    NSMutableArray<SourceDocument *> *tabs = [NSMutableArray arrayWithCapacity:_projectDocuments.size()];
    for (SourceDocument *document : _projectDocuments) {
        if (document)
            [tabs addObject:document];
    }
    return tabs;
}

- (BOOL)projectTabBarShown
{
    return self.projectTabCount > 1 || (self.projectTabCount && !_hideSingleProjectTab);
}

- (NSUInteger)projectIndexOf:(SourceDocument *)document
{
    for (NSUInteger i = 0; i < _projectDocuments.size(); ++i) {
        if (_projectDocuments[i] == document)
            return i;
    }
    return NSNotFound;
}

- (void)layoutEditorPane
{
    NSRect body = _editorPane.bounds;
    CGFloat height = self.projectTabBarShown ? std::min(projectTabBarHeight, NSHeight(body)) : 0;
    _projectTabs.hidden = height == 0;
    _projectTabs.frame = NSMakeRect(0, NSMaxY(body) - height, NSWidth(body), height);
    body.size.height -= height;
    _installedEditor.frame = body;
}

- (void)refreshProjectTabs
{
    if (!_projectTabs) {
        [self layoutEditorPane];
        return;
    }
    [_projectTabs showDocuments:self.projectTabs selected:self.document];
    [self layoutEditorPane];
}

- (void)projectDocumentsChanged:(NSNotification *)notification
{
    (void)notification;
    [self refreshProjectTabs];
}

- (void)addProjectDocument:(SourceDocument *)document
{
    if ([self projectIndexOf:document] == NSNotFound) {
        _projectDocuments.push_back(document);
        [document setProjectWindowController:self];
    }
    [self refreshProjectTabs];
}

- (BOOL)selectProjectDocument:(SourceDocument *)document
{
    if (self.document == document)
        return YES;
    if (self.window.attachedSheet || [self projectIndexOf:document] == NSNotFound)
        return NO;
    [self activateProjectDocument:document];
    return YES;
}

- (void)selectProjectTabAtIndex:(NSUInteger)index
{
    if (index < _projectDocuments.size()) {
        if (SourceDocument *document = _projectDocuments[index])
            [self selectProjectDocument:document];
    }
}

- (void)activateProjectDocument:(SourceDocument *)document
{
    [_installedEditor rememberTabFocus];
    [(SourceDocument *)self.document requestAutoSave:AutoSaveMode::OnFocusChange];
    [self.window makeFirstResponder:nil];
    [document addWindowController:self];
    [EmptyProjectWindows() removeObject:self];
    [document installEditor:self];
    [self synchronizeWindowTitleWithDocumentName];
    self.window.documentEdited = document.isDocumentEdited;
    [self.window makeFirstResponder:_installedEditor.tabFocus];
    _workspace.selectedDocument = document;
}

- (BOOL)replaceProjectDocument:(SourceDocument *)document withDocument:(SourceDocument *)replacement
{
    NSUInteger index = [self projectIndexOf:document];
    if (index == NSNotFound || self.window.attachedSheet)
        return NO;
    _projectDocuments[index] = replacement;
    [document setProjectWindowController:nil];
    [replacement setProjectWindowController:self];
    return [self selectProjectDocument:replacement];
}

- (void)removeProjectDocument:(SourceDocument *)document
{
    NSUInteger index = [self projectIndexOf:document];
    if (index == NSNotFound)
        return;
    _projectDocuments.erase(_projectDocuments.begin() + index);
    [document setProjectWindowController:nil];
    if (self.document == document && !_projectDocuments.empty()) {
        SourceDocument *next = _projectDocuments[std::min(index, _projectDocuments.size() - 1)];
        [self activateProjectDocument:next];
    }
    [self refreshProjectTabs];
}

- (void)closeProjectDocument:(SourceDocument *)document
{
    if (!_windowClosed && self.document == document && self.projectTabCount == 1) {
        // An empty project window has no document to retain its controller.
        [EmptyProjectWindows() addObject:self];
        [document removeWindowController:self];
        [self.window makeFirstResponder:nil];
        self.window.initialFirstResponder = nil;
        _installedEditor.runButton = nil;
        [_installedEditor detachWindowOutput];
        [_installedEditor removeFromSuperview];
        _installedEditor = nil;
        [self showEmptyProject];
    }
    [self removeProjectDocument:document];
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
    if (self.window.attachedSheet || [self projectIndexOf:document] == NSNotFound)
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
        if (self->_workspace) {
            // Close the host with its active document instead of keeping an empty project window.
            self->_projectDocuments.clear();
            for (SourceDocument *document in documents)
                [document setProjectWindowController:nil];
        }
        for (SourceDocument *document in documents)
            [document close];
        if (!documents.count)
            [self.window close];
    });
}

- (void)cycleProjectTabs:(NSInteger)direction
{
    NSUInteger current = [self projectIndexOf:self.document], count = _projectDocuments.size();
    if (current == NSNotFound || count < 2)
        return;
    NSUInteger next = (current + (direction < 0 ? count - 1 : 1)) % count;
    [self selectProjectTabAtIndex:next];
}

- (void)toggleProjectTabBar
{
    if (self.projectTabCount != 1)
        return;
    _hideSingleProjectTab = !_hideSingleProjectTab;
    [self layoutEditorPane];
}

- (void)moveProjectDocument:(SourceDocument *)document toIndex:(NSUInteger)index
{
    NSUInteger previous = [self projectIndexOf:document];
    if (previous == NSNotFound || index >= _projectDocuments.size() || previous == index)
        return;
    _projectDocuments.erase(_projectDocuments.begin() + previous);
    _projectDocuments.insert(_projectDocuments.begin() + index, document);
    [self refreshProjectTabs];
}

- (void)detachProjectTab
{
    if (self.projectTabCount < 2 || self.window.attachedSheet)
        return;
    SourceDocument *document = self.document;
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
    SourceDocument *selected = self.document;
    for (SourceDocument *document in _workspace.documents) {
        if (document.projectWindowController && document.projectWindowController != self &&
            [document joinTabsInWindow:self.window] && !selected)
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
    SourceDocument *document = self.document;
    if (workspace != _workspace) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        if (_workspace) {
            [center removeObserver:self name:FolderSidebarChanged object:_workspace];
            [center removeObserver:self name:FolderDocumentsChanged object:_workspace];
            [center removeObserver:self name:FolderRunChanged object:_workspace];
        }
        [_sidebar removeFromSuperview];
        _sidebar = nil;
        [_projectTabs removeFromSuperview];
        _projectTabs = nil;
        for (SourceDocument *open : _projectDocuments)
            [open setProjectWindowController:nil];
        _projectDocuments.clear();
        _hideSingleProjectTab = NO;
        _workspace = workspace;
        NSArray *accessories = self.window.titlebarAccessoryViewControllers;
        NSUInteger index = [accessories indexOfObjectIdenticalTo:_sidebarAccessory];
        if (_workspace) {
            [center addObserver:self selector:@selector(workspaceSidebarChanged:)
                           name:FolderSidebarChanged object:_workspace];
            [center addObserver:self selector:@selector(projectDocumentsChanged:)
                           name:FolderDocumentsChanged object:_workspace];
            [center addObserver:self selector:@selector(workspaceRunChanged:)
                           name:FolderRunChanged object:_workspace];
            _projectTabs = [[ProjectTabBar alloc] initWithFrame:NSZeroRect];
            _projectTabs.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
            [_editorPane addSubview:_projectTabs];
            __weak SourceWindowController *controller = self;
            _projectTabs.selectDocument = ^(SourceDocument *selected) { [controller selectProjectDocument:selected]; };
            _projectTabs.closeDocument = ^(SourceDocument *selected) { [controller requestCloseProjectDocument:selected]; };
            _projectTabs.moveDocument = ^(SourceDocument *moved, NSUInteger index) {
                [controller moveProjectDocument:moved toIndex:index];
            };
            if (document)
                [self addProjectDocument:document];
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
    BOOL running = _workspace.runningDocument != nil || _installedEditor.running;
    _runButton.enabled = _installedEditor && (running || _installedEditor.canRun);
    SetRunButton(_runButton, running);
}

- (void)updateExplorerLayout
{
    _layingOutExplorer = YES;
    if (_workspace.sidebarShown) {
        if (!_sidebar) {
            _sidebar = [[FolderSidebar alloc] initWithWorkspace:_workspace];
            __weak SourceWindowController *controller = self;
            _sidebar.explorer.openFile = ^(NSURL *url) {
                if (NSWindow *window = controller.window) {
                    OpenRelatedFile(url, window, ^(NSDocument *, BOOL, NSError *error) {
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
        _sidebarButton.toolTip = @"Hide Sidebar";
    } else {
        NSResponder *focus = self.window.firstResponder;
        if (_sidebar && [focus isKindOfClass:NSView.class] && [(NSView *)focus isDescendantOf:_sidebar])
            [self.window makeFirstResponder:_installedEditor.activeEditor];
        [_sidebar removeFromSuperview];
        _sidebarButton.toolTip = @"Show Sidebar";
    }
    _sidebarButton.accessibilityLabel = _sidebarButton.toolTip;
    [_editorSplit adjustSubviews];
    if (_sidebar.superview && NSWidth(_editorSplit.bounds) >= 140) {
        CGFloat width = std::clamp(_workspace.sidebarWidth, 140.0, [self maximumExplorerWidth]);
        [_editorSplit setPosition:width ofDividerAtIndex:0];
    }
    _layingOutExplorer = NO;
}

- (void)showFolderSearchReplacing:(BOOL)replace
{
    CodeView *editor = _installedEditor.activeEditor;
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
    OpenRelatedFile(currentFile, self.window, ^(NSDocument *opened, BOOL, NSError *error) {
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
    return std::clamp(NSWidth(_editorSplit.bounds) - 280, 140.0, 420.0);
}

- (void)splitView:(NSSplitView *)split resizeSubviewsWithOldSize:(NSSize)oldSize
{
    (void)oldSize;
    NSRect body = split.bounds;
    if (_sidebar.superview == split) {
        CGFloat width = std::min(NSWidth(body), std::clamp(_workspace.sidebarWidth, 140.0, [self maximumExplorerWidth]));
        _sidebar.frame = NSMakeRect(0, 0, width, NSHeight(body));
        CGFloat start = std::min(NSWidth(body), width + split.dividerThickness);
        body.origin.x = start;
        body.size.width -= start;
    }
    _editorPane.frame = body;
    [self layoutEditorPane];
}

- (CGFloat)splitView:(NSSplitView *)split constrainMinCoordinate:(CGFloat)minimum ofSubviewAt:(NSInteger)index
{
    (void)split;
    (void)index;
    return std::max(minimum, 140.0);
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
    [self layoutEditorPane];
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
    __weak SourceWindowController *_projectWindowController;
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

- (NSDictionary *)sessionState
{
    return [self sessionStateDiscardingChanges:NO];
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
    window.initialFirstResponder = _editorWindow.tabFocus;
    _pendingSessionView = nil;
}

- (void)markSessionDraftEdited
{
    [super updateChangeCount:NSChangeDone];
    [_workspace documentChanged];
}

- (NSData *)dataForSourceText:(NSString *)text error:(NSError **)error
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data && error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil];
    if (_hasBOM && data) {
        uint8_t bom[] = {0xEF, 0xBB, 0xBF};
        NSMutableData *withBOM = [NSMutableData dataWithBytes:bom length:sizeof(bom)];
        [withBOM appendData:data];
        return withBOM;
    }
    return data;
}

- (NSData *)dataOfType:(NSString *)type error:(NSError **)error
{
    (void)type;
    return [self dataForSourceText:_textBeingSaved ? _textBeingSaved : self.sourceText error:error];
}

- (BOOL)applyFolderSearchEdits:(Vim::EditBatch)batch error:(NSError **)error
{
    NSURL *file = self.fileURL;
    NSString *failure = nil;
    if (_closing || _fileSavesInProgress || _reviewingClose || _editorWindow.hasMarkedEditorText) {
        failure = @"The document is busy.";
    } else if (self.isLocked) {
        failure = @"The file is locked.";
    } else if (_editorWindow) {
        if (_editorWindow.activeEditor.editable &&
            [_editorWindow.activeEditor applyDocumentEdits:std::move(batch) undoName:@"Replace in Files"])
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
        [_editorWindow.activeEditor applyDocumentEdits:std::move(batch) undoName:@"Save Cleanup"];
    else
        _initialText = TextByApplyingEdits(self.sourceText, batch);
}

- (BOOL)isUnusedUntitled
{
    NSWindow *window = self.editorHostWindow;
    if (self.fileURL || self.isDocumentEdited || _isExample || !window || _editorWindow.isRunSource ||
        window.attachedSheet || _editorWindow.editor.string.length ||
        _editorWindow.activeEditor.hasMarkedText)
        return NO;

    return !self.undoManager.canUndo && !self.undoManager.canRedo;
}

- (NSWindow *)editorHostWindow
{
    SourceWindowController *project = _projectWindowController;
    return project ? project.window : self.windowControllers.firstObject.window;
}

- (NSWindow *)windowForSheet
{
    if (_reviewingClose)
        return nil;
    NSWindow *window = [super windowForSheet];
    return window ? window : _projectWindowController.window;
}

- (SourceWindowController *)projectWindowController { return _projectWindowController; }
- (void)setProjectWindowController:(SourceWindowController *)controller { _projectWindowController = controller; }

- (void)setWorkspace:(FolderWorkspace *)workspace
{
    if (_workspace == workspace)
        return;
    if (_workspace.runningDocument == self)
        [_editorWindow stopRun];
    [_projectWindowController removeProjectDocument:self];
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
}

- (void)installEditor:(SourceWindowController *)controller
{
    if (!_editorWindow) {
        Language language = [self inferredLanguageForText:_initialText];
        _editorWindow = [[EditorWindow alloc] initWithDocument:self text:_initialText ? _initialText : @""
                                                     language:language];
        _initialText = nil;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(autoSavePreferencesChanged:)
                                                   name:AutoSavePreferencesChanged object:nil];
    }
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
    if (document.projectWindowController == controller)
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
    if (_workspace) {
        if (_projectWindowController == target)
            return YES;
        if (self.editorHostWindow.attachedSheet)
            return NO;
        [_projectWindowController removeProjectDocument:self];
        NSWindowController *previous = self.windowControllers.firstObject;
        if (previous && previous != target) {
            [self removeWindowController:previous];
            [previous close];
        }
        [target addProjectDocument:self];
        return YES;
    }
    if (self.windowControllers.count)
        return NO;
    [self makeWindowControllers];
    [window addTabbedWindow:self.editorHostWindow ordered:NSWindowAbove];
    [target syncWindowOutput];
    [(SourceWindowController *)self.editorHostWindow.windowController syncWindowOutput];
    return YES;
}

- (void)makeWindowControllers
{
    if (self.windowControllers.count || _projectWindowController)
        return;
    SourceWindowController *controller = MakeSourceWindowController(_workspace);
    [self addWindowController:controller];
    [self installEditor:controller];
}

- (void)showWindows
{
    if (_projectWindowController && ![_projectWindowController selectProjectDocument:self])
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
    SourceWindowController *project = _projectWindowController;
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
        [_editorWindow refreshDetectedLanguage];
        [_workspace refresh];
        [_workspace documentChanged];
        if (self.editorHostWindow.windowController.document == self)
            [(SourceWindowController *)self.editorHostWindow.windowController revealCurrentFile];
    }
}

- (void)setFileURLFromExplorer:(NSURL *)url
{
    NSURL *old = self.fileURL;
    NSDate *date = self.fileModificationDate;
    [super setFileURL:url];
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
    NSWindowController *controller = self.windowControllers.firstObject;
    [controller synchronizeWindowTitleWithDocumentName];
}

- (void)updateChangeCount:(NSDocumentChangeType)change
{
    BOOL edited = self.isDocumentEdited;
    [super updateChangeCount:change];
    if (edited != self.isDocumentEdited) {
        [_workspace documentChanged];
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
        [_workspace documentChanged];
}

- (IBAction)selectTheme:(NSMenuItem *)sender
{
    SelectEditorTheme(sender.tag);
}

- (IBAction)runDocument:(id)sender
{
    [_editorWindow runSource:sender];
}

- (IBAction)toggleDocumentOutput:(id)sender
{
    [_editorWindow toggleOutput:sender];
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

- (void)cancelRun { [_editorWindow stopRun]; }
- (NSUInteger)beginBuildDiagnostics { return [_editorWindow beginBuildDiagnostics]; }

- (void)applyBuildMessages:(const std::vector<RunMessage> &)messages version:(NSUInteger)version owner:(BOOL)owner
{
    [_editorWindow applyBuildMessages:messages version:version owner:owner];
}

- (void)close
{
    if (_closing)
        return;
    _closing = YES;
    [self cancelAutoSave];
    [_editorWindow stopRun];
    [_projectWindowController closeProjectDocument:self];
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
    if (action == @selector(runDocument:)) {
        BOOL running = _editorWindow.running || _workspace.runningDocument != nil;
        item.title = running ? @"Stop" : @"Run";
        return _editorWindow && (running || _editorWindow.canRun);
    }
    if (action == @selector(toggleDocumentOutput:)) {
        item.state = _editorWindow.outputShown ? NSControlStateValueOn : NSControlStateValueOff;
        return _editorWindow != nil;
    }
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
                OpenRelatedFile(url, self.editorHostWindow, ^(NSDocument *, BOOL, NSError *error) {
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
                [VimTextView jumpToVimFileMark:[argument characterAtIndex:0] exact:force];
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