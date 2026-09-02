# Tells atrium what this session is doing right now.
#
# Wire into PreToolUse, PostToolUse, UserPromptSubmit and SubagentStop in
# settings.json, passing -Event to match.
#
# Why: a card in "running" looks identical whether its session is grinding
# through a build, thinking, waiting on four subagents, or hung. That is the
# difference between leaving it alone and going to look at it, and without this
# the only way to tell is to attach to the session.
#
# FIRE AND FORGET. This is the load-bearing property, not a nicety.
#
# This runs before every single tool call in every session. The failure that
# hurts is not a slow answer, it is no answer: a daemon that is reachable but
# stalled, a listener that accepts and never replies, a machine under load.
# Waiting on any of those would add latency to every tool call everywhere. So
# the timeout is one second, every failure is swallowed, and nothing downstream
# reads the result. A session that never manages one successful post works
# exactly as it did before this file existed.
#
# Losing activity is the cheapest failure available. The card goes back to
# saying nothing, which is what it said before, and the daemon expires a stale
# activity on its own.
#
# Do not add a retry here. Do not raise the timeout. Do not log on failure. A
# hook that runs this often has no room for any of it.

param(
    [ValidateSet('tool-start', 'tool-end', 'prompt', 'subagent-end', 'idle', 'waiting')]
    [string]$Event = 'tool-start'
)

$gate = "$($env:ATRIUM_PERM_GATE)".Trim().ToLower()
if ($gate -eq 'off') { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $null
    if ($raw) { $payload = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue }

    $cwd = if ($payload -and $payload.cwd) { "$($payload.cwd)" } else { (Get-Location).Path }
    $agent = if ($env:ATRIUM_AGENT_NAME) { $env:ATRIUM_AGENT_NAME } else { Split-Path -Leaf $cwd }

    # The tool name is what makes "running Bash" possible rather than just
    # "busy". Only PreToolUse carries one.
    $tool = ''
    if ($payload -and $payload.tool_name) { $tool = "$($payload.tool_name)" }

    $hubUrl = if ($env:ATRIUM_HUB_URL) { $env:ATRIUM_HUB_URL.TrimEnd('/') } else { 'http://localhost:7777' }
    $body = @{
        agent   = $agent
        task_id = "$($env:ATRIUM_TASK_ID)"
        event   = $Event
        tool    = $tool
    } | ConvertTo-Json -Compress

    Invoke-RestMethod -Uri "$hubUrl/activity" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 1 -ErrorAction Stop | Out-Null
} catch {
    # Every failure lands here on purpose, and nothing happens. See the header.
}
exit 0
