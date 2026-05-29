# D:\git\github\dovholuknf\dotfiles\powershell\onpath\weekly-disk-usage.ps1

$script = "D:\git\github\dovholuknf\dotfiles\powershell\onpath\disk-usage.ps1"
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
    & $script $o.Drive 2 -All | Out-File $o.File

    # Find the largest path in that drive's output and re-run at depth 2
    # against it. Append the deeper view to the same file so the snapshot
    # has a "and here's what's hogging the most space" follow-up.
    $topPath = $null
    $topGB   = 0.0
    foreach ($line in (Get-Content $o.File -ErrorAction SilentlyContinue)) {
        # Format-Table lines: "<path>  <GB>  <MB>  <Note>".
        # Match: capture path (greedy, may contain spaces), then GB + MB decimals.
        if ($line -match '^(?<path>[A-Za-z]:\\.*?)\s+(?<gb>\d+\.\d+)\s+(?<mb>\d+\.\d+)(\s|$)') {
            $gb = [double]$Matches.gb
            if ($gb -gt $topGB) {
                $topGB   = $gb
                $topPath = $Matches.path.TrimEnd()
            }
        }
    }
    if ($topPath -and (Test-Path -LiteralPath $topPath)) {
        Write-Host ("    -> drilling into top dir: $topPath ($topGB GB)") -ForegroundColor DarkGray
        Add-Content -Path $o.File -Value ""
        Add-Content -Path $o.File -Value "============================================================"
        Add-Content -Path $o.File -Value " depth=2 drill-down into top dir: $topPath ($topGB GB)"
        Add-Content -Path $o.File -Value "============================================================"
        & $script $topPath 2 -All | Out-File $o.File -Append
    } else {
        Write-Host "    (couldn't determine top dir for $($o.Drive) -- skipping drill-down)" -ForegroundColor DarkYellow
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