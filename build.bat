@echo off
rem Builds the Qt frontend for Windows into build\RetinaCode.exe.
rem Edit these two paths if Qt or Visual Studio is installed somewhere else.
set QT=C:\Qt\6.12.1\msvc2022_64
set VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat

setlocal
cd /d "%~dp0"
if not exist build mkdir build

rem Load the MSVC compiler unless this prompt already has it.
where cl >nul 2>nul || call "%VCVARS%" >nul

rem Qt's runtime: three libraries and the Windows platform plugin, copied next to the exe once.
if not exist build\platforms mkdir build\platforms
if not exist build\Qt6Core.dll copy "%QT%\bin\Qt6Core.dll" build >nul
if not exist build\Qt6Gui.dll copy "%QT%\bin\Qt6Gui.dll" build >nul
if not exist build\Qt6Widgets.dll copy "%QT%\bin\Qt6Widgets.dll" build >nul
if not exist build\platforms\qwindows.dll copy "%QT%\plugins\platforms\qwindows.dll" build\platforms >nul

rc /nologo /fo build\retina-code.res resources\retina-code.rc

rem One translation unit: main_qt.cpp includes everything else.
cl /nologo /O2 /std:c++20 /utf-8 /permissive- /Zc:__cplusplus /MD /EHs-c- /D_HAS_EXCEPTIONS=0 ^
   /DNDEBUG /DQT_NO_DEBUG /DUNICODE /D_UNICODE ^
   /I "%QT%\include" /I "%QT%\include\QtCore" /I "%QT%\include\QtGui" /I "%QT%\include\QtWidgets" ^
   source\main_qt.cpp build\retina-code.res /Fobuild\ /Febuild\RetinaCode.exe ^
   /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup /INCREMENTAL:NO /MANIFEST:NO ^
   /LIBPATH:"%QT%\lib" Qt6Core.lib Qt6Gui.lib Qt6Widgets.lib
