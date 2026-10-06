<#
.SYNOPSIS
    Fit the weekly meter against local API-equivalent cost, and predict when the week hits 100%.
.DESCRIPTION
    Reads ~/.claude/usage-log.jsonl (written by statusline-command.sh) for the seven_day percent over time,
    cuts it into intervals where the percent rose, and sums the transcript cost of each interval. Then it
    fits, by least squares through the origin:
      A. one weight:        delta% = k * cost
      B. one per model:     delta% = sum(k_model * cost_model)
      C. one per token class: delta% = sum(k_class * cost_class)   (input, cache write, cache read, output)
    Each fit prints its interval count and R^2, and says when it has too little data to mean anything.

    The prediction uses fit A when it is usable, else a single-point estimate: the current percent divided
    by the cost since the window started (this assumes the meter started the window at 0 and counts only
    Claude Code on this machine).
.EXAMPLE
    ./Get-BurnFit.ps1                                # fit on the log, predict from the newest percent
.EXAMPLE
    ./Get-BurnFit.ps1 -CurrentPct 98 -Model claude-opus-5-5,claude-sonnet-5
#>
[CmdletBinding()]
param(
    [string]$LogPath,
    [double]$CurrentPct = -1,
    [string[]]$Model,
    [double]$RateHours = 24,
    [int]$MinDelta = 1,
    [datetime]$Now = (Get-Date)
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\UsageCommon.ps1"
if (-not $LogPath) { $LogPath = $script:UsageLogPath }

# Least squares through the origin with a tiny ridge so a column of zeros cannot make it singular.
function Fit-Ls([double[][]]$X, [double[]]$y) {
    $n = $X.Count; $p = $X[0].Count
    $a = New-Object 'double[,]' $p, ($p + 1)
    for ($i = 0; $i -lt $p; $i++) {
        for ($j = 0; $j -lt $p; $j++) { $s = 0.0; for ($r = 0; $r -lt $n; $r++) { $s += $X[$r][$i] * $X[$r][$j] }; $a[$i, $j] = $s }
        $s = 0.0; for ($r = 0; $r -lt $n; $r++) { $s += $X[$r][$i] * $y[$r] }; $a[$i, $p] = $s
        $a[$i, $i] += 1e-9 * [math]::Max(1.0, $a[$i, $i])
    }
    for ($c = 0; $c -lt $p; $c++) {
        $piv = $c
        for ($r = $c + 1; $r -lt $p; $r++) { if ([math]::Abs($a[$r, $c]) -gt [math]::Abs($a[$piv, $c])) { $piv = $r } }
        for ($k = 0; $k -le $p; $k++) { $t = $a[$c, $k]; $a[$c, $k] = $a[$piv, $k]; $a[$piv, $k] = $t }
        if ([math]::Abs($a[$c, $c]) -lt 1e-15) { continue }
        for ($r = 0; $r -lt $p; $r++) {
            if ($r -eq $c) { continue }
            $f = $a[$r, $c] / $a[$c, $c]
            for ($k = $c; $k -le $p; $k++) { $a[$r, $k] -= $f * $a[$c, $k] }
        }
    }
    $w = for ($i = 0; $i -lt $p; $i++) { if ([math]::Abs($a[$i, $i]) -lt 1e-15) { 0.0 } else { $a[$i, $p] / $a[$i, $i] } }
    $w = [double[]]@($w)
    # Uncentered R^2, the right one for a fit through the origin.
    $ssr = 0.0; $sst = 0.0
    for ($r = 0; $r -lt $n; $r++) {
        $e = $y[$r]; for ($i = 0; $i -lt $p; $i++) { $e -= $w[$i] * $X[$r][$i] }
        $ssr += $e * $e; $sst += $y[$r] * $y[$r]
    }
    [pscustomobject]@{ W = $w; R2 = $(if ($sst -gt 0) { 1 - $ssr / $sst } else { $null }); N = $n }
}

# --- meter samples ----------------------------------------------------------------------------------------
$samples = @()
if (Test-Path $LogPath) {
    $samples = @(Get-Content $LogPath | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
        Where-Object { $_.seven_day_pct -ne $null -and $_.ts } | Sort-Object ts)
}
Write-Output "Log: $LogPath, $($samples.Count) samples"

$win = Get-WeekWindow -Now $Now
$recs = Get-UsageRecords -From $win.Start.AddDays(-7) -To $Now
$costed = foreach ($r in $recs) {
    $c = Get-UsageCost $r
    if ($null -eq $c) { continue }
    $parts = Get-UsageCostParts $r
    [pscustomobject]@{ Time = $r.Time; Model = $r.Model; IsSub = $r.IsSub; Cost = $c; Parts = $parts }
}
$costed = @($costed)

# --- intervals --------------------------------------------------------------------------------------------
# Within one reset window, an interval runs from one percent change to the next (merged until the rise is at
# least -MinDelta). Samples from different sessions carry the same account-wide percent, so all are pooled.
$intervals = [System.Collections.Generic.List[object]]::new()
foreach ($g in ($samples | Group-Object seven_day_resets_at)) {
    $pts = @($g.Group | Sort-Object ts)
    $start = $pts[0]
    foreach ($pt in $pts) {
        if ($pt.seven_day_pct -lt $start.seven_day_pct) { $start = $pt; continue }
        if ($pt.seven_day_pct - $start.seven_day_pct -ge $MinDelta) {
            $intervals.Add([pscustomobject]@{
                    T0 = [DateTimeOffset]::FromUnixTimeSeconds([long]$start.ts).LocalDateTime
                    T1 = [DateTimeOffset]::FromUnixTimeSeconds([long]$pt.ts).LocalDateTime
                    Delta = [double]($pt.seven_day_pct - $start.seven_day_pct)
                })
            $start = $pt
        }
    }
}
$models = @($costed | Group-Object Model | Sort-Object { ($_.Group | Measure-Object Cost -Sum).Sum } -Descending |
    ForEach-Object Name)
$classes = 'In', 'Cw', 'Cr', 'Out'
$rowsA = @(); $rowsB = @(); $rowsC = @(); $ys = @()
foreach ($iv in $intervals) {
    $in = @($costed | Where-Object { $_.Time -gt $iv.T0 -and $_.Time -le $iv.T1 })
    $rowsA += , [double[]]@([double](($in | Measure-Object Cost -Sum).Sum))
    $rowsB += , [double[]]@($models | ForEach-Object { $m = $_; [double](($in | Where-Object Model -eq $m | Measure-Object Cost -Sum).Sum) })
    $rowsC += , [double[]]@($classes | ForEach-Object { $c = $_; [double](($in | ForEach-Object { $_.Parts[$c] } | Measure-Object -Sum).Sum) })
    $ys += $iv.Delta
}

Write-Output "Intervals with a rise of >= $MinDelta%: $($intervals.Count)"
Write-Output ''
$kA = $null
function Show-Fit([string]$name, [string[]]$labels, $rows, [int]$minN) {
    $script:fit = $null
    if ($rows.Count -lt $minN) {
        Write-Output "$name : not fitted, $($rows.Count) intervals (needs at least $minN)."
        return
    }
    $f = Fit-Ls $rows ([double[]]$ys)
    $r2 = if ($null -ne $f.R2) { '{0:N2}' -f $f.R2 } else { 'n/a' }
    Write-Output "$name : $($f.N) intervals, R^2 $r2"
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $share = [double](($rows | ForEach-Object { $_[$i] } | Measure-Object -Sum).Sum)
        $total = [double](($rows | ForEach-Object { $_ } | Measure-Object -Sum).Sum)
        $note = if ($share -le 0) { '  (no data in any interval: weight meaningless)' }
            elseif ($share -lt 0.01 * $total) { '  (under 1% of the cost seen: weight unreliable)' } else { '' }
        Write-Output ('  {0,-18} {1,10:N4} % per $   ({2,8:N2} $ per 1%)   cost seen ${3:N2}{4}' -f `
                $labels[$i], $f.W[$i], $(if ($f.W[$i] -gt 0) { 1 / $f.W[$i] } else { [double]::NaN }), $share, $note)
    }
    $script:fit = $f
}
# Rough needs: about 10 intervals per weight, and for B and C the models / classes must vary independently
# across intervals, which only a mix of sessions over several days gives.
Show-Fit 'A (one weight)' @('all') $rowsA 5; $fA = $script:fit
Show-Fit 'B (per model)' $models $rowsB (10 * $models.Count)
Show-Fit 'C (per token class)' @('input', 'cache write', 'cache read', 'output') $rowsC 40
if ($fA -and $fA.W[0] -gt 0 -and $fA.N -ge 10) { $kA = $fA.W[0] }
Write-Output ''

# --- prediction -------------------------------------------------------------------------------------------
$last = $samples | Select-Object -Last 1
if ($CurrentPct -lt 0) {
    if (-not $last) { Write-Output 'No meter sample in the log. Pass -CurrentPct to predict.'; return }
    $CurrentPct = [double]$last.seven_day_pct
}
$sinceStart = @($costed | Where-Object { $_.Time -ge $win.Start -and $_.Time -le $Now })
$weekCost = [double](($sinceStart | Measure-Object Cost -Sum).Sum)
$how = 'fit A'
$k = $kA
if (-not $k) {
    if ($weekCost -le 0 -or $CurrentPct -le 0) { Write-Output 'No cost or percent to estimate from.'; return }
    $k = $CurrentPct / $weekCost
    $how = "single point: $CurrentPct% / `$$('{0:N2}' -f $weekCost) since $($win.Start.ToString('ddd HH:mm'))"
}
$left = [math]::Max(0, 100 - $CurrentPct)
Write-Output ("Meter now {0}%, window {1:ddd MM-dd HH:mm} to {2:ddd MM-dd HH:mm}, {3:N1} h left" -f `
        $CurrentPct, $win.Start, $win.End, ($win.End - $Now).TotalHours)
Write-Output ("Weight: {0:N4}% per `$ (`${1:N2} per 1%), from {2}" -f $k, (1 / $k), $how)
Write-Output ("Budget left: {0}% = about `${1:N2} API-equivalent" -f $left, ($left / $k))

$recent = @($costed | Where-Object { $_.Time -gt $Now.AddHours(-$RateHours) -and $_.Time -le $Now })
$rate = [double](($recent | Measure-Object Cost -Sum).Sum) / $RateHours
if ($rate -gt 0) {
    $hrs = $left / ($k * $rate)
    $eta = $Now.AddHours($hrs)
    $verdict = if ($eta -lt $win.End) { 'BEFORE the reset' } else { 'after the reset (the week does not run out)' }
    Write-Output ("At the last {0} h rate (`${1:N2}/h, {2:N2}%/h): 100% at {3:ddd MM-dd HH:mm}, {4}" -f `
            $RateHours, $rate, ($k * $rate), $eta, $verdict)
} else {
    Write-Output "No usage in the last $RateHours h, so no rate to extrapolate."
}

if (-not $Model) { $Model = $models }
Write-Output ''
Write-Output 'Calls that fit in the budget left, at this window''s average cost per main-session call:'
foreach ($m in $Model) {
    $mc = @($sinceStart | Where-Object { $_.Model -eq $m -and -not $_.IsSub })
    if (-not $mc) { $mc = @($sinceStart | Where-Object Model -eq $m) }
    if (-not $mc) { Write-Output ("  {0,-18} no calls this window" -f $m); continue }
    $avg = [double](($mc | Measure-Object Cost -Average).Average)
    Write-Output ("  {0,-18} `${1:N3}/call -> about {2:N0} calls" -f $m, $avg, ($left / $k / $avg))
}
