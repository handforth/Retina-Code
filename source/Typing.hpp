#pragma once

#include "Comments.hpp"

#include <optional>
#include <span>
#include <string>
#include <vector>

enum class TypingKey { Character, Enter, Backspace, Tab, Backtab };

struct Indentation {
    size_t tabWidth = 4;
    size_t width = 4;
    bool tabs = false;
    bool automatic = true;
    bool operator==(const Indentation &) const = default;
};

inline constexpr size_t typingNotFound = size_t(-1);
inline constexpr size_t typedPairLimit = 512;

struct TypingRange {
    size_t location, length;
    size_t end() const { return location + length; }
};

struct BracketMatch {
    size_t at = typingNotFound;
    size_t mate = typingNotFound;

    bool operator==(const BracketMatch &) const = default;
};

struct TypedPair {
    TypingRange opening, closing;
};

struct TypingPlan {
    TypingRange range;
    std::u16string text;
    TypingRange selection;
    std::optional<TypedPair> pair;
    size_t passedCloser = typingNotFound;
};

struct TypingSpan {
    TypingRange range;
    Ink role = Ink::Text;
};

constexpr Ink TypingRole(Ink ink)
{
    return ink == Ink::Comment || ink == Ink::Escape ? ink : Ink::String;
}

enum class TypingSearch { Bracket, NonBlank, TagStart, CommentStar, YamlScalar };

constexpr std::u16string_view TypingSearchCharacters(TypingSearch search)
{
    switch (search) {
        case TypingSearch::Bracket: return u"()[]{}";
        case TypingSearch::NonBlank: return u" \t\r\n\u0085\u2028\u2029";
        case TypingSearch::TagStart: return u"<";
        case TypingSearch::CommentStar: return u"*";
        case TypingSearch::YamlScalar: return u"|>";
    }
    return {};
}

// Read from the editor's existing text and syntax ranges. Offsets are UTF-16.
struct TypingSource {
    void *context;
    size_t length;
    char16_t (*character)(void *, size_t);
    CommentLine (*line)(void *, size_t);
    TypingSpan (*syntax)(void *, size_t);
    void (*append)(void *, std::u16string &, TypingRange);
    size_t (*find)(void *, TypingRange, TypingSearch, bool backwards);
    size_t (*graphemeEnd)(void *, size_t);
    bool (*alphanumeric)(char16_t);

    char16_t at(size_t position) const { return position < length ? character(context, position) : 0; }
};

constexpr char16_t TypingCloseFor(char16_t character)
{
    switch (character) {
        case u'(': return u')';
        case u'[': return u']';
        case u'{': return u'}';
        default: return 0;
    }
}

constexpr char16_t TypingOpenFor(char16_t character)
{
    switch (character) {
        case u')': return u'(';
        case u']': return u'[';
        case u'}': return u'{';
        default: return 0;
    }
}

constexpr bool TypingQuote(char16_t character)
{
    return character == u'"' || character == u'\'' || character == 0x60;
}

constexpr bool MayCompleteCharacter(char16_t character)
{
    return TypingCloseFor(character) || TypingOpenFor(character) || TypingQuote(character) ||
           character == u':' || character == u'<' || character == u'>' || character == u'#';
}

template<class Map>
void RemapTypedPairs(std::vector<TypedPair> &pairs, Map map)
{
    std::erase_if(pairs, [&](TypedPair &pair) { return !map(pair.opening) || !map(pair.closing); });
}

inline bool MapTypedRange(TypingRange &part, TypingRange edited, size_t inserted)
{
    if (edited.location < part.end() && part.location < edited.end())
        return false;
    if (part.location >= edited.end())
        part.location = part.location - edited.length + inserted;
    return true;
}

// One change a comment toggle makes: replace [start, end) with text. Offsets are in the text before any change.
struct CommentEdit {
    size_t start, end;
    std::u16string text;
};

// Comments or uncomments the lines from start to end, adding the changes in text order. A caller applying them one
// by one moves each later offset by how much the earlier changes grew or shrank the text.
void ToggleCommentLines(const TypingSource &text, size_t start, size_t end, CommentSyntax comments, size_t tabWidth,
                        size_t indentWidth, std::vector<CommentEdit> &edits);

void RememberTypedPair(std::vector<TypedPair> &pairs, const std::optional<TypedPair> &pair,
                       size_t passedCloser, size_t length);
Indentation DetectTypingIndentation(const TypingSource &text, Indentation fallback = {});
size_t NextTypingBracket(const TypingSource &text, TypingRange range, bool backwards);
size_t MatchingTypingBracket(const TypingSource &text, size_t position);
BracketMatch BracketsAtSelection(const TypingSource &text, TypingRange selection, bool preferUnderCursor = false);
std::optional<TypingPlan> PlanTyping(const TypingSource &text, Language language, const LexState &context,
                                    const Indentation &style, std::span<const TypedPair> pairs,
                                    TypingRange selection, TypingKey key, char16_t character = 0);
