<#
.SYNOPSIS
Find (and optionally remove) orphan claude-code project transcript dirs.

.DESCRIPTION
Claude Code stashes per-cwd transcripts in $env:USERPROFILE\.claude\projects\<encoded-cwd>.
When a gwt worktree is pruned the matching transcript dir is left behind. This script
walks projects\, tries to decode each entry back to a real path, and lists the ones
that no longer resolve.

By default only entries whose encoded name starts with a worktree-style prefix
('D--worktrees-' etc.) are considered, so transcripts from random cwds are left alone.

.PARAMETER Apply
Actually delete the orphan dirs. Without this, the script is read-only.

.PARAMETER All
Consider every encoded name, not just the worktree-rooted ones. Use with care.
#>
param(
    [switch]$Apply,
    [switch]$All
)

function Try-DecodeProjectDir([string]$name) {
    # Encoding: <drive>:\<path-with-\-as-> -> <drive>--<path-with-\-and-:-collapsed-to-->.
    # Reverse is ambiguous (hyphens in dir names look like separators), so brute-force
    # all interpretations and accept the first one Test-Path agrees with.
    if ($name -notmatch '^([A-Za-z])--(.+)$') { return $null }
    $drive = $Matches[1]
    $rest  = $Matches[2]
    $parts = $rest.Split('-')
    $n = $parts.Count
    $combos = [int][Math]::Pow(2, $n - 1)
    for ($mask = 0; $mask -lt $combos; $mask++) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("${drive}:\")
        [void]$sb.Append($parts[0])
        for ($i = 1; $i -lt $n; $i++) {
            $bit = ($mask -shr ($i - 1)) -band 1
            if ($bit) { [void]$sb.Append('\') } else { [void]$sb.Append('-') }
            [void]$sb.Append($parts[$i])
        }
        $cand = $sb.ToString()
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $null
}

$projDir = Join-Path $env:USERPROFILE '.claude\projects'
if (-not (Test-Path $projDir)) {
    Write-Host "no projects dir at $projDir" -ForegroundColor DarkGray
    return
}

$filter = if ($All) { '^[A-Za-z]--' } else { '^[A-Za-z]--worktrees' }
$dirs = Get-ChildItem $projDir -Directory | Where-Object { $_.Name -match $filter }

$orphans = @()
$live    = @()
foreach ($d in $dirs) {
    $decoded = Try-DecodeProjectDir $d.Name
    if ($decoded) { $live    += [PSCustomObject]@{ Encoded = $d.Name; Path = $decoded; Dir = $d } }
    else          { $orphans += $d }
}

Write-Host ("LIVE ({0}):" -f $live.Count) -ForegroundColor Green
$live | Sort-Object Encoded | ForEach-Object {
    Write-Host ("  {0} -> {1}" -f $_.Encoded, $_.Path) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host ("ORPHAN ({0}):" -f $orphans.Count) -ForegroundColor Yellow
$totalBytes = 0L
$totalFiles = 0
foreach ($o in $orphans | Sort-Object Name) {
    $files = Get-ChildItem $o.FullName -Recurse -File -ErrorAction SilentlyContinue
    $sz = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sz) { $sz = 0 }
    $totalBytes += $sz
    $totalFiles += $files.Count
    Write-Host ("  {0,9:N0} KB  {1,4} files  {2}" -f ($sz/1KB), $files.Count, $o.Name)
}
Write-Host ''
Write-Host ("Total: {0} dirs, {1} files, {2:N1} MB" -f $orphans.Count, $totalFiles, ($totalBytes/1MB)) -ForegroundColor Yellow

if (-not $Apply) {
    Write-Host ''
    Write-Host "Read-only run. Re-run with -Apply to delete." -ForegroundColor Cyan
    return
}

Write-Host ''
Write-Host "Deleting $($orphans.Count) orphan dirs..." -ForegroundColor Red
foreach ($o in $orphans) {
    try {
        Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction Stop
        Write-Host "  removed $($o.Name)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  FAILED $($o.Name): $_" -ForegroundColor Red
    }
}
Write-Host "done." -ForegroundColor Green
