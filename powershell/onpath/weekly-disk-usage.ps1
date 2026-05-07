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

& $script "C:\" 2 -All | Out-File "$outdir\disk-usage-C-$ts.txt"
& $script "D:\" 2 -All | Out-File "$outdir\disk-usage-D-$ts.txt"
& $script "V:\" 2 -All | Out-File "$outdir\disk-usage-V-$ts.txt"