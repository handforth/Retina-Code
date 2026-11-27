// The reference editor for the editor tests: the Qt frontend at the reference commit, built on QPlainTextEdit.
// tests/test.bat exports that commit's source/ and puts it first on the include path, so the files below are the
// reference's own. They are the files main_qt.cpp includes, without its main().

#include "Languages.cpp"
#include "Lexer.cpp"
#include "Typing.cpp"
#include "RunText.cpp"
#include "qt/RunPane.cpp"
#include "qt/Editor.cpp"

#include "editor_test.cpp"

static CodeEdit *code_edit(QWidget *editor)
{
    return static_cast<CodeEdit *>(editor);
}

static void adapter_setup_application(QApplication &application)
{
    application.setApplicationName(QStringLiteral("Retina Code"));
    useDarkWidgets(application);
}

static QWidget *adapter_create_editor(const QString &name, const QString &text, int theme, int font_size, TestAppearance appearance)
{
    TextAppearance look;
    look.stroke = appearance.stroke;
    look.saturation = appearance.saturation;
    look.brightness = appearance.brightness;
    look.contrast = appearance.contrast;
    return new CodeEdit(name, text, QString(), themes[theme], font_size, look);
}

// The window reads its theme when it's created, from the settings the test writes into the scratch registry.
static QWidget *adapter_create_window(const QStringList &paths, int theme)
{
    begin_scratch_registry();

    {
        QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
        settings.setValue(QStringLiteral("EditorTheme"), QString::fromLatin1(themes[theme].name));
    }

    EditorWindow *window = EditorWindow::create();
    end_scratch_registry();

    window->openFiles(paths);
    return window;
}

// The memory readout changes every two seconds, so its timer stops and it shows a fixed reading.
static void adapter_freeze_window(QWidget *window)
{
    QList<QTimer *> timers = window->findChildren<QTimer *>(Qt::FindDirectChildrenOnly);
    for (QTimer *timer : timers) {
        if (timer->interval() == 2000)
            timer->stop();
    }

    QList<QLabel *> labels = window->findChildren<QLabel *>();
    for (QLabel *label : labels) {
        if (label->toolTip().startsWith(QStringLiteral("Resident memory")))
            label->setText(QString::fromUtf16(u"Private WS 34.5 MB  \u00b7  WS 102.0 MB"));
    }
}

// The text as it would be saved, with \n between lines.
static QString adapter_text(QWidget *editor)
{
    QString text = code_edit(editor)->document()->toRawText();
    text.replace(QChar::ParagraphSeparator, u'\n');
    return text;
}

static void adapter_selection(QWidget *editor, int &anchor, int &caret)
{
    QTextCursor cursor = code_edit(editor)->textCursor();
    anchor = cursor.anchor();
    caret = cursor.position();
}

static void adapter_set_selection(QWidget *editor, int anchor, int caret)
{
    QTextCursor cursor = code_edit(editor)->textCursor();
    cursor.setPosition(anchor);
    cursor.setPosition(caret, QTextCursor::KeepAnchor);
    code_edit(editor)->setTextCursor(cursor);
}

// Horizontal scrolling is in pixels and vertical scrolling in lines, as QPlainTextEdit's scroll bars count them.
static void adapter_scroll(QWidget *editor, int &x, int &y)
{
    x = code_edit(editor)->horizontalScrollBar()->value();
    y = code_edit(editor)->verticalScrollBar()->value();
}

static void adapter_set_scroll(QWidget *editor, int x, int y)
{
    code_edit(editor)->horizontalScrollBar()->setValue(x);
    code_edit(editor)->verticalScrollBar()->setValue(y);
}

static QRect adapter_caret_rect(QWidget *editor, int position)
{
    QTextCursor cursor(code_edit(editor)->document());
    cursor.setPosition(position);
    return code_edit(editor)->cursorRect(cursor);
}

static QWidget *adapter_mouse_target(QWidget *editor)
{
    return code_edit(editor)->viewport();
}

static bool adapter_overwrite(QWidget *editor)
{
    return code_edit(editor)->overwriteMode();
}

static void adapter_set_overwrite(QWidget *editor, bool overwrite)
{
    code_edit(editor)->setOverwriteMode(overwrite);
}

static void adapter_show_completions(QWidget *editor)
{
    code_edit(editor)->complete();
}

static void adapter_toggle_comment(QWidget *editor)
{
    code_edit(editor)->toggleLineComment();
}

static bool adapter_completion_visible(QWidget *editor)
{
    QList<QWidget *> children = code_edit(editor)->viewport()->findChildren<QWidget *>(Qt::FindDirectChildrenOnly);
    for (QWidget *child : children) {
        if (child->accessibleName() == QStringLiteral("Completions"))
            return child->isVisible();
    }

    return false;
}
