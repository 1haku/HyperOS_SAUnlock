# HyperOS_SAUnlock for macOS

The AppKit app is built for the host Mac's architecture, with macOS 11 as its minimum deployment target. The target comes from `Info.plist`. It requires Android platform-tools at runtime.

From the repository root:

```sh
bash macos/build.sh
open "macos/build/HyperOS_SAUnlock.app"
```

Building requires Xcode Command Line Tools, a JDK, Android SDK Platform API 23+ and Build-Tools containing `d8`. The highest installed stable versions are selected automatically; `ANDROID_PLATFORM` and `ANDROID_BUILD_TOOLS` can pin them. `ANDROID_SDK_ROOT`, `ANDROID_HOME`, or the current user's standard SDK directory can locate the SDK. The Android helper is compiled from `android/SaProbe.java`. The app is locally signed, not notarized.

Backend tests use simulated ADB responses and temporary backups:

```sh
bash macos/test.sh
```

Usage: [English](../README.md#usage) | [日本語](../README.ja.md#使い方)
