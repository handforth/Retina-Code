#pragma once

#include <QDockWidget>
#include <QProcess>
#include <QTemporaryDir>
#include <QTemporaryFile>
#include <QTextBrowser>

#include <array>
#include <optional>

#include "../RunText.hpp"
#include "../RunTools.hpp"

class RunPane final : public QDockWidget {
public:
    explicit RunPane(QWidget *parent);
    ~RunPane() override;

    QTextBrowser &output() { return output_; }
    bool isRunning() const { return stage_ != Stage::Idle; }
    void run(Language language, const QString &file, const QString &name, const QByteArray *draft);
    void stop();
    void shutdown();

private:
    enum class Stage {
        Idle, Build, Run,
#ifdef Q_OS_WIN
        FindMsvc, LoadMsvc, ProbeClang,
#endif
    };
    struct Stream {
        RunRecords records;
        TerminalDecoder decoder;
    };
    class Output final : public QTextBrowser {
    public:
        explicit Output(RunPane &pane);
        void updateInput();

    private:
        void keyPressEvent(QKeyEvent *event) override;
        void inputMethodEvent(QInputMethodEvent *event) override;
        void insertFromMimeData(const QMimeData *source) override;
        void moveToInput();
        bool inputFits(int added, int removed) const;

        RunPane &pane_;
    };

    bool makeTemporaryDirectory();
    bool makeSnapshot(const QByteArray &bytes, QStringView suffix);
    void buildCFamily(const QString &program);
    void launch(const QString &program, const QStringList &arguments, Stage stage, const QString &workingDirectory = {});
#ifdef Q_OS_WIN
    bool preparingCompiler() const;
    void prepareWindowsCompiler();
    void selectWindowsCompiler();
    void compilerSetupFinished(bool success);
#endif
    void appendStatus(const QString &message, OutputTone tone = OutputTone::Text);
    void readOutput(QProcess::ProcessChannel channel);
    void appendLine(QTextCursor &cursor, std::string_view bytes, Stream &stream, bool stderrLine, bool partial = false);
    void removePreview(QTextCursor &cursor);
    void commitPreview();
    QTextCursor outputCursor() const;
    void trimOutput(const QTextCursor &end);
    void finishOutput(QTextCursor &cursor, bool follow);
    void setInputEnabled(bool enabled);
    void sendInput(bool eof);
    QUrl diagnosticLink(const CompilerLocation &location, bool byteColumns, bool utf16Columns) const;
    void finished(int exitCode, QProcess::ExitStatus status);
    void endRun();
    void processStarted();
    void releaseProcessGroup();

    QProcess process_;
    QTextCursor preview_, inputStart_;
    Output output_;
    std::array<Stream, 2> streams_;
    DecodedOutput decoded_;
    std::optional<QTemporaryDir> temporary_;
    std::optional<QTemporaryFile> snapshot_;
    QString directory_, inputPath_, name_, executable_, launchTool_;
    Language language_ = Language::Plain;
    Stage stage_ = Stage::Idle;
    bool stopping_ = false;
    qint64 processGroup_ = 0;
#ifdef Q_OS_WIN
    void *job_ = nullptr;
    bool msvc_ = false;
#endif
};
