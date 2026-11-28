// The run pane: runs a tab's file through Run.cpp and shows what it writes, in its colors and with links to the
// places diagnostics name. While the program runs, what's typed after its output goes to its input. main_qt.cpp
// includes this file before Window.cpp.
//
// The job runs on a thread of its own. Its children are QProcesses on that thread, which waits on them with
// QProcess's blocking calls. The job posts an event to the pane when its log has lines, and the pane shows them.

#include <QCoreApplication>
#include <QDir>
#include <QDockWidget>
#include <QEvent>
#include <QFileInfo>
#include <QFontDatabase>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QMimeData>
#include <QMouseEvent>
#include <QPlainTextEdit>
#include <QProcess>
#include <QScrollBar>
#include <QTextBlock>
#include <QUrl>

#include <thread>

#if defined(Q_OS_WIN)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#elif defined(Q_OS_UNIX)
#include <csignal>
#include <unistd.h>
#endif

#include "../Color.h"
#include "../Run.hpp"

static const int RUN_INPUT_LIMIT = 16 * 1024;      // the most that can be typed for the program before Return
static const QEvent::Type RUN_OUTPUT_EVENT = QEvent::Type(QEvent::User + 1);
#ifdef Q_OS_MAC
static const Qt::KeyboardModifier END_OF_INPUT_MODIFIER = Qt::MetaModifier;    // Control, which Qt calls Meta on macOS
#else
static const Qt::KeyboardModifier END_OF_INPUT_MODIFIER = Qt::ControlModifier;
#endif

struct RunPane;

// The output, which takes typing after the program's output while the program can read it. It's a QPlainTextEdit, so
// it lays out only the lines it shows.
struct RunOutput : QPlainTextEdit {
    RunPane *pane = nullptr;

    void keyPressEvent(QKeyEvent *event) override;
    void inputMethodEvent(QInputMethodEvent *event) override;
    void insertFromMimeData(const QMimeData *source) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    bool event(QEvent *event) override;
    void update_input();
};

struct RunPane : QDockWidget {
    RunOutput output;
    RunJob *job = nullptr;             // the run going on, until its thread ends
    std::thread thread;
    RunLog shown;                      // the lines taken from the job last, kept for their buffers
    QTextCursor input_start;           // where typing for the program starts, while it can read

    // Who hears about a click on a link in the output: the window, which shows the place it names.
    void (*link_clicked)(void *context, const QUrl &link) = nullptr;
    void *link_context = nullptr;

    explicit RunPane(QWidget *parent);
    ~RunPane() override;
    bool event(QEvent *event) override;
};

static QString utf8_string(std::string_view bytes)
{
    return QString::fromUtf8(bytes.data(), qsizetype(bytes.size()));
}

//
// Running a child, on the job's thread.
//

// Wakes the pane on its thread. The job calls this once until the pane takes the log.
void notify_run_output(RunJob &job)
{
    QCoreApplication::postEvent(static_cast<RunPane *>(job.frontend), new QEvent(RUN_OUTPUT_EVENT));
}

static void read_channel(RunJob &job, QProcess &process, QProcess::ProcessChannel channel)
{
    process.setReadChannel(channel);
    char buffer[16 * 1024];
    for (;;) {
        qint64 count = process.read(buffer, sizeof buffer);
        if (count <= 0)
            break;
        child_output(job, channel == QProcess::StandardError, std::string_view(buffer, size_t(count)));
    }
}

// Runs the child to its end. It goes into a group of its own, so stopping it stops what it started too: a job
// object on Windows that kills its processes when it closes, and on Unix a session of its own.
int run_child(RunJob &job, const ChildCommand &child)
{
    QProcess process;
    process.setProgram(utf8_string(child.program));
    QStringList arguments;
    for (std::string_view rest = child.arguments; !rest.empty();) {
        size_t end = rest.find('\0');
        arguments.append(utf8_string(rest.substr(0, end)));
        rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
    }
    process.setArguments(arguments);
    process.setWorkingDirectory(utf8_string(child.folder));

    // The job's environment, or the app's, with the folders of tools found outside PATH.
    if (!job.environment.empty() || !job.extra_path.empty()) {
        QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
        if (!job.environment.empty()) {
            environment = QProcessEnvironment();
            for (std::string_view rest = job.environment; !rest.empty();) {
                std::string_view entry = rest.substr(0, rest.find('\0'));
                rest.remove_prefix(std::min(entry.size() + 1, rest.size()));
                size_t equals = entry.find('=', 1);
                if (equals != std::string_view::npos)
                    environment.insert(utf8_string(entry.substr(0, equals)), utf8_string(entry.substr(equals + 1)));
            }
        }
        if (!job.extra_path.empty()) {
            QString path = environment.value(QStringLiteral("PATH"));
            if (!path.isEmpty())
                path += QDir::listSeparator();
            environment.insert(QStringLiteral("PATH"), path + QDir::toNativeSeparators(utf8_string(job.extra_path)));
        }
        process.setProcessEnvironment(environment);
    }
#ifdef Q_OS_UNIX
    QProcess::UnixProcessParameters parameters;
    parameters.flags = QProcess::UnixProcessFlag::CreateNewSession;
    process.setUnixProcessParameters(parameters);
#endif

    process.start();
    if (!process.waitForStarted(-1)) {
        QString message = QFileInfo(process.program()).fileName() + QStringLiteral(": ") + process.errorString() + u'\n';
        log_status(job, message.toStdString(), OutputTone::Error);
        return CHILD_NOT_STARTED;
    }
    qint64 group = process.processId();
#ifdef Q_OS_WIN
    HANDLE job_object = CreateJobObjectW(nullptr, nullptr);
    if (job_object) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        HANDLE handle = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, DWORD(group));
        if (!handle || !SetInformationJobObject(job_object, JobObjectExtendedLimitInformation, &limits, sizeof limits) ||
            !AssignProcessToJobObject(job_object, handle)) {
            CloseHandle(job_object);
            job_object = nullptr;
        }
        if (handle)
            CloseHandle(handle);
    }
#endif

    // A tool gets its input and then the end of it. The program reads what the pane sends it.
    if (!child.input.empty())
        process.write(child.input.data(), qint64(child.input.size()));
    if (child.kind != CHILD_PROGRAM)
        process.closeWriteChannel();
    child_started(job);

    std::string typed;
    bool close = false;
    bool stopped = false;
    for (;;) {
        if (job.stop && !stopped) {
            stopped = true;
#ifdef Q_OS_WIN
            if (job_object)
                TerminateJobObject(job_object, 1);
#elif defined(Q_OS_UNIX)
            ::kill(-pid_t(group), SIGKILL);
#endif
            process.kill();
        }
        if (child.kind == CHILD_PROGRAM && !stopped && take_child_input(job, typed, close)) {
            if (!typed.empty())
                process.write(typed.data(), qint64(typed.size()));
            if (close)
                process.closeWriteChannel();
        }

        bool ready = process.waitForReadyRead(25);
        read_channel(job, process, QProcess::StandardOutput);
        read_channel(job, process, QProcess::StandardError);
        if (!ready && process.state() == QProcess::NotRunning)
            break;
        if (!ready)
            child_idle(job);
    }
    read_channel(job, process, QProcess::StandardOutput);
    read_channel(job, process, QProcess::StandardError);

    // What the child started dies with it.
#ifdef Q_OS_WIN
    if (job_object)
        CloseHandle(job_object);
#elif defined(Q_OS_UNIX)
    ::kill(-pid_t(group), SIGKILL);
#endif
    if (process.exitStatus() == QProcess::CrashExit)
        return CHILD_CRASHED;
    return process.exitCode();
}

//
// The output.
//

static QColor tone_color(OutputTone tone, const QPalette &palette)
{
    bool dark = palette.color(QPalette::Base).lightness() < 128;
    if (tone == OutputTone::Error)
        return dark ? QColor(255, 128, 123) : QColor(166, 31, 36);
    if (tone == OutputTone::Warning)
        return dark ? QColor(240, 193, 95) : QColor(139, 88, 0);
    return palette.color(QPalette::Text);
}

static QColor terminal_color(uint32_t color, bool dark)
{
    uint32_t ink = RunTerminalColor(color, dark);
    return QColor(ColorRed(ink), ColorGreen(ink), ColorBlue(ink), ColorAlpha(ink));
}

// Where output goes: before the program's input while it can read, else at the end.
static QTextCursor output_cursor(const RunPane &pane)
{
    QTextCursor cursor(pane.output.document());
    cursor.setPosition(pane.input_start.isNull() ? pane.output.document()->characterCount() - 1 : pane.input_start.position());
    return cursor;
}

// Drops the oldest lines past the scrollback's limits, at a line's start where it can.
static void trim_output(RunPane &pane, const QTextCursor &end)
{
    int first_line = end.blockNumber() - int(outputScrollbackLines);
    int excess = end.position() - int(outputScrollbackCharacters);
    if (first_line <= 0 && excess <= 0)
        return;

    int line_start = first_line > 0 ? pane.output.document()->findBlockByNumber(first_line).position() : 0;
    QTextCursor cursor(end);
    cursor.setPosition(std::max(excess, line_start));
    QTextBlock next = cursor.block().next();
    if (cursor.positionInBlock() && next.isValid() && next.position() < end.position())
        cursor.setPosition(next.position());
    else if (pane.output.document()->characterAt(cursor.position()).isLowSurrogate())
        cursor.setPosition(cursor.position() + 1);
    cursor.setPosition(0, QTextCursor::KeepAnchor);
    cursor.removeSelectedText();
}

static void set_input_enabled(RunPane &pane, bool enabled)
{
    if (enabled == !pane.input_start.isNull())
        return;

    QTextCursor cursor = output_cursor(pane);
    if (enabled) {
        pane.input_start = cursor;
        pane.input_start.setKeepPositionOnInsert(true);
    } else {
        pane.input_start = QTextCursor();
        cursor.movePosition(QTextCursor::End, QTextCursor::KeepAnchor);
        cursor.removeSelectedText();
    }
    pane.output.update_input();
}

static void insert_text(QTextCursor &cursor, const QString &text, int first, int last, const QTextCharFormat &format)
{
    if (last > first)
        cursor.insertText(text.sliced(first, last - first), format);
}

// A link for a message's place: "retina-source:current" for the file that ran, or the file's URL for another file,
// with "line:column:encoding" as the fragment. The window reads it.
static QString message_link(const RunLog &log, const RunLine &message)
{
    QUrl link;
    if (message.current_source) {
        link.setScheme(QStringLiteral("retina-source"));
        link.setPath(QStringLiteral("current"));
    } else {
        link = QUrl::fromLocalFile(utf8_string(std::string_view(log.text).substr(message.file_start, message.file_length)));
    }
    int encoding = message.columns == RUN_COLUMN_UTF16 ? 2 : message.columns == RUN_COLUMN_BYTES ? 1 : 0;
    link.setFragment(QStringLiteral("%1:%2:%3").arg(message.line).arg(message.column).arg(encoding));
    return link.toString(QUrl::FullyEncoded);
}

// Shows the lines the job wrote since the last time, and the input as the job has it now. A job that finished goes.
static void show_run_output(RunPane &pane)
{
    take_run_log(*pane.job, pane.shown);
    RunLog &log = pane.shown;

    QScrollBar *scroll = pane.output.verticalScrollBar();
    bool follow = scroll->value() == scroll->maximum();
    QTextCursor cursor = output_cursor(pane);
    cursor.beginEditBlock();
    if (log.discarded) {
        cursor.setPosition(0, QTextCursor::KeepAnchor);
        cursor.removeSelectedText();
    }

    QPalette palette = pane.output.palette();
    bool dark = palette.color(QPalette::Base).lightness() < 128;
    for (const RunLine &message : log.messages) {
        // The text in its tone, then its colors, then the link over it.
        QString text = utf8_string(std::string_view(log.text).substr(message.text_start, message.text_length));
        int start = cursor.position();
        int length = int(text.size());
        QTextCharFormat base;
        base.setForeground(tone_color(VisibleOutputTone(message.tone, message.colored), palette));
        int at = 0;
        for (uint32_t index = 0; index < message.span_count; ++index) {
            const OutputColorSpan &span = log.spans[message.spans_start + index];
            int first = std::min(length, int(span.range.location));
            int last = std::min(length, int(span.range.location + span.range.length));
            insert_text(cursor, text, at, first, base);
            QTextCharFormat format = base;
            if (span.colors.foreground != defaultOutputColor)
                format.setForeground(terminal_color(span.colors.foreground, dark));
            if (span.colors.background != defaultOutputColor)
                format.setBackground(terminal_color(span.colors.background, dark));
            insert_text(cursor, text, std::max(at, first), last, format);
            at = std::max(at, last);
        }
        insert_text(cursor, text, at, length, base);

        if (message.link_length && message.line && int(message.link_start + message.link_length) <= length) {
            QTextCharFormat anchor;
            anchor.setAnchor(true);
            anchor.setAnchorHref(message_link(log, message));
            anchor.setFontUnderline(true);
            QTextCursor range = cursor;
            range.setPosition(start + int(message.link_start));
            range.setPosition(start + int(message.link_start + message.link_length), QTextCursor::KeepAnchor);
            range.mergeCharFormat(anchor);
        }
    }

    if (!pane.input_start.isNull())
        pane.input_start.setPosition(cursor.position());
    trim_output(pane, cursor);
    cursor.endEditBlock();
    set_input_enabled(pane, log.input_open);
    pane.output.update_input();
    if (follow)
        scroll->setValue(scroll->maximum());

    bool finished = log.finished;
    log.text.clear();
    log.spans.clear();
    log.messages.clear();
    if (finished) {
        pane.thread.join();
        delete pane.job;
        pane.job = nullptr;
    }
}

// Sends what was typed, with a line break, or at the end of input without one, and then closes the program's input.
static void send_input(RunPane &pane, bool end_of_input)
{
    if (pane.input_start.isNull() || !pane.job)
        return;

    QTextCursor cursor = output_cursor(pane);
    cursor.movePosition(QTextCursor::End, QTextCursor::KeepAnchor);
    QString typed = cursor.selectedText();
    typed.replace(QChar::ParagraphSeparator, u'\n');
    typed.replace(QChar::LineSeparator, u'\n');
    QByteArray bytes = typed.toUtf8();
    if (!end_of_input)
        bytes += '\n';
    {
        std::lock_guard lock(pane.job->mutex);
        pane.job->typed.append(bytes.constData(), size_t(bytes.size()));
        pane.job->end_of_input |= end_of_input;
    }

    // What was typed stays in the output, before the output that comes after it.
    cursor.clearSelection();
    cursor.beginEditBlock();
    if (!end_of_input)
        cursor.insertText(QStringLiteral("\n"), QTextCharFormat());
    pane.input_start.setPosition(cursor.position());
    trim_output(pane, cursor);
    cursor.endEditBlock();
    pane.output.moveCursor(QTextCursor::End);
    pane.output.verticalScrollBar()->setValue(pane.output.verticalScrollBar()->maximum());
    if (end_of_input)
        set_input_enabled(pane, false);
}

//
// Running.
//

// Runs a file with its language's tools: the tab's file, or the tab's text when there's a draft.
static void run_file(RunPane &pane, Language language, const QString &file, const QString &name, const QByteArray *draft)
{
    if (pane.job)
        return;

    pane.output.clear();
    pane.input_start = QTextCursor();
    RunJob *job = new RunJob();
    job->language = language;
    QByteArray path = file.toUtf8();
    job->file.assign(path.constData(), size_t(path.size()));
    QByteArray tab = name.toUtf8();
    job->name.assign(tab.constData(), size_t(tab.size()));
    if (draft) {
        job->draft.assign(draft->constData(), size_t(draft->size()));
        job->has_draft = true;
    }
    job->frontend = &pane;
    pane.job = job;
    pane.thread = std::thread(run_job, std::ref(*job));
}

// Whether a run is going on. A job that finished whose last lines haven't shown yet shows them and goes.
static bool run_going(RunPane &pane)
{
    if (!pane.job)
        return false;

    bool finished;
    {
        std::lock_guard lock(pane.job->mutex);
        finished = pane.job->finished;
    }
    if (finished)
        show_run_output(pane);
    return !finished;
}

static void stop_run(RunPane &pane)
{
    if (!pane.job)
        return;

    pane.job->stop = true;
    set_input_enabled(pane, false);
}

// Stops a run as the window closes, and waits for its thread, which ends once the child dies.
static void shut_down_run(RunPane &pane)
{
    if (!pane.job)
        return;

    stop_run(pane);
    pane.thread.join();
    delete pane.job;
    pane.job = nullptr;
}

//
// The pane and its output.
//

RunPane::RunPane(QWidget *parent) : QDockWidget(QStringLiteral("Output"), parent)
{
    setAllowedAreas(Qt::BottomDockWidgetArea);
    setFeatures(QDockWidget::DockWidgetClosable);
    setWidget(&output);

    output.pane = this;
    output.setReadOnly(true);
    output.setAcceptDrops(false);
    output.setUndoRedoEnabled(false);
    output.setLineWrapMode(QPlainTextEdit::NoWrap);
    output.viewport()->setMouseTracking(true);
    QFont font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
#ifdef Q_OS_WIN
    font.setFamily(QStringLiteral("Consolas"));
    font.setHintingPreference(QFont::PreferVerticalHinting);
#endif
    font.setPixelSize(13);
    output.setFont(font);
    QObject::connect(&output, &QPlainTextEdit::cursorPositionChanged, &output, &RunOutput::update_input);
    QObject::connect(&output, &QPlainTextEdit::selectionChanged, &output, &RunOutput::update_input);
}

RunPane::~RunPane()
{
    shut_down_run(*this);
}

bool RunPane::event(QEvent *event)
{
    if (event->type() != RUN_OUTPUT_EVENT)
        return QDockWidget::event(event);

    if (job)
        show_run_output(*this);
    return true;
}

// The output is read-only except at the program's input, and typing at the input's start takes no color from the
// output before it.
void RunOutput::update_input()
{
    QTextCursor cursor = textCursor();
    bool read_only = pane->input_start.isNull() || cursor.selectionStart() < pane->input_start.position();
    if (read_only != isReadOnly())
        setReadOnly(read_only);
    if (!read_only && !cursor.hasSelection() && cursor.position() == pane->input_start.position())
        setCurrentCharFormat(QTextCharFormat());
}

// Typing goes to the input, and fits in RUN_INPUT_LIMIT.
static void move_to_input(RunOutput &output)
{
    if (output.textCursor().selectionStart() < output.pane->input_start.position())
        output.moveCursor(QTextCursor::End);
}

static bool input_fits(const RunOutput &output, int added, int removed)
{
    int typed = output.document()->characterCount() - 1 - output.pane->input_start.position();
    return added <= RUN_INPUT_LIMIT - (typed - removed);
}

// Return sends the line typed and Control+D ends the input. Erasing stops at the input's start.
void RunOutput::keyPressEvent(QKeyEvent *event)
{
    if (pane->input_start.isNull()) {
        QPlainTextEdit::keyPressEvent(event);
        return;
    }

    bool end_of_input = event->key() == Qt::Key_D && event->modifiers() == END_OF_INPUT_MODIFIER;
    if (end_of_input || event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) {
        send_input(*pane, end_of_input);
        event->accept();
        return;
    }

    QTextCursor cursor = textCursor();
    int first = pane->input_start.position();
    if (!cursor.hasSelection() && cursor.position() >= first && event->matches(QKeySequence::DeleteStartOfWord)) {
        int end = cursor.position();
        cursor.movePosition(QTextCursor::PreviousWord);
        cursor.setPosition(std::max(first, cursor.position()));
        cursor.setPosition(end, QTextCursor::KeepAnchor);
        cursor.removeSelectedText();
        setTextCursor(cursor);
        event->accept();
        return;
    }
    if (!cursor.hasSelection() && cursor.position() == first && (event->key() == Qt::Key_Backspace || event->matches(QKeySequence::Backspace))) {
        event->accept();
        return;
    }

    // A character typed anywhere goes to the end of the input.
    QString text = event->text();
    Qt::KeyboardModifiers modifiers = event->modifiers();
    bool command = (modifiers & (Qt::ControlModifier | Qt::MetaModifier)) && !(modifiers & (Qt::AltModifier | Qt::GroupSwitchModifier));
    if (!command && !text.isEmpty() && (text.front().unicode() >= ' ' || text.front() == u'\t')) {
        move_to_input(*this);
        cursor = textCursor();
        if (!input_fits(*this, int(text.size()), cursor.selectionEnd() - cursor.selectionStart())) {
            event->accept();
            return;
        }
    }
    QPlainTextEdit::keyPressEvent(event);
}

void RunOutput::inputMethodEvent(QInputMethodEvent *event)
{
    if (pane->input_start.isNull())
        return;

    move_to_input(*this);
    QTextCursor cursor = textCursor();
    int selection = cursor.selectionEnd() - cursor.selectionStart();
    int start = cursor.selectionStart() + event->replacementStart();
    if (start >= pane->input_start.position() && start + event->replacementLength() < document()->characterCount() - selection &&
        input_fits(*this, int(event->commitString().size()), selection + event->replacementLength()))
        QPlainTextEdit::inputMethodEvent(event);
}

void RunOutput::insertFromMimeData(const QMimeData *source)
{
    if (pane->input_start.isNull() || !source->hasText())
        return;

    move_to_input(*this);
    QTextCursor cursor = textCursor();
    QString text = source->text();
    if (input_fits(*this, int(text.size()), cursor.selectionEnd() - cursor.selectionStart())) {
        cursor.insertText(text, QTextCharFormat());
        setTextCursor(cursor);
    }
}

// While the program reads, the end of input key is the output's, not the window's Add Next Occurrence.
bool RunOutput::event(QEvent *event)
{
    if (event->type() == QEvent::ShortcutOverride && !pane->input_start.isNull()) {
        QKeyEvent *key = static_cast<QKeyEvent *>(event);
        if (key->key() == Qt::Key_D && key->modifiers() == END_OF_INPUT_MODIFIER) {
            event->accept();
            return true;
        }
    }
    return QPlainTextEdit::event(event);
}

// Links show the pointing hand, and a click on one that selects nothing opens the place it names.
void RunOutput::mouseMoveEvent(QMouseEvent *event)
{
    QPlainTextEdit::mouseMoveEvent(event);
    bool link = !anchorAt(event->position().toPoint()).isEmpty();
    viewport()->setCursor(link ? Qt::PointingHandCursor : Qt::IBeamCursor);
}

void RunOutput::mouseReleaseEvent(QMouseEvent *event)
{
    QPlainTextEdit::mouseReleaseEvent(event);
    QString link = anchorAt(event->position().toPoint());
    if (event->button() == Qt::LeftButton && !link.isEmpty() && !textCursor().hasSelection() && pane->link_clicked)
        pane->link_clicked(pane->link_context, QUrl(link));
}
