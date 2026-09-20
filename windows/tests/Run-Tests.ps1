#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../SAUnlock.Core.psm1') -Force
$script:passed = 0
$script:failed = 0
$script:testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sa-unlock-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:testRoot

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Fails {
    param([scriptblock]$Body, [string]$Pattern)
    try { & $Body | Out-Null }
    catch {
        $message = $_.Exception.Message
        Assert-True ($message -match $Pattern) "Expected '$Pattern', got: $message"
        return $message
    }
    throw "Expected failure matching '$Pattern'."
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL ${Name}: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}
function New-Fixture {
    param([int]$Slot = 0)
    $directory = Join-Path $script:testRoot ([Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $directory
    $probe = Join-Path $directory 'probe with spaces.jar'
    [IO.File]::WriteAllText($probe, 'fixture')
    $fake = [pscustomobject]@{
        Enabled = $false; Settings = @{}; Devices = "TEST`tdevice`n"
        EnabledSlot1 = $false; DataSlot = 0
        StateOutput = $null; Override = $null; Writes = 0; Fails = 0
        Commands = (New-Object 'Collections.Generic.List[object]')
    }
    Add-Member -InputObject $fake -MemberType ScriptMethod -Name Run -Value {
        param([string[]]$Arguments)
        $this.Commands.Add($Arguments)
        $result = [pscustomobject]@{ Status = 0; Stdout = ''; Stderr = ''; Truncated = $false }
        if ($this.Override) {
            $custom = & $this.Override $this $Arguments
            if ($null -ne $custom) { return $custom }
        }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'devices') {
            $result.Stdout = "List of devices attached`n" + $this.Devices
            return $result
        }
        if ($Arguments.Count -lt 4 -or $Arguments[0] -ne '-s' -or -not $this.Devices.StartsWith($Arguments[1] + "`t")) {
            throw "Unexpected fake command: $Arguments"
        }
        if ($Arguments[2] -eq 'push') { return $result }
        if ($Arguments[2] -ne 'shell') { throw "Unexpected command: $Arguments" }
        if ($Arguments[3].Contains('app_process')) {
            $words = $Arguments[3] -split ' '
            $action = $words[-2]
            $slot = [int]$words[-1]
            if ($action -eq 'state') {
                if ($null -ne $this.StateOutput) { $result.Stdout = $this.StateOutput }
                else {
                    $enabled = if ($slot -eq 0) { $this.Enabled } else { $this.EnabledSlot1 }
                    $result.Stdout = "STATE slot=$slot`nSTATE isUserFiveGSaEnabled=$($enabled.ToString().ToLowerInvariant())`nSTATE fiveGNetworkMode=null`n"
                }
                return $result
            }
            if ($action -notin @('enable-sa', 'disable-sa')) { throw "Unknown action: $action" }
            $this.Writes++
            $enabled = $action -eq 'enable-sa'
            if ($slot -eq 0) { $this.Enabled = $enabled } else { $this.EnabledSlot1 = $enabled }
            $key = if ($slot -eq $this.DataSlot) { 'global/fiveg_network_mode' } else { 'global/dual_sa_enabled' }
            $this.Settings[$key] = if ($enabled) { '2' } else { '0' }
            return $result
        }
        if ($Arguments[3] -eq 'getprop') { $result.Stdout = '1'; return $result }
        if ($Arguments[3] -ne 'settings') { throw "Unexpected command: $Arguments" }
        $key = $Arguments[5] + '/' + $Arguments[6]
        switch ($Arguments[4]) {
            'get' {
                $result.Stdout = if ($this.Settings.ContainsKey($key)) { $this.Settings[$key] } else { 'null' }
            }
            'put' { $this.Writes++; $this.Settings[$key] = $Arguments[7] }
            'delete' { $this.Writes++; $this.Settings.Remove($key) }
            default { throw "Unknown settings operation: $Arguments" }
        }
        return $result
    }
    $runner = { param([string[]]$Arguments) $fake.Run($Arguments) }.GetNewClosure()
    $context = New-SAUnlockContext -Slot $Slot -AdbPath '/mock/adb' -BackupDirectory $directory -ProbePath $probe -Runner $runner
    [pscustomobject]@{
        Context = $context; Fake = $fake; Directory = $directory
        Backup = (Join-Path $directory "devices/54455354/slot-$Slot/backup.json"); Recovery = (Join-Path $directory "devices/54455354/slot-$Slot/recovery.json")
    }
}
function Write-Original {
    param($Fixture, [bool]$Enabled = $false, [string]$Serial = 'TEST')
    $json = @{ serial = $Serial; savedAt = 'test'; saEnabled = $Enabled } | ConvertTo-Json
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Fixture.Backup))
    [IO.File]::WriteAllText($Fixture.Backup, $json)
}
function Fail-Command {
    [pscustomobject]@{ Status = 1; Stdout = ''; Stderr = 'Injected failure'; Truncated = $false }
}

try {
    Test-Case 'status leaves phone and backups unchanged' {
        $f = New-Fixture
        $result = Invoke-SAUnlockOperation $f.Context status
        Assert-True ($result -match 'Unknown' -and $result -match 'SIM 1') 'Missing status fields'
        Assert-True ($f.Fake.Writes -eq 0 -and -not (Test-Path $f.Backup)) 'Status created backup or wrote settings'
    }
    Test-Case 'enable and restore preserve the original and delete unset keys' {
        $f = New-Fixture
        $null = Invoke-SAUnlockOperation $f.Context enable
        Assert-True ($f.Fake.Enabled -and $f.Fake.Settings['system/5g_sa_mode_disabled'] -eq '0') 'Enable failed'
        Assert-True ((Test-Path $f.Backup) -and -not (Test-Path $f.Recovery)) 'Backup lifecycle failed'
        $original = [IO.File]::ReadAllText($f.Backup)
        $null = Invoke-SAUnlockOperation $f.Context restore
        Assert-True (-not $f.Fake.Enabled -and $f.Fake.Settings.Count -eq 0) 'Restore failed'
        Assert-True ([IO.File]::ReadAllText($f.Backup) -ceq $original) 'Original backup changed'
    }
    foreach ($slot in @(0, 1)) {
        foreach ($dataSlot in @(0, 1)) {
            Test-Case "slot $slot, data slot ${dataSlot}: enable and restore" {
                $f = New-Fixture -Slot $slot
                $f.Fake.DataSlot = $dataSlot
                $f.Fake.Settings = @{ 'global/fiveg_network_mode' = '8'; 'global/dual_sa_enabled' = '9' }
                $null = Invoke-SAUnlockOperation $f.Context enable
                Assert-True ($f.Fake.Enabled -eq ($slot -eq 0) -and $f.Fake.EnabledSlot1 -eq ($slot -eq 1)) 'Wrong slot enabled'
                $saved = [IO.File]::ReadAllText($f.Backup) | ConvertFrom-Json
                Assert-True ($saved.slot -eq $slot -and $saved.formatVersion -eq 2) 'Missing slot metadata'
                $null = Invoke-SAUnlockOperation $f.Context restore
                Assert-True (-not $f.Fake.Enabled -and -not $f.Fake.EnabledSlot1) 'Wrong switch state after restore'
                Assert-True ($f.Fake.Settings.Count -eq 2 -and $f.Fake.Settings['global/fiveg_network_mode'] -eq '8' -and $f.Fake.Settings['global/dual_sa_enabled'] -eq '9') 'Mode settings not restored'
            }
        }
    }
    Test-Case 'legacy backup cannot enable or restore slot 1' {
        $f = New-Fixture -Slot 1; Write-Original $f
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'backup targets SIM 1'
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context restore } 'backup targets SIM 1'
        Assert-True ($f.Fake.Writes -eq 0) 'Wrong-slot mutation'
    }
    Test-Case 'legacy restore preserves the unrecorded secondary setting' {
        $f = New-Fixture; Write-Original $f
        $f.Fake.Settings['global/dual_sa_enabled'] = '7'
        $null = Invoke-SAUnlockOperation $f.Context restore
        Assert-True ($f.Fake.Settings.Count -eq 1 -and $f.Fake.Settings['global/dual_sa_enabled'] -eq '7') 'Legacy restore changed secondary setting'
    }
    Test-Case 'wrong slot in probe output cannot create a backup' {
        $f = New-Fixture -Slot 1
        $f.Fake.StateOutput = "STATE slot=0`nSTATE isUserFiveGSaEnabled=false"
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'slot'
        Assert-True ($f.Fake.Writes -eq 0 -and -not (Test-Path $f.Backup)) 'Wrong-slot state accepted'
    }
    Test-Case 'slot 1 failure rolls back both mode settings' {
        $f = New-Fixture -Slot 1
        $f.Fake.Settings = @{ 'global/fiveg_network_mode' = '8'; 'global/dual_sa_enabled' = '9' }
        $f.Fake.Override = { param($fake, $arguments) if ($arguments[-1].EndsWith('enable-sa 1')) { Fail-Command } }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Restored the state from before this attempt'
        Assert-True (-not $f.Fake.EnabledSlot1 -and $f.Fake.Settings.Count -eq 2 -and $f.Fake.Settings['global/dual_sa_enabled'] -eq '9') 'Secondary rollback failed'
    }
    Test-Case 'no implicit slot is used by the backend' {
        $null = Assert-Fails { New-SAUnlockContext } 'Select'
        $null = Assert-Fails { New-SAUnlockContext -Slot 2 } 'Select'
    }
    Test-Case 'repeated unlock failure restores the current state, not the original backup' {
        $f = New-Fixture
        Write-Original $f
        $original = [IO.File]::ReadAllText($f.Backup)
        $f.Fake.Enabled = $true
        $f.Fake.Settings = @{ 'system/5g_network_mode_selection_visiable' = '7'; 'system/5g_sa_mode_disabled' = '8'; 'global/fiveg_network_mode' = '9' }
        $f.Fake.Override = {
            param($fake, $arguments)
            if ($fake.Fails -eq 0 -and $arguments -contains 'put' -and $arguments -contains '5g_sa_mode_disabled') {
                $fake.Fails++; Fail-Command
            }
        }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Restored the state from before this attempt'
        Assert-True ($f.Fake.Enabled -and $f.Fake.Settings['global/fiveg_network_mode'] -eq '9') 'Wrong rollback state'
        Assert-True ($f.Fake.Settings['system/5g_network_mode_selection_visiable'] -eq '7') 'Visibility not restored'
        Assert-True ([IO.File]::ReadAllText($f.Backup) -ceq $original) 'Original backup overwritten'
    }
    Test-Case 'permission preflight stops before snapshots and writes' {
        $f = New-Fixture
        $f.Fake.Override = { param($fake, $arguments)
            if ($arguments[-1] -eq 'persist.security.adbinput') { [pscustomobject]@{ Status = 0; Stdout = '0'; Stderr = ''; Truncated = $false } }
        }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'USB debugging \(Security settings\)'
        Assert-True ($f.Fake.Writes -eq 0 -and -not (Test-Path $f.Backup)) 'Permission check changed state'
    }
    Test-Case 'permission exception leaves unchanged state without false recovery failure' {
        $f = New-Fixture
        $f.Fake.Override = { param($fake, $arguments)
            if ($arguments -contains 'put' -or $arguments -contains 'delete') { [pscustomobject]@{ Status = 0; Stdout = 'java.lang.SecurityException: android.permission.WRITE_SETTINGS'; Stderr = ''; Truncated = $false } }
        }
        $message = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'USB debugging \(Security settings\)'
        Assert-True ($message.Contains('Restored the state') -and -not (Test-Path $f.Recovery)) 'False recovery failure'
    }
    Test-Case 'pending recovery blocks the other slot on the same phone only' {
        $f = New-Fixture
        Write-Original $f
        Copy-Item $f.Backup $f.Recovery
        $other = New-SAUnlockContext -Slot 1 -AdbPath '/mock/adb' -BackupDirectory $f.Directory -ProbePath $f.Context.ProbePath -Runner $f.Context.Runner
        $null = Assert-Fails { Invoke-SAUnlockOperation $other enable } 'pending recovery on this phone'
        Assert-True ($f.Fake.Writes -eq 0) 'Other slot changed during recovery'
        $f.Fake.Devices = "OTHER`tdevice`n"
        $null = Invoke-SAUnlockOperation $other enable
    }
    Test-Case 'switching phones selects independent backups' {
        $f = New-Fixture
        $null = Invoke-SAUnlockOperation $f.Context enable
        $first = [IO.File]::ReadAllText($f.Backup)
        $f.Fake.Devices = "OTHER`tdevice`n"
        $f.Fake.Enabled = $false
        $f.Fake.Settings = @{}
        $null = Invoke-SAUnlockOperation $f.Context enable
        $null = Invoke-SAUnlockOperation $f.Context restore
        Assert-True (-not $f.Fake.Enabled -and $f.Fake.Settings.Count -eq 0) 'Other device restore failed'
        Assert-True ([IO.File]::ReadAllText($f.Backup) -ceq $first) 'First device backup overwritten'
    }
    Test-Case 'device and slot backups coexist and preserve a legacy device' {
        $f = New-Fixture
        [IO.File]::WriteAllText((Join-Path $f.Directory 'backup.json'), (@{serial='OTHER';savedAt='old';saEnabled=$false} | ConvertTo-Json))
        $null = Invoke-SAUnlockOperation $f.Context enable
        $first = [IO.File]::ReadAllText($f.Backup)
        $other = New-SAUnlockContext -Slot 1 -AdbPath '/mock/adb' -BackupDirectory $f.Directory -ProbePath $f.Context.ProbePath -Runner $f.Context.Runner
        $null = Invoke-SAUnlockOperation $other enable
        Assert-True ([IO.File]::ReadAllText($f.Backup) -ceq $first) 'Original slot overwritten'
        Assert-True (Test-Path (Join-Path $f.Directory 'devices/4f54484552/slot-0/backup.json')) 'Legacy backup lost'
        $null = Invoke-SAUnlockOperation $other restore
        $null = Invoke-SAUnlockOperation $f.Context restore
        Assert-True (-not $f.Fake.Enabled -and -not $f.Fake.EnabledSlot1 -and $f.Fake.Settings.Count -eq 0) 'Reverse restore failed'
    }
    Test-Case 'partial rollback survives reopening and blocks further unlocks' {
        $f = New-Fixture
        Write-Original $f
        $f.Fake.Enabled = $true
        $f.Fake.Settings['global/fiveg_network_mode'] = '2'
        $f.Fake.Override = {
            param($fake, $arguments)
            if ($arguments[-1].EndsWith('enable-sa 0')) { $fake.Enabled = $false; Fail-Command }
        }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Automatic rollback also failed'
        Assert-True ((Test-Path $f.Recovery) -and $f.Fake.Settings.Count -eq 1) 'Recovery lost or remaining settings not restored'
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Recovery pending'
        $f.Fake.Override = $null
        $reopened = New-SAUnlockContext -Slot 0 -AdbPath '/mock/adb' -BackupDirectory $f.Directory -ProbePath $f.Context.ProbePath -Runner $f.Context.Runner
        $status = Invoke-SAUnlockOperation $reopened status
        Assert-True ($status -match 'Recovery pending') 'Pending recovery not shown'
        $null = Invoke-SAUnlockOperation $reopened restore
        Assert-True ($f.Fake.Enabled -and -not (Test-Path $f.Recovery)) 'Pre-attempt snapshot not restored'
        $null = Invoke-SAUnlockOperation $reopened restore
        Assert-True (-not $f.Fake.Enabled -and $f.Fake.Settings.Count -eq 0) 'Original backup no longer restores'
    }
    Test-Case 'restore continues all writes and checks after separate failures' {
        $f = New-Fixture
        Write-Original $f
        $f.Fake.Enabled = $true
        $f.Fake.Settings = @{ 'system/5g_network_mode_selection_visiable' = '1'; 'system/5g_sa_mode_disabled' = '0'; 'global/fiveg_network_mode' = '2' }
        $f.Fake.Override = {
            param($fake, $arguments)
            if (($arguments -contains 'delete' -and $arguments -contains '5g_sa_mode_disabled') -or
                ($arguments -contains 'get' -and $arguments -contains '5g_network_mode_selection_visiable')) { Fail-Command }
        }
        $message = Assert-Fails { Invoke-SAUnlockOperation $f.Context restore } 'Restore incomplete'
        Assert-True (-not $f.Fake.Settings.ContainsKey('global/fiveg_network_mode')) 'Later write skipped'
        Assert-True ($message -match 'Verified:.*fiveg_network_mode' -and $message -match 'verification:') 'Missing verification details'
        $f.Fake.Override = $null
        $null = Invoke-SAUnlockOperation $f.Context restore
        Assert-True ($f.Fake.Settings.Count -eq 0) 'Retry failed'
    }
    foreach ($state in @('unavailable', 'TRUE', 'STATE isUserFiveGSaEnabled=true')) {
        Test-Case "invalid state is rejected: $state" {
            $f = New-Fixture
            $f.Fake.StateOutput = "STATE isUserFiveGSaEnabled=$state"
            $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Invalid'
            Assert-True ($f.Fake.Writes -eq 0 -and -not (Test-Path $f.Backup)) 'Invalid state used as backup'
        }
    }
    foreach ($state in @('STATE fiveGNetworkMode=null', "STATE isUserFiveGSaEnabled=false`nSTATE isUserFiveGSaEnabled=true")) {
        Test-Case 'missing or duplicate SA state cannot create a backup' {
            $f = New-Fixture; $f.Fake.StateOutput = $state
            $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'parse|duplicate'
            Assert-True ($f.Fake.Writes -eq 0 -and -not (Test-Path $f.Backup)) 'Invalid state backed up'
        }
    }
    Test-Case 'stderr is not an authoritative state source' {
        $f = New-Fixture
        $f.Fake.Override = {
            param($fake, $arguments)
            if ($arguments[-1].EndsWith('SaProbe state 0')) {
                [pscustomobject]@{ Status = 0; Stdout = ''; Stderr = 'STATE isUserFiveGSaEnabled=false'; Truncated = $false }
            }
        }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Could not parse'
        Assert-True ($f.Fake.Writes -eq 0) 'Accepted stderr state'
    }
    Test-Case 'successful command with unchanged state triggers rollback' {
        $f = New-Fixture
        $f.Fake.Override = {
            param($fake, $arguments)
            if ($arguments[-1].EndsWith('enable-sa 0')) {
                [pscustomobject]@{ Status = 0; Stdout = 'ok'; Stderr = ''; Truncated = $false }
            }
        }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Read-back state'
        Assert-True (-not $f.Fake.Enabled -and $f.Fake.Settings.Count -eq 0) 'Partial changes remain'
    }
    Test-Case 'timeout or USB failure during enable triggers rollback' {
        $f = New-Fixture
        $f.Fake.Override = { param($fake, $arguments) if ($arguments[-1].EndsWith('enable-sa 0')) { throw 'ADB command timed out.' } }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'timed out.*|Restored'
        Assert-True (-not $f.Fake.Enabled -and $f.Fake.Settings.Count -eq 0) 'Timeout left partial state'
    }
    Test-Case 'disconnect during enable and rollback keeps recovery snapshot' {
        $f = New-Fixture
        $f.Fake.Override = {
            param($fake, $arguments)
            if ($arguments[-1].EndsWith('enable-sa 0')) { $fake.Fails++ }
            if ($fake.Fails -gt 0) { throw 'USB disconnected' }
        }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Recovery snapshot kept'
        Assert-True (Test-Path $f.Recovery) 'Recovery file lost'
        $f.Fake.Override = $null
        $null = Invoke-SAUnlockOperation $f.Context restore
        Assert-True ($f.Fake.Settings.Count -eq 0) 'Reconnect recovery failed'
    }
    Test-Case 'wrong-device backup blocks all mutations' {
        $f = New-Fixture; Write-Original $f -Serial OTHER
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'another device'
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context restore } 'another device'
        Assert-True ($f.Fake.Writes -eq 0) 'Wrong-device mutation'
    }
    foreach ($devices in @('', "TEST`tunauthorized`n", "TEST`tdevice`nOTHER`tdevice`n")) {
        Test-Case 'missing, unauthorized or multiple devices stop before push' {
            $f = New-Fixture; $f.Fake.Devices = $devices
            $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'device|Device'
            Assert-True ($f.Fake.Commands.Count -eq 1) 'Sent commands without an unambiguous device'
        }
    }
    foreach ($json in @('{broken', '{"serial":"TEST","savedAt":"test","saEnabled":"false"}',
                        '{"serial":"TEST","savedAt":"test","saEnabled":false,"visible":"1; reboot"}')) {
        Test-Case 'damaged or malicious backup is rejected before writes' {
            $f = New-Fixture; $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f.Backup)); [IO.File]::WriteAllText($f.Backup, $json)
            $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context restore } 'Could not read backup'
            Assert-True ($f.Fake.Writes -eq 0) 'Invalid backup executed'
        }
    }
    Test-Case 'truncated ADB output is rejected' {
        $f = New-Fixture
        $f.Fake.Override = { param($fake, $arguments) [pscustomobject]@{ Status = 0; Stdout = ''; Stderr = ''; Truncated = $true } }
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'capture limit'
        Assert-True ($f.Fake.Writes -eq 0) 'Used truncated output'
    }
    Test-Case 'invalid settings output cannot become a rollback snapshot' {
        $f = New-Fixture
        $f.Fake.Settings['system/5g_sa_mode_disabled'] = 'Permission denied'
        $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Invalid setting read-back'
        Assert-True ($f.Fake.Writes -eq 0 -and -not (Test-Path $f.Backup)) 'Invalid settings accepted'
    }
    Test-Case 'concurrent operation cannot replace a pending snapshot' {
        $f = New-Fixture
        $lock = [IO.File]::Open((Join-Path $f.Directory 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try { $null = Assert-Fails { Invoke-SAUnlockOperation $f.Context enable } 'Cannot lock' }
        finally { $lock.Dispose() }
        Assert-True ($f.Fake.Writes -eq 0) 'Lock ignored'
    }
    Test-Case 'unwritable backup path stops before phone changes' {
        $f = New-Fixture
        $context = $f.Context
        $context.BackupDirectory = Join-Path $context.ProbePath 'backup'
        $null = Assert-Fails { Invoke-SAUnlockOperation $context enable } '.'
        Assert-True ($f.Fake.Writes -eq 0) 'Wrote before saving'
    }

    $hostExecutable = (Get-Process -Id $PID).Path
    $child = Join-Path $PSScriptRoot 'Child.ps1'
    Test-Case 'runner preserves exit code and separate output streams' {
        $result = [HyperOSSAUnlock.ProcessRunner]::Run($hostExecutable, @('-NoProfile', '-File', $child, 'exit'), 10000)
        Assert-True ($result.Status -eq 7 -and $result.Stdout -ceq 'out' -and $result.Stderr -ceq 'err') 'Lost exit code or streams'
    }
    Test-Case 'runner drains both streams and bounds captured output' {
        $result = [HyperOSSAUnlock.ProcessRunner]::Run($hostExecutable, @('-NoProfile', '-File', $child, 'flood'), 15000)
        Assert-True ($result.Status -eq 0 -and $result.Truncated) 'Flood did not complete'
        Assert-True ($result.Stdout.Length -eq 1048576 -and $result.Stderr.Length -eq 1048576) 'Output was not bounded'
    }
    Test-Case 'runner times out a stalled child' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $null = Assert-Fails { [HyperOSSAUnlock.ProcessRunner]::Run($hostExecutable, @('-NoProfile', '-File', $child, 'sleep'), 500) } 'timed out'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 5) 'Timeout not bounded'
    }
    Test-Case 'runner preserves spaces, quotes, backslashes and shell metacharacters' {
        $values = @('C:\path with spaces\', 'a"b', 'a\"b', 'one&two;three', '$(not-executed)', 'plain')
        $result = [HyperOSSAUnlock.ProcessRunner]::Run($hostExecutable, (@('-NoProfile', '-File', $child, 'args') + $values), 10000)
        Assert-True ($result.Status -eq 0) $result.Stderr
        # PowerShell 5.1 emits a JSON array as one pipeline object; @(...)
        # would wrap it in another array. Direct assignment works in both versions.
        $actual = ConvertFrom-Json -InputObject $result.Stdout
        Assert-True ($actual.Count -eq $values.Count) "Expected $($values.Count) arguments, got $($actual.Count). Child JSON: $($result.Stdout)"
        for ($i = 0; $i -lt $values.Count; $i++) { Assert-True ($actual[$i] -ceq $values[$i]) "Argument $i changed" }
        Assert-True ([HyperOSSAUnlock.ProcessRunner]::QuoteArgument('') -ceq '""') 'Empty argument escaping failed'
    }
    Test-Case 'missing executable fails visibly' {
        $null = Assert-Fails { [HyperOSSAUnlock.ProcessRunner]::Run((Join-Path $script:testRoot 'missing.exe'), @(), 1000) } '.'
    }
    Test-Case 'menu displays all actions and exits on end of input without ADB' {
        $entry = Join-Path $PSScriptRoot '../HyperOSSAUnlock.ps1'
        $result = [HyperOSSAUnlock.ProcessRunner]::Run($hostExecutable, @('-NoProfile', '-File', $entry), 15000)
        Assert-True ($result.Status -eq 0) $result.Stderr
        foreach ($label in @('1. Check Status', '2. Unlock (Backup)', '3. Restore', '0. Exit')) {
            Assert-True ($result.Stdout.Contains($label)) "Missing menu item: $label"
        }
    }
    Test-Case 'menu routes choices and remains usable after an operation fails' {
        $menuDirectory = Join-Path $script:testRoot 'menu-test'
        $null = New-Item -ItemType Directory -Path $menuDirectory
        $entry = Join-Path $menuDirectory 'HyperOSSAUnlock.ps1'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../HyperOSSAUnlock.ps1') -Destination $entry
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'MenuStub.psm1') -Destination (Join-Path $menuDirectory 'SAUnlock.Core.psm1')
        $process = New-Object Diagnostics.Process
        $process.StartInfo.FileName = $hostExecutable
        $process.StartInfo.Arguments = '-NoProfile -File ' + [HyperOSSAUnlock.ProcessRunner]::QuoteArgument($entry)
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        try {
            $null = $process.Start()
            $output = $process.StandardOutput.ReadToEndAsync()
            $errors = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine("invalid`n1`n4`n2`n1`n2`n3`n0")
            $process.StandardInput.Close()
            Assert-True ($process.WaitForExit(15000)) 'Menu did not exit'
            Assert-True ($output.Wait(1000) -and $errors.Wait(1000)) 'Menu output did not close'
            Assert-True ($process.ExitCode -eq 0) $errors.Result
            foreach ($text in @('Enter 0, 1, 2, 3 or 4.', 'Select a SIM slot first', 'TEST SLOT: 1', 'TEST ACTION: status', 'Simulated enable failure', 'TEST ACTION: restore')) {
                Assert-True ($output.Result.Contains($text)) "Menu missing: $text"
            }
        } finally {
            if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(1000) }
            $process.Dispose()
        }
    }
    Test-Case 'all scripts use syntax accepted by the PowerShell parser' {
        foreach ($file in (Get-ChildItem (Join-Path $PSScriptRoot '..') -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) "Parse failed: $($file.Name): $errors"
        }
    }
} finally {
    Remove-Item -LiteralPath $script:testRoot -Recurse -Force
}
Write-Host "$script:passed passed; $script:failed failed"
if ($script:failed -ne 0) { exit 1 }
