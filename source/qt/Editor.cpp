// The editor window: tabs of TextView editors, the menus, the status bar, and the run pane. main_qt.cpp includes
// TextView.cpp before this file.

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
#include <QFormLayout>
#include <QHBoxLayout>
#include <QIcon>
#include <QLabel>
#include <QLineEdit>
#include <QListView>
#include <QMainWindow>
#include <QMenuBar>
#include <QMessageBox>
#include <QMimeData>
#include <QPainter>
#include <QPalette>
#include <QPointer>
#include <QProxyStyle>
#include <QPushButton>
#include <QSaveFile>
#include <QSettings>
#include <QShortcut>
#include <QSlider>
#include <QStandardPaths>
#include <QStatusBar>
#include <QStringDecoder>
#include <QStyle>
#include <QStyleHints>
#include <QStyleOption>
#include <QTabBar>
#include <QTabWidget>
#include <QTextEdit>
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

#include "RunPane.h"

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

std::string_view utf8View(const QByteArray &text)
{
    return {text.constData(), size_t(text.size())};
}

constexpr char utf8Bom[] = "\xef\xbb\xbf";

FileFormat formatOf(std::string_view bytes)
{
    FileFormat format;
    format.bom = bytes.starts_with(utf8Bom);
    const auto first = bytes.find_first_of("\r\n");
    if (first != bytes.npos && bytes[first] == '\r')
        format.newline = bytes.substr(first, 2) == "\r\n" ? LineEnding::CRLF : LineEnding::CR;
    return format;
}

// The path a file is run from, or nothing for text that was never saved.
QString source_path(const TextView &view)
{
    return view.file_path.isEmpty() ? QString() : QString::fromUtf8(view.language_path);
}

// The text as it is saved: in UTF-8, with the file's own line endings.
QByteArray source_bytes(const TextView &view)
{
    QString text = qstring_of(std::u16string_view(view.text.units.data(), view.text.units.size()));
    if (view.file_format.newline == LineEnding::CRLF)
        text.replace(u'\n', QStringLiteral("\r\n"));
    else if (view.file_format.newline == LineEnding::CR)
        text.replace(u'\n', u'\r');
    return text.toUtf8();
}

// After Save As: the view takes the file's name and path, and detects its language again from the new name.
void adopt_path(TextView &view, const QFileInfo &info, const QString &resolved_path)
{
    view.name = info.fileName();
    view.file_path = resolved_path;
    view.language_path = QDir::fromNativeSeparators(info.absoluteFilePath()).toUtf8();
    view.detects_from_text = detect_language(utf8View(view.language_path)) == Language::Plain;
    if (view.mode == Language::Count)
        set_view_language(view, detect_view_language(view));
}

QString tab_label(const TextView &view)
{
    QString label = view.name;
    label.replace(QLatin1Char('&'), QStringLiteral("&&"));
    return view.text.modified ? QStringLiteral("* ") + label : label;
}

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
            : QStringLiteral("%1 (Auto)").arg(QString::fromUtf8(language_info(language).name));
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
                result[i] = {Language(i), QString::fromUtf8(language_info(Language(i)).name)};
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
                apply_appearance(*editor, *theme_, appearance_);
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
                set_language_mode(*editor, Language(languagePicker_->itemData(row).toInt()));
                updateLanguagePicker();
                editor->setFocus();
            }
        });

        makeActions();
        connect(tabs_, &QTabWidget::currentChanged, this, [this] { activateTab(); });
        connect(tabs_, &QTabWidget::tabCloseRequested, this, [this](int index) {
            QPointer<TextView> editor = static_cast<TextView *>(tabs_->widget(index));
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
        TextView *first = nullptr;
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

    TextView *openTabForPath(const QString &path) const
    {
        for (int i = 0; i < tabs_->count(); ++i) {
            auto *editor = static_cast<TextView *>(tabs_->widget(i));
            if (editor->file_path == path)
                return editor;
            if (editor->file_path.compare(path, Qt::CaseInsensitive) == 0) {
                // Qt can retain the caller's spelling on a case-insensitive volume.
                std::error_code failure;
                if (std::filesystem::equivalent(QFileInfo(path).filesystemAbsoluteFilePath(),
                                                QFileInfo(editor->file_path).filesystemAbsoluteFilePath(), failure))
                    return editor;
            }
        }
        return nullptr;
    }

    TextView *openFile(const QString &path, QString &error)
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
        editor->file_format = formatOf(utf8View(bytes));
        return editor;
    }

    static QString writeFile(const TextView &editor, const QString &path)
    {
        QSaveFile file(path);
        if (!file.open(QIODevice::WriteOnly))
            return file.errorString();
        if (editor.file_format.bom && file.write(utf8Bom, sizeof(utf8Bom) - 1) != sizeof(utf8Bom) - 1)
            return file.errorString();
        const QByteArray bytes = source_bytes(editor);
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
        runSourcePath_ = source_path(*editor);
        if (runSourcePath_.isEmpty() || editor->text.modified) {
            const auto bytes = source_bytes(*editor);
            runPane_->run(editor->text.language, runSourcePath_, editor->name, &bytes);
        } else {
            runPane_->run(editor->text.language, runSourcePath_, editor->name, nullptr);
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
        const uint32_t line = uint32_t(std::min(row, int(line_count(*editor))) - 1);
        const std::u16string_view text = line_text(editor->text, line);
        int remaining = std::max(0, column - 1);
        int offset = 0;
        if (encoding == 2) {
            offset = std::min(remaining, int(text.size()));
        } else {
            while (remaining && offset < int(text.size())) {
                const char16_t unit = text[size_t(offset)];
                const bool pair = QChar::isHighSurrogate(unit) && size_t(offset) + 1 < text.size() &&
                                  QChar::isLowSurrogate(text[size_t(offset) + 1]);
                const int width = encoding != 1 || unit < 0x80 ? 1 : unit < 0x800 ? 2 : pair ? 4 : 3;
                if (remaining < width)
                    break;
                remaining -= width;
                offset += pair ? 2 : 1;
            }
        }
        selectTab(editor);
        const uint32_t position = line_start(*editor, line) + uint32_t(offset);
        set_selection(*editor, position, position);
        center_caret(*editor);
    }

    bool saveTab(TextView *editor, bool saveAs = false)
    {
        if (!editor)
            return false;
        const bool choosePath = saveAs || editor->file_path.isEmpty();
        if (!choosePath && !editor->text.modified)
            return true;

        QPointer<TextView> guard = editor;
        QString path = editor->file_path;
        if (choosePath) {
            QString suggested = source_path(*editor);
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
            adopt_path(*editor, info, resolvedPath(info));
            tabs_->setTabToolTip(tab, QDir::toNativeSeparators(info.absoluteFilePath()));
        }
        mark_view_saved(*editor);
        tabs_->setTabText(tab, tab_label(*editor));
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

    TextView *activeEditor() const { return static_cast<TextView *>(tabs_->currentWidget()); }

    void selectTab(TextView *editor)
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

    TextView *addTab(const QString &name, const QString &text, const QString &sourcePath = {},
                     const QString &filePath = {})
    {
        auto *editor = new TextView(name, text, sourcePath, *theme_, fontSize_, appearance_);
        editor->file_path = filePath;
        editor->notify = editorChanged;
        editor->notify_context = this;
        editor->viewport()->installEventFilter(this);
        const int index = tabs_->addTab(editor, tab_label(*editor));
        tabs_->setTabToolTip(index, sourcePath.isEmpty() ? name : QDir::toNativeSeparators(sourcePath));
        return editor;
    }

    // What a tab's editor reports: the status bar follows the caret, the tab's label shows whether the text is
    // saved, and the language picker shows the language detected.
    static void editorChanged(void *context, TextView &editor, uint32_t changes)
    {
        EditorWindow &window = *static_cast<EditorWindow *>(context);
        if (changes & VIEW_CARET_MOVED)
            window.updateStatus();
        if (changes & VIEW_MODIFIED_CHANGED)
            window.tabs_->setTabText(window.tabs_->indexOf(&editor), tab_label(editor));
        if ((changes & VIEW_LANGUAGE_CHANGED) && &editor == window.activeEditor())
            window.updateLanguagePicker();
    }

    bool confirmCloseTab(TextView *editor)
    {
        if (!editor->text.modified)
            return true;
        QPointer<TextView> guard = editor;
        const auto choice = QMessageBox::question(this, QStringLiteral("Unsaved Changes"),
                                                  QStringLiteral("Save changes to %1?").arg(editor->name),
                                                  QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel,
                                                  QMessageBox::Cancel);
        return choice == QMessageBox::Discard || (choice == QMessageBox::Save && guard && saveTab(guard));
    }

    bool confirmClose()
    {
        for (int i = 0; i < tabs_->count(); ++i) {
            if (!confirmCloseTab(static_cast<TextView *>(tabs_->widget(i))))
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
            apply_appearance(*editor, *theme_, appearance_);
        setWindowTitle(editor ? editor->name + QStringLiteral(" — Retina Code") : QStringLiteral("Retina Code"));
        updateLanguagePicker();
        updateStatus();
    }

    void updateLanguagePicker()
    {
        auto *editor = activeEditor();
        languagePicker_->setEnabled(editor != nullptr);
        const Language mode = editor ? editor->mode : Language::Count;
        languageChoices_.setDetectedLanguage(editor && mode == Language::Count ? editor->text.language : Language::Count);
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
        const uint32_t line = caret_line(*editor);
        position_->setText(QStringLiteral("Ln %1, Col %2").arg(line + 1).arg(editor->caret - line_start(*editor, line) + 1));
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
        addEditAction(edit, QStringLiteral("&Undo"), QKeySequence::Undo, EditCommand::Undo);
        addEditAction(edit, QStringLiteral("&Redo"), QKeySequence::Redo, EditCommand::Redo);
        edit->addSeparator();
        addEditAction(edit, QStringLiteral("Cu&t"), QKeySequence::Cut, EditCommand::Cut);
        addEditAction(edit, QStringLiteral("&Copy"), QKeySequence::Copy, EditCommand::Copy);
        addEditAction(edit, QStringLiteral("&Paste"), QKeySequence::Paste, EditCommand::Paste);
        addEditAction(edit, QStringLiteral("Select &All"), QKeySequence::SelectAll, EditCommand::SelectAll);
        edit->addSeparator();
        auto *comment = edit->addAction(QStringLiteral("Toggle Line &Comment"),
            QKeySequence(Qt::CTRL | Qt::Key_Slash), this, [this] {
                if (auto *editor = activeEditor())
                    toggle_line_comment(*editor);
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
                show_completions(*editor, 0);
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

    void addEditAction(QMenu *menu, const QString &label, QKeySequence::StandardKey key, EditCommand command)
    {
        auto *action = menu->addAction(label);
        action->setShortcuts(key);
        connect(action, &QAction::triggered, this, [this, command] {
            auto *focused = focusWidget();
            if (auto *text = qobject_cast<QTextEdit *>(focused))
                runEditCommand(*text, command);
            else if (auto *field = qobject_cast<QLineEdit *>(focused))
                runEditCommand(*field, command);
            else if (auto *editor = activeEditor())
                run_edit_command(*editor, command);
        });
    }

    // The Edit menu in the output pane and in text fields, which have Qt's own edit functions.
    template <class TextWidget>
    static void runEditCommand(TextWidget &text, EditCommand command)
    {
        switch (command) {
            case EditCommand::Undo: text.undo(); break;
            case EditCommand::Redo: text.redo(); break;
            case EditCommand::Cut: text.cut(); break;
            case EditCommand::Copy: text.copy(); break;
            case EditCommand::Paste: text.paste(); break;
            case EditCommand::SelectAll: text.selectAll(); break;
        }
    }

    void zoom(int size)
    {
        const int clamped = std::clamp(size, 9, 36);
        if (fontSize_ == clamped)
            return;
        fontSize_ = clamped;
        for (int i = 0; i < tabs_->count(); ++i)
            apply_font_size(*static_cast<TextView *>(tabs_->widget(i)), fontSize_);
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
                    apply_appearance(*editor, theme, window->appearance_);
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
    QPointer<TextView> runSource_;
    QString runSourcePath_;
    QTimer appearanceUpdate_;
    int fontSize_ = 15;
    int wheelZoomDelta_ = 0;
    bool closeApproved_ = false;
};

} // namespace
