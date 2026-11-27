// The text of one document. See TextBuffer.hpp.

#include "TextBuffer.hpp"

#include <cstring>

// Lexer states no line uses are dropped once there are this many, or twice as many as the last drop left.
static const uint32_t LEX_STATE_LIMIT_MINIMUM = 256;

// The end state of a line that hasn't been lexed yet. It never equals a real index, so lexing never stops on it.
static const uint32_t NOT_LEXED = UINT32_MAX;

static uint32_t count_line_breaks(std::u16string_view units)
{
    uint32_t count = 0;
    for (char16_t unit : units) {
        if (unit == u'\n')
            count += 1;
    }

    return count;
}

//
// Lines and lexer states.
//

uint32_t line_of_offset(const TextBuffer &text, uint32_t offset)
{
    // The last line that starts at or before the offset.
    uint32_t low = 0, high = uint32_t(text.lines.size());
    while (high - low > 1) {
        uint32_t middle = (low + high) / 2;
        if (text.lines[middle].start <= offset)
            low = middle;
        else
            high = middle;
    }

    return low;
}

std::u16string_view line_text(const TextBuffer &text, uint32_t line)
{
    uint32_t start = text.lines[line].start;
    uint32_t end = line + 1 < text.lines.size() ? text.lines[line + 1].start - 1 : uint32_t(text.units.size());
    return std::u16string_view(text.units.data() + start, end - start);
}

const LexState &lex_state_before_line(const TextBuffer &text, uint32_t line)
{
    return text.lex_states[line ? text.lines[line - 1].end_state : 0];
}

// FNV-1a over 8 bytes at a time. LexState has no padding, so equal states hash the same.
static uint64_t hash_lex_state(const LexState &state)
{
    static_assert(sizeof(LexState) % 8 == 0);

    const uint8_t *bytes = (const uint8_t *)&state;
    uint64_t hash = 14695981039346656037ull;
    for (size_t at = 0; at < sizeof(LexState); at += 8) {
        uint64_t word;
        memcpy(&word, bytes + at, 8);
        hash = (hash ^ word) * 1099511628211ull;
    }

    return hash;
}

// Starts the table of lexer states over, holding only the state a text starts in.
static void forget_lex_states(TextBuffer &text)
{
    LexState start_state = {};
    text.lex_states.assign(1, start_state);
    text.lex_state_indexes.clear();
    text.lex_state_indexes[hash_lex_state(start_state)] = 0;
    text.lex_state_limit = LEX_STATE_LIMIT_MINIMUM;
}

// The index of a state in lex_states, adding it if it's new. After a change, most lines end in the same state as
// before, so the old index is tried before the hash table.
static uint32_t lex_state_index(TextBuffer &text, const LexState &state, uint32_t old_index)
{
    if (old_index != NOT_LEXED && lex_states_equal(state, text.lex_states[old_index]))
        return old_index;

    uint64_t hash = hash_lex_state(state);
    auto found = text.lex_state_indexes.find(hash);
    if (found != text.lex_state_indexes.end() && lex_states_equal(state, text.lex_states[found->second]))
        return found->second;

    // Of two different states with the same hash, only the first can be found again, so the second may be stored
    // more than once. That costs memory, never correctness.
    uint32_t index = uint32_t(text.lex_states.size());
    text.lex_states.push_back(state);
    text.lex_state_indexes.emplace(hash, index);
    return index;
}

// Drops the states no line ends in any more, so editing can't grow lex_states without limit. The state a text starts
// in stays at index 0.
static void drop_unused_lex_states(TextBuffer &text)
{
    const uint32_t DROPPED = UINT32_MAX;

    // Mark the states in use with 0, then move them down over the dropped ones and note where each one went.
    std::vector<uint32_t> new_indexes(text.lex_states.size(), DROPPED);
    new_indexes[0] = 0;
    for (const TextLine &line : text.lines)
        new_indexes[line.end_state] = 0;

    uint32_t kept = 0;
    text.lex_state_indexes.clear();
    for (uint32_t index = 0; index < text.lex_states.size(); ++index) {
        if (new_indexes[index] == DROPPED)
            continue;

        text.lex_states[kept] = text.lex_states[index];
        text.lex_state_indexes.emplace(hash_lex_state(text.lex_states[kept]), kept);
        new_indexes[index] = kept;
        kept += 1;
    }

    text.lex_states.resize(kept);
    for (TextLine &line : text.lines)
        line.end_state = new_indexes[line.end_state];

    text.lex_state_limit = kept * 2 > LEX_STATE_LIMIT_MINIMUM ? kept * 2 : LEX_STATE_LIMIT_MINIMUM;
}

// Lexes from first_line on. Every line through last_changed_line is lexed; after that, lexing stops at the first line
// that ends in the same state as before, because the lines after it then lex as they did before.
static void lex_lines(TextBuffer &text, uint32_t first_line, uint32_t last_changed_line)
{
    // Plain text is lexed as C, so typing rules still know where its quotes and comments are.
    Language language = text.language == Language::Plain ? Language::C : text.language;
    LexState state = lex_state_before_line(text, first_line);

    uint32_t line = first_line;
    for (; line < text.lines.size(); ++line) {
        tokenize_line(line_text(text, line), language, state, text.tokens);

        uint32_t old_index = text.lines[line].end_state;
        uint32_t index = lex_state_index(text, state, old_index);
        text.lines[line].end_state = index;
        if (index == old_index && line >= last_changed_line)
            break;
    }

    uint32_t last_line = line < text.lines.size() ? line : uint32_t(text.lines.size() - 1);
    if (text.lexed_end_line == NO_POSITION || last_line > text.lexed_end_line)
        text.lexed_end_line = last_line;

    if (text.lex_states.size() >= text.lex_state_limit)
        drop_unused_lex_states(text);
}

//
// Qt's string. QTextDocumentPrivate keeps the document as fragments of its string: runs of units that sit side by
// side there, with each line break in a fragment of its own. This follows how its insert_string, insert_block, move,
// and unite split and join those fragments.
//

static uint32_t qt_position(const TextBuffer &text, uint32_t at)
{
    return text.qt_positions[at] & ~QT_FRAGMENT_START;
}

static bool starts_qt_fragment(const TextBuffer &text, uint32_t at)
{
    return (text.qt_positions[at] & QT_FRAGMENT_START) != 0;
}

static void set_qt_fragment_start(TextBuffer &text, uint32_t at, bool starts)
{
    text.qt_positions[at] = starts ? text.qt_positions[at] | QT_FRAGMENT_START : text.qt_positions[at] & ~QT_FRAGMENT_START;
}

// Marks the fragments after a change left inserted_length new units at start. Qt splits its fragments where it
// changes them, and each inserted line and line break begins a fragment. Then it joins the fragment just before the
// change with the one that now starts there, when neither holds a line break and their text sits side by side.
static void mark_qt_fragments(TextBuffer &text, uint32_t start, uint32_t inserted_length)
{
    uint32_t end = start + inserted_length;
    for (uint32_t at = start; at < end; ++at)
        set_qt_fragment_start(text, at, at == start || text.units[at] == u'\n' || text.units[at - 1] == u'\n');

    if (end < text.units.size())
        set_qt_fragment_start(text, end, true);

    bool joins = start > 0 && start < text.units.size() && text.units[start - 1] != u'\n' && text.units[start] != u'\n' &&
                 qt_position(text, start - 1) + 1 == qt_position(text, start);
    if (joins)
        set_qt_fragment_start(text, start, false);
}

// Merges one insertion or removal into the changed range, as QTextDocumentPrivate::adjustDocumentChangesAndCursors
// does. The range grows to cover both, along with any text between them.
static void note_changed_range(TextChange &change, uint32_t start, uint32_t removed, uint32_t added)
{
    if (change.start == NO_POSITION) {
        change = {start, removed, added};
        return;
    }

    int64_t from = start, old_start = change.start, old_end = old_start + change.new_length;
    int64_t gap = from + removed < old_start ? old_start - from - removed : from > old_end ? from - old_end : 0;

    int64_t overlap_start = from > old_start ? from : old_start;
    int64_t overlap_end = from + removed < old_end ? from + removed : old_end;
    int64_t removed_inside = overlap_end > overlap_start ? overlap_end - overlap_start : 0;

    change.start = uint32_t(from < old_start ? from : old_start);
    change.old_length += uint32_t(removed - removed_inside + gap);
    change.new_length += uint32_t(added - removed_inside + gap);
}

void note_document_change(TextChange &change, uint32_t start, uint32_t length)
{
    if (change.start == NO_POSITION) {
        change = {start, length, length};
        return;
    }

    uint32_t range_start = start < change.start ? start : change.start;
    uint32_t end = start + length > change.start + change.new_length ? start + length : change.start + change.new_length;
    uint32_t grown = end - range_start > change.new_length ? end - range_start - change.new_length : 0;
    change.start = range_start;
    change.old_length += grown;
    change.new_length += grown;
}

// Replaces the units in [start, start + length) with inserted, and keeps the rest in step: Qt's string and fragments,
// the line starts, and the lexer states. In Qt's string, the inserted text counts up from qt_text_position and its
// line breaks from qt_separator_position. Recording the change for undo is up to the caller.
static void change_text(TextBuffer &text, uint32_t start, uint32_t length, std::u16string_view inserted,
                        uint32_t qt_text_position, uint32_t qt_separator_position)
{
    uint32_t first_line = line_of_offset(text, start);
    uint32_t last_line = line_of_offset(text, start + length);

    // The units after the change, with their places in Qt's string, move to just after the inserted ones.
    size_t old_size = text.units.size();
    size_t new_size = old_size - length + inserted.size();
    size_t moved_count = old_size - start - length;
    if (new_size > old_size) {
        text.units.resize(new_size);
        text.qt_positions.resize(new_size);
    }

    memmove(text.units.data() + start + inserted.size(), text.units.data() + start + length, moved_count * sizeof(char16_t));
    memmove(text.qt_positions.data() + start + inserted.size(), text.qt_positions.data() + start + length,
            moved_count * sizeof(uint32_t));
    memcpy(text.units.data() + start, inserted.data(), inserted.size() * sizeof(char16_t));

    if (new_size < old_size) {
        text.units.resize(new_size);
        text.qt_positions.resize(new_size);
    }

    // Lines that started inside the removed units go, and each inserted '\n' starts a new line. The last of the
    // changed lines ends where last_line ended, so it takes that line's end state for lex_lines to compare against.
    uint32_t end_state_after_change = text.lines[last_line].end_state;
    uint32_t removed_line_count = last_line - first_line;
    uint32_t inserted_line_count = count_line_breaks(inserted);

    std::vector<TextLine>::iterator changed_lines = text.lines.begin() + first_line + 1;
    if (inserted_line_count > removed_line_count)
        text.lines.insert(changed_lines + removed_line_count, inserted_line_count - removed_line_count, TextLine{});
    else
        text.lines.erase(changed_lines + inserted_line_count, changed_lines + removed_line_count);

    // Each inserted unit gets its place in Qt's string, and each line break starts its line.
    uint32_t line = first_line + 1;
    for (uint32_t at = 0; at < inserted.size(); ++at) {
        if (inserted[at] == u'\n') {
            text.qt_positions[start + at] = qt_separator_position++;
            text.lines[line] = {start + at + 1, NOT_LEXED};
            line += 1;
        } else {
            text.qt_positions[start + at] = qt_text_position + at;
        }
    }

    text.lines[first_line + inserted_line_count].end_state = end_state_after_change;
    mark_qt_fragments(text, start, uint32_t(inserted.size()));

    // Qt notes the removal and the insertion one after the other.
    if (length)
        note_changed_range(text.changed, start, length, 0);
    if (!inserted.empty())
        note_changed_range(text.changed, start, 0, uint32_t(inserted.size()));

    // The lines after the change move by its change in length. When the text got shorter, the unsigned shift wraps
    // around, and adding it still moves the starts back by the right amount.
    uint32_t shift = uint32_t(inserted.size()) - length;
    for (; line < text.lines.size(); ++line)
        text.lines[line].start += shift;

    lex_lines(text, first_line, first_line + inserted_line_count);
}

void set_text(TextBuffer &text, std::u16string_view units, Language language)
{
    text.units.clear();
    text.qt_positions.clear();
    text.lines.assign(1, TextLine{0, NOT_LEXED});
    text.language = language;
    text.changed.start = NO_POSITION;
    text.lexed_end_line = NO_POSITION;
    forget_lex_states(text);

    // QTextDocument::setPlainText stores the text with insertText.
    uint32_t size = uint32_t(units.size());
    change_text(text, 0, 0, units, 0, size);
    text.qt_string_length = size + uint32_t(text.lines.size() - 1);

    text.undo_records.clear();
    text.undo_text.clear();
    text.undo_position = 0;
    text.saved_undo_position = 0;
    text.undo_group_depth = 0;
    text.undo_group_caret = NO_POSITION;
    text.modified = false;
    text.changed.start = NO_POSITION;
    text.lexed_end_line = NO_POSITION;
}

void set_text_language(TextBuffer &text, Language language)
{
    text.language = language;
    forget_lex_states(text);
    for (TextLine &line : text.lines)
        line.end_state = NOT_LEXED;

    lex_lines(text, 0, uint32_t(text.lines.size() - 1));
    text.lexed_end_line = NO_POSITION;
}

//
// Undo history. The rules are Qt's, from QTextDocumentPrivate::appendUndoItem, QTextUndoCommand::tryMerge, and
// QTextDocumentPrivate::undoRedo in Qt 6.
//

// Qt updates whether the text is modified only after a change made outside a group, and its merging rules read that.
static void note_whether_modified(TextBuffer &text)
{
    text.modified = text.undo_position != text.saved_undo_position;
}

static void append_undo_record(TextBuffer &text, UndoKind kind, uint32_t start, std::u16string_view changed, uint32_t qt_position)
{
    UndoRecord record;
    record.start = start;
    record.length = uint32_t(changed.size());
    record.text_at = uint32_t(text.undo_text.size());
    record.qt_position = qt_position;
    record.kind = kind;
    record.grouped = text.undo_group_depth > 0;
    record.ends_group = false;

    text.undo_text.insert(text.undo_text.end(), changed.begin(), changed.end());
    text.undo_records.push_back(record);
    text.undo_position += 1;
}

// Extends the last record with a change that continues it, both in the document and in Qt's string: typing on at the
// end of an insertion, Delete at the start of a removal, or Backspace just before it. Line breaks are a different kind
// of change in Qt, which never merges.
static bool merge_undo_record(TextBuffer &text, UndoRecord &last, UndoKind kind, uint32_t start, std::u16string_view changed,
                              uint32_t qt_position)
{
    if (last.kind != kind || text.undo_text[last.text_at] == u'\n' || changed[0] == u'\n')
        return false;

    uint32_t changed_length = uint32_t(changed.size());
    bool typed_on = kind == UndoKind::Insertion && start == last.start + last.length &&
                    qt_position == last.qt_position + last.length;
    bool deleted_forward = kind == UndoKind::Removal && start == last.start && qt_position == last.qt_position + last.length;
    bool deleted_backward = kind == UndoKind::Removal && start + changed_length == last.start &&
                            qt_position + changed_length == last.qt_position;

    // The last record's text is at the end of undo_text, so it can grow in place.
    if (typed_on || deleted_forward) {
        text.undo_text.insert(text.undo_text.end(), changed.begin(), changed.end());
    } else if (deleted_backward) {
        text.undo_text.insert(text.undo_text.begin() + last.text_at, changed.begin(), changed.end());
        last.start = start;
        last.qt_position = qt_position;
    } else {
        return false;
    }

    last.length += changed_length;
    return true;
}

// Records one change.
static void record_change(TextBuffer &text, UndoKind kind, uint32_t start, std::u16string_view changed, uint32_t qt_position)
{
    // A change drops whatever could have been redone, along with the saved point if it was among that.
    if (text.undo_position < text.undo_records.size()) {
        const UndoRecord *last = text.undo_position ? &text.undo_records[text.undo_position - 1] : nullptr;
        text.undo_text.resize(last ? last->text_at + last->length : 0);
        text.undo_records.resize(text.undo_position);

        if (text.saved_undo_position > text.undo_position)
            text.saved_undo_position = NO_POSITION;
    }

    // Before a group's first change away from the caret it began at, a caret record keeps that caret for undo.
    if (text.undo_group_depth > 0 && text.undo_group_caret != NO_POSITION && text.undo_group_caret != start) {
        append_undo_record(text, UndoKind::Caret, text.undo_group_caret, {}, 0);
        text.undo_group_caret = NO_POSITION;
    }

    // Qt merges only while the text is modified, and only inside one open group, between two changes outside groups,
    // or when typing goes on after a group.
    if (text.modified && text.undo_position > 0) {
        UndoRecord &last = text.undo_records[text.undo_position - 1];
        bool grouped = text.undo_group_depth > 0;
        bool same_open_group = last.grouped && grouped && !last.ends_group;
        bool both_outside_groups = !last.grouped && !grouped;
        bool typing_after_group = kind == UndoKind::Insertion && last.kind == UndoKind::Insertion && last.grouped && !grouped;

        if ((same_open_group || both_outside_groups || typing_after_group) &&
            merge_undo_record(text, last, kind, start, changed, qt_position))
            return;
    }

    append_undo_record(text, kind, start, changed, qt_position);
}

void replace_text(TextBuffer &text, uint32_t start, uint32_t length, std::u16string_view inserted)
{
    if (!length && inserted.empty())
        return;

    // Qt records a removal as one change for each of its fragments. Each one is gone before the next is removed, so
    // they are all at start.
    uint32_t piece_start = start;
    for (uint32_t at = start + 1; at <= start + length; ++at) {
        if (at == start + length || starts_qt_fragment(text, at)) {
            std::u16string_view piece(text.units.data() + piece_start, at - piece_start);
            record_change(text, UndoKind::Removal, start, piece, qt_position(text, piece_start));
            piece_start = at;
        }
    }

    // insertText puts the whole text at the end of Qt's string, and then a separator for each of its line breaks.
    uint32_t inserted_length = uint32_t(inserted.size());
    change_text(text, start, length, inserted, text.qt_string_length, text.qt_string_length + inserted_length);
    text.qt_string_length += inserted_length + count_line_breaks(inserted);

    // Qt records an insertion as one change for each line's text and each line break.
    piece_start = 0;
    for (uint32_t at = 1; at <= inserted.size(); ++at) {
        if (at == inserted.size() || inserted[at] == u'\n' || inserted[at - 1] == u'\n') {
            record_change(text, UndoKind::Insertion, start + piece_start, inserted.substr(piece_start, at - piece_start),
                          qt_position(text, start + piece_start));
            piece_start = at;
        }
    }

    if (text.undo_group_depth == 0)
        note_whether_modified(text);
}

void begin_undo_group(TextBuffer &text, uint32_t caret)
{
    if (text.undo_group_depth == 0)
        text.undo_group_caret = caret;

    text.undo_group_depth += 1;
}

void end_undo_group(TextBuffer &text)
{
    text.undo_group_depth -= 1;
    if (text.undo_group_depth > 0)
        return;

    // The last record ends the group. A group that changed nothing leaves the record before it as it was.
    if (text.undo_position > 0 && text.undo_records[text.undo_position - 1].grouped)
        text.undo_records[text.undo_position - 1].ends_group = true;

    text.undo_group_caret = NO_POSITION;
    note_whether_modified(text);
}

void mark_text_saved(TextBuffer &text)
{
    text.saved_undo_position = text.undo_position;
    text.modified = false;
}

// True when the records on both sides of an undo position belong to one group, so undo or redo goes on past it.
static bool group_continues(const TextBuffer &text, uint32_t position)
{
    return position > 0 && position < text.undo_records.size() &&
           text.undo_records[position].grouped && text.undo_records[position - 1].grouped &&
           !text.undo_records[position - 1].ends_group;
}

// Applies a record forwards for redo or backwards for undo, and tracks where Qt puts the caret: where text was
// removed, or after the text put back. When several records put text back at the same place, it goes after all of it.
static void apply_undo_record(TextBuffer &text, const UndoRecord &record, bool forwards, uint32_t &edit_start, uint32_t &edit_length)
{
    if (record.kind == UndoKind::Caret) {
        edit_start = record.start;
        edit_length = 0;
        return;
    }

    // Qt puts a record's text back where it was in its string. A record is either text or one line break, so its
    // position serves for both.
    std::u16string_view record_text(text.undo_text.data() + record.text_at, record.length);
    bool puts_text_back = (record.kind == UndoKind::Insertion) == forwards;
    if (puts_text_back) {
        change_text(text, record.start, 0, record_text, record.qt_position, record.qt_position);
        if (edit_start != record.start)
            edit_length = 0;
        edit_start = record.start;
        edit_length += record.length;
    } else {
        change_text(text, record.start, record.length, {}, 0, 0);
        edit_start = record.start;
        edit_length = 0;

        // Undo and redo take out a line break without joining the fragments on either side of it.
        if (record_text[0] == u'\n' && record.start < text.units.size())
            set_qt_fragment_start(text, record.start, true);
    }
}

uint32_t undo_text_change(TextBuffer &text)
{
    if (text.undo_position == 0)
        return NO_POSITION;

    uint32_t edit_start = NO_POSITION, edit_length = 0;
    do {
        text.undo_position -= 1;
        apply_undo_record(text, text.undo_records[text.undo_position], false, edit_start, edit_length);
    } while (group_continues(text, text.undo_position));

    note_whether_modified(text);
    return edit_start + edit_length;
}

uint32_t redo_text_change(TextBuffer &text)
{
    if (text.undo_position == text.undo_records.size())
        return NO_POSITION;

    uint32_t edit_start = NO_POSITION, edit_length = 0;
    do {
        apply_undo_record(text, text.undo_records[text.undo_position], true, edit_start, edit_length);
        text.undo_position += 1;
    } while (group_continues(text, text.undo_position));

    note_whether_modified(text);
    return edit_start + edit_length;
}
