// The current editor for the editor tests: TextView and the window around it. These are the files main_qt.cpp
// includes, without its main().

#include "Languages.cpp"
#include "Lexer.cpp"
#include "TextBuffer.cpp"
#include "Typing.cpp"
#include "RunText.cpp"
#include "qt/RunPane.cpp"
#include "qt/TextView.cpp"
#include "qt/Window.cpp"

#include "editor_test.cpp"

static TextView &text_view(QWidget *editor)
{
    return *static_cast<TextView *>(editor);
}

static void adapter_setup_application(QApplication &application)
{
    application.setApplicationName(QStringLiteral("Retina Code"));
    use_dark_widgets(application);
}

static QWidget *adapter_create_editor(const QString &name, const QString &text, int theme, int font_size, TestAppearance appearance)
{
    TextAppearance look;
    look.stroke = appearance.stroke;
    look.saturation = appearance.saturation;
    look.brightness = appearance.brightness;
    look.contrast = appearance.contrast;
    return new TextView(name, text, QString(), themes[theme], font_size, look);
}

// The window reads its theme when it's created, from the settings the test writes into the scratch registry.
static QWidget *adapter_create_window(const QStringList &paths, int theme)
{
    begin_scratch_registry();

    {
        QSettings settings(QStringLiteral("Retina Code"), QStringLiteral("Qt Prototype"));
        settings.setValue(QStringLiteral("EditorTheme"), QString::fromLatin1(themes[theme].name));
    }

    EditorWindow *window = create_window(nullptr);
    end_scratch_registry();

    open_files(*window, paths);
    return window;
}

// The memory readout changes every two seconds, so its timer stops and it shows a fixed reading.
static void adapter_freeze_window(QWidget *window)
{
    EditorWindow *editor_window = static_cast<EditorWindow *>(window);
    editor_window->killTimer(editor_window->memory_timer);

    QList<QLabel *> labels = window->findChildren<QLabel *>();
    for (QLabel *label : labels) {
        if (label->toolTip().startsWith(QStringLiteral("Resident memory")))
            label->setText(QString::fromUtf16(u"Private WS 34.5 MB  \u00b7  WS 102.0 MB"));
    }
}

static QString adapter_text(QWidget *editor)
{
    const TextBuffer &text = text_view(editor).text;
    return qstring_of(std::u16string_view(text.units.data(), text.units.size()));
}

static void adapter_selection(QWidget *editor, int &anchor, int &caret)
{
    anchor = int(text_view(editor).anchor);
    caret = int(text_view(editor).caret);
}

static void adapter_set_selection(QWidget *editor, int anchor, int caret)
{
    set_selection(text_view(editor), uint32_t(anchor), uint32_t(caret));
}

// Horizontal scrolling is in pixels and vertical scrolling in lines, as QPlainTextEdit's scroll bars count them.
static void adapter_scroll(QWidget *editor, int &x, int &y)
{
    x = text_view(editor).horizontalScrollBar()->value();
    y = text_view(editor).verticalScrollBar()->value();
}

static void adapter_set_scroll(QWidget *editor, int x, int y)
{
    text_view(editor).horizontalScrollBar()->setValue(x);
    text_view(editor).verticalScrollBar()->setValue(y);
}

static QRect adapter_caret_rect(QWidget *editor, int position)
{
    return caret_rect_at(text_view(editor), uint32_t(position));
}

static QWidget *adapter_mouse_target(QWidget *editor)
{
    return text_view(editor).viewport();
}

static bool adapter_overwrite(QWidget *editor)
{
    return text_view(editor).overwrite;
}

// QPlainTextEdit::setOverwriteMode, which repaints the caret.
static void adapter_set_overwrite(QWidget *editor, bool overwrite)
{
    text_view(editor).overwrite = overwrite;
    text_view(editor).viewport()->update();
}

static void adapter_show_completions(QWidget *editor)
{
    show_completions(text_view(editor), 0);
}

static void adapter_toggle_comment(QWidget *editor)
{
    toggle_line_comment(text_view(editor));
}

static bool adapter_completion_visible(QWidget *editor)
{
    return text_view(editor).completion && text_view(editor).completion->isVisible();
}
