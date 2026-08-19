param(
    [string]$Root = '',
    [switch]$TestMode
)

# This hook intentionally writes nothing to stdout. UserPromptSubmit output becomes
# extra prompt context, and Stop output must be JSON when it is not empty.
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = $PSScriptRoot }
$stateDirectory = Join-Path $Root 'semantic-state'
$logPath = Join-Path $Root 'notifier.log'
$settingsPath = Join-Path $Root 'settings.json'
$playbackLockPath = Join-Path $Root 'semantic-playback.lock'

function Initialize-CompletionState {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
}

function Write-CompletionLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        Initialize-CompletionState
        Add-Content -LiteralPath $logPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message) -Encoding UTF8
    } catch {}
}

function Read-HookPayload {
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not $raw -or -not $raw.Trim()) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        Write-CompletionLog "Hook skipped: could not read JSON: $($_.Exception.Message)"
        return $null
    }
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CompletionKey {
    param([Parameter(Mandatory)][string]$SessionId, [Parameter(Mandatory)][string]$TurnId)
    $bytes = [Text.Encoding]::UTF8.GetBytes("$SessionId`n$TurnId")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return (([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 32)).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 5 -Compress
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-CompletionLog "Could not read completion state: $($_.Exception.Message)"
        return $null
    }
}

function Get-CompletionSettings {
    try {
        if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }
        return Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-CompletionLog "Could not read sound settings: $($_.Exception.Message)"
        return $null
    }
}

function Get-CompletionSoundPath {
    param($Settings)
    $selected = if ($null -ne $Settings) { [string](Get-PropertyValue $Settings 'SoundPath') } else { '' }
    $candidates = @(
        $selected,
        (Join-Path $Root 'assets\default-sound.mp3'),
        (Join-Path $env:WINDIR 'Media\Windows Background.wav'),
        (Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav')
    )
    return $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Enter-CompletionPlaybackLock {
    try {
        if (Test-Path -LiteralPath $playbackLockPath) {
            $age = (Get-Date) - (Get-Item -LiteralPath $playbackLockPath).LastWriteTime
            if ($age.TotalMinutes -gt 5) { Remove-Item -LiteralPath $playbackLockPath -Force -ErrorAction SilentlyContinue }
        }
        $stream = [IO.File]::Open($playbackLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        return $true
    } catch {
        Write-CompletionLog 'Confirmed completion skipped: sound is already playing.'
        return $false
    }
}

function Invoke-CompletionSound {
    $settings = Get-CompletionSettings
    if ($null -ne $settings -and $settings.PSObject.Properties['Enabled'] -and -not [bool]$settings.Enabled) { return }
    $soundPath = Get-CompletionSoundPath $settings
    if (-not $soundPath) {
        Write-CompletionLog 'Confirmed completion was not played: no audio file was found.'
        return
    }
    if (-not (Enter-CompletionPlaybackLock)) { return }
    $opened = $false
    $alias = 'codexcompletionhook'
    try {
        if (-not ('CodexCompletionMci' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodexCompletionMci {
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    public static extern int mciSendString(string command, StringBuilder buffer, int bufferSize, IntPtr callback);
}
'@
        }
        $extension = [IO.Path]::GetExtension($soundPath).ToLowerInvariant()
        $deviceType = if ($extension -eq '.wav') { 'waveaudio' } elseif ($extension -eq '.mp3') { 'mpegvideo' } else { throw "Unsupported audio format: $extension" }
        $openResult = [CodexCompletionMci]::mciSendString(('open "' + $soundPath.Replace('"', '') + '" type ' + $deviceType + ' alias ' + $alias), $null, 0, [IntPtr]::Zero)
        if ($openResult -ne 0) { throw "Could not open audio file (code $openResult)." }
        $opened = $true
        $volume = if ($null -ne $settings -and $settings.PSObject.Properties['Volume']) { [int]$settings.Volume } else { 55 }
        $volume = [Math]::Min(100, [Math]::Max(0, $volume))
        [void][CodexCompletionMci]::mciSendString(('setaudio ' + $alias + ' volume to ' + ($volume * 10)), $null, 0, [IntPtr]::Zero)
        $playCount = if ($null -ne $settings -and $settings.PSObject.Properties['PlayCount']) { [int]$settings.PlayCount } else { 1 }
        $playCount = [Math]::Min(10, [Math]::Max(1, $playCount))
        for ($index = 0; $index -lt $playCount; $index++) {
            $result = [CodexCompletionMci]::mciSendString(('play ' + $alias + ' wait'), $null, 0, [IntPtr]::Zero)
            if ($result -ne 0) { throw "Could not play audio file (code $result)." }
            if ($index -lt ($playCount - 1)) { Start-Sleep -Milliseconds 180 }
        }
        Write-CompletionLog "Sound played after confirmed completion: $([IO.Path]::GetFileName($soundPath)); volume $volume%."
    } catch {
        Write-CompletionLog "Confirmed completion audio error: $($_.Exception.Message)"
    } finally {
        if ($opened) { [void][CodexCompletionMci]::mciSendString(('close ' + $alias), $null, 0, [IntPtr]::Zero) }
        Remove-Item -LiteralPath $playbackLockPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ConfirmedCompletion {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Path)
    $playedPath = "$Path.completed"
    try {
        New-Item -ItemType File -Path $playedPath -ErrorAction Stop | Out-Null
    } catch {
        Write-CompletionLog "Confirmed completion was already handled: turn=$($State.TurnId)."
        return
    }
    if ($TestMode) {
        Write-CompletionLog "TEST: confirmed task completion: turn=$($State.TurnId)."
        return
    }
    Invoke-CompletionSound
    Write-CompletionLog "Stop confirmed task completion: turn=$($State.TurnId)."
}

try {
    Initialize-CompletionState
    $payload = Read-HookPayload
    if ($null -eq $payload) { exit 0 }
    $eventName = [string](Get-PropertyValue $payload 'hook_event_name')
    $sessionId = [string](Get-PropertyValue $payload 'session_id')
    $turnId = [string](Get-PropertyValue $payload 'turn_id')
    if (-not $sessionId -or -not $turnId) {
        Write-CompletionLog "Hook $eventName skipped: session_id or turn_id is missing."
        exit 0
    }
    $key = Get-CompletionKey -SessionId $sessionId -TurnId $turnId
    $currentStatePath = Join-Path $stateDirectory "$key.start.json"
    if ($eventName -eq 'UserPromptSubmit') {
        $state = [pscustomobject]@{
            SessionId = $sessionId
            TurnId = $turnId
            StartedAtUtc = [DateTime]::UtcNow.ToString('O')
        }
        Write-JsonFile -Path $currentStatePath -Value $state
        Remove-Item -LiteralPath "$currentStatePath.watch", "$currentStatePath.completed" -Force -ErrorAction SilentlyContinue
        Write-CompletionLog "Task start recorded: turn=$turnId. No sound is played at start."
        exit 0
    }
    if ($eventName -eq 'Stop') {
        if (-not (Test-Path -LiteralPath $currentStatePath)) {
            Write-CompletionLog "Stop skipped: no recorded user start for turn=$turnId."
            exit 0
        }
        if ((Get-PropertyValue $payload 'stop_hook_active') -eq $true) {
            Write-CompletionLog "Stop skipped: this turn was already continued by a Stop hook: turn=$turnId."
            exit 0
        }
        $lastAssistantMessage = [string](Get-PropertyValue $payload 'last_assistant_message')
        if ([string]::IsNullOrWhiteSpace($lastAssistantMessage)) {
            Write-CompletionLog "Stop skipped: no final assistant message for turn=$turnId."
            exit 0
        }
        $state = Read-JsonFile $currentStatePath
        if ($state) { Invoke-ConfirmedCompletion -State $state -Path $currentStatePath }
    }
} catch {
    Write-CompletionLog "Unhandled completion hook error: $($_.Exception.Message)"
}

exit 0
