#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/HyperOS_SAUnlock.app"
bash "$SCRIPT_DIR/../android/build.sh"
mkdir -p "$BUILD_DIR/module-cache" \
    "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/bin/cp "$SCRIPT_DIR/../android/build/sa-probe.jar" "$APP_BUNDLE/Contents/Resources/sa-probe.jar"

SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SCRIPT_DIR/Info.plist")"
/usr/bin/swiftc -swift-version 5 -O \
    -target "$(uname -m)-apple-macosx$MIN_MACOS" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -framework Cocoa \
    -o "$APP_BUNDLE/Contents/MacOS/HyperOSSAUnlock" \
    "$SCRIPT_DIR/Sources/HyperOSSAUnlock.swift" \
    "$SCRIPT_DIR/Sources/ProcessRunner.swift"

/bin/cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/bin/chmod +x "$APP_BUNDLE/Contents/MacOS/HyperOSSAUnlock"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

echo "Built: $APP_BUNDLE"
