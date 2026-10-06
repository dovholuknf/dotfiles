<#
.SYNOPSIS
    Check that Get-BurnFit.ps1 recovers known weights from a synthetic meter.
.DESCRIPTION
    Builds a fake usage log from this window's real transcripts: the meter is the running cost divided by
    -DollarsPerPct, with -Model's cost weighted by -Factor, sampled at most every 2 minutes and floored to
    whole percents like the real meter. Then runs the fit on it. Fit B should report about
    Factor/DollarsPerPct for -Model and 1/DollarsPerPct for the rest. Writes only to a temp file.
#>
[CmdletBinding()]
param(
    [double]$DollarsPerPct = 22,
    [string]$Model = 'claude-opus-5-5',
    [double]$Factor = 1.5
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\UsageCommon.ps1"

$w = Get-WeekWindow
$reset = [DateTimeOffset]::new($w.End).ToUnixTimeSeconds()
$cum = 0.0; $lastTs = 0
$lines = foreach ($r in (Get-UsageRecords -From $w.Start -To (Get-Date))) {
    $c = Get-UsageCost $r
    if ($null -eq $c) { continue }
    if ($r.Model -eq $Model) { $c *= $Factor }
    $cum += $c
    $ts = [DateTimeOffset]::new($r.Time).ToUnixTimeSeconds()
    if ($ts - $lastTs -lt 120) { continue }
    $lastTs = $ts
    @{ ts = $ts; seven_day_pct = [math]::Floor($cum / $DollarsPerPct); seven_day_resets_at = $reset } |
        ConvertTo-Json -Compress
}
$log = Join-Path ([IO.Path]::GetTempPath()) 'usage-burnfit-synthetic.jsonl'
$lines | Set-Content $log
Write-Output ("Expect fit B: {0} ~ {1:N4} % per `$, others ~ {2:N4}" -f $Model, ($Factor / $DollarsPerPct), (1 / $DollarsPerPct))
Write-Output ''
& "$PSScriptRoot\Get-BurnFit.ps1" -LogPath $log -Model $Model
Remove-Item $log
