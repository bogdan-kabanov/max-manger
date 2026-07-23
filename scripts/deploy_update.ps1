#Requires -Version 5.1
<#
.SYNOPSIS
  Build MAX Desktop Windows installer and publish to the update server.

  Prefers HTTP upload (token in scripts/.deploy_secrets) — no interactive SSH.
  Falls back to SCP with the dedicated deploy key if HTTP is unavailable.

.EXAMPLE
  .\scripts\deploy_update.ps1
  .\scripts\deploy_update.ps1 -SkipBuild
#>
param(
  [switch]$SkipBuild,
  [string]$HostName = "145.63.130.142",
  [string]$User = "root",
  [string]$IdentityFile = "$env:USERPROFILE\.ssh\max_desktop_deploy",
  [string]$RemoteDir = "/var/www/max-desktop",
  [int]$HttpPort = 8080,
  [string]$Notes = "Обновление MAX Desktop"
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

function Read-DeploySecrets {
  $path = Join-Path $PSScriptRoot ".deploy_secrets"
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  Get-Content $path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
    $k, $v = $_.Split('=', 2)
    $map[$k.Trim()] = $v.Trim()
  }
  return $map
}

$Pubspec = Get-Content (Join-Path $Root "pubspec.yaml") -Raw
if ($Pubspec -notmatch 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)') {
  throw "Cannot parse version from pubspec.yaml"
}
$AppVersion = $Matches[1]
$BuildNumber = $Matches[2]

$SetupName = "MAX-Desktop-Setup-$AppVersion.exe"
$SetupPath = Join-Path $Root "release\$SetupName"
$Secrets = Read-DeploySecrets
if ($Secrets.ContainsKey("MAX_UPDATE_HOST") -and $Secrets["MAX_UPDATE_HOST"]) {
  $HostName = $Secrets["MAX_UPDATE_HOST"]
}
$UploadUrl = if ($Secrets.ContainsKey("MAX_UPDATE_UPLOAD_URL") -and $Secrets["MAX_UPDATE_UPLOAD_URL"]) {
  $Secrets["MAX_UPDATE_UPLOAD_URL"]
} else {
  "http://${HostName}:${HttpPort}/_deploy/upload"
}
$DeployToken = $env:MAX_DEPLOY_TOKEN
if (-not $DeployToken -and $Secrets.ContainsKey("MAX_DEPLOY_TOKEN")) {
  $DeployToken = $Secrets["MAX_DEPLOY_TOKEN"]
}
if ($Secrets.ContainsKey("MAX_DEPLOY_KEY") -and (Test-Path $Secrets["MAX_DEPLOY_KEY"])) {
  $IdentityFile = $Secrets["MAX_DEPLOY_KEY"]
}

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
$LatestObj = [ordered]@{
  version   = $AppVersion
  build     = [int]$BuildNumber
  url       = $DownloadUrl
  notes     = $Notes
  mandatory = $false
}
$LatestJson = ($LatestObj | ConvertTo-Json -Compress)
# HttpWebRequest headers must be ASCII — escape non-ASCII in notes.
$LatestJsonAscii = [regex]::Replace($LatestJson, '[^\x00-\x7F]', {
    param($m) ('\u{0:X4}' -f [int][char]$m.Value)
  })

function Publish-ViaHttp {
  if (-not $DeployToken) {
    throw "No MAX_DEPLOY_TOKEN (run scripts/bootstrap_update_deploy.py once)"
  }
  $uri = "$UploadUrl" + $(if ($UploadUrl -match '\?') { '&' } else { '?' }) + "name=$([uri]::EscapeDataString($SetupName))"
  Write-Host "==> HTTP upload $SetupName" -ForegroundColor Cyan
  Write-Host "    $uri"

  $bytes = [System.IO.File]::ReadAllBytes($SetupPath)
  $req = [System.Net.HttpWebRequest]::Create($uri)
  $req.Method = "POST"
  $req.Timeout = 600000
  $req.ReadWriteTimeout = 600000
  $req.ContentType = "application/octet-stream"
  $req.ContentLength = $bytes.Length
  $req.Headers.Add("Authorization", "Bearer $DeployToken")
  $req.Headers.Add("X-Latest-Json", $LatestJsonAscii)

  $stream = $req.GetRequestStream()
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Close()

  try {
    $resp = $req.GetResponse()
  } catch [System.Net.WebException] {
    $errResp = $_.Exception.Response
    if ($errResp -ne $null) {
      $reader = New-Object System.IO.StreamReader($errResp.GetResponseStream())
      $body = $reader.ReadToEnd()
      throw "HTTP upload failed: $($errResp.StatusCode) $body"
    }
    throw
  }
  $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
  $body = $reader.ReadToEnd()
  $resp.Close()
  Write-Host "    response: $body"
  if ($body -notmatch '"ok"\s*:\s*true') {
    throw "HTTP upload rejected: $body"
  }
}

function Publish-ViaScp {
  if (-not (Test-Path $IdentityFile)) {
    throw "Deploy key missing: $IdentityFile (run bootstrap_update_deploy.py)"
  }
  $SshTarget = "${User}@${HostName}"
  $SshArgs = @(
    "-o", "BatchMode=yes",
    "-o", "IdentitiesOnly=yes",
    "-o", "ConnectTimeout=20",
    "-o", "StrictHostKeyChecking=accept-new",
    "-i", $IdentityFile
  )
  $LatestLocal = Join-Path $env:TEMP "max-desktop-latest.json"
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($LatestLocal, $LatestJson, $utf8NoBom)

  Write-Host "==> SCP upload $SetupName (fallback)" -ForegroundColor Yellow
  & scp @SshArgs $SetupPath "${SshTarget}:${RemoteDir}/$SetupName"
  if ($LASTEXITCODE -ne 0) { throw "scp installer failed" }
  & scp @SshArgs $LatestLocal "${SshTarget}:${RemoteDir}/latest.json"
  if ($LASTEXITCODE -ne 0) { throw "scp latest.json failed" }
  & ssh @SshArgs $SshTarget "chown www-data:www-data $RemoteDir/$SetupName $RemoteDir/latest.json; chmod 644 $RemoteDir/$SetupName $RemoteDir/latest.json; ln -sfn $SetupName $RemoteDir/MAX-Desktop-Setup-latest.exe"
  if ($LASTEXITCODE -ne 0) { throw "remote chmod failed" }
}

$published = $false
if ($DeployToken) {
  try {
    Publish-ViaHttp
    $published = $true
  } catch {
    Write-Host "HTTP publish failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Trying SCP fallback..." -ForegroundColor Yellow
  }
}

if (-not $published) {
  Publish-ViaScp
}

Write-Host ""
Write-Host "Deployed:" -ForegroundColor Green
Write-Host "  Feed:  http://${HostName}:${HttpPort}/latest.json"
Write-Host "  Setup: $DownloadUrl"
Write-Host "  latest.json => version=$AppVersion build=$BuildNumber"
