# gwt-session-registry.ps1 — registry of running Claude sessions launched via
# gwt / claudeshell. Source from $PROFILE so every spawned shell auto-registers.
#
# usage (in $PROFILE):
#   . "$PSScriptRoot\gwt-session-registry.ps1"
#
# the spawned shell calls Register-GwtSession at startup; an exit hook removes
# the entry on clean exit. on reboot or window-close-by-X, entries remain
# stale — gwt sessions list/restore handles them.

$script:GwtSessionDir = 'D:\worktrees\sessions'

function _Ensure-GwtSessionDir {
    if (-not (Test-Path $script:GwtSessionDir)) {
        [System.IO.Directory]::CreateDirectory($script:GwtSessionDir) | Out-Null
    }
}

function Register-GwtSession {
    # Lean form: gwt has already written the session file with metadata. We just
    # patch in this shell's PID + start time + WT_SESSION, then register an exit
    # hook to delete the file on clean exit. Keeps the encoded command short
    # enough for runas (which has a tight command-line length limit).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Id
    )
    _Ensure-GwtSessionDir
    $file = Join-Path $script:GwtSessionDir "$Id.json"
    if (-not (Test-Path $file)) {
        Write-Warning "gwt-session: no pre-written entry at $file — registration skipped"
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
    $entry.SpawnedAt = (Get-Date).ToString('o')
    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path $file -Encoding UTF8

    $global:GwtSessionId = $Id
    Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
        try {
            $f = Join-Path 'D:\worktrees\sessions' "$($global:GwtSessionId).json"
            if (Test-Path $f) { Remove-Item $f -Force }
        } catch {}
    } | Out-Null
}

# Read all session entries. Adds an .Alive boolean based on PID + StartTime.
function Get-GwtSessions {
    _Ensure-GwtSessionDir
    Get-ChildItem $script:GwtSessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $alive = $false
            if ($e.Pid) {
                $p = Get-Process -Id $e.Pid -ErrorAction SilentlyContinue
                if ($p -and $e.StartTime) {
                    $alive = ($p.StartTime.ToString('o') -eq $e.StartTime)
                } elseif ($p) {
                    $alive = $true
                }
            }
            $e | Add-Member -NotePropertyName Alive -NotePropertyValue $alive -PassThru |
                 Add-Member -NotePropertyName File  -NotePropertyValue $_.FullName -PassThru
        } catch { }
    }
}

# Drop entries whose PID/StartTime don't match (stale).
function Remove-StaleGwtSessions {
    Get-GwtSessions | Where-Object { -not $_.Alive } | ForEach-Object {
        Remove-Item $_.File -Force -ErrorAction SilentlyContinue
        Write-Host "  removed stale: $($_.Branch) ($($_.WindowName))" -ForegroundColor DarkGray
    }
}
