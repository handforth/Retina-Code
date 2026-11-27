#pragma once

#include "Lexer.hpp"

#include <algorithm>

struct CommentLine {
    size_t start, end, next;
};

inline bool CommentContextDependsOnLexer(Language language)
{
    return language == Language::HTML || language == Language::Markdown || language == Language::PHP ||
           language == Language::JSX || language == Language::TSX;
}

inline CommentSyntax CommentsInContext(Language language, const LexState &context)
{
    if (CommentContextDependsOnLexer(language)) {
        language = language_in_context(language, context);
        if (context.mode == LexMode::MarkupText) {
            if (language == Language::JSX || language == Language::TSX)
                return {{}, u"{/*", u"*/}"};
            if (language == Language::PHP)
                language = Language::HTML;
        }
    }
    return language_info(language).comments;
}

inline size_t CommentInsertionAdvance(std::u16string_view text)
{
    const auto space = text.find(u' ');
    return space == 0 || space == text.npos ? 0 : space + 1;
}

// Emit in source order. A caller editing in place can translate offsets by the cumulative edit delta.
template <class LineAt, class CharAt, class Edit>
void ToggleCommentLines(size_t start, size_t end, CommentSyntax comments, size_t tabWidth, size_t indentWidth,
                        LineAt lineAt, CharAt at, Edit edit)
{
    const auto blank = [](char16_t ch) { return ch == u' ' || ch == u'\t'; };
    const auto firstText = [&](CommentLine line) {
        size_t first = line.start;
        while (first < line.end && blank(at(first)))
            ++first;
        return first;
    };
    const auto matches = [&](size_t first, size_t last, std::u16string_view marker) {
        if (marker.size() > last - first)
            return false;
        for (char16_t ch : marker) {
            if (at(first++) != ch)
                return false;
        }
        return true;
    };

    if (comments.line.empty()) {
        if (comments.open.empty() || comments.close.empty())
            return;
        const size_t first = firstText(lineAt(start));
        size_t last = end;
        while (last > first && blank(at(last - 1)))
            --last;
        if (last - first >= comments.open.size() + comments.close.size() &&
            matches(first, last, comments.open) && matches(last - comments.close.size(), last, comments.close)) {
            size_t left = first + comments.open.size();
            size_t right = last - comments.close.size();
            if (left < right && at(left) == u' ')
                ++left;
            if (right > left && at(right - 1) == u' ')
                --right;
            edit(first, left, {});
            edit(right, last, {});
        } else if (first == end) {
            const auto wrapped = std::u16string(comments.open) + u"  " + std::u16string(comments.close);
            edit(first, first, wrapped);
        } else {
            const auto opening = std::u16string(comments.open) + u" ";
            const auto closing = u" " + std::u16string(comments.close);
            edit(first, first, opening);
            edit(end, end, closing);
        }
        return;
    }

    const auto step = [tabWidth](char16_t ch, size_t column) {
        return ch == u'\t' ? tabWidth - column % tabWidth : 1;
    };
    size_t indent = std::u16string_view::npos, blankIndent = indent;
    bool remove = true;
    for (auto line = lineAt(start);; line = lineAt(line.next)) {
        size_t first = line.start, column = 0;
        while (first < line.end) {
            const char16_t ch = at(first);
            if (!blank(ch))
                break;
            column += step(ch, column);
            ++first;
        }
        if (first == line.end) {
            blankIndent = std::min(blankIndent, column);
        } else {
            indent = std::min(indent, column);
            remove = remove && matches(first, line.end, comments.line);
        }
        if (line.end == end)
            break;
    }

    const bool onlyBlank = indent == std::u16string_view::npos;
    if (onlyBlank) {
        indent = blankIndent;
        remove = false;
    }
    indent -= indent % indentWidth;
    const auto prefix = std::u16string(comments.line) + u" ";
    for (auto line = lineAt(start);; line = lineAt(line.next)) {
        const size_t first = firstText(line);
        if (first < line.end || onlyBlank) {
            if (remove) {
                size_t last = first + comments.line.size();
                if (last < line.end && at(last) == u' ')
                    ++last;
                edit(first, last, {});
            } else {
                size_t offset = line.start, column = 0;
                while (offset < first && column < indent) {
                    const size_t advance = step(at(offset), column);
                    if (advance > indent - column)
                        break;
                    column += advance;
                    ++offset;
                }
                edit(offset, offset, prefix);
            }
        }
        if (line.end == end)
            break;
    }
}
