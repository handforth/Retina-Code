#pragma once

#import <AppKit/AppKit.h>
#include "Lexer.hpp"
#include "VimMulti.hpp"

#include <optional>

extern NSString *const EditorNonCodeAttribute;

enum class TypingKey { Character, Enter, Backspace, Tab, Backtab };

struct Indentation {
    NSUInteger tabWidth = 4;
    NSUInteger width = 4;
    bool tabs = false;
    bool automatic = true;
    bool operator==(const Indentation &) const = default;
};

struct TypedPair {
    NSRange opening;
    NSRange closing;
};

struct TypingEdit {
    NSRange range;
    NSString *text;
    NSRange selection;
    std::optional<TypedPair> pair;
    NSUInteger passedCloser = NSNotFound;
};

struct BracketMatch {
    NSUInteger at = NSNotFound;
    NSUInteger mate = NSNotFound;

    bool operator==(const BracketMatch &) const = default;
};

Indentation DetectIndentation(NSString *text, Indentation fallback = {});
void AdjustTypedPairs(std::vector<TypedPair> &pairs, const Vim::EditMap &edit);
bool MayCompleteCharacter(unichar character);
NSRange NextCodeBracket(NSAttributedString *storage, NSRange range, bool backwards);
BracketMatch BracketsAtSelection(NSAttributedString *storage, NSRange selection, bool preferUnderCursor);
std::vector<Vim::Range> CommentLineRanges(NSString *text, std::vector<Vim::Range> selections);
void AppendLineCommentEdits(NSString *text, Vim::Range lines, Vim::Comments comments, const Indentation &indentation,
                            std::vector<Vim::CursorEdit> &edits);
std::optional<TypingEdit> PlanTyping(NSAttributedString *storage, Language language, const LexState &context,
                                     const Indentation &indentation, const std::vector<TypedPair> &pairs,
                                     NSRange selection, TypingKey key, unichar character = 0);