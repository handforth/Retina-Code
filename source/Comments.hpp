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
