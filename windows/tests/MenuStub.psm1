function New-SAUnlockContext {
    param([int]$Slot, [string]$AdbPath, [string]$BackupDirectory)
    [pscustomobject]@{ BackupDirectory = $BackupDirectory; Slot = $Slot }
}
function Invoke-SAUnlockOperation {
    param($Context, [string]$Action)
    if ($Action -eq 'enable') { throw 'Simulated enable failure' }
    "TEST ACTION: $Action`nTEST SLOT: $($Context.Slot)"
}
Export-ModuleMember -Function New-SAUnlockContext, Invoke-SAUnlockOperation
