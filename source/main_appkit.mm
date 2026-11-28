// Retina Code, AppKit frontend (macOS).
//
// This is the only file the Mac build compiles. It includes the shared editor code from source/
// and the AppKit platform layer from source/mac_appkit/, so the whole program is one translation unit.

// Shared editor code.
#include "Languages.cpp"
#include "Lexer.cpp"
#include "Typing.cpp"
#include "RunText.cpp"
#include "Run.cpp"
#include "Vim.cpp"
#include "VimMulti.cpp"

// macOS processes, debugger transport, and language servers.
#include "mac_appkit/ChildProcess.cpp"
#include "mac_appkit/LSPProcess.cpp"
#include "mac_appkit/DebugTransport.cpp"
#include "mac_appkit/LanguageTools.cpp"
#include "mac_appkit/LanguageServer.cpp"

// AppKit platform layer.
#include "mac_appkit/Rendering.mm"
#include "mac_appkit/Typing.mm"
#include "mac_appkit/VimView.mm"
#include "mac_appkit/Chrome.mm"
#include "mac_appkit/Output.mm"
#include "mac_appkit/Runner.mm"
#include "mac_appkit/Debugger.mm"
#include "mac_appkit/DebugPane.mm"
#include "mac_appkit/Preferences.mm"
#include "mac_appkit/Workspace.mm"
#include "mac_appkit/FolderSearch.mm"
#include "mac_appkit/Starters.mm"
#include "mac_appkit/EditorHover.mm"
#include "mac_appkit/LanguageServerBridge.mm"
#include "mac_appkit/Editor.mm"
#include "mac_appkit/Application.mm"

int main()
{
    @autoreleasepool {
        SetUpEditorFontManager();

        NSApplication *application = NSApplication.sharedApplication;
        ApplicationDelegate *delegate = [[ApplicationDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }

    return 0;
}
