#include "VimMulti.hpp"

#include <algorithm>
#include <utility>

namespace Vim {

EditBatch::EditBatch(std::vector<CursorEdit> changes)
{
    std::stable_sort(changes.begin(), changes.end(), [](const CursorEdit &a, const CursorEdit &b) {
        if (a.range.first != b.range.first)
            return a.range.first < b.range.first;
        return a.range.last > b.range.last;
    });
    // A command can reach the same line or text object from several cursors.
    for (auto &edit : changes) {
        if (!edits.empty()) {
            auto &last = edits.back();
            if (edit.range.first < last.range.last || edit.range.first == last.range.first) {
                if (last.text.empty() && edit.text.empty()) {
                    last.range.last = std::max(last.range.last, edit.range.last);
                } else if (last.range.size() == last.text.size() && edit.range.size() == edit.text.size() &&
                           edit.range.last > last.range.last) {
                    last.text.append(edit.text, last.range.last - edit.range.first);
                    last.range.last = edit.range.last;
                }
                continue;
            }
        }
        edits.push_back(std::move(edit));
    }
    starts.reserve(edits.size());
    Offset oldEnd = 0;
    Offset newEnd = 0;
    for (const auto &edit : edits) {
        starts.push_back(newEnd + edit.range.first - oldEnd);
        oldEnd = edit.range.last;
        newEnd = starts.back() + edit.text.size();
    }
}

Offset EditBatch::map(Offset position, bool after) const
{
    if (position == NoOffset)
        return position;
    auto past = std::upper_bound(edits.begin(), edits.end(), position,
                                 [](Offset at, const CursorEdit &edit) { return at < edit.range.first; });
    if (past == edits.begin())
        return position;
    Offset index = Offset(past - edits.begin() - 1);
    const auto &edit = edits[index];
    if (position < edit.range.last && edit.range.size() == edit.text.size())
        return starts[index] + position - edit.range.first;
    if (position < edit.range.last || (!after && position == edit.range.first))
        return starts[index];
    return starts[index] + edit.text.size() + position - edit.range.last;
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

std::vector<Text> ClipboardLines(Text text, Offset count)
{
    std::vector<Text> lines;
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
            host.read(host.context, {offset, offset + 1}, &unit);
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
    std::vector<Text> lines;

    void load()
    {
        if (loaded)
            return;
        loaded = true;
        if (host.readClipboard)
            value = host.readClipboard(host.context);
        if (value && value->cursors.size() != count)
            lines = ClipboardLines(value->text, count);
    }

    std::optional<Register> read(Offset index)
    {
        load();
        if (!value)
            return {};
        if (value->cursors.size() == count)
            return *value->cursors[index];
        if (lines.empty())
            return value;
        Register part;
        part.text = lines[index];
        return part;
    }
};

// A command usually replaces one small range. Unchanged text and its line index
// stay in the editor, so planning a cursor never copies the rest of the file.
struct Preview {
    const Source &source;
    std::vector<Piece> pieces;
    Offset length;
    Offset rows;
    ClusterInText clusterInText;
    FindInText findInText;
    CursorClipboard &clipboard;
    Offset cursorIndex;
    std::optional<std::u16string> writtenClipboard;
    std::vector<Range> flashes;
    Kind flashKind = Kind::Character;
    bool primary;

    Preview(const Source &base, bool active, ClusterInText cluster, FindInText find,
            CursorClipboard &input, Offset index)
        : source(base), length(base.length), rows(base.rows), clusterInText(cluster),
          findInText(find), clipboard(input), cursorIndex(index), primary(active) {}

    const Host &host() const { return source.host; }
    bool changed = false;

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
                piece.sourceRow = host().lineAt(host().context, piece.source);
                piece.breaks = host().lineAt(host().context, end) - piece.sourceRow;
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
            host().read(host().context, range, output);
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
                host().read(host().context, {piece.source + start, piece.source + start + count}, output);
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
            return host().lineAt(host().context, position);
        for (const auto &piece : pieces) {
            if (position >= piece.end())
                continue;
            Offset at = position - piece.start;
            Offset relative = piece.original() ?
                host().lineAt(host().context, piece.source + at) - piece.sourceRow :
                Offset(std::upper_bound(piece.lineStarts.begin(), piece.lineStarts.end(), at) - piece.lineStarts.begin());
            return piece.row + relative;
        }
        return rows - 1;
    }

    Offset lineStart(Offset row) const
    {
        if (!changed)
            return host().lineStart(host().context, row);
        if (!row)
            return 0;
        for (const auto &piece : pieces) {
            if (row > piece.row + piece.breaks)
                continue;
            Offset relative = row - piece.row;
            if (!piece.original())
                return piece.start + piece.lineStarts[relative - 1];
            Offset end = piece.source + piece.length;
            if (piece.sourceRow + relative > host().lineAt(host().context, end))
                return piece.end(); // The piece ends with a newly separated CR.
            return piece.start + host().lineStart(host().context, piece.sourceRow + relative) - piece.source;
        }
        return length;
    }

    Range cluster(Offset position) const
    {
        if (!changed)
            return host().cluster(host().context, position);
        for (const auto &piece : pieces) {
            if (!piece.original() || position < piece.start || position >= piece.end())
                continue;
            Offset at = piece.source + position - piece.start;
            Range original = host().cluster(host().context, at);
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

    std::vector<CursorEdit> edits() const
    {
        std::vector<CursorEdit> result;
        if (!changed)
            return result;
        Offset start = 0;
        std::u16string inserted;
        for (const auto &piece : pieces) {
            if (piece.original()) {
                if (piece.source > start || !inserted.empty()) {
                    result.push_back({{start, piece.source}, std::move(inserted)});
                    inserted.clear();
                }
                start = piece.source + piece.length;
            } else {
                inserted.append(piece.text);
            }
        }
        if (start < source.length || !inserted.empty())
            result.push_back({{start, source.length}, std::move(inserted)});
        return result;
    }

    Host callbacks();
};

Host Preview::callbacks()
{
    return {
        .context = this,
        .length = [](void *p) { return static_cast<Preview *>(p)->length; },
        .lineCount = [](void *p) { return static_cast<Preview *>(p)->rows; },
        .lineAt = [](void *p, Offset at) { return static_cast<Preview *>(p)->lineAt(at); },
        .lineStart = [](void *p, Offset row) { return static_cast<Preview *>(p)->lineStart(row); },
        .read = [](void *p, Range range, char16_t *output) { static_cast<Preview *>(p)->read(range, output); },
        .cluster = source.host.cluster && clusterInText ? +[](void *p, Offset at) {
            return static_cast<Preview *>(p)->cluster(at);
        } : nullptr,
        .structural = [](void *p, Offset at) {
            auto &preview = *static_cast<Preview *>(p);
            auto &host = preview.host();
            Offset original = preview.originalPosition(at);
            return original == NoOffset || !host.structural || host.structural(host.context, original);
        },
        .replace = [](void *p, Range r, Text text) { static_cast<Preview *>(p)->replace(r, text); },
        .recordUndo = nullptr,
        .undo = nullptr,
        .flash = [](void *p, const std::vector<Range> &ranges, Kind kind) {
            auto &preview = *static_cast<Preview *>(p);
            preview.flashKind = kind;
            preview.flashes.insert(preview.flashes.end(), ranges.begin(), ranges.end());
        },
        .readClipboard = [](void *p) {
            auto &preview = *static_cast<Preview *>(p);
            return preview.clipboard.read(preview.cursorIndex);
        },
        .writeClipboard = [](void *p, Text text) { static_cast<Preview *>(p)->writtenClipboard.emplace(text); },
        .find = [](void *p, Text pattern, Range scope, bool backwards, bool ignoreCase, bool captures) {
            auto &preview = *static_cast<Preview *>(p);
            auto &host = preview.host();
            if (!preview.changed && host.find)
                return host.find(host.context, pattern, scope, backwards, ignoreCase, captures);
            if (preview.findInText)
                return preview.findInText(preview.read({0, preview.length}), pattern, scope, backwards, ignoreCase, captures);
            return std::optional<Match>{};
        },
        .viewport = [](void *p) {
            auto &preview = *static_cast<Preview *>(p);
            auto &host = preview.host();
            return host.viewport ? host.viewport(host.context) : Range{0, preview.rows};
        },
        .scroll = primary && source.host.scroll ? +[](void *p, Offset row) {
            auto &host = static_cast<Preview *>(p)->host();
            host.scroll(host.context, row);
        } : nullptr,
        .action = primary && source.host.action ? +[](void *p, Action action, Text text, bool force) {
            auto &host = static_cast<Preview *>(p)->host();
            host.action(host.context, action, text, force);
        } : nullptr,
        .planInsert = source.host.planInsert ? +[](void *p, Key key, Offset at, unsigned tab,
                                                 unsigned indent, bool spaces, bool automatic) {
            auto &preview = *static_cast<Preview *>(p);
            auto &host = preview.host();
            if (preview.changed)
                return std::optional<InsertEdit>{};
            return host.planInsert(host.context, key, at, tab, indent, spaces, automatic);
        } : nullptr,
        .finishInsertEdit = source.host.finishInsertEdit ? +[](void *p) {
            auto &host = static_cast<Preview *>(p)->host();
            host.finishInsertEdit(host.context);
        } : nullptr,
        .indentAfter = source.host.indentAfter ? +[](void *p, Offset at, unsigned tab, unsigned indent, bool spaces) {
            auto &preview = *static_cast<Preview *>(p);
            auto &host = preview.host();
            Offset original = preview.originalPosition(at);
            return original == NoOffset ? std::u16string() : host.indentAfter(host.context, original, tab, indent, spaces);
        } : nullptr,
        .fileName = source.host.fileName ? +[](void *p) {
            auto &host = static_cast<Preview *>(p)->host();
            return host.fileName(host.context);
        } : nullptr,
        .fileMark = source.host.fileMark ? +[](void *p, char32_t key) {
            auto &host = static_cast<Preview *>(p)->host();
            return host.fileMark(host.context, key);
        } : nullptr,
        .setFileMark = primary && source.host.setFileMark ? +[](void *p, char32_t key, Offset at) {
            auto &host = static_cast<Preview *>(p)->host();
            host.setFileMark(host.context, key, at);
        } : nullptr,
        .comments = source.host.comments ? +[](void *p) {
            auto &host = static_cast<Preview *>(p)->host();
            return host.comments(host.context);
        } : nullptr,
        .definition = source.host.definition ? +[](void *p, Offset at) {
            auto &host = static_cast<Preview *>(p)->host();
            return host.definition(host.context, at);
        } : nullptr,
        .fold = primary && source.host.fold ? +[](void *p, char32_t key, Offset at) {
            auto &host = static_cast<Preview *>(p)->host();
            return host.fold(host.context, key, at);
        } : nullptr,
        .stepRow = source.host.stepRow ? +[](void *p, Offset row, bool down, Offset count) {
            auto &preview = *static_cast<Preview *>(p);
            auto &host = preview.host();
            return preview.changed ? (down ? row + count : row - std::min(row, count)) :
                                     host.stepRow(host.context, row, down, count);
        } : nullptr,
        .hiddenRows = source.host.hiddenRows ? +[](void *p, Range visible) {
            auto &host = static_cast<Preview *>(p)->host();
            return host.hiddenRows(host.context, visible);
        } : nullptr,
        .batch = true,
    };
}

template<typename Map>
static void Translate(State &state, Map map)
{
    state.cursor = map(state.cursor);
    state.anchor = map(state.anchor);
    state.commandStart = map(state.commandStart);
    state.lastInsert = map(state.lastInsert);
    state.lastAnchor = map(state.lastAnchor);
    state.lastVisualCursor = map(state.lastVisualCursor);
    state.searchPreview = map(state.searchPreview);
    state.exNextLine = map(state.exNextLine);
    state.exEnd = map(state.exEnd);
    state.insertStart = map(state.insertStart);
    state.blockReturn = map(state.blockReturn);
    auto range = [&](Range &r) { r = {map(r.first), map(r.last)}; };
    if (!state.automaticIndent.empty())
        range(state.automaticIndent);
    for (auto &edit : state.replacements)
        edit.at = map(edit.at);
    for (auto &mark : state.marks)
        mark = map(mark);
    for (auto &jump : state.jumps)
        jump = map(jump);
    for (auto &change : state.changes)
        change = map(change);
    for (auto &selection : state.occurrences)
        range(selection);
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

void MoveCursorOffsets(State &state, const EditBatch &batch, bool after)
{
    Translate(state, [&](Offset position) { return batch.map(position, after); });
    state.lineUndo.reset();
}

void MoveCursorOffsets(State &state, Range range, Offset length)
{
    Translate(state, [&](Offset position) {
        if (position == NoOffset || position < range.first)
            return position;
        return position < range.last ? range.first : position - range.size() + length;
    });
    state.lineUndo.reset();
}

static Offset Rebase(Offset position, const EditBatch &local, const EditBatch &all)
{
    if (position == NoOffset)
        return position;
    auto past = std::upper_bound(local.starts.begin(), local.starts.end(), position);
    if (past == local.starts.begin())
        return all.map(position);
    Offset index = Offset(past - local.starts.begin() - 1);
    const auto &edit = local.edits[index];
    Offset relative = position - local.starts[index];
    if (relative <= edit.text.size()) {
        const auto *shared = all.find(edit.range.first);
        if (shared)
            return all.starts[shared - all.edits.data()] + std::min(relative, shared->text.size());
        if (edit.range.size() == edit.text.size())
            return all.map(edit.range.first + relative);
        return all.map(edit.range.first, false);
    }
    return all.map(edit.range.last + relative - edit.text.size());
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
    Source source{host, host.length(host.context), host.lineCount(host.context)};
    Registers local = registers;
    auto saved = registers.slots;
    auto primarySlots = saved;
    std::array<std::vector<std::shared_ptr<const Register>>, 128> written;
    std::vector<EditBatch> planned;
    planned.reserve(states.size());
    std::vector<CursorEdit> changes;
    changes.reserve(states.size());
    std::vector<Range> flashes;
    Kind flashKind = Kind::Character;
    std::u16string clipboardOutput;
    bool wroteClipboard = false;

    CursorClipboard clipboard{host, states.size(), false, {}, {}};
    auto pasteParts = key == Key::Paste ? ClipboardLines(text, states.size()) : std::vector<Text>{};
    if (key == Key::Paste) {
        clipboard.load();
        if (clipboard.value && clipboard.value->text == text && clipboard.value->cursors.size() == states.size()) {
            pasteParts.clear();
            for (const auto &part : clipboard.value->cursors)
                pasteParts.push_back(part->text);
        }
    }

    for (Offset i = 0; i < states.size(); ++i) {
        State &state = *states[i];
        bool active = &state == &primary;
        for (Offset slot = 0; slot < saved.size(); ++slot) {
            const auto &value = saved[slot];
            local.slots[slot] = value && value->cursors.size() == states.size() ? value->cursors[i] : value;
        }
        const auto inputSlots = local.slots;
        Preview preview(source, active, cluster, find, clipboard, i);
        Host callbacks = preview.callbacks();
        if (key == Key::None)
            FlushMappings(state, callbacks, local);
        else
            Feed(state, callbacks, local, key, pasteParts.empty() ? text : pasteParts[i], smart);
        if (active)
            primarySlots = local.slots;
        for (Offset slot = 0; slot < saved.size(); ++slot) {
            if (local.slots[slot] != inputSlots[slot]) {
                if (written[slot].empty())
                    written[slot].resize(states.size());
                written[slot][i] = local.slots[slot];
            }
        }
        if (preview.writtenClipboard) {
            wroteClipboard = true;
            AppendClipboard(clipboardOutput, *preview.writtenClipboard);
        }
        flashKind = preview.flashes.empty() ? flashKind : preview.flashKind;
        flashes.insert(flashes.end(), preview.flashes.begin(), preview.flashes.end());
        auto edits = preview.edits();
        changes.insert(changes.end(), edits.begin(), edits.end());
        planned.emplace_back(std::move(edits));
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
            host.writeClipboard(host.context, clipboardOutput);
    }

    EditBatch all(std::move(changes));
    if (!all.edits.empty()) {
        for (Offset i = 0; i < states.size(); ++i) {
            Translate(*states[i], [&](Offset position) { return Rebase(position, planned[i], all); });
        }
    }
    return {std::move(all), std::move(flashes), flashKind};
}

} // namespace Vim