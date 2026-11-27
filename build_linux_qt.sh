#!/bin/sh
# Builds the Qt frontend for Linux into output/retina-code-qt.
# It uses Qt from the online installer in ~/Qt/6.12.1/gcc_64, or the folder QT names, or else the system's Qt 6
# through pkg-config. The editor also uses some of Qt's private headers, which distributions package on their own:
# qt6-base-private-dev on Debian and Ubuntu, qt6-qtbase-private-devel on Fedora.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
qt=${QT:-"$HOME/Qt/6.12.1/gcc_64"}
output="$project_dir/output"

if [ -e "$qt/lib/libQt6Core.so" ]; then
    include="$qt/include"
    lib="$qt/lib"
    version=$(ls "$include/QtCore" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    qt_flags="-I$include -I$include/QtCore -I$include/QtGui -I$include/QtWidgets"
    qt_libraries="-L$lib -lQt6Widgets -lQt6Gui -lQt6Core"
elif pkg-config --exists Qt6Widgets 2>/dev/null; then
    include=$(pkg-config --variable=includedir Qt6Core)
    lib=$(pkg-config --variable=libdir Qt6Core)
    version=$(pkg-config --modversion Qt6Core)
    qt_flags=$(pkg-config --cflags Qt6Widgets)
    qt_libraries=$(pkg-config --libs Qt6Widgets)
else
    echo "There's no Qt 6 in $qt or through pkg-config. Install Qt 6 with the online installer and set QT to its" >&2
    echo "gcc_64 folder, or install your distribution's Qt 6 development packages." >&2
    exit 1
fi

# The private headers sit in a folder named after Qt's version.
if [ ! -d "$include/QtGui/$version/QtGui/private" ]; then
    echo "Qt's private headers aren't in $include/QtGui/$version. Install them, as qt6-base-private-dev or similar." >&2
    exit 1
fi

set -x
mkdir -p "$output"

# One translation unit: main_qt.cpp includes everything else. The program finds Qt's libraries where they are installed.
${CXX:-c++} -std=c++20 -O2 -fPIC -DNDEBUG -DQT_NO_DEBUG \
    $qt_flags \
    -I "$include/QtCore/$version" -I "$include/QtCore/$version/QtCore" \
    -I "$include/QtGui/$version" -I "$include/QtGui/$version/QtGui" \
    "$project_dir/source/main_qt.cpp" \
    $qt_libraries -Wl,-rpath,"$lib" \
    -o "$output/retina-code-qt"
printf '%s\n' "$output/retina-code-qt"
