#requires -Version 7
# Stamp the gwt session ledger entry for a worktree with the path to a recap that
# was just written. Called by the /recap skill after it writes its markdown, so
# `gwt sessions` can show a '+r' marker and `gwt prune -Recapped` can target
# folders whose work is already captured. Thin wrapper over _StampSessionRecap in
# gwt-session-registry.ps1. Defaults the worktree to the current directory.
param(
    [Parameter(Mandatory)][string]$RecapPath,
    [string]$WorktreePath
)
$reg = if ($env:DOTFILES_PWSH) { Join-Path $env:DOTFILES_PWSH 'gwt-session-registry.ps1' }
       else { 'D:\git\github\dovholuknf\dotfiles\powershell\gwt-session-registry.ps1' }
if (-not (Test-Path $reg)) { Write-Host "stamp-recap: registry script not found at $reg" -ForegroundColor Yellow; exit 0 }
. $reg
$ok = if ($WorktreePath) { _StampSessionRecap -RecapPath $RecapPath -WorktreePath $WorktreePath }
      else                { _StampSessionRecap -RecapPath $RecapPath }
if ($ok) { Write-Host "stamped session ledger with recap: $RecapPath" -ForegroundColor DarkGray }
else     { Write-Host "no gwt session entry matched this worktree; recap written, ledger not stamped" -ForegroundColor DarkGray }
