#include "VimMulti.hpp"

#include <algorithm>
#include <bit>
#include <utility>

namespace Vim {

EditBatch::EditBatch(std::vector<CursorEdit> changes)
{
    assign(std::move(changes), EditOrder::Cursors);
}

bool EditBatch::assign(std::vector<CursorEdit> changes, EditOrder order)
{
    auto less = [order](const CursorEdit &a, const CursorEdit &b) {
        if (a.range.first != b.range.first)
            return a.range.first < b.range.first;
        return order == EditOrder::Cursors && a.range.last > b.range.last;
    };
    if (!std::is_sorted(changes.begin(), changes.end(), less))
        std::stable_sort(changes.begin(), changes.end(), less);

    size_t count = 0;
    for (size_t i = 0; i < changes.size(); ++i) {
        auto &edit = changes[i];
        if (count) {
            auto &last = changes[count - 1];
            if (edit.range.first < last.range.last || edit.range.first == last.range.first) {
                if (order == EditOrder::Server) {
                    if (edit.range.first < last.range.last)
                        return false;

                    last.range.last = edit.range.last;
                    last.text += edit.text;
                } else if (last.text.empty() && edit.text.empty()) {
                    last.range.last = std::max(last.range.last, edit.range.last);
                } else if (last.range.size() == last.text.size() && edit.range.size() == edit.text.size() &&
                           edit.range.last > last.range.last) {
                    last.text.append(edit.text, last.range.last - edit.range.first);
                    last.range.last = edit.range.last;
                }
                continue;
            }
        }
        if (count != i)
            changes[count] = std::move(edit);
        ++count;
    }

    changes.resize(count);
    if (!count || changes.capacity() > std::bit_ceil(count))
        changes.shrink_to_fit();

    Offset oldEnd = 0;
    Offset newEnd = 0;
    for (auto &edit : changes) {
        edit.newStart = newEnd + edit.range.first - oldEnd;
        oldEnd = edit.range.last;
        newEnd = edit.newStart + edit.text.size();
    }

    edits = std::move(changes);
    return true;
}

Offset EditBatch::map(Offset position, bool after) const
{
    if (position == NoOffset)
        return position;
    auto past = std::upper_bound(edits.begin(), edits.end(), position,
                                 [](Offset at, const CursorEdit &edit) { return at < edit.range.first; });
    if (past == edits.begin())
        return position;
    const auto &edit = *(past - 1);
    if (position < edit.range.last && edit.range.size() == edit.text.size())
        return edit.newStart + position - edit.range.first;
    if (position < edit.range.last || (!after && position == edit.range.first))
        return edit.newStart;
    return edit.newStart + edit.text.size() + position - edit.range.last;
}

const CursorEdit *EditBatch::find(Offset first) const
{
    auto it = std::lower_bound(edits.begin(), edits.end(), first,
                              [](const CursorEdit &edit, Offset at) { return edit.range.first < at; });
    return it != edits.end() && it->range.first == first ? &*it : nullptr;
}

bool EditBatch::overlaps(Range range) const
{
    auto it = std::lower_bound(edits.begin(), edits.end(), range.first,
                               [](const CursorEdit &edit, Offset at) { return edit.range.last <= at; });
    return it != edits.end() && it->range.first < range.last;
}

std::vector<Text> ClipboardParts(Text text, Offset count, const Register *clipboard)
{
    std::vector<Text> lines;
    if (clipboard && clipboard->text == text && clipboard->cursors.size() == count) {
        lines.reserve(count);
        for (const auto &part : clipboard->cursors)
            lines.push_back(part->text);
        return lines;
    }

    Offset first = 0;
    for (Offset at = 0; at < text.size(); ++at) {
        if (text[at] != u'\r' && text[at] != u'\n' && text[at] != 0x2028 && text[at] != 0x2029)
            continue;
        lines.push_back(text.substr(first, at - first));
        if (text[at] == u'\r' && at + 1 < text.size() && text[at + 1] == u'\n')
            ++at;
        first = at + 1;
        if (lines.size() > count)
            return {};
    }
    if (first < text.size() || lines.size() != count)
        lines.push_back(text.substr(first));
    if (lines.size() != count)
        lines.clear();
    return lines;
}

static bool Break(char16_t unit)
{
    return unit == u'\r' || unit == u'\n' || unit == 0x2028 || unit == 0x2029;
}

struct Source {
    const Host &host;
    Offset length;
    Offset rows;

    char16_t at(Offset offset) const
    {
        char16_t unit = 0;
        if (offset < length)
            host.read(host.document, {offset, offset + 1}, &unit);
        return unit;
    }
};

struct Piece {
    Offset start = 0;
    Offset source = NoOffset;
    Offset length = 0;
    Offset row = 0;
    Offset breaks = 0;
    Offset sourceRow = 0;
    std::u16string text;
    std::vector<Offset> lineStarts;

    bool original() const { return source != NoOffset; }
    Offset end() const { return start + length; }
};

struct CursorClipboard {
    const Host &host;
    Offset count;
    bool loaded = false;
    std::optional<Register> value;
    std::optional<std::vector<Text>> lines;

    void load()
    {
        if (loaded)
            return;
        loaded = true;
        if (host.readClipboard)
            value = host.readClipboard(host.document);
    }

    std::optional<Register> read(Offset index)
    {
        load();
        if (!value)
            return {};
        if (value->cursors.size() == count)
            return *value->cursors[index];
        if (!lines)
            lines = ClipboardParts(value->text, count);
        if (lines->empty())
            return value;
        Register part;
        part.text = (*lines)[index];
        return part;
    }
};

struct PlannedEdit {
    Range source;
    Range result;
};

// A command usually replaces one small range. Unchanged text and its line index
// stay in the editor, so planning a cursor never copies the rest of the file.
struct Preview {
    const Source &source;
    std::vector<Piece> &pieces;
    std::vector<Range> &flashes;
    CursorClipboard &clipboard;
    ClusterInText clusterInText;
    FindInText findInText;
    Offset cursorIndex;
    bool primary;
    Offset length = source.length;
    Offset rows = source.rows;
    std::optional<std::u16string> writtenClipboard{};
    Kind flashKind = Kind::Character;
    bool changed = false;

    const Host &host() const { return source.host; }

    char16_t at(const Piece &piece, Offset offset) const
    {
        return piece.original() ? source.at(piece.source + offset) : piece.text[offset];
    }

    void index()
    {
        length = 0;
        rows = 1;
        for (Offset i = 0; i < pieces.size(); ++i) {
            Piece &piece = pieces[i];
            piece.start = length;
            piece.row = rows - 1;
            length += piece.length;
            char16_t next = i + 1 < pieces.size() ? at(pieces[i + 1], 0) : 0;
            if (piece.original()) {
                Offset end = piece.source + piece.length;
                piece.sourceRow = host().lineAt(host().document, piece.source);
                piece.breaks = host().lineAt(host().document, end) - piece.sourceRow;
                if (at(piece, piece.length - 1) == u'\r') {
                    piece.breaks += Offset(source.at(end) == u'\n');
                    piece.breaks -= Offset(next == u'\n');
                }
            } else {
                piece.lineStarts.clear();
                for (Offset p = 0; p < piece.length; ++p) {
                    char16_t unit = piece.text[p];
                    char16_t following = p + 1 < piece.length ? piece.text[p + 1] : next;
                    if (Break(unit) && (unit != u'\r' || following != u'\n'))
                        piece.lineStarts.push_back(p + 1);
                }
                piece.breaks = piece.lineStarts.size();
            }
            rows += piece.breaks;
        }
    }

    Offset split(Offset position)
    {
        Offset start = 0;
        for (Offset i = 0; i < pieces.size(); ++i) {
            Piece &piece = pieces[i];
            if (position == start)
                return i;
            Offset end = start + piece.length;
            if (position < end) {
                Offset count = position - start;
                Piece rest;
                rest.length = end - position;
                if (piece.original())
                    rest.source = piece.source + count;
                else {
                    rest.text = piece.text.substr(count);
                    piece.text.resize(count);
                }
                piece.length = count;
                pieces.insert(pieces.begin() + i + 1, std::move(rest));
                return i + 1;
            }
            start = end;
        }
        return pieces.size();
    }

    void replace(Range range, Text text)
    {
        if (!changed && source.length) {
            Piece document;
            document.source = 0;
            document.length = source.length;
            pieces.push_back(std::move(document));
        }
        changed = true;
        Offset first = split(range.first);
        Offset last = split(range.last);
        pieces.erase(pieces.begin() + first, pieces.begin() + last);
        if (!text.empty()) {
            Piece inserted;
            inserted.length = text.size();
            inserted.text = text;
            pieces.insert(pieces.begin() + first, std::move(inserted));
        }
        index();
    }

    void read(Range range, char16_t *output) const
    {
        if (!changed) {
            host().read(host().document, range, output);
            return;
        }
        for (const auto &piece : pieces) {
            Offset first = std::max(piece.start, range.first);
            Offset last = std::min(piece.end(), range.last);
            if (last <= first)
                continue;
            Offset count = last - first;
            Offset start = first - piece.start;
            if (piece.original())
                host().read(host().document, {piece.source + start, piece.source + start + count}, output);
            else
                std::copy_n(piece.text.data() + start, count, output);
            output += count;
        }
    }

    std::u16string read(Range range) const
    {
        std::u16string text(range.size(), 0);
        if (!text.empty())
            read(range, text.data());
        return text;
    }

    Offset lineAt(Offset position) const
    {
        if (!changed)
            return host().lineAt(host().document, position);
        for (const auto &piece : pieces) {
            if (position >= piece.end())
                continue;
            Offset at = position - piece.start;
            Offset relative = piece.original() ?
                host().lineAt(host().document, piece.source + at) - piece.sourceRow :
                Offset(std::upper_bound(piece.lineStarts.begin(), piece.lineStarts.end(), at) - piece.lineStarts.begin());
            return piece.row + relative;
        }
        return rows - 1;
    }

    Offset lineStart(Offset row) const
    {
        if (!changed)
            return host().lineStart(host().document, row);
        if (!row)
            return 0;
        for (const auto &piece : pieces) {
            if (row > piece.row + piece.breaks)
                continue;
            Offset relative = row - piece.row;
            if (!piece.original())
                return piece.start + piece.lineStarts[relative - 1];
            Offset end = piece.source + piece.length;
            if (piece.sourceRow + relative > host().lineAt(host().document, end))
                return piece.end(); // The piece ends with a newly separated CR.
            return piece.start + host().lineStart(host().document, piece.sourceRow + relative) - piece.source;
        }
        return length;
    }

    Range cluster(Offset position) const
    {
        if (!changed)
            return host().cluster(host().document, position);
        for (const auto &piece : pieces) {
            if (!piece.original() || position < piece.start || position >= piece.end())
                continue;
            Offset at = piece.source + position - piece.start;
            Range original = host().cluster(host().document, at);
            if (original.first > piece.source && original.last < piece.source + piece.length)
                return {piece.start + original.first - piece.source, piece.start + original.last - piece.source};
            break;
        }
        Offset row = lineAt(position);
        Offset start = lineStart(row);
        auto text = read({start, row + 1 < rows ? lineStart(row + 1) : length});
        Range result = clusterInText(text, position - start);
        return {start + result.first, start + result.last};
    }

    Offset originalPosition(Offset position) const
    {
        if (!changed)
            return position;
        for (const auto &piece : pieces) {
            if (position >= piece.start && position < piece.end())
                return piece.original() ? piece.source + position - piece.start : NoOffset;
        }
        return position == length ? source.length : NoOffset;
    }

    void appendEdits(std::vector<CursorEdit> &changes, std::vector<PlannedEdit> &positions)
    {
        if (!changed)
            return;

        Offset start = 0;
        std::u16string inserted;
        auto append = [&](Offset sourceEnd, Offset resultEnd) {
            positions.push_back({{start, sourceEnd}, {resultEnd - inserted.size(), resultEnd}});
            changes.push_back({{start, sourceEnd}, std::move(inserted)});
            inserted.clear();
        };
        for (auto &piece : pieces) {
            if (piece.original()) {
                if (piece.source > start || !inserted.empty())
                    append(piece.source, piece.start);
                start = piece.source + piece.length;
            } else if (inserted.empty()) {
                inserted = std::move(piece.text);
            } else {
                inserted.append(piece.text);
            }
        }

        if (start < source.length || !inserted.empty())
            append(source.length, length);
    }

    Host callbacks();
};

Host Preview::callbacks()
{
    Host callbacks = source.host;
    callbacks.document = this;
    if (!primary) {
        callbacks.scroll = nullptr;
        callbacks.action = nullptr;
        callbacks.setFileMark = nullptr;
        callbacks.fold = nullptr;
    }

    callbacks.length = [](void *p) { return static_cast<Preview *>(p)->length; };
    callbacks.lineCount = [](void *p) { return static_cast<Preview *>(p)->rows; };
    callbacks.lineAt = [](void *p, Offset at) { return static_cast<Preview *>(p)->lineAt(at); };
    callbacks.lineStart = [](void *p, Offset row) { return static_cast<Preview *>(p)->lineStart(row); };
    callbacks.read = [](void *p, Range range, char16_t *output) { static_cast<Preview *>(p)->read(range, output); };
    callbacks.cluster = source.host.cluster && clusterInText ? +[](void *p, Offset at) {
        return static_cast<Preview *>(p)->cluster(at);
    } : nullptr;
    callbacks.structural = [](void *p, Offset at) {
        auto &preview = *static_cast<Preview *>(p);
        auto &host = preview.host();
        Offset original = preview.originalPosition(at);
        return original == NoOffset || !host.structural || host.structural(host.document, original);
    };
    callbacks.replace = [](void *p, Range r, Text text) { static_cast<Preview *>(p)->replace(r, text); };
    callbacks.recordUndo = nullptr;
    callbacks.undo = nullptr;
    callbacks.flash = [](void *p, const std::vector<Range> &ranges, Kind kind) {
        auto &preview = *static_cast<Preview *>(p);
        preview.flashKind = kind;
        preview.flashes.insert(preview.flashes.end(), ranges.begin(), ranges.end());
    };
    callbacks.readClipboard = [](void *p) {
        auto &preview = *static_cast<Preview *>(p);
        return preview.clipboard.read(preview.cursorIndex);
    };
    callbacks.writeClipboard = [](void *p, Text text) { static_cast<Preview *>(p)->writtenClipboard.emplace(text); };
    callbacks.find = [](void *p, Text pattern, Range scope, bool backwards, bool ignoreCase, bool captures) {
        auto &preview = *static_cast<Preview *>(p);
        auto &host = preview.host();
        if (!preview.changed && host.find)
            return host.find(host.document, pattern, scope, backwards, ignoreCase, captures);
        if (preview.findInText)
            return preview.findInText(preview.read({0, preview.length}), pattern, scope, backwards, ignoreCase, captures);
        return std::optional<Match>{};
    };
    callbacks.viewport = [](void *p) {
        auto &preview = *static_cast<Preview *>(p);
        auto &host = preview.host();
        return host.viewport ? host.viewport(host.document) : Range{0, preview.rows};
    };
    callbacks.planInsert = source.host.planInsert ? +[](void *p, Key key, Offset at, unsigned tab,
                                             unsigned indent, bool spaces, bool automatic) {
        auto &preview = *static_cast<Preview *>(p);
        auto &host = preview.host();
        if (preview.changed)
            return std::optional<InsertEdit>{};
        return host.planInsert(host.document, key, at, tab, indent, spaces, automatic);
    } : nullptr;
    callbacks.indentAfter = source.host.indentAfter ? +[](void *p, Offset at, unsigned tab, unsigned indent, bool spaces) {
        auto &preview = *static_cast<Preview *>(p);
        auto &host = preview.host();
        Offset original = preview.originalPosition(at);
        return original == NoOffset ? std::u16string() : host.indentAfter(host.document, original, tab, indent, spaces);
    } : nullptr;
    callbacks.stepRow = source.host.stepRow ? +[](void *p, Offset row, bool down, Offset count) {
        auto &preview = *static_cast<Preview *>(p);
        auto &host = preview.host();
        return preview.changed ? (down ? row + count : row - std::min(row, count)) :
                                 host.stepRow(host.document, row, down, count);
    } : nullptr;
    callbacks.batch = true;
    callbacks.inlayAt = source.host.inlayAt ? +[](void *p, Offset at) {
        auto &preview = *static_cast<Preview *>(p);
        const auto &host = preview.host();
        return !preview.changed && host.inlayAt(host.document, at);
    } : nullptr;
    callbacks.writeCursorClipboard = nullptr;
    return callbacks;
}

template<typename Map>
static void Translate(State &state, Map map)
{
    state.cursor = map(state.cursor);
    state.anchor = map(state.anchor);
    state.commandStart = map(state.commandStart);
    state.searchPreview = map(state.searchPreview);
    state.insertStart = map(state.insertStart);
    state.blockReturn = map(state.blockReturn);
    MapHistory(state, map);
    auto range = [&](Range &r) { r = {map(r.first), map(r.last)}; };
    if (!state.automaticIndent.empty())
        range(state.automaticIndent);
    for (auto &edit : state.replacements)
        edit.at = map(edit.at);
    for (auto &caret : state.insertMirrors)
        caret = map(caret);
    for (auto &surround : state.surrounds) {
        range(surround.left);
        range(surround.right);
    }
    if (state.change && !state.change->edits.empty()) {
        state.change->edits.front().at = map(state.change->edits.front().at);
        state.change->after = state.cursor;
    }
}

void MoveCursorOffsets(State &state, const EditMap &edit, bool after)
{
    if (edit.batch)
        Translate(state, [&](Offset position) { return edit.batch->map(position, after); });
    else
        Translate(state, [&](Offset position) { return OffsetAfterEdit(position, edit.range, edit.inserted); });

    state.beforeInlay = false;
    state.lineUndo.reset();
}

static Offset Rebase(Offset position, std::span<const PlannedEdit> local, const EditBatch &all)
{
    if (position == NoOffset)
        return position;
    auto past = std::upper_bound(local.begin(), local.end(), position,
                                 [](Offset at, const PlannedEdit &edit) { return at < edit.result.first; });
    if (past == local.begin())
        return all.map(position);

    const auto &edit = *(past - 1);
    if (position <= edit.result.last) {
        Offset relative = position - edit.result.first;
        const auto *shared = all.find(edit.source.first);
        if (shared)
            return shared->newStart + std::min(relative, shared->text.size());
        if (edit.source.size() == edit.result.size())
            return all.map(edit.source.first + relative);
        return all.map(edit.source.first, false);
    }

    return all.map(edit.source.last + position - edit.result.last);
}

static void AppendClipboard(std::u16string &text, Text piece)
{
    if (!text.empty() && !Break(text.back()))
        text.push_back(u'\n');
    text.append(piece);
}

CursorRun FeedCursors(std::span<State *> states, State &primary, const Host &host,
                      Registers &registers, Key key, Text text, bool smart,
                      ClusterInText cluster, FindInText find)
{
    Source source{host, host.length(host.document), host.lineCount(host.document)};
    Registers local = registers;
    auto saved = registers.slots;
    auto primarySlots = saved;
    std::array<std::vector<std::shared_ptr<const Register>>, 128> written;
    std::vector<Offset> cursorEnds(states.size() + 1);
    std::vector<PlannedEdit> positions;
    std::vector<CursorEdit> changes;
    std::vector<Range> flashes;
    Kind flashKind = Kind::Character;
    std::u16string clipboardOutput;
    bool wroteClipboard = false;

    CursorClipboard clipboard{host, states.size(), false, {}, {}};
    std::vector<Text> pasteParts;
    if (key == Key::Paste) {
        clipboard.load();
        pasteParts = ClipboardParts(text, states.size(), clipboard.value ? &*clipboard.value : nullptr);
    }

    std::vector<Piece> pieces;
    std::array<const Register *, saved.size()> inputSlots;
    for (Offset i = 0; i < states.size(); ++i) {
        State &state = *states[i];
        bool active = &state == &primary;
        for (Offset slot = 0; slot < saved.size(); ++slot) {
            const auto &value = saved[slot];
            local.slots[slot] = value && value->cursors.size() == states.size() ? value->cursors[i] : value;
            inputSlots[slot] = local.slots[slot].get();
        }

        pieces.clear();
        size_t firstFlash = flashes.size();
        Preview preview{source, pieces, flashes, clipboard, cluster, find, i, active};
        Host callbacks = preview.callbacks();
        if (key == Key::None)
            FlushMappings(state, callbacks, local);
        else
            Feed(state, callbacks, local, key, pasteParts.empty() ? text : pasteParts[i], smart);
        if (active)
            primarySlots = local.slots;
        for (Offset slot = 0; slot < saved.size(); ++slot) {
            if (local.slots[slot].get() != inputSlots[slot]) {
                if (written[slot].empty())
                    written[slot].resize(states.size());
                written[slot][i] = local.slots[slot];
            }
        }
        if (preview.writtenClipboard) {
            wroteClipboard = true;
            AppendClipboard(clipboardOutput, *preview.writtenClipboard);
        }
        if (flashes.size() != firstFlash)
            flashKind = preview.flashKind;
        if (preview.changed && !changes.capacity()) {
            positions.reserve(states.size());
            changes.reserve(states.size());
        }

        preview.appendEdits(changes, positions);
        cursorEnds[i + 1] = positions.size();
    }
    for (Offset slot = 0; slot < saved.size(); ++slot) {
        auto &values = written[slot];
        if (values.empty())
            continue;
        auto first = std::find_if(values.begin(), values.end(), [](const auto &value) { return bool(value); });
        if (first == values.end()) {
            registers.slots[slot] = primarySlots[slot];
            continue;
        }
        if (!(*first)->keys.empty()) {
            registers.slots[slot] = *first;
            continue;
        }
        Register value;
        value.kind = (*first)->kind;
        for (auto &part : values) {
            if (!part)
                part = std::make_shared<Register>();
            if (part->kind != value.kind)
                value.kind = Kind::Character;
            AppendClipboard(value.text, part->text);
        }
        value.cursors = std::move(values);
        registers.slots[slot] = std::make_shared<Register>(std::move(value));
    }
    if (wroteClipboard) {
        const auto &value = registers.slots['"'];
        if (host.writeCursorClipboard && value && value->text == clipboardOutput)
            host.writeCursorClipboard(host.context, *value);
        else if (host.writeClipboard)
            host.writeClipboard(host.document, clipboardOutput);
    }

    EditBatch all(std::move(changes));
    if (!all.edits.empty()) {
        for (Offset i = 0; i < states.size(); ++i) {
            auto local = std::span<const PlannedEdit>(positions).subspan(cursorEnds[i], cursorEnds[i + 1] - cursorEnds[i]);
            Translate(*states[i], [&](Offset position) { return Rebase(position, local, all); });
        }
    }
    return {std::move(all), std::move(flashes), flashKind};
}

} // namespace Vim