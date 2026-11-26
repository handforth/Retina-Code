#import "EditorHover.h"
#import "Chrome.h"
#import "LanguageServer.h"
#import "Rendering.h"
#include "Themes.h"

#include <algorithm>
#include <cmath>

static constexpr NSUInteger hoverTextLimit = 16000;
static constexpr CGFloat hoverInset = 8;
static constexpr CGFloat footerHeight = 22;
static constexpr CGFloat actionGap = 8;
static NSString *const viewErrorTitle = @"View Error (⌥F8)";
static NSString *const quickFixTitle = @"Quick Fix… (⌘.)";
static NSString *const hoverBlock = @"RetinaCode.HoverBlock";

enum class HoverBlock { Quote, Rule };

static NSString *BoundedHoverText(NSString *text, NSUInteger limit)
{
    if (text.length <= limit)
        return text;
    limit = [text rangeOfComposedCharacterSequenceAtIndex:limit - 1].location;
    return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

struct HoverStyle {
    const Theme &theme;
    PopupColors colors;
    NSFont *code;
    NSFont *body;
    NSColor *text;
    NSColor *muted;
    NSColor *rule;
    NSColor *link;

    HoverStyle(const Theme &palette, NSFont *font)
        : theme(palette), colors(EditorPopupColors(palette)), code(font), body([NSFont systemFontOfSize:12])
    {
        text = SRGBColor(colors.text);
        muted = SRGBColor(BlendColor(colors.paper, colors.text, 70));
        rule = SRGBColor(BlendColor(colors.paper, colors.text, 22));
        link = SRGBColor(BlendColor(colors.text, palette.ink[size_t(Ink::Type)], 64));
    }
};

static NSAttributedString *StyledText(NSString *text, NSFont *font, NSColor *ink)
{
    return [[NSAttributedString alloc] initWithString:text ? text : @"" attributes:@{
        NSFontAttributeName:font, NSForegroundColorAttributeName:ink, NSLigatureAttributeName:@0
    }];
}

static void EndParagraph(NSMutableAttributedString *text, NSUInteger first, NSParagraphStyle *style, BOOL gap)
{
    if (first == text.length)
        return;
    [text replaceCharactersInRange:NSMakeRange(text.length, 0) withString:@"\n"];
    if (gap) {
        NSMutableParagraphStyle *spaced = [style mutableCopy];
        spaced.paragraphSpacing = 5;
        style = spaced;
    }
    [text addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(first, text.length - first)];
}

static Language HoverCodeLanguage(NSString *hint, Language fallback)
{
    if (!hint.length)
        return fallback;
    hint = [[hint componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] firstObject];
    std::u16string name(hint.length, u'\0');
    [hint getCharacters:reinterpret_cast<unichar *>(name.data()) range:NSMakeRange(0, hint.length)];
    return LanguageForFence(name);
}

static void AppendCode(NSMutableAttributedString *text, NSString *code, NSString *hint,
                       Language language, const HoverStyle &style)
{
    if (!code.length)
        return;
    if ([code hasSuffix:@"\n"])
        code = [code substringToIndex:code.length - 1];
    NSUInteger first = text.length;
    [text appendAttributedString:StyledText(code.length ? code : @" ", style.code, style.text)];
    Language codeLanguage = HoverCodeLanguage(hint, language);
    if (codeLanguage != Language::Plain) {
        std::u16string source(code.length, u'\0');
        [code getCharacters:reinterpret_cast<unichar *>(source.data()) range:NSMakeRange(0, code.length)];
        LexState state;
        std::vector<Token> tokens;
        for (size_t start = 0; start < source.size();) {
            size_t end = source.find(u'\n', start);
            if (end == std::u16string::npos)
                end = source.size();
            TokenizeLine(std::u16string_view(source).substr(start, end - start), codeLanguage, state, tokens);
            for (const Token &token : tokens) {
                if (token.ink == Ink::Text)
                    continue;
                [text addAttribute:NSForegroundColorAttributeName value:SRGBColor(style.theme.ink[size_t(token.ink)])
                             range:NSMakeRange(first + start + token.start, token.length)];
            }
            start = end + 1;
        }
    }
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.tabStops = @[];
    paragraph.defaultTabInterval = 4 * [@" " sizeWithAttributes:@{NSFontAttributeName:style.code}].width;
    [text addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(first, text.length - first)];
    NSUInteger last = [text.string lineRangeForRange:NSMakeRange(text.length - 1, 0)].location;
    EndParagraph(text, last, paragraph, YES);
}

static void AppendPlain(NSMutableAttributedString *text, NSString *value, const HoverStyle &style)
{
    if (!value.length)
        return;
    NSUInteger first = text.length;
    [text appendAttributedString:StyledText(value, style.body, style.text)];
    EndParagraph(text, first, NSParagraphStyle.defaultParagraphStyle, YES);
}

static void AppendInline(NSMutableAttributedString *text, NSAttributedString *markdown, NSRange range,
                         NSFont *font, NSColor *ink, const HoverStyle &style) API_AVAILABLE(macos(12.0))
{
    NSString *source = markdown.string;
    [markdown enumerateAttributesInRange:range options:0 usingBlock:^(NSDictionary *attributes, NSRange part, BOOL *) {
        NSUInteger intent = [attributes[NSInlinePresentationIntentAttributeName] unsignedIntegerValue];
        BOOL code = intent & NSInlinePresentationIntentCode;
        NSFont *selectedFont = code ? style.code : font;
        NSFontTraitMask traits = 0;
        if (intent & NSInlinePresentationIntentStronglyEmphasized)
            traits |= NSBoldFontMask;
        if (intent & NSInlinePresentationIntentEmphasized)
            traits |= NSItalicFontMask;
        if (traits)
            selectedFont = [NSFontManager.sharedFontManager convertFont:selectedFont toHaveTrait:traits];
        NSUInteger first = text.length;
        [text appendAttributedString:StyledText([source substringWithRange:part], selectedFont, ink)];
        NSRange added = NSMakeRange(first, part.length);
        if (intent & NSInlinePresentationIntentStrikethrough)
            [text addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:added];
        id link = attributes[NSLinkAttributeName];
        NSURL *url = [link isKindOfClass:NSURL.class] ? link : nil;
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])
            [text addAttribute:NSLinkAttributeName value:url range:added];
    }];
}

static BOOL AppendMarkdown(NSMutableAttributedString *text, NSString *source, Language language, const HoverStyle &style)
{
    if (@available(macOS 12.0, *)) {
        NSAttributedString *markdown = [[NSAttributedString alloc] initWithMarkdownString:source
                                                                                options:nil baseURL:nil error:nullptr];
        if (!markdown)
            return NO;
        __block NSInteger lastItem = -1, tableIdentity = -1;
        __block NSTextTable *table = nil;
        [markdown enumerateAttribute:NSPresentationIntentAttributeName inRange:NSMakeRange(0, markdown.length)
                              options:0 usingBlock:^(NSPresentationIntent *intent, NSRange range, BOOL *) {
            if (intent.intentKind == NSPresentationIntentKindCodeBlock) {
                AppendCode(text, [markdown.string substringWithRange:range], intent.languageHint, language, style);
                return;
            }
            NSUInteger first = text.length;
            NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
            NSFont *font = style.body;
            NSColor *ink = style.text;
            BOOL quote = NO, list = NO, gap = YES;
            for (NSPresentationIntent *parent = intent; parent; parent = parent.parentIntent) {
                if (parent.intentKind == NSPresentationIntentKindBlockQuote) {
                    quote = YES;
                    ink = style.muted;
                }
                if (parent.intentKind == NSPresentationIntentKindListItem && !list) {
                    list = YES;
                    CGFloat indent = 12 * std::clamp<NSInteger>(parent.indentationLevel - 1, 0, 4);
                    paragraph.firstLineHeadIndent = indent;
                    paragraph.headIndent = indent + 15;
                    if (lastItem != parent.identity) {
                        NSString *marker = parent.parentIntent.intentKind == NSPresentationIntentKindOrderedList
                            ? [NSString stringWithFormat:@"%ld. ", (long)parent.ordinal] : @"•  ";
                        [text appendAttributedString:StyledText(marker, font, ink)];
                        lastItem = parent.identity;
                    } else {
                        paragraph.firstLineHeadIndent = paragraph.headIndent;
                    }
                    gap = NO;
                }
            }
            if (intent.intentKind == NSPresentationIntentKindHeader)
                font = [NSFont boldSystemFontOfSize:intent.headerLevel <= 2 ? 14 : 12];
            if (intent.intentKind == NSPresentationIntentKindTableCell) {
                NSPresentationIntent *row = intent.parentIntent;
                NSPresentationIntent *grid = row.parentIntent;
                if (tableIdentity != grid.identity) {
                    tableIdentity = grid.identity;
                    table = [[NSTextTable alloc] init];
                    table.numberOfColumns = grid.columnCount;
                    table.collapsesBorders = YES;
                    table.layoutAlgorithm = NSTextTableFixedLayoutAlgorithm;
                }
                BOOL header = row.intentKind == NSPresentationIntentKindTableHeaderRow;
                NSTextTableBlock *cell = [[NSTextTableBlock alloc] initWithTable:table startingRow:row.row rowSpan:1
                                                                 startingColumn:intent.column columnSpan:1];
                [cell setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
                [cell setWidth:1 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder];
                [cell setBorderColor:style.rule];
                paragraph.textBlocks = @[cell];
                if (header)
                    font = [NSFont boldSystemFontOfSize:12];
                switch ([grid.columnAlignments[intent.column] integerValue]) {
                    case NSPresentationIntentTableColumnAlignmentCenter: paragraph.alignment = NSTextAlignmentCenter; break;
                    case NSPresentationIntentTableColumnAlignmentRight: paragraph.alignment = NSTextAlignmentRight; break;
                    default: break;
                }
                gap = NO;
            }
            if (quote) {
                paragraph.firstLineHeadIndent += 8;
                paragraph.headIndent += 8;
            }
            if (intent.intentKind == NSPresentationIntentKindThematicBreak) {
                [text appendAttributedString:StyledText(@"\u200B", font, ink)];
                [text addAttribute:hoverBlock value:@(NSInteger(HoverBlock::Rule)) range:NSMakeRange(first, 1)];
            } else {
                AppendInline(text, markdown, range, font, ink, style);
                if (quote)
                    [text addAttribute:hoverBlock value:@(NSInteger(HoverBlock::Quote)) range:NSMakeRange(first, text.length - first)];
            }
            EndParagraph(text, first, paragraph, gap);
        }];
        return YES;
    }
    return NO;
}

// On macOS 11, preserve code fences when the server sends Markdown.
static void AppendLegacyMarkdown(NSMutableAttributedString *text, NSString *source,
                                 Language language, const HoverStyle &style)
{
    NSString *fence = nil, *hint = nil;
    NSMutableString *part = [NSMutableString string];
    for (NSString *line in [source componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!fence && ([trimmed hasPrefix:@"```"] || [trimmed hasPrefix:@"~~~"])) {
            AppendPlain(text, part, style);
            [part setString:@""];
            NSUInteger end = 3;
            while (end < trimmed.length && [trimmed characterAtIndex:end] == [trimmed characterAtIndex:0])
                ++end;
            fence = [trimmed substringToIndex:end];
            hint = [[trimmed substringFromIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        } else if (fence && [trimmed hasPrefix:fence]) {
            AppendCode(text, part, hint, language, style);
            [part setString:@""];
            fence = nil;
        } else {
            [part appendString:line];
            [part appendString:@"\n"];
        }
    }
    if (fence)
        AppendCode(text, part, hint, language, style);
    else
        AppendPlain(text, part, style);
}

static void AppendMarkupPart(NSMutableAttributedString *text, id value, Language language, const HoverStyle &style)
{
    NSDictionary *markup = LSPDict(value);
    NSString *source = LSPString(value);
    if (!source)
        source = LSPString(markup[@"value"]);
    source = BoundedHoverText(source, hoverTextLimit - text.length);
    if (!source.length)
        return;
    if (NSString *hint = LSPString(markup[@"language"]))
        AppendCode(text, source, hint, language, style);
    else if ([LSPString(markup[@"kind"]) isEqualToString:@"plaintext"])
        AppendPlain(text, source, style);
    else if (!AppendMarkdown(text, source, language, style))
        AppendLegacyMarkdown(text, source, language, style);
}

@interface HoverTextView : NSTextView
@property(nonatomic) NSColor *ruleColor;
@end

@implementation HoverTextView

- (void)drawViewBackgroundInRect:(NSRect)dirty
{
    [super drawViewBackgroundInRect:dirty];
    NSLayoutManager *layout = self.layoutManager;
    NSTextContainer *container = self.textContainer;
    NSPoint origin = self.textContainerOrigin;
    NSRange glyphs = [layout glyphRangeForBoundingRect:NSOffsetRect(dirty, -origin.x, -origin.y)
                                       inTextContainer:container];
    NSRange visible = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:nullptr];
    [self.textStorage enumerateAttribute:hoverBlock inRange:visible options:0
                              usingBlock:^(NSNumber *kind, NSRange range, BOOL *) {
        if (!kind)
            return;
        NSRange marks = [layout glyphRangeForCharacterRange:range actualCharacterRange:nullptr];
        NSRect rect = [layout boundingRectForGlyphRange:marks inTextContainer:container];
        rect.origin = NSMakePoint(origin.x, origin.y + rect.origin.y);
        rect.size.width = self.bounds.size.width - 2 * origin.x;
        switch (HoverBlock(kind.integerValue)) {
            case HoverBlock::Quote:
                [self.ruleColor setFill];
                rect.size.width = 2;
                NSRectFill(NSIntersectionRect(rect, dirty));
                break;
            case HoverBlock::Rule:
                [self.ruleColor setFill];
                rect.origin.y = std::floor(NSMidY(rect));
                rect.size.height = 1;
                NSRectFill(NSIntersectionRect(rect, dirty));
                break;
        }
    }];
}

@end

@interface EditorHover () <NSTextViewDelegate>
@end

@implementation EditorHover {
    NSScrollView *_scroll;
    HoverTextView *_text;
    NSButton *_error;
    NSButton *_fixButton;
    PopupColors _colors;
    NSColor *_rule;
    SignatureLabel _signature;
    id _signatureMarkup;
    NSSize _signatureLimit;
    NSSize _signatureSize;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.clipsToBounds = YES;
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _text = [[HoverTextView alloc] initWithFrame:NSZeroRect];
    _text.drawsBackground = NO;
    _text.editable = NO;
    _text.textContainerInset = NSMakeSize(hoverInset, 6);
    _text.textContainer.lineFragmentPadding = 0;
    _text.textContainer.widthTracksTextView = YES;
    _text.textContainer.heightTracksTextView = NO;
    _text.verticallyResizable = YES;
    _text.autoresizingMask = NSViewWidthSizable;
    _text.delegate = self;
    _scroll.documentView = _text;
    [self addSubview:_scroll];
    _error = [NSButton buttonWithTitle:viewErrorTitle target:self action:@selector(openError:)];
    _fixButton = [NSButton buttonWithTitle:quickFixTitle target:self action:@selector(openQuickFix:)];
    for (NSButton *button : {_error, _fixButton}) {
        button.bordered = NO;
        button.alignment = NSTextAlignmentLeft;
        button.refusesFirstResponder = YES;
        [self addSubview:button];
    }
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect | NSTrackingActiveInKeyWindow;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (BOOL)containsResponder:(NSResponder *)responder
{
    return !self.hidden && [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:self];
}

- (void)clear
{
    if (self.hidden)
        return;

    NSWindow *window = self.window;
    BOOL restoreCursor = window.isKeyWindow && NSCursor.currentCursor == NSCursor.pointingHandCursor &&
        NSPointInRect([self convertPoint:window.mouseLocationOutsideOfEventStream fromView:nil], self.visibleRect);
    self.hidden = YES;
    if (restoreCursor)
        [NSCursor.IBeamCursor set];

    _signature = {};
    _signatureMarkup = nil;
    [_text.textStorage deleteCharactersInRange:NSMakeRange(0, _text.textStorage.length)];
}

- (void)mouseExited:(NSEvent *)event
{
    (void)event;
    if (!self.hidden && self.pointerExited)
        self.pointerExited();
}

- (void)resetCursorRects
{
    for (NSButton *button : {_error, _fixButton}) {
        if (!button.hidden)
            [self addCursorRect:button.frame cursor:NSCursor.pointingHandCursor];
    }
}

- (void)openError:(id)sender
{
    (void)sender;
    if (self.viewError)
        self.viewError();
}

- (void)openQuickFix:(id)sender
{
    (void)sender;
    if (!_fixButton.hidden && self.quickFix)
        self.quickFix();
}

- (BOOL)textView:(NSTextView *)view doCommandBySelector:(SEL)selector
{
    (void)view;
    if (selector != @selector(cancelOperation:))
        return NO;
    if (self.cancel)
        self.cancel();
    return YES;
}

- (void)drawRect:(NSRect)dirty
{
    dirty = NSIntersectionRect(dirty, self.bounds);
    if (NSIsEmptyRect(dirty))
        return;
    DrawPopupFrame(self.bounds, dirty, _colors.paper, _colors.border);
    if (!_error.hidden) {
        [_rule setFill];
        NSRectFill(NSIntersectionRect(dirty, NSMakeRect(1, NSMaxY(_scroll.frame), NSWidth(self.bounds) - 2, 1)));
    }
}

- (NSSize)showText:(NSMutableAttributedString *)text diagnostic:(BOOL)diagnostic quickFix:(BOOL)quickFix
              style:(const HoverStyle &)style limit:(NSSize)limit
{
    if (!text.length)
        return NSZeroSize;
    if ([text.string hasSuffix:@"\n"])
        [text deleteCharactersInRange:NSMakeRange(text.length - 1, 1)];
    if (!text.length)
        return NSZeroSize;
    BOOL dark = style.theme.dark;
    self.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    _colors = style.colors;
    _rule = style.rule;
    _text.ruleColor = style.rule;
    _text.linkTextAttributes = @{NSForegroundColorAttributeName:style.link, NSUnderlineStyleAttributeName:@1};
    _text.selectedTextAttributes = @{NSBackgroundColorAttributeName:SRGBColor(_colors.selection),
                                      NSForegroundColorAttributeName:SRGBColor(_colors.selectedText)};
    CGFloat padding = 2 * hoverInset + 2;
    CGFloat errorWidth = 0;
    if (diagnostic) {
        _error.attributedTitle = StyledText(viewErrorTitle, style.body, style.link);
        errorWidth = std::ceil(_error.attributedTitle.size.width) + 6;
    }
    CGFloat fixWidth = 0;
    if (quickFix) {
        _fixButton.attributedTitle = StyledText(quickFixTitle, style.body, style.link);
        fixWidth = std::ceil(_fixButton.attributedTitle.size.width) + 6;
    }
    BOOL stacked = quickFix && errorWidth + actionGap + fixWidth + padding > limit.width;
    CGFloat minimumWidth = diagnostic ? 165 : 64;
    if (quickFix)
        minimumWidth = std::max(minimumWidth, padding + (stacked ? std::max(errorWidth, fixWidth) : errorWidth + actionGap + fixWidth));
    CGFloat footer = diagnostic ? (stacked ? 2 : 1) * footerHeight : 0;
    _error.hidden = !diagnostic;
    _fixButton.hidden = !quickFix;
    NSRect measure = [text boundingRectWithSize:NSMakeSize(limit.width - padding, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin];
    CGFloat width = std::min(limit.width, std::max(minimumWidth, std::ceil(NSWidth(measure)) + padding + 2));
    CGFloat height = std::min(limit.height - footer, std::ceil(NSHeight(measure)) + 14);
    BOOL sameMessage = quickFix && !self.hidden && [text isEqualToAttributedString:_text.textStorage];
    NSPoint origin = sameMessage ? _scroll.contentView.bounds.origin : NSZeroPoint;
    _scroll.hasVerticalScroller = NO;
    _scroll.frame = NSMakeRect(1, 1, width - 2, height - 2);
    [_text setFrameSize:NSMakeSize(width - 2, height - 2)];
    if (!sameMessage) {
        [_text.textStorage setAttributedString:text];
        [_text setSelectedRange:NSMakeRange(0, 0)];
    }
    NSLayoutManager *layout = _text.layoutManager;
    [layout ensureLayoutForTextContainer:_text.textContainer];
    CGFloat content = std::ceil(NSHeight([layout usedRectForTextContainer:_text.textContainer])) + 2 * _text.textContainerInset.height;
    height = std::min(limit.height - footer, content + 2);
    _scroll.frame = NSMakeRect(1, 1, width - 2, height - 2);
    _scroll.hasVerticalScroller = content > height - 2;
    [_text setFrameSize:NSMakeSize(width - 2, std::max(content, height - 2))];
    [_scroll.contentView scrollToPoint:origin];
    [_scroll reflectScrolledClipView:_scroll.contentView];
    CGFloat linkWidth = std::min(width - padding, errorWidth);
    _error.frame = NSMakeRect(1 + hoverInset, height, linkWidth, footerHeight - 1);
    if (quickFix) {
        CGFloat x = stacked ? NSMinX(_error.frame) : NSMaxX(_error.frame) + actionGap;
        CGFloat y = stacked ? height + footerHeight : height;
        _fixButton.frame = NSMakeRect(x, y, std::min(fixWidth, width - x - hoverInset - 1), footerHeight - 1);
    }
    [self setNeedsDisplay:YES];
    [self.window invalidateCursorRectsForView:self];
    return NSMakeSize(width, height + footer);
}

- (NSSize)showDocumentation:(id)markup signature:(const SignatureLabel *)signature language:(Language)language
                       font:(NSFont *)font theme:(const Theme &)theme limit:(NSSize)limit
{
    if (signature && !self.hidden && [_signature.text isEqualToString:signature->text] &&
        NSEqualRanges(_signature.parameters, signature->parameters) && NSEqualRanges(_signature.active, signature->active) &&
        _signature.index == signature->index && _signature.count == signature->count &&
        (_signatureMarkup == markup || [_signatureMarkup isEqual:markup]) && NSEqualSizes(_signatureLimit, limit))
        return _signatureSize;

    HoverStyle style{theme, font};
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    if (signature) {
        AppendCode(text, BoundedHoverText(signature->text, hoverTextLimit), nil, language, style);
        NSRange length = NSMakeRange(0, text.length);
        NSRange parameters = NSIntersectionRange(signature->parameters, length);
        if (parameters.length)
            [text addAttribute:NSForegroundColorAttributeName value:style.muted range:parameters];

        NSRange active = NSIntersectionRange(signature->active, length);
        if (active.length) {
            [text addAttribute:NSForegroundColorAttributeName value:SRGBColor(style.colors.selectedText) range:active];
            [text addAttribute:NSBackgroundColorAttributeName value:SRGBColor(style.colors.selection) range:active];
        }

        if (signature->count > 1) {
            NSString *position = [NSString stringWithFormat:@"%lu/%lu  ", (unsigned long)signature->index + 1, (unsigned long)signature->count];
            [text insertAttributedString:StyledText(position, style.code, style.muted) atIndex:0];
        }
    }
    if (NSArray *parts = LSPArray(markup)) {
        for (id part in parts) {
            if (text.length >= hoverTextLimit)
                break;
            AppendMarkupPart(text, part, language, style);
        }
    } else if (text.length < hoverTextLimit) {
        AppendMarkupPart(text, markup, language, style);
    }
    NSSize size = [self showText:text diagnostic:NO quickFix:NO style:style limit:limit];
    NSString *source = LSPString(markup);
    if (!source)
        source = LSPString(LSPDict(markup)[@"value"]);
    bool cache = signature && signature->text.length <= hoverTextLimit && (!markup || (source && source.length <= hoverTextLimit));
    _signature = cache ? *signature : SignatureLabel{};
    _signatureMarkup = cache ? markup : nil;
    _signatureLimit = limit;
    _signatureSize = size;
    return size;
}

- (NSSize)showMessage:(NSString *)message diagnosticLabel:(NSString *)label showsQuickFix:(BOOL)quickFix
                 font:(NSFont *)font theme:(const Theme &)theme limit:(NSSize)limit
{
    _signature = {};
    _signatureMarkup = nil;
    HoverStyle style{theme, font};
    NSMutableAttributedString *text = [StyledText(BoundedHoverText(message, hoverTextLimit), font, style.text) mutableCopy];
    if (label.length)
        [text appendAttributedString:StyledText([@"  " stringByAppendingString:label], font, style.muted)];
    return [self showText:text diagnostic:YES quickFix:quickFix style:style limit:limit];
}

@end