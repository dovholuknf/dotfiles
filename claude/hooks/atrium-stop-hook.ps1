# Delivers anything the human queued in atrium, at the moment a turn ends.
# Wire into Stop in settings.json.
#
# Why this exists: a claude session cannot be typed at from outside. The
# permission hook can carry a message back, but only when the session makes a
# tool call, and a session sitting idle makes none. Idle is exactly when you
# most want to reach it.
#
# Stop fires as a turn ends, and a Stop hook that blocks tells the model to keep
# going with the reason it was given. So a queued message is delivered as that
# reason and the session picks the work up, rather than going quiet with the
# message still sitting in a queue.
#
# Silent and exit 0 on any failure. A session must never fail to finish a turn
# because atrium was not listening.

$gate = "$($env:ATRIUM_PERM_GATE)".Trim().ToLower()
if ($gate -eq 'off') { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $null
    if ($raw) { $payload = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue }

    # Never loop. When this hook has already blocked, claude is continuing
    # because of us, and blocking again would keep it going forever.
    if ($payload -and $payload.stop_hook_active) { exit 0 }

    $cwd = if ($payload -and $payload.cwd) { "$($payload.cwd)" } else { (Get-Location).Path }
    $agent = if ($env:ATRIUM_AGENT_NAME) { $env:ATRIUM_AGENT_NAME } else { Split-Path -Leaf $cwd }

    $hubUrl = if ($env:ATRIUM_HUB_URL) { $env:ATRIUM_HUB_URL.TrimEnd('/') } else { 'http://localhost:7777' }
    $body = @{ agent = $agent } | ConvertTo-Json -Compress

    $resp = Invoke-RestMethod -Uri "$hubUrl/stop" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 3 -ErrorAction Stop

    # Nothing queued: let the turn end.
    if (-not $resp -or $resp.decision -ne 'block') { exit 0 }

    @{ decision = 'block'; reason = "$($resp.reason)" } | ConvertTo-Json -Compress
    exit 0
} catch {
    exit 0
}
