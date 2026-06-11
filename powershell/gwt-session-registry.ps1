# gwt-session-registry.ps1 -- registry of running Claude sessions launched via
# gwt / claudeshell. Source from $PROFILE so every spawned shell auto-registers.
#
# usage (in $PROFILE):
#   . "$PSScriptRoot\gwt-session-registry.ps1"
#
# the spawned shell calls _RegisterGwtSession at startup; an exit hook removes
# the entry on clean exit. on reboot or window-close-by-X, entries remain
# stale -- gwt sessions list/restore handles them.

$script:WtRoot        = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT.TrimEnd('\') } else { 'D:\worktrees' }
$script:GwtSessionDir = "$script:WtRoot\sessions"

function _Ensure-GwtSessionDir {
    if (-not (Test-Path $script:GwtSessionDir)) {
        [System.IO.Directory]::CreateDirectory($script:GwtSessionDir) | Out-Null
    }
}

function _InvokeGwtSpawn {
    # All-in-one spawn helper called by the encoded command. Reads the
    # pre-written session entry, registers PID, applies theme, cds, invokes
    # claude with --continue and any saved prompt. Keeps the encoded command
    # tiny so it fits through runas's ~1024-char limit.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Id)

    _Ensure-GwtSessionDir
    _RegisterGwtSession -Id $Id

    $file  = Join-Path $script:GwtSessionDir "$Id.json"
    $entry = Get-Content $file -Raw | ConvertFrom-Json

    # Apply theme based on the saved WindowName. The window->theme mapping
    # lives in claude-shell.ps1's _GetThemeFnForWindow as the single source of
    # truth -- delegate to it rather than duplicating the switch here.
    $themeFn = if (Get-Command _GetThemeFnForWindow -ErrorAction SilentlyContinue) {
        _GetThemeFnForWindow $entry.WindowName
    } else { $null }
    if ($themeFn -and (Get-Command $themeFn -ErrorAction SilentlyContinue)) {
        & $themeFn
    }

    # cd to the worktree
    if ($entry.WorktreePath -and (Test-Path $entry.WorktreePath)) {
        Set-Location $entry.WorktreePath
    }

    # If NoClaude flag is set on the entry, stop here (claudeshell case).
    if ($entry.NoClaude) { return }

    # Decide --continue based on existing claude session history at this cwd.
    $slug    = ((Get-Location).Path -replace '[:\\/]', '-')
    $projDir = "C:\Users\claude\.claude\projects\$slug"
    $hasSession = (Test-Path $projDir) -and @(Get-ChildItem $projDir -Filter *.jsonl -ErrorAction SilentlyContinue).Count -gt 0

    $claudeArgs = @()
    if ($hasSession) {
        $claudeArgs += '--continue'
    } elseif ($entry.Branch) {
        $claudeArgs += '--name'
        $claudeArgs += $entry.Branch
    }
    if ($entry.PromptText) {
        $claudeArgs += $entry.PromptText
    }

    if ($claudeArgs.Count) { & claude @claudeArgs } else { & claude }
}

function _RegisterGwtSession {
    # Lean form: gwt has already written the session file with metadata. We just
    # patch in this shell's PID + start time + WT_SESSION, then register an exit
    # hook to delete the file on clean exit. Keeps the encoded command short
    # enough for runas (which has a tight command-line length limit).
    #
    # If -Id is omitted, scans the registry for an entry whose WorktreePath
    # matches the current cwd and isn't already alive -- handy for manually
    # claiming a session entry from inside an already-running shell.
    [CmdletBinding()]
    param(
        [string]$Id
    )
    _Ensure-GwtSessionDir

    if (-not $Id) {
        $cwd = (Get-Location).Path
        $candidate = Get-ChildItem $script:GwtSessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($e.WorktreePath -eq $cwd) { return $e }
            } catch {}
        } | Select-Object -First 1
        if (-not $candidate) {
            Write-Warning "gwt-session: no entry found for cwd '$cwd' -- pass -Id explicitly or check 'gwt sessions'"
            return
        }
        $Id = $candidate.Id
        Write-Host ("claiming entry {0} (branch={1}, window={2})" -f $Id, $candidate.Branch, $candidate.WindowName) -ForegroundColor DarkGray
    }

    $file = Join-Path $script:GwtSessionDir "$Id.json"
    if (-not (Test-Path $file)) {
        Write-Warning "gwt-session: no pre-written entry at $file -- registration skipped"
        return
    }

    try {
        $entry = Get-Content $file -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "gwt-session: failed to read $file : $_"
        return
    }

    $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    $entry.Pid       = $PID
    $entry.StartTime = if ($proc) { $proc.StartTime.ToString('o') } else { $null }
    $entry.WtSession = $env:WT_SESSION
    # Preserve FirstSpawnedAt (first registration); always update LastSpawnedAt.
    $now = (Get-Date).ToString('o')
    if (-not $entry.PSObject.Properties['FirstSpawnedAt'] -or [string]::IsNullOrEmpty($entry.FirstSpawnedAt)) {
        $entry | Add-Member -NotePropertyName FirstSpawnedAt -NotePropertyValue $now -Force
    }
    $entry | Add-Member -NotePropertyName LastSpawnedAt -NotePropertyValue $now -Force
    # SpawnedAt stays as a backwards-compat alias for LastSpawnedAt.
    $entry.SpawnedAt = $now
    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path $file -Encoding UTF8

    $global:GwtSessionId = $Id
    # NOTE: no PowerShell.Exiting hook -- entries are kept on shell close so
    # you can decide when to drop them (gwt sessions clean / clean -All).
    # On reboot, the PID becomes invalid and the entry naturally goes STALE.
}

# Read all session entries. Adds an .Alive boolean based on PID (and StartTime
# when readable -- cross-user process StartTime access is denied by Windows, so
# we fall back to "process exists" as the liveness signal).
function _GetGwtSessions {
    _Ensure-GwtSessionDir
    Get-ChildItem $script:GwtSessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $alive = $false
            if ($e.Pid -and $e.Pid -ne 0) {
                # CimInstance works cross-user; Get-Process doesn't see other users' procs.
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($e.Pid)" -ErrorAction SilentlyContinue
                if ($cim) {
                    if ($e.StartTime -and $cim.CreationDate) {
                        $alive = [math]::Abs(($cim.CreationDate - [datetime]::Parse($e.StartTime)).TotalSeconds) -lt 2
                    } else {
                        $alive = $true
                    }
                }
            }
            $e | Add-Member -NotePropertyName Alive -NotePropertyValue $alive -PassThru |
                 Add-Member -NotePropertyName File  -NotePropertyValue $_.FullName -PassThru
        } catch { }
    }
}

# Drop entries whose PID/StartTime don't match (stale).
function _RemoveStaleGwtSessions {
    _GetGwtSessions | Where-Object { -not $_.Alive } | ForEach-Object {
        Remove-Item $_.File -Force -ErrorAction SilentlyContinue
        Write-Host ("  removed stale: {0} ({1})" -f $_.Branch, $_.WindowName) -ForegroundColor DarkGray
    }
}
