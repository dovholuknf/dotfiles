# Tiny dispatcher invoked by the claude SessionStart / SessionEnd hooks. Lives in
# claude/hooks/ so settings.json can reference the symlinked path under
# ~/.claude/hooks/ and never has to encode the actual dotfiles checkout location.
# Resolves claude-shell.ps1 via $PSScriptRoot (which follows the symlink to the
# real file in the dotfiles repo).
param(
    [Parameter(Mandatory)][ValidateSet('start','end')][string]$Phase
)

# Trace: every invocation logs a line to a debug file regardless of what comes
# next. If you don't see entries here after a SessionStart, claude-code never
# fired the hook (or pwsh wasn't found on PATH).
$dbg = 'D:\worktrees\watch\hook-debug.log'
try {
    [System.IO.Directory]::CreateDirectory((Split-Path $dbg)) | Out-Null
    Add-Content -Path $dbg -Value ("{0}  bootstrap fired  phase={1}  pid={2}" -f (Get-Date).ToString('o'), $Phase, $PID)
} catch {}

# $PSScriptRoot points at the symlink location (C:\Users\claude\.claude\hooks),
# whose parent isn't the dotfiles repo. Resolve the hooks dir's symlink target
# to find the real dotfiles checkout. Falls back to $env:DOTFILES_PWSH or a
# hardcoded default if symlink resolution fails.
$dotfilesPwsh = $null
try {
    $hooksDirInfo = [System.IO.Directory]::new($PSScriptRoot) -as [System.IO.DirectoryInfo]
    if (-not $hooksDirInfo) { $hooksDirInfo = [System.IO.DirectoryInfo]::new($PSScriptRoot) }
    $resolvedHooks = if ($hooksDirInfo.LinkType -eq 'SymbolicLink') {
        $hooksDirInfo.ResolveLinkTarget($true).FullName
    } else {
        $hooksDirInfo.FullName
    }
    $candidate = Join-Path (Split-Path $resolvedHooks -Parent) 'powershell'
    if (Test-Path (Join-Path $candidate 'claude-shell.ps1')) { $dotfilesPwsh = $candidate }
} catch {}
if (-not $dotfilesPwsh) {
    $dotfilesPwsh = if ($env:DOTFILES_PWSH) { $env:DOTFILES_PWSH.TrimEnd('\') } else { 'D:\git\github\dovholuknf\dotfiles\powershell' }
}
try { Add-Content -Path $dbg -Value ("    resolved dotfilesPwsh={0}" -f $dotfilesPwsh) } catch {}
. (Join-Path $dotfilesPwsh 'claude-shell.ps1')

try {
    if ($Phase -eq 'start') { _RegisterOrClaimClaudeSession }
    else                    { _UnregisterClaudeSession }
    try { Add-Content -Path $dbg -Value ("{0}  bootstrap done    phase={1}  OK" -f (Get-Date).ToString('o'), $Phase) } catch {}
} catch {
    try {
        Add-Content -Path $dbg -Value ("{0}  bootstrap ERROR   phase={1}  {2}" -f (Get-Date).ToString('o'), $Phase, $_.Exception.Message)
        Add-Content -Path $dbg -Value ("    stack: {0}" -f $_.ScriptStackTrace)
    } catch {}
}
