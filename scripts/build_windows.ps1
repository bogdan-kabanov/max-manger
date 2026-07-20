#Requires -Version 5.1
<#
.SYNOPSIS
  Builds MAX Desktop for Windows and creates Setup.exe + portable zip.

.EXAMPLE
  .\scripts\build_windows.ps1
#>
param(
  [string]$NodeVersion = "22.16.0",
  [switch]$SkipFlutterBuild,
  [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

$Pubspec = Get-Content (Join-Path $Root "pubspec.yaml") -Raw
if ($Pubspec -notmatch 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
  throw "Cannot read version from pubspec.yaml"
}
$AppVersion = $Matches[1]

$ReleaseDir = Join-Path $Root "release"
$AppDir = Join-Path $ReleaseDir "app"
$CacheDir = Join-Path $Root ".cache"
$FlutterRelease = Join-Path $Root "build\windows\x64\runner\Release"

Write-Host "==> MAX Desktop $AppVersion - Windows package" -ForegroundColor Cyan

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
  Ensure-Dir $Destination
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

# --- Flutter build ---
if (-not $SkipFlutterBuild) {
  Write-Host "==> flutter pub get" -ForegroundColor Cyan
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

  Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }
}

if (-not (Test-Path (Join-Path $FlutterRelease "max_desktop.exe"))) {
  throw "Release exe not found: $FlutterRelease\max_desktop.exe"
}

# --- Auth CLI deps ---
$AuthDir = Join-Path $Root "tools\max_auth"
if (-not (Test-Path (Join-Path $AuthDir "node_modules"))) {
  Write-Host "==> npm install in tools/max_auth" -ForegroundColor Cyan
  Push-Location $AuthDir
  try {
    npm install --omit=dev
    if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
  } finally {
    Pop-Location
  }
}

# --- Portable Node ---
Ensure-Dir $CacheDir
$NodeZipName = "node-v$NodeVersion-win-x64.zip"
$NodeZip = Join-Path $CacheDir $NodeZipName
$NodeExtracted = Join-Path $CacheDir "node-v$NodeVersion-win-x64"

if (-not (Test-Path (Join-Path $NodeExtracted "node.exe"))) {
  if (-not (Test-Path $NodeZip)) {
    $Url = "https://nodejs.org/dist/v$NodeVersion/$NodeZipName"
    Write-Host "==> Download Node.js $NodeVersion" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $NodeZip
  }
  Write-Host "==> Extract Node.js" -ForegroundColor Cyan
  if (Test-Path $NodeExtracted) { Remove-Item $NodeExtracted -Recurse -Force }
  Expand-Archive -Path $NodeZip -DestinationPath $CacheDir -Force
}

# --- Stage app folder ---
Write-Host "==> Stage release/app" -ForegroundColor Cyan
if (Test-Path $AppDir) { Remove-Item $AppDir -Recurse -Force }
Ensure-Dir $AppDir
Copy-DirectoryContents $FlutterRelease $AppDir

$ToolsOut = Join-Path $AppDir "tools"
$AuthOut = Join-Path $ToolsOut "max_auth"
$NodeOut = Join-Path $ToolsOut "node"
Ensure-Dir $AuthOut
Ensure-Dir $NodeOut

Get-ChildItem $AuthDir -File | ForEach-Object {
  Copy-Item $_.FullName -Destination $AuthOut -Force
}
if (Test-Path (Join-Path $AuthDir "node_modules")) {
  Copy-Item (Join-Path $AuthDir "node_modules") -Destination $AuthOut -Recurse -Force
}

Copy-Item (Join-Path $NodeExtracted "node.exe") -Destination $NodeOut -Force
foreach ($extra in @("LICENSE", "README.md")) {
  $p = Join-Path $NodeExtracted $extra
  if (Test-Path $p) { Copy-Item $p -Destination $NodeOut -Force }
}

# --- Portable zip ---
Ensure-Dir $ReleaseDir
$ZipPath = Join-Path $ReleaseDir "MAX-Desktop-Portable-$AppVersion.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Write-Host "==> Portable zip" -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $AppDir "*") -DestinationPath $ZipPath -CompressionLevel Optimal

# --- Inno Setup installer ---
$SetupPath = Join-Path $ReleaseDir "MAX-Desktop-Setup-$AppVersion.exe"
if (-not $SkipInstaller) {
  function Find-ISCC {
    $candidates = @(
      "${env:LocalAppData}\Programs\Inno Setup 6\ISCC.exe",
      "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
      "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
      (Join-Path $CacheDir "innosetup\ISCC.exe")
    )
    foreach ($c in $candidates) {
      if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
  }

  $Iscc = Find-ISCC
  if (-not $Iscc) {
    Write-Host "==> Download Inno Setup 6" -ForegroundColor Cyan
    $InnoSetup = Join-Path $CacheDir "innosetup-6.exe"
    if (-not (Test-Path $InnoSetup) -or ((Get-Item $InnoSetup).Length -lt 1MB)) {
      $InnoUrl = "https://github.com/jrsoftware/issrc/releases/download/is-6_4_3/innosetup-6.4.3.exe"
      Invoke-WebRequest -Uri $InnoUrl -OutFile $InnoSetup
    }
    $InnoDir = Join-Path $CacheDir "innosetup"
    Ensure-Dir $InnoDir
    Write-Host "==> Install Inno Setup into .cache" -ForegroundColor Cyan
    $proc = Start-Process -FilePath $InnoSetup -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART","/DIR=`"$InnoDir`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 1) {
      Write-Warning "Inno Setup installer exit code: $($proc.ExitCode)"
    }
    $Iscc = Find-ISCC
  }

  if ($Iscc) {
    Write-Host "==> Compile Setup.exe ($Iscc)" -ForegroundColor Cyan
    $Iss = Join-Path $Root "installer\max_desktop.iss"
    & $Iscc "/DMyAppVersion=$AppVersion" "/DMyAppSource=$AppDir" $Iss
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
  } else {
    Write-Warning "ISCC not found - Setup.exe skipped. Portable zip is ready."
  }
}

Write-Host ""
Write-Host "Done:" -ForegroundColor Green
Write-Host "  App folder: $AppDir"
Write-Host "  Portable:   $ZipPath"
if (Test-Path $SetupPath) {
  Write-Host "  Installer:  $SetupPath"
  Write-Host ""
  Write-Host "Give user: MAX-Desktop-Setup-$AppVersion.exe" -ForegroundColor Green
} else {
  Write-Host ""
  Write-Host "Give user the zip - extract and run max_desktop.exe" -ForegroundColor Yellow
}
