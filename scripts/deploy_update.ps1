#Requires -Version 5.1
<#
.SYNOPSIS
  Build MAX Desktop Windows installer and upload to the update server via SCP.

.EXAMPLE
  .\scripts\deploy_update.ps1
  .\scripts\deploy_update.ps1 -SkipBuild
#>
param(
  [switch]$SkipBuild,
  [string]$HostName = "145.63.130.142",
  [string]$User = "root",
  [string]$IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519",
  [string]$RemoteDir = "/var/www/max-desktop",
  [int]$HttpPort = 8080,
  [string]$Notes = "Обновление MAX Desktop"
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

$Pubspec = Get-Content (Join-Path $Root "pubspec.yaml") -Raw
if ($Pubspec -notmatch 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)') {
  throw "Cannot parse version from pubspec.yaml"
}
$AppVersion = $Matches[1]
$BuildNumber = $Matches[2]

$SetupName = "MAX-Desktop-Setup-$AppVersion.exe"
$SetupPath = Join-Path $Root "release\$SetupName"
$SshTarget = "${User}@${HostName}"
$SshArgs = @("-o", "IdentitiesOnly=yes", "-i", $IdentityFile)

Write-Host "==> Version $AppVersion+$BuildNumber" -ForegroundColor Cyan

if (-not $SkipBuild) {
  Write-Host "==> Building installer..." -ForegroundColor Cyan
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\build_windows.ps1")
  if ($LASTEXITCODE -ne 0) { throw "build_windows.ps1 failed" }
}

if (-not (Test-Path $SetupPath)) {
  throw "Installer not found: $SetupPath"
}

$DownloadUrl = "http://${HostName}:${HttpPort}/$SetupName"
$Latest = @{
  version = $AppVersion
  build = [int]$BuildNumber
  url = $DownloadUrl
  notes = $Notes
  mandatory = $false
} | ConvertTo-Json -Compress

$LatestLocal = Join-Path $env:TEMP "max-desktop-latest.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($LatestLocal, $Latest, $utf8NoBom)

Write-Host "==> Upload $SetupName via scp" -ForegroundColor Cyan
& scp @SshArgs $SetupPath "${SshTarget}:${RemoteDir}/$SetupName"
if ($LASTEXITCODE -ne 0) { throw "scp installer failed" }

& scp @SshArgs $LatestLocal "${SshTarget}:${RemoteDir}/latest.json"
if ($LASTEXITCODE -ne 0) { throw "scp latest.json failed" }

& ssh @SshArgs $SshTarget "chown www-data:www-data $RemoteDir/$SetupName $RemoteDir/latest.json; chmod 644 $RemoteDir/$SetupName $RemoteDir/latest.json; ln -sfn $SetupName $RemoteDir/MAX-Desktop-Setup-latest.exe"
if ($LASTEXITCODE -ne 0) { throw "remote chmod failed" }

Write-Host ""
Write-Host "Deployed:" -ForegroundColor Green
Write-Host "  Feed:  http://${HostName}:${HttpPort}/latest.json"
Write-Host "  Setup: $DownloadUrl"
Write-Host "  latest.json => version=$AppVersion build=$BuildNumber"
