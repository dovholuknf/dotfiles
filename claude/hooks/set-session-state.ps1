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

    # SessionEnd carries a `reason` (clear | logout | prompt_input_exit | other).
    # It only exists on a clean exit (a kill fires nothing), so it can't flag a
    # dirty exit -- but it tells apart the kinds of clean exit, and notably catches
    # `clear`, which fires SessionEnd without the session actually ending.
    $reason = "$($payload.reason)"

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

    # Per-folder activity log: drop the same transition into <cwd>\.claude\agent-log.txt
    # so any repo or worktree shows its own claude history (and thus the last time a
    # session ran there) without consulting the central ledger. The folder is implicit
    # in the path, so the line just carries time, state, and the claude session id.
    # Best-effort: never blocks the hook. Gitignore .claude/agent-log.txt if you don't
    # want it tracked.
    $cwd = $payload.cwd
    if (-not $cwd) { $cwd = $payload.workspace.current_dir }
    if ($cwd -and (Test-Path $cwd)) {
        try {
            $dotClaude = Join-Path $cwd '.claude'
            [System.IO.Directory]::CreateDirectory($dotClaude) | Out-Null
            $folderLog = Join-Path $dotClaude 'agent-log.txt'
            $reasonTag = if ($reason) { "  reason=$reason" } else { '' }
            $logLine   = '{0}  {1,-11}  session={2}{3}' -f $now, $State, $sid, $reasonTag
            # A fresh launch (source=startup) starts the folder log over; a resumed
            # session (claude -c -> source=resume), /clear, compact, and every
            # mid-session event append. So the file reflects the current session, and
            # full history still lives in the central state.log.
            if ($FromPayloadSource -and $State -eq 'startup') {
                Set-Content -Path $folderLog -Value $logLine -Encoding UTF8
            } else {
                Add-Content -Path $folderLog -Value $logLine -Encoding UTF8
            }
        } catch {}
    }

    foreach ($f in (Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $e = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($e.ClaudeSessionId -ne $sid) { continue }
            $e | Add-Member -NotePropertyName State           -NotePropertyValue $State -Force
            $e | Add-Member -NotePropertyName LastStateChange -NotePropertyValue $now   -Force
            if ($reason) { $e | Add-Member -NotePropertyName EndReason -NotePropertyValue $reason -Force }
            ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $f.FullName -Encoding UTF8

            $branch = if ($e.Label) { $e.Label } elseif ($e.Branch) { $e.Branch } else { '(unknown)' }
            $line   = '{0}  {1,-11}  {2,-30}  @ {3}' -f $now, $State, $branch, $e.WorktreePath
            Add-Content -Path $logFile -Value $line -Encoding UTF8

            # Per-window tab-order registry: append this tab (keyed by its stable
            # WT_SESSION) the first time we see it, and NEVER move or remove it here.
            # A tab's WT_SESSION survives claude exiting and 'claude -c' restarting in
            # the same tab, so append-if-missing keeps its position fixed across that
            # cycle. (Removing on SessionEnd + re-appending on resume used to shuffle
            # it to the end -- that was the reorder bug.) A tab that truly closed just
            # leaves a stale line; 'gwt sessions tabs' flags it [GHOST] and
            # 'tabs prune' / 'tabs test' drop it. Position = approximate wt tab index.
            $wtSess = if ($e.WtSession) { $e.WtSession } else { $env:WT_SESSION }
            if ($wtSess -and $e.WindowName -and $State -ne 'ended') {
                try {
                    $winDir = Join-Path $wtRoot 'windows'
                    [System.IO.Directory]::CreateDirectory($winDir) | Out-Null
                    $safe     = ($e.WindowName -replace '[^A-Za-z0-9._-]', '_')
                    $tabFile  = Join-Path $winDir "$safe.tabs"
                    $existing = if (Test-Path $tabFile) { @(Get-Content $tabFile -ErrorAction SilentlyContinue) } else { @() }
                    # For a main clone the branch is just 'main', which is useless as a
                    # label (every repo's main clone looks the same). Fall back to the
                    # folder leaf (the repo name) so agora/main reads 'agora'.
                    $tabLabel = if ($branch -in @('main','master') -and $e.WorktreePath) { Split-Path $e.WorktreePath -Leaf } else { $branch }
                    if (-not @($existing | Where-Object { ($_ -split "`t")[0] -eq $wtSess }).Count) {
                        Add-Content -Path $tabFile -Value ("{0}`t{1}`t{2}" -f $wtSess, $tabLabel, $e.WorktreePath) -Encoding UTF8
                    }
                } catch {}
            }
            break
        } catch {}
    }
} catch {}

exit 0
