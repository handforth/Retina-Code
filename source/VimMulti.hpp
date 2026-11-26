#pragma once

#include "Vim.hpp"

namespace Vim {

struct CursorEdit {
    Range range;
    std::u16string text;
    Offset newStart = 0;
};

enum class EditOrder { Cursors, Server };

struct EditBatch {
    std::vector<CursorEdit> edits;

    explicit EditBatch(std::vector<CursorEdit> changes = {});
    bool assign(std::vector<CursorEdit> changes, EditOrder order);
    Offset map(Offset position, bool after = true) const;
    const CursorEdit *find(Offset first) const;
    bool overlaps(Range range) const;
};

struct EditMap {
    Range range{};
    Offset inserted = 0;
    const EditBatch *batch = nullptr;

    Offset map(Offset position, bool after = true) const
    {
        return batch ? batch->map(position, after) : OffsetAfterEdit(position, range, inserted);
    }

    bool overlaps(Range part) const
    {
        return batch ? batch->overlaps(part) : range.first < part.last && part.first < range.last;
    }
};

struct CursorRun {
    EditBatch batch;
    std::vector<Range> flashes;
    Kind flashKind = Kind::Character;
};

using ClusterInText = Range (*)(Text, Offset);
using FindInText = std::optional<Match> (*)(Text, Text, Range, bool, bool, bool);

// States are in document order. Each command reads the same original text.
CursorRun FeedCursors(std::span<State *> states, State &primary, const Host &host,
                      Registers &registers, Key key, Text text, bool smart,
                      ClusterInText cluster, FindInText find);
void MoveCursorOffsets(State &state, const EditMap &edit, bool after = true);
std::vector<Text> ClipboardParts(Text text, Offset count, const Register *clipboard = nullptr);

} // namespace Vim