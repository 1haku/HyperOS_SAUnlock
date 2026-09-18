#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('HyperOSSAUnlock.ProcessRunner' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'ProcessRunner.cs')
}

function Find-SAUnlockADB {
    param([string]$ExplicitPath)
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { throw "ADB not found: $ExplicitPath" }
        return (Resolve-Path -LiteralPath $ExplicitPath).ProviderPath
    }
    $candidates = @()
    foreach ($sdk in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if ($sdk) { $candidates += Join-Path $sdk 'platform-tools/adb.exe' }
    }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Android/Sdk/platform-tools/adb.exe' }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command adb.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw 'adb.exe was not found. Install Android platform-tools, add it to PATH, or use -AdbPath.'
}

function New-SAUnlockContext {
    param([int]$Slot = -1, [string]$AdbPath, [string]$BackupDirectory, [string]$ProbePath, [scriptblock]$Runner)
    if ($Slot -notin @(0, 1)) { throw 'Select SIM 1 (slot 0) or SIM 2 (slot 1) using -Slot.' }
    if (-not $BackupDirectory) {
        $localData = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $localData) { throw 'Local application data directory is unavailable. Use -BackupDirectory.' }
        $BackupDirectory = Join-Path $localData 'HyperOSSAUnlock'
    }
    if (-not $ProbePath) {
        $ProbePath = Join-Path $PSScriptRoot 'sa-probe.jar'
        if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) {
            $ProbePath = Join-Path $PSScriptRoot '../android/build/sa-probe.jar'
        }
    }
    if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) {
        throw 'sa-probe.jar is missing. Extract the complete Windows package or build the Android helper first.'
    }
    if (-not $Runner) { $AdbPath = Find-SAUnlockADB $AdbPath }
    [pscustomobject]@{
        AdbPath = $AdbPath
        ProbePath = [IO.Path]::GetFullPath($ProbePath)
        BackupDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupDirectory)
        Runner = $Runner
        Slot = $Slot
    }
}

function Invoke-SAUnlockADB {
    param($Context, [string[]]$Arguments)
    if ($Context.Runner) { $result = & $Context.Runner $Arguments }
    else { $result = [HyperOSSAUnlock.ProcessRunner]::Run($Context.AdbPath, $Arguments, 30000) }
    if ($result.Truncated) { throw 'ADB output exceeded the capture limit; the result cannot be verified.' }
    if ($result.Status -ne 0) {
        throw "ADB command failed (exit code $($result.Status)):`n$($result.Stdout)`n$($result.Stderr)"
    }
    return $result.Stdout
}

function Get-SAUnlockDevice {
    param($Context)
    $output = Invoke-SAUnlockADB $Context @('devices')
    $devices = @()
    foreach ($line in ($output -split '\r?\n')) {
        if ($line -match '^(\S+)\t+(\S+)') {
            $devices += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    $ready = @($devices | Where-Object { $_.State -ceq 'device' })
    if ($ready.Count -gt 1) { throw 'Multiple authorized devices found. Connect only the target phone.' }
    if ($ready.Count -eq 1) { return $ready[0].Serial }
    if ($devices.Count) { throw "Device state: $($devices[0].State). Unlock the phone and allow USB debugging." }
    throw 'No ADB device found. Check the USB cable, debugging authorization and Windows USB driver.'
}

function Copy-SAUnlockProbe {
    param($Context, [string]$Serial)
    $null = Invoke-SAUnlockADB $Context @('-s', $Serial, 'push', $Context.ProbePath, '/data/local/tmp/sa-unlock-probe.jar')
}

function Invoke-SAUnlockProbe {
    param($Context, [string]$Serial, [ValidateSet('state', 'enable-sa', 'disable-sa')][string]$Action)
    Invoke-SAUnlockADB $Context @('-s', $Serial, 'shell', "CLASSPATH=/data/local/tmp/sa-unlock-probe.jar app_process /system/bin SaProbe $Action $($Context.Slot)")
}

function Get-SAUnlockProbeState {
    param($Context, [string]$Serial)
    $output = Invoke-SAUnlockProbe $Context $Serial state
    $enabled = $null
    $mode = $null
    $reportedSlot = $null
    foreach ($line in ($output -split '\r?\n')) {
        if ($line.StartsWith('STATE slot=')) {
            if ($null -ne $reportedSlot -or $line -cne "STATE slot=$($Context.Slot)") { throw 'Unexpected or duplicate slot in state output.' }
            $reportedSlot = $Context.Slot
        } elseif ($line.StartsWith('STATE isUserFiveGSaEnabled=')) {
            $value = $line.Substring('STATE isUserFiveGSaEnabled='.Length).Trim()
            if ($null -ne $enabled -or ($value -cne 'true' -and $value -cne 'false')) {
                throw "Invalid or duplicate SA state: $value"
            }
            $enabled = $value -ceq 'true'
        } elseif ($line.StartsWith('STATE fiveGNetworkMode=')) {
            $mode = ConvertTo-SAUnlockSetting $line.Substring('STATE fiveGNetworkMode='.Length)
        }
    }
    if ($null -eq $enabled -or $reportedSlot -ne $Context.Slot) { throw 'Could not parse SaProbe state output.' }
    [pscustomobject]@{ Enabled = $enabled; NetworkMode = $mode }
}

function ConvertTo-SAUnlockSetting {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return $null }
    $trimmed = $Value.Trim()
    if (-not $trimmed -or $trimmed -ceq 'null') { return $null }
    return $trimmed
}

function Get-SAUnlockSetting {
    param($Context, [string]$Serial, [string]$Scope, [string]$Key)
    $output = Invoke-SAUnlockADB $Context @('-s', $Serial, 'shell', 'settings', 'get', $Scope, $Key)
    $value = ConvertTo-SAUnlockSetting $output
    if ($null -ne $value -and $value -cnotmatch '^-?\d+$') { throw "Invalid setting read-back for $Key." }
    return $value
}

function Set-SAUnlockSetting {
    param($Context, [string]$Serial, [string]$Scope, [string]$Key, $Value)
    if ($null -eq $Value) { $command = @('delete', $Scope, $Key) }
    else {
        # ADB joins remote-shell arguments. These keys contain integers, so refuse
        # arbitrary shell text from an edited backup before sending it to the phone.
        if ($Value -isnot [string] -or $Value -cnotmatch '^-?\d+$') { throw "Invalid saved value for $Key." }
        $command = @('put', $Scope, $Key, $Value)
    }
    $null = Invoke-SAUnlockADB $Context (@('-s', $Serial, 'shell', 'settings') + $command)
}

function Get-SAUnlockState {
    param($Context, [string]$Serial)
    $visible = Get-SAUnlockSetting $Context $Serial system '5g_network_mode_selection_visiable'
    $disabled = Get-SAUnlockSetting $Context $Serial system '5g_sa_mode_disabled'
    $mode = Get-SAUnlockSetting $Context $Serial global 'fiveg_network_mode'
    $probe = Get-SAUnlockProbeState $Context $Serial
    $dual = Get-SAUnlockSetting $Context $Serial global 'dual_sa_enabled'
    [pscustomobject]@{
        visible = $visible; saDisabled = $disabled; fiveGNetworkMode = $mode
        saEnabled = $probe.Enabled; networkMode = $probe.NetworkMode
        dualSaEnabled = $dual
    }
}

function Read-SAUnlockBackup {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if ($value -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
        foreach ($required in @('serial', 'savedAt', 'saEnabled')) {
            if (-not $value.PSObject.Properties[$required]) { throw "Missing field: $required" }
        }
        # Some PowerShell versions deserialize ISO JSON strings as DateTime.
        if ($value.savedAt -is [DateTime]) { $value.savedAt = $value.savedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
        if ($value.serial -isnot [string] -or [string]::IsNullOrWhiteSpace($value.serial) -or
            $value.savedAt -isnot [string] -or $value.saEnabled -isnot [bool]) { throw 'Invalid backup fields.' }
        if (-not $value.PSObject.Properties['formatVersion']) {
            if ($value.PSObject.Properties['slot']) { throw 'Slot is present without a backup version.' }
            Add-Member -InputObject $value -NotePropertyName formatVersion -NotePropertyValue 1
            Add-Member -InputObject $value -NotePropertyName slot -NotePropertyValue 0
        } elseif (($value.formatVersion -isnot [int] -and $value.formatVersion -isnot [long]) -or
                  $value.formatVersion -ne 2 -or -not $value.PSObject.Properties['slot'] -or
                  ($value.slot -isnot [int] -and $value.slot -isnot [long]) -or $value.slot -notin @(0, 1)) {
            throw 'Unsupported backup version or invalid slot.'
        }
        foreach ($key in @('visible', 'saDisabled', 'fiveGNetworkMode', 'dualSaEnabled')) {
            if (-not $value.PSObject.Properties[$key]) { Add-Member -InputObject $value -NotePropertyName $key -NotePropertyValue $null }
            if ($null -ne $value.$key -and ($value.$key -isnot [string] -or $value.$key -cnotmatch '^-?\d+$')) {
                throw "Invalid saved value: $key"
            }
        }
        return $value
    } catch { throw "Could not read backup ${Path}: $($_.Exception.Message)" }
}

function Assert-SAUnlockBackupSlot {
    param($Context, $Backup)
    if ($Backup.slot -ne $Context.Slot) {
        throw "The backup targets SIM $($Backup.slot + 1) (slot $($Backup.slot)). Select that slot to restore it, or move the original backup somewhere safe before using a different slot."
    }
}

function Save-SAUnlockBackup {
    param($Backup, [string]$Path)
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        $json = $Backup | ConvertTo-Json -Depth 4
        $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($json)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        # Same-directory rename is atomic and refuses to overwrite an existing backup.
        [IO.File]::Move($temporary, $Path)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Restore-SAUnlockCore {
    param($Context, [string]$Serial, $Backup)
    Assert-SAUnlockBackupSlot $Context $Backup
    $errors = New-Object 'Collections.Generic.List[string]'
    $verified = New-Object 'Collections.Generic.List[string]'
    $action = if ($Backup.saEnabled) { 'enable-sa' } else { 'disable-sa' }
    try { $null = Invoke-SAUnlockProbe $Context $Serial $action }
    catch { $errors.Add("SA write: $($_.Exception.Message)") }
    $settings = @(
        @('system', '5g_network_mode_selection_visiable', $Backup.visible),
        @('system', '5g_sa_mode_disabled', $Backup.saDisabled),
        @('global', 'fiveg_network_mode', $Backup.fiveGNetworkMode)
    )
    if ($Backup.formatVersion -eq 2) { $settings += ,@('global', 'dual_sa_enabled', $Backup.dualSaEnabled) }
    foreach ($item in $settings) {
        try { Set-SAUnlockSetting $Context $Serial $item[0] $item[1] $item[2] }
        catch { $errors.Add("$($item[1]) write: $($_.Exception.Message)") }
    }
    try {
        $actual = Get-SAUnlockProbeState $Context $Serial
        if ($actual.Enabled -ne $Backup.saEnabled) { throw "Expected $($Backup.saEnabled), read $($actual.Enabled)." }
        $verified.Add('SA user switch')
    } catch { $errors.Add("SA verification: $($_.Exception.Message)") }
    foreach ($item in $settings) {
        try {
            $actual = Get-SAUnlockSetting $Context $Serial $item[0] $item[1]
            if ($actual -cne $item[2]) { throw "Expected '$($item[2])', read '$actual'." }
            $verified.Add($item[1])
        } catch { $errors.Add("$($item[1]) verification: $($_.Exception.Message)") }
    }
    if ($errors.Count) { throw "Restore incomplete.`nVerified: $($verified -join ', ')`n$($errors -join "`n")" }
}

function Format-SAUnlockValue {
    param($Value)
    if ($null -eq $Value) { return 'unset' }
    return [string]$Value
}

function Invoke-SAUnlockOperation {
    param($Context, [ValidateSet('status', 'enable', 'restore')][string]$Action)
    $null = [IO.Directory]::CreateDirectory($Context.BackupDirectory)
    try {
        $lock = [IO.File]::Open((Join-Path $Context.BackupDirectory 'operation.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch { throw "Cannot lock the backup directory. Another instance may be running: $($_.Exception.Message)" }
    try {
        $serial = Get-SAUnlockDevice $Context
        $backupPath = Join-Path $Context.BackupDirectory 'backup.json'
        $recoveryPath = Join-Path $Context.BackupDirectory 'recovery.json'
        $pending = Test-Path -LiteralPath $recoveryPath
        if ($Action -eq 'restore') {
            $path = if ($pending) { $recoveryPath } else { $backupPath }
            $backup = Read-SAUnlockBackup $path
            if ($null -eq $backup) { throw 'No backup is available.' }
            if ($backup.serial -cne $serial) { throw 'The backup belongs to another device. Restore stopped.' }
            Assert-SAUnlockBackupSlot $Context $backup
            Copy-SAUnlockProbe $Context $serial
            Restore-SAUnlockCore $Context $serial $backup
            if ($pending) { [IO.File]::Delete($recoveryPath) }
            $label = if ($pending) { 'Recovery' } else { 'Restore' }
            return "$label completed. SA user switch: $($backup.saEnabled)`nOriginal backup kept at: $backupPath"
        }
        if ($Action -eq 'enable' -and $pending) { throw 'Recovery pending. Choose Restore before unlocking again.' }
        $original = Read-SAUnlockBackup $backupPath
        if ($Action -eq 'enable' -and $null -ne $original -and $original.serial -cne $serial) {
            throw 'The backup belongs to another device. Move it somewhere safe before backing up this phone.'
        }
        if ($Action -eq 'enable' -and $null -ne $original) { Assert-SAUnlockBackupSlot $Context $original }
        Copy-SAUnlockProbe $Context $serial
        $before = Get-SAUnlockState $Context $serial
        if ($Action -eq 'status') {
            $property = Invoke-SAUnlockADB $Context @('-s', $serial, 'shell', 'getprop', 'persist.radio.sa.user.enabled')
            $shortSerial = if ($serial.Length -gt 8) { $serial.Substring(0, 4) + '...' + $serial.Substring($serial.Length - 4) } else { $serial }
            $backupLabel = if ($null -eq $original) { 'none' } else { $original.savedAt }
            $mode = if ($null -eq $before.networkMode) { 'Unknown' } else { $before.networkMode }
            $summary = @(
                "Device: $shortSerial", "Target: SIM $($Context.Slot + 1) (slot $($Context.Slot))", "SA user switch: $($before.saEnabled)",
                "SA network mode: $mode", "Visibility setting: $(Format-SAUnlockValue $before.visible)",
                "SA disabled setting: $(Format-SAUnlockValue $before.saDisabled)",
                "fiveg_network_mode: $(Format-SAUnlockValue $before.fiveGNetworkMode)",
                "dual_sa_enabled: $(Format-SAUnlockValue $before.dualSaEnabled)",
                "persist.radio.sa.user.enabled: $($property.Trim())", "Backup: $backupLabel"
            )
            if ($pending) { $summary += 'Recovery pending. Restore will recover the last operation.' }
            return $summary -join "`n"
        }
        $snapshot = [pscustomobject][ordered]@{
            serial = $serial; savedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            visible = $before.visible; saDisabled = $before.saDisabled
            fiveGNetworkMode = $before.fiveGNetworkMode; saEnabled = $before.saEnabled
            formatVersion = 2; slot = $Context.Slot; dualSaEnabled = $before.dualSaEnabled
        }
        if ($null -eq $original) { Save-SAUnlockBackup $snapshot $backupPath }
        Save-SAUnlockBackup $snapshot $recoveryPath
        try {
            Set-SAUnlockSetting $Context $serial system '5g_network_mode_selection_visiable' '1'
            Set-SAUnlockSetting $Context $serial system '5g_sa_mode_disabled' '0'
            $null = Invoke-SAUnlockProbe $Context $serial 'enable-sa'
            $after = Get-SAUnlockState $Context $serial
            if ($after.visible -cne '1' -or $after.saDisabled -cne '0' -or -not $after.saEnabled) {
                throw 'Read-back state is unexpected after enabling SA.'
            }
        } catch {
            $failure = $_.Exception.Message
            try {
                Restore-SAUnlockCore $Context $serial $snapshot
                [IO.File]::Delete($recoveryPath)
            } catch {
                throw "Unlock failed: $failure`nAutomatic rollback also failed: $($_.Exception.Message)`nRecovery snapshot kept at: $recoveryPath. Choose Restore to retry."
            }
            throw "Unlock failed: $failure`nRestored the state from before this attempt. The original backup is unchanged."
        }
        [IO.File]::Delete($recoveryPath)
        return "Unlock completed. SA user switch: Enabled`nOriginal backup kept at: $backupPath"
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function New-SAUnlockContext, Invoke-SAUnlockOperation
