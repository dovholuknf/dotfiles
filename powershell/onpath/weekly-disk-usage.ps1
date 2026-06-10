# $env:ON_PATH\weekly-disk-usage.ps1

$onPath = if ($env:ON_PATH) { $env:ON_PATH.TrimEnd('\') } else { $PSScriptRoot }
$script = "$onPath\disk-usage.ps1"
$outdir = "V:\disk-usage-history"
$ts     = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " weekly-disk-usage scheduled task" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " what:    snapshot disk usage of C:\, D:\, V:\ to text files" -ForegroundColor DarkGray
Write-Host " where:   $outdir" -ForegroundColor DarkGray
Write-Host " when:    weekly (Mondays 8am) -- registered as 'weekly-disk-usage'" -ForegroundColor DarkGray
Write-Host " script:  $PSCommandPath" -ForegroundColor DarkGray
Write-Host ""
Write-Host " to remove the task:" -ForegroundColor Yellow
Write-Host "   Unregister-ScheduledTask -TaskName weekly-disk-usage -Confirm:`$false" -ForegroundColor Yellow
Write-Host " to inspect / change schedule:" -ForegroundColor Yellow
Write-Host "   Get-ScheduledTask -TaskName weekly-disk-usage" -ForegroundColor Yellow
Write-Host "   taskschd.msc                 (GUI)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Force -Path $outdir | Out-Null

$outputs = @(
    @{ Drive = 'C:\'; File = "$outdir\disk-usage-C-$ts.txt" }
    @{ Drive = 'D:\'; File = "$outdir\disk-usage-D-$ts.txt" }
    @{ Drive = 'V:\'; File = "$outdir\disk-usage-V-$ts.txt" }
)

foreach ($o in $outputs) {
    Write-Host "  snapshotting $($o.Drive) ..." -ForegroundColor DarkGray
    & $script $o.Drive 2 -MinMB 10 | Out-File $o.File

    # Parse the top-level table to find the biggest entries, then drill into
    # each. Append every drill-down to the same file. Items that turn out to be
    # files (or empty / unreadable) produce a "no children" note instead of
    # silently failing.
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content $o.File -ErrorAction SilentlyContinue)) {
        # Format-Table lines: "<path>  <GB>  <MB>  <Note>".
        if ($line -match '^(?<path>[A-Za-z]:\\.*?)\s+(?<gb>\d+\.\d+)\s+(?<mb>\d+\.\d+)(\s|$)') {
            $candidates.Add([PSCustomObject]@{
                Path = $Matches.path.TrimEnd()
                GB   = [double]$Matches.gb
            })
        }
    }
    # Top 5 by size, skipping anything that isn't a directory (files have no
    # children to drill into) and any synthesized rows like "[+ N other items]".
    $topN = @($candidates |
        Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Container) } |
        Sort-Object GB -Descending |
        Select-Object -First 5)

    if (-not $topN.Count) {
        Write-Host "    (no drillable directories found for $($o.Drive))" -ForegroundColor DarkYellow
        continue
    }
    foreach ($c in $topN) {
        Write-Host ("    -> drilling into: {0} ({1} GB)" -f $c.Path, $c.GB) -ForegroundColor DarkGray
        Add-Content -Path $o.File -Value ""
        Add-Content -Path $o.File -Value "============================================================"
        Add-Content -Path $o.File -Value (" depth=2 drill-down: {0} ({1} GB)" -f $c.Path, $c.GB)
        Add-Content -Path $o.File -Value "============================================================"
        & $script $c.Path 2 -MinMB 10 | Out-File $o.File -Append
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " summary -- weekly-disk-usage finished $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
foreach ($o in $outputs) {
    $exists = Test-Path $o.File
    if ($exists) {
        $sizeKB = [int]((Get-Item $o.File).Length / 1KB)
        $lines  = (Get-Content $o.File | Measure-Object -Line).Lines
        Write-Host ("  {0,-4}  {1,6} KB  {2,5} lines  ->  {3}" -f $o.Drive, $sizeKB, $lines, $o.File) -ForegroundColor White
    } else {
        Write-Host ("  {0,-4}  FAILED -- no output file at {1}" -f $o.Drive, $o.File) -ForegroundColor Red
    }
}
Write-Host ""

# Re-print the management banner so it's visible at the end too.
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " to remove the task:" -ForegroundColor Yellow
Write-Host "   Unregister-ScheduledTask -TaskName weekly-disk-usage -Confirm:`$false" -ForegroundColor Yellow
Write-Host " to inspect / change schedule:" -ForegroundColor Yellow
Write-Host "   Get-ScheduledTask -TaskName weekly-disk-usage" -ForegroundColor Yellow
Write-Host "   taskschd.msc                 (GUI)" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Hold the window open. Three guards to avoid hanging headless runs:
#   1. UserInteractive    -- false for "Run whether user is logged on or not"
#   2. !IsInputRedirected -- piped/file-redirected stdin can't take Enter
#   3. Host.Name == ConsoleHost -- excludes ISE / VS Code integrated terminal
# When all three pass we use a real blocking Read-Host (sits there forever
# until you press Enter). A 2-hour belt-and-suspenders timeout fires only
# if KeyAvailable polling is the only thing that ever returns -- under a
# normal pwsh console window, the inner Read-Host wins long before that.
$canPrompt = $false
try {
    $canPrompt = [Environment]::UserInteractive -and `
                 -not [Console]::IsInputRedirected -and `
                 $Host.Name -eq 'ConsoleHost'
} catch { $canPrompt = $false }

if ($canPrompt) {
    Write-Host "press Enter to close (window stays open; 2h hard cap)" -ForegroundColor DarkGray
    $deadline = (Get-Date).AddHours(2)
    try {
        # Tight loop on KeyAvailable so the timeout is enforceable. Under
        # Task Scheduler -> visible pwsh window this happily sits for hours.
        while ((Get-Date) -lt $deadline) {
            if ($Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                if ($key.VirtualKeyCode -eq 13) { break }   # Enter
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        # If KeyAvailable isn't supported (no real console attached) fall out.
    }
}