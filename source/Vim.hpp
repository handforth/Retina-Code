#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace Vim {

using Offset = std::size_t;
using Text = std::u16string_view;
inline constexpr Offset NoOffset = std::numeric_limits<Offset>::max();

struct Range {
    Offset first = 0;
    Offset last = 0;

    Offset size() const { return last - first; }
    bool empty() const { return first == last; }
    bool operator==(const Range &) const = default;
};

enum class Key : uint32_t {
    None = 0,
    Backspace = 8, Tab = 9, Enter = 13, Escape = 27,
    Text = 0x110000, Paste, Left, Right, Up, Down, Home, End, PageUp, PageDown, Delete,
    WordLeft, WordRight, Backtab, DocumentStart, DocumentEnd,
};

enum class Mode { Normal, Insert, Replace, Visual, VisualLine, VisualBlock, Command, Confirm };
enum class Kind { Character, Line, Block };
enum class Op {
    None, Yank, Delete, Change, ShiftLeft, ShiftRight, Indent, Lower, Upper, Toggle,
    Comment, BlockComment, Surround,
};
enum class Prefix {
    None, G, Z, Find, Inner, Around, Register, SetMark, MarkLine, MarkExact, Record, Play,
    Replace, InsertRegister, InsertControl, CommandRegister, CommandLiteral, Window, SurroundTarget,
};
enum class Action {
    Save, WriteCopy, SaveAs, SaveClose, Close, Open, Revert, NextWindow, PreviousWindow,
    JumpFileMark, SourceMappings, SplitBelow, SplitRight, WindowCommand,
};
enum class RowInsert { Column, FirstNonblank, End };

struct Input {
    Key key;
    std::u16string text;
    bool smart = false;
};

struct Register {
    std::u16string text;
    Kind kind = Kind::Character;
    Offset width = 0;
    std::vector<Input> keys;
    std::vector<std::shared_ptr<const Register>> cursors;
};

struct Mapping {
    unsigned modes;
    bool recursive;
    std::vector<Input> from;
    std::vector<Input> to;
};

struct Registers {
    std::array<std::shared_ptr<const Register>, 128> slots;
    std::vector<Mapping> mappings;
    Key leader = Key('\\');
};

struct Edit {
    Offset at;
    std::u16string before;
    std::u16string after;
};

struct LineUndo {
    Offset start;
    Offset column;
    std::u16string text;
};

struct Change {
    Offset before;
    Offset after;
    std::vector<Edit> edits;
    std::shared_ptr<const LineUndo> beforeLine;
    std::shared_ptr<const LineUndo> afterLine;
};

struct Match {
    Range range;
    std::vector<Range> groups;
};

struct InsertEdit {
    Range range;
    std::u16string text;
    Offset cursor;
};

struct Comments {
    Text line;
    Text open;
    Text close;
};

struct Surround {
    Range left;
    Range right;
};

struct Host {
    void *context;
    Offset (*length)(void *);
    Offset (*lineCount)(void *);
    Offset (*lineAt)(void *, Offset);
    Offset (*lineStart)(void *, Offset);
    void (*read)(void *, Range, char16_t *);
    Range (*cluster)(void *, Offset);
    bool (*structural)(void *, Offset);
    void (*replace)(void *, Range, Text);
    void (*recordUndo)(void *, std::shared_ptr<Change>);
    std::optional<Offset> (*undo)(void *, bool);
    void (*flash)(void *, const std::vector<Range> &, Kind);
    std::optional<Register> (*readClipboard)(void *);
    void (*writeClipboard)(void *, Text);
    std::optional<Match> (*find)(void *, Text, Range, bool backwards, bool ignoreCase, bool captures);
    Range (*viewport)(void *);
    void (*scroll)(void *, Offset topRow);
    void (*action)(void *, Action, Text, bool force);
    std::optional<InsertEdit> (*planInsert)(void *, Key, Offset, unsigned, unsigned, bool, bool) = nullptr;
    void (*finishInsertEdit)(void *) = nullptr;
    std::u16string (*indentAfter)(void *, Offset, unsigned, unsigned, bool) = nullptr;
    std::u16string (*fileName)(void *) = nullptr;
    Offset (*fileMark)(void *, char32_t) = nullptr;
    void (*setFileMark)(void *, char32_t, Offset) = nullptr;
    Comments (*comments)(void *) = nullptr;
    Offset (*definition)(void *, Offset) = nullptr;
    Offset (*fold)(void *, char32_t, Offset) = nullptr;
    Offset (*stepRow)(void *, Offset, bool down, Offset count) = nullptr;
    Offset (*hiddenRows)(void *, Range) = nullptr;
    bool batch = false;
    void (*writeCursorClipboard)(void *, const Register &) = nullptr;
};

struct Selection {
    Kind kind = Kind::Character;
    Offset left = 0;
    Offset right = 0;
    Offset top = 0;
    Offset bottom = 0;
    bool toEnd = false;
    bool disjoint = false;
    std::vector<Range> ranges;
};

struct Repeat {
    std::vector<Input> inputs;
    Mode visualMode = Mode::Normal;
    Offset rows = 0;
    Offset columns = 0;
    bool toEnd = false;
    Offset occurrences = 0;
};

struct State {
    Mode mode = Mode::Normal;
    Op op = Op::None;
    Prefix prefix = Prefix::None;
    Kind forcedKind = Kind::Character;
    bool forceMotion = false;
    Offset cursor = 0;
    Offset anchor = 0;
    Offset goalColumn = NoOffset;
    bool goalEnd = false;
    std::optional<bool> finalNewline;
    Offset commandStart = 0;
    unsigned count = 0;
    unsigned operatorCount = 1;
    char32_t selectedRegister = 0;
    char32_t findCommand = 0;
    char32_t lastFindCommand = 0;
    std::u16string lastFind;
    std::array<Offset, 52> marks;
    std::vector<Offset> jumps;
    Offset jumpIndex = 0;
    std::vector<Offset> changes;
    Offset changeIndex = 0;
    Offset lastInsert = NoOffset;
    Mode lastVisual = Mode::Normal;
    Offset lastAnchor = 0;
    Offset lastVisualCursor = 0;
    Offset lastVisualColumn = NoOffset;
    bool lastVisualToEnd = false;
    Mode returnToInsert = Mode::Normal;

    std::shared_ptr<Change> change;
    std::shared_ptr<const LineUndo> lineUndo;
    std::vector<Input> inputs;
    Repeat repeat;
    Repeat visualRepeat;
    bool replaying = false;
    std::vector<Input> mappingKeys;
    bool groupChanges = false;
    Offset exNextLine = NoOffset;
    Offset exEnd = NoOffset;
    unsigned executionDepth = 0;
    unsigned executionBudget = 0;
    char32_t recording = 0;
    char32_t lastMacro = 0;
    std::vector<Input> macro;
    unsigned insertCount = 1;
    char32_t openCommand = 0;
    Offset insertStart = 0;
    Range automaticIndent;
    Offset blockTop = 0;
    Offset blockBottom = 0;
    Offset blockColumn = 0;
    Offset blockReturn = NoOffset;
    RowInsert rowInsert = RowInsert::Column;
    bool padBlock = false;
    bool simpleInsert = true;
    std::vector<Edit> replacements;
    std::vector<Range> occurrences;
    std::u16string occurrencePattern;
    std::vector<Offset> insertMirrors;
    std::vector<Surround> surrounds;
    bool surroundingTag = false;
    bool keepSurroundCursor = false;
    std::u16string surroundTag;

    Mode beforeCommand = Mode::Normal;
    char32_t prompt = 0;
    std::u16string command;
    Offset commandCaret = 0;
    std::vector<std::u16string> commandHistory;
    std::vector<std::u16string> searchHistory;
    Offset historyIndex = NoOffset;
    std::u16string lastSearch;
    Offset searchPreview = NoOffset;
    bool searchBackwards = false;
    bool ignoreCase = false;
    bool smartCase = false;
    bool highlightSearch = true;
    bool showMatches = false;
    bool incrementalSearch = true;
    bool wrapSearch = true;
    bool autoIndent = true;
    bool expandTab = false;
    bool number = true;
    bool relativeNumber = false;
    unsigned tabStop = 4;
    unsigned shiftWidth = 4;
    unsigned scrollLines = 0;
    std::u16string lastSubstitute;
    std::vector<Edit> substitutions;
    Offset substitutionIndex = 0;
    Offset substitutionOriginalCursor = 0;
    std::u16string message;

    State() { marks.fill(NoOffset); }
};

bool IsVisual(Mode mode);
bool IsInsert(Mode mode);
void SetCursor(State &state, const Host &host, Offset cursor);
Offset CursorOnRow(const State &state, const Host &host, Offset row);
Offset CursorColumn(const Host &host, Offset position, unsigned tabStop, bool finalNewline);
Offset CursorAtColumn(const Host &host, Offset row, Offset column, unsigned tabStop, bool finalNewline,
                      bool block = false);
Range WordAtCursor(const Host &host, Offset cursor);
Offset MoveEditorCursor(const Host &host, Key key, Offset position, Offset &column, unsigned tabStop);
void ExternalEdit(State &state, Range oldRange, Offset newLength);
void ForeignEdit(State &state, Range oldRange, Offset newLength);
void FinishChange(State &state);
Selection Selected(const State &state, const Host &host, Range visible = {0, NoOffset},
                   Offset cursor = NoOffset);
std::vector<Range> SearchHighlights(const State &state, const Host &host, Range visible);
std::u16string Status(const State &state);
void Feed(State &state, const Host &host, Registers &registers, Key key, Text text = {}, bool smart = false);
void FlushMappings(State &state, const Host &host, Registers &registers);
Offset LoadMappings(Registers &registers, Text config);
void MouseSelection(State &state, const Host &host, Range range, bool backwards = false);
void SelectAll(State &state, const Host &host);
void CopySelection(State &state, const Host &host, Registers &registers, bool cut);

} // namespace Vim
