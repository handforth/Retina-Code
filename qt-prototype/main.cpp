#include <QAbstractListModel>
#include <QApplication>
#include <QCloseEvent>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QDropEvent>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFocusEvent>
#include <QFontDatabase>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QIcon>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListView>
#include <QMainWindow>
#include <QMenuBar>
#include <QMessageBox>
#include <QMimeData>
#include <QMouseEvent>
#include <QPaintEvent>
#include <QPainter>
#include <QPalette>
#include <QPlainTextEdit>
#include <QPointer>
#include <QProxyStyle>
#include <QPushButton>
#include <QRegion>
#include <QSaveFile>
#include <QScrollBar>
#include <QSettings>
#include <QShortcut>
#include <QSlider>
#include <QStandardPaths>
#include <QStatusBar>
#include <QStringDecoder>
#include <QStyle>
#include <QStyleHints>
#include <QStyleOption>
#include <QSyntaxHighlighter>
#include <QTabBar>
#include <QTabWidget>
#include <QTextBlock>
#include <QTextEdit>
#include <QTextLayout>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>
#include <QWheelEvent>

#include <algorithm>
#include <filesystem>
#include <iterator>
#include <utility>

#ifdef Q_OS_WIN
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <psapi.h>
#endif

#include "Comments.hpp"
#include "OfflineWords.h"
#include "PopupColors.h"
#include "RunPane.h"
#include "Typing.hpp"
#undef rgb
#undef rgba

namespace {

class DocumentTabStyle final : public QProxyStyle {
public:
    DocumentTabStyle() : QProxyStyle(QStringLiteral("Fusion")) {}

    void drawControl(ControlElement element, const QStyleOption *option, QPainter *painter,
                     const QWidget *widget) const override
    {
        if (element != CE_TabBarTabShape || !documentBar(widget)) {
            QProxyStyle::drawControl(element, option, painter, widget);
            return;
        }

        const QRect tab = option->rect;
        const bool selected = option->state.testFlag(State_Selected);
        const bool hovered = option->state.testFlag(State_MouseOver);
        QColor tint = option->palette.color(QPalette::WindowText);
        painter->fillRect(tab, option->palette.brush(QPalette::Window));
        tint.setAlpha(selected ? 20 : hovered ? 15 : 7);
        painter->fillRect(tab, tint);
        tint.setAlpha(13);
        painter->fillRect(QRect(tab.left(), tab.top(), tab.width(), 1), tint);
        tint.setAlpha(22);
        painter->fillRect(QRect(tab.right(), tab.top(), 1, tab.height()), tint);
        painter->fillRect(QRect(tab.left(), tab.bottom(), tab.width(), 1), tint);
        if (selected) {
            painter->fillRect(QRect(tab.left(), tab.bottom() - 1, tab.width() - 1, 2),
                              option->palette.brush(QPalette::Highlight));
        }
    }

    void drawPrimitive(PrimitiveElement element, const QStyleOption *option, QPainter *painter,
                       const QWidget *widget) const override
    {
        const auto *bar = (element == PE_FrameTabBarBase || element == PE_IndicatorTabClose)
            ? documentBar(widget) : nullptr;
        if (bar && element == PE_FrameTabBarBase) {
            QColor tint = option->palette.color(QPalette::WindowText);
            tint.setAlpha(13);
            painter->fillRect(QRect(0, 0, bar->width(), 1), tint);
            tint.setAlpha(22);
            painter->fillRect(QRect(option->rect.left(), option->rect.bottom(), option->rect.width(), 1), tint);
        } else if (bar && element == PE_IndicatorTabClose) {
            const QRectF bounds(option->rect);
            painter->save();
            painter->setRenderHint(QPainter::Antialiasing);
            painter->setPen(Qt::NoPen);
            QColor tint = option->palette.color(QPalette::WindowText);
            const bool hovered = option->state.testAnyFlags(State_MouseOver | State_Sunken);
            if (hovered) {
                tint.setAlpha(option->state.testFlag(State_Sunken) ? 50 : 29);
                painter->setBrush(tint);
                painter->drawRoundedRect(bounds.adjusted(1, 1, -1, -1), 2, 2);
            }
            tint.setAlpha(hovered || option->state.testFlag(State_Selected) ? 205 : 132);
            // One filled shape gives both diagonals the same coverage at their intersection.
            static constexpr QPointF glyph[] = {
                {-3, -2}, {-2, -3}, {0, -1}, {2, -3}, {3, -2}, {1, 0},
                {3, 2}, {2, 3}, {0, 1}, {-2, 3}, {-3, 2}, {-1, 0}
            };
            // The center can lie between device pixels, including at 100% scaling.
            painter->translate(bounds.center());
            painter->setBrush(tint);
            painter->drawPolygon(glyph, std::size(glyph));
            painter->restore();
        } else {
            QProxyStyle::drawPrimitive(element, option, painter, widget);
        }
    }

    QRect subElementRect(SubElement element, const QStyleOption *option, const QWidget *widget) const override
    {
        QRect rect = QProxyStyle::subElementRect(element, option, widget);
        if (element == SE_TabBarTabRightButton && rect.isValid() && documentBar(widget))
            rect.translate(option->direction == Qt::RightToLeft ? -2 : 2, 0);
        return rect;
    }

    int pixelMetric(PixelMetric metric, const QStyleOption *option, const QWidget *widget) const override
    {
        if (metric == PM_TabBarTabHSpace || metric == PM_TabBarTabVSpace || metric == PM_TabCloseIndicatorWidth ||
            metric == PM_TabCloseIndicatorHeight || metric == PM_TabBarBaseOverlap) {
            if (documentBar(widget)) {
                // Fusion uses half this spacing to inset tab labels and buttons.
                if (metric == PM_TabBarTabHSpace)
                    return 14;
                if (metric == PM_TabBarTabVSpace)
                    return 8;
                if (metric == PM_TabBarBaseOverlap)
                    return 1;
                return 18;
            }
        }
        return QProxyStyle::pixelMetric(metric, option, widget);
    }

private:
    static const QTabBar *documentBar(const QWidget *widget)
    {
        auto *bar = qobject_cast<const QTabBar *>(widget);
        if (!bar && widget)
            bar = qobject_cast<const QTabBar *>(widget->parentWidget());
        return bar && bar->documentMode() && bar->shape() == QTabBar::RoundedNorth ? bar : nullptr;
    }
};

void useDarkWidgets(QApplication &app)
{
    app.setStyle(new DocumentTabStyle);
    app.styleHints()->setColorScheme(Qt::ColorScheme::Dark);
    if (app.palette().color(QPalette::Window).lightness() < 128)
        return;

    // Some platform plugins cannot provide a dark palette on request.
    QPalette palette(QColor(53, 53, 53), QColor(35, 35, 35));
    palette.setColor(QPalette::Base, QColor(27, 27, 27));
    palette.setColor(QPalette::AlternateBase, QColor(41, 41, 41));
    palette.setColor(QPalette::Highlight, QColor(48, 98, 155));
    palette.setColor(QPalette::HighlightedText, Qt::white);
    app.setPalette(palette);
}

constexpr auto sampleMain = R"rs(// Edit this file, or open one of your own with Ctrl+O.
mod sample;

use sample::Entry;

fn summarize(entries: &[Entry]) -> (usize, u32) {
    let active = entries.iter().filter(|entry| entry.enabled);
    active.fold((0, 0), |(count, total), entry| {
        (count + 1, total + entry.score)
    })
}

fn main() {
    let entries = [
        Entry::new("café", 21, true),
        Entry::new("naïve", 34, false),
        Entry::new("日本語 🍦", 55, true),
    ];

    for entry in &entries {
        println!("{:>4}  {}", entry.score, entry.name);
    }

    let (count, total) = summarize(&entries);
    println!("{count} active entries, {total} points");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_only_enabled_entries() {
        let entries = [Entry::new("first", 8, true), Entry::new("second", 13, false)];
        assert_eq!(summarize(&entries), (1, 8));
    }
}
)rs";

constexpr auto sampleModule = R"rs(#[derive(Debug)]
pub struct Entry {
    pub name: &'static str,
    pub score: u32,
    pub enabled: bool,
}

impl Entry {
    pub const fn new(name: &'static str, score: u32, enabled: bool) -> Self {
        Self { name, score, enabled }
    }
}
)rs";

QColor qtColor(Col32 color)
{
    return {ColorRed(color), ColorGreen(color), ColorBlue(color), ColorAlpha(color)};
}

struct TextAppearance {
    int stroke = 0;
    int saturation = 100;
    int brightness = 100;
    int contrast = 100;
};

struct AppearanceControl {
    const char *label;
    const char *key;
    int TextAppearance::*value;
    int minimum, maximum;
};

constexpr AppearanceControl appearanceControls[] = {
    {"Stroke weight", "stroke", &TextAppearance::stroke, 0, 100},
    {"Saturation", "saturation", &TextAppearance::saturation, 0, 160},
    {"Brightness", "brightness", &TextAppearance::brightness, 65, 135},
    {"Contrast", "contrast", &TextAppearance::contrast, 65, 135},
};

QColor adjustInk(Col32 ink, Col32 paper, const TextAppearance &appearance)
{
    if (appearance.saturation == 100 && appearance.brightness == 100 && appearance.contrast == 100)
        return qtColor(ink);

    const auto luminance = [](Col32 color) {
        return 0.2126 * ColorRed(color) + 0.7152 * ColorGreen(color) + 0.0722 * ColorBlue(color);
    };
    const double gray = luminance(ink);
    const double background = luminance(paper);
    const double contrast = appearance.contrast / 100.0;
    const double brightness = appearance.brightness / 100.0;
    const double saturation = appearance.saturation / 100.0;
    const double adjustedGray = (background + (gray - background) * contrast) * brightness;
    const auto channel = [=](uint8_t value) {
        return qBound(0, qRound(adjustedGray + (value - gray) * saturation * brightness), 255);
    };
    return {channel(ColorRed(ink)), channel(ColorGreen(ink)), channel(ColorBlue(ink)), ColorAlpha(ink)};
}

constexpr int languagePrefixLength = 512;

std::string_view utf8View(const QByteArray &text)
{
    return {text.constData(), size_t(text.size())};
}

constexpr char utf8Bom[] = "\xef\xbb\xbf";

enum class LineEnding : uint8_t { LF, CRLF, CR };

struct FileFormat {
    LineEnding newline = LineEnding::LF;
    bool bom = false;
};

FileFormat formatOf(std::string_view bytes)
{
    FileFormat format;
    format.bom = bytes.starts_with(utf8Bom);
    const auto first = bytes.find_first_of("\r\n");
    if (first != bytes.npos && bytes[first] == '\r')
        format.newline = bytes.substr(first, 2) == "\r\n" ? LineEnding::CRLF : LineEnding::CR;
    return format;
}

Language detectSourceLanguage(const QByteArray &path, QStringView text)
{
    const QByteArray beginning = text.first(std::min<qsizetype>(languagePrefixLength, text.size())).toUtf8();
    return DetectLanguage(utf8View(path), utf8View(beginning));
}

constexpr int typingRoleProperty = QTextFormat::UserProperty + 1;

const QTextCharFormat &plainTypingFormat(Ink ink)
{
    static const auto formats = [] {
        std::array<QTextCharFormat, 3> entries;
        entries[0].setProperty(typingRoleProperty, int(Ink::String));
        entries[1].setProperty(typingRoleProperty, int(Ink::Comment));
        entries[2].setProperty(typingRoleProperty, int(Ink::Escape));
        return entries;
    }();
    return formats[ink == Ink::Comment ? 1 : ink == Ink::Escape ? 2 : 0];
}

class SourceHighlighter final : public QSyntaxHighlighter {
public:
    explicit SourceHighlighter(Language language)
        : QSyntaxHighlighter(static_cast<QObject *>(nullptr)), language_(language) {}

    Language language() const { return language_; }

    const LexState &stateBefore(const QTextBlock &block) const { return state(block.previous().userState()); }
    void typingContext(const QTextBlock &block, std::u16string_view prefix, LexState &context)
    {
        context = stateBefore(block);
        TokenizeLine(prefix, language_ == Language::Plain ? Language::C : language_, context, tokens_, false);
    }

    bool setLanguage(Language language)
    {
        if (language_ == language)
            return false;
        language_ = language;
        states_.clear();
        freeStates_.clear();
        recentStates_.fill(0);
        nextRecent_ = 0;
        reclaimAt_ = 128;
        for (auto block = document()->begin(); block.isValid(); block = block.next())
            block.setUserState(0);
        rehighlight();
        return true;
    }

    void applyTheme(const Theme &theme, const TextAppearance &appearance)
    {
        ++paletteRevision_;
        for (size_t i = 0; i < formats_.size(); ++i) {
            formats_[i].setForeground(adjustInk(theme.ink[i], theme.paper, appearance));
            formats_[i].setProperty(QTextFormat::UserProperty, paletteRevision_);
        }
        formats_[size_t(Ink::Comment)].setFontItalic(theme.italicComments);
        formats_[size_t(Ink::Type)].setFontItalic(theme.italicTypes);
        for (size_t i = 0; i < formats_.size(); ++i) {
            nonCodeFormats_[i] = formats_[i];
            nonCodeFormats_[i].setProperty(typingRoleProperty, int(TypingRole(Ink(i))));
        }
    }

    bool mayHaveStaleColors() const
    {
        return paletteRevision_ > 1 && language_ != Language::Plain;
    }

    void refreshBlockColors(const QTextBlock &block)
    {
        auto *layout = block.layout();
        if (!layout->preeditAreaText().isEmpty())
            return;
        // The existing syntax formats carry the palette revision for the whole block.
        const auto formats = layout->formats();
        if (!formats.isEmpty() && formats.first().format.property(QTextFormat::UserProperty).toUInt() != paletteRevision_)
            rehighlightBlock(block);
    }

protected:
    void highlightBlock(const QString &text) override
    {
        const bool plain = language_ == Language::Plain;
        const int previous = previousBlockState();
        scratch_ = state(previous);
        TokenizeLine(utf16View(text), plain ? Language::C : language_, scratch_, tokens_);
        for (const auto &token : tokens_) {
            if (IsNonCodeToken(token))
                setFormat(int(token.start), int(token.length),
                          plain ? plainTypingFormat(token.ink) : nonCodeFormats_[size_t(token.ink)]);
            else if (!plain)
                setFormat(int(token.start), int(token.length), formats_[size_t(token.ink)]);
        }
        setCurrentBlockState(stateId(currentBlockState(), previous));
    }

private:
    const LexState &state(int id) const
    {
        static const LexState initial;
        return id > 0 ? states_[size_t(id - 1)] : initial;
    }

    int stateId(int old, int previous)
    {
        // Preserve the old ID when its state matches so Qt can stop the incremental pass.
        if (scratch_ == state(0))
            return 0;
        if (old > 0 && scratch_ == state(old))
            return old;
        if (previous > 0 && scratch_ == state(previous))
            return previous;
        for (int id : recentStates_) {
            if (id > 0 && scratch_ == state(id))
                return id;
        }

        if (freeStates_.empty() && states_.size() >= reclaimAt_)
            reclaimStates();
        int id;
        if (freeStates_.empty()) {
            states_.push_back(scratch_);
            id = int(states_.size());
        } else {
            id = freeStates_.back();
            freeStates_.pop_back();
            states_[size_t(id - 1)] = scratch_;
        }
        recentStates_[nextRecent_] = id;
        nextRecent_ = (nextRecent_ + 1) % recentStates_.size();
        return id;
    }

    void reclaimStates()
    {
        // Only reuse unreferenced IDs. Live IDs stay stable during Qt's incremental pass.
        std::vector<uint8_t> used(states_.size());
        for (auto block = document()->begin(); block.isValid(); block = block.next()) {
            if (const int id = block.userState(); id > 0)
                used[size_t(id - 1)] = true;
        }
        for (size_t i = 0; i < states_.size(); ++i) {
            if (!used[i]) {
                states_[i] = LexState{};
                freeStates_.push_back(int(i + 1));
            }
        }
        recentStates_.fill(0);
        nextRecent_ = 0;
        reclaimAt_ = states_.size() + std::max<size_t>(128, states_.size() / 2);
    }

    Language language_;
    std::array<QTextCharFormat, size_t(Ink::Count)> formats_, nonCodeFormats_;
    std::vector<Token> tokens_;
    LexState scratch_;
    std::vector<LexState> states_;
    std::vector<int> freeStates_;
    std::array<int, 16> recentStates_{};
    size_t nextRecent_ = 0;
    size_t reclaimAt_ = 128;
    uint paletteRevision_ = 0;
};

struct QtTypingText {
    explicit QtTypingText(QTextDocument &doc) : document(doc) {}

    TypingSource source()
    {
        return {this, size_t(document.characterCount() - 1),
            [](void *context, size_t at) -> char16_t {
                auto &text = *static_cast<QtTypingText *>(context);
                text.load(at);
                const auto offset = at - size_t(text.block.position());
                if (offset == size_t(text.block.length() - 1))
                    return u'\n';
                return text.characters.isNull() ? text.document.characterAt(int(at)).unicode() :
                       text.characters[qsizetype(offset)].unicode();
            },
            [](void *context, size_t at) {
                auto &text = *static_cast<QtTypingText *>(context);
                text.load(at);
                const auto start = size_t(text.block.position());
                const auto end = start + size_t(text.block.length() - 1);
                return CommentLine{start, end, end + size_t(text.block.next().isValid())};
            },
            [](void *context, size_t at) { return static_cast<QtTypingText *>(context)->syntax(at); },
            [](void *context, std::u16string &result, TypingRange range) {
                auto &text = *static_cast<QtTypingText *>(context);
                const auto end = range.end();
                for (auto at = range.location; at < end;) {
                    text.load(at);
                    const auto start = size_t(text.block.position());
                    const auto contents = text.view();
                    const auto next = std::min(end, start + contents.size());
                    result += contents.substr(at - start, next - at);
                    at = next;
                    if (at < end) {
                        result += u'\n';
                        ++at;
                    }
                }
            },
            [](void *context, TypingRange range, TypingSearch search, bool backwards) {
                return static_cast<QtTypingText *>(context)->find(range, search, backwards);
            },
            [](void *context, size_t at) {
                auto &text = *static_cast<QtTypingText *>(context);
                text.load(at);
                const auto start = text.block.position();
                const auto next = text.block.layout()->nextCursorPosition(int(at) - start, QTextLayout::SkipCharacters);
                return std::max(at + 1, size_t(start + next));
            },
            [](char16_t ch) { return QChar(ch).isLetterOrNumber() || QChar(ch).isMark(); }};
    }

    void load(size_t at)
    {
        if (block.isValid()) {
            const auto start = size_t(block.position());
            const auto next = start + size_t(block.length());
            if (at >= start && at < next)
                return;
            if (at == next)
                block = block.next();
            else if (at + 1 == start)
                block = block.previous();
            else
                block = document.findBlock(int(at));
        } else {
            block = document.findBlock(int(at));
        }
        characters = QString();
    }

    std::u16string_view view()
    {
        if (characters.isNull())
            characters = block.text();
        return utf16View(characters);
    }

    TypingSpan syntax(size_t at)
    {
        load(at);
        const int offset = int(at) - block.position();
        const auto formats = block.layout()->formats();
        const auto next = std::ranges::upper_bound(formats, offset, {}, &QTextLayout::FormatRange::start);
        if (next != formats.begin()) {
            const auto &format = *std::prev(next);
            if (offset < format.start + format.length && format.format.hasProperty(typingRoleProperty))
                return {{size_t(block.position() + format.start), size_t(format.length)},
                        Ink(format.format.intProperty(typingRoleProperty))};
        }
        const int end = next == formats.end() ? block.length() : next->start;
        return {{at, size_t(end - offset)}, Ink::Text};
    }

    size_t find(TypingRange range, TypingSearch search, bool backwards)
    {
        const auto choices = TypingSearchCharacters(search);
        auto first = range.location;
        auto last = range.end();
        while (first < last) {
            load(backwards ? last - 1 : first);
            const auto start = size_t(block.position());
            const auto from = std::max(first, start) - start;
            const auto contents = view();
            const auto end = std::min(last - start, contents.size());
            const auto slice = contents.substr(from, end - from);
            size_t at = typingNotFound;
            if (search == TypingSearch::NonBlank)
                at = backwards ? slice.find_last_not_of(choices) : slice.find_first_not_of(choices);
            else
                at = backwards ? slice.find_last_of(choices) : slice.find_first_of(choices);
            if (at != typingNotFound)
                return start + from + at;
            if (backwards)
                last = start;
            else
                first = start + size_t(block.length());
        }
        return typingNotFound;
    }

    QTextDocument &document;
    QTextBlock block;
    QString characters;
};

bool completionCharacter(QStringView text, qsizetype at, bool lisp)
{
    const QChar unit = text[at];
    if (lisp)
        return IsLispSymbolPart(unit.unicode());
    if (unit.unicode() < 128)
        return IsASCIIIdentifierPart(unit.unicode());
    if (unit.isHighSurrogate() && at + 1 < text.size() && text[at + 1].isLowSurrogate())
        return QChar::isLetterOrNumber(QChar::surrogateToUcs4(unit, text[at + 1]));
    if (unit.isLowSurrogate() && at > 0 && text[at - 1].isHighSurrogate())
        return QChar::isLetterOrNumber(QChar::surrogateToUcs4(text[at - 1], unit));
    return unit.isLetterOrNumber();
}

class CodeEdit final : public QPlainTextEdit {
    class Gutter final : public QWidget {
    public:
        explicit Gutter(CodeEdit &editor) : QWidget(&editor), editor_(editor) {}

    protected:
        void paintEvent(QPaintEvent *event) override { editor_.paintGutter(event->rect()); }

    private:
        CodeEdit &editor_;
    };

    class CompletionPopup final : public QWidget {
    public:
        explicit CompletionPopup(CodeEdit &editor) : QWidget(editor.viewport()), editor_(editor)
        {
            setFocusPolicy(Qt::NoFocus);
            setAttribute(Qt::WA_OpaquePaintEvent);
            setAccessibleName(QStringLiteral("Completions"));
        }

        void present(std::span<const std::u16string_view> words, const QRect &anchor, int rows, bool below)
        {
            const auto previous = isVisible() ? word(selected_) : std::u16string_view{};
            const auto match = std::find(words.begin(), words.end(), previous);
            selected_ = match == words.end() ? 0 : int(match - words.begin());
            count_ = int(words.size());
            rowHeight_ = rows;
            setFont(editor_.font());
            colors_ = EditorPopupColors(*editor_.theme_);
            text_.clear();
            int width = 140;
            const QFontMetrics metrics(font());
            for (int i = 0; i < count_; ++i) {
                ranges_[i] = {text_.size(), words[i].size()};
                text_.append(words[i]);
                width = std::max(width, metrics.horizontalAdvance(label(i)) + 18);
            }
            const QRect area = parentWidget()->rect().adjusted(2, 2, -2, -2);
            width = std::min({width, 300, area.width()});
            const int tall = count_ * rowHeight_ + 4;
            const int x = std::clamp(anchor.left(), area.left(), area.right() - width + 1);
            setGeometry(x, below ? anchor.bottom() + 2 : anchor.top() - tall - 1, width, tall);
            show();
            raise();
            update();
        }

        void step(int direction)
        {
            selected_ = (selected_ + count_ + direction) % count_;
            update();
        }

        std::u16string_view word(int row) const
        {
            const auto range = ranges_[row];
            return {text_.data() + range.at, range.length};
        }

        int selected() const { return selected_; }
        OfflineWords index;

    protected:
        void paintEvent(QPaintEvent *) override
        {
            QPainter painter(this);
            painter.fillRect(rect(), qtColor(colors_.paper));
            painter.setPen(qtColor(colors_.border));
            painter.drawRect(rect().adjusted(0, 0, -1, -1));
            const QFontMetrics metrics(font());
            for (int i = 0; i < count_; ++i) {
                const QRect row(2, 2 + i * rowHeight_, width() - 4, rowHeight_);
                if (i == selected_)
                    painter.fillRect(row, qtColor(colors_.selection));
                painter.setPen(qtColor(i == selected_ ? colors_.selectedText : colors_.text));
                const QRect labelRect = row.adjusted(5, 0, -5, 0);
                const QString text = label(i);
                painter.drawText(labelRect, Qt::AlignLeft | Qt::AlignVCenter | Qt::TextSingleLine,
                                 metrics.elidedText(text, Qt::ElideRight, labelRect.width()));
            }
        }

        void mousePressEvent(QMouseEvent *event) override
        {
            const int y = int(event->position().y()) - 2;
            if (event->button() == Qt::LeftButton && y >= 0 && y / rowHeight_ < count_)
                editor_.acceptCompletion(y / rowHeight_);
        }

    private:
        struct Range { size_t at, length; };

        QString label(int row) const
        {
            const auto text = word(row);
            return QString::fromRawData(reinterpret_cast<const QChar *>(text.data()), qsizetype(text.size()));
        }

        CodeEdit &editor_;
        std::u16string text_;
        std::array<Range, WordCompletionLimit> ranges_{};
        PopupColors colors_{};
        int count_ = 0, selected_ = 0, rowHeight_ = 18;
    };

public:
    CodeEdit(QString name, const QString &text, const QString &sourcePath, const Theme &theme, int fontSize,
             const TextAppearance &appearance = {})
        : name(std::move(name)), gutter_(*this), theme_(&theme), appearance_(appearance),
          languagePath_(QDir::fromNativeSeparators(sourcePath.isEmpty() ? this->name : sourcePath).toUtf8()),
          detectsFromText_(DetectLanguage(utf8View(languagePath_)) == Language::Plain),
          highlighter_(detectSourceLanguage(languagePath_, text))
    {
        gutter_.setAttribute(Qt::WA_OpaquePaintEvent);
        setFrameStyle(QFrame::NoFrame);
        setLineWrapMode(QPlainTextEdit::NoWrap);
        setCenterOnScroll(false);
        setAcceptDrops(false);
        document()->setDocumentMargin(5);

        connect(this, &QPlainTextEdit::blockCountChanged, this, [this] { updateGutter(); });
        connect(this, &QPlainTextEdit::cursorPositionChanged, this, [this] {
            updateActiveLine();
            refreshBracketMatch();
            if (!editingCompletion_)
                dismissCompletion();
        });
        connect(this, &QPlainTextEdit::selectionChanged, this, [this] {
            refreshBracketMatch();
            if (!editingCompletion_)
                dismissCompletion();
        });
        for (auto *bar : {horizontalScrollBar(), verticalScrollBar()}) {
            connect(bar, &QScrollBar::valueChanged, this, [this] {
                if (!editingCompletion_)
                    dismissCompletion();
            });
        }
        connect(document(), &QTextDocument::contentsChange, this, [this](int at, int removed, int added) {
            if (removed || added) {
                editingDocument_ = true;
                const auto map = [&](TypingRange &part) {
                    return MapTypedRange(part, {size_t(at), size_t(removed)}, size_t(added));
                };
                RemapTypedPairs(typedPairs_, map);
                // Keep the old pair on the same glyphs until its outlines are repainted.
                for (auto *position : {&brackets_.at, &brackets_.mate}) {
                    if (*position != typingNotFound) {
                        TypingRange bracket{*position, 1};
                        *position = map(bracket) ? bracket.location : typingNotFound;
                    }
                }
            }
            if (completion_ && (removed || added)) {
                completion_->index.edited(*document(), at, removed, added);
                if (!editingCompletion_)
                    dismissCompletion();
            }
        });
        connect(document(), &QTextDocument::contentsChanged, this, [this] {
            editingDocument_ = false;
            refreshBracketMatch();
        });
        connect(this, &QPlainTextEdit::updateRequest, this, [this](const QRect &rect, int dy) {
            if (dy) {
                gutter_.scroll(0, dy);
            } else {
                gutter_.update(0, rect.y(), gutter_.width(), rect.height());
            }
        });

        setPlainText(text);
        QtTypingText typing(*document());
        indentation_ = DetectTypingIndentation(typing.source());
        applyFontSize(fontSize);
        highlighter_.applyTheme(theme, appearance_);
        highlighter_.setDocument(document());
        highlighter_.rehighlight();
        applyColors();
        refreshBracketMatch();
    }

    Language language() const { return highlighter_.language(); }
    Language languageMode() const { return mode_; }

    void complete() { showCompletions(0); }

    void toggleLineComment()
    {
        const auto selection = textCursor();
        if (isReadOnly() || !selection.block().layout()->preeditAreaText().isEmpty())
            return;
        auto *doc = document();
        const auto first = doc->findBlock(selection.selectionStart());
        const auto last = doc->findBlock(selection.selectionEnd() - int(selection.hasSelection()));
        const auto comments = CommentsInContext(language(), highlighter_.stateBefore(first));
        if (comments.line.empty() && (comments.open.empty() || comments.close.empty()))
            return;

        dismissCompletion();
        int anchor = selection.anchor(), head = selection.position(), delta = 0;
        QTextCursor cursor(doc);
        QString insertion;
        std::u16string_view previousInsertion;
        cursor.beginEditBlock();
        // Offsets passed to the shared planner refer to the original text.
        ToggleCommentLines(size_t(first.position()), size_t(last.position() + last.length() - 1),
            comments, indentation_.tabWidth, 1,
            [&](size_t at) {
                const auto block = doc->findBlock(int(at) + delta);
                const size_t start = size_t(block.position() - delta);
                return CommentLine{start, start + block.length() - 1, start + block.length()};
            },
            [&](size_t at) { return doc->characterAt(int(at) + delta).unicode(); },
            [&](size_t first, size_t last, std::u16string_view text) {
                const int start = int(first) + delta, end = int(last) + delta;
                const int change = int(text.size()) - (end - start);
                const auto map = [&](int at) {
                    if (at == start && start == end)
                        return at + int(CommentInsertionAdvance(text));
                    if (at < start)
                        return at;
                    return at < end ? start : at + change;
                };
                anchor = map(anchor);
                head = map(head);
                cursor.setPosition(start);
                cursor.setPosition(end, QTextCursor::KeepAnchor);
                if (text.empty()) {
                    cursor.removeSelectedText();
                } else {
                    if (previousInsertion != text) {
                        insertion = QString::fromUtf16(text.data(), qsizetype(text.size()));
                        previousInsertion = text;
                    }
                    cursor.insertText(insertion);
                }
                delta += change;
            });
        cursor.endEditBlock();
        cursor.setPosition(anchor);
        cursor.setPosition(head, QTextCursor::KeepAnchor);
        setTextCursor(cursor);
    }

    QString sourcePath() const { return filePath.isEmpty() ? QString{} : QString::fromUtf8(languagePath_); }

    void adoptPath(const QFileInfo &info, const QString &resolvedPath)
    {
        name = info.fileName();
        filePath = resolvedPath;
        languagePath_ = QDir::fromNativeSeparators(info.absoluteFilePath()).toUtf8();
        detectsFromText_ = DetectLanguage(utf8View(languagePath_)) == Language::Plain;
        refreshDetectedLanguage();
    }

    QByteArray sourceBytes() const
    {
        QString text = document()->toRawText();
        if (fileFormat.newline == LineEnding::CRLF)
            text.replace(QChar::ParagraphSeparator, QStringLiteral("\r\n"));
        else
            text.replace(QChar::ParagraphSeparator, QLatin1Char(fileFormat.newline == LineEnding::CR ? '\r' : '\n'));
        return text.toUtf8();
    }

    void setLanguageMode(Language mode)
    {
        dismissCompletion();
        mode_ = mode;
        if (mode_ == Language::Count)
            refreshDetectedLanguage();
        else if (highlighter_.setLanguage(mode_)) {
            typedPairs_.clear();
            refreshBracketMatch();
        }
    }

    bool shouldDetectLanguageAfterEdit(int offset) const
    {
        if (mode_ != Language::Count || !detectsFromText_ || offset >= languagePrefixLength)
            return false;
        if (language() != Language::Plain)
            return true;
        const QChar first = document()->characterAt(0);
        const QChar second = document()->characterAt(1);
        return (first == QLatin1Char('#') && second == QLatin1Char('!')) ||
               (first == QLatin1Char('<') && second == QLatin1Char('?')) || first.isSpace();
    }

    bool refreshDetectedLanguage()
    {
        if (mode_ != Language::Count)
            return false;
        QTextCursor prefix(document());
        prefix.setPosition(std::min(languagePrefixLength, document()->characterCount() - 1), QTextCursor::KeepAnchor);
        QString text = prefix.selectedText();
        text.replace(QChar::ParagraphSeparator, QLatin1Char('\n'));
        const bool changed = highlighter_.setLanguage(detectSourceLanguage(languagePath_, text));
        if (changed) {
            typedPairs_.clear();
            dismissCompletion();
            refreshBracketMatch();
        }
        return changed;
    }

    void applyAppearance(const Theme &theme, const TextAppearance &appearance)
    {
        const bool colorsChanged = theme_ != &theme ||
                                   appearance_.saturation != appearance.saturation ||
                                   appearance_.brightness != appearance.brightness ||
                                   appearance_.contrast != appearance.contrast;
        const bool weightChanged = appearance_.stroke != appearance.stroke;
        theme_ = &theme;
        appearance_ = appearance;
        if (colorsChanged) {
            dismissCompletion();
            highlighter_.applyTheme(theme, appearance);
            applyColors();
        }
        if (colorsChanged || weightChanged)
            viewport()->update();
    }

    void applyFontSize(int pixels)
    {
        dismissCompletion();
        QFont code = QFontDatabase::systemFont(QFontDatabase::FixedFont);
#ifdef Q_OS_WIN
        code.setFamily(QStringLiteral("Consolas"));
        // Keep fractional horizontal advances at small sizes on the DirectWrite backend.
        code.setHintingPreference(QFont::PreferVerticalHinting);
#endif
        code.setStyleHint(QFont::Monospace);
        code.setPixelSize(pixels);
        setFont(code);
        setTabStopDistance(QFontMetricsF(code).horizontalAdvance(QLatin1Char(' ')) * indentation_.tabWidth);
        updateGutter();
    }

    QString name;
    QString filePath;
    FileFormat fileFormat;

    QString tabLabel(bool modified = false) const
    {
        QString label = name;
        label.replace(QLatin1Char('&'), QStringLiteral("&&"));
        return modified ? QStringLiteral("* ") + label : label;
    }

protected:
    void keyPressEvent(QKeyEvent *event) override
    {
        const bool open = completion_ && completion_->isVisible();
        const auto modifiers = event->modifiers() &
            (Qt::ShiftModifier | Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);
        if (open && !modifiers) {
            switch (event->key()) {
            case Qt::Key_Up: case Qt::Key_Down:
                completion_->step(event->key() == Qt::Key_Up ? -1 : 1);
                return;
            case Qt::Key_Tab: case Qt::Key_Return: case Qt::Key_Enter:
                acceptCompletion(completion_->selected());
                return;
            case Qt::Key_Escape:
                dismissCompletion();
                return;
            default:
                break;
            }
        }
        const QString text = event->text();
        const bool word = !(modifiers & (Qt::ControlModifier | Qt::MetaModifier)) &&
            (text.size() == 1 || (text.size() == 2 && text[0].isHighSurrogate() && text[1].isLowSurrogate())) &&
            completionCharacter(text, 0, lispCompletion());
        const bool refine = open && !modifiers && event->key() == Qt::Key_Backspace;
        if (!word && !refine)
            dismissCompletion();
        const int revision = document()->revision();
        editingCompletion_ = word || refine;
        if (handleTypingKey(*event, modifiers, text))
            event->accept();
        else
            QPlainTextEdit::keyPressEvent(event);
        editingCompletion_ = false;
        if ((word || refine) && revision != document()->revision())
            showCompletions(open ? 1 : 2);
    }

    void inputMethodEvent(QInputMethodEvent *event) override
    {
        dismissCompletion();
        const auto &text = event->commitString();
        if (text.size() == 1 && MayCompleteCharacter(text.front().unicode()) &&
            event->preeditString().isEmpty() && !event->replacementStart() && !event->replacementLength() &&
            applyTyping(TypingKey::Character, text.front().unicode())) {
            event->accept();
            return;
        }
        QPlainTextEdit::inputMethodEvent(event);
        if (!event->commitString().isEmpty() && event->preeditString().isEmpty())
            showCompletions(2);
    }

    void focusOutEvent(QFocusEvent *event) override
    {
        dismissCompletion();
        QPlainTextEdit::focusOutEvent(event);
    }

    void mousePressEvent(QMouseEvent *event) override
    {
        dismissCompletion();
        QPlainTextEdit::mousePressEvent(event);
    }

    void resizeEvent(QResizeEvent *event) override
    {
        dismissCompletion();
        QPlainTextEdit::resizeEvent(event);
        positionGutter();
    }

    void paintEvent(QPaintEvent *event) override
    {
        if (highlighter_.mayHaveStaleColors()) {
            qreal y = contentOffset().y();
            for (auto block = firstVisibleBlock(); block.isValid() && y <= event->rect().bottom(); block = block.next()) {
                if (block.isVisible())
                    highlighter_.refreshBlockColors(block);
                y += blockBoundingRect(block).height();
            }
        }
        QPlainTextEdit::paintEvent(event);
        if (!appearance_.stroke && brackets_.mate == typingNotFound)
            return;

        QPainter painter(viewport());
        if (appearance_.stroke)
            paintTextWeight(painter, *event);
        if (brackets_.mate != typingNotFound)
            paintBracketMatch(painter, event->region());
    }

private:
    void paintTextWeight(QPainter &painter, const QPaintEvent &event)
    {
        const auto context = getPaintContext();
        painter.setPen(context.palette.text().color());
        QRegion inkClip = event.region();
        if (context.cursorPosition >= 0)
            inkClip -= cursorRect();
        painter.setClipRegion(inkClip);

        // Limit the sideways spread at higher weights to keep narrow glyphs distinct.
        // The centered pass puts the rest of the weight into the original glyph edges.
        const qreal extraWeight = std::max(0, appearance_.stroke - 30) / 70.0;
        const qreal sideOpacity = std::min(appearance_.stroke, 30) / 100.0 + 0.10 * extraWeight;
        const qreal centerOpacity = 0.90 * extraWeight;
        const QPointF side(0.5 / viewport()->devicePixelRatioF(), 0);
        const QRect dirty = event.rect();
        QPointF offset = contentOffset();
        for (auto block = firstVisibleBlock(); block.isValid() && offset.y() <= dirty.bottom(); block = block.next()) {
            const QRectF row = blockBoundingRect(block).translated(offset);
            auto *layout = block.layout();
            if (block.isVisible() && row.bottom() >= dirty.top() && layout->preeditAreaText().isEmpty()) {
                QList<QTextLayout::FormatRange> selections;
                for (const auto &selection : context.selections) {
                    const int start = std::max(0, selection.cursor.selectionStart() - block.position());
                    const int end = std::min(block.length() - 1, selection.cursor.selectionEnd() - block.position());
                    const auto foreground = selection.format.foreground();
                    if (start < end && foreground.style() != Qt::NoBrush) {
                        QTextCharFormat format;
                        format.setForeground(foreground);
                        selections.append({start, end - start, format});
                    }
                }
                painter.setOpacity(sideOpacity);
                layout->draw(&painter, offset - side, selections, dirty);
                layout->draw(&painter, offset + side, selections, dirty);
                if (centerOpacity > 0) {
                    painter.setOpacity(centerOpacity);
                    layout->draw(&painter, offset, selections, dirty);
                }
            }
            offset.ry() += row.height();
        }
    }

    QRectF visibleBracketRect(size_t at) const
    {
        if (at >= size_t(document()->characterCount() - 1))
            return {};
        const auto block = document()->findBlock(int(at));
        if (!block.isVisible() || block.position() < firstVisibleBlock().position())
            return {};
        const auto bounds = blockBoundingGeometry(block).translated(contentOffset());
        if (bounds.top() >= viewport()->height() || bounds.bottom() <= 0)
            return {};

        const int offset = int(at) - block.position();
        const auto line = block.layout()->lineForTextPosition(offset);
        if (!line.isValid())
            return {};
        const auto left = line.cursorToX(offset, QTextLine::Leading);
        const auto right = line.cursorToX(offset, QTextLine::Trailing);
        const QRectF rect(bounds.left() + std::min(left, right), bounds.top() + line.y(),
                          std::abs(right - left), line.height());
        return rect.intersects(viewport()->rect()) ? rect : QRectF{};
    }

    void refreshBracketMatch()
    {
        if (editingDocument_ || highlighter_.document() != document())
            return;
        const auto cursor = textCursor();
        QtTypingText text(*document());
        const auto match = isReadOnly() ? BracketMatch{} :
            BracketsAtSelection(text.source(), {size_t(cursor.selectionStart()),
                                                size_t(cursor.selectionEnd() - cursor.selectionStart())});
        if (match == brackets_)
            return;

        const auto previous = std::exchange(brackets_, match);
        for (const auto at : {previous.at, previous.mate, match.at, match.mate}) {
            const auto rect = visibleBracketRect(at);
            if (!rect.isEmpty())
                viewport()->update(rect.adjusted(-1, -1, 1, 1).toAlignedRect());
        }
    }

    void paintBracketMatch(QPainter &painter, const QRegion &dirty) const
    {
        const auto &theme = *theme_;
        auto color = qtColor(theme.dark || theme.blockCaretText ? theme.accents.bracketMatch :
                             theme.caret.value_or(theme.ink[size_t(Ink::Text)]));
        color.setAlphaF(theme.dark ? 0.48f : 0.38f);
        painter.setOpacity(1);
        painter.setClipRegion(dirty);
        painter.setRenderHint(QPainter::Antialiasing);
        painter.setPen(QPen(color, 0));
        painter.setBrush(Qt::NoBrush);
        for (const auto at : {brackets_.at, brackets_.mate}) {
            const auto rect = visibleBracketRect(at);
            if (!rect.isEmpty() && dirty.intersects(rect.toAlignedRect()))
                painter.drawRoundedRect(rect.adjusted(0.4, 1.1, -0.4, -1.1), 1.5, 1.5);
        }
    }

    bool handleTypingKey(const QKeyEvent &event, Qt::KeyboardModifiers modifiers, QStringView text)
    {
        const bool shiftOnly = !(modifiers & ~Qt::ShiftModifier);
        if (shiftOnly) {
            switch (event.key()) {
                case Qt::Key_Return: case Qt::Key_Enter: return applyTyping(TypingKey::Enter);
                case Qt::Key_Backspace: return applyTyping(TypingKey::Backspace);
                case Qt::Key_Tab: return applyTyping(modifiers ? TypingKey::Backtab : TypingKey::Tab);
                case Qt::Key_Backtab: return applyTyping(TypingKey::Backtab);
                default: break;
            }
        }
        bool command = modifiers & (Qt::ControlModifier | Qt::MetaModifier);
#ifndef Q_OS_MAC
        if ((modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) ==
            (Qt::ControlModifier | Qt::AltModifier))
            command = false; // AltGr can produce brackets and braces.
#endif
        return !command && text.size() == 1 && MayCompleteCharacter(text.front().unicode()) &&
               applyTyping(TypingKey::Character, text.front().unicode());
    }

    bool applyTyping(TypingKey key, char16_t character = 0)
    {
        const auto old = textCursor();
        const auto block = old.block();
        if (isReadOnly() || !block.layout()->preeditAreaText().isEmpty())
            return false;

        QtTypingText text(*document());
        const auto source = text.source();
        const auto at = size_t(old.selectionStart());
        LexState context;
        if (key == TypingKey::Character || key == TypingKey::Enter) {
            text.load(at);
            highlighter_.typingContext(text.block, text.view().substr(0, at - size_t(text.block.position())), context);
        }
        const auto plan = PlanTyping(source, language(), context, indentation_, typedPairs_,
                                    {at, size_t(old.selectionEnd() - old.selectionStart())}, key, character);
        if (!plan)
            return false;

        bool changed = plan->range.length != plan->text.size();
        for (size_t i = 0; !changed && i < plan->text.size(); ++i)
            changed = source.at(plan->range.location + i) != plan->text[i];
        const bool reversed = old.position() < old.anchor();
        QTextCursor cursor(document());
        if (changed) {
            cursor.beginEditBlock();
            cursor.setPosition(int(plan->range.location));
            cursor.setPosition(int(plan->range.end()), QTextCursor::KeepAnchor);
            if (plan->text.empty())
                cursor.removeSelectedText();
            else
                cursor.insertText(QString::fromUtf16(plan->text.data(), qsizetype(plan->text.size())));
            cursor.endEditBlock();
        }

        RememberTypedPair(typedPairs_, plan->pair, plan->passedCloser, size_t(document()->characterCount() - 1));
        cursor.setPosition(int(reversed ? plan->selection.end() : plan->selection.location));
        cursor.setPosition(int(reversed ? plan->selection.location : plan->selection.end()), QTextCursor::KeepAnchor);
        setTextCursor(cursor);
        ensureCursorVisible();
        return true;
    }

    bool lispCompletion() const
    {
        return language() == Language::CommonLisp || language() == Language::Clojure;
    }

    void dismissCompletion()
    {
        if (completion_)
            completion_->hide();
    }

    void showCompletions(int minimum)
    {
        const auto cursor = textCursor();
        const auto block = cursor.block();
        if (isReadOnly() || !hasFocus() || cursor.hasSelection() || !block.layout()->preeditAreaText().isEmpty()) {
            dismissCompletion();
            return;
        }
        const QString line = block.text();
        const bool lisp = lispCompletion();
        const int end = cursor.positionInBlock();
        int start = end;
        while (start > 0 && completionCharacter(line, start - 1, lisp))
            --start;
        if (end - start < minimum || (end < line.size() && completionCharacter(line, end, lisp)) ||
            (start < end && !lisp && line[start].unicode() < 128 && !IsASCIIIdentifierStart(line[start].unicode()))) {
            dismissCompletion();
            return;
        }

        QTextCursor atPrefix(cursor);
        atPrefix.setPosition(block.position() + start);
        const QRect anchor = cursorRect(atPrefix);
        const QRect area = viewport()->rect().adjusted(2, 2, -2, -2);
        const int height = std::max(18, fontMetrics().height() + 4);
        const int below = (area.bottom() - anchor.bottom() - 5) / height;
        const int above = (anchor.top() - area.top() - 5) / height;
        const int limit = std::max(below, above);
        if (limit < 1 || area.width() < 48 || anchor.bottom() < area.top() || anchor.top() > area.bottom()) {
            dismissCompletion();
            return;
        }
        if (!completion_)
            completion_ = new CompletionPopup(*this);
        std::array<std::u16string_view, WordCompletionLimit> words;
        const auto matches = std::span(words).first(std::min(words.size(), size_t(limit)));
        const size_t count = completion_->index.complete(block, utf16View(line), start, end, language(), matches);
        if (count == 0) {
            dismissCompletion();
            return;
        }
        completionStart_ = atPrefix.position();
        completionEnd_ = cursor.position();
        completion_->present(matches.first(count), anchor, height, below >= int(count));
    }

    void acceptCompletion(int row)
    {
        auto cursor = textCursor();
        const auto word = completion_->word(row);
        dismissCompletion();
        if (isReadOnly() || cursor.hasSelection() || cursor.position() != completionEnd_)
            return;
        const auto suffix = word.substr(size_t(completionEnd_ - completionStart_));
        cursor.beginEditBlock();
        cursor.insertText(QString::fromUtf16(suffix.data(), qsizetype(suffix.size())));
        cursor.endEditBlock();
        setTextCursor(cursor);
    }

    void applyColors()
    {
        QPalette colors = palette();
        colors.setColor(QPalette::Base, qtColor(theme_->paper));
        const Col32 text = theme_->ink[size_t(Ink::Text)];
        colors.setColor(QPalette::Text, adjustInk(text, theme_->paper, appearance_));
        colors.setColor(QPalette::Highlight, qtColor(theme_->selection));
        colors.setColor(QPalette::HighlightedText, adjustInk(text, theme_->selection, appearance_));
        setPalette(colors);
        updateActiveLine();
    }

    void updateActiveLine()
    {
        QTextEdit::ExtraSelection line;
        line.format.setBackground(qtColor(theme_->line));
        line.format.setProperty(QTextFormat::FullWidthSelection, true);
        line.cursor = textCursor();
        line.cursor.clearSelection();
        setExtraSelections({line});
        gutter_.update();
    }

    void updateGutter()
    {
        const auto digits = std::max<qsizetype>(3, QString::number(blockCount()).size());
        const int width = 16 + int(digits) * fontMetrics().horizontalAdvance(QLatin1Char('9'));
        if (viewportMargins().left() != width)
            setViewportMargins(width, 0, 0, 0);
        positionGutter();
    }

    void positionGutter()
    {
        const QRect area = contentsRect();
        gutter_.setGeometry(area.left(), area.top(), viewportMargins().left(), viewport()->height());
    }

    void paintGutter(const QRect &dirty)
    {
        QPainter painter(&gutter_);
        painter.fillRect(dirty, qtColor(theme_->gutter));
        painter.setPen(qtColor(theme_->rule));
        painter.drawLine(gutter_.width() - 1, dirty.top(), gutter_.width() - 1, dirty.bottom());
        painter.setFont(font());

        QTextBlock block = firstVisibleBlock();
        const int active = textCursor().blockNumber();
        while (block.isValid()) {
            const QRectF bounds = blockBoundingGeometry(block).translated(contentOffset());
            if (bounds.top() > dirty.bottom())
                break;

            if (block.isVisible() && bounds.bottom() >= dirty.top()) {
                const QRectF row(0, bounds.top(), gutter_.width() - 1, bounds.height());
                const bool current = block.blockNumber() == active;
                if (current)
                    painter.fillRect(row, qtColor(theme_->line));
                painter.setPen(qtColor(current ? theme_->activeNumber : theme_->lineNumber));
                painter.drawText(row.adjusted(0, 0, -8, 0), Qt::AlignRight | Qt::AlignVCenter,
                                 QString::number(block.blockNumber() + 1));
            }
            block = block.next();
        }
    }

    Gutter gutter_;
    const Theme *theme_;
    TextAppearance appearance_;
    QByteArray languagePath_;
    bool detectsFromText_;
    Language mode_ = Language::Count; // Auto Detect
    SourceHighlighter highlighter_;
    Indentation indentation_;
    std::vector<TypedPair> typedPairs_;
    BracketMatch brackets_;
    CompletionPopup *completion_ = nullptr;
    int completionStart_ = 0, completionEnd_ = 0;
    bool editingCompletion_ = false;
    bool editingDocument_ = false;
};

class LanguageChoices final : public QAbstractListModel {
public:
    int rowCount(const QModelIndex &parent = {}) const override
    {
        return parent.isValid() ? 0 : int(Language::Count) + 1;
    }

    QVariant data(const QModelIndex &item, int role) const override
    {
        if (!item.isValid() || item.row() >= rowCount())
            return {};
        if (item.row() == 0) {
            if (role == Qt::DisplayRole)
                return autoLabel_;
            if (role == Qt::UserRole)
                return int(Language::Count);
            return {};
        }
        const auto &choice = choices()[size_t(item.row() - 1)];
        if (role == Qt::DisplayRole)
            return choice.label;
        if (role == Qt::UserRole)
            return int(choice.language);
        return {};
    }

    void setDetectedLanguage(Language language)
    {
        if (detected_ == language)
            return;
        detected_ = language;
        autoLabel_ = language == Language::Count ? QStringLiteral("Auto Detect")
            : QStringLiteral("%1 (Auto)").arg(QString::fromUtf8(InfoForLanguage(language).name));
        emit dataChanged(index(0), index(0), {Qt::DisplayRole});
    }

private:
    struct Choice {
        Language language;
        QString label;
    };

    static const std::array<Choice, size_t(Language::Count)> &choices()
    {
        static const auto rows = [] {
            std::array<Choice, size_t(Language::Count)> result{};
            for (size_t i = 0; i < result.size(); ++i)
                result[i] = {Language(i), QString::fromUtf8(InfoForLanguage(Language(i)).name)};
            std::sort(result.begin() + 1, result.end(), [](const Choice &left, const Choice &right) {
                return left.label.compare(right.label, Qt::CaseInsensitive) < 0;
            });
            return result;
        }();
        return rows;
    }

    Language detected_ = Language::Count;
    QString autoLabel_ = QStringLiteral("Auto Detect");
};

class ThemeChoices final : public QAbstractListModel {
public:
    void filter(QStringView query)
    {
        beginResetModel();
        count_ = 0;
        for (int i = 0; i < int(std::size(themes)); ++i) {
            if (QLatin1StringView(themes[i].name).contains(query, Qt::CaseInsensitive))
                rows_[count_++] = i;
        }
        endResetModel();
    }

    int rowCount(const QModelIndex &parent = {}) const override
    {
        return parent.isValid() ? 0 : count_;
    }

    QVariant data(const QModelIndex &item, int role) const override
    {
        if (role == Qt::DisplayRole) {
            if (const auto *theme = themeAt(item))
                return QString::fromLatin1(theme->name);
        }
        return {};
    }

    const Theme *themeAt(const QModelIndex &item) const
    {
        return item.isValid() && item.row() < count_ ? &themes[rows_[item.row()]] : nullptr;
    }

    int rowOf(const Theme *theme) const
    {
        for (int row = 0; row < count_; ++row) {
            if (&themes[rows_[row]] == theme)
                return row;
        }
        return -1;
    }

private:
    std::array<int, std::size(themes)> rows_;
    int count_ = 0;
};

class EditorWindow final : public QMainWindow {
public:
    explicit EditorWindow(const EditorWindow *opener = nullptr)
        : theme_(opener ? opener->theme_ : nullptr), fontSize_(opener ? opener->fontSize_ : 15)
    {
        if (opener) {
            appearance_ = opener->appearance_;
        } else {
            QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
            theme_ = &findTheme(utf8View(settings.value(QStringLiteral("EditorTheme")).toByteArray()));
            settings.beginGroup(QStringLiteral("TextAppearance"));
            for (const auto &control : appearanceControls) {
                int &value = appearance_.*control.value;
                value = std::clamp(settings.value(QString::fromLatin1(control.key), value).toInt(),
                                   control.minimum, control.maximum);
            }
        }

        appearanceUpdate_.setSingleShot(true);
        appearanceUpdate_.setInterval(40);
        connect(&appearanceUpdate_, &QTimer::timeout, this, [this] {
            if (auto *editor = activeEditor())
                editor->applyAppearance(*theme_, appearance_);
        });

        resize(1040, 720);
        setMinimumSize(510, 340);
        setWindowTitle(QStringLiteral("Retina Code"));
        setAcceptDrops(true);

        tabs_ = new QTabWidget(this);
        tabs_->setDocumentMode(true);
        tabs_->setTabsClosable(true);
        tabs_->setMovable(true);
        tabs_->setElideMode(Qt::ElideMiddle);
        setCentralWidget(tabs_);

        position_ = new QLabel(this);
        languagePicker_ = new QComboBox(this);
        languagePicker_->setAccessibleName(QStringLiteral("Language"));
        languagePicker_->setToolTip(QStringLiteral("Choose this tab's language mode."));
        languagePicker_->setModel(&languageChoices_);
        encodingAndSize_ = new QLabel(this);
        encodingAndSize_->setToolTip(QStringLiteral("Editor font size in logical pixels, before display scaling."));
        statusBar()->addWidget(position_);
        statusBar()->addPermanentWidget(languagePicker_);
        statusBar()->addPermanentWidget(encodingAndSize_);
        connect(languagePicker_, &QComboBox::activated, this, [this](int row) {
            if (auto *editor = activeEditor()) {
                editor->setLanguageMode(Language(languagePicker_->itemData(row).toInt()));
                updateLanguagePicker();
                editor->setFocus();
            }
        });

        makeActions();
        connect(tabs_, &QTabWidget::currentChanged, this, [this] { activateTab(); });
        connect(tabs_, &QTabWidget::tabCloseRequested, this, [this](int index) {
            QPointer<CodeEdit> editor = static_cast<CodeEdit *>(tabs_->widget(index));
            if (editor && confirmCloseTab(editor) && editor) {
                tabs_->removeTab(tabs_->indexOf(editor));
                delete editor.data();
            }
        });

#ifdef Q_OS_WIN
        memory_ = new QLabel(this);
        memory_->setToolTip(QStringLiteral("Resident memory for this process. MB = 1,000,000 bytes."));
        statusBar()->addPermanentWidget(memory_);
        auto *timer = new QTimer(this);
        connect(timer, &QTimer::timeout, this, [this] { updateMemory(); });
        timer->start(2000);
#endif
        activateTab();
    }

    static EditorWindow *create(const EditorWindow *opener = nullptr)
    {
        auto *window = new EditorWindow(opener);
        window->setAttribute(Qt::WA_DeleteOnClose);
        return window;
    }

    void loadSamples()
    {
        auto *first = addTab(QStringLiteral("main.rs"), QString::fromUtf8(sampleMain));
        addTab(QStringLiteral("sample.rs"), QString::fromUtf8(sampleModule));
        selectTab(first);
    }

    void openFiles(const QStringList &paths)
    {
        CodeEdit *first = nullptr;
        QStringList errors;
        for (const auto &path : paths) {
            QString error;
            if (auto *editor = openFile(path, error)) {
                if (!first)
                    first = editor;
            } else {
                errors.append(QStringLiteral("%1 — %2").arg(QDir::toNativeSeparators(path), error));
            }
        }
        if (first)
            selectTab(first);
        if (!errors.isEmpty()) {
            QMessageBox message(QMessageBox::Warning, QStringLiteral("Open Files"), {}, QMessageBox::Ok, this);
            message.setTextFormat(Qt::PlainText);
            if (errors.size() == 1) {
                message.setText(errors.first());
            } else {
                message.setText(QStringLiteral("Could not open %1 files.").arg(errors.size()));
                message.setDetailedText(errors.join(QLatin1Char('\n')));
            }
            message.exec();
        }
    }

protected:
    void dragEnterEvent(QDragEnterEvent *event) override
    {
        if (!(event->possibleActions() & Qt::CopyAction) || droppedFiles(event->mimeData()).isEmpty()) {
            event->ignore();
            return;
        }
        event->setDropAction(Qt::CopyAction);
        event->accept();
    }

    void dragMoveEvent(QDragMoveEvent *event) override
    {
        if (!(event->possibleActions() & Qt::CopyAction)) {
            event->ignore();
            return;
        }
        event->setDropAction(Qt::CopyAction);
        event->accept();
    }

    void dropEvent(QDropEvent *event) override
    {
        auto paths = droppedFiles(event->mimeData());
        if (paths.isEmpty() || !(event->possibleActions() & Qt::CopyAction)) {
            event->ignore();
            return;
        }
        event->setDropAction(Qt::CopyAction);
        event->accept();
        // Finish the native drop before loading files or showing an open error.
        QTimer::singleShot(0, this, [this, paths = std::move(paths)] { openFiles(paths); });
    }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() == QEvent::Wheel) {
            auto *wheel = static_cast<QWheelEvent *>(event);
            const int delta = wheel->angleDelta().y();
            if (wheel->modifiers() == Qt::ControlModifier && delta != 0) {
                wheelZoomDelta_ += delta;
                const int steps = wheelZoomDelta_ / 120;
                wheelZoomDelta_ %= 120;
                if (steps != 0)
                    zoom(fontSize_ + steps);
                wheel->accept();
                return true;
            }
            wheelZoomDelta_ = 0;
        }
        return QMainWindow::eventFilter(watched, event);
    }

    void closeEvent(QCloseEvent *event) override
    {
        if (!std::exchange(closeApproved_, false) && !confirmClose()) {
            event->ignore();
            return;
        }
        saveAppearance();
        if (runPane_)
            runPane_->shutdown();
        event->accept();
    }

private:
    static QStringList droppedFiles(const QMimeData *mime)
    {
        QStringList paths;
        for (const auto &url : mime->urls()) {
            const QString path = url.toLocalFile();
            if (!path.isEmpty() && QFileInfo(path).isFile())
                paths.append(path);
        }
        return paths;
    }

    static QString resolvedPath(const QFileInfo &info)
    {
        const QString canonical = info.canonicalFilePath();
        return canonical.isEmpty() ? info.absoluteFilePath() : canonical;
    }

    CodeEdit *openTabForPath(const QString &path) const
    {
        for (int i = 0; i < tabs_->count(); ++i) {
            auto *editor = static_cast<CodeEdit *>(tabs_->widget(i));
            if (editor->filePath == path)
                return editor;
            if (editor->filePath.compare(path, Qt::CaseInsensitive) == 0) {
                // Qt can retain the caller's spelling on a case-insensitive volume.
                std::error_code failure;
                if (std::filesystem::equivalent(QFileInfo(path).filesystemAbsoluteFilePath(),
                                                QFileInfo(editor->filePath).filesystemAbsoluteFilePath(), failure))
                    return editor;
            }
        }
        return nullptr;
    }

    CodeEdit *openFile(const QString &path, QString &error)
    {
        const QFileInfo info(path);
        if (!info.isFile()) {
            error = QStringLiteral("Choose an existing file.");
            return nullptr;
        }
        const QString sourcePath = info.absoluteFilePath();
        const QString filePath = resolvedPath(info);
        if (auto *editor = openTabForPath(filePath))
            return editor;

        QFile file(sourcePath);
        if (!file.open(QIODevice::ReadOnly)) {
            error = file.errorString();
            return nullptr;
        }
        const QByteArray bytes = file.readAll();
        if (file.error() != QFileDevice::NoError) {
            error = file.errorString();
            return nullptr;
        }
        QStringDecoder decode(QStringDecoder::Utf8, QStringDecoder::Flag::Stateless);
        const QString text = decode(bytes);
        if (decode.hasError() || text.contains(QChar::Null)) {
            error = QStringLiteral("Choose a UTF-8 text file.");
            return nullptr;
        }
        auto *editor = addTab(info.fileName(), text, sourcePath, filePath);
        editor->fileFormat = formatOf(utf8View(bytes));
        return editor;
    }

    static QString writeFile(const CodeEdit &editor, const QString &path)
    {
        QSaveFile file(path);
        if (!file.open(QIODevice::WriteOnly))
            return file.errorString();
        if (editor.fileFormat.bom && file.write(utf8Bom, sizeof(utf8Bom) - 1) != sizeof(utf8Bom) - 1)
            return file.errorString();
        const QByteArray bytes = editor.sourceBytes();
        if (file.write(bytes) != bytes.size() || !file.commit())
            return file.errorString();
        return {};
    }

    void showSaveError(const QString &path, const QString &error)
    {
        QMessageBox message(QMessageBox::Warning, QStringLiteral("Could Not Save"), {}, QMessageBox::Ok, this);
        message.setTextFormat(Qt::PlainText);
        message.setText(QStringLiteral("%1 — %2").arg(QDir::toNativeSeparators(path), error));
        message.exec();
    }

    void showOutput()
    {
        if (!runPane_) {
            runPane_ = new RunPane(this);
            addDockWidget(Qt::BottomDockWidgetArea, runPane_);
            resizeDocks({runPane_}, {170}, Qt::Vertical);
            connect(&runPane_->output(), &QTextBrowser::anchorClicked, this, &EditorWindow::revealRunLocation);
        }
        runPane_->show();
    }

    void runCurrentFile()
    {
        if (runPane_ && runPane_->isRunning()) {
            runPane_->stop();
            return;
        }
        auto *editor = activeEditor();
        if (!editor)
            return;
        showOutput();
        runSource_ = editor;
        runSourcePath_ = editor->sourcePath();
        if (runSourcePath_.isEmpty() || editor->document()->isModified()) {
            const auto bytes = editor->sourceBytes();
            runPane_->run(editor->language(), runSourcePath_, editor->name, &bytes);
        } else {
            runPane_->run(editor->language(), runSourcePath_, editor->name, nullptr);
        }
    }

    void revealRunLocation(const QUrl &link)
    {
        const auto coordinates = link.fragment().split(QLatin1Char(':'));
        if (coordinates.size() != 3)
            return;
        const int row = coordinates[0].toInt();
        const int column = coordinates[1].toInt();
        const int encoding = coordinates[2].toInt();
        if (row < 1 || column < 0)
            return;
        const bool original = link.scheme() == QLatin1StringView("retina-source");
        auto *editor = original ? runSource_.data() : nullptr;
        if (!editor) {
            const QString path = original ? runSourcePath_ : link.toLocalFile();
            if (path.isEmpty())
                return;
            QString error;
            editor = openFile(path, error);
            if (!editor) {
                QMessageBox message(QMessageBox::Warning, QStringLiteral("Open Diagnostic"), error, QMessageBox::Ok, this);
                message.setTextFormat(Qt::PlainText);
                message.exec();
                return;
            }
        }
        const auto line = editor->document()->findBlockByNumber(std::min(row, editor->blockCount()) - 1);
        const auto text = line.text();
        int remaining = std::max(0, column - 1);
        int offset = 0;
        if (encoding == 2) {
            offset = std::min(remaining, int(text.size()));
        } else {
            while (remaining && offset < text.size()) {
                const auto ch = text[offset];
                const bool pair = ch.isHighSurrogate() && offset + 1 < text.size() && text[offset + 1].isLowSurrogate();
                const auto unit = ch.unicode();
                const int width = encoding != 1 || unit < 0x80 ? 1 : unit < 0x800 ? 2 : pair ? 4 : 3;
                if (remaining < width)
                    break;
                remaining -= width;
                offset += pair ? 2 : 1;
            }
        }
        selectTab(editor);
        QTextCursor cursor(line);
        cursor.setPosition(line.position() + offset);
        editor->setTextCursor(cursor);
        editor->centerCursor();
    }

    bool saveTab(CodeEdit *editor, bool saveAs = false)
    {
        if (!editor)
            return false;
        const bool choosePath = saveAs || editor->filePath.isEmpty();
        if (!choosePath && !editor->document()->isModified())
            return true;

        QPointer<CodeEdit> guard = editor;
        QString path = editor->filePath;
        if (choosePath) {
            QString suggested = editor->sourcePath();
            if (suggested.isEmpty()) {
                const QString documents = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
                const QDir folder(!documents.isEmpty() && QDir(documents).exists() ? documents : QDir::homePath());
                suggested = folder.filePath(editor->name);
            }
            path = QFileDialog::getSaveFileName(this, QStringLiteral("Save As"), suggested);
            if (path.isEmpty() || !guard)
                return false;
        }

        QFileInfo info(path);
        const QString destination = resolvedPath(info);
        if (choosePath) {
            for (auto *widget : QApplication::topLevelWidgets()) {
                if (auto *window = dynamic_cast<EditorWindow *>(widget); window && window->isVisible()) {
                    if (auto *other = window->openTabForPath(destination); other && other != editor) {
                        showSaveError(path, QStringLiteral("This file is open in another tab."));
                        return false;
                    }
                }
            }
        }
        if (const QString error = writeFile(*editor, destination); !error.isEmpty()) {
            showSaveError(path, error);
            return false;
        }

        const int tab = tabs_->indexOf(editor);
        if (choosePath) {
            info.refresh();
            editor->adoptPath(info, resolvedPath(info));
            tabs_->setTabToolTip(tab, QDir::toNativeSeparators(info.absoluteFilePath()));
        }
        editor->document()->setModified(false);
        tabs_->setTabText(tab, editor->tabLabel());
        if (editor == activeEditor())
            activateTab();
        return true;
    }

    static const Theme &findTheme(std::string_view name)
    {
        const Theme *fallback = &themes[0];
        for (const auto &theme : themes) {
            const std::string_view title = theme.name;
            if (title == name)
                return theme;
            if (title == "Monokai")
                fallback = &theme;
        }
        return *fallback;
    }

    CodeEdit *activeEditor() const { return static_cast<CodeEdit *>(tabs_->currentWidget()); }

    void selectTab(CodeEdit *editor)
    {
        tabs_->setCurrentWidget(editor);
        editor->setFocus();
    }

    void newTab()
    {
        static unsigned untitledCount = 0;
        ++untitledCount;
        const QString name = untitledCount == 1 ? QStringLiteral("Untitled")
            : QStringLiteral("Untitled %1").arg(untitledCount);
        selectTab(addTab(name, {}));
    }

    void newWindow()
    {
        auto *window = create(this);
        window->newTab();
        window->show();
        window->raise();
        window->activateWindow();
    }

    CodeEdit *addTab(const QString &name, const QString &text, const QString &sourcePath = {},
                     const QString &filePath = {})
    {
        auto *editor = new CodeEdit(name, text, sourcePath, *theme_, fontSize_, appearance_);
        editor->filePath = filePath;
        editor->viewport()->installEventFilter(this);
        const int index = tabs_->addTab(editor, editor->tabLabel());
        tabs_->setTabToolTip(index, sourcePath.isEmpty() ? name : QDir::toNativeSeparators(sourcePath));
        connect(editor, &QPlainTextEdit::cursorPositionChanged, this, [this] { updateStatus(); });
        connect(editor->document(), &QTextDocument::contentsChange, this, [this, editor](int offset, int removed, int added) {
            if (!(removed || added) || !editor->shouldDetectLanguageAfterEdit(offset))
                return;
            QTimer::singleShot(0, editor, [this, editor] {
                if (editor->refreshDetectedLanguage() && editor == activeEditor())
                    updateLanguagePicker();
            });
        });
        connect(editor->document(), &QTextDocument::modificationChanged, this, [this, editor](bool modified) {
            tabs_->setTabText(tabs_->indexOf(editor), editor->tabLabel(modified));
        });
        return editor;
    }

    bool confirmCloseTab(CodeEdit *editor)
    {
        if (!editor->document()->isModified())
            return true;
        QPointer<CodeEdit> guard = editor;
        const auto choice = QMessageBox::question(this, QStringLiteral("Unsaved Changes"),
                                                  QStringLiteral("Save changes to %1?").arg(editor->name),
                                                  QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel,
                                                  QMessageBox::Cancel);
        return choice == QMessageBox::Discard || (choice == QMessageBox::Save && guard && saveTab(guard));
    }

    bool confirmClose()
    {
        for (int i = 0; i < tabs_->count(); ++i) {
            if (!confirmCloseTab(static_cast<CodeEdit *>(tabs_->widget(i))))
                return false;
        }
        return true;
    }

    void quitApplication()
    {
        QList<EditorWindow *> windows{this};
        for (auto *widget : QApplication::topLevelWidgets()) {
            if (auto *window = dynamic_cast<EditorWindow *>(widget); window && window != this && window->isVisible())
                windows.append(window);
        }
        for (auto *window : windows) {
            if (!window->confirmClose())
                return;
        }
        // A canceled quit should leave every window and draft intact.
        for (auto *window : windows) {
            window->closeApproved_ = true;
            window->close();
        }
    }

    void activateTab()
    {
        auto *editor = activeEditor();
        saveAction_->setEnabled(editor != nullptr);
        saveAsAction_->setEnabled(editor != nullptr);
        if (editor)
            editor->applyAppearance(*theme_, appearance_);
        setWindowTitle(editor ? editor->name + QStringLiteral(" — Retina Code") : QStringLiteral("Retina Code"));
        updateLanguagePicker();
        updateStatus();
    }

    void updateLanguagePicker()
    {
        auto *editor = activeEditor();
        languagePicker_->setEnabled(editor != nullptr);
        const Language mode = editor ? editor->languageMode() : Language::Count;
        languageChoices_.setDetectedLanguage(editor && mode == Language::Count ? editor->language() : Language::Count);
        languagePicker_->setCurrentIndex(editor ? languagePicker_->findData(int(mode)) : -1);
    }

    void updateStatus()
    {
        auto *editor = activeEditor();
        if (!editor) {
            position_->clear();
            encodingAndSize_->clear();
            return;
        }
        const auto cursor = editor->textCursor();
        position_->setText(QStringLiteral("Ln %1, Col %2").arg(cursor.blockNumber() + 1).arg(cursor.positionInBlock() + 1));
        encodingAndSize_->setText(QStringLiteral("UTF-8  ·  %1 px").arg(fontSize_));
    }

    void makeActions()
    {
        auto *file = menuBar()->addMenu(QStringLiteral("&File"));
        auto *newTabAction = file->addAction(QStringLiteral("&New Tab"), QKeySequence::New, this, &EditorWindow::newTab);
        auto *newWindowAction = file->addAction(QStringLiteral("New &Window"),
                                               QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_N), this, &EditorWindow::newWindow);
        newTabAction->setAutoRepeat(false);
        newWindowAction->setAutoRepeat(false);
        file->addSeparator();
        auto *open = file->addAction(QStringLiteral("&Open…"));
        open->setShortcut(QKeySequence::Open);
        open->setIcon(style()->standardIcon(QStyle::SP_DirOpenIcon));
        connect(open, &QAction::triggered, this, [this] {
            openFiles(QFileDialog::getOpenFileNames(this, QStringLiteral("Open Source Files")));
        });
        saveAction_ = file->addAction(QStringLiteral("&Save"), QKeySequence::Save, this,
                                      [this] { saveTab(activeEditor()); });
        saveAsAction_ = file->addAction(QStringLiteral("Save &As…"), QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_S), this,
                                        [this] { saveTab(activeEditor(), true); });
        saveAction_->setAutoRepeat(false);
        saveAsAction_->setAutoRepeat(false);
        file->addSeparator();
        auto *closeTab = file->addAction(QStringLiteral("&Close Tab"));
        auto closeKeys = QKeySequence::keyBindings(QKeySequence::Close);
        const QKeySequence controlW(Qt::CTRL | Qt::Key_W);
        closeKeys.removeAll(controlW);
        closeKeys.prepend(controlW);
        closeTab->setShortcuts(closeKeys);
        connect(closeTab, &QAction::triggered, this, [this] {
            if (tabs_->currentIndex() >= 0)
                emit tabs_->tabCloseRequested(tabs_->currentIndex());
        });
        file->addSeparator();
        auto *run = file->addAction(QStringLiteral("&Run Current File"), QKeySequence(Qt::CTRL | Qt::Key_R),
                                    this, &EditorWindow::runCurrentFile);
        run->setAutoRepeat(false);
        file->addSeparator();
        file->addAction(QStringLiteral("E&xit"), QKeySequence::Quit, this, &EditorWindow::quitApplication);

        auto *edit = menuBar()->addMenu(QStringLiteral("&Edit"));
        addEditAction(edit, QStringLiteral("&Undo"), QKeySequence::Undo, [](auto &text) { text.undo(); });
        addEditAction(edit, QStringLiteral("&Redo"), QKeySequence::Redo, [](auto &text) { text.redo(); });
        edit->addSeparator();
        addEditAction(edit, QStringLiteral("Cu&t"), QKeySequence::Cut, [](auto &text) { text.cut(); });
        addEditAction(edit, QStringLiteral("&Copy"), QKeySequence::Copy, [](auto &text) { text.copy(); });
        addEditAction(edit, QStringLiteral("&Paste"), QKeySequence::Paste, [](auto &text) { text.paste(); });
        addEditAction(edit, QStringLiteral("Select &All"), QKeySequence::SelectAll, [](auto &text) { text.selectAll(); });
        edit->addSeparator();
        auto *comment = edit->addAction(QStringLiteral("Toggle Line &Comment"),
            QKeySequence(Qt::CTRL | Qt::Key_Slash), this, [this] {
                if (auto *editor = activeEditor())
                    editor->toggleLineComment();
            });
        comment->setAutoRepeat(true);
#ifdef Q_OS_MAC
        comment->setShortcuts({comment->shortcut(), QKeySequence(Qt::META | Qt::Key_Slash)});
#endif
#ifdef Q_OS_MAC
        const QKeySequence completeShortcut(Qt::META | Qt::Key_Space);
#else
        const QKeySequence completeShortcut(Qt::CTRL | Qt::Key_Space);
#endif
        edit->addAction(QStringLiteral("Show &Completions"), completeShortcut, this, [this] {
            if (auto *editor = activeEditor()) {
                editor->setFocus(Qt::ShortcutFocusReason);
                editor->complete();
            }
        });

        auto *view = menuBar()->addMenu(QStringLiteral("&View"));
        auto *zoomIn = view->addAction(QStringLiteral("Zoom &In"), this, [this] { zoom(fontSize_ + 1); });
        auto zoomInKeys = QKeySequence::keyBindings(QKeySequence::ZoomIn);
        const QKeySequence controlEquals(Qt::CTRL | Qt::Key_Equal);
        if (!zoomInKeys.contains(controlEquals))
            zoomInKeys.append(controlEquals);
        zoomIn->setShortcuts(zoomInKeys);
        view->addAction(QStringLiteral("Zoom &Out"), QKeySequence::ZoomOut, this, [this] { zoom(fontSize_ - 1); });
        view->addAction(QStringLiteral("&Reset Zoom"), QKeySequence(QStringLiteral("Ctrl+0")), this, [this] { zoom(15); });
        view->addAction(QStringLiteral("Editor &Theme…"), this, &EditorWindow::showThemePicker);
        view->addSeparator();
        view->addAction(QStringLiteral("&Text Appearance…"), this, [this] { showTextAppearance(); });
        view->addAction(QStringLiteral("&Output"), this, &EditorWindow::showOutput);
    }

    void addEditAction(QMenu *menu, const QString &label, QKeySequence::StandardKey key, auto operation)
    {
        auto *action = menu->addAction(label);
        action->setShortcuts(key);
        connect(action, &QAction::triggered, this, [this, operation] {
            auto *focused = focusWidget();
            if (auto *text = qobject_cast<QTextEdit *>(focused))
                operation(*text);
            else if (auto *field = qobject_cast<QLineEdit *>(focused))
                operation(*field);
            else if (auto *editor = activeEditor())
                operation(*editor);
        });
    }

    void zoom(int size)
    {
        const int clamped = std::clamp(size, 9, 36);
        if (fontSize_ == clamped)
            return;
        fontSize_ = clamped;
        for (int i = 0; i < tabs_->count(); ++i)
            static_cast<CodeEdit *>(tabs_->widget(i))->applyFontSize(fontSize_);
        updateStatus();
    }

    void setEditorTheme(const Theme &theme)
    {
        if (theme_ == &theme)
            return;
        for (auto *widget : QApplication::topLevelWidgets()) {
            if (auto *window = dynamic_cast<EditorWindow *>(widget)) {
                window->theme_ = &theme;
                if (auto *editor = window->activeEditor())
                    editor->applyAppearance(theme, window->appearance_);
            }
        }
    }

    void showThemePicker()
    {
        const Theme *original = theme_;
        QDialog dialog(this);
        dialog.setWindowTitle(QStringLiteral("Editor Theme"));
        QVBoxLayout layout(&dialog);
        QLineEdit filter;
        filter.setPlaceholderText(QStringLiteral("Filter themes…"));
        filter.setAccessibleName(QStringLiteral("Filter themes"));
        layout.addWidget(&filter);

        ThemeChoices choices;
        choices.filter({});
        QListView list;
        list.setAccessibleName(QStringLiteral("Themes"));
        list.setUniformItemSizes(true);
        list.setModel(&choices);
        layout.addWidget(&list, 1);

        QDialogButtonBox buttons(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
        layout.addWidget(&buttons);
        auto *ok = buttons.button(QDialogButtonBox::Ok);
        ok->setDefault(true);
        connect(&buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
        connect(&buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
        connect(&list, &QListView::activated, &dialog, &QDialog::accept);
        connect(list.selectionModel(), &QItemSelectionModel::currentChanged, &dialog, [&](const QModelIndex &item) {
            if (const auto *theme = choices.themeAt(item))
                setEditorTheme(*theme);
        });

        list.setCurrentIndex(choices.index(choices.rowOf(theme_)));
        connect(&filter, &QLineEdit::textChanged, &dialog, [&](const QString &text) {
            const auto *current = choices.themeAt(list.currentIndex());
            choices.filter(QStringView(text).trimmed());
            list.setCurrentIndex(choices.index(std::max(0, choices.rowOf(current))));
            ok->setEnabled(list.currentIndex().isValid());
        });
        QShortcut up(QKeySequence(Qt::Key_Up), &filter, [&] {
            list.setCurrentIndex(choices.index(std::max(0, list.currentIndex().row() - 1)));
        }, Qt::WidgetShortcut);
        QShortcut down(QKeySequence(Qt::Key_Down), &filter, [&] {
            list.setCurrentIndex(choices.index(std::min(choices.rowCount() - 1, list.currentIndex().row() + 1)));
        }, Qt::WidgetShortcut);
        filter.setFocus();
        dialog.resize(340, 420);
        dialog.move(mapToGlobal(QPoint(width() - dialog.width() - 20, menuBar()->height() + 20)));
        if (dialog.exec() != QDialog::Accepted || !list.currentIndex().isValid()) {
            setEditorTheme(*original);
            return;
        }
        if (theme_ == original)
            return;
        QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
        settings.setValue(QStringLiteral("EditorTheme"), QString::fromLatin1(theme_->name));
    }

    void showTextAppearance()
    {
        if (!appearanceDialog_) {
            appearanceDialog_ = new QDialog(this, Qt::Tool);
            appearanceDialog_->setObjectName(QStringLiteral("textAppearance"));
            appearanceDialog_->setWindowTitle(QStringLiteral("Text Appearance"));
            auto *layout = new QVBoxLayout(appearanceDialog_);
            auto *form = new QFormLayout;
            layout->addLayout(form);

            std::array<QSlider *, std::size(appearanceControls)> sliders{};
            for (size_t i = 0; i < sliders.size(); ++i) {
                const auto &control = appearanceControls[i];
                auto *slider = new QSlider(Qt::Horizontal, appearanceDialog_);
                slider->setObjectName(QString::fromLatin1(control.key));
                slider->setRange(control.minimum, control.maximum);
                slider->setPageStep(5);
                slider->setMinimumWidth(200);
                slider->setValue(appearance_.*control.value);
                sliders[i] = slider;

                auto *number = new QLabel(QString::number(slider->value()) + QLatin1Char('%'), appearanceDialog_);
                number->setMinimumWidth(number->fontMetrics().horizontalAdvance(QStringLiteral("160%")) + 4);
                number->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
                auto *row = new QHBoxLayout;
                row->addWidget(slider, 1);
                row->addWidget(number);
                auto *label = new QLabel(QString::fromLatin1(control.label), appearanceDialog_);
                label->setBuddy(slider);
                slider->setAccessibleName(label->text());
                form->addRow(label, row);

                connect(slider, &QSlider::valueChanged, this, [this, number, i, member = control.value](int value) {
                    number->setText(QString::number(value) + QLatin1Char('%'));
                    appearance_.*member = value;
                    changedAppearance_[i] = true;
                    if (!appearanceUpdate_.isActive())
                        appearanceUpdate_.start();
                });
            }

            auto *buttons = new QDialogButtonBox(QDialogButtonBox::Reset | QDialogButtonBox::Close, appearanceDialog_);
            layout->addWidget(buttons);
            connect(buttons->button(QDialogButtonBox::Reset), &QPushButton::clicked, this, [sliders] {
                const TextAppearance defaults;
                for (size_t i = 0; i < sliders.size(); ++i)
                    sliders[i]->setValue(defaults.*appearanceControls[i].value);
            });
            connect(buttons, &QDialogButtonBox::rejected, appearanceDialog_, &QDialog::reject);
            connect(appearanceDialog_, &QDialog::finished, this, [this] { saveAppearance(); });

            appearanceDialog_->adjustSize();
            appearanceDialog_->move(mapToGlobal(QPoint(width() - appearanceDialog_->width() - 30, 86)));
        }
        appearanceDialog_->show();
        appearanceDialog_->raise();
        appearanceDialog_->activateWindow();
    }

    void saveAppearance()
    {
        if (std::ranges::none_of(changedAppearance_, [](bool changed) { return changed; }))
            return;
        QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
        settings.beginGroup(QStringLiteral("TextAppearance"));
        for (size_t i = 0; i < changedAppearance_.size(); ++i) {
            if (std::exchange(changedAppearance_[i], false)) {
                const auto &control = appearanceControls[i];
                settings.setValue(QString::fromLatin1(control.key), appearance_.*control.value);
            }
        }
    }

#ifdef Q_OS_WIN
    void updateMemory()
    {
        // Use the EX2 layout on recent Windows, including with SDKs that predate the type.
        struct ExtendedCounters {
            PROCESS_MEMORY_COUNTERS_EX counters;
            SIZE_T privateWorkingSet;
            ULONG64 sharedCommit;
        } sample{};
        auto *counters = reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&sample.counters);
        const HANDLE process = GetCurrentProcess();
        QString label;
        if (GetProcessMemoryInfo(process, counters, sizeof(sample)) && sample.privateWorkingSet) {
            label = QStringLiteral("Private WS %1 MB  ·  WS %2 MB")
                .arg(double(sample.privateWorkingSet) / 1e6, 0, 'f', 1)
                .arg(double(sample.counters.WorkingSetSize) / 1e6, 0, 'f', 1);
        } else if (GetProcessMemoryInfo(process, counters, sizeof(sample.counters))) {
            label = QStringLiteral("WS %1 MB").arg(double(sample.counters.WorkingSetSize) / 1e6, 0, 'f', 1);
        }
        if (memory_->text() != label)
            memory_->setText(label);
    }

    QLabel *memory_;
#endif

    QTabWidget *tabs_;
    QAction *saveAction_;
    QAction *saveAsAction_;
    QLabel *position_;
    LanguageChoices languageChoices_;
    QComboBox *languagePicker_;
    QLabel *encodingAndSize_;
    const Theme *theme_;
    TextAppearance appearance_;
    std::array<bool, std::size(appearanceControls)> changedAppearance_{};
    QDialog *appearanceDialog_ = nullptr;
    RunPane *runPane_ = nullptr;
    QPointer<CodeEdit> runSource_;
    QString runSourcePath_;
    QTimer appearanceUpdate_;
    int fontSize_ = 15;
    int wheelZoomDelta_ = 0;
    bool closeApproved_ = false;
};

} // namespace

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Retina Code"));
    app.setWindowIcon(QIcon(QStringLiteral(":/icons/retina-code.ico")));
    useDarkWidgets(app);

    auto *window = EditorWindow::create();
    window->show();
    const auto files = app.arguments().mid(1);
    if (files.isEmpty())
        window->loadSamples();
    else
        window->openFiles(files);
    return app.exec();
}
