# Tells atrium a session started or ended. Wire into SessionStart and
# SessionEnd in settings.json, passing -Event start or -Event end.
#
# Why a hook rather than a prompt: a session that is sitting at its prompt has
# not made a tool call yet, so the permission hook has nothing to report and the
# session is invisible on the board. Asking the model to "register with atrium"
# would work but costs a turn every time a session opens. SessionStart fires at
# exactly the right moment and costs nothing.
#
# SessionEnd is the more valuable half. It is the only reliable signal that a
# session is over, which is what lets a card go dead on its own instead of
# sitting in running forever.
#
# Fails silently and always exits 0. A session must never fail to start because
# atrium was not listening.

param(
    [ValidateSet('start', 'end')]
    [string]$Event = 'start'
)

$gate = "$($env:ATRIUM_PERM_GATE)".Trim().ToLower()
if ($gate -eq 'off') { exit 0 }

# Timing probe: this hook once cost up to ~6.5s from a per-PID CIM ancestor walk.
# Logs its own elapsed ms so a future regression is visible without guessing.
$__sw = [System.Diagnostics.Stopwatch]::StartNew()
$__dbg = 'D:\worktrees\watch\hook-debug.log'

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $null
    if ($raw) { $payload = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue }

    $cwd = if ($payload -and $payload.cwd) { "$($payload.cwd)" } else { (Get-Location).Path }

    # A session launched by atrium is told which card it belongs to. Anything
    # else identifies itself by directory, matching the permission hook.
    $agent = if ($env:ATRIUM_AGENT_NAME) { $env:ATRIUM_AGENT_NAME } else { Split-Path -Leaf $cwd }

    # The runner's own process, so atrium can check liveness for free later.
    # This script runs as a descendant of it, so walk up until it turns up.
    # ONE Win32_Process enumeration into an in-memory pid->{name,parent} map, then
    # walk the map. A per-PID filtered CIM call costs ~1s each on this box, so the
    # old six-hop loop cost up to ~6.5s per SessionStart. See CLAUDE.md pitfalls.
    $runnerPid = 0
    try {
        $procMap = @{}
        foreach ($p in (Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $procMap[[int]$p.ProcessId] = @{ Name = "$($p.Name)"; Parent = [int]$p.ParentProcessId }
        }
        $walk = $PID
        for ($i = 0; $i -lt 6 -and $walk -gt 0; $i++) {
            $p = $procMap[$walk]
            if (-not $p) { break }
            if ($i -gt 0 -and $p.Name -match '^(claude|node)(\.exe)?$') { $runnerPid = $walk; break }
            $walk = $p.Parent
        }
    } catch {}

    $hubUrl = if ($env:ATRIUM_HUB_URL) { $env:ATRIUM_HUB_URL.TrimEnd('/') } else { 'http://localhost:7777' }

    $body = @{
        agent   = $agent
        event   = $Event
        runner  = 'claude'
        cwd     = $cwd
        pid     = $runnerPid
        task_id = "$($env:ATRIUM_TASK_ID)"
        resume  = if ($payload -and $payload.session_id) { "$($payload.session_id)" } else { '' }
        source  = if ($payload -and $payload.source) { "$($payload.source)" } else { '' }
    } | ConvertTo-Json -Compress

    Invoke-RestMethod -Uri "$hubUrl/session" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 3 | Out-Null
} catch {
    # Atrium not running, or not reachable. Nothing to do about it here.
}
try {
    $__sw.Stop()
    Add-Content -Path $__dbg -Value ("{0}  atrium-session  event={1}  {2:N0} ms" -f (Get-Date).ToString('o'), $Event, $__sw.Elapsed.TotalMilliseconds)
} catch {}
exit 0
