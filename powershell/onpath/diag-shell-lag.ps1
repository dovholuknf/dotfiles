#requires -Version 7
# Snapshot the usual causes of an interactive pwsh session going sluggish over its
# lifetime. Run it IN the slow session (not a fresh tab) so the accumulated state
# is what gets measured. Nothing here changes state; it only reports.
#
#   diag-shell-lag.ps1
#
# Read the output top-down: the first block that looks off is almost always it.
# Rules of thumb on this box:
#   prompt render        > ~40 ms   -> the prompt is the drag (theme/banner/admin check)
#   history file lines   > ~10000   -> PSReadLine search/prediction is scanning a big file
#   PredictionSource     HistoryAndPlugin with a slow predictor -> per-keystroke cost
#   event subscribers    climbing across a session -> a leak re-registering handlers
#   working set / handles climbing steadily -> a real leak; compare two runs an hour apart

Write-Host "== shell lag diagnostic (run in the SLOW session) ==" -ForegroundColor Cyan
Write-Host ""

# 1. Prompt render cost -- runs on every command return, so it is felt constantly.
if (Get-Command _WtPrompt -ErrorAction SilentlyContinue) {
    $ms = (Measure-Command { for ($i = 0; $i -lt 5; $i++) { _WtPrompt | Out-Null } }).TotalMilliseconds / 5
    '{0,-32}{1,9:N1} ms  per render' -f 'prompt (_WtPrompt)', $ms
} else {
    '{0,-32}{1}' -f 'prompt (_WtPrompt)', 'not defined in this session'
}

# 2. PSReadLine: prediction source + history size drive per-keystroke latency.
$o = Get-PSReadLineOption
'{0,-32}{1}' -f 'PredictionSource',      $o.PredictionSource
'{0,-32}{1}' -f 'PredictionViewStyle',   $o.PredictionViewStyle
'{0,-32}{1}' -f 'MaximumHistoryCount',   $o.MaximumHistoryCount
'{0,-32}{1}' -f 'in-session history',    @(Get-History).Count
$hf = $o.HistorySavePath
if ($hf -and (Test-Path $hf)) {
    '{0,-32}{1:N0} lines  ({2})' -f 'history file', @(Get-Content -LiteralPath $hf).Count, $hf
}

# 3. Accumulators: these should stay flat across a session. Growth = a leak.
'{0,-32}{1}' -f 'event subscribers', @(Get-EventSubscriber).Count
'{0,-32}{1}' -f 'background jobs',   @(Get-Job).Count
'{0,-32}{1}' -f 'runspaces',         @(Get-Runspace).Count
'{0,-32}{1}' -f 'loaded modules',    @(Get-Module).Count

# 4. This process. Working set / handles / gen2 GCs climbing steadily is a leak.
$p = Get-Process -Id $PID
'{0,-32}{1:N0} MB' -f 'working set',       ($p.WorkingSet64      / 1MB)
'{0,-32}{1:N0} MB' -f 'private memory',    ($p.PrivateMemorySize64 / 1MB)
'{0,-32}{1:N0}'    -f 'handles',           $p.HandleCount
'{0,-32}{1:N0}'    -f 'threads',           $p.Threads.Count
'{0,-32}{1:N0}'    -f 'gen2 GC count',     [System.GC]::CollectionCount(2)

Write-Host ""
Write-Host "run it again after it feels slow again; the number that moved is the cause." -ForegroundColor DarkGray
