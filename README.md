# HyperOS_SAUnlock

[日本語](README.ja.md)

A desktop tool for enabling hidden or disabled 5G Standalone (SA) settings on Xiaomi and Redmi phones running HyperOS. It connects over ADB, backs up the current settings, and lets you restore them later. Available as a macOS app and a Windows PowerShell menu.

Select the SIM slot yourself; there is no carrier check. The method uses Xiaomi's private telephony service, so compatibility depends on the phone's firmware.

[macOS](macos/README.md) | [Windows](windows/README.md)

## Target SIM Slot

Select **SIM 1 (slot 0)** or **SIM 2 (slot 1)** before running an operation. The tool does not check the carrier or change the default data SIM.

These are Android logical slots, not necessarily physical tray positions. Check the phone’s SIM settings when using an eSIM.

## Tested Devices

- Redmi K60 Ultra (23078RKD5C) HyperOS 3.0.307.0 CNROM
- Redmi K80 (24122RKC7C) HyperOS 3.0.307.0 CNROM
- Redmi 15 5G SoftBank (A501XM) HyperOS 3.0.3.0 JP SOFTBANK ROM

Testing so far has been on povo. The same method may work with other carriers if the restriction comes from the same firmware settings, but those carriers have not been tested. Enabling the switch does not add hardware support or bypass carrier-side restrictions. Actual SA registration depends on the device, SIM, plan, and network coverage.

## Usage

### macOS

1. Enable "USB Debugging" in Developer Options on your phone, connect it to your Mac, and authorize the prompt (connect only one device at a time).
2. Launch `HyperOS_SAUnlock.app` and select the target SIM slot.
3. Click "Check Status" to verify device connection and current values.
4. Click "Unlock (Backup)" (current settings will be backed up, and SA on the selected slot will be enabled).
5. Click "Restore" to revert to the backed-up state.

### Windows

Extract the Windows package, open PowerShell in that directory, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperOSSAUnlock.ps1
```

Choose **4** to select a SIM slot, then **1** to check status, **2** to unlock and back up, **3** to restore, or **0** to exit. Requires Windows PowerShell 5.1 or PowerShell 7 and Android platform-tools. See the [Windows instructions](windows/README.md) for ADB setup and command-line options.

## Backup

macOS: `~/Library/Application Support/HyperOSSAUnlock/backup.json`

Windows: `%LocalAppData%\HyperOSSAUnlock\backup.json`

Stores the selected slot, Android Settings values (including `dual_sa_enabled`), the SA switch state, and the device serial number. Existing backups are never overwritten. The device and selected slot must match the backup. Older backups without a slot field are treated as slot 0.

Before using a different slot, restore the previous one and move its original backup somewhere safe. Keep the same SIM configuration and default data SIM when restoring: the saved Settings values apply across the phone, and backups do not identify individual SIM cards.

Each unlock also saves `recovery.json` beside the original backup. If an unlock fails, the tool attempts to restore the state from before that attempt. If recovery is incomplete, **Restore** retries it first; after that, another restore returns to the original backup. Both platforms use the same [backup format and helper commands](docs/protocol.md).

## How It Works

The tool sets `system/5g_network_mode_selection_visiable` to `1` and `system/5g_sa_mode_disabled` to `0` to expose and enable the SA controls.

It then pushes `sa-probe.jar` to `/data/local/tmp` and runs it with `app_process`. The helper calls `setUserFiveGSaEnabled(true, slot)` through Xiaomi's `miui.radio.extphone` Binder service, using the selected slot.

Finally, it reads back `isUserFiveGSaEnabled(slot)` and the Settings values. A successful result confirms the phone-side switch, not an active SA connection.

## Building from Source

Requirements: macOS 11+, Xcode Command Line Tools, a JDK, Android SDK Platform API 23 or newer, and Build-Tools containing `d8`.

Build scripts select the highest installed stable Platform and Build-Tools versions. To pin them, set `ANDROID_PLATFORM` and `ANDROID_BUILD_TOOLS`, or pass `-PlatformVersion` and `-BuildToolsVersion` to the PowerShell build script. See the [Android build instructions](android/README.md). These are build-time dependencies; released packages only need ADB.

```sh
bash macos/build.sh
open "macos/build/HyperOS_SAUnlock.app"
```

To build the Windows package on Windows, with a JDK on `PATH`:

```powershell
.\windows\build.ps1 -SdkRoot 'C:\Android\Sdk'
```

This creates `windows/build/HyperOSSAUnlock-windows-powershell.zip`. Both builds compile the shared `android/SaProbe.java`. Platform-specific code is in `macos/` and `windows/`; generated files and device backups are excluded by `.gitignore`.

Run tests with `bash macos/test.sh` or `.\windows\tests\Run-Tests.ps1`. Tests use simulated ADB responses; they do not change a connected phone. The Windows workflow runs under both Windows PowerShell 5.1 and PowerShell 7.

## Troubleshooting

- Device not found: Run `adb devices` in Terminal to check connection. Unlock the screen and accept the USB debugging authorization prompt.
- ADB not found: Ensure platform-tools is added to your PATH or set `ANDROID_HOME`.
- Network mode shows "Unknown": Expected behavior on certain firmware builds where the query API is omitted. Check the "SA user switch" value instead.

## Disclaimer

- This is an unofficial tool and is not affiliated with Xiaomi, KDDI, povo, or any other carrier.
- The author assumes no responsibility for bricked devices, boot loops, data loss, contract issues, or any other damages resulting from using this tool. Use entirely at your own risk.

## License

MIT License
