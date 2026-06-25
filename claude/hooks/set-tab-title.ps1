# Claude-code hook helper: set the Windows Terminal tab title from a hook.
#
# A hook's stdout is captured by claude-code for the hook JSON protocol, so an
# OSC title sequence written to stdout never reaches the terminal. Instead we
# try to attach to an ancestor console (the WT ConPTY that claude/node owns)
# and call SetConsoleTitleW directly.
#
# Usage (settings.json hook entry):
#   pwsh -NoProfile -File <this> -Title "‼️ waiting"
param(
    [Parameter(Mandatory)][string]$Title
)

$dbg = 'D:\worktrees\watch\title-debug.log'
function _Log($m) {
    try {
        [System.IO.Directory]::CreateDirectory((Split-Path $dbg)) | Out-Null
        Add-Content -Path $dbg -Value ("{0}  {1}" -f (Get-Date).ToString('o'), $m)
    } catch {}
}

try {
    Add-Type -Namespace WT -Name Con -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetConsoleTitleW(string lpConsoleTitle);
[DllImport("kernel32.dll")] public static extern uint GetConsoleWindow();
'@ -ErrorAction SilentlyContinue

    # Walk the parent chain so we can see who spawned us.
    $chain = @()
    $cur = $PID
    for ($i = 0; $i -lt 6 -and $cur; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId = $cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        $chain += ('{0}({1})' -f $p.Name, $p.ProcessId)
        $cur = $p.ParentProcessId
    }
    _Log ("fired pid=$PID  title='$Title'  chain=" + ($chain -join ' <- '))

    $ATTACH_PARENT_PROCESS = [uint32]'0xFFFFFFFF'
    $freed = [WT.Con]::FreeConsole()
    $att   = [WT.Con]::AttachConsole($ATTACH_PARENT_PROCESS)
    $err   = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    _Log ("  FreeConsole=$freed  AttachConsole(parent)=$att  lastErr=$err")
    if ($att) {
        $set = [WT.Con]::SetConsoleTitleW($Title)
        _Log ("  SetConsoleTitleW=$set")
    }
} catch {
    _Log ("  EXCEPTION: " + $_.Exception.Message)
}

exit 0
