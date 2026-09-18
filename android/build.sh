#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$SDK_ROOT" ]]; then
    for candidate in "${HOME:-}/Library/Android/sdk" "${HOME:-}/Android/Sdk"; do
        if [[ -d "$candidate" ]]; then
            SDK_ROOT="$candidate"
            break
        fi
    done
fi
if [[ -z "$SDK_ROOT" ]]; then
    echo "Android SDK not found. Set ANDROID_SDK_ROOT or ANDROID_HOME." >&2
    exit 1
fi
PLATFORM_VERSION="${ANDROID_PLATFORM:-}"
if [[ -z "$PLATFORM_VERSION" ]]; then
    PLATFORM_VERSION=0
    for candidate in "$SDK_ROOT"/platforms/android-*; do
        version="${candidate##*/android-}"
        if [[ "$version" =~ ^[1-9][0-9]*$ ]] && [[ -f "$candidate/android.jar" ]] && (( version > PLATFORM_VERSION )); then
            PLATFORM_VERSION="$version"
        fi
    done
fi
if [[ ! "$PLATFORM_VERSION" =~ ^[1-9][0-9]*$ ]] || (( PLATFORM_VERSION < 23 )); then
    echo "Install a stable Android SDK Platform API 23 or newer, or set ANDROID_PLATFORM to its API number." >&2
    exit 1
fi
TOOLS_VERSION="${ANDROID_BUILD_TOOLS:-}"
if [[ -z "$TOOLS_VERSION" ]]; then
    versions=()
    for candidate in "$SDK_ROOT"/build-tools/*; do
        version="${candidate##*/}"
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ -x "$candidate/d8" ]]; then
            versions+=("$version")
        fi
    done
    if (( ${#versions[@]} )); then
        TOOLS_VERSION="$(printf '%s\n' "${versions[@]}" | sort -t . -k1,1n -k2,2n -k3,3n | tail -n 1)"
    fi
fi
if [[ ! "$TOOLS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Install stable Android Build-Tools containing d8, or set ANDROID_BUILD_TOOLS to an installed version." >&2
    exit 1
fi
ANDROID_JAR="$SDK_ROOT/platforms/android-$PLATFORM_VERSION/android.jar"
D8="$SDK_ROOT/build-tools/$TOOLS_VERSION/d8"
if [[ ! -f "$ANDROID_JAR" || ! -x "$D8" ]]; then
    echo "Requested Android SDK Platform $PLATFORM_VERSION or Build-Tools $TOOLS_VERSION is not installed." >&2
    exit 1
fi
echo "Using Android SDK Platform $PLATFORM_VERSION and Build-Tools $TOOLS_VERSION"
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex"
javac -source 8 -target 8 -classpath "$ANDROID_JAR" \
    -d "$BUILD_DIR/classes" "$SCRIPT_DIR/SaProbe.java"
"$D8" --min-api 23 --lib "$ANDROID_JAR" --output "$BUILD_DIR/dex" "$BUILD_DIR/classes/SaProbe.class"
jar cf "$BUILD_DIR/sa-probe.jar" -C "$BUILD_DIR/dex" classes.dex
echo "Built: $BUILD_DIR/sa-probe.jar"
