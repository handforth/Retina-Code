// The editor window: tabs of TextViews, the menus, the status bar, the theme picker, the text appearance panel, and
// the run pane. main_qt.cpp includes RunPane.cpp and TextView.cpp before this file.

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
#include <QFormLayout>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMainWindow>
#include <QMenuBar>
#include <QMessageBox>
#include <QMimeData>
#include <QPainter>
#include <QPlainTextEdit>
#include <QProxyStyle>
#include <QPushButton>
#include <QSaveFile>
#include <QSettings>
#include <QSlider>
#include <QStandardPaths>
#include <QStatusBar>
#include <QStringDecoder>
#include <QStyleHints>
#include <QStyleOption>
#include <QTabBar>
#include <QTabWidget>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>
#include <QWheelEvent>

#include <algorithm>
#include <filesystem>
#include <vector>

#ifdef Q_OS_WIN
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <psapi.h>
#endif

//
// The style: Fusion, with flat document tabs.
//

// The tab bar a style call is for, when it's a document-mode bar along the top like the window's. The close buttons
// on its tabs are its children.
static const QTabBar *document_tab_bar(const QWidget *widget)
{
    const QTabBar *bar = qobject_cast<const QTabBar *>(widget);
    if (!bar && widget)
        bar = qobject_cast<const QTabBar *>(widget->parentWidget());
    if (bar && bar->documentMode() && bar->shape() == QTabBar::RoundedNorth)
        return bar;

    return nullptr;
}

struct DocumentTabStyle : QProxyStyle {
    DocumentTabStyle() : QProxyStyle(QStringLiteral("Fusion")) {}

    // A tab is a faint tint over the window's color, stronger when hovered and stronger still when current, with
    // hairline edges and the highlight color along the bottom of the current one.
    void drawControl(ControlElement element, const QStyleOption *option, QPainter *painter, const QWidget *widget) const override
    {
        if (element != CE_TabBarTabShape || !document_tab_bar(widget)) {
            QProxyStyle::drawControl(element, option, painter, widget);
            return;
        }

        QRect tab = option->rect;
        bool selected = option->state.testFlag(State_Selected);
        bool hovered = option->state.testFlag(State_MouseOver);
        QColor tint = option->palette.color(QPalette::WindowText);
        painter->fillRect(tab, option->palette.brush(QPalette::Window));
        tint.setAlpha(selected ? 20 : hovered ? 15 : 7);
        painter->fillRect(tab, tint);
        tint.setAlpha(13);
        painter->fillRect(QRect(tab.left(), tab.top(), tab.width(), 1), tint);
        tint.setAlpha(22);
        painter->fillRect(QRect(tab.right(), tab.top(), 1, tab.height()), tint);
        painter->fillRect(QRect(tab.left(), tab.bottom(), tab.width(), 1), tint);
        if (selected)
            painter->fillRect(QRect(tab.left(), tab.bottom() - 1, tab.width() - 1, 2), option->palette.brush(QPalette::Highlight));
    }

    void drawPrimitive(PrimitiveElement element, const QStyleOption *option, QPainter *painter, const QWidget *widget) const override
    {
        const QTabBar *bar = nullptr;
        if (element == PE_FrameTabBarBase || element == PE_IndicatorTabClose)
            bar = document_tab_bar(widget);

        // Hairlines along the top of the bar and under its tabs.
        if (bar && element == PE_FrameTabBarBase) {
            QColor tint = option->palette.color(QPalette::WindowText);
            tint.setAlpha(13);
            painter->fillRect(QRect(0, 0, bar->width(), 1), tint);
            tint.setAlpha(22);
            painter->fillRect(QRect(option->rect.left(), option->rect.bottom(), option->rect.width(), 1), tint);
            return;
        }

        // The close button: an × on a rounded square while hovered or pressed. The × is one filled shape, so both
        // strokes have the same coverage where they cross.
        if (bar && element == PE_IndicatorTabClose) {
            static const QPointF CROSS[12] = {
                {-3, -2}, {-2, -3}, {0, -1}, {2, -3}, {3, -2}, {1, 0},
                {3, 2}, {2, 3}, {0, 1}, {-2, 3}, {-3, 2}, {-1, 0},
            };
            QRectF bounds(option->rect);
            bool hovered = option->state.testAnyFlags(State_MouseOver | State_Sunken);
            QColor tint = option->palette.color(QPalette::WindowText);
            painter->save();
            painter->setRenderHint(QPainter::Antialiasing);
            painter->setPen(Qt::NoPen);
            if (hovered) {
                tint.setAlpha(option->state.testFlag(State_Sunken) ? 50 : 29);
                painter->setBrush(tint);
                painter->drawRoundedRect(bounds.adjusted(1, 1, -1, -1), 2, 2);
            }

            // The center can lie between device pixels, even at 100% scaling.
            tint.setAlpha(hovered || option->state.testFlag(State_Selected) ? 205 : 132);
            painter->translate(bounds.center());
            painter->setBrush(tint);
            painter->drawPolygon(CROSS, 12);
            painter->restore();
            return;
        }

        QProxyStyle::drawPrimitive(element, option, painter, widget);
    }

    QRect subElementRect(SubElement element, const QStyleOption *option, const QWidget *widget) const override
    {
        QRect rect = QProxyStyle::subElementRect(element, option, widget);
        if (element == SE_TabBarTabRightButton && rect.isValid() && document_tab_bar(widget))
            rect.translate(option->direction == Qt::RightToLeft ? -2 : 2, 0);
        return rect;
    }

    // Fusion insets tab labels and buttons by half of these spaces.
    int pixelMetric(PixelMetric metric, const QStyleOption *option, const QWidget *widget) const override
    {
        int size = 0;
        switch (metric) {
            case PM_TabBarTabHSpace: size = 14; break;
            case PM_TabBarTabVSpace: size = 8; break;
            case PM_TabBarBaseOverlap: size = 1; break;
            case PM_TabCloseIndicatorWidth: size = 18; break;
            case PM_TabCloseIndicatorHeight: size = 18; break;
            default: break;
        }
        if (size && document_tab_bar(widget))
            return size;

        return QProxyStyle::pixelMetric(metric, option, widget);
    }
};

// Fusion's dark colors, or a dark palette of our own where the platform can't give them.
static void use_dark_widgets(QApplication &application)
{
    application.setStyle(new DocumentTabStyle);
    application.styleHints()->setColorScheme(Qt::ColorScheme::Dark);
    if (application.palette().color(QPalette::Window).lightness() < 128)
        return;

    QPalette palette(QColor(53, 53, 53), QColor(35, 35, 35));
    palette.setColor(QPalette::Base, QColor(27, 27, 27));
    palette.setColor(QPalette::AlternateBase, QColor(41, 41, 41));
    palette.setColor(QPalette::Highlight, QColor(48, 98, 155));
    palette.setColor(QPalette::HighlightedText, Qt::white);
    application.setPalette(palette);
}

//
// The window's data.
//

static const char SAMPLE_MAIN[] = R"rs(// Edit this file, or open one of your own with Ctrl+O.
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

static const char SAMPLE_MODULE[] = R"rs(#[derive(Debug)]
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

static const char UTF8_BOM[] = "\xef\xbb\xbf";
static const int THEME_COUNT = int(sizeof themes / sizeof themes[0]);

// The text appearance panel's sliders, in percent, and the settings that keep them.
struct AppearanceControl {
    const char *label;
    const char *key;
    int TextAppearance::*value;
    int minimum, maximum;
};

static const int APPEARANCE_CONTROL_COUNT = 4;
static const AppearanceControl APPEARANCE_CONTROLS[APPEARANCE_CONTROL_COUNT] = {
    {"Stroke weight", "stroke", &TextAppearance::stroke, 0, 100},
    {"Saturation", "saturation", &TextAppearance::saturation, 0, 160},
    {"Brightness", "brightness", &TextAppearance::brightness, 65, 135},
    {"Contrast", "contrast", &TextAppearance::contrast, 65, 135},
};

// What the menu items do. Each item carries its command as its data.
enum Command {
    COMMAND_NONE,
    COMMAND_NEW_TAB, COMMAND_NEW_WINDOW, COMMAND_OPEN, COMMAND_SAVE, COMMAND_SAVE_AS, COMMAND_CLOSE_TAB, COMMAND_RUN, COMMAND_EXIT,
    COMMAND_UNDO, COMMAND_REDO, COMMAND_CUT, COMMAND_COPY, COMMAND_PASTE, COMMAND_SELECT_ALL, COMMAND_TOGGLE_COMMENT,
    COMMAND_SHOW_COMPLETIONS,
    COMMAND_ZOOM_IN, COMMAND_ZOOM_OUT, COMMAND_RESET_ZOOM, COMMAND_THEME, COMMAND_TEXT_APPEARANCE, COMMAND_OUTPUT,
};

// The theme every window shows. A window's hidden tabs take it up when they're next shown.
static const Theme *current_theme;

struct EditorWindow : QMainWindow {
    QTabWidget *tabs = nullptr;
    QLabel *position_label = nullptr;
    QComboBox *language_picker = nullptr;
    QLabel *encoding_label = nullptr;
    QLabel *memory_label = nullptr;          // on Windows only
    int memory_timer = 0;

    TextAppearance appearance;
    int font_size = 15;
    int wheel_zoom = 0;                      // how far the wheel turned toward the next zoom step, in eighths of a degree
    bool close_approved = false;             // Exit asked about every changed tab already
    QStringList dropped_paths;               // files dropped on the window, which open once the drop is done

    // The text appearance panel, made the first time it shows.
    QDialog *appearance_panel = nullptr;
    QSlider *appearance_sliders[APPEARANCE_CONTROL_COUNT] = {};
    QLabel *appearance_numbers[APPEARANCE_CONTROL_COUNT] = {};
    bool appearance_changed[APPEARANCE_CONTROL_COUNT] = {};    // since the settings last got them
    int appearance_timer = 0;                // shows the appearance a moment after a slider moves

    // The run pane, made for the first run, and the tab that run came from until the tab closes.
    RunPane *run_pane = nullptr;
    TextView *run_view = nullptr;
    QString run_path;

    void closeEvent(QCloseEvent *event) override;
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dragMoveEvent(QDragMoveEvent *event) override;
    void dropEvent(QDropEvent *event) override;
    bool eventFilter(QObject *object, QEvent *event) override;
    void timerEvent(QTimerEvent *event) override;

    // What the window's widgets tell it.
    void command_chosen(QAction *action);
    void tab_changed();
    void tab_close_requested(int index);
    void language_chosen(int row);
    void appearance_slider_moved();
    void appearance_reset();
    void save_appearance();
    void open_dropped_files();
};

//
// Tabs and the status bar.
//

static std::string_view byte_view(const QByteArray &bytes)
{
    return std::string_view(bytes.constData(), size_t(bytes.size()));
}

static TextView *active_view(const EditorWindow &window)
{
    return static_cast<TextView *>(window.tabs->currentWidget());
}

static QString tab_label(const TextView &view)
{
    QString label = view.name;
    label.replace(u'&', QStringLiteral("&&"));
    return view.text.modified ? QStringLiteral("* ") + label : label;
}

// The path the tab's file was opened or saved at, which runs use, or nothing for text that was never saved.
static QString saved_path(const TextView &view)
{
    return view.file_path.isEmpty() ? QString() : QString::fromUtf8(view.language_path);
}

// The text as it's saved: UTF-8, with the file's own line endings.
static QByteArray source_bytes(const TextView &view)
{
    QString text = qstring_of(std::u16string_view(view.text.units.data(), view.text.units.size()));
    if (view.file_format.newline == LineEnding::CRLF)
        text.replace(u'\n', QStringLiteral("\r\n"));
    else if (view.file_format.newline == LineEnding::CR)
        text.replace(u'\n', u'\r');
    return text.toUtf8();
}

// The caret's line and column, which change with every move of the caret.
static void update_position(EditorWindow &window)
{
    TextView *view = active_view(window);
    if (!view) {
        window.position_label->clear();
        return;
    }

    uint32_t line = caret_line(*view);
    window.position_label->setText(QStringLiteral("Ln %1, Col %2").arg(line + 1).arg(view->caret - line_start(*view, line) + 1));
}

// The caret's place, and the encoding and font size, which change only with the tab and the zoom.
static void update_status(EditorWindow &window)
{
    update_position(window);
    window.encoding_label->setText(active_view(window) ? QStringLiteral("UTF-8  ·  %1 px").arg(window.font_size) : QString());
}

// The picker shows the tab's language mode. While the tab detects its language, the first row, Auto Detect, names the
// language detected.
static void update_language_picker(EditorWindow &window)
{
    TextView *view = active_view(window);
    QString automatic = QStringLiteral("Auto Detect");
    if (view && view->mode == Language::Count)
        automatic = QStringLiteral("%1 (Auto)").arg(QString::fromUtf8(language_info(view->text.language).name));

    window.language_picker->setEnabled(view != nullptr);
    window.language_picker->setItemText(0, automatic);
    window.language_picker->setCurrentIndex(view ? window.language_picker->findData(int(view->mode)) : -1);
}

// The window shows the current tab in its title, the language picker, and the status bar. The tab takes up the
// theme and appearance, which may have changed while it was hidden.
static void show_active_tab(EditorWindow &window)
{
    TextView *view = active_view(window);
    if (view)
        apply_appearance(*view, *current_theme, window.appearance);
    window.setWindowTitle(view ? view->name + QStringLiteral(" — Retina Code") : QStringLiteral("Retina Code"));
    update_language_picker(window);
    update_status(window);
}

// What a tab's view reports: the status bar follows the caret, the tab's label shows whether the text is saved, and
// the language picker shows the language detected.
static void view_changed(void *context, TextView &view, uint32_t changes)
{
    EditorWindow &window = *static_cast<EditorWindow *>(context);
    if (changes & VIEW_CARET_MOVED)
        update_position(window);
    if (changes & VIEW_MODIFIED_CHANGED)
        window.tabs->setTabText(window.tabs->indexOf(&view), tab_label(view));
    if ((changes & VIEW_LANGUAGE_CHANGED) && &view == active_view(window))
        update_language_picker(window);
}

static TextView *add_tab(EditorWindow &window, const QString &name, const QString &text, const QString &source_path,
                         const QString &file_path)
{
    TextView *view = new TextView(name, text, source_path, *current_theme, window.font_size, window.appearance);
    view->file_path = file_path;
    view->notify = view_changed;
    view->notify_context = &window;
    view->viewport()->installEventFilter(&window);
    int index = window.tabs->addTab(view, tab_label(*view));
    window.tabs->setTabToolTip(index, source_path.isEmpty() ? name : QDir::toNativeSeparators(source_path));
    return view;
}

// Shows a tab and gives it focus. The tab can be in another window, which then comes to the front.
static void select_tab(EditorWindow &window, TextView *view)
{
    EditorWindow *owner = static_cast<EditorWindow *>(view->window());
    owner->tabs->setCurrentWidget(view);
    if (owner != &window) {
        owner->raise();
        owner->activateWindow();
    }
    view->setFocus();
}

// An empty tab named Untitled, then Untitled 2 and on, counting across windows.
static void new_tab(EditorWindow &window)
{
    static int untitled_count = 0;
    untitled_count += 1;
    QString name = untitled_count == 1 ? QStringLiteral("Untitled") : QStringLiteral("Untitled %1").arg(untitled_count);
    select_tab(window, add_tab(window, name, QString(), QString(), QString()));
}

// What a window shows when it opens with no files named.
static void load_samples(EditorWindow &window)
{
    TextView *first = add_tab(window, QStringLiteral("main.rs"), QString::fromUtf8(SAMPLE_MAIN), QString(), QString());
    add_tab(window, QStringLiteral("sample.rs"), QString::fromUtf8(SAMPLE_MODULE), QString(), QString());
    select_tab(window, first);
}

static void zoom(EditorWindow &window, int size)
{
    size = std::clamp(size, 9, 36);
    if (size == window.font_size)
        return;

    window.font_size = size;
    for (int index = 0; index < window.tabs->count(); ++index)
        apply_font_size(*static_cast<TextView *>(window.tabs->widget(index)), size);
    update_status(window);
}

// A warning in plain text, so file names show as they are.
static void show_warning(EditorWindow &window, const QString &title, const QString &text, const QString &details)
{
    QMessageBox message(QMessageBox::Warning, title, text, QMessageBox::Ok, &window);
    message.setTextFormat(Qt::PlainText);
    message.setDetailedText(details);
    message.exec();
}

//
// Files.
//

// A file's path with links resolved, so a file has one tab however it's reached.
static QString resolved_path(const QFileInfo &info)
{
    QString canonical = info.canonicalFilePath();
    return canonical.isEmpty() ? info.absoluteFilePath() : canonical;
}

// The tab that has a file, in this window or another, since two tabs on one file would save over each other. Qt can
// keep the caller's spelling of a path on a volume that ignores case, so paths that differ only in case are the same
// file when the file system says so.
static TextView *tab_for_path(EditorWindow &window, const QString &path)
{
    for (QWidget *widget : QApplication::topLevelWidgets()) {
        EditorWindow *each = dynamic_cast<EditorWindow *>(widget);
        if (!each || (each != &window && !each->isVisible()))
            continue;

        for (int index = 0; index < each->tabs->count(); ++index) {
            TextView *view = static_cast<TextView *>(each->tabs->widget(index));
            if (view->file_path == path)
                return view;

            if (view->file_path.compare(path, Qt::CaseInsensitive) == 0) {
                std::error_code failure;
                if (std::filesystem::equivalent(QFileInfo(path).filesystemAbsoluteFilePath(),
                                                QFileInfo(view->file_path).filesystemAbsoluteFilePath(), failure))
                    return view;
            }
        }
    }

    return nullptr;
}

// A file's byte order mark and line endings, which saving keeps. The first line break decides the endings.
static FileFormat file_format_of(std::string_view bytes)
{
    FileFormat format;
    format.bom = bytes.starts_with(UTF8_BOM);
    size_t first = bytes.find_first_of("\r\n");
    if (first != bytes.npos && bytes[first] == '\r')
        format.newline = bytes.substr(first, 2) == "\r\n" ? LineEnding::CRLF : LineEnding::CR;
    return format;
}

// Opens a file in a new tab, or finds the tab that has it. The error says why a file can't open: it's missing,
// unreadable, or not UTF-8 text.
static TextView *open_file(EditorWindow &window, const QString &path, QString &error)
{
    QFileInfo info(path);
    if (!info.isFile()) {
        error = QStringLiteral("Choose an existing file.");
        return nullptr;
    }

    QString source = info.absoluteFilePath();
    QString file_path = resolved_path(info);
    TextView *open = tab_for_path(window, file_path);
    if (open)
        return open;

    QFile file(source);
    if (!file.open(QIODevice::ReadOnly)) {
        error = file.errorString();
        return nullptr;
    }
    QByteArray bytes = file.readAll();
    if (file.error() != QFileDevice::NoError) {
        error = file.errorString();
        return nullptr;
    }

    QStringDecoder decode(QStringDecoder::Utf8, QStringDecoder::Flag::Stateless);
    QString text = decode(bytes);
    if (decode.hasError() || text.contains(QChar::Null)) {
        error = QStringLiteral("Choose a UTF-8 text file.");
        return nullptr;
    }

    TextView *view = add_tab(window, info.fileName(), text, source, file_path);
    view->file_format = file_format_of(byte_view(bytes));
    return view;
}

// Opens files in tabs and selects the first. One message lists the files that couldn't open.
static void open_files(EditorWindow &window, const QStringList &paths)
{
    TextView *first = nullptr;
    QStringList errors;
    for (const QString &path : paths) {
        QString error;
        TextView *view = open_file(window, path, error);
        if (!view)
            errors.append(QStringLiteral("%1 — %2").arg(QDir::toNativeSeparators(path), error));
        else if (!first)
            first = view;
    }

    if (first)
        select_tab(window, first);
    if (errors.size() == 1)
        show_warning(window, QStringLiteral("Open Files"), errors[0], QString());
    if (errors.size() > 1)
        show_warning(window, QStringLiteral("Open Files"), QStringLiteral("Could not open %1 files.").arg(errors.size()), errors.join(u'\n'));
}

// Writes the tab's text to the file in one step, so a save that fails leaves the file as it was.
static QString write_file(const TextView &view, const QString &path)
{
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return file.errorString();
    if (view.file_format.bom && file.write(UTF8_BOM, 3) != 3)
        return file.errorString();

    QByteArray bytes = source_bytes(view);
    if (file.write(bytes) != bytes.size() || !file.commit())
        return file.errorString();
    return QString();
}

// Saves the tab to its file, or to a file the user picks for Save As or when it has none. Says whether it saved.
static bool save_tab(EditorWindow &window, TextView *view, bool choose_path)
{
    if (!view)
        return false;
    choose_path = choose_path || view->file_path.isEmpty();
    if (!choose_path && !view->text.modified)
        return true;

    QString path = view->file_path;
    if (choose_path) {
        QString suggested = saved_path(*view);
        if (suggested.isEmpty()) {
            QString documents = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
            QDir folder(!documents.isEmpty() && QDir(documents).exists() ? documents : QDir::homePath());
            suggested = folder.filePath(view->name);
        }
        path = QFileDialog::getSaveFileName(&window, QStringLiteral("Save As"), suggested);
        if (path.isEmpty())
            return false;
    }

    QFileInfo info(path);
    QString destination = resolved_path(info);
    TextView *other = choose_path ? tab_for_path(window, destination) : nullptr;
    if (other && other != view) {
        show_warning(window, QStringLiteral("Could Not Save"),
                     QStringLiteral("%1 — This file is open in another tab.").arg(QDir::toNativeSeparators(path)), QString());
        return false;
    }

    QString error = write_file(*view, destination);
    if (!error.isEmpty()) {
        show_warning(window, QStringLiteral("Could Not Save"), QStringLiteral("%1 — %2").arg(QDir::toNativeSeparators(path), error), QString());
        return false;
    }

    // After Save As the tab takes the file's name and path, and detects its language again from the new name.
    int tab = window.tabs->indexOf(view);
    if (choose_path) {
        info.refresh();
        view->name = info.fileName();
        view->file_path = resolved_path(info);
        view->language_path = QDir::fromNativeSeparators(info.absoluteFilePath()).toUtf8();
        view->detects_from_text = detect_language(byte_view(view->language_path)) == Language::Plain;
        if (view->mode == Language::Count)
            set_view_language(*view, detect_view_language(*view));
        window.tabs->setTabToolTip(tab, QDir::toNativeSeparators(info.absoluteFilePath()));
    }

    mark_view_saved(*view);
    window.tabs->setTabText(tab, tab_label(*view));
    if (view == active_view(window))
        show_active_tab(window);
    return true;
}

// Asks whether to save a tab's changes before it closes. Says whether it may close.
static bool confirm_close_tab(EditorWindow &window, TextView *view)
{
    if (!view->text.modified)
        return true;

    QMessageBox::StandardButton choice = QMessageBox::question(&window, QStringLiteral("Unsaved Changes"),
                                                               QStringLiteral("Save changes to %1?").arg(view->name),
                                                               QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel,
                                                               QMessageBox::Cancel);
    if (choice == QMessageBox::Save)
        return save_tab(window, view, false);
    return choice == QMessageBox::Discard;
}

static bool confirm_close(EditorWindow &window)
{
    for (int index = 0; index < window.tabs->count(); ++index) {
        if (!confirm_close_tab(window, static_cast<TextView *>(window.tabs->widget(index))))
            return false;
    }

    return true;
}

static void close_tab(EditorWindow &window, TextView *view)
{
    if (!confirm_close_tab(window, view))
        return;

    if (window.run_view == view)
        window.run_view = nullptr;
    window.tabs->removeTab(window.tabs->indexOf(view));
    delete view;
}

// Exit: every window asks about its changed tabs, this one first, and a Cancel anywhere keeps them all open.
static void quit_application(EditorWindow &window)
{
    std::vector<EditorWindow *> windows;
    windows.push_back(&window);
    for (QWidget *widget : QApplication::topLevelWidgets()) {
        EditorWindow *other = dynamic_cast<EditorWindow *>(widget);
        if (other && other != &window && other->isVisible())
            windows.push_back(other);
    }

    for (EditorWindow *each : windows) {
        if (!confirm_close(*each))
            return;
    }
    for (EditorWindow *each : windows) {
        each->close_approved = true;
        each->close();
    }
}

//
// Themes and text appearance.
//

// The theme with this name, or Monokai.
static const Theme &find_theme(std::string_view name)
{
    const Theme *monokai = &themes[0];
    for (const Theme &theme : themes) {
        if (name == theme.name)
            return theme;
        if (std::string_view(theme.name) == "Monokai")
            monokai = &theme;
    }

    return *monokai;
}

static void set_theme(const Theme &theme)
{
    if (current_theme == &theme)
        return;

    current_theme = &theme;
    for (QWidget *widget : QApplication::topLevelWidgets()) {
        EditorWindow *window = dynamic_cast<EditorWindow *>(widget);
        if (window && active_view(*window))
            apply_appearance(*active_view(*window), theme, window->appearance);
    }
}

// The theme picker: a filter field over the list of themes. The windows show each theme as it becomes the current
// one, and Cancel puts the first one back.
struct ThemePicker : QDialog {
    QLineEdit filter;
    QListWidget list;
    QPushButton *ok = nullptr;

    explicit ThemePicker(QWidget *parent) : QDialog(parent) {}

    // Up and Down in the filter field move through the list.
    bool eventFilter(QObject *object, QEvent *event) override
    {
        if (object == &filter && event->type() == QEvent::KeyPress) {
            int key = static_cast<QKeyEvent *>(event)->key();
            if (key == Qt::Key_Up || key == Qt::Key_Down) {
                QApplication::sendEvent(&list, event);
                return true;
            }
        }

        return QDialog::eventFilter(object, event);
    }

    // Lists the themes whose names have the filter in them, and keeps the current one when it's still listed.
    void filter_changed(const QString &text)
    {
        int current = list.currentItem() ? list.currentItem()->data(Qt::UserRole).toInt() : int(current_theme - themes);
        QStringView query = QStringView(text).trimmed();

        list.clear();
        int current_row = 0;
        for (int index = 0; index < THEME_COUNT; ++index) {
            if (!QLatin1StringView(themes[index].name).contains(query, Qt::CaseInsensitive))
                continue;
            if (index == current)
                current_row = list.count();
            QListWidgetItem *item = new QListWidgetItem(QString::fromLatin1(themes[index].name), &list);
            item->setData(Qt::UserRole, index);
        }

        list.setCurrentRow(current_row);
        ok->setEnabled(list.count() > 0);
    }

    void row_changed(int row)
    {
        if (row >= 0)
            set_theme(themes[list.item(row)->data(Qt::UserRole).toInt()]);
    }
};

static void show_theme_picker(EditorWindow &window)
{
    const Theme *original = current_theme;

    ThemePicker picker(&window);
    picker.setWindowTitle(QStringLiteral("Editor Theme"));
    QVBoxLayout *layout = new QVBoxLayout(&picker);
    picker.filter.setPlaceholderText(QStringLiteral("Filter themes…"));
    picker.filter.setAccessibleName(QStringLiteral("Filter themes"));
    picker.filter.installEventFilter(&picker);
    layout->addWidget(&picker.filter);
    picker.list.setAccessibleName(QStringLiteral("Themes"));
    picker.list.setUniformItemSizes(true);
    layout->addWidget(&picker.list, 1);
    QDialogButtonBox *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    layout->addWidget(buttons);
    picker.ok = buttons->button(QDialogButtonBox::Ok);
    picker.ok->setDefault(true);

    QObject::connect(buttons, &QDialogButtonBox::accepted, &picker, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &picker, &QDialog::reject);
    QObject::connect(&picker.list, &QListWidget::itemActivated, &picker, &QDialog::accept);
    QObject::connect(&picker.list, &QListWidget::currentRowChanged, &picker, &ThemePicker::row_changed);
    QObject::connect(&picker.filter, &QLineEdit::textChanged, &picker, &ThemePicker::filter_changed);
    picker.filter_changed(QString());

    picker.filter.setFocus();
    picker.resize(340, 420);
    picker.move(window.mapToGlobal(QPoint(window.width() - picker.width() - 20, window.menuBar()->height() + 20)));
    if (picker.exec() != QDialog::Accepted) {
        set_theme(*original);
        return;
    }

    if (current_theme != original) {
        QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
        settings.setValue(QStringLiteral("EditorTheme"), QString::fromLatin1(current_theme->name));
    }
}

// The text appearance panel: a slider for each control, then Reset and Close. It's made once, and the settings get
// its values when it closes and when the window does.
static void show_text_appearance(EditorWindow &window)
{
    if (!window.appearance_panel) {
        QDialog *panel = new QDialog(&window, Qt::Tool);
        panel->setWindowTitle(QStringLiteral("Text Appearance"));
        QVBoxLayout *layout = new QVBoxLayout(panel);
        QFormLayout *form = new QFormLayout;
        layout->addLayout(form);

        for (int index = 0; index < APPEARANCE_CONTROL_COUNT; ++index) {
            const AppearanceControl &control = APPEARANCE_CONTROLS[index];
            QSlider *slider = new QSlider(Qt::Horizontal, panel);
            slider->setRange(control.minimum, control.maximum);
            slider->setPageStep(5);
            slider->setMinimumWidth(200);
            slider->setValue(window.appearance.*control.value);
            slider->setAccessibleName(QString::fromLatin1(control.label));
            QObject::connect(slider, &QSlider::valueChanged, &window, &EditorWindow::appearance_slider_moved);

            QLabel *number = new QLabel(QString::number(slider->value()) + u'%', panel);
            number->setMinimumWidth(number->fontMetrics().horizontalAdvance(QStringLiteral("160%")) + 4);
            number->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
            QHBoxLayout *row = new QHBoxLayout;
            row->addWidget(slider, 1);
            row->addWidget(number);
            form->addRow(QString::fromLatin1(control.label), row);

            window.appearance_sliders[index] = slider;
            window.appearance_numbers[index] = number;
        }

        QDialogButtonBox *buttons = new QDialogButtonBox(QDialogButtonBox::Reset | QDialogButtonBox::Close, panel);
        layout->addWidget(buttons);
        QObject::connect(buttons->button(QDialogButtonBox::Reset), &QPushButton::clicked, &window, &EditorWindow::appearance_reset);
        QObject::connect(buttons, &QDialogButtonBox::rejected, panel, &QDialog::reject);
        QObject::connect(panel, &QDialog::finished, &window, &EditorWindow::save_appearance);

        panel->adjustSize();
        panel->move(window.mapToGlobal(QPoint(window.width() - panel->width() - 30, 86)));
        window.appearance_panel = panel;
    }

    window.appearance_panel->show();
    window.appearance_panel->raise();
    window.appearance_panel->activateWindow();
}

#ifdef Q_OS_WIN
// The process's private working set, and its whole working set.
static void update_memory(EditorWindow &window)
{
    // The EX2 layout, which recent Windows fills in, including with SDKs that predate the type.
    struct ExtendedCounters {
        PROCESS_MEMORY_COUNTERS_EX counters;
        SIZE_T private_working_set;
        ULONG64 shared_commit;
    };
    ExtendedCounters sample = {};
    PROCESS_MEMORY_COUNTERS *counters = reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&sample.counters);
    HANDLE process = GetCurrentProcess();

    QString label;
    if (GetProcessMemoryInfo(process, counters, sizeof sample) && sample.private_working_set) {
        label = QStringLiteral("Private WS %1 MB  ·  WS %2 MB").arg(double(sample.private_working_set) / 1e6, 0, 'f', 1)
                    .arg(double(sample.counters.WorkingSetSize) / 1e6, 0, 'f', 1);
    } else if (GetProcessMemoryInfo(process, counters, sizeof sample.counters)) {
        label = QStringLiteral("WS %1 MB").arg(double(sample.counters.WorkingSetSize) / 1e6, 0, 'f', 1);
    }
    window.memory_label->setText(label);
}
#endif

//
// Running.
//

// A link in the run's output: "retina-source:current#line:column:encoding" for the file that ran, or a file URL with
// the same fragment for another file. Columns count characters (0), UTF-8 bytes (1), or UTF-16 units (2).
static void show_run_location(void *context, const QUrl &link)
{
    EditorWindow &window = *static_cast<EditorWindow *>(context);
    QStringList coordinates = link.fragment().split(u':');
    if (coordinates.size() != 3)
        return;
    int row = coordinates[0].toInt();
    int column = coordinates[1].toInt();
    int encoding = coordinates[2].toInt();
    if (row < 1 || column < 0)
        return;

    // The file that ran is its tab, or the file again if the tab closed.
    bool ran = link.scheme() == QLatin1StringView("retina-source");
    TextView *view = ran ? window.run_view : nullptr;
    if (!view) {
        QString path = ran ? window.run_path : link.toLocalFile();
        if (path.isEmpty())
            return;

        QString error;
        view = open_file(window, path, error);
        if (!view) {
            show_warning(window, QStringLiteral("Open Diagnostic"), error, QString());
            return;
        }
    }

    // The column as an offset in the line's UTF-16 units.
    uint32_t line = uint32_t(std::min(row, int(line_count(*view))) - 1);
    std::u16string_view text = line_text(view->text, line);
    int remaining = std::max(0, column - 1);
    int offset = 0;
    if (encoding == 2) {
        offset = std::min(remaining, int(text.size()));
    } else {
        while (remaining && offset < int(text.size())) {
            char16_t unit = text[size_t(offset)];
            bool pair = QChar::isHighSurrogate(unit) && size_t(offset) + 1 < text.size() && QChar::isLowSurrogate(text[size_t(offset) + 1]);
            int width = encoding != 1 || unit < 0x80 ? 1 : unit < 0x800 ? 2 : pair ? 4 : 3;
            if (remaining < width)
                break;
            remaining -= width;
            offset += pair ? 2 : 1;
        }
    }

    select_tab(window, view);
    uint32_t position = line_start(*view, line) + uint32_t(offset);
    set_selection(*view, position, position);
    center_caret(*view);
}

static void show_output(EditorWindow &window)
{
    if (!window.run_pane) {
        window.run_pane = new RunPane(&window);
        window.addDockWidget(Qt::BottomDockWidgetArea, window.run_pane);
        window.resizeDocks({window.run_pane}, {170}, Qt::Vertical);
        window.run_pane->link_clicked = show_run_location;
        window.run_pane->link_context = &window;
    }

    window.run_pane->show();
}

// Runs the current tab, or stops the run going on. A tab with unsaved changes, or one never saved, runs from a
// snapshot of its text.
static void run_current_file(EditorWindow &window)
{
    if (window.run_pane && run_going(*window.run_pane)) {
        stop_run(*window.run_pane);
        return;
    }
    TextView *view = active_view(window);
    if (!view)
        return;

    show_output(window);
    window.run_view = view;
    window.run_path = saved_path(*view);
    if (window.run_path.isEmpty() || view->text.modified) {
        QByteArray bytes = source_bytes(*view);
        run_file(*window.run_pane, view->text.language, window.run_path, view->name, &bytes);
    } else {
        run_file(*window.run_pane, view->text.language, window.run_path, view->name, nullptr);
    }
}

//
// The window.
//

// A menu item for a command. Its own key comes first, so the menu shows it, then the platform's keys for the standard
// command. QMenuBar::triggered brings every item to EditorWindow::command_chosen.
static QAction *add_command(QMenu *menu, const char *label, Command command, QKeySequence key, QKeySequence::StandardKey standard)
{
    QList<QKeySequence> shortcuts = QKeySequence::keyBindings(standard);
    if (!key.isEmpty()) {
        shortcuts.removeAll(key);
        shortcuts.prepend(key);
    }

    QAction *action = menu->addAction(QString::fromUtf8(label));
    action->setData(int(command));
    action->setShortcuts(shortcuts);
    return action;
}

// A window with no tabs yet. It has the opener's text appearance and zoom, or when nothing opened it, the saved
// theme and appearance.
static EditorWindow *create_window(const EditorWindow *opener)
{
    EditorWindow *window = new EditorWindow;
    window->setAttribute(Qt::WA_DeleteOnClose);
    if (opener) {
        window->appearance = opener->appearance;
        window->font_size = opener->font_size;
    } else {
        QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
        current_theme = &find_theme(byte_view(settings.value(QStringLiteral("EditorTheme")).toByteArray()));
        settings.beginGroup(QStringLiteral("TextAppearance"));
        for (const AppearanceControl &control : APPEARANCE_CONTROLS) {
            int &value = window->appearance.*control.value;
            value = std::clamp(settings.value(QString::fromLatin1(control.key), value).toInt(), control.minimum, control.maximum);
        }
    }

    window->resize(1040, 720);
    window->setMinimumSize(510, 340);
    window->setWindowTitle(QStringLiteral("Retina Code"));
    window->setAcceptDrops(true);

    window->tabs = new QTabWidget(window);
    window->tabs->setDocumentMode(true);
    window->tabs->setTabsClosable(true);
    window->tabs->setMovable(true);
    window->tabs->setElideMode(Qt::ElideMiddle);
    window->setCentralWidget(window->tabs);

    // The status bar: the caret's line and column, the language picker, the encoding and font size, and on Windows
    // the memory. The picker lists Auto Detect, Plain Text, then the other languages by name.
    window->position_label = new QLabel(window);
    window->language_picker = new QComboBox(window);
    window->language_picker->setAccessibleName(QStringLiteral("Language"));
    window->language_picker->setToolTip(QStringLiteral("Choose this tab's language mode."));
    window->language_picker->addItem(QStringLiteral("Auto Detect"), int(Language::Count));
    window->language_picker->addItem(QString::fromUtf8(language_info(Language(0)).name), 0);
    for (int language = 1; language < int(Language::Count); ++language) {
        QString name = QString::fromUtf8(language_info(Language(language)).name);
        int row = 2;
        while (row < window->language_picker->count() && window->language_picker->itemText(row).compare(name, Qt::CaseInsensitive) < 0)
            row += 1;
        window->language_picker->insertItem(row, name, language);
    }
    window->encoding_label = new QLabel(window);
    window->encoding_label->setToolTip(QStringLiteral("Editor font size in logical pixels, before display scaling."));
    window->statusBar()->addWidget(window->position_label);
    window->statusBar()->addPermanentWidget(window->language_picker);
    window->statusBar()->addPermanentWidget(window->encoding_label);

    // The menus.
    QKeySequence none;
    QMenu *file_menu = window->menuBar()->addMenu(QStringLiteral("&File"));
    add_command(file_menu, "&New Tab", COMMAND_NEW_TAB, none, QKeySequence::New)->setAutoRepeat(false);
    add_command(file_menu, "New &Window", COMMAND_NEW_WINDOW, QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_N), QKeySequence::UnknownKey)->setAutoRepeat(false);
    file_menu->addSeparator();
    add_command(file_menu, "&Open…", COMMAND_OPEN, none, QKeySequence::Open)->setIcon(window->style()->standardIcon(QStyle::SP_DirOpenIcon));
    add_command(file_menu, "&Save", COMMAND_SAVE, none, QKeySequence::Save)->setAutoRepeat(false);
    add_command(file_menu, "Save &As…", COMMAND_SAVE_AS, QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_S), QKeySequence::UnknownKey)->setAutoRepeat(false);
    file_menu->addSeparator();
    add_command(file_menu, "&Close Tab", COMMAND_CLOSE_TAB, QKeySequence(Qt::CTRL | Qt::Key_W), QKeySequence::Close);
    file_menu->addSeparator();
    add_command(file_menu, "&Run Current File", COMMAND_RUN, QKeySequence(Qt::CTRL | Qt::Key_R), QKeySequence::UnknownKey)->setAutoRepeat(false);
    file_menu->addSeparator();
    add_command(file_menu, "E&xit", COMMAND_EXIT, none, QKeySequence::Quit);

    QMenu *edit_menu = window->menuBar()->addMenu(QStringLiteral("&Edit"));
    add_command(edit_menu, "&Undo", COMMAND_UNDO, none, QKeySequence::Undo);
    add_command(edit_menu, "&Redo", COMMAND_REDO, none, QKeySequence::Redo);
    edit_menu->addSeparator();
    add_command(edit_menu, "Cu&t", COMMAND_CUT, none, QKeySequence::Cut);
    add_command(edit_menu, "&Copy", COMMAND_COPY, none, QKeySequence::Copy);
    add_command(edit_menu, "&Paste", COMMAND_PASTE, none, QKeySequence::Paste);
    add_command(edit_menu, "Select &All", COMMAND_SELECT_ALL, none, QKeySequence::SelectAll);
    edit_menu->addSeparator();
#ifdef Q_OS_MAC
    // Control+/ too, and Control+Space for completions since Command+Space is Spotlight. Qt::META is the Control key.
    add_command(edit_menu, "Toggle Line &Comment", COMMAND_TOGGLE_COMMENT, QKeySequence(Qt::CTRL | Qt::Key_Slash), QKeySequence::UnknownKey)
        ->setShortcuts({QKeySequence(Qt::CTRL | Qt::Key_Slash), QKeySequence(Qt::META | Qt::Key_Slash)});
    add_command(edit_menu, "Show &Completions", COMMAND_SHOW_COMPLETIONS, QKeySequence(Qt::META | Qt::Key_Space), QKeySequence::UnknownKey);
#else
    add_command(edit_menu, "Toggle Line &Comment", COMMAND_TOGGLE_COMMENT, QKeySequence(Qt::CTRL | Qt::Key_Slash), QKeySequence::UnknownKey);
    add_command(edit_menu, "Show &Completions", COMMAND_SHOW_COMPLETIONS, QKeySequence(Qt::CTRL | Qt::Key_Space), QKeySequence::UnknownKey);
#endif

    // Zoom In takes Control+= too, the same key without Shift on most layouts.
    QMenu *view_menu = window->menuBar()->addMenu(QStringLiteral("&View"));
    QAction *zoom_in = add_command(view_menu, "Zoom &In", COMMAND_ZOOM_IN, none, QKeySequence::ZoomIn);
    QList<QKeySequence> zoom_in_keys = zoom_in->shortcuts();
    zoom_in_keys.removeAll(QKeySequence(Qt::CTRL | Qt::Key_Equal));
    zoom_in_keys.append(QKeySequence(Qt::CTRL | Qt::Key_Equal));
    zoom_in->setShortcuts(zoom_in_keys);
    add_command(view_menu, "Zoom &Out", COMMAND_ZOOM_OUT, none, QKeySequence::ZoomOut);
    add_command(view_menu, "&Reset Zoom", COMMAND_RESET_ZOOM, QKeySequence(Qt::CTRL | Qt::Key_0), QKeySequence::UnknownKey);
    add_command(view_menu, "Editor &Theme…", COMMAND_THEME, none, QKeySequence::UnknownKey);
    view_menu->addSeparator();
    add_command(view_menu, "&Text Appearance…", COMMAND_TEXT_APPEARANCE, none, QKeySequence::UnknownKey);
    add_command(view_menu, "&Output", COMMAND_OUTPUT, none, QKeySequence::UnknownKey);

    QObject::connect(window->menuBar(), &QMenuBar::triggered, window, &EditorWindow::command_chosen);
    QObject::connect(window->tabs, &QTabWidget::currentChanged, window, &EditorWindow::tab_changed);
    QObject::connect(window->tabs, &QTabWidget::tabCloseRequested, window, &EditorWindow::tab_close_requested);
    QObject::connect(window->language_picker, &QComboBox::activated, window, &EditorWindow::language_chosen);

#ifdef Q_OS_WIN
    window->memory_label = new QLabel(window);
    window->memory_label->setToolTip(QStringLiteral("Resident memory for this process. MB = 1,000,000 bytes."));
    window->statusBar()->addPermanentWidget(window->memory_label);
    window->memory_timer = window->startTimer(2000);
#endif

    show_active_tab(*window);
    return window;
}

static void new_window(EditorWindow &opener)
{
    EditorWindow *window = create_window(&opener);
    new_tab(*window);
    window->show();
    window->raise();
    window->activateWindow();
}

// The Edit menu acts on the output pane, with its own functions, while the pane has focus.
static void run_edit_menu_command(EditorWindow &window, EditCommand command)
{
    QPlainTextEdit *output = qobject_cast<QPlainTextEdit *>(window.focusWidget());
    if (!output) {
        if (active_view(window))
            run_edit_command(*active_view(window), command);
        return;
    }

    switch (command) {
        case EditCommand::Undo: output->undo(); break;
        case EditCommand::Redo: output->redo(); break;
        case EditCommand::Cut: output->cut(); break;
        case EditCommand::Copy: output->copy(); break;
        case EditCommand::Paste: output->paste(); break;
        case EditCommand::SelectAll: output->selectAll(); break;
    }
}

void EditorWindow::command_chosen(QAction *action)
{
    TextView *view = active_view(*this);
    switch (action->data().toInt()) {
        case COMMAND_NEW_TAB: new_tab(*this); break;
        case COMMAND_NEW_WINDOW: new_window(*this); break;
        case COMMAND_OPEN: open_files(*this, QFileDialog::getOpenFileNames(this, QStringLiteral("Open Source Files"))); break;
        case COMMAND_SAVE: save_tab(*this, view, false); break;
        case COMMAND_SAVE_AS: save_tab(*this, view, true); break;
        case COMMAND_RUN: run_current_file(*this); break;
        case COMMAND_EXIT: quit_application(*this); break;

        case COMMAND_CLOSE_TAB:
            if (view)
                close_tab(*this, view);
            break;

        case COMMAND_UNDO: run_edit_menu_command(*this, EditCommand::Undo); break;
        case COMMAND_REDO: run_edit_menu_command(*this, EditCommand::Redo); break;
        case COMMAND_CUT: run_edit_menu_command(*this, EditCommand::Cut); break;
        case COMMAND_COPY: run_edit_menu_command(*this, EditCommand::Copy); break;
        case COMMAND_PASTE: run_edit_menu_command(*this, EditCommand::Paste); break;
        case COMMAND_SELECT_ALL: run_edit_menu_command(*this, EditCommand::SelectAll); break;

        case COMMAND_TOGGLE_COMMENT:
            if (view)
                toggle_line_comment(*view);
            break;

        case COMMAND_SHOW_COMPLETIONS:
            if (view) {
                view->setFocus(Qt::ShortcutFocusReason);
                show_completions(*view, 0);
            }
            break;

        case COMMAND_ZOOM_IN: zoom(*this, font_size + 1); break;
        case COMMAND_ZOOM_OUT: zoom(*this, font_size - 1); break;
        case COMMAND_RESET_ZOOM: zoom(*this, 15); break;
        case COMMAND_THEME: show_theme_picker(*this); break;
        case COMMAND_TEXT_APPEARANCE: show_text_appearance(*this); break;
        case COMMAND_OUTPUT: show_output(*this); break;
    }
}

void EditorWindow::tab_changed()
{
    show_active_tab(*this);
}

void EditorWindow::tab_close_requested(int index)
{
    close_tab(*this, static_cast<TextView *>(tabs->widget(index)));
}

void EditorWindow::language_chosen(int row)
{
    TextView *view = active_view(*this);
    if (!view)
        return;

    set_language_mode(*view, Language(language_picker->itemData(row).toInt()));
    update_language_picker(*this);
    view->setFocus();
}

// A slider moved: the appearance takes every slider's value, and the tab shows it a moment later, so dragging doesn't
// restyle the text at every step.
void EditorWindow::appearance_slider_moved()
{
    for (int index = 0; index < APPEARANCE_CONTROL_COUNT; ++index) {
        int value = appearance_sliders[index]->value();
        int &kept = appearance.*APPEARANCE_CONTROLS[index].value;
        if (value == kept)
            continue;

        kept = value;
        appearance_changed[index] = true;
        appearance_numbers[index]->setText(QString::number(value) + u'%');
    }

    if (!appearance_timer)
        appearance_timer = startTimer(40);
}

void EditorWindow::appearance_reset()
{
    TextAppearance defaults;
    for (int index = 0; index < APPEARANCE_CONTROL_COUNT; ++index)
        appearance_sliders[index]->setValue(defaults.*APPEARANCE_CONTROLS[index].value);
}

// Saves only the controls this window changed, so it keeps what another window saved for the others.
void EditorWindow::save_appearance()
{
    bool changed = false;
    for (int index = 0; index < APPEARANCE_CONTROL_COUNT; ++index)
        changed = changed || appearance_changed[index];
    if (!changed)
        return;

    QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
    settings.beginGroup(QStringLiteral("TextAppearance"));
    for (int index = 0; index < APPEARANCE_CONTROL_COUNT; ++index) {
        if (appearance_changed[index])
            settings.setValue(QString::fromLatin1(APPEARANCE_CONTROLS[index].key), appearance.*APPEARANCE_CONTROLS[index].value);
        appearance_changed[index] = false;
    }
}

void EditorWindow::timerEvent(QTimerEvent *event)
{
    if (event->timerId() == appearance_timer) {
        killTimer(appearance_timer);
        appearance_timer = 0;
        if (active_view(*this))
            apply_appearance(*active_view(*this), *current_theme, appearance);
        return;
    }

#ifdef Q_OS_WIN
    if (event->timerId() == memory_timer) {
        update_memory(*this);
        return;
    }
#endif

    QMainWindow::timerEvent(event);
}

// Control and the wheel over a tab zoom, a step per notch. A finer wheel adds up to notches, and the sum starts over
// when the wheel turns without Control.
bool EditorWindow::eventFilter(QObject *object, QEvent *event)
{
    if (event->type() != QEvent::Wheel)
        return QMainWindow::eventFilter(object, event);

    QWheelEvent *wheel = static_cast<QWheelEvent *>(event);
    int delta = wheel->angleDelta().y();
    if (wheel->modifiers() != Qt::ControlModifier || delta == 0) {
        wheel_zoom = 0;
        return QMainWindow::eventFilter(object, event);
    }

    wheel_zoom += delta;
    int steps = wheel_zoom / 120;
    wheel_zoom %= 120;
    if (steps != 0)
        zoom(*this, font_size + steps);
    wheel->accept();
    return true;
}

// Closing asks about changed tabs, unless Exit did already.
void EditorWindow::closeEvent(QCloseEvent *event)
{
    if (!close_approved && !confirm_close(*this)) {
        event->ignore();
        return;
    }

    save_appearance();
    if (run_pane)
        shut_down_run(*run_pane);
    event->accept();
}

// The local files a drag carries.
static QStringList dropped_files(const QMimeData *mime)
{
    QStringList paths;
    for (const QUrl &url : mime->urls()) {
        QString path = url.toLocalFile();
        if (!path.isEmpty() && QFileInfo(path).isFile())
            paths.append(path);
    }

    return paths;
}

void EditorWindow::dragEnterEvent(QDragEnterEvent *event)
{
    if (dropped_files(event->mimeData()).isEmpty()) {
        event->ignore();
        return;
    }

    dragMoveEvent(event);
}

// Files dragged in are copied, never moved, so the file manager leaves them where they are.
void EditorWindow::dragMoveEvent(QDragMoveEvent *event)
{
    if (!(event->possibleActions() & Qt::CopyAction)) {
        event->ignore();
        return;
    }

    event->setDropAction(Qt::CopyAction);
    event->accept();
}

// The files open after the drop is done, so the file manager isn't left waiting on a message about one that can't.
void EditorWindow::dropEvent(QDropEvent *event)
{
    QStringList paths = dropped_files(event->mimeData());
    if (paths.isEmpty()) {
        event->ignore();
        return;
    }

    event->setDropAction(Qt::CopyAction);
    event->accept();
    dropped_paths += paths;
    QTimer::singleShot(0, this, &EditorWindow::open_dropped_files);
}

void EditorWindow::open_dropped_files()
{
    QStringList paths = dropped_paths;
    dropped_paths.clear();
    open_files(*this, paths);
}
