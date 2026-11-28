// Several cursors in one text. See Cursors.hpp.

#include "Cursors.hpp"

#include <algorithm>

bool is_word_unit(char16_t unit)
{
    return unit == u'_' || (unit >= u'0' && unit <= u'9') || (unit >= u'a' && unit <= u'z') || (unit >= u'A' && unit <= u'Z') ||
           unit >= 0x80;
}

static bool cursor_before(const Cursor &a, const Cursor &b)
{
    if (cursor_start(a) != cursor_start(b))
        return cursor_start(a) < cursor_start(b);
    return cursor_end(a) < cursor_end(b);
}

void merge_cursors(std::vector<Cursor> &cursors)
{
    if (cursors.size() < 2)
        return;

    std::sort(cursors.begin(), cursors.end(), cursor_before);
    size_t count = 1;
    for (size_t index = 1; index < cursors.size(); ++index) {
        Cursor &previous = cursors[count - 1];
        const Cursor &next = cursors[index];
        uint32_t end = cursor_end(previous), first = cursor_start(next);
        bool caret = previous.anchor == previous.head || next.anchor == next.head;
        if (first > end || (first == end && !caret)) {
            cursors[count++] = next;
            continue;
        }

        // The merged cursor keeps the direction of the primary one, or else of the first.
        uint32_t low = cursor_start(previous), high = std::max(end, cursor_end(next));
        bool primary = previous.primary || next.primary;
        if (next.primary)
            previous = next;
        bool backwards = previous.head < previous.anchor;
        previous.anchor = backwards ? high : low;
        previous.head = backwards ? low : high;
        previous.primary = primary;
    }
    cursors.resize(count);
}

uint32_t find_occurrence(std::u16string_view units, std::u16string_view pattern, uint32_t from, uint32_t to, bool whole_word)
{
    if (pattern.empty())
        return OCCURRENCE_NOT_FOUND;

    for (size_t at = units.find(pattern, from); at != std::u16string_view::npos && at + pattern.size() <= to; at = units.find(pattern, at + 1)) {
        size_t end = at + pattern.size();
        bool inside_word = (at > 0 && is_word_unit(units[at - 1])) || (end < units.size() && is_word_unit(units[end]));
        if (!whole_word || !inside_word)
            return uint32_t(at);
    }
    return OCCURRENCE_NOT_FOUND;
}

uint32_t position_after_typing(uint32_t position, uint32_t start, uint32_t removed, uint32_t inserted, const Vim::EditBatch &batch)
{
    const Vim::CursorEdit *edit = batch.find(start);
    if (position >= start && position <= start + inserted && edit && edit->range.last == start + removed)
        return uint32_t(edit->newStart + std::min<size_t>(position - start, edit->text.size()));
    if (position > start + inserted)
        position = position - inserted + removed;
    return uint32_t(batch.map(position));
}
