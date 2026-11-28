// Retina Code, Qt frontend (Windows and Linux).
//
// This is the only file the Qt build compiles. It includes the shared editor code from source/
// and the Qt platform layer from source/qt/, so the whole program is one translation unit.

// Shared editor code.
#include "Languages.cpp"
#include "Lexer.cpp"
#include "TextBuffer.cpp"
#include "Typing.cpp"
#include "Vim.cpp"
#include "VimMulti.cpp"
#include "Cursors.cpp"
#include "RunText.cpp"
#include "Run.cpp"

// Qt platform layer.
#include "qt/RunPane.cpp"
#include "qt/TextView.cpp"
#include "qt/Window.cpp"

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Retina Code"));
    use_dark_widgets(app);

    EditorWindow *window = create_window(nullptr);
    window->show();

    // Open the files named on the command line, or the sample files when there are none.
    QStringList files = app.arguments().mid(1);
    if (files.isEmpty())
        load_samples(*window);
    else
        open_files(*window, files);

    return app.exec();
}
