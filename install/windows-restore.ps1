$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$info = Get-Content -LiteralPath (Join-Path $scriptRoot 'BUILD-INFO.json') -Raw | ConvertFrom-Json
$version = [string]$info.codexVersion
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
if (-not $npm) { throw 'npm.cmd was not found.' }
$npmRoot = (& $npm.Source root -g | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or -not $npmRoot) { throw 'Could not locate the global npm directory.' }
$cliRoot = Join-Path $npmRoot '@openai\codex'
$platformRoot = Join-Path $cliRoot 'node_modules\@openai\codex-win32-x64'
$installedExe = Join-Path $platformRoot 'vendor\x86_64-pc-windows-msvc\bin\codex.exe'
$cliManifest = Get-Content -LiteralPath (Join-Path $cliRoot 'package.json') -Raw | ConvertFrom-Json
$platformManifest = Get-Content -LiteralPath (Join-Path $platformRoot 'package.json') -Raw | ConvertFrom-Json
if ($cliManifest.version -ne $version -or $platformManifest.version -ne "$version-win32-x64") {
    throw "Installed npm Codex version does not match this restore package ($version)."
}
$customExe = Join-Path (Join-Path $scriptRoot 'codex-package') 'bin\codex.exe'
$backupExe = Join-Path $scriptRoot "Original-Codex-$version.exe"
$backupHashFile = "$backupExe.sha256"
if (-not (Test-Path -LiteralPath $backupExe -PathType Leaf) -or -not (Test-Path -LiteralPath $backupHashFile -PathType Leaf)) {
    throw "Original CLI backup or its checksum was not found: $backupExe"
}
if ((Get-FileHash -LiteralPath $backupExe -Algorithm SHA256).Hash -ine (Get-Content -LiteralPath $backupHashFile -Raw).Trim()) {
    throw "Original CLI backup checksum mismatch: $backupExe"
}
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
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
if ($activeCli.Count) { throw 'Close active Codex CLI sessions before restoring.' }
if ($processes.Count) {
    $answer = Read-Host 'Restoring will restart the daemon. Save work and continue? [y/N]'
    if ($answer -notmatch '^(?i)y$') { exit 2 }
}

$current = Join-Path $codexHome 'packages\app-server-daemon\current'
$selectedManifestPath = Join-Path $current 'codex-package.json'
function Restore-CustomDaemon {
    Copy-Item -LiteralPath $customExe -Destination $installedExe -Force
    if ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash -ine $info.customExecutableSha256) {
        throw 'Custom executable checksum mismatch during recovery.'
    }
    & $installedExe app-server daemon update --from-cli --yes
    $recoveryExitCode = $LASTEXITCODE
    if ($recoveryExitCode -ne 0) { throw "Custom daemon recovery failed with exit code $recoveryExitCode." }
    $recoveredDaemonExe = Join-Path $current 'bin\codex.exe'
    if (-not (Test-Path -LiteralPath $recoveredDaemonExe -PathType Leaf) -or
        (Get-FileHash -LiteralPath $recoveredDaemonExe -Algorithm SHA256).Hash -ine $info.customExecutableSha256) {
        throw 'Custom daemon recovery did not select the expected executable.'
    }
}

try {
    Copy-Item -LiteralPath $backupExe -Destination $installedExe -Force
    & $installedExe app-server daemon update --from-cli --yes
    $restoreExitCode = $LASTEXITCODE
    if ($restoreExitCode -ne 0) { throw "Daemon restore failed with exit code $restoreExitCode." }
    if (-not (Test-Path -LiteralPath $selectedManifestPath -PathType Leaf)) {
        throw 'The selected daemon package could not be verified.'
    }
    $selectedManifest = Get-Content -LiteralPath $selectedManifestPath -Raw | ConvertFrom-Json
    $daemonExe = Join-Path $current 'bin\codex.exe'
    if ($selectedManifest.version -ne $version -or
        -not (Test-Path -LiteralPath $daemonExe -PathType Leaf) -or
        (Get-FileHash -LiteralPath $daemonExe -Algorithm SHA256).Hash -ine (Get-Content -LiteralPath $backupHashFile -Raw).Trim()) {
        throw 'The selected daemon binary does not match its backup.'
    }
} catch {
    $restoreError = $_
    try {
        Restore-CustomDaemon
    } catch {
        throw "$($restoreError.Exception.Message) Recovery to the custom build also failed: $($_.Exception.Message)"
    }
    throw "$($restoreError.Exception.Message) The custom CLI and daemon package were restored."
}
Write-Host "Restored the original npm Codex $version CLI and daemon package."
