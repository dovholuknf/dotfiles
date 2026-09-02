# Atrium permission-gating hook. Fires as a claude-code PreToolUse hook.
#
# Activation is tri-state via $env:ATRIUM_PERM_GATE:
#   - 'on' / 'force' / '1' / 'true' / 'yes': gate EVERY session through the hub,
#     no .mcp.json required. Use this for permissions-only mode across a fleet of
#     agents that are not running the atrium submit loop.
#   - 'off': never gate; claude-code's normal permission flow runs unchanged.
#   - unset / anything else: auto-detect. Gate only sessions that have the
#     atrium-agent MCP wired in (an .mcp.json at cwd or any ancestor declaring
#     "atrium-agent"). This is the original Mode A behavior.
#
# What it does when active:
#   - reads the hook payload from stdin (JSON: tool_name, tool_input, ...)
#   - for Bash calls it POSTs the command to the atrium hub at /permission
#   - the POST blocks until the human at the hub types /approve N or /deny N
#   - emits a hookSpecificOutput block to stdout with permissionDecision set to
#     allow or deny, which claude-code obeys (skipping its own permission UI)
#   - when the human edited the request in the atrium board before approving it,
#     the hub returns a `command` field and the hook passes it through as
#     updatedInput, so what runs is what the human typed rather than what the
#     agent asked for
#
# Pair with the existing pre-tool-use-hook.ps1: chain both into PreToolUse.
# This script runs first; if it approves, the next hook still gets to refuse
# (footgun guard wins). If this one blocks, the chain short-circuits.

$gate = "$($env:ATRIUM_PERM_GATE)".Trim().ToLower()
if ($gate -eq 'off') { exit 0 }
$forceGate = @('on','force','1','true','yes') -contains $gate

# Walk up from cwd looking for an .mcp.json that references atrium-agent.
# That's the signal this session is an atrium-connected agent and gating is
# wanted. Cheap on every hook fire (small files, short walk).
function _AtriumWired {
    $dir = (Get-Location).Path
    while ($dir -and (Test-Path -LiteralPath $dir)) {
        $cfg = Join-Path $dir '.mcp.json'
        if (Test-Path -LiteralPath $cfg) {
            try {
                $contents = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop
                if ($contents -match 'atrium-agent') { return $true }
            } catch {}
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $false
}

$hubUrl = if ($env:ATRIUM_HUB_URL) { $env:ATRIUM_HUB_URL.TrimEnd('/') } else { 'http://localhost:7777' }

# What this session calls itself. Resolved before the gate check, because the
# daemon is asked about this exact name and `atrium join` uses the same rule.
$agentName = if ($env:ATRIUM_AGENT_NAME) {
    $env:ATRIUM_AGENT_NAME
} else {
    Split-Path -Leaf (Get-Location).Path
}

# Has this session joined atrium while running?
#
# Gating used to be decided once, here, from the environment, which fixed the
# answer for the life of the session. Asking the daemon is what makes
# `atrium join` and `atrium leave` take effect immediately. An unreachable
# daemon means no gating, matching the fail-open posture of the rest of this
# script.
function _AtriumJoined {
    param([string]$Name)
    try {
        $resp = Invoke-RestMethod -Uri "$hubUrl/gate?agent=$([uri]::EscapeDataString($Name))" `
            -Method Get -TimeoutSec 2 -ErrorAction Stop
        return [bool]$resp.gate
    } catch {
        return $false
    }
}

if (-not $forceGate -and -not (_AtriumWired) -and -not (_AtriumJoined $agentName)) { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $json = $raw | ConvertFrom-Json -ErrorAction Stop

    # Tools we DON'T gate. Two categories:
    #   1. Pure-read built-ins: Read, Grep, Glob, WebFetch, WebSearch, etc.
    #   2. MCP-provided tools (names prefixed with `mcp__`): trust comes from
    #      having the MCP wired into .mcp.json. Crucially this prevents the
    #      atrium-agent MCP's own `submit` from being gated, which would
    #      otherwise demand a permission on every loop turn.
    #   3. ToolSearch: claude's meta-tool for discovering other tools. No
    #      side effects; the eventual tool call is what gets gated.
    $skipTools = @('Read','Grep','Glob','WebFetch','WebSearch','TodoWrite','Task','ToolSearch')
    if ($skipTools -contains $json.tool_name) { exit 0 }
    if ("$($json.tool_name)" -like 'mcp__*') { exit 0 }

    $toolName = "$($json.tool_name)"
    $cmd = ''
    if ($json.tool_input) {
        # Each tool has its own input shape. Pick the most-useful field for
        # the human to look at in the hub.
        if ($json.tool_input.command)      { $cmd = "$($json.tool_input.command)" }
        elseif ($json.tool_input.file_path) {
            $cmd = "$($json.tool_input.file_path)"
            if ($json.tool_input.new_string) { $cmd += " <- (replace edit)" }
            if ($json.tool_input.content)    { $cmd += " <- (write " + ($json.tool_input.content.Length) + " chars)" }
        }
        elseif ($json.tool_input.url)        { $cmd = "$($json.tool_input.url)" }
        elseif ($json.tool_input.pattern)    { $cmd = "$($json.tool_input.pattern)" }
        else {
            # Fallback: dump the whole tool_input as compact JSON.
            $cmd = ($json.tool_input | ConvertTo-Json -Compress -Depth 4)
        }
    }
    $agent = if ($env:ATRIUM_AGENT_NAME) { $env:ATRIUM_AGENT_NAME } else { Split-Path -Leaf (Get-Location).Path }

    # Report the runner's own process, not this hook's. Atrium uses it to tell a
    # live session from a dead one by asking the operating system, which costs
    # nothing, rather than asking the runner, which would cost a turn.
    #
    # This script runs as a grandchild of the runner, so walk up the parent
    # chain until something that looks like the runner turns up. Best effort:
    # a pid of 0 just means atrium cannot check liveness for this session.
    $runnerPid = 0
    try {
        $walk = $PID
        for ($i = 0; $i -lt 6 -and $walk -gt 0; $i++) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$walk" -ErrorAction Stop
            if (-not $p) { break }
            if ($i -gt 0 -and $p.Name -match '^(claude|node)(\.exe)?$') { $runnerPid = [int]$p.ProcessId; break }
            $walk = [int]$p.ParentProcessId
        }
    } catch {}

    # What is actually changing. A path says which file, not what happens to
    # it, and "approve this edit" is not answerable without seeing the edit.
    # Capped so a huge write does not turn into a wall of text on the board.
    $maxDetail = 6000
    $details = ''
    if ($json.tool_input) {
        if ($json.tool_input.new_string -ne $null -or $json.tool_input.old_string -ne $null) {
            $old = "$($json.tool_input.old_string)"
            $new = "$($json.tool_input.new_string)"
            $details = "--- removing`n$old`n`n+++ adding`n$new"
        }
        elseif ($json.tool_input.content -ne $null) {
            $details = "+++ writing`n$($json.tool_input.content)"
        }
        elseif ($json.tool_input.edits) {
            # MultiEdit carries a list of replacements.
            $parts = foreach ($e in $json.tool_input.edits) {
                "--- removing`n$($e.old_string)`n`n+++ adding`n$($e.new_string)"
            }
            $details = ($parts -join "`n`n=== next edit ===`n`n")
        }
    }
    if ($details.Length -gt $maxDetail) {
        $details = $details.Substring(0, $maxDetail) +
            "`n`n... truncated, $($details.Length - $maxDetail) more characters"
    }

    $body = @{
        agent   = $agent
        tool    = $toolName
        command = $cmd
        pid     = $runnerPid
        cwd     = "$($json.cwd)"
        details = $details
    } | ConvertTo-Json -Compress

    # No client-side timeout: the hook blocks as long as it takes the human to
    # answer. Claude-code's own hook timeout (set in settings.json) is the upper
    # bound. If you want a deadline shorter than that, set ATRIUM_PERM_TIMEOUT
    # to a value parseable by [System.TimeSpan].
    $timeoutMs = 0
    if ($env:ATRIUM_PERM_TIMEOUT) {
        try { $timeoutMs = [int]([System.TimeSpan]::Parse($env:ATRIUM_PERM_TIMEOUT).TotalMilliseconds) } catch {}
    }

    $resp = Invoke-RestMethod -Uri "$hubUrl/permission" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec ($(if ($timeoutMs) { [int]($timeoutMs/1000) } else { 0 }))

    $decision = if ($resp.decision -eq 'approve') { 'approve' } else { 'block' }
    $reason   = if ($resp.reason) { $resp.reason } else { "via atrium hub" }

    # The hub returns a `command` field when the human edited the request before
    # approving it. Map that display string back onto the tool's own input
    # shape, mirroring how $cmd was built above. A rewrite only applies to an
    # approval: a block already carries its guidance in $reason.
    $updated = $null
    if ($decision -eq 'approve' -and $resp.command -and "$($resp.command)" -ne $cmd) {
        $edited = "$($resp.command)"
        $updated = @{}
        # Copy every original field first, then overwrite the edited one.
        # Sending a partial tool_input would drop the other arguments.
        if ($json.tool_input) {
            foreach ($p in $json.tool_input.PSObject.Properties) { $updated[$p.Name] = $p.Value }
        }
        if ($json.tool_input.command) {
            $updated['command'] = $edited
        }
        elseif ($json.tool_input.file_path) {
            # File tools are shown as `<path> <- (what is happening)`. Only the
            # path is real input, so drop the annotation before using it.
            $sep = $edited.IndexOf(' <- ')
            $updated['file_path'] = if ($sep -ge 0) { $edited.Substring(0, $sep).Trim() } else { $edited.Trim() }
        }
        elseif ($json.tool_input.url)     { $updated['url'] = $edited }
        elseif ($json.tool_input.pattern) { $updated['pattern'] = $edited }
        else {
            # The fallback path showed raw JSON, so an edit has to parse back as
            # JSON or there is nothing safe to do with it.
            try {
                $parsed = $edited | ConvertFrom-Json -ErrorAction Stop
                $updated = @{}
                foreach ($p in $parsed.PSObject.Properties) { $updated[$p.Name] = $p.Value }
            } catch { $updated = $null }
        }
    }

    # Current hook output shape. permissionDecision replaces the older
    # decision/reason pair, and updatedInput is the only way to rewrite what
    # actually runs.
    $hookOut = @{
        hookEventName            = 'PreToolUse'
        permissionDecision       = $(if ($decision -eq 'approve') { 'allow' } else { 'deny' })
        permissionDecisionReason = $reason
    }
    if ($updated) { $hookOut['updatedInput'] = $updated }

    @{ hookSpecificOutput = $hookOut } | ConvertTo-Json -Compress -Depth 8
    exit 0
} catch {
    # Hub unreachable / hook borked: fail OPEN (let claude's normal permission
    # flow handle it). Failing closed would brick the agent any time atrium
    # isn't running, which is worse than a brief lapse in centralized gating.
    exit 0
}
