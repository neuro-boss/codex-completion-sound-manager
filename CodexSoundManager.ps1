param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgumentsFromCodex
)

$ErrorActionPreference = 'Stop'
$soundRuCodexHome = Join-Path $env:USERPROFILE '.codex'
$soundRuRoot = $PSScriptRoot
$soundRuSettingsPath = Join-Path $soundRuRoot 'settings.json'
$soundRuSoundsPath = Join-Path $soundRuRoot 'sounds'
$soundRuLogPath = Join-Path $soundRuRoot 'notifier.log'
$soundRuLockPath = Join-Path $soundRuRoot 'playback.lock'

function Initialize-SoundRuStorage {
    New-Item -ItemType Directory -Path $soundRuRoot, $soundRuSoundsPath -Force | Out-Null
}

function Get-DefaultSoundPath {
    $candidates = @(
        (Join-Path $soundRuRoot 'assets\default-sound.mp3'),
        (Join-Path $env:WINDIR 'Media\Windows Background.wav'),
        (Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav'),
        (Join-Path $env:WINDIR 'Media\notify.wav')
    )
    return $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Get-SoundRuSettings {
    Initialize-SoundRuStorage
    if (Test-Path -LiteralPath $soundRuSettingsPath) {
        try {
            $saved = Get-Content -LiteralPath $soundRuSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved) {
                if ($null -eq $saved.PSObject.Properties['Volume']) {
                    $saved | Add-Member -NotePropertyName Volume -NotePropertyValue 55
                }
                if ($null -eq $saved.PSObject.Properties['Language']) {
                    $saved | Add-Member -NotePropertyName Language -NotePropertyValue 'ru'
                }
                if ($null -eq $saved.PSObject.Properties['Theme']) {
                    $saved | Add-Member -NotePropertyName Theme -NotePropertyValue 'light'
                }
                return $saved
            }
        } catch {}
    }
    return [pscustomobject]@{
        Enabled = $true
        PlayCount = 1
        Volume = 55
        Language = 'ru'
        Theme = 'light'
        SoundPath = (Get-DefaultSoundPath)
        PreviousNotifyLine = $null
    }
}

function Save-SoundRuSettings {
    param([Parameter(Mandatory)]$Settings)
    Initialize-SoundRuStorage
    $json = $Settings | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($soundRuSettingsPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Write-SoundRuLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        Initialize-SoundRuStorage
        if ((Test-Path -LiteralPath $soundRuLogPath) -and ((Get-Item -LiteralPath $soundRuLogPath).Length -gt 1MB)) {
            Remove-Item -LiteralPath $soundRuLogPath -Force
        }
        Add-Content -LiteralPath $soundRuLogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message) -Encoding UTF8
    } catch {}
}

function Enter-SoundRuPlaybackLock {
    Initialize-SoundRuStorage
    if (Test-Path -LiteralPath $soundRuLockPath) {
        $age = (Get-Date) - (Get-Item -LiteralPath $soundRuLockPath).LastWriteTime
        if ($age.TotalMinutes -gt 10) { Remove-Item -LiteralPath $soundRuLockPath -Force -ErrorAction SilentlyContinue }
    }
    try {
        $stream = [System.IO.File]::Open($soundRuLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.WriteLine("$PID $(Get-Date -Format o)")
        $writer.Dispose()
        return $true
    } catch {
        Write-SoundRuLog 'Повторное уведомление пропущено: звук уже воспроизводится.'
        return $false
    }
}

function Exit-SoundRuPlaybackLock {
    Remove-Item -LiteralPath $soundRuLockPath -Force -ErrorAction SilentlyContinue
}

function Invoke-SoundRuAudioPlayer {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Volume,
        [Parameter(Mandatory)][int]$PlayCount,
        [switch]$SkipLock
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not ('CodexSoundRuMci' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodexSoundRuMci {
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    public static extern int mciSendString(string command, StringBuilder buffer, int bufferSize, IntPtr callback);
}
'@
    }
    if (-not $SkipLock -and -not (Enter-SoundRuPlaybackLock)) { return }
    $alias = 'codexsoundru'
    $opened = $false
    try {
        $safePath = $Path.Replace('"', '')
        $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        $deviceType = if ($extension -eq '.wav') { 'waveaudio' } elseif ($extension -eq '.mp3') { 'mpegvideo' } else { throw "Неподдерживаемый формат: $extension" }
        $openResult = [CodexSoundRuMci]::mciSendString(('open "' + $safePath + '" type ' + $deviceType + ' alias ' + $alias), $null, 0, [IntPtr]::Zero)
        if ($openResult -ne 0) { throw "Не удалось открыть аудиофайл (код $openResult)" }
        $opened = $true
        $mciVolume = [Math]::Min(1000, [Math]::Max(0, $Volume * 10))
        [void][CodexSoundRuMci]::mciSendString(('setaudio ' + $alias + ' volume to ' + $mciVolume), $null, 0, [IntPtr]::Zero)
        for ($index = 0; $index -lt $PlayCount; $index++) {
            $playResult = [CodexSoundRuMci]::mciSendString(('play ' + $alias + ' wait'), $null, 0, [IntPtr]::Zero)
            if ($playResult -ne 0) { throw "Не удалось воспроизвести аудиофайл (код $playResult)" }
            if ($index -lt ($PlayCount - 1)) { Start-Sleep -Milliseconds 180 }
        }
        Write-SoundRuLog "Звук воспроизведён: $([System.IO.Path]::GetFileName($Path)); громкость $Volume%."
    } catch {
        Write-SoundRuLog "Ошибка воспроизведения: $($_.Exception.Message)"
    } finally {
        if ($opened) { [void][CodexSoundRuMci]::mciSendString(('close ' + $alias), $null, 0, [IntPtr]::Zero) }
        if (-not $SkipLock) { Exit-SoundRuPlaybackLock }
    }
}

function Invoke-SoundRuPlayback {
    param([Parameter(Mandatory)]$Settings, [string[]]$PayloadArguments = @())
    if (-not $Settings.Enabled) { return }
    $path = [string]$Settings.SoundPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        $path = Get-DefaultSoundPath
    }
    if (-not $path) {
        [System.Media.SystemSounds]::Asterisk.Play()
        return
    }
    $count = [Math]::Min(10, [Math]::Max(1, [int]$Settings.PlayCount))
    $volume = [Math]::Min(100, [Math]::Max(0, [int]$Settings.Volume))
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '--play-audio', $path, '--volume', $volume, '--count', $count) -WindowStyle Hidden
    } catch {
        Write-SoundRuLog "Не удалось запустить проигрыватель: $($_.Exception.Message)"
    }
}

function Invoke-PreviousNotifier {
    param([Parameter(Mandatory)]$Settings, [string[]]$PayloadArguments = @())
    $line = [string]$Settings.PreviousNotifyLine
    if (-not $line) { return }
    try {
        $arrayMatch = [regex]::Match($line, '\[(?<arguments>.*)\]')
        if (-not $arrayMatch.Success) { throw 'Не удалось прочитать сохранённую строку notify.' }
        $command = @((ConvertFrom-Json ('[' + $arrayMatch.Groups['arguments'].Value + ']')))
        if ($command.Count -eq 0 -or -not $command[0]) { throw 'Сохранённая команда notify пуста.' }
        if ([string]$command[0] -eq $PSCommandPath) { return }
        $previousArguments = if ($command.Count -gt 1) { @($command[1..($command.Count - 1)]) } else { @() }
        Start-Process -FilePath ([string]$command[0]) -ArgumentList @($previousArguments + $PayloadArguments) -WindowStyle Hidden
        Write-SoundRuLog "Запущено прежнее уведомление Codex: $([System.IO.Path]::GetFileName([string]$command[0]))."
    } catch {
        Write-SoundRuLog "Не удалось запустить прежнее уведомление Codex: $($_.Exception.Message)"
    }
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Backup-SoundRuConfig {
    param([Parameter(Mandatory)][string]$ConfigPath)
    if (Test-Path -LiteralPath $ConfigPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$ConfigPath.before-codex-sound-manager-$stamp.bak"
        Copy-Item -LiteralPath $ConfigPath -Destination $backup -ErrorAction Stop
        return $backup
    }
    return $null
}

function Apply-SoundRuConfiguration {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Form)
    $texts = Get-SoundRuTranslations -Language ([string]$Settings.Language)
    $configPath = Join-Path $soundRuCodexHome 'config.toml'
    $scriptArgument = ConvertTo-TomlString -Value $PSCommandPath
    $notifyLine = 'notify = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "' + $scriptArgument + '", "--notify" ]'
    $text = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { '' }
    $pattern = '(?m)^\s*notify\s*=\s*\[[^\r\n]*\]\s*$'
    $existing = [regex]::Match($text, $pattern)
    if ($existing.Success -and $existing.Value -notlike "*$PSCommandPath*") {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $texts.ExistingMessage,
            $texts.ExistingTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $Settings.PreviousNotifyLine = $existing.Value
    }
    $backup = Backup-SoundRuConfig -ConfigPath $configPath
    if ($existing.Success) {
        $text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $notifyLine }, 1)
    } else {
        $text = $notifyLine + [Environment]::NewLine + $text
    }
    [System.IO.File]::WriteAllText($configPath, $text, [System.Text.UTF8Encoding]::new($false))
    Save-SoundRuSettings -Settings $Settings
    $backupInfo = if ($backup) { "`n$($texts.BackupLabel): $backup" } else { '' }
    [System.Windows.Forms.MessageBox]::Show("$($texts.ApplySuccess)$backupInfo", $texts.ReadyTitle, 'OK', 'Information') | Out-Null
}

function Remove-SoundRuConfiguration {
    param([Parameter(Mandatory)]$Settings)
    $texts = Get-SoundRuTranslations -Language ([string]$Settings.Language)
    $configPath = Join-Path $soundRuCodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath)) { return }
    $text = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $pattern = '(?m)^\s*notify\s*=\s*\[[^\r\n]*CodexSound(?:Ru|Manager)\.ps1[^\r\n]*\]\s*\r?\n?'
    if ($text -notmatch $pattern) {
        [System.Windows.Forms.MessageBox]::Show($texts.NotOurs, $texts.NoChanges, 'OK', 'Information') | Out-Null
        return
    }
    $backup = Backup-SoundRuConfig -ConfigPath $configPath
    $replacement = if ($Settings.PreviousNotifyLine) { $Settings.PreviousNotifyLine + [Environment]::NewLine } else { '' }
    $text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)
    [System.IO.File]::WriteAllText($configPath, $text, [System.Text.UTF8Encoding]::new($false))
    $Settings.PreviousNotifyLine = $null
    Save-SoundRuSettings -Settings $Settings
    [System.Windows.Forms.MessageBox]::Show("$($texts.RemoveSuccess)`n$($texts.BackupLabel): $backup", $texts.ReadyTitle, 'OK', 'Information') | Out-Null
}

function Set-SoundRuButtonStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [ValidateSet('Primary', 'Secondary', 'Danger')][string]$Kind = 'Secondary'
    )
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 1
    $Button.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    switch ($Kind) {
        'Primary' {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(0, 105, 96)
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(0, 105, 96)
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 82, 76)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 65, 60)
        }
        'Danger' {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = [System.Drawing.Color]::FromArgb(168, 54, 54)
            $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(221, 185, 185)
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 244, 244)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(250, 232, 232)
        }
        default {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = [System.Drawing.Color]::FromArgb(26, 71, 69)
            $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(177, 198, 197)
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(231, 242, 240)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(209, 230, 226)
        }
    }
}

function Set-SoundRuRoundedRegion {
    param(
        [Parameter(Mandatory)]$Control,
        [int]$Radius = 14
    )
    $refreshRegion = {
        if ($Control.Width -lt 4 -or $Control.Height -lt 4) { return }
        $diameter = [Math]::Min($Radius * 2, [Math]::Min($Control.Width, $Control.Height))
        $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
        $path.AddArc($Control.Width - $diameter, 0, $diameter, $diameter, 270, 90)
        $path.AddArc($Control.Width - $diameter, $Control.Height - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc(0, $Control.Height - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        $Control.Region = [System.Drawing.Region]::new($path)
        $path.Dispose()
    }
    & $refreshRegion
    $Control.Add_Resize($refreshRegion)
}

function Show-SoundRuLegacyWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $settings = Get-SoundRuSettings

    $form = [System.Windows.Forms.Form]@{
        Text = 'Менеджер звуков Codex'
        StartPosition = 'CenterScreen'
        Size = [System.Drawing.Size]::new(770, 540)
        MinimumSize = [System.Drawing.Size]::new(770, 540)
        MaximumSize = [System.Drawing.Size]::new(770, 540)
        Font = [System.Drawing.Font]::new('Segoe UI', 9.5)
        BackColor = [System.Drawing.Color]::White
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }

    $header = [System.Windows.Forms.Panel]@{ Location = [System.Drawing.Point]::new(28, 24); Size = [System.Drawing.Size]::new(698, 92); BackColor = [System.Drawing.Color]::White }
    $mark = [System.Windows.Forms.Label]@{ Text = '♪'; Location = [System.Drawing.Point]::new(0, 14); Size = [System.Drawing.Size]::new(52, 52); TextAlign = 'MiddleCenter'; Font = [System.Drawing.Font]::new('Segoe UI Symbol', 23); ForeColor = [System.Drawing.Color]::FromArgb(0, 124, 112); BackColor = [System.Drawing.Color]::FromArgb(232, 246, 243) }
    $title = [System.Windows.Forms.Label]@{ Text = 'Звук завершения'; Location = [System.Drawing.Point]::new(68, 10); Size = [System.Drawing.Size]::new(350, 33); Font = [System.Drawing.Font]::new('Segoe UI Semibold', 20); ForeColor = [System.Drawing.Color]::FromArgb(27, 47, 52) }
    $description = [System.Windows.Forms.Label]@{ Text = 'Настройте спокойное уведомление для всех задач Codex.'; Location = [System.Drawing.Point]::new(70, 47); Size = [System.Drawing.Size]::new(400, 25); Font = [System.Drawing.Font]::new('Segoe UI', 9.5); ForeColor = [System.Drawing.Color]::FromArgb(100, 117, 121) }
    $status = [System.Windows.Forms.Label]@{ Location = [System.Drawing.Point]::new(553, 26); Size = [System.Drawing.Size]::new(145, 30); TextAlign = 'MiddleCenter'; Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8.5); BackColor = [System.Drawing.Color]::White }
    $separator = [System.Windows.Forms.Panel]@{ Location = [System.Drawing.Point]::new(28, 128); Size = [System.Drawing.Size]::new(698, 1); BackColor = [System.Drawing.Color]::FromArgb(228, 235, 235) }
    Set-SoundRuRoundedRegion -Control $mark -Radius 16
    $header.Controls.AddRange(@($mark, $title, $description, $status))

    $settingsCard = [System.Windows.Forms.Panel]@{ Location = [System.Drawing.Point]::new(28, 151); Size = [System.Drawing.Size]::new(338, 220); BackColor = [System.Drawing.Color]::FromArgb(248, 250, 250) }
    $settingsTitle = [System.Windows.Forms.Label]@{ Text = 'Уведомления'; Location = [System.Drawing.Point]::new(22, 20); Size = [System.Drawing.Size]::new(220, 25); Font = [System.Drawing.Font]::new('Segoe UI Semibold', 11); ForeColor = [System.Drawing.Color]::FromArgb(27, 47, 52) }
    $settingsHint = [System.Windows.Forms.Label]@{ Text = 'Когда Codex завершает задачу'; Location = [System.Drawing.Point]::new(22, 45); Size = [System.Drawing.Size]::new(220, 20); Font = [System.Drawing.Font]::new('Segoe UI', 8.5); ForeColor = [System.Drawing.Color]::FromArgb(108, 123, 126) }
    $enabledCaption = [System.Windows.Forms.Label]@{ Text = 'Звук уведомления'; Location = [System.Drawing.Point]::new(22, 86); Size = [System.Drawing.Size]::new(155, 27); Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9.5); ForeColor = [System.Drawing.Color]::FromArgb(38, 58, 62) }
    $enabled = [System.Windows.Forms.CheckBox]@{ Appearance = 'Button'; Location = [System.Drawing.Point]::new(220, 82); Size = [System.Drawing.Size]::new(96, 34); Checked = [bool]$settings.Enabled; TextAlign = 'MiddleCenter'; FlatStyle = 'Flat'; Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8.5); Cursor = [System.Windows.Forms.Cursors]::Hand }
    $enabled.FlatAppearance.BorderSize = 1
    $enabled.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(54, 72, 76)
    $settingLine = [System.Windows.Forms.Panel]@{ Location = [System.Drawing.Point]::new(22, 132); Size = [System.Drawing.Size]::new(294, 1); BackColor = [System.Drawing.Color]::FromArgb(225, 233, 233) }
    $countHint = [System.Windows.Forms.Label]@{ Text = 'Повторы'; Location = [System.Drawing.Point]::new(22, 148); Size = [System.Drawing.Size]::new(105, 20); Font = [System.Drawing.Font]::new('Segoe UI', 8.5); ForeColor = [System.Drawing.Color]::FromArgb(108, 123, 126) }
    $count = [System.Windows.Forms.NumericUpDown]@{ Location = [System.Drawing.Point]::new(22, 171); Size = [System.Drawing.Size]::new(104, 31); Minimum = 1; Maximum = 10; Value = [decimal]([Math]::Min(10, [Math]::Max(1, [int]$settings.PlayCount))); TextAlign = 'Center'; BackColor = [System.Drawing.Color]::White; BorderStyle = 'FixedSingle' }
    $volumeHint = [System.Windows.Forms.Label]@{ Text = 'Громкость'; Location = [System.Drawing.Point]::new(176, 148); Size = [System.Drawing.Size]::new(105, 20); Font = [System.Drawing.Font]::new('Segoe UI', 8.5); ForeColor = [System.Drawing.Color]::FromArgb(108, 123, 126) }
    $volume = [System.Windows.Forms.NumericUpDown]@{ Location = [System.Drawing.Point]::new(176, 171); Size = [System.Drawing.Size]::new(104, 31); Minimum = 0; Maximum = 100; Value = [decimal]([Math]::Min(100, [Math]::Max(0, [int]$settings.Volume))); TextAlign = 'Center'; BackColor = [System.Drawing.Color]::White; BorderStyle = 'FixedSingle' }
    $percent = [System.Windows.Forms.Label]@{ Text = '%'; Location = [System.Drawing.Point]::new(285, 177); Size = [System.Drawing.Size]::new(22, 20); Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9); ForeColor = [System.Drawing.Color]::FromArgb(108, 123, 126) }
    Set-SoundRuRoundedRegion -Control $settingsCard -Radius 18
    $settingsCard.Controls.AddRange(@($settingsTitle, $settingsHint, $enabledCaption, $enabled, $settingLine, $countHint, $count, $volumeHint, $volume, $percent))

    $soundCard = [System.Windows.Forms.Panel]@{ Location = [System.Drawing.Point]::new(388, 151); Size = [System.Drawing.Size]::new(338, 220); BackColor = [System.Drawing.Color]::FromArgb(248, 250, 250) }
    $soundTitle = [System.Windows.Forms.Label]@{ Text = 'Звук'; Location = [System.Drawing.Point]::new(22, 20); Size = [System.Drawing.Size]::new(200, 25); Font = [System.Drawing.Font]::new('Segoe UI Semibold', 11); ForeColor = [System.Drawing.Color]::FromArgb(27, 47, 52) }
    $soundHint = [System.Windows.Forms.Label]@{ Text = 'WAV или MP3, хранится в папке sounds'; Location = [System.Drawing.Point]::new(22, 45); Size = [System.Drawing.Size]::new(270, 20); Font = [System.Drawing.Font]::new('Segoe UI', 8.5); ForeColor = [System.Drawing.Color]::FromArgb(108, 123, 126) }
    $soundInputSurface = [System.Windows.Forms.Panel]@{ Location = [System.Drawing.Point]::new(22, 83); Size = [System.Drawing.Size]::new(294, 38); BackColor = [System.Drawing.Color]::White }
    $soundPath = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(12, 10); Size = [System.Drawing.Size]::new(270, 20); ReadOnly = $true; Text = [string]$settings.SoundPath; BackColor = [System.Drawing.Color]::White; BorderStyle = 'None'; Font = [System.Drawing.Font]::new('Segoe UI', 8.5); ForeColor = [System.Drawing.Color]::FromArgb(56, 73, 77) }
    Set-SoundRuRoundedRegion -Control $soundInputSurface -Radius 10
    $soundInputSurface.Controls.Add($soundPath)
    $choose = [System.Windows.Forms.Button]@{ Text = 'Выбрать файл'; Location = [System.Drawing.Point]::new(22, 143); Size = [System.Drawing.Size]::new(145, 38) }
    $default = [System.Windows.Forms.Button]@{ Text = 'Стандартный'; Location = [System.Drawing.Point]::new(177, 143); Size = [System.Drawing.Size]::new(139, 38) }
    Set-SoundRuRoundedRegion -Control $soundCard -Radius 18
    $soundCard.Controls.AddRange(@($soundTitle, $soundHint, $soundInputSurface, $choose, $default))

    $preview = [System.Windows.Forms.Button]@{ Text = 'Прослушать'; Location = [System.Drawing.Point]::new(28, 407); Size = [System.Drawing.Size]::new(133, 42) }
    $log = [System.Windows.Forms.Button]@{ Text = 'Журнал'; Location = [System.Drawing.Point]::new(171, 407); Size = [System.Drawing.Size]::new(102, 42) }
    $disable = [System.Windows.Forms.Button]@{ Text = 'Отключить'; Location = [System.Drawing.Point]::new(283, 407); Size = [System.Drawing.Size]::new(120, 42) }
    $apply = [System.Windows.Forms.Button]@{ Text = 'Применить к Codex'; Location = [System.Drawing.Point]::new(514, 407); Size = [System.Drawing.Size]::new(212, 42) }
    Set-SoundRuButtonStyle -Button $choose
    Set-SoundRuButtonStyle -Button $default
    Set-SoundRuButtonStyle -Button $preview
    Set-SoundRuButtonStyle -Button $log
    Set-SoundRuButtonStyle -Button $disable -Kind Danger
    Set-SoundRuButtonStyle -Button $apply -Kind Primary

    $toolTip = [System.Windows.Forms.ToolTip]::new()
    $toolTip.SetToolTip($soundPath, $soundPath.Text)

    $refreshStatus = {
        if ($enabled.Checked) {
            $enabled.Text = 'Включено'
            $enabled.BackColor = [System.Drawing.Color]::FromArgb(54, 72, 76)
            $enabled.ForeColor = [System.Drawing.Color]::White
            $enabled.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(54, 72, 76)
            $status.Text = '●  Звук включён'
            $status.ForeColor = [System.Drawing.Color]::FromArgb(54, 72, 76)
        } else {
            $enabled.Text = 'Выключено'
            $enabled.BackColor = [System.Drawing.Color]::White
            $enabled.ForeColor = [System.Drawing.Color]::FromArgb(91, 108, 111)
            $enabled.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(155, 173, 174)
            $status.Text = '○  Звук выключен'
            $status.ForeColor = [System.Drawing.Color]::FromArgb(91, 108, 111)
        }
    }
    & $refreshStatus
    $enabled.Add_CheckedChanged($refreshStatus)

    $choose.Add_Click({
        $dialog = [System.Windows.Forms.OpenFileDialog]@{ Filter = 'Аудиофайлы (*.wav;*.mp3)|*.wav;*.mp3|Файлы WAV (*.wav)|*.wav|Файлы MP3 (*.mp3)|*.mp3'; Title = 'Выберите звук завершения задачи' }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Initialize-SoundRuStorage
            $extension = [System.IO.Path]::GetExtension($dialog.FileName).ToLowerInvariant()
            $targetName = 'custom-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $extension
            $targetPath = Join-Path $soundRuSoundsPath $targetName
            Copy-Item -LiteralPath $dialog.FileName -Destination $targetPath -ErrorAction Stop
            $soundPath.Text = $targetPath
            $toolTip.SetToolTip($soundPath, $targetPath)
        }
    })
    $default.Add_Click({
        $soundPath.Text = [string](Get-DefaultSoundPath)
        $toolTip.SetToolTip($soundPath, $soundPath.Text)
    })
    $preview.Add_Click({
        $current = [pscustomobject]@{ Enabled = $true; PlayCount = [int]$count.Value; Volume = [int]$volume.Value; SoundPath = $soundPath.Text; PreviousNotifyLine = $settings.PreviousNotifyLine }
        Invoke-SoundRuPlayback -Settings $current
    })
    $log.Add_Click({
        Initialize-SoundRuStorage
        if (-not (Test-Path -LiteralPath $soundRuLogPath)) { [System.IO.File]::WriteAllText($soundRuLogPath, "Журнал ещё пуст.`r`n", [System.Text.UTF8Encoding]::new($true)) }
        Start-Process -FilePath 'notepad.exe' -ArgumentList @($soundRuLogPath)
    })
    $apply.Add_Click({
        $settings.Enabled = $enabled.Checked
        $settings.PlayCount = [int]$count.Value
        $settings.Volume = [int]$volume.Value
        $settings.SoundPath = $soundPath.Text
        Apply-SoundRuConfiguration -Settings $settings -Form $form
    })
    $disable.Add_Click({ Remove-SoundRuConfiguration -Settings $settings })
    $form.Controls.AddRange(@($header, $separator, $settingsCard, $soundCard, $preview, $log, $disable, $apply))
    [void]$form.ShowDialog()
}

function Get-SoundRuModernXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Менеджер звуков Codex"
        Width="860" Height="590"
        MinWidth="860" MinHeight="590"
        MaxWidth="860" MaxHeight="590"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="{DynamicResource AppBackground}"
        FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display"
        SnapsToDevicePixels="True">
    <Window.Resources>
        <SolidColorBrush x:Key="Ink" Color="#171B24"/>
        <SolidColorBrush x:Key="AppBackground" Color="#F3F4F6"/>
        <SolidColorBrush x:Key="Muted" Color="#6B7280"/>
        <SolidColorBrush x:Key="Accent" Color="#2F3B52"/>
        <SolidColorBrush x:Key="AccentHover" Color="#222C3F"/>
        <SolidColorBrush x:Key="Line" Color="#E1E4E8"/>
        <SolidColorBrush x:Key="Surface" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="Subtle" Color="#F7F8FA"/>
        <SolidColorBrush x:Key="Hover" Color="#F1F3F6"/>
        <SolidColorBrush x:Key="Pressed" Color="#E6E9EE"/>
        <SolidColorBrush x:Key="StatusSurface" Color="#EDF0F4"/>
        <SolidColorBrush x:Key="IconSurface" Color="#E9ECF2"/>
        <SolidColorBrush x:Key="TextStrong" Color="#303744"/>
        <SolidColorBrush x:Key="Danger" Color="#8B4A4A"/>
        <SolidColorBrush x:Key="ToggleOff" Color="#D5D9E0"/>
        <SolidColorBrush x:Key="Focus" Color="#7B8496"/>
        <SolidColorBrush x:Key="PrimaryPressed" Color="#171E2C"/>

        <Style x:Key="Heading" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>

        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Height" Value="44"/>
            <Setter Property="Padding" Value="18,0"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{DynamicResource TextStrong}"/>
            <Setter Property="Background" Value="{DynamicResource Surface}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource Hover}"/>
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{DynamicResource Focus}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource Pressed}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{DynamicResource Focus}"/>
                                <Setter TargetName="ButtonBorder" Property="BorderThickness" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="{DynamicResource Accent}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1"
                                CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource AccentHover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource PrimaryPressed}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{DynamicResource Focus}"/>
                                <Setter TargetName="ButtonBorder" Property="BorderThickness" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="QuietButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
        </Style>

        <Style x:Key="ModernToggle" TargetType="ToggleButton">
            <Setter Property="Width" Value="54"/>
            <Setter Property="Height" Value="30"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="Track" Background="{DynamicResource ToggleOff}" CornerRadius="15"/>
                            <Ellipse x:Name="Knob" Width="22" Height="22" Fill="White"
                                     HorizontalAlignment="Left" Margin="4,0,0,0">
                                <Ellipse.Effect>
                                    <DropShadowEffect BlurRadius="4" ShadowDepth="1" Opacity="0.18"/>
                                </Ellipse.Effect>
                            </Ellipse>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Track" Property="Background" Value="{DynamicResource Accent}"/>
                                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                                <Setter TargetName="Knob" Property="Margin" Value="0,0,4,0"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Track" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource Focus}"/>
                                <Setter TargetName="Track" Property="BorderThickness" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernComboBoxItem" TargetType="ComboBoxItem">
            <Setter Property="Padding" Value="11,8"/>
            <Setter Property="Foreground" Value="{DynamicResource TextStrong}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource Hover}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource Pressed}"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernComboBox" TargetType="ComboBox">
            <Setter Property="Height" Value="32"/>
            <Setter Property="Padding" Value="11,0,30,0"/>
            <Setter Property="Foreground" Value="{DynamicResource TextStrong}"/>
            <Setter Property="Background" Value="{DynamicResource Surface}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource ModernComboBoxItem}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="ComboBorder" Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                                    CornerRadius="9"/>
                            <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"
                                              HorizontalAlignment="Left" IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
                            <Path x:Name="Arrow" Data="M 0 0 L 4 4 L 8 0" Stroke="{DynamicResource Muted}"
                                  StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                  HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0"
                                  IsHitTestVisible="False" RenderTransformOrigin="0.5,0.5">
                                <Path.RenderTransform><RotateTransform Angle="0"/></Path.RenderTransform>
                            </Path>
                            <ToggleButton Background="Transparent" BorderThickness="0" Focusable="False"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"/></ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                                <Border Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Line}"
                                        BorderThickness="1" CornerRadius="9" Padding="4" Margin="0,4,0,0"
                                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                                    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="4" Opacity="0.18"/></Border.Effect>
                                    <ScrollViewer MaxHeight="240" CanContentScroll="True">
                                        <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="{DynamicResource Focus}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="{DynamicResource Focus}"/>
                            </Trigger>
                            <Trigger Property="IsDropDownOpen" Value="True">
                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernSlider" TargetType="Slider">
            <Setter Property="Height" Value="24"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Slider">
                        <Grid VerticalAlignment="Center">
                            <Track x:Name="PART_Track" Height="16" VerticalAlignment="Center"
                                   Orientation="Horizontal" IsDirectionReversed="{TemplateBinding IsDirectionReversed}">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static Slider.DecreaseLarge}">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Height="3" Background="{DynamicResource Accent}" CornerRadius="1.5"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static Slider.IncreaseLarge}">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Height="3" Background="{DynamicResource Line}" CornerRadius="1.5"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Width="14" Height="14">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Ellipse x:Name="ThumbCircle" Fill="{DynamicResource Surface}"
                                                         Stroke="{DynamicResource Accent}" StrokeThickness="2"/>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="ThumbCircle" Property="Fill" Value="{DynamicResource Hover}"/>
                                                    </Trigger>
                                                    <Trigger Property="IsDragging" Value="True">
                                                        <Setter TargetName="ThumbCircle" Property="Fill" Value="{DynamicResource Accent}"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="28,24,28,24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="24"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="22"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="56"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Width="56" Height="56" CornerRadius="17" Background="{DynamicResource IconSurface}">
                <TextBlock Text="♪" FontFamily="Segoe UI Symbol" FontSize="27"
                           Foreground="{DynamicResource Accent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="2" VerticalAlignment="Center">
                <TextBlock x:Name="TitleText" Text="Звук завершения" Style="{StaticResource Heading}" FontSize="25"/>
                <TextBlock x:Name="SubtitleText" Text="Спокойное уведомление для всех задач Codex" Foreground="{DynamicResource Muted}"
                           FontSize="13" Margin="0,5,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                <Border x:Name="StatusBadge" Height="32" Padding="13,0" CornerRadius="16"
                        Background="{DynamicResource StatusSurface}" VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="{DynamicResource Muted}" Margin="0,0,8,0"/>
                        <TextBlock x:Name="StatusText" Text="Звук включён" Foreground="{DynamicResource Muted}"
                                   FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
                    </StackPanel>
                </Border>
                <ComboBox x:Name="LanguageCombo" Width="106" Margin="10,0,0,0"
                          Style="{StaticResource ModernComboBox}"/>
                <Button x:Name="ThemeButton" Content="☾" Style="{StaticResource ActionButton}"
                        Width="40" Height="34" Padding="0" Margin="8,0,0,0" FontFamily="Segoe UI Symbol"
                        FontSize="16" ToolTip="Тёмная тема"/>
            </StackPanel>
        </Grid>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.35*"/>
                <ColumnDefinition Width="18"/>
                <ColumnDefinition Width="1*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="{DynamicResource Surface}" CornerRadius="16"
                    BorderBrush="{DynamicResource Line}" BorderThickness="1" Padding="24">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="26"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="16"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0">
                        <TextBlock x:Name="AudioTitleText" Text="Звуковой файл" Style="{StaticResource Heading}" FontSize="17"/>
                        <TextBlock x:Name="AudioDescriptionText" Text="WAV или MP3 до 50 МБ. Файл хранится локально."
                                   Foreground="{DynamicResource Muted}" FontSize="12" Margin="0,6,0,0"/>
                    </StackPanel>
                    <Border Grid.Row="2" Background="{DynamicResource Subtle}" CornerRadius="11"
                            BorderBrush="{DynamicResource Line}" BorderThickness="1" Height="52" Padding="14,0">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="10"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="♫" FontFamily="Segoe UI Symbol" FontSize="17"
                                       Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/>
                            <TextBlock Grid.Column="2" x:Name="SoundNameText" Text="Звук не выбран"
                                       Foreground="{DynamicResource TextStrong}" FontWeight="SemiBold" FontSize="13"
                                       TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                        </Grid>
                    </Border>
                    <TextBlock Grid.Row="4" x:Name="SoundPathText" Text=""
                               Foreground="{DynamicResource Muted}" FontSize="11"
                               TextTrimming="CharacterEllipsis" ToolTip=""/>
                    <StackPanel Grid.Row="6" Orientation="Horizontal">
                        <Button x:Name="ChooseButton" Content="Выбрать файл" Style="{StaticResource ActionButton}" Width="142"/>
                        <Button x:Name="DefaultButton" Content="Стандартный звук" Style="{StaticResource QuietButton}" Width="166" Margin="10,0,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>

            <Border Grid.Column="2" Background="{DynamicResource Surface}" CornerRadius="16"
                    BorderBrush="{DynamicResource Line}" BorderThickness="1" Padding="24">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="24"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="20"/>
                        <RowDefinition Height="1"/>
                        <RowDefinition Height="20"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="14"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" x:Name="SettingsTitleText" Text="Настройки" Style="{StaticResource Heading}" FontSize="17"/>
                    <Grid Grid.Row="2">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center">
                            <TextBlock x:Name="NotificationsText" Text="Уведомления" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" FontSize="14"/>
                            <TextBlock x:Name="NotificationsDescriptionText" Text="Проигрывать после завершения" Foreground="{DynamicResource Muted}" FontSize="11" Margin="0,4,0,0"/>
                        </StackPanel>
                        <ToggleButton Grid.Column="1" x:Name="EnabledToggle" Style="{StaticResource ModernToggle}"/>
                    </Grid>
                    <Border Grid.Row="4" Background="{DynamicResource Line}"/>
                    <Grid Grid.Row="6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="88"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock x:Name="RepeatsText" Text="Повторы" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" FontSize="13"/>
                            <ComboBox x:Name="RepeatCombo" Width="64" Margin="0,10,0,0"
                                      HorizontalAlignment="Left" Style="{StaticResource ModernComboBox}"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="VolumeText" Text="Громкость" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" FontSize="13"/>
                                <TextBlock Grid.Column="1" x:Name="VolumeValueText" Text="55%" Foreground="{DynamicResource Muted}" FontSize="12"/>
                            </Grid>
                            <Slider x:Name="VolumeSlider" Minimum="0" Maximum="100" TickFrequency="5"
                                    IsSnapToTickEnabled="False" Margin="0,8,0,0" Style="{StaticResource ModernSlider}"/>
                        </StackPanel>
                    </Grid>
                    <Border Grid.Row="8" Background="{DynamicResource Subtle}" CornerRadius="10" Padding="12">
                        <TextBlock x:Name="NoOverlapText" Text="Одновременные уведомления не накладываются друг на друга."
                                   Foreground="{DynamicResource Muted}" FontSize="11" TextWrapping="Wrap"/>
                    </Border>
                </Grid>
            </Border>
        </Grid>

        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button Grid.Column="0" x:Name="PreviewButton" Content="▶  Прослушать" Style="{StaticResource ActionButton}" Width="142"/>
            <Button Grid.Column="2" x:Name="LogButton" Content="Журнал" Style="{StaticResource QuietButton}" Width="92"/>
            <Button Grid.Column="4" x:Name="DisableButton" Content="Отключить" Style="{StaticResource QuietButton}" Width="106" Foreground="{DynamicResource Danger}"/>
            <Button Grid.Column="6" x:Name="ApplyButton" Content="Применить к Codex" Style="{StaticResource PrimaryButton}" Width="210"/>
        </Grid>
    </Grid>
</Window>
'@
}

function New-SoundRuModernWindow {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml
    $xaml = Get-SoundRuModernXaml
    $reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

function Get-SoundRuTranslations {
    param([string]$Language = 'ru')
    $translations = @{
        ru = @{
            WindowTitle='Менеджер звуков Codex'; Title='Звук завершения'; Subtitle='Спокойное уведомление для всех задач Codex'
            StatusOn='Звук включён'; StatusOff='Звук выключен'; AudioTitle='Звуковой файл'
            AudioDescription='WAV или MP3 до 50 МБ. Файл хранится локально.'; NotSelected='Звук не выбран'; ChoosePrompt='Выберите WAV или MP3'
            Choose='Выбрать файл'; Default='Стандартный звук'; Settings='Настройки'; Notifications='Уведомления'
            NotificationsDescription='Проигрывать после завершения'; Repeats='Повторы'; Volume='Громкость'
            NoOverlap='Одновременные уведомления не накладываются друг на друга.'; Preview='▶  Прослушать'; Log='Журнал'
            Disable='Отключить'; Apply='Применить к Codex'; DarkTheme='Включить тёмную тему'; LightTheme='Включить светлую тему'
            FileDialogTitle='Выберите звук завершения задачи'; FileTooLarge='Размер звукового файла не должен превышать 50 МБ.'; FileTooLargeTitle='Файл слишком большой'
            ExistingTitle='Существующее уведомление'; ExistingMessage='В config.toml уже есть обработчик уведомлений. Он будет сохранён и восстановлен при отключении менеджера. Продолжить?'
            ReadyTitle='Готово'; ApplySuccess='Настройка сохранена. Полностью перезапустите Codex, чтобы включить звук.'; BackupLabel='Резервная копия'
            NoChanges='Без изменений'; NotOurs='Текущий обработчик notify не принадлежит этому менеджеру. Ничего не изменено.'; RemoveSuccess='Интеграция с Codex отключена.'
        }
        en = @{
            WindowTitle='Codex Sound Manager'; Title='Completion sound'; Subtitle='A calm notification for every Codex task'
            StatusOn='Sound on'; StatusOff='Sound off'; AudioTitle='Sound file'
            AudioDescription='WAV or MP3 up to 50 MB. Stored locally.'; NotSelected='No sound selected'; ChoosePrompt='Choose a WAV or MP3 file'
            Choose='Choose file'; Default='Default sound'; Settings='Settings'; Notifications='Notifications'
            NotificationsDescription='Play when a task completes'; Repeats='Repeats'; Volume='Volume'
            NoOverlap='Simultaneous notifications never play over each other.'; Preview='▶  Preview'; Log='Log'
            Disable='Disable'; Apply='Apply to Codex'; DarkTheme='Switch to dark theme'; LightTheme='Switch to light theme'
            FileDialogTitle='Choose a task completion sound'; FileTooLarge='The sound file must not exceed 50 MB.'; FileTooLargeTitle='File is too large'
            ExistingTitle='Existing notification'; ExistingMessage='config.toml already contains a notification handler. It will be saved and restored when this manager is disabled. Continue?'
            ReadyTitle='Done'; ApplySuccess='Settings saved. Fully restart Codex to enable the sound.'; BackupLabel='Backup'
            NoChanges='No changes'; NotOurs='The current notify handler does not belong to this manager. Nothing was changed.'; RemoveSuccess='Codex integration has been disabled.'
        }
        es = @{
            WindowTitle='Gestor de sonidos de Codex'; Title='Sonido de finalización'; Subtitle='Una notificación tranquila para todas las tareas de Codex'
            StatusOn='Sonido activado'; StatusOff='Sonido desactivado'; AudioTitle='Archivo de sonido'
            AudioDescription='WAV o MP3 de hasta 50 MB. Se guarda localmente.'; NotSelected='No hay sonido seleccionado'; ChoosePrompt='Elige un archivo WAV o MP3'
            Choose='Elegir archivo'; Default='Sonido predeterminado'; Settings='Ajustes'; Notifications='Notificaciones'
            NotificationsDescription='Reproducir al finalizar una tarea'; Repeats='Repeticiones'; Volume='Volumen'
            NoOverlap='Las notificaciones simultáneas no se superponen.'; Preview='▶  Escuchar'; Log='Registro'
            Disable='Desactivar'; Apply='Aplicar a Codex'; DarkTheme='Cambiar al tema oscuro'; LightTheme='Cambiar al tema claro'
            FileDialogTitle='Elige un sonido de finalización'; FileTooLarge='El archivo de sonido no debe superar los 50 MB.'; FileTooLargeTitle='Archivo demasiado grande'
            ExistingTitle='Notificación existente'; ExistingMessage='config.toml ya contiene un controlador de notificaciones. Se guardará y restaurará al desactivar este gestor. ¿Continuar?'
            ReadyTitle='Listo'; ApplySuccess='Configuración guardada. Reinicia Codex por completo para activar el sonido.'; BackupLabel='Copia de seguridad'
            NoChanges='Sin cambios'; NotOurs='El controlador notify actual no pertenece a este gestor. No se modificó nada.'; RemoveSuccess='La integración con Codex se ha desactivado.'
        }
        de = @{
            WindowTitle='Codex Sound Manager'; Title='Abschlusston'; Subtitle='Eine ruhige Benachrichtigung für alle Codex-Aufgaben'
            StatusOn='Ton aktiviert'; StatusOff='Ton deaktiviert'; AudioTitle='Audiodatei'
            AudioDescription='WAV oder MP3 bis 50 MB. Lokal gespeichert.'; NotSelected='Kein Ton ausgewählt'; ChoosePrompt='WAV- oder MP3-Datei auswählen'
            Choose='Datei auswählen'; Default='Standardton'; Settings='Einstellungen'; Notifications='Benachrichtigungen'
            NotificationsDescription='Nach Abschluss einer Aufgabe abspielen'; Repeats='Anzahl'; Volume='Lautstärke'
            NoOverlap='Gleichzeitige Benachrichtigungen überlagern sich nicht.'; Preview='▶  Anhören'; Log='Protokoll'
            Disable='Deaktivieren'; Apply='Auf Codex anwenden'; DarkTheme='Dunkles Design aktivieren'; LightTheme='Helles Design aktivieren'
            FileDialogTitle='Abschlusston auswählen'; FileTooLarge='Die Audiodatei darf höchstens 50 MB groß sein.'; FileTooLargeTitle='Datei ist zu groß'
            ExistingTitle='Vorhandene Benachrichtigung'; ExistingMessage='config.toml enthält bereits einen Benachrichtigungs-Handler. Er wird gespeichert und beim Deaktivieren wiederhergestellt. Fortfahren?'
            ReadyTitle='Fertig'; ApplySuccess='Einstellungen gespeichert. Codex vollständig neu starten, um den Ton zu aktivieren.'; BackupLabel='Sicherung'
            NoChanges='Keine Änderungen'; NotOurs='Der aktuelle notify-Handler gehört nicht zu diesem Manager. Es wurde nichts geändert.'; RemoveSuccess='Die Codex-Integration wurde deaktiviert.'
        }
        zh = @{
            WindowTitle='Codex 声音管理器'; Title='任务完成提示音'; Subtitle='为所有 Codex 任务提供安静的完成提醒'
            StatusOn='声音已开启'; StatusOff='声音已关闭'; AudioTitle='声音文件'
            AudioDescription='支持 50 MB 以内的 WAV 或 MP3，仅保存在本机。'; NotSelected='未选择声音'; ChoosePrompt='请选择 WAV 或 MP3 文件'
            Choose='选择文件'; Default='默认声音'; Settings='设置'; Notifications='通知'
            NotificationsDescription='任务完成后播放'; Repeats='重复次数'; Volume='音量'
            NoOverlap='多个通知同时出现时不会叠加播放。'; Preview='▶  试听'; Log='日志'
            Disable='停用'; Apply='应用到 Codex'; DarkTheme='切换到深色主题'; LightTheme='切换到浅色主题'
            FileDialogTitle='选择任务完成提示音'; FileTooLarge='声音文件不能超过 50 MB。'; FileTooLargeTitle='文件过大'
            ExistingTitle='已有通知设置'; ExistingMessage='config.toml 中已有通知处理程序。停用本管理器时会恢复原设置。是否继续？'
            ReadyTitle='完成'; ApplySuccess='设置已保存。请完全重启 Codex 以启用提示音。'; BackupLabel='备份'
            NoChanges='未更改'; NotOurs='当前 notify 处理程序不属于本管理器，未进行任何更改。'; RemoveSuccess='已停用 Codex 集成。'
        }
    }
    if (-not $translations.ContainsKey($Language)) { $Language = 'ru' }
    return $translations[$Language]
}

function Set-SoundRuTheme {
    param([Parameter(Mandatory)]$Window, [ValidateSet('light','dark')][string]$Theme)
    $palette = if ($Theme -eq 'dark') {
        @{
            AppBackground='#101217'; Ink='#F2F4F7'; Muted='#A5ACB8'; Accent='#586781'; AccentHover='#697893'
            Line='#323741'; Surface='#1A1D24'; Subtle='#22262E'; Hover='#272C35'; Pressed='#303640'
            StatusSurface='#232832'; IconSurface='#232834'; TextStrong='#E7EAF0'; Danger='#D58A8A'
            ToggleOff='#4A505B'; Focus='#8C96A9'; PrimaryPressed='#77839A'
        }
    } else {
        @{
            AppBackground='#F3F4F6'; Ink='#171B24'; Muted='#6B7280'; Accent='#2F3B52'; AccentHover='#222C3F'
            Line='#E1E4E8'; Surface='#FFFFFF'; Subtle='#F7F8FA'; Hover='#F1F3F6'; Pressed='#E6E9EE'
            StatusSurface='#EDF0F4'; IconSurface='#E9ECF2'; TextStrong='#303744'; Danger='#8B4A4A'
            ToggleOff='#D5D9E0'; Focus='#7B8496'; PrimaryPressed='#171E2C'
        }
    }
    foreach ($entry in $palette.GetEnumerator()) {
        $Window.Resources[$entry.Key] = [System.Windows.Media.BrushConverter]::new().ConvertFromString($entry.Value)
    }
}

function Set-SoundRuLanguage {
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)]$Texts, [Parameter(Mandatory)][string]$Theme)
    $Window.Title = $Texts.WindowTitle
    $Window.FindName('TitleText').Text = $Texts.Title
    $Window.FindName('SubtitleText').Text = $Texts.Subtitle
    $Window.FindName('AudioTitleText').Text = $Texts.AudioTitle
    $Window.FindName('AudioDescriptionText').Text = $Texts.AudioDescription
    $Window.FindName('SettingsTitleText').Text = $Texts.Settings
    $Window.FindName('NotificationsText').Text = $Texts.Notifications
    $Window.FindName('NotificationsDescriptionText').Text = $Texts.NotificationsDescription
    $Window.FindName('RepeatsText').Text = $Texts.Repeats
    $Window.FindName('VolumeText').Text = $Texts.Volume
    $Window.FindName('NoOverlapText').Text = $Texts.NoOverlap
    $Window.FindName('ChooseButton').Content = $Texts.Choose
    $Window.FindName('DefaultButton').Content = $Texts.Default
    $Window.FindName('PreviewButton').Content = $Texts.Preview
    $Window.FindName('LogButton').Content = $Texts.Log
    $Window.FindName('DisableButton').Content = $Texts.Disable
    $Window.FindName('ApplyButton').Content = $Texts.Apply
    $Window.FindName('ThemeButton').ToolTip = if ($Theme -eq 'dark') { $Texts.LightTheme } else { $Texts.DarkTheme }
    $soundNameControl = $Window.FindName('SoundNameText')
    if ($soundNameControl.Text -eq 'Звук не выбран' -or -not $soundNameControl.Text) { $soundNameControl.Text = $Texts.NotSelected }
}

function Show-SoundRuWindow {
    Add-Type -AssemblyName System.Windows.Forms
    $settings = Get-SoundRuSettings
    $window = New-SoundRuModernWindow

    $enabledToggle = $window.FindName('EnabledToggle')
    $statusBadge = $window.FindName('StatusBadge')
    $statusDot = $window.FindName('StatusDot')
    $statusText = $window.FindName('StatusText')
    $repeatCombo = $window.FindName('RepeatCombo')
    $volumeSlider = $window.FindName('VolumeSlider')
    $volumeValueText = $window.FindName('VolumeValueText')
    $soundNameText = $window.FindName('SoundNameText')
    $soundPathText = $window.FindName('SoundPathText')
    $chooseButton = $window.FindName('ChooseButton')
    $defaultButton = $window.FindName('DefaultButton')
    $previewButton = $window.FindName('PreviewButton')
    $logButton = $window.FindName('LogButton')
    $disableButton = $window.FindName('DisableButton')
    $applyButton = $window.FindName('ApplyButton')
    $languageCombo = $window.FindName('LanguageCombo')
    $themeButton = $window.FindName('ThemeButton')

    $currentTheme = if ([string]$settings.Theme -eq 'dark') { 'dark' } else { 'light' }
    $currentLanguage = if (@('ru','en','es','de','zh') -contains [string]$settings.Language) { [string]$settings.Language } else { 'ru' }
    $uiState = @{
        Theme = $currentTheme
        Language = $currentLanguage
        Texts = Get-SoundRuTranslations -Language $currentLanguage
    }

    $languageCombo.DisplayMemberPath = 'Label'
    $languageCombo.SelectedValuePath = 'Code'
    $languageItems = @(
        [pscustomobject]@{ Code='ru'; Label='Русский' },
        [pscustomobject]@{ Code='en'; Label='English' },
        [pscustomobject]@{ Code='es'; Label='Español' },
        [pscustomobject]@{ Code='de'; Label='Deutsch' },
        [pscustomobject]@{ Code='zh'; Label='中文' }
    )
    foreach ($languageItem in $languageItems) { [void]$languageCombo.Items.Add($languageItem) }
    $languageCombo.SelectedItem = $languageItems | Where-Object { $_.Code -eq $currentLanguage } | Select-Object -First 1

    1..10 | ForEach-Object { [void]$repeatCombo.Items.Add($_) }
    $repeatCombo.SelectedItem = [int]([Math]::Min(10, [Math]::Max(1, [int]$settings.PlayCount)))
    $volumeSlider.Value = [Math]::Min(100, [Math]::Max(0, [int]$settings.Volume))
    $enabledToggle.IsChecked = [bool]$settings.Enabled
    Set-SoundRuTheme -Window $window -Theme $uiState.Theme
    Set-SoundRuLanguage -Window $window -Texts $uiState.Texts -Theme $uiState.Theme
    $themeButton.Content = if ($uiState.Theme -eq 'dark') { '☀' } else { '☾' }

    $updateSoundDisplay = {
        $selectedPath = [string]$settings.SoundPath
        if ($soundPathText.Tag) { $selectedPath = [string]$soundPathText.Tag }
        if ($selectedPath) {
            $soundNameText.Text = [System.IO.Path]::GetFileNameWithoutExtension($selectedPath)
            $soundPathText.Text = $selectedPath
            $soundPathText.ToolTip = $selectedPath
        } else {
            $soundNameText.Text = $uiState.Texts.NotSelected
            $soundPathText.Text = $uiState.Texts.ChoosePrompt
            $soundPathText.ToolTip = $null
        }
    }

    $updateStatus = {
        if ($enabledToggle.IsChecked) {
            $statusText.Text = $uiState.Texts.StatusOn
            $statusDot.Opacity = 1
        } else {
            $statusText.Text = $uiState.Texts.StatusOff
            $statusDot.Opacity = 0.45
        }
    }

    & $updateSoundDisplay
    & $updateStatus
    $volumeValueText.Text = ('{0}%' -f [int]$volumeSlider.Value)

    $enabledToggle.Add_Checked($updateStatus)
    $enabledToggle.Add_Unchecked($updateStatus)
    $volumeSlider.Add_ValueChanged({ $volumeValueText.Text = ('{0}%' -f [int]$volumeSlider.Value) })
    $languageCombo.Add_SelectionChanged({
        if (-not $languageCombo.SelectedValue) { return }
        $uiState.Language = [string]$languageCombo.SelectedValue
        $uiState.Texts = Get-SoundRuTranslations -Language $uiState.Language
        $settings.Language = $uiState.Language
        Set-SoundRuLanguage -Window $window -Texts $uiState.Texts -Theme $uiState.Theme
        & $updateSoundDisplay
        & $updateStatus
        Save-SoundRuSettings -Settings $settings
    })
    $themeButton.Add_Click({
        $uiState.Theme = if ($uiState.Theme -eq 'dark') { 'light' } else { 'dark' }
        $settings.Theme = $uiState.Theme
        Set-SoundRuTheme -Window $window -Theme $uiState.Theme
        Set-SoundRuLanguage -Window $window -Texts $uiState.Texts -Theme $uiState.Theme
        $themeButton.Content = if ($uiState.Theme -eq 'dark') { '☀' } else { '☾' }
        Save-SoundRuSettings -Settings $settings
    })

    $chooseButton.Add_Click({
        $dialog = [System.Windows.Forms.OpenFileDialog]@{
            Filter = 'Аудиофайлы (*.wav;*.mp3)|*.wav;*.mp3|Файлы WAV (*.wav)|*.wav|Файлы MP3 (*.mp3)|*.mp3'
            Title = $uiState.Texts.FileDialogTitle
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if ((Get-Item -LiteralPath $dialog.FileName).Length -gt 50MB) {
                [System.Windows.MessageBox]::Show($uiState.Texts.FileTooLarge, $uiState.Texts.FileTooLargeTitle, 'OK', 'Warning') | Out-Null
                return
            }
            Initialize-SoundRuStorage
            $extension = [System.IO.Path]::GetExtension($dialog.FileName).ToLowerInvariant()
            $targetName = 'custom-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $extension
            $targetPath = Join-Path $soundRuSoundsPath $targetName
            Copy-Item -LiteralPath $dialog.FileName -Destination $targetPath -ErrorAction Stop
            $soundPathText.Tag = $targetPath
            & $updateSoundDisplay
        }
    })

    $defaultButton.Add_Click({
        $soundPathText.Tag = [string](Get-DefaultSoundPath)
        & $updateSoundDisplay
    })

    $previewButton.Add_Click({
        $selectedPath = if ($soundPathText.Tag) { [string]$soundPathText.Tag } else { [string]$settings.SoundPath }
        $current = [pscustomobject]@{
            Enabled = $true
            PlayCount = [int]$repeatCombo.SelectedItem
            Volume = [int]$volumeSlider.Value
            SoundPath = $selectedPath
            PreviousNotifyLine = $settings.PreviousNotifyLine
        }
        Invoke-SoundRuPlayback -Settings $current
    })

    $logButton.Add_Click({
        Initialize-SoundRuStorage
        if (-not (Test-Path -LiteralPath $soundRuLogPath)) {
            [System.IO.File]::WriteAllText($soundRuLogPath, "Журнал ещё пуст.`r`n", [System.Text.UTF8Encoding]::new($true))
        }
        Start-Process -FilePath 'notepad.exe' -ArgumentList @($soundRuLogPath)
    })

    $applyButton.Add_Click({
        $settings.Enabled = [bool]$enabledToggle.IsChecked
        $settings.PlayCount = [int]$repeatCombo.SelectedItem
        $settings.Volume = [int]$volumeSlider.Value
        $settings.SoundPath = if ($soundPathText.Tag) { [string]$soundPathText.Tag } else { [string]$settings.SoundPath }
        $settings.Language = $uiState.Language
        $settings.Theme = $uiState.Theme
        Apply-SoundRuConfiguration -Settings $settings -Form $window
    })

    $disableButton.Add_Click({ Remove-SoundRuConfiguration -Settings $settings })
    [void]$window.ShowDialog()
}

if ($ArgumentsFromCodex -contains '--render-ui') {
    try {
        $renderIndex = [array]::IndexOf($ArgumentsFromCodex, '--render-ui')
        if (($renderIndex + 1) -ge $ArgumentsFromCodex.Count) { throw 'Не указан путь для изображения интерфейса.' }
        $renderPath = [string]$ArgumentsFromCodex[$renderIndex + 1]
        $renderWindow = New-SoundRuModernWindow
        $themeIndex = [array]::IndexOf($ArgumentsFromCodex, '--theme')
        $languageIndex = [array]::IndexOf($ArgumentsFromCodex, '--language')
        $renderTheme = if ($themeIndex -ge 0 -and ($themeIndex + 1) -lt $ArgumentsFromCodex.Count -and $ArgumentsFromCodex[$themeIndex + 1] -eq 'dark') { 'dark' } else { 'light' }
        $renderLanguage = if ($languageIndex -ge 0 -and ($languageIndex + 1) -lt $ArgumentsFromCodex.Count) { [string]$ArgumentsFromCodex[$languageIndex + 1] } else { 'ru' }
        $renderTexts = Get-SoundRuTranslations -Language $renderLanguage
        Set-SoundRuTheme -Window $renderWindow -Theme $renderTheme
        Set-SoundRuLanguage -Window $renderWindow -Texts $renderTexts -Theme $renderTheme
        $renderLanguageCombo = $renderWindow.FindName('LanguageCombo')
        $renderLanguageCombo.Items.Add((@{ru='Русский';en='English';es='Español';de='Deutsch';zh='中文'}[$renderLanguage])) | Out-Null
        $renderLanguageCombo.SelectedIndex = 0
        $renderWindow.FindName('ThemeButton').Content = if ($renderTheme -eq 'dark') { '☀' } else { '☾' }
        $renderWindow.FindName('StatusText').Text = $renderTexts.StatusOn
        $renderWindow.FindName('EnabledToggle').IsChecked = $true
        $renderRepeat = $renderWindow.FindName('RepeatCombo')
        1..10 | ForEach-Object { [void]$renderRepeat.Items.Add($_) }
        $renderRepeat.SelectedItem = 1
        $renderWindow.Show()
        $renderWindow.UpdateLayout()
        $pixelWidth = [Math]::Max(1, [int][Math]::Ceiling($renderWindow.ActualWidth))
        $pixelHeight = [Math]::Max(1, [int][Math]::Ceiling($renderWindow.ActualHeight))
        $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($pixelWidth, $pixelHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($renderWindow)
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [System.IO.File]::Open($renderPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $renderWindow.Close()
        Write-Output "UI_RENDER=$renderPath"
        exit 0
    } catch {
        $uiError = $_.Exception
        while ($uiError) {
            Write-Output ("UI_ERROR: " + $uiError.Message)
            $uiError = $uiError.InnerException
        }
        exit 1
    }
}

if ($ArgumentsFromCodex -contains '--validate-ui') {
    try {
        $testWindow = New-SoundRuModernWindow
        $requiredControls = @('EnabledToggle', 'RepeatCombo', 'VolumeSlider', 'ChooseButton', 'PreviewButton', 'ApplyButton')
        foreach ($controlName in $requiredControls) {
            if (-not $testWindow.FindName($controlName)) { throw "Не найден элемент интерфейса: $controlName" }
        }
        $testLanguageCombo = $testWindow.FindName('LanguageCombo')
        $testLanguageCombo.DisplayMemberPath = 'Label'
        $testLanguageCombo.SelectedValuePath = 'Code'
        $testLanguageItem = [pscustomobject]@{ Code='en'; Label='English' }
        [void]$testLanguageCombo.Items.Add($testLanguageItem)
        $testLanguageCombo.SelectedItem = $testLanguageItem
        if ([string]$testLanguageCombo.SelectedValue -ne 'en') { throw 'Не работает выбор языка.' }
        Set-SoundRuTheme -Window $testWindow -Theme dark
        $testTexts = Get-SoundRuTranslations -Language en
        Set-SoundRuLanguage -Window $testWindow -Texts $testTexts -Theme dark
        if ($testWindow.FindName('ApplyButton').Content -ne 'Apply to Codex') { throw 'Не применился перевод интерфейса.' }
        $testWindow.Close()
        Write-Output 'WPF UI: OK'
        exit 0
    } catch {
        Write-Error $_
        exit 1
    }
}

if ($ArgumentsFromCodex -contains '--play-audio') {
    $audioIndex = [array]::IndexOf($ArgumentsFromCodex, '--play-audio')
    $volumeIndex = [array]::IndexOf($ArgumentsFromCodex, '--volume')
    $countIndex = [array]::IndexOf($ArgumentsFromCodex, '--count')
    if ($audioIndex -ge 0 -and ($audioIndex + 1) -lt $ArgumentsFromCodex.Count) {
        $audioPath = [string]$ArgumentsFromCodex[$audioIndex + 1]
        $audioVolume = if ($volumeIndex -ge 0 -and ($volumeIndex + 1) -lt $ArgumentsFromCodex.Count) { [int]$ArgumentsFromCodex[$volumeIndex + 1] } else { 55 }
        $audioCount = if ($countIndex -ge 0 -and ($countIndex + 1) -lt $ArgumentsFromCodex.Count) { [int]$ArgumentsFromCodex[$countIndex + 1] } else { 1 }
        try { Invoke-SoundRuAudioPlayer -Path $audioPath -Volume $audioVolume -PlayCount ([Math]::Min(10, [Math]::Max(1, $audioCount))) } catch { Write-SoundRuLog "Необработанная ошибка проигрывателя: $($_.Exception.Message)" }
    }
    exit 0
}

if ($ArgumentsFromCodex -contains '--notify') {
    try {
        $notificationSettings = Get-SoundRuSettings
        $payload = @($ArgumentsFromCodex | Where-Object { $_ -ne '--notify' })
        Invoke-PreviousNotifier -Settings $notificationSettings -PayloadArguments $payload
        Invoke-SoundRuPlayback -Settings $notificationSettings -PayloadArguments $payload
    } catch {
        Write-SoundRuLog "Необработанная ошибка уведомления: $($_.Exception.Message)"
    }
    exit 0
}

Show-SoundRuWindow
