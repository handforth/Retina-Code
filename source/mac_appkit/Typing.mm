#import "Typing.h"

#include <algorithm>

NSString *const EditorNonCodeAttribute = @"RetinaCodeNonCode";

using Line = CommentLine;

static Line LineAt(NSString *text, NSUInteger offset)
{
    Line line;
    [text getLineStart:&line.start end:&line.next contentsEnd:&line.end forRange:NSMakeRange(offset, 0)];
    return line;
}

static unichar At(NSString *text, NSUInteger offset)
{
    return offset < text.length ? [text characterAtIndex:offset] : 0;
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

struct AppKitTypingText {
    NSString *text;
    NSAttributedString *storage;

    TypingSource source()
    {
        return {this, text.length,
            [](void *context, size_t at) -> char16_t {
                return [static_cast<AppKitTypingText *>(context)->text characterAtIndex:at];
            },
            [](void *context, size_t at) { return LineAt(static_cast<AppKitTypingText *>(context)->text, at); },
            [](void *context, size_t at) {
                NSRange span;
                auto *storage = static_cast<AppKitTypingText *>(context)->storage;
                NSNumber *literal = [storage attribute:EditorNonCodeAttribute atIndex:at effectiveRange:&span];
                return TypingSpan{{span.location, span.length}, literal ? Ink(literal.integerValue) : Ink::Text};
            },
            [](void *context, std::u16string &result, TypingRange range) {
                if (!range.length)
                    return;
                const auto start = result.size();
                result.resize(start + range.length);
                [static_cast<AppKitTypingText *>(context)->text getCharacters:reinterpret_cast<unichar *>(result.data() + start)
                                                                         range:NSMakeRange(range.location, range.length)];
            },
            [](void *context, TypingRange range, TypingSearch search, bool backwards) -> size_t {
                static NSArray<NSCharacterSet *> *sets = [] {
                    NSMutableArray<NSCharacterSet *> *result = [NSMutableArray arrayWithCapacity:5];
                    for (auto search : {TypingSearch::Bracket, TypingSearch::NonBlank, TypingSearch::TagStart,
                                       TypingSearch::CommentStar, TypingSearch::YamlScalar}) {
                        const auto chars = TypingSearchCharacters(search);
                        NSString *characters = [[NSString alloc] initWithCharacters:
                            reinterpret_cast<const unichar *>(chars.data()) length:chars.size()];
                        NSCharacterSet *set = [NSCharacterSet characterSetWithCharactersInString:characters];
                        [result addObject:search == TypingSearch::NonBlank ? set.invertedSet : set];
                    }
                    return [result copy];
                }();
                NSCharacterSet *set = sets[size_t(search)];
                const NSRange match = [static_cast<AppKitTypingText *>(context)->text rangeOfCharacterFromSet:set
                    options:backwards ? NSBackwardsSearch : 0 range:NSMakeRange(range.location, range.length)];
                return match.location == NSNotFound ? typingNotFound : match.location;
            },
            [](void *context, size_t at) {
                return NSMaxRange([static_cast<AppKitTypingText *>(context)->text rangeOfComposedCharacterSequenceAtIndex:at]);
            },
            [](char16_t ch) -> bool { return [NSCharacterSet.alphanumericCharacterSet characterIsMember:ch]; }};
    }
};

void AppendLineCommentEdits(NSString *text, Vim::Range lines, CommentSyntax comments, const Indentation &indentation,
                            std::vector<Vim::CursorEdit> &edits)
{
    AppKitTypingText source{text, nil};
    std::vector<CommentEdit> commentEdits;
    ToggleCommentLines(source.source(), lines.first, lines.last, comments, indentation.tabWidth, indentation.width,
                       commentEdits);
    for (const CommentEdit &edit : commentEdits)
        edits.push_back({{edit.start, edit.end}, edit.text});
}

Indentation DetectIndentation(NSString *text, Indentation fallback)
{
    AppKitTypingText source{text, nil};
    return DetectTypingIndentation(source.source(), fallback);
}

NSRange NextCodeBracket(NSAttributedString *storage, NSRange range, bool backwards)
{
    AppKitTypingText text{storage.string, storage};
    const auto bracket = NextTypingBracket(text.source(), {range.location, range.length}, backwards);
    return bracket == typingNotFound ? NSMakeRange(NSNotFound, 0) : NSMakeRange(bracket, 1);
}

BracketMatch BracketsAtSelection(NSAttributedString *storage, NSRange selection, bool preferUnderCursor)
{
    AppKitTypingText text{storage.string, storage};
    return BracketsAtSelection(text.source(), {selection.location, selection.length}, preferUnderCursor);
}

void AdjustTypedPairs(std::vector<TypedPair> &pairs, const Vim::EditMap &edit)
{
    RemapTypedPairs(pairs, [&](TypingRange &part) {
        if (!edit.batch)
            return MapTypedRange(part, {edit.range.first, edit.range.last - edit.range.first}, edit.inserted);
        if (edit.overlaps({part.location, part.end()}))
            return false;
        part.location = edit.map(part.location);
        return true;
    });
}

std::optional<TypingEdit> PlanTyping(NSAttributedString *storage, Language language, const LexState &context,
                                     const Indentation &style, const std::vector<TypedPair> &pairs,
                                     NSRange selection, TypingKey key, unichar character)
{
    AppKitTypingText text{storage.string, storage};
    auto plan = PlanTyping(text.source(), language, context, style, pairs, {selection.location, selection.length}, key, character);
    if (!plan)
        return {};
    const bool passed = plan->passedCloser != typingNotFound;
    NSString *replacement = passed ? nil : [[NSString alloc] initWithCharacters:
        reinterpret_cast<const unichar *>(plan->text.data()) length:plan->text.size()];
    return TypingEdit{NSMakeRange(plan->range.location, plan->range.length), replacement,
                      NSMakeRange(plan->selection.location, plan->selection.length), plan->pair,
                      passed ? plan->passedCloser : NSNotFound};
}
