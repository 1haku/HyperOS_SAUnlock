#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('menu', 'status', 'enable', 'restore')][string]$Action = 'menu',
    [ValidateSet(0, 1)][int]$Slot,
    [string]$AdbPath,
    [string]$BackupDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SAUnlock.Core.psm1') -Force
$selectedSlot = if ($PSBoundParameters.ContainsKey('Slot')) { $Slot } else { $null }

function Invoke-Selection {
    param([string]$SelectedAction)
    if ($null -eq $selectedSlot) { throw 'Select a SIM slot first, or use -Slot 0 or -Slot 1.' }
    $context = New-SAUnlockContext -Slot $selectedSlot -AdbPath $AdbPath -BackupDirectory $BackupDirectory
    Invoke-SAUnlockOperation $context $SelectedAction
}

function Read-MenuInput {
    param([string]$Prompt)
    if ([Console]::IsInputRedirected) {
        Write-Host ($Prompt + ': ') -NoNewline
        return [Console]::ReadLine()
    }
    return Read-Host $Prompt
}

if ($Action -ne 'menu') {
    try { Write-Output (Invoke-Selection $Action); exit 0 }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
}

while ($true) {
    Write-Host ''
    Write-Host 'HyperOS_SAUnlock' -ForegroundColor Cyan
    if ($null -eq $selectedSlot) { Write-Host 'Target: not selected' }
    else { Write-Host "Target: SIM $($selectedSlot + 1) (slot $selectedSlot)" }
    Write-Host ''
    Write-Host '  1. Check Status'
    Write-Host '  2. Unlock (Backup)'
    Write-Host '  3. Restore'
    Write-Host '  4. Select SIM slot'
    Write-Host '  0. Exit'
    Write-Host ''
    $selection = Read-MenuInput 'Select [0-4]'
    if ($null -eq $selection -or $selection -eq '0') { break }
    if ($selection -eq '4') {
        $choice = Read-MenuInput 'SIM 1 (slot 0) or SIM 2 (slot 1)? Enter 1 or 2'
        if ($null -eq $choice) { break }
        if ($choice -in @('1', '2')) { $selectedSlot = [int]$choice - 1 }
        else { Write-Host 'Enter 1 or 2.' -ForegroundColor Yellow }
        continue
    }
    $selectedAction = switch ($selection) { '1' { 'status' }; '2' { 'enable' }; '3' { 'restore' } }
    if (-not $selectedAction) { Write-Host 'Enter 0, 1, 2, 3 or 4.' -ForegroundColor Yellow; continue }
    Write-Host 'Running...'
    try { Write-Host (Invoke-Selection $selectedAction) -ForegroundColor Green }
    catch { Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red }
}
