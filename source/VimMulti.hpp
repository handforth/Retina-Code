#pragma once

#include "Vim.hpp"

namespace Vim {

struct CursorEdit {
    Range range;
    std::u16string text;
};

struct EditBatch {
    std::vector<CursorEdit> edits;
    std::vector<Offset> starts;

    explicit EditBatch(std::vector<CursorEdit> changes = {});
    Offset map(Offset position, bool after = true) const;
    const CursorEdit *find(Offset first) const;
    bool overlaps(Range range) const;
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
void MoveCursorOffsets(State &state, const EditBatch &batch, bool after = true);
void MoveCursorOffsets(State &state, Range range, Offset length);
std::vector<Text> ClipboardLines(Text text, Offset count);

} // namespace Vim