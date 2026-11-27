#pragma once

#include "Lexer.hpp"

#include <algorithm>
#include <span>

inline constexpr size_t WordCompletionLimit = 8;

constexpr bool IsNonCodeToken(const Token &token)
{
    return token.nonCode || token.ink == Ink::Comment || token.ink == Ink::String || token.ink == Ink::Escape;
}

constexpr bool IsCompletionName(std::u16string_view line, const Token &token, bool plain)
{
    return !token.nonCode && token.length > 1 && line[token.start] != u'\'' &&
           (token.ink == Ink::Text || token.ink == Ink::Name || token.ink == Ink::Type ||
            token.ink == Ink::Function || token.ink == Ink::Constant ||
            (plain && (token.ink == Ink::Keyword || token.ink == Ink::Control)));
}

inline size_t MergeCompletionWords(std::u16string_view prefix, Language language,
                                   std::span<const std::u16string_view> names,
                                   std::span<std::u16string_view> results)
{
    const auto &words = CompletionWords(language);
    auto keyword = std::upper_bound(words.begin(), words.end(), prefix);
    size_t name = 0, count = 0;
    while (count < results.size()) {
        const bool hasKeyword = keyword != words.end() && keyword->starts_with(prefix);
        const bool hasName = name < names.size();
        if (!hasKeyword && !hasName)
            break;
        const auto word = hasKeyword && (!hasName || *keyword <= names[name]) ? *keyword : names[name];
        results[count++] = word;
        if (hasKeyword && *keyword == word)
            ++keyword;
        if (hasName && names[name] == word)
            ++name;
    }
    return count;
}
