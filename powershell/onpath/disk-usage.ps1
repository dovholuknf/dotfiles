param(
    [Parameter(Position = 0)]
    [string]$Path = ".",

    [Parameter(Position = 1)]
    [int]$Depth = 1,

    # roll items below this many MB into a single "[N other items < <MinMB>MB each]" summary row.
    # default is 1MB so the noise floor is hidden; pass -All to disable, or set explicitly.
    [int]$MinMB = 1,

    # show only the top N items by size; fold the rest into the summary row.
    # 0 (default) = unlimited.
    [int]$Top = 0,

    # show everything -- disables the default 1MB floor and any -Top truncation.
    [switch]$All
)

if ($All) {
    $MinMB = 0
    $Top   = 0
}

$Path = (Resolve-Path -LiteralPath $Path).Path
if ($Path -notmatch '^[A-Za-z]:\\$') {
    $Path = $Path.TrimEnd('\')
}

# warn if the root itself is a reparse point — walking through it double-counts whatever
# lives at the link target, which is almost never what the user wants.
try {
    $rootInfo = [System.IO.DirectoryInfo]::new($Path)
    if (($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $target = try { $rootInfo.LinkTarget } catch { $null }
        Write-Host ""
        Write-Host "warning: '$Path' is a reparse point" -ForegroundColor Yellow
        if ($target) {
            Write-Host "         --> $target" -ForegroundColor Yellow
        }
        Write-Host "         scanning through it will measure the link target, not new storage." -ForegroundColor DarkYellow
        $resp = Read-Host "continue anyway? (y/N)"
        if ($resp -notmatch '^[Yy]$') {
            Write-Host "aborted." -ForegroundColor DarkGray
            return
        }
    }
} catch {}

$script:skippedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:progressIdx  = 0

function Test-Reparse {
    param([System.IO.DirectoryInfo]$Info)
    return ($Info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
}

function Get-ReparseNote {
    param([System.IO.DirectoryInfo]$Info)
    try {
        $t = $Info.LinkTarget
        if ($t) { return "--> $t" }
    } catch {}
    return "--> reparse point"
}

# recursive byte count; silently skips reparse points (avoids loops / cloud hydration).
# genuine failures (ACL denied, etc.) land in $script:skippedPaths.
function Measure-DirSize {
    param([string]$Dir, [string]$TopDisplay)
    $total = 0L
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Dir)) {
            try {
                $total += [System.IO.FileInfo]::new($f).Length
                $script:progressIdx++
                if (($script:progressIdx % 1000) -eq 0) {
                    Write-Progress -Activity "Calculating disk usage" `
                        -Status ("{0} | {1} files" -f $TopDisplay, $script:progressIdx) `
                        -PercentComplete -1
                }
            } catch {
                [void]$script:skippedPaths.Add($f)
            }
        }
        foreach ($sd in [System.IO.Directory]::EnumerateDirectories($Dir)) {
            try {
                $di = [System.IO.DirectoryInfo]::new($sd)
                if (Test-Reparse $di) { continue }
                $total += Measure-DirSize -Dir $sd -TopDisplay $TopDisplay
            } catch {
                [void]$script:skippedPaths.Add($sd)
            }
        }
    } catch {
        [void]$script:skippedPaths.Add($Dir)
    }
    return $total
}

# return dirs at exactly $Remaining levels under $Root, plus any reparse points
# encountered on the way (surfaced as stop-points so they appear in the output).
function Get-DirsAtDepth {
    param([string]$Root, [int]$Remaining)
    $out = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($sd in [System.IO.Directory]::EnumerateDirectories($Root)) {
            $di = $null
            try { $di = [System.IO.DirectoryInfo]::new($sd) } catch {
                [void]$script:skippedPaths.Add($sd); continue
            }
            $isReparse = Test-Reparse $di
            if ($Remaining -le 1 -or $isReparse) {
                $out.Add([PSCustomObject]@{ Path = $sd; Info = $di; IsReparse = $isReparse })
            } else {
                foreach ($x in (Get-DirsAtDepth -Root $sd -Remaining ($Remaining - 1))) {
                    $out.Add($x)
                }
            }
        }
    } catch {
        [void]$script:skippedPaths.Add($Root)
    }
    return $out
}

$targets = Get-DirsAtDepth -Root $Path -Remaining $Depth

$results = foreach ($t in $targets) {
    if ($t.IsReparse) {
        [PSCustomObject]@{
            Path = $t.Path
            GB   = 0.00
            MB   = 0.00
            Note = (Get-ReparseNote -Info $t.Info)
        }
    } else {
        $size = Measure-DirSize -Dir $t.Path -TopDisplay $t.Path
        [PSCustomObject]@{
            Path = $t.Path
            GB   = [math]::Round(($size / 1GB), 2)
            MB   = [math]::Round(($size / 1MB), 2)
            Note = ''
        }
    }
}

Write-Progress -Activity "Calculating disk usage" -Completed

# Sort all results by size. With no filter, reparse rows are kept visible
# (they're informational). With -Top or -MinMB, they go through the same
# pipeline and being size 0 they naturally fold into the summary.
$sorted     = @($results | Sort-Object MB -Descending)
$filterMode = ($Top -gt 0) -or ($MinMB -gt 0)

if ($filterMode) {
    $kept   = $sorted
    $folded = @()
    if ($Top -gt 0 -and $kept.Count -gt $Top) {
        $folded += $kept | Select-Object -Skip $Top
        $kept    = $kept | Select-Object -First $Top
    }
    if ($MinMB -gt 0) {
        $folded += $kept | Where-Object { $_.MB -lt $MinMB }
        $kept    = $kept | Where-Object { $_.MB -ge $MinMB }
    }
} else {
    $kept   = $sorted
    $folded = @()
}

$display = @()
$display += $kept
if ($folded.Count -gt 0) {
    $foldedTotal = ($folded | Measure-Object -Sum MB).Sum
    $note = if ($MinMB -gt 0) { "$($folded.Count) folded items < ${MinMB}MB each" } else { "$($folded.Count) folded items below top $Top" }
    $display += [PSCustomObject]@{
        Path = "[+ $($folded.Count) other items]"
        GB   = [math]::Round(($foldedTotal / 1024), 2)
        MB   = [math]::Round($foldedTotal, 2)
        Note = $note
    }
}

$display | Format-Table -AutoSize

if ($script:skippedPaths.Count -gt 0) {
    Write-Host ""
    Write-Host ("skipped {0} path(s) — access denied or unreadable:" -f $script:skippedPaths.Count) -ForegroundColor DarkYellow
    $script:skippedPaths | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}
