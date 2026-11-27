// Retina Code, Qt frontend (Windows and Linux).
//
// This is the only file the Qt build compiles. It includes the shared editor code from source/
// and the Qt platform layer from source/qt/, so the whole program is one translation unit.

// Shared editor code.
#include "Languages.cpp"
#include "Lexer.cpp"
#include "TextBuffer.cpp"
#include "Typing.cpp"
#include "RunText.cpp"

// Qt platform layer.
#include "qt/RunPane.cpp"
#include "qt/TextView.cpp"
#include "qt/Editor.cpp"

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Retina Code"));
    useDarkWidgets(app);

    EditorWindow *window = EditorWindow::create();
    window->show();

    // Open the files named on the command line, or the sample files when there are none.
    QStringList files = app.arguments().mid(1);
    if (files.isEmpty())
        window->loadSamples();
    else
        window->openFiles(files);

    return app.exec();
}
