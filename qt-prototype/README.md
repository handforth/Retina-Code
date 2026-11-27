# Retina Code Qt prototype

This standalone build uses Qt Fusion in dark mode, with a compact document tab strip and Retina Code’s shared lexer and built-in editor themes. It opens and saves UTF-8 source files. The two sample tabs include accented text, Japanese, and an emoji for checking font fallback.

## Try it on Windows

Extract the entire Windows x64 ZIP and open `RetinaCodePrototype.exe` in the extracted folder. Use **File → Open** or **Ctrl+O** to add your own files. **View** has zoom and editor palette controls. On Windows, use **Ctrl+=** or **Ctrl++** to zoom in, **Ctrl+-** to zoom out, **Ctrl+0** to reset, or **Ctrl+mouse wheel** to zoom in either direction. The Windows build uses Consolas by default and Qt’s DirectWrite font backend. Check the text at your normal Windows display scaling, then at 100% and 125% if you want to compare.

You can also drop one or more UTF-8 files from Explorer onto the window. They open in separate tabs, with the first successfully opened file selected. Dropping an already-open file focuses its tab and preserves its edits.

Use **Ctrl+N** for a blank untitled tab or **Ctrl+Shift+N** for a new window with one blank tab. A new window inherits the current window’s zoom, editor palette, and text appearance.

Use **Ctrl+S** to save the current tab or **Ctrl+Shift+S** to choose a destination with Save As. The first save of an untitled tab opens the same file picker. Closing an edited tab offers Save, Discard, and Cancel. Existing files keep their UTF-8 BOM and first detected line-ending style. New files use UTF-8 with LF line endings.

Use the language dropdown in the status bar to set the current tab’s mode or return to **Auto Detect**. The Qt build compiles Retina Code’s `source/Languages.cpp` and `source/Lexer.cpp` directly, so the picker, file detection, and syntax highlighting use the shared language definitions.

Word completions appear as you type and combine names from the current file with the active language’s built-in vocabulary. Press **Ctrl+Space** to show completions, use the arrow keys to select a word, and accept it with **Tab**, **Enter**, or a click. **Esc** dismisses the list.

Press **Ctrl+/** to toggle comments on the current line or selected lines. The command uses the active language’s comment syntax and undoes in one step.

The editor shares Retina Code’s typing rules for brackets, quotes, tags, and smart indentation. Type an opening delimiter around a selection to wrap it. Place the caret beside a bracket to outline both ends of the pair. Enter indents using the file’s style, and Tab and Shift+Tab indent or outdent selected lines.

Press **Ctrl+R** to run the current source file with its installed interpreter or compiler. Run uses a temporary snapshot for untitled files and unsaved edits. The bottom Output pane shows program output and clickable diagnostics. Click Output to type program input and press **Enter** to send it. The submitted text stays in the log. Press **Ctrl+R** again to stop the run. **View → Output** reopens the log.

On Windows, the first C or C++ run prepares the installed Visual Studio toolchain in the background and reuses it for the rest of the session. The runner uses Clang on PATH when it can compile and link, and falls back to MSVC. To install MSVC, select **Desktop development with C++** and a Windows SDK in the [Visual Studio Build Tools installer](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio).

The Qt runner launches single source files. It searches PATH first, then common tool directories on macOS and Linux. For Rust it also checks the Cargo bin directory on all three platforms, including an absolute `CARGO_HOME` if set. Standalone C# files use the file-based mode in the .NET 10 SDK. [Microsoft’s `dotnet run` documentation](https://learn.microsoft.com/dotnet/core/tools/dotnet-run)

The Windows editor requests natural horizontal spacing with vertical hinting. The status bar shows the zoom level in logical pixels.

Open **View → Editor Theme** to search the built-in themes. Click a theme or use the arrow keys to preview it in your open editor windows. Press Enter to keep it as the default for future launches, or Esc to restore the previous theme.

Open **View → Text Appearance** to adjust stroke weight, saturation, brightness, and contrast. The sliders preview changes in the active tab and apply to all tabs as you switch between them. The prototype saves them locally. **Reset** restores the original palette values and stroke weight.

Stroke weight runs from 0% to 100%. It blends in half-pixel edge passes for light adjustments. Above 30%, it also reinforces coverage at the original glyph positions to limit sideways spread. The effect uses the existing backing store and the same glyph positions. Contrast adjusts the distance between the text luminance and the editor background.

The status bar samples memory every two seconds. **Private WS** is the process’s private resident memory. **WS** includes resident shared pages. Both are in decimal MB. On Windows versions where the private working-set counter is unavailable, the status bar shows only WS.

1. Launch normally and record both numbers after the first few samples settle.
2. Open a few of the files you normally edit. Type, scroll, and switch tabs. Record the range you see.
3. Resize or maximize the window and record the new numbers with the display scaling. Backing-store memory grows with the window’s physical pixel count.

This prototype measures Qt Widgets, basic editing, and syntax highlighting. It leaves LSP, Vim, inlays, and the debugger for the full port. The build measures the editor process by itself.

## Build from source

Install Qt 6.8 or newer with its desktop Widgets libraries, a matching C++20 compiler, CMake, and Ninja. On Windows, use a command prompt configured for the Qt kit, with that kit’s `bin` and the matching compiler on PATH. Run these commands from the repository root.

```bat
qt-cmake -S qt-prototype -B build\qt-prototype -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build\qt-prototype
windeployqt --release --no-translations --no-opengl-sw --no-system-d3d-compiler build\qt-prototype\RetinaCodePrototype.exe
build\qt-prototype\RetinaCodePrototype.exe
```

On Linux or macOS, run `qt-cmake -S qt-prototype -B build/qt-prototype -G Ninja -DCMAKE_BUILD_TYPE=Release` and `cmake --build build/qt-prototype`. The macOS build produces an app bundle.

The portable x64 package uses Qt 6.9.3. It includes the prototype sources, Qt license texts, and information about the matching Qt source archive.
