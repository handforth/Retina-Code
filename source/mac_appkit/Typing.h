#pragma once

#import <AppKit/AppKit.h>
#include "../Typing.hpp"
#include "../VimMulti.hpp"

#include <optional>

extern NSString *const EditorNonCodeAttribute;

struct TypingEdit {
    NSRange range;
    NSString *text;
    NSRange selection;
    std::optional<TypedPair> pair;
    NSUInteger passedCloser = NSNotFound;
};

Indentation DetectIndentation(NSString *text, Indentation fallback = {});
void AdjustTypedPairs(std::vector<TypedPair> &pairs, const Vim::EditMap &edit);
NSRange NextCodeBracket(NSAttributedString *storage, NSRange range, bool backwards);
BracketMatch BracketsAtSelection(NSAttributedString *storage, NSRange selection, bool preferUnderCursor);
std::vector<Vim::Range> CommentLineRanges(NSString *text, std::vector<Vim::Range> selections);
void AppendLineCommentEdits(NSString *text, Vim::Range lines, CommentSyntax comments, const Indentation &indentation,
                            std::vector<Vim::CursorEdit> &edits);
std::optional<TypingEdit> PlanTyping(NSAttributedString *storage, Language language, const LexState &context,
                                     const Indentation &indentation, const std::vector<TypedPair> &pairs,
                                     NSRange selection, TypingKey key, unichar character = 0);
