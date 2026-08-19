param(
    [switch]$NoDesktopShortcut,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$sourceScript = Join-Path $projectRoot 'CodexSoundManager.ps1'
$sourceCompletionHook = Join-Path $projectRoot 'hooks\CodexCompletionHook.ps1'
$sourceAssetsDirectory = Join-Path $projectRoot 'assets'
$sourceDefaultSound = Join-Path $sourceAssetsDirectory 'default-sound.mp3'
$codexDirectory = Join-Path $env:USERPROFILE '.codex'
$installDirectory = Join-Path $codexDirectory 'codex-completion-sound-manager'
$installedScript = Join-Path $installDirectory 'CodexSoundManager.ps1'
$installedCompletionHook = Join-Path $installDirectory 'CodexCompletionHook.ps1'
$installedAssetsDirectory = Join-Path $installDirectory 'assets'
$installedDefaultSound = Join-Path $installedAssetsDirectory 'default-sound.mp3'

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "CodexSoundManager.ps1 was not found in $projectRoot"
}
if (-not (Test-Path -LiteralPath $sourceCompletionHook)) {
    throw "CodexCompletionHook.ps1 was not found in $projectRoot\hooks"
}
if (-not (Test-Path -LiteralPath $sourceDefaultSound)) {
    throw "The bundled default sound was not found in $sourceAssetsDirectory"
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null

if ((Test-Path -LiteralPath $installedScript) -or (Test-Path -LiteralPath $installedCompletionHook) -or (Test-Path -LiteralPath $installedDefaultSound)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDirectory = Join-Path $installDirectory "backup-install-$stamp"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $installedScript) {
        Copy-Item -LiteralPath $installedScript -Destination (Join-Path $backupDirectory 'CodexSoundManager.ps1') -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $installedCompletionHook) {
        Copy-Item -LiteralPath $installedCompletionHook -Destination (Join-Path $backupDirectory 'CodexCompletionHook.ps1') -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $installedDefaultSound) {
        $backupAssetsDirectory = Join-Path $backupDirectory 'assets'
        New-Item -ItemType Directory -Path $backupAssetsDirectory -Force | Out-Null
        Copy-Item -LiteralPath $installedDefaultSound -Destination (Join-Path $backupAssetsDirectory 'default-sound.mp3') -ErrorAction Stop
    }

    foreach ($personalFile in @('settings.json', 'notifier.log')) {
        $personalPath = Join-Path $installDirectory $personalFile
        if (Test-Path -LiteralPath $personalPath) {
            Copy-Item -LiteralPath $personalPath -Destination (Join-Path $backupDirectory $personalFile) -ErrorAction Stop
        }
    }
}

Copy-Item -LiteralPath $sourceScript -Destination $installedScript -Force -ErrorAction Stop
Copy-Item -LiteralPath $sourceCompletionHook -Destination $installedCompletionHook -Force -ErrorAction Stop
New-Item -ItemType Directory -Path $installedAssetsDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceDefaultSound -Destination $installedDefaultSound -Force -ErrorAction Stop

foreach ($noticeFile in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) {
    $sourceNotice = Join-Path $projectRoot $noticeFile
    if (Test-Path -LiteralPath $sourceNotice) {
        Copy-Item -LiteralPath $sourceNotice -Destination (Join-Path $installDirectory $noticeFile) -Force -ErrorAction Stop
    }
}

$launcherPath = Join-Path $installDirectory 'Launch Codex Sound Manager.cmd'
$launcherText = @'
@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CodexSoundManager.ps1"
'@
[System.IO.File]::WriteAllText($launcherPath, $launcherText, [System.Text.Encoding]::ASCII)

if (-not $NoDesktopShortcut) {
    $desktopDirectory = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktopDirectory 'Codex Completion Sound Manager.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$installedScript`""
    $shortcut.WorkingDirectory = $installDirectory
    $shortcut.Description = 'Configure Codex task completion sounds'
    $shortcut.Save()
}

Write-Host "Installed to: $installDirectory" -ForegroundColor Green
Write-Host 'No Codex configuration was changed by the installer.'
Write-Host 'Open the manager and select Apply to Codex when you are ready.'

if (-not $NoLaunch) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $installedScript
    )
}
