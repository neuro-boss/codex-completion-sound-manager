param(
    [switch]$NoDesktopShortcut,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$sourceScript = Join-Path $projectRoot 'CodexSoundManager.ps1'
$codexDirectory = Join-Path $env:USERPROFILE '.codex'
$installDirectory = Join-Path $codexDirectory 'codex-completion-sound-manager'
$installedScript = Join-Path $installDirectory 'CodexSoundManager.ps1'

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "CodexSoundManager.ps1 was not found in $projectRoot"
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null

if (Test-Path -LiteralPath $installedScript) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDirectory = Join-Path $installDirectory "backup-install-$stamp"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $installedScript -Destination (Join-Path $backupDirectory 'CodexSoundManager.ps1') -ErrorAction Stop

    foreach ($personalFile in @('settings.json', 'notifier.log')) {
        $personalPath = Join-Path $installDirectory $personalFile
        if (Test-Path -LiteralPath $personalPath) {
            Copy-Item -LiteralPath $personalPath -Destination (Join-Path $backupDirectory $personalFile) -ErrorAction Stop
        }
    }
}

Copy-Item -LiteralPath $sourceScript -Destination $installedScript -Force -ErrorAction Stop

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
