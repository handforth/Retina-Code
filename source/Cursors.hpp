#pragma once

// Several cursors in one text, for both editors. Each has a selection from anchor to head, and one is the primary:
// the one that scrolls into view, and the one left when the others go. An editor keeps them in a vector, sorted and
// apart, as merge_cursors leaves them.

#include "VimMulti.hpp"

#include <cstdint>
#include <string_view>
#include <vector>

static const size_t CURSOR_LIMIT = 10000;
static const uint32_t OCCURRENCE_NOT_FOUND = UINT32_MAX;

struct Cursor {
    uint32_t anchor, head;
    float goal;       // where Up and Down aim, in the editor's own units, or below 0 until a move needs it
    bool primary;
};

inline uint32_t cursor_start(const Cursor &cursor) { return cursor.anchor < cursor.head ? cursor.anchor : cursor.head; }
inline uint32_t cursor_end(const Cursor &cursor) { return cursor.anchor < cursor.head ? cursor.head : cursor.anchor; }

// Letters, digits, and underscores, and everything past ASCII, which words are made of.
bool is_word_unit(char16_t unit);

// Sorts the cursors by where their selections start, and merges the ones that overlap, or that touch when one of
// them is only a caret. A merged cursor covers both, and it's the primary when either was.
void merge_cursors(std::vector<Cursor> &cursors);

// Where pattern is first in [from, to), as a whole word when whole_word is set, or OCCURRENCE_NOT_FOUND.
uint32_t find_occurrence(std::u16string_view units, std::u16string_view pattern, uint32_t from, uint32_t to, bool whole_word);

// A place in the text as one cursor's own edit left it, which replaced removed units at start with inserted ones, in
// the text after every cursor's edit in the batch: inside the new text it keeps its place there, and after it it
// moves with the rest.
uint32_t position_after_typing(uint32_t position, uint32_t start, uint32_t removed, uint32_t inserted, const Vim::EditBatch &batch);
