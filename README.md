# HyperOS_SAUnlock

[日本語](README.ja.md) 

A desktop utility to enable and restore hidden or disabled 5G Standalone (SA) settings on Xiaomi and Redmi devices running HyperOS via ADB. Available as a macOS app (GUI) and a Windows PowerShell menu.

## Tested Devices

- Redmi K60 Ultra (23078RKD5C) HyperOS 3.0.307.0 CNROM
- Redmi K80 (24122RKC7C) HyperOS 3.0.307.0 CNROM
- Redmi 15 5G SoftBank (A501XM) HyperOS 3.0.3.0 JP SOFTBANK ROM

*Note: Verified only on povo. In theory, this may bypass device-side restrictions for other carriers if caused by identical firmware limitations, but other carriers remain untested.*  
*This tool removes device-side software blocks only. It cannot enable unsupported hardware bands or bypass carrier-level restrictions. Actual SA connectivity depends on your carrier plan and network coverage.*

## Target SIM Slot

Manually select the target slot before running any operation:

- **SIM 1 (slot 0)**
- **SIM 2 (slot 1)**

*Note: Slot numbers correspond to Android's internal logical slot indexing (0-indexed) and may not match physical tray labels. If using an eSIM, check your system SIM settings to identify the correct slot. The tool does not automatically switch default data SIMs or detect carriers.*

## Usage
[macOS](macos/README.md) | [Windows](windows/README.md)

Ensure Android platform-tools is installed on your PC, enable "USB Debugging" in Developer Options, and authorize the computer when prompted (keep only one device connected).

### macOS

1. Launch `HyperOS_SAUnlock.app` and select the target SIM slot.
2. Click **Check Status** to verify the device connection and current values.
3. Click **Unlock (Backup)** (settings will be backed up, and SA will be enabled on the selected slot).
4. Click **Restore** to revert to the backed-up state.

### Windows(Not confirmed)

Extract the Windows package and run the script in PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperOSSAUnlock.ps1

```

* `[4]` Select SIM Slot (set this first)
* `[1]` Check Status
* `[2]` Backup & Unlock
* `[3]` Restore
* `[0]` Exit

*Requires Windows PowerShell 5.1 or PowerShell 7. See the [Windows documentation](https://www.google.com/search?q=windows/README.md&utm_source=gemini) for details.*

## Backup & Safety

Backup files are stored locally:

* **macOS**: `~/Library/Application Support/HyperOSSAUnlock/backup.json`
* **Windows**: `%LocalAppData%\HyperOSSAUnlock\backup.json`

Stores the selected slot, target Android Settings values (including `dual_sa_enabled`), the SA switch state, and the device serial number. Existing `backup.json` files are never overwritten, and restoring is rejected if the serial number or slot does not match (legacy backups without slot metadata default to slot 0).

Before each operation, state snapshots are saved to `recovery.json`. If an operation fails or is interrupted, the next **Restore** automatically prioritizes rolling back to this immediate pre-operation state.

*Note: To modify a different slot, restore the current slot first, then move `backup.json` to a safe location before unlocking the other slot.*

## How It Works

1. **System Settings Override**
Sets `5g_network_mode_selection_visiable = 1` (exposes SA mode selection) and `5g_sa_mode_disabled = 0` (removes firmware-level SA restrictions).
2. **Private API Invocation**
Pushes `sa-probe.jar` to `/data/local/tmp` and invokes Xiaomi's `miui.radio.extphone` Binder service via `app_process` to execute `setUserFiveGSaEnabled(true, slot)` for the selected slot.
3. **Verification**
Reads back `isUserFiveGSaEnabled(slot)` and system settings to verify the changes.

## Building from Source

Requirements: JDK, Android SDK Platform (API 23+), Build-Tools (with `d8`).

### macOS

Requires macOS 11+ and Xcode Command Line Tools.

```sh
bash macos/build.sh
open "macos/build/HyperOS_SAUnlock.app"

```

### Windows

```powershell
.\windows\build.ps1 -SdkRoot 'C:\Android\Sdk'

```

*Outputs `windows/build/HyperOSSAUnlock-windows-powershell.zip`.*

### Running Tests

* **macOS**: `bash macos/test.sh`
* **Windows**: `.\windows\tests\Run-Tests.ps1`

*Tests use mocked ADB responses and will not modify connected devices.*

## Troubleshooting

* **Device not found**: Run `adb devices` in your terminal to verify the connection. Unlock the screen and accept the USB debugging authorization prompt.
* **ADB not found**: Ensure `platform-tools` is in your `PATH` or set `ANDROID_HOME`.
* **Network mode shows "Unknown"**: Expected on firmware builds where the query API is omitted. Check the "SA user switch" value to verify the toggle state.

## Disclaimer

* This is an unofficial tool and is not affiliated with Xiaomi, KDDI, povo, or any other carrier.
* The author assumes no liability for bricked devices, boot loops, data loss, carrier disputes, or any damages arising from the use of this tool. Use entirely at your own risk.

## License
MIT License
