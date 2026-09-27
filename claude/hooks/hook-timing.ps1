# Dot-source at the top of a pwsh hook, then call Complete-HookTiming in a finally.
# Logs to D:\worktrees\watch\hook-timing.log when a hook takes over 5s or 10s, and when one never finished.
#
# The clock starts at process creation, not at this line, because the slow part is pwsh starting up under load.
# A hook killed at its timeout cannot log itself, so each run leaves a marker named for its pid and removes it on the
# way out. The next hook to run finds markers whose pid is gone and logs them as never finished.
# Blind spot: a pwsh so slow it is killed before reaching the dot-source leaves no marker. Claude Code's own
# "timed out" message is the only record of that.
# Best effort: nothing here may fail a hook.
param([string]$HookName)

$script:HookTimingLog     = 'D:\worktrees\watch\hook-timing.log'
$script:HookTimingMarkers = 'D:\worktrees\watch\hook-timing'
$script:HookTimingName    = $HookName
$script:HookTimingMarker  = $null
$script:HookTimingStart   = $null

try {
    $script:HookTimingStart = (Get-Process -Id $PID).StartTime
    [System.IO.Directory]::CreateDirectory($script:HookTimingMarkers) | Out-Null
    $script:HookTimingMarker = Join-Path $script:HookTimingMarkers "$PID.start"
    Set-Content -Path $script:HookTimingMarker -Value ("{0}`t{1}" -f $script:HookTimingStart.ToString('o'), $HookName)

    foreach ($m in (Get-ChildItem $script:HookTimingMarkers -Filter '*.start' -ErrorAction SilentlyContinue)) {
        if ($m.FullName -eq $script:HookTimingMarker) { continue }
        $mpid = [int]($m.BaseName)
        if (Get-Process -Id $mpid -ErrorAction SilentlyContinue) { continue }
        $parts = (Get-Content $m.FullName -Raw -ErrorAction SilentlyContinue) -split "`t"
        Add-Content -Path $script:HookTimingLog -Value ("{0}  NEVER-FINISHED  {1}  pid={2}  started={3}" -f `
            (Get-Date).ToString('o'), "$($parts[1])".Trim(), $mpid, $parts[0])
        Remove-Item $m.FullName -Force -ErrorAction SilentlyContinue
    }
} catch {}

function Complete-HookTiming {
    try {
        if ($script:HookTimingStart) {
            $secs = ((Get-Date) - $script:HookTimingStart).TotalSeconds
            $tag = if ($secs -gt 10) { 'OVER-10S' } elseif ($secs -gt 5) { 'OVER-5S' } else { $null }
            if ($tag) {
                Add-Content -Path $script:HookTimingLog -Value ("{0}  {1}  {2}  pid={3}  took={4:N1}s" -f `
                    (Get-Date).ToString('o'), $tag, $script:HookTimingName, $PID, $secs)
            }
        }
        if ($script:HookTimingMarker) { Remove-Item $script:HookTimingMarker -Force -ErrorAction SilentlyContinue }
    } catch {}
}
