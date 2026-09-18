# Android helper

`SaProbe.java` is the single source used by both desktop clients. It is compiled to DEX and packaged as `sa-probe.jar`; it is not an installable APK.

Build on macOS:

```sh
bash android/build.sh
```

Build on Windows:

```powershell
.\android\build.ps1 -SdkRoot 'C:\Android\Sdk'
```

Both produce `android/build/sa-probe.jar`. A JDK, Android SDK Platform API 23 or newer, and Build-Tools containing `d8` are required. The desktop build scripts invoke this build automatically.

The scripts select the highest installed stable version of each SDK component, excluding preview names. These versions describe the compiler environment, not the required HyperOS version. To reproduce a particular build, specify installed versions explicitly:

```sh
ANDROID_PLATFORM=36 ANDROID_BUILD_TOOLS=36.0.0 bash android/build.sh
```

```powershell
.\android\build.ps1 -SdkRoot 'C:\Android\Sdk' -PlatformVersion 36 -BuildToolsVersion 36.0.0
```

The PowerShell build also accepts the `ANDROID_PLATFORM` and `ANDROID_BUILD_TOOLS` environment variables. An explicitly requested version must be installed; the build does not silently choose another version. No SDK downloads are performed.

The helper uses Xiaomi's private telephony service. Its availability and permissions depend on the phone's firmware; the DEX minimum API level does not imply support for every Android device. See [commands and backup behavior](../docs/protocol.md).
