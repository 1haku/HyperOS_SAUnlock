# HyperOS_SAUnlock for Windows

[日本語](README.ja.md)

Requires Windows 10/11, Windows PowerShell 5.1 or PowerShell 7, and Android platform-tools. The phone must appear as an authorized device in `adb devices`. Install its ADB USB driver if Windows does not recognize it.

Extract the entire Windows ZIP into one directory. Open PowerShell there and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperOSSAUnlock.ps1
```

This execution-policy setting applies to that PowerShell process only. It does not change the machine's policy. If scripts are already allowed, use `.\HyperOSSAUnlock.ps1` directly.

```text
HyperOS_SAUnlock
Target: not selected

  1. Check Status
  2. Unlock (Backup)
  3. Restore
  4. Select SIM slot
  0. Exit

Select [0-4]:
```

Enter a number and press Enter. Operations print their result and return to the menu. Keep only the target phone connected. First choose **4** to select SIM 1 (slot 0) or SIM 2 (slot 1). No carrier check is performed.

The script searches `ANDROID_SDK_ROOT`, `ANDROID_HOME`, `%LocalAppData%\Android\Sdk`, and `PATH` for `adb.exe`. To use a specific copy:

```powershell
.\HyperOSSAUnlock.ps1 -AdbPath 'C:\Android\platform-tools\adb.exe'
```

Commands are also available without the menu. These examples target SIM 2; use `-Slot 0` for SIM 1:

```powershell
.\HyperOSSAUnlock.ps1 -Action status -Slot 1
.\HyperOSSAUnlock.ps1 -Action enable -Slot 1
.\HyperOSSAUnlock.ps1 -Action restore -Slot 1
```

## Backups and recovery

The default directory is `%LocalAppData%\HyperOSSAUnlock`. `-BackupDirectory` can select another directory. Keep using the same directory when restoring.

- `backup.json` preserves the original settings and is never overwritten.
- `recovery.json` holds the state immediately before an unlock attempt. If automatic rollback fails or the process is interrupted, choose **Restore** to recover that attempt first. A second restore returns to the original backup.
- `operation.lock` prevents two copies using the same backup directory at once. The file may remain after exit; the lock is released when the process closes.

Restoration checks the device serial number and slot, attempts every saved setting, and reports failures. Older backups are treated as slot 0. Before using another slot, restore the previous one and move its original backup somewhere safe, or use a separate `-BackupDirectory`. Settings values apply across the phone: restore overlapping backups in reverse order and keep the same SIM configuration and default data SIM. A missing original setting is restored by deleting its key. The backup format matches the macOS app, but files are not synchronized between computers. Do not publish these files: they contain the device serial number.

## Build and test

From the repository root, with a JDK on `PATH` and Android SDK Platform API 23+ and Build-Tools containing `d8` installed:

```powershell
.\windows\build.ps1 -SdkRoot 'C:\Android\Sdk'
```

The build selects the highest installed stable versions. Use `-PlatformVersion` and `-BuildToolsVersion` to pin them.

The output is `windows/build/HyperOSSAUnlock-windows-powershell.zip`. The build compiles `android/SaProbe.java` and bundles the scripts, process helper and DEX JAR. End users do not need a JDK or Android SDK build tools.

Tests use a simulated ADB device and temporary backup directories:

```powershell
.\windows\tests\Run-Tests.ps1
```

For the phone-side method, tested devices, and project disclaimer, see the repository's main README. Windows USB operation still requires testing on a Windows host; a passing simulated-device test is not a real-device verification.
