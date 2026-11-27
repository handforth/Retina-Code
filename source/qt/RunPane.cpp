// The run pane: runs a tab's file with the tool for its language, building it first when the language compiles, and
// shows what the program writes, in its colors and with links to the lines that diagnostics name. While the program
// runs, what's typed after its output goes to its input. main_qt.cpp includes this file before Window.cpp.

#include <QDir>
#include <QDockWidget>
#include <QFileInfo>
#include <QFontDatabase>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QMimeData>
#include <QProcess>
#include <QScrollBar>
#include <QStandardPaths>
#include <QStringDecoder>
#include <QTemporaryDir>
#include <QTemporaryFile>
#include <QTextBlock>
#include <QTextBrowser>

#include <algorithm>
#include <limits>

#if defined(Q_OS_WIN)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#elif defined(Q_OS_UNIX)
#include <csignal>
#include <unistd.h>
#endif

#include "../Color.h"
#include "../RunText.hpp"
#include "../RunTools.hpp"

static const size_t RUN_LINE_LIMIT = 64 * 1024;    // output lines longer than this are left out
static const int RUN_INPUT_LIMIT = 16 * 1024;      // the most that can be typed for the program before Return
#ifdef Q_OS_MAC
static const Qt::KeyboardModifier END_OF_INPUT_MODIFIER = Qt::MetaModifier;    // Control, which Qt calls Meta on macOS
#else
static const Qt::KeyboardModifier END_OF_INPUT_MODIFIER = Qt::ControlModifier;
#endif

// What the process running now does. On Windows, a C or C++ run first finds a compiler, a process per step: vswhere
// finds Visual Studio, vcvars64.bat gives MSVC's environment, and a probe checks that clang on PATH builds with it.
enum RunStage { RUN_IDLE, RUN_BUILD, RUN_PROGRAM, RUN_FIND_MSVC, RUN_LOAD_MSVC, RUN_PROBE_CLANG };

// A stream of output: the line it has so far, and the terminal colors it set.
struct RunStream {
    RunRecords records;
    TerminalDecoder decoder;
};

struct RunPane;

// The output, which takes typing after the program's output while the program can read it.
struct RunOutput : QTextBrowser {
    RunPane *pane = nullptr;

    void keyPressEvent(QKeyEvent *event) override;
    void inputMethodEvent(QInputMethodEvent *event) override;
    void insertFromMimeData(const QMimeData *source) override;
    void update_input();
};

struct RunPane : QDockWidget {
    RunOutput output;
    QProcess process;
    RunStage stage = RUN_IDLE;
    bool stopping = false;
    Language language = Language::Plain;
    QString name;                      // the tab's, which diagnostics about the file show instead of its path
    QString folder;                    // where the tools and the program run
    QString input_path;                // the file the tool reads: the tab's file, or a snapshot of its text
    QString executable;                // what the build makes
    QString launcher;                  // what runs the executable, when it doesn't run itself: java for Kotlin's jar
    QTemporaryDir *temporary = nullptr;
    QTemporaryFile *snapshot = nullptr;
    RunStream streams[2];              // standard output, then standard error
    DecodedOutput decoded;             // scratch for a line's text and colors
    QTextCursor preview;               // where the partial lines at the end start, which more output replaces
    QTextCursor input_start;           // where typing for the program starts, while it can read
    bool msvc = false;                 // the build uses MSVC's cl, on Windows, whose diagnostics read differently
    qint64 process_group = 0;
#ifdef Q_OS_WIN
    void *job = nullptr;
#endif

    explicit RunPane(QWidget *parent);
    ~RunPane() override;

    // What the process tells the pane.
    void process_started();
    void channel_ready(int channel);
    void process_finished(int exit_code, QProcess::ExitStatus status);
    void process_error(QProcess::ProcessError error);
};

//
// Tools.
//

static QString utf8_string(std::string_view bytes)
{
    return QString::fromUtf8(bytes.data(), qsizetype(bytes.size()));
}

// Where a tool is: on PATH, or for tools that install outside it, in the folders they install to, since apps started
// from the desktop on macOS and Linux don't get the shell's PATH. When the tool is in one of those folders, extra_path
// gets them all, so the tool's own subprocesses find their neighbors.
static QString tool_path(QStringView name, QString *extra_path)
{
    QString tool = name.toString();
    QString program = QStandardPaths::findExecutable(tool);
    if (!program.isEmpty() || !extra_path)
        return program;

    bool rust = name == u"rustc";
#ifdef Q_OS_WIN
    if (!rust)
        return QString();
    QString home = QDir::fromNativeSeparators(qEnvironmentVariable("USERPROFILE"));
    if (!QDir::isAbsolutePath(home))
        home = QDir::homePath();
#else
    QString home = QDir::homePath();
#endif

    QStringList folders;
    if (rust) {
        QString cargo = QDir::fromNativeSeparators(qEnvironmentVariable("CARGO_HOME"));
        if (QDir::isAbsolutePath(cargo))
            folders.append(QDir::cleanPath(cargo + QStringLiteral("/bin")));
        folders.append(home + QStringLiteral("/.cargo/bin"));
    }
#ifdef Q_OS_UNIX
    folders.append(home + QStringLiteral("/.local/bin"));
#ifdef Q_OS_MAC
    folders.append(QStringLiteral("/opt/homebrew/bin"));
#endif
    folders.append({QStringLiteral("/usr/local/bin"), QStringLiteral("/usr/bin"), QStringLiteral("/bin"),
                    QStringLiteral("/usr/sbin"), QStringLiteral("/sbin")});
#endif

    program = QStandardPaths::findExecutable(tool, folders);
    if (!program.isEmpty())
        *extra_path = QDir::toNativeSeparators(folders.join(QDir::listSeparator()));
    return program;
}

#ifdef Q_OS_WIN
// A C or C++ compiler and the environment it builds in.
struct WindowsCompiler {
    QString program;
    QProcessEnvironment environment = QProcessEnvironment(QProcessEnvironment::InheritFromParent);
    bool msvc = false;
};

// What the first C and C++ runs found, for the runs after them: MSVC's cl, and the compiler each language uses.
static WindowsCompiler msvc_compiler;
static WindowsCompiler windows_compilers[2];    // C, then C++

// Whether a file is in one of the folders a list like INCLUDE or LIB names.
static bool has_toolchain_file(const QString &folders, QStringView name)
{
    QString file;
    for (QStringView folder : QStringView(folders).tokenize(QLatin1Char(';'), Qt::SkipEmptyParts)) {
        if (folder.size() >= 2 && folder.startsWith(u'"') && folder.endsWith(u'"'))
            folder = folder.sliced(1, folder.size() - 2);
        if (folder.isEmpty())
            continue;

        file.assign(folder);
        if (!file.endsWith(u'/') && !file.endsWith(u'\\'))
            file += u'/';
        file += name;
        if (QFileInfo(file).isFile())
            return true;
    }

    return false;
}

// MSVC's cl in an environment, when the environment has the headers and libraries it needs.
static WindowsCompiler find_msvc(QProcessEnvironment environment)
{
    QString includes = environment.value(QStringLiteral("INCLUDE"));
    QString libraries = environment.value(QStringLiteral("LIB"));
    if (!has_toolchain_file(includes, u"stdio.h") || !has_toolchain_file(includes, u"vcruntime.h") ||
        !has_toolchain_file(libraries, u"kernel32.lib") || !has_toolchain_file(libraries, u"ucrt.lib"))
        return WindowsCompiler();

    QStringList paths = environment.value(QStringLiteral("PATH")).split(u';', Qt::SkipEmptyParts);
    if (paths.isEmpty())
        return WindowsCompiler();
    QString cl = QStandardPaths::findExecutable(QStringLiteral("cl.exe"), paths);
    if (cl.isEmpty() || !QFileInfo(QFileInfo(cl).dir().filePath(QStringLiteral("link.exe"))).isFile())
        return WindowsCompiler();

    // Diagnostics in English, which the diagnostic parser reads.
    environment.insert(QStringLiteral("VSLANG"), QStringLiteral("1033"));
    WindowsCompiler compiler;
    compiler.program = cl;
    compiler.environment = environment;
    compiler.msvc = true;
    return compiler;
}

// The environment that "set" printed in UTF-16, one NAME=value per line.
static QProcessEnvironment read_windows_environment(const QByteArray &bytes)
{
    QString variables = QStringDecoder(QStringDecoder::Utf16LE).decode(bytes);
    QProcessEnvironment environment;
    for (QStringView line : QStringView(variables).tokenize(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        if (line.endsWith(u'\r'))
            line.chop(1);
        qsizetype equals = line.indexOf(u'=');
        if (equals > 0)
            environment.insert(line.first(equals).toString(), line.sliced(equals + 1).toString());
    }

    return environment;
}
#endif

//
// The output.
//

static bool finding_compiler(const RunPane &pane)
{
    return pane.stage == RUN_FIND_MSVC || pane.stage == RUN_LOAD_MSVC || pane.stage == RUN_PROBE_CLANG;
}

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

static CompilerFormat compiler_format(Language language)
{
    switch (language) {
        case Language::Rust: return CompilerFormat::Rust;
        case Language::Go: return CompilerFormat::Go;
        case Language::Kotlin: return CompilerFormat::Kotlin;
        case Language::CSharp: return CompilerFormat::Parenthesized;
        case Language::FSharp: return CompilerFormat::Parenthesized;
        case Language::VisualBasic: return CompilerFormat::Parenthesized;
        default: return CompilerFormat::Standard;
    }
}

// Where output goes: before the program's input while it can read, else at the end.
static QTextCursor output_cursor(const RunPane &pane)
{
    QTextCursor cursor(pane.output.document());
    cursor.setPosition(pane.input_start.isNull() ? pane.output.document()->characterCount() - 1 : pane.input_start.position());
    return cursor;
}

static void remove_preview(RunPane &pane, QTextCursor &cursor)
{
    if (pane.preview.isNull())
        return;

    cursor.setPosition(pane.preview.position(), QTextCursor::KeepAnchor);
    pane.preview = QTextCursor();
    cursor.removeSelectedText();
}

// Keeps the partial lines shown, as a prompt is before what's typed after it, and moves the decoders past them.
static void commit_preview(RunPane &pane)
{
    if (pane.preview.isNull())
        return;

    pane.preview = QTextCursor();
    for (RunStream &stream : pane.streams) {
        std::string &partial = stream.records.partial;
        size_t count = CompleteUTF8Prefix(partial);
        if (count) {
            ClearDecodedOutput(pane.decoded);
            DecodeTerminal(stream.decoder, std::string_view(partial).substr(0, count), pane.decoded);
            partial.erase(0, count);
        }
    }
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

// Ends an edit of the output, and keeps the end in view when it was in view before.
static void finish_output(RunPane &pane, QTextCursor &cursor, bool follow)
{
    if (!pane.input_start.isNull())
        pane.input_start.setPosition(cursor.position());
    trim_output(pane, cursor);
    cursor.endEditBlock();
    pane.output.update_input();
    if (follow)
        pane.output.verticalScrollBar()->setValue(pane.output.verticalScrollBar()->maximum());
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

// A line from the pane itself, on a line of its own.
static void append_status(RunPane &pane, const QString &message, OutputTone tone)
{
    commit_preview(pane);
    QScrollBar *scroll = pane.output.verticalScrollBar();
    bool follow = scroll->value() == scroll->maximum();
    QTextCursor cursor = output_cursor(pane);
    QTextCharFormat format;
    format.setForeground(tone_color(tone, pane.output.palette()));
    cursor.beginEditBlock();
    if (cursor.positionInBlock() != 0)
        cursor.insertText(QStringLiteral("\n"), format);
    cursor.insertText(message + u'\n', format);
    finish_output(pane, cursor, follow);
}

// Sends what was typed, with a line break, or at the end of input without one, and then closes the program's input.
static void send_input(RunPane &pane, bool end_of_input)
{
    if (pane.input_start.isNull() || pane.process.state() != QProcess::Running)
        return;

    QTextCursor cursor = output_cursor(pane);
    cursor.movePosition(QTextCursor::End, QTextCursor::KeepAnchor);
    QString typed = cursor.selectedText();
    typed.replace(QChar::ParagraphSeparator, u'\n');
    typed.replace(QChar::LineSeparator, u'\n');
    QByteArray bytes = typed.toUtf8();
    if (!end_of_input)
        bytes += '\n';
    if (!bytes.isEmpty() && pane.process.write(bytes) != bytes.size())
        return;

    commit_preview(pane);
    cursor.clearSelection();
    cursor.beginEditBlock();
    if (!end_of_input)
        cursor.insertText(QStringLiteral("\n"), QTextCharFormat());
    finish_output(pane, cursor, true);
    pane.output.moveCursor(QTextCursor::End);
    if (end_of_input) {
        pane.process.closeWriteChannel();
        set_input_enabled(pane, false);
    }
}

// A link for a diagnostic's place: "retina-source:current" for the file that ran, which may be a snapshot of it, or
// the file's URL for another file, with "line:column:encoding" as the fragment. The window reads it.
static QUrl diagnostic_link(const RunPane &pane, const CompilerLocation &location, bool byte_columns, bool utf16_columns)
{
    if (!location.line || location.line > size_t(std::numeric_limits<int>::max()) ||
        location.column > size_t(std::numeric_limits<int>::max()) || location.path.starts_with('<'))
        return QUrl();

    QString file = utf8_string(location.path);
    QUrl url = file.startsWith(QLatin1StringView("file://")) ? QUrl(file) : QUrl();
    QString absolute = url.isLocalFile() ? url.toLocalFile() : QDir::fromNativeSeparators(file);
    absolute = QDir::cleanPath(QDir(pane.folder).absoluteFilePath(absolute));
    QFileInfo info(absolute);

    QUrl link;
    if (absolute.compare(QDir::cleanPath(pane.input_path), Qt::CaseSensitive) == 0 ||
        (pane.snapshot && info.canonicalFilePath() == QFileInfo(pane.input_path).canonicalFilePath())) {
        link.setScheme(QStringLiteral("retina-source"));
        link.setPath(QStringLiteral("current"));
    } else if (info.isFile()) {
        link = QUrl::fromLocalFile(absolute);
    } else {
        return QUrl();
    }

    link.setFragment(QStringLiteral("%1:%2:%3").arg(location.line).arg(location.column).arg(utf16_columns ? 2 : byte_columns ? 1 : 0));
    return link;
}

static void insert_text(QTextCursor &cursor, const QString &text, int first, int last, const QTextCharFormat &format)
{
    if (last > first)
        cursor.insertText(text.sliced(first, last - first), format);
}

// Shows a line of output in its terminal colors, or else the tone its words give it, with a link when it names a
// place in a file. A partial line, which more output may finish, shows in the colors its decoder has so far.
static void append_line(RunPane &pane, QTextCursor &cursor, std::string_view bytes, RunStream &stream, bool error_stream, bool partial)
{
    ClearDecodedOutput(pane.decoded);
    bool colored;
    if (partial) {
        TerminalDecoder decoder = stream.decoder;
        DecodeTerminal(decoder, bytes.substr(0, CompleteUTF8Prefix(bytes)), pane.decoded);
        colored = decoder.sawSGR;
    } else {
        DecodeTerminal(stream.decoder, bytes, pane.decoded);
        colored = stream.decoder.sawSGR;
    }
    std::string_view data = pane.decoded.text;

    // MSVC writes its diagnostics in the console's code page.
    bool msvc_diagnostic = pane.msvc && pane.stage == RUN_BUILD;
    QByteArray converted;
    if (msvc_diagnostic && !QByteArrayView(data.data(), qsizetype(data.size())).isValidUtf8()) {
        converted = QString::fromLocal8Bit(QByteArrayView(data.data(), qsizetype(data.size()))).toUtf8();
        data = std::string_view(converted.constData(), size_t(converted.size()));
    }
    if (data.empty())
        return;

    // A diagnostic or a traceback line gets a link to the place it names.
    OutputTone tone = colored ? OutputTone::Text : ConsoleTone(data, error_stream);
    QUrl link;
    CompilerLocation location = {};
    if (!partial) {
        bool runtime = error_stream && (pane.language == Language::Python || is_javascript_family(pane.language)) &&
                       ParseRuntimeLocation(data, pane.language == Language::Python, location);
        CompilerFormat format = msvc_diagnostic ? CompilerFormat::Parenthesized : compiler_format(pane.language);
        bool compiler = !runtime && ParseCompilerLocation(data, format, location);
        if (compiler && pane.language != Language::Rust)
            tone = location.tone;
        if (runtime || compiler) {
            bool byte_columns = format != CompilerFormat::Parenthesized &&
                                (is_c_family(pane.language) || pane.language == Language::Go || pane.language == Language::Odin ||
                                 pane.language == Language::Zig || pane.language == Language::Assembly);
            link = diagnostic_link(pane, location, byte_columns, runtime && is_javascript_family(pane.language));
        }
    }

    // A line about the file that ran names the tab instead of the path, which may be a snapshot's. Rust's lines link
    // from the path on.
    QString text = utf8_string(data);
    int link_start = 0;
    bool current_source = link.scheme() == QLatin1StringView("retina-source");
    if (link.isValid() && (current_source || pane.language == Language::Rust)) {
        QString path = utf8_string(location.path);
        qsizetype at = text.indexOf(path);
        if (at >= 0 && pane.language == Language::Rust)
            link_start = int(at);
        if (at >= 0 && current_source) {
            ShiftOutputColors(pane.decoded.spans, {uint32_t(at), uint32_t(path.size())}, uint32_t(pane.name.size()));
            text.replace(at, path.size(), pane.name);
        }
    }

    // The text in its colors, then the link over it.
    int line_start = cursor.position();
    int length = int(text.size()) - int(text.endsWith(u'\n'));
    QPalette palette = pane.output.palette();
    bool dark = palette.color(QPalette::Base).lightness() < 128;
    QTextCharFormat base;
    base.setForeground(tone_color(VisibleOutputTone(tone, colored), palette));
    int at = 0;
    for (const OutputColorSpan &span : pane.decoded.spans) {
        int first = std::min(length, int(span.range.location));
        int last = std::min(length, int(span.range.location + span.range.length));
        insert_text(cursor, text, at, first, base);
        QTextCharFormat format = base;
        if (span.colors.foreground != defaultOutputColor)
            format.setForeground(terminal_color(span.colors.foreground, dark));
        if (span.colors.background != defaultOutputColor)
            format.setBackground(terminal_color(span.colors.background, dark));
        insert_text(cursor, text, first, last, format);
        at = last;
    }
    insert_text(cursor, text, at, length, base);

    if (link.isValid() && link_start < length) {
        QTextCharFormat anchor;
        anchor.setAnchor(true);
        anchor.setAnchorHref(link.toString(QUrl::FullyEncoded));
        anchor.setFontUnderline(true);
        QTextCursor range = cursor;
        range.setPosition(line_start + link_start, QTextCursor::KeepAnchor);
        range.mergeCharFormat(anchor);
    }
    if (length < text.size())
        cursor.insertText(QStringLiteral("\n"), QTextCharFormat());
}

// Where ReadRunRecords puts each line it splits off.
struct OutputLines {
    RunPane *pane;
    QTextCursor *cursor;
    RunStream *stream;
    bool error_stream;
};

static bool append_output_line(void *context, std::string_view line)
{
    OutputLines &lines = *static_cast<OutputLines *>(context);
    append_line(*lines.pane, *lines.cursor, line, *lines.stream, lines.error_stream, false);
    return true;
}

// Reads what the process wrote on one channel. Whole lines go into the output, and each stream's partial line shows
// at the end until the rest of it comes. What the steps that find a compiler write isn't shown.
static void read_output(RunPane &pane, QProcess::ProcessChannel channel)
{
    if (finding_compiler(pane)) {
        if (channel == QProcess::StandardError)
            pane.process.readAllStandardError();
        else if (pane.stage == RUN_PROBE_CLANG)
            pane.process.readAllStandardOutput();
        return;
    }

    pane.process.setReadChannel(channel);
    if (!pane.process.bytesAvailable())
        return;

    QScrollBar *scroll = pane.output.verticalScrollBar();
    bool follow = scroll->value() == scroll->maximum();
    QTextCursor cursor = output_cursor(pane);
    cursor.beginEditBlock();
    remove_preview(pane, cursor);

    bool error_stream = channel == QProcess::StandardError;
    OutputLines lines = {&pane, &cursor, &pane.streams[error_stream], error_stream};
    char buffer[16 * 1024];
    for (;;) {
        qint64 count = pane.process.read(buffer, sizeof buffer);
        if (count <= 0)
            break;

        ReadRunRecords(lines.stream->records, std::string_view(buffer, size_t(count)), RUN_LINE_LIMIT, append_output_line, &lines);
        if (lines.stream->records.discarded) {
            lines.stream->records.discarded = false;
            cursor.insertText(QStringLiteral("[Overlong output line omitted]\n"), QTextCharFormat());
        }
        trim_output(pane, cursor);
    }

    if (!pane.streams[0].records.partial.empty() || !pane.streams[1].records.partial.empty()) {
        pane.preview = cursor;
        pane.preview.setKeepPositionOnInsert(true);
        for (int index = 0; index < 2; ++index)
            append_line(pane, cursor, pane.streams[index].records.partial, pane.streams[index], index == 1, true);
    }
    finish_output(pane, cursor, follow);
}

//
// Running.
//

static void launch(RunPane &pane, const QString &program, const QStringList &arguments, RunStage stage, const QString &folder)
{
    pane.stage = stage;
    pane.process.setWorkingDirectory(folder);
    pane.process.start(program, arguments);
}

// Kills the process and everything it started: closing the job object does it on Windows, and a signal to the
// process's session on Unix.
static void release_process_group(RunPane &pane)
{
#ifdef Q_OS_WIN
    if (pane.job) {
        CloseHandle(pane.job);
        pane.job = nullptr;
    }
#elif defined(Q_OS_UNIX)
    if (pane.process_group > 0)
        ::kill(-pid_t(pane.process_group), SIGKILL);
#endif
    pane.process_group = 0;
}

static void end_run(RunPane &pane)
{
    release_process_group(pane);
    pane.stage = RUN_IDLE;
    pane.stopping = false;
    delete pane.snapshot;
    pane.snapshot = nullptr;
    delete pane.temporary;
    pane.temporary = nullptr;
    pane.executable.clear();
    pane.launcher.clear();
    pane.msvc = false;
    pane.process.setProcessEnvironment(QProcessEnvironment(QProcessEnvironment::InheritFromParent));
    set_input_enabled(pane, false);
    pane.streams[0] = RunStream();
    pane.streams[1] = RunStream();
}

static void stop_run(RunPane &pane)
{
    if (pane.stage == RUN_IDLE)
        return;

    pane.stopping = true;
    set_input_enabled(pane, false);
    release_process_group(pane);
    pane.process.kill();
}

// Stops a run as the window closes, without waiting on the process's signals.
static void shut_down_run(RunPane &pane)
{
    if (pane.stage == RUN_IDLE)
        return;

    QObject::disconnect(&pane.process, nullptr, &pane, nullptr);
    stop_run(pane);
    pane.process.waitForFinished(1000);
    end_run(pane);
}

static bool make_temporary_folder(RunPane &pane)
{
    if (!pane.temporary)
        pane.temporary = new QTemporaryDir(QDir::temp().filePath(QStringLiteral("RetinaCode-XXXXXX")));
    if (pane.temporary->isValid())
        return true;

    append_status(pane, pane.temporary->errorString(), OutputTone::Error);
    return false;
}

// A snapshot of the tab's text for the tool to read. It goes next to the file, so the file's includes and imports
// still resolve, or else into the temporary folder: for text never saved, and for Go, whose tool skips files with
// names that start with a dot.
static bool make_snapshot(RunPane &pane, const QByteArray &bytes, const QString &suffix)
{
    QString name = QStringLiteral("retina-code-XXXXXX") + suffix;
    if (!pane.folder.isEmpty() && pane.language != Language::Go)
        pane.snapshot = new QTemporaryFile(QDir(pane.folder).filePath(u'.' + name));
    if (!pane.snapshot || !pane.snapshot->open()) {
        if (!make_temporary_folder(pane))
            return false;

        delete pane.snapshot;
        pane.snapshot = new QTemporaryFile(QDir(pane.temporary->path()).filePath(name));
        if (!pane.snapshot->open()) {
            append_status(pane, pane.snapshot->errorString(), OutputTone::Error);
            return false;
        }
    }

    if (pane.snapshot->write(bytes) != bytes.size() || !pane.snapshot->flush()) {
        append_status(pane, pane.snapshot->errorString(), OutputTone::Error);
        return false;
    }
    pane.input_path = pane.snapshot->fileName();
    pane.snapshot->close();
    if (pane.folder.isEmpty())
        pane.folder = QFileInfo(pane.input_path).absolutePath();
    return true;
}

static void build_c_family(RunPane &pane, const QString &program)
{
    bool cpp = pane.language == Language::Cpp || pane.language == Language::ObjectiveCpp;
    bool objective = pane.language == Language::ObjectiveC || pane.language == Language::ObjectiveCpp;
    QStringList arguments;
    if (pane.msvc) {
        QString object = QDir(pane.temporary->path()).filePath(QStringLiteral("program.obj"));
        arguments = {QStringLiteral("/nologo"), QStringLiteral("/utf-8"), QStringLiteral("/W4"), QStringLiteral("/FC"),
                     QStringLiteral("/diagnostics:column"), cpp ? QStringLiteral("/TP") : QStringLiteral("/TC"),
                     cpp ? QStringLiteral("/std:c++20") : QStringLiteral("/std:c17")};
        if (cpp)
            arguments.append(QStringLiteral("/EHsc"));
        arguments.append({QStringLiteral("/I") + QDir::toNativeSeparators(pane.folder),
                          QStringLiteral("/Fo") + QDir::toNativeSeparators(object),
                          QStringLiteral("/Fe") + QDir::toNativeSeparators(pane.executable), QDir::toNativeSeparators(pane.input_path)});
    } else {
        QString kind = objective ? (cpp ? QStringLiteral("objective-c++") : QStringLiteral("objective-c")) : (cpp ? QStringLiteral("c++") : QStringLiteral("c"));
        arguments = {QStringLiteral("-x"), kind, cpp ? QStringLiteral("-std=c++20") : QStringLiteral("-std=c17"), QStringLiteral("-Wall"),
                     QStringLiteral("-Wextra"), QStringLiteral("-fcolor-diagnostics"), QStringLiteral("-fno-caret-diagnostics"),
                     QStringLiteral("-iquote"), pane.folder};
#ifdef Q_OS_MAC
        if (objective)
            arguments.append({QStringLiteral("-framework"), QStringLiteral("Foundation")});
#endif
        arguments.append({pane.input_path, QStringLiteral("-o"), pane.executable, QStringLiteral("-g")});
    }
    append_status(pane, QStringLiteral("Building %1…").arg(pane.name), OutputTone::Text);
    launch(pane, program, arguments, RUN_BUILD, pane.folder);
}

#ifdef Q_OS_WIN
// Finds the C or C++ compiler, then builds with it. The first run of each looks for MSVC, in the environment the app
// started with or with vswhere and vcvars64.bat, and tries clang on PATH with MSVC's headers and libraries. Each of
// those steps is a process, and this runs again when it ends.
static void find_windows_compiler(RunPane &pane, bool step_worked)
{
    bool cpp = pane.language == Language::Cpp;
    WindowsCompiler &compiler = windows_compilers[cpp];

    // What the step that ended found.
    if (finding_compiler(pane)) {
        QByteArray output = pane.process.readAllStandardOutput();
        pane.process.readAllStandardError();
        pane.process.setNativeArguments(QString());
        release_process_group(pane);
        if (pane.stopping) {
            append_status(pane, QStringLiteral("Stopped."), OutputTone::Text);
            end_run(pane);
            return;
        }

        // vswhere names vcvars64.bat, and "set" after it prints MSVC's environment, in UTF-16 with /u so paths
        // outside the code page come through.
        if (pane.stage == RUN_FIND_MSVC && step_worked && msvc_compiler.program.isEmpty()) {
            QString script = QString::fromUtf8(output.trimmed());
            wchar_t system_folder[MAX_PATH];
            UINT length = GetSystemDirectoryW(system_folder, MAX_PATH);
            if (length && length < MAX_PATH && QFileInfo(script).isFile()) {
                QString cmd = QDir(QString::fromWCharArray(system_folder, length)).filePath(QStringLiteral("cmd.exe"));
                pane.process.setNativeArguments(QStringLiteral("/d /u /c call .\\vcvars64.bat >nul && set"));
                launch(pane, cmd, QStringList(), RUN_LOAD_MSVC, QFileInfo(script).absolutePath());
                return;
            }
        }
        if (pane.stage == RUN_LOAD_MSVC && step_worked && msvc_compiler.program.isEmpty())
            msvc_compiler = find_msvc(read_windows_environment(output));
        if (pane.stage == RUN_PROBE_CLANG && step_worked && compiler.program.isEmpty() &&
            QFileInfo(QDir(pane.temporary->path()).filePath(QStringLiteral("probe.exe"))).isFile()) {
            compiler.program = pane.process.program();
            compiler.environment = pane.process.processEnvironment();
            compiler.msvc = false;
        }
    }

    // MSVC, the first time.
    if (pane.stage == RUN_IDLE && compiler.program.isEmpty()) {
        if (msvc_compiler.program.isEmpty() && !qEnvironmentVariableIsEmpty("INCLUDE") && !qEnvironmentVariableIsEmpty("LIB"))
            msvc_compiler = find_msvc(QProcessEnvironment::systemEnvironment());
        QString installer = qEnvironmentVariable("ProgramFiles(x86)");
        QString vswhere = QDir(installer).filePath(QStringLiteral("Microsoft Visual Studio/Installer/vswhere.exe"));
        if (msvc_compiler.program.isEmpty() && !installer.isEmpty() && QFileInfo(vswhere).isFile()) {
            append_status(pane, QStringLiteral("Preparing C/C++ toolchain…"), OutputTone::Text);
            QStringList arguments = {QStringLiteral("-latest"), QStringLiteral("-products"), QStringLiteral("*"), QStringLiteral("-requires"),
                                     QStringLiteral("Microsoft.VisualStudio.Component.VC.Tools.x86.x64"), QStringLiteral("-utf8"),
                                     QStringLiteral("-find"), QStringLiteral("VC\\Auxiliary\\Build\\vcvars64.bat")};
            launch(pane, vswhere, arguments, RUN_FIND_MSVC, QFileInfo(vswhere).absolutePath());
            return;
        }
    }

    // clang, when it's on PATH. A compiler there can still be missing its headers, linker, or runtime, so it builds a
    // probe first.
    if (compiler.program.isEmpty() && pane.stage != RUN_PROBE_CLANG) {
        QString clang = tool_path(cpp ? u"clang++" : u"clang", nullptr);
        if (!clang.isEmpty()) {
            if (pane.stage == RUN_IDLE)
                append_status(pane, QStringLiteral("Preparing C/C++ toolchain…"), OutputTone::Text);
            pane.process.setProcessEnvironment(msvc_compiler.environment);
            QStringList arguments = {QStringLiteral("-x"), cpp ? QStringLiteral("c++") : QStringLiteral("c"),
                                     cpp ? QStringLiteral("-std=c++20") : QStringLiteral("-std=c17"),
                                     QStringLiteral("-"), QStringLiteral("-o"), QStringLiteral("probe.exe")};
            launch(pane, clang, arguments, RUN_PROBE_CLANG, pane.temporary->path());
            return;
        }
    }

    if (compiler.program.isEmpty())
        compiler = msvc_compiler;
    if (compiler.program.isEmpty()) {
        append_status(pane, QStringLiteral("Install Visual Studio Build Tools with “Desktop development with C++” and a Windows SDK, then press Ctrl+R again."),
                      OutputTone::Error);
        end_run(pane);
        return;
    }
    pane.msvc = compiler.msvc;
    pane.process.setProcessEnvironment(compiler.environment);
    build_c_family(pane, compiler.program);
}
#endif

// Runs a file with its language's tool: the tab's file, or a snapshot of the tab's text when there's a draft.
// Languages that compile build into a temporary folder first.
static void run_file(RunPane &pane, Language language, const QString &file, const QString &name, const QByteArray *draft)
{
    pane.preview = QTextCursor();
    pane.output.clear();
    pane.folder = file.isEmpty() ? QString() : QFileInfo(file).absolutePath();
    pane.input_path = file;
    pane.name = name;
    pane.language = language;
    RunTool spec = ToolForRun(language);
    if (!spec.tool) {
        append_status(pane, QStringLiteral("This file type cannot be run."), OutputTone::Error);
        return;
    }
    if (language == Language::VisualBasic) {
        append_status(pane, QStringLiteral("Visual Basic requires a .NET project."), OutputTone::Error);
        return;
    }

    QString extension = QFileInfo(file.isEmpty() ? name : file).suffix().toLower();
    bool kotlin_build = language == Language::Kotlin && extension != QStringLiteral("kts");
    bool build = is_c_family(language) || language == Language::Rust || language == Language::Go || language == Language::Swift ||
                 language == Language::Odin || language == Language::Assembly || kotlin_build;
#ifdef Q_OS_WIN
    bool find_compiler = language == Language::C || language == Language::Cpp;
#else
    bool find_compiler = false;
#endif

    // The tool. On Windows, Python is the py launcher, or python, but not the Microsoft Store's stand-ins for them in
    // WindowsApps, which open the Store.
    QString tool = QString::fromLatin1(spec.tool);
    QString program;
    QString extra_path;
    QStringList arguments;
    if (language == Language::CSharp && extension == QStringLiteral("csx"))
        tool = QStringLiteral("csi");
    else if (language == Language::TypeScript)
        program = tool_path(u"tsx", &extra_path);
#ifdef Q_OS_WIN
    if (language == Language::Python) {
        program = tool_path(u"py", nullptr);
        if (program.contains(QLatin1StringView("/Microsoft/WindowsApps/"), Qt::CaseInsensitive))
            program.clear();
        if (!program.isEmpty())
            arguments.append(QStringLiteral("-3"));
        else
            program = tool_path(u"python", nullptr);
    }
#endif
    if (program.isEmpty() && !find_compiler)
        program = tool_path(tool, &extra_path);
#ifdef Q_OS_WIN
    if (language == Language::Python && program.contains(QLatin1StringView("/Microsoft/WindowsApps/"), Qt::CaseInsensitive))
        program.clear();
    if (language == Language::Python)
        arguments.append({QStringLiteral("-X"), QStringLiteral("utf8")});
#endif
    if (program.isEmpty() && !find_compiler) {
        append_status(pane, QStringLiteral("%1 was not found. Install it or add it to PATH.").arg(tool), OutputTone::Error);
        return;
    }
    if (kotlin_build) {
        pane.launcher = tool_path(u"java", &extra_path);
        if (pane.launcher.isEmpty()) {
            append_status(pane, QStringLiteral("java was not found. Install it or add it to PATH."), OutputTone::Error);
            return;
        }
    }

    // The file the tool reads, and the folder a build goes to.
    if (draft) {
        QString suffix = extension.isEmpty() ? QString::fromLatin1(spec.suffix) : u'.' + extension;
        if (!make_snapshot(pane, *draft, suffix)) {
            end_run(pane);
            return;
        }
    }
    if (pane.input_path.isEmpty() || !QFileInfo(pane.input_path).isFile()) {
        append_status(pane, QStringLiteral("The source file could not be opened."), OutputTone::Error);
        end_run(pane);
        return;
    }
    if (build && !make_temporary_folder(pane)) {
        end_run(pane);
        return;
    }

    if (!extra_path.isEmpty()) {
        QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
        QString path = environment.value(QStringLiteral("PATH"));
        if (!path.isEmpty())
            path += QDir::listSeparator();
        environment.insert(QStringLiteral("PATH"), path + extra_path);
        pane.process.setProcessEnvironment(environment);
    }

    if (!build) {
        if (language == Language::CSharp && extension != QStringLiteral("csx"))
            arguments.append({QStringLiteral("run"), QStringLiteral("--file")});
        RunFlags flags = ScriptRunFlags(language);
        for (unsigned index = 0; index < flags.count; ++index)
            arguments.append(QString::fromLatin1(flags.values[index]));
        arguments.append(pane.input_path);
        append_status(pane, QStringLiteral("Running %1…").arg(name), OutputTone::Text);
        launch(pane, program, arguments, RUN_PROGRAM, pane.folder);
        return;
    }

#ifdef Q_OS_WIN
    QString executable_name = kotlin_build ? QStringLiteral("program.jar") : QStringLiteral("program.exe");
#else
    QString executable_name = kotlin_build ? QStringLiteral("program.jar") : QStringLiteral("program");
#endif
    pane.executable = QDir(pane.temporary->path()).filePath(executable_name);
    if (is_c_family(language)) {
#ifdef Q_OS_WIN
        if (find_compiler) {
            find_windows_compiler(pane, false);
            return;
        }
#endif
        build_c_family(pane, program);
        return;
    }

    if (language == Language::Rust) {
        arguments = {QStringLiteral("--edition=2021"), QStringLiteral("--crate-name"), QStringLiteral("editor_program"),
                     QStringLiteral("--color=always"), pane.input_path, QStringLiteral("-o"), pane.executable};
    } else if (language == Language::Go) {
        arguments = {QStringLiteral("build"), QStringLiteral("-o"), pane.executable, pane.input_path};
    } else if (language == Language::Odin) {
        arguments = {QStringLiteral("build"), pane.input_path, QStringLiteral("-file"), QStringLiteral("-out:") + pane.executable,
                     QStringLiteral("-error-pos-style:unix"), QStringLiteral("-terse-errors")};
    } else if (kotlin_build) {
        arguments = {pane.input_path, QStringLiteral("-include-runtime"), QStringLiteral("-d"), pane.executable};
    } else {
        arguments = {pane.input_path, QStringLiteral("-o"), pane.executable};
        if (language == Language::Assembly)
            arguments.append(QStringLiteral("-g"));
    }
    append_status(pane, QStringLiteral("Building %1…").arg(name), OutputTone::Text);
    launch(pane, program, arguments, RUN_BUILD, pane.folder);
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
    output.setAcceptDrops(false);
    output.setAcceptRichText(false);
    output.setOpenLinks(false);
    output.setOpenExternalLinks(false);
    output.setUndoRedoEnabled(false);
    output.setLineWrapMode(QTextEdit::NoWrap);
    QFont font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
#ifdef Q_OS_WIN
    font.setFamily(QStringLiteral("Consolas"));
    font.setHintingPreference(QFont::PreferVerticalHinting);
#endif
    font.setPixelSize(13);
    output.setFont(font);
    QObject::connect(&output, &QTextEdit::cursorPositionChanged, &output, &RunOutput::update_input);
    QObject::connect(&output, &QTextEdit::selectionChanged, &output, &RunOutput::update_input);

#ifdef Q_OS_UNIX
    QProcess::UnixProcessParameters parameters;
    parameters.flags = QProcess::UnixProcessFlag::CreateNewSession;
    process.setUnixProcessParameters(parameters);
#endif
    QObject::connect(&process, &QProcess::started, this, &RunPane::process_started);
    QObject::connect(&process, &QProcess::channelReadyRead, this, &RunPane::channel_ready);
    QObject::connect(&process, &QProcess::finished, this, &RunPane::process_finished);
    QObject::connect(&process, &QProcess::errorOccurred, this, &RunPane::process_error);
}

RunPane::~RunPane()
{
    shut_down_run(*this);
}

// The process goes into a group of its own, so stopping it stops what it started too: a job object on Windows that
// kills its processes when it closes, and on Unix the session it started.
void RunPane::process_started()
{
    process_group = process.processId();
#ifdef Q_OS_WIN
    HANDLE job_object = CreateJobObjectW(nullptr, nullptr);
    if (job_object) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        HANDLE handle = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, DWORD(process_group));
        if (handle && SetInformationJobObject(job_object, JobObjectExtendedLimitInformation, &limits, sizeof limits) &&
            AssignProcessToJobObject(job_object, handle))
            job = job_object;
        else
            CloseHandle(job_object);
        if (handle)
            CloseHandle(handle);
    }
#endif

    // A stop that came while the process was starting kills it with its group now.
    if (stopping) {
        stop_run(*this);
        return;
    }

    if (stage == RUN_PROBE_CLANG) {
        process.write(language == Language::Cpp ? "#include <cstdio>\nint main() { return std::puts(\"\") < 0; }\n"
                                                : "#include <stdio.h>\nint main(void) { return puts(\"\") < 0; }\n");
        process.closeWriteChannel();
    }
    if (stage == RUN_PROGRAM)
        set_input_enabled(*this, true);
}

void RunPane::channel_ready(int channel)
{
    read_output(*this, QProcess::ProcessChannel(channel));
}

void RunPane::process_finished(int exit_code, QProcess::ExitStatus status)
{
#ifdef Q_OS_WIN
    if (finding_compiler(*this)) {
        find_windows_compiler(*this, status == QProcess::NormalExit && exit_code == 0);
        return;
    }
#endif

    // The rest of the output, with each stream's partial line as a whole one.
    set_input_enabled(*this, false);
    read_output(*this, QProcess::StandardOutput);
    read_output(*this, QProcess::StandardError);
    QTextCursor cursor = output_cursor(*this);
    cursor.beginEditBlock();
    remove_preview(*this, cursor);
    for (int index = 0; index < 2; ++index) {
        append_line(*this, cursor, streams[index].records.partial, streams[index], index == 1, false);
        streams[index] = RunStream();
    }
    finish_output(*this, cursor, false);
    release_process_group(*this);

    // A build that worked runs what it built.
    if (!stopping && status == QProcess::NormalExit && exit_code == 0 && stage == RUN_BUILD) {
        append_status(*this, QStringLiteral("Running…"), OutputTone::Text);
        if (launcher.isEmpty())
            launch(*this, executable, QStringList(), RUN_PROGRAM, folder);
        else
            launch(*this, launcher, {QStringLiteral("-jar"), executable}, RUN_PROGRAM, folder);
        return;
    }

    if (stopping)
        append_status(*this, QStringLiteral("Stopped."), OutputTone::Text);
    else if (status == QProcess::CrashExit)
        append_status(*this, QStringLiteral("The process crashed."), OutputTone::Error);
    else if (stage == RUN_BUILD && exit_code != 0)
        append_status(*this, QStringLiteral("Build failed with exit code %1.").arg(exit_code), OutputTone::Error);
    else
        append_status(*this, QStringLiteral("Exited with code %1.").arg(exit_code), exit_code ? OutputTone::Error : OutputTone::Text);
    end_run(*this);
}

// A process that couldn't start ends the run. Failures to read or write are reported, and the program's input
// closes when it can't be written.
void RunPane::process_error(QProcess::ProcessError error)
{
    if (error == QProcess::FailedToStart) {
#ifdef Q_OS_WIN
        if (finding_compiler(*this)) {
            find_windows_compiler(*this, false);
            return;
        }
#endif
        if (stopping)
            append_status(*this, QStringLiteral("Stopped."), OutputTone::Text);
        else
            append_status(*this, process.errorString(), OutputTone::Error);
        end_run(*this);
        return;
    }

    if (stopping || finding_compiler(*this) || (error != QProcess::ReadError && error != QProcess::WriteError))
        return;
    if (error == QProcess::WriteError)
        set_input_enabled(*this, false);
    append_status(*this, process.errorString(), OutputTone::Error);
}

// The output is read-only except at the program's input. Making it editable drops the flag that lets links be
// clicked, so it goes back on, and typing at the input's start takes no color from the output before it.
void RunOutput::update_input()
{
    QTextCursor cursor = textCursor();
    bool read_only = pane->input_start.isNull() || cursor.selectionStart() < pane->input_start.position();
    if (read_only != isReadOnly()) {
        setReadOnly(read_only);
        if (!read_only)
            setTextInteractionFlags(textInteractionFlags() | Qt::LinksAccessibleByMouse);
    }
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
        QTextBrowser::keyPressEvent(event);
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
    QTextEdit::keyPressEvent(event);
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
        QTextEdit::inputMethodEvent(event);
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
