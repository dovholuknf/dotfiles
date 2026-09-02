# Throttled layout-history recorder. Wired into the UserPromptSubmit hook, so it
# runs on every claude turn -- but does real work only once every ~10 minutes.
# Each tick it appends the current window->tabs layout (from the ledger) to a
# rolling N-day JSONL history (default 7, so a week-plus vacation doesn't stomp it;
# override with GWT_LAYOUT_HISTORY_DAYS), so the tab layout is restorable to any
# recent point even after the live registry churns (drag-kill, mass restart). Most invocations
# just read a stamp file and exit. Best-effort: never blocks claude, never throws.
$ErrorActionPreference = 'SilentlyContinue'
try {
    $wtRoot = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT.TrimEnd('\') } else { 'D:\worktrees' }
    $watch  = Join-Path $wtRoot 'watch'
    [System.IO.Directory]::CreateDirectory($watch) | Out-Null
    $stamp  = Join-Path $watch '.layout-snap-stamp'
    $hist   = Join-Path $watch 'layout-history.jsonl'
    $now    = Get-Date

    # How many days of history to retain. Rolling window: each capture drops lines
    # older than this. Default 7 (survives a week-plus away); override via env.
    $retainDays = if ($env:GWT_LAYOUT_HISTORY_DAYS) { [int]$env:GWT_LAYOUT_HISTORY_DAYS } else { 7 }

    # Throttle: do nothing unless 10 minutes have passed since the last capture.
    if (Test-Path $stamp) {
        $last = $null
        try { $last = [datetime]::Parse((Get-Content $stamp -Raw).Trim()) } catch {}
        if ($last -and ($now - $last).TotalMinutes -lt 10) { exit 0 }
    }

    # Capture EVERY open tab: a session whose claude process is still ALIVE (pid
    # running), grouped by window, newest session per existing worktree. Liveness is
    # the right filter, not recency: it captures a tab left open and idle for days,
    # while still excluding dead/old worktrees, so the capture never balloons to every
    # worktree on disk. (An earlier version cut on an 18h LastStateChange window, which
    # wrongly dropped open-but-idle tabs.)
    #
    # Build a pid -> process map once so liveness is O(1) per ledger entry, and guard
    # pid reuse by matching the process StartTime to the session's recorded StartTime.
    $procById = @{}
    try { foreach ($pp in (Get-Process -ErrorAction SilentlyContinue)) { $procById[[int]$pp.Id] = $pp } } catch {}

    $sessDir = Join-Path $wtRoot 'sessions'
    $seen = @{}
    $tabs = @()
    foreach ($f in (Get-ChildItem $sessDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not ($e.WtSession -and $e.WindowName -and $e.WorktreePath)) { continue }
        if (-not ($e.Pid) -or [int]$e.Pid -eq 0) { continue }
        $proc = $procById[[int]$e.Pid]
        if (-not $proc) { continue }                 # pid not running -> tab not open
        if ($e.StartTime) {                          # guard pid reuse
            try { if ([math]::Abs(($proc.StartTime - [datetime]::Parse("$($e.StartTime)")).TotalSeconds) -gt 2) { continue } } catch {}
        }
        $p   = ($e.WorktreePath -replace '/', '\').TrimEnd('\')
        $key = $p.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        if (-not (Test-Path $p)) { continue }
        $seen[$key] = $true
        $lbl = if ($e.Label) { $e.Label } elseif ($e.Branch) { $e.Branch } else { Split-Path $p -Leaf }
        $tabs += [ordered]@{ win = "$($e.WindowName)"; label = "$lbl"; path = $p; ws = "$($e.WtSession)" }
    }

    # Always stamp (so we don't retry every turn), even if there was nothing to record.
    Set-Content -Path $stamp -Value $now.ToString('o') -Encoding ASCII
    if (-not $tabs.Count) { exit 0 }

    $line = ([ordered]@{ ts = $now.ToString('o'); tabs = $tabs } | ConvertTo-Json -Depth 5 -Compress)
    Add-Content -Path $hist -Value $line -Encoding UTF8

    # Prune history older than the retention window (rewrite the file each capture).
    $cutoff = $now.AddDays(-$retainDays)
    $kept = @(Get-Content $hist -ErrorAction SilentlyContinue | Where-Object {
        if ($_ -match '"ts":"([^"]+)"') { try { ([datetime]::Parse($Matches[1])) -ge $cutoff } catch { $true } } else { $false }
    })
    Set-Content -Path $hist -Value $kept -Encoding UTF8
} catch {}
exit 0
