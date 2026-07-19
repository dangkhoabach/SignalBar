# =============================================================================
# Builds + signs the Windows release: NSIS/MSI installer plus the matching
# updater artifact (.nsis.zip or .msi.zip) + .sig. Run this ON the Windows
# machine after `git pull` — Tauri's Windows installer bundlers (NSIS/WiX)
# and the ring/rustls C build only work on native Windows; this cannot be
# cross-compiled from macOS (verified: `cargo check` fails on both the msvc
# and gnu targets from macOS without a full Windows C toolchain).
#
# Usage: powershell -ExecutionPolicy Bypass -File release\build-windows.ps1
#
# Prerequisites (one-time, same as any Tauri Windows dev setup):
#   - Node.js, Rust (rustup), Visual Studio Build Tools (C++ workload)
#   - release\.env.release with TAURI_SIGNING_PRIVATE_KEY and
#     TAURI_SIGNING_PRIVATE_KEY_PASSWORD, AND the private key file itself
#     copied onto this machine. Same signing keypair as macOS (the public
#     half is already embedded in tauri.conf.json) — see release/README.md.
#
# After it finishes, upload the 3 output files through the "Publish new app" /
# "Republish" dialog at admin.dangkhoabach.vn (Windows (x64) row): installer =
# the .exe/.msi, updater bundle = the .nsis.zip/.msi.zip, signature = .sig.
# That admin panel builds latest.json/app.json itself — nothing here uploads
# anything.
#
# NOT verified end-to-end: written and reviewed carefully, but there is no
# Windows machine available in the environment that wrote this to actually
# run it. Sanity-check the first real run, especially the installer/updater
# filename globs below if Tauri's actual output differs from what's assumed.
# =============================================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

$EnvFile = Join-Path $RootDir ".env.release"
if (-not (Test-Path $EnvFile)) {
    Write-Error "Error: $EnvFile not found (needed to sign the updater artifacts). See release/README.md."
    exit 1
}

Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#") -or -not $line.Contains("=")) { return }
    $parts = $line -split "=", 2
    $key = $parts[0].Trim()
    $value = $parts[1].Trim()
    [Environment]::SetEnvironmentVariable($key, $value, "Process")
}

$packageJson = Get-Content (Join-Path $RootDir "package.json") -Raw | ConvertFrom-Json
$Version = $packageJson.version

Write-Host "===> [Windows] Building v$Version ..."
Push-Location $RootDir
try {
    npm run tauri build
    if ($LASTEXITCODE -ne 0) {
        throw "tauri build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$BundleDir = Join-Path $RootDir "src-tauri\target\release\bundle"
$OutDir = Join-Path $ScriptDir "output\$Version\windows"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Installer = $null
$UpdaterArtifact = $null

$NsisDir = Join-Path $BundleDir "nsis"
if (Test-Path $NsisDir) {
    $Installer = Get-ChildItem $NsisDir -Filter "*-setup.exe" | Select-Object -First 1
    $UpdaterArtifact = Get-ChildItem $NsisDir -Filter "*.nsis.zip" | Select-Object -First 1
}
if (-not $Installer) {
    $MsiDir = Join-Path $BundleDir "msi"
    if (Test-Path $MsiDir) {
        $Installer = Get-ChildItem $MsiDir -Filter "*.msi" | Select-Object -First 1
        $UpdaterArtifact = Get-ChildItem $MsiDir -Filter "*.msi.zip" | Select-Object -First 1
    }
}

if ((-not $Installer) -or (-not $UpdaterArtifact)) {
    Write-Error "Error: could not find the built installer/updater artifact under $BundleDir. Check the tauri build output above for the actual bundle paths and adjust the filename globs in this script if they differ."
    exit 1
}

$SigPath = "$($UpdaterArtifact.FullName).sig"
if (-not (Test-Path $SigPath)) {
    Write-Error "Error: expected signature file not found: $SigPath"
    exit 1
}

Copy-Item $Installer.FullName -Destination (Join-Path $OutDir $Installer.Name)
Copy-Item $UpdaterArtifact.FullName -Destination (Join-Path $OutDir $UpdaterArtifact.Name)
Copy-Item $SigPath -Destination (Join-Path $OutDir "$($UpdaterArtifact.Name).sig")

Write-Host "  Windows build ready -> $OutDir"
Write-Host "    - $($Installer.Name)         -> Installer file"
Write-Host "    - $($UpdaterArtifact.Name)   -> Updater bundle"
Write-Host "    - $($UpdaterArtifact.Name).sig -> Signature (.sig)"
Write-Host "  Upload all 3 at admin.dangkhoabach.vn, Windows (x64) row."
