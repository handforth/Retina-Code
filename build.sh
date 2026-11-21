#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir="$project_dir/source"
app=${1:-"$project_dir/output/Retina Code.app"}
macos="$app/Contents/MacOS"
resources="$app/Contents/Resources"

# AppKit uses the pre-glass tab appearance when linked against the macOS 26 SDK.
sdk=$(xcrun --sdk macosx --show-sdk-path)
if [ -d "$sdk/../MacOSX26.sdk" ]; then
    sdk="$sdk/../MacOSX26.sdk"
elif [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]; then
    sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi

set -x
mkdir -p "$macos" "$resources"
xcrun --sdk macosx clang++ \
    -std=c++20 -fobjc-arc -O2 -Wall -Wextra -Wpedantic \
    -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
    -isysroot "$sdk" \
    -framework AppKit -framework CoreText -framework CoreGraphics -framework CoreServices \
    "$source_dir/main.mm" "$source_dir/Editor.mm" "$source_dir/Rendering.mm" "$source_dir/Lexer.cpp" "$source_dir/Languages.cpp" \
    "$source_dir/VimView.mm" "$source_dir/Vim.cpp" "$source_dir/VimMulti.cpp" "$source_dir/Preferences.mm" "$source_dir/Typing.mm" \
    "$source_dir/Output.mm" "$source_dir/Runner.mm" "$source_dir/Chrome.mm" "$source_dir/Workspace.mm" \
    "$source_dir/FolderSearch.mm" \
    -o "$macos/Retina Code"
cp "$project_dir/resources/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/THEME_CREDITS.txt" "$resources/THEME_CREDITS.txt"
codesign --force --sign - "$app"
printf '%s\n' "$app"