#!/bin/sh
# Builds the Qt frontend for macOS into "output/Retina Code Qt.app", next to the AppKit app build.sh makes.
# It uses Qt from the online installer in ~/Qt/6.12.1/macos. Set QT to use another Qt for macOS folder, the one that
# holds lib/QtCore.framework.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
qt=${QT:-"$HOME/Qt/6.12.1/macos"}
app="$project_dir/output/Retina Code Qt.app"
macos="$app/Contents/MacOS"
resources="$app/Contents/Resources"

if [ ! -d "$qt/lib/QtCore.framework" ]; then
    echo "There's no Qt for macOS in $qt. Install Qt 6 with the online installer, or set QT to its macos folder." >&2
    exit 1
fi

# The editor also uses some of Qt's private headers, which sit in a folder named after Qt's version.
version=$(ls "$qt/lib/QtCore.framework/Headers" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)

set -x
mkdir -p "$macos" "$resources"

# One translation unit: main_qt.cpp includes everything else. The app finds Qt's frameworks where they are installed.
xcrun --sdk macosx clang++ \
    -std=c++20 -O2 -DNDEBUG -DQT_NO_DEBUG \
    -arch "$(uname -m)" \
    -F "$qt/lib" \
    -I "$qt/lib/QtCore.framework/Headers" -I "$qt/lib/QtGui.framework/Headers" -I "$qt/lib/QtWidgets.framework/Headers" \
    -I "$qt/lib/QtCore.framework/Headers/$version" -I "$qt/lib/QtCore.framework/Headers/$version/QtCore" \
    -I "$qt/lib/QtGui.framework/Headers/$version" -I "$qt/lib/QtGui.framework/Headers/$version/QtGui" \
    "$project_dir/source/main_qt.cpp" \
    -framework QtCore -framework QtGui -framework QtWidgets -Wl,-rpath,"$qt/lib" \
    -o "$macos/Retina Code Qt"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Retina Code Qt</string>
    <key>CFBundleIdentifier</key>
    <string>local.retina-code-qt</string>
    <key>CFBundleName</key>
    <string>Retina Code Qt</string>
    <key>CFBundleIconFile</key>
    <string>retina-code</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
cp "$project_dir/resources/retina-code.icns" "$resources/retina-code.icns"
codesign --force --sign - "$app"
printf '%s\n' "$app"
