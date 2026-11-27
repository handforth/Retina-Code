// Editor test harness: renders scenarios to images and replays scripted input, and records what the editor shows
// and does. tests/test.bat builds it once per editor: an adapter file includes that editor's code, then this file,
// and then defines the adapter_* functions declared below. The scenarios and the recording are the same for every
// editor, so two recordings can be compared line by line.
//
//   editor_test render <output> [--save <folder>] [--only <name>]   one line per scenario: size and pixel hash
//   editor_test behavior <output> [--save <folder>] [--only <case>]  one line per input step: text, caret, scroll, image
//   editor_test accessibility <output> [--only <case>]              per input step: screen reader events and answers
//   editor_test window <output>                                     per step on whole windows: tabs, status, dialogs, files, runs
//   editor_test bench                                               time and memory to open, page through, and type in a large file
//   editor_test runbench                                            time and memory to build and run, and to show a flood of output
//   editor_test compare <reference> <current>
//   editor_test onscreen                                            checks hidden rendering against a shown window
//
// The display scale comes from QT_SCALE_FACTOR. Windows stay hidden (WA_DontShowOnScreen) and are made active through
// Qt's window-system interface, so the caret and focus colors draw the same way they do on screen.

#include <QAbstractButton>
#include <QAbstractScrollArea>
#include <QAccessible>
#include <QApplication>
#include <QClipboard>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QDockWidget>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QFileDialog>
#include <QImage>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListView>
#include <QMainWindow>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QMimeData>
#include <QMouseEvent>
#include <QPixmap>
#include <QRegularExpression>
#include <QScreen>
#include <QScrollBar>
#include <QSettings>
#include <QSlider>
#include <QStatusBar>
#include <QStyleHints>
#include <QTabWidget>
#include <QTextBlock>
#include <QPlainTextEdit>
#include <QTextEdit>
#include <QTextCharFormat>
#include <QTimer>
#include <QUrl>
#include <QWheelEvent>
#include <qpa/qwindowsysteminterface.h>
#include <QtGui/private/qfont_p.h>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <psapi.h>

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

struct TestAppearance {
    int stroke;
    int saturation;
    int brightness;
    int contrast;
};

static const TestAppearance DEFAULT_APPEARANCE = {0, 100, 100, 100};

//
// Supplied by the adapter for the editor under test.
//

static void adapter_setup_application(QApplication &application);

// An editor for one document, as a top-level widget that isn't shown yet.
static QWidget *adapter_create_editor(const QString &name, const QString &text, int theme, int font_size, TestAppearance appearance);

// A whole editor window with these files open in tabs, using the theme as the saved default.
static QWidget *adapter_create_window(const QStringList &paths, int theme);

// Stops anything in the window that changes over time, like the memory readout.
static void adapter_freeze_window(QWidget *window);

static QString adapter_text(QWidget *editor);
static void adapter_selection(QWidget *editor, int &anchor, int &caret);
static void adapter_set_selection(QWidget *editor, int anchor, int caret);
static void adapter_scroll(QWidget *editor, int &x, int &y);
static void adapter_set_scroll(QWidget *editor, int x, int y);

// Where the caret would be drawn at a text position, in the coordinates of the widget that gets mouse events.
static QRect adapter_caret_rect(QWidget *editor, int position);
static QWidget *adapter_mouse_target(QWidget *editor);

static bool adapter_overwrite(QWidget *editor);
static void adapter_set_overwrite(QWidget *editor, bool overwrite);
static void adapter_show_completions(QWidget *editor);
static void adapter_toggle_comment(QWidget *editor);
static bool adapter_completion_visible(QWidget *editor);

//
// Hashes.
//

static uint64_t hash_bytes(uint64_t hash, const void *data, size_t size)
{
    const uint8_t *bytes = (const uint8_t *)data;
    for (size_t index = 0; index < size; ++index) {
        hash ^= bytes[index];
        hash *= 1099511628211ull;
    }

    return hash;
}

static const uint64_t HASH_START = 14695981039346656037ull;

static uint64_t hash_image(const QImage &image)
{
    uint64_t hash = HASH_START;
    for (int y = 0; y < image.height(); ++y)
        hash = hash_bytes(hash, image.constScanLine(y), size_t(image.width()) * 4);

    return hash;
}

static uint64_t hash_text(const QString &text)
{
    return hash_bytes(HASH_START, text.constData(), size_t(text.size()) * 2);
}

//
// Windows and focus.
//

static void process_events()
{
    QCoreApplication::processEvents();
    QCoreApplication::processEvents();
}

// Shows a widget without putting it on screen, so it gets its size, layout, and paint like a visible window.
static void show_hidden(QWidget *widget, int width, int height)
{
    widget->setAttribute(Qt::WA_DontShowOnScreen);
    widget->resize(width, height);
    widget->show();
    widget->winId();
    process_events();
}

// Makes the window the active one, as if the user clicked it, and gives the widget keyboard focus.
static void activate(QWidget *window, QWidget *focus)
{
    QWindowSystemInterface::handleFocusWindowChanged(window->windowHandle(), Qt::ActiveWindowFocusReason);
    process_events();
    focus->setFocus(Qt::OtherFocusReason);
    process_events();
}

static void deactivate()
{
    QWindowSystemInterface::handleFocusWindowChanged(nullptr, Qt::ActiveWindowFocusReason);
    process_events();
}

static QImage capture(QWidget *widget)
{
    return widget->grab().toImage().convertToFormat(QImage::Format_ARGB32);
}

// A font engine draws glyphs at a number of subpixel positions that Qt measures from the first glyph drawn with
// it, and Qt drops idle engines on a timer. So without this, a rendering would depend on what was drawn before it
// and on how long that took. Every scenario and behavior case starts with an empty font cache instead.
static void reset_font_cache()
{
    QFontCache::instance()->clear();
}

//
// Settings. Qt keeps them in the registry on Windows, under HKEY_CURRENT_USER. While an adapter creates a window,
// this process's HKEY_CURRENT_USER points at an empty scratch key instead, so the window reads only what the test
// wrote there and the user's own settings are never read or changed. The override is kept that short because
// DirectWrite reads the user's ClearType tuning from the real HKEY_CURRENT_USER.
//

static const wchar_t *SCRATCH_REGISTRY_KEY = L"Software\\Retina Code Tests";

static void begin_scratch_registry()
{
    RegDeleteTreeW(HKEY_CURRENT_USER, SCRATCH_REGISTRY_KEY);

    HKEY scratch;
    RegCreateKeyExW(HKEY_CURRENT_USER, SCRATCH_REGISTRY_KEY, 0, nullptr, 0, KEY_ALL_ACCESS, nullptr, &scratch, nullptr);
    RegOverridePredefKey(HKEY_CURRENT_USER, scratch);
    RegCloseKey(scratch);
}

static void end_scratch_registry()
{
    RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
    RegDeleteTreeW(HKEY_CURRENT_USER, SCRATCH_REGISTRY_KEY);
}

//
// Test documents.
//

struct TestDocument {
    QString name;    // the file name, which picks the language
    QString text;
};

static const char *RUST_SAMPLE = R"(// Edit this file, or open one of your own with Ctrl+O.
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
)";

static const char *CPP_SAMPLE = "// Templates, raw strings, and a few preprocessor lines.\n"
    "#include <vector>\n"
    "#include \"local.h\"\n"
    "#define SQUARE(x) ((x) * (x))\n"
    "\n"
    "namespace demo {\n"
    "\n"
    "template <typename T, typename Allocator = std::allocator<T>>\n"
    "struct Ring {\n"
    "\tT *items;\t// tab-indented field\n"
    "\tsize_t count = 0;\n"
    "\n"
    "\tT &operator[](size_t index) { return items[index % count]; }\n"
    "};\n"
    "\n"
    "static const char *banner = R\"(raw \"string\" with \\n and (parens))\";\n"
    "static const char16_t greeting[] = u\"h\xc3\xa9llo\\tworld\\n\";\n"
    "constexpr int masks[] = {0x1F, 0b1010, 1'000'000, 'x', '\\''};\n"
    "static const char *long_line = \"This line is long enough to need horizontal scrolling in a narrow editor window, "
    "and it keeps going with words and (brackets) and [indices] and {braces} until it is far past the right edge.\";\n"
    "\n"
    "int main(int argc, char **argv)\n"
    "{\n"
    "    std::vector<Ring<int>> rings(argc);\n"
    "    for (auto &ring : rings) {\n"
    "        if (ring.count > 2 && SQUARE(ring.count) < 100)\n"
    "            ring[0] = static_cast<int>(argv[0][0]);   /* block comment */\n"
    "    }\n"
    "    return rings.empty() ? 0 : 1; // trailing comment\n"
    "}\n"
    "\n"
    "} // namespace demo\n";

static QString unicode_sample()
{
    const char16_t *lines[] = {
        u"Plain ASCII line for reference.",
        u"Accents: caf\u00e9 na\u00efve r\u00e9sum\u00e9, decomposed: cafe\u0301 nai\u0308ve",
        u"CJK: \u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8 \u4e2d\u6587\u6587\u672c \ud55c\uad6d\uc5b4 \ud14d\uc2a4\ud2b8",
        u"Emoji: \U0001F600 \U0001F44D\U0001F3FD \U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466 \U0001F1EF\U0001F1F5 \u2764\uFE0F \U0001F366 \u2708\uFE0F 1\uFE0F\u20E3",
        u"Combining: Z\u0324\u0308a\u0301\u0302\u0303l\u0361g\u0489o",
        u"RTL: \u0645\u0631\u062d\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645 and \u05e9\u05dc\u05d5\u05dd \u05e2\u05d5\u05dc\u05dd mixed with English (123) end",
        u"Indic: \u0928\u092e\u0938\u094d\u0924\u0947 \u0915\u094d\u0937\u0924\u094d\u0930\u093f\u092f  Thai: \u0e2a\u0e27\u0e31\u0e2a\u0e14\u0e35\u0e04\u0e23\u0e31\u0e1a",
        u"Math: \U0001D518\U0001D52B\U0001D526\U0001D520\U0001D52C\U0001D521\U0001D522 \U0001D7D9\U0001D7DA\U0001D7DB \u2211\u222b\u221a\u221e \u2260 \u2264",
        u"Spaces: a\tb\tc\t\td  [no-break\u00a0space] [zero\u200bwidth] [soft\u00adhyphen]",
        u"\tTab-indented line",
        u"\t\tTwo tabs then text\twith\ttabs",
        u"Trailing spaces here    ",
        u"",
        u"Box drawing \u250c\u2500\u252c\u2500\u2510 \u2502 \u251c \u2514\u2518 and arrows \u2190 \u2192 \u2191 \u2193",
        u"Control: [\u0001] and a byte order mark [\ufeff] inside",
    };

    QString text;
    for (int round = 0; round < 3; ++round) {
        for (const char16_t *line : lines) {
            text += QString::fromUtf16(line);
            text += u'\n';
        }

        text += u"A long line: ";
        for (int word = 0; word < 60; ++word)
            text += QString::fromUtf16(u"word\u00b7%1 ").arg(round * 100 + word);
        text += u'\n';
    }

    return text;
}

// A C++ document with this many lines, so the line numbers need a given number of digits.
static QString numbered_lines(int count)
{
    QString text;
    for (int line = 1; line <= count; ++line) {
        if (line % 50 == 1)
            text += QStringLiteral("void block_%1() {\n").arg(line);
        else if (line % 50 == 0)
            text += QStringLiteral("}\n");
        else
            text += QStringLiteral("    int value_%1 = %2; // line %1\n").arg(line).arg(line * 7 % 1000);
    }

    return text;
}

static void add_document(std::vector<TestDocument> &documents, const QString &name, const QString &text)
{
    documents.push_back({name, text});
}

// The first lines of every hand-written lexer sample, one document per file.
static void add_language_samples(std::vector<TestDocument> &documents)
{
    QDir samples(QCoreApplication::applicationDirPath() + QStringLiteral("/../tests/lexer/samples"));
    QStringList folders = samples.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);

    for (const QString &folder : folders) {
        QDir directory(samples.filePath(folder));
        QStringList files = directory.entryList(QDir::Files, QDir::Name);
        for (const QString &file : files) {
            QFile input(directory.filePath(file));
            if (!input.open(QIODevice::ReadOnly))
                continue;

            QStringList lines = QString::fromUtf8(input.readAll()).split(u'\n');
            QString text = lines.mid(0, 60).join(u'\n');
            text.remove(u'\r');
            add_document(documents, file, text);
        }
    }
}

// Fixed documents first, so their indexes below stay the same.
enum DocumentIndex {
    DOCUMENT_RUST, DOCUMENT_CPP, DOCUMENT_UNICODE, DOCUMENT_LARGE,
    DOCUMENT_LINES_9, DOCUMENT_LINES_99, DOCUMENT_LINES_999, DOCUMENT_LINES_10000, DOCUMENT_EMPTY,
    DOCUMENT_LANGUAGE_SAMPLES,    // the first of the lexer samples, which follow the fixed documents
};

static std::vector<TestDocument> make_documents()
{
    std::vector<TestDocument> documents;
    add_document(documents, QStringLiteral("main.rs"), QString::fromUtf8(RUST_SAMPLE));
    add_document(documents, QStringLiteral("demo.cpp"), QString::fromUtf8(CPP_SAMPLE));
    add_document(documents, QStringLiteral("unicode.txt"), unicode_sample());
    add_document(documents, QStringLiteral("large.cpp"), numbered_lines(3200));
    add_document(documents, QStringLiteral("nine.cpp"), numbered_lines(9));
    add_document(documents, QStringLiteral("ninety_nine.cpp"), numbered_lines(99));
    add_document(documents, QStringLiteral("nine_hundred.cpp"), numbered_lines(999));
    add_document(documents, QStringLiteral("ten_thousand.cpp"), numbered_lines(10000));
    add_document(documents, QStringLiteral("empty.txt"), QString());
    add_language_samples(documents);
    return documents;
}

// The text offset of a line and column, with the column clamped to the line.
static int position_at(const QString &text, int line, int column)
{
    int start = 0;
    for (int index = 0; index < line; ++index) {
        int end = text.indexOf(u'\n', start);
        if (end < 0)
            return int(text.size());
        start = end + 1;
    }

    int end = text.indexOf(u'\n', start);
    if (end < 0)
        end = int(text.size());

    return start + (column < end - start ? column : end - start);
}

static int theme_index(const char *name)
{
    for (size_t index = 0; index < sizeof themes / sizeof themes[0]; ++index) {
        if (!strcmp(themes[index].name, name))
            return int(index);
    }

    return 0;
}

//
// Render scenarios.
//

struct RenderScenario {
    QString name;
    int document;
    int theme;
    int font_size;
    TestAppearance appearance;
    int width, height;            // the editor's logical size
    bool focused;
    int anchor, caret;            // -1 leaves the caret at the start
    int scroll_x, scroll_y;       // scroll bar values, -1 leaves them alone
    bool overwrite;
    QString typed;                // typed before the capture, as with a completion prefix
    bool show_completions;
    int completion_down;          // Down presses in the completion list
    QString preedit;              // input-method text being composed at the caret
    bool window;                  // the whole editor window instead of one editor
    QList<int> window_documents;
};

static RenderScenario base_scenario(const QString &name, int document)
{
    RenderScenario scenario;
    scenario.name = name;
    scenario.document = document;
    scenario.theme = theme_index("Monokai");
    scenario.font_size = 15;
    scenario.appearance = DEFAULT_APPEARANCE;
    scenario.width = 720;
    scenario.height = 400;
    scenario.focused = true;
    scenario.anchor = scenario.caret = -1;
    scenario.scroll_x = scenario.scroll_y = -1;
    scenario.overwrite = false;
    scenario.show_completions = false;
    scenario.completion_down = 0;
    scenario.window = false;
    return scenario;
}

static void set_caret(RenderScenario &scenario, const std::vector<TestDocument> &documents, int line, int column)
{
    scenario.anchor = scenario.caret = position_at(documents[scenario.document].text, line, column);
}

static void set_selection(RenderScenario &scenario, const std::vector<TestDocument> &documents,
                          int anchor_line, int anchor_column, int line, int column)
{
    const QString &text = documents[scenario.document].text;
    scenario.anchor = position_at(text, anchor_line, anchor_column);
    scenario.caret = position_at(text, line, column);
}

static std::vector<RenderScenario> make_render_scenarios(const std::vector<TestDocument> &documents)
{
    std::vector<RenderScenario> scenarios;
    int theme_count = int(sizeof themes / sizeof themes[0]);
    int monokai = theme_index("Monokai");
    int classic = theme_index("Classic");

    // Every theme on the Rust sample.
    for (int theme = 0; theme < theme_count; ++theme) {
        RenderScenario scenario = base_scenario(QStringLiteral("theme_%1").arg(theme), DOCUMENT_RUST);
        scenario.theme = theme;
        set_caret(scenario, documents, 2, 4);
        scenarios.push_back(scenario);
    }

    // Every zoom size on the C++ sample.
    for (int size = 9; size <= 36; ++size) {
        RenderScenario scenario = base_scenario(QStringLiteral("size_%1").arg(size), DOCUMENT_CPP);
        scenario.font_size = size;
        set_caret(scenario, documents, 5, 10);
        scenarios.push_back(scenario);
    }

    // Text appearance: stroke weight and the color sliders, on a dark and a light theme.
    int strokes[] = {0, 10, 30, 31, 60, 100};
    TestAppearance colors[] = {{0, 100, 100, 100}, {0, 0, 65, 65}, {0, 160, 135, 135}, {0, 50, 100, 135}};
    int appearance_themes[] = {monokai, classic};
    for (int theme : appearance_themes) {
        for (int stroke : strokes) {
            for (int color = 0; color < 4; ++color) {
                RenderScenario scenario = base_scenario(QStringLiteral("appearance_t%1_s%2_c%3").arg(theme).arg(stroke).arg(color), DOCUMENT_RUST);
                scenario.theme = theme;
                scenario.appearance = colors[color];
                scenario.appearance.stroke = stroke;
                set_selection(scenario, documents, 14, 8, 15, 20);
                scenarios.push_back(scenario);
            }
        }
    }

    // Every language sample.
    for (int document = DOCUMENT_LANGUAGE_SAMPLES; document < int(documents.size()); ++document) {
        RenderScenario scenario = base_scenario(QStringLiteral("language_%1").arg(documents[document].name), document);
        set_caret(scenario, documents, 1, 0);
        scenarios.push_back(scenario);
    }

    // Unicode: selections across emoji, combining marks, and right-to-left text, at three sizes and two scroll offsets.
    int sizes[] = {11, 15, 24};
    int horizontal_offsets[] = {0, 200};
    int selections[][4] = {{0, 0, 0, 0}, {5, 6, 5, 11}, {5, 4, 5, 40}, {3, 8, 3, 24}, {1, 10, 6, 12}};
    for (int size : sizes) {
        for (int scroll_x : horizontal_offsets) {
            for (int selection = 0; selection < 5; ++selection) {
                RenderScenario scenario = base_scenario(QStringLiteral("unicode_z%1_x%2_s%3").arg(size).arg(scroll_x).arg(selection), DOCUMENT_UNICODE);
                scenario.font_size = size;
                int *range = selections[selection];
                set_selection(scenario, documents, range[0], range[1], range[2], range[3]);
                scenario.scroll_x = scroll_x;
                scenarios.push_back(scenario);
            }
        }
    }

    // Unicode: the caret beside each kind of character.
    int carets[][2] = {{1, 27}, {1, 31}, {2, 5}, {3, 7}, {3, 10}, {3, 13}, {4, 12}, {5, 9}, {6, 10}, {7, 8}, {8, 9}, {9, 0}, {10, 2}, {13, 13}};
    for (int index = 0; index < int(sizeof carets / sizeof carets[0]); ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("unicode_caret_%1").arg(index), DOCUMENT_UNICODE);
        set_caret(scenario, documents, carets[index][0], carets[index][1]);
        scenarios.push_back(scenario);
    }

    // Editor states on the C++ sample.
    int cpp_selections[][4] = {{2, 0, 2, 8}, {7, 0, 13, 4}, {9, 1, 10, 3}, {15, 30, 15, 40}, {0, 0, 30, 0},
                               {20, 0, 21, 0}, {21, 5, 20, 2}, {12, 0, 12, 60}};
    for (int index = 0; index < 8; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("selection_%1").arg(index), DOCUMENT_CPP);
        int *range = cpp_selections[index];
        set_selection(scenario, documents, range[0], range[1], range[2], range[3]);
        scenarios.push_back(scenario);
    }

    // Bracket matching: the caret beside brackets, inside a string, and at line ends.
    int brackets[][2] = {{3, 15}, {3, 16}, {3, 28}, {12, 16}, {12, 17}, {15, 40}, {22, 34}, {27, 4}, {24, 23}, {3, 27}};
    for (int index = 0; index < int(sizeof brackets / sizeof brackets[0]); ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("bracket_%1").arg(index), DOCUMENT_CPP);
        set_caret(scenario, documents, brackets[index][0], brackets[index][1]);
        scenarios.push_back(scenario);
    }

    // Overwrite mode draws a block caret.
    int overwrite_carets[][2] = {{8, 3}, {9, 1}, {29, 0}};
    for (int index = 0; index < 3; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("overwrite_%1").arg(index), DOCUMENT_CPP);
        scenario.overwrite = true;
        set_caret(scenario, documents, overwrite_carets[index][0], overwrite_carets[index][1]);
        scenarios.push_back(scenario);
    }

    // Without focus: no caret, and the inactive selection colors.
    for (int index = 0; index < 2; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("unfocused_%1").arg(index), DOCUMENT_CPP);
        scenario.focused = false;
        if (index)
            set_selection(scenario, documents, 7, 0, 9, 5);
        scenarios.push_back(scenario);
    }

    // Horizontal scrolling on the long line, and a narrow editor.
    int scroll_offsets[] = {0, 150, 600};
    for (int index = 0; index < 3; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("scroll_x_%1").arg(index), DOCUMENT_CPP);
        scenario.width = 420;
        set_caret(scenario, documents, 18, 0);
        scenario.scroll_x = scroll_offsets[index];
        scenarios.push_back(scenario);
    }

    // Vertical scrolling through a long file, down to the end.
    int scroll_lines[] = {1, 50, 777, 3150, 100000};
    for (int index = 0; index < 5; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("scroll_y_%1").arg(index), DOCUMENT_LARGE);
        set_caret(scenario, documents, 0, 0);
        scenario.scroll_y = scroll_lines[index];
        scenarios.push_back(scenario);
    }

    // Line number widths, and an empty document.
    int gutter_documents[] = {DOCUMENT_LINES_9, DOCUMENT_LINES_99, DOCUMENT_LINES_999, DOCUMENT_LINES_10000, DOCUMENT_EMPTY};
    for (int index = 0; index < 5; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("gutter_%1").arg(index), gutter_documents[index]);
        set_caret(scenario, documents, 0, 0);
        scenarios.push_back(scenario);
    }

    // Input-method text being composed, in plain text and in code.
    const char16_t *preedits[] = {u"\u306b\u307b\u3093", u"\u65e5\u672c\u8a9e\u5165\u529b", u"pinyin", u"\u0101"};
    int preedit_lines[][3] = {{DOCUMENT_UNICODE, 0, 5}, {DOCUMENT_UNICODE, 2, 8}, {DOCUMENT_CPP, 22, 8}, {DOCUMENT_RUST, 13, 0}};
    for (int index = 0; index < 4; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("preedit_%1").arg(index), preedit_lines[index][0]);
        set_caret(scenario, documents, preedit_lines[index][1], preedit_lines[index][2]);
        scenario.preedit = QString::fromUtf16(preedits[index]);
        scenarios.push_back(scenario);
    }

    // The completion list, opened by typing or by Ctrl+Space, near the top and the bottom.
    struct CompletionCase { int document, line, column; const char *typed; bool request; int down; };
    CompletionCase completions[] = {
        {DOCUMENT_CPP, 23, 0, "    ri", false, 0}, {DOCUMENT_CPP, 23, 0, "    st", true, 2}, {DOCUMENT_CPP, 28, 0, "SQ", true, 0},
        {DOCUMENT_RUST, 13, 0, "    en", false, 1}, {DOCUMENT_RUST, 33, 0, "        as", true, 0}, {DOCUMENT_LARGE, 3, 0, "va", true, 5},
    };
    for (int index = 0; index < 6; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("completion_%1").arg(index), completions[index].document);
        set_caret(scenario, documents, completions[index].line, completions[index].column);
        scenario.typed = QString::fromUtf8(completions[index].typed);
        scenario.show_completions = completions[index].request;
        scenario.completion_down = completions[index].down;
        scenarios.push_back(scenario);
    }

    // Whole windows: tabs, menus, the status bar, and the language picker.
    QList<int> window_sets[] = {
        {DOCUMENT_RUST}, {DOCUMENT_RUST, DOCUMENT_CPP}, {DOCUMENT_CPP, DOCUMENT_UNICODE, DOCUMENT_RUST},
        {DOCUMENT_UNICODE}, {DOCUMENT_EMPTY}, {DOCUMENT_LINES_999, DOCUMENT_RUST},
    };
    int window_themes[] = {monokai, monokai, classic, monokai, theme_index("Dark+ (2019)"), classic};
    for (int index = 0; index < 6; ++index) {
        RenderScenario scenario = base_scenario(QStringLiteral("window_%1").arg(index), window_sets[index][0]);
        scenario.window = true;
        scenario.window_documents = window_sets[index];
        scenario.theme = window_themes[index];
        scenario.width = 900;
        scenario.height = 560;
        scenario.focused = index != 3;
        scenarios.push_back(scenario);
    }

    return scenarios;
}

//
// Input events.
//

static QString key_text(int key)
{
    switch (key) {
        case Qt::Key_Return: return QStringLiteral("\r");
        case Qt::Key_Tab: return QStringLiteral("\t");
        case Qt::Key_Backspace: return QStringLiteral("\b");
        case Qt::Key_Delete: return QString(QChar(0x7f));
        case Qt::Key_Escape: return QString(QChar(0x1b));
        default: return QString();
    }
}

static void send_key(QWidget *editor, int key, Qt::KeyboardModifiers modifiers, const QString &text)
{
    QKeyEvent press(QEvent::KeyPress, key, modifiers, text);
    QApplication::sendEvent(editor, &press);

    QKeyEvent release(QEvent::KeyRelease, key, modifiers, text);
    QApplication::sendEvent(editor, &release);
}

// The key for a typed character: Qt's key codes for ASCII characters are the uppercase characters themselves.
static void type_character(QWidget *editor, const QString &character)
{
    char16_t ch = character.at(0).unicode();
    int key = Qt::Key_unknown;
    Qt::KeyboardModifiers modifiers = Qt::NoModifier;

    if (ch >= u'a' && ch <= u'z') {
        key = Qt::Key_A + (ch - u'a');
    } else if (ch >= u'A' && ch <= u'Z') {
        key = Qt::Key_A + (ch - u'A');
        modifiers = Qt::ShiftModifier;
    } else if (ch == u'\n') {
        send_key(editor, Qt::Key_Return, Qt::NoModifier, key_text(Qt::Key_Return));
        return;
    } else if (ch == u'\t') {
        send_key(editor, Qt::Key_Tab, Qt::NoModifier, key_text(Qt::Key_Tab));
        return;
    } else if (ch >= 0x20 && ch < 0x7f) {
        key = ch;
        if (QStringLiteral("~!@#$%^&*()_+{}|:\"<>?").contains(QChar(ch)))
            modifiers = Qt::ShiftModifier;
    }

    send_key(editor, key, modifiers, character);
}

// Types text one key at a time. A surrogate pair is one key.
static void type_text(QWidget *editor, const QString &text)
{
    for (qsizetype at = 0; at < text.size();) {
        qsizetype length = text.at(at).isHighSurrogate() && at + 1 < text.size() ? 2 : 1;
        type_character(editor, text.mid(at, length));
        at += length;
    }
}

static void send_mouse(QWidget *target, QEvent::Type type, QPoint point, Qt::MouseButtons buttons, Qt::KeyboardModifiers modifiers)
{
    Qt::MouseButton button = type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton;
    QMouseEvent event(type, QPointF(point), QPointF(target->mapToGlobal(point)), button, buttons, modifiers);
    QApplication::sendEvent(target, &event);
}

static void send_preedit(QWidget *editor, const QString &text)
{
    QTextCharFormat underline;
    underline.setFontUnderline(true);

    QList<QInputMethodEvent::Attribute> attributes;
    attributes.append(QInputMethodEvent::Attribute(QInputMethodEvent::TextFormat, 0, int(text.size()), underline));
    attributes.append(QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, int(text.size()), 1, QVariant()));

    QInputMethodEvent event(text, attributes);
    QApplication::sendEvent(editor, &event);
}

static void send_commit(QWidget *editor, const QString &text)
{
    QInputMethodEvent event;
    event.setCommitString(text);
    QApplication::sendEvent(editor, &event);
}

//
// Rendering.
//

static QImage render_editor(const RenderScenario &scenario, const std::vector<TestDocument> &documents)
{
    const TestDocument &document = documents[scenario.document];
    QWidget *editor = adapter_create_editor(document.name, document.text, scenario.theme, scenario.font_size, scenario.appearance);
    show_hidden(editor, scenario.width, scenario.height);
    if (scenario.focused)
        activate(editor, editor);

    if (scenario.overwrite)
        adapter_set_overwrite(editor, true);
    if (scenario.caret >= 0)
        adapter_set_selection(editor, scenario.anchor, scenario.caret);
    if (!scenario.typed.isEmpty())
        type_text(editor, scenario.typed);
    if (scenario.show_completions)
        adapter_show_completions(editor);
    for (int step = 0; step < scenario.completion_down; ++step)
        send_key(editor, Qt::Key_Down, Qt::NoModifier, QString());
    if (!scenario.preedit.isEmpty())
        send_preedit(editor, scenario.preedit);

    if (scenario.scroll_x >= 0 || scenario.scroll_y >= 0) {
        int x, y;
        adapter_scroll(editor, x, y);
        adapter_set_scroll(editor, scenario.scroll_x >= 0 ? scenario.scroll_x : x, scenario.scroll_y >= 0 ? scenario.scroll_y : y);
    }

    process_events();
    QImage image = capture(editor);
    if (scenario.focused)
        deactivate();

    delete editor;
    process_events();
    return image;
}

static QString document_path(const TestDocument &document)
{
    return QCoreApplication::applicationDirPath() + QStringLiteral("/tests/documents/") + document.name;
}

// Writes the documents that windows open from disk.
static void write_documents(const std::vector<TestDocument> &documents)
{
    QDir().mkpath(QCoreApplication::applicationDirPath() + QStringLiteral("/tests/documents"));
    for (int index = 0; index < DOCUMENT_LANGUAGE_SAMPLES; ++index) {
        QFile file(document_path(documents[index]));
        if (file.open(QIODevice::WriteOnly | QIODevice::Truncate))
            file.write(documents[index].text.toUtf8());
    }
}

static QImage render_window(const RenderScenario &scenario, const std::vector<TestDocument> &documents)
{
    QStringList paths;
    for (int document : scenario.window_documents)
        paths.append(document_path(documents[document]));

    QWidget *window = adapter_create_window(paths, scenario.theme);
    adapter_freeze_window(window);
    show_hidden(window, scenario.width, scenario.height);
    if (scenario.focused)
        activate(window, window->focusWidget() ? window->focusWidget() : window);

    process_events();
    QImage image = capture(window);
    if (scenario.focused)
        deactivate();

    delete window;
    process_events();
    return image;
}

static int run_render(const char *output_path, const char *save_folder, const char *only)
{
    std::vector<TestDocument> documents = make_documents();
    write_documents(documents);
    std::vector<RenderScenario> scenarios = make_render_scenarios(documents);

    FILE *out = fopen(output_path, "wb");
    if (!out)
        return 1;

    if (save_folder)
        QDir().mkpath(QString::fromUtf8(save_folder));

    for (const RenderScenario &scenario : scenarios) {
        if (only && scenario.name != QString::fromUtf8(only))
            continue;

        reset_font_cache();
        QImage image = scenario.window ? render_window(scenario, documents) : render_editor(scenario, documents);
        fprintf(out, "%s %d %d %016llx\n", scenario.name.toUtf8().constData(), image.width(), image.height(),
                (unsigned long long)hash_image(image));

        if (save_folder)
            image.save(QString::fromUtf8(save_folder) + u'/' + scenario.name + QStringLiteral(".png"));
    }

    fclose(out);
    printf("rendered %zu scenarios at scale %.2f\n", scenarios.size(), qApp->devicePixelRatio());
    return 0;
}

//
// Behavior replay.
//

enum class StepKind : uint8_t {
    Key, Text, Click, ShiftClick, DoubleClick, TripleClick, Drag, Wheel, ScrollBar, Complete, ToggleComment, Clipboard, Preedit, Commit,
};

// Mouse steps aim at a text position, clamped to the text length when the step runs, or, when at_point is set,
// at a point in the visible text area given in thousandths of its width and height.
struct Step {
    StepKind kind;
    int key;
    Qt::KeyboardModifiers modifiers;
    QString text;
    int position, position2;    // position2 and point2 are where a drag ends
    QPoint point, point2;
    bool at_point;
    int wheel_delta;            // in eighths of a degree, 120 to a notch, negative to scroll down
};

struct BehaviorCase {
    QString name;
    int document;
    int caret;
    std::vector<Step> steps;
};

static Step make_step(StepKind kind)
{
    Step step;
    step.kind = kind;
    step.key = 0;
    step.modifiers = Qt::NoModifier;
    step.position = step.position2 = 0;
    step.at_point = false;
    step.wheel_delta = 0;
    return step;
}

static void add_keys(BehaviorCase &script, int key, Qt::KeyboardModifiers modifiers = Qt::NoModifier, int count = 1)
{
    for (int index = 0; index < count; ++index) {
        Step step = make_step(StepKind::Key);
        step.key = key;
        step.modifiers = modifiers;
        step.text = (modifiers & (Qt::ControlModifier | Qt::AltModifier)) ? QString() : key_text(key);
        script.steps.push_back(step);
    }
}

// One step per typed character, so the state is recorded after every key. A surrogate pair is one character.
static void add_text(BehaviorCase &script, const QString &text)
{
    for (qsizetype at = 0; at < text.size();) {
        qsizetype length = text.at(at).isHighSurrogate() && at + 1 < text.size() ? 2 : 1;
        Step step = make_step(StepKind::Text);
        step.text = text.mid(at, length);
        script.steps.push_back(step);
        at += length;
    }
}

static void add_mouse(BehaviorCase &script, StepKind kind, int position, int position2 = 0)
{
    Step step = make_step(kind);
    step.position = position;
    step.position2 = position2;
    script.steps.push_back(step);
}

static void add_wheel(BehaviorCase &script, int delta)
{
    Step step = make_step(StepKind::Wheel);
    step.wheel_delta = delta;
    script.steps.push_back(step);
}

static void add_mouse_at_point(BehaviorCase &script, StepKind kind, QPoint point, QPoint point2 = QPoint())
{
    Step step = make_step(kind);
    step.point = point;
    step.point2 = point2;
    step.at_point = true;
    script.steps.push_back(step);
}

static void add_step(BehaviorCase &script, StepKind kind, const QString &text = QString(), int key = 0)
{
    Step step = make_step(kind);
    step.text = text;
    step.key = key;
    script.steps.push_back(step);
}

static BehaviorCase make_case(const QString &name, int document, int caret)
{
    BehaviorCase script;
    script.name = name;
    script.document = document;
    script.caret = caret;
    return script;
}

// Typing rules in several languages, each typed into its own empty document.
struct TypingCase {
    const char *name;
    const char *file;
    const char16_t *text;
};

static const TypingCase TYPING_CASES[] = {
    {"typing_cpp", "typing.cpp", u"int main(int argc) {\nif (argc > 1) {\nreturn \"x\";\n}\nint a[] = {1, 2};\n// done\n"},
    {"typing_python", "typing.py", u"def f(x):\nif x:\nreturn [x, 'y']\nelse:\npass\n\nprint(f\"{x}\")\n"},
    {"typing_rust", "typing.rs", u"fn main() {\nlet v = vec![1, 2];\nmatch v.len() {\n0 => {}\n_ => println!(\"{}\", 'c'),\n}\n}\n"},
    {"typing_html", "typing.html", u"<div class=\"a\">\n<p>text</p>\n<br/>\n</div>\n<script>let s = `x${1}`;</script>\n"},
    {"typing_jsx", "typing.jsx", u"const A = () => (\n<div onClick={() => go(1)}>\n<span>{'hi'}</span>\n</div>\n);\n"},
    {"typing_yaml", "typing.yaml", u"key: |\n  text\nlist:\n  - a: 1\n    b: \"q\"\n"},
    {"typing_lisp", "typing.lisp", u"(defun f (x)\n(let ((y (* x 2)))\n(+ y 1)))\n"},
    {"typing_markdown", "typing.md", u"# Title\n\n* item\n```cpp\nint x = (1);\n```\n"},
};

// Scripted cases for navigation, selection, the mouse, typing rules, undo, the clipboard, completion, and input
// methods. The typing cases add their empty documents to the list first.
static void add_scripted_cases(std::vector<BehaviorCase> &cases, std::vector<TestDocument> &documents)
{
    int typing_count = int(sizeof TYPING_CASES / sizeof TYPING_CASES[0]);
    int first_typing_document = int(documents.size());
    for (int index = 0; index < typing_count; ++index)
        add_document(documents, QString::fromUtf8(TYPING_CASES[index].file), QString());

    const QString &unicode = documents[DOCUMENT_UNICODE].text;
    const QString &cpp = documents[DOCUMENT_CPP].text;

    for (int document : {DOCUMENT_UNICODE, DOCUMENT_CPP}) {
        BehaviorCase script = make_case(document == DOCUMENT_UNICODE ? QStringLiteral("navigate_unicode") : QStringLiteral("navigate_cpp"), document, 0);
        add_keys(script, Qt::Key_Right, Qt::NoModifier, 260);
        add_keys(script, Qt::Key_Left, Qt::NoModifier, 120);
        add_keys(script, Qt::Key_Down, Qt::NoModifier, 18);
        add_keys(script, Qt::Key_Up, Qt::NoModifier, 18);
        for (int line = 0; line < 16; ++line) {
            add_keys(script, Qt::Key_End);
            add_keys(script, Qt::Key_Home);
            add_keys(script, Qt::Key_Home);
            add_keys(script, Qt::Key_Down);
        }
        add_keys(script, Qt::Key_Right, Qt::ControlModifier, 60);
        add_keys(script, Qt::Key_Left, Qt::ControlModifier, 30);
        add_keys(script, Qt::Key_PageDown, Qt::NoModifier, 3);
        add_keys(script, Qt::Key_PageUp, Qt::NoModifier, 2);
        add_keys(script, Qt::Key_End, Qt::ControlModifier);
        add_keys(script, Qt::Key_Home, Qt::ControlModifier);
        cases.push_back(script);
    }

    BehaviorCase select = make_case(QStringLiteral("select_unicode"), DOCUMENT_UNICODE, position_at(unicode, 3, 4));
    add_keys(select, Qt::Key_Right, Qt::ShiftModifier, 30);
    add_keys(select, Qt::Key_Down, Qt::ShiftModifier, 5);
    add_keys(select, Qt::Key_End, Qt::ShiftModifier);
    add_keys(select, Qt::Key_Left, Qt::ShiftModifier | Qt::ControlModifier, 8);
    add_keys(select, Qt::Key_Up, Qt::ShiftModifier, 7);
    add_keys(select, Qt::Key_Home, Qt::ShiftModifier);
    add_keys(select, Qt::Key_PageDown, Qt::ShiftModifier);
    add_keys(select, Qt::Key_A, Qt::ControlModifier);
    add_keys(select, Qt::Key_Left);
    cases.push_back(select);

    BehaviorCase mouse = make_case(QStringLiteral("mouse_unicode"), DOCUMENT_UNICODE, 0);
    for (int line = 0; line < 16; ++line) {
        for (int column = 0; column < 60; column += 7)
            add_mouse(mouse, StepKind::Click, position_at(unicode, line, column));
    }
    for (int line = 0; line < 16; line += 2) {
        for (int column = 1; column < 50; column += 11)
            add_mouse(mouse, StepKind::DoubleClick, position_at(unicode, line, column));
    }
    add_mouse(mouse, StepKind::TripleClick, position_at(unicode, 2, 6));
    add_mouse(mouse, StepKind::TripleClick, position_at(unicode, 5, 20));
    add_mouse(mouse, StepKind::Drag, position_at(unicode, 1, 3), position_at(unicode, 6, 10));
    add_mouse(mouse, StepKind::Drag, position_at(unicode, 5, 30), position_at(unicode, 5, 8));
    add_mouse(mouse, StepKind::Click, position_at(unicode, 3, 2));
    add_mouse(mouse, StepKind::ShiftClick, position_at(unicode, 8, 12));
    add_wheel(mouse, -120);
    add_wheel(mouse, -240);
    add_wheel(mouse, 120);
    cases.push_back(mouse);

    // The scroll bars scroll without moving the caret, a page at a time in the trough.
    BehaviorCase scroll_bars = make_case(QStringLiteral("scroll_bars"), DOCUMENT_CPP, position_at(cpp, 3, 4));
    add_step(scroll_bars, StepKind::ScrollBar, QString(), 1);
    add_step(scroll_bars, StepKind::ScrollBar, QString(), 1);
    add_step(scroll_bars, StepKind::ScrollBar, QString(), -1);
    add_step(scroll_bars, StepKind::ScrollBar, QString(), 2);
    add_step(scroll_bars, StepKind::ScrollBar, QString(), 2);
    add_step(scroll_bars, StepKind::ScrollBar, QString(), -2);
    add_keys(scroll_bars, Qt::Key_Down);
    add_step(scroll_bars, StepKind::ScrollBar, QString(), 1);
    add_keys(scroll_bars, Qt::Key_PageDown);
    cases.push_back(scroll_bars);

    for (int index = 0; index < typing_count; ++index) {
        BehaviorCase script = make_case(QString::fromUtf8(TYPING_CASES[index].name), first_typing_document + index, 0);
        add_text(script, QString::fromUtf16(TYPING_CASES[index].text));
        cases.push_back(script);
    }

    BehaviorCase pairs = make_case(QStringLiteral("pairs_and_indent"), DOCUMENT_CPP, position_at(cpp, 22, 0));
    add_text(pairs, QStringLiteral("x = ("));
    add_text(pairs, QStringLiteral("a[\"b\"]"));
    add_text(pairs, QStringLiteral(")"));
    add_keys(pairs, Qt::Key_Backspace, Qt::NoModifier, 4);
    add_text(pairs, QStringLiteral("{"));
    add_keys(pairs, Qt::Key_Return);
    add_text(pairs, QStringLiteral("'c'"));
    add_keys(pairs, Qt::Key_Backspace, Qt::NoModifier, 3);
    add_keys(pairs, Qt::Key_Up, Qt::ShiftModifier, 3);
    add_keys(pairs, Qt::Key_Tab);
    add_keys(pairs, Qt::Key_Backtab, Qt::ShiftModifier);
    add_keys(pairs, Qt::Key_Backtab, Qt::ShiftModifier);
    add_step(pairs, StepKind::ToggleComment);
    add_step(pairs, StepKind::ToggleComment);
    add_keys(pairs, Qt::Key_Right, Qt::ShiftModifier, 4);
    add_text(pairs, QStringLiteral("("));
    add_text(pairs, QStringLiteral("\""));
    cases.push_back(pairs);

    BehaviorCase undo = make_case(QStringLiteral("undo_redo"), DOCUMENT_CPP, position_at(cpp, 20, 0));
    add_text(undo, QStringLiteral("int first = 1;\n"));
    add_keys(undo, Qt::Key_Up, Qt::NoModifier, 2);
    add_text(undo, QStringLiteral("x"));
    add_text(undo, QStringLiteral("(y"));
    add_step(undo, StepKind::ToggleComment);
    add_keys(undo, Qt::Key_Z, Qt::ControlModifier, 6);
    add_keys(undo, Qt::Key_Y, Qt::ControlModifier, 3);
    add_keys(undo, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier, 1);
    add_text(undo, QStringLiteral("z"));
    add_keys(undo, Qt::Key_Y, Qt::ControlModifier, 2);
    cases.push_back(undo);

    BehaviorCase clipboard = make_case(QStringLiteral("clipboard"), DOCUMENT_CPP, position_at(cpp, 8, 0));
    add_step(clipboard, StepKind::Clipboard, QStringLiteral("pasted line one\r\n\tpasted\tline two\r\n"));
    add_keys(clipboard, Qt::Key_V, Qt::ControlModifier);
    add_keys(clipboard, Qt::Key_Down, Qt::ShiftModifier, 2);
    add_keys(clipboard, Qt::Key_C, Qt::ControlModifier);
    add_keys(clipboard, Qt::Key_End, Qt::ControlModifier);
    add_keys(clipboard, Qt::Key_V, Qt::ControlModifier);
    add_keys(clipboard, Qt::Key_Up, Qt::ShiftModifier, 3);
    add_keys(clipboard, Qt::Key_X, Qt::ControlModifier);
    add_keys(clipboard, Qt::Key_Home, Qt::ControlModifier);
    add_keys(clipboard, Qt::Key_V, Qt::ControlModifier);
    add_keys(clipboard, Qt::Key_Z, Qt::ControlModifier, 3);
    cases.push_back(clipboard);

    BehaviorCase completion = make_case(QStringLiteral("completion"), DOCUMENT_CPP, position_at(cpp, 23, 0));
    add_text(completion, QStringLiteral("    ri"));
    add_keys(completion, Qt::Key_Down);
    add_keys(completion, Qt::Key_Tab);
    add_text(completion, QStringLiteral(";\n    st"));
    add_keys(completion, Qt::Key_Escape);
    add_text(completion, QStringLiteral("a"));
    add_keys(completion, Qt::Key_Backspace);
    add_step(completion, StepKind::Complete);
    add_keys(completion, Qt::Key_Down, Qt::NoModifier, 2);
    add_keys(completion, Qt::Key_Up);
    add_keys(completion, Qt::Key_Return);
    add_text(completion, QStringLiteral(" x"));
    add_step(completion, StepKind::Complete);
    add_keys(completion, Qt::Key_Escape);
    cases.push_back(completion);

    BehaviorCase input_method = make_case(QStringLiteral("input_method"), DOCUMENT_UNICODE, position_at(unicode, 0, 6));
    add_step(input_method, StepKind::Preedit, QString::fromUtf16(u"\u306b\u307b"));
    add_step(input_method, StepKind::Preedit, QString::fromUtf16(u"\u306b\u307b\u3093"));
    add_step(input_method, StepKind::Commit, QString::fromUtf16(u"\u65e5\u672c"));
    add_step(input_method, StepKind::Commit, QStringLiteral("("));
    add_step(input_method, StepKind::Commit, QString::fromUtf16(u"\U0001F600"));
    add_keys(input_method, Qt::Key_Backspace, Qt::NoModifier, 2);
    cases.push_back(input_method);

    BehaviorCase overwrite = make_case(QStringLiteral("overwrite"), DOCUMENT_CPP, position_at(cpp, 8, 0));
    add_keys(overwrite, Qt::Key_Insert);
    add_text(overwrite, QStringLiteral("STRUCT"));
    add_keys(overwrite, Qt::Key_Insert);
    add_text(overwrite, QStringLiteral("x"));
    cases.push_back(overwrite);
}

static uint32_t behavior_seed;

static uint32_t next_random()
{
    behavior_seed ^= behavior_seed << 13;
    behavior_seed ^= behavior_seed >> 17;
    behavior_seed ^= behavior_seed << 5;
    return behavior_seed;
}

// A point in the visible text area, in thousandths of its width and height.
static QPoint random_point()
{
    int x = int(next_random() % 1000);
    int y = int(next_random() % 1000);
    return QPoint(x, y);
}

// Random input with a fixed seed: typing, deleting, moving, selecting, clicking, undoing, and the editor commands.
static void add_fuzz_cases(std::vector<BehaviorCase> &cases)
{
    const char16_t *texts[] = {u"a", u"x", u"_", u"1", u" ", u"(", u")", u"[", u"]", u"{", u"}", u"\"", u"'", u"`", u"<",
                               u">", u"/", u"*", u"#", u":", u";", u",", u".", u"=", u"\t", u"\n", u"\u00e9", u"\u65e5",
                               u"\U0001F600", u"if", u"return", u"<div>", u"//"};
    int moves[] = {Qt::Key_Left, Qt::Key_Right, Qt::Key_Up, Qt::Key_Down, Qt::Key_Home, Qt::Key_End, Qt::Key_PageUp, Qt::Key_PageDown};
    int documents[] = {DOCUMENT_CPP, DOCUMENT_RUST, DOCUMENT_UNICODE, DOCUMENT_LANGUAGE_SAMPLES, DOCUMENT_LANGUAGE_SAMPLES + 20, DOCUMENT_LANGUAGE_SAMPLES + 40, DOCUMENT_LANGUAGE_SAMPLES + 60};

    for (int round = 0; round < int(sizeof documents / sizeof documents[0]); ++round) {
        behavior_seed = 2024u + uint32_t(round) * 7919u;
        BehaviorCase script = make_case(QStringLiteral("fuzz_%1").arg(round), documents[round], 0);

        for (int index = 0; index < 400; ++index) {
            uint32_t roll = next_random() % 100;
            if (roll < 40) {
                add_text(script, QString::fromUtf16(texts[next_random() % (sizeof texts / sizeof texts[0])]));
            } else if (roll < 48) {
                add_keys(script, Qt::Key_Backspace);
            } else if (roll < 52) {
                add_keys(script, Qt::Key_Delete);
            } else if (roll < 70) {
                Qt::KeyboardModifiers modifiers = Qt::NoModifier;
                if (next_random() % 3 == 0)
                    modifiers |= Qt::ShiftModifier;
                if (next_random() % 4 == 0)
                    modifiers |= Qt::ControlModifier;
                add_keys(script, moves[next_random() % 8], modifiers);
            } else if (roll < 74) {
                add_keys(script, next_random() % 2 ? Qt::Key_Tab : Qt::Key_Backtab, next_random() % 2 ? Qt::NoModifier : Qt::ShiftModifier);
            } else if (roll < 79) {
                add_keys(script, Qt::Key_Z, Qt::ControlModifier);
            } else if (roll < 81) {
                add_keys(script, Qt::Key_Y, Qt::ControlModifier);
            } else if (roll < 83) {
                add_step(script, StepKind::ToggleComment);
            } else if (roll < 85) {
                add_step(script, StepKind::Complete);
            } else if (roll < 87) {
                add_keys(script, Qt::Key_Escape);
            } else if (roll < 94) {
                add_mouse_at_point(script, StepKind::Click, random_point());
            } else if (roll < 96) {
                add_mouse_at_point(script, StepKind::DoubleClick, random_point());
            } else if (roll < 98) {
                QPoint from = random_point();
                add_mouse_at_point(script, StepKind::Drag, from, random_point());
            } else {
                add_keys(script, Qt::Key_Insert);
            }
        }

        cases.push_back(script);
    }
}

// The point that puts the caret at a position when clicked, or the middle of the character there for double clicks.
static QPoint click_point(QWidget *editor, int position, bool middle_of_character)
{
    QRect rect = adapter_caret_rect(editor, position);
    if (!middle_of_character)
        return QPoint(rect.left() + 1, rect.center().y());

    QRect next = adapter_caret_rect(editor, position + 1);
    int x = next.top() == rect.top() && next.left() > rect.left() ? (rect.left() + next.left()) / 2 : rect.left() + 2;
    return QPoint(x, rect.center().y());
}

// Where a mouse step presses and where a drag ends, in the coordinates of the widget that gets mouse events.
static void mouse_points(QWidget *editor, QWidget *target, const Step &step, QPoint &point, QPoint &point2)
{
    if (step.at_point) {
        point = QPoint(step.point.x() * target->width() / 1000, step.point.y() * target->height() / 1000);
        point2 = QPoint(step.point2.x() * target->width() / 1000, step.point2.y() * target->height() / 1000);
        return;
    }

    int length = int(adapter_text(editor).size());
    int position = step.position < length ? step.position : length;
    int position2 = step.position2 < length ? step.position2 : length;
    bool middle_of_character = step.kind == StepKind::DoubleClick || step.kind == StepKind::TripleClick;
    point = click_point(editor, position, middle_of_character);
    point2 = click_point(editor, position2, false);
}

static void run_step(QWidget *editor, const Step &step)
{
    // The mouse steps are the ones from Click to Drag in StepKind.
    QWidget *target = adapter_mouse_target(editor);
    QPoint point, point2;
    if (step.kind >= StepKind::Click && step.kind <= StepKind::Drag)
        mouse_points(editor, target, step, point, point2);

    switch (step.kind) {
        case StepKind::Key:
            send_key(editor, step.key, step.modifiers, step.text);
            break;

        case StepKind::Text:
            type_text(editor, step.text);
            break;

        case StepKind::Click:
        case StepKind::ShiftClick: {
            Qt::KeyboardModifiers modifiers = step.kind == StepKind::ShiftClick ? Qt::ShiftModifier : Qt::NoModifier;
            send_mouse(target, QEvent::MouseButtonPress, point, Qt::LeftButton, modifiers);
            send_mouse(target, QEvent::MouseButtonRelease, point, Qt::NoButton, modifiers);
            break;
        }

        case StepKind::DoubleClick:
        case StepKind::TripleClick: {
            send_mouse(target, QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseButtonRelease, point, Qt::NoButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseButtonDblClick, point, Qt::LeftButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseButtonRelease, point, Qt::NoButton, Qt::NoModifier);
            if (step.kind == StepKind::TripleClick) {
                send_mouse(target, QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::NoModifier);
                send_mouse(target, QEvent::MouseButtonRelease, point, Qt::NoButton, Qt::NoModifier);
            }
            break;
        }

        // A press inside a selection would start dragging the selected text, which runs a modal loop that waits
        // for the real mouse. So a click first puts the caret where the drag starts, and the drag only selects.
        case StepKind::Drag:
            send_mouse(target, QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseButtonRelease, point, Qt::NoButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseMove, (point + point2) / 2, Qt::LeftButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseMove, point2, Qt::LeftButton, Qt::NoModifier);
            send_mouse(target, QEvent::MouseButtonRelease, point2, Qt::NoButton, Qt::NoModifier);
            break;

        case StepKind::Wheel: {
            QPoint middle(target->width() / 2, target->height() / 2);
            QWheelEvent wheel(QPointF(middle), QPointF(target->mapToGlobal(middle)), QPoint(), QPoint(0, step.wheel_delta),
                              Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
            QApplication::sendEvent(target, &wheel);
            break;
        }

        // A click on a scroll bar's arrows or trough: key 1 and -1 turn a page down and up, 2 and -2 step right and left.
        case StepKind::ScrollBar: {
            QAbstractScrollArea *area = static_cast<QAbstractScrollArea *>(editor);
            bool page = step.key == 1 || step.key == -1;
            QScrollBar *bar = page ? area->verticalScrollBar() : area->horizontalScrollBar();
            if (page)
                bar->triggerAction(step.key > 0 ? QAbstractSlider::SliderPageStepAdd : QAbstractSlider::SliderPageStepSub);
            else
                bar->triggerAction(step.key > 0 ? QAbstractSlider::SliderSingleStepAdd : QAbstractSlider::SliderSingleStepSub);
            break;
        }

        case StepKind::Complete:
            adapter_show_completions(editor);
            break;

        case StepKind::ToggleComment:
            adapter_toggle_comment(editor);
            break;

        case StepKind::Clipboard:
            QApplication::clipboard()->setText(step.text);
            break;

        case StepKind::Preedit:
            send_preedit(editor, step.text);
            break;

        case StepKind::Commit:
            send_commit(editor, step.text);
            break;
    }

    process_events();
}

static const char *step_name(StepKind kind)
{
    switch (kind) {
        case StepKind::Key: return "key";
        case StepKind::Text: return "text";
        case StepKind::Click: return "click";
        case StepKind::ShiftClick: return "shift_click";
        case StepKind::DoubleClick: return "double_click";
        case StepKind::TripleClick: return "triple_click";
        case StepKind::Drag: return "drag";
        case StepKind::Wheel: return "wheel";
        case StepKind::ScrollBar: return "scroll_bar";
        case StepKind::Complete: return "complete";
        case StepKind::ToggleComment: return "toggle_comment";
        case StepKind::Clipboard: return "clipboard";
        case StepKind::Preedit: return "preedit";
        case StepKind::Commit: return "commit";
    }

    return "?";
}

// Writes one line for the editor's state after a step, and saves the step's image when save_folder names a folder.
static void record_state(FILE *out, const QString &name, int step_index, const Step *step, QWidget *editor,
                         const char *save_folder)
{
    int anchor, caret, scroll_x, scroll_y;
    adapter_selection(editor, anchor, caret);
    adapter_scroll(editor, scroll_x, scroll_y);
    QString text = adapter_text(editor);
    QImage image = capture(editor);
    if (save_folder)
        image.save(QStringLiteral("%1/%2_%3.png").arg(QString::fromUtf8(save_folder), name).arg(step_index));

    fprintf(out, "%s %d %s %d %x | text %016llx %d caret %d anchor %d scroll %d %d overwrite %d popup %d image %016llx\n",
            name.toUtf8().constData(), step_index, step ? step_name(step->kind) : "start", step ? step->key : 0,
            step ? unsigned(step->modifiers.toInt()) : 0u, (unsigned long long)hash_text(text), int(text.size()), caret,
            anchor, scroll_x, scroll_y, adapter_overwrite(editor), adapter_completion_visible(editor),
            (unsigned long long)hash_image(image));
}

static int run_behavior(const char *output_path, const char *save_folder, const char *only)
{
    std::vector<TestDocument> documents = make_documents();
    std::vector<BehaviorCase> cases;
    add_scripted_cases(cases, documents);
    add_fuzz_cases(cases);

    FILE *out = fopen(output_path, "wb");
    if (!out)
        return 1;

    // The clipboard cases replace what's on the clipboard, so every format on it is copied first and put back after.
    QMimeData *saved_clipboard = new QMimeData;
    const QMimeData *clipboard = QApplication::clipboard()->mimeData();
    if (clipboard) {
        QStringList formats = clipboard->formats();
        for (const QString &format : formats)
            saved_clipboard->setData(format, clipboard->data(format));
    }

    size_t step_count = 0;
    for (const BehaviorCase &script : cases) {
        if (only && script.name != QString::fromUtf8(only))
            continue;

        reset_font_cache();
        const TestDocument &document = documents[script.document];
        QWidget *editor = adapter_create_editor(document.name, document.text, theme_index("Monokai"), 15, DEFAULT_APPEARANCE);
        show_hidden(editor, 720, 400);
        activate(editor, editor);
        adapter_set_selection(editor, script.caret, script.caret);
        process_events();
        record_state(out, script.name, 0, nullptr, editor, save_folder);

        for (size_t index = 0; index < script.steps.size(); ++index) {
            run_step(editor, script.steps[index]);
            record_state(out, script.name, int(index + 1), &script.steps[index], editor, save_folder);
        }
        step_count += script.steps.size();

        deactivate();
        delete editor;
        process_events();
    }

    QApplication::clipboard()->setMimeData(saved_clipboard);
    fclose(out);
    printf("replayed %zu cases, %zu steps, at scale %.2f\n", cases.size(), step_count, qApp->devicePixelRatio());
    return 0;
}

//
// Comparing recordings.
//

static QStringList read_recording(const char *path)
{
    QFile file(QString::fromUtf8(path));
    if (!file.open(QIODevice::ReadOnly))
        return {};

    return QString::fromUtf8(file.readAll()).split(u'\n', Qt::SkipEmptyParts);
}

static int run_compare(const char *reference_path, const char *current_path)
{
    QStringList reference = read_recording(reference_path);
    QStringList current = read_recording(current_path);
    if (reference.size() != current.size())
        printf("line counts differ: reference %lld, current %lld\n", (long long)reference.size(), (long long)current.size());

    qsizetype count = reference.size() < current.size() ? reference.size() : current.size();
    int differences = 0;
    for (qsizetype index = 0; index < count; ++index) {
        if (reference[index] == current[index])
            continue;

        differences += 1;
        if (differences <= 20)
            printf("  reference: %s\n  current:   %s\n", reference[index].toUtf8().constData(), current[index].toUtf8().constData());
    }

    printf("%s: %lld lines, %d differ\n", current_path, (long long)count, differences);
    return differences || reference.size() != current.size() ? 1 : 0;
}

//
// On-screen check: the hidden rendering the tests use against the pixels of a window that is really on screen.
//

static QImage capture_on_screen(QWidget *window)
{
    HWND handle = (HWND)window->winId();
    RECT client;
    GetClientRect(handle, &client);

    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateCompatibleBitmap(screen, client.right, client.bottom);
    HGDIOBJ previous = SelectObject(memory, bitmap);

    // PW_CLIENTONLY and PW_RENDERFULLCONTENT: the client area as the compositor shows it.
    PrintWindow(handle, memory, 0x1 | 0x2);

    SelectObject(memory, previous);
    QImage image = QImage::fromHBITMAP(bitmap).convertToFormat(QImage::Format_ARGB32);
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return image;
}

static int count_different_pixels(const QImage &a, const QImage &b)
{
    if (a.size() != b.size())
        return -1;

    int count = 0;
    for (int y = 0; y < a.height(); ++y) {
        const uint32_t *left = (const uint32_t *)a.constScanLine(y);
        const uint32_t *right = (const uint32_t *)b.constScanLine(y);
        for (int x = 0; x < a.width(); ++x) {
            if ((left[x] & 0xFFFFFF) != (right[x] & 0xFFFFFF))
                count += 1;
        }
    }

    return count;
}

static int run_onscreen()
{
    std::vector<TestDocument> documents = make_documents();
    write_documents(documents);
    QStringList paths = {document_path(documents[DOCUMENT_RUST]), document_path(documents[DOCUMENT_UNICODE]), document_path(documents[DOCUMENT_CPP])};
    int failures = 0;

    // Windows doesn't paint the part of a window past the edge of the screen, so the window fits on the screen
    // at every scale. Sizes here are logical pixels, with room left for the title bar.
    QRect available = QGuiApplication::primaryScreen()->availableGeometry();
    int width = available.width() - 40 < 900 ? available.width() - 40 : 900;
    int height = available.height() - 80 < 560 ? available.height() - 80 : 560;

    for (int kind = 0; kind < 2; ++kind) {
        reset_font_cache();

        // The same content twice: one window on screen, one hidden the way the tests render.
        QWidget *shown = kind ? adapter_create_window(paths, theme_index("Monokai")) :
                                adapter_create_editor(documents[DOCUMENT_UNICODE].name, documents[DOCUMENT_UNICODE].text, theme_index("Monokai"), 15, DEFAULT_APPEARANCE);
        QWidget *hidden = kind ? adapter_create_window(paths, theme_index("Monokai")) :
                                 adapter_create_editor(documents[DOCUMENT_UNICODE].name, documents[DOCUMENT_UNICODE].text, theme_index("Monokai"), 15, DEFAULT_APPEARANCE);
        if (kind) {
            adapter_freeze_window(shown);
            adapter_freeze_window(hidden);
        }

        shown->setAttribute(Qt::WA_ShowWithoutActivating);
        shown->move(available.left() + 20, available.top() + 20);
        shown->resize(width, height);
        shown->show();
        show_hidden(hidden, width, height);

        // Let the shown window reach the screen.
        for (int round = 0; round < 40; ++round) {
            process_events();
            Sleep(25);
        }

        QImage screen = capture_on_screen(shown);
        QImage shown_grab = capture(shown);
        QImage hidden_grab = capture(hidden);
        int screen_against_hidden = count_different_pixels(screen, hidden_grab);
        int shown_against_hidden = count_different_pixels(shown_grab, hidden_grab);

        const char *what = kind ? "window" : "editor";
        printf("%s: screen %dx%d, hidden %dx%d, %d pixels differ from the screen, %d differ from the shown window's own render\n",
               what, screen.width(), screen.height(), hidden_grab.width(), hidden_grab.height(), screen_against_hidden,
               shown_against_hidden);

        QString folder = QCoreApplication::applicationDirPath() + QStringLiteral("/tests/onscreen");
        QDir().mkpath(folder);
        screen.save(folder + u'/' + QString::fromUtf8(what) + QStringLiteral("_screen.png"));
        hidden_grab.save(folder + u'/' + QString::fromUtf8(what) + QStringLiteral("_hidden.png"));
        if (screen_against_hidden != 0)
            failures += 1;

        delete shown;
        delete hidden;
        process_events();
    }

    return failures ? 1 : 0;
}

//
// Screen readers.
//

static QObject *accessibility_editor;
static QString accessibility_text_events;    // the step's text events so far, as they are written
static bool accessibility_told_of_move;      // a caret or selection event came during the step

// Qt's QPlainTextEdit put U+2029 between lines in the text it sent with events, where the text itself has \n.
static uint64_t hash_accessible_text(QString text)
{
    text.replace(QChar::ParagraphSeparator, u'\n');
    return hash_text(text);
}

// QAccessible's update handler. Text events must match Qt's exactly. Caret and selection events reach Windows screen
// readers as the same notice with nothing in it, which makes them ask for the caret and selection, and Qt sent extra
// and duplicate ones; for those it only matters that one came when something moved.
static void record_accessibility_event(QAccessibleEvent *event)
{
    if (event->object() != accessibility_editor)
        return;

    switch (event->type()) {
        case QAccessible::TextCaretMoved:
        case QAccessible::TextSelectionChanged:
            accessibility_told_of_move = true;
            break;

        case QAccessible::TextInserted: {
            QAccessibleTextInsertEvent *insert = static_cast<QAccessibleTextInsertEvent *>(event);
            accessibility_text_events += QStringLiteral(" inserted %1 %2").arg(insert->changePosition())
                                             .arg(hash_accessible_text(insert->textInserted()), 16, 16, u'0');
            break;
        }

        case QAccessible::TextRemoved: {
            QAccessibleTextRemoveEvent *remove = static_cast<QAccessibleTextRemoveEvent *>(event);
            accessibility_text_events += QStringLiteral(" removed %1 %2").arg(remove->changePosition()).arg(remove->textRemoved().size());
            break;
        }

        case QAccessible::TextUpdated: {
            QAccessibleTextUpdateEvent *update = static_cast<QAccessibleTextUpdateEvent *>(event);
            accessibility_text_events += QStringLiteral(" updated %1 %2 %3").arg(update->changePosition()).arg(update->textRemoved().size())
                                             .arg(hash_accessible_text(update->textInserted()), 16, 16, u'0');
            break;
        }

        default:
            break;
    }
}

// The spans before, at, and after an offset, for each kind of span.
static void record_spans(FILE *out, QAccessibleTextInterface *text, int offset)
{
    QAccessible::TextBoundaryType types[] = {QAccessible::CharBoundary, QAccessible::WordBoundary, QAccessible::SentenceBoundary,
                                             QAccessible::LineBoundary, QAccessible::ParagraphBoundary};
    fprintf(out, "  spans at %d:", offset);
    for (QAccessible::TextBoundaryType type : types) {
        int start, end;
        QString before = text->textBeforeOffset(offset, type, &start, &end);
        fprintf(out, " %d,%d,%016llx", start, end, (unsigned long long)hash_text(before));
        QString at = text->textAtOffset(offset, type, &start, &end);
        fprintf(out, " %d,%d,%016llx", start, end, (unsigned long long)hash_text(at));
        QString after = text->textAfterOffset(offset, type, &start, &end);
        fprintf(out, " %d,%d,%016llx", start, end, (unsigned long long)hash_text(after));
    }
    fprintf(out, "\n");
}

static void record_accessible_state(FILE *out, const QString &name, int step_index, QAccessibleInterface *accessible)
{
    QAccessibleTextInterface *text = accessible->textInterface();
    QAccessible::State state = accessible->state();
    int start, end;
    text->selection(0, &start, &end);
    fprintf(out, "%s %d | role %d editable %d multiline %d selectable %d count %d caret %d selections %d %d %d value %016llx\n",
            name.toUtf8().constData(), step_index, int(accessible->role()), int(state.editable), int(state.multiLine),
            int(state.selectableText), text->characterCount(), text->cursorPosition(), text->selectionCount(), start, end,
            (unsigned long long)hash_text(accessible->text(QAccessible::Value)));
    record_spans(out, text, text->cursorPosition());
}

// Replays the behavior cases and writes, for each step, what the editor tells screen readers: the text events it
// sends, whether it told them when the caret or selection moved, and its answers about the caret, the selection, and
// the text around the caret. The navigation cases also get the spans at every offset.
static int run_accessibility(const char *output_path, const char *only)
{
    std::vector<TestDocument> documents = make_documents();
    std::vector<BehaviorCase> cases;
    add_scripted_cases(cases, documents);
    add_fuzz_cases(cases);

    FILE *out = fopen(output_path, "wb");
    if (!out)
        return 1;

    QAccessible::installUpdateHandler(record_accessibility_event);
    QAccessible::setActive(true);

    for (const BehaviorCase &script : cases) {
        if (only && script.name != QString::fromUtf8(only))
            continue;

        const TestDocument &document = documents[script.document];
        QWidget *editor = adapter_create_editor(document.name, document.text, theme_index("Monokai"), 15, DEFAULT_APPEARANCE);
        show_hidden(editor, 720, 400);
        activate(editor, editor);
        adapter_set_selection(editor, script.caret, script.caret);
        process_events();
        accessibility_editor = editor;

        QAccessibleInterface *accessible = QAccessible::queryAccessibleInterface(editor);
        QAccessibleTextInterface *text = accessible->textInterface();
        record_accessible_state(out, script.name, 0, accessible);
        if (script.name.startsWith(QStringLiteral("navigate_"))) {
            for (int offset = 0; offset <= text->characterCount(); ++offset)
                record_spans(out, text, offset);

            // Qt's QPlainTextEdit gave wrong character rectangles and no point lookups, so these aren't compared. The
            // middle of each character in view must find a position on the same line within the character's width, or
            // the end of the cluster the character belongs to, since the units inside an emoji sequence or a cluster of
            // marks can't be told apart on screen.
            QWidget *viewport = adapter_mouse_target(editor);
            QRect visible(viewport->mapToGlobal(QPoint(0, 0)), viewport->size());
            int checked = 0, wrong = 0;
            for (int offset = 0; offset < text->characterCount(); ++offset) {
                QRect rect = text->characterRect(offset);
                if (!visible.contains(rect.center()))
                    continue;
                int found = text->offsetAtPoint(rect.center());
                QRect at = text->characterRect(found);
                bool on_character = at.y() == rect.y() && at.left() >= rect.left() && at.left() <= rect.left() + rect.width();
                checked += 1;
                wrong += !on_character && text->characterRect(found - 1) != rect;
            }
            printf("%s: %d characters in view, %d found somewhere else\n", script.name.toUtf8().constData(), checked, wrong);
        }

        int caret = text->cursorPosition(), start, end;
        text->selection(0, &start, &end);
        for (size_t index = 0; index < script.steps.size(); ++index) {
            accessibility_text_events.clear();
            accessibility_told_of_move = false;
            run_step(editor, script.steps[index]);

            int new_caret = text->cursorPosition(), new_start, new_end;
            text->selection(0, &new_start, &new_end);
            bool moved = new_caret != caret || new_start != start || new_end != end;
            caret = new_caret;
            start = new_start;
            end = new_end;

            record_accessible_state(out, script.name, int(index + 1), accessible);
            fprintf(out, "  text events:%s\n  told of the move: %s\n", accessibility_text_events.toUtf8().constData(),
                    moved ? (accessibility_told_of_move ? "yes" : "no") : "-");
        }

        accessibility_editor = nullptr;
        deactivate();
        delete editor;
        process_events();
    }

    fclose(out);
    return 0;
}

//
// Window behavior: a whole window driven through its menus, tabs, dialogs, and run pane. It runs on Qt's offscreen
// platform, so no dialog shows on screen, and a timer answers each modal dialog with the next answer a step queued.
// After each step the record has the window's title, tabs, status bar, and output pane.
//

static FILE *window_out;
static QString window_folder;                // the files the steps open, save, and run
static QStringList dialog_answers;           // for the next modal dialogs, in order

// One record per line, without the paths and temporary names that differ between machines and runs.
static void window_print(QString line)
{
    static const QRegularExpression temporary(QStringLiteral("(RetinaCode-|retina-code-)\\w{6}"));
    line.replace(QDir::toNativeSeparators(window_folder), QStringLiteral("<folder>"));
    line.replace(window_folder, QStringLiteral("<folder>"));
    line.replace(temporary, QStringLiteral("\\1XXXXXX"));
    line.replace(u'\n', QStringLiteral("\\n"));
    fprintf(window_out, "%s\n", line.toUtf8().constData());
}

static QString window_file(const char *name)
{
    return window_folder + u'/' + QString::fromUtf8(name);
}

static void write_window_file(const char *name, const QByteArray &bytes)
{
    QFile file(window_file(name));
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        file.write(bytes);
}

// A file's bytes, with line endings and bytes outside ASCII written as escapes.
static void record_file(const char *name)
{
    QFile file(window_file(name));
    if (!file.open(QIODevice::ReadOnly)) {
        window_print(QStringLiteral("file %1 is missing").arg(QString::fromUtf8(name)));
        return;
    }

    QByteArray bytes = file.readAll();
    QString shown;
    for (char byte : bytes) {
        unsigned char value = (unsigned char)byte;
        if (value >= 0x20 && value < 0x7f && value != '\\')
            shown += QChar(value);
        else
            shown += QStringLiteral("\\x%1").arg(unsigned(value), 2, 16, QChar(u'0'));
    }
    window_print(QStringLiteral("file %1, %2 bytes: %3").arg(QString::fromUtf8(name)).arg(bytes.size()).arg(shown));
}

static void record_settings()
{
    QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
    QStringList keys = settings.allKeys();
    keys.sort();
    for (const QString &key : keys)
        window_print(QStringLiteral("setting %1 = %2").arg(key, settings.value(key).toString()));
}

static int count_windows()
{
    int count = 0;
    QWidgetList widgets = QApplication::topLevelWidgets();
    for (QWidget *widget : widgets) {
        if (qobject_cast<QMainWindow *>(widget) && widget->isVisible())
            count += 1;
    }

    return count;
}

static QAction *window_action(QWidget *window, const char *text)
{
    QList<QAction *> actions = window->findChildren<QAction *>();
    for (QAction *action : actions) {
        if (action->text() == QString::fromUtf8(text))
            return action;
    }

    window_print(QStringLiteral("no action ") + QString::fromUtf8(text));
    return nullptr;
}

// Runs a menu command. One that opens a modal dialog returns once the dialog is answered and closed.
static void trigger(QWidget *window, const char *text)
{
    QAction *action = window_action(window, text);
    if (action)
        action->trigger();
    process_events();
}

// The output pane's text widget, a QTextEdit or a QPlainTextEdit, and its document.
static QWidget *window_output(QWidget *window)
{
    QDockWidget *dock = window->findChild<QDockWidget *>();
    return dock ? dock->widget() : nullptr;
}

static QTextDocument *output_document(QWidget *output)
{
    QTextEdit *edit = qobject_cast<QTextEdit *>(output);
    if (edit)
        return edit->document();
    QPlainTextEdit *plain = qobject_cast<QPlainTextEdit *>(output);
    return plain ? plain->document() : nullptr;
}

// A key press and release through the window system, so shortcuts see it the way they see a real key.
static void press_key(QWidget *window, int key)
{
    QWindowSystemInterface::handleKeyEvent<QWindowSystemInterface::SynchronousDelivery>(window->windowHandle(), QEvent::KeyPress, key, Qt::NoModifier);
    QWindowSystemInterface::handleKeyEvent<QWindowSystemInterface::SynchronousDelivery>(window->windowHandle(), QEvent::KeyRelease, key, Qt::NoModifier);
    process_events();
}

// Answers the open modal dialog: a message box gets the button named, a file dialog the path or "cancel", and the
// theme picker "<filter> <downs> ok|cancel", which types the filter, presses Down, then Return or Escape. A click
// that closes a dialog runs after this returns, because it may open the next dialog. A dialog is answered once: one
// that opened another, like Save As asking to replace a file, is still modal for a moment after the other closes.
static void answer_dialog()
{
    QWidget *modal = QApplication::activeModalWidget();
    if (!modal || modal->property("answered").toBool())
        return;
    modal->setProperty("answered", true);

    if (dialog_answers.isEmpty()) {
        window_print(QStringLiteral("dialog without an answer: ") + modal->windowTitle());
        QTimer::singleShot(0, modal, &QWidget::close);
        return;
    }
    QString answer = dialog_answers.takeFirst();

    QMessageBox *box = qobject_cast<QMessageBox *>(modal);
    if (box) {
        window_print(QStringLiteral("message %1: %2 [%3] -> %4").arg(box->windowTitle(), box->text(), box->detailedText(), answer));
        QMessageBox::StandardButton button = QMessageBox::Ok;
        if (answer == QStringLiteral("Save"))
            button = QMessageBox::Save;
        if (answer == QStringLiteral("Discard"))
            button = QMessageBox::Discard;
        if (answer == QStringLiteral("Cancel"))
            button = QMessageBox::Cancel;
        if (answer == QStringLiteral("Yes"))
            button = QMessageBox::Yes;
        if (box->button(button)) {
            QTimer::singleShot(0, box->button(button), &QAbstractButton::click);
        } else {
            window_print(QStringLiteral("the message has no button ") + answer);
            QTimer::singleShot(0, box, &QWidget::close);
        }
        return;
    }

    QFileDialog *files = qobject_cast<QFileDialog *>(modal);
    if (files) {
        window_print(QStringLiteral("file dialog %1 -> %2").arg(files->windowTitle(), answer));
        if (answer == QStringLiteral("cancel")) {
            QTimer::singleShot(0, files, &QDialog::reject);
        } else {
            files->selectFile(answer);
            QTimer::singleShot(0, files, &QDialog::accept);
        }
        return;
    }

    // The theme picker. Return and Escape close it, and nothing opens after it.
    QStringList parts = answer.split(u' ');
    QLineEdit *filter = modal->findChild<QLineEdit *>();
    QListView *list = modal->findChild<QListView *>();
    QWindowSystemInterface::handleFocusWindowChanged(modal->windowHandle(), Qt::ActiveWindowFocusReason);
    process_events();
    for (QChar character : parts[0])
        filter->insert(QString(character));
    for (int index = 0; index < parts[1].toInt(); ++index)
        press_key(modal, Qt::Key_Down);

    int shown = 0;
    for (int row = 0; row < list->model()->rowCount(); ++row) {
        if (!list->isRowHidden(row))
            shown += 1;
    }
    window_print(QStringLiteral("theme picker \"%1\": %2, %3 shown, filter focused %4 -> %5")
                     .arg(parts[0], list->currentIndex().data().toString()).arg(shown).arg(int(filter->hasFocus())).arg(parts[2]));
    press_key(modal, parts[2] == QStringLiteral("ok") ? Qt::Key_Return : Qt::Key_Escape);
}

static void record_menus(QWidget *window)
{
    QList<QAction *> menus = qobject_cast<QMainWindow *>(window)->menuBar()->actions();
    for (QAction *menu : menus) {
        window_print(QStringLiteral("menu ") + menu->text());
        QList<QAction *> actions = menu->menu()->actions();
        for (QAction *action : actions) {
            if (action->isSeparator()) {
                window_print(QStringLiteral("  ---"));
                continue;
            }

            QStringList keys;
            QList<QKeySequence> shortcuts = action->shortcuts();
            for (const QKeySequence &shortcut : shortcuts)
                keys.append(shortcut.toString(QKeySequence::PortableText));
            window_print(QStringLiteral("  %1 [%2] enabled %3 repeat %4 icon %5 context %6").arg(action->text(), keys.join(QStringLiteral(", ")))
                             .arg(int(action->isEnabled())).arg(int(action->autoRepeat())).arg(int(!action->icon().isNull())).arg(int(action->shortcutContext())));
        }
    }
}

// The output pane's lines, with each run of one color, background, or link in braces.
static void record_output(QWidget *window)
{
    QWidget *output = window_output(window);
    if (!output)
        return;

    window_print(QStringLiteral("output %1, read only %2").arg(output->parentWidget()->isVisible() ? "shown" : "hidden").arg(int(output->property("readOnly").toBool())));
    for (QTextBlock block = output_document(output)->begin(); block.isValid(); block = block.next()) {
        QString line, last_style;
        for (QTextBlock::iterator at = block.begin(); !at.atEnd(); ++at) {
            QTextFragment fragment = at.fragment();
            QTextCharFormat format = fragment.charFormat();
            QString style = format.foreground().color().name();
            if (format.background().style() != Qt::NoBrush)
                style += QStringLiteral(" on ") + format.background().color().name();
            if (format.isAnchor())
                style += QStringLiteral(" link ") + format.anchorHref();
            if (style != last_style)
                line += QStringLiteral("{%1}").arg(style);
            line += fragment.text();
            last_style = style;
        }
        window_print(QStringLiteral("| ") + line);
    }
}

static void record_window(QWidget *window, const char *step)
{
    process_events();
    window_print(QStringLiteral("== ") + QString::fromUtf8(step));
    window_print(QStringLiteral("title %1, %2 windows").arg(window->windowTitle()).arg(count_windows()));

    QTabWidget *tabs = window->findChild<QTabWidget *>();
    for (int index = 0; index < tabs->count(); ++index)
        window_print(QStringLiteral("tab%1 %2 | %3").arg(index == tabs->currentIndex() ? "*" : " ", tabs->tabText(index), tabs->tabToolTip(index)));

    QWidget *editor = tabs->currentWidget();
    if (editor) {
        int anchor, caret;
        adapter_selection(editor, anchor, caret);
        QString text = adapter_text(editor);
        window_print(QStringLiteral("text %1 %2 caret %3 anchor %4 focus %5 popup %6").arg(text.size()).arg(hash_text(text), 16, 16, QChar(u'0'))
                         .arg(caret).arg(anchor).arg(int(editor->hasFocus())).arg(int(adapter_completion_visible(editor))));
    }

    QStatusBar *status = qobject_cast<QMainWindow *>(window)->statusBar();
    QStringList labels;
    QList<QLabel *> status_labels = status->findChildren<QLabel *>();
    for (QLabel *label : status_labels) {
        if (!label->toolTip().startsWith(QStringLiteral("Resident memory")))
            labels.append(label->text());
    }
    QComboBox *picker = status->findChild<QComboBox *>();
    window_print(QStringLiteral("status %1 | picker %2 \"%3\", %4 rows, first \"%5\"").arg(labels.join(QStringLiteral(" | ")), picker->isEnabled() ? "on" : "off", picker->currentText())
                     .arg(picker->count()).arg(picker->itemText(0)));
    window_print(QStringLiteral("save %1, save as %2").arg(int(window_action(window, "&Save")->isEnabled())).arg(int(window_action(window, "Save &As…")->isEnabled())));
    record_output(window);
}

// Drops files from a file manager on the window. The window opens them once the drop is done.
static void drop_files(QWidget *window, const char *const *names, int count)
{
    QList<QUrl> urls;
    for (int index = 0; index < count; ++index)
        urls.append(QUrl::fromLocalFile(window_file(names[index])));
    QMimeData mime;
    mime.setUrls(urls);

    QDragEnterEvent enter(QPoint(200, 200), Qt::CopyAction | Qt::MoveAction, &mime, Qt::LeftButton, Qt::NoModifier);
    QApplication::sendEvent(window, &enter);
    QDropEvent drop(QPointF(200, 200), Qt::CopyAction | Qt::MoveAction, &mime, Qt::LeftButton, Qt::NoModifier);
    QApplication::sendEvent(window, &drop);
    window_print(QStringLiteral("drop: enter accepted %1, drop accepted %2, action %3").arg(int(enter.isAccepted())).arg(int(drop.isAccepted())).arg(int(drop.dropAction())));
    process_events();
}

static void select_tab(QWidget *window, const char *label)
{
    QTabWidget *tabs = window->findChild<QTabWidget *>();
    for (int index = 0; index < tabs->count(); ++index) {
        if (tabs->tabText(index) == QString::fromUtf8(label))
            tabs->setCurrentIndex(index);
    }
    process_events();
}

static QWidget *current_editor(QWidget *window)
{
    return window->findChild<QTabWidget *>()->currentWidget();
}

static void control_wheel(QWidget *window, int delta, Qt::KeyboardModifiers modifiers)
{
    QWidget *target = adapter_mouse_target(current_editor(window));
    QPoint middle(target->width() / 2, target->height() / 2);
    QWheelEvent wheel(QPointF(middle), QPointF(target->mapToGlobal(middle)), QPoint(), QPoint(0, delta), Qt::NoButton, modifiers, Qt::NoScrollPhase, false);
    QApplication::sendEvent(target, &wheel);
    process_events();
}

// Runs the event loop for a few milliseconds. processEvents with WaitForMoreEvents can handle an event and then sleep
// on until something else wakes it, which made waits up to a couple of seconds too long.
static void run_events_briefly()
{
    QEventLoop loop;
    QTimer::singleShot(5, &loop, &QEventLoop::quit);
    loop.exec();
}

// Lets a run go on until its output shows the text, for at most a minute.
static void wait_for_output(QWidget *window, const char *text)
{
    QWidget *output = window_output(window);
    QElapsedTimer timer;
    timer.start();
    while (!output || !output_document(output)->toPlainText().contains(QString::fromUtf8(text))) {
        if (timer.elapsed() > 60000) {
            window_print(QStringLiteral("timed out waiting for ") + QString::fromUtf8(text));
            return;
        }
        run_events_briefly();
        output = window_output(window);
    }
    process_events();
}

static void run_and_wait(QWidget *window, const char *ending)
{
    trigger(window, "&Run Current File");
    wait_for_output(window, ending);
}

// Clicks the first link in the output whose address starts with the text, in the middle of the link, after scrolling
// it into view.
static void click_link(QWidget *window, const char *start)
{
    QWidget *output = window_output(window);
    QTextDocument *document = output_document(output);
    for (QTextBlock block = document->begin(); block.isValid(); block = block.next()) {
        for (QTextBlock::iterator at = block.begin(); !at.atEnd(); ++at) {
            QTextFragment fragment = at.fragment();
            if (!fragment.charFormat().isAnchor() || !fragment.charFormat().anchorHref().startsWith(QString::fromUtf8(start)))
                continue;

            QTextCursor cursor(document);
            cursor.setPosition(fragment.position() + fragment.length() / 2);
            QRect rect;
            QTextEdit *edit = qobject_cast<QTextEdit *>(output);
            QPlainTextEdit *plain = qobject_cast<QPlainTextEdit *>(output);
            if (edit) {
                edit->setTextCursor(cursor);
                edit->ensureCursorVisible();
                rect = edit->cursorRect(cursor);
            } else {
                plain->setTextCursor(cursor);
                plain->ensureCursorVisible();
                rect = plain->cursorRect(cursor);
            }

            QWidget *viewport = static_cast<QAbstractScrollArea *>(output)->viewport();
            QPoint point(rect.left() + 1, rect.center().y());
            send_mouse(viewport, QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::NoModifier);
            send_mouse(viewport, QEvent::MouseButtonRelease, point, Qt::NoButton, Qt::NoModifier);
            process_events();
            return;
        }
    }

    window_print(QStringLiteral("no link starting with ") + QString::fromUtf8(start));
}

static void record_appearance(QDialog *dialog)
{
    QStringList parts;
    QList<QLabel *> labels = dialog->findChildren<QLabel *>();
    for (QLabel *label : labels)
        parts.append(label->text());
    QList<QSlider *> sliders = dialog->findChildren<QSlider *>();
    for (QSlider *slider : sliders)
        parts.append(QString::number(slider->value()));
    window_print(QStringLiteral("text appearance ") + parts.join(QStringLiteral(" | ")));
}

static int run_window(const char *output_path)
{
    window_out = fopen(output_path, "wb");
    if (!window_out)
        return 1;

    // The files: a C++ file with a byte order mark and CRLF line endings, two that aren't UTF-8 text, and programs.
    window_folder = QCoreApplication::applicationDirPath() + QStringLiteral("/tests/window");
    QDir(window_folder).removeRecursively();
    QDir().mkpath(window_folder);
    write_window_file("main.rs", RUST_SAMPLE);
    write_window_file("crlf.cpp", "\xef\xbb\xbf#include <stdio.h>\r\n\r\nint main() { return 0; }\r\n");
    write_window_file("latin1.txt", "caf\xe9\n");
    write_window_file("nul.txt", QByteArray("a\0b\n", 4));
    write_window_file("notes.txt", "Plain text can't run.\n");
    write_window_file("ask.py", "name = input(\"Name? \")\nprint(\"Hello,\", name)\n");
    write_window_file("eof.py", "import sys\ntext = sys.stdin.read()\nprint(len(text), repr(text))\n");
    write_window_file("trace.py", "def fail():\n    raise ValueError(\"no\")\n\nfail()\n");
    write_window_file("sleep.py", "import time\nprint(\"waiting\", flush=True)\ntime.sleep(60)\n");
    write_window_file("hello.c", "#include <stdio.h>\n\nint main(void)\n{\n    printf(\"café %d\\n\", 6 * 7);\n    return 3;\n}\n");
    write_window_file("bad.c", "#include \"broken.h\"\n\nint main(void)\n{\n    return missing;\n}\n");
    write_window_file("broken.h", "int broken(void) { return 1 }\n");

    // The window reads its settings when it's made. Everything it saves after that goes to an empty scratch key.
    QWidget *window = adapter_create_window({window_file("main.rs"), window_file("crlf.cpp")}, theme_index("Monokai"));
    begin_scratch_registry();
    window->show();
    activate(window, current_editor(window));
    QTimer answers;
    QObject::connect(&answers, &QTimer::timeout, answer_dialog);
    answers.start(10);
    record_menus(window);
    record_window(window, "open two files");

    // Tabs and the language picker.
    select_tab(window, "crlf.cpp");
    record_window(window, "second tab");
    QComboBox *picker = window->findChild<QComboBox *>();
    int python = picker->findText(QStringLiteral("Python"));
    picker->setCurrentIndex(python);
    picker->activated(python);
    record_window(window, "choose Python");
    picker->setCurrentIndex(0);
    picker->activated(0);
    record_window(window, "choose auto detect");

    // Saving keeps the byte order mark and the line endings.
    type_text(current_editor(window), QStringLiteral("x"));
    record_window(window, "type");
    trigger(window, "&Save");
    record_window(window, "save");
    record_file("crlf.cpp");

    trigger(window, "&New Tab");
    type_text(current_editor(window), QStringLiteral("#!/usr/bin/env python3\nprint('hi')\n"));
    record_window(window, "new tab");
    dialog_answers << window_file("saved.py");
    trigger(window, "&Save");
    record_window(window, "save a new tab");
    record_file("saved.py");
    dialog_answers << window_file("main.rs") << QStringLiteral("Yes") << QStringLiteral("Ok");
    trigger(window, "Save &As…");
    record_window(window, "save as a file open in another tab");
    dialog_answers << window_file("missing/saved.py") << QStringLiteral("Ok");
    trigger(window, "Save &As…");
    record_window(window, "save as in a missing folder");
    dialog_answers << QStringLiteral("cancel");
    trigger(window, "Save &As…");
    record_window(window, "cancel save as");

    // Opening: from the dialog, again under another case, and files that aren't UTF-8 text.
    dialog_answers << window_file("ask.py");
    trigger(window, "&Open…");
    record_window(window, "open from the dialog");
    const char *dropped[] = {"ASK.PY", "latin1.txt", "nul.txt", "missing.txt", "notes.txt"};
    dialog_answers << QStringLiteral("Ok");
    drop_files(window, dropped, 5);
    record_window(window, "drop files");

    // Zoom, from the menu and from the wheel with Control held.
    trigger(window, "Zoom &In");
    record_window(window, "zoom in");
    control_wheel(window, 60, Qt::ControlModifier);
    control_wheel(window, 60, Qt::ControlModifier);
    record_window(window, "wheel up two half steps");
    control_wheel(window, 60, Qt::ControlModifier);
    control_wheel(window, 120, Qt::NoModifier);
    control_wheel(window, 60, Qt::ControlModifier);
    record_window(window, "half steps around a plain wheel turn");
    control_wheel(window, -360, Qt::ControlModifier);
    record_window(window, "wheel down three steps");
    control_wheel(window, 4000, Qt::ControlModifier);
    record_window(window, "wheel far up");
    trigger(window, "Zoom &Out");
    record_window(window, "zoom out");
    trigger(window, "&Reset Zoom");
    record_window(window, "reset zoom");

    // The Edit menu.
    trigger(window, "&New Tab");
    QApplication::clipboard()->setText(QStringLiteral("first line\nsecond line\n"));
    trigger(window, "&Paste");
    record_window(window, "paste");
    trigger(window, "&Undo");
    record_window(window, "undo");
    trigger(window, "&Redo");
    record_window(window, "redo");
    trigger(window, "Select &All");
    trigger(window, "Cu&t");
    record_window(window, "cut everything");
    window_print(QStringLiteral("clipboard ") + QApplication::clipboard()->text());
    trigger(window, "&Paste");
    trigger(window, "Select &All");
    trigger(window, "&Copy");
    window_print(QStringLiteral("clipboard ") + QApplication::clipboard()->text());
    select_tab(window, "crlf.cpp");
    trigger(window, "Toggle Line &Comment");
    record_window(window, "toggle comment");
    trigger(window, "Show &Completions");
    record_window(window, "show completions");
    send_key(current_editor(window), Qt::Key_Escape, Qt::NoModifier, key_text(Qt::Key_Escape));

    // The theme picker previews as you go and keeps the theme only on OK.
    dialog_answers << QStringLiteral("sol 1 ok");
    trigger(window, "Editor &Theme…");
    record_window(window, "pick a theme");
    record_settings();
    dialog_answers << QStringLiteral("dark 2 cancel");
    trigger(window, "Editor &Theme…");
    dialog_answers << QStringLiteral("zzz 0 cancel");
    trigger(window, "Editor &Theme…");
    record_window(window, "cancel the theme picker");
    record_settings();

    // Text appearance: sliders, Reset, and the settings saved when the panel closes.
    trigger(window, "&Text Appearance…");
    QDialog *appearance = nullptr;
    QList<QDialog *> dialogs = window->findChildren<QDialog *>();
    for (QDialog *dialog : dialogs) {
        if (dialog->isVisible() && dialog->findChild<QSlider *>())
            appearance = dialog;
    }
    QList<QSlider *> sliders = appearance->findChildren<QSlider *>();
    sliders[0]->setValue(40);
    sliders[3]->setValue(120);
    QElapsedTimer settle;
    settle.start();
    while (settle.elapsed() < 100)
        run_events_briefly();
    record_appearance(appearance);
    appearance->findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Reset)->click();
    record_appearance(appearance);
    sliders[1]->setValue(130);
    appearance->findChild<QDialogButtonBox *>()->button(QDialogButtonBox::Close)->click();
    record_window(window, "text appearance");
    record_settings();

    // A second window, closed again.
    trigger(window, "New &Window");
    QWidget *second = nullptr;
    QWidgetList widgets = QApplication::topLevelWidgets();
    for (QWidget *widget : widgets) {
        if (qobject_cast<QMainWindow *>(widget) && widget != window && widget->isVisible())
            second = widget;
    }
    record_window(second, "new window");
    const char *open_in_first[] = {"main.rs"};
    drop_files(second, open_in_first, 1);
    window_print(QStringLiteral("dropped a file the first window has open: the second window has %1 tabs, the first shows %2")
                     .arg(second->findChild<QTabWidget *>()->count()).arg(window->windowTitle()));
    second->close();
    process_events();
    select_tab(window, "* crlf.cpp");
    activate(window, current_editor(window));
    record_window(window, "close the new window");

    // Runs: a file that can't run, input, end of input, a traceback, a build and run, a failed build, and a stop.
    const char *programs[] = {"eof.py", "trace.py", "sleep.py", "hello.c", "bad.c"};
    drop_files(window, programs, 5);
    select_tab(window, "notes.txt");
    trigger(window, "&Run Current File");
    record_window(window, "run plain text");

    select_tab(window, "ask.py");
    run_and_wait(window, "Name? ");
    QWidget *output = window_output(window);
    send_key(output, Qt::Key_Backspace, Qt::NoModifier, key_text(Qt::Key_Backspace));
    type_text(output, QStringLiteral("Ada Lovelace"));
    send_key(output, Qt::Key_Backspace, Qt::ControlModifier, QString());
    type_text(output, QStringLiteral("Byron"));
    record_window(window, "type input");
    send_key(output, Qt::Key_Return, Qt::NoModifier, key_text(Qt::Key_Return));
    wait_for_output(window, "Exited with code");
    record_window(window, "run with input");

    select_tab(window, "eof.py");
    run_and_wait(window, "Running");
    type_text(output, QStringLiteral("abc"));
    send_key(output, Qt::Key_Return, Qt::NoModifier, key_text(Qt::Key_Return));
    type_text(output, QStringLiteral("de"));
    send_key(output, Qt::Key_D, Qt::ControlModifier, QString(QChar(4)));
    wait_for_output(window, "Exited with code");
    record_window(window, "end of input");

    select_tab(window, "trace.py");
    run_and_wait(window, "Exited with code");
    record_window(window, "traceback");
    click_link(window, "retina-source");
    record_window(window, "click the traceback");
    adapter_set_selection(current_editor(window), 0, 0);
    type_text(current_editor(window), QStringLiteral("# changed\n"));
    run_and_wait(window, "Exited with code");
    record_window(window, "traceback from unsaved changes");

    select_tab(window, "hello.c");
    run_and_wait(window, "Exited with code");
    record_window(window, "build and run");
    select_tab(window, "bad.c");
    run_and_wait(window, "Build failed");
    record_window(window, "failed build");
    click_link(window, "file:");
    record_window(window, "click a diagnostic in another file");

    select_tab(window, "sleep.py");
    run_and_wait(window, "waiting");
    run_and_wait(window, "Stopped.");
    record_window(window, "stop");

    // The output pane: closed and shown again, and the Edit menu acting on it when it has focus.
    output->parentWidget()->close();
    trigger(window, "&Output");
    record_window(window, "show the output");
    output->setFocus();
    trigger(window, "Select &All");
    trigger(window, "&Copy");
    window_print(QStringLiteral("clipboard ") + QApplication::clipboard()->text());
    current_editor(window)->setFocus();

    // Closing tabs with and without unsaved changes.
    select_tab(window, "* trace.py");
    dialog_answers << QStringLiteral("Cancel");
    trigger(window, "&Close Tab");
    record_window(window, "cancel closing a changed tab");
    dialog_answers << QStringLiteral("Discard");
    trigger(window, "&Close Tab");
    record_window(window, "discard a changed tab");
    select_tab(window, "saved.py");
    type_text(current_editor(window), QStringLiteral("pass\n"));
    dialog_answers << QStringLiteral("Save");
    trigger(window, "&Close Tab");
    record_window(window, "save a changed tab as it closes");
    record_file("saved.py");
    select_tab(window, "notes.txt");
    trigger(window, "&Close Tab");
    record_window(window, "close a saved tab");

    // Exit asks about each changed tab, and a Cancel keeps everything open.
    select_tab(window, "ask.py");
    type_text(current_editor(window), QStringLiteral("x"));
    dialog_answers << QStringLiteral("Cancel");
    trigger(window, "E&xit");
    record_window(window, "cancel exit");
    dialog_answers << QStringLiteral("Discard") << QStringLiteral("Discard") << QStringLiteral("Discard") << QStringLiteral("Discard");
    trigger(window, "E&xit");
    process_events();
    window_print(QStringLiteral("after exit: %1 windows, %2 answers left").arg(count_windows()).arg(dialog_answers.size()));
    record_settings();

    answers.stop();
    end_scratch_registry();
    fclose(window_out);
    printf("ran the window steps\n");
    return 0;
}

//
// Measurements.
//

static double private_megabytes()
{
    PROCESS_MEMORY_COUNTERS_EX counters = {};
    GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&counters, sizeof counters);
    return double(counters.PrivateUsage) / 1e6;
}

static double elapsed_ms(QElapsedTimer &timer)
{
    double ms = double(timer.nsecsElapsed()) / 1e6;
    timer.restart();
    return ms;
}

// The run pane: the first C build and run, which finds the compiler, a second one, then a Python program that writes
// 200,000 lines, every tenth in color, and paging through the output it keeps.
static int run_run_bench()
{
    window_out = stdout;
    window_folder = QCoreApplication::applicationDirPath() + QStringLiteral("/tests/run_bench");
    QDir(window_folder).removeRecursively();
    QDir().mkpath(window_folder);
    write_window_file("hello.c", "#include <stdio.h>\n\nint main(void)\n{\n    puts(\"hello\");\n    return 0;\n}\n");
    write_window_file("flood.py", "for i in range(200000):\n    if i % 10 == 0:\n        print(f\"\\x1b[32m{i:6}\\x1b[0m a line of output, about as long as a log line\")\n"
                                  "    else:\n        print(f\"{i:6} a line of output, about as long as a log line\")\n");

    QWidget *window = adapter_create_window({window_file("hello.c"), window_file("flood.py")}, theme_index("Monokai"));
    show_hidden(window, 1040, 720);
    activate(window, current_editor(window));
    QElapsedTimer timer;
    timer.start();
    select_tab(window, "hello.c");
    run_and_wait(window, "Exited with code");
    double first_ms = elapsed_ms(timer);
    run_and_wait(window, "Exited with code");
    printf("C build and run: first %.0f ms, second %.0f ms\n", first_ms, elapsed_ms(timer));

    select_tab(window, "flood.py");
    double before = private_megabytes();
    timer.restart();
    run_and_wait(window, "Exited with code");
    double flood_ms = elapsed_ms(timer);
    QTextDocument *document = output_document(window_output(window));
    printf("200,000 lines of output: %.0f ms, %d lines kept, %.1f MB more private\n", flood_ms, document->blockCount(),
           private_megabytes() - before);

    QAbstractScrollArea *output = static_cast<QAbstractScrollArea *>(window_output(window));
    QScrollBar *bar = output->verticalScrollBar();
    int pages = 0;
    for (int value = 0; value <= bar->maximum(); value += bar->pageStep()) {
        bar->setValue(value);
        output->viewport()->repaint();
        pages += 1;
    }
    double paging_ms = elapsed_ms(timer);
    printf("paged through the output: %d pages, %.2f ms a page, %.1f MB more private\n", pages, paging_ms / pages,
           private_megabytes() - before);

    deactivate();
    delete window;
    process_events();
    return 0;
}

// Opens a large file made of the lexer samples, pages through all of it, and types in it, painting after every step.
static int run_bench()
{
    std::vector<TestDocument> samples;
    add_language_samples(samples);
    QString big;
    while (big.count(u'\n') < 100000) {
        for (const TestDocument &sample : samples)
            big += sample.text + u'\n';
    }
    big.squeeze();
    printf("text: %lld lines, %.1f MB of UTF-16\n", (long long)big.count(u'\n') + 1, double(big.size()) * 2 / 1e6);

    QElapsedTimer timer;
    double before = private_megabytes();
    timer.start();
    QWidget *editor = adapter_create_editor(QStringLiteral("bench.cpp"), big, theme_index("Monokai"), 15, DEFAULT_APPEARANCE);
    double create_ms = elapsed_ms(timer);
    show_hidden(editor, 1000, 800);
    activate(editor, editor);
    editor->repaint();
    double show_ms = elapsed_ms(timer);
    printf("open: created in %.0f ms, shown and painted in %.0f ms, %.1f MB private\n", create_ms, show_ms,
           private_megabytes() - before);

    int pages = 0, anchor, caret = 0, last_caret = -1;
    while (caret != last_caret) {
        last_caret = caret;
        send_key(editor, Qt::Key_PageDown, Qt::NoModifier, QString());
        adapter_mouse_target(editor)->repaint();
        adapter_selection(editor, anchor, caret);
        pages += 1;
    }
    double paging_ms = elapsed_ms(timer);
    printf("paged to the end: %d pages, %.2f ms a page, %.1f MB private\n", pages, paging_ms / pages,
           private_megabytes() - before);

    adapter_set_selection(editor, int(big.size() / 2), int(big.size() / 2));
    process_events();
    timer.restart();
    const int KEY_COUNT = 300;
    for (int key = 0; key < KEY_COUNT; ++key) {
        type_character(editor, QStringLiteral("x"));
        adapter_mouse_target(editor)->repaint();
    }
    double typing_ms = elapsed_ms(timer);
    for (int key = 0; key < KEY_COUNT; ++key) {
        send_key(editor, Qt::Key_Backspace, Qt::NoModifier, QString());
        adapter_mouse_target(editor)->repaint();
    }
    double backspace_ms = elapsed_ms(timer);
    printf("typing in the middle with a paint each key: %.2f ms a key, backspace %.2f ms, %.1f MB private\n",
           typing_ms / KEY_COUNT, backspace_ms / KEY_COUNT, private_megabytes() - before);

    deactivate();
    delete editor;
    process_events();
    return 0;
}

int main(int argument_count, char **arguments)
{
    if (argument_count >= 4 && !strcmp(arguments[1], "compare")) {
        QCoreApplication core(argument_count, arguments);
        return run_compare(arguments[2], arguments[3]);
    }

    // Window runs open dialogs, so they use the offscreen platform, where nothing shows on screen.
    bool window_run = argument_count >= 3 && !strcmp(arguments[1], "window");
    if (window_run) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
    }

    QApplication application(argument_count, arguments);
    adapter_setup_application(application);
    if (window_run)
        return run_window(arguments[2]);

    // The caret doesn't blink, so it is in every image.
    QGuiApplication::styleHints()->setCursorFlashTime(0);

    const char *save_folder = nullptr, *only = nullptr;
    for (int index = 3; index + 1 < argument_count; ++index) {
        if (!strcmp(arguments[index], "--save"))
            save_folder = arguments[index + 1];
        if (!strcmp(arguments[index], "--only"))
            only = arguments[index + 1];
    }

    if (argument_count >= 3 && !strcmp(arguments[1], "render"))
        return run_render(arguments[2], save_folder, only);
    if (argument_count >= 3 && !strcmp(arguments[1], "behavior"))
        return run_behavior(arguments[2], save_folder, only);
    if (argument_count >= 2 && !strcmp(arguments[1], "onscreen"))
        return run_onscreen();
    if (argument_count >= 2 && !strcmp(arguments[1], "bench"))
        return run_bench();
    if (argument_count >= 2 && !strcmp(arguments[1], "runbench"))
        return run_run_bench();
    if (argument_count >= 3 && !strcmp(arguments[1], "accessibility"))
        return run_accessibility(arguments[2], only);

    printf("usage: editor_test render|behavior <output> [--save <folder>] [--only <name>] | compare <reference> <current> | onscreen\n");
    return 2;
}
