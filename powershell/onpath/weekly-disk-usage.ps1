# D:\git\github\dovholuknf\dotfiles\powershell\onpath\weekly-disk-usage.ps1

$script = "D:\git\github\dovholuknf\dotfiles\powershell\onpath\disk-usage.ps1"
$outdir = "C:\temp"
$ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

New-Item -ItemType Directory -Force -Path $outdir | Out-Null

& $script "C:\" 2 | Out-File "$outdir\disk-usage-C-$ts.txt"
& $script "D:\" 2 | Out-File "$outdir\disk-usage-D-$ts.txt"
& $script "V:\" 2 | Out-File "$outdir\disk-usage-V-$ts.txt"