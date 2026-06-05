# Claude code hook helper. Reads the hook payload from stdin to extract
# session_id, then patches the matching <WORKTREE_ROOT>\sessions\<id>.json
# with the State + LastStateChange fields. Wired into UserPromptSubmit
# (thinking), Stop (idle), and Notification (needs-input) in settings.json.
#
# Usage (in settings.json hook entry):
#   pwsh -NoProfile -File <this> -State <thinking|idle|needs-input>
param(
    # Explicit state to record. One of the lifecycle states. Pass this when the
    # state is known at hook-fire time (UserPromptSubmit, Stop, Notification,
    # SessionEnd).
    [ValidateSet('thinking','idle','needs-input','ended','startup','resume','clear','compact')]
    [string]$State,

    # SessionStart-only: pull the state from the hook payload's `source` field
    # instead of -State. claude-code's SessionStart payload includes
    # source = startup|resume|clear|compact; wire this switch into the
    # SessionStart hook to get a state.log line per session opening.
    [switch]$FromPayloadSource
)
if (-not $State -and -not $FromPayloadSource) {
    throw "set-session-state.ps1: pass -State <name> or -FromPayloadSource"
}

# Best-effort: any failure is swallowed so we never block claude.

# Trace: every invocation appends. If you don't see entries after a prompt /
# stop / permission-prompt, the hook didn't fire (or pwsh wasn't on PATH).
$dbg = 'D:\worktrees\watch\hook-debug.log'
try {
    [System.IO.Directory]::CreateDirectory((Split-Path $dbg)) | Out-Null
    Add-Content -Path $dbg -Value ("{0}  set-state fired  state={1}  pid={2}" -f (Get-Date).ToString('o'), $State, $PID)
} catch {}

try {
    $stdinRedirected = [Console]::IsInputRedirected
    $raw = if ($stdinRedirected) { [Console]::In.ReadToEnd() } else { $null }
    try {
        Add-Content -Path $dbg -Value ("    stdinRedirected={0}  rawLen={1}" -f $stdinRedirected, $(if ($raw) { $raw.Length } else { 0 }))
    } catch {}
    if (-not $stdinRedirected) { exit 0 }
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    $sid = $payload.session_id
    try { Add-Content -Path $dbg -Value ("    parsed session_id={0}" -f $sid) } catch {}
    if (-not $sid) { exit 0 }

    # SessionStart-only: read claude's `source` field and use it as the state.
    # Accepted values: startup, resume, clear, compact. If missing, fall back
    # to 'startup' so the line still surfaces in the log.
    if ($FromPayloadSource) {
        $src = "$($payload.source)"
        if ($src -in @('startup','resume','clear','compact')) {
            $State = $src
        } else {
            $State = 'startup'
        }
        try { Add-Content -Path $dbg -Value ("    derived state from source: $State") } catch {}
    }

    $wtRoot = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT.TrimEnd('\') } else { 'D:\worktrees' }
    $sessionDir = "$wtRoot\sessions"
    if (-not (Test-Path $sessionDir)) { exit 0 }

    $watchDir = "$wtRoot\watch"
    [System.IO.Directory]::CreateDirectory($watchDir) | Out-Null
    $logFile = Join-Path $watchDir 'state.log'

    $now = (Get-Date).ToString('o')
    foreach ($f in (Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $e = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($e.ClaudeSessionId -ne $sid) { continue }
            $e | Add-Member -NotePropertyName State           -NotePropertyValue $State -Force
            $e | Add-Member -NotePropertyName LastStateChange -NotePropertyValue $now   -Force
            ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $f.FullName -Encoding UTF8

            $branch = if ($e.Label) { $e.Label } elseif ($e.Branch) { $e.Branch } else { '(unknown)' }
            $line   = '{0}  {1,-11}  {2,-30}  @ {3}' -f $now, $State, $branch, $e.WorktreePath
            Add-Content -Path $logFile -Value $line -Encoding UTF8
            break
        } catch {}
    }
} catch {}

exit 0
