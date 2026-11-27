@echo off
rem Test tools for the lexer, the text buffer, and the editor.
rem
rem   tests\test.bat build      builds the tools for the current tree and for the reference commit
rem   tests\test.bat capture    records what the reference does: lexer dumps, editor images, editor behavior
rem   tests\test.bat check      runs the current tree the same way and compares it with the reference
rem
rem The reference is the commit below, exported from git into build\reference. Everything else goes into build\tests.
rem Editor runs repeat at each display scale, set through QT_SCALE_FACTOR on a 100% display.
set REFERENCE_COMMIT=3ca73d1
set SCALES=1 1.25 1.5 1.75 2 2.5

rem Builds the app first, which copies Qt's runtime next to it and sets QT and VCVARS.
call "%~dp0..\build.bat" || exit /b 1

setlocal
cd /d "%~dp0.."
where cl >nul 2>nul || call "%VCVARS%" >nul

set REFERENCE=build\reference\%REFERENCE_COMMIT%
set OUT=build\tests
if not exist %OUT% mkdir %OUT%
if not exist %REFERENCE%\source (
    mkdir %REFERENCE%
    git archive %REFERENCE_COMMIT% source | tar -x -f - -C %REFERENCE% || exit /b 1
)

set FLAGS=/nologo /O2 /Zi /std:c++20 /utf-8 /permissive- /Zc:__cplusplus /MD /EHs-c- /D_HAS_EXCEPTIONS=0 /DNDEBUG /DQT_NO_DEBUG /DUNICODE /D_UNICODE /D_CRT_SECURE_NO_WARNINGS
rem The editor tests also use two of Qt's private headers: the window-system interface and the font cache.
set QT_FLAGS=/I "%QT%\include" /I "%QT%\include\QtCore" /I "%QT%\include\QtGui" /I "%QT%\include\QtWidgets" /I "%QT%\include\QtGui\6.12.1\QtGui" /I "%QT%\include\QtGui\6.12.1" /I "%QT%\include\QtCore\6.12.1"
set QT_LINK=/DEBUG /LIBPATH:"%QT%\lib" Qt6Core.lib Qt6Gui.lib Qt6Widgets.lib user32.lib gdi32.lib advapi32.lib

rem Lexer: the same tool built against each tree.
cl %FLAGS% /I source tests\lexer\lexer_test.cpp /Fo%OUT%\lexer_test.obj /Fd%OUT%\lexer_test.pdb /Febuild\lexer_test.exe /link /DEBUG /OPT:REF /OPT:ICF || exit /b 1
cl %FLAGS% /I %REFERENCE%\source tests\lexer\lexer_test.cpp /Fo%OUT%\lexer_reference.obj /Fd%OUT%\lexer_reference.pdb /Febuild\lexer_reference.exe /link /DEBUG /OPT:REF /OPT:ICF || exit /b 1

rem Text buffer: new in the current tree, and checked against Qt's QTextDocument instead of a reference.
cl %FLAGS% %QT_FLAGS% /I source tests\text\text_test.cpp /Fo%OUT%\text_test.obj /Fd%OUT%\text_test.pdb /Febuild\text_test.exe /link %QT_LINK% psapi.lib || exit /b 1

rem Editor: each tree has its own adapter around the shared scenarios in tests\editor\editor_test.cpp.
cl %FLAGS% %QT_FLAGS% /I %REFERENCE%\source tests\editor\reference_adapter.cpp /Fo%OUT%\editor_reference.obj /Fd%OUT%\editor_reference.pdb /Febuild\editor_reference.exe /link %QT_LINK% || exit /b 1
if exist tests\editor\current_adapter.cpp (
    cl %FLAGS% %QT_FLAGS% /I source tests\editor\current_adapter.cpp /Fo%OUT%\editor_current.obj /Fd%OUT%\editor_current.pdb /Febuild\editor_current.exe /link %QT_LINK% || exit /b 1
)

if "%1"=="capture" goto capture
if "%1"=="check" goto check
exit /b 0

:capture
if not exist %OUT%\reference mkdir %OUT%\reference
build\lexer_reference.exe dump %OUT%\reference\lexer.txt tests\lexer\samples %LEXER_CORPUS% || exit /b 1
for %%s in (%SCALES%) do (
    set QT_SCALE_FACTOR=%%s
    build\editor_reference.exe render %OUT%\reference\render_%%s.txt || exit /b 1
    build\editor_reference.exe behavior %OUT%\reference\behavior_%%s.txt || exit /b 1
)
set QT_SCALE_FACTOR=
exit /b 0

:check
if not exist %OUT%\current mkdir %OUT%\current
build\lexer_test.exe dump %OUT%\current\lexer.txt tests\lexer\samples %LEXER_CORPUS% || exit /b 1
build\lexer_test.exe compare %OUT%\reference\lexer.txt %OUT%\current\lexer.txt
build\text_test.exe check tests\lexer\samples || exit /b 1
if not exist build\editor_current.exe (
    echo The current tree has no editor adapter yet, so only the lexer was compared.
    exit /b 0
)
for %%s in (%SCALES%) do (
    set QT_SCALE_FACTOR=%%s
    build\editor_current.exe render %OUT%\current\render_%%s.txt
    build\editor_current.exe behavior %OUT%\current\behavior_%%s.txt
    build\editor_current.exe compare %OUT%\reference\render_%%s.txt %OUT%\current\render_%%s.txt
    build\editor_current.exe compare %OUT%\reference\behavior_%%s.txt %OUT%\current\behavior_%%s.txt
)
set QT_SCALE_FACTOR=
exit /b 0
