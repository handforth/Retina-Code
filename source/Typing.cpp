#include "Typing.hpp"

#include <array>
#include <utility>

static constexpr auto missing = typingNotFound;

static CommentLine LineAt(const TypingSource &text, size_t at)
{
    return text.line(text.context, at);
}

static bool Blank(char16_t ch)
{
    return ch == u' ' || ch == u'\t';
}

static bool UnicodeWhitespace(char16_t ch)
{
    return ch == u' ' || (ch >= u'\t' && ch <= u'\r') || ch == 0x85 || ch == 0xA0 || ch == 0x1680 ||
           (ch >= 0x2000 && ch <= 0x200A) || ch == 0x2028 || ch == 0x2029 ||
           ch == 0x202F || ch == 0x205F || ch == 0x3000;
}

static bool Word(const TypingSource &text, char16_t ch)
{
    return (is_ascii_identifier_char(ch) && ch != u'$') || (ch >= 0x80 && text.alphanumeric(ch));
}

static size_t SkipIndent(const TypingSource &text, size_t from, size_t end)
{
    while (from < end && Blank(text.at(from)))
        ++from;
    return from;
}

static std::u16string Slice(const TypingSource &text, size_t first, size_t end)
{
    std::u16string result;
    text.append(text.context, result, {first, end - first});
    return result;
}

static std::u16string LeadingIndent(const TypingSource &text, CommentLine line)
{
    return Slice(text, line.start, SkipIndent(text, line.start, line.end));
}

static size_t Column(const TypingSource &text, size_t at, size_t end, size_t tabWidth)
{
    size_t column = 0;
    while (at < end) {
        if (text.at(at) == u'\t') {
            column += tabWidth - column % tabWidth;
            ++at;
        } else {
            ++column;
            at = text.at(at) < 128 && text.at(at + 1) < 128 ? at + 1 : text.graphemeEnd(text.context, at);
        }
    }
    return column;
}

static size_t IndentColumn(std::u16string_view indent, size_t tabWidth)
{
    size_t column = 0;
    for (char16_t ch : indent)
        column += ch == u'\t' ? tabWidth - column % tabWidth : 1;
    return column;
}

static std::u16string MakeIndent(size_t column, const Indentation &style)
{
    if (!style.tabs)
        return std::u16string(column, u' ');
    std::u16string result(column / style.tabWidth, u'\t');
    result.append(column % style.tabWidth, u' ');
    return result;
}

static std::u16string AddIndent(std::u16string_view indent, const Indentation &style)
{
    const auto column = IndentColumn(indent, style.tabWidth);
    return MakeIndent(column + style.width - column % style.width, style);
}

static std::u16string NormalizeIndent(std::u16string_view text, const Indentation &style)
{
    size_t end = 0;
    while (end < text.size() && Blank(text[end]))
        ++end;
    std::u16string indent = MakeIndent(IndentColumn(text.substr(0, end), style.tabWidth), style);
    indent += text.substr(end);
    return indent;
}

Indentation DetectTypingIndentation(const TypingSource &text, Indentation fallback)
{
    const size_t limit = std::min<size_t>(65536, text.length);
    std::array<unsigned, 9> widths{};
    size_t previous = 0;
    unsigned withTabs = 0, withSpaces = 0;
    for (size_t at = 0; at < limit;) {
        const auto line = LineAt(text, at);
        const auto first = SkipIndent(text, at, std::min(line.end, limit));
        if (first < line.end && first < limit && text.at(first) != u'*') {
            if (text.at(at) == u'\t') {
                ++withTabs;
            } else {
                const auto count = first - at;
                withSpaces += count != 0;
                if (count > previous && count - previous >= 2 && count - previous < widths.size())
                    ++widths[count - previous];
                previous = count;
            }
        }
        at = line.next;
    }
    if (!withTabs && !withSpaces)
        return fallback;
    fallback.tabs = withTabs > withSpaces;
    if (!fallback.tabs) {
        size_t best = Indentation{}.width;
        if (fallback.width < widths.size() && widths[fallback.width] >= widths[best])
            best = fallback.width;
        for (size_t width = 2; width < widths.size(); ++width)
            if (widths[width] > widths[best])
                best = width;
        if (widths[best])
            fallback.tabWidth = fallback.width = best;
    }
    return fallback;
}

static std::u16string Newline(const TypingSource &text, CommentLine line)
{
    if (line.next > line.end)
        return Slice(text, line.end, line.next);
    if (line.start) {
        const auto previous = LineAt(text, line.start - 1);
        if (previous.next > previous.end)
            return Slice(text, previous.end, previous.next);
    }
    return u"\n";
}

static bool CodeAt(const TypingSource &text, size_t position)
{
    return position < text.length && text.syntax(text.context, position).role == Ink::Text;
}

size_t NextTypingBracket(const TypingSource &text, TypingRange range, bool backwards)
{
    while (range.length) {
        const auto bracket = text.find(text.context, range, TypingSearch::Bracket, backwards);
        if (bracket == missing)
            break;
        const auto span = text.syntax(text.context, bracket);
        if (span.role == Ink::Text)
            return bracket;
        if (backwards) {
            if (span.range.location <= range.location)
                break;
            range.length = span.range.location - range.location;
        } else {
            const auto end = range.end();
            range.location = std::min(end, span.range.end());
            range.length = end - range.location;
        }
    }
    return missing;
}

static size_t ScanBrackets(const TypingSource &text, size_t start, bool backwards, char16_t expected = 0)
{
    std::u16string nesting;
    if (expected)
        nesting += expected;
    TypingRange remaining = backwards ? TypingRange{0, start} : TypingRange{start, text.length - start};
    while (remaining.length) {
        const auto bracket = NextTypingBracket(text, remaining, backwards);
        if (bracket == missing)
            break;
        const auto ch = text.at(bracket);
        if (const auto other = backwards ? TypingOpenFor(ch) : TypingCloseFor(ch)) {
            nesting += other;
        } else if (nesting.empty()) {
            return bracket;
        } else {
            if (nesting.back() != ch)
                break;
            nesting.pop_back();
            if (nesting.empty() && expected)
                return bracket;
        }
        remaining = backwards ? TypingRange{0, bracket} : TypingRange{bracket + 1, text.length - bracket - 1};
    }
    return missing;
}

size_t MatchingTypingBracket(const TypingSource &text, size_t position)
{
    const auto ch = text.at(position);
    const auto close = TypingCloseFor(ch), open = TypingOpenFor(ch);
    if ((!close && !open) || !CodeAt(text, position))
        return missing;
    return close ? ScanBrackets(text, position + 1, false, close) : ScanBrackets(text, position, true, open);
}

BracketMatch BracketsAtSelection(const TypingSource &text, TypingRange selection, bool preferUnderCursor)
{
    const auto at = selection.location;
    if (at > text.length || selection.length > 1 || selection.length > text.length - at)
        return {};
    if (selection.length) {
        const auto mate = MatchingTypingBracket(text, at);
        return mate == missing ? BracketMatch{} : BracketMatch{at, mate};
    }
    const auto previous = at ? at - 1 : missing;
    const auto candidates = preferUnderCursor ? std::array{at, previous} : std::array{previous, at};
    for (auto candidate : candidates) {
        const auto mate = MatchingTypingBracket(text, candidate);
        if (mate != missing)
            return {candidate, mate};
    }
    return {};
}

void RememberTypedPair(std::vector<TypedPair> &pairs, const std::optional<TypedPair> &pair,
                       size_t passedCloser, size_t length)
{
    if (passedCloser != missing)
        std::erase_if(pairs, [=](const TypedPair &item) { return passedCloser == item.closing.end() - 1; });
    if (pair && pair->closing.end() <= length) {
        if (pairs.size() >= typedPairLimit)
            pairs.erase(pairs.begin());
        pairs.push_back(*pair);
    }
}

static TypingPlan Edit(TypingRange range, std::u16string text, size_t cursor, size_t selected = 0)
{
    return {range, std::move(text), {cursor, selected}, {}, missing};
}

static bool Escaped(const TypingSource &text, size_t at)
{
    auto start = at;
    while (start && text.at(start - 1) == u'\\')
        --start;
    return (at - start) % 2 != 0;
}

static bool IsCStyle(Language language)
{
    return is_c_family(language) || is_javascript_family(language) || language == Language::Rust ||
           language == Language::CSharp || language == Language::Java || language == Language::GML;
}

static std::u16string_view Trim(std::u16string_view text)
{
    while (!text.empty() && UnicodeWhitespace(text.front()))
        text.remove_prefix(1);
    while (!text.empty() && UnicodeWhitespace(text.back()))
        text.remove_suffix(1);
    return text;
}

static std::u16string_view CodePrefix(const TypingSource &text, CommentLine line, size_t end, std::u16string &code)
{
    code.clear();
    for (size_t at = line.start; at < end;) {
        const auto span = text.syntax(text.context, at);
        const auto next = std::min(span.range.end(), end);
        if (span.role == Ink::Text)
            text.append(text.context, code, {at, next - at});
        else if (span.role != Ink::Comment)
            code += u'_';
        at = next;
    }
    return Trim(code);
}

template<size_t N>
static bool OneOf(std::u16string_view word, const char16_t *const (&choices)[N])
{
    return std::ranges::any_of(choices, [=](std::u16string_view candidate) { return word == candidate; });
}

static char16_t LowerASCII(char16_t ch)
{
    return ch >= u'A' && ch <= u'Z' ? ch + (u'a' - u'A') : ch;
}

static bool EqualIgnoringCase(std::u16string_view a, std::u16string_view b)
{
    return std::ranges::equal(a, b, {}, LowerASCII, LowerASCII);
}

static std::u16string_view FirstWord(const TypingSource &text, std::u16string_view code)
{
    size_t start = 0, end = 0;
    while (end < code.size() && Word(text, code[end]))
        ++end;
    if (code.substr(0, end) == u"async") {
        while (end < code.size() && Blank(code[end]))
            ++end;
        start = end;
        while (end < code.size() && Word(text, code[end]))
            ++end;
    }
    return code.substr(start, end - start);
}

static size_t LispListColumn(const TypingSource &text, CommentLine line, size_t opening, size_t end, const Indentation &style)
{
    const auto column = Column(text, line.start, opening, style.tabWidth);
    const auto first = SkipIndent(text, opening + 1, end);
    auto head = first;
    auto headEnd = head;
    while (headEnd < end && is_lisp_symbol_char(text.at(headEnd))) {
        if (text.at(headEnd) == u':')
            head = headEnd + 1;
        ++headEnd;
    }
    if (first == headEnd)
        return column + 1;

    auto form = Slice(text, head, headEnd);
    std::ranges::transform(form, form.begin(), LowerASCII);
    if (OneOf(form, {u"block", u"catch", u"defclass", u"defgeneric", u"defmacro", u"defmethod", u"defpackage",
                     u"defstruct", u"defsystem", u"deftype", u"defun", u"destructuring-bind", u"do", u"do*",
                     u"dolist", u"dotimes", u"eval-when", u"flet", u"handler-bind", u"handler-case", u"if",
                     u"in-package", u"labels", u"lambda", u"let", u"let*", u"locally", u"loop", u"macrolet",
                     u"multiple-value-bind", u"progn", u"unless", u"unwind-protect", u"when",
                     u"with-input-from-string", u"with-open-file", u"with-output-to-string"}))
        return column + style.width;
    const auto argument = SkipIndent(text, headEnd, end);
    return argument < end && text.at(argument) != u';' && text.at(argument) != u')' ?
        Column(text, line.start, argument, style.tabWidth) : column + 1;
}

static bool PythonHeader(const TypingSource &text, std::u16string_view code)
{
    return OneOf(FirstWord(text, code), {u"def", u"class", u"if", u"elif", u"else", u"for", u"while", u"try",
                                         u"except", u"finally", u"with", u"match", u"case"});
}

static bool CaseLabel(const TypingSource &text, std::u16string_view code)
{
    return OneOf(FirstWord(text, code), {u"case", u"default"});
}

static bool SingleStatementHeader(const TypingSource &text, std::u16string_view code)
{
    if (code == u"else" || code == u"do")
        return true;
    if (code.starts_with(u"else "))
        code = Trim(code.substr(5));
    return code.ends_with(u")") && OneOf(FirstWord(text, code), {u"if", u"for", u"while"});
}

static std::optional<std::u16string> PythonSuiteIndent(const TypingSource &text, CommentLine line, size_t end, std::u16string_view code, std::u16string &scratch)
{
    if (!code.ends_with(u":"))
        return {};
    if (PythonHeader(text, code))
        return LeadingIndent(text, line);
    const auto bracket = NextTypingBracket(text, {line.start, end - line.start}, true);
    if (bracket != missing && TypingOpenFor(text.at(bracket))) {
        const auto opening = MatchingTypingBracket(text, bracket);
        if (opening != missing && opening < line.start) {
            const auto begin = LineAt(text, opening);
            if (PythonHeader(text, CodePrefix(text, begin, opening, scratch)))
                return LeadingIndent(text, begin);
        }
    }
    return {};
}

static void IndentAfterStatement(const TypingSource &text, CommentLine line, std::u16string &existing, std::u16string &scratch)
{
    for (unsigned i = 0; line.start && i < 64; ++i) {
        line = LineAt(text, line.start - 1);
        const auto code = CodePrefix(text, line, line.end, scratch);
        if (code.empty())
            continue;
        auto indent = LeadingIndent(text, line);
        if (!SingleStatementHeader(text, code) || indent.size() >= existing.size() || !existing.starts_with(indent))
            break;
        existing = std::move(indent);
    }
}

static bool MarkupLanguage(Language language)
{
    return language == Language::HTML || language == Language::XML || language == Language::PHP ||
           language == Language::JSX || language == Language::TSX;
}

static std::optional<TypingRange> OpeningTag(const TypingSource &text, size_t end)
{
    const size_t first = end > 4096 ? end - 4096 : 0;
    const auto opening = text.find(text.context, {first, end - first}, TypingSearch::TagStart, true);
    if (opening == missing)
        return {};
    const auto start = opening + 1;
    auto nameEnd = start;
    while (nameEnd < end) {
        const auto ch = text.at(nameEnd);
        if (!Word(text, ch) && ch != u':' && ch != u'-' && ch != u'.')
            break;
        ++nameEnd;
    }
    if (nameEnd == start && start != end)
        return {};
    if (nameEnd > start && !is_ascii_identifier_start(text.at(start)) && text.at(start) < 0x80)
        return {};
    auto tail = end;
    while (tail > nameEnd && Blank(text.at(tail - 1)))
        --tail;
    if (tail > nameEnd && text.at(tail - 1) == u'/')
        return {};
    char16_t quote = 0;
    for (auto at = nameEnd; at < tail; ++at) {
        const auto ch = text.at(at);
        if (quote) {
            if (ch == quote)
                quote = 0;
        } else if (ch == u'"' || ch == u'\'') {
            quote = ch;
        } else if (ch == u'>') {
            return {};
        }
    }
    if (quote)
        return {};
    return TypingRange{start, nameEnd - start};
}

static bool VoidHTMLTag(std::u16string_view name, Language language)
{
    if (language != Language::HTML && language != Language::PHP)
        return false;
    constexpr std::u16string_view names[] = {u"area", u"base", u"br", u"col", u"embed", u"hr", u"img", u"input", u"link", u"meta",
                              u"param", u"source", u"track", u"wbr"};
    return std::ranges::any_of(names, [=](std::u16string_view candidate) { return EqualIgnoringCase(name, candidate); });
}

static bool StartsWith(const TypingSource &text, size_t at, std::u16string_view expected, bool insensitive = false)
{
    if (expected.size() > text.length - at)
        return false;
    for (const auto ch : expected) {
        const auto actual = text.at(at++);
        if (insensitive ? LowerASCII(actual) != LowerASCII(ch) : actual != ch)
            return false;
    }
    return true;
}

static bool StartsWithTagEnd(const TypingSource &text, size_t at, std::u16string_view name, Language language)
{
    return StartsWith(text, at, u"</") &&
           StartsWith(text, at + 2, name, language == Language::HTML || language == Language::PHP) &&
           text.at(at + 2 + name.size()) == u'>';
}

static bool WordSuffix(const TypingSource &text, std::u16string_view code, std::u16string_view word)
{
    return code.ends_with(word) && (code.size() == word.size() || !Word(text, code[code.size() - word.size() - 1]));
}

static bool StartsIndentedBlock(const TypingSource &text, Language language, std::u16string_view code)
{
    const auto word = FirstWord(text, code);
    switch (language) {
        case Language::Ruby:
            return !WordSuffix(text, code, u"end") &&
                (WordSuffix(text, code, u"do") || code.find(u" do |") != code.npos ||
                 OneOf(word, {u"begin", u"case", u"class", u"def", u"else", u"elsif", u"ensure", u"for",
                              u"if", u"module", u"rescue", u"unless", u"until", u"when", u"while"}));
        case Language::Lua: case Language::Luau:
            return !WordSuffix(text, code, u"end") && (WordSuffix(text, code, u"then") || WordSuffix(text, code, u"do") ||
                code.starts_with(u"function ") || code.starts_with(u"local function ") || OneOf(word, {u"else", u"repeat"}));
        case Language::Bash: case Language::Zsh:
            return WordSuffix(text, code, u"do") || WordSuffix(text, code, u"then") || word == u"else" ||
                   (word == u"case" && WordSuffix(text, code, u"in"));
        case Language::Fish:
            return OneOf(word, {u"begin", u"case", u"else", u"for", u"function", u"if", u"switch", u"while"});
        case Language::Julia:
            return !WordSuffix(text, code, u"end") && OneOf(word, {u"begin", u"baremodule", u"catch", u"do", u"else",
                u"elseif", u"finally", u"for", u"function", u"if", u"let", u"macro", u"module", u"quote",
                u"struct", u"try", u"while"});
        case Language::Elixir:
            return WordSuffix(text, code, u"do") || code.ends_with(u"->") || code == u"else";
        case Language::CMake: {
            constexpr std::u16string_view names[] = {u"if", u"elseif", u"else", u"foreach", u"while", u"function", u"macro", u"block"};
            return code.ends_with(u")") && std::ranges::any_of(names, [=](std::u16string_view name) { return EqualIgnoringCase(word, name); });
        }
        default: return false;
    }
}

static bool ClosesIndentedBlock(const TypingSource &text, Language language, std::u16string_view code)
{
    const auto word = FirstWord(text, code);
    switch (language) {
        case Language::Bash: case Language::Zsh:
            return OneOf(word, {u"fi", u"done", u"esac"});
        case Language::Ruby: case Language::Lua: case Language::Luau:
        case Language::Elixir: case Language::Fish: case Language::Julia:
            return word == u"end" || ((language == Language::Lua || language == Language::Luau) && word == u"until");
        case Language::CMake: {
            constexpr std::u16string_view names[] = {u"endif", u"endforeach", u"endwhile", u"endfunction", u"endmacro", u"endblock"};
            return std::ranges::any_of(names, [=](std::u16string_view name) { return EqualIgnoringCase(word, name); });
        }
        default: return false;
    }
}

static std::optional<std::u16string> OuterBlockIndent(const TypingSource &text, CommentLine line, Language language, std::u16string &scratch)
{
    unsigned depth = 1;
    for (unsigned scanned = 0; line.start && scanned < 128; ++scanned) {
        line = LineAt(text, line.start - 1);
        const auto code = CodePrefix(text, line, line.end, scratch);
        if (ClosesIndentedBlock(text, language, code)) {
            ++depth;
        } else if (StartsIndentedBlock(text, language, code)) {
            const auto word = FirstWord(text, code);
            if (!OneOf(word, {u"elif", u"elsif", u"elseif", u"else", u"rescue", u"ensure", u"catch", u"finally", u"when"}) &&
                --depth == 0)
                return LeadingIndent(text, line);
        }
    }
    return {};
}

static bool TripleQuotedStrings(Language language, char16_t quote)
{
    switch (language) {
        case Language::Python: case Language::TOML: case Language::Dart: case Language::Groovy:
        case Language::Elixir: case Language::FSharp:
            return true;
        case Language::CSharp: case Language::Java: case Language::Swift: case Language::Kotlin:
        case Language::Scala: case Language::Julia:
            return quote == u'"';
        default: return false;
    }
}

static TypingPlan LineBreak(const TypingSource &text, Language language, const LexState &context,
                            const Indentation &style, TypingRange selection)
{
    const auto at = selection.location;
    const auto line = LineAt(text, at);
    const auto newline = Newline(text, line);
    if (!style.automatic)
        return Edit(selection, newline, at + newline.size());

    auto indent = LeadingIndent(text, line);
    if (at < line.start + indent.size())
        indent.resize(at - line.start);
    const auto tail = LineAt(text, selection.end());
    const auto next = SkipIndent(text, selection.end(), tail.end);
    const auto first = SkipIndent(text, line.start, at);
    std::u16string scratch;
    if (language == Language::Makefile && next == tail.end && context.mode == LexMode::Code) {
        const auto code = CodePrefix(text, line, at, scratch);
        const auto colon = code.find(u':'), equals = code.find(u'=');
        auto separator = colon;
        while (separator < code.size() && code[separator] == u':')
            ++separator;
        const bool target = colon != code.npos && colon && (equals == code.npos || equals > separator);
        if (indent.starts_with(u'\t') || (at > line.start && first == line.start && target))
            return Edit(selection, newline + u'\t', at + newline.size() + 1);
    }
    if (text.at(first) == u'*' && text.at(first + 1) == u'/' && first + 2 <= at &&
        !CodeAt(text, first) && indent.ends_with(u' '))
        indent.pop_back();
    if (context.mode == LexMode::BlockComment) {
        const auto marker = SkipIndent(text, line.start, line.end);
        const bool opening = StartsWith(text, marker, u"/*");
        if (opening || text.at(marker) == u'*') {
            auto margin = NormalizeIndent(indent, style);
            if (opening)
                margin += u' ';
            auto head = newline + margin + u"* ";
            const auto caret = at + head.size();
            if (StartsWith(text, next, u"*/"))
                return Edit({at, next - at}, head + newline + margin, caret);
            if (opening && text.at(marker + 2) == u'*' && next == tail.end) {
                auto search = next;
                for (;;) {
                    const auto star = text.find(text.context, {search, text.length - search}, TypingSearch::CommentStar, false);
                    if (star == missing)
                        return Edit(selection, head + newline + margin + u"*/", caret);
                    if (text.at(star + 1) == u'/')
                        break;
                    search = star + 1;
                }
            }
            return Edit(selection, std::move(head), caret);
        }
    }

    if (context.mode == LexMode::LineComment && next < tail.end) {
        const auto prefix = language_info(language).comments.line;
        if (!prefix.empty() && first + prefix.size() <= at && StartsWith(text, first, prefix)) {
            indent += prefix;
            indent += u' ';
        }
    }

    if (MarkupLanguage(language) && at > line.start && text.at(at - 1) == u'>' &&
        (context.mode == LexMode::MarkupText || context.mode == LexMode::Code)) {
        if (const auto name = OpeningTag(text, at - 1)) {
            const auto tag = Slice(text, name->location, name->end());
            if (!VoidHTMLTag(tag, language)) {
                auto head = newline + AddIndent(indent, style);
                const auto caret = at + head.size();
                if (StartsWithTagEnd(text, next, tag, language))
                    return Edit({at, next - at}, head + newline + NormalizeIndent(indent, style), caret);
                if (next == tail.end)
                    return Edit(selection, std::move(head), caret);
            }
        }
    }
    if (language == Language::YAML && context.mode == LexMode::BlockScalar &&
        CodePrefix(text, line, at, scratch).ends_with(u"_") && next == tail.end &&
        text.find(text.context, {first, at - first}, TypingSearch::YamlScalar, false) != missing) {
        auto head = newline + AddIndent(indent, style);
        const auto caret = at + head.size();
        return Edit(selection, std::move(head), caret);
    }

    if (context.mode == LexMode::Code || (context.mode == LexMode::LineComment && next == tail.end)) {
        const auto opening = ScanBrackets(text, at, true);
        if (opening != missing) {
            const auto begin = LineAt(text, opening);
            auto outer = LeadingIndent(text, begin);
            auto inner = AddIndent(outer, style);
            if (language == Language::CommonLisp) {
                outer = MakeIndent(Column(text, begin.start, opening, style.tabWidth), style);
                indent = MakeIndent(LispListColumn(text, begin, opening, std::min(at, begin.end), style), style);
            } else if (IndentColumn(indent, style.tabWidth) < IndentColumn(inner, style.tabWidth)) {
                indent = std::move(inner);
            }
            if (begin.start == line.start && tail.start == line.start && next < tail.end &&
                TypingCloseFor(text.at(opening)) == text.at(next) && CodeAt(text, next)) {
                auto head = newline + NormalizeIndent(indent, style);
                const auto caret = at + head.size();
                return Edit({at, next - at}, head + newline + NormalizeIndent(outer, style), caret);
            }
        }

        const auto code = CodePrefix(text, line, at, scratch);
        if (language == Language::Python && (opening == missing || LineAt(text, opening).start != line.start)) {
            if (auto suite = PythonSuiteIndent(text, line, at, code, scratch))
                indent = AddIndent(*suite, style);
        } else if (language == Language::YAML && code.ends_with(u":")) {
            indent = AddIndent(indent, style);
        } else if (opening == missing && ClosesIndentedBlock(text, language, code) && next == tail.end) {
            auto outer = OuterBlockIndent(text, line, language, scratch);
            if (outer && indent == AddIndent(*outer, style)) {
                auto replacement = *outer + Slice(text, first, at) + newline + *outer;
                const auto caret = line.start + replacement.size();
                return Edit({line.start, at - line.start}, std::move(replacement), caret);
            }
        } else if (opening == missing && StartsIndentedBlock(text, language, code)) {
            indent = AddIndent(indent, style);
        } else if (IsCStyle(language)) {
            if ((code.ends_with(u":") && CaseLabel(text, code)) ||
                (language != Language::Rust && SingleStatementHeader(text, code))) {
                indent = AddIndent(indent, style);
            } else if (language != Language::Rust && code.ends_with(u";")) {
                IndentAfterStatement(text, line, indent, scratch);
            }
        }
    }

    if (context.mode == LexMode::Code && tail.start == line.start)
        selection.length = next - at;
    auto inserted = newline + NormalizeIndent(indent, style);
    const auto caret = at + inserted.size();
    return Edit(selection, std::move(inserted), caret);
}

static std::optional<TypingPlan> Backspace(const TypingSource &text, const Indentation &style,
                                            std::span<const TypedPair> pairs, TypingRange selection)
{
    const auto at = selection.location;
    if (selection.length || !at)
        return {};
    for (const auto &pair : pairs)
        if (pair.opening.end() == at && pair.closing.location == at)
            return Edit({pair.opening.location, pair.closing.end() - pair.opening.location}, {}, pair.opening.location);
    const auto line = LineAt(text, at);
    if (at <= line.start || SkipIndent(text, line.start, at) != at)
        return {};
    const auto column = Column(text, line.start, at, style.tabWidth);
    auto indent = MakeIndent((column - 1) / style.width * style.width, style);
    const auto caret = line.start + indent.size();
    return Edit({line.start, at - line.start}, std::move(indent), caret);
}

static TypingPlan ShiftIndent(const TypingSource &text, TypingRange selection, const Indentation &style, bool right)
{
    const auto first = LineAt(text, selection.location);
    const auto last = LineAt(text, selection.length ? selection.end() - 1 : selection.location);
    std::u16string reformatted;
    ptrdiff_t delta = 0;
    size_t start = selection.location, end = selection.end();
    for (auto offset = first.start;;) {
        const auto line = LineAt(text, offset);
        const auto indentEnd = SkipIndent(text, line.start, line.end);
        const auto column = Column(text, line.start, indentEnd, style.tabWidth);
        const auto width = right ? column + style.width - column % style.width :
                           column ? (column - 1) / style.width * style.width : 0;
        const auto indent = MakeIndent(width, style);
        const auto adjust = [&](size_t position) {
            const auto mapped = indentEnd <= position ? position - (indentEnd - line.start) + indent.size() :
                                line.start + std::min(position - line.start, indent.size());
            return size_t(ptrdiff_t(mapped) + delta);
        };
        if (selection.location >= line.start && (selection.location < line.next || line.start == last.start))
            start = adjust(selection.location);
        if (selection.end() >= line.start && (selection.end() < line.next || line.start == last.start))
            end = adjust(selection.end());
        reformatted += indent;
        text.append(text.context, reformatted, {indentEnd, line.next - indentEnd});
        delta += ptrdiff_t(indent.size()) - ptrdiff_t(indentEnd - line.start);
        if (line.start == last.start)
            break;
        offset = line.next;
    }
    return Edit({first.start, last.next - first.start}, std::move(reformatted), start, end - start);
}

static size_t PreviousIndentColumn(const TypingSource &text, size_t lineStart, size_t tabWidth)
{
    auto last = text.find(text.context, {0, lineStart}, TypingSearch::NonBlank, true);
    if (last == missing)
        return 0;
    const auto previous = LineAt(text, last);
    return Column(text, previous.start, SkipIndent(text, previous.start, previous.end), tabWidth);
}

static TypingPlan Tab(const TypingSource &text, TypingRange selection, const Indentation &style)
{
    if (selection.length)
        return ShiftIndent(text, selection, style, true);
    const auto at = selection.location;
    const auto line = LineAt(text, at);
    if (style.automatic && line.start) {
        const auto end = SkipIndent(text, line.start, line.end);
        if (at <= end) {
            const auto target = PreviousIndentColumn(text, line.start, style.tabWidth);
            if (target && target > Column(text, line.start, end, style.tabWidth)) {
                auto indent = MakeIndent(target, style);
                const auto caret = line.start + indent.size();
                return Edit({line.start, end - line.start}, std::move(indent), caret);
            }
        }
    }
    const auto column = Column(text, line.start, at, style.tabWidth);
    const auto toStop = style.width - column % style.width;
    const bool tab = style.tabs && style.tabWidth - column % style.tabWidth == toStop;
    return Edit(selection, std::u16string(tab ? 1 : toStop, tab ? u'\t' : u' '), at + (tab ? 1 : toStop));
}

static bool IncludeDirective(const TypingSource &text, size_t at)
{
    std::u16string scratch;
    auto code = CodePrefix(text, LineAt(text, at), at, scratch);
    return code.starts_with(u'#') && OneOf(Trim(code.substr(1)), {u"include", u"include_next", u"import"});
}

static size_t RustRawHashes(const TypingSource &text, size_t at)
{
    auto start = at;
    while (start && text.at(start - 1) == u'#')
        --start;
    if (!start || text.at(start - 1) != u'r')
        return 0;
    auto prefix = start - 1;
    if (prefix && (text.at(prefix - 1) == u'b' || text.at(prefix - 1) == u'c'))
        --prefix;
    return prefix && Word(text, text.at(prefix - 1)) ? 0 : at - start;
}

static bool CanPairApostrophe(const TypingSource &text, size_t at, Language language)
{
    const auto prior = at ? text.at(at - 1) : 0;
    if (language == Language::Rust) {
        if (prior == u'b' && (at < 2 || !Word(text, text.at(at - 2))))
            return true;
        const auto start = LineAt(text, at).start;
        while (at > start && Blank(text.at(at - 1)))
            --at;
        return at > start && std::u16string_view(u"=([,").find(text.at(at - 1)) != std::u16string_view::npos;
    }
    return !Word(text, prior) || language == Language::Python || is_c_family(language);
}

static std::optional<TypingPlan> AlignColon(const TypingSource &text, Language language,
                                             const Indentation &style, TypingRange selection)
{
    const auto at = selection.location;
    const auto line = LineAt(text, at);
    if (SkipIndent(text, at, line.end) != line.end)
        return {};
    const auto indent = LeadingIndent(text, line);
    if (indent.empty())
        return {};
    std::u16string scratch;
    const auto code = CodePrefix(text, line, at, scratch);
    std::optional<std::u16string> aligned;
    const bool odinCase = language == Language::Odin && FirstWord(text, code) == u"case";
    if ((odinCase || (IsCStyle(language) && language != Language::Rust && CaseLabel(text, code))) &&
        code.find_first_of(u"?:") == code.npos) {
        const auto brace = ScanBrackets(text, line.start, true);
        if (brace != missing && text.at(brace) == u'{') {
            auto outer = LeadingIndent(text, LineAt(text, brace));
            aligned = odinCase ? std::move(outer) : AddIndent(outer, style);
        }
    } else if (language == Language::Python && ScanBrackets(text, at, true) == missing) {
        const auto clause = FirstWord(text, code);
        constexpr std::u16string_view ifs[] = {u"if", u"elif"};
        constexpr std::u16string_view elses[] = {u"if", u"elif", u"for", u"while", u"try", u"except"};
        constexpr std::u16string_view errors[] = {u"try", u"except", u"else"};
        constexpr std::u16string_view cases[] = {u"case", u"match"};
        std::span<const std::u16string_view> headers;
        if (clause == u"elif")
            headers = ifs;
        else if (clause == u"else")
            headers = elses;
        else if (clause == u"except" || clause == u"finally")
            headers = errors;
        else if (clause == u"case")
            headers = cases;
        auto from = line.start;
        for (unsigned i = 0; !headers.empty() && from && i < 256; ++i) {
            const auto above = LineAt(text, from - 1);
            const auto header = CodePrefix(text, above, above.end, scratch);
            const auto word = FirstWord(text, header);
            auto prefix = LeadingIndent(text, above);
            if (indent.starts_with(prefix) && header.ends_with(u":") &&
                std::ranges::find(headers, word) != headers.end()) {
                aligned = word == u"match" ? AddIndent(prefix, style) : std::move(prefix);
                break;
            }
            from = above.start;
        }
    }
    if (!aligned || *aligned == indent)
        return {};
    text.append(text.context, *aligned, {line.start + indent.size(), at - line.start - indent.size()});
    *aligned += u':';
    const auto caret = line.start + aligned->size();
    return Edit({line.start, at - line.start}, std::move(*aligned), caret);
}

static std::optional<TypingPlan> CompleteCharacter(const TypingSource &text, Language language, const LexState &context,
                                                   const Indentation &style, std::span<const TypedPair> pairs,
                                                   TypingRange selection, char16_t ch)
{
    const auto at = selection.location;
    if (language == Language::CommonLisp && std::u16string_view(u"[]{}").find(ch) != std::u16string_view::npos)
        return {};
    const auto next = text.at(at);
    const bool inCode = context.mode == LexMode::Code, markupTag = context.mode == LexMode::MarkupTag;
    const bool jsx = language == Language::JSX || language == Language::TSX;
    const bool jsxBrace = jsx && ch == u'{' && (markupTag || context.mode == LexMode::MarkupText);
    const bool backticks = is_javascript_family(language) || language == Language::Plain || language == Language::Go ||
        language == Language::Odin || language == Language::Luau || language == Language::Bash || language == Language::Zsh ||
        language == Language::Swift || language == Language::Kotlin || language == Language::SQL || language == Language::Markdown;
    const bool apostrophe = language == Language::GML ? at && text.at(at - 1) == u'@' :
        language != Language::JSON && language != Language::JSONC && language != Language::Swift &&
        language != Language::VisualBasic && language != Language::Clojure && language != Language::CommonLisp;
    const bool quote = TypingQuote(ch) && (ch != 0x60 || backticks) && (ch != u'\'' || apostrophe);

    if (ch == u'>' && !selection.length && markupTag && !context.markup.end_tag &&
        (!next || Blank(next) || next == u'<' || next == u'\r' || next == u'\n')) {
        if (const auto name = OpeningTag(text, at); name && (name->length || jsx)) {
            const auto tag = Slice(text, name->location, name->end());
            if (!VoidHTMLTag(tag, language) && !StartsWithTagEnd(text, at, tag, language)) {
                auto edit = Edit(selection, u"></" + tag + u'>', at + 1);
                edit.pair = TypedPair{{at, 1}, {at + 1, tag.size() + 3}};
                return edit;
            }
        }
    }

    if (!selection.length && next == ch && !(quote && Escaped(text, at))) {
        for (const auto &pair : pairs) {
            if (at >= pair.closing.location && at < pair.closing.end()) {
                auto passed = Edit(selection, {}, at + 1);
                passed.passedCloser = at;
                return passed;
            }
        }
    }

    if (!selection.length && inCode && style.automatic) {
        if (ch == u':') {
            if (auto aligned = AlignColon(text, language, style, selection))
                return aligned;
        } else if (const auto open = TypingOpenFor(ch)) {
            const auto line = LineAt(text, at);
            if (SkipIndent(text, line.start, at) == at) {
                const auto mate = ScanBrackets(text, at, true);
                if (mate != missing && text.at(mate) == open) {
                    const auto begin = LineAt(text, mate);
                    auto replacement = language == Language::CommonLisp ?
                        MakeIndent(Column(text, begin.start, mate, style.tabWidth), style) : LeadingIndent(text, begin);
                    replacement += ch;
                    auto end = at;
                    auto close = SkipIndent(text, at, line.end);
                    if (close == line.end && line.next > line.end) {
                        const auto following = LineAt(text, line.next);
                        close = SkipIndent(text, following.start, following.end);
                    }
                    if (text.at(close) == ch) {
                        for (const auto &pair : pairs) {
                            if (pair.opening.location == mate && pair.closing.location == close) {
                                end = close + 1;
                                break;
                            }
                        }
                    }
                    const auto caret = line.start + replacement.size();
                    return Edit({line.start, end - line.start}, std::move(replacement), caret);
                }
            }
        }
    }

    const bool header = ch == u'<' && is_c_family(language) && inCode && IncludeDirective(text, at);
    const bool templateBrace = ch == u'{' && !inCode &&
        ((is_javascript_family(language) && lex_closing_is(context.closing, u"\x60") &&
          at && text.at(at - 1) == u'$' && !Escaped(text, at - 1)) ||
         (language == Language::GML && context.interpolation == Interpolation::Braces && !Escaped(text, at)));
    const auto close = quote ? ch : header ? u'>' : TypingCloseFor(ch);
    if (!close)
        return {};

    if (quote && TripleQuotedStrings(language, ch) && !selection.length && inCode && at >= 2 &&
        text.at(at - 1) == ch && text.at(at - 2) == ch &&
        (at < 3 || text.at(at - 3) != ch) && next != ch && !Escaped(text, at - 2)) {
        auto triple = Edit(selection, std::u16string(4, ch), at + 1);
        triple.pair = TypedPair{{at - 2, 3}, {at + 1, 3}};
        return triple;
    }

    if (!selection.length) {
        if (!inCode && !templateBrace && !jsxBrace && !(quote && markupTag && context.markup.part == TagPart::Value))
            return {};
        if (next && !UnicodeWhitespace(next) && std::u16string_view(u";:.,=)}]>\"'\x60").find(next) == std::u16string_view::npos)
            return {};
        if (quote && (Escaped(text, at) || (ch == u'\'' && !CanPairApostrophe(text, at, language))))
            return {};
        if (TypingCloseFor(ch) && !templateBrace && !jsxBrace && next == close && CodeAt(text, at) &&
            MatchingTypingBracket(text, at) == missing)
            return {};
    }

    const auto hashes = language == Language::Rust && ch == u'"' ? RustRawHashes(text, at) : 0;
    if (hashes > 255)
        return {};
    std::u16string replacement(1, ch);
    replacement.reserve(selection.length + hashes + 2);
    text.append(text.context, replacement, selection);
    replacement += close;
    replacement.append(hashes, u'#');
    auto paired = Edit(selection, std::move(replacement), at + 1, selection.length);
    paired.pair = TypedPair{{at, 1}, {at + 1 + selection.length, hashes + 1}};
    return paired;
}

std::optional<TypingPlan> PlanTyping(const TypingSource &text, Language language, const LexState &context,
                                     const Indentation &style, std::span<const TypedPair> pairs,
                                     TypingRange selection, TypingKey key, char16_t ch)
{
    if (selection.location > text.length || selection.length > text.length - selection.location)
        return {};
    language = language_in_context(language, context);
    switch (key) {
        case TypingKey::Enter: return LineBreak(text, language, context, style, selection);
        case TypingKey::Backspace: return Backspace(text, style, pairs, selection);
        case TypingKey::Tab: return Tab(text, selection, style);
        case TypingKey::Backtab: return ShiftIndent(text, selection, style, false);
        case TypingKey::Character: return CompleteCharacter(text, language, context, style, pairs, selection, ch);
    }
    return {};
}
