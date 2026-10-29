# UserPromptSubmit hook. Injects the clock into context each turn, so a session never spends a tool call on 'date'.
# The atrium orchestrator made 32 bare date/Get-Date calls in 1000 before this. Best-effort: stdout becomes
# additional context, and it never blocks the turn.
. "$PSScriptRoot\hook-timing.ps1" -HookName 'filler-guard'
try {
    $tz = [TimeZoneInfo]::Local
    $name = if ($tz.IsDaylightSavingTime((Get-Date))) { $tz.DaylightName } else { $tz.StandardName }
    $zone = if ($name -match '\s') { -join ($name -split '\s+' | ForEach-Object { $_[0] }) } else { $name }
    Write-Output "now: $((Get-Date).ToString('yyyy-MM-dd ddd HH:mm')) $zone"
} finally { Complete-HookTiming }
exit 0
