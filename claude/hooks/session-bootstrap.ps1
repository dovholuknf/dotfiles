# Tiny dispatcher invoked by the claude SessionStart / SessionEnd hooks. Lives in
# claude/hooks/ so settings.json can reference the symlinked path under
# ~/.claude/hooks/ and never has to encode the actual dotfiles checkout location.
# Resolves claude-shell.ps1 via $PSScriptRoot (which follows the symlink to the
# real file in the dotfiles repo).
param(
    [Parameter(Mandatory)][ValidateSet('start','end')][string]$Phase
)

$dotfilesPwsh = (Resolve-Path (Join-Path $PSScriptRoot '..\..\powershell')).Path
. (Join-Path $dotfilesPwsh 'claude-shell.ps1')

if ($Phase -eq 'start') { _RegisterOrClaimClaudeSession }
else                    { _UnregisterClaudeSession }
