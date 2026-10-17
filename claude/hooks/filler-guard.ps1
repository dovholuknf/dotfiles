# UserPromptSubmit hook. Injects the clock and a one-line filler-word reminder into context each
# turn. Hooks never see Claude's replies, so this cannot flag usage after the fact.
# It keeps the ban in recent context, where the drift actually happens. Best-effort:
# stdout becomes additional context, and it never blocks the turn.
# SCOPE: chat replies to the user only. NOT prose authored into files/docs/commits.
. "$PSScriptRoot\hook-timing.ps1" -HookName 'filler-guard'
try {
    # The clock rides along so a session never spends a tool call on 'date'. The atrium orchestrator made 32 bare
    # date/Get-Date calls in 1000. Kept in this hook to avoid a second pwsh spawn per prompt.
    $tz = [TimeZoneInfo]::Local
    $name = if ($tz.IsDaylightSavingTime((Get-Date))) { $tz.DaylightName } else { $tz.StandardName }
    $zone = if ($name -match '\s') { -join ($name -split '\s+' | ForEach-Object { $_[0] }) } else { $name }
    Write-Output "now: $((Get-Date).ToString('yyyy-MM-dd ddd HH:mm')) $zone"
    Write-Output "reminder (applies to your REPLIES TO ME, not prose you author into files/docs/commits): in replies, every word must be load-bearing. cut hedges, throat-clearing, and editorializing adjectives (honest, genuinely, worth noting, surely, 'real'/'clean'/'robust', reflexive status sign-offs). if removing a word loses no meaning, remove it."
} finally { Complete-HookTiming }
exit 0
