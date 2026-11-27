#pragma once

// The text of one document: its UTF-16 units, where each line starts, the lexer state at the end of every line, and
// the undo history. Every change goes through replace_text(), which keeps the lines and lexer states in step with
// the units. A buffer starts with set_text().
//
// Lines are separated by '\n' alone. The file layer turns other line endings into '\n' when it loads a file.
//
// The undo history works exactly as QTextDocument's does, so undo behaves as it did in the QPlainTextEdit editor.
// Qt keeps all the text it is ever given in one internal string that only grows, and the document is a list of
// fragments of that string. It merges two undo records only when their text sits side by side in that string, so the
// buffer keeps track of where Qt would have put each unit. Every edit is made the way QTextCursor::insertText makes
// it, which stores the inserted text and then a separator for each of its line breaks. Enter through insertBlock
// stores its line break differently, but no undo rule can tell the two apart.

#include "Lexer.hpp"

#include <string_view>
#include <unordered_map>
#include <vector>

constexpr uint32_t NO_POSITION = UINT32_MAX;

struct TextLine {
    uint32_t start;        // offset of the line's first unit
    uint32_t end_state;    // index in TextBuffer::lex_states of the lexer state after the line
};

enum class UndoKind : uint8_t { Insertion, Removal, Caret };

// One change in the undo history, the same as one of Qt's undo commands: a line break on its own, or text from one
// line that sits side by side in Qt's string. Its text is kept in TextBuffer::undo_text. A caret record has no text:
// it holds where the caret was when an undo group began, so undoing the group puts the caret back there.
struct UndoRecord {
    uint32_t start;
    uint32_t length;
    uint32_t text_at;        // offset of the text in undo_text
    uint32_t qt_position;    // where the text starts in Qt's string
    UndoKind kind;
    bool grouped;            // made inside an undo group, which undo and redo treat as one step
    bool ends_group;         // the last record of its group
};

struct TextBuffer {
    std::vector<char16_t> units;
    std::vector<TextLine> lines;    // never empty: an empty text is one empty line

    Language language;
    std::vector<LexState> lex_states;                            // every distinct state that ends a line; 0 is the state a text starts in
    std::unordered_map<uint64_t, uint32_t> lex_state_indexes;    // from the hash of a state to its index in lex_states
    uint32_t lex_state_limit;                                    // states no line uses are dropped when there are this many
    std::vector<Token> tokens;                                   // scratch for lexing

    // Where Qt would keep each unit in its string, with QT_FRAGMENT_START set on units that begin one of its fragments.
    std::vector<uint32_t> qt_positions;
    uint32_t qt_string_length;

    std::vector<UndoRecord> undo_records;
    std::vector<char16_t> undo_text;
    uint32_t undo_position;          // records before this are done, the rest can be redone
    uint32_t saved_undo_position;    // undo_position when the text was saved, or NO_POSITION once undo can't get back there
    uint32_t undo_group_depth;
    uint32_t undo_group_caret;       // the caret when the outermost group began, until the group's first change away from it
    bool modified;                   // the text differs from the saved text, as of the last change made outside a group
};

constexpr uint32_t QT_FRAGMENT_START = 0x80000000u;

// Replaces all the text and starts a new undo history, with the new text counted as saved.
void set_text(TextBuffer &text, std::u16string_view units, Language language);

// Lexes every line again for another language.
void set_text_language(TextBuffer &text, Language language);

// Replaces the units in [start, start + length) with inserted, as QTextCursor::insertText does. Undo gets the records
// Qt would make, and each one merges into the record before it when Qt's would.
void replace_text(TextBuffer &text, uint32_t start, uint32_t length, std::u16string_view inserted);

// Makes the changes until the matching end_undo_group() one undo step. Groups nest, and only the outermost group's
// caret counts: undoing the group puts the caret back there, unless it is NO_POSITION.
void begin_undo_group(TextBuffer &text, uint32_t caret);
void end_undo_group(TextBuffer &text);

// Undoes or redoes one step. Returns where the caret goes afterwards, or NO_POSITION when there was nothing to do.
uint32_t undo_text_change(TextBuffer &text);
uint32_t redo_text_change(TextBuffer &text);

void mark_text_saved(TextBuffer &text);

// The line an offset is on. The offset of a '\n' is on the line the '\n' ends.
uint32_t line_of_offset(const TextBuffer &text, uint32_t offset);

// A line's units, without its '\n'.
std::u16string_view line_text(const TextBuffer &text, uint32_t line);

const LexState &lex_state_before_line(const TextBuffer &text, uint32_t line);
