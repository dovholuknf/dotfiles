# Tiny dispatcher invoked by the claude SessionStart / SessionEnd hooks. Lives in
# claude/hooks/ so settings.json can reference the symlinked path under
# ~/.claude/hooks/ and never has to encode the actual dotfiles checkout location.
# Resolves claude-shell.ps1 via $PSScriptRoot (which follows the symlink to the
# real file in the dotfiles repo).
param(
    [Parameter(Mandatory)][ValidateSet('start','end')][string]$Phase
)

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
. (Join-Path $dotfilesPwsh 'claude-shell.ps1')

try {
    if ($Phase -eq 'start') { _RegisterOrClaimClaudeSession }
    else                    { _UnregisterClaudeSession }
} catch {}
