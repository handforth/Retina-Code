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
// Changes.
//

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

// Replaces the units in [start, start + length) with inserted, and keeps the line starts and lexer states in step.
// Recording the change for undo is up to the caller.
static void change_text(TextBuffer &text, uint32_t start, uint32_t length, std::u16string_view inserted)
{
    uint32_t first_line = line_of_offset(text, start);
    uint32_t last_line = line_of_offset(text, start + length);

    // The units after the change move to just after the inserted ones.
    size_t old_size = text.units.size();
    size_t new_size = old_size - length + inserted.size();
    size_t moved_count = old_size - start - length;
    if (new_size > old_size)
        text.units.resize(new_size);
    memmove(text.units.data() + start + inserted.size(), text.units.data() + start + length, moved_count * sizeof(char16_t));
    memcpy(text.units.data() + start, inserted.data(), inserted.size() * sizeof(char16_t));
    if (new_size < old_size)
        text.units.resize(new_size);

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

    uint32_t line = first_line + 1;
    for (uint32_t at = 0; at < inserted.size(); ++at) {
        if (inserted[at] == u'\n') {
            text.lines[line] = {start + at + 1, NOT_LEXED};
            line += 1;
        }
    }
    text.lines[first_line + inserted_line_count].end_state = end_state_after_change;

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
    text.lines.assign(1, TextLine{0, NOT_LEXED});
    text.language = language;
    forget_lex_states(text);
    change_text(text, 0, 0, units);

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
// Undo history.
//

// The text is modified once undo can't reach the saved text without stepping, as of the last change made outside a
// group. Typing merges only while it's modified, so undo always stops at the saved text.
static void note_whether_modified(TextBuffer &text)
{
    text.modified = text.undo_position != text.saved_undo_position;
}

static bool has_line_break(std::u16string_view units)
{
    return units.find(u'\n') != std::u16string_view::npos;
}

// Extends the newest change with one that goes on from it: typing on at the end of what it inserted, or Delete at
// the start of what it removed or Backspace just before it. Typing also goes on from a group, as after a bracket that
// closes itself, so undo takes back the pair and what was typed in it together. Nothing goes on across a line break.
static bool merge_undo_record(TextBuffer &text, UndoRecord &last, uint32_t start, std::u16string_view removed, std::u16string_view inserted)
{
    std::u16string_view last_removed(text.undo_text.data() + last.text_at, last.removed_length);
    std::u16string_view last_inserted(text.undo_text.data() + last.text_at + last.removed_length, last.inserted_length);
    uint32_t removed_length = uint32_t(removed.size());
    bool typing = removed.empty() && !inserted.empty() && last.inserted_length && !has_line_break(last_inserted) && !has_line_break(inserted);
    bool deleting = inserted.empty() && !last.inserted_length && !last.grouped && !has_line_break(last_removed) && !has_line_break(removed);
    bool typed_on = typing && start == last.start + last.inserted_length;
    bool deleted_forward = deleting && start == last.start;
    bool deleted_backward = deleting && start + removed_length == last.start;

    // The last record's text is at the end of undo_text, the removed units first.
    if (typed_on) {
        text.undo_text.insert(text.undo_text.end(), inserted.begin(), inserted.end());
        last.inserted_length += uint32_t(inserted.size());
    } else if (deleted_forward) {
        text.undo_text.insert(text.undo_text.end(), removed.begin(), removed.end());
        last.removed_length += removed_length;
    } else if (deleted_backward) {
        text.undo_text.insert(text.undo_text.begin() + last.text_at, removed.begin(), removed.end());
        last.removed_length += removed_length;
        last.start = start;
    } else {
        return false;
    }
    return true;
}

static void record_change(TextBuffer &text, uint32_t start, std::u16string_view removed, std::u16string_view inserted)
{
    // A change drops whatever could have been redone, along with the saved point if it was among that. Then it
    // starts a record of its own: only the newest change made goes on.
    bool newest = text.undo_position == text.undo_records.size();
    if (!newest) {
        const UndoRecord *last = text.undo_position ? &text.undo_records[text.undo_position - 1] : nullptr;
        text.undo_text.resize(last ? last->text_at + last->removed_length + last->inserted_length : 0);
        text.undo_records.resize(text.undo_position);
        if (text.saved_undo_position > text.undo_position)
            text.saved_undo_position = NO_POSITION;
    }

    bool grouped = text.undo_group_depth > 0;
    if (!grouped && newest && text.modified && text.undo_position > 0 &&
        merge_undo_record(text, text.undo_records[text.undo_position - 1], start, removed, inserted))
        return;

    // Inside a group, the changes after its first undo with it, and the first keeps the caret the group began at
    // when that isn't where the change is.
    UndoRecord record;
    record.start = start;
    record.removed_length = uint32_t(removed.size());
    record.inserted_length = uint32_t(inserted.size());
    record.text_at = uint32_t(text.undo_text.size());
    record.grouped = grouped;
    record.continues = grouped && text.undo_position > text.undo_group_first;
    record.caret = grouped && !record.continues && text.undo_group_caret != start ? text.undo_group_caret : NO_POSITION;

    text.undo_text.insert(text.undo_text.end(), removed.begin(), removed.end());
    text.undo_text.insert(text.undo_text.end(), inserted.begin(), inserted.end());
    text.undo_records.push_back(record);
    text.undo_position += 1;
}

void replace_text(TextBuffer &text, uint32_t start, uint32_t length, std::u16string_view inserted)
{
    if (!length && inserted.empty())
        return;

    // The removed units go into the history before the change overwrites them.
    record_change(text, start, std::u16string_view(text.units.data() + start, length), inserted);
    change_text(text, start, length, inserted);
    if (text.undo_group_depth == 0)
        note_whether_modified(text);
}

void begin_undo_group(TextBuffer &text, uint32_t caret)
{
    if (text.undo_group_depth == 0) {
        text.undo_group_caret = caret;
        text.undo_group_first = text.undo_position;
    }
    text.undo_group_depth += 1;
}

void end_undo_group(TextBuffer &text)
{
    text.undo_group_depth -= 1;
    if (text.undo_group_depth == 0)
        note_whether_modified(text);
}

void mark_text_saved(TextBuffer &text)
{
    text.saved_undo_position = text.undo_position;
    text.modified = false;
}

// Undo takes back the records of one step from the last, and puts the caret after the text it put back, or where the
// step's group began.
uint32_t undo_text_change(TextBuffer &text)
{
    if (text.undo_position == 0)
        return NO_POSITION;

    const UndoRecord *record;
    do {
        text.undo_position -= 1;
        record = &text.undo_records[text.undo_position];
        std::u16string_view removed(text.undo_text.data() + record->text_at, record->removed_length);
        change_text(text, record->start, record->inserted_length, removed);
    } while (record->continues);

    note_whether_modified(text);
    return record->caret != NO_POSITION ? record->caret : record->start + record->removed_length;
}

// Redo makes the records of one step again, and puts the caret after the last text it inserted.
uint32_t redo_text_change(TextBuffer &text)
{
    if (text.undo_position == text.undo_records.size())
        return NO_POSITION;

    const UndoRecord *record;
    do {
        record = &text.undo_records[text.undo_position];
        std::u16string_view inserted(text.undo_text.data() + record->text_at + record->removed_length, record->inserted_length);
        change_text(text, record->start, record->removed_length, inserted);
        text.undo_position += 1;
    } while (text.undo_position < text.undo_records.size() && text.undo_records[text.undo_position].continues);

    note_whether_modified(text);
    return record->start + record->inserted_length;
}
