#include "RunPane.h"

#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QMimeData>
#include <QScrollBar>
#include <QStandardPaths>
#include <QStringDecoder>
#include <QTextBlock>

#include <algorithm>
#include <limits>
#include <utility>

#if defined(Q_OS_WIN)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#elif defined(Q_OS_UNIX)
#include <csignal>
#include <unistd.h>
#endif

#include "Color.h"
#undef rgb
#undef rgba

namespace {

constexpr size_t recordLimit = 64 * 1024;
constexpr int inputLimit = 16 * 1024;
#ifdef Q_OS_MAC
constexpr auto eofModifier = Qt::MetaModifier;
#else
constexpr auto eofModifier = Qt::ControlModifier;
#endif

QString decodeText(std::string_view bytes)
{
    return QString::fromUtf8(bytes.data(), qsizetype(bytes.size()));
}

QColor terminalColor(uint32_t color, bool dark)
{
    const auto ink = RunTerminalColor(color, dark);
    return {ColorRed(ink), ColorGreen(ink), ColorBlue(ink), ColorAlpha(ink)};
}

CompilerFormat compilerFormat(Language language)
{
    switch (language) {
    case Language::Rust: return CompilerFormat::Rust;
    case Language::Go: return CompilerFormat::Go;
    case Language::Kotlin: return CompilerFormat::Kotlin;
    case Language::CSharp: case Language::FSharp: case Language::VisualBasic: return CompilerFormat::Parenthesized;
    default: return CompilerFormat::Standard;
    }
}

QColor toneColor(OutputTone tone, const QPalette &palette)
{
    const bool dark = palette.color(QPalette::Base).lightness() < 128;
    if (tone == OutputTone::Error)
        return dark ? QColor(255, 128, 123) : QColor(166, 31, 36);
    if (tone == OutputTone::Warning)
        return dark ? QColor(240, 193, 95) : QColor(139, 88, 0);
    return palette.color(QPalette::Text);
}

QString toolPath(QStringView name, QString *additionalPath = nullptr)
{
    const auto tool = name.toString();
    auto program = QStandardPaths::findExecutable(tool);
    if (!program.isEmpty() || !additionalPath)
        return program;

    const bool rust = name == u"rustc";
#ifdef Q_OS_WIN
    if (!rust)
        return {};
    auto home = QDir::fromNativeSeparators(qEnvironmentVariable("USERPROFILE"));
    if (!QDir::isAbsolutePath(home))
        home = QDir::homePath();
#else
    const auto home = QDir::homePath();
#endif
    QStringList directories;
    directories.reserve(9);
    if (rust) {
        const auto cargo = QDir::fromNativeSeparators(qEnvironmentVariable("CARGO_HOME"));
        if (QDir::isAbsolutePath(cargo))
            directories.append(QDir::cleanPath(cargo + QStringLiteral("/bin")));
        directories.append(home + QStringLiteral("/.cargo/bin"));
    }
#ifdef Q_OS_UNIX
    directories.append(home + QStringLiteral("/.local/bin"));
#ifdef Q_OS_MAC
    directories.append(QStringLiteral("/opt/homebrew/bin"));
#endif
    directories.append({QStringLiteral("/usr/local/bin"), QStringLiteral("/usr/bin"), QStringLiteral("/bin"),
                        QStringLiteral("/usr/sbin"), QStringLiteral("/sbin")});
#endif
    program = QStandardPaths::findExecutable(tool, directories);
    if (!program.isEmpty())
        *additionalPath = QDir::toNativeSeparators(directories.join(QDir::listSeparator()));
    return program;
}

#ifdef Q_OS_WIN
struct WindowsCompiler {
    QString program;
    QProcessEnvironment environment{QProcessEnvironment::InheritFromParent};
    bool msvc = false;
};

struct WindowsToolchain {
    WindowsCompiler msvc;
    WindowsCompiler compilers[2];
};

WindowsToolchain &windowsToolchain()
{
    static WindowsToolchain toolchain;
    return toolchain;
}

bool hasToolchainFile(const QString &paths, QStringView name)
{
    QString file;
    for (auto path : QStringView(paths).tokenize(QLatin1Char(';'), Qt::SkipEmptyParts)) {
        if (path.size() >= 2 && path.startsWith(QLatin1Char('"')) && path.endsWith(QLatin1Char('"')))
            path = path.sliced(1, path.size() - 2);
        if (path.isEmpty())
            continue;
        file.assign(path);
        if (!file.endsWith(QLatin1Char('/')) && !file.endsWith(QLatin1Char('\\')))
            file += QLatin1Char('/');
        file += name;
        if (QFileInfo(file).isFile())
            return true;
    }
    return false;
}

WindowsCompiler msvcCompiler(QProcessEnvironment environment)
{
    const auto includes = environment.value(QStringLiteral("INCLUDE"));
    const auto libraries = environment.value(QStringLiteral("LIB"));
    if (!hasToolchainFile(includes, u"stdio.h") || !hasToolchainFile(includes, u"vcruntime.h") ||
        !hasToolchainFile(libraries, u"kernel32.lib") || !hasToolchainFile(libraries, u"ucrt.lib"))
        return {};
    const auto paths = environment.value(QStringLiteral("PATH")).split(QLatin1Char(';'), Qt::SkipEmptyParts);
    if (paths.isEmpty())
        return {};
    const auto cl = QStandardPaths::findExecutable(QStringLiteral("cl.exe"), paths);
    if (cl.isEmpty() || !QFileInfo(QFileInfo(cl).dir().filePath(QStringLiteral("link.exe"))).isFile())
        return {};
    environment.insert(QStringLiteral("VSLANG"), QStringLiteral("1033"));
    return {cl, std::move(environment), true};
}

QProcessEnvironment readWindowsEnvironment(const QByteArray &bytes)
{
    const QString variables = QStringDecoder(QStringDecoder::Utf16LE).decode(bytes);
    QProcessEnvironment environment;
    for (auto line : QStringView(variables).tokenize(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        if (line.endsWith(QLatin1Char('\r')))
            line.chop(1);
        const auto equals = line.indexOf(QLatin1Char('='));
        if (equals > 0)
            environment.insert(line.first(equals).toString(), line.sliced(equals + 1).toString());
    }
    return environment;
}
#endif

} // namespace

RunPane::Output::Output(RunPane &pane) : pane_(pane)
{
    setAcceptDrops(false);
    setAcceptRichText(false);
    connect(this, &QTextEdit::cursorPositionChanged, this, &Output::updateInput);
    connect(this, &QTextEdit::selectionChanged, this, &Output::updateInput);
}

void RunPane::Output::updateInput()
{
    const auto cursor = textCursor();
    const bool readOnly = pane_.inputStart_.isNull() || cursor.selectionStart() < pane_.inputStart_.position();
    if (readOnly != isReadOnly()) {
        setReadOnly(readOnly);
        if (!readOnly)
            setTextInteractionFlags(textInteractionFlags() | Qt::LinksAccessibleByMouse);
    }
    if (!readOnly && !cursor.hasSelection() && cursor.position() == pane_.inputStart_.position())
        setCurrentCharFormat(QTextCharFormat{});
}

void RunPane::Output::moveToInput()
{
    if (textCursor().selectionStart() < pane_.inputStart_.position())
        moveCursor(QTextCursor::End);
}

bool RunPane::Output::inputFits(int added, int removed) const
{
    return added <= inputLimit - (document()->characterCount() - 1 - pane_.inputStart_.position() - removed);
}

void RunPane::Output::keyPressEvent(QKeyEvent *event)
{
    if (pane_.inputStart_.isNull()) {
        QTextBrowser::keyPressEvent(event);
        return;
    }

    const bool eof = event->key() == Qt::Key_D && event->modifiers() == eofModifier;
    if (eof || event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) {
        pane_.sendInput(eof);
        event->accept();
        return;
    }

    auto cursor = textCursor();
    const int first = pane_.inputStart_.position();
    if (!cursor.hasSelection() && cursor.position() >= first &&
        event->matches(QKeySequence::DeleteStartOfWord)) {
        const int end = cursor.position();
        cursor.movePosition(QTextCursor::PreviousWord);
        cursor.setPosition(std::max(first, cursor.position()));
        cursor.setPosition(end, QTextCursor::KeepAnchor);
        cursor.removeSelectedText();
        setTextCursor(cursor);
        event->accept();
        return;
    }
    if (!cursor.hasSelection() && cursor.position() == first &&
        (event->key() == Qt::Key_Backspace || event->matches(QKeySequence::Backspace))) {
        event->accept();
        return;
    }

    const auto text = event->text();
    const auto modifiers = event->modifiers();
    const bool command = (modifiers & (Qt::ControlModifier | Qt::MetaModifier)) &&
                         !(modifiers & (Qt::AltModifier | Qt::GroupSwitchModifier));
    if (!command && !text.isEmpty() && (text.front().unicode() >= ' ' || text.front() == u'\t')) {
        moveToInput();
        cursor = textCursor();
        if (!inputFits(int(text.size()), cursor.selectionEnd() - cursor.selectionStart())) {
            event->accept();
            return;
        }
    }
    QTextEdit::keyPressEvent(event);
}

void RunPane::Output::inputMethodEvent(QInputMethodEvent *event)
{
    if (pane_.inputStart_.isNull())
        return;
    moveToInput();
    const auto cursor = textCursor();
    const int selection = cursor.selectionEnd() - cursor.selectionStart();
    const int start = cursor.selectionStart() + event->replacementStart();
    if (start >= pane_.inputStart_.position() &&
        start + event->replacementLength() < document()->characterCount() - selection &&
        inputFits(int(event->commitString().size()), selection + event->replacementLength()))
        QTextEdit::inputMethodEvent(event);
}

void RunPane::Output::insertFromMimeData(const QMimeData *source)
{
    if (pane_.inputStart_.isNull() || !source->hasText())
        return;
    moveToInput();
    auto cursor = textCursor();
    const auto text = source->text();
    if (inputFits(int(text.size()), cursor.selectionEnd() - cursor.selectionStart())) {
        cursor.insertText(text, QTextCharFormat{});
        setTextCursor(cursor);
    }
}

RunPane::RunPane(QWidget *parent) : QDockWidget(QStringLiteral("Output"), parent), output_(*this)
{
    setObjectName(QStringLiteral("RunOutput"));
    setAllowedAreas(Qt::BottomDockWidgetArea);
    setFeatures(QDockWidget::DockWidgetClosable);
    setWidget(&output_);

    output_.setObjectName(QStringLiteral("RunLog"));
    output_.setOpenLinks(false);
    output_.setOpenExternalLinks(false);
    output_.setUndoRedoEnabled(false);
    output_.setLineWrapMode(QTextEdit::NoWrap);
    QFont font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
#ifdef Q_OS_WIN
    font.setFamily(QStringLiteral("Consolas"));
    font.setHintingPreference(QFont::PreferVerticalHinting);
#endif
    font.setPixelSize(13);
    output_.setFont(font);

#ifdef Q_OS_UNIX
    QProcess::UnixProcessParameters parameters;
    parameters.flags = QProcess::UnixProcessFlag::CreateNewSession;
    process_.setUnixProcessParameters(parameters);
#endif
    connect(&process_, &QProcess::started, this, &RunPane::processStarted);
    connect(&process_, &QProcess::readyReadStandardOutput, this, [this] { readOutput(QProcess::StandardOutput); });
    connect(&process_, &QProcess::readyReadStandardError, this, [this] { readOutput(QProcess::StandardError); });
    connect(&process_, &QProcess::finished, this, &RunPane::finished);
    connect(&process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
#ifdef Q_OS_WIN
            if (preparingCompiler()) {
                compilerSetupFinished(false);
                return;
            }
#endif
            appendStatus(stopping_ ? QStringLiteral("Stopped.") : process_.errorString(),
                         stopping_ ? OutputTone::Text : OutputTone::Error);
            endRun();
        } else if (!stopping_ && (error == QProcess::ReadError || error == QProcess::WriteError)) {
#ifdef Q_OS_WIN
            if (preparingCompiler())
                return;
#endif
            if (error == QProcess::WriteError)
                setInputEnabled(false);
            appendStatus(process_.errorString(), OutputTone::Error);
        }
    });
}

RunPane::~RunPane()
{
    shutdown();
}

bool RunPane::makeTemporaryDirectory()
{
    if (!temporary_)
        temporary_.emplace(QDir::temp().filePath(QStringLiteral("RetinaCode-XXXXXX")));
    if (temporary_->isValid())
        return true;
    appendStatus(temporary_->errorString(), OutputTone::Error);
    return false;
}

bool RunPane::makeSnapshot(const QByteArray &bytes, QStringView suffix)
{
    const auto filename = QStringLiteral("retina-code-XXXXXX%1").arg(suffix);
    if (!directory_.isEmpty() && language_ != Language::Go)
        snapshot_.emplace(QDir(directory_).filePath(QLatin1Char('.') + filename));
    if (!snapshot_ || !snapshot_->open()) {
        if (!makeTemporaryDirectory())
            return false;
        snapshot_.emplace(QDir(temporary_->path()).filePath(filename));
        if (!snapshot_->open()) {
            appendStatus(snapshot_->errorString(), OutputTone::Error);
            return false;
        }
    }
    if (snapshot_->write(bytes) != bytes.size() || !snapshot_->flush()) {
        appendStatus(snapshot_->errorString(), OutputTone::Error);
        return false;
    }
    inputPath_ = snapshot_->fileName();
    snapshot_->close();
    if (directory_.isEmpty())
        directory_ = QFileInfo(inputPath_).absolutePath();
    return true;
}

void RunPane::run(Language language, const QString &file, const QString &name, const QByteArray *draft)
{
    if (isRunning()) {
        stop();
        return;
    }
    preview_ = QTextCursor();
    output_.clear();
    directory_ = file.isEmpty() ? QString{} : QFileInfo(file).absolutePath();
    inputPath_ = file;
    name_ = name;
    language_ = language;
    const auto spec = ToolForRun(language);
    if (!spec.tool) {
        appendStatus(QStringLiteral("This file type cannot be run."), OutputTone::Error);
        return;
    }
    if (language == Language::VisualBasic) {
        appendStatus(QStringLiteral("Visual Basic requires a .NET project."), OutputTone::Error);
        return;
    }

    const auto extension = QFileInfo(file.isEmpty() ? name : file).suffix().toLower();
    const bool kotlinBuild = language == Language::Kotlin && extension != QStringLiteral("kts");
    const bool build = CFamily(language) || language == Language::Rust || language == Language::Go ||
        language == Language::Swift || language == Language::Odin || language == Language::Assembly || kotlinBuild;
    QString tool = QString::fromLatin1(spec.tool);
    QString program;
    QString additionalPath;
    QStringList args;
#ifdef Q_OS_WIN
    const bool prepareCompiler = language == Language::C || language == Language::Cpp;
#else
    constexpr bool prepareCompiler = false;
#endif
    if (language == Language::CSharp && extension == QStringLiteral("csx")) {
        tool = QStringLiteral("csi");
    } else if (language == Language::TypeScript) {
        program = toolPath(u"tsx", &additionalPath);
    }
#ifdef Q_OS_WIN
    if (language == Language::Python) {
        program = toolPath(u"py");
        if (program.contains(QLatin1StringView("/Microsoft/WindowsApps/"), Qt::CaseInsensitive))
            program.clear();
        if (!program.isEmpty())
            args.append(QStringLiteral("-3"));
        else
            program = toolPath(u"python");
    }
#endif
    if (program.isEmpty() && !prepareCompiler)
        program = toolPath(tool, &additionalPath);
#ifdef Q_OS_WIN
    if (language == Language::Python && program.contains(QLatin1StringView("/Microsoft/WindowsApps/"), Qt::CaseInsensitive))
        program.clear();
#endif
    if (program.isEmpty() && !prepareCompiler) {
        appendStatus(QStringLiteral("%1 was not found. Install it or add it to PATH.").arg(tool), OutputTone::Error);
        return;
    }
#ifdef Q_OS_WIN
    if (language == Language::Python)
        args.append({QStringLiteral("-X"), QStringLiteral("utf8")});
#endif
    if (kotlinBuild) {
        launchTool_ = toolPath(u"java", &additionalPath);
        if (launchTool_.isEmpty()) {
            appendStatus(QStringLiteral("java was not found. Install it or add it to PATH."), OutputTone::Error);
            return;
        }
    }

    if (draft) {
        const QString suffix = extension.isEmpty() ? QString::fromLatin1(spec.suffix)
                                                  : QLatin1Char('.') + extension;
        if (!makeSnapshot(*draft, suffix)) {
            endRun();
            return;
        }
    }
    if (inputPath_.isEmpty() || !QFileInfo(inputPath_).isFile()) {
        appendStatus(QStringLiteral("The source file could not be opened."), OutputTone::Error);
        endRun();
        return;
    }
    if (build && !makeTemporaryDirectory()) {
        endRun();
        return;
    }

    if (!additionalPath.isEmpty()) {
        auto environment = QProcessEnvironment::systemEnvironment();
        const auto pathKey = QStringLiteral("PATH");
        auto path = environment.value(pathKey);
        if (!path.isEmpty())
            path += QDir::listSeparator();
        path += additionalPath;
        environment.insert(pathKey, path);
        process_.setProcessEnvironment(environment);
    }

    if (build) {
        executable_ = QDir(temporary_->path()).filePath(kotlinBuild ? QStringLiteral("program.jar")
#ifdef Q_OS_WIN
            : QStringLiteral("program.exe"));
#else
            : QStringLiteral("program"));
#endif
        if (CFamily(language)) {
#ifdef Q_OS_WIN
            if (prepareCompiler) {
                prepareWindowsCompiler();
                return;
            }
#endif
            buildCFamily(program);
            return;
        }
        if (language == Language::Rust) {
            args = {QStringLiteral("--edition=2021"), QStringLiteral("--crate-name"),
                    QStringLiteral("editor_program"), QStringLiteral("--color=always")};
        } else if (language == Language::Go) {
            args = {QStringLiteral("build"), QStringLiteral("-o"), executable_, inputPath_};
        } else if (language == Language::Odin) {
            args = {QStringLiteral("build"), inputPath_, QStringLiteral("-file"), QStringLiteral("-out:") + executable_,
                    QStringLiteral("-error-pos-style:unix"), QStringLiteral("-terse-errors")};
        } else if (kotlinBuild) {
            args = {inputPath_, QStringLiteral("-include-runtime"), QStringLiteral("-d"), executable_};
        }
        if (!kotlinBuild && language != Language::Go && language != Language::Odin)
            args.append({inputPath_, QStringLiteral("-o"), executable_});
        if (language == Language::Assembly)
            args.append(QStringLiteral("-g"));
    } else {
        if (language == Language::CSharp && extension != QStringLiteral("csx"))
            args.append({QStringLiteral("run"), QStringLiteral("--file")});
        const auto flags = ScriptRunFlags(language);
        for (unsigned i = 0; i < flags.count; ++i)
            args.append(QString::fromLatin1(flags.values[i]));
        args.append(inputPath_);
    }

    appendStatus((build ? QStringLiteral("Building %1…") : QStringLiteral("Running %1…")).arg(name));
    launch(program, args, build ? Stage::Build : Stage::Run);
}

void RunPane::buildCFamily(const QString &program)
{
    const bool cpp = language_ == Language::Cpp || language_ == Language::ObjectiveCpp;
    const bool objective = language_ == Language::ObjectiveC || language_ == Language::ObjectiveCpp;
    QStringList args;
#ifdef Q_OS_WIN
    if (msvc_) {
        const auto object = QDir(temporary_->path()).filePath(QStringLiteral("program.obj"));
        args = {QStringLiteral("/nologo"), QStringLiteral("/utf-8"), QStringLiteral("/W4"), QStringLiteral("/FC"),
                QStringLiteral("/diagnostics:column"), cpp ? QStringLiteral("/TP") : QStringLiteral("/TC"),
                cpp ? QStringLiteral("/std:c++20") : QStringLiteral("/std:c17")};
        if (cpp)
            args.append(QStringLiteral("/EHsc"));
        args.append({QStringLiteral("/I") + QDir::toNativeSeparators(directory_),
                     QStringLiteral("/Fo") + QDir::toNativeSeparators(object),
                     QStringLiteral("/Fe") + QDir::toNativeSeparators(executable_), QDir::toNativeSeparators(inputPath_)});
    } else
#endif
    {
        args = {QStringLiteral("-x"), objective ? (cpp ? QStringLiteral("objective-c++") : QStringLiteral("objective-c"))
                                                 : (cpp ? QStringLiteral("c++") : QStringLiteral("c")),
                cpp ? QStringLiteral("-std=c++20") : QStringLiteral("-std=c17"), QStringLiteral("-Wall"),
                QStringLiteral("-Wextra"), QStringLiteral("-fcolor-diagnostics"),
                QStringLiteral("-fno-caret-diagnostics"), QStringLiteral("-iquote"), directory_};
#ifdef Q_OS_MAC
        if (objective)
            args.append({QStringLiteral("-framework"), QStringLiteral("Foundation")});
#endif
        args.append({inputPath_, QStringLiteral("-o"), executable_, QStringLiteral("-g")});
    }
    appendStatus(QStringLiteral("Building %1…").arg(name_));
    launch(program, args, Stage::Build);
}

void RunPane::launch(const QString &program, const QStringList &arguments, Stage stage, const QString &workingDirectory)
{
    stage_ = stage;
    process_.setWorkingDirectory(workingDirectory.isEmpty() ? directory_ : workingDirectory);
    process_.start(program, arguments);
}

#ifdef Q_OS_WIN
bool RunPane::preparingCompiler() const
{
    return stage_ == Stage::FindMsvc || stage_ == Stage::LoadMsvc || stage_ == Stage::ProbeClang;
}

void RunPane::prepareWindowsCompiler()
{
    auto &toolchain = windowsToolchain();
    if (!toolchain.compilers[language_ == Language::Cpp].program.isEmpty()) {
        selectWindowsCompiler();
        return;
    }

    if (toolchain.msvc.program.isEmpty() && !qEnvironmentVariableIsEmpty("INCLUDE") &&
        !qEnvironmentVariableIsEmpty("LIB"))
        toolchain.msvc = msvcCompiler(QProcessEnvironment::systemEnvironment());
    if (toolchain.msvc.program.isEmpty()) {
        const auto root = qEnvironmentVariable("ProgramFiles(x86)");
        const auto vswhere = QDir(root).filePath(QStringLiteral("Microsoft Visual Studio/Installer/vswhere.exe"));
        if (!root.isEmpty() && QFileInfo(vswhere).isFile()) {
            appendStatus(QStringLiteral("Preparing C/C++ toolchain…"));
            launch(vswhere, {QStringLiteral("-latest"), QStringLiteral("-products"), QStringLiteral("*"),
                             QStringLiteral("-requires"), QStringLiteral("Microsoft.VisualStudio.Component.VC.Tools.x86.x64"),
                             QStringLiteral("-utf8"), QStringLiteral("-find"),
                             QStringLiteral("VC\\Auxiliary\\Build\\vcvars64.bat")},
                   Stage::FindMsvc, QFileInfo(vswhere).absolutePath());
            return;
        }
    }
    selectWindowsCompiler();
}

void RunPane::selectWindowsCompiler()
{
    auto &toolchain = windowsToolchain();
    const bool cpp = language_ == Language::Cpp;
    auto &compiler = toolchain.compilers[cpp];
    if (compiler.program.isEmpty() && stage_ != Stage::ProbeClang) {
        const auto clang = toolPath(cpp ? u"clang++" : u"clang");
        if (!clang.isEmpty()) {
            // A compiler on PATH can still be missing its headers, linker, or runtime.
            if (stage_ == Stage::Idle)
                appendStatus(QStringLiteral("Preparing C/C++ toolchain…"));
            process_.setProcessEnvironment(toolchain.msvc.environment);
            launch(clang, {QStringLiteral("-x"), cpp ? QStringLiteral("c++") : QStringLiteral("c"),
                           cpp ? QStringLiteral("-std=c++20") : QStringLiteral("-std=c17"),
                           QStringLiteral("-"), QStringLiteral("-o"), QStringLiteral("probe.exe")},
                   Stage::ProbeClang, temporary_->path());
            return;
        }
    }
    if (compiler.program.isEmpty())
        compiler = toolchain.msvc;
    if (compiler.program.isEmpty()) {
        appendStatus(QStringLiteral("Install Visual Studio Build Tools with “Desktop development with C++” and a Windows SDK, then press Ctrl+R again."),
                     OutputTone::Error);
        endRun();
        return;
    }
    msvc_ = compiler.msvc;
    process_.setProcessEnvironment(compiler.environment);
    buildCFamily(compiler.program);
}

void RunPane::compilerSetupFinished(bool success)
{
    const auto output = process_.readAllStandardOutput();
    process_.readAllStandardError();
    process_.setNativeArguments({});
    releaseProcessGroup();
    if (stopping_) {
        appendStatus(QStringLiteral("Stopped."));
        endRun();
        return;
    }

    auto &toolchain = windowsToolchain();
    if (stage_ == Stage::FindMsvc && success && toolchain.msvc.program.isEmpty()) {
        const auto script = QString::fromUtf8(output.trimmed());
        wchar_t systemDirectory[MAX_PATH];
        const auto length = GetSystemDirectoryW(systemDirectory, MAX_PATH);
        if (length && length < MAX_PATH && QFileInfo(script).isFile()) {
            const auto cmd = QDir(QString::fromWCharArray(systemDirectory, length)).filePath(QStringLiteral("cmd.exe"));
            // /u writes the environment as UTF-16, including paths outside the active code page.
            process_.setNativeArguments(QStringLiteral("/d /u /c call .\\vcvars64.bat >nul && set"));
            launch(cmd, {}, Stage::LoadMsvc, QFileInfo(script).absolutePath());
            return;
        }
    } else if (stage_ == Stage::LoadMsvc && success && toolchain.msvc.program.isEmpty()) {
        toolchain.msvc = msvcCompiler(readWindowsEnvironment(output));
    } else if (stage_ == Stage::ProbeClang) {
        auto &compiler = toolchain.compilers[language_ == Language::Cpp];
        if (success && compiler.program.isEmpty() &&
            QFileInfo(QDir(temporary_->path()).filePath(QStringLiteral("probe.exe"))).isFile())
            compiler = {process_.program(), process_.processEnvironment(), false};
    }
    selectWindowsCompiler();
}
#endif

void RunPane::processStarted()
{
    processGroup_ = process_.processId();
#ifdef Q_OS_WIN
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        HANDLE process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, DWORD(processGroup_));
        if (process && SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) &&
            AssignProcessToJobObject(job, process))
            job_ = job;
        else
            CloseHandle(job);
        if (process)
            CloseHandle(process);
    }
#endif
    if (stopping_)
        stop();
    else {
#ifdef Q_OS_WIN
        if (stage_ == Stage::ProbeClang) {
            process_.write(language_ == Language::Cpp
                ? "#include <cstdio>\nint main() { return std::puts(\"\") < 0; }\n"
                : "#include <stdio.h>\nint main(void) { return puts(\"\") < 0; }\n");
            process_.closeWriteChannel();
        }
#endif
        if (stage_ == Stage::Run)
            setInputEnabled(true);
    }
}

void RunPane::releaseProcessGroup()
{
#ifdef Q_OS_WIN
    if (auto job = std::exchange(job_, nullptr))
        CloseHandle(job);
#elif defined(Q_OS_UNIX)
    if (processGroup_ > 0)
        ::kill(-pid_t(processGroup_), SIGKILL);
#endif
    processGroup_ = 0;
}

void RunPane::stop()
{
    if (!isRunning())
        return;
    stopping_ = true;
    setInputEnabled(false);
    releaseProcessGroup();
    process_.kill();
}

void RunPane::shutdown()
{
    if (isRunning()) {
        disconnect(&process_, nullptr, this, nullptr);
        stop();
        process_.waitForFinished(1000);
        endRun();
    }
}

void RunPane::endRun()
{
    releaseProcessGroup();
    stage_ = Stage::Idle;
    stopping_ = false;
    snapshot_.reset();
    temporary_.reset();
    executable_.clear();
    launchTool_.clear();
#ifdef Q_OS_WIN
    msvc_ = false;
#endif
    process_.setProcessEnvironment(QProcessEnvironment(QProcessEnvironment::InheritFromParent));
    setInputEnabled(false);
    for (auto &stream : streams_) {
        stream.records.partial.clear();
        stream.records.dropping = stream.records.discarded = false;
        stream.decoder = {};
    }
}

void RunPane::removePreview(QTextCursor &cursor)
{
    if (preview_.isNull())
        return;
    cursor.setPosition(preview_.position(), QTextCursor::KeepAnchor);
    preview_ = QTextCursor();
    cursor.removeSelectedText();
}

void RunPane::commitPreview()
{
    if (preview_.isNull())
        return;
    // Keep the visible prompt and advance the decoders past the bytes it already displays.
    preview_ = QTextCursor();
    for (auto &stream : streams_) {
        auto &pending = stream.records.partial;
        const auto count = CompleteUTF8Prefix(pending);
        if (count) {
            ClearDecodedOutput(decoded_);
            DecodeTerminal(stream.decoder, std::string_view(pending).substr(0, count), decoded_);
            pending.erase(0, count);
        }
    }
}

QTextCursor RunPane::outputCursor() const
{
    QTextCursor cursor(output_.document());
    cursor.setPosition(inputStart_.isNull() ? output_.document()->characterCount() - 1 : inputStart_.position());
    return cursor;
}

void RunPane::trimOutput(const QTextCursor &end)
{
    const int firstLine = end.blockNumber() - int(outputScrollbackLines);
    const int excess = end.position() - int(outputScrollbackCharacters);
    if (firstLine <= 0 && excess <= 0)
        return;
    const int lineStart = firstLine > 0 ? output_.document()->findBlockByNumber(firstLine).position() : 0;
    QTextCursor cursor(end);
    cursor.setPosition(std::max(excess, lineStart));
    const auto next = cursor.block().next();
    if (cursor.positionInBlock() && next.isValid() && next.position() < end.position())
        cursor.setPosition(next.position());
    else if (output_.document()->characterAt(cursor.position()).isLowSurrogate())
        cursor.setPosition(cursor.position() + 1);
    cursor.setPosition(0, QTextCursor::KeepAnchor);
    cursor.removeSelectedText();
}

void RunPane::finishOutput(QTextCursor &cursor, bool follow)
{
    if (!inputStart_.isNull())
        inputStart_.setPosition(cursor.position());
    trimOutput(cursor);
    cursor.endEditBlock();
    output_.updateInput();
    if (follow) {
        auto *scroll = output_.verticalScrollBar();
        scroll->setValue(scroll->maximum());
    }
}

void RunPane::setInputEnabled(bool enabled)
{
    if (enabled == !inputStart_.isNull())
        return;
    auto cursor = outputCursor();
    if (enabled) {
        inputStart_ = cursor;
        inputStart_.setKeepPositionOnInsert(true);
    } else {
        inputStart_ = QTextCursor();
        cursor.movePosition(QTextCursor::End, QTextCursor::KeepAnchor);
        cursor.removeSelectedText();
    }
    output_.updateInput();
}

void RunPane::sendInput(bool eof)
{
    if (inputStart_.isNull() || process_.state() != QProcess::Running)
        return;
    auto cursor = outputCursor();
    cursor.movePosition(QTextCursor::End, QTextCursor::KeepAnchor);
    auto bytes = cursor.selectedText().replace(QChar::ParagraphSeparator, u'\n').replace(QChar::LineSeparator, u'\n').toUtf8();
    if (!eof)
        bytes += '\n';
    if (!bytes.isEmpty() && process_.write(bytes) != bytes.size())
        return;

    commitPreview();
    cursor.clearSelection();
    cursor.beginEditBlock();
    if (!eof)
        cursor.insertText(QStringLiteral("\n"), QTextCharFormat{});
    finishOutput(cursor, true);
    output_.moveCursor(QTextCursor::End);
    if (eof) {
        process_.closeWriteChannel();
        setInputEnabled(false);
    }
}

void RunPane::appendStatus(const QString &message, OutputTone tone)
{
    commitPreview();
    auto *scroll = output_.verticalScrollBar();
    const bool follow = scroll->value() == scroll->maximum();
    auto cursor = outputCursor();
    QTextCharFormat format;
    format.setForeground(toneColor(tone, output_.palette()));
    cursor.beginEditBlock();
    if (cursor.positionInBlock() != 0)
        cursor.insertText(QStringLiteral("\n"), format);
    cursor.insertText(message + QLatin1Char('\n'), format);
    finishOutput(cursor, follow);
}

QUrl RunPane::diagnosticLink(const CompilerLocation &location, bool byteColumns, bool utf16Columns) const
{
    if (!location.line || location.line > size_t(std::numeric_limits<int>::max()) ||
        location.column > size_t(std::numeric_limits<int>::max()) || location.path.starts_with('<'))
        return {};
    const QString file = decodeText(location.path);
    const QUrl url = file.startsWith(QLatin1StringView("file://")) ? QUrl(file) : QUrl();
    QString absolute = url.isLocalFile() ? url.toLocalFile() : QDir::fromNativeSeparators(file);
    absolute = QDir::cleanPath(QDir(directory_).absoluteFilePath(absolute));
    const QFileInfo info(absolute);
    QUrl link;
    if (absolute.compare(QDir::cleanPath(inputPath_), Qt::CaseSensitive) == 0 ||
        (snapshot_ && info.canonicalFilePath() == QFileInfo(inputPath_).canonicalFilePath())) {
        link.setScheme(QStringLiteral("retina-source"));
        link.setPath(QStringLiteral("current"));
    } else if (info.isFile()) {
        link = QUrl::fromLocalFile(absolute);
    } else {
        return {};
    }
    link.setFragment(QStringLiteral("%1:%2:%3").arg(location.line).arg(location.column)
                          .arg(utf16Columns ? 2 : byteColumns ? 1 : 0));
    return link;
}

void RunPane::appendLine(QTextCursor &cursor, std::string_view bytes, Stream &stream, bool stderrLine, bool partial)
{
    ClearDecodedOutput(decoded_);
    bool usesTerminalColors;
    if (partial) {
        auto decoder = stream.decoder;
        DecodeTerminal(decoder, bytes.substr(0, CompleteUTF8Prefix(bytes)), decoded_);
        usesTerminalColors = decoder.sawSGR;
    } else {
        DecodeTerminal(stream.decoder, bytes, decoded_);
        usesTerminalColors = stream.decoder.sawSGR;
    }
    auto data = std::string_view(decoded_.text);
#ifdef Q_OS_WIN
    const bool msvcDiagnostic = msvc_ && stage_ == Stage::Build;
    QByteArray converted;
    if (msvcDiagnostic) {
        const QByteArrayView bytes(data.data(), qsizetype(data.size()));
        if (!bytes.isValidUtf8()) {
            converted = QString::fromLocal8Bit(bytes).toUtf8();
            data = {converted.constData(), size_t(converted.size())};
        }
    }
#endif
    if (data.empty())
        return;

    OutputTone tone = usesTerminalColors ? OutputTone::Text : ConsoleTone(data, stderrLine);
    QUrl link;
    CompilerLocation location{};
    if (!partial) {
        const bool runtime = stderrLine && (language_ == Language::Python || JavaScriptFamily(language_)) &&
            ParseRuntimeLocation(data, language_ == Language::Python, location);
        auto format = compilerFormat(language_);
#ifdef Q_OS_WIN
        if (msvcDiagnostic)
            format = CompilerFormat::Parenthesized;
#endif
        const bool compiler = !runtime && ParseCompilerLocation(data, format, location);
        if (compiler && language_ != Language::Rust)
            tone = location.tone;
        if (runtime || compiler) {
            const bool byteColumns = format != CompilerFormat::Parenthesized &&
                (CFamily(language_) || language_ == Language::Go || language_ == Language::Odin ||
                 language_ == Language::Zig || language_ == Language::Assembly);
            link = diagnosticLink(location, byteColumns, runtime && JavaScriptFamily(language_));
        }
    }

    QString text = decodeText(data);
    int linkStart = 0;
    const bool currentSource = link.scheme() == QLatin1StringView("retina-source");
    if (link.isValid() && (currentSource || language_ == Language::Rust)) {
        const auto path = decodeText(location.path);
        const auto at = text.indexOf(path);
        if (at >= 0) {
            if (language_ == Language::Rust)
                linkStart = int(at);
            if (currentSource) {
                ShiftOutputColors(decoded_.spans, {uint32_t(at), uint32_t(path.size())}, uint32_t(name_.size()));
                text.replace(at, path.size(), name_);
            }
        }
    }
    const int lineStart = cursor.position();
    const int length = int(text.size()) - int(text.endsWith(QLatin1Char('\n')));
    const auto palette = output_.palette();
    QTextCharFormat base;
    base.setForeground(toneColor(VisibleOutputTone(tone, usesTerminalColors), palette));
    const bool dark = palette.color(QPalette::Base).lightness() < 128;
    const auto insert = [&](int first, int last, const QTextCharFormat &format) {
        if (last > first)
            cursor.insertText(text.sliced(first, last - first), format);
    };
    int at = 0;
    for (auto span : decoded_.spans) {
        const int first = std::min(length, int(span.range.location));
        const int last = std::min(length, int(span.range.location + span.range.length));
        insert(at, first, base);
        auto format = base;
        if (span.colors.foreground != defaultOutputColor)
            format.setForeground(terminalColor(span.colors.foreground, dark));
        if (span.colors.background != defaultOutputColor)
            format.setBackground(terminalColor(span.colors.background, dark));
        insert(first, last, format);
        at = last;
    }
    insert(at, length, base);
    if (link.isValid() && linkStart < length) {
        QTextCharFormat anchor;
        anchor.setAnchor(true);
        anchor.setAnchorHref(link.toString(QUrl::FullyEncoded));
        anchor.setFontUnderline(true);
        QTextCursor range = cursor;
        range.setPosition(lineStart + linkStart, QTextCursor::KeepAnchor);
        range.mergeCharFormat(anchor);
    }
    if (length < text.size())
        cursor.insertText(QStringLiteral("\n"), QTextCharFormat{});
}

void RunPane::readOutput(QProcess::ProcessChannel channel)
{
#ifdef Q_OS_WIN
    if (preparingCompiler()) {
        if (channel == QProcess::StandardError)
            process_.readAllStandardError();
        else if (stage_ == Stage::ProbeClang)
            process_.readAllStandardOutput();
        return;
    }
#endif
    process_.setReadChannel(channel);
    if (!process_.bytesAvailable())
        return;

    auto *scroll = output_.verticalScrollBar();
    const bool follow = scroll->value() == scroll->maximum();
    auto cursor = outputCursor();
    cursor.beginEditBlock();
    removePreview(cursor);
    const bool error = channel == QProcess::StandardError;
    struct Read {
        RunPane &pane;
        QTextCursor &cursor;
        Stream &stream;
        bool error;
    } read{*this, cursor, streams_[error], error};
    char buffer[16 * 1024];
    while (const auto count = process_.read(buffer, sizeof(buffer))) {
        if (count < 0)
            break;
        ReadRunRecords(read.stream.records, {buffer, size_t(count)}, recordLimit,
            [](void *context, std::string_view line) {
                auto &read = *static_cast<Read *>(context);
                read.pane.appendLine(read.cursor, line, read.stream, read.error);
                return true;
            }, &read);
        if (std::exchange(read.stream.records.discarded, false))
            cursor.insertText(QStringLiteral("[Overlong output line omitted]\n"), QTextCharFormat{});
        trimOutput(cursor);
    }
    if (!streams_[0].records.partial.empty() || !streams_[1].records.partial.empty()) {
        preview_ = cursor;
        preview_.setKeepPositionOnInsert(true);
        for (size_t i = 0; i < streams_.size(); ++i)
            appendLine(cursor, streams_[i].records.partial, streams_[i], i == 1, true);
    }
    finishOutput(cursor, follow);
}

void RunPane::finished(int exitCode, QProcess::ExitStatus status)
{
#ifdef Q_OS_WIN
    if (preparingCompiler()) {
        compilerSetupFinished(status == QProcess::NormalExit && exitCode == 0);
        return;
    }
#endif
    setInputEnabled(false);
    readOutput(QProcess::StandardOutput);
    readOutput(QProcess::StandardError);
    auto cursor = outputCursor();
    cursor.beginEditBlock();
    removePreview(cursor);
    for (size_t i = 0; i < streams_.size(); ++i) {
        appendLine(cursor, streams_[i].records.partial, streams_[i], i == 1);
        streams_[i].records.partial.clear();
        streams_[i].records.dropping = streams_[i].records.discarded = false;
        streams_[i].decoder = {};
    }
    finishOutput(cursor, false);
    releaseProcessGroup();

    if (!stopping_ && status == QProcess::NormalExit && exitCode == 0 && stage_ == Stage::Build) {
        appendStatus(QStringLiteral("Running…"));
        if (launchTool_.isEmpty())
            launch(executable_, {}, Stage::Run);
        else
            launch(launchTool_, {QStringLiteral("-jar"), executable_}, Stage::Run);
        return;
    }

    if (stopping_) {
        appendStatus(QStringLiteral("Stopped."));
    } else if (status == QProcess::CrashExit) {
        appendStatus(QStringLiteral("The process crashed."), OutputTone::Error);
    } else if (stage_ == Stage::Build && exitCode != 0) {
        appendStatus(QStringLiteral("Build failed with exit code %1.").arg(exitCode), OutputTone::Error);
    } else {
        appendStatus(QStringLiteral("Exited with code %1.").arg(exitCode), exitCode ? OutputTone::Error : OutputTone::Text);
    }
    endRun();
}
