#import "Output.h"
#import "Preferences.h"

#include <algorithm>
#include <deque>

static NSAttributedStringKey const outputToneKey = @"RetinaCodeOutputTone";
static NSAttributedStringKey const outputForegroundKey = @"RetinaCodeTerminalForeground";
static NSAttributedStringKey const outputBackgroundKey = @"RetinaCodeTerminalBackground";

static NSColor *TerminalColor(uint32_t color, BOOL dark)
{
    if (color < outputPaletteStart)
        return SRGBHex(color);
    constexpr uint32_t darkPalette[] = {
        0x000000, 0xDF4A44, 0x4DB864, 0xD3AD38, 0x588BE4, 0xBC69D7, 0x47ADB5, 0xCCCCCC,
        0x808080, 0xFF5555, 0x69DE83, 0xFFD94D, 0x7BA9FF, 0xE592FF, 0x71D9DF, 0xFFFFFF,
    };
    constexpr uint32_t lightPalette[] = {
        0x000000, 0xA51A21, 0x14632C, 0x765600, 0x234997, 0x80248D, 0x136A73, 0x666666,
        0x666666, 0xC4252C, 0x207B37, 0x876100, 0x315AC0, 0x9639A4, 0x127985, 0xFFFFFF,
    };
    uint32_t index = color - outputPaletteStart;
    if (index < 16)
        return SRGBHex((dark ? darkPalette : lightPalette)[index]);
    if (index < 232) {
        constexpr uint32_t levels[] = {0, 95, 135, 175, 215, 255};
        index -= 16;
        return SRGBHex((levels[index / 36] << 16) | (levels[index / 6 % 6] << 8) | levels[index % 6]);
    }
    uint32_t gray = 8 + (index - 232) * 10;
    return SRGBHex(gray * 0x010101);
}

static void SetTerminalColor(NSTextStorage *storage, NSRange range, uint32_t color, BOOL dark,
                             NSAttributedStringKey codeKey, NSAttributedStringKey colorKey)
{
    if (color != defaultOutputColor)
        [storage addAttributes:@{codeKey:@(color), colorKey:TerminalColor(color, dark)} range:range];
}

static void RecolorTerminalText(NSTextStorage *storage, BOOL dark, NSAttributedStringKey codeKey,
                                NSAttributedStringKey colorKey)
{
    [storage enumerateAttribute:codeKey inRange:NSMakeRange(0, storage.length)
                         options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
                      usingBlock:^(NSNumber *color, NSRange range, BOOL *) {
        if (color)
            [storage addAttribute:colorKey value:TerminalColor(color.unsignedIntValue, dark) range:range];
    }];
}

struct OutputScrollPosition {
    NSPoint origin;
    bool following;
    NSUInteger character = NSNotFound;
    CGFloat lineOffset = 0;
};

struct OutputLocation {
    NSUInteger end;
    RunLocation location;
    __weak SourceDocument *source;
};

static bool OutputLineEnding(unichar character)
{
    return (character >= '\n' && character <= '\r') || character == 0x85 ||
           character == 0x2028 || character == 0x2029;
}

@interface OutputTextView : NSTextView
@property(nonatomic) RenderSettings rendering;
@property(nonatomic) NSUInteger inputStart;
@property(nonatomic, copy) void (^sendEOF)(void);
@end

@implementation OutputTextView

- (void)moveToInputIfNeeded
{
    if (self.editable && self.selectedRange.location < self.inputStart)
        self.selectedRange = NSMakeRange(self.string.length, 0);
}

- (void)insertText:(id)text replacementRange:(NSRange)range
{
    [self moveToInputIfNeeded];
    if (self.editable && range.location < self.inputStart)
        range = self.selectedRange;
    [super insertText:text replacementRange:range];
}

- (void)paste:(id)sender
{
    [self moveToInputIfNeeded];
    [super paste:sender];
}

- (void)insertNewline:(id)sender
{
    [self moveToInputIfNeeded];
    [super insertNewline:sender];
}

- (void)insertTab:(id)sender
{
    if (self.editable)
        [self insertText:@"\t" replacementRange:NSMakeRange(NSNotFound, 0)];
    else
        [super insertTab:sender];
}

- (void)keyDown:(NSEvent *)event
{
    if (self.editable && (event.modifierFlags & NSEventModifierFlagControl) &&
        !(event.modifierFlags & NSEventModifierFlagCommand) && [event.charactersIgnoringModifiers isEqualToString:@"d"]) {
        if (self.sendEOF)
            self.sendEOF();
        return;
    }
    [super keyDown:event];
}

- (void)drawRect:(NSRect)dirty
{
    dirty = NSIntersectionRect(dirty, self.visibleRect);
    if (NSIsEmptyRect(dirty))
        return;
    DrawEditorSurface(self, dirty, self.rendering, self.backgroundColor,
                      (CodeLayoutManager *)self.layoutManager, ^(NSRect rect) {
        [self.backgroundColor setFill];
        NSRectFill(rect);
        [super drawRect:rect];
    });
}

@end

@interface OutputPane () <NSTextViewDelegate, NSMenuItemValidation>
@end

@implementation OutputPane {
    NSScrollView *_scroll;
    OutputTextView *_text;
    NSFont *_font;
    NSArray<NSColor *> *_colors;
    std::deque<NSUInteger> _lineEnds;
    std::deque<OutputLocation> _locations;
    NSUInteger _historyStart;
    NSUInteger _firstLink;
    NSUInteger _scrollbackLines;
    BOOL _scrollRepaintPending;
    BOOL _dark;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleLegacy;
    _scroll.verticalScrollElasticity = NSScrollElasticityNone;
    [self addSubview:_scroll];

    NSTextStorage *storage = [[NSTextStorage alloc] init];
    CodeLayoutManager *layout = [[CodeLayoutManager alloc] init];
    [storage addLayoutManager:layout];
    NSTextContainer *container = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(600, 10000000)];
    container.lineFragmentPadding = 0;
    container.widthTracksTextView = YES;
    [layout addTextContainer:container];
    _text = [[OutputTextView alloc] initWithFrame:_scroll.contentView.bounds textContainer:container];
    _text.verticallyResizable = YES;
    _text.horizontallyResizable = NO;
    _text.autoresizingMask = NSViewWidthSizable;
    _text.minSize = NSZeroSize;
    _text.maxSize = NSMakeSize(10000000, 10000000);
    _text.textContainerInset = NSMakeSize(9, 6);
    _text.richText = NO;
    _text.editable = NO;
    _text.selectable = YES;
    _text.drawsBackground = NO;
    _text.automaticLinkDetectionEnabled = NO;
    _text.automaticDataDetectionEnabled = NO;
    _text.automaticQuoteSubstitutionEnabled = NO;
    _text.automaticDashSubstitutionEnabled = NO;
    _text.automaticTextReplacementEnabled = NO;
    _text.automaticSpellingCorrectionEnabled = NO;
    _text.smartInsertDeleteEnabled = NO;
    _text.linkTextAttributes = @{NSCursorAttributeName:NSCursor.pointingHandCursor};
    _text.delegate = self;
    _text.accessibilityLabel = @"Output";
    __weak OutputPane *pane = self;
    _text.sendEOF = ^{ [pane sendEndOfFile]; };
    _scroll.documentView = _text;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItem:[self clearMenuItem]];
    _scroll.contentView.menu = menu;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrollBoundsChanged:)
                                               name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    _scrollbackLines = OutputScrollbackLinesPreference();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(outputScrollbackChanged:)
                                               name:OutputScrollbackPreferencesChanged object:nil];
    return self;
}

- (void)scrollBoundsChanged:(NSNotification *)notification
{
    (void)notification;
    if (_scrollRepaintPending || !self.window || self.isHiddenOrHasHiddenAncestor)
        return;
    _scrollRepaintPending = YES;
    __weak OutputPane *pane = self;
    // Invalidate the LCD surface at the new viewport after AppKit finishes scrolling.
    [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes] block:^{
        OutputPane *output = pane;
        if (output) {
            output->_scrollRepaintPending = NO;
            [output->_text setNeedsDisplayInRect:output->_text.visibleRect];
        }
    }];
}

- (void)layout
{
    [super layout];
    NSRect area = self.bounds;
    area.size.height = std::max<CGFloat>(0, NSHeight(area) - 1);
    if (NSEqualRects(area, _scroll.frame))
        return;
    OutputScrollPosition position = [self scrollPosition];
    _scroll.frame = area;
    [self restoreScrollPosition:position removed:0 reflow:YES];
}

- (void)drawRect:(NSRect)dirty
{
    dirty = NSIntersectionRect(dirty, self.bounds);
    [_text.backgroundColor setFill];
    NSRectFill(dirty);
    [SRGBHex(_dark ? 0x555555 : 0xA0A0A0) setFill];
    NSRectFill(NSIntersectionRect(dirty, NSMakeRect(0, NSHeight(self.bounds) - 1, NSWidth(self.bounds), 1)));
}

- (BOOL)hasKeyboardFocus
{
    return self.window.firstResponder == _text;
}

- (BOOL)atOutputEnd
{
    CGFloat margin = _text.textContainerInset.height + 4;
    return NSMaxY(_scroll.documentVisibleRect) >= NSMaxY(_text.bounds) - margin;
}

- (OutputScrollPosition)scrollPosition
{
    OutputScrollPosition position{_scroll.documentVisibleRect.origin, bool([self atOutputEnd])};
    if (position.following || !_text.string.length)
        return position;
    NSLayoutManager *layout = _text.layoutManager;
    NSPoint origin = _text.textContainerOrigin;
    CGFloat top = position.origin.y - origin.y;
    NSUInteger glyph = [layout glyphIndexForPoint:NSMakePoint(0, std::max<CGFloat>(0, top))
                                    inTextContainer:_text.textContainer];
    if (glyph < layout.numberOfGlyphs) {
        position.character = [layout characterIndexForGlyphAtIndex:glyph];
        position.lineOffset = top - NSMinY([layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr]);
    }
    return position;
}

- (void)restoreScrollPosition:(OutputScrollPosition)position removed:(NSUInteger)removed reflow:(BOOL)reflow
{
    if (removed || reflow)
        [_text sizeToFit];
    NSClipView *clip = _scroll.contentView;
    if (position.following) {
        // Scroll to the document edge after TextKit lays out the new final row.
        [_text scrollRangeToVisible:NSMakeRange(_text.string.length, 0)];
        position.origin = clip.bounds.origin;
        position.origin.y = NSMaxY(_text.frame) - NSHeight(clip.bounds);
    } else if (removed || reflow) {
        if (position.character != NSNotFound && position.character >= removed &&
            position.character - removed < _text.string.length) {
            NSLayoutManager *layout = _text.layoutManager;
            NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:position.character - removed];
            NSRect line = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr];
            position.origin.y = _text.textContainerOrigin.y + NSMinY(line) + position.lineOffset;
        } else if (removed) {
            position.origin.y = 0;
        }
    }
    NSRect bounds = clip.bounds;
    bounds.origin = position.origin;
    [clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
    [_scroll reflectScrolledClipView:clip];
}

- (NSUInteger)recordLineEndingsFrom:(NSUInteger)start to:(NSUInteger)end
{
    NSString *text = _text.string;
    NSUInteger discardThrough = _historyStart;
    unichar previous = start ? [text characterAtIndex:start - 1] : 0;
    unichar characters[1024];
    for (NSUInteger at = start; at < end;) {
        NSUInteger length = std::min<NSUInteger>(std::size(characters), end - at);
        [text getCharacters:characters range:NSMakeRange(at, length)];
        for (NSUInteger index = 0; index < length; ++index) {
            unichar character = characters[index];
            if (OutputLineEnding(character)) {
                NSUInteger after = _historyStart + at + index + 1;
                if (character == '\n' && previous == '\r' && !_lineEnds.empty() && _lineEnds.back() == after - 1) {
                    _lineEnds.back() = after;
                } else {
                    // Reclaim in chunks so a long run does not reflow the history on each new line.
                    if (_lineEnds.size() == _scrollbackLines) {
                        NSUInteger lineChunk = std::min<NSUInteger>(128, std::max<NSUInteger>(1, _scrollbackLines / 16));
                        discardThrough = _lineEnds[lineChunk - 1];
                        _lineEnds.erase(_lineEnds.begin(), _lineEnds.begin() + lineChunk);
                    }
                    _lineEnds.push_back(after);
                }
            }
            previous = character;
        }
        at += length;
    }
    return discardThrough - _historyStart;
}

- (NSUInteger)discardOutputBefore:(NSUInteger)offset
{
    NSUInteger end = _text.inputStart;
    NSUInteger characterLimit = OutputScrollbackCharacterLimit(_scrollbackLines);
    if (end > characterLimit) {
        constexpr NSUInteger characterChunk = 8192;
        NSUInteger cutoff = end - (characterLimit - characterChunk);
        if (cutoff > offset) {
            offset = cutoff;
            auto line = std::lower_bound(_lineEnds.begin(), _lineEnds.end(), _historyStart + cutoff);
            if (line != _lineEnds.end() && *line - _historyStart - cutoff <= 4096)
                offset = *line - _historyStart;
        }
    }
    if (!offset)
        return 0;
    if (offset < end) {
        NSString *text = _text.string;
        unichar before = [text characterAtIndex:offset - 1], after = [text characterAtIndex:offset];
        if ((before == '\r' && after == '\n') ||
            (CFStringIsSurrogateHighCharacter(before) && CFStringIsSurrogateLowCharacter(after)))
            ++offset;
    }
    _historyStart += offset;
    while (!_lineEnds.empty() && _lineEnds.front() <= _historyStart)
        _lineEnds.pop_front();
    while (!_locations.empty() && _locations.front().end <= _historyStart) {
        _locations.pop_front();
        ++_firstLink;
    }
    _text.inputStart = end - offset;
    [_text.textStorage deleteCharactersInRange:NSMakeRange(0, offset)];
    return offset;
}

- (void)restoreSelection:(NSRange)selection insertion:(NSUInteger)insertion added:(NSUInteger)added removed:(NSUInteger)removed
{
    if (selection.location == NSNotFound || _text.hasMarkedText)
        return;
    NSUInteger start = selection.location, end = NSMaxRange(selection);
    if (_text.editable) {
        if (start >= insertion) {
            start += added;
            end += added;
        } else if (end > insertion) {
            end += added;
        }
    }
    start = std::max(start, removed) - removed;
    end = std::max(end, removed) - removed;
    NSRange current = NSMakeRange(start, end - start);
    if (!NSEqualRanges(_text.selectedRange, current))
        _text.selectedRange = current;
    if (_text.editable && start >= _text.inputStart)
        _text.typingAttributes = [self inputAttributes];
}

- (void)trimOutputBefore:(NSUInteger)cutoff
{
    NSUInteger end = _text.inputStart;
    if (!cutoff && end <= OutputScrollbackCharacterLimit(_scrollbackLines))
        return;
    OutputScrollPosition position = [self scrollPosition];
    NSRange selection = _text.selectedRange;
    NSUInteger removed = [self discardOutputBefore:cutoff];
    [self restoreSelection:selection insertion:end added:0 removed:removed];
    [self restoreScrollPosition:position removed:removed reflow:NO];
}

- (void)outputScrollbackChanged:(NSNotification *)notification
{
    (void)notification;
    _scrollbackLines = OutputScrollbackLinesPreference();
    NSUInteger cutoff = 0;
    if (_lineEnds.size() > _scrollbackLines)
        cutoff = _lineEnds[_lineEnds.size() - _scrollbackLines - 1] - _historyStart;
    [self trimOutputBefore:cutoff];
}

- (NSDictionary *)inputAttributes
{
    return @{NSFontAttributeName:_font, NSForegroundColorAttributeName:_colors.firstObject,
             NSLigatureAttributeName:@0, outputToneKey:@0};
}

- (void)setInputEnabled:(BOOL)enabled
{
    if (enabled == _text.editable)
        return;
    if (enabled) {
        _text.inputStart = _text.string.length;
        _text.typingAttributes = [self inputAttributes];
    } else if (_text.string.length > _text.inputStart) {
        OutputScrollPosition position = [self scrollPosition];
        [_text.textStorage deleteCharactersInRange:NSMakeRange(_text.inputStart, _text.string.length - _text.inputStart)];
        [self restoreScrollPosition:position removed:0 reflow:YES];
    }
    _text.editable = enabled;
}

- (BOOL)focusInput
{
    if (!_text.editable || self.hidden || !self.window || ![self atOutputEnd])
        return NO;
    if (![self.window makeFirstResponder:_text])
        return NO;
    _text.selectedRange = NSMakeRange(_text.string.length, 0);
    _text.typingAttributes = [self inputAttributes];
    [_text scrollRangeToVisible:_text.selectedRange];
    return YES;
}

- (void)sendEndOfFile
{
    NSString *pending = [_text.string substringFromIndex:_text.inputStart];
    unichar end = 4;
    NSString *eof = [NSString stringWithCharacters:&end length:1];
    if (self.sendInput && self.sendInput([pending stringByAppendingString:eof]))
        [self commitInputThrough:_text.string.length];
}

- (BOOL)textView:(NSTextView *)view shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)text
{
    return view.editable && range.location >= _text.inputStart &&
           view.string.length - _text.inputStart - range.length + text.length <= 16384;
}

- (void)textDidChange:(NSNotification *)notification
{
    (void)notification;
    if (!_text.editable || _text.hasMarkedText || !self.sendInput)
        return;
    NSString *text = _text.string;
    NSRange tail = NSMakeRange(_text.inputStart, text.length - _text.inputStart);
    NSRange newline = [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet options:NSBackwardsSearch range:tail];
    if (newline.location == NSNotFound)
        return;
    NSUInteger end = NSMaxRange(newline);
    NSString *pending = [text substringWithRange:NSMakeRange(tail.location, end - tail.location)];
    pending = [pending stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    pending = [pending stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    if (self.sendInput(pending)) {
        [self commitInputThrough:end];
    } else {
        [_text.textStorage deleteCharactersInRange:newline];
        NSBeep();
    }
}

- (void)commitInputThrough:(NSUInteger)end
{
    NSUInteger first = _text.inputStart;
    NSUInteger cutoff = [self recordLineEndingsFrom:first to:end];
    _text.inputStart = end;
    [self trimOutputBefore:cutoff];
    _text.typingAttributes = [self inputAttributes];
}

- (void)applyFont:(NSFont *)font rendering:(RenderSettings)settings dark:(BOOL)dark
{
    // Keep the terminal's white, black, and diagnostic colors.
    settings.saturation = 1;
    settings.brightness = 1;
    _text.rendering = settings;
    BOOL colorChanged = !_colors || _dark != dark;
    BOOL fontChanged = ![_font isEqual:font];
    BOOL reflow = fontChanged && _text.string.length;
    OutputScrollPosition position{};
    if (reflow)
        position = [self scrollPosition];
    if (colorChanged) {
        _dark = dark;
        _colors = dark ? @[SRGBHex(0xFFFFFF), SRGBHex(0xFFD94D), SRGBHex(0xFF5555)] :
                         @[SRGBHex(0x000000), SRGBHex(0x866200), SRGBHex(0xB8191F)];
        NSColor *paper = SRGBHex(dark ? 0x000000 : 0xFFFFFF);
        _scroll.backgroundColor = paper;
        _text.backgroundColor = paper;
        _text.insertionPointColor = _colors.firstObject;
        _scroll.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        _text.selectedTextAttributes = @{NSBackgroundColorAttributeName:SRGBHex(dark ? 0x333F55 : 0xBDD6F7)};
    }
    NSTextStorage *storage = _text.textStorage;
    NSRange all = NSMakeRange(0, storage.length);
    if (fontChanged || colorChanged) {
        [storage beginEditing];
        if (fontChanged) {
            _font = font;
            if (storage.length)
                [storage addAttribute:NSFontAttributeName value:font range:all];
            else
                _text.font = font;
        }
        if (colorChanged && all.length) {
            [storage enumerateAttribute:outputToneKey inRange:all options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
                              usingBlock:^(NSNumber *tone, NSRange range, BOOL *) {
                [storage addAttribute:NSForegroundColorAttributeName value:self->_colors[tone.unsignedIntegerValue] range:range];
            }];
            RecolorTerminalText(storage, dark, outputForegroundKey, NSForegroundColorAttributeName);
            RecolorTerminalText(storage, dark, outputBackgroundKey, NSBackgroundColorAttributeName);
        }
        [storage endEditing];
    }
    if (_text.editable)
        _text.typingAttributes = [self inputAttributes];
    if (reflow)
        [self restoreScrollPosition:position removed:0 reflow:YES];
    [self setNeedsDisplay:YES];
    [_text setNeedsDisplayInRect:_text.visibleRect];
}

- (NSMenuItem *)clearMenuItem
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Clear" action:@selector(clearOutput:) keyEquivalent:@""];
    item.target = self;
    return item;
}

- (NSMenu *)textView:(NSTextView *)view menu:(NSMenu *)menu forEvent:(NSEvent *)event atIndex:(NSUInteger)index
{
    (void)view;
    (void)event;
    (void)index;
    NSMenu *context = menu ? [menu copy] : [[NSMenu alloc] initWithTitle:@""];
    if (context.numberOfItems && !context.itemArray.lastObject.isSeparatorItem)
        [context addItem:NSMenuItem.separatorItem];
    [context addItem:[self clearMenuItem]];
    return context;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    return item.action != @selector(clearOutput:) || _text.inputStart != 0;
}

- (IBAction)clearOutput:(id)sender
{
    (void)sender;
    [self clear];
}

- (void)prepareForRun
{
    if (ClearOutputOnRunPreference())
        [self clear];
    else
        [self restoreScrollPosition:{NSZeroPoint, true} removed:0 reflow:NO];
}

- (void)clear
{
    NSUInteger end = _text.inputStart;
    NSRange selection = _text.selectedRange;
    NSUInteger removed = [self discardOutputBefore:end];
    _historyStart = 0;
    [self restoreSelection:selection insertion:end added:0 removed:removed];
    [self restoreScrollPosition:{NSZeroPoint, _text.string.length != 0} removed:removed reflow:YES];
}

- (void)appendMessages:(const std::vector<RunMessage> &)messages source:(SourceDocument *)source
{
    if (messages.empty())
        return;
    OutputScrollPosition position = [self scrollPosition];
    NSTextStorage *storage = _text.textStorage;
    NSUInteger insertion = _text.editable ? _text.inputStart : storage.length;
    const NSUInteger initial = insertion;
    NSRange selection = _text.selectedRange;
    [storage beginEditing];
    for (const auto &message : messages) {
        NSUInteger tone = message.usesTerminalColors ? NSUInteger(OutputTone::Text) : NSUInteger(message.tone);
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:message.text
            attributes:@{NSFontAttributeName:_font, NSForegroundColorAttributeName:_colors[tone],
                         NSLigatureAttributeName:@0, outputToneKey:@(tone)}];
        NSUInteger start = insertion;
        [storage insertAttributedString:text atIndex:insertion];
        insertion += text.length;
        for (const auto &span : message.colorSpans) {
            NSRange range = NSMakeRange(start + span.range.location, span.range.length);
            SetTerminalColor(storage, range, span.colors.foreground, _dark, outputForegroundKey, NSForegroundColorAttributeName);
            SetTerminalColor(storage, range, span.colors.background, _dark, outputBackgroundKey, NSBackgroundColorAttributeName);
        }
        if (message.location.line) {
            NSRange range = message.linkRange;
            if (range.location == NSNotFound)
                range = NSMakeRange(0, text.length - [message.text hasSuffix:@"\n"]);
            if (!range.length || NSMaxRange(range) > text.length)
                continue;
            range.location += start;
            _locations.push_back({_historyStart + NSMaxRange(range), message.location,
                                  message.location.currentSource ? source : nil});
            NSURL *link = [NSURL URLWithString:[NSString stringWithFormat:@"retina-code-diagnostic:%lu",
                                                 (unsigned long)(_firstLink + _locations.size())]];
            [storage addAttributes:@{NSLinkAttributeName:link, NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle)}
                              range:range];
        }
    }
    NSUInteger cutoff = [self recordLineEndingsFrom:initial to:insertion];
    _text.inputStart = insertion;
    if (messages.front().earlierOutputDiscarded)
        cutoff = std::max(cutoff, initial);
    NSUInteger removed = [self discardOutputBefore:cutoff];
    [storage endEditing];
    [self restoreSelection:selection insertion:initial added:insertion - initial removed:removed];
    [self restoreScrollPosition:position removed:removed reflow:NO];
}

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)index
{
    (void)textView;
    (void)index;
    if ([link isKindOfClass:NSURL.class] && [[link scheme] isEqualToString:@"retina-code-diagnostic"]) {
        NSUInteger number = NSUInteger([[link resourceSpecifier] integerValue]);
        if (number > _firstLink && number - _firstLink <= _locations.size() && self.openLocation) {
            const OutputLocation &entry = _locations[number - _firstLink - 1];
            self.openLocation(entry.location, entry.source);
        }
    }
    return YES;
}

@end