param(
    [Parameter(Position = 0)]
    [string]$Path = ".",

    [Parameter(Position = 1)]
    [int]$Depth = 1
)

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

$results | Sort-Object MB -Descending | Format-Table -AutoSize

if ($script:skippedPaths.Count -gt 0) {
    Write-Host ""
    Write-Host ("skipped {0} path(s) — access denied or unreadable:" -f $script:skippedPaths.Count) -ForegroundColor DarkYellow
    $script:skippedPaths | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}
