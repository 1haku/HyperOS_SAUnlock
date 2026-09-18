#Requires -Version 5.1
[CmdletBinding()]
param([string]$SdkRoot, [string]$PlatformVersion = $env:ANDROID_PLATFORM,
      [string]$BuildToolsVersion = $env:ANDROID_BUILD_TOOLS)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot '../android/build.ps1') -SdkRoot $SdkRoot -PlatformVersion $PlatformVersion -BuildToolsVersion $BuildToolsVersion
$package = Join-Path $PSScriptRoot 'build/HyperOSSAUnlock-windows-powershell'
$null = New-Item -ItemType Directory -Force -Path $package
$files = @('HyperOSSAUnlock.ps1', 'SAUnlock.Core.psm1', 'ProcessRunner.cs', 'README.md', 'README.ja.md')
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $package $file) -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../android/build/sa-probe.jar') -Destination (Join-Path $package 'sa-probe.jar') -Force
$archive = Join-Path $PSScriptRoot 'build/HyperOSSAUnlock-windows-powershell.zip'
$archiveFiles = @($files + 'sa-probe.jar' | ForEach-Object { Join-Path $package $_ })
Compress-Archive -LiteralPath $archiveFiles -DestinationPath $archive -Force
Write-Host "Built: $archive"
