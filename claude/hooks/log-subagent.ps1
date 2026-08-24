# Claude-code hook helper: log subagent (Task tool) activity into the same
# state.log that agent-log tails. Subagents do NOT fire SessionStart / Stop /
# UserPromptSubmit, so without this a spawned agent's work is invisible in the
# live log -- the parent session just sits on 'thinking' until it returns.
#
# Two phases, wired in settings.json:
#   -Phase start  on PreToolUse matcher 'Task'  -> a subagent is being spawned
#   -Phase stop   on SubagentStop               -> a subagent finished
#
# The line reuses state.log's shape:  <iso>  <state>  <label>  @ <path>
#   state = 'subagent' (start) | 'sub-done' (stop)
#   label = '<agent-type>: <description>' on start, '<- subagent returned' on stop
#   path  = the PARENT session's worktree path (subagents have no worktree of
#           their own), falling back to the payload cwd.
# agent-log renders these under the parent's terminal group by path lookup.
#
# Best-effort: every failure is swallowed and the hook always exits 0 (allow).
# A PreToolUse hook that emitted a block decision would stop the Task, so this
# one never emits JSON -- it only appends a log line.
param(
    [ValidateSet('start','stop')]
    [string]$Phase = 'start'
)

try {
    if (-not [Console]::IsInputRedirected) { exit 0 }
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $payload) { exit 0 }

    $sid = "$($payload.session_id)"
    $cwd = $payload.cwd
    if (-not $cwd) { $cwd = $payload.workspace.current_dir }

    $wtRoot = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT.TrimEnd('\') } else { 'D:\worktrees' }
    $sessionDir = "$wtRoot\sessions"
    $watchDir   = "$wtRoot\watch"
    [System.IO.Directory]::CreateDirectory($watchDir) | Out-Null
    $logFile = Join-Path $watchDir 'state.log'
    $now     = (Get-Date).ToString('o')

    # Resolve the parent session's worktree path from the ledger by session id, so
    # the subagent line lands under the right terminal group. Newest entry wins if
    # the id is shared (claude -c reuse). Fall back to cwd when nothing matches.
    $parentPath = $cwd
    if ($sid -and (Test-Path $sessionDir)) {
        $cands = @()
        foreach ($f in (Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try { $ce = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
            if ("$($ce.ClaudeSessionId)" -ne $sid) { continue }
            $cands += $ce
        }
        if ($cands.Count) {
            $pick = @($cands | Sort-Object {
                if ($_.LastStateChange) { "$($_.LastStateChange)" }
                elseif ($_.LastSpawnedAt) { "$($_.LastSpawnedAt)" }
                else { "$($_.SpawnedAt)" }
            } -Descending)[0]
            if ($pick.WorktreePath) { $parentPath = $pick.WorktreePath }
        }
    }
    if (-not $parentPath) { exit 0 }

    if ($Phase -eq 'start') {
        $type = "$($payload.tool_input.subagent_type)"
        if (-not $type) { $type = 'agent' }
        $desc = "$($payload.tool_input.description)"
        # Keep the label single-line and bounded; state.log is one line per event.
        $desc = ($desc -replace '\s+', ' ').Trim()
        if ($desc.Length -gt 48) { $desc = $desc.Substring(0, 47) + '...' }
        $label = if ($desc) { "$type`: $desc" } else { $type }
        $state = 'subagent'
    } else {
        $label = '<- subagent returned'
        $state = 'sub-done'
    }

    $line = '{0}  {1,-11}  {2,-30}  @ {3}' -f $now, $state, $label, $parentPath
    Add-Content -Path $logFile -Value $line -Encoding UTF8
} catch {}

exit 0
