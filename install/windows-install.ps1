$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$info = Get-Content -LiteralPath (Join-Path $scriptRoot 'BUILD-INFO.json') -Raw | ConvertFrom-Json
$packageDirectory = Join-Path $scriptRoot 'codex-package'
$target = 'x86_64-pc-windows-msvc'
if ($info.target -ne $target -or -not [Environment]::Is64BitOperatingSystem) {
    throw "This package requires Windows x64. Package target: $($info.target)."
}
if (-not (Test-Path -LiteralPath (Join-Path $scriptRoot 'SHA256SUMS') -PathType Leaf)) {
    throw 'Package SHA256SUMS file not found.'
}
foreach ($line in Get-Content -LiteralPath (Join-Path $scriptRoot 'SHA256SUMS')) {
    if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') { throw 'Invalid package checksum entry.' }
    $relativePath = $Matches[2].Replace('/', '\')
    $path = Join-Path $scriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Matches[1]) {
        throw "Package checksum validation failed: $relativePath"
    }
}

$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) { throw 'npm.cmd was not found. Install or update Codex with npm first.' }
$npmRoot = (& $npm.Source root -g | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or -not $npmRoot) { throw 'Could not locate the global npm directory.' }

$version = [string]$info.codexVersion
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$cliRoot = Join-Path $npmRoot '@openai\codex'
$platformRoot = Join-Path $cliRoot 'node_modules\@openai\codex-win32-x64'
$vendorRoot = Join-Path $platformRoot "vendor\$target"
$installedExe = Join-Path $vendorRoot 'bin\codex.exe'
$customExe = Join-Path $packageDirectory 'bin\codex.exe'
$backupExe = Join-Path $scriptRoot "Original-Codex-$version.exe"

foreach ($path in @((Join-Path $cliRoot 'package.json'), (Join-Path $platformRoot 'package.json'), $installedExe, $customExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file not found: $path" }
}
$cliManifest = Get-Content -LiteralPath (Join-Path $cliRoot 'package.json') -Raw | ConvertFrom-Json
$platformManifest = Get-Content -LiteralPath (Join-Path $platformRoot 'package.json') -Raw | ConvertFrom-Json
$runtimeManifest = Get-Content -LiteralPath (Join-Path $packageDirectory 'codex-package.json') -Raw | ConvertFrom-Json
if ($cliManifest.version -ne $version -or
    $platformManifest.version -ne "$version-win32-x64" -or
    $runtimeManifest.version -ne $version -or
    $runtimeManifest.target -ne $target) {
    throw "Version mismatch. This build is $version; installed packages are $($cliManifest.version), $($platformManifest.version), and $($runtimeManifest.version). Update npm Codex to $version first."
}
$customHash = (Get-FileHash -LiteralPath $customExe -Algorithm SHA256).Hash
if ($customHash -ne $info.customExecutableSha256) { throw 'Custom executable checksum mismatch.' }

$daemonRoot = Join-Path $codexHome 'packages\app-server-daemon'
$legacyDaemonRoot = Join-Path $codexHome 'packages\standalone'
function Normalize-WindowsPath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.Substring(4)
    }
    return $fullPath.TrimEnd('\')
}
$installedExeFull = Normalize-WindowsPath $installedExe
$daemonRootFull = Normalize-WindowsPath $daemonRoot
$processes = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -ieq 'codex.exe' -and
    $_.ExecutablePath -and
    (
        (Normalize-WindowsPath $_.ExecutablePath) -ieq $installedExeFull -or
        (Normalize-WindowsPath $_.ExecutablePath).StartsWith($daemonRootFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Normalize-WindowsPath $_.ExecutablePath).StartsWith((Normalize-WindowsPath $legacyDaemonRoot) + '\', [StringComparison]::OrdinalIgnoreCase)
    )
})
$activeCli = @($processes | Where-Object {
    (Normalize-WindowsPath $_.ExecutablePath) -ieq $installedExeFull -and
    $_.CommandLine -notmatch 'app-server\s+(--listen|daemon\s+pid-update-loop)'
})
if ($activeCli.Count) {
    $activeCli | ForEach-Object { Write-Host ("PID {0}: {1}" -f $_.ProcessId, $_.CommandLine) }
    throw 'Close active Codex CLI sessions, save your work, and run this installer again.'
}
if ($processes.Count) {
    $processes | ForEach-Object { Write-Host ("PID {0}: {1}" -f $_.ProcessId, $_.CommandLine) }
    $answer = Read-Host 'The daemon will restart and may interrupt active work. Save work and continue? [y/N]'
    if ($answer -notmatch '^(?i)y$') { exit 2 }
}

$backupHashFile = "$backupExe.sha256"
if (-not (Test-Path -LiteralPath $backupExe)) {
    Copy-Item -LiteralPath $installedExe -Destination $backupExe
    (Get-FileHash -LiteralPath $backupExe -Algorithm SHA256).Hash | Set-Content -LiteralPath $backupHashFile -NoNewline
} elseif (-not (Test-Path -LiteralPath $backupHashFile)) {
    (Get-FileHash -LiteralPath $backupExe -Algorithm SHA256).Hash | Set-Content -LiteralPath $backupHashFile -NoNewline
}

if ((Get-FileHash -LiteralPath $backupExe -Algorithm SHA256).Hash -ine (Get-Content -LiteralPath $backupHashFile -Raw).Trim()) {
    throw 'Original CLI backup checksum mismatch; refusing to replace the installed CLI.'
}

function Restore-OriginalDaemon {
    Copy-Item -LiteralPath $backupExe -Destination $installedExe -Force
    if ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ine (Get-Content -LiteralPath $backupHashFile -Raw).Trim()) {
        throw 'Original CLI restore checksum mismatch.'
    }
    & $installedExe app-server daemon update --from-cli --yes
    $restoreExitCode = $LASTEXITCODE
    if ($restoreExitCode -ne 0) {
        throw "Restoring the original daemon package failed with exit code $restoreExitCode."
    }
}

try {
    Copy-Item -LiteralPath $customExe -Destination $installedExe -Force
    if ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ine $info.customExecutableSha256) {
        throw 'Installed CLI checksum mismatch.'
    }

    & $installedExe app-server daemon update --from-cli --yes
    $updateExitCode = $LASTEXITCODE
    if ($updateExitCode -ne 0) { throw "Daemon update failed with exit code $updateExitCode." }

    $current = Join-Path $codexHome 'packages\app-server-daemon\current'
    $selectedManifestPath = Join-Path $current 'codex-package.json'
    if (-not (Test-Path -LiteralPath $selectedManifestPath)) {
        throw 'Daemon update did not produce a selected package.'
    }
    $selectedManifest = Get-Content -LiteralPath $selectedManifestPath -Raw | ConvertFrom-Json
    $daemonExe = Join-Path $current 'bin\codex.exe'
    if ($selectedManifest.version -ne $version -or
        -not (Test-Path -LiteralPath $daemonExe -PathType Leaf) -or
        (Get-FileHash -LiteralPath $daemonExe -Algorithm SHA256).Hash -ine $info.customExecutableSha256) {
        throw 'Selected daemon package did not match the custom build.'
    }
} catch {
    $installError = $_
    try {
        Restore-OriginalDaemon
    } catch {
        throw "$($installError.Exception.Message) Automatic rollback failed: $($_.Exception.Message) Original CLI backup: $backupExe"
    }
    throw "$($installError.Exception.Message) The original CLI and daemon package were restored."
}

Write-Host "Installed Codex $version custom build."
Write-Host "Original CLI backup: $backupExe"
Write-Host 'To restore, run Restore-Codex-Original.ps1 from this directory.'
