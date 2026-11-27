// Editor test harness: renders scenarios to images and replays scripted input, and records what the editor shows
// and does. tests/test.bat builds it once per editor: an adapter file includes that editor's code, then this file,
// and then defines the adapter_* functions declared below. The scenarios and the recording are the same for every
// editor, so two recordings can be compared line by line.
//
//   editor_test render <output> [--save <folder>] [--only <name>]   one line per scenario: size and pixel hash
//   editor_test behavior <output> [--only <case>]                   one line per input step: text, caret, scroll, image
//   editor_test compare <reference> <current>
//   editor_test onscreen                                            checks hidden rendering against a shown window
//
// The display scale comes from QT_SCALE_FACTOR. Windows stay hidden (WA_DontShowOnScreen) and are made active through
// Qt's window-system interface, so the caret and focus colors draw the same way they do on screen.

#include <QApplication>
#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QLabel>
#include <QMimeData>
#include <QMouseEvent>
#include <QPixmap>
#include <QScreen>
#include <QStyleHints>
#include <QTextCharFormat>
#include <QTimer>
#include <QWheelEvent>
#include <qpa/qwindowsysteminterface.h>
#include <QtGui/private/qfont_p.h>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

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
    Key, Text, Click, ShiftClick, DoubleClick, TripleClick, Drag, Wheel, Complete, ToggleComment, Clipboard, Preedit, Commit,
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
        case StepKind::Complete: return "complete";
        case StepKind::ToggleComment: return "toggle_comment";
        case StepKind::Clipboard: return "clipboard";
        case StepKind::Preedit: return "preedit";
        case StepKind::Commit: return "commit";
    }

    return "?";
}

static void record_state(FILE *out, const QString &name, int step_index, const Step *step, QWidget *editor)
{
    int anchor, caret, scroll_x, scroll_y;
    adapter_selection(editor, anchor, caret);
    adapter_scroll(editor, scroll_x, scroll_y);
    QString text = adapter_text(editor);

    fprintf(out, "%s %d %s %d %x | text %016llx %d caret %d anchor %d scroll %d %d overwrite %d popup %d image %016llx\n",
            name.toUtf8().constData(), step_index, step ? step_name(step->kind) : "start", step ? step->key : 0,
            step ? unsigned(step->modifiers.toInt()) : 0u, (unsigned long long)hash_text(text), int(text.size()), caret,
            anchor, scroll_x, scroll_y, adapter_overwrite(editor), adapter_completion_visible(editor),
            (unsigned long long)hash_image(capture(editor)));
}

static int run_behavior(const char *output_path, const char *only)
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
        record_state(out, script.name, 0, nullptr, editor);

        for (size_t index = 0; index < script.steps.size(); ++index) {
            run_step(editor, script.steps[index]);
            record_state(out, script.name, int(index + 1), &script.steps[index], editor);
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

int main(int argument_count, char **arguments)
{
    if (argument_count >= 4 && !strcmp(arguments[1], "compare")) {
        QCoreApplication core(argument_count, arguments);
        return run_compare(arguments[2], arguments[3]);
    }

    QApplication application(argument_count, arguments);
    adapter_setup_application(application);

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
        return run_behavior(arguments[2], only);
    if (argument_count >= 2 && !strcmp(arguments[1], "onscreen"))
        return run_onscreen();

    printf("usage: editor_test render|behavior <output> [--save <folder>] [--only <name>] | compare <reference> <current> | onscreen\n");
    return 2;
}
