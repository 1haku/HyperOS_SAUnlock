#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/tests"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SCRIPT_DIR/Info.plist")"
mkdir -p "$BUILD_DIR/module-cache"
/usr/bin/swiftc -swift-version 5 -D TESTING \
    -target "$(uname -m)-apple-macosx$MIN_MACOS" \
    -sdk "$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -framework Cocoa \
    "$SCRIPT_DIR/Sources/HyperOSSAUnlock.swift" \
    "$SCRIPT_DIR/Sources/ProcessRunner.swift" \
    "$SCRIPT_DIR/Tests/main.swift" \
    -o "$BUILD_DIR/test-runner"
"$BUILD_DIR/test-runner"
