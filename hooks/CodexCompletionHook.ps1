param(
    [switch]$Watch,
    [string]$StatePath = '',
    [string]$Root = '',
    [int]$WatchSeconds = 1800,
    [switch]$TestMode
)

# This hook intentionally writes nothing to stdout. UserPromptSubmit output becomes
# extra prompt context, and Stop output must be JSON when it is not empty.
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = $PSScriptRoot }
$stateDirectory = Join-Path $Root 'semantic-state'
$logPath = Join-Path $Root 'notifier.log'
$managerPath = Join-Path $Root 'CodexSoundManager.ps1'

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

function Get-RecordPayload {
    param($Record)
    $nested = Get-PropertyValue -Object $Record -Name 'payload'
    if ($null -ne $nested -and $nested -is [psobject]) { return $nested }
    return $Record
}

function Get-RecordTurnId {
    param($Record)
    $payload = Get-RecordPayload $Record
    foreach ($candidate in @(
        (Get-PropertyValue $payload 'turn_id'),
        (Get-PropertyValue $Record 'turn_id')
    )) {
        if ($null -ne $candidate -and [string]$candidate) { return [string]$candidate }
    }
    $metadata = Get-PropertyValue $payload 'internal_chat_message_metadata_passthrough'
    $metadataTurn = Get-PropertyValue $metadata 'turn_id'
    if ($null -ne $metadataTurn -and [string]$metadataTurn) { return [string]$metadataTurn }
    return ''
}

function Test-SuccessfulTaskComplete {
    param($Record, [Parameter(Mandatory)][string]$ExpectedTurnId)
    if ($null -eq $Record) { return $false }
    $payload = Get-RecordPayload $Record
    if ([string](Get-PropertyValue $payload 'type') -ne 'task_complete') { return $false }
    if ((Get-RecordTurnId $Record) -ne $ExpectedTurnId) { return $false }
    $status = ([string](Get-PropertyValue $payload 'status')).Trim().ToLowerInvariant()
    if ($status -in @('failed', 'failure', 'error', 'cancelled', 'canceled', 'aborted')) { return $false }
    $lastMessage = $payload.PSObject.Properties['last_agent_message']
    if ($null -ne $lastMessage -and [string]::IsNullOrWhiteSpace([string]$lastMessage.Value)) { return $false }
    return $true
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
        Write-CompletionLog "TEST: successful task_complete found: turn=$($State.TurnId)."
        return
    }
    if (-not (Test-Path -LiteralPath $managerPath)) {
        Write-CompletionLog "Confirmed completion was not played: manager not found at $managerPath."
        return
    }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $managerPath,
            '--semantic-complete', '--turn-id', [string]$State.TurnId
        ) -WindowStyle Hidden
        Write-CompletionLog "Successful task_complete found: turn=$($State.TurnId); sound started."
    } catch {
        Write-CompletionLog "Could not start confirmed-completion sound: $($_.Exception.Message)"
    }
}

function Watch-Completion {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $state = Read-JsonFile $Path
        if ($null -eq $state) { return }
        $transcriptPath = [string]$state.TranscriptPath
        $turnId = [string]$state.TurnId
        if (-not $transcriptPath -or -not $turnId) {
            Write-CompletionLog 'Completion watch skipped: transcript path or turn ID is missing.'
            return
        }
        $offset = [Math]::Max(0, [long]$state.StartOffset)
        $pending = ''
        $lastReadError = ''
        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $WatchSeconds))
        while ((Get-Date) -lt $deadline) {
            try {
                if (Test-Path -LiteralPath $transcriptPath) {
                    $bytes = [IO.File]::ReadAllBytes($transcriptPath)
                    if ($bytes.Length -gt $offset) {
                        $newText = [Text.Encoding]::UTF8.GetString($bytes, [int]$offset, [int]($bytes.Length - $offset))
                        $offset = $bytes.Length
                        $combined = $pending + $newText
                        $parts = [regex]::Split($combined, "`r?`n")
                        if ($combined -match "(?:`r?`n)$") {
                            $pending = ''
                        } else {
                            $pending = $parts[$parts.Count - 1]
                            if ($parts.Count -gt 1) { $parts = $parts[0..($parts.Count - 2)] } else { $parts = @() }
                        }
                        foreach ($line in $parts) {
                            if (-not $line -or -not $line.Trim()) { continue }
                            try { $record = $line | ConvertFrom-Json } catch { continue }
                            if (Test-SuccessfulTaskComplete -Record $record -ExpectedTurnId $turnId) {
                                Invoke-ConfirmedCompletion -State $state -Path $Path
                                return
                            }
                        }
                        $lastReadError = ''
                    }
                }
            } catch {
                $message = [string]$_.Exception.Message
                if ($message -ne $lastReadError) {
                    Write-CompletionLog "Transcript read will be retried: $message"
                    $lastReadError = $message
                }
            }
            Start-Sleep -Milliseconds 250
        }
        Write-CompletionLog "No confirmed completion found within $WatchSeconds seconds: turn=$turnId. Sound was not played."
    } finally {
        Remove-Item -LiteralPath "$Path.watch" -Force -ErrorAction SilentlyContinue
    }
}

function Start-CompletionWatcher {
    param([Parameter(Mandatory)][string]$Path)
    $watchLock = "$Path.watch"
    try {
        New-Item -ItemType File -Path $watchLock -ErrorAction Stop | Out-Null
    } catch {
        Write-CompletionLog 'Completion watcher is already running for this turn.'
        return
    }
    if ($TestMode) {
        Watch-Completion -Path $Path
        return
    }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
            '-Watch', '-StatePath', $Path, '-Root', $Root, '-WatchSeconds', $WatchSeconds
        ) -WindowStyle Hidden
        $state = Read-JsonFile $Path
        if ($state) { Write-CompletionLog "Started waiting for task_complete: turn=$($state.TurnId)." }
    } catch {
        Remove-Item -LiteralPath $watchLock -Force -ErrorAction SilentlyContinue
        Write-CompletionLog "Could not start completion watcher: $($_.Exception.Message)"
    }
}

try {
    Initialize-CompletionState
    if ($Watch) {
        if ($StatePath) { Watch-Completion -Path $StatePath }
        exit 0
    }
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
        $transcriptPath = [string](Get-PropertyValue $payload 'transcript_path')
        $startOffset = 0L
        if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath)) {
            $startOffset = (Get-Item -LiteralPath $transcriptPath).Length
        }
        $state = [pscustomobject]@{
            SessionId = $sessionId
            TurnId = $turnId
            TranscriptPath = $transcriptPath
            StartOffset = $startOffset
            StartedAtUtc = [DateTime]::UtcNow.ToString('O')
        }
        Write-JsonFile -Path $currentStatePath -Value $state
        Remove-Item -LiteralPath "$currentStatePath.watch", "$currentStatePath.completed" -Force -ErrorAction SilentlyContinue
        Write-CompletionLog "Task start recorded: turn=$turnId. No sound is played at start."
        exit 0
    }
    if ($eventName -eq 'Stop') {
        if (Test-Path -LiteralPath $currentStatePath) {
            Start-CompletionWatcher -Path $currentStatePath
        } else {
            Write-CompletionLog "Stop skipped: no recorded user start for turn=$turnId."
        }
    }
} catch {
    Write-CompletionLog "Unhandled completion hook error: $($_.Exception.Message)"
}

exit 0
