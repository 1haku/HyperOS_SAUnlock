#Requires -Version 5.1
[CmdletBinding()]
param([string]$SdkRoot, [string]$PlatformVersion = $env:ANDROID_PLATFORM,
      [string]$BuildToolsVersion = $env:ANDROID_BUILD_TOOLS)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $SdkRoot) { $SdkRoot = $env:ANDROID_SDK_ROOT }
if (-not $SdkRoot) { $SdkRoot = $env:ANDROID_HOME }
if (-not $SdkRoot -and $env:LOCALAPPDATA) { $SdkRoot = Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
if (-not $SdkRoot) { throw 'Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK directory.' }
if (-not $PlatformVersion) {
    $platforms = @(Get-ChildItem -LiteralPath (Join-Path $SdkRoot 'platforms') -Directory |
        Where-Object { $_.Name -match '^android-[1-9][0-9]*$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'android.jar')) } |
        ForEach-Object { [int]$_.Name.Substring(8) } | Sort-Object -Descending)
    if ($platforms.Count) { $PlatformVersion = [string]$platforms[0] }
}
if ($PlatformVersion -notmatch '^[1-9][0-9]*$' -or [int]$PlatformVersion -lt 23) {
    throw 'Install a stable Android SDK Platform API 23 or newer, or specify -PlatformVersion.'
}
$d8Name = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'd8.bat' } else { 'd8' }
if (-not $BuildToolsVersion) {
    $versions = @(Get-ChildItem -LiteralPath (Join-Path $SdkRoot 'build-tools') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName $d8Name)) } |
        Sort-Object { [version]$_.Name } -Descending)
    if ($versions.Count) { $BuildToolsVersion = $versions[0].Name }
}
if ($BuildToolsVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Install stable Android Build-Tools containing d8, or specify -BuildToolsVersion.'
}
$androidJar = Join-Path $SdkRoot "platforms/android-$PlatformVersion/android.jar"
$d8 = Join-Path $SdkRoot "build-tools/$BuildToolsVersion/$d8Name"
if (-not (Test-Path -LiteralPath $androidJar) -or -not (Test-Path -LiteralPath $d8)) {
    throw "Requested Android SDK Platform $PlatformVersion or Build-Tools $BuildToolsVersion is not installed."
}
Write-Host "Using Android SDK Platform $PlatformVersion and Build-Tools $BuildToolsVersion"
$javac = (Get-Command javac -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$jar = (Get-Command jar -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$build = Join-Path $PSScriptRoot 'build'
$classes = Join-Path $build 'classes'
$dex = Join-Path $build 'dex'
$null = New-Item -ItemType Directory -Force -Path $classes, $dex
& $javac -source 8 -target 8 -classpath $androidJar -d $classes (Join-Path $PSScriptRoot 'SaProbe.java')
if ($LASTEXITCODE -ne 0) { throw 'Java compilation failed.' }
& $d8 --min-api 23 --lib $androidJar --output $dex (Join-Path $classes 'SaProbe.class')
if ($LASTEXITCODE -ne 0) { throw 'DEX compilation failed.' }
$probe = Join-Path $build 'sa-probe.jar'
& $jar cf $probe -C $dex classes.dex
if ($LASTEXITCODE -ne 0) { throw 'Probe packaging failed.' }
Write-Host "Built: $probe"
