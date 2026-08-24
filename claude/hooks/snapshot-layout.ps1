# Throttled layout-history recorder. Wired into the UserPromptSubmit hook, so it
# runs on every claude turn -- but does real work only once every ~10 minutes.
# Each tick it appends the current window->tabs layout (from the ledger) to a
# rolling 1-day JSONL history, so the tab layout is restorable to any recent point
# even after the live registry churns (drag-kill, mass restart). Most invocations
# just read a stamp file and exit. Best-effort: never blocks claude, never throws.
$ErrorActionPreference = 'SilentlyContinue'
try {
    $wtRoot = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT.TrimEnd('\') } else { 'D:\worktrees' }
    $watch  = Join-Path $wtRoot 'watch'
    [System.IO.Directory]::CreateDirectory($watch) | Out-Null
    $stamp  = Join-Path $watch '.layout-snap-stamp'
    $hist   = Join-Path $watch 'layout-history.jsonl'
    $now    = Get-Date

    # Throttle: do nothing unless 10 minutes have passed since the last capture.
    if (Test-Path $stamp) {
        $last = $null
        try { $last = [datetime]::Parse((Get-Content $stamp -Raw).Trim()) } catch {}
        if ($last -and ($now - $last).TotalMinutes -lt 10) { exit 0 }
    }

    # Capture the current layout from the ledger: newest session per EXISTING
    # worktree (the working set), grouped by window. Paths/windows are stable even
    # when pids churn, so a history line stays restorable regardless of liveness.
    # Working set only: recently-active sessions (an open tab fires hooks, so its
    # LastStateChange is recent), newest per existing worktree. Without this, the
    # capture balloons to every worktree on disk.
    $recent = $now.AddHours(-18)
    $sessDir = Join-Path $wtRoot 'sessions'
    $seen = @{}
    $tabs = @()
    foreach ($f in (Get-ChildItem $sessDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not ($e.WtSession -and $e.WindowName -and $e.WorktreePath)) { continue }
        $last = if ($e.LastStateChange) { $e.LastStateChange } elseif ($e.LastSpawnedAt) { $e.LastSpawnedAt } else { $e.SpawnedAt }
        $lastDt = $null; try { $lastDt = [datetime]::Parse($last) } catch {}
        if (-not $lastDt -or $lastDt -lt $recent) { continue }
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

    # Prune history older than 1 day (rewrite the small file each capture).
    $cutoff = $now.AddDays(-1)
    $kept = @(Get-Content $hist -ErrorAction SilentlyContinue | Where-Object {
        if ($_ -match '"ts":"([^"]+)"') { try { ([datetime]::Parse($Matches[1])) -ge $cutoff } catch { $true } } else { $false }
    })
    Set-Content -Path $hist -Value $kept -Encoding UTF8
} catch {}
exit 0
