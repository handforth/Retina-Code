#import "Typing.h"

#include <algorithm>
#include <array>

NSString *const EditorNonCodeAttribute = @"RetinaCodeNonCode";

struct Line {
    NSUInteger start;
    NSUInteger end;
    NSUInteger next;
};

static Line LineAt(NSString *text, NSUInteger offset)
{
    Line line;
    [text getLineStart:&line.start end:&line.next contentsEnd:&line.end forRange:NSMakeRange(offset, 0)];
    return line;
}

static bool Blank(unichar character)
{
    return character == ' ' || character == '\t';
}

static unichar At(NSString *text, NSUInteger offset)
{
    return offset < text.length ? [text characterAtIndex:offset] : 0;
}

static NSUInteger SkipIndent(NSString *text, NSUInteger from, NSUInteger end)
{
    while (from < end && Blank(At(text, from)))
        ++from;
    return from;
}

static NSString *LeadingIndent(NSString *text, Line line)
{
    return [text substringWithRange:NSMakeRange(line.start, SkipIndent(text, line.start, line.end) - line.start)];
}

static NSUInteger Column(NSString *text, NSUInteger start, NSUInteger end, NSUInteger tabWidth)
{
    NSUInteger column = 0;
    for (NSUInteger at = start; at < end;) {
        if (At(text, at) == '\t') {
            column += tabWidth - column % tabWidth;
            ++at;
        } else {
            ++column;
            at = At(text, at) < 128 && At(text, at + 1) < 128 ? at + 1 :
                 NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex:at]);
        }
    }
    return column;
}

std::vector<Vim::Range> CommentLineRanges(NSString *text, std::vector<Vim::Range> selections)
{
    NSUInteger length = text.length;
    std::erase_if(selections, [length](Vim::Range selection) {
        return selection.first > selection.last || selection.last > length;
    });
    for (auto &selection : selections) {
        // A selection ending at the next line's start stops before that line.
        auto first = LineAt(text, selection.first);
        auto last = LineAt(text, selection.empty() ? selection.first : selection.last - 1);
        selection = {first.start, last.end};
    }
    std::sort(selections.begin(), selections.end(), [](Vim::Range a, Vim::Range b) {
        return a.first < b.first;
    });
    size_t count = 0;
    for (auto selection : selections) {
        if (count && selection.first <= selections[count - 1].last)
            selections[count - 1].last = std::max(selections[count - 1].last, selection.last);
        else
            selections[count++] = selection;
    }
    selections.resize(count);
    return selections;
}

static bool CommentMarkerAt(NSString *text, NSUInteger at, NSUInteger end, Vim::Text marker)
{
    if (marker.size() > end - at)
        return false;
    for (char16_t character : marker) {
        if (At(text, at++) != character)
            return false;
    }
    return true;
}

static void AppendBlockCommentEdits(NSString *text, Vim::Range lines, Vim::Comments comments,
                                   std::vector<Vim::CursorEdit> &edits)
{
    auto first = LineAt(text, lines.first);
    NSUInteger start = SkipIndent(text, first.start, first.end);
    NSUInteger end = lines.last;
    while (end > start && Blank(At(text, end - 1)))
        --end;
    if (end - start >= comments.open.size() + comments.close.size() &&
        CommentMarkerAt(text, start, end, comments.open) &&
        CommentMarkerAt(text, end - comments.close.size(), end, comments.close)) {
        NSUInteger left = start + comments.open.size();
        NSUInteger right = end - comments.close.size();
        if (left < right && At(text, left) == ' ')
            ++left;
        if (right > left && At(text, right - 1) == ' ')
            --right;
        edits.push_back({{start, left}, {}});
        edits.push_back({{right, end}, {}});
    } else if (start == lines.last) {
        edits.push_back({{start, start}, std::u16string(comments.open) + u"  " + std::u16string(comments.close)});
    } else {
        edits.push_back({{start, start}, std::u16string(comments.open) + u" "});
        edits.push_back({{lines.last, lines.last}, u" " + std::u16string(comments.close)});
    }
}

void AppendLineCommentEdits(NSString *text, Vim::Range lines, Vim::Comments comments, const Indentation &indentation,
                            std::vector<Vim::CursorEdit> &edits)
{
    if (comments.line.empty()) {
        if (!comments.open.empty() && !comments.close.empty())
            AppendBlockCommentEdits(text, lines, comments, edits);
        return;
    }

    NSUInteger indent = NSNotFound;
    NSUInteger blankIndent = NSNotFound;
    bool remove = true;
    for (Line line = LineAt(text, lines.first);; line = LineAt(text, line.next)) {
        NSUInteger first = SkipIndent(text, line.start, line.end);
        NSUInteger column = Column(text, line.start, first, indentation.tabWidth);
        if (first == line.end) {
            blankIndent = std::min(blankIndent, column);
        } else {
            indent = std::min(indent, column);
            remove = remove && CommentMarkerAt(text, first, line.end, comments.line);
        }
        if (line.end == lines.last)
            break;
    }

    bool onlyBlank = indent == NSNotFound;
    if (onlyBlank) {
        indent = blankIndent;
        remove = false;
    }
    indent -= indent % indentation.width;
    std::u16string prefix = std::u16string(comments.line) + u" ";
    for (Line line = LineAt(text, lines.first);; line = LineAt(text, line.next)) {
        NSUInteger first = SkipIndent(text, line.start, line.end);
        if (first < line.end || onlyBlank) {
            if (remove) {
                NSUInteger end = first + comments.line.size();
                if (end < line.end && At(text, end) == ' ')
                    ++end;
                edits.push_back({{first, end}, {}});
            } else {
                NSUInteger at = line.start;
                NSUInteger column = 0;
                while (at < first && column < indent) {
                    NSUInteger step = At(text, at) == '\t' ? indentation.tabWidth - column % indentation.tabWidth : 1;
                    if (step > indent - column)
                        break;
                    column += step;
                    ++at;
                }
                edits.push_back({{at, at}, prefix});
            }
        }
        if (line.end == lines.last)
            break;
    }
}

static NSString *Spaces(NSUInteger count)
{
    return [@"" stringByPaddingToLength:count withString:@" " startingAtIndex:0];
}

static NSString *MakeIndent(NSUInteger columns, const Indentation &style)
{
    if (!style.tabs)
        return Spaces(columns);
    NSString *tabs = [@"" stringByPaddingToLength:columns / style.tabWidth withString:@"\t" startingAtIndex:0];
    return [tabs stringByAppendingString:Spaces(columns % style.tabWidth)];
}

static NSString *AddIndent(NSString *existing, const Indentation &style)
{
    NSUInteger column = Column(existing, 0, existing.length, style.tabWidth);
    return MakeIndent(column + style.width - column % style.width, style);
}

static NSString *NormalizeIndent(NSString *text, const Indentation &style)
{
    NSUInteger end = SkipIndent(text, 0, text.length);
    if (!end)
        return text;
    NSString *indent = MakeIndent(Column(text, 0, end, style.tabWidth), style);
    return end == text.length ? indent : [indent stringByAppendingString:[text substringFromIndex:end]];
}

Indentation DetectIndentation(NSString *text, Indentation fallback)
{
    NSUInteger limit = std::min<NSUInteger>(65536, text.length);
    std::array<unsigned, 9> widths{};
    NSUInteger previous = 0;
    unsigned withTabs = 0;
    unsigned withSpaces = 0;
    for (NSUInteger offset = 0; offset < limit;) {
        Line line = LineAt(text, offset);
        NSUInteger first = SkipIndent(text, offset, std::min(line.end, limit));
        if (first < line.end && first < limit && At(text, first) != '*') {
            if (At(text, offset) == '\t') {
                ++withTabs;
            } else {
                NSUInteger count = first - offset;
                withSpaces += count != 0;
                if (count > previous && count - previous >= 2 && count - previous < widths.size())
                    ++widths[count - previous];
                previous = count;
            }
        }
        offset = line.next;
    }
    if (!withTabs && !withSpaces)
        return fallback;
    fallback.tabs = withTabs > withSpaces;
    if (!fallback.tabs) {
        NSUInteger best = Indentation{}.width;
        if (fallback.width < widths.size() && widths[fallback.width] >= widths[best])
            best = fallback.width;
        for (NSUInteger width = 2; width < widths.size(); ++width) {
            if (widths[width] > widths[best])
                best = width;
        }
        if (widths[best])
            fallback.tabWidth = fallback.width = best;
    }
    return fallback;
}

static NSString *Newline(NSString *text, Line line)
{
    if (line.next > line.end)
        return [text substringWithRange:NSMakeRange(line.end, line.next - line.end)];
    if (line.start) {
        Line previous = LineAt(text, line.start - 1);
        if (previous.next > previous.end)
            return [text substringWithRange:NSMakeRange(previous.end, previous.next - previous.end)];
    }
    return @"\n";
}

static unichar CloseFor(unichar character)
{
    switch (character) {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        default: return 0;
    }
}

static unichar OpenFor(unichar character)
{
    switch (character) {
        case ')': return '(';
        case ']': return '[';
        case '}': return '{';
        default: return 0;
    }
}

static bool Quote(unichar character)
{
    return character == '"' || character == '\'' || character == 0x60;
}

bool MayCompleteCharacter(unichar character)
{
    return CloseFor(character) || OpenFor(character) || Quote(character) ||
           character == ':' || character == '<' || character == '>' || character == '#';
}

static bool CodeAt(NSAttributedString *storage, NSUInteger position)
{
    return position < storage.length && ![storage attribute:EditorNonCodeAttribute atIndex:position
                                             effectiveRange:nullptr];
}

static NSRange NextBracket(NSAttributedString *storage, NSRange range, bool backwards)
{
    static NSCharacterSet *const characters = [NSCharacterSet characterSetWithCharactersInString:@"()[]{}"];
    NSString *text = storage.string;
    while (range.length) {
        NSStringCompareOptions options = backwards ? NSBackwardsSearch : 0;
        NSRange bracket = [text rangeOfCharacterFromSet:characters options:options range:range];
        if (bracket.location == NSNotFound || CodeAt(storage, bracket.location))
            return bracket;
        NSRange literal;
        [storage attribute:EditorNonCodeAttribute atIndex:bracket.location effectiveRange:&literal];
        if (backwards) {
            if (literal.location <= range.location)
                break;
            range.length = literal.location - range.location;
        } else {
            NSUInteger end = NSMaxRange(range);
            range.location = std::min(end, NSMaxRange(literal));
            range.length = end - range.location;
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

static NSUInteger ScanBrackets(NSAttributedString *storage, NSUInteger start, bool backwards, unichar expected)
{
    NSString *text = storage.string;
    std::vector<unichar> nesting;
    if (expected)
        nesting.push_back(expected);
    NSRange remaining = backwards ? NSMakeRange(0, start) : NSMakeRange(start, text.length - start);
    while (remaining.length) {
        NSRange bracket = NextBracket(storage, remaining, backwards);
        if (bracket.location == NSNotFound)
            break;
        unichar character = At(text, bracket.location);
        unichar ends = backwards ? OpenFor(character) : CloseFor(character);
        if (ends) {
            nesting.push_back(ends);
        } else if (nesting.empty()) {
            return bracket.location;
        } else {
            if (nesting.back() != character)
                break;
            nesting.pop_back();
            if (nesting.empty() && expected)
                return bracket.location;
        }
        remaining = backwards ? NSMakeRange(0, bracket.location) :
                    NSMakeRange(NSMaxRange(bracket), text.length - NSMaxRange(bracket));
    }
    return NSNotFound;
}

static NSUInteger MatchingBracket(NSAttributedString *storage, NSUInteger position)
{
    if (!CodeAt(storage, position))
        return NSNotFound;
    unichar character = At(storage.string, position);
    if (auto close = CloseFor(character))
        return ScanBrackets(storage, position + 1, false, close);
    if (auto open = OpenFor(character))
        return ScanBrackets(storage, position, true, open);
    return NSNotFound;
}

BracketMatch BracketsAtSelection(NSAttributedString *storage, NSRange selection, bool preferUnderCursor)
{
    if (NSMaxRange(selection) > storage.length || selection.length > 1)
        return {};
    NSUInteger at = selection.location;
    if (selection.length == 1) {
        NSUInteger mate = MatchingBracket(storage, at);
        return mate == NSNotFound ? BracketMatch{} : BracketMatch{at, mate};
    }
    NSUInteger prior = at ? at - 1 : NSNotFound;
    std::array<NSUInteger, 2> positions = preferUnderCursor ? std::array{at, prior} : std::array{prior, at};
    for (NSUInteger candidate : positions) {
        NSUInteger mate = MatchingBracket(storage, candidate);
        if (mate != NSNotFound)
            return {candidate, mate};
    }
    return {};
}

static bool ShiftRange(NSRange &range, NSRange changed, NSUInteger newLength)
{
    if (NSMaxRange(changed) <= range.location) {
        range.location = range.location - changed.length + newLength;
        return true;
    }
    return changed.location >= NSMaxRange(range);
}

void AdjustTypedPairs(std::vector<TypedPair> &pairs, NSRange oldRange, NSUInteger newLength)
{
    std::erase_if(pairs, [&](TypedPair &pair) {
        return !ShiftRange(pair.opening, oldRange, newLength) || !ShiftRange(pair.closing, oldRange, newLength);
    });
}

static TypingEdit Edit(NSRange range, NSString *text, NSUInteger cursor, NSUInteger selected = 0)
{
    return {range, text, NSMakeRange(cursor, selected), {}, NSNotFound};
}

static NSString *Character(unichar character)
{
    return [NSString stringWithCharacters:&character length:1];
}

static bool Escaped(NSString *text, NSUInteger at)
{
    NSUInteger start = at;
    while (start && At(text, start - 1) == '\\')
        --start;
    return (at - start) % 2 != 0;
}

static bool IsWord(unichar character)
{
    return character == '_' || [NSCharacterSet.alphanumericCharacterSet characterIsMember:character];
}

static bool IsCStyle(Language language)
{
    return CFamily(language) || JavaScriptFamily(language) || language == Language::Rust ||
           language == Language::CSharp || language == Language::Java || language == Language::GML;
}

static NSString *CodePrefix(NSAttributedString *storage, Line line, NSUInteger end)
{
    NSString *text = storage.string;
    NSMutableString *code = [NSMutableString string];
    for (NSUInteger offset = line.start; offset < end;) {
        NSRange span;
        NSNumber *literal = [storage attribute:EditorNonCodeAttribute atIndex:offset effectiveRange:&span];
        NSUInteger next = std::min(NSMaxRange(span), end);
        if (!literal)
            [code appendString:[text substringWithRange:NSMakeRange(offset, next - offset)]];
        else if (literal.integerValue != NSInteger(Ink::Comment))
            [code appendString:@"_"];
        offset = next;
    }
    return [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSString *LispListIndent(NSString *text, Line line, NSUInteger opening, NSUInteger end, const Indentation &style)
{
    NSUInteger column = Column(text, line.start, opening, style.tabWidth);
    NSUInteger head = SkipIndent(text, opening + 1, end);
    NSUInteger headEnd = head;
    while (headEnd < end && IsLispSymbolPart(At(text, headEnd)))
        ++headEnd;
    if (head == headEnd)
        return MakeIndent(column + 1, style);

    NSString *form = [[text substringWithRange:NSMakeRange(head, headEnd - head)] lowercaseString];
    form = [form componentsSeparatedByString:@":"].lastObject;
    static NSSet<NSString *> *const bodyForms = [NSSet setWithArray:@[
        @"block", @"catch", @"defclass", @"defgeneric", @"defmacro", @"defmethod", @"defpackage", @"defstruct",
        @"defsystem", @"deftype", @"defun", @"destructuring-bind", @"do", @"do*", @"dolist", @"dotimes",
        @"eval-when", @"flet", @"handler-bind", @"handler-case", @"if", @"in-package", @"labels", @"lambda",
        @"let", @"let*", @"locally", @"loop", @"macrolet", @"multiple-value-bind", @"progn", @"unless",
        @"unwind-protect", @"when", @"with-input-from-string", @"with-open-file", @"with-output-to-string",
    ]];
    if ([bodyForms containsObject:form])
        return MakeIndent(column + style.width, style);

    NSUInteger argument = SkipIndent(text, headEnd, end);
    NSUInteger nextColumn = argument < end && At(text, argument) != ';' && At(text, argument) != ')' ?
        Column(text, line.start, argument, style.tabWidth) : column + 1;
    return MakeIndent(nextColumn, style);
}

static NSString *FirstWord(NSString *text)
{
    NSUInteger end = 0;
    while (IsWord(At(text, end)))
        ++end;
    NSString *word = [text substringToIndex:end];
    if ([word isEqualToString:@"async"]) {
        NSUInteger start = SkipIndent(text, end, text.length);
        end = start;
        while (IsWord(At(text, end)))
            ++end;
        return [text substringWithRange:NSMakeRange(start, end - start)];
    }
    return word;
}

static bool PythonHeader(NSString *code)
{
    static NSSet<NSString *> *const headers =
        [NSSet setWithArray:@[@"def", @"class", @"if", @"elif", @"else", @"for", @"while", @"try", @"except",
                              @"finally", @"with", @"match", @"case"]];
    return [headers containsObject:FirstWord(code)];
}

static bool CaseLabel(NSString *code)
{
    NSString *word = FirstWord(code);
    return [word isEqualToString:@"case"] || [word isEqualToString:@"default"];
}

static bool SingleStatementHeader(NSString *code)
{
    if ([code isEqualToString:@"else"] || [code isEqualToString:@"do"])
        return true;
    if ([code hasPrefix:@"else "])
        code = [[code substringFromIndex:5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (![code hasSuffix:@")"])
        return false;
    NSString *word = FirstWord(code);
    return [word isEqualToString:@"if"] || [word isEqualToString:@"for"] || [word isEqualToString:@"while"];
}

static NSString *PythonSuiteIndent(NSAttributedString *storage, Line line, NSUInteger end)
{
    NSString *code = CodePrefix(storage, line, end);
    if (![code hasSuffix:@":"])
        return nil;
    if (PythonHeader(code))
        return LeadingIndent(storage.string, line);
    // A header may start above the line containing its closing parenthesis and colon.
    NSRange bracket = NextBracket(storage, NSMakeRange(line.start, end - line.start), true);
    if (bracket.location != NSNotFound && OpenFor(At(storage.string, bracket.location))) {
        NSUInteger opening = MatchingBracket(storage, bracket.location);
        if (opening != NSNotFound && opening < line.start) {
            Line begin = LineAt(storage.string, opening);
            if (PythonHeader(CodePrefix(storage, begin, opening)))
                return LeadingIndent(storage.string, begin);
        }
    }
    return nil;
}

static NSString *IndentAfterStatement(NSAttributedString *storage, Line current, NSString *existing)
{
    NSString *text = storage.string;
    NSUInteger from = current.start;
    for (unsigned i = 0; from && i < 64; ++i) {
        Line above = LineAt(text, from - 1);
        NSString *code = CodePrefix(storage, above, above.end);
        if (!code.length) {
            from = above.start;
            continue;
        }
        NSString *indent = LeadingIndent(text, above);
        if (!SingleStatementHeader(code) || indent.length >= existing.length ||
            (indent.length && ![existing hasPrefix:indent]))
            break;
        existing = indent;
        from = above.start;
    }
    return existing;
}

static bool MarkupLanguage(Language language)
{
    return language == Language::HTML || language == Language::XML || language == Language::PHP ||
           language == Language::JSX || language == Language::TSX;
}

static NSString *OpeningTag(NSString *text, NSUInteger end)
{
    NSUInteger first = end > 4096 ? end - 4096 : 0;
    NSRange opening = [text rangeOfString:@"<" options:NSBackwardsSearch range:NSMakeRange(first, end - first)];
    if (opening.location == NSNotFound)
        return nil;
    NSUInteger start = opening.location + 1;
    NSUInteger name = start;
    while (name < end) {
        unichar ch = At(text, name);
        if (!IsWord(ch) && ch != ':' && ch != '-' && ch != '.')
            break;
        ++name;
    }
    if (name == start && start != end)
        return nil;
    if (name > start && !IsASCIIIdentifierStart(At(text, start)) && At(text, start) < 0x80)
        return nil;
    if (name == start && At(text, start) != '>' && start != end)
        return nil;
    NSUInteger tail = end;
    while (tail > name && Blank(At(text, tail - 1)))
        --tail;
    if (tail > name && At(text, tail - 1) == '/')
        return nil;
    // Skip terminators inside attribute values, including values containing a greater-than sign.
    unichar quote = 0;
    for (NSUInteger at = name; at < tail; ++at) {
        unichar ch = At(text, at);
        if (quote) {
            if (ch == quote)
                quote = 0;
        } else if (ch == '"' || ch == '\'') {
            quote = ch;
        } else if (ch == '>') {
            return nil;
        }
    }
    if (quote)
        return nil;
    return [text substringWithRange:NSMakeRange(start, name - start)];
}

static bool VoidHTMLTag(NSString *name, Language language)
{
    if (language != Language::HTML && language != Language::PHP)
        return false;
    static NSSet<NSString *> *const names = [NSSet setWithArray:@[@"area", @"base", @"br", @"col", @"embed",
        @"hr", @"img", @"input", @"link", @"meta", @"param", @"source", @"track", @"wbr"]];
    return [names containsObject:name.lowercaseString];
}

static bool StartsWithTagEnd(NSString *text, NSUInteger at, NSString *name, Language language)
{
    NSString *end = [NSString stringWithFormat:@"</%@>", name];
    if (end.length > text.length - at)
        return false;
    NSStringCompareOptions options = (language == Language::HTML || language == Language::PHP) ?
        NSCaseInsensitiveSearch : NSLiteralSearch;
    return [text compare:end options:options range:NSMakeRange(at, end.length)] == NSOrderedSame;
}

static bool WordSuffix(NSString *code, NSString *word)
{
    if (![code hasSuffix:word])
        return false;
    NSUInteger start = code.length - word.length;
    return !start || !IsWord(At(code, start - 1));
}

static bool StartsIndentedBlock(Language language, NSString *code)
{
    NSString *word = FirstWord(code);
    switch (language) {
        case Language::Ruby:
            return !WordSuffix(code, @"end") &&
                (WordSuffix(code, @"do") || [code containsString:@" do |"] ||
                 [@[@"begin", @"case", @"class", @"def", @"else", @"elsif", @"ensure", @"for",
                    @"if", @"module", @"rescue", @"unless", @"until", @"when", @"while"] containsObject:word]);
        case Language::Lua: case Language::Luau:
            return !WordSuffix(code, @"end") && (WordSuffix(code, @"then") || WordSuffix(code, @"do") ||
                [code hasPrefix:@"function "] || [code hasPrefix:@"local function "] ||
                [word isEqualToString:@"else"] || [word isEqualToString:@"repeat"]);
        case Language::Bash: case Language::Zsh:
            return WordSuffix(code, @"do") || WordSuffix(code, @"then") || [word isEqualToString:@"else"] ||
                   ([word isEqualToString:@"case"] && WordSuffix(code, @"in"));
        case Language::Fish:
            return [@[@"begin", @"case", @"else", @"for", @"function", @"if", @"switch", @"while"] containsObject:word];
        case Language::Julia:
            return !WordSuffix(code, @"end") && [@[@"begin", @"baremodule", @"catch", @"do", @"else", @"elseif",
                @"finally", @"for", @"function", @"if", @"let", @"macro", @"module", @"quote",
                @"struct", @"try", @"while"] containsObject:word];
        case Language::Elixir:
            return WordSuffix(code, @"do") || [code hasSuffix:@"->"] || [code isEqualToString:@"else"];
        case Language::CMake:
            return [code hasSuffix:@")"] && [@[@"if", @"elseif", @"else", @"foreach", @"while", @"function",
                @"macro", @"block"] containsObject:word.lowercaseString];
        default: return false;
    }
}

static bool ClosesIndentedBlock(Language language, NSString *code)
{
    NSString *word = FirstWord(code);
    switch (language) {
        case Language::Bash: case Language::Zsh:
            return [@[@"fi", @"done", @"esac"] containsObject:word];
        case Language::Ruby: case Language::Lua: case Language::Luau:
        case Language::Elixir: case Language::Fish: case Language::Julia:
            return [word isEqualToString:@"end"] || ((language == Language::Lua || language == Language::Luau) &&
                                                    [word isEqualToString:@"until"]);
        case Language::CMake:
            return [@[@"endif", @"endforeach", @"endwhile", @"endfunction", @"endmacro", @"endblock"]
                    containsObject:word.lowercaseString];
        default: return false;
    }
}

static NSString *OuterBlockIndent(NSAttributedString *storage, Line line, Language language)
{
    NSUInteger from = line.start;
    unsigned depth = 1;
    for (unsigned scanned = 0; from && scanned < 128; ++scanned) {
        Line above = LineAt(storage.string, from - 1);
        NSString *code = CodePrefix(storage, above, above.end);
        if (ClosesIndentedBlock(language, code)) {
            ++depth;
        } else if (StartsIndentedBlock(language, code)) {
            NSString *word = FirstWord(code);
            bool clause = [@[@"elif", @"elsif", @"elseif", @"else", @"rescue", @"ensure", @"catch", @"finally", @"when"]
                           containsObject:word];
            if (!clause && --depth == 0)
                return LeadingIndent(storage.string, above);
        }
        from = above.start;
    }
    return nil;
}

static bool TripleQuotedStrings(Language language, unichar quote)
{
    switch (language) {
        case Language::Python: case Language::TOML: case Language::Dart: case Language::Groovy:
        case Language::Elixir: case Language::FSharp:
            return true;
        case Language::CSharp: case Language::Java: case Language::Swift: case Language::Kotlin:
        case Language::Scala: case Language::Julia:
            return quote == '"';
        default: return false;
    }
}

static TypingEdit LineBreak(NSAttributedString *storage, Language language, const LexState &context,
                           const Indentation &style, NSRange selection)
{
    NSString *text = storage.string;
    NSUInteger at = selection.location;
    Line line = LineAt(text, at);
    NSString *newline = Newline(text, line);
    if (!style.automatic)
        return Edit(selection, newline, at + newline.length);

    NSString *indent = LeadingIndent(text, line);
    if (at < line.start + indent.length)
        indent = [text substringWithRange:NSMakeRange(line.start, at - line.start)];
    Line tail = LineAt(text, NSMaxRange(selection));
    NSUInteger next = SkipIndent(text, NSMaxRange(selection), tail.end);
    NSUInteger first = SkipIndent(text, line.start, at);
    if (language == Language::Makefile && next == tail.end && context.mode == LexMode::Code) {
        NSString *code = CodePrefix(storage, line, at);
        NSRange colon = [code rangeOfString:@":"];
        NSRange equals = [code rangeOfString:@"="];
        NSUInteger separator = colon.location;
        while (At(code, separator) == ':')
            ++separator;
        bool target = colon.location != NSNotFound && colon.location &&
                      (equals.location == NSNotFound || equals.location > separator);
        if ([indent hasPrefix:@"\t"] || (at > line.start && first == line.start && target)) {
            NSString *inserted = [newline stringByAppendingString:@"\t"];
            return Edit(selection, inserted, at + inserted.length);
        }
    }
    if (At(text, first) == '*' && At(text, first + 1) == '/' && first + 2 <= at &&
        !CodeAt(storage, first) && [indent hasSuffix:@" "])
        indent = [indent substringToIndex:indent.length - 1];
    if (context.mode == LexMode::BlockComment) {
        NSUInteger first = SkipIndent(text, line.start, line.end);
        bool opening = At(text, first) == '/' && At(text, first + 1) == '*';
        bool continuation = At(text, first) == '*';
        if (opening || continuation) {
            indent = NormalizeIndent(indent, style);
            NSString *margin = opening ? [indent stringByAppendingString:@" "] : indent;
            NSString *head = [NSString stringWithFormat:@"%@%@* ", newline, margin];
            if (At(text, next) == '*' && At(text, next + 1) == '/') {
                NSString *split = [NSString stringWithFormat:@"%@%@%@", head, newline, margin];
                return Edit(NSMakeRange(at, next - at), split, at + head.length);
            }
            if (opening && At(text, first + 2) == '*' && next == tail.end &&
                [text rangeOfString:@"*/" options:NSLiteralSearch
                              range:NSMakeRange(next, text.length - next)].location == NSNotFound) {
                NSString *split = [NSString stringWithFormat:@"%@%@%@*/", head, newline, margin];
                return Edit(selection, split, at + head.length);
            }
            return Edit(selection, head, at + head.length);
        }
    }

    if (context.mode == LexMode::LineComment && next < tail.end) {
        const auto prefix = InfoForLanguage(language).comments.line;
        if (!prefix.empty()) {
            NSString *marker = [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(prefix.data())
                                                           length:prefix.size()];
            if (first + marker.length <= at &&
                [text compare:marker options:NSLiteralSearch range:NSMakeRange(first, marker.length)] == NSOrderedSame)
                indent = [NSString stringWithFormat:@"%@%@ ", indent, marker];
        }
    }

    if (MarkupLanguage(language) && at > line.start && At(text, at - 1) == '>' &&
        (context.mode == LexMode::MarkupText || context.mode == LexMode::Code)) {
        NSString *tag = OpeningTag(text, at - 1);
        if (tag && !VoidHTMLTag(tag, language)) {
            NSString *inner = NormalizeIndent(AddIndent(indent, style), style);
            NSString *head = [newline stringByAppendingString:inner];
            if (StartsWithTagEnd(text, next, tag, language)) {
                NSString *split = [NSString stringWithFormat:@"%@%@%@", head, newline, NormalizeIndent(indent, style)];
                return Edit(NSMakeRange(at, next - at), split, at + head.length);
            }
            if (next == tail.end)
                return Edit(selection, head, at + head.length);
        }
    }
    if (language == Language::YAML && context.mode == LexMode::BlockScalar &&
        [CodePrefix(storage, line, at) hasSuffix:@"_"] && next == tail.end) {
        NSString *header = [text substringWithRange:NSMakeRange(first, at - first)];
        if ([header rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"|>"]].location != NSNotFound) {
            NSString *head = [newline stringByAppendingString:NormalizeIndent(AddIndent(indent, style), style)];
            return Edit(selection, head, at + head.length);
        }
    }

    if (context.mode == LexMode::Code || (context.mode == LexMode::LineComment && next == tail.end)) {
        NSUInteger opening = ScanBrackets(storage, at, true, 0);
        if (opening != NSNotFound) {
            Line begin = LineAt(text, opening);
            NSString *outer = LeadingIndent(text, begin);
            NSString *inner = AddIndent(outer, style);
            if (language == Language::CommonLisp) {
                outer = MakeIndent(Column(text, begin.start, opening, style.tabWidth), style);
                indent = LispListIndent(text, begin, opening, std::min(at, begin.end), style);
            } else if (Column(indent, 0, indent.length, style.tabWidth) < Column(inner, 0, inner.length, style.tabWidth)) {
                indent = inner;
            }
            if (begin.start == line.start && tail.start == line.start && next < tail.end &&
                CloseFor(At(text, opening)) == At(text, next) && CodeAt(storage, next)) {
                NSString *head = [newline stringByAppendingString:NormalizeIndent(indent, style)];
                NSString *split = [NSString stringWithFormat:@"%@%@%@", head, newline, NormalizeIndent(outer, style)];
                return Edit(NSMakeRange(at, next - at), split, at + head.length);
            }
        }

        NSString *code = CodePrefix(storage, line, at);
        if (language == Language::Python && (opening == NSNotFound || LineAt(text, opening).start != line.start)) {
            if (NSString *suite = PythonSuiteIndent(storage, line, at))
                indent = AddIndent(suite, style);
        } else if (language == Language::YAML && [code hasSuffix:@":"]) {
            indent = AddIndent(indent, style);
        } else if (opening == NSNotFound && ClosesIndentedBlock(language, code) && next == tail.end) {
            NSString *outer = OuterBlockIndent(storage, line, language);
            if (outer && [indent isEqualToString:AddIndent(outer, style)]) {
                NSString *body = [text substringWithRange:NSMakeRange(first, at - first)];
                NSString *replacement = [NSString stringWithFormat:@"%@%@%@%@", outer, body, newline, outer];
                return Edit(NSMakeRange(line.start, at - line.start), replacement, line.start + replacement.length);
            }
        } else if (opening == NSNotFound && StartsIndentedBlock(language, code)) {
            indent = AddIndent(indent, style);
        } else if (IsCStyle(language)) {
            if ([code hasSuffix:@":"] && CaseLabel(code)) {
                indent = AddIndent(indent, style);
            } else if (SingleStatementHeader(code) && language != Language::Rust) {
                indent = AddIndent(indent, style);
            } else if ([code hasSuffix:@";"] && language != Language::Rust) {
                indent = IndentAfterStatement(storage, line, indent);
            }
        }
    }

    NSRange replaced = selection;
    if (context.mode == LexMode::Code && tail.start == line.start)
        replaced.length = next - at;
    NSString *inserted = [newline stringByAppendingString:NormalizeIndent(indent, style)];
    return Edit(replaced, inserted, at + inserted.length);
}

static std::optional<TypingEdit> Backspace(NSAttributedString *storage, const Indentation &style,
                                           const std::vector<TypedPair> &pairs, NSRange selection)
{
    if (selection.length || !selection.location)
        return std::nullopt;
    NSUInteger at = selection.location;
    for (const auto &pair : pairs) {
        if (NSMaxRange(pair.opening) == at && pair.closing.location == at)
            return Edit(NSMakeRange(pair.opening.location, NSMaxRange(pair.closing) - pair.opening.location),
                        @"", pair.opening.location);
    }
    NSString *text = storage.string;
    Line line = LineAt(text, at);
    if (at <= line.start || SkipIndent(text, line.start, at) != at)
        return std::nullopt;
    NSUInteger column = Column(text, line.start, at, style.tabWidth);
    NSUInteger stop = (column - 1) / style.width * style.width;
    NSString *indent = MakeIndent(stop, style);
    return Edit(NSMakeRange(line.start, at - line.start), indent, line.start + indent.length);
}

static TypingEdit ShiftIndent(NSString *text, NSRange selection, const Indentation &style, bool right)
{
    Line first = LineAt(text, selection.location);
    Line last = LineAt(text, selection.length ? NSMaxRange(selection) - 1 : selection.location);
    NSMutableString *reformatted = [NSMutableString string];
    NSInteger delta = 0;
    NSUInteger start = selection.location;
    NSUInteger end = NSMaxRange(selection);
    for (NSUInteger offset = first.start;;) {
        Line line = LineAt(text, offset);
        NSUInteger indentEnd = SkipIndent(text, line.start, line.end);
        NSUInteger column = Column(text, line.start, indentEnd, style.tabWidth);
        NSUInteger width = right ? column + style.width - column % style.width :
                           column ? (column - 1) / style.width * style.width : 0;
        NSString *indent = MakeIndent(width, style);
        auto adjust = [&](NSUInteger position) -> NSUInteger {
            return NSUInteger(NSInteger(indentEnd <= position ? position - (indentEnd - line.start) + indent.length :
                                       line.start + std::min(position - line.start, indent.length)) + delta);
        };
        if (selection.location >= line.start && (selection.location < line.next || line.start == last.start))
            start = adjust(selection.location);
        if (NSMaxRange(selection) >= line.start && (NSMaxRange(selection) < line.next || line.start == last.start))
            end = adjust(NSMaxRange(selection));
        [reformatted appendString:indent];
        [reformatted appendString:[text substringWithRange:NSMakeRange(indentEnd, line.next - indentEnd)]];
        delta += NSInteger(indent.length) - NSInteger(indentEnd - line.start);
        if (line.start == last.start)
            break;
        offset = line.next;
    }
    return Edit(NSMakeRange(first.start, last.next - first.start), reformatted, start, end - start);
}

static NSUInteger PreviousIndentColumn(NSString *text, NSUInteger lineStart, NSUInteger tabWidth)
{
    // These are spaces, tabs, and the line endings recognized by LineAt.
    static NSCharacterSet *content = [[NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\u0085\u2028\u2029"] invertedSet];
    NSRange last = [text rangeOfCharacterFromSet:content options:NSBackwardsSearch range:NSMakeRange(0, lineStart)];
    if (last.location == NSNotFound)
        return 0;
    Line previous = LineAt(text, last.location);
    NSUInteger end = SkipIndent(text, previous.start, previous.end);
    return Column(text, previous.start, end, tabWidth);
}

static TypingEdit Tab(NSString *text, NSRange selection, const Indentation &style)
{
    if (selection.length)
        return ShiftIndent(text, selection, style, true);
    NSUInteger at = selection.location;
    Line line = LineAt(text, at);
    if (style.automatic && line.start) {
        NSUInteger end = SkipIndent(text, line.start, line.end);
        if (at <= end) {
            NSUInteger target = PreviousIndentColumn(text, line.start, style.tabWidth);
            if (target && target > Column(text, line.start, end, style.tabWidth)) {
                NSString *indent = MakeIndent(target, style);
                return Edit(NSMakeRange(line.start, end - line.start), indent, line.start + indent.length);
            }
        }
    }
    NSUInteger column = Column(text, line.start, at, style.tabWidth);
    NSUInteger toStop = style.width - column % style.width;
    NSString *inserted = style.tabs && (style.tabWidth - column % style.tabWidth) == toStop ? @"\t" : Spaces(toStop);
    return Edit(selection, inserted, at + inserted.length);
}

static bool IncludeDirective(NSAttributedString *storage, NSUInteger at)
{
    NSString *line = CodePrefix(storage, LineAt(storage.string, at), at);
    if (![line hasPrefix:@"#"])
        return false;
    line = [[line substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return [line isEqualToString:@"include"] || [line isEqualToString:@"include_next"] || [line isEqualToString:@"import"];
}

static NSUInteger RustRawHashes(NSString *text, NSUInteger at)
{
    NSUInteger start = at;
    while (start && At(text, start - 1) == '#')
        --start;
    if (!start || At(text, start - 1) != 'r')
        return 0;
    NSUInteger prefix = start - 1;
    if (prefix && (At(text, prefix - 1) == 'b' || At(text, prefix - 1) == 'c'))
        --prefix;
    return prefix && IsWord(At(text, prefix - 1)) ? 0 : at - start;
}

static bool CanPairApostrophe(NSString *text, NSUInteger at, Language language)
{
    unichar prior = at ? At(text, at - 1) : 0;
    if (language == Language::Rust) {
        if (prior == 'b' && (at < 2 || !IsWord(At(text, at - 2))))
            return true;
        Line line = LineAt(text, at);
        while (at > line.start && Blank(At(text, at - 1)))
            --at;
        return at > line.start && [@"=([," rangeOfString:Character(At(text, at - 1))].location != NSNotFound;
    }
    return !IsWord(prior) || language == Language::Python || CFamily(language);
}

static std::optional<TypingEdit> AlignColon(NSAttributedString *storage, Language language,
                                            const Indentation &style, NSRange selection)
{
    NSString *text = storage.string;
    NSUInteger at = selection.location;
    Line line = LineAt(text, at);
    if (SkipIndent(text, at, line.end) != line.end)
        return std::nullopt;
    NSString *indent = LeadingIndent(text, line);
    if (!indent.length)
        return std::nullopt;
    NSString *code = CodePrefix(storage, line, at);
    NSString *aligned = nil;
    bool odinCase = language == Language::Odin && [FirstWord(code) isEqualToString:@"case"];
    if ((odinCase || (IsCStyle(language) && language != Language::Rust && CaseLabel(code))) &&
        [code rangeOfString:@"?"].location == NSNotFound && [code rangeOfString:@":"].location == NSNotFound) {
        NSUInteger brace = ScanBrackets(storage, line.start, true, 0);
        if (brace != NSNotFound && At(text, brace) == '{') {
            NSString *outer = LeadingIndent(text, LineAt(text, brace));
            aligned = odinCase ? outer : AddIndent(outer, style);
        }
    } else if (language == Language::Python && ScanBrackets(storage, at, true, 0) == NSNotFound) {
        NSString *clause = FirstWord(code);
        NSSet<NSString *> *headers = nil;
        if ([clause isEqualToString:@"elif"])
            headers = [NSSet setWithArray:@[@"if", @"elif"]];
        else if ([clause isEqualToString:@"else"])
            headers = [NSSet setWithArray:@[@"if", @"elif", @"for", @"while", @"try", @"except"]];
        else if ([clause isEqualToString:@"except"] || [clause isEqualToString:@"finally"])
            headers = [NSSet setWithArray:@[@"try", @"except", @"else"]];
        else if ([clause isEqualToString:@"case"])
            headers = [NSSet setWithArray:@[@"case", @"match"]];
        if (headers) {
            NSUInteger from = line.start;
            for (unsigned i = 0; from && i < 256; ++i) {
                Line above = LineAt(text, from - 1);
                NSString *header = CodePrefix(storage, above, above.end);
                NSString *word = FirstWord(header);
                NSString *prefix = LeadingIndent(text, above);
                if ((!prefix.length || [indent hasPrefix:prefix]) &&
                    [header hasSuffix:@":"] && [headers containsObject:word]) {
                    aligned = [word isEqualToString:@"match"] ? AddIndent(prefix, style) : prefix;
                    break;
                }
                from = above.start;
            }
        }
    }
    if (!aligned || [aligned isEqualToString:indent])
        return std::nullopt;
    NSString *body = [text substringWithRange:NSMakeRange(line.start + indent.length, at - line.start - indent.length)];
    NSString *replacement = [NSString stringWithFormat:@"%@%@:", aligned, body];
    return Edit(NSMakeRange(line.start, at - line.start), replacement, line.start + replacement.length);
}

static std::optional<TypingEdit> CompleteCharacter(NSAttributedString *storage, Language language,
                                                   const LexState &context, const Indentation &style,
                                                   const std::vector<TypedPair> &pairs, NSRange selection,
                                                   unichar character)
{
    NSString *text = storage.string;
    NSUInteger at = selection.location;
    if (language == Language::CommonLisp && (character == '[' || character == ']' || character == '{' || character == '}'))
        return std::nullopt;
    unichar next = At(text, at);
    bool inCode = context.mode == LexMode::Code;
    bool markupTag = context.mode == LexMode::MarkupTag;
    bool jsx = language == Language::JSX || language == Language::TSX;
    bool jsxBrace = jsx && character == '{' && (markupTag || context.mode == LexMode::MarkupText);
    bool backticks = JavaScriptFamily(language) || language == Language::Plain || language == Language::Go ||
        language == Language::Odin || language == Language::Luau || language == Language::Bash || language == Language::Zsh ||
        language == Language::Swift || language == Language::Kotlin || language == Language::SQL ||
        language == Language::Markdown;
    bool apostrophe = language != Language::JSON && language != Language::JSONC && language != Language::Swift &&
                      language != Language::VisualBasic && language != Language::Clojure && language != Language::CommonLisp;
    if (language == Language::GML)
        apostrophe = at && At(text, at - 1) == '@';
    bool quote = Quote(character) && (character != 0x60 || backticks) && (character != '\'' || apostrophe);

    if (character == '>' && !selection.length && markupTag && !context.markup.endTag &&
        (!next || Blank(next) || next == '<' || next == '\r' || next == '\n')) {
        NSString *name = OpeningTag(text, at);
        if (name && (name.length || jsx) && !VoidHTMLTag(name, language) &&
            !StartsWithTagEnd(text, at, name, language)) {
            NSString *ending = [NSString stringWithFormat:@"</%@>", name];
            auto edit = Edit(selection, [@">" stringByAppendingString:ending], at + 1);
            edit.pair = TypedPair{NSMakeRange(at, 1), NSMakeRange(at + 1, ending.length)};
            return edit;
        }
    }

    if (!selection.length && next == character && !(quote && Escaped(text, at))) {
        for (const auto &pair : pairs) {
            if (NSLocationInRange(at, pair.closing)) {
                TypingEdit passed = Edit(selection, nil, at + 1);
                passed.passedCloser = at;
                return passed;
            }
        }
    }

    if (!selection.length && inCode && style.automatic) {
        if (character == ':') {
            if (auto aligned = AlignColon(storage, language, style, selection))
                return aligned;
        } else if (auto open = OpenFor(character)) {
            Line line = LineAt(text, at);
            if (SkipIndent(text, line.start, at) == at) {
                NSUInteger mate = ScanBrackets(storage, at, true, 0);
                if (mate != NSNotFound && At(text, mate) == open) {
                    Line begin = LineAt(text, mate);
                    NSString *indent = language == Language::CommonLisp ?
                        MakeIndent(Column(text, begin.start, mate, style.tabWidth), style) : LeadingIndent(text, begin);
                    NSString *replacement = [indent stringByAppendingString:Character(character)];
                    NSUInteger end = at;
                    NSUInteger close = SkipIndent(text, at, line.end);
                    if (close == line.end && line.next > line.end) {
                        Line following = LineAt(text, line.next);
                        close = SkipIndent(text, following.start, following.end);
                    }
                    if (At(text, close) == character) {
                        for (const auto &pair : pairs) {
                            if (pair.opening.location == mate && pair.closing.location == close) {
                                end = close + 1;
                                break;
                            }
                        }
                    }
                    return Edit(NSMakeRange(line.start, end - line.start), replacement, line.start + replacement.length);
                }
            }
        }
    }

    bool header = character == '<' && CFamily(language) &&
                  inCode && IncludeDirective(storage, at);
    bool templateBrace = character == '{' && !inCode &&
        ((JavaScriptFamily(language) && context.closing == u"\x60" &&
          at && At(text, at - 1) == '$' && !Escaped(text, at - 1)) ||
         (language == Language::GML && context.interpolation == Interpolation::Braces && !Escaped(text, at)));
    unichar close = quote ? character : header ? '>' : CloseFor(character);
    if (!close)
        return std::nullopt;

    if (quote && TripleQuotedStrings(language, character) && !selection.length && inCode && at >= 2 &&
        At(text, at - 1) == character && At(text, at - 2) == character &&
        (at < 3 || At(text, at - 3) != character) && next != character && !Escaped(text, at - 2)) {
        NSString *four = [@"" stringByPaddingToLength:4 withString:Character(character) startingAtIndex:0];
        auto triple = Edit(selection, four, at + 1);
        triple.pair = TypedPair{NSMakeRange(at - 2, 3), NSMakeRange(at + 1, 3)};
        return triple;
    }

    if (!selection.length) {
        if (!inCode && !templateBrace && !jsxBrace && !(quote && markupTag && context.markup.part == TagPart::Value))
            return std::nullopt;
        if (next && ![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:next] &&
            [@";:.,=)}]>\"'\x60" rangeOfString:Character(next)].location == NSNotFound)
            return std::nullopt;
        if (quote && (Escaped(text, at) || (character == '\'' && !CanPairApostrophe(text, at, language))))
            return std::nullopt;
        if (CloseFor(character) && !templateBrace && !jsxBrace && next == close && CodeAt(storage, at) &&
            MatchingBracket(storage, at) == NSNotFound)
            return std::nullopt;
    }

    NSString *inside = selection.length ? [text substringWithRange:selection] : @"";
    NSUInteger hashes = language == Language::Rust && character == '"' ? RustRawHashes(text, at) : 0;
    if (hashes > 255)
        return std::nullopt;
    NSString *ending = Character(close);
    if (hashes)
        ending = [ending stringByPaddingToLength:hashes + 1 withString:@"#" startingAtIndex:0];
    NSString *replacement = [NSString stringWithFormat:@"%@%@%@", Character(character), inside, ending];
    auto paired = Edit(selection, replacement, at + 1, selection.length);
    paired.pair = TypedPair{NSMakeRange(at, 1), NSMakeRange(at + 1 + inside.length, ending.length)};
    return paired;
}

std::optional<TypingEdit> PlanTyping(NSAttributedString *storage, Language language, const LexState &context,
                                     const Indentation &style, const std::vector<TypedPair> &pairs,
                                     NSRange selection, TypingKey key, unichar character)
{
    if (selection.location == NSNotFound || NSMaxRange(selection) > storage.length)
        return std::nullopt;
    language = LanguageInContext(language, context);
    switch (key) {
        case TypingKey::Enter:
            return LineBreak(storage, language, context, style, selection);
        case TypingKey::Backspace:
            return Backspace(storage, style, pairs, selection);
        case TypingKey::Tab:
            return Tab(storage.string, selection, style);
        case TypingKey::Backtab:
            return ShiftIndent(storage.string, selection, style, false);
        case TypingKey::Character:
            return CompleteCharacter(storage, language, context, style, pairs, selection, character);
    }
    return std::nullopt;
}