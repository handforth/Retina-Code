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

# One translation unit: main_appkit.mm includes everything else.
xcrun --sdk macosx clang++ \
    -std=c++20 -fobjc-arc -O2 -Wall -Wextra -Wpedantic \
    -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
    -isysroot "$sdk" \
    -framework AppKit -framework CoreText -framework CoreGraphics -framework CoreServices \
    "$source_dir/main_appkit.mm" \
    -o "$macos/Retina Code"

cp "$project_dir/resources/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/THEME_CREDITS.txt" "$resources/THEME_CREDITS.txt"
cp "$source_dir/mac_appkit/LispDebug.lisp" "$resources/LispDebug.lisp"
cp "$source_dir/mac_appkit/AliveLSP.ros" "$resources/AliveLSP.ros"
codesign --force --sign - "$app"
printf '%s\n' "$app"