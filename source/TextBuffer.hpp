#pragma once

// The text of one document: its UTF-16 units, where each line starts, the lexer state at the end of every line, and
// the undo history. Every change goes through replace_text(), which keeps the lines and lexer states in step with
// the units. A buffer starts with set_text().
//
// Lines are separated by '\n' alone. The file layer turns other line endings into '\n' when it loads a file.
//
// The undo history is a list of changes, each of them where it starts, the units it removed, and the units it
// inserted. Typing on, Backspace, and Delete merge into the change before them, so undo takes back a run of them at
// once, the way editors do. Changes made inside a group undo as one step.

#include "Lexer.hpp"

#include <string_view>
#include <unordered_map>
#include <vector>

constexpr uint32_t NO_POSITION = UINT32_MAX;

struct TextLine {
    uint32_t start;        // offset of the line's first unit
    uint32_t end_state;    // index in TextBuffer::lex_states of the lexer state after the line
};

// One change in the undo history: the units at [start, start + removed_length) were the removed ones, which the
// inserted ones replaced. Both are in TextBuffer::undo_text at text_at, the removed units first.
struct UndoRecord {
    uint32_t start;
    uint32_t removed_length;
    uint32_t inserted_length;
    uint32_t text_at;
    uint32_t caret;          // where undoing the step puts the caret, when its group began away from its first change
    bool grouped;            // made inside an undo group
    bool continues;          // undoes and redoes with the record before it, as one group
};

// A range of changed text, merged the way QTextDocument reports an edit: where it starts, how many units it held, and
// how many it holds now. start is NO_POSITION when nothing changed.
struct TextChange {
    uint32_t start, old_length, new_length;
};

struct TextBuffer {
    std::vector<char16_t> units;
    std::vector<TextLine> lines;    // never empty: an empty text is one empty line

    Language language;
    std::vector<LexState> lex_states;                            // every distinct state that ends a line; 0 is the state a text starts in
    std::unordered_map<uint64_t, uint32_t> lex_state_indexes;    // from the hash of a state to its index in lex_states
    uint32_t lex_state_limit;                                    // states no line uses are dropped when there are this many
    std::vector<Token> tokens;                                   // scratch for lexing

    TextChange changed;          // what changed since the editor last looked
    uint32_t lexed_end_line;     // the last line lexed again for those changes, or NO_POSITION

    std::vector<UndoRecord> undo_records;
    std::vector<char16_t> undo_text;
    uint32_t undo_position;          // records before this are done, the rest can be redone
    uint32_t saved_undo_position;    // undo_position when the text was saved, or NO_POSITION once undo can't get back there
    uint32_t undo_group_depth;
    uint32_t undo_group_caret;       // the caret when the outermost group began
    uint32_t undo_group_first;       // the record the outermost group's changes start at
    bool modified;                   // the text differs from the saved text, as of the last change made outside a group
};

// Replaces all the text and starts a new undo history, with the new text counted as saved.
void set_text(TextBuffer &text, std::u16string_view units, Language language);

// Lexes every line again for another language.
void set_text_language(TextBuffer &text, Language language);

// Replaces the units in [start, start + length) with inserted, and records the change for undo.
void replace_text(TextBuffer &text, uint32_t start, uint32_t length, std::u16string_view inserted);

// Marks [start, start + length) as changed without changing its text, as QTextDocumentPrivate::documentChange does
// when a line's formats or the text being composed in it change. The range grows to cover the old one and this one.
void note_document_change(TextChange &change, uint32_t start, uint32_t length);

// Makes the changes until the matching end_undo_group() one undo step. Groups nest, and only the outermost group's
// caret counts: undoing the group puts the caret back there, unless it is NO_POSITION.
void begin_undo_group(TextBuffer &text, uint32_t caret);
void end_undo_group(TextBuffer &text);

// Undoes or redoes one step. Returns where the caret goes afterwards, or NO_POSITION when there was nothing to do.
uint32_t undo_text_change(TextBuffer &text);
uint32_t redo_text_change(TextBuffer &text);

void mark_text_saved(TextBuffer &text);

// Makes the records from first to last, last left out, one undo step, which undo ends with the caret at caret. Vim
// mode uses it for its changes, which span keys.
void join_undo_steps(TextBuffer &text, uint32_t first, uint32_t last, uint32_t caret);

// The line an offset is on. The offset of a '\n' is on the line the '\n' ends.
uint32_t line_of_offset(const TextBuffer &text, uint32_t offset);

// A line's units, without its '\n'.
std::u16string_view line_text(const TextBuffer &text, uint32_t line);

const LexState &lex_state_before_line(const TextBuffer &text, uint32_t line);
