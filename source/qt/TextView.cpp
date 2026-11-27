// The editor widget: a TextBuffer shown and edited exactly as QPlainTextEdit showed and edited the same text, pixel
// for pixel and key for key. Lines are laid out with QTextLayout the way QPlainTextEdit laid them out, but only when
// they are drawn or measured, and only their sizes are kept afterwards.
//
// "Qt" below means the Qt 6.12 code this replaces: QPlainTextEdit, QPlainTextDocumentLayout, QWidgetTextControl, and
// QTextCursor. The editor never wraps lines, so each of Qt's text blocks is one line here. tests/editor compares the
// two on hundreds of renders and thousands of key presses at six display scales.

#include "../Completion.hpp"
#include "../PopupColors.h"
#include "../TextBuffer.hpp"
#include "../Typing.hpp"

#include <QAbstractScrollArea>
#include <QAccessible>
#include <QAccessibleWidget>
#include <QApplication>
#include <QBasicTimer>
#include <QBuffer>
#include <QClipboard>
#include <QContextMenuEvent>
#include <QDir>
#include <QDrag>
#include <QFontDatabase>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QMenu>
#include <QMimeData>
#include <QMouseEvent>
#include <QPainter>
#include <QScrollBar>
#include <QStyle>
#include <QStyleHints>
#include <QStyleOption>
#include <QTextBoundaryFinder>
#include <QTextDocument>
#include <QTextDocumentFragment>
#include <QTextDocumentWriter>
#include <QTextLayout>

// Some of Qt's private headers: which keys a text edit takes before shortcuts, the text engine's emoji check that
// Backspace uses, and the platform's scroll step.
#include <QtGui/private/qfontdatabase_p.h>
#include <QtGui/private/qguiapplication_p.h>
#include <QtGui/private/qinputcontrol_p.h>
#include <QtGui/private/qtextengine_p.h>
#include <qpa/qplatformtheme.h>

#include <climits>
#include <cmath>
#include <cstdlib>
#include <utility>

struct TextAppearance {
    int stroke = 0;
    int saturation = 100;
    int brightness = 100;
    int contrast = 100;
};

enum class LineEnding : uint8_t { LF, CRLF, CR };

// How a file was written, so saving writes it back the same way.
struct FileFormat {
    LineEnding newline = LineEnding::LF;
    bool bom = false;
};

static const qreal DOCUMENT_MARGIN = 5;    // the margin the editor gave its QTextDocument
static const int CARET_WIDTH = 1;
static const int LANGUAGE_PREFIX_LENGTH = 512;    // how much of the text language detection reads
static const int TYPING_ROLE_PROPERTY = QTextFormat::UserProperty + 1;    // the Ink a typing rule sees in a non-code range

// What a line separator (U+2028) shows as. QTextLayout breaks a line at one, and QPlainTextEdit then scrolled by
// the lines inside each block. Here every line is one row, so the separator stays in its row as a pilcrow, which the
// editor's font has.
static const QChar LINE_SEPARATOR_MARK = QChar(0x00B6);

static QColor qt_color(Col32 color)
{
    return QColor(ColorRed(color), ColorGreen(color), ColorBlue(color), ColorAlpha(color));
}

static double color_luminance(Col32 color)
{
    return 0.2126 * ColorRed(color) + 0.7152 * ColorGreen(color) + 0.0722 * ColorBlue(color);
}

// A theme color with the appearance sliders applied: contrast against the paper, then brightness, then saturation.
static QColor adjust_ink(Col32 ink, Col32 paper, const TextAppearance &appearance)
{
    if (appearance.saturation == 100 && appearance.brightness == 100 && appearance.contrast == 100)
        return qt_color(ink);

    double gray = color_luminance(ink);
    double background = color_luminance(paper);
    double brightness = appearance.brightness / 100.0;
    double saturation = appearance.saturation / 100.0;
    double adjusted_gray = (background + (gray - background) * (appearance.contrast / 100.0)) * brightness;

    int channels[3] = {ColorRed(ink), ColorGreen(ink), ColorBlue(ink)};
    for (int &channel : channels)
        channel = qBound(0, qRound(adjusted_gray + (channel - gray) * saturation * brightness), 255);

    return QColor(channels[0], channels[1], channels[2], ColorAlpha(ink));
}

// A copy of the units. QString::fromUtf16 would drop a U+FEFF at the start as a byte order mark.
static QString qstring_of(std::u16string_view units)
{
    return QString((const QChar *)units.data(), qsizetype(units.size()));
}

static std::u16string_view view_of(QStringView text)
{
    return std::u16string_view((const char16_t *)text.utf16(), size_t(text.size()));
}

// Turns every line break QTextCursor::insertText breaks lines at into '\n', the only one the text keeps: CRLF, CR,
// the paragraph separator, and the two characters Qt uses to mark frames.
static void normalize_line_breaks(QString &text)
{
    text.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
    text.replace(u'\r', u'\n');
    text.replace(QChar::ParagraphSeparator, u'\n');
    text.replace(QChar(0xFDD0), u'\n');
    text.replace(QChar(0xFDD1), u'\n');
}

//
// The widget and its state.
//

// What Qt's document layout knew about a line it had laid out. It lays a line out when it first needs its size, and
// forgets every line when the editor's width changes.
struct LineSize {
    uint32_t generation : 31;    // the line is laid out while this equals TextView::layout_generation
    uint32_t has_formats : 1;    // QSyntaxHighlighter gave the line some formats when it last colored it
    int32_t height;              // the line's height rounded up to whole pixels, as QTextLayout::boundingRect gives it
    float width;                 // QTextLine::naturalTextWidth
};

// A run of tokens with equal formats, as QSyntaxHighlighter gave them to a line's layout.
struct InkRange {
    int start, length;
    const QTextCharFormat *format;
};

class TextView;

class TextViewGutter final : public QWidget {
public:
    explicit TextViewGutter(QWidget *view);

protected:
    void paintEvent(QPaintEvent *event) override;
};

class CompletionList final : public QWidget {
public:
    explicit CompletionList(QWidget *viewport);

    std::u16string characters;                       // the words shown, one after another
    uint32_t word_starts[WordCompletionLimit + 1];   // where each word starts in characters, and where the last ends
    int count, selected, row_height;
    PopupColors colors;

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
};

// Names from the rest of the text, collected when completion first runs on a line and kept while typing goes on in it.
struct CompletionWords {
    std::u16string characters;
    std::vector<uint32_t> word_starts;    // where each word starts in characters, with the end of the last one after
    std::vector<uint32_t> word_order;     // the words' numbers, sorted by word
    uint32_t line;                        // the line the names were collected around, or NO_POSITION
    uint32_t line_start, line_end, line_count;
    Language language;
    LexState incoming, outgoing;          // the lexer states around that line when they were collected
};

class TextView final : public QAbstractScrollArea {
public:
    TextView(const QString &name, const QString &units, const QString &source_path, const Theme &theme, int font_size,
             const TextAppearance &appearance);

    TextBuffer text;
    QString name;
    QString file_path;            // the file the text is saved to, or empty for a new one
    FileFormat file_format;
    QByteArray language_path;     // the path language detection reads, with forward slashes
    bool detects_from_text;       // the path names no language, so the first lines decide it
    Language mode;                // the language chosen in the picker, or Language::Count to detect it

    // The selection, as Qt's QTextCursor kept it.
    uint32_t caret, anchor;
    qreal caret_x;                // the x that Up and Down keep, or -1 until it's needed
    bool overwrite;
    bool caret_on;                // Qt's cursorOn: the caret is drawn, which blinking turns off and on
    bool focused;
    QBasicTimer caret_blink;

    // Scrolling and line sizes, as QPlainTextEdit and its document layout kept them.
    uint32_t top_line;
    std::vector<LineSize> line_sizes;
    uint32_t layout_generation;
    qreal layout_width;           // the width lines are laid out for: the viewport's, or 0 before it has one
    qreal widest_width;           // QPlainTextDocumentLayout's maximumWidth
    uint32_t widest_line;
    bool holding_size_changes;    // QPlainTextDocumentLayout's blockDocumentSizeChanged
    bool page_caret_y_valid;      // false once the caret moves, as Qt's cursorPositionChanged made it
    qreal page_caret_y;           // where the caret was in the viewport when Page Up or Page Down started
    uint32_t reported_caret, reported_anchor;    // the selection when caret_moved last ran

    // The mouse, as QWidgetTextControl tracked it.
    QPointF press_point;
    bool might_start_drag;        // the press landed in the selection, which a move drags and a release unselects
    QBasicTimer auto_scroll;      // scrolls while a selection is dragged past the viewport's edge
    uint32_t word_selection_anchor, word_selection_caret;    // the word a double click selected, or NO_POSITION
    uint32_t line_selection_anchor, line_selection_caret;    // the line a triple click selected, or NO_POSITION
    QBasicTimer triple_click;
    QPointF triple_click_point;

    // Text being composed by an input method, drawn inside its line's layout with the input method's formats. The
    // line keeps its syntax colors around it.
    QString preedit;
    uint32_t preedit_line;
    int preedit_position;         // where in the line, or -1 when nothing is being composed
    int preedit_caret;            // Qt's preeditCursor
    bool preedit_hides_caret;
    QList<QTextLayout::FormatRange> preedit_formats;

    // Fonts and colors.
    const Theme *theme;
    TextAppearance appearance;
    QFont code_font;
    QTextOption text_option;
    QTextCharFormat code_formats[size_t(Ink::Count)];
    QTextCharFormat non_code_formats[size_t(Ink::Count)];

    // Typing rules and brackets.
    Indentation indentation;
    std::vector<TypedPair> typed_pairs;
    BracketMatch brackets;
    QBasicTimer language_check;   // detecting the language again waits for the edit to finish, as Qt's did

    // Completion.
    CompletionList *completion;
    CompletionWords completion_words;
    uint32_t completion_start, completion_end;
    bool editing_completion;

    // What the window wants to hear about.
    void (*notify)(void *context, TextView &view, uint32_t changes);
    void *notify_context;
    uint32_t text_version;
    bool was_modified;

    TextViewGutter *gutter;

    // Scratch for lexing and laying out lines.
    std::vector<Token> tokens;
    std::vector<InkRange> ink_ranges;

    // The gutter sits in the viewport's left margin, which Qt only lets the scroll area itself set.
    using QAbstractScrollArea::setViewportMargins;
    using QAbstractScrollArea::viewportMargins;

protected:
    bool event(QEvent *event) override;
    void paintEvent(QPaintEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;
    void showEvent(QShowEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;
    void inputMethodEvent(QInputMethodEvent *event) override;
    QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void mouseDoubleClickEvent(QMouseEvent *event) override;
    void focusInEvent(QFocusEvent *event) override;
    void focusOutEvent(QFocusEvent *event) override;
    void timerEvent(QTimerEvent *event) override;
    void scrollContentsBy(int dx, int dy) override;
    void contextMenuEvent(QContextMenuEvent *event) override;
    bool focusNextPrevChild(bool next) override;

    void scroll_bar_action(int action);
};

// The changes TextView::notify reports.
static const uint32_t VIEW_CARET_MOVED = 1;
static const uint32_t VIEW_MODIFIED_CHANGED = 2;
static const uint32_t VIEW_LANGUAGE_CHANGED = 4;

// What the Edit menu can do.
enum class EditCommand : uint8_t { Undo, Redo, Cut, Copy, Paste, SelectAll };

static void notify_window(TextView &view, uint32_t changes)
{
    if (view.notify)
        view.notify(view.notify_context, view, changes);
}

static Language lexing_language(const TextView &view)
{
    return view.text.language == Language::Plain ? Language::C : view.text.language;
}

static bool lisp_completion(const TextView &view)
{
    return view.text.language == Language::CommonLisp || view.text.language == Language::Clojure;
}

static uint32_t text_length(const TextView &view)
{
    return uint32_t(view.text.units.size());
}

static uint32_t line_count(const TextView &view)
{
    return uint32_t(view.text.lines.size());
}

static uint32_t line_start(const TextView &view, uint32_t line)
{
    return view.text.lines[line].start;
}

static uint32_t line_end(const TextView &view, uint32_t line)
{
    return line_start(view, line) + uint32_t(line_text(view.text, line).size());
}

static uint32_t caret_line(const TextView &view)
{
    return line_of_offset(view.text, view.caret);
}

static uint32_t selection_start(const TextView &view)
{
    return view.caret < view.anchor ? view.caret : view.anchor;
}

static uint32_t selection_end(const TextView &view)
{
    return view.caret < view.anchor ? view.anchor : view.caret;
}

static bool composing_on(const TextView &view, uint32_t line)
{
    return view.preedit_position >= 0 && view.preedit_line == line;
}

//
// Syntax colors.
//

// The formats QSyntaxHighlighter gave each kind of token, with the theme's colors and the appearance applied. Plain
// text has no colors, only the typing role on its strings and comments.
static void build_formats(TextView &view)
{
    const Theme &theme = *view.theme;
    bool plain = view.text.language == Language::Plain;

    for (size_t ink = 0; ink < size_t(Ink::Count); ++ink) {
        QTextCharFormat &format = view.code_formats[ink];
        format = QTextCharFormat();
        format.setForeground(adjust_ink(theme.ink[ink], theme.paper, view.appearance));

        // Comments and types always say whether they are italic, even when not, so they never equal another kind of
        // token in the same color. Adjacent equal formats merge into one range, and QTextLayout shapes each range on
        // its own, so merging differently can move glyphs by a fraction of a pixel.
        if (Ink(ink) == Ink::Comment)
            format.setFontItalic(theme.italicComments);
        if (Ink(ink) == Ink::Type)
            format.setFontItalic(theme.italicTypes);

        view.non_code_formats[ink] = plain ? QTextCharFormat() : format;
        view.non_code_formats[ink].setProperty(TYPING_ROLE_PROPERTY, int(TypingRole(Ink(ink))));
    }
}

// A line's syntax ranges: one per run of adjacent tokens whose formats are equal, as QSyntaxHighlighter merges them.
// Plain text colors nothing, so only its non-code tokens get a range.
static void find_ink_ranges(TextView &view, uint32_t line, std::u16string_view units)
{
    LexState state = lex_state_before_line(view.text, line);
    tokenize_line(units, lexing_language(view), state, view.tokens);

    bool plain = view.text.language == Language::Plain;
    view.ink_ranges.clear();
    for (const Token &token : view.tokens) {
        bool non_code = IsNonCodeToken(token);
        if (plain && !non_code)
            continue;

        const QTextCharFormat *format = non_code ? &view.non_code_formats[size_t(token.ink)] : &view.code_formats[size_t(token.ink)];
        if (!view.ink_ranges.empty()) {
            InkRange &last = view.ink_ranges.back();
            if (last.start + last.length == int(token.start) && *last.format == *format) {
                last.length += token.length;
                continue;
            }
        }
        view.ink_ranges.push_back({int(token.start), int(token.length), format});
    }
}

//
// Laying out lines, as QPlainTextDocumentLayout::layoutBlock does.
//

// Fills a layout with a line: its text, its syntax colors or the input method's formats, and one QTextLine placed at
// the document margin.
static void lay_out_line(TextView &view, uint32_t line, QTextLayout &layout)
{
    std::u16string_view units = line_text(view.text, line);
    QString shown = qstring_of(units);
    shown.replace(QChar::LineSeparator, LINE_SEPARATOR_MARK);
    layout.setText(shown);
    layout.setTextOption(view.text_option);

    // With text being composed, the formats are QSyntaxHighlighter::applyFormatChanges's: the input method's, then the
    // syntax colors, with those after the composed text moved past it and one that reaches it stretched over it.
    bool composing = composing_on(view, line);
    int preedit_start = composing ? view.preedit_position : 0;
    int preedit_length = composing ? int(view.preedit.size()) : 0;
    QList<QTextLayout::FormatRange> formats;
    if (composing) {
        layout.setPreeditArea(preedit_start, view.preedit);
        formats = view.preedit_formats;
    }

    find_ink_ranges(view, line, units);
    for (const InkRange &range : view.ink_ranges) {
        int start = range.start, length = range.length;
        if (preedit_length && start >= preedit_start)
            start += preedit_length;
        else if (preedit_length && start + length >= preedit_start)
            length += preedit_length;
        formats.append({start, length, *range.format});
    }
    layout.setFormats(formats);

    qreal available = (view.layout_width <= 0 ? qreal(INT_MAX) : view.layout_width) - 2 * DOCUMENT_MARGIN;
    layout.beginLayout();
    QTextLine text_line = layout.createLine();
    text_line.setLeadingIncluded(true);
    text_line.setLineWidth(available);
    text_line.setPosition(QPointF(DOCUMENT_MARGIN, 0));
    layout.endLayout();
}

static void adjust_scrollbars(TextView &view);

// Records a line's size after laying it out, and keeps the widest line the way Qt's layoutBlock does: a line wider
// than the widest becomes the widest, and when the widest line itself gets narrower, Qt looks through the laid-out
// lines again, measuring each 8 pixels wider than its text instead of the 10 the margins add.
static void note_line_laid_out(TextView &view, uint32_t line, const QTextLayout &layout)
{
    LineSize &size = view.line_sizes[line];
    size.generation = view.layout_generation;
    size.height = int32_t(layout.boundingRect().bottom());
    size.width = float(layout.lineAt(0).naturalTextWidth());

    qreal width = size.width + 2 * DOCUMENT_MARGIN;
    bool widest_changed = false;
    if (width > view.widest_width) {
        view.widest_width = width;
        view.widest_line = line;
        widest_changed = true;
    } else if (line == view.widest_line && width < view.widest_width) {
        view.widest_width = 0;
        for (uint32_t other = 0; other < view.line_sizes.size(); ++other) {
            const LineSize &other_size = view.line_sizes[other];
            if (other_size.generation == view.layout_generation && other_size.width + 8 > view.widest_width) {
                view.widest_width = other_size.width + 8;
                view.widest_line = other;
            }
        }
        widest_changed = true;
    }

    if (widest_changed && !view.holding_size_changes)
        adjust_scrollbars(view);
}

static void lay_out_and_note(TextView &view, uint32_t line)
{
    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    note_line_laid_out(view, line, layout);
}

// Lays a line out unless it already is, as Qt did whenever it needed a line's size or a QTextCursor moved through it.
static void lay_out_if_needed(TextView &view, uint32_t line)
{
    if (view.line_sizes[line].generation != view.layout_generation)
        lay_out_and_note(view, line);
}

// The height Qt gave a line's block. The last line's block also holds the bottom margin.
static int line_block_height(TextView &view, uint32_t line)
{
    lay_out_if_needed(view, line);
    int height = view.line_sizes[line].height;
    return line + 1 == line_count(view) ? height + int(DOCUMENT_MARGIN) : height;
}

//
// Scrolling, as QPlainTextEdit does it with one line per block.
//

static int horizontal_offset(const TextView &view)
{
    return view.horizontalScrollBar()->value();
}

// Qt's verticalOffset: the first line keeps the top margin above it only while it is the top line.
static qreal vertical_offset(uint32_t top_line)
{
    return top_line == 0 ? -DOCUMENT_MARGIN : 0;
}

static QPointF content_offset(const TextView &view)
{
    return QPointF(-horizontal_offset(view), -vertical_offset(view.top_line));
}

// Where a line's block starts below the top line's, as QPlainTextEditControl::blockBoundingRect walks to it. The walk
// gives up two viewport heights away, and then only the walk so far counts.
static qreal line_top(TextView &view, uint32_t line)
{
    uint32_t current = view.top_line;
    qreal offset = 0;
    int height = line_block_height(view, current);
    int max_vertical_offset = height;
    int viewport_height = view.viewport()->height();

    while (current < line && offset - max_vertical_offset <= 2 * viewport_height) {
        offset += height;
        current += 1;
        height = line_block_height(view, current);
    }

    while (current > line && offset + max_vertical_offset >= -viewport_height) {
        current -= 1;
        height = line_block_height(view, current);
        offset -= height;
    }

    // A line out of reach is still laid out, and above the walk it goes a line higher.
    if (current != line) {
        int line_height = line_block_height(view, line);
        if (current > line)
            offset -= line_height;
    }

    return offset;
}

static void set_top_line(TextView &view, uint32_t line, int dx);

// QPlainTextEditPrivate::adjustScrollbars: the vertical range ends where the last lines fill the viewport, and the
// horizontal range covers the widest line laid out so far.
static void adjust_scrollbars(TextView &view)
{
    bool holding = view.holding_size_changes;
    view.holding_size_changes = true;

    int count = int(line_count(view));
    int maximum, page;
    if (view.isVisible()) {
        // Only lines entirely in view count, so a line cut off at the top doesn't.
        qreal visible = view.viewport()->rect().height() - DOCUMENT_MARGIN - 1;
        qreal y = 0;
        int visible_from_bottom = 0;
        for (int line = count - 1; line >= 0; --line) {
            y += line_block_height(view, uint32_t(line));
            if (y > visible)
                break;
            visible_from_bottom += 1;
        }
        maximum = count - visible_from_bottom;
        page = visible_from_bottom;
    } else {
        maximum = count - 1;
        int line_spacing = view.fontMetrics().lineSpacing();
        page = line_spacing ? view.viewport()->height() / line_spacing : 0;
    }

    QScrollBar *vertical = view.verticalScrollBar();
    vertical->setRange(0, maximum > 0 ? maximum : 0);
    vertical->setPageStep(page);
    vertical->setValue(int(view.top_line));

    QScrollBar *horizontal = view.horizontalScrollBar();
    horizontal->setRange(0, int(view.widest_width) - view.viewport()->width());
    horizontal->setPageStep(view.viewport()->width());

    view.holding_size_changes = holding;
    set_top_line(view, uint32_t(vertical->value()), 0);
}

// QPlainTextEditPrivate::setTopBlock for one line per block. Block heights are whole pixels, so scrolling never
// leaves a fraction of a pixel behind.
static void set_top_line(TextView &view, uint32_t line, int dx)
{
    QScrollBar *vertical = view.verticalScrollBar();
    if (line > uint32_t(vertical->maximum()))
        line = uint32_t(vertical->maximum());

    // Setting the scroll bar can come back here through scrollContentsBy, and then this one has nothing left to do.
    vertical->setValue(int(line));
    if (!dx && line == view.top_line)
        return;

    if (view.viewport()->updatesEnabled() && view.viewport()->isVisible()) {
        qreal real_dy = -line_top(view, line) + vertical_offset(view.top_line) - vertical_offset(line);
        int dy = int(real_dy);
        view.top_line = line;
        vertical->setValue(int(line));
        if (dx || dy)
            view.viewport()->scroll(dx, dy);
        else
            view.viewport()->update();
        view.gutter->update();
    } else {
        view.top_line = line;
    }
}

static void lay_out_again(TextView &view, qreal width)
{
    view.layout_width = width;
    view.widest_width = width;
    view.layout_generation += 1;
}

// QPlainTextEditPrivate::ensureVisible: scrolls so the line holding position is in view, at the bottom when it was
// below, at the top when it was above, or in the middle when centering.
static void ensure_visible(TextView &view, uint32_t position, bool center, bool force_center)
{
    QRectF visible = QRectF(view.viewport()->rect()).translated(-content_offset(view));
    uint32_t line = line_of_offset(view.text, position);
    qreal top = line_top(view, line);

    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    QRectF line_rect = layout.lineAt(0).naturalTextRect();

    if (top + line_rect.bottom() >= visible.bottom() || (center && top + line_rect.top() < visible.top()) || force_center) {
        qreal room = center ? visible.height() / 2 : visible.height();
        qreal h = center ? line_rect.center().y() : line_rect.bottom();
        uint32_t block = line, previous_visible = line;
        while (h < room && block > 0) {
            previous_visible = block;
            block -= 1;
            h += line_block_height(view, block);
        }

        // The walk can overshoot by part of a line, and then the line after the one it stopped on goes on top.
        if (h - vertical_offset(block) > room)
            block = previous_visible;

        set_top_line(view, block, 0);
    } else if (top + line_rect.top() < visible.top()) {
        set_top_line(view, line, 0);
    }
}

// The caret's rectangle at a position in Qt's content coordinates, as QWidgetTextControlPrivate::rectForPosition
// gives it: wide enough to cover the next character in overwrite mode.
static QRectF caret_rect_in_content(TextView &view, uint32_t position)
{
    uint32_t line = line_of_offset(view.text, position);
    qreal top = line_top(view, line);
    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);

    int relative = int(position - line_start(view, line));
    if (view.preedit_caret != 0 && composing_on(view, line)) {
        if (relative == view.preedit_position)
            relative += view.preedit_caret;
        else if (relative > view.preedit_position)
            relative += int(view.preedit.size());
    }

    QTextLine text_line = layout.lineForTextPosition(relative);
    qreal x = text_line.cursorToX(relative);
    qreal width = 0;
    if (view.overwrite) {
        if (relative < text_line.textLength() - text_line.textStart())
            width = text_line.cursorToX(relative + 1) - x;
        else
            width = QFontMetrics(layout.font()).horizontalAdvance(u' ');
    }

    return QRectF(x, top + text_line.y(), CARET_WIDTH + width, text_line.height());
}

// QPlainTextEdit::cursorRect: in viewport coordinates, rounded to whole pixels.
static QRect caret_rect_at(TextView &view, uint32_t position)
{
    QRect rect = caret_rect_in_content(view, position).toRect();
    return rect.translated(-horizontal_offset(view), -int(vertical_offset(view.top_line)));
}

// What QWidgetTextControl repaints when the caret blinks: the caret, widened for direction marks around it, as
// QPlainTextEditPrivate::repaintContents turns a rectangle in content coordinates into one in the viewport.
static void repaint_caret(TextView &view)
{
    int x = horizontal_offset(view), y = int(vertical_offset(view.top_line));
    QRectF visible(x, y, view.viewport()->width(), view.viewport()->height());
    QRectF caret = caret_rect_in_content(view, view.caret).adjusted(-4, 0, 4, 0);
    QRect rect = caret.adjusted(-1, -1, 1, 1).intersected(visible).toAlignedRect();
    if (!rect.isEmpty())
        view.viewport()->update(rect.translated(-x, -y));
}

// QPlainTextEditPrivate::ensureCursorVisible: vertically through ensure_visible, and horizontally by centering the
// caret when it is out of view.
static void ensure_caret_visible(TextView &view)
{
    QRect visible = view.viewport()->rect();
    QRect caret = caret_rect_at(view, view.caret);
    if (caret.top() < visible.top() || caret.bottom() > visible.bottom())
        ensure_visible(view, view.caret, false, false);

    if (caret.left() < visible.left() || caret.right() > visible.right())
        view.horizontalScrollBar()->setValue(caret.center().x() + horizontal_offset(view) - visible.width() / 2);
}

// A point in the viewport in Qt's content coordinates, which start at the top line's block.
static QPointF content_point(const TextView &view, QPointF point)
{
    return point + QPointF(horizontal_offset(view), vertical_offset(view.top_line));
}

// QPlainTextEditControl::hitTest: the text position at a point in content coordinates.
static uint32_t hit_test(TextView &view, QPointF point)
{
    uint32_t line = view.top_line;
    qreal offset = 0;
    int height = line_block_height(view, line);
    while (line + 1 < line_count(view) && height + offset <= point.y()) {
        offset += height;
        line += 1;
        height = line_block_height(view, line);
    }

    // Going up, Qt steps back by the height of the line it leaves rather than the one it reaches.
    while (line > 0 && offset > point.y()) {
        offset -= height;
        line -= 1;
        height = line_block_height(view, line);
    }

    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    QTextLine text_line = layout.lineAt(0);
    QRectF rect = text_line.naturalTextRect();

    // Above the line is its start, below it its end.
    qreal y = point.y() - offset;
    int column = 0;
    if (rect.bottom() <= y)
        column = text_line.textStart() + text_line.textLength();
    else if (rect.top() <= y)
        column = text_line.xToCursor(point.x(), view.overwrite ? QTextLine::CursorOnCharacter : QTextLine::CursorBetweenCharacters);

    return line_start(view, line) + uint32_t(column);
}

//
// The caret, as QTextCursor moves it.
//

// Left, Right, WordLeft, and WordRight go the other way in a right-to-left line; the rest follow the text's order.
enum class CaretMove : uint8_t {
    Start, End, StartOfLine, EndOfLine, Left, Right, Up, Down, WordLeft, WordRight, NextCharacter, PreviousCharacter,
    NextWord, PreviousWord, StartOfWord, EndOfWord,
};

// Qt's QTextBlock::textDirection: the direction of the first strong character in the line.
static bool line_is_right_to_left(const TextView &view, uint32_t line)
{
    std::u16string_view units = line_text(view.text, line);
    for (size_t at = 0; at < units.size(); ++at) {
        char32_t code = units[at];
        if (QChar::isHighSurrogate(units[at]) && at + 1 < units.size() && QChar::isLowSurrogate(units[at + 1])) {
            code = QChar::surrogateToUcs4(units[at], units[at + 1]);
            at += 1;
        }

        QChar::Direction direction = QChar::direction(code);
        if (direction == QChar::DirL)
            return false;
        if (direction == QChar::DirR || direction == QChar::DirAL)
            return true;
    }

    return false;
}

// QTextDocumentPrivate::nextCursorPosition and previousCursorPosition: through the layout inside a line, and across
// the line break between lines.
static uint32_t next_position(TextView &view, uint32_t position, QTextLayout::CursorMode mode)
{
    if (position == text_length(view))
        return position;

    uint32_t line = line_of_offset(view.text, position);
    if (position == line_end(view, line))
        return position + 1;

    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    uint32_t start = line_start(view, line);
    return start + uint32_t(layout.nextCursorPosition(int(position - start), mode));
}

static uint32_t previous_position(TextView &view, uint32_t position, QTextLayout::CursorMode mode)
{
    if (position == 0)
        return 0;

    uint32_t line = line_of_offset(view.text, position);
    uint32_t start = line_start(view, line);
    if (position == start)
        return start - 1;

    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    return start + uint32_t(layout.previousCursorPosition(int(position - start), mode));
}

static bool is_word_separator(char16_t ch)
{
    switch (ch) {
        case u'.': case u',': case u'?': case u'!': case u'@': case u'#': case u'$': case u':': case u';': case u'-':
        case u'<': case u'>': case u'[': case u']': case u'(': case u')': case u'{': case u'}': case u'=': case u'/':
        case u'+': case u'%': case u'&': case u'^': case u'*': case u'\'': case u'"': case u'`': case u'~': case u'|':
        case u'\\':
            return true;
        default:
            return false;
    }
}

// QTextEngine's whiteSpace attribute: set on the first unit of each space character.
static bool is_white_space_at(std::u16string_view units, size_t at)
{
    if (QChar::isLowSurrogate(units[at]) && at > 0 && QChar::isHighSurrogate(units[at - 1]))
        return false;
    if (QChar::isHighSurrogate(units[at]) && at + 1 < units.size() && QChar::isLowSurrogate(units[at + 1]))
        return QChar::isSpace(QChar::surrogateToUcs4(units[at], units[at + 1]));
    return QChar::isSpace(units[at]);
}

// QTextCursor's StartOfWord and EndOfWord from a position. Each returns false when Qt's movePosition would.
static bool find_word_start(TextView &view, uint32_t position, uint32_t &word_start)
{
    uint32_t line = line_of_offset(view.text, position);
    uint32_t relative = position - line_start(view, line);
    word_start = position;
    if (relative == 0)
        return false;

    std::u16string_view units = line_text(view.text, line);
    if (relative == units.size() && (is_white_space_at(units, relative - 1) || is_word_separator(units[relative - 1])))
        return false;

    // Qt steps one unit ahead first, so a position already at a word's start stays there and still counts as moved.
    if (relative < units.size())
        position += 1;
    word_start = previous_position(view, position, QTextLayout::SkipWords);
    return word_start != position;
}

static bool find_word_end(TextView &view, uint32_t position, uint32_t &word_end)
{
    uint32_t line = line_of_offset(view.text, position);
    uint32_t start = line_start(view, line);
    uint32_t relative = position - start;
    std::u16string_view units = line_text(view.text, line);
    word_end = position;
    if (relative >= units.size())
        return false;

    if (is_word_separator(units[relative])) {
        relative += 1;
        while (relative < units.size() && is_word_separator(units[relative]))
            relative += 1;
    } else {
        while (relative < units.size() && !is_white_space_at(units, relative) && !is_word_separator(units[relative]))
            relative += 1;
    }

    word_end = start + relative;
    return word_end != position;
}

// The x Up and Down keep, as QTextCursorPrivate::setX measures it.
static qreal caret_x_now(TextView &view)
{
    uint32_t line = caret_line(view);
    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    return layout.lineAt(0).cursorToX(int(view.caret - line_start(view, line)));
}

// QTextCursorPrivate::movePosition with Qt's logical cursor movement. Returns whether the caret moved.
static bool move_caret(TextView &view, CaretMove move, bool keep_anchor)
{
    uint32_t line = caret_line(view);
    uint32_t start = line_start(view, line);
    bool adjust_x = true;

    if (line_is_right_to_left(view, line)) {
        if (move == CaretMove::WordLeft)
            move = CaretMove::WordRight;
        else if (move == CaretMove::WordRight)
            move = CaretMove::WordLeft;
        else if (move == CaretMove::Left)
            move = CaretMove::NextCharacter;
        else if (move == CaretMove::Right)
            move = CaretMove::PreviousCharacter;
    }

    if (view.caret_x < 0 && (move == CaretMove::Up || move == CaretMove::Down))
        view.caret_x = caret_x_now(view);

    uint32_t new_position = view.caret;
    switch (move) {
        case CaretMove::Start:
            new_position = 0;
            break;

        case CaretMove::End:
            new_position = text_length(view);
            break;

        case CaretMove::StartOfLine:
            new_position = start;
            break;

        case CaretMove::EndOfLine:
            new_position = line_end(view, line);
            break;

        case CaretMove::Left:
        case CaretMove::PreviousCharacter:
            if (!keep_anchor && view.caret != view.anchor)
                new_position = selection_start(view);
            else
                new_position = previous_position(view, view.caret, QTextLayout::SkipCharacters);
            break;

        case CaretMove::Right:
        case CaretMove::NextCharacter:
            if (!keep_anchor && view.caret != view.anchor)
                new_position = selection_end(view);
            else
                new_position = next_position(view, view.caret, QTextLayout::SkipCharacters);
            break;

        case CaretMove::WordLeft:
        case CaretMove::PreviousWord:
            new_position = previous_position(view, view.caret, QTextLayout::SkipWords);
            break;

        case CaretMove::WordRight:
        case CaretMove::NextWord:
            new_position = next_position(view, view.caret, QTextLayout::SkipWords);
            break;

        case CaretMove::StartOfWord:
        case CaretMove::EndOfWord: {
            bool moved = move == CaretMove::StartOfWord ? find_word_start(view, view.caret, new_position) :
                                                           find_word_end(view, view.caret, new_position);
            view.caret = new_position;
            if (!keep_anchor)
                view.anchor = new_position;
            view.caret_x = -1;
            return moved;
        }

        case CaretMove::Up:
        case CaretMove::Down: {
            if ((move == CaretMove::Up && line == 0) || (move == CaretMove::Down && line + 1 == line_count(view)))
                return false;

            uint32_t target = move == CaretMove::Up ? line - 1 : line + 1;
            QTextLayout layout(QString(), view.code_font, view.viewport());
            lay_out_line(view, target, layout);
            new_position = line_start(view, target) + uint32_t(layout.lineAt(0).xToCursor(view.caret_x));
            adjust_x = false;
            break;
        }
    }

    bool moved = new_position != view.caret;
    view.caret = new_position;
    if (!keep_anchor)
        view.anchor = new_position;
    if (adjust_x)
        view.caret_x = -1;

    return moved;
}

// QTextCursor::setPosition.
static void set_caret(TextView &view, uint32_t position, bool keep_anchor)
{
    view.caret = position;
    if (!keep_anchor)
        view.anchor = position;
    view.caret_x = -1;
}

//
// Reacting to the caret and to text changes.
//

static void dismiss_completion(TextView &view);
static void completion_words_edited(TextView &view, uint32_t at, uint32_t removed, uint32_t added);
static TypingSource typing_source(TextView &view);

static void refresh_bracket_match(TextView &view)
{
    uint32_t start = selection_start(view);
    BracketMatch match = BracketsAtSelection(typing_source(view), {start, selection_end(view) - start});
    if (match == view.brackets)
        return;

    view.brackets = match;
    view.viewport()->update();
}

// QWidget::updateMicroFocus: the input method hears where the caret is now, and keeps its window beside it.
static void update_input_method(TextView &view)
{
    if (&view == QGuiApplication::focusObject())
        QGuiApplication::inputMethod()->update(Qt::ImQueryAll);
}

// What the editor did when the caret moved: the current line and bracket outlines follow it, the completion list
// closes unless typing is refining it, and the window hears about it.
static void caret_moved(TextView &view)
{
    // Screen readers hear about a moved caret, and about a selection that appeared, went, or changed, as
    // QPlainTextEdit and QWidgetTextControl told them.
    bool selected = view.caret != view.anchor, was_selected = view.reported_caret != view.reported_anchor;
    if (QAccessible::isActive()) {
        if (selected != was_selected || (selected && (view.caret != view.reported_caret || view.anchor != view.reported_anchor))) {
            QAccessibleTextSelectionEvent event(&view, int(view.anchor), int(view.caret));
            QAccessible::updateAccessibility(&event);
        }
        if (view.caret != view.reported_caret) {
            QAccessibleTextCursorEvent event(&view, int(view.caret));
            QAccessible::updateAccessibility(&event);
        }
    }
    view.reported_anchor = view.anchor;

    if (view.caret != view.reported_caret) {
        view.page_caret_y_valid = false;
        view.reported_caret = view.caret;
    }

    refresh_bracket_match(view);
    if (!view.editing_completion)
        dismiss_completion(view);

    view.viewport()->update();
    view.gutter->update();
    update_input_method(view);
    notify_window(view, VIEW_CARET_MOVED);
}

// QWidgetTextControl::setTextCursor.
static void set_selection(TextView &view, uint32_t anchor, uint32_t caret)
{
    view.anchor = anchor;
    view.caret = caret;
    view.caret_x = -1;
    view.caret_on = view.focused;
    ensure_caret_visible(view);
    caret_moved(view);
}

static void update_gutter_width(TextView &view);

// Qt counted a line's formats or composed text changing as a change to all of the line and its line break.
static void note_line_changed(TextView &view, TextChange &change, uint32_t line)
{
    note_document_change(change, line_start(view, line), uint32_t(line_text(view.text, line).size()) + 1);
}

// Whether QSyntaxHighlighter gives a line any formats: any token in code, and strings and comments in plain text.
// Text being composed in the line has the input method's formats too.
static bool line_has_formats(TextView &view, uint32_t line)
{
    if (composing_on(view, line) && !view.preedit_formats.empty())
        return true;

    LexState state = lex_state_before_line(view.text, line);
    tokenize_line(line_text(view.text, line), lexing_language(view), state, view.tokens);
    bool plain = view.text.language == Language::Plain;
    for (const Token &token : view.tokens) {
        if (token.length && (!plain || IsNonCodeToken(token)))
            return true;
    }

    return false;
}

// QSyntaxHighlighter colors every line when it starts, and again for another language.
static void note_all_line_formats(TextView &view)
{
    for (uint32_t line = 0; line < line_count(view); ++line)
        view.line_sizes[line].has_formats = line_has_formats(view, line);
}

// What Qt did once an edit finished: QPlainTextDocumentLayout::documentChanged lays out a line edited in place, or
// forgets the lines a larger change touched, and the editor moves its typed pairs and bracket outlines with the text.
// Inside an undo group this waits for the group to end, as Qt waited for the edit block.
static void react_to_text_change(TextView &view)
{
    TextBuffer &text = view.text;
    if (text.changed.start == NO_POSITION || text.undo_group_depth > 0)
        return;

    uint32_t from = text.changed.start, removed = text.changed.old_length, added = text.changed.new_length;
    text.changed.start = NO_POSITION;
    view.text_version += 1;

    // Typed pairs and bracket positions follow the text, and any that the change touched go.
    TypingRange edited = {from, removed};
    size_t kept = 0;
    for (TypedPair pair : view.typed_pairs) {
        if (MapTypedRange(pair.opening, edited, added) && MapTypedRange(pair.closing, edited, added))
            view.typed_pairs[kept++] = pair;
    }
    view.typed_pairs.resize(kept);

    size_t *bracket_positions[2] = {&view.brackets.at, &view.brackets.mate};
    for (size_t *position : bracket_positions) {
        TypingRange bracket = {*position, 1};
        if (*position != typingNotFound)
            *position = MapTypedRange(bracket, edited, added) ? bracket.location : typingNotFound;
    }

    completion_words_edited(view, from, removed, added);
    if (!view.editing_completion)
        dismiss_completion(view);

    // Screen readers hear what text came in. Like QWidgetTextControl, they get spaces for what went, since it's gone.
    if (QAccessible::isActive()) {
        QString inserted = qstring_of(std::u16string_view(text.units.data() + from, added));
        QString gone(qsizetype(removed), u' ');
        if (!removed) {
            QAccessibleTextInsertEvent event(&view, int(from), inserted);
            QAccessible::updateAccessibility(&event);
        } else if (!added) {
            QAccessibleTextRemoveEvent event(&view, int(from), gone);
            QAccessible::updateAccessibility(&event);
        } else {
            QAccessibleTextUpdateEvent event(&view, int(from), gone, inserted);
            QAccessible::updateAccessibility(&event);
        }
    }

    // The line sizes follow the lines. A line break splits a line, and its second half is a new line, not laid out and
    // without formats yet. Removing a line break joins the next line into the one before it.
    uint32_t count = line_count(view);
    int32_t line_difference = int32_t(count) - int32_t(view.line_sizes.size());
    uint32_t first_line = line_of_offset(text, from);
    uint32_t stale_generation = view.layout_generation - 1;
    if (line_difference > 0) {
        LineSize new_line = {};
        new_line.generation = stale_generation;
        view.line_sizes.insert(view.line_sizes.begin() + first_line + 1, size_t(line_difference), new_line);
    } else if (line_difference < 0) {
        view.line_sizes.erase(view.line_sizes.begin() + first_line + 1, view.line_sizes.begin() + first_line + 1 - line_difference);
    }

    // QSyntaxHighlighter colors the lines from the change to the one holding the unit after the insertion, or after
    // the removal's end. It goes on past a new line, and past each line that now ends in a different lexer state.
    // Every line whose formats it sets counts as changed again, which widens the range the layout hears about.
    uint32_t highlight_end = from + added + (removed ? 1 : 0);
    uint32_t last_highlighted = line_of_offset(text, highlight_end < text_length(view) ? highlight_end : text_length(view));
    if (line_difference > 0 && last_highlighted < first_line + uint32_t(line_difference) + 1)
        last_highlighted = first_line + uint32_t(line_difference) + 1;
    if (text.lexed_end_line != NO_POSITION && text.lexed_end_line > last_highlighted)
        last_highlighted = text.lexed_end_line;
    if (last_highlighted >= count)
        last_highlighted = count - 1;
    text.lexed_end_line = NO_POSITION;

    TextChange layout_change = {from, removed, added};
    for (uint32_t line = first_line; line <= last_highlighted; ++line) {
        bool has_formats = line_has_formats(view, line);
        if (view.line_sizes[line].has_formats || has_formats)
            note_line_changed(view, layout_change, line);
        view.line_sizes[line].has_formats = has_formats;
    }

    // QPlainTextDocumentLayout::documentChanged. The range ends at the old and new lengths added together, which can
    // reach past the end of the text and find no line, and then every line to the end is laid out again.
    uint32_t layout_start_line = line_of_offset(text, layout_change.start);
    uint32_t reach = layout_change.start + layout_change.old_length + layout_change.new_length;
    bool reaches_end = reach > text_length(view) + 1;
    uint32_t layout_end_line = reaches_end ? count - 1 : line_of_offset(text, reach ? reach - 1 : 0);

    if (layout_start_line == layout_end_line && !reaches_end && !line_difference) {
        // Qt measured the line to compare heights and then laid it out again, which changed nothing more.
        view.line_sizes[layout_start_line].generation = stale_generation;
        lay_out_and_note(view, layout_start_line);
    } else {
        for (uint32_t line = layout_start_line; line <= layout_end_line; ++line)
            view.line_sizes[line].generation = stale_generation;

        // A different number of lines changes the document's size. The widest line's number moves with the lines
        // after the change, which Qt counts from -1 when the range found no line.
        if (line_difference) {
            int64_t old_change_end = (reaches_end ? -1 : int64_t(layout_end_line)) - line_difference;
            if (int64_t(view.widest_line) > old_change_end)
                view.widest_line = uint32_t(int64_t(view.widest_line) + line_difference);
            if (count == 1)
                view.widest_width = 0;
            if (!view.holding_size_changes)
                adjust_scrollbars(view);
        }
    }

    if (line_difference)
        update_gutter_width(view);

    if (text.modified != view.was_modified) {
        view.was_modified = text.modified;
        notify_window(view, VIEW_MODIFIED_CHANGED);
    }

    // The language follows the first lines when the file's name doesn't say. Qt's version waited for the edit to end.
    if (view.mode == Language::Count && view.detects_from_text && from < uint32_t(LANGUAGE_PREFIX_LENGTH)) {
        const char16_t *units = text.units.data();
        size_t length = text.units.size();
        bool may_change = text.language != Language::Plain || (length && QChar::isSpace(units[0])) ||
                          (length >= 2 && ((units[0] == u'#' && units[1] == u'!') || (units[0] == u'<' && units[1] == u'?')));
        if (may_change)
            view.language_check.start(0, &view);
    }

    refresh_bracket_match(view);
    view.viewport()->update();
    view.gutter->update();
}

// The text was saved, so it no longer counts as modified.
static void mark_view_saved(TextView &view)
{
    mark_text_saved(view.text);
    if (view.was_modified) {
        view.was_modified = false;
        notify_window(view, VIEW_MODIFIED_CHANGED);
    }
}

//
// Typing rules read the text through TypingSource.
//

static char16_t typing_character(void *context, size_t at)
{
    return static_cast<TextView *>(context)->text.units[at];
}

static CommentLine typing_line(void *context, size_t at)
{
    TextView &view = *static_cast<TextView *>(context);
    uint32_t line = line_of_offset(view.text, uint32_t(at));
    uint32_t end = line_end(view, line);
    return {line_start(view, line), end, end + (line + 1 < line_count(view) ? 1u : 0u)};
}

// The syntax range around a position, as typing rules read it from the layout's formats in Qt: a non-code range
// carries its role, and anything else reads as plain text up to the next range.
static TypingSpan typing_syntax(void *context, size_t at)
{
    TextView &view = *static_cast<TextView *>(context);
    uint32_t line = line_of_offset(view.text, uint32_t(at));
    uint32_t start = line_start(view, line);
    std::u16string_view units = line_text(view.text, line);
    find_ink_ranges(view, line, units);

    int offset = int(at - start);
    int next_start = int(units.size()) + 1;
    for (const InkRange &range : view.ink_ranges) {
        if (range.start > offset) {
            next_start = range.start;
            break;
        }

        if (offset < range.start + range.length && range.format->hasProperty(TYPING_ROLE_PROPERTY))
            return {{start + size_t(range.start), size_t(range.length)}, Ink(range.format->intProperty(TYPING_ROLE_PROPERTY))};
    }

    return {{at, size_t(next_start - offset)}, Ink::Text};
}

static void typing_append(void *context, std::u16string &result, TypingRange range)
{
    const TextView &view = *static_cast<TextView *>(context);
    result.append(view.text.units.data() + range.location, range.length);
}

static size_t typing_find(void *context, TypingRange range, TypingSearch search, bool backwards)
{
    const TextView &view = *static_cast<TextView *>(context);
    std::u16string_view slice(view.text.units.data() + range.location, range.length);
    std::u16string_view choices = TypingSearchCharacters(search);

    size_t at;
    if (search == TypingSearch::NonBlank)
        at = backwards ? slice.find_last_not_of(choices) : slice.find_first_not_of(choices);
    else
        at = backwards ? slice.find_last_of(choices) : slice.find_first_of(choices);

    return at == slice.npos ? typingNotFound : range.location + at;
}

static size_t typing_grapheme_end(void *context, size_t at)
{
    TextView &view = *static_cast<TextView *>(context);
    uint32_t line = line_of_offset(view.text, uint32_t(at));
    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);

    uint32_t start = line_start(view, line);
    size_t next = start + size_t(layout.nextCursorPosition(int(at - start), QTextLayout::SkipCharacters));
    return next > at + 1 ? next : at + 1;
}

static bool typing_alphanumeric(char16_t ch)
{
    return QChar(ch).isLetterOrNumber() || QChar(ch).isMark();
}

static TypingSource typing_source(TextView &view)
{
    return {&view, view.text.units.size(), typing_character, typing_line, typing_syntax, typing_append, typing_find,
            typing_grapheme_end, typing_alphanumeric};
}

//
// Editing, the way QTextCursor and QWidgetTextControl edit.
//

// QTextCursor::insertText at the selection: a removal or a line break makes the insertion one undo step.
static void insert_at_selection(TextView &view, std::u16string_view inserted)
{
    uint32_t start = selection_start(view);
    uint32_t length = selection_end(view) - start;
    bool grouped = length > 0 || inserted.find(u'\n') != inserted.npos;

    if (grouped)
        begin_undo_group(view.text, NO_POSITION);
    replace_text(view.text, start, length, inserted);
    if (grouped)
        end_undo_group(view.text);

    set_caret(view, start + uint32_t(inserted.size()), false);
    react_to_text_change(view);
}

// QTextCursor::removeSelectedText, one undo step, or nothing without a selection.
static void remove_selection(TextView &view)
{
    if (view.caret == view.anchor)
        return;

    uint32_t start = selection_start(view);
    begin_undo_group(view.text, NO_POSITION);
    replace_text(view.text, start, selection_end(view) - start, {});
    end_undo_group(view.text);

    set_caret(view, start, false);
    react_to_text_change(view);
}

// QTextCursor::deleteChar: the whole character after the caret.
static void delete_next_character(TextView &view)
{
    if (view.caret != view.anchor) {
        remove_selection(view);
        return;
    }

    uint32_t end = next_position(view, view.caret, QTextLayout::SkipCharacters);
    if (end > view.caret)
        replace_text(view.text, view.caret, end - view.caret, {});

    view.caret_x = -1;
    react_to_text_change(view);
}

// QTextCursor::deletePreviousChar in Qt 6.12: a whole emoji sequence, or else one code point.
static void delete_previous_character(TextView &view)
{
    if (view.caret != view.anchor) {
        remove_selection(view);
        return;
    }

    if (view.caret == 0)
        return;

    uint32_t cluster_start = previous_position(view, view.caret, QTextLayout::SkipCharacters);
    uint32_t start = view.caret - 1;
    if (view.caret - cluster_start > 1) {
        uint32_t line = line_of_offset(view.text, cluster_start);
        QTextLayout layout(QString(), view.code_font, view.viewport());
        lay_out_line(view, line, layout);

        QTextEngine *engine = layout.engine();
        int item = engine->findItem(int(cluster_start - line_start(view, line)));
        if (item >= 0 && engine->layoutData->items[item].analysis.script == QFontDatabasePrivate::Script_Emoji) {
            start = cluster_start;
        } else {
            const char16_t *units = view.text.units.data();
            if (start > line_start(view, line) && QChar::isLowSurrogate(units[start]) && QChar::isHighSurrogate(units[start - 1]))
                start -= 1;
        }
    }

    replace_text(view.text, start, view.caret - start, {});
    set_caret(view, start, false);
    react_to_text_change(view);
}

// The selection as QPlainTextEdit offered it to the clipboard and to drags: as plain text, and as HTML, Markdown, and
// OpenDocument in the editor's font, which are only made when another program asks for them.
class SelectionMimeData final : public QMimeData {
public:
    QTextDocumentFragment fragment;

    QStringList formats() const override
    {
        if (fragment.isEmpty())
            return QMimeData::formats();
        return {QStringLiteral("text/plain"), QStringLiteral("text/html"), QStringLiteral("text/markdown"),
                QStringLiteral("application/vnd.oasis.opendocument.text")};
    }

    bool hasFormat(const QString &format) const override
    {
        return formats().contains(format);
    }

protected:
    QVariant retrieveData(const QString &format, QMetaType type) const override
    {
        if (!fragment.isEmpty()) {
            SelectionMimeData &data = const_cast<SelectionMimeData &>(*this);
            data.setData(QStringLiteral("text/html"), fragment.toHtml().toUtf8());
            data.setData(QStringLiteral("text/markdown"), fragment.toMarkdown().toUtf8());
            QBuffer odf;
            QTextDocumentWriter(&odf, "ODF").write(fragment);
            data.setData(QStringLiteral("application/vnd.oasis.opendocument.text"), odf.data());
            data.setText(fragment.toPlainText());
            data.fragment = QTextDocumentFragment();
        }
        return QMimeData::retrieveData(format, type);
    }
};

static QMimeData *selection_mime_data(TextView &view)
{
    uint32_t start = selection_start(view);
    QTextDocument document;
    document.setDefaultFont(view.code_font);
    document.setPlainText(qstring_of(std::u16string_view(view.text.units.data() + start, selection_end(view) - start)));

    SelectionMimeData *data = new SelectionMimeData;
    data->fragment = QTextDocumentFragment(&document);
    return data;
}

static void copy_selection(TextView &view)
{
    if (view.caret != view.anchor)
        QApplication::clipboard()->setMimeData(selection_mime_data(view));
}

// Pastes the way the editor's other edits work: one undo step that starts at the caret.
static void paste(TextView &view)
{
    const QMimeData *mime = QApplication::clipboard()->mimeData();
    QString pasted = mime ? mime->text() : QString();
    if (pasted.isEmpty())
        return;

    normalize_line_breaks(pasted);

    begin_undo_group(view.text, view.caret);
    insert_at_selection(view, view_of(pasted));
    end_undo_group(view.text);
    react_to_text_change(view);
    set_selection(view, view.anchor, view.caret);
}

// QWidgetTextControl::selectAll, which leaves the view where it is. QTextCursor lays out each line it moves from or
// to, here the caret's line, the first, and the last, and that can widen the document.
static void select_all(TextView &view)
{
    lay_out_if_needed(view, caret_line(view));
    lay_out_if_needed(view, 0);
    lay_out_if_needed(view, line_count(view) - 1);
    view.anchor = 0;
    view.caret = text_length(view);
    view.caret_x = -1;
    caret_moved(view);
}

// QWidgetTextControl::undo and redo: the caret goes where QTextDocument puts it.
static void undo_or_redo(TextView &view, bool redo)
{
    uint32_t caret = redo ? redo_text_change(view.text) : undo_text_change(view.text);
    if (caret != NO_POSITION)
        set_caret(view, caret, false);

    react_to_text_change(view);
}

//
// Typing rules.
//

// The typing rules' plan for a key, applied as one undo step that starts at the caret.
static bool apply_typing(TextView &view, TypingKey key, char16_t character)
{
    if (view.preedit_position >= 0)
        return false;

    TypingSource source = typing_source(view);
    uint32_t at = selection_start(view);
    LexState context = {};
    if (key == TypingKey::Character || key == TypingKey::Enter) {
        uint32_t line = line_of_offset(view.text, at);
        context = lex_state_before_line(view.text, line);
        std::u16string_view prefix = line_text(view.text, line).substr(0, at - line_start(view, line));
        tokenize_line(prefix, lexing_language(view), context, view.tokens, false);
    }

    std::optional<TypingPlan> plan = PlanTyping(source, view.text.language, context, view.indentation, view.typed_pairs,
                                                {at, size_t(selection_end(view) - at)}, key, character);
    if (!plan)
        return false;

    bool changed = plan->range.length != plan->text.size();
    for (size_t index = 0; !changed && index < plan->text.size(); ++index)
        changed = source.at(plan->range.location + index) != plan->text[index];

    bool reversed = view.caret < view.anchor;
    if (changed) {
        begin_undo_group(view.text, view.caret);
        replace_text(view.text, uint32_t(plan->range.location), uint32_t(plan->range.length), plan->text);
        end_undo_group(view.text);
        react_to_text_change(view);
    }

    RememberTypedPair(view.typed_pairs, plan->pair, plan->passedCloser, view.text.units.size());

    uint32_t first = uint32_t(plan->selection.location), last = uint32_t(plan->selection.end());
    set_selection(view, reversed ? last : first, reversed ? first : last);
    ensure_caret_visible(view);
    return true;
}

static bool handle_typing_key(TextView &view, const QKeyEvent &event, Qt::KeyboardModifiers modifiers, QStringView text)
{
    if (!(modifiers & ~Qt::ShiftModifier)) {
        switch (event.key()) {
            case Qt::Key_Return: case Qt::Key_Enter: return apply_typing(view, TypingKey::Enter, 0);
            case Qt::Key_Backspace: return apply_typing(view, TypingKey::Backspace, 0);
            case Qt::Key_Tab: return apply_typing(view, modifiers ? TypingKey::Backtab : TypingKey::Tab, 0);
            case Qt::Key_Backtab: return apply_typing(view, TypingKey::Backtab, 0);
            default: break;
        }
    }

    // Ctrl with Alt is AltGr on Windows, which types brackets on many keyboards.
    bool command = modifiers & (Qt::ControlModifier | Qt::MetaModifier);
    if ((modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) == (Qt::ControlModifier | Qt::AltModifier))
        command = false;

    return !command && text.size() == 1 && MayCompleteCharacter(text.front().unicode()) &&
           apply_typing(view, TypingKey::Character, text.front().unicode());
}

// Moves an offset in the text before a comment edit to the text after it.
static uint32_t offset_after_comment_edit(uint32_t at, uint32_t start, uint32_t end, std::u16string_view inserted)
{
    if (at == start && start == end)
        return at + uint32_t(CommentInsertionAdvance(inserted));
    if (at < start)
        return at;
    return at < end ? start : at + uint32_t(inserted.size()) - (end - start);
}

static void toggle_line_comment(TextView &view)
{
    if (composing_on(view, caret_line(view)))
        return;

    uint32_t first = line_of_offset(view.text, selection_start(view));
    uint32_t last = line_of_offset(view.text, selection_end(view) - (view.caret != view.anchor ? 1 : 0));
    CommentSyntax comments = CommentsInContext(view.text.language, lex_state_before_line(view.text, first));
    if (comments.line.empty() && (comments.open.empty() || comments.close.empty()))
        return;

    dismiss_completion(view);
    std::vector<CommentEdit> edits;
    ToggleCommentLines(typing_source(view), line_start(view, first), line_end(view, last), comments,
                       view.indentation.tabWidth, 1, edits);

    // The edits are at offsets in the original text, so each one moves by how much the edits before it changed.
    uint32_t anchor = view.anchor, caret = view.caret;
    int64_t delta = 0;
    begin_undo_group(view.text, view.caret);
    for (const CommentEdit &edit : edits) {
        uint32_t start = uint32_t(int64_t(edit.start) + delta), end = uint32_t(int64_t(edit.end) + delta);
        anchor = offset_after_comment_edit(anchor, start, end, edit.text);
        caret = offset_after_comment_edit(caret, start, end, edit.text);
        replace_text(view.text, start, end - start, edit.text);
        delta += int64_t(edit.text.size()) - int64_t(end - start);
    }
    end_undo_group(view.text);
    react_to_text_change(view);

    set_selection(view, anchor, caret);
}

//
// Bracket outlines.
//

// A character's extent in its line, from its leading edge to its trailing one, which are the other way round in
// right-to-left text.
static QRectF character_rect(const QTextLine &text_line, int column)
{
    qreal left = text_line.cursorToX(column, QTextLine::Leading);
    qreal right = text_line.cursorToX(column, QTextLine::Trailing);
    return QRectF(qMin(left, right), text_line.y(), std::abs(right - left), text_line.height());
}

// Where a bracket is drawn in the viewport, or an empty rectangle when it is out of view.
static QRectF bracket_rect(TextView &view, size_t at)
{
    if (at >= text_length(view))
        return QRectF();

    uint32_t line = line_of_offset(view.text, uint32_t(at));
    if (line < view.top_line)
        return QRectF();

    QPointF offset = content_offset(view);
    qreal top = line_top(view, line) + offset.y();
    if (top >= view.viewport()->height() || top + line_block_height(view, line) <= 0)
        return QRectF();

    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    QRectF rect = character_rect(layout.lineAt(0), int(at - line_start(view, line))).translated(offset.x(), top);
    return rect.intersects(view.viewport()->rect()) ? rect : QRectF();
}

static void paint_bracket_match(TextView &view, QPainter &painter, const QRegion &dirty)
{
    const Theme &theme = *view.theme;
    QColor color = qt_color(theme.dark || theme.blockCaretText ? theme.accents.bracketMatch :
                            theme.caret.value_or(theme.ink[size_t(Ink::Text)]));
    color.setAlphaF(theme.dark ? 0.48f : 0.38f);

    painter.setOpacity(1);
    painter.setClipRegion(dirty);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setPen(QPen(color, 0));
    painter.setBrush(Qt::NoBrush);

    size_t positions[2] = {view.brackets.at, view.brackets.mate};
    for (size_t at : positions) {
        QRectF rect = bracket_rect(view, at);
        if (!rect.isEmpty() && dirty.intersects(rect.toAlignedRect()))
            painter.drawRoundedRect(rect.adjusted(0.4, 1.1, -0.4, -1.1), 1.5, 1.5);
    }
}

//
// Completion.
//

static bool completion_character(std::u16string_view line, size_t at, bool lisp)
{
    char16_t unit = line[at];
    if (lisp)
        return is_lisp_symbol_char(unit);
    if (unit < 128)
        return is_ascii_identifier_char(unit);
    if (QChar::isHighSurrogate(unit) && at + 1 < line.size() && QChar::isLowSurrogate(line[at + 1]))
        return QChar::isLetterOrNumber(QChar::surrogateToUcs4(unit, line[at + 1]));
    if (QChar::isLowSurrogate(unit) && at > 0 && QChar::isHighSurrogate(line[at - 1]))
        return QChar::isLetterOrNumber(QChar::surrogateToUcs4(line[at - 1], unit));
    return QChar::isLetterOrNumber(unit);
}

static std::u16string_view completion_word(const CompletionWords &words, uint32_t index)
{
    uint32_t start = words.word_starts[index];
    return std::u16string_view(words.characters.data() + start, words.word_starts[index + 1] - start);
}

static const CompletionWords *sorting_words;

static int compare_completion_words(const void *a, const void *b)
{
    std::u16string_view left = completion_word(*sorting_words, *(const uint32_t *)a);
    std::u16string_view right = completion_word(*sorting_words, *(const uint32_t *)b);
    return left < right ? -1 : left > right ? 1 : 0;
}

static size_t hash_completion_word(std::u16string_view word)
{
    uint64_t hash = 14695981039346656037ull;
    for (char16_t unit : word)
        hash = (hash ^ unit) * 1099511628211ull;
    return size_t(hash);
}

// The slot for a word in an open-addressing table of word numbers plus one: its own slot, or the empty one where it
// would go. word_starts must end with the end of the last word.
static size_t completion_slot(const CompletionWords &words, const std::vector<uint32_t> &word_table, std::u16string_view word)
{
    size_t mask = word_table.size() - 1;
    size_t slot = hash_completion_word(word) & mask;
    while (word_table[slot] && completion_word(words, word_table[slot] - 1) != word)
        slot = (slot + 1) & mask;
    return slot;
}

// Collects the names on every line but the active one, without duplicates, and sorts them.
static void collect_completion_words(TextView &view, uint32_t active_line)
{
    CompletionWords &words = view.completion_words;
    words.line = active_line;
    words.line_start = line_start(view, active_line);
    words.line_end = line_end(view, active_line);
    words.line_count = line_count(view);
    words.language = view.text.language;
    words.characters.clear();
    words.word_starts.assign(1, 0);

    std::vector<uint32_t> word_table(1024, 0);
    bool plain = view.text.language == Language::Plain;
    for (uint32_t line = 0; line < line_count(view); ++line) {
        std::u16string_view units = line_text(view.text, line);
        LexState state = lex_state_before_line(view.text, line);
        if (line == active_line)
            words.incoming = state;
        tokenize_line(units, lexing_language(view), state, view.tokens);
        if (line == active_line) {
            words.outgoing = state;
            continue;
        }

        for (const Token &token : view.tokens) {
            if (!IsCompletionName(units, token, plain))
                continue;

            std::u16string_view name = units.substr(token.start, token.length);
            size_t slot = completion_slot(words, word_table, name);
            if (word_table[slot])
                continue;

            words.characters.append(name);
            words.word_starts.push_back(uint32_t(words.characters.size()));
            uint32_t count = uint32_t(words.word_starts.size() - 1);
            word_table[slot] = count;

            // The table doubles when it gets half full, and every word goes into its new slot.
            if (count * 2 >= word_table.size()) {
                word_table.assign(word_table.size() * 2, 0);
                for (uint32_t index = 0; index < count; ++index)
                    word_table[completion_slot(words, word_table, completion_word(words, index))] = index + 1;
            }
        }
    }

    uint32_t count = uint32_t(words.word_starts.size() - 1);
    words.word_order.resize(count);
    for (uint32_t index = 0; index < count; ++index)
        words.word_order[index] = index;

    sorting_words = &words;
    qsort(words.word_order.data(), count, sizeof(uint32_t), compare_completion_words);
}

// Typing inside the active line keeps the collected names; anything else collects them again next time.
static void completion_words_edited(TextView &view, uint32_t at, uint32_t removed, uint32_t added)
{
    CompletionWords &words = view.completion_words;
    if (words.line == NO_POSITION || !(removed || added))
        return;

    if (line_count(view) != words.line_count || at < words.line_start || at > words.line_end || removed > words.line_end - at)
        words.line = NO_POSITION;
    else
        words.line_end = words.line_end + added - removed;
}

// The words to offer for the prefix in [start, end) of a line: names from the text, merged with the language's
// keywords. None inside a string or comment.
static size_t complete_words(TextView &view, uint32_t line, uint32_t start, uint32_t end, std::u16string_view *matches,
                             size_t limit)
{
    CompletionWords &words = view.completion_words;
    Language language = view.text.language;
    if (words.line != line || words.language != language)
        collect_completion_words(view, line);

    std::u16string_view units = line_text(view.text, line);
    LexState state = words.incoming;
    tokenize_line(units, lexing_language(view), state, view.tokens);
    if (!lex_states_equal(state, words.outgoing)) {
        // A string, comment, or embedded language that changed here changes the names on later lines.
        collect_completion_words(view, line);
        state = words.incoming;
        tokenize_line(units, lexing_language(view), state, view.tokens);
    }

    if (end > 0) {
        for (const Token &token : view.tokens) {
            if (token.start > end - 1)
                break;
            if (end - 1 - token.start < token.length && IsNonCodeToken(token))
                return 0;
        }
    }

    std::u16string_view prefix = units.substr(start, end - start);
    std::u16string_view names[WordCompletionLimit];
    size_t count = 0;

    // The first collected word after the prefix, by binary search in the sorted order.
    uint32_t low = 0, high = uint32_t(words.word_order.size());
    while (low < high) {
        uint32_t middle = (low + high) / 2;
        if (completion_word(words, words.word_order[middle]) <= prefix)
            low = middle + 1;
        else
            high = middle;
    }

    for (uint32_t index = low; index < words.word_order.size() && count < WordCompletionLimit; ++index) {
        std::u16string_view name = completion_word(words, words.word_order[index]);
        if (!name.starts_with(prefix))
            break;
        names[count++] = name;
    }

    // Names on the line itself join in sorted order, keeping the list at most WordCompletionLimit long.
    bool plain = language == Language::Plain;
    for (const Token &token : view.tokens) {
        if (!IsCompletionName(units, token, plain))
            continue;

        std::u16string_view name = units.substr(token.start, token.length);
        if (name == prefix || !name.starts_with(prefix))
            continue;

        size_t row = 0;
        while (row < count && names[row] < name)
            row += 1;
        if (row == WordCompletionLimit || (row < count && names[row] == name))
            continue;

        if (count < WordCompletionLimit)
            count += 1;
        for (size_t move = count - 1; move > row; --move)
            names[move] = names[move - 1];
        names[row] = name;
    }

    if (language == Language::HTML || language == Language::Markdown || language == Language::PHP) {
        state = words.incoming;
        tokenize_line(units.substr(0, end), language, state, view.tokens, false);
        language = language_in_context(language, state);
    }

    return MergeCompletionWords(prefix, language, std::span<const std::u16string_view>(names, count),
                                std::span<std::u16string_view>(matches, limit));
}

static void dismiss_completion(TextView &view)
{
    if (view.completion)
        view.completion->hide();
}

static std::u16string_view completion_list_word(const CompletionList &list, int row)
{
    uint32_t start = list.word_starts[row];
    return std::u16string_view(list.characters.data() + start, list.word_starts[row + 1] - start);
}

static void show_completion_list(TextView &view, const std::u16string_view *words, size_t count, const QRect &anchor,
                                 int row_height, bool below)
{
    CompletionList &list = *view.completion;

    // The same word stays selected while the list changes under it.
    std::u16string selected_word;
    if (list.isVisible())
        selected_word = completion_list_word(list, list.selected);

    list.selected = 0;
    list.count = int(count);
    list.row_height = row_height;
    list.setFont(view.code_font);
    list.colors = EditorPopupColors(*view.theme);
    list.characters.clear();
    list.word_starts[0] = 0;

    int width = 140;
    QFontMetrics metrics(list.font());
    for (size_t row = 0; row < count; ++row) {
        if (words[row] == selected_word)
            list.selected = int(row);
        list.characters.append(words[row]);
        list.word_starts[row + 1] = uint32_t(list.characters.size());
        width = qMax(width, metrics.horizontalAdvance(qstring_of(words[row])) + 18);
    }

    QRect area = list.parentWidget()->rect().adjusted(2, 2, -2, -2);
    width = qMin(qMin(width, 300), area.width());
    int tall = list.count * list.row_height + 4;
    int x = qBound(area.left(), anchor.left(), area.right() - width + 1);
    list.setGeometry(x, below ? anchor.bottom() + 2 : anchor.top() - tall - 1, width, tall);
    list.show();
    list.raise();
    list.update();
}

// Offers completions for the word before the caret, once it is at least minimum long.
static void show_completions(TextView &view, int minimum)
{
    uint32_t line = caret_line(view);
    if (!view.hasFocus() || view.caret != view.anchor || composing_on(view, line)) {
        dismiss_completion(view);
        return;
    }

    std::u16string_view units = line_text(view.text, line);
    bool lisp = lisp_completion(view);
    uint32_t end = view.caret - line_start(view, line);
    uint32_t start = end;
    while (start > 0 && completion_character(units, start - 1, lisp))
        start -= 1;

    if (int(end - start) < minimum || (end < units.size() && completion_character(units, end, lisp)) ||
        (start < end && !lisp && units[start] < 128 && !is_ascii_identifier_start(units[start]))) {
        dismiss_completion(view);
        return;
    }

    QRect anchor = caret_rect_at(view, line_start(view, line) + start);
    QRect area = view.viewport()->rect().adjusted(2, 2, -2, -2);
    int row_height = qMax(18, view.fontMetrics().height() + 4);
    int below = (area.bottom() - anchor.bottom() - 5) / row_height;
    int above = (anchor.top() - area.top() - 5) / row_height;
    int limit = qMax(below, above);
    if (limit < 1 || area.width() < 48 || anchor.bottom() < area.top() || anchor.top() > area.bottom()) {
        dismiss_completion(view);
        return;
    }

    if (!view.completion)
        view.completion = new CompletionList(view.viewport());

    std::u16string_view matches[WordCompletionLimit];
    size_t count = complete_words(view, line, start, end, matches, qMin(size_t(limit), size_t(WordCompletionLimit)));
    if (count == 0) {
        dismiss_completion(view);
        return;
    }

    view.completion_start = line_start(view, line) + start;
    view.completion_end = view.caret;
    show_completion_list(view, matches, count, anchor, row_height, below >= int(count));
}

static void accept_completion(TextView &view, int row)
{
    std::u16string word(completion_list_word(*view.completion, row));
    dismiss_completion(view);
    if (view.caret != view.anchor || view.caret != view.completion_end)
        return;

    std::u16string_view suffix = std::u16string_view(word).substr(view.completion_end - view.completion_start);
    begin_undo_group(view.text, view.caret);
    insert_at_selection(view, suffix);
    end_undo_group(view.text);
    react_to_text_change(view);
    set_selection(view, view.caret, view.caret);
}

CompletionList::CompletionList(QWidget *viewport) : QWidget(viewport)
{
    count = selected = 0;
    row_height = 18;
    colors = {};
    setFocusPolicy(Qt::NoFocus);
    setAttribute(Qt::WA_OpaquePaintEvent);
    setAccessibleName(QStringLiteral("Completions"));
}

void CompletionList::paintEvent(QPaintEvent *)
{
    QPainter painter(this);
    painter.fillRect(rect(), qt_color(colors.paper));
    painter.setPen(qt_color(colors.border));
    painter.drawRect(rect().adjusted(0, 0, -1, -1));

    QFontMetrics metrics(font());
    for (int row = 0; row < count; ++row) {
        QRect row_rect(2, 2 + row * row_height, width() - 4, row_height);
        if (row == selected)
            painter.fillRect(row_rect, qt_color(colors.selection));

        painter.setPen(qt_color(row == selected ? colors.selectedText : colors.text));
        QRect label_rect = row_rect.adjusted(5, 0, -5, 0);
        painter.drawText(label_rect, Qt::AlignLeft | Qt::AlignVCenter | Qt::TextSingleLine,
                         metrics.elidedText(qstring_of(completion_list_word(*this, row)), Qt::ElideRight, label_rect.width()));
    }
}

void CompletionList::mousePressEvent(QMouseEvent *event)
{
    int y = int(event->position().y()) - 2;
    if (event->button() == Qt::LeftButton && y >= 0 && y / row_height < count)
        accept_completion(*static_cast<TextView *>(parentWidget()->parentWidget()), y / row_height);
}

//
// Page Up and Page Down.
//

// QPlainTextEditPrivate::pageUpDown: scrolls a page, then moves the caret line by line until it is back where it was
// in the viewport. A run of these presses keeps the caret's place from the first one.
static void page_up_down(TextView &view, bool up, bool keep_anchor, bool moves_caret)
{
    if (moves_caret) {
        ensure_caret_visible(view);
        if (!view.page_caret_y_valid)
            view.page_caret_y = line_top(view, caret_line(view)) - vertical_offset(view.top_line);
    }

    qreal last_y = view.page_caret_y;
    QRectF visible = QRectF(view.viewport()->rect()).translated(-content_offset(view));
    if (!up) {
        uint32_t line = view.top_line;
        qreal h = 0;
        int height = line_block_height(view, line);
        bool at_end = false;
        while (h + height <= visible.bottom()) {
            if (line + 1 == line_count(view)) {
                at_end = true;
                last_y = visible.bottom();
                break;
            }
            h += height;
            line += 1;
            height = line_block_height(view, line);
        }

        if (!at_end)
            set_top_line(view, line, 0);
    } else {
        visible.translate(0, -visible.height());
        uint32_t line = view.top_line;
        qreal h = 0;
        while (h >= visible.top()) {
            if (line == 0) {
                if (view.top_line == 0)
                    last_y = 0;
                break;
            }
            line -= 1;
            h -= line_block_height(view, line);
        }

        // The line found counts when its top reaches the page's top; otherwise the page starts at the next line.
        if (visible.top() - h > 0 && line + 1 < line_count(view) && line + 1 != view.top_line)
            line += 1;
        set_top_line(view, line, 0);
    }

    if (!moves_caret)
        return;

    // The caret's top is its line's top, since each line is one row.
    last_y += vertical_offset(view.top_line);
    CaretMove move = up ? CaretMove::Up : CaretMove::Down;
    bool moved;
    do {
        moved = move_caret(view, move, keep_anchor);
    } while (moved && (up ? line_top(view, caret_line(view)) > last_y : line_top(view, caret_line(view)) < last_y));

    // QWidgetTextControl::setTextCursor, keeping the remembered x, then the caret's place stays remembered.
    view.caret_on = view.focused;
    ensure_caret_visible(view);
    caret_moved(view);
    view.page_caret_y_valid = true;
}

//
// Keys, as QWidgetTextControl handled them.
//

struct KeyMove {
    QKeySequence::StandardKey key;
    CaretMove move;
    bool keep_anchor;
};

static const KeyMove KEY_MOVES[] = {
    {QKeySequence::MoveToNextChar, CaretMove::Right, false},
    {QKeySequence::MoveToPreviousChar, CaretMove::Left, false},
    {QKeySequence::SelectNextChar, CaretMove::Right, true},
    {QKeySequence::SelectPreviousChar, CaretMove::Left, true},
    {QKeySequence::SelectNextWord, CaretMove::WordRight, true},
    {QKeySequence::SelectPreviousWord, CaretMove::WordLeft, true},
    {QKeySequence::SelectStartOfLine, CaretMove::StartOfLine, true},
    {QKeySequence::SelectEndOfLine, CaretMove::EndOfLine, true},
    {QKeySequence::SelectStartOfBlock, CaretMove::StartOfLine, true},
    {QKeySequence::SelectEndOfBlock, CaretMove::EndOfLine, true},
    {QKeySequence::SelectStartOfDocument, CaretMove::Start, true},
    {QKeySequence::SelectEndOfDocument, CaretMove::End, true},
    {QKeySequence::SelectPreviousLine, CaretMove::Up, true},
    {QKeySequence::SelectNextLine, CaretMove::Down, true},
    {QKeySequence::MoveToNextWord, CaretMove::WordRight, false},
    {QKeySequence::MoveToPreviousWord, CaretMove::WordLeft, false},
    {QKeySequence::MoveToEndOfBlock, CaretMove::EndOfLine, false},
    {QKeySequence::MoveToStartOfBlock, CaretMove::StartOfLine, false},
    {QKeySequence::MoveToNextLine, CaretMove::Down, false},
    {QKeySequence::MoveToPreviousLine, CaretMove::Up, false},
    {QKeySequence::MoveToStartOfLine, CaretMove::StartOfLine, false},
    {QKeySequence::MoveToEndOfLine, CaretMove::EndOfLine, false},
    {QKeySequence::MoveToStartOfDocument, CaretMove::Start, false},
    {QKeySequence::MoveToEndOfDocument, CaretMove::End, false},
};

// QWidgetTextControlPrivate::cursorMoveKeyEvent: returns whether the key moves the caret.
static bool move_caret_for_key(TextView &view, QKeyEvent *event)
{
    const KeyMove *found = nullptr;
    for (const KeyMove &key_move : KEY_MOVES) {
        if (event->matches(key_move.key)) {
            found = &key_move;
            break;
        }
    }

    if (!found)
        return false;

    // Selecting up from the first line or down from the last goes to the end of the text.
    CaretMove move = found->move;
    uint32_t line = caret_line(view);
    if (found->key == QKeySequence::SelectPreviousLine && line == 0)
        move = CaretMove::Start;
    if (found->key == QKeySequence::SelectNextLine && line + 1 == line_count(view))
        move = CaretMove::End;

    move_caret(view, move, found->keep_anchor);
    ensure_caret_visible(view);
    caret_moved(view);
    return true;
}

// QInputControl::isAcceptableInput for a text edit.
static bool is_acceptable_input(const QKeyEvent &event)
{
    QString text = event.text();
    if (text.isEmpty())
        return false;

    QChar ch = text.at(0);
    if (ch.category() == QChar::Other_Format)
        return true;

    // Ctrl and Ctrl+Shift type nothing; Ctrl+Alt is AltGr.
    Qt::KeyboardModifiers modifiers = event.modifiers();
    if (modifiers == Qt::ControlModifier || modifiers == (Qt::ShiftModifier | Qt::ControlModifier))
        return false;

    return ch.isPrint() || ch.category() == QChar::Other_PrivateUse ||
           (ch.isHighSurrogate() && text.size() > 1 && text.at(1).isLowSurrogate()) || ch == u'\t';
}

// QPlainTextEdit::keyPressEvent and QWidgetTextControlPrivate::keyPressEvent.
static void handle_key(TextView &view, QKeyEvent *event)
{
    bool select_up = event->matches(QKeySequence::SelectPreviousPage), select_down = event->matches(QKeySequence::SelectNextPage);
    bool move_up = event->matches(QKeySequence::MoveToPreviousPage), move_down = event->matches(QKeySequence::MoveToNextPage);
    if (select_up || select_down || move_up || move_down) {
        page_up_down(view, select_up || move_up, select_up || select_down, true);
        event->accept();
        return;
    }

    if (event->matches(QKeySequence::SelectAll)) {
        select_all(view);
        event->accept();
        return;
    }

    if (event->matches(QKeySequence::Copy)) {
        copy_selection(view);
        event->accept();
        return;
    }

    if (!move_caret_for_key(view, event)) {
        Qt::KeyboardModifiers modifiers = event->modifiers();
        if (event->key() == Qt::Key_Backspace && !(modifiers & ~(Qt::ShiftModifier | Qt::GroupSwitchModifier))) {
            delete_previous_character(view);
        } else if (event->matches(QKeySequence::InsertParagraphSeparator)) {
            insert_at_selection(view, u"\n");
        } else if (event->matches(QKeySequence::InsertLineSeparator)) {
            insert_at_selection(view, u"\u2028");
        } else if (event->matches(QKeySequence::Undo)) {
            undo_or_redo(view, false);
        } else if (event->matches(QKeySequence::Redo)) {
            undo_or_redo(view, true);
        } else if (event->matches(QKeySequence::Cut)) {
            if (view.caret != view.anchor) {
                copy_selection(view);
                remove_selection(view);
            }
        } else if (event->matches(QKeySequence::Paste)) {
            paste(view);
        } else if (event->matches(QKeySequence::Delete)) {
            delete_next_character(view);
        } else if (event->matches(QKeySequence::Backspace)) {
            delete_previous_character(view);
        } else if (event->matches(QKeySequence::DeleteEndOfWord) || event->matches(QKeySequence::DeleteStartOfWord)) {
            if (view.caret == view.anchor)
                move_caret(view, event->matches(QKeySequence::DeleteEndOfWord) ? CaretMove::NextWord : CaretMove::PreviousWord, true);
            remove_selection(view);
        } else if (event->matches(QKeySequence::DeleteEndOfLine)) {
            // Qt selected one character right from the last one in the line, and to the line's end from anywhere else.
            if (view.caret + 1 == line_end(view, caret_line(view)))
                move_caret(view, CaretMove::Right, true);
            else
                move_caret(view, CaretMove::EndOfLine, true);
            remove_selection(view);
        } else if (is_acceptable_input(*event)) {
            if (view.overwrite && view.caret == view.anchor && view.caret != line_end(view, caret_line(view)))
                delete_next_character(view);
            insert_at_selection(view, view_of(event->text()));
        } else {
            event->ignore();
            return;
        }
        caret_moved(view);
    }

    event->accept();
    view.caret_on = true;
    ensure_caret_visible(view);
}

// QPlainTextEdit's undo(), redo(), cut(), copy(), paste(), and selectAll(), which the Edit menu calls. Unlike the
// keys for them, cutting and selecting all from the menu leave the view where it is.
static void run_edit_command(TextView &view, EditCommand command)
{
    switch (command) {
        case EditCommand::Undo:
        case EditCommand::Redo:
            undo_or_redo(view, command == EditCommand::Redo);
            ensure_caret_visible(view);
            caret_moved(view);
            break;

        case EditCommand::Cut:
            if (view.caret != view.anchor) {
                copy_selection(view);
                remove_selection(view);
                caret_moved(view);
            }
            break;

        case EditCommand::Copy:
            copy_selection(view);
            break;

        case EditCommand::Paste:
            paste(view);
            break;

        case EditCommand::SelectAll:
            select_all(view);
            break;
    }
}

//
// The mouse, as QWidgetTextControl handled it.
//

static void extend_word_selection(TextView &view, uint32_t position, qreal mouse_x)
{
    uint32_t word_first = qMin(view.word_selection_anchor, view.word_selection_caret);
    uint32_t word_last = qMax(view.word_selection_anchor, view.word_selection_caret);

    // Inside the double-clicked word, that word stays selected.
    if (position >= word_first && position <= word_last) {
        set_selection(view, view.word_selection_anchor, view.word_selection_caret);
        return;
    }

    uint32_t word_start, word_end;
    if (!find_word_start(view, position, word_start) || !find_word_end(view, word_start, word_end))
        return;

    uint32_t line = line_of_offset(view.text, word_start);
    if (line_of_offset(view.text, word_end) != line || word_end == word_start)
        return;

    QTextLayout layout(QString(), view.code_font, view.viewport());
    lay_out_line(view, line, layout);
    QTextLine text_line = layout.lineAt(0);
    qreal word_start_x = text_line.cursorToX(int(word_start - line_start(view, line)));
    qreal word_end_x = text_line.cursorToX(int(word_end - line_start(view, line)));
    if (mouse_x < word_start_x || mouse_x > word_end_x)
        return;

    // The selection keeps the double-clicked word on the side away from the mouse, and reaches the nearer end of the
    // word under it.
    view.anchor = position < view.word_selection_caret ? word_last : word_first;
    view.caret = mouse_x - word_start_x < word_end_x - mouse_x ? word_start : word_end;
    view.caret_x = -1;
}

static void extend_line_selection(TextView &view, uint32_t position)
{
    uint32_t line_first = qMin(view.line_selection_anchor, view.line_selection_caret);
    uint32_t line_last = qMax(view.line_selection_anchor, view.line_selection_caret);
    if (position >= line_first && position <= line_last) {
        set_selection(view, view.line_selection_anchor, view.line_selection_caret);
        return;
    }

    if (position < view.line_selection_caret) {
        view.anchor = line_last;
        view.caret = position;
        move_caret(view, CaretMove::StartOfLine, true);
    } else {
        view.anchor = line_first;
        view.caret = position;
        move_caret(view, CaretMove::EndOfLine, true);
        move_caret(view, CaretMove::NextCharacter, true);
    }
}

static void forget_click_selections(TextView &view)
{
    view.word_selection_anchor = view.word_selection_caret = NO_POSITION;
    view.line_selection_anchor = view.line_selection_caret = NO_POSITION;
}

static void commit_preedit(TextView &view);

static void handle_mouse_press(TextView &view, QMouseEvent *event)
{
    dismiss_completion(view);
    QPointF point = content_point(view, event->position());
    view.might_start_drag = false;
    if (event->button() != Qt::LeftButton)
        return;

    view.press_point = point;
    commit_preedit(view);

    if (view.triple_click.isActive() && (point - view.triple_click_point).manhattanLength() < QApplication::startDragDistance()) {
        move_caret(view, CaretMove::StartOfLine, false);
        move_caret(view, CaretMove::EndOfLine, true);
        move_caret(view, CaretMove::NextCharacter, true);
        view.line_selection_anchor = view.anchor;
        view.line_selection_caret = view.caret;
        view.triple_click.stop();
    } else {
        uint32_t position = hit_test(view, point);
        if (event->modifiers() == Qt::ShiftModifier) {
            if (view.line_selection_anchor != NO_POSITION)
                extend_line_selection(view, position);
            else if (view.word_selection_anchor != NO_POSITION)
                extend_word_selection(view, position, point.x());
            else
                set_caret(view, position, true);
        } else if (view.caret != view.anchor && position >= selection_start(view) && position <= selection_end(view)) {
            // A press on the selection could start dragging it, so the caret waits for the release.
            view.might_start_drag = true;
            return;
        } else {
            set_caret(view, position, false);
            forget_click_selections(view);
        }
    }

    ensure_caret_visible(view);
    caret_moved(view);
}

// QWidgetTextControlPrivate::startDrag: the selection goes where it's dropped, and moving it to another program
// takes it out of the text.
static void start_drag(TextView &view)
{
    QDrag *drag = new QDrag(view.viewport());
    drag->setMimeData(selection_mime_data(view));
    if (drag->exec(Qt::CopyAction | Qt::MoveAction, Qt::MoveAction) == Qt::MoveAction && drag->target() != view.viewport()) {
        remove_selection(view);
        caret_moved(view);
    }
}

static void handle_mouse_move(TextView &view, QMouseEvent *event)
{
    if (!(event->buttons() & Qt::LeftButton))
        return;

    QPointF point = content_point(view, event->position());
    if (view.might_start_drag) {
        if ((point - view.press_point).manhattanLength() > QApplication::startDragDistance()) {
            view.might_start_drag = false;
            start_drag(view);
        }
        return;
    }

    uint32_t position = hit_test(view, point);
    if (view.line_selection_anchor != NO_POSITION)
        extend_line_selection(view, position);
    else if (view.word_selection_anchor != NO_POSITION)
        extend_word_selection(view, position, point.x());
    else if (view.preedit_position < 0)
        set_caret(view, position, true);

    caret_moved(view);
}

static void handle_mouse_release(TextView &view, QMouseEvent *event)
{
    if (event->button() != Qt::LeftButton)
        return;

    if (view.might_start_drag) {
        set_caret(view, hit_test(view, content_point(view, event->position())), false);
        view.might_start_drag = false;
        caret_moved(view);
    }
}

static void handle_double_click(TextView &view, QMouseEvent *event)
{
    if (event->button() != Qt::LeftButton)
        return;

    view.might_start_drag = false;
    commit_preedit(view);
    QPointF point = content_point(view, event->position());
    set_caret(view, hit_test(view, point), false);
    if (!line_text(view.text, caret_line(view)).empty()) {
        // QTextCursor::select(WordUnderCursor).
        move_caret(view, CaretMove::StartOfWord, false);
        move_caret(view, CaretMove::EndOfWord, true);
    }

    view.word_selection_anchor = view.anchor;
    view.word_selection_caret = view.caret;
    view.triple_click_point = point;
    view.triple_click.start(QApplication::doubleClickInterval(), &view);
    caret_moved(view);
}

//
// Input methods.
//


// Ends composing, as QWidgetTextControlPrivate::commitPreedit does when a click comes in. Most input methods answer
// the commit with an event of their own; for one that doesn't, the composed text is dropped. Qt also kept the caret
// hidden then if the input method had hidden it; here it comes back.
static void commit_preedit(TextView &view)
{
    if (view.preedit_position < 0)
        return;

    QGuiApplication::inputMethod()->commit();
    if (view.preedit_position < 0)
        return;

    view.preedit_position = -1;
    view.preedit.clear();
    view.preedit_caret = 0;
    view.preedit_hides_caret = false;
    view.preedit_formats.clear();
    if (view.preedit_line < view.line_sizes.size())
        view.line_sizes[view.preedit_line].has_formats = false;
    note_line_changed(view, view.text.changed, view.preedit_line);
    react_to_text_change(view);
}

// Where an offset goes when [start, end) is replaced with inserted_length units elsewhere than at the caret, as a
// QTextCursor moves: one in the replaced range or at its start goes past the new text.
static uint32_t offset_after_edit(uint32_t at, uint32_t start, uint32_t end, uint32_t inserted_length)
{
    if (at < start)
        return at;
    return at <= end ? start + inserted_length : at + inserted_length - (end - start);
}

// QWidgetTextControlPrivate::inputMethodEvent.
static void handle_input_method(TextView &view, QInputMethodEvent *event)
{
    QString current_preedit = composing_on(view, caret_line(view)) ? view.preedit : QString();
    bool getting_input = !event->commitString().isEmpty() || event->preeditString() != current_preedit || event->replacementLength() > 0;
    if (!getting_input && event->attributes().isEmpty()) {
        event->ignore();
        return;
    }

    uint32_t old_caret = view.caret, old_anchor = view.anchor;
    begin_undo_group(view.text, view.caret);
    if (getting_input && view.caret != view.anchor) {
        uint32_t start = selection_start(view);
        begin_undo_group(view.text, NO_POSITION);
        replace_text(view.text, start, selection_end(view) - start, {});
        end_undo_group(view.text);
        set_caret(view, start, false);
    }

    // The committed text replaces the range the input method names around the caret, and the caret moves past it.
    if (!event->commitString().isEmpty() || event->replacementLength()) {
        uint32_t start = uint32_t(int64_t(view.caret) + event->replacementStart());
        uint32_t end = start + uint32_t(event->replacementLength());
        QString committed = event->commitString();
        normalize_line_breaks(committed);
        if (end > start || !committed.isEmpty())
            replace_text(view.text, start, end - start, view_of(committed));
        view.caret = offset_after_edit(view.caret, start, end, uint32_t(committed.size()));
        view.anchor = view.caret;
    }

    uint32_t line = caret_line(view);
    for (const QInputMethodEvent::Attribute &attribute : event->attributes()) {
        if (attribute.type == QInputMethodEvent::Selection) {
            uint32_t start = line_start(view, line) + uint32_t(attribute.start);
            view.anchor = start;
            view.caret = start + uint32_t(attribute.length);
        }
    }

    line = caret_line(view);
    int position = int(view.caret - line_start(view, line));
    if (getting_input) {
        view.preedit = event->preeditString();
        view.preedit_line = line;
        view.preedit_position = view.preedit.isEmpty() ? -1 : position;
    }

    // The input method's formats in order, filled out with the plain format where it gave none. A format that isn't
    // a character format leaves the plain one, as merging it into the plain format does in Qt.
    view.preedit_caret = int(event->preeditString().size());
    view.preedit_hides_caret = false;
    QList<QTextLayout::FormatRange> given;
    for (const QInputMethodEvent::Attribute &attribute : event->attributes()) {
        if (attribute.type == QInputMethodEvent::Cursor) {
            view.preedit_caret = attribute.start;
            view.preedit_hides_caret = !attribute.length;
        } else if (attribute.type == QInputMethodEvent::TextFormat) {
            QTextCharFormat format;
            format.merge(qvariant_cast<QTextFormat>(attribute.value).toCharFormat());
            qsizetype at = given.size();
            while (at > 0 && given[at - 1].start > attribute.start + position)
                at -= 1;
            given.insert(at, {attribute.start + position, attribute.length, format});
        }
    }

    int start = position, end = position + int(event->preeditString().size());
    QList<QTextLayout::FormatRange> formats;
    for (const QTextLayout::FormatRange &range : given) {
        if (range.start > start)
            formats.append({start, range.start - start, QTextCharFormat()});
        formats.append(range);
        start = range.start + range.length;
    }
    if (start < end)
        formats.append({start, end - start, QTextCharFormat()});

    // Setting the formats counts as a change to the line, so QSyntaxHighlighter colors it again, and keeps only the
    // formats inside the composed text.
    int preedit_start = view.preedit_position, preedit_end = preedit_start + int(view.preedit.size());
    view.preedit_formats.clear();
    for (const QTextLayout::FormatRange &range : formats) {
        if (composing_on(view, line) && range.start >= preedit_start && range.start + range.length <= preedit_end)
            view.preedit_formats.append(range);
    }
    if (line < view.line_sizes.size())
        view.line_sizes[line].has_formats = !formats.empty();
    note_line_changed(view, view.text.changed, line);

    end_undo_group(view.text);
    view.caret_x = -1;
    react_to_text_change(view);
    view.viewport()->update();
    if (view.caret != old_caret || view.anchor != old_anchor)
        caret_moved(view);
}

//
// Painting.
//

// The selections Qt drew under a line's text: the current line's background, the selected text, and in overwrite mode
// the character under the caret drawn as a block.
static QList<QTextLayout::FormatRange> line_selections(TextView &view, uint32_t line, bool caret_as_block)
{
    QList<QTextLayout::FormatRange> selections;
    uint32_t start = line_start(view, line);
    int length = int(line_text(view.text, line).size()) + 1;

    // The current line's background covers the line's layout, with its line break, or with any text being composed.
    int current_length = composing_on(view, line) ? length - 1 + int(view.preedit.size()) : length;

    if (line == caret_line(view)) {
        QTextLayout::FormatRange current = {0, current_length, QTextCharFormat()};
        current.format.setBackground(qt_color(view.theme->line));
        current.format.setProperty(QTextFormat::FullWidthSelection, true);
        selections.append(current);
    }

    int selected_start = int(selection_start(view)) - int(start);
    int selected_end = int(selection_end(view)) - int(start);
    if (selected_start < length && selected_end > 0 && selected_end > selected_start) {
        QPalette::ColorGroup group = view.focused ? QPalette::Active : QPalette::Inactive;
        QTextLayout::FormatRange selected = {selected_start, selected_end - selected_start, QTextCharFormat()};
        selected.format.setBackground(view.palette().brush(group, QPalette::Highlight));
        selected.format.setForeground(view.palette().brush(group, QPalette::HighlightedText));

        QStyleOption option;
        option.initFrom(view.viewport());
        if (view.style()->styleHint(QStyle::SH_RichText_FullWidthSelection, &option, view.viewport()))
            selected.format.setProperty(QTextFormat::FullWidthSelection, true);
        selections.append(selected);
    }

    if (caret_as_block) {
        QTextLayout::FormatRange block = {int(view.caret - start), 1, QTextCharFormat()};
        block.format.setForeground(view.palette().base());
        block.format.setBackground(view.palette().text());
        selections.append(block);
    }

    return selections;
}

// QWidgetTextControl::getPaintContext's cursor position: the caret's position, below -1 for a place in text being
// composed, or -1 for no caret.
static int painted_caret_position(const TextView &view)
{
    if (!view.caret_on || view.preedit_hides_caret)
        return -1;
    if (view.preedit_caret != 0 && view.preedit_position >= 0)
        return -(view.preedit_caret + 2);
    return int(view.caret);
}

// Strokes the text again on both sides and in place, faintly, to make it look heavier.
static void paint_text_weight(TextView &view, QPainter &painter, const QPaintEvent &event)
{
    painter.setPen(view.palette().text().color());
    QRegion ink_clip = event.region();
    if (painted_caret_position(view) >= 0)
        ink_clip -= caret_rect_at(view, view.caret);
    painter.setClipRegion(ink_clip);

    // The sideways spread stops growing past 30 so narrow glyphs stay distinct; the rest goes into the glyph edges.
    qreal extra_weight = qMax(0, view.appearance.stroke - 30) / 70.0;
    qreal side_opacity = qMin(view.appearance.stroke, 30) / 100.0 + 0.10 * extra_weight;
    qreal center_opacity = 0.90 * extra_weight;
    QPointF side(0.5 / view.viewport()->devicePixelRatioF(), 0);
    QRect dirty = event.rect();

    QPointF offset = content_offset(view);
    for (uint32_t line = view.top_line; line < line_count(view) && offset.y() <= dirty.bottom(); ++line) {
        int height = line_block_height(view, line);
        if (offset.y() + height >= dirty.top() && !composing_on(view, line)) {
            QTextLayout layout(QString(), view.code_font, view.viewport());
            lay_out_line(view, line, layout);

            // Selected text keeps its own color in the extra strokes.
            QList<QTextLayout::FormatRange> selections;
            int start = int(line_start(view, line));
            int selected_start = qMax(0, int(selection_start(view)) - start);
            int selected_end = qMin(int(line_text(view.text, line).size()), int(selection_end(view)) - start);
            if (selected_start < selected_end) {
                QPalette::ColorGroup group = view.focused ? QPalette::Active : QPalette::Inactive;
                QTextCharFormat format;
                format.setForeground(view.palette().brush(group, QPalette::HighlightedText));
                selections.append({selected_start, selected_end - selected_start, format});
            }

            painter.setOpacity(side_opacity);
            layout.draw(&painter, offset - side, selections, dirty);
            layout.draw(&painter, offset + side, selections, dirty);
            if (center_opacity > 0) {
                painter.setOpacity(center_opacity);
                layout.draw(&painter, offset, selections, dirty);
            }
        }
        offset.ry() += height;
    }
}

// QPlainTextEdit::paintEvent, then the stroke weight and bracket outlines the editor added.
static void paint_text(TextView &view, QPaintEvent *event)
{
    QPainter painter(view.viewport());
    QPointF offset = content_offset(view);
    QRect dirty = event->rect();
    QRect viewport = view.viewport()->rect();

    // The full-width line background stops at the right margin.
    painter.setBrushOrigin(offset);
    int max_x = int(offset.x() + qMax(qreal(viewport.width()), view.widest_width) - DOCUMENT_MARGIN + CARET_WIDTH);
    dirty.setRight(qMin(dirty.right(), max_x));
    painter.setClipRect(dirty);
    painter.setPen(view.palette().text().color());

    int caret_position = painted_caret_position(view);
    for (uint32_t line = view.top_line; line < line_count(view); ++line) {
        // A line not laid out yet is laid out once, both to measure it and to draw it.
        QTextLayout layout(QString(), view.code_font, view.viewport());
        bool laid_out = view.line_sizes[line].generation != view.layout_generation;
        if (laid_out) {
            lay_out_line(view, line, layout);
            note_line_laid_out(view, line, layout);
        }

        int height = line_block_height(view, line);
        if (offset.y() + height >= dirty.top() && offset.y() <= dirty.bottom()) {
            if (!laid_out)
                lay_out_line(view, line, layout);

            int start = int(line_start(view, line)), end = int(line_end(view, line));
            bool draw_caret = caret_position >= start && caret_position <= end;
            bool caret_as_block = draw_caret && view.overwrite && caret_position != end;
            layout.draw(&painter, offset, line_selections(view, line, caret_as_block), dirty);

            if ((draw_caret && !caret_as_block) || (caret_position < -1 && composing_on(view, line))) {
                int at = caret_position < -1 ? layout.preeditAreaPosition() - (caret_position + 2) : caret_position - start;
                layout.drawCursor(&painter, offset, at, CARET_WIDTH);
            }
        }

        offset.ry() += height;
        if (offset.y() > viewport.height())
            break;
    }

    if (!view.appearance.stroke && view.brackets.mate == typingNotFound)
        return;

    QPainter extra(view.viewport());
    if (view.appearance.stroke)
        paint_text_weight(view, extra, *event);
    if (view.brackets.mate != typingNotFound)
        paint_bracket_match(view, extra, event->region());
}

TextViewGutter::TextViewGutter(QWidget *view) : QWidget(view)
{
    setAttribute(Qt::WA_OpaquePaintEvent);
}

void TextViewGutter::paintEvent(QPaintEvent *event)
{
    TextView &view = *static_cast<TextView *>(parentWidget());
    QRect dirty = event->rect();
    QPainter painter(this);
    painter.fillRect(dirty, qt_color(view.theme->gutter));
    painter.setPen(qt_color(view.theme->rule));
    painter.drawLine(width() - 1, dirty.top(), width() - 1, dirty.bottom());
    painter.setFont(view.code_font);

    // Each line's number sits beside its text, from the top line down.
    uint32_t active = caret_line(view);
    qreal top = content_offset(view).y();
    for (uint32_t line = view.top_line; line < line_count(view) && top <= dirty.bottom(); ++line) {
        int height = line_block_height(view, line);
        if (top + height >= dirty.top()) {
            QRectF row(0, top, width() - 1, height);
            if (line == active)
                painter.fillRect(row, qt_color(view.theme->line));
            painter.setPen(qt_color(line == active ? view.theme->activeNumber : view.theme->lineNumber));
            painter.drawText(row.adjusted(0, 0, -8, 0), Qt::AlignRight | Qt::AlignVCenter, QString::number(line + 1));
        }
        top += height;
    }
}

//
// Fonts, colors, and language.
//

static void place_gutter(TextView &view)
{
    QRect area = view.contentsRect();
    view.gutter->setGeometry(area.left(), area.top(), view.viewportMargins().left(), view.viewport()->height());
}

static void update_gutter_width(TextView &view)
{
    int digits = qMax(3, int(QString::number(line_count(view)).size()));
    int width = 16 + digits * view.fontMetrics().horizontalAdvance(u'9');
    if (view.viewportMargins().left() != width)
        view.setViewportMargins(width, 0, 0, 0);
    place_gutter(view);
}

static void apply_colors(TextView &view)
{
    QPalette colors = view.palette();
    colors.setColor(QPalette::Base, qt_color(view.theme->paper));
    Col32 text = view.theme->ink[size_t(Ink::Text)];
    colors.setColor(QPalette::Text, adjust_ink(text, view.theme->paper, view.appearance));
    colors.setColor(QPalette::Highlight, qt_color(view.theme->selection));
    colors.setColor(QPalette::HighlightedText, adjust_ink(text, view.theme->selection, view.appearance));
    view.setPalette(colors);
    view.gutter->update();
}

static void apply_appearance(TextView &view, const Theme &theme, const TextAppearance &appearance)
{
    bool colors_changed = view.theme != &theme || view.appearance.saturation != appearance.saturation ||
                          view.appearance.brightness != appearance.brightness || view.appearance.contrast != appearance.contrast;
    // Another theme can make comments or types italic, so every line is measured again when it is next needed.
    if (view.theme != &theme)
        view.layout_generation += 1;

    view.theme = &theme;
    view.appearance = appearance;
    if (colors_changed) {
        dismiss_completion(view);
        build_formats(view);
        apply_colors(view);
    }
    view.viewport()->update();
}

// The editor's font: Consolas on Windows, with only vertical hinting so small sizes keep their fractional advances.
static void apply_font_size(TextView &view, int pixels)
{
    dismiss_completion(view);
    QFont code = QFontDatabase::systemFont(QFontDatabase::FixedFont);
#ifdef Q_OS_WIN
    code.setFamily(QStringLiteral("Consolas"));
    code.setHintingPreference(QFont::PreferVerticalHinting);
#endif
    code.setStyleHint(QFont::Monospace);
    code.setPixelSize(pixels);

    view.code_font = code;
    view.setFont(code);
    view.text_option = QTextOption();
    view.text_option.setWrapMode(QTextOption::NoWrap);
    view.text_option.setTabStopDistance(QFontMetricsF(code).horizontalAdvance(u' ') * qreal(view.indentation.tabWidth));
    view.layout_generation += 1;
    update_gutter_width(view);
    view.viewport()->update();
}

// The language from the file's name, or from the beginning of its text when the name doesn't say.
static Language detect_text_language(const TextView &view, std::u16string_view units)
{
    QByteArray beginning = qstring_of(units.substr(0, LANGUAGE_PREFIX_LENGTH)).toUtf8();
    return detect_language(std::string_view(view.language_path.constData(), size_t(view.language_path.size())),
                           std::string_view(beginning.constData(), size_t(beginning.size())));
}

static Language detect_view_language(const TextView &view)
{
    return detect_text_language(view, std::u16string_view(view.text.units.data(), view.text.units.size()));
}

static bool set_view_language(TextView &view, Language language)
{
    if (view.text.language == language)
        return false;

    set_text_language(view.text, language);
    build_formats(view);
    note_all_line_formats(view);
    view.typed_pairs.clear();

    // QSyntaxHighlighter colors every line again with a QTextCursor that starts on the first line, which lays that
    // line out, and then every line is laid out again when it is next needed.
    lay_out_if_needed(view, 0);
    view.layout_generation += 1;
    dismiss_completion(view);
    refresh_bracket_match(view);
    view.viewport()->update();
    notify_window(view, VIEW_LANGUAGE_CHANGED);
    return true;
}

// Chooses the language from the picker, or detects it again when mode is Language::Count.
static void set_language_mode(TextView &view, Language mode)
{
    view.mode = mode;
    set_view_language(view, mode == Language::Count ? detect_view_language(view) : mode);
}

// QPlainTextEdit::centerCursor.
static void center_caret(TextView &view)
{
    ensure_visible(view, view.caret, true, true);
}

//
// Screen readers.
//

// The span of text around an offset that a screen reader asks for, as QAccessible::qAccessibleTextBoundaryHelper
// finds it with QTextCursor: a character, a word, a sentence, a line, or all of the text.
static void text_boundaries(TextView &view, uint32_t offset, QAccessible::TextBoundaryType type, uint32_t &start, uint32_t &end)
{
    uint32_t line = line_of_offset(view.text, offset);
    switch (type) {
        case QAccessible::CharBoundary:
            start = offset;
            end = next_position(view, offset, QTextLayout::SkipCharacters);
            break;

        case QAccessible::WordBoundary:
            find_word_start(view, offset, start);
            find_word_end(view, start, end);
            break;

        // Qt finds sentences inside the line with QTextBoundaryFinder.
        case QAccessible::SentenceBoundary: {
            start = line_start(view, line);
            end = line_end(view, line);
            QString units = qstring_of(line_text(view.text, line));
            QTextBoundaryFinder sentences(QTextBoundaryFinder::Sentence, units);
            sentences.setPosition(int(offset - start));
            int previous = int(offset - start);
            if (!(sentences.boundaryReasons() & QTextBoundaryFinder::StartOfItem))
                previous = int(sentences.toPreviousBoundary());
            int next = int(sentences.toNextBoundary());
            if (next != -1)
                end = start + uint32_t(next);
            if (previous != -1)
                start += uint32_t(previous);
            break;
        }

        case QAccessible::LineBoundary:
        case QAccessible::ParagraphBoundary:
            start = line_start(view, line);
            end = line_end(view, line);
            break;

        case QAccessible::NoBoundary:
            start = 0;
            end = text_length(view);
            break;
    }
}

// QWidgetTextControl's answers to screen readers, through the interfaces Qt's QAccessiblePlainTextEdit implemented.
// Offsets are the text's UTF-16 offsets. Qt's character rectangles left out where the line was, and its point lookups
// always failed; these give real places.
class TextViewAccessible final : public QAccessibleWidgetV2, public QAccessibleTextInterface, public QAccessibleEditableTextInterface {
public:
    explicit TextViewAccessible(TextView *view) : QAccessibleWidgetV2(view, QAccessible::EditableText) {}

    TextView &view() const
    {
        return *static_cast<TextView *>(widget());
    }

    // An offset Qt's QTextCursor would reject stays at the caret.
    uint32_t valid_offset(int offset) const
    {
        return offset >= 0 && uint32_t(offset) <= text_length(view()) ? uint32_t(offset) : view().caret;
    }

    void *interface_cast(QAccessible::InterfaceType type) override
    {
        if (type == QAccessible::TextInterface)
            return static_cast<QAccessibleTextInterface *>(this);
        if (type == QAccessible::EditableTextInterface)
            return static_cast<QAccessibleEditableTextInterface *>(this);
        return QAccessibleWidgetV2::interface_cast(type);
    }

    QAccessible::State state() const override
    {
        QAccessible::State state = QAccessibleWidgetV2::state();
        state.selectableText = true;
        state.multiLine = true;
        state.editable = true;
        return state;
    }

    // The value is the text as QPlainTextEdit::toPlainText gave it, with line separators and no-break spaces plain.
    QString text(QAccessible::Text type) const override
    {
        if (type != QAccessible::Value)
            return QAccessibleWidgetV2::text(type);

        QString value = text(0, characterCount());
        value.replace(QChar::LineSeparator, u'\n');
        value.replace(QChar::Nbsp, u' ');
        return value;
    }

    // Replacing the value is one edit that can be undone, where Qt's setPlainText dropped the undo history.
    void setText(QAccessible::Text type, const QString &units) override
    {
        if (type == QAccessible::Value)
            replaceText(0, characterCount(), units);
        else
            QAccessibleWidgetV2::setText(type, units);
    }

    void selection(int index, int *start, int *end) const override
    {
        *start = *end = 0;
        if (index == 0 && view().caret != view().anchor) {
            *start = int(selection_start(view()));
            *end = int(selection_end(view()));
        }
    }

    int selectionCount() const override
    {
        return view().caret != view().anchor ? 1 : 0;
    }

    void addSelection(int start, int end) override
    {
        setSelection(0, start, end);
    }

    void removeSelection(int index) override
    {
        if (index == 0)
            set_selection(view(), view().caret, view().caret);
    }

    void setSelection(int index, int start, int end) override
    {
        if (index == 0)
            set_selection(view(), valid_offset(start), valid_offset(end));
    }

    int cursorPosition() const override
    {
        return int(view().caret);
    }

    void setCursorPosition(int position) override
    {
        set_selection(view(), valid_offset(position), valid_offset(position));
    }

    QString text(int start, int end) const override
    {
        uint32_t first = valid_offset(start), last = valid_offset(end);
        if (first > last)
            std::swap(first, last);
        return qstring_of(std::u16string_view(view().text.units.data() + first, last - first));
    }

    QString textAtOffset(int offset, QAccessible::TextBoundaryType type, int *start, int *end) const override
    {
        uint32_t first, last;
        text_boundaries(view(), valid_offset(offset), type, first, last);
        *start = int(first);
        *end = int(last);
        return text(*start, *end);
    }

    // The span before the one at offset: Qt stepped back a character at a time from that span's start until the span
    // there ended at offset or before.
    QString textBeforeOffset(int offset, QAccessible::TextBoundaryType type, int *start, int *end) const override
    {
        *start = *end = -1;
        uint32_t at = valid_offset(offset), first, last;
        text_boundaries(view(), at, type, first, last);
        uint32_t position = first;
        while (last > at) {
            if (position == 0)
                return QString();
            position = previous_position(view(), position, QTextLayout::SkipCharacters);
            text_boundaries(view(), position, type, first, last);
        }
        *start = int(first);
        *end = int(last);
        return text(*start, *end);
    }

    // The span after the one at offset, stepping forward a character at a time from that span's end.
    QString textAfterOffset(int offset, QAccessible::TextBoundaryType type, int *start, int *end) const override
    {
        *start = *end = -1;
        uint32_t at = valid_offset(offset), first, last;
        text_boundaries(view(), at, type, first, last);
        uint32_t position = last;
        while (first <= at) {
            if (position == text_length(view()))
                return QString();
            position = next_position(view(), position, QTextLayout::SkipCharacters);
            text_boundaries(view(), position, type, first, last);
        }
        *start = int(first);
        *end = int(last);
        return text(*start, *end);
    }

    int characterCount() const override
    {
        return int(text_length(view()));
    }

    // The character's place on the screen. The end of a line is as wide as the caret.
    QRect characterRect(int offset) const override
    {
        if (offset < 0 || uint32_t(offset) > text_length(view()))
            return QRect();

        TextView &text_view = view();
        uint32_t line = line_of_offset(text_view.text, uint32_t(offset));
        QTextLayout layout(QString(), text_view.code_font, text_view.viewport());
        lay_out_line(text_view, line, layout);
        QRectF rect = character_rect(layout.lineAt(0), int(uint32_t(offset) - line_start(text_view, line)));
        rect.setWidth(qMax(rect.width(), qreal(CARET_WIDTH)));
        rect.translate(content_offset(text_view) + QPointF(0, line_top(text_view, line)));
        return rect.toAlignedRect().translated(text_view.viewport()->mapToGlobal(QPoint(0, 0)));
    }

    int offsetAtPoint(const QPoint &point) const override
    {
        QPoint inside = view().viewport()->mapFromGlobal(point);
        if (!view().viewport()->rect().contains(inside))
            return -1;
        return int(hit_test(view(), content_point(view(), inside)));
    }

    void scrollToSubstring(int start, int) override
    {
        ensure_visible(view(), valid_offset(start), false, false);
    }

    // IAccessible2 text attributes, the same for a whole line: the editor's font, and the line's direction.
    QString attributes(int offset, int *start, int *end) const override
    {
        int count = characterCount();
        if (offset == -2)
            offset = cursorPosition();
        if (offset == -1 || offset == count)
            offset = count - 1;
        if (offset < 0 || offset > count) {
            *start = *end = -1;
            return QString();
        }

        TextView &text_view = view();
        uint32_t line = line_of_offset(text_view.text, uint32_t(offset));
        *start = int(line_start(text_view, line));
        *end = int(line_end(text_view, line)) + 1;

        int points = qRound(text_view.code_font.pixelSize() * 72.0 / text_view.logicalDpiY());
        QString attributes = QStringLiteral("font-family:\"%1\";font-size:%2pt;font-weight:normal;font-style:normal;"
                                            "text-line-through-type:none;")
                                 .arg(text_view.code_font.family())
                                 .arg(points);
        if (line_is_right_to_left(text_view, line))
            attributes += QStringLiteral("writing-mode:rl;");
        return attributes + QStringLiteral("text-position:baseline;");
    }

    // Edits elsewhere than at the caret, one undo step each, with the caret and anchor moving with the text.
    void replaceText(int start, int end, const QString &units) override
    {
        TextView &text_view = view();
        uint32_t first = valid_offset(start), last = valid_offset(end);
        if (first > last)
            std::swap(first, last);

        QString inserted = units;
        normalize_line_breaks(inserted);
        begin_undo_group(text_view.text, NO_POSITION);
        replace_text(text_view.text, first, last - first, view_of(inserted));
        end_undo_group(text_view.text);

        text_view.caret = offset_after_edit(text_view.caret, first, last, uint32_t(inserted.size()));
        text_view.anchor = offset_after_edit(text_view.anchor, first, last, uint32_t(inserted.size()));
        text_view.caret_x = -1;
        react_to_text_change(text_view);
        caret_moved(text_view);
    }

    void deleteText(int start, int end) override
    {
        replaceText(start, end, QString());
    }

    void insertText(int offset, const QString &units) override
    {
        replaceText(offset, offset, units);
    }
};

// QAccessible asks for an object's interface by class name. TextView has no meta-object of its own, so it's asked
// for as a QAbstractScrollArea.
static QAccessibleInterface *text_view_accessible(const QString &class_name, QObject *object)
{
    if (class_name != QLatin1StringView("QAbstractScrollArea"))
        return nullptr;

    TextView *view = dynamic_cast<TextView *>(object);
    return view ? new TextViewAccessible(view) : nullptr;
}

//
// The widget's events.
//

TextView::TextView(const QString &view_name, const QString &units, const QString &source_path, const Theme &view_theme,
                   int font_size, const TextAppearance &view_appearance)
{
    name = view_name;
    language_path = QDir::fromNativeSeparators(source_path.isEmpty() ? view_name : source_path).toUtf8();
    detects_from_text = detect_language(std::string_view(language_path.constData(), size_t(language_path.size()))) == Language::Plain;
    mode = Language::Count;

    caret = anchor = 0;
    caret_x = -1;
    overwrite = false;
    caret_on = false;
    focused = false;

    top_line = 0;
    layout_generation = 1;
    layout_width = 0;
    widest_width = 0;
    widest_line = 0;
    holding_size_changes = false;
    page_caret_y_valid = false;
    page_caret_y = 0;
    reported_caret = reported_anchor = 0;

    might_start_drag = false;
    forget_click_selections(*this);

    preedit_line = 0;
    preedit_position = -1;
    preedit_caret = 0;
    preedit_hides_caret = false;

    theme = &view_theme;
    appearance = view_appearance;

    completion = nullptr;
    completion_words.line = NO_POSITION;
    completion_start = completion_end = 0;
    editing_completion = false;

    notify = nullptr;
    notify_context = nullptr;
    text_version = 0;
    was_modified = false;

    gutter = new TextViewGutter(this);
    QAccessible::installFactory(text_view_accessible);
    setFrameStyle(QFrame::NoFrame);
    setFocusPolicy(Qt::StrongFocus);
    setAttribute(Qt::WA_InputMethodEnabled);
    setAttribute(Qt::WA_KeyCompression);
    setInputMethodHints(Qt::ImhMultiLine);
    viewport()->setCursor(Qt::IBeamCursor);
    verticalScrollBar()->setSingleStep(1);
    horizontalScrollBar()->setSingleStep(QGuiApplicationPrivate::platformTheme()->themeHint(QPlatformTheme::ScrollSingleStepDistance).toInt());
    QObject::connect(verticalScrollBar(), &QAbstractSlider::actionTriggered, this, &TextView::scroll_bar_action);

    // The language comes from the text as it was given, line endings and all, as the old editor detected it.
    QString normalized = units;
    normalize_line_breaks(normalized);
    set_text(text, view_of(normalized), detect_text_language(*this, view_of(units)));
    line_sizes.assign(line_count(*this), LineSize{0, 0, 0, 0});
    note_all_line_formats(*this);

    // Qt set the scroll bars' ranges when the text went in, so the vertical one is there before the editor is shown.
    adjust_scrollbars(*this);

    indentation = DetectTypingIndentation(typing_source(*this));
    apply_font_size(*this, font_size);
    build_formats(*this);

    // The highlighter's first pass started with a QTextCursor on the first line, which laid it out in the editor's
    // font. That can widen the document, and the horizontal scroll bar then shows from the start. The pass itself
    // laid the line out again later, when it had colors to give it.
    lay_out_if_needed(*this, 0);
    if (line_sizes[0].has_formats)
        line_sizes[0].generation = layout_generation - 1;

    apply_colors(*this);
    refresh_bracket_match(*this);
}

bool TextView::event(QEvent *event)
{
    // The editor takes the keys it edits with before the window's shortcuts get them.
    if (event->type() == QEvent::ShortcutOverride && QInputControl::isCommonTextEditShortcut(static_cast<QKeyEvent *>(event)))
        event->accept();

    return QAbstractScrollArea::event(event);
}

void TextView::paintEvent(QPaintEvent *event)
{
    paint_text(*this, event);
}

void TextView::resizeEvent(QResizeEvent *event)
{
    dismiss_completion(*this);
    if (event->oldSize().width() != event->size().width())
        lay_out_again(*this, viewport()->width());
    adjust_scrollbars(*this);
    place_gutter(*this);
}

void TextView::showEvent(QShowEvent *)
{
    adjust_scrollbars(*this);
}

void TextView::scrollContentsBy(int dx, int)
{
    if (!editing_completion)
        dismiss_completion(*this);
    set_top_line(*this, uint32_t(verticalScrollBar()->value()), dx);
    update_input_method(*this);
}

void TextView::keyPressEvent(QKeyEvent *event)
{
    bool open = completion && completion->isVisible();
    Qt::KeyboardModifiers modifiers = event->modifiers() & (Qt::ShiftModifier | Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);
    if (open && !modifiers) {
        switch (event->key()) {
            case Qt::Key_Up: case Qt::Key_Down:
                completion->selected = (completion->selected + completion->count + (event->key() == Qt::Key_Up ? -1 : 1)) % completion->count;
                completion->update();
                return;
            case Qt::Key_Tab: case Qt::Key_Return: case Qt::Key_Enter:
                accept_completion(*this, completion->selected);
                return;
            case Qt::Key_Escape:
                dismiss_completion(*this);
                return;
            default:
                break;
        }
    }

    // Typing a name character opens or narrows the completion list, and Backspace narrows it back.
    QString typed = event->text();
    bool word = !(modifiers & (Qt::ControlModifier | Qt::MetaModifier)) &&
                (typed.size() == 1 || (typed.size() == 2 && typed[0].isHighSurrogate() && typed[1].isLowSurrogate())) &&
                completion_character(view_of(typed), 0, lisp_completion(*this));
    bool refine = open && !modifiers && event->key() == Qt::Key_Backspace;
    if (!word && !refine)
        dismiss_completion(*this);

    uint32_t version = text_version;
    editing_completion = word || refine;
    if (handle_typing_key(*this, *event, modifiers, typed))
        event->accept();
    else
        handle_key(*this, event);
    editing_completion = false;

    if ((word || refine) && version != text_version)
        show_completions(*this, open ? 1 : 2);
}

void TextView::inputMethodEvent(QInputMethodEvent *event)
{
    dismiss_completion(*this);
    QString committed = event->commitString();
    if (committed.size() == 1 && MayCompleteCharacter(committed.front().unicode()) && event->preeditString().isEmpty() &&
        !event->replacementStart() && !event->replacementLength() &&
        apply_typing(*this, TypingKey::Character, committed.front().unicode())) {
        event->accept();
        return;
    }

    handle_input_method(*this, event);
    if (!event->preeditString().isEmpty() || !event->commitString().isEmpty() || !event->attributes().isEmpty())
        ensure_caret_visible(*this);
    if (!event->commitString().isEmpty() && event->preeditString().isEmpty())
        show_completions(*this, 2);
    update_input_method(*this);
}

// QPlainTextEdit::inputMethodQuery and QWidgetTextControl's. Rectangles are in the widget's coordinates.
QVariant TextView::inputMethodQuery(Qt::InputMethodQuery query) const
{
    // Measuring the caret lays its line out, which Qt's const query did as well.
    TextView &view = const_cast<TextView &>(*this);
    uint32_t line = caret_line(view);
    uint32_t start = line_start(view, line);
    QPointF offset = content_offset(view) + QPointF(viewport()->pos());
    const char16_t *units = view.text.units.data();

    switch (query) {
        case Qt::ImEnabled:
            return isEnabled();
        case Qt::ImHints:
        case Qt::ImInputItemClipRectangle:
            return QWidget::inputMethodQuery(query);
        case Qt::ImReadOnly:
            return false;
        case Qt::ImCursorRectangle:
            return caret_rect_in_content(view, view.caret).translated(offset);
        case Qt::ImAnchorRectangle:
            return caret_rect_in_content(view, view.anchor).translated(offset);
        case Qt::ImFont:
            return view.code_font;
        case Qt::ImCursorPosition:
            return int(view.caret - start);
        case Qt::ImAnchorPosition:
            return int(view.anchor) - int(start);
        case Qt::ImAbsolutePosition:
            return int(view.caret);
        case Qt::ImSurroundingText:
            return qstring_of(line_text(view.text, line));
        case Qt::ImCurrentSelection:
            return qstring_of(std::u16string_view(units + selection_start(view), selection_end(view) - selection_start(view)));

        // Qt gives 1024 units or more around the caret, in whole lines.
        case Qt::ImTextBeforeCursor: {
            uint32_t first = line;
            while (first > 0 && view.caret - line_start(view, first) < 1024)
                first -= 1;
            return qstring_of(std::u16string_view(units + line_start(view, first), view.caret - line_start(view, first)));
        }
        case Qt::ImTextAfterCursor: {
            uint32_t last = line;
            while (last + 1 < line_count(view) && line_end(view, last) - view.caret < 1024)
                last += 1;
            return qstring_of(std::u16string_view(units + view.caret, line_end(view, last) - view.caret));
        }

        default:
            return QVariant();
    }
}

void TextView::mousePressEvent(QMouseEvent *event)
{
    handle_mouse_press(*this, event);
}

// Dragging a selection past the viewport's edge starts scrolling, as QPlainTextEdit's autoScrollTimer did.
void TextView::mouseMoveEvent(QMouseEvent *event)
{
    QPoint point = event->position().toPoint();
    handle_mouse_move(*this, event);
    if (!(event->buttons() & Qt::LeftButton) || event->source() != Qt::MouseEventNotSynthesized)
        return;

    if (viewport()->rect().contains(point))
        auto_scroll.stop();
    else if (!auto_scroll.isActive())
        auto_scroll.start(100, this);
}

void TextView::mouseReleaseEvent(QMouseEvent *event)
{
    handle_mouse_release(*this, event);
    if (event->source() == Qt::MouseEventNotSynthesized && auto_scroll.isActive()) {
        auto_scroll.stop();
        ensure_caret_visible(*this);
    }
}

void TextView::mouseDoubleClickEvent(QMouseEvent *event)
{
    handle_double_click(*this, event);
}

void TextView::focusInEvent(QFocusEvent *event)
{
    QAbstractScrollArea::focusInEvent(event);
    focused = true;
    caret_on = true;
    int flash = QGuiApplication::styleHints()->cursorFlashTime();
    if (flash >= 2)
        caret_blink.start(flash / 2, this);
    viewport()->update();
}

void TextView::focusOutEvent(QFocusEvent *event)
{
    QAbstractScrollArea::focusOutEvent(event);
    dismiss_completion(*this);
    focused = false;
    caret_on = false;
    caret_blink.stop();
    viewport()->update();
}

void TextView::timerEvent(QTimerEvent *event)
{
    if (event->timerId() == caret_blink.timerId()) {
        caret_on = !caret_on;
        if (caret != anchor)
            caret_on = caret_on && style()->styleHint(QStyle::SH_BlinkCursorWhenTextSelected);
        repaint_caret(*this);
    } else if (event->timerId() == auto_scroll.timerId()) {
        // The selection follows the mouse, and the view scrolls a step toward it, faster the farther out it is.
        QRect visible = viewport()->rect();
        QPoint global = QCursor::pos();
        QPoint point = viewport()->mapFromGlobal(global);
        QMouseEvent move(QEvent::MouseMove, point, viewport()->mapTo(viewport()->topLevelWidget(), point), global, Qt::LeftButton,
                         Qt::LeftButton, QGuiApplication::keyboardModifiers());
        mouseMoveEvent(&move);

        int delta_y = qMax(point.y() - visible.top(), visible.bottom() - point.y()) - visible.height();
        int delta_x = qMax(point.x() - visible.left(), visible.right() - point.x()) - visible.width();
        int delta = qMax(delta_x, delta_y);
        if (delta >= 0) {
            delta = qMax(delta, 7);
            auto_scroll.start(4900 / (delta * delta), this);
            if (delta_y > 0)
                verticalScrollBar()->triggerAction(point.y() < visible.center().y() ? QAbstractSlider::SliderSingleStepSub :
                                                                                      QAbstractSlider::SliderSingleStepAdd);
            if (delta_x > 0)
                horizontalScrollBar()->triggerAction(point.x() < visible.center().x() ? QAbstractSlider::SliderSingleStepSub :
                                                                                        QAbstractSlider::SliderSingleStepAdd);
        }
    } else if (event->timerId() == triple_click.timerId()) {
        triple_click.stop();
    } else if (event->timerId() == language_check.timerId()) {
        language_check.stop();
        if (mode == Language::Count) {
            // Qt's detection read the beginning with a QTextCursor, which laid out the line it stopped on.
            lay_out_if_needed(*this, line_of_offset(text, qMin(text_length(*this), uint32_t(LANGUAGE_PREFIX_LENGTH))));
            set_view_language(*this, detect_view_language(*this));
        }
    }
}

// Clicking the scroll bar above or below its handle turns a page, as Page Up and Page Down do, but leaves the caret.
void TextView::scroll_bar_action(int action)
{
    if (action == QAbstractSlider::SliderPageStepAdd || action == QAbstractSlider::SliderPageStepSub)
        page_up_down(*this, action == QAbstractSlider::SliderPageStepSub, false, false);
}

// Tab types, so it never moves the focus away.
bool TextView::focusNextPrevChild(bool)
{
    return false;
}

// QWidgetTextControl::createStandardContextMenu, in its words. The window's Edit menu has the shortcuts, so this menu
// shows none, as Qt's didn't when another action had them.
void TextView::contextMenuEvent(QContextMenuEvent *event)
{
    bool selected = caret != anchor;
    const QMimeData *clipboard = QApplication::clipboard()->mimeData();

    QMenu menu(this);
    QAction *undo = menu.addAction(QCoreApplication::translate("QWidgetTextControl", "&Undo"));
    undo->setEnabled(text.undo_position > 0);
    QAction *redo = menu.addAction(QCoreApplication::translate("QWidgetTextControl", "&Redo"));
    redo->setEnabled(text.undo_position < text.undo_records.size());
    menu.addSeparator();
    QAction *cut = menu.addAction(QCoreApplication::translate("QWidgetTextControl", "Cu&t"));
    cut->setEnabled(selected);
    QAction *copy = menu.addAction(QCoreApplication::translate("QWidgetTextControl", "&Copy"));
    copy->setEnabled(selected);
    QAction *paste_action = menu.addAction(QCoreApplication::translate("QWidgetTextControl", "&Paste"));
    paste_action->setEnabled(clipboard && clipboard->hasText() && !clipboard->text().isEmpty());
    QAction *remove = menu.addAction(QCoreApplication::translate("QWidgetTextControl", "Delete"));
    remove->setEnabled(selected);
    menu.addSeparator();
    QAction *select = menu.addAction(QCoreApplication::translate("QWidgetTextControl", "Select All"));
    select->setEnabled(!text.units.empty());

    QAction *chosen = menu.exec(event->globalPos());
    if (chosen == undo)
        run_edit_command(*this, EditCommand::Undo);
    else if (chosen == redo)
        run_edit_command(*this, EditCommand::Redo);
    else if (chosen == cut)
        run_edit_command(*this, EditCommand::Cut);
    else if (chosen == copy)
        run_edit_command(*this, EditCommand::Copy);
    else if (chosen == paste_action)
        run_edit_command(*this, EditCommand::Paste);
    else if (chosen == select)
        run_edit_command(*this, EditCommand::SelectAll);
    else if (chosen == remove && caret != anchor) {
        remove_selection(*this);
        caret_moved(*this);
    }
}
