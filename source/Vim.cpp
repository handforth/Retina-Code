#include "Vim.hpp"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <utility>

namespace Vim {

static constexpr unsigned maxCount = 999999;
static constexpr unsigned maxPlayback = 100000;

struct Line {
    Offset first;
    Offset end;
    Offset next;
};

struct Buffer {
    const Host &host;
    std::optional<bool> finalNewline;
    Offset length = 0;
    Offset rows = 1;
    mutable Offset cached = NoOffset;
    mutable std::array<char16_t, 256> units;

    explicit Buffer(const Host &source, std::optional<bool> newline = {})
        : host(source), finalNewline(newline) { reset(); }

    void reset()
    {
        length = host.length(host.document);
        rows = host.lineCount(host.document);
        bool trailingEmpty = rows > 1 && host.lineStart(host.document, rows - 1) == length;
        if (trailingEmpty && finalNewline.value_or(true))
            --rows;
        cached = NoOffset;
    }

    bool endsWithNewline() const
    {
        Offset count = host.lineCount(host.document);
        return count > 1 && host.lineStart(host.document, count - 1) == length;
    }

    char16_t at(Offset position) const
    {
        if (position >= length)
            return 0;
        if (cached == NoOffset || position < cached || position - cached >= units.size()) {
            cached = position - position % units.size();
            host.read(host.document, {cached, std::min(length, cached + units.size())}, units.data());
        }
        return units[position - cached];
    }

    std::u16string read(Range range) const
    {
        std::u16string text(range.size(), 0);
        if (!range.empty())
            host.read(host.document, range, text.data());
        return text;
    }

    Offset row(Offset position) const
    {
        return std::min(rows - 1, host.lineAt(host.document, std::min(position, length)));
    }

    Line line(Offset index) const;
    Offset next(Offset position) const;
    Offset prev(Offset position) const;
};

static bool Break(char32_t ch)
{
    return ch == '\n' || ch == '\r' || ch == 0x2028 || ch == 0x2029;
}

static bool Blank(char32_t ch)
{
    return ch == ' ' || ch == '\t' || ch == '\v' || ch == '\f' || ch == 0x00a0 ||
           (ch >= 0x2000 && ch <= 0x200a) || ch == 0x3000;
}

static bool Space(char32_t ch)
{
    return Blank(ch) || Break(ch);
}

static bool Digit(char32_t ch)
{
    return ch >= '0' && ch <= '9';
}

static bool Lower(char32_t ch)
{
    return ch >= 'a' && ch <= 'z';
}

static bool Upper(char32_t ch)
{
    return ch >= 'A' && ch <= 'Z';
}

static char32_t Lowercase(char32_t ch)
{
    return Upper(ch) ? ch + ('a' - 'A') : ch;
}

Line Buffer::line(Offset index) const
{
    Offset first = host.lineStart(host.document, index);
    Offset next = index + 1 < rows ? host.lineStart(host.document, index + 1) : length;
    Offset end = next;
    if (end > first && Break(at(end - 1))) {
        --end;
        if (end > first && at(end) == '\n' && at(end - 1) == '\r')
            --end;
    }
    return {first, end, next};
}

Offset Buffer::next(Offset position) const
{
    if (position >= length)
        return length;
    if (at(position) == '\r' && at(position + 1) == '\n')
        return position + 2;
    if (host.cluster && (at(position) >= 0x80 || at(position + 1) >= 0x300))
        return host.cluster(host.document, position).last;
    return position + 1;
}

Offset Buffer::prev(Offset position) const
{
    if (!position)
        return 0;
    --position;
    if (at(position) == '\n' && position && at(position - 1) == '\r')
        return position - 1;
    if (host.cluster && at(position) >= 0x80)
        return host.cluster(host.document, position).first;
    return position;
}

bool IsVisual(Mode mode)
{
    return mode == Mode::Visual || mode == Mode::VisualLine || mode == Mode::VisualBlock;
}

bool IsInsert(Mode mode)
{
    return mode == Mode::Insert || mode == Mode::Replace;
}

static Offset FirstNonblank(const Buffer &buffer, Line line)
{
    while (line.first < line.end && Blank(buffer.at(line.first)))
        ++line.first;
    return line.first;
}

static Offset NormalPosition(const Buffer &buffer, Offset position)
{
    Line line = buffer.line(buffer.row(position));
    if (position >= line.end)
        return line.end == line.first ? line.first : buffer.prev(line.end);
    return position;
}

static Offset AtColumn(const Buffer &buffer, Line line, Offset column, unsigned tabStop)
{
    Offset current = 0;
    for (Offset p = line.first; p < line.end; p = buffer.next(p)) {
        current += buffer.at(p) == '\t' ? tabStop - current % tabStop : 1;
        if (current > column)
            return p;
    }
    return line.end;
}

static Offset ColumnAt(const Buffer &buffer, Offset position, unsigned tabStop)
{
    Line line = buffer.line(buffer.row(position));
    Offset column = 0;
    for (Offset p = line.first; p < std::min(line.end, position); p = buffer.next(p))
        column += buffer.at(p) == '\t' ? tabStop - column % tabStop : 1;
    return column;
}

Offset CursorColumn(const Host &host, Offset position, unsigned tabStop, bool finalNewline)
{
    return ColumnAt(Buffer(host, finalNewline), position, tabStop);
}

Offset CursorAtColumn(const Host &host, Offset row, Offset column, unsigned tabStop, bool finalNewline, bool block)
{
    Buffer buffer(host, finalNewline);
    if (row >= buffer.rows)
        return NoOffset;
    Offset position = AtColumn(buffer, buffer.line(row), column, tabStop);
    return block ? NormalPosition(buffer, position) : position;
}

static Offset CellWidth(const Buffer &buffer, Offset position, Offset column, unsigned tabStop)
{
    return buffer.at(position) == '\t' ? tabStop - column % tabStop : 1;
}

static Offset CellEnd(const Buffer &buffer, Offset position)
{
    return position < buffer.line(buffer.row(position)).end ? buffer.next(position) : position;
}

static Range Ordered(Offset a, Offset b)
{
    return {std::min(a, b), std::max(a, b)};
}

static std::u16string KeyText(Key key, Text text);

static std::u16string EndOfLine(const Buffer &buffer, Offset row)
{
    Line line = buffer.line(row);
    if (line.next == line.end && row)
        line = buffer.line(row - 1);
    return line.next > line.end ? buffer.read({line.end, line.next}) : u"\n";
}

static std::u16string NormalizeNewlines(Text text, Text newline)
{
    std::u16string result;
    result.reserve(text.size());
    for (Offset i = 0; i < text.size(); ++i) {
        if (Break(text[i])) {
            if (text[i] == '\r' && i + 1 < text.size() && text[i + 1] == '\n')
                ++i;
            result.append(newline);
        } else {
            result.push_back(text[i]);
        }
    }
    return result;
}

void SetCursor(State &state, const Host &host, Offset cursor)
{
    Buffer buffer(host, state.finalNewline);
    if (!state.finalNewline)
        state.finalNewline = buffer.endsWithNewline();
    state.cursor = std::min(buffer.length, cursor);
    state.beforeInlay = false;
    if (!IsInsert(state.mode) && state.mode != Mode::Command)
        state.cursor = NormalPosition(buffer, state.cursor);
    state.goalColumn = NoOffset;
    state.goalEnd = false;
}

Offset ClampNormalCursor(const Host &host, Offset cursor, std::optional<bool> finalNewline)
{
    Buffer buffer(host, finalNewline);
    return NormalPosition(buffer, std::min(buffer.length, cursor));
}

static Selection Selected(const State &state, const Buffer &buffer, Range visible = {0, NoOffset},
                          Offset cursor = NoOffset)
{
    Selection selected;
    if (!state.occurrences.empty()) {
        selected.disjoint = true;
        selected.top = buffer.row(state.occurrences.front().first);
        selected.bottom = buffer.row(state.occurrences.back().last);
        selected.ranges = state.occurrences;
        return selected;
    }
    if (cursor == NoOffset)
        cursor = state.cursor;
    Range positions = Ordered(state.anchor, cursor);
    selected.top = buffer.row(positions.first);
    selected.bottom = buffer.row(positions.last);
    if (state.mode == Mode::VisualLine) {
        selected.kind = Kind::Line;
        selected.ranges.push_back({buffer.line(selected.top).first, buffer.line(selected.bottom).next});
    } else if (state.mode == Mode::VisualBlock) {
        selected.kind = Kind::Block;
        selected.toEnd = state.goalEnd;
        Offset column = state.goalColumn != NoOffset && !state.goalEnd ? state.goalColumn :
                        ColumnAt(buffer, cursor, state.tabStop);
        Offset anchorColumn = ColumnAt(buffer, state.anchor, state.tabStop);
        selected.left = selected.toEnd ? anchorColumn : std::min(anchorColumn, column);
        Offset cursorWidth = state.goalColumn == NoOffset ? CellWidth(buffer, cursor, column, state.tabStop) : 1;
        selected.right = std::max(anchorColumn + CellWidth(buffer, state.anchor, anchorColumn, state.tabStop),
                                  column + cursorWidth);
        Offset top = std::max(selected.top, buffer.row(visible.first));
        Offset bottom = std::min(selected.bottom, buffer.row(std::min(visible.last, buffer.length)));
        for (Offset row = top; row <= bottom; ++row) {
            Line line = buffer.line(row);
            Offset first = AtColumn(buffer, line, selected.left, state.tabStop);
            Offset last = line.end;
            if (!selected.toEnd) {
                Offset edge = AtColumn(buffer, line, selected.right - 1, state.tabStop);
                last = std::min(buffer.next(edge), line.end);
            }
            selected.ranges.push_back({first, last});
        }
    } else {
        Line last = buffer.line(selected.bottom);
        Offset end = positions.last == last.end ? last.next : CellEnd(buffer, positions.last);
        selected.ranges.push_back({positions.first, end});
    }
    return selected;
}

Selection Selected(const State &state, const Host &host, Range visible, Offset cursor)
{
    if (!IsVisual(state.mode))
        return {};
    return Selected(state, Buffer(host, state.finalNewline), visible, cursor);
}

static void ClearCommand(State &state)
{
    state.op = Op::None;
    state.prefix = Prefix::None;
    state.forceMotion = false;
    state.count = 0;
    state.operatorCount = 1;
    state.selectedRegister = 0;
}

static void LeaveVisual(State &state)
{
    if (IsVisual(state.mode)) {
        state.lastVisual = state.mode;
        state.lastAnchor = state.anchor;
        state.lastVisualCursor = state.cursor;
        state.lastVisualColumn = state.goalColumn;
        state.lastVisualToEnd = state.goalEnd;
        state.mode = Mode::Normal;
        state.occurrences.clear();
        state.occurrencePattern.clear();
    }
}

void ExternalEdit(State &state, Range range, Offset inserted)
{
    state.beforeInlay = false;
    MapHistory(state, [&](Offset position) { return OffsetAfterEdit(position, range, inserted); });
}

void ForeignEdit(State &state, Range range, Offset inserted)
{
    ExternalEdit(state, range, inserted);
    state.cursor = OffsetAfterEdit(state.cursor, range, inserted);
    state.anchor = OffsetAfterEdit(state.anchor, range, inserted);
    state.commandStart = OffsetAfterEdit(state.commandStart, range, inserted);
    state.automaticIndent = {};
    state.lineUndo.reset();
    state.goalColumn = NoOffset;
    state.goalEnd = false;
}

void FinishChange(State &state)
{
    if (!state.change || state.groupChanges)
        return;
    state.change->after = state.cursor;
    state.change->afterLine = state.lineUndo;
    Offset position = state.change->edits.front().at;
    if (state.changes.empty() || state.changes.back() != position) {
        if (state.changes.size() >= 100)
            state.changes.erase(state.changes.begin());
        state.changes.push_back(position);
    }
    state.changeIndex = state.changes.size();
    if (!state.replaying && !state.inputs.empty()) {
        state.repeat = std::move(state.visualRepeat);
        state.repeat.inputs = state.inputs;
    }
    state.change.reset();
}

static void Replace(State &state, Buffer &buffer, Range range, Text replacement)
{
    auto before = buffer.read(range);
    if (before == replacement)
        return;

    bool first = !state.change;
    if (first)
        state.change = std::make_shared<Change>(Change{state.commandStart, state.cursor, {}, state.lineUndo, {}});
    Line line = buffer.line(buffer.row(range.first));
    if (buffer.host.batch || range.last > line.end || std::any_of(replacement.begin(), replacement.end(), Break)) {
        state.lineUndo.reset();
    } else if (!state.lineUndo || state.lineUndo->start != line.first) {
        state.lineUndo = std::make_shared<LineUndo>(LineUndo{line.first, range.first - line.first,
                                                           buffer.read({line.first, line.end})});
    }
    auto &edits = state.change->edits;
    if (buffer.host.batch) {
        if (edits.empty())
            edits.push_back({range.first, {}, {}});
    } else if (!edits.empty() && range.empty() && edits.back().before.empty() &&
        range.first == edits.back().at + edits.back().after.size()) {
        edits.back().after.append(replacement);
    } else {
        edits.push_back({range.first, std::move(before), std::u16string(replacement)});
    }
    ExternalEdit(state, range, replacement.size());
    buffer.host.replace(buffer.host.document, range, replacement);
    buffer.reset();
    state.goalColumn = NoOffset;
    state.goalEnd = false;
    if (first && buffer.host.recordUndo)
        buffer.host.recordUndo(buffer.host.context, state.change);
}

static void AddJump(State &state, const Buffer &buffer)
{
    Offset row = buffer.row(state.cursor);
    std::erase_if(state.jumps, [&](Offset jump) { return buffer.row(jump) == row; });
    if (state.jumps.size() >= 100)
        state.jumps.erase(state.jumps.begin());
    state.jumps.push_back(state.cursor);
}

static void SaveJump(State &state, const Buffer &buffer)
{
    if (state.jumpIndex < state.jumps.size())
        state.jumps.resize(state.jumpIndex + 1);
    AddJump(state, buffer);
    state.jumpIndex = state.jumps.size();
}

static void ListJump(State &state, const Buffer &buffer, bool forward, unsigned count)
{
    if (state.jumps.empty())
        return;
    if (state.jumpIndex == state.jumps.size()) {
        if (forward)
            return;
        AddJump(state, buffer);
        state.jumpIndex = state.jumps.size() - 1;
    }
    state.jumpIndex = forward ? std::min(state.jumps.size() - 1, state.jumpIndex + count) :
                      state.jumpIndex - std::min<Offset>(state.jumpIndex, count);
    state.cursor = NormalPosition(buffer, state.jumps[state.jumpIndex]);
    state.goalColumn = NoOffset;
    state.goalEnd = false;
}

enum class Word { Space, Keyword, Punctuation, Ideograph };

static Word WordAt(const Buffer &buffer, Offset position, bool big)
{
    char16_t ch = buffer.at(position);
    if (!ch || Space(ch))
        return Word::Space;
    if (big || Digit(ch) || Lower(ch) || Upper(ch) || ch == '_')
        return Word::Keyword;
    if (ch >= 0x3400 && ch <= 0x9fff)
        return Word::Ideograph;
    if (ch >= 0x80 && !(ch >= 0x200b && ch <= 0x206f) && !(ch >= 0x3000 && ch <= 0x303f))
        return Word::Keyword;
    return Word::Punctuation;
}

static bool EmptyLine(const Buffer &buffer, Offset position)
{
    Line line = buffer.line(buffer.row(position));
    return line.first == line.end && position == line.first;
}

static Offset ForwardWord(const Buffer &buffer, Offset position, bool big)
{
    Word first = WordAt(buffer, position, big);
    if (first != Word::Space) {
        while (position < buffer.length && WordAt(buffer, position, big) == first)
            position = buffer.next(position);
    } else if (EmptyLine(buffer, position)) {
        position = buffer.next(position);
    }
    while (position < buffer.length && WordAt(buffer, position, big) == Word::Space &&
           !EmptyLine(buffer, position))
        position = buffer.next(position);
    return position;
}

static Offset BackwardWord(const Buffer &buffer, Offset position, bool big)
{
    position = buffer.prev(position);
    while (position && WordAt(buffer, position, big) == Word::Space && !EmptyLine(buffer, position))
        position = buffer.prev(position);
    Word word = WordAt(buffer, position, big);
    while (position && word != Word::Space && WordAt(buffer, buffer.prev(position), big) == word)
        position = buffer.prev(position);
    return position;
}

static Offset EndWord(const Buffer &buffer, Offset position, bool big, bool advance)
{
    if (advance)
        position = buffer.next(position);
    while (position < buffer.length && WordAt(buffer, position, big) == Word::Space)
        position = buffer.next(position);
    Word word = WordAt(buffer, position, big);
    while (position < buffer.length && WordAt(buffer, buffer.next(position), big) == word && word != Word::Space)
        position = buffer.next(position);
    return position;
}

static Offset BackwardEnd(const Buffer &buffer, Offset position, bool big)
{
    Word word = WordAt(buffer, position, big);
    while (position && word != Word::Space && WordAt(buffer, buffer.prev(position), big) == word)
        position = buffer.prev(position);
    position = buffer.prev(position);
    while (position && WordAt(buffer, position, big) == Word::Space)
        position = buffer.prev(position);
    return position;
}

struct Motion {
    Offset to = NoOffset;
    Kind kind = Kind::Character;
    bool inclusive = false;
    bool jump = false;
    bool vertical = false;
    bool endColumn = false;
};

static Offset ColumnPosition(const State &state, const Buffer &buffer, Offset row)
{
    Line line = buffer.line(row);
    if (state.goalEnd)
        return line.end;
    Offset column = state.goalColumn == NoOffset ? ColumnAt(buffer, state.cursor, state.tabStop) : state.goalColumn;
    return AtColumn(buffer, line, column, state.tabStop);
}

static Offset StepRow(const Buffer &buffer, Offset row, bool down, Offset count)
{
    if (buffer.host.stepRow)
        return std::min(buffer.rows - 1, buffer.host.stepRow(buffer.host.document, row, down, count));
    return down ? std::min(buffer.rows - 1, row + count) : row - std::min(row, count);
}

static Motion Vertical(State &state, const Buffer &buffer, bool down, Offset count)
{
    Offset row = buffer.row(state.cursor);
    Offset target = StepRow(buffer, row, down, count);
    if (state.op != Op::None && target == row)
        return {};
    if (state.goalColumn == NoOffset)
        state.goalColumn = ColumnAt(buffer, state.cursor, state.tabStop);
    return {ColumnPosition(state, buffer, target), Kind::Line, false, false, true};
}

Offset CursorOnRow(const State &state, const Host &host, Offset row)
{
    Buffer buffer(host, state.finalNewline);
    Offset position = ColumnPosition(state, buffer, std::min(row, buffer.rows - 1));
    return state.mode == Mode::Visual ? position : NormalPosition(buffer, position);
}

template<bool vimInsert>
static Offset MoveCaret(const Buffer &buffer, Key key, Offset position, Offset &column, unsigned tabStop)
{
    const auto &host = buffer.host;
    Offset row = buffer.row(position);
    if (key == Key::Up || key == Key::Down || key == Key::PageUp || key == Key::PageDown) {
        if (column == NoOffset)
            column = ColumnAt(buffer, position, tabStop);
        Offset count = 1;
        if ((key == Key::PageUp || key == Key::PageDown) && host.viewport)
            count = std::max(Offset(1), host.viewport(host.document).size());
        bool down = key == Key::Down || key == Key::PageDown;
        return AtColumn(buffer, buffer.line(StepRow(buffer, row, down, count)), column, tabStop);
    }
    column = NoOffset;
    switch (key) {
        case Key::Left:
            return vimInsert && position <= buffer.line(row).first ? position : buffer.prev(position);
        case Key::Right:
            return vimInsert && position >= buffer.line(row).end ? position : buffer.next(position);
        case Key::WordLeft: return BackwardWord(buffer, position, false);
        case Key::WordRight:
            return vimInsert ? ForwardWord(buffer, position, false) : buffer.next(EndWord(buffer, position, false, false));
        case Key::Home: return buffer.line(row).first;
        case Key::End: return buffer.line(row).end;
        case Key::DocumentStart: return 0;
        case Key::DocumentEnd: return buffer.length;
        default: return position;
    }
}

Offset MoveEditorCursor(const Host &host, Key key, Offset position, Offset &column, unsigned tabStop)
{
    return MoveCaret<false>(Buffer(host, false), key, position, column, tabStop);
}

static char16_t Paired(char16_t ch)
{
    switch (ch) {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        case '<': return '>';
        case ')': return '(';
        case ']': return '[';
        case '}': return '{';
        case '>': return '<';
    }
    return 0;
}

static bool Opening(char16_t ch)
{
    return ch == '(' || ch == '[' || ch == '{' || ch == '<';
}

static bool Structural(const Buffer &buffer, Offset position)
{
    return !buffer.host.structural || buffer.host.structural(buffer.host.document, position);
}

static Offset MatchPair(const Buffer &buffer, Offset start, bool forward)
{
    char16_t opener = buffer.at(start);
    char16_t closer = Paired(opener);
    unsigned depth = 1;
    Offset position = start;
    bool structural = Structural(buffer, start);
    for (;;) {
        Offset next = forward ? buffer.next(position) : buffer.prev(position);
        if (next == position || next >= buffer.length)
            return NoOffset;
        position = next;
        char16_t ch = buffer.at(position);
        if ((ch == opener || ch == closer) && Structural(buffer, position) != structural)
            continue;
        if (ch == opener)
            ++depth;
        else if (ch == closer && --depth == 0)
            return position;
    }
}

static Motion Percent(const Buffer &buffer, Offset cursor, unsigned count)
{
    if (count) {
        if (count > 100)
            return {};
        Offset row = (buffer.rows * count + 99) / 100 - 1;
        return {FirstNonblank(buffer, buffer.line(row)), Kind::Line, false, true};
    }
    Line line = buffer.line(buffer.row(cursor));
    for (Offset p = cursor; p < line.end; ++p) {
        char16_t ch = buffer.at(p);
        if (Paired(ch) && ch != '<' && ch != '>')
            return {MatchPair(buffer, p, Opening(ch)), Kind::Character, true, true};
    }
    return {};
}

static Offset Sentence(const Buffer &buffer, Offset cursor, bool forward, unsigned count)
{
    Offset p = cursor;
    while (count--) {
        if (forward) {
            while (p < buffer.length) {
                char16_t ch = buffer.at(p);
                Offset next = buffer.next(p);
                if (ch == '.' || ch == '!' || ch == '?') {
                    while (next < buffer.length &&
                           (buffer.at(next) == '"' || buffer.at(next) == '\'' ||
                            buffer.at(next) == ')' || buffer.at(next) == ']'))
                        next = buffer.next(next);
                    if (next == buffer.length || Space(buffer.at(next))) {
                        p = next;
                        while (p < buffer.length && Space(buffer.at(p)) && !EmptyLine(buffer, p))
                            p = buffer.next(p);
                        break;
                    }
                }
                p = next;
                if (EmptyLine(buffer, p))
                    break;
            }
        } else {
            while (p) {
                p = buffer.prev(p);
                if (!p || EmptyLine(buffer, p))
                    break;
                if (!Space(buffer.at(p)) && Space(buffer.at(buffer.prev(p)))) {
                    Offset previous = buffer.prev(p);
                    while (previous && Space(buffer.at(previous)) && !EmptyLine(buffer, previous))
                        previous = buffer.prev(previous);
                    while (previous && (buffer.at(previous) == ')' || buffer.at(previous) == ']' ||
                                        buffer.at(previous) == '\'' || buffer.at(previous) == '"'))
                        previous = buffer.prev(previous);
                    if (buffer.at(previous) == '.' || buffer.at(previous) == '!' ||
                        buffer.at(previous) == '?' || EmptyLine(buffer, previous))
                        break;
                }
            }
        }
    }
    return p;
}

static Offset Paragraph(const Buffer &buffer, Offset position, bool down, unsigned count)
{
    Offset row = buffer.row(position);
    while (count--) {
        Offset old = row;
        while ((down && row + 1 < buffer.rows) || (!down && row)) {
            row = down ? row + 1 : row - 1;
            if (EmptyLine(buffer, buffer.line(row).first) &&
                (!EmptyLine(buffer, buffer.line(old).first) || row > old + 1 || old > row + 1))
                break;
        }
    }
    if (down && row + 1 == buffer.rows && !EmptyLine(buffer, buffer.line(row).first))
        return buffer.length;
    return buffer.line(row).first;
}

static Motion ReadMotion(State &state, const Buffer &buffer, Key key, unsigned count, bool explicitCount)
{
    Offset p = state.cursor;
    Offset row = buffer.row(p);
    Line line = buffer.line(row);
    bool big = Upper(char32_t(key));
    switch (char32_t(key)) {
        case 'h': case 8: case 127: case char32_t(Key::Left):
            for (; count && p > line.first; --count)
                p = buffer.prev(p);
            return {p};
        case 'l': case ' ': case char32_t(Key::Right):
            for (; count && p < line.end; --count)
                p = buffer.next(p);
            return {p};
        case 'j': case 14: case char32_t(Key::Down):
            return Vertical(state, buffer, true, count);
        case 'k': case 16: case char32_t(Key::Up):
            return Vertical(state, buffer, false, count);
        case '+': case '-': case '_': case '\n': case '\r': {
            bool up = key == Key('-');
            count -= key == Key('_') ? 1 : 0;
            Offset target = up ? row - std::min<Offset>(row, count) : std::min(buffer.rows - 1, row + count);
            return {FirstNonblank(buffer, buffer.line(target)), Kind::Line};
        }
        case '0': case char32_t(Key::Home):
            return {line.first};
        case '^':
            return {FirstNonblank(buffer, line)};
        case '$': case char32_t(Key::End): {
            Line target = buffer.line(std::min(buffer.rows - 1, row + count - 1));
            return {target.end, Kind::Character, true, false, false, true};
        }
        case '|':
            return {AtColumn(buffer, line, count - 1, state.tabStop)};
        case 'G': {
            Offset target = explicitCount ? std::min<Offset>(buffer.rows, count) - 1 : buffer.rows - 1;
            return {FirstNonblank(buffer, buffer.line(target)), Kind::Line, false, true};
        }
        case 'w': case 'W': case char32_t(Key::WordRight):
            if (state.op == Op::Change && !Space(buffer.at(p))) {
                for (unsigned i = 0; i < count && p < buffer.length; ++i)
                    p = EndWord(buffer, p, big, i != 0);
                return {p, Kind::Character, true};
            }
            while (count && p < buffer.length) {
                Offset next = ForwardWord(buffer, p, big);
                if (--count == 0 && state.op != Op::None && !EmptyLine(buffer, p) &&
                    next >= buffer.line(buffer.row(p)).next)
                    return {buffer.line(buffer.row(p)).end};
                p = next;
            }
            return {p};
        case 'b': case 'B': case char32_t(Key::WordLeft):
            while (count-- && p)
                p = BackwardWord(buffer, p, big);
            return {p};
        case 'e': case 'E':
            while (count-- && p < buffer.length)
                p = EndWord(buffer, p, big, true);
            return {p, Kind::Character, true};
        case '%':
            return Percent(buffer, p, explicitCount ? count : 0);
        case '(':
        case ')':
            return {Sentence(buffer, p, key == Key(')'), count), Kind::Character, false, true};
        case '{':
        case '}':
            return {Paragraph(buffer, p, key == Key('}'), count), Kind::Character, false, true};
        case 'H': case 'M': case 'L': {
            Range view = buffer.host.viewport ? buffer.host.viewport(buffer.host.document) : Range{0, buffer.rows};
            Offset top = std::min(view.first, buffer.rows - 1);
            Offset bottom = std::clamp(view.last, top + 1, buffer.rows) - 1;
            Offset target = key == Key('H') ? std::min(bottom, top + count - 1) :
                            key == Key('L') ? bottom - std::min<Offset>(bottom - top, count - 1) :
                            (top + bottom) / 2;
            return {FirstNonblank(buffer, buffer.line(target)), Kind::Line, false, true};
        }
    }
    return {};
}

static Motion FindCharacter(State &state, const Buffer &buffer, char32_t command,
                            Text needle, unsigned count, bool repeat)
{
    if (needle.empty())
        return {};
    bool back = Upper(command);
    bool till = Lowercase(command) == 't';
    Line line = buffer.line(buffer.row(state.cursor));
    Offset p = state.cursor;
    if (repeat && till)
        p = back ? buffer.prev(p) : buffer.next(p);
    while (count--) {
        bool found = false;
        while (back ? p > line.first : buffer.next(p) < line.end) {
            p = back ? buffer.prev(p) : buffer.next(p);
            if (buffer.at(p) == needle.front() && buffer.next(p) - p == needle.size() &&
                (needle.size() == 1 || buffer.read({p, buffer.next(p)}) == needle)) {
                found = true;
                break;
            }
        }
        if (!found)
            return {};
    }
    if (till)
        p = back ? buffer.next(p) : buffer.prev(p);
    return {p, Kind::Character, !back};
}

static Selection LineSelection(const Buffer &buffer, Offset first, Offset last)
{
    Selection result;
    result.kind = Kind::Line;
    result.top = std::min(first, last);
    result.bottom = std::max(first, last);
    result.ranges.push_back({buffer.line(result.top).first, buffer.line(result.bottom).next});
    return result;
}

static Selection MotionSelection(const State &state, const Buffer &buffer, Motion motion)
{
    Offset from = state.cursor;
    Offset to = motion.to;
    Kind kind = state.forceMotion ? state.forcedKind : motion.kind;
    if (kind == Kind::Line)
        return LineSelection(buffer, buffer.row(from), buffer.row(to));
    if (kind == Kind::Block) {
        State block;
        block.mode = Mode::VisualBlock;
        block.anchor = from;
        block.cursor = NormalPosition(buffer, to);
        block.tabStop = state.tabStop;
        return Selected(block, buffer);
    }
    Range range = Ordered(from, to);
    bool inclusive = state.forceMotion && motion.kind == Kind::Character ? !motion.inclusive : motion.inclusive;
    if (inclusive) {
        range.last = CellEnd(buffer, range.last);
    } else if (to > from && to != buffer.length && to == buffer.line(buffer.row(to)).first &&
               !state.forceMotion && buffer.row(from) < buffer.row(to)) {
        if (from <= FirstNonblank(buffer, buffer.line(buffer.row(from))))
            return LineSelection(buffer, buffer.row(from), buffer.row(to) - 1);
        range.last = buffer.line(buffer.row(to) - 1).end;
    }
    Selection result;
    result.top = buffer.row(range.first);
    result.bottom = buffer.row(range.last);
    result.ranges.push_back(range);
    return result;
}

static Range WordObject(const Buffer &buffer, Offset cursor, bool big, bool around, unsigned count)
{
    Word word = WordAt(buffer, cursor, big);
    Line line = buffer.line(buffer.row(cursor));
    Offset first = cursor;
    Offset last = cursor;
    while (first > line.first && WordAt(buffer, buffer.prev(first), big) == word)
        first = buffer.prev(first);
    while (last < line.end && WordAt(buffer, last, big) == word)
        last = buffer.next(last);
    if (around && word == Word::Space) {
        if (last == line.end) {
            Word previous = WordAt(buffer, buffer.prev(first), big);
            while (first > line.first && WordAt(buffer, buffer.prev(first), big) == previous)
                first = buffer.prev(first);
        } else {
            Word next = WordAt(buffer, last, big);
            while (last < line.end && WordAt(buffer, last, big) == next)
                last = buffer.next(last);
        }
    }
    while (--count && last < buffer.length) {
        if (around) {
            while (last < buffer.length && Space(buffer.at(last)))
                last = buffer.next(last);
        }
        Word next = WordAt(buffer, last, big);
        while (last < buffer.length && WordAt(buffer, last, big) == next)
            last = buffer.next(last);
    }
    line = buffer.line(buffer.row(last));
    if (around && word != Word::Space) {
        Offset end = last;
        while (last < line.end && Blank(buffer.at(last)))
            last = buffer.next(last);
        if (last == end) {
            Line start = buffer.line(buffer.row(first));
            while (first > start.first && Blank(buffer.at(buffer.prev(first))))
                first = buffer.prev(first);
        }
    }
    return {first, last};
}

static std::optional<Range> QuoteObject(const Buffer &buffer, Offset cursor, char16_t quote, bool around)
{
    Line line = buffer.line(buffer.row(cursor));
    Offset start = NoOffset;
    for (Offset p = line.first; p < line.end; p = buffer.next(p)) {
        if (buffer.at(p) == '\\') {
            p = buffer.next(p);
        } else if (buffer.at(p) == quote) {
            if (start == NoOffset) {
                start = p;
            } else if (p >= cursor) {
                if (!around)
                    return Range{start + 1, p};
                Offset end = p + 1;
                while (end < line.end && Blank(buffer.at(end)))
                    ++end;
                if (end == p + 1) {
                    while (start > line.first && Blank(buffer.at(start - 1)))
                        --start;
                }
                return Range{start, end};
            } else {
                start = NoOffset;
            }
        }
    }
    return std::nullopt;
}

static std::optional<Range> PairObject(const Buffer &buffer, Offset cursor, char16_t left,
                                        bool around, unsigned count, bool codeOnly = false)
{
    char16_t right = Paired(left);
    Offset start = NoOffset;
    Offset end = NoOffset;
    unsigned depth = 0;
    bool insideText = !codeOnly && cursor < buffer.length && !Structural(buffer, cursor);
    for (Offset p = cursor + 1; p;) {
        --p;
        char16_t ch = buffer.at(p);
        if ((ch == left || ch == right) && !insideText && !Structural(buffer, p))
            continue;
        if (ch == right && p != cursor)
            ++depth;
        else if (ch == left) {
            if (depth) {
                --depth;
            } else {
                start = p;
                end = MatchPair(buffer, p, true);
                if (end != NoOffset && end >= cursor && --count == 0)
                    break;
                start = NoOffset;
            }
        }
    }
    if (start == NoOffset && count == 1) {
        Line line = buffer.line(buffer.row(cursor));
        for (Offset p = cursor; p < line.end; ++p) {
            if (buffer.at(p) != left || (codeOnly && !Structural(buffer, p)))
                continue;
            start = p;
            end = MatchPair(buffer, p, true);
            break;
        }
    }
    if (start == NoOffset || end == NoOffset)
        return std::nullopt;
    if (around)
        return Range{start, end + 1};
    Line before = buffer.line(buffer.row(start));
    Line after = buffer.line(buffer.row(end));
    Offset first = start + 1;
    Offset last = end;
    if (left == '{' && before.first != after.first) {
        while (first < before.end && Blank(buffer.at(first)))
            ++first;
        if (first == before.end)
            first = before.next;
        if (FirstNonblank(buffer, after) == end)
            last = after.first;
    }
    return Range{std::min(first, last), last};
}

struct Tag {
    std::u16string name;
    Range range;
};

static std::optional<Range> TagObject(const Buffer &buffer, Offset cursor, bool around, unsigned count)
{
    std::vector<Tag> tags;
    for (Offset p = 0; p < buffer.length; ++p) {
        if (buffer.at(p) != '<')
            continue;
        Offset first = p++;
        bool closing = buffer.at(p) == '/';
        p += closing;
        Offset name = p;
        while (Lower(buffer.at(p)) || Upper(buffer.at(p)) || Digit(buffer.at(p)) ||
               buffer.at(p) == '-' || buffer.at(p) == ':' || buffer.at(p) == '.')
            ++p;
        if (p == name && buffer.at(p) != '>')
            continue;
        auto token = buffer.read({name, p});
        char16_t quote = 0;
        for (; p < buffer.length; ++p) {
            char16_t ch = buffer.at(p);
            if (ch == quote)
                quote = 0;
            else if (!quote && (ch == '\'' || ch == '"'))
                quote = ch;
            else if (!quote && ch == '>')
                break;
        }
        if (p == buffer.length)
            break;
        if (buffer.at(p - 1) == '/')
            continue;
        if (!closing) {
            tags.push_back({std::move(token), {first, p + 1}});
            continue;
        }
        auto found = std::find_if(tags.rbegin(), tags.rend(), [&](const Tag &tag) { return tag.name == token; });
        if (found == tags.rend())
            continue;
        Range start = found->range;
        tags.erase(found.base() - 1, tags.end());
        if (start.first <= cursor && cursor <= p && --count == 0)
            return around ? Range{start.first, p + 1} : Range{start.last, first};
    }
    return std::nullopt;
}

static std::optional<Range> ArgumentObject(const Buffer &buffer, Offset cursor, bool around, unsigned count)
{
    std::optional<Range> pair;
    for (char16_t opening : {u'(', u'['}) {
        auto found = PairObject(buffer, cursor, opening, true, 1, true);
        if (found && found->first <= cursor && cursor < found->last &&
            (!pair || found->first > pair->first))
            pair = found;
    }
    if (!pair)
        return {};
    Offset first = pair->first + 1;
    Offset last = pair->last - 1;
    Offset preceding = NoOffset;
    for (Offset at = first; at < last; at = buffer.next(at)) {
        char16_t ch = buffer.at(at);
        if (!Structural(buffer, at))
            continue;
        if (ch == '(' || ch == '[' || ch == '{' ||
            (ch == '<' && at > first && WordAt(buffer, buffer.prev(at), false) == Word::Keyword)) {
            Offset close = MatchPair(buffer, at, true);
            if (close < last)
                at = close;
        } else if (ch == ',') {
            if (at < cursor) {
                preceding = at;
                first = at + 1;
            } else if (--count == 0) {
                last = at;
                break;
            }
        }
    }
    if (around && last < pair->last - 1) {
        ++last;
        while (last < pair->last - 1 && Space(buffer.at(last)))
            ++last;
    } else if (around && preceding != NoOffset) {
        first = preceding;
    } else {
        while (first < last && Space(buffer.at(first)))
            ++first;
        while (last > first && Space(buffer.at(last - 1)))
            --last;
    }
    return Range{first, last};
}

static Selection IndentObject(const State &state, const Buffer &buffer, bool around, bool trailing)
{
    Offset top = buffer.row(state.cursor);
    while (top && EmptyLine(buffer, buffer.line(top).first))
        --top;
    Offset bottom = top;
    Offset indent = ColumnAt(buffer, FirstNonblank(buffer, buffer.line(top)), state.tabStop);
    auto inBlock = [&](Offset row) {
        Line line = buffer.line(row);
        Offset code = FirstNonblank(buffer, line);
        return code == line.end || ColumnAt(buffer, code, state.tabStop) >= indent;
    };
    while (top && inBlock(top - 1))
        --top;
    while (bottom + 1 < buffer.rows && inBlock(bottom + 1))
        ++bottom;
    while (top < bottom && EmptyLine(buffer, buffer.line(top).first))
        ++top;
    while (bottom > top && EmptyLine(buffer, buffer.line(bottom).first))
        --bottom;
    if (around && top)
        --top;
    if (trailing && bottom + 1 < buffer.rows)
        ++bottom;
    return LineSelection(buffer, top, bottom);
}

static std::optional<Selection> TextObject(const State &state, const Buffer &buffer, char32_t key,
                                           bool around, unsigned count)
{
    if (key == 'i' || (around && key == 'I'))
        return IndentObject(state, buffer, around, key == 'I');
    if (key == 'p') {
        Offset top = buffer.row(state.cursor);
        Offset bottom = top;
        bool empty = EmptyLine(buffer, buffer.line(top).first);
        while (top && EmptyLine(buffer, buffer.line(top - 1).first) == empty)
            --top;
        while (bottom + 1 < buffer.rows && EmptyLine(buffer, buffer.line(bottom + 1).first) == empty)
            ++bottom;
        for (unsigned i = 1; i < count && bottom + 1 < buffer.rows; ++i) {
            while (bottom + 1 < buffer.rows && EmptyLine(buffer, buffer.line(bottom + 1).first) != empty)
                ++bottom;
            while (bottom + 1 < buffer.rows && EmptyLine(buffer, buffer.line(bottom + 1).first) == empty)
                ++bottom;
        }
        if (around) {
            Offset old = bottom;
            while (bottom + 1 < buffer.rows && EmptyLine(buffer, buffer.line(bottom + 1).first) != empty)
                ++bottom;
            if (old == bottom && !empty) {
                while (top && EmptyLine(buffer, buffer.line(top - 1).first))
                    --top;
            }
        }
        return LineSelection(buffer, top, bottom);
    }

    std::optional<Range> range;
    if (key == 'w' || key == 'W') {
        range = WordObject(buffer, state.cursor, Upper(key), around, count);
    } else if (key == 'a') {
        range = ArgumentObject(buffer, state.cursor, around, count);
    } else if (key == '"' || key == '\'' || key == 0x60) {
        range = QuoteObject(buffer, state.cursor, char16_t(key), around);
    } else if (key == 't') {
        range = TagObject(buffer, state.cursor, around, count);
    } else if (key == 's') {
        Offset first = Sentence(buffer, buffer.next(state.cursor), false, 1);
        Offset last = Sentence(buffer, first, true, count);
        if (!around) {
            while (last > first && Space(buffer.at(buffer.prev(last))))
                last = buffer.prev(last);
        }
        range = Range{first, last};
    } else {
        char16_t left = key == 'b' ? '(' : key == 'B' ? '{' : char16_t(key);
        if (!Opening(left))
            left = Paired(left);
        if (left)
            range = PairObject(buffer, state.cursor, left, around, count);
    }
    if (!range)
        return std::nullopt;
    Selection result;
    result.top = buffer.row(range->first);
    result.bottom = buffer.row(range->empty() ? range->last : buffer.prev(range->last));
    result.ranges.push_back(*range);
    return result;
}

static bool RegisterName(char32_t key)
{
    return key == '"' || key == '_' || key == '-' || key == '+' || key == '*' ||
           key == '.' || key == '%' || key == '/' || key == ':' ||
           Lower(key) || Upper(key) || Digit(key);
}

static bool ReadOnlyRegister(char32_t key)
{
    return key == '%' || key == '/' || key == '.' || key == ':';
}

static std::shared_ptr<const Register> ReadRegister(const State &state, const Host &host,
                                                    const Registers &registers, char32_t key)
{
    if (key == '/' || key == '%') {
        if (key == '%' && !host.fileName)
            return {};
        Register value;
        value.text = key == '/' ? state.lastSearch : host.fileName(host.context);
        return value.text.empty() ? nullptr : std::make_shared<Register>(std::move(value));
    }
    if (key == '+' || key == '*') {
        if (host.readClipboard) {
            if (auto value = host.readClipboard(host.document))
                return std::make_shared<Register>(std::move(*value));
        }
        return {};
    }
    if (key == '_')
        return {};
    return registers.slots[Lowercase(key ? key : '"')];
}

static std::shared_ptr<const Register> SetRegister(Registers &registers, char32_t name, Register value)
{
    auto &slot = registers.slots[Lowercase(name)];
    if (Upper(name) && slot) {
        Register combined = *slot;
        if (value.kind == Kind::Line) {
            if (!combined.text.empty() && !combined.text.ends_with(u"\n"))
                combined.text.push_back('\n');
            combined.kind = Kind::Line;
        }
        combined.text.append(value.text);
        combined.keys.insert(combined.keys.end(), value.keys.begin(), value.keys.end());
        if (combined.kind == Kind::Line && !combined.text.ends_with(u"\n"))
            combined.text.push_back('\n');
        slot = std::make_shared<Register>(std::move(combined));
    } else {
        slot = std::make_shared<Register>(std::move(value));
    }
    return slot;
}

static Register ReadSelection(const State &state, const Buffer &buffer, const Selection &selection)
{
    Register value;
    value.kind = selection.kind;
    value.width = selection.toEnd ? 0 : selection.right - selection.left;
    for (std::size_t i = 0; i < selection.ranges.size(); ++i) {
        Range range = selection.ranges[i];
        auto raw = buffer.read(range);
        if (selection.kind == Kind::Block) {
            if (i)
                value.text.push_back('\n');
            Offset column = ColumnAt(buffer, range.first, state.tabStop);
            Offset copied = 0;
            for (Offset at = range.first; at < range.last; at = buffer.next(at)) {
                if (buffer.at(at) == '\t') {
                    Offset end = column + CellWidth(buffer, at, column, state.tabStop);
                    Offset first = std::max(column, selection.left);
                    Offset width = selection.toEnd ? end - first :
                                   std::min(end, std::max(selection.right, first)) - first;
                    value.text.append(width, u' ');
                    copied += width;
                    column = end;
                } else {
                    value.text.append(Text(raw).substr(at - range.first, buffer.next(at) - at));
                    ++column;
                    ++copied;
                }
            }
            if (selection.toEnd)
                value.width = std::max(value.width, copied);
            else if (copied < value.width)
                value.text.append(value.width - copied, u' ');
        } else {
            if (selection.disjoint && i)
                value.text.push_back('\n');
            value.text.append(NormalizeNewlines(raw, u"\n"));
        }
    }
    if (value.kind == Kind::Line && (value.text.empty() || value.text.back() != '\n'))
        value.text.push_back('\n');
    return value;
}

static void WriteRegister(const State &state, const Host &host, Registers &registers, Register value, Op op)
{
    char32_t name = state.selectedRegister;
    if (name == '_')
        return;
    std::shared_ptr<const Register> saved;
    if (name == '+' || name == '*') {
        if (host.writeClipboard)
            host.writeClipboard(host.document, value.text);
    } else if (name && name != '"') {
        saved = SetRegister(registers, name, std::move(value));
    }
    if (!saved)
        saved = std::make_shared<Register>(std::move(value));
    if (!name || name == '"') {
        if (op == Op::Yank) {
            registers.slots['0'] = saved;
        } else if (saved->kind == Kind::Line || saved->text.find(u'\n') != Text::npos) {
            for (char32_t slot = '9'; slot > '1'; --slot)
                registers.slots[slot] = registers.slots[slot - 1];
            registers.slots['1'] = saved;
        } else {
            registers.slots['-'] = saved;
        }
    }
    registers.slots['"'] = saved;
}

static std::u16string IndentText(Offset columns, unsigned tabStop, bool expandTab)
{
    std::u16string text;
    if (!expandTab) {
        text.assign(columns / tabStop, '\t');
        columns %= tabStop;
    }
    text.append(columns, ' ');
    return text;
}

static std::u16string Indentation(const Buffer &buffer, Offset row)
{
    Line line = buffer.line(row);
    return buffer.read({line.first, FirstNonblank(buffer, line)});
}

static void StartInsert(State &state, Offset position, Mode mode, unsigned count = 1)
{
    state.mode = mode;
    state.cursor = position;
    state.insertStart = position;
    state.insertCount = count;
    state.openCommand = 0;
    state.automaticIndent = {};
    state.blockTop = 0;
    state.blockBottom = 0;
    state.blockReturn = NoOffset;
    state.rowInsert = RowInsert::Column;
    state.padBlock = false;
    state.simpleInsert = true;
    state.replacements.clear();
    state.insertMirrors.clear();
    state.goalColumn = NoOffset;
    state.goalEnd = false;
}

static Offset EnsureColumn(State &state, Buffer &buffer, Offset row, Offset column, bool pad)
{
    Line line = buffer.line(row);
    Offset at = AtColumn(buffer, line, column, state.tabStop);
    Offset current = ColumnAt(buffer, at, state.tabStop);
    if (at < line.end && buffer.at(at) == '\t' && column > current) {
        Offset width = CellWidth(buffer, at, current, state.tabStop);
        Replace(state, buffer, {at, at + 1}, std::u16string(width, ' '));
        at += column - current;
    } else if (at == line.end && pad && column > current) {
        Replace(state, buffer, {at, at}, std::u16string(column - current, ' '));
        at += column - current;
    }
    return at;
}

static void StartBlockInsert(State &state, Buffer &buffer, const Selection &selected, bool append, bool change = false)
{
    Offset column = append ? selected.right : selected.left;
    Line top = buffer.line(selected.top);
    Offset left = AtColumn(buffer, top, selected.left, state.tabStop);
    RowInsert placement = RowInsert::Column;
    if (append && (selected.toEnd || selected.kind == Kind::Line))
        placement = RowInsert::End;
    else if (selected.kind == Kind::Line)
        placement = RowInsert::FirstNonblank;
    Offset first = placement == RowInsert::End ? top.end :
                   placement == RowInsert::FirstNonblank ? FirstNonblank(buffer, top) :
                   EnsureColumn(state, buffer, selected.top, column, append);
    StartInsert(state, first, Mode::Insert);
    state.blockTop = selected.top;
    state.blockBottom = selected.bottom;
    state.blockColumn = column;
    state.rowInsert = placement;
    state.blockReturn = change || selected.kind == Kind::Line ? NoOffset : left;
    state.padBlock = append;
}

static void RememberVisual(State &state, const Buffer &buffer, const Selection &selected)
{
    if (selected.disjoint) {
        state.visualRepeat.occurrences = selected.ranges.size();
        return;
    }
    state.visualRepeat.visualMode = state.mode;
    state.visualRepeat.rows = selected.bottom - selected.top + 1;
    if (selected.kind == Kind::Block) {
        state.visualRepeat.columns = selected.right - selected.left;
        state.visualRepeat.toEnd = selected.toEnd;
    } else if (selected.kind == Kind::Character) {
        Range range = selected.ranges.front();
        Offset start = selected.top == selected.bottom ? ColumnAt(buffer, range.first, state.tabStop) : 0;
        Offset end = std::min(range.last, buffer.line(selected.bottom).end);
        state.visualRepeat.columns = ColumnAt(buffer, end, state.tabStop) - start;
    }
}

static void ShiftLines(State &state, Buffer &buffer, const Selection &selection, Op op, unsigned count)
{
    for (Offset row = selection.top; row <= selection.bottom; ++row) {
        Line line = buffer.line(row);
        Offset first = FirstNonblank(buffer, line);
        if (first == line.end)
            continue;
        Offset column = ColumnAt(buffer, first, state.tabStop);
        Offset width = state.shiftWidth * count;
        if (op == Op::ShiftRight) {
            column += width;
        } else if (op == Op::ShiftLeft) {
            column -= std::min(column, width);
        } else if (row) {
            Line prev = buffer.line(row - 1);
            while (row > selection.top && prev.first == prev.end) {
                Offset previousRow = buffer.row(prev.first);
                if (!previousRow)
                    break;
                prev = buffer.line(previousRow - 1);
            }
            column = ColumnAt(buffer, FirstNonblank(buffer, prev), state.tabStop);
            Offset end = prev.end;
            while (end > prev.first && Blank(buffer.at(end - 1)))
                --end;
            char16_t last = end > prev.first ? buffer.at(end - 1) : 0;
            if (last == '{' || last == '[' || last == '(' || last == ':')
                column += state.shiftWidth;
            char16_t head = buffer.at(first);
            if (head == '}' || head == ']' || head == ')') {
                Offset opening = MatchPair(buffer, first, false);
                if (opening != NoOffset)
                    column = ColumnAt(buffer, FirstNonblank(buffer, buffer.line(buffer.row(opening))), state.tabStop);
                else
                    column -= std::min<Offset>(column, state.shiftWidth);
            }
        } else {
            column = 0;
        }
        Replace(state, buffer, {line.first, first}, IndentText(column, state.tabStop, state.expandTab));
    }
    state.cursor = FirstNonblank(buffer, buffer.line(selection.top));
}

static void ChangeCase(State &state, Buffer &buffer, Range range, Op op)
{
    auto text = buffer.read(range);
    for (char16_t &ch : text) {
        if ((op == Op::Toggle || op == Op::Lower) && Upper(ch))
            ch += 'a' - 'A';
        else if ((op == Op::Toggle || op == Op::Upper) && Lower(ch))
            ch -= 'a' - 'A';
    }
    Replace(state, buffer, range, text);
}

static bool AtText(const Buffer &buffer, Offset at, Text text)
{
    for (char16_t unit : text) {
        if (buffer.at(at++) != unit)
            return false;
    }
    return true;
}

static void ToggleComments(State &state, Buffer &buffer, const Selection &selected, bool block)
{
    if (!buffer.host.comments)
        return;
    Comments style = buffer.host.comments(buffer.host.context);
    if (block || style.line.empty()) {
        if (style.open.empty())
            return;
        for (auto it = selected.ranges.rbegin(); it != selected.ranges.rend(); ++it) {
            Range part = *it;
            if (selected.kind == Kind::Line)
                part = {FirstNonblank(buffer, buffer.line(selected.top)), buffer.line(selected.bottom).end};
            Offset before = part.first;
            Offset after = part.last;
            while (before < after && Blank(buffer.at(before)))
                ++before;
            while (after > before && Blank(buffer.at(after - 1)))
                --after;
            if (after - before >= style.open.size() + style.close.size() &&
                AtText(buffer, before, style.open) && AtText(buffer, after - style.close.size(), style.close)) {
                Offset giveBack = after - style.close.size();
                if (giveBack > before && buffer.at(giveBack - 1) == ' ')
                    --giveBack;
                Replace(state, buffer, {giveBack, after}, u"");
                Offset end = before + style.open.size();
                if (end < giveBack && buffer.at(end) == ' ')
                    ++end;
                Replace(state, buffer, {before, end}, u"");
            } else {
                Replace(state, buffer, {part.last, part.last}, u" " + std::u16string(style.close));
                Replace(state, buffer, {part.first, part.first}, std::u16string(style.open) + u" ");
            }
        }
        return;
    }
    bool allCommented = true;
    Offset indent = NoOffset;
    for (Offset row = selected.top; row <= selected.bottom; ++row) {
        Line line = buffer.line(row);
        Offset first = FirstNonblank(buffer, line);
        if (first == line.end && selected.top != selected.bottom)
            continue;
        indent = std::min(indent, ColumnAt(buffer, first, state.tabStop));
        allCommented &= AtText(buffer, first, style.line);
    }
    if (indent == NoOffset)
        return;
    for (Offset row = selected.bottom + 1; row-- > selected.top;) {
        Line line = buffer.line(row);
        Offset first = FirstNonblank(buffer, line);
        if (first == line.end && selected.top != selected.bottom)
            continue;
        if (allCommented) {
            Offset end = first + style.line.size();
            if (buffer.at(end) == ' ')
                ++end;
            Replace(state, buffer, {first, end}, u"");
        } else {
            Offset at = EnsureColumn(state, buffer, row, indent, false);
            Replace(state, buffer, {at, at}, std::u16string(style.line) + u" ");
        }
    }
}

static void StartSurround(State &state, const Buffer &buffer, Selection selected)
{
    if (selected.kind == Kind::Line) {
        selected.ranges.front().first = FirstNonblank(buffer, buffer.line(selected.top));
        selected.ranges.front().last = buffer.line(selected.bottom).end;
    }
    for (Range part : selected.ranges)
        state.surrounds.push_back({{part.first, part.first}, {part.last, part.last}});
    state.keepSurroundCursor = false;
}

static void ReplaceSurround(State &state, Buffer &buffer, Text open, Text close)
{
    Offset cursor = state.keepSurroundCursor ? state.cursor : state.surrounds.front().left.first;
    for (auto it = state.surrounds.rbegin(); it != state.surrounds.rend(); ++it) {
        Replace(state, buffer, it->right, close);
        if (state.keepSurroundCursor)
            cursor = OffsetAfterEdit(cursor, it->right, close.size());
        Replace(state, buffer, it->left, open);
        if (state.keepSurroundCursor)
            cursor = OffsetAfterEdit(cursor, it->left, open.size());
    }
    state.cursor = NormalPosition(buffer, cursor);
    state.surrounds.clear();
    state.surroundingTag = false;
    state.surroundTag.clear();
}

static char16_t SurroundOpening(char32_t key)
{
    switch (key) {
        case 'b': case ')': return '(';
        case 'B': case '}': return '{';
        case 'r': case ']': return '[';
        case 'a': case '>': return '<';
        default: return key < 0x10000 ? char16_t(key) : 0;
    }
}

static void SurroundTarget(State &state, Buffer &buffer, char32_t key, unsigned count)
{
    char16_t opening = SurroundOpening(key);
    std::optional<Range> whole;
    std::optional<Range> inner;
    if (opening == 't') {
        whole = TagObject(buffer, state.cursor, true, count);
        inner = TagObject(buffer, state.cursor, false, count);
    } else if (opening == '"' || opening == '\'' || opening == 0x60) {
        inner = QuoteObject(buffer, state.cursor, opening, false);
        if (inner)
            whole = Range{inner->first - 1, inner->last + 1};
    } else if (Opening(opening)) {
        whole = PairObject(buffer, state.cursor, opening, true, count);
    }
    if (!whole)
        return;
    if (!inner) {
        inner = Range{whole->first + 1, whole->last - 1};
        if (key == '(' || key == '[' || key == '{') {
            while (inner->first < inner->last && Blank(buffer.at(inner->first)))
                ++inner->first;
            while (inner->last > inner->first && Blank(buffer.at(inner->last - 1)))
                --inner->last;
        }
    }
    state.surrounds.push_back({{whole->first, inner->first}, {inner->last, whole->last}});
    state.keepSurroundCursor = true;
    if (state.op == Op::Delete)
        ReplaceSurround(state, buffer, {}, {});
}

static void SurroundKey(State &state, Buffer &buffer, Key key, Text text)
{
    char32_t ch = char32_t(key);
    if (key == Key::Escape || key == Key(3)) {
        state.surrounds.clear();
        state.surroundingTag = false;
        state.surroundTag.clear();
        return;
    }
    if (state.surroundingTag) {
        if (ch == '>' || key == Key::Enter) {
            Text tag = state.surroundTag;
            Offset end = 0;
            while (end < tag.size() && !Space(tag[end]))
                ++end;
            if (end && (Lower(tag.front()) || Upper(tag.front()))) {
                auto open = u"<" + state.surroundTag + u">";
                auto close = u"</" + std::u16string(tag.substr(0, end)) + u">";
                ReplaceSurround(state, buffer, open, close);
            } else {
                state.surrounds.clear();
                state.surroundingTag = false;
                state.surroundTag.clear();
            }
        } else if (key == Key::Backspace || key == Key(127)) {
            if (!state.surroundTag.empty())
                state.surroundTag.pop_back();
        } else if (key == Key::Text || (ch >= 32 && ch < 0x110000)) {
            state.surroundTag.append(KeyText(key, text));
        }
        return;
    }
    if (ch == '<' || ch == 't') {
        state.surroundingTag = true;
        return;
    }
    char16_t opening = SurroundOpening(ch);
    char16_t closing = Opening(opening) ? Paired(opening) : opening;
    if (opening && (Opening(opening) || ch == '"' || ch == '\'' || ch == 0x60 || ch == '*')) {
        std::u16string open(1, opening);
        std::u16string close(1, closing);
        if (ch == '(' || ch == '[' || ch == '{') {
            open.push_back(' ');
            close.insert(close.begin(), ' ');
        }
        ReplaceSurround(state, buffer, open, close);
    } else {
        state.surrounds.clear();
    }
}

static void ApplyOperator(State &state, Buffer &buffer, Registers &registers, Op op, Selection selected,
                          unsigned shiftCount = 1, bool writeRegister = true)
{
    if (selected.ranges.empty())
        return;
    if (writeRegister && ReadOnlyRegister(state.selectedRegister) &&
        (op == Op::Yank || op == Op::Delete || op == Op::Change)) {
        state.message = u"Read-only register";
        return;
    }
    bool visual = IsVisual(state.mode);
    if (visual)
        RememberVisual(state, buffer, selected);
    LeaveVisual(state);

    Range range = selected.ranges.front();
    if (op == Op::Surround) {
        StartSurround(state, buffer, std::move(selected));
        return;
    }
    if (op == Op::Comment || op == Op::BlockComment) {
        ToggleComments(state, buffer, selected, op == Op::BlockComment);
        state.cursor = FirstNonblank(buffer, buffer.line(selected.top));
        return;
    }
    if (op == Op::ShiftLeft || op == Op::ShiftRight || op == Op::Indent) {
        ShiftLines(state, buffer, selected, op, shiftCount);
        return;
    }
    if (op == Op::Lower || op == Op::Upper || op == Op::Toggle) {
        for (Range part : selected.ranges)
            ChangeCase(state, buffer, part, op);
        state.cursor = NormalPosition(buffer, range.first);
        return;
    }
    if (range.empty() && selected.kind == Kind::Character && op != Op::Change)
        return;
    if (writeRegister)
        WriteRegister(state, buffer.host, registers, ReadSelection(state, buffer, selected), op);
    if (op == Op::Yank) {
        if (buffer.host.flash)
            buffer.host.flash(buffer.host.document, selected.ranges, selected.kind);
        state.cursor = NormalPosition(buffer, range.first);
        state.goalColumn = NoOffset;
        state.goalEnd = false;
        return;
    }
    if (selected.disjoint) {
        state.commandStart = range.first;
        for (auto part = selected.ranges.rbegin(); part != selected.ranges.rend(); ++part)
            Replace(state, buffer, *part, u"");
        if (op == Op::Change) {
            StartInsert(state, range.first, Mode::Insert);
            Offset removed = range.size();
            for (Offset i = 1; i < selected.ranges.size(); ++i) {
                Range part = selected.ranges[i];
                state.insertMirrors.push_back(part.first - removed);
                removed += part.size();
            }
        } else {
            state.cursor = NormalPosition(buffer, range.first);
        }
        return;
    }

    if (selected.kind == Kind::Line) {
        Line bottom = buffer.line(selected.bottom);
        if (op == Op::Change) {
            auto indent = state.autoIndent ? Indentation(buffer, selected.top) : u"";
            auto retained = indent + buffer.read({bottom.end, bottom.next});
            Replace(state, buffer, range, retained);
            StartInsert(state, range.first + indent.size(), Mode::Insert);
        } else {
            if (selected.top && selected.bottom + 1 == buffer.rows && bottom.end == bottom.next)
                range.first = buffer.line(selected.top - 1).end;
            Replace(state, buffer, range, u"");
            state.cursor = FirstNonblank(buffer, buffer.line(std::min(selected.top, buffer.rows - 1)));
        }
    } else {
        for (auto part = selected.ranges.rbegin(); part != selected.ranges.rend(); ++part) {
            Offset padding = 0;
            if (selected.kind == Kind::Block && !part->empty()) {
                Offset before = ColumnAt(buffer, part->first, state.tabStop);
                Offset after = ColumnAt(buffer, part->last, state.tabStop);
                if (before < selected.left)
                    padding += selected.left - before;
                if (!selected.toEnd && after > selected.right && buffer.at(buffer.prev(part->last)) == '\t')
                    padding += after - selected.right;
            }
            Replace(state, buffer, *part, std::u16string(padding, u' '));
        }
        if (op == Op::Change && selected.kind == Kind::Block) {
            StartBlockInsert(state, buffer, selected, false, true);
        } else if (op == Op::Change) {
            StartInsert(state, range.first, Mode::Insert);
        } else {
            state.cursor = NormalPosition(buffer, range.first);
        }
    }
}

static std::u16string Repeated(Text text, unsigned count)
{
    if (!text.empty() && count > (64 * 1024 * 1024) / text.size())
        return {};
    std::u16string result;
    result.reserve(text.size() * count);
    while (count--)
        result.append(text);
    return result;
}

static void Put(State &state, Buffer &buffer, Registers &registers, bool after, bool movePast, unsigned count)
{
    auto value = ReadRegister(state, buffer.host, registers, state.selectedRegister);
    if (!value || value->text.empty())
        return;
    bool replacing = IsVisual(state.mode);
    Selection selected;
    Offset position = state.cursor;
    Offset row = buffer.row(position);
    bool lineReplace = false;
    if (replacing) {
        selected = Selected(state, buffer);
        if (selected.disjoint) {
            if (value->kind != Kind::Character) {
                state.message = u"Multiple selections require a characterwise register";
                return;
            }
            LeaveVisual(state);
            if (after)
                WriteRegister(state, buffer.host, registers, ReadSelection(state, buffer, selected), Op::Delete);
            for (auto part = selected.ranges.rbegin(); part != selected.ranges.rend(); ++part) {
                auto text = NormalizeNewlines(value->text, EndOfLine(buffer, buffer.row(part->first)));
                Replace(state, buffer, *part, Repeated(text, count));
            }
            state.cursor = NormalPosition(buffer, selected.ranges.front().first);
            return;
        }
        lineReplace = selected.kind == Kind::Line;
        position = selected.ranges.front().first;
        row = selected.top;
        char32_t name = state.selectedRegister;
        state.selectedRegister = 0;
        ApplyOperator(state, buffer, registers, Op::Delete, selected, 1, after);
        state.selectedRegister = name;
        if (position > buffer.length)
            position = buffer.length;
        row = std::min(row, buffer.rows - 1);
    }

    auto newline = EndOfLine(buffer, row);
    if (value->kind == Kind::Block) {
        Offset column = replacing && selected.kind == Kind::Block ? selected.left :
                        ColumnAt(buffer, replacing || !after ? position : CellEnd(buffer, position), state.tabStop);
        Offset first = 0;
        for (Offset at = 0; at <= value->text.size();) {
            Offset end = value->text.find('\n', at);
            if (end == Text::npos)
                end = value->text.size();
            while (row >= buffer.rows) {
                Offset last = buffer.length;
                Replace(state, buffer, {last, last}, newline);
            }
            Offset start = EnsureColumn(state, buffer, row, column, true);
            if (at == 0)
                first = start;
            Replace(state, buffer, {start, start}, Repeated(Text(value->text).substr(at, end - at), count));
            ++row;
            at = end + 1;
        }
        state.cursor = NormalPosition(buffer, first + (movePast ? value->width * count : 0));
        return;
    }

    auto text = Repeated(NormalizeNewlines(value->text, newline), count);
    if (text.empty())
        return;
    if (value->kind == Kind::Line || lineReplace) {
        Line line = buffer.line(row);
        Offset at = lineReplace ? position : after ? line.next : line.first;
        Offset first = at;
        if (!text.ends_with(newline))
            text.append(newline);
        Line final = buffer.line(buffer.rows - 1);
        if (at == buffer.length && buffer.length && final.next == final.end) {
            text.insert(0, newline);
            first += newline.size();
            text.resize(text.size() - newline.size());
        }
        Replace(state, buffer, {at, at}, text);
        Offset target = buffer.row(movePast ? at + text.size() : first);
        state.cursor = FirstNonblank(buffer, buffer.line(target));
    } else {
        Offset at = replacing || !after ? position : CellEnd(buffer, position);
        Replace(state, buffer, {at, at}, text);
        Offset target = at;
        if (text.find(newline) == Text::npos)
            target = movePast ? at + text.size() : buffer.prev(at + text.size());
        state.cursor = NormalPosition(buffer, target);
    }
}

static void OpenLine(State &state, Buffer &buffer, bool below, unsigned count)
{
    Offset row = buffer.row(state.cursor);
    Line line = buffer.line(row);
    auto newline = EndOfLine(buffer, row);
    std::u16string indent;
    if (state.autoIndent) {
        indent = below && buffer.host.indentAfter ?
                 buffer.host.indentAfter(buffer.host.document, line.end, state.tabStop, state.shiftWidth, state.expandTab) :
                 Indentation(buffer, row);
    }
    Offset at = below ? line.end : line.first;
    Replace(state, buffer, {at, at}, below ? newline + indent : indent + newline);
    StartInsert(state, at + (below ? newline.size() : 0) + indent.size(), Mode::Insert, count);
    state.openCommand = below ? 'o' : 'O';
    if (std::all_of(indent.begin(), indent.end(), Blank))
        state.automaticIndent = {state.cursor - indent.size(), state.cursor};
}

static void JoinLines(State &state, Buffer &buffer, Offset first, Offset last, bool space)
{
    if (last <= first)
        return;
    Line line = buffer.line(first);
    std::u16string joined;
    Offset cursor = line.end;
    for (Offset row = first + 1; row <= last; ++row) {
        Line next = buffer.line(row);
        Offset start = space ? FirstNonblank(buffer, next) : next.first;
        if (space && start < next.end && buffer.at(start) != ')' &&
            (joined.empty() ? (line.end > line.first && !Blank(buffer.at(line.end - 1))) :
                              !Blank(joined.back())))
            joined.push_back(' ');
        joined.append(buffer.read({start, next.end}));
    }
    Replace(state, buffer, {line.end, buffer.line(last).end}, joined);
    state.cursor = NormalPosition(buffer, cursor);
}

static void JoinAtCursor(State &state, Buffer &buffer, Offset row, unsigned count, bool space)
{
    Offset first = row, last = row + std::max(2U, count) - 1;
    if (IsVisual(state.mode)) {
        auto selected = Selected(state, buffer);
        RememberVisual(state, buffer, selected);
        first = selected.top;
        last = std::max(selected.bottom, first + Offset(space));
    }

    LeaveVisual(state);
    JoinLines(state, buffer, first, std::min(last, buffer.rows - 1), space);
}

static std::u16string KeyText(Key key, Text text)
{
    if (key == Key::Text || key == Key::Paste)
        return std::u16string(text);
    char32_t value = char32_t(key);
    if (value < 0x10000)
        return std::u16string(1, char16_t(value));
    if (value < 0x110000) {
        value -= 0x10000;
        return {char16_t(0xd800 + (value >> 10)), char16_t(0xdc00 + (value & 0x3ff))};
    }
    return {};
}

static void ReplaceAtInsertCursors(State &state, Buffer &buffer, Range range, Text replacement, Offset cursor)
{
    Offset primary = state.cursor;
    Offset after = range.last > primary ? range.last - primary : 0;
    if (!state.insertMirrors.empty())
        range.last = std::clamp(range.last, range.first, std::max(range.first, state.insertMirrors.front()));
    Replace(state, buffer, range, replacement);
    state.cursor = std::min(cursor, buffer.length);
    state.beforeInlay = state.mode == Mode::Insert;
    if (state.insertMirrors.empty())
        return;
    Offset before = primary > range.first ? primary - range.first : 0;
    Offset caretInEdit = cursor > range.first ? cursor - range.first : 0;
    Offset occupied = range.first + replacement.size();
    auto delta = std::ptrdiff_t(replacement.size()) - std::ptrdiff_t(range.size());
    for (Offset i = 0; i < state.insertMirrors.size(); ++i) {
        Offset at = Offset(std::ptrdiff_t(state.insertMirrors[i]) + delta);
        Offset next = i + 1 < state.insertMirrors.size() ?
                      Offset(std::ptrdiff_t(state.insertMirrors[i + 1]) + delta) : buffer.length;
        Offset first = std::min(at, std::max(occupied, at - std::min(at, before)));
        Offset last = std::max(first, std::min(at + after, next));
        if (buffer.host.cluster) {
            if (first < at)
                first = std::max(occupied, buffer.host.cluster(buffer.host.document, first).first);
            if (at < last && last < next) {
                Range cluster = buffer.host.cluster(buffer.host.document, last);
                if (cluster.first < last)
                    last = std::min(next, cluster.last);
            }
        }
        Range part{first, last};
        Replace(state, buffer, part, replacement);
        state.insertMirrors[i] = std::min(buffer.length, first + caretInEdit);
        occupied = first + replacement.size();
        delta += std::ptrdiff_t(replacement.size()) - std::ptrdiff_t(part.size());
    }
}

static void InsertText(State &state, Buffer &buffer, Text raw, bool paste)
{
    if (raw.empty())
        return;
    Offset row = buffer.row(state.cursor);
    auto newline = EndOfLine(buffer, row);
    auto text = NormalizeNewlines(raw, newline);
    Offset first = state.cursor;
    Offset end = first;
    if (state.mode == Mode::Replace && !paste && text.find(newline) == Text::npos) {
        Line line = buffer.line(row);
        for (Offset index = 0; index < text.size() && end < line.end; ++index) {
            end = buffer.next(end);
            if (text[index] >= 0xd800 && text[index] <= 0xdbff && index + 1 < text.size())
                ++index;
        }
        state.replacements.push_back({first, buffer.read({first, end}), text});
    }
    ReplaceAtInsertCursors(state, buffer, {first, end}, text, first + text.size());
    state.goalColumn = NoOffset;
}

static void SaveInsertedText(const State &state, const Buffer &buffer, Registers &registers)
{
    if (state.change && state.cursor > state.insertStart && state.simpleInsert) {
        Register value;
        value.text = buffer.read({state.insertStart, state.cursor});
        SetRegister(registers, '.', std::move(value));
    }
}

static void FinishInsert(State &state, Buffer &buffer, Registers &registers)
{
    if (!state.automaticIndent.empty()) {
        Replace(state, buffer, state.automaticIndent, u"");
        state.cursor = state.automaticIndent.first;
        state.insertStart = std::min(state.cursor, state.insertStart);
        state.automaticIndent = {};
    }
    SaveInsertedText(state, buffer, registers);
    if (state.simpleInsert && state.cursor >= state.insertStart &&
        (state.insertCount > 1 || state.blockBottom > state.blockTop)) {
        auto inserted = buffer.read({state.insertStart, state.cursor});
        if (state.insertCount > 1 && (state.openCommand || !inserted.empty())) {
            auto repeated = inserted;
            if (state.openCommand) {
                auto newline = EndOfLine(buffer, buffer.row(state.cursor));
                auto indent = inserted.empty() ? u"" : Indentation(buffer, buffer.row(state.insertStart));
                repeated = newline + indent + inserted;
            }
            InsertText(state, buffer, Repeated(repeated, state.insertCount - 1), true);
        }
        if (state.blockBottom > state.blockTop && !inserted.empty() &&
            std::none_of(inserted.begin(), inserted.end(), Break)) {
            for (Offset row = state.blockBottom; row > state.blockTop; --row) {
                Line line = buffer.line(row);
                if (state.rowInsert == RowInsert::Column && !state.padBlock &&
                    ColumnAt(buffer, line.end, state.tabStop) < state.blockColumn)
                    continue;
                Offset at = state.rowInsert == RowInsert::End ? line.end :
                            state.rowInsert == RowInsert::FirstNonblank ? FirstNonblank(buffer, line) :
                            EnsureColumn(state, buffer, row, state.blockColumn, state.padBlock);
                Replace(state, buffer, {at, at}, inserted);
            }
        }
    }
    state.lastInsert = state.cursor;
    if (state.cursor > buffer.line(buffer.row(state.cursor)).first)
        state.cursor = buffer.prev(state.cursor);
    if (state.blockReturn != NoOffset && state.simpleInsert)
        state.cursor = state.blockReturn;
    state.cursor = NormalPosition(buffer, state.cursor);
    state.mode = Mode::Normal;
    state.replacements.clear();
    state.insertMirrors.clear();
    state.returnToInsert = Mode::Normal;
    ClearCommand(state);
}

static void MoveInsertMirrors(State &state, const Buffer &buffer, Key key, Offset primary)
{
    if (state.insertMirrors.empty())
        return;
    for (auto &cursor : state.insertMirrors) {
        Offset column = NoOffset;
        cursor = MoveCaret<true>(buffer, key, cursor, column, state.tabStop);
    }
    std::sort(state.insertMirrors.begin(), state.insertMirrors.end());
    auto first = std::upper_bound(state.insertMirrors.begin(), state.insertMirrors.end(), primary);
    state.insertMirrors.erase(state.insertMirrors.begin(), first);
    state.insertMirrors.erase(std::unique(state.insertMirrors.begin(), state.insertMirrors.end()),
                              state.insertMirrors.end());
}

static void InsertKey(State &state, Buffer &buffer, Registers &registers, Key key, Text text, bool smart)
{
    if (key == Key::Escape || key == Key(3)) {
        FinishInsert(state, buffer, registers);
        return;
    }
    state.automaticIndent = {};
    if (state.prefix == Prefix::InsertControl) {
        state.prefix = Prefix::None;
        if (key == Key('u')) {
            FinishChange(state);
            state.commandStart = state.cursor;
        }
        return;
    }
    if (state.prefix == Prefix::InsertRegister) {
        state.prefix = Prefix::None;
        if (RegisterName(char32_t(key))) {
            if (auto value = ReadRegister(state, buffer.host, registers, char32_t(key)))
                InsertText(state, buffer, value->text, true);
        }
        return;
    }
    if (smart && state.mode == Mode::Insert && state.insertCount == 1 && state.blockTop == state.blockBottom &&
        buffer.host.planInsert) {
        auto edit = buffer.host.planInsert(buffer.host.document, key, state.cursor, state.tabStop,
                                           state.shiftWidth, state.expandTab, state.autoIndent);
        if (edit) {
            state.simpleInsert &= edit->range.first >= state.insertStart;
            ReplaceAtInsertCursors(state, buffer, edit->range, edit->text, edit->cursor);
            state.goalColumn = NoOffset;
            if ((key == Key::Enter || key == Key('\n')) && state.insertMirrors.empty()) {
                Line insertedLine = buffer.line(buffer.row(state.cursor));
                if (insertedLine.end == state.cursor && FirstNonblank(buffer, insertedLine) == state.cursor)
                    state.automaticIndent = {insertedLine.first, state.cursor};
            }
            if (buffer.host.finishInsertEdit)
                buffer.host.finishInsertEdit(buffer.host.context);
            return;
        }
    }
    Offset at = state.cursor;
    Offset row = buffer.row(at);
    Line line = buffer.line(row);
    switch (char32_t(key)) {
        case 1:
            if (auto value = ReadRegister(state, buffer.host, registers, '.'))
                InsertText(state, buffer, value->text, true);
            return;
        case 7:
            state.prefix = Prefix::InsertControl;
            return;
        case 15:
            state.returnToInsert = state.mode;
            state.mode = Mode::Normal;
            state.cursor = NormalPosition(buffer, at);
            state.simpleInsert = false;
            return;
        case 18:
            state.prefix = Prefix::InsertRegister;
            return;
        case '\n': case '\r': {
            auto newline = EndOfLine(buffer, row);
            auto indent = state.autoIndent && at > line.first ? Indentation(buffer, row) : u"";
            InsertText(state, buffer, newline + indent, true);
            if (state.insertMirrors.empty() && state.cursor == buffer.line(buffer.row(state.cursor)).end)
                state.automaticIndent = {state.cursor - indent.size(), state.cursor};
            return;
        }
        case '\t':
            if (state.expandTab)
                InsertText(state, buffer, std::u16string(state.tabStop - ColumnAt(buffer, at, state.tabStop) %
                                                        state.tabStop, u' '), false);
            else
                InsertText(state, buffer, u"\t", false);
            return;
        case char32_t(Key::Backspace): case 127: case 21: case 23: {
            if (!at)
                return;
            if ((key == Key::Backspace || key == Key(127)) && state.mode == Mode::Replace &&
                !state.replacements.empty() && state.replacements.back().at + state.replacements.back().after.size() == at) {
                Edit replaced = std::move(state.replacements.back());
                state.replacements.pop_back();
                Replace(state, buffer, {replaced.at, at}, replaced.before);
                state.cursor = replaced.at;
                return;
            }
            Offset first = buffer.prev(at);
            if (key == Key(23) && at > line.first)
                first = std::max(line.first, BackwardWord(buffer, at, false));
            else if (key == Key(21) && at > line.first)
                first = at > FirstNonblank(buffer, line) ? FirstNonblank(buffer, line) : line.first;
            if (first < state.insertStart)
                state.simpleInsert = false;
            ReplaceAtInsertCursors(state, buffer, {first, at}, u"", first);
            return;
        }
        case 4: case 20: {
            Offset first = FirstNonblank(buffer, line);
            Offset indentation = ColumnAt(buffer, first, state.tabStop);
            Offset newWidth = key == Key(20) ? indentation + state.shiftWidth - indentation % state.shiftWidth :
                              indentation ? (indentation - 1) / state.shiftWidth * state.shiftWidth : 0;
            auto indent = IndentText(newWidth, state.tabStop, state.expandTab);
            state.simpleInsert = false;
            ReplaceAtInsertCursors(state, buffer, {line.first, first}, indent,
                                   line.first + indent.size() + (at > first ? at - first : 0));
            return;
        }
        case 5: case 25: {
            bool above = key == Key(25);
            if (above ? row > 0 : row + 1 < buffer.rows) {
                Line other = buffer.line(above ? row - 1 : row + 1);
                Offset near = AtColumn(buffer, other, ColumnAt(buffer, at, state.tabStop), state.tabStop);
                if (near < other.end)
                    InsertText(state, buffer, buffer.read({near, buffer.next(near)}), false);
            }
            return;
        }
        case char32_t(Key::Delete):
            if (at < buffer.length)
                ReplaceAtInsertCursors(state, buffer, {at, buffer.next(at)}, u"", at);
            return;
        case char32_t(Key::Left):
        case char32_t(Key::Right):
        case char32_t(Key::WordLeft):
        case char32_t(Key::WordRight):
        case char32_t(Key::Up):
        case char32_t(Key::Down):
        case char32_t(Key::Home):
        case char32_t(Key::End): {
            Motion motion = ReadMotion(state, buffer, key, 1, false);
            if (motion.to != NoOffset && motion.to != at) {
                if (state.change && state.blockTop == state.blockBottom) {
                    SaveInsertedText(state, buffer, registers);
                    state.inputs.back() = {Key::Escape, {}};
                    FinishChange(state);
                }
                if (state.blockTop == state.blockBottom) {
                    state.inputs.assign(1, {state.mode == Mode::Replace ? Key('R') : Key('i'), {}});
                    state.commandStart = state.insertStart = motion.to;
                    state.insertCount = 1;
                    state.openCommand = 0;
                }
                MoveInsertMirrors(state, buffer, key, motion.to);
                state.cursor = motion.to;
                state.simpleInsert = state.blockTop == state.blockBottom;
                state.replacements.clear();
                if (!motion.vertical)
                    state.goalColumn = NoOffset;
            }
            return;
        }
        case char32_t(Key::Paste):
            InsertText(state, buffer, text, true);
            return;
        default:
            if (key == Key::Text || (char32_t(key) >= 32 && char32_t(key) < 0x110000))
                InsertText(state, buffer, KeyText(key, text), false);
    }
}

struct Pattern {
    std::u16string regex;
    bool ignoreCase;
};

static Pattern CompilePattern(const State &state, Text text)
{
    Pattern result{{}, state.ignoreCase};
    bool veryMagic = false;
    bool literal = false;
    bool sawUpper = false;
    bool manualCase = false;
    bool characterClass = false;
    constexpr Text metacharacters = u".^$*+?()[]{}|\\";
    for (Offset i = 0; i < text.size(); ++i) {
        char16_t ch = text[i];
        if (ch == '\\' && i + 1 < text.size()) {
            ch = text[++i];
            if (ch == 'c' || ch == 'C') {
                manualCase = true;
                result.ignoreCase = ch == 'c';
                continue;
            }
            if (ch == 'v' || ch == 'm' || ch == 'V') {
                veryMagic = ch == 'v';
                literal = ch == 'V';
                continue;
            }
            if (!literal && (ch == '<' || ch == '>')) {
                result.regex.append(u"\\b");
            } else if (!literal && ch == '(' && i && i + 2 < text.size() &&
                       text[i + 1] == '?' && text[i + 2] == ':') {
                result.regex.push_back('(');
            } else if (!literal && ch == '%' && i + 1 < text.size() && text[i + 1] == '(') {
                ++i;
                result.regex.append(u"(?:");
            } else if (!literal && !veryMagic && !characterClass && Text(u"+?(){}|=").find(ch) != Text::npos) {
                result.regex.push_back(ch == '=' ? '?' : ch);
            } else if (!literal && ch == 'k') {
                result.regex.append(u"\\w");
            } else if (!literal && ch == '_' && i + 1 < text.size() && text[i + 1] == '.') {
                ++i;
                result.regex.append(u"[\\s\\S]");
            } else {
                if (!literal || metacharacters.find(ch) != Text::npos)
                    result.regex.push_back('\\');
                result.regex.push_back(ch);
            }
            continue;
        }
        sawUpper |= Upper(ch);
        if (literal) {
            if (metacharacters.find(ch) != Text::npos)
                result.regex.push_back('\\');
        } else if (ch == '[') {
            characterClass = true;
        } else if (ch == ']') {
            characterClass = false;
        } else if (!veryMagic && !characterClass && Text(u"+?(){}|").find(ch) != Text::npos) {
            result.regex.push_back('\\');
        }
        result.regex.push_back(ch);
    }
    if (!manualCase && state.smartCase && sawUpper)
        result.ignoreCase = false;
    return result;
}

static std::optional<Match> Find(const Buffer &buffer, const Pattern &pattern, Range range,
                                 bool backwards, bool captures = false)
{
    if (!buffer.host.find || pattern.regex.empty())
        return std::nullopt;
    return buffer.host.find(buffer.host.document, pattern.regex, range, backwards, pattern.ignoreCase, captures);
}

static std::optional<Match> SearchObject(const State &state, const Buffer &buffer, bool backwards, unsigned count)
{
    Pattern pattern = CompilePattern(state, state.lastSearch);
    Offset cursor = state.cursor;
    Offset scan = buffer.line(buffer.row(cursor)).first;
    std::optional<Match> match;
    while (scan <= cursor) {
        auto found = Find(buffer, pattern, {scan, buffer.length}, false);
        if (!found || found->range.first > cursor)
            break;
        if (cursor < found->range.last) {
            match = std::move(found);
            break;
        }
        Offset next = std::max(found->range.last, buffer.next(found->range.first));
        if (next <= scan)
            break;
        scan = next;
    }

    Range selected = Ordered(state.anchor, cursor);
    bool extend = match && IsVisual(state.mode) && selected.first <= match->range.first &&
                  CellEnd(buffer, selected.last) >= match->range.last;
    if (match && !extend && --count == 0)
        return match;

    Offset edge = match ? (backwards ? match->range.first : match->range.last) : cursor;
    while (count--) {
        Range slice = backwards ? Range{0, edge} : Range{edge, buffer.length};
        match = Find(buffer, pattern, slice, backwards);
        if (!match && state.wrapSearch) {
            Range wrap = backwards ? Range{edge, buffer.length} : Range{0, edge};
            match = Find(buffer, pattern, wrap, backwards);
        }
        if (!match || match->range.empty())
            return {};
        edge = backwards ? match->range.first : match->range.last;
    }
    return match;
}

static Offset Search(const State &state, const Buffer &buffer, Text expression, Offset start,
                      bool backwards, unsigned count)
{
    if (expression.empty())
        return NoOffset;
    Pattern pattern = CompilePattern(state, expression);
    Offset result = start;
    while (count--) {
        Range primary = backwards ? Range{0, result} : Range{buffer.next(result), buffer.length};
        auto match = Find(buffer, pattern, primary, backwards);
        if (!match && state.wrapSearch) {
            Range wrap = backwards ? Range{result, buffer.length} : Range{0, buffer.next(result)};
            match = Find(buffer, pattern, wrap, backwards);
        }
        if (!match)
            return NoOffset;
        result = match->range.first;
    }
    return result;
}

std::vector<Range> SearchHighlights(const State &state, const Host &host, Range visible)
{
    Buffer buffer(host, state.finalNewline);
    if (state.mode == Mode::Confirm && state.substitutionIndex < state.substitutions.size()) {
        const Edit &edit = state.substitutions[state.substitutionIndex];
        return {{edit.at, edit.at + edit.before.size()}};
    }
    bool searching = state.mode == Mode::Command && state.prompt != ':';
    if (searching) {
        if (state.searchPreview == NoOffset)
            return {};
        auto match = Find(buffer, CompilePattern(state, state.command),
                          {state.searchPreview, buffer.length}, false);
        return match && match->range.first == state.searchPreview ? std::vector<Range>{match->range} :
                                                                    std::vector<Range>{};
    }
    if (!state.showMatches || !state.highlightSearch || state.lastSearch.empty())
        return {};

    Pattern pattern = CompilePattern(state, state.lastSearch);
    std::vector<Range> ranges;
    visible.last = std::min(visible.last, buffer.length);
    while (visible.first <= visible.last && ranges.size() < 4096) {
        auto match = Find(buffer, pattern, visible, false);
        if (!match)
            break;
        if (!match->range.empty())
            ranges.push_back(match->range);
        else if (match->range.first >= visible.last)
            break;
        visible.first = match->range.empty() ? buffer.next(match->range.first) : match->range.last;
    }
    return ranges;
}

Range WordAtCursor(const Host &host, Offset cursor)
{
    Buffer buffer(host, false);
    if (cursor < buffer.length && WordAt(buffer, cursor, false) == Word::Keyword)
        return WordObject(buffer, cursor, false, false, 1);
    if (cursor && cursor <= buffer.length) {
        Offset previous = buffer.prev(cursor);
        if (WordAt(buffer, previous, false) == Word::Keyword)
            return WordObject(buffer, previous, false, false, 1);
    }
    return {cursor, cursor};
}

static std::u16string WordPattern(const Buffer &buffer, Offset cursor, bool whole)
{
    Line line = buffer.line(buffer.row(cursor));
    while (cursor < line.end && WordAt(buffer, cursor, false) != Word::Keyword)
        cursor = buffer.next(cursor);
    if (cursor == line.end)
        return {};
    auto text = buffer.read(WordObject(buffer, cursor, false, false, 1));
    return whole ? u"\\<" + text + u"\\>" : text;
}

static void AddOccurrences(State &state, const Buffer &buffer, unsigned count)
{
    if (state.occurrences.empty()) {
        if (IsVisual(state.mode) && state.mode != Mode::Visual)
            return;
        Range first = IsVisual(state.mode) ? Selected(state, buffer).ranges.front() :
                      WordObject(buffer, state.cursor, false, false, 1);
        if (first.empty() || (!IsVisual(state.mode) && WordAt(buffer, state.cursor, false) != Word::Keyword))
            return;
        std::u16string pattern = IsVisual(state.mode) ? u"" : u"\\b";
        for (char16_t unit : buffer.read(first)) {
            if (Text(u"\\.^$|()[]{}*+?").find(unit) != Text::npos)
                pattern.push_back('\\');
            pattern.push_back(unit);
        }
        if (!IsVisual(state.mode)) {
            pattern.append(u"\\b");
            --count;
        }
        // This pattern is already escaped for the host's regular expression engine.
        state.occurrencePattern = std::move(pattern);
        state.occurrences.push_back(first);
        state.mode = Mode::Visual;
        state.anchor = first.first;
        state.cursor = buffer.prev(first.last);
        state.goalColumn = NoOffset;
        state.goalEnd = false;
    }
    Pattern pattern{state.occurrencePattern, false};
    Offset edge = CellEnd(buffer, state.cursor);
    Offset limit = edge;
    bool wrapped = false;
    while (count) {
        auto match = Find(buffer, pattern, {edge, wrapped ? limit : buffer.length}, false);
        if (!match && !wrapped) {
            edge = 0;
            wrapped = true;
            continue;
        }
        if (!match || match->range.empty())
            break;
        Range range = match->range;
        edge = range.last;
        auto at = std::lower_bound(state.occurrences.begin(), state.occurrences.end(), range.first,
                                   [](Range part, Offset start) { return part.first < start; });
        if (at != state.occurrences.end() && at->first < range.last)
            continue;
        if (at != state.occurrences.begin() && (at - 1)->last > range.first)
            continue;
        state.occurrences.insert(at, range);
        state.anchor = range.first;
        state.cursor = buffer.prev(range.last);
        --count;
    }
}

static std::u16string SubstituteText(const Buffer &buffer, const Match &match, Text replacement, Text newline,
                                     Text previous)
{
    std::u16string output;
    enum class Case { Keep, Upper, Lower, UpperOne, LowerOne } changeCase = Case::Keep;
    auto append = [&](Text text) {
        for (char16_t ch : text) {
            if (changeCase == Case::Upper || changeCase == Case::UpperOne) {
                if (Lower(ch))
                    ch -= 'a' - 'A';
            } else if (changeCase == Case::Lower || changeCase == Case::LowerOne) {
                if (Upper(ch))
                    ch += 'a' - 'A';
            }
            if (changeCase == Case::UpperOne || changeCase == Case::LowerOne)
                changeCase = Case::Keep;
            output.push_back(ch);
        }
    };
    for (Offset i = 0; i < replacement.size(); ++i) {
        char16_t ch = replacement[i];
        if (ch == '&') {
            append(buffer.read(match.range));
        } else if (ch == '~') {
            append(previous);
        } else if (ch == '\\' && ++i < replacement.size()) {
            ch = replacement[i];
            if (Digit(ch)) {
                Offset index = ch - '0';
                if (!index)
                    append(buffer.read(match.range));
                else if (index <= match.groups.size() && match.groups[index - 1].first != NoOffset)
                    append(buffer.read(match.groups[index - 1]));
            } else {
                switch (ch) {
                    case 'r': case 'n': append(newline); break;
                    case 't': append(u"\t"); break;
                    case 'u': changeCase = Case::UpperOne; break;
                    case 'l': changeCase = Case::LowerOne; break;
                    case 'U': changeCase = Case::Upper; break;
                    case 'L': changeCase = Case::Lower; break;
                    case 'e': case 'E': changeCase = Case::Keep; break;
                    default: append(Text(&ch, 1)); break;
                }
            }
        } else {
            append(Text(&ch, 1));
        }
    }
    return output;
}

static Text TrimLeft(Text text)
{
    while (!text.empty() && Space(text.front()))
        text.remove_prefix(1);
    return text;
}

static Text Trim(Text text)
{
    text = TrimLeft(text);
    while (!text.empty() && Space(text.back()))
        text.remove_suffix(1);
    return text;
}

static std::optional<Key> NamedKey(Text name)
{
    struct Name { Text name; Key key; };
    constexpr Name names[] = {
        {u"esc", Key::Escape}, {u"cr", Key::Enter}, {u"enter", Key::Enter},
        {u"return", Key::Enter}, {u"tab", Key::Tab}, {u"bs", Key::Backspace},
        {u"del", Key::Delete}, {u"left", Key::Left}, {u"right", Key::Right},
        {u"up", Key::Up}, {u"down", Key::Down}, {u"home", Key::Home}, {u"end", Key::End},
        {u"pageup", Key::PageUp}, {u"pagedown", Key::PageDown},
        {u"space", Key(' ')}, {u"lt", Key('<')}, {u"bar", Key('|')},
    };
    std::u16string lower(name);
    for (auto &unit : lower)
        unit = char16_t(Lowercase(unit));
    if (lower.size() == 3 && lower.starts_with(u"c-")) {
        if (Lower(lower[2]))
            return Key(lower[2] - 'a' + 1);
        if (lower[2] == '[')
            return Key::Escape;
    }
    for (auto item : names) {
        if (item.name == lower)
            return item.key;
    }
    return {};
}

static std::vector<Input> ReadKeys(Text text, Key leader = Key('\\'))
{
    std::vector<Input> keys;
    for (Offset i = 0; i < text.size(); ++i) {
        char32_t unit = text[i];
        if (unit == '<') {
            Offset end = text.find('>', i + 1);
            if (end != Text::npos && end - i <= 12) {
                auto name = text.substr(i + 1, end - i - 1);
                auto key = name == u"leader" || name == u"Leader" ? std::optional{leader} : NamedKey(name);
                if (key) {
                    keys.push_back({*key, {}, true});
                    i = end;
                    continue;
                }
            }
        } else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < text.size() &&
                   text[i + 1] >= 0xdc00 && text[i + 1] <= 0xdfff) {
            unit = 0x10000 + ((unit - 0xd800) << 10) + text[++i] - 0xdc00;
        }
        keys.push_back({Key(unit), {}, true});
    }
    return keys;
}

enum MappingMode : unsigned {
    MapNormal = 1, MapVisual = 2, MapOperator = 4, MapInsert = 8, MapCommand = 16
};

static bool SameKey(const Input &a, const Input &b)
{
    return a.key == b.key && a.text == b.text;
}

static bool SetMapping(Registers &registers, Text command, Text args)
{
    if (command == u"let") {
        if (!args.starts_with(u"mapleader"))
            return false;
        args = Trim(args.substr(9));
        if (!args.starts_with(u"="))
            return false;
        args = Trim(args.substr(1));
        if (args.size() == 3 && (args.front() == '"' || args.front() == '\'') && args.back() == args.front()) {
            registers.leader = Key(args[1]);
            return true;
        }
        if (args == u"\"\\\\\"") {
            registers.leader = Key('\\');
            return true;
        }
        return false;
    }
    constexpr unsigned defaultModes = MapNormal | MapVisual | MapOperator;
    unsigned modes = defaultModes;
    if (!command.empty() && command != u"noremap") {
        switch (command.front()) {
            case 'n': modes = MapNormal; break;
            case 'x': case 'v': modes = MapVisual; break;
            case 'o': modes = MapOperator; break;
            case 'i': modes = MapInsert; break;
            case 'c': modes = MapCommand; break;
            default: break;
        }
        if (modes != defaultModes)
            command.remove_prefix(1);
    }
    bool remove = command == u"unmap" || command == u"mapclear";
    if (!remove && command != u"map" && command != u"noremap")
        return false;
    if (args.starts_with(u"<silent>"))
        args = TrimLeft(args.substr(8));
    Offset split = 0;
    while (split < args.size() && !Space(args[split]))
        ++split;
    auto from = ReadKeys(args.substr(0, split), registers.leader);
    Text replacement = Trim(args.substr(split));
    if (from.empty() && command != u"mapclear")
        return true;
    if (!remove && replacement.empty())
        return true;
    auto to = replacement == u"<Nop>" || replacement == u"<nop>" ?
              std::vector<Input>{} : ReadKeys(replacement, registers.leader);
    for (auto &map : registers.mappings) {
        if (command == u"mapclear" || std::ranges::equal(map.from, from, SameKey))
            map.modes &= ~modes;
    }
    std::erase_if(registers.mappings, [](const Mapping &mapping) { return !mapping.modes; });
    if (!remove)
        registers.mappings.push_back({modes, command == u"map", std::move(from), std::move(to)});
    return true;
}

Offset LoadMappings(Registers &registers, Text config)
{
    Offset loaded = 0;
    while (!config.empty()) {
        Offset end = config.find('\n');
        Text line = Trim(config.substr(0, end));
        if (line.starts_with(u":"))
            line = TrimLeft(line.substr(1));
        Offset name = 0;
        while (name < line.size() && Lower(line[name]))
            ++name;
        if (name)
            loaded += SetMapping(registers, line.substr(0, name), TrimLeft(line.substr(name)));
        if (end == Text::npos)
            break;
        config.remove_prefix(end + 1);
    }
    return loaded;
}

static unsigned ReadCount(Text &text)
{
    unsigned value = 0;
    while (!text.empty() && Digit(text.front())) {
        value = std::min(maxCount, value * 10 + (text.front() - '0'));
        text.remove_prefix(1);
    }
    return value;
}

static std::u16string Decimal(Offset number)
{
    std::string text = std::to_string(number);
    return std::u16string(text.begin(), text.end());
}

static std::optional<Offset> ExAddress(State &state, const Buffer &buffer, Text &text, bool *beforeFirst = nullptr)
{
    text = TrimLeft(text);
    if (text.empty())
        return std::nullopt;
    Offset number = buffer.row(state.cursor) + 1;
    char16_t key = text.front();
    if (Digit(key)) {
        number = std::min<Offset>(buffer.rows, ReadCount(text));
    } else if (key == '.' || key == '$') {
        text.remove_prefix(1);
        if (key == '$')
            number = buffer.rows;
    } else if (key == '\'' && text.size() >= 2) {
        key = text[1];
        text.remove_prefix(2);
        if ((key == '<' || key == '>') && state.lastVisual != Mode::Normal) {
            auto range = Ordered(state.lastAnchor, state.lastVisualCursor);
            number = buffer.row(key == '<' ? range.first : range.last) + 1;
        } else if (Lower(key) && state.marks[key - 'a'] != NoOffset) {
            number = buffer.row(state.marks[key - 'a']) + 1;
        } else {
            return std::nullopt;
        }
    } else if (key != '+' && key != '-') {
        return std::nullopt;
    }
    text = TrimLeft(text);
    while (!text.empty() && (text.front() == '+' || text.front() == '-')) {
        bool after = text.front() == '+';
        text.remove_prefix(1);
        text = TrimLeft(text);
        unsigned amount = std::max(1U, ReadCount(text));
        number = after ? std::min(buffer.rows, number + amount) : number - std::min<Offset>(number, amount);
        text = TrimLeft(text);
    }
    if (beforeFirst)
        *beforeFirst = number == 0;
    return number ? number - 1 : 0;
}

static std::u16string Delimited(Text &text, char16_t delimiter)
{
    std::u16string value;
    while (!text.empty()) {
        char16_t ch = text.front();
        text.remove_prefix(1);
        if (ch == delimiter)
            break;
        if (ch == '\\' && !text.empty()) {
            if (text.front() != delimiter)
                value.push_back(ch);
            ch = text.front();
            text.remove_prefix(1);
        }
        value.push_back(ch);
    }
    return value;
}

static void Substitute(State &state, Buffer &buffer, Offset top, Offset bottom, Text args)
{
    std::u16string pattern;
    std::u16string replacement = state.lastSubstitute;
    if (!args.empty() && !Lower(args.front()) && !Upper(args.front()) && !Blank(args.front()) &&
        !Digit(args.front())) {
        char16_t delimiter = args.front();
        args.remove_prefix(1);
        pattern = Delimited(args, delimiter);
        replacement = Delimited(args, delimiter);
    }
    Offset endFlags = 0;
    while (endFlags < args.size() && !Blank(args[endFlags]) && !Digit(args[endFlags]))
        ++endFlags;
    Text countText = Trim(args.substr(endFlags));
    if (unsigned count = ReadCount(countText)) {
        top = bottom;
        bottom = std::min(buffer.rows - 1, bottom + count - 1);
    }
    args = args.substr(0, endFlags);
    if (pattern.empty())
        pattern = state.lastSearch;
    if (pattern.empty()) {
        state.message = u"No previous search";
        return;
    }
    state.lastSearch = pattern;
    Pattern compiled = CompilePattern(state, pattern);
    if (args.find(u'i') != Text::npos)
        compiled.ignoreCase = true;
    if (args.find(u'I') != Text::npos)
        compiled.ignoreCase = false;
    bool all = args.find(u'g') != Text::npos;
    bool confirm = args.find(u'c') != Text::npos;
    std::vector<Edit> edits;
    for (Offset row = top; row <= bottom; ++row) {
        Line line = buffer.line(row);
        Range scope{line.first, line.end};
        auto newline = EndOfLine(buffer, row);
        while (auto match = Find(buffer, compiled, scope, false, true)) {
            edits.push_back({match->range.first, buffer.read(match->range),
                             SubstituteText(buffer, *match, replacement, newline, state.lastSubstitute)});
            if (!all || (match->range.empty() && match->range.first >= scope.last))
                break;
            scope.first = match->range.empty() ? buffer.next(match->range.first) : match->range.last;
        }
    }
    state.lastSubstitute = replacement;
    if (edits.empty()) {
        state.message = u"Pattern not found";
        return;
    }
    if (args.find(u'n') != Text::npos) {
        state.message = Decimal(edits.size()) + u" matches";
        return;
    }
    if (confirm) {
        state.substitutionOriginalCursor = state.cursor;
        state.substitutionIndex = 0;
        state.cursor = edits.front().at;
        state.substitutions = std::move(edits);
        state.mode = Mode::Confirm;
        return;
    }
    Offset last = buffer.row(edits.back().at);
    for (auto edit = edits.rbegin(); edit != edits.rend(); ++edit)
        Replace(state, buffer, {edit->at, edit->at + edit->before.size()}, edit->after);
    state.cursor = FirstNonblank(buffer, buffer.line(std::min(last, buffer.rows - 1)));
    state.message = Decimal(edits.size()) + u" substitutions";
}

static void ConfirmSubstitute(State &state, Buffer &buffer, Key key)
{
    bool all = key == Key('a');
    bool finish = key == Key('q') || key == Key::Escape || key == Key(3) || key == Key('l');
    if (!finish && !all && key != Key('y') && key != Key('n'))
        return;
    if (all || key == Key('y') || key == Key('l')) {
        do {
            auto &edit = state.substitutions[state.substitutionIndex];
            Range range{edit.at, edit.at + edit.before.size()};
            Replace(state, buffer, range, edit.after);
            ++state.substitutionIndex;
            for (Offset i = state.substitutionIndex; i < state.substitutions.size(); ++i)
                state.substitutions[i].at = OffsetAfterEdit(state.substitutions[i].at, range, edit.after.size());
        } while (all && state.substitutionIndex < state.substitutions.size());
    } else if (key == Key('n')) {
        ++state.substitutionIndex;
    }
    if (finish || state.substitutionIndex == state.substitutions.size()) {
        state.mode = Mode::Normal;
        state.cursor = NormalPosition(buffer, state.change ? state.cursor : state.substitutionOriginalCursor);
        state.substitutions.clear();
    } else {
        state.cursor = state.substitutions[state.substitutionIndex].at;
    }
}

static void Undo(State &state, Buffer &buffer, bool redo, unsigned count)
{
    FinishChange(state);
    if (!buffer.host.undo)
        return;
    while (count--) {
        auto cursor = buffer.host.undo(buffer.host.context, redo);
        if (!cursor)
            break;
        buffer.reset();
        state.cursor = NormalPosition(buffer, *cursor);
        state.goalColumn = NoOffset;
        state.goalEnd = false;
    }
}

static void UndoLine(State &state, Buffer &buffer)
{
    auto saved = state.lineUndo;
    if (!saved)
        return;
    Line line = buffer.line(buffer.row(saved->start));
    if (line.first != saved->start)
        return;
    auto current = buffer.read({line.first, line.end});
    if (current == saved->text)
        return;
    Offset position = std::clamp(state.cursor, line.first, line.end);
    Replace(state, buffer, {line.first, line.end}, saved->text);
    state.lineUndo = std::make_shared<LineUndo>(LineUndo{line.first, position - line.first, std::move(current)});
    state.cursor = NormalPosition(buffer, line.first + std::min(saved->column, saved->text.size()));
}

static void SetOptions(State &state, Text options)
{
    struct Toggle {
        Text name;
        Text shortName;
        bool State::*value;
    };
    static constexpr Toggle toggles[] = {
        {u"number", u"nu", &State::number}, {u"relativenumber", u"rnu", &State::relativeNumber},
        {u"ignorecase", u"ic", &State::ignoreCase}, {u"smartcase", u"scs", &State::smartCase},
        {u"hlsearch", u"hls", &State::highlightSearch}, {u"incsearch", u"is", &State::incrementalSearch},
        {u"wrapscan", u"ws", &State::wrapSearch}, {u"autoindent", u"ai", &State::autoIndent},
        {u"expandtab", u"et", &State::expandTab},
    };
    while (!options.empty()) {
        Offset space = options.find_first_of(u" \t");
        Text option = options.substr(0, space);
        options = space == Text::npos ? Text{} : Trim(options.substr(space));
        bool off = option.starts_with(u"no") && option != u"number";
        bool flip = option.starts_with(u"inv") || option.ends_with(u"!");
        bool query = option.ends_with(u"?");
        Text name = option;
        if (off)
            name.remove_prefix(2);
        else if (name.starts_with(u"inv"))
            name.remove_prefix(3);
        if (query || name.ends_with(u"!"))
            name.remove_suffix(1);
        auto toggle = std::find_if(std::begin(toggles), std::end(toggles), [&](const Toggle &entry) {
            return name == entry.name || name == entry.shortName;
        });
        if (toggle != std::end(toggles)) {
            bool &value = state.*toggle->value;
            if (query)
                state.message = (value ? u"" : u"no") + std::u16string(toggle->name);
            else
                value = flip ? !value : !off;
            if (toggle->value == &State::highlightSearch)
                state.showMatches = value && !state.lastSearch.empty();
            continue;
        }
        Offset equals = option.find('=');
        Text numeric = option.substr(0, equals);
        if (numeric == u"tabstop" || numeric == u"ts" || numeric == u"shiftwidth" || numeric == u"sw") {
            bool tab = numeric == u"tabstop" || numeric == u"ts";
            if (equals != Text::npos) {
                Text amount = option.substr(equals + 1);
                unsigned width = ReadCount(amount);
                if (amount.empty() && width <= 32 && (width || !tab)) {
                    (tab ? state.tabStop : state.shiftWidth) = width ? width : state.tabStop;
                    continue;
                }
            }
        }
        state.message = u"Unknown option: " + std::u16string(option);
        break;
    }
}

static void ExGlobal(State &state, Buffer &buffer, Registers &registers,
                     Offset top, Offset bottom, Text args, bool invert)
{
    if (args.empty())
        return;
    char16_t delimiter = args.front();
    args.remove_prefix(1);
    auto pattern = Delimited(args, delimiter);
    args = Trim(args);
    if (pattern.empty())
        pattern = state.lastSearch;
    if (pattern.empty())
        return;
    Pattern compiled = CompilePattern(state, pattern);
    std::vector<Offset> rows;
    for (Offset row = top; row <= bottom; ++row) {
        Line line = buffer.line(row);
        if (bool(Find(buffer, compiled, {line.first, line.end}, false)) != invert)
            rows.push_back(row);
    }
    if (!args.empty() && args.front() == 'd' && (args == u"d" || args == u"delete" || args == u"d _" || args == u"d_")) {
        if (args.back() == '_')
            state.selectedRegister = '_';
        for (auto row = rows.rbegin(); row != rows.rend(); ++row)
            ApplyOperator(state, buffer, registers, Op::Delete, LineSelection(buffer, *row, *row));
        state.selectedRegister = 0;
    } else if (args.size() > 1 && args.front() == 's') {
        for (auto row = rows.rbegin(); row != rows.rend(); ++row)
            Substitute(state, buffer, *row, *row, args.substr(1));
    } else {
        state.message = Decimal(rows.size()) + u" matching lines";
    }
}

static void ExSort(State &state, Buffer &buffer, Offset top, Offset bottom, Text args, bool reverse)
{
    std::vector<std::u16string> rows;
    for (Offset row = top; row <= bottom; ++row) {
        Line line = buffer.line(row);
        rows.push_back(buffer.read({line.first, line.end}));
    }
    if (args.find('i') != Text::npos) {
        std::stable_sort(rows.begin(), rows.end(), [](Text a, Text b) {
            return std::lexicographical_compare(a.begin(), a.end(), b.begin(), b.end(),
                                                [](char16_t x, char16_t y) { return Lowercase(x) < Lowercase(y); });
        });
    } else {
        std::sort(rows.begin(), rows.end());
    }
    if (args.find('u') != Text::npos)
        rows.erase(std::unique(rows.begin(), rows.end()), rows.end());
    if (reverse)
        std::reverse(rows.begin(), rows.end());
    std::u16string newline = EndOfLine(buffer, top);
    std::u16string text;
    for (std::size_t i = 0; i < rows.size(); ++i) {
        if (i)
            text.append(newline);
        text.append(rows[i]);
    }
    Line first = buffer.line(top);
    Line last = buffer.line(bottom);
    Replace(state, buffer, {first.first, last.end}, text);
    state.cursor = FirstNonblank(buffer, buffer.line(top));
}

static void DispatchAction(const Buffer &buffer, Action action, Text args = {}, bool force = false)
{
    if (buffer.host.action)
        buffer.host.action(buffer.host.context, action, args, force);
}

static void FeedInput(State &, Buffer &, Registers &, Key, Text, bool);
static void Play(State &, Buffer &, Registers &, const std::vector<Input> &, unsigned);
static void FeedMapped(State &, Buffer &, Registers &, Input, bool flush = false);

static void ExecuteNormal(State &state, Buffer &buffer, Registers &registers, Offset top, Offset bottom,
                          bool range, Text keys, bool remap)
{
    auto inputs = ReadKeys(keys);
    if (inputs.empty() || state.groupChanges)
        return;

    auto originalInputs = std::move(state.inputs);
    state.groupChanges = true;
    state.exEnd = bottom + 1 == buffer.rows ? buffer.length + 1 : buffer.line(bottom + 1).first;
    Offset at = range ? buffer.line(top).first : state.cursor;
    for (Offset i = 0; i <= bottom - top && at < state.exEnd && state.executionBudget; ++i) {
        Line line = buffer.line(buffer.row(at));
        state.exNextLine = line.next < state.exEnd && buffer.row(at) + 1 < buffer.rows ? line.next : NoOffset;
        state.mode = Mode::Normal;
        state.cursor = NormalPosition(buffer, at);
        ClearCommand(state);
        state.inputs.clear();
        if (remap && !registers.mappings.empty()) {
            for (const auto &input : inputs)
                FeedMapped(state, buffer, registers, input);
            FeedMapped(state, buffer, registers, {Key::None, {}}, true);
        } else {
            Play(state, buffer, registers, inputs, 1);
        }
        if (IsInsert(state.mode) || state.mode == Mode::Command || state.mode == Mode::Confirm)
            FeedInput(state, buffer, registers, Key::Escape, {}, false);
        LeaveVisual(state);
        if (state.exNextLine == NoOffset || !buffer.length)
            break;
        at = state.exNextLine;
    }
    state.exNextLine = state.exEnd = NoOffset;
    state.inputs = std::move(originalInputs);
    state.groupChanges = false;
}

static void ExecuteEx(State &state, Buffer &buffer, Registers &registers, Text text)
{
    Offset top = buffer.row(state.cursor);
    Offset bottom = top;
    bool range = false;
    text = TrimLeft(text);
    if (text.starts_with(u"%")) {
        text = TrimLeft(text.substr(1));
        range = true;
        top = 0;
        bottom = buffer.rows - 1;
    } else if (auto address = ExAddress(state, buffer, text)) {
        range = true;
        top = bottom = *address;
        if (!text.empty() && (text.front() == ',' || text.front() == ';')) {
            text.remove_prefix(1);
            bottom = ExAddress(state, buffer, text).value_or(buffer.rows - 1);
            if (top > bottom)
                std::swap(top, bottom);
        }
    }
    if (text.empty()) {
        if (range) {
            SaveJump(state, buffer);
            state.cursor = FirstNonblank(buffer, buffer.line(bottom));
        }
        return;
    }
    Offset letters = 0;
    while (letters < text.size() && (Lower(text[letters]) || Upper(text[letters])))
        ++letters;
    if (!letters)
        letters = 1;
    Text name = text.substr(0, letters);
    Text args = text.substr(letters);
    bool force = args.starts_with(u"!");
    if (force)
        args.remove_prefix(1);
    if (name == u"norm" || name == u"norma" || name == u"normal") {
        ExecuteNormal(state, buffer, registers, top, bottom, range, TrimLeft(args), !force);
        return;
    }
    args = Trim(args);
    if (SetMapping(registers, name, args)) {
        return;
    } else if (name == u"source" || name == u"so") {
        if (!args.empty())
            DispatchAction(buffer, Action::SourceMappings, args);
    } else if (name == u"s" || name == u"substitute" || name == u"&") {
        Substitute(state, buffer, top, bottom, args);
    } else if (name == u"set" || name == u"se" || name == u"setlocal") {
        SetOptions(state, args);
    } else if (name == u"nohlsearch" || name == u"noh") {
        state.showMatches = false;
    } else if (name == u"w" || name == u"write" || name == u"up" || name == u"update") {
        DispatchAction(buffer, args.empty() ? Action::Save : Action::WriteCopy, args, force);
    } else if (name == u"wq" || name == u"x" || name == u"xit" || name == u"exit") {
        DispatchAction(buffer, Action::SaveClose, args, force);
    } else if (name == u"q" || name == u"quit" || name == u"close") {
        DispatchAction(buffer, Action::Close, {}, force);
    } else if (name == u"e" || name == u"edit" || name == u"open") {
        DispatchAction(buffer, args.empty() ? Action::Revert : Action::Open, args, force);
    } else if (name == u"sav" || name == u"saveas") {
        DispatchAction(buffer, Action::SaveAs, args, force);
    } else if (name == u"bn" || name == u"bnext" || name == u"tabnext") {
        DispatchAction(buffer, Action::NextWindow);
    } else if (name == u"bp" || name == u"bprevious" || name == u"tabprevious") {
        DispatchAction(buffer, Action::PreviousWindow);
    } else if (name == u"sp" || name == u"split" || name == u"vs" || name == u"vsplit") {
        DispatchAction(buffer, name.front() == 'v' ? Action::SplitRight : Action::SplitBelow, args);
    } else if (name == u"on" || name == u"only") {
        DispatchAction(buffer, Action::WindowCommand, u"o");
    } else if (name == u"u" || name == u"undo" || name == u"red" || name == u"redo") {
        Undo(state, buffer, name.starts_with(u"r"), 1);
    } else if (name == u"g" || name == u"global" || name == u"v" || name == u"vglobal") {
        ExGlobal(state, buffer, registers, range ? top : 0, range ? bottom : buffer.rows - 1,
                 args, force || name.starts_with(u"v"));
    } else if (name == u"sort" || name == u"sor") {
        ExSort(state, buffer, range ? top : 0, range ? bottom : buffer.rows - 1, args, force);
    } else if (name == u"d" || name == u"delete" || name == u"y" || name == u"yank" ||
               name == u"c" || name == u"change" || name == u">" || name == u"<") {
        if (!args.empty() && RegisterName(args.front()) && !Digit(args.front())) {
            state.selectedRegister = args.front();
            args = Trim(args.substr(1));
        }
        if (auto count = ReadCount(args))
            bottom = std::min(buffer.rows - 1, bottom + count - 1);
        Op op = name.front() == 'd' ? Op::Delete : name.front() == 'y' ? Op::Yank :
                name.front() == 'c' ? Op::Change : name.front() == '>' ? Op::ShiftRight : Op::ShiftLeft;
        ApplyOperator(state, buffer, registers, op, LineSelection(buffer, top, bottom));
        state.selectedRegister = 0;
    } else if (name == u"j" || name == u"join") {
        JoinLines(state, buffer, top, range ? bottom : std::min(buffer.rows - 1, top + 1), !force);
    } else if (name == u"pu" || name == u"put") {
        state.cursor = buffer.line(bottom).first;
        if (!args.empty() && RegisterName(args.front()))
            state.selectedRegister = args.front();
        Put(state, buffer, registers, !force, false, 1);
        state.selectedRegister = 0;
    } else if (name == u"m" || name == u"move" || name == u"co" || name == u"copy" || name == u"t") {
        bool beforeFirst = false;
        if (auto destination = ExAddress(state, buffer, args, &beforeFirst)) {
            bool move = name.front() == 'm';
            if (move && (beforeFirst ? top == 0 : top <= *destination && *destination <= bottom))
                return;
            auto selection = LineSelection(buffer, top, bottom);
            Register value = ReadSelection(state, buffer, selection);
            Registers temporary;
            SetRegister(temporary, '"', std::move(value));
            if (move) {
                ApplyOperator(state, buffer, registers, Op::Delete, selection, 1, false);
                if (*destination > bottom)
                    *destination -= bottom - top + 1;
            }
            state.cursor = buffer.line(std::min(*destination, buffer.rows - 1)).first;
            Put(state, buffer, temporary, !beforeFirst, false, 1);
        }
    } else {
        state.message = u"Not an editor command: " + std::u16string(name);
    }
}

static void StartCommand(State &state, char32_t prompt)
{
    state.beforeCommand = state.mode;
    state.mode = Mode::Command;
    state.prompt = prompt;
    state.command = prompt == ':' && IsVisual(state.beforeCommand) ? u"'<,'>" : u"";
    state.commandCaret = state.command.size();
    state.historyIndex = NoOffset;
    state.searchPreview = NoOffset;
}

static void Move(State &state, Buffer &buffer, Registers &registers, Motion motion)
{
    if (motion.to != NoOffset) {
        if (state.op != Op::None) {
            ApplyOperator(state, buffer, registers, state.op, MotionSelection(state, buffer, motion));
        } else {
            if (motion.jump && motion.to != state.cursor)
                SaveJump(state, buffer);
            state.cursor = state.mode == Mode::Visual ?
                           std::min(motion.to, buffer.line(buffer.row(motion.to)).end) :
                           NormalPosition(buffer, motion.to);
            if (!motion.vertical) {
                state.goalColumn = NoOffset;
                state.goalEnd = motion.endColumn;
            }
        }
    }
    ClearCommand(state);
}

static void SearchMotion(State &state, Buffer &buffer, Registers &registers, bool backwards, unsigned count)
{
    Offset result = Search(state, buffer, state.lastSearch, state.cursor, backwards, count);
    if (result == NoOffset) {
        state.message = state.lastSearch.empty() ? u"No previous search" : u"Pattern not found";
        ClearCommand(state);
        return;
    }
    state.showMatches = state.highlightSearch;
    Move(state, buffer, registers, {result, Kind::Character, false, true});
}

static void AddHistory(std::vector<std::u16string> &history, Text command)
{
    if (command.empty() || (!history.empty() && history.back() == command))
        return;
    if (history.size() >= 100)
        history.erase(history.begin());
    history.emplace_back(command);
}

static void CommandKey(State &state, Buffer &buffer, Registers &registers, Key key, Text text)
{
    auto &history = state.prompt == ':' ? state.commandHistory : state.searchHistory;
    auto &command = state.command;
    auto &caret = state.commandCaret;
    if (state.prefix == Prefix::CommandLiteral) {
        auto literal = KeyText(key, text);
        command.insert(caret, literal);
        caret += literal.size();
        state.prefix = Prefix::None;
    } else if (state.prefix == Prefix::CommandRegister && key != Key::Escape) {
        if (RegisterName(char32_t(key))) {
            if (auto value = ReadRegister(state, buffer.host, registers, char32_t(key))) {
                command.insert(caret, value->text);
                caret += value->text.size();
            }
        }
        state.prefix = Prefix::None;
    } else {
        switch (char32_t(key)) {
            case 3: case char32_t(Key::Escape):
                state.mode = state.beforeCommand;
                state.searchPreview = NoOffset;
                ClearCommand(state);
                return;
            case '\n': case '\r': {
                AddHistory(history, command);
                state.mode = state.beforeCommand;
                state.searchPreview = NoOffset;
                if (state.prompt == ':') {
                    LeaveVisual(state);
                    Register value;
                    value.text = command;
                    auto lastCommand = SetRegister(registers, ':', std::move(value));
                    ExecuteEx(state, buffer, registers, lastCommand->text);
                    ClearCommand(state);
                } else {
                    if (!command.empty())
                        state.lastSearch = command;
                    state.searchBackwards = state.prompt == '?';
                    unsigned count = unsigned(std::min<uint64_t>(maxCount, std::max(1U, state.count) *
                                                                uint64_t(state.operatorCount)));
                    SearchMotion(state, buffer, registers, state.searchBackwards, count);
                }
                return;
            }
            case 18:
                state.prefix = Prefix::CommandRegister;
                return;
            case 22:
                state.prefix = Prefix::CommandLiteral;
                return;
            case char32_t(Key::Backspace): case 127:
                if (caret)
                    command.erase(--caret, 1);
                else if (command.empty()) {
                    state.mode = state.beforeCommand;
                    ClearCommand(state);
                    return;
                }
                break;
            case 21:
                command.erase(0, caret);
                caret = 0;
                break;
            case 23:
                while (caret && Blank(command[caret - 1]))
                    command.erase(--caret, 1);
                while (caret && !Blank(command[caret - 1]))
                    command.erase(--caret, 1);
                break;
            case char32_t(Key::Delete):
                if (caret < command.size())
                    command.erase(caret, 1);
                break;
            case char32_t(Key::Left):
                caret -= caret != 0;
                break;
            case char32_t(Key::Right):
                caret += caret < command.size();
                break;
            case char32_t(Key::Home):
                caret = 0;
                break;
            case char32_t(Key::End):
                caret = command.size();
                break;
            case char32_t(Key::Up): case char32_t(Key::Down): {
                Offset index = state.historyIndex == NoOffset ? history.size() : state.historyIndex;
                if (key == Key::Up)
                    index -= index != 0;
                else if (index < history.size())
                    ++index;
                command = index < history.size() ? history[index] : u"";
                caret = command.size();
                state.historyIndex = index;
                break;
            }
            default:
                if (key == Key::Text || key == Key::Paste || (char32_t(key) >= 32 && char32_t(key) < 0x110000)) {
                    auto inserted = KeyText(key, text);
                    command.insert(caret, inserted);
                    caret += inserted.size();
                }
                break;
        }
    }
    if (state.prompt != ':' && state.incrementalSearch)
        state.searchPreview = Search(state, buffer, command, state.cursor, state.prompt == '?', 1);
}

static unsigned Count(const State &state)
{
    return unsigned(std::min<uint64_t>(maxCount, state.operatorCount * uint64_t(std::max(1U, state.count))));
}

static Op Operator(char32_t command)
{
    switch (command) {
        case 'y': return Op::Yank;
        case 'd': return Op::Delete;
        case 'c': return Op::Change;
        case '<': return Op::ShiftLeft;
        case '>': return Op::ShiftRight;
        case '=': return Op::Indent;
        case 'u': return Op::Lower;
        case 'U': return Op::Upper;
        case '~': return Op::Toggle;
    }
    return Op::None;
}

static void StartOperator(State &state, Buffer &buffer, Registers &registers, Op op)
{
    if (IsVisual(state.mode)) {
        ApplyOperator(state, buffer, registers, op, Selected(state, buffer), Count(state));
        ClearCommand(state);
    } else if (state.op == op) {
        Offset first = buffer.row(state.cursor);
        Offset last = std::min(buffer.rows - 1, first + Count(state) - 1);
        ApplyOperator(state, buffer, registers, op, LineSelection(buffer, first, last));
        ClearCommand(state);
    } else if (state.op == Op::None) {
        state.op = op;
        state.operatorCount = Count(state);
        state.count = 0;
    } else {
        ClearCommand(state);
    }
}

static Selection Characters(const Buffer &buffer, Range range)
{
    Selection selected;
    selected.top = buffer.row(range.first);
    selected.bottom = buffer.row(range.empty() ? range.last : buffer.prev(range.last));
    selected.ranges.push_back(range);
    return selected;
}

static void StartVisual(State &state, const Buffer &buffer, Mode mode, unsigned count)
{
    if (state.mode == mode) {
        LeaveVisual(state);
    } else if (IsVisual(state.mode)) {
        state.mode = mode;
    } else {
        state.anchor = state.cursor;
        state.mode = mode;
        if (mode == Mode::VisualLine)
            state.cursor = NormalPosition(buffer, Vertical(state, buffer, true, count - 1).to);
        else if (mode == Mode::Visual && count > 1)
            state.cursor = ReadMotion(state, buffer, Key('l'), count - 1, false).to;
        else if (mode == Mode::VisualBlock && count > 1)
            state.cursor = NormalPosition(buffer, ReadMotion(state, buffer, Key('l'), count - 1, false).to);
    }
    ClearCommand(state);
}

static void SelectObject(State &state, Buffer &buffer, Registers &registers, char32_t key, bool around)
{
    if (auto object = TextObject(state, buffer, key, around, Count(state))) {
        if (state.op != Op::None) {
            ApplyOperator(state, buffer, registers, state.op, std::move(*object));
        } else {
            Range range = object->ranges.front();
            if (object->kind == Kind::Character && range.size() &&
                state.anchor == range.first && state.cursor == buffer.prev(range.last)) {
                State next;
                next.cursor = range.last;
                auto extended = TextObject(next, buffer, key, around, 1);
                if (extended && extended->ranges.front().last > range.last)
                    range.last = extended->ranges.front().last;
            }
            state.mode = object->kind == Kind::Line ? Mode::VisualLine : Mode::Visual;
            state.anchor = range.first;
            state.cursor = range.empty() ? range.first : NormalPosition(buffer, buffer.prev(range.last));
        }
    }
    ClearCommand(state);
}

static Offset Mark(const State &state, char32_t mark)
{
    if (Lower(mark))
        return state.marks[mark - 'a'];
    if (Upper(mark))
        return state.marks[26 + mark - 'A'];
    if (mark == '\'' || mark == 0x60)
        return state.jumps.empty() ? NoOffset : state.jumps.back();
    if (mark == '.')
        return state.changes.empty() ? NoOffset : state.changes.back();
    if (mark == '^')
        return state.lastInsert;
    if (mark == '<' || mark == '>') {
        if (state.lastVisual == Mode::Normal)
            return NoOffset;
        auto marks = Ordered(state.lastAnchor, state.lastVisualCursor);
        return mark == '<' ? marks.first : marks.last;
    }
    return NoOffset;
}

static void WordSearch(State &state, Buffer &buffer, Registers &registers, bool backwards, bool whole)
{
    auto pattern = WordPattern(buffer, state.cursor, whole);
    if (!pattern.empty()) {
        state.lastSearch = std::move(pattern);
        state.searchBackwards = backwards;
        SearchMotion(state, buffer, registers, backwards, Count(state));
    } else {
        ClearCommand(state);
    }
}

static void Scroll(State &state, Buffer &buffer, char32_t key, unsigned count)
{
    Range view = buffer.host.viewport ? buffer.host.viewport(buffer.host.document) : Range{0, buffer.rows};
    Offset top = std::min(view.first, buffer.rows - 1);
    Offset rows = std::max<Offset>(1, view.last > top ? view.last - top : 1);
    if (buffer.host.hiddenRows)
        rows -= std::min(rows - 1, buffer.host.hiddenRows(buffer.host.context, {top, view.last}));
    Offset row = buffer.row(state.cursor);
    if (key == 'z' || key == 't' || key == 'b' || key == '.' || key == '-' || key == '\r') {
        if (state.count) {
            row = std::min<Offset>(state.count, buffer.rows) - 1;
            state.cursor = FirstNonblank(buffer, buffer.line(row));
        } else if (key == '.' || key == '-' || key == '\r') {
            state.cursor = FirstNonblank(buffer, buffer.line(row));
        }
        Offset above = key == 'z' || key == '.' ? rows / 2 : key == 'b' || key == '-' ? rows - 1 : 0;
        top = StepRow(buffer, row, false, above);
    } else {
        bool down = key == 4 || key == 6 || key == 5 || key == char32_t(Key::PageDown);
        bool full = key == 6 || key == 2 || key == char32_t(Key::PageUp) || key == char32_t(Key::PageDown);
        bool scrollOnly = key == 5 || key == 25;
        if (!scrollOnly && !full && state.count)
            state.scrollLines = count;
        Offset amount = scrollOnly ? count : full ? std::max<Offset>(1, rows - 2) * count :
                        state.scrollLines ? state.scrollLines : std::max<Offset>(1, rows / 2);
        top = StepRow(buffer, top, down, amount);
        Offset target = row;
        if (scrollOnly) {
            target = std::clamp(row, top, StepRow(buffer, top, true, rows - 1));
        } else {
            target = StepRow(buffer, row, down, amount);
        }
        if (target != row) {
            if (state.goalColumn == NoOffset)
                state.goalColumn = ColumnAt(buffer, state.cursor, state.tabStop);
            state.cursor = NormalPosition(buffer, ColumnPosition(state, buffer, target));
        }
    }
    if (buffer.host.scroll)
        buffer.host.scroll(buffer.host.context, top);
    ClearCommand(state);
}

static void ReplaceCharacters(State &state, Buffer &buffer, Key key, Text text)
{
    if (key == Key::Escape || key == Key(3))
        return;
    bool newline = key == Key::Enter || key == Key('\n');
    if (!newline && key != Key::Text && key != Key::Tab &&
        (char32_t(key) < 32 || char32_t(key) >= 0x110000))
        return;
    std::u16string replacement = newline ? EndOfLine(buffer, buffer.row(state.cursor)) : KeyText(key, text);
    if (replacement.empty())
        return;
    bool visual = IsVisual(state.mode);
    auto selected = visual ? Selected(state, buffer) : Selection{};
    Offset start = state.cursor;
    if (visual) {
        RememberVisual(state, buffer, selected);
        LeaveVisual(state);
        start = selected.ranges.front().first;
    } else {
        Offset end = state.cursor;
        Line line = buffer.line(buffer.row(end));
        for (unsigned i = 0; i < Count(state); ++i) {
            if (end >= line.end)
                return;
            end = buffer.next(end);
        }
        selected.ranges.push_back({start, end});
    }
    for (auto range = selected.ranges.rbegin(); range != selected.ranges.rend(); ++range) {
        if (newline) {
            Replace(state, buffer, *range, replacement);
        } else {
            std::u16string filled;
            for (Offset p = range->first; p < range->last; p = buffer.next(p)) {
                if (Break(buffer.at(p)))
                    filled.append(buffer.read({p, buffer.next(p)}));
                else
                    filled.append(replacement);
            }
            Replace(state, buffer, *range, filled);
        }
    }
    if (!visual)
        start += newline ? replacement.size() : (Count(state) - 1) * replacement.size();
    state.cursor = NormalPosition(buffer, start);
}

static int NumberDigit(char16_t ch)
{
    if (Digit(ch))
        return ch - '0';
    if (Lowercase(ch) >= 'a' && Lowercase(ch) <= 'f')
        return Lowercase(ch) - 'a' + 10;
    return 36;
}

static std::optional<Edit> NumberEdit(const Buffer &buffer, Range range, Offset cursor, bool increment, uint64_t amount)
{
    Offset first = range.first;
    while (first < range.last) {
        if (!Digit(buffer.at(first))) {
            ++first;
            continue;
        }
        bool negative = first > range.first && buffer.at(first - 1) == '-';
        int base = 10;
        Offset digits = first;
        char16_t prefix = buffer.at(first + 1);
        if (buffer.at(first) == '0' && first + 2 < range.last) {
            if (Lowercase(prefix) == 'x' && NumberDigit(buffer.at(first + 2)) < 16)
                base = 16;
            else if (Lowercase(prefix) == 'b' && NumberDigit(buffer.at(first + 2)) < 2)
                base = 2;
        }
        if (base != 10)
            digits += 2;
        Offset end = digits;
        uint64_t number = 0;
        bool upper = false;
        while (end < range.last && NumberDigit(buffer.at(end)) < base) {
            upper |= Upper(buffer.at(end));
            number = number * base + NumberDigit(buffer.at(end++));
        }
        if (end <= cursor) {
            first = end;
            continue;
        }
        bool hadSign = negative;
        if (base == 10 && (negative == increment) && amount > number) {
            number = amount - number;
            negative = !negative;
        } else if (negative == increment) {
            number -= amount;
        } else {
            number += amount;
        }
        if (base == 10 && !number)
            negative = false;
        char result[64];
        auto converted = std::to_chars(std::begin(result), std::end(result), number, base);
        if (converted.ec != std::errc{})
            return {};
        std::u16string text;
        Offset old = base != 10 ? first : first - hadSign;
        if (negative && base == 10)
            text.push_back('-');
        if (base != 10) {
            text.push_back('0');
            text.push_back(prefix);
        }
        auto width = Offset(converted.ptr - result);
        if (buffer.at(digits) == '0' && end - digits > width)
            text.append(end - digits - width, '0');
        for (char *ch = result; ch < converted.ptr; ++ch)
            text.push_back(upper && Lower(*ch) ? *ch - 32 : *ch);
        return Edit{old, buffer.read({old, end}), std::move(text)};
    }
    return {};
}

static void ChangeNumber(State &state, Buffer &buffer, bool increment, bool progressive = false)
{
    unsigned count = Count(state);
    if (!IsVisual(state.mode)) {
        Line line = buffer.line(buffer.row(state.cursor));
        if (auto edit = NumberEdit(buffer, {line.first, line.end}, state.cursor, increment, count)) {
            Replace(state, buffer, {edit->at, edit->at + edit->before.size()}, edit->after);
            state.cursor = edit->at + edit->after.size() - 1;
        }
        return;
    }
    auto selected = Selected(state, buffer);
    std::vector<Edit> edits;
    for (Offset row = selected.top; row <= selected.bottom; ++row) {
        Line line = buffer.line(row);
        Range part = selected.ranges[selected.kind == Kind::Block ? row - selected.top : 0];
        Range range{std::max(part.first, line.first), std::min(part.last, line.end)};
        uint64_t amount = uint64_t(count) * (progressive ? edits.size() + 1 : 1);
        if (range.first < range.last) {
            if (auto edit = NumberEdit(buffer, range, range.first, increment, amount))
                edits.push_back(std::move(*edit));
        }
    }
    RememberVisual(state, buffer, selected);
    LeaveVisual(state);
    for (auto edit = edits.rbegin(); edit != edits.rend(); ++edit)
        Replace(state, buffer, {edit->at, edit->at + edit->before.size()}, edit->after);
    state.cursor = NormalPosition(buffer, selected.ranges.front().first);
}

static void FileUnderCursor(const State &state, const Buffer &buffer)
{
    auto pathChar = [](char16_t ch) {
        return Lower(ch) || Upper(ch) || Digit(ch) || Text(u"./~_-+@").find(ch) != Text::npos;
    };
    Line line = buffer.line(buffer.row(state.cursor));
    Offset start = state.cursor;
    Offset end = start;
    while (start > line.first && pathChar(buffer.at(start - 1)))
        --start;
    while (end < line.end && pathChar(buffer.at(end)))
        ++end;
    if (start < end)
        DispatchAction(buffer, Action::Open, buffer.read({start, end}));
}

static void Play(State &state, Buffer &buffer, Registers &registers, const std::vector<Input> &inputs, unsigned count)
{
    if (++state.executionDepth < 32) {
        for (unsigned i = 0; i < count && state.executionBudget; ++i) {
            for (const auto &input : inputs) {
                if (!state.executionBudget)
                    break;
                FeedInput(state, buffer, registers, input.key, input.text, input.smart);
            }
        }
    } else {
        state.message = u"Macro recursion limit reached";
        state.executionBudget = 0;
    }
    --state.executionDepth;
}

static void PlayMacro(State &state, Buffer &buffer, Registers &registers, char32_t name, unsigned count)
{
    if (name == '@')
        name = state.lastMacro;
    if (!name || !RegisterName(name))
        return;
    auto value = ReadRegister(state, buffer.host, registers, name);
    if (!value)
        return;
    state.lastMacro = name;
    if (name == ':') {
        for (; count && state.executionBudget && state.mode == Mode::Normal; --count) {
            --state.executionBudget;
            ExecuteEx(state, buffer, registers, value->text);
        }
        return;
    }
    state.inputs.clear();
    if (!value->keys.empty()) {
        Play(state, buffer, registers, value->keys, count);
    } else {
        std::vector<Input> inputs;
        for (Offset i = 0; i < value->text.size(); ++i) {
            char32_t ch = value->text[i];
            if (ch >= 0xd800 && ch <= 0xdbff && i + 1 < value->text.size() &&
                value->text[i + 1] >= 0xdc00 && value->text[i + 1] <= 0xdfff) {
                ch = 0x10000 + ((ch - 0xd800) << 10) + value->text[++i] - 0xdc00;
            }
            inputs.push_back({Key(ch), {}});
        }
        Play(state, buffer, registers, inputs, count);
    }
}

static void StopRecording(State &state, Registers &registers)
{
    Register value;
    for (const Input &input : state.macro)
        value.text.append(KeyText(input.key, input.text));
    value.keys = std::move(state.macro);
    SetRegister(registers, state.recording, std::move(value));
    state.recording = 0;
}

static void RepeatChange(State &state, Buffer &buffer, Registers &registers, unsigned overrideCount)
{
    if (state.repeat.inputs.empty())
        return;
    auto inputs = state.repeat.inputs;
    if (state.repeat.occurrences) {
        LeaveVisual(state);
        AddOccurrences(state, buffer, overrideCount ? overrideCount : unsigned(state.repeat.occurrences));
        if (state.occurrences.empty())
            return;
    } else if (IsVisual(state.repeat.visualMode)) {
        LeaveVisual(state);
        state.anchor = state.cursor;
        state.mode = state.repeat.visualMode;
        Offset row = buffer.row(state.cursor);
        Offset target = std::min(buffer.rows - 1, row + state.repeat.rows - 1);
        Offset column = state.repeat.columns ? state.repeat.columns - 1 : 0;
        if (state.mode == Mode::VisualBlock || target == row)
            column += ColumnAt(buffer, state.cursor, state.tabStop);
        state.cursor = NormalPosition(buffer, AtColumn(buffer, buffer.line(target), column, state.tabStop));
        state.goalColumn = NoOffset;
        state.goalEnd = state.repeat.toEnd;
    } else if (overrideCount) {
        Offset at = 0;
        bool registerPrefix = false;
        while (at < inputs.size()) {
            char32_t key = char32_t(inputs[at].key);
            if (key == '"') {
                at = std::min(at + 2, inputs.size());
                registerPrefix = true;
            } else if (Digit(key) && key != '0') {
                Offset end = at + 1;
                while (end < inputs.size() && Digit(char32_t(inputs[end].key)))
                    ++end;
                inputs.erase(inputs.begin() + at, inputs.begin() + end);
            } else {
                break;
            }
        }
        std::vector<Input> count;
        for (char16_t value : Decimal(overrideCount))
            count.push_back({Key(value), {}});
        inputs.insert(inputs.begin() + (registerPrefix ? at : 0), count.begin(), count.end());
    }
    state.replaying = true;
    state.inputs.clear();
    Play(state, buffer, registers, inputs, 1);
    state.replaying = false;
}

static void GCommand(State &state, Buffer &buffer, Registers &registers, char32_t key)
{
    unsigned count = Count(state);
    Offset row = buffer.row(state.cursor);
    switch (key) {
        case 'g':
            Move(state, buffer, registers, {FirstNonblank(buffer, buffer.line(std::min<Offset>(buffer.rows, count) - 1)),
                                            Kind::Line, false, true});
            return;
        case 'e': case 'E': {
            Offset position = state.cursor;
            while (count-- && position)
                position = BackwardEnd(buffer, position, Upper(key));
            Move(state, buffer, registers, {position, Kind::Character, true});
            return;
        }
        case 'j': case 'k':
            Move(state, buffer, registers, Vertical(state, buffer, key == 'j', count));
            return;
        case '_': {
            Line line = buffer.line(std::min(buffer.rows - 1, row + count - 1));
            Offset end = line.end;
            while (end > line.first && Blank(buffer.at(buffer.prev(end))))
                end = buffer.prev(end);
            Move(state, buffer, registers, {end > line.first ? buffer.prev(end) : end, Kind::Character, true});
            return;
        }
        case '0': case '^': case '$':
            Move(state, buffer, registers, ReadMotion(state, buffer, Key(key), count, false));
            return;
        case 'u': case 'U': case '~':
            StartOperator(state, buffer, registers, Operator(key));
            return;
        case 'c': case 'C':
            StartOperator(state, buffer, registers, key == 'c' ? Op::Comment : Op::BlockComment);
            return;
        case 'v':
            if (state.lastVisual != Mode::Normal) {
                Mode previous = state.lastVisual;
                Offset anchor = state.lastAnchor;
                Offset cursor = state.lastVisualCursor;
                Offset column = state.lastVisualColumn;
                bool toEnd = state.lastVisualToEnd;
                LeaveVisual(state);
                state.mode = previous;
                state.anchor = NormalPosition(buffer, anchor);
                state.cursor = NormalPosition(buffer, cursor);
                state.goalColumn = column;
                state.goalEnd = toEnd;
            }
            break;
        case 'i':
            if (state.lastInsert != NoOffset) {
                SaveJump(state, buffer);
                StartInsert(state, std::min(state.lastInsert, buffer.length), Mode::Insert, count);
            }
            break;
        case 'I':
            if (state.mode == Mode::Normal && state.op == Op::None)
                StartInsert(state, buffer.line(row).first, Mode::Insert, count);
            break;
        case 'n': case 'N':
            if (auto match = SearchObject(state, buffer, key == 'N', count)) {
                auto range = match->range;
                if (state.op != Op::None) {
                    ApplyOperator(state, buffer, registers, state.op, Characters(buffer, range));
                } else {
                    if (!IsVisual(state.mode))
                        state.anchor = key == 'n' ? range.first : buffer.prev(range.last);
                    state.mode = Mode::Visual;
                    state.cursor = key == 'n' ? buffer.prev(range.last) : range.first;
                    state.goalColumn = NoOffset;
                    state.goalEnd = false;
                }
            } else {
                state.message = state.lastSearch.empty() ? u"No previous search" : u"Pattern not found";
            }
            break;
        case 1: case 24:
            if (IsVisual(state.mode))
                ChangeNumber(state, buffer, key == 1, true);
            break;
        case 'p': case 'P':
            Put(state, buffer, registers, key == 'p', true, count);
            break;
        case 'J':
            JoinAtCursor(state, buffer, row, count, false);
            break;
        case ';': case ',':
            if (!state.changes.empty()) {
                if (key == ';')
                    state.changeIndex -= std::min<Offset>(state.changeIndex, count);
                else
                    state.changeIndex = std::min(state.changes.size() - 1, state.changeIndex + count);
                state.cursor = NormalPosition(buffer, state.changes[state.changeIndex]);
            }
            break;
        case '*': case '#':
            WordSearch(state, buffer, registers, key == '#', false);
            return;
        case 'f':
            FileUnderCursor(state, buffer);
            break;
        case 'd':
            if (state.op == Op::None && buffer.host.definition) {
                Offset position = buffer.host.definition(buffer.host.context, state.cursor);
                if (position == NoOffset)
                    state.message = u"Definition not found";
                else
                    Move(state, buffer, registers, {position, Kind::Character, false, true});
            }
            break;
        case 'b':
            if (state.op == Op::None)
                AddOccurrences(state, buffer, count);
            break;
        case 't': case 'T':
            DispatchAction(buffer, key == 't' ? Action::NextWindow : Action::PreviousWindow);
            break;
        case '&':
            Substitute(state, buffer, 0, buffer.rows - 1, u"g");
            break;
    }
    ClearCommand(state);
}

static void PrefixKey(State &state, Buffer &buffer, Registers &registers, Key key, Text text)
{
    Prefix prefix = std::exchange(state.prefix, Prefix::None);
    char32_t ch = char32_t(key);
    unsigned count = Count(state);
    if (key == Key::Escape || key == Key(3)) {
        ClearCommand(state);
        return;
    }
    switch (prefix) {
        case Prefix::G:
            GCommand(state, buffer, registers, ch);
            return;
        case Prefix::Z:
            if (Text(u"ztb.-\r").find(char16_t(ch)) != Text::npos)
                Scroll(state, buffer, ch, count);
            else if (buffer.host.fold && Text(u"acoACOMRv").find(char16_t(ch)) != Text::npos) {
                state.cursor = NormalPosition(buffer, buffer.host.fold(buffer.host.context, ch, state.cursor));
                state.goalColumn = NoOffset;
            }
            break;
        case Prefix::Find: {
            auto needle = KeyText(key, text);
            Motion motion = FindCharacter(state, buffer, state.findCommand, needle, count, false);
            state.lastFindCommand = state.findCommand;
            state.lastFind = std::move(needle);
            Move(state, buffer, registers, motion);
            return;
        }
        case Prefix::Inner: case Prefix::Around:
            SelectObject(state, buffer, registers, ch, prefix == Prefix::Around);
            return;
        case Prefix::SurroundTarget:
            SurroundTarget(state, buffer, ch, count);
            break;
        case Prefix::Register:
            if (RegisterName(ch)) {
                state.selectedRegister = ch;
                return;
            }
            break;
        case Prefix::SetMark:
            if (Lower(ch))
                state.marks[ch - 'a'] = state.cursor;
            else if (Upper(ch)) {
                state.marks[26 + ch - 'A'] = state.cursor;
                if (buffer.host.setFileMark)
                    buffer.host.setFileMark(buffer.host.context, ch, state.cursor);
            }
            break;
        case Prefix::MarkLine: case Prefix::MarkExact: {
            Offset position = Upper(ch) && buffer.host.fileMark ? buffer.host.fileMark(buffer.host.context, ch) :
                              Mark(state, ch);
            if (position == NoOffset && Upper(ch) && state.op == Op::None && !IsVisual(state.mode)) {
                char16_t mark = char16_t(ch);
                DispatchAction(buffer, Action::JumpFileMark, Text(&mark, 1), prefix == Prefix::MarkExact);
                break;
            }
            if (position != NoOffset) {
                Motion motion{position, Kind::Character, false, true};
                if (prefix == Prefix::MarkLine) {
                    motion.to = FirstNonblank(buffer, buffer.line(buffer.row(position)));
                    motion.kind = Kind::Line;
                }
                Move(state, buffer, registers, motion);
            }
            break;
        }
        case Prefix::Record:
            if (Upper(ch) || Lower(ch) || Digit(ch)) {
                state.recording = ch;
                state.macro.clear();
            }
            break;
        case Prefix::Play:
            ClearCommand(state);
            PlayMacro(state, buffer, registers, ch, count);
            return;
        case Prefix::Replace:
            ReplaceCharacters(state, buffer, key, text);
            break;
        case Prefix::Window: {
            if (ch >= 1 && ch <= 26)
                ch += 'a' - 1;
            else if (key == Key::Left || key == Key::Right || key == Key::Up || key == Key::Down)
                ch = key == Key::Left ? 'h' : key == Key::Right ? 'l' : key == Key::Up ? 'k' : 'j';
            constexpr Text commands = u"wWlhjkpqcovs";
            if (commands.find(char16_t(ch)) != Text::npos) {
                char16_t command = char16_t(ch);
                DispatchAction(buffer, Action::WindowCommand, Text(&command, 1));
            }
            break;
        }
        default:
            break;
    }
    ClearCommand(state);
}

static void NormalKey(State &state, Buffer &buffer, Registers &registers, Key key, Text text)
{
    char32_t ch = char32_t(key);
    if (key == Key::Text && text.size() == 1)
        ch = text[0];
    if (!state.surrounds.empty()) {
        SurroundKey(state, buffer, Key(ch), text);
        return;
    }
    if (state.prefix != Prefix::None) {
        PrefixKey(state, buffer, registers, Key(ch), text);
        return;
    }
    if (Digit(ch) && (state.count || ch != '0')) {
        state.count = std::min(maxCount, state.count * 10 + unsigned(ch - '0'));
        return;
    }

    unsigned count = Count(state);
    bool visual = IsVisual(state.mode);
    bool operated = state.op != Op::None;
    if ((state.op == Op::Comment && ch == 'c') || (state.op == Op::BlockComment && ch == 'C') ||
        (state.op == Op::Surround && ch == 's')) {
        StartOperator(state, buffer, registers, state.op);
        return;
    }
    if (ch == 's' && (state.op == Op::Yank || state.op == Op::Change || state.op == Op::Delete)) {
        if (state.op == Op::Yank)
            state.op = Op::Surround;
        else
            state.prefix = Prefix::SurroundTarget;
        return;
    }
    if (visual && ch == 'S') {
        ApplyOperator(state, buffer, registers, Op::Surround, Selected(state, buffer));
        ClearCommand(state);
        return;
    }
    Offset row = buffer.row(state.cursor);
    Line line = buffer.line(row);
    switch (ch) {
        case 3: case char32_t(Key::Escape):
            LeaveVisual(state);
            break;
        case 'g': state.prefix = Prefix::G; return;
        case 'z': state.prefix = Prefix::Z; return;
        case '"': state.prefix = Prefix::Register; return;
        case 'f': case 'F': case 't': case 'T':
            state.prefix = Prefix::Find;
            state.findCommand = ch;
            return;
        case 'm': state.prefix = Prefix::SetMark; return;
        case '\'': state.prefix = Prefix::MarkLine; return;
        case 0x60: state.prefix = Prefix::MarkExact; return;
        case 23: state.prefix = Prefix::Window; return;
        case ';': case ',': {
            char32_t command = state.lastFindCommand;
            if (command && ch == ',')
                command = Upper(command) ? Lowercase(command) : command - ('a' - 'A');
            Move(state, buffer, registers, FindCharacter(state, buffer, command, state.lastFind, count, true));
            return;
        }
        case 'y': case 'c': case 'd': case '>': case '<': case '=':
            StartOperator(state, buffer, registers, Operator(ch));
            return;
        case ':': case '/': case '?':
            StartCommand(state, ch);
            return;
        case 'n': case 'N':
            SearchMotion(state, buffer, registers, state.searchBackwards != (ch == 'N'), count);
            return;
        case '*': case '#':
            WordSearch(state, buffer, registers, ch == '#', true);
            return;
        case 'v': case 'V': case 22: {
            Mode mode = ch == 'v' ? Mode::Visual : ch == 'V' ? Mode::VisualLine : Mode::VisualBlock;
            if (operated) {
                state.forceMotion = true;
                state.forcedKind = ch == 'v' ? Kind::Character : ch == 'V' ? Kind::Line : Kind::Block;
            } else {
                StartVisual(state, buffer, mode, count);
            }
            return;
        }
        case 'a': case 'i':
            if (operated || visual) {
                state.prefix = ch == 'i' ? Prefix::Inner : Prefix::Around;
            } else {
                StartInsert(state, ch == 'a' ? CellEnd(buffer, state.cursor) : state.cursor, Mode::Insert, count);
                ClearCommand(state);
            }
            return;
        case 'I': case 'A': {
            Offset position = ch == 'A' ? line.end : FirstNonblank(buffer, line);
            if (visual) {
                auto selected = Selected(state, buffer);
                RememberVisual(state, buffer, selected);
                LeaveVisual(state);
                if (selected.disjoint) {
                    StartInsert(state, ch == 'A' ? selected.ranges.front().last : selected.ranges.front().first,
                                Mode::Insert);
                    for (Offset i = 1; i < selected.ranges.size(); ++i)
                        state.insertMirrors.push_back(ch == 'A' ? selected.ranges[i].last : selected.ranges[i].first);
                    break;
                }
                if (selected.kind == Kind::Block || selected.kind == Kind::Line) {
                    StartBlockInsert(state, buffer, selected, ch == 'A');
                    break;
                }
                position = ch == 'A' ? selected.ranges.front().last : selected.ranges.front().first;
            }
            if (!operated)
                StartInsert(state, position, Mode::Insert, count);
            break;
        }
        case 'o': case 'O':
            if (visual) {
                if (ch == 'O' && state.mode == Mode::VisualBlock) {
                    Offset left = ColumnAt(buffer, state.anchor, state.tabStop);
                    Offset right = ColumnAt(buffer, state.cursor, state.tabStop);
                    state.anchor = NormalPosition(buffer, AtColumn(buffer, buffer.line(buffer.row(state.anchor)), right,
                                                                  state.tabStop));
                    state.cursor = NormalPosition(buffer, AtColumn(buffer, line, left, state.tabStop));
                } else {
                    std::swap(state.cursor, state.anchor);
                }
                state.goalColumn = NoOffset;
            } else if (!operated) {
                OpenLine(state, buffer, ch == 'o', count);
            }
            break;
        case 'r':
            state.prefix = Prefix::Replace;
            return;
        case 'R':
            if (visual) {
                auto selected = Selected(state, buffer);
                ApplyOperator(state, buffer, registers, Op::Change, std::move(selected));
            } else if (!operated) {
                StartInsert(state, state.cursor, Mode::Replace, count);
            }
            break;
        case 'x': case 'X': case 's': case char32_t(Key::Delete):
        case 'D': case 'C': case 'S': case 'Y': {
            if (operated)
                break;
            Op op = ch == 'Y' ? Op::Yank : (ch == 'c' || ch == 'C' || ch == 's' || ch == 'S') ? Op::Change : Op::Delete;
            Selection selected;
            if (visual) {
                selected = Selected(state, buffer);
                if (ch == 'S' || (selected.kind != Kind::Block && (ch == 'Y' || ch == 'D' || ch == 'C'))) {
                    selected = LineSelection(buffer, selected.top, selected.bottom);
                } else if (selected.kind == Kind::Block && (ch == 'Y' || ch == 'D' || ch == 'C')) {
                    for (Offset i = 0; i < selected.ranges.size(); ++i) {
                        selected.ranges[i].last = buffer.line(selected.top + i).end;
                        selected.right = std::max(selected.right, ColumnAt(buffer, selected.ranges[i].last, state.tabStop));
                    }
                }
            } else if (ch == 'S' || ch == 'Y') {
                selected = LineSelection(buffer, row, std::min(buffer.rows - 1, row + count - 1));
            } else {
                Offset end = state.cursor;
                if (ch == 'D' || ch == 'C') {
                    end = buffer.line(std::min(buffer.rows - 1, row + count - 1)).end;
                } else if (ch == 'X') {
                    for (; count && end > line.first; --count)
                        end = buffer.prev(end);
                } else {
                    for (; count && end < line.end; --count)
                        end = buffer.next(end);
                }
                selected = Characters(buffer, Ordered(state.cursor, end));
            }
            ApplyOperator(state, buffer, registers, op, std::move(selected));
            break;
        }
        case 'p': case 'P':
            if (!operated)
                Put(state, buffer, registers, ch == 'p', false, count);
            break;
        case 'J':
            JoinAtCursor(state, buffer, row, count, true);
            break;
        case '~': case 'U': case 'u':
            if (visual) {
                StartOperator(state, buffer, registers, Operator(ch));
                return;
            }
            if (operated && state.op == Operator(ch)) {
                StartOperator(state, buffer, registers, state.op);
                return;
            }
            if (ch == '~') {
                Offset end = state.cursor;
                for (; count && end < line.end; --count)
                    end = buffer.next(end);
                ChangeCase(state, buffer, {state.cursor, end}, Op::Toggle);
                state.cursor = NormalPosition(buffer, end);
            } else if (ch == 'U') {
                UndoLine(state, buffer);
            } else if (ch == 'u') {
                Undo(state, buffer, false, count);
            }
            break;
        case 18:
            LeaveVisual(state);
            Undo(state, buffer, true, count);
            break;
        case 15: case 9:
            ListJump(state, buffer, ch == 9, count);
            break;
        case 4: case 21: case 5: case 25: case 6: case 2:
        case char32_t(Key::PageUp): case char32_t(Key::PageDown):
            if (!operated)
                Scroll(state, buffer, ch, count);
            break;
        case 1: case 24:
            if (!operated)
                ChangeNumber(state, buffer, ch == 1);
            break;
        case 'q':
            if (!operated && !visual)
                state.prefix = Prefix::Record;
            return;
        case '@':
            if (!operated)
                state.prefix = Prefix::Play;
            return;
        case '.': {
            unsigned overrideCount = state.count;
            ClearCommand(state);
            if (!state.replaying)
                RepeatChange(state, buffer, registers, overrideCount);
            return;
        }
        default: {
            Motion motion = ReadMotion(state, buffer, Key(ch), count, state.count || state.operatorCount > 1);
            Move(state, buffer, registers, motion);
            return;
        }
    }
    ClearCommand(state);
}

static bool Waiting(const State &state)
{
    return state.prefix != Prefix::None || state.op != Op::None || state.selectedRegister ||
           !state.surrounds.empty() || state.count || state.mode == Mode::Command ||
           state.mode == Mode::Confirm || IsInsert(state.mode);
}

static void FeedInput(State &state, Buffer &buffer, Registers &registers, Key key, Text text, bool smart)
{
    if (!state.executionBudget)
        return;
    --state.executionBudget;
    bool stopRecording = state.recording && !state.executionDepth && key == Key('q') &&
                         state.mode == Mode::Normal && !Waiting(state);
    if (stopRecording) {
        StopRecording(state, registers);
        return;
    }

    Mode mode = state.mode;
    Offset at = state.cursor;
    bool before = std::exchange(state.beforeInlay, false);
    bool normal = mode == Mode::Normal && state.op == Op::None && !state.count;
    bool insert = mode == Mode::Insert && state.insertMirrors.empty() && state.blockTop == state.blockBottom;
    bool right = key == Key::Right || (normal && key == Key('l'));
    bool left = key == Key::Left || (normal && key == Key('h'));
    bool inlayMotion = (left || right) && (normal || insert) && buffer.host.inlayAt &&
                       state.prefix == Prefix::None && state.surrounds.empty() &&
                       !state.recording && !state.replaying && !state.executionDepth;
    // A hint edge is a display stop, so it never enters the Vim command history.
    if (inlayMotion && before == right && buffer.host.inlayAt(buffer.host.document, at)) {
        state.beforeInlay = !right;
        state.goalColumn = NoOffset;
        return;
    }

    bool append = normal && state.prefix == Prefix::None && (key == Key('a') || key == Key('A'));
    if (append && before && key == Key('a') && buffer.host.inlayAt && buffer.host.inlayAt(buffer.host.document, at))
        key = Key('i');
    if (state.recording && !state.executionDepth)
        state.macro.push_back({key, std::u16string(text), smart});
    bool insertCommand = state.mode == Mode::Normal && state.returnToInsert != Mode::Normal;
    if (state.inputs.empty())
        state.commandStart = state.cursor;
    state.inputs.push_back({key, std::u16string(text), smart});

    if (IsInsert(state.mode))
        InsertKey(state, buffer, registers, key, text, smart);
    else if (state.mode == Mode::Command)
        CommandKey(state, buffer, registers, key, text);
    else if (state.mode == Mode::Confirm)
        ConfirmSubstitute(state, buffer, key);
    else
        NormalKey(state, buffer, registers, key, text);

    if (!Waiting(state)) {
        if (state.returnToInsert != Mode::Normal) {
            if (insertCommand)
                state.mode = std::exchange(state.returnToInsert, Mode::Normal);
        } else {
            if (state.mode == Mode::Normal)
                state.cursor = NormalPosition(buffer, state.cursor);
            FinishChange(state);
            state.inputs.clear();
            state.visualRepeat = {};
        }
    } else if (state.change) {
        state.change->after = state.cursor;
    }
    if (inlayMotion && state.mode == mode && (right ? state.cursor != at : before && state.cursor == at))
        state.beforeInlay = buffer.host.inlayAt(buffer.host.document, state.cursor);
    if (normal && state.mode == Mode::Insert && (append || (before && key == Key('i'))))
        state.beforeInlay = true;
}

static unsigned CurrentMappingMode(const State &state)
{
    if (state.prefix != Prefix::None || !state.surrounds.empty() || state.mode == Mode::Confirm)
        return 0;
    if (state.mode == Mode::Command)
        return MapCommand;
    if (IsInsert(state.mode))
        return MapInsert;
    if (state.op != Op::None)
        return MapOperator;
    return IsVisual(state.mode) ? MapVisual : MapNormal;
}

static void FeedMapped(State &state, Buffer &buffer, Registers &registers, Input input, bool flush)
{
    if (!flush)
        state.mappingKeys.push_back(std::move(input));
    while (!state.mappingKeys.empty() && state.executionBudget) {
        unsigned mode = CurrentMappingMode(state);
        const Mapping *best = nullptr;
        bool incomplete = false;
        for (const auto &map : registers.mappings) {
            if (!(map.modes & mode))
                continue;
            Offset length = std::min(map.from.size(), state.mappingKeys.size());
            if (!std::equal(map.from.begin(), map.from.begin() + length, state.mappingKeys.begin(), SameKey))
                continue;
            if (length < map.from.size())
                incomplete = true;
            else if (!best || map.from.size() > best->from.size())
                best = &map;
        }
        if (incomplete && !flush)
            return;
        if (!best) {
            Input original = std::move(state.mappingKeys.front());
            state.mappingKeys.erase(state.mappingKeys.begin());
            FeedInput(state, buffer, registers, original.key, original.text, original.smart);
            continue;
        }
        Mapping chosen = *best;
        auto remaining = std::move(state.mappingKeys);
        state.mappingKeys.clear();
        --state.executionBudget;
        if (!chosen.recursive) {
            Play(state, buffer, registers, chosen.to, 1);
        } else {
            if (++state.executionDepth < 32) {
                for (const auto &mapped : chosen.to)
                    FeedMapped(state, buffer, registers, mapped);
                FeedMapped(state, buffer, registers, {Key::None, {}}, true);
            } else {
                state.executionBudget = 0;
                state.message = u"Mapping recursion limit reached";
            }
            --state.executionDepth;
        }
        for (Offset i = chosen.from.size(); i < remaining.size(); ++i)
            state.mappingKeys.push_back(std::move(remaining[i]));
    }
    if (!state.executionBudget)
        state.mappingKeys.clear();
}

void Feed(State &state, const Host &host, Registers &registers, Key key, Text text, bool smart)
{
    state.message.clear();
    state.executionBudget = maxPlayback;
    Buffer buffer(host, state.finalNewline);
    if (!state.finalNewline) {
        state.finalNewline = buffer.endsWithNewline();
        buffer.finalNewline = state.finalNewline;
    }
    if (registers.mappings.empty() && state.mappingKeys.empty())
        FeedInput(state, buffer, registers, key, text, smart);
    else
        FeedMapped(state, buffer, registers, {key, std::u16string(text), smart});
}

void FlushMappings(State &state, const Host &host, Registers &registers)
{
    if (state.mappingKeys.empty())
        return;
    state.executionBudget = maxPlayback;
    Buffer buffer(host, state.finalNewline);
    FeedMapped(state, buffer, registers, {Key::None, {}}, true);
}

void MouseSelection(State &state, const Host &host, Range range, bool backwards)
{
    Buffer buffer(host, state.finalNewline);
    if (!state.finalNewline)
        state.finalNewline = buffer.endsWithNewline();
    Offset first = std::min(range.first, buffer.length);
    Offset last = std::min(range.last, buffer.length);
    state.beforeInlay = false;
    state.goalEnd = false;
    if (IsInsert(state.mode) && first == last) {
        state.simpleInsert = false;
        state.cursor = first;
        state.goalColumn = NoOffset;
        return;
    }
    FinishChange(state);
    LeaveVisual(state);
    state.mode = first == last ? Mode::Normal : Mode::Visual;
    // A Visual endpoint can sit on a line break. Only a collapsed caret needs
    // Normal-mode positioning.
    state.anchor = first == last ? NormalPosition(buffer, first) : first;
    state.cursor = first == last ? state.anchor : buffer.prev(last);
    if (backwards)
        std::swap(state.anchor, state.cursor);
    state.returnToInsert = Mode::Normal;
    state.goalColumn = NoOffset;
    state.searchPreview = NoOffset;
    state.surrounds.clear();
    state.surroundingTag = false;
    state.surroundTag.clear();
    state.insertMirrors.clear();
    state.message.clear();
    state.inputs.clear();
    state.mappingKeys.clear();
    ClearCommand(state);
}

void SelectAll(State &state, const Host &host)
{
    MouseSelection(state, host, {0, host.length(host.document)});
}

void CopySelection(State &state, const Host &host, Registers &registers, bool cut)
{
    // Menu actions operate on the selection even if a Vim prefix is pending.
    ClearCommand(state);
    state.inputs.clear();
    Feed(state, host, registers, Key('"'));
    Feed(state, host, registers, Key('+'));
    Feed(state, host, registers, Key(cut ? 'd' : 'y'));
}

std::u16string Status(const State &state)
{
    if (state.mode == Mode::Command)
        return std::u16string(1, char16_t(state.prompt)) + state.command;
    if (state.mode == Mode::Confirm)
        return u"Replace? (y/n/a/q/l)";
    if (!state.message.empty())
        return state.message;
    Text name;
    switch (state.mode) {
        case Mode::Normal: name = u"Normal"; break;
        case Mode::Insert: name = u"Insert"; break;
        case Mode::Replace: name = u"Replace"; break;
        case Mode::Visual: name = u"Visual"; break;
        case Mode::VisualLine: name = u"Visual Line"; break;
        case Mode::VisualBlock: name = u"Visual Block"; break;
        default: break;
    }
    std::u16string status(name);
    if (state.recording) {
        status.append(u"  recording @");
        status.push_back(char16_t(state.recording));
    }
    if (state.op != Op::None || state.prefix != Prefix::None || state.count || state.selectedRegister ||
        !state.surrounds.empty()) {
        status.append(u"  ");
        for (const auto &input : state.inputs) {
            char32_t value = char32_t(input.key);
            if (value >= 32 && value <= 126)
                status.push_back(char16_t(value));
        }
    }
    return status;
}

} // namespace Vim