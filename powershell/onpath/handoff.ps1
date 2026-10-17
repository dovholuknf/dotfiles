#requires -Version 7
# Read or append a session HANDOFF.md in one call. Replaces the hand-rolled
# 'date; Get-Content HANDOFF.md -TotalCount N' reads and '$c[0..2] + "## ..."' prepends that
# the atrium orchestrator repeated about 60 times in 1000 calls.
#
# The file shape it expects: an optional pinned preamble of '# ' lines at the top, then entries
# newest first. -Add inserts '## <date> <HH:mm> <zone>: <text>' right after the preamble.
#
#   handoff                       # print the clock, then the top 40 lines
#   handoff -Lines 80             # more lines
#   handoff -Add 'landed 9d749e57, sgg free'
#   handoff -Path D:\x\HANDOFF.md # any file. Default: <git toplevel>\.uncommitted\notes\HANDOFF.md
param(
    [string]$Add,
    [string]$Path,
    [int]$Lines = 40
)

if (-not $Path) {
    $top = "$(git rev-parse --show-toplevel 2>$null)".Trim()
    if (-not $top) { Write-Error 'handoff: not in a git repo. Pass -Path.'; exit 1 }
    $Path = Join-Path $top '.uncommitted\notes\HANDOFF.md'
}

$now  = Get-Date
$tz   = [TimeZoneInfo]::Local
$name = if ($tz.IsDaylightSavingTime($now)) { $tz.DaylightName } else { $tz.StandardName }
# 'Eastern Daylight Time' -> 'EDT'. A name that is already short stays as is.
$zone = if ($name -match '\s') { -join ($name -split '\s+' | ForEach-Object { $_[0] }) } else { $name }
$clock = $now.ToString('yyyy-MM-dd ddd HH:mm') + " $zone"

if ($Add) {
    $dir = Split-Path $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $body = @(if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path })
    $i = 0
    while ($i -lt $body.Count -and $body[$i] -match '^# ') { $i++ }
    $entry = "## $($now.ToString('yyyy-MM-dd HH:mm')) ${zone}: $Add"
    $head = if ($i) { @($body[0..($i - 1)]) + '' } else { @() }
    $j = $i
    while ($j -lt $body.Count -and $body[$j] -eq '') { $j++ }
    $rest = if ($j -lt $body.Count) { @($body[$j..($body.Count - 1)]) } else { @() }
    Set-Content -LiteralPath $Path -Value (@($head) + $entry + @($rest))
    Write-Output "added to ${Path}: $entry"
    exit 0
}

Write-Output "now: $clock"
if (-not (Test-Path -LiteralPath $Path)) { Write-Output "handoff: $Path does not exist"; exit 0 }
Get-Content -LiteralPath $Path -TotalCount $Lines
