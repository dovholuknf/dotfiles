# Claude code hook helper. Reads the hook payload from stdin to extract
# session_id, then patches the matching <WORKTREE_ROOT>\sessions\<id>.json
# with the State + LastStateChange fields. Wired into UserPromptSubmit
# (thinking), Stop (idle), and Notification (needs-input) in settings.json.
#
# Usage (in settings.json hook entry):
#   pwsh -NoProfile -File <this> -State <thinking|idle|needs-input>
param(
    [Parameter(Mandatory)][ValidateSet('thinking','idle','needs-input')][string]$State
)

# Best-effort: any failure is swallowed so we never block claude.
try {
    if (-not [Console]::IsInputRedirected) { exit 0 }
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    $sid = $payload.session_id
    if (-not $sid) { exit 0 }

    $wtRoot = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT.TrimEnd('\') } else { 'D:\worktrees' }
    $sessionDir = "$wtRoot\sessions"
    if (-not (Test-Path $sessionDir)) { exit 0 }

    $now = (Get-Date).ToString('o')
    foreach ($f in (Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $e = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($e.ClaudeSessionId -ne $sid) { continue }
            $e | Add-Member -NotePropertyName State           -NotePropertyValue $State -Force
            $e | Add-Member -NotePropertyName LastStateChange -NotePropertyValue $now   -Force
            ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $f.FullName -Encoding UTF8
            break
        } catch {}
    }
} catch {}

exit 0
