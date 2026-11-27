#pragma once

#include "Completion.hpp"

#include <QTextBlock>
#include <QTextDocument>

#include <array>
#include <cstdint>
#include <functional>

inline std::u16string_view utf16View(QStringView text)
{
    return {text.utf16(), size_t(text.size())};
}

class OfflineWords {
public:
    void edited(const QTextDocument &document, int at, int removed, int added)
    {
        if (line_ < 0 || !(removed || added))
            return;
        if (document.blockCount() != blockCount_ || at < start_ || at > end_ || removed > end_ - at) {
            line_ = -1;
        } else {
            end_ += added - removed;
        }
    }

    size_t complete(const QTextBlock &block, std::u16string_view line, int start, int end,
                    Language language, std::span<std::u16string_view> matches)
    {
        if (line_ != block.blockNumber() || language_ != language)
            rebuild(block, language);

        const bool plain = language == Language::Plain;
        const auto lexLanguage = plain ? Language::C : language;
        state_ = incoming_;
        TokenizeLine(line, lexLanguage, state_, tokens_);
        if (state_ != outgoing_) {
            // Comments, strings, or embedded modes can change the names on later lines.
            rebuild(block, language);
            state_ = incoming_;
            TokenizeLine(line, lexLanguage, state_, tokens_);
        }
        if (end > 0) {
            for (const Token &token : tokens_) {
                if (token.start > size_t(end - 1))
                    break;
                if (size_t(end - 1) - token.start < token.length && IsNonCodeToken(token))
                    return 0;
            }
        }

        const auto prefix = line.substr(size_t(start), size_t(end - start));
        std::array<std::u16string_view, WordCompletionLimit> names;
        size_t count = 0;
        const auto position = std::upper_bound(words_.begin(), words_.end(), prefix,
            [this](auto key, Word word) { return key < text(word); });
        for (auto it = position; it != words_.end() && count < names.size(); ++it) {
            const auto name = text(*it);
            if (!name.starts_with(prefix))
                break;
            names[count++] = name;
        }
        for (const Token &token : tokens_) {
            if (!IsCompletionName(line, token, plain))
                continue;
            const auto name = line.substr(token.start, token.length);
            if (name == prefix || !name.starts_with(prefix))
                continue;
            const auto last = names.begin() + count;
            const auto row = std::lower_bound(names.begin(), last, name);
            if (row == names.end() || (row != last && *row == name))
                continue;
            count = std::min(count + 1, names.size());
            std::move_backward(row, names.begin() + count - 1, names.begin() + count);
            *row = name;
        }

        if (language == Language::HTML || language == Language::Markdown || language == Language::PHP) {
            state_ = incoming_;
            TokenizeLine(line.substr(0, size_t(end)), language, state_, tokens_, false);
            language = LanguageInContext(language, state_);
        }
        return MergeCompletionWords(prefix, language, std::span(names).first(count), matches);
    }

private:
    struct Word {
        uint32_t at, length;
    };

    std::u16string_view text(Word word) const
    {
        return {characters_.data() + word.at, word.length};
    }

    void rebuild(const QTextBlock &active, Language language)
    {
        line_ = active.blockNumber();
        start_ = active.position();
        end_ = start_ + active.length() - 1;
        blockCount_ = active.document()->blockCount();
        language_ = language;
        characters_.clear();
        words_.clear();
        std::array<uint32_t, 1024> localSlots{};
        std::vector<uint32_t> largerTable;
        std::span<uint32_t> buckets = localSlots;
        const auto findSlot = [&](std::u16string_view name) {
            size_t mask = buckets.size() - 1;
            size_t slot = std::hash<std::u16string_view>{}(name) & mask;
            while (buckets[slot] && text(words_[buckets[slot] - 1]) != name)
                slot = (slot + 1) & mask;
            return slot;
        };
        const bool plain = language == Language::Plain;
        const auto lexLanguage = plain ? Language::C : language;
        state_ = LexState{};
        for (auto block = active.document()->begin(); block.isValid(); block = block.next()) {
            const QString blockText = block.text();
            const auto line = utf16View(blockText);
            if (block == active)
                incoming_ = state_;
            TokenizeLine(line, lexLanguage, state_, tokens_);
            if (block == active) {
                outgoing_ = state_;
                continue;
            }
            for (const Token &token : tokens_) {
                if (!IsCompletionName(line, token, plain))
                    continue;
                const auto name = line.substr(token.start, token.length);
                size_t slot = findSlot(name);
                if (buckets[slot])
                    continue;
                if (words_.size() * 2 >= buckets.size()) {
                    largerTable.assign(buckets.size() * 2, 0);
                    buckets = largerTable;
                    for (size_t i = 0; i < words_.size(); ++i)
                        buckets[findSlot(text(words_[i]))] = uint32_t(i + 1);
                    slot = findSlot(name);
                }
                words_.push_back({uint32_t(characters_.size()), uint32_t(name.size())});
                characters_.append(name);
                buckets[slot] = uint32_t(words_.size());
            }
        }
        const auto byText = [this](Word a, Word b) { return text(a) < text(b); };
        std::sort(words_.begin(), words_.end(), byText);
    }

    std::u16string characters_;
    std::vector<Word> words_;
    std::vector<Token> tokens_;
    LexState incoming_, outgoing_, state_;
    Language language_ = Language::Count;
    int line_ = -1, start_ = 0, end_ = 0, blockCount_ = 0;
};
