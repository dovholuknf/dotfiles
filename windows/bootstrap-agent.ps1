#requires -Version 7
<#
Sets up the agent account (claude) on a new Windows machine from dotfiles and dotagents. Run it as that account.
It is safe to run again: a correct link is left alone, and a real file in the way is renamed to <name>.bak-<date>.

What it does:
  1. User env vars: GIT_ROOT, GH_ROOT, DOTFILES, DOTFILES_PWSH, ON_PATH, WORKTREE_ROOT. Processes started by atrium
     never load the pwsh profile, so these must be real env vars, not profile assignments.
  2. Links ~/.profile.ps1, ~/.gitignore_global, and ~/.claude/{CLAUDE.md, settings.json, hooks, statusline-command.sh}
     plus each agent, skill and command into dotfiles.
  3. Makes the pwsh profile dot-source ~/.profile.ps1.
  4. ~/.gitconfig: includes claude/agent.gitconfig and sets core.hooksPath and the signing key for this machine.
  5. Links each Claude Code memory dir (projects/<key>/memory, agent-memory) into dotagents/claude-memory.
  6. Builds the statusline binary if Go is installed and the binary is missing.
Then it prints what it cannot do: secrets, MCP servers, atrium. See windows/bootstrap-agent.md.

Run:  pwsh -NoProfile -File windows/bootstrap-agent.ps1 [-WorktreeRoot D:\worktrees] [-WhatIf]
Symlinks need Developer Mode on, or an elevated shell.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Dotfiles = (Split-Path -Parent $PSScriptRoot),
    [string]$Dotagents = (Join-Path (Split-Path -Parent $Dotfiles) 'dotagents'),
    [string]$WorktreeRoot = $(if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT } else { 'D:\worktrees' })
)
$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd'
$claudeDir = Join-Path $HOME '.claude'

function _Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

# _Link <path> <target>: makes <path> a symlink to <target>. A link that already points there is left alone. A real
# file or dir in the way is renamed to <path>.bak-<date>, never deleted.
function _Link([string]$Path, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target)) { Write-Warning "missing target, skipped: $Target"; return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -and ($item.Target -replace '/', '\') -eq ($Target -replace '/', '\')) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, "link to $Target")) { return }
    if ($item) {
        if ($item.LinkType) { $item.Delete() }
        else { Move-Item -LiteralPath $Path -Destination "$Path.bak-$stamp" }
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType SymbolicLink -Path $Path -Target $Target | Out-Null
    Write-Host "  linked $Path -> $Target"
}

if (-not (Test-Path (Join-Path $Dotfiles 'claude\settings.json'))) { throw "not a dotfiles checkout: $Dotfiles" }
$gitRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Dotfiles))   # <git-root>\github\<org>\dotfiles

_Step 'user env vars'
$vars = [ordered]@{
    GIT_ROOT      = $gitRoot
    GH_ROOT       = Join-Path $gitRoot 'github'
    DOTFILES      = $Dotfiles
    DOTFILES_PWSH = Join-Path $Dotfiles 'powershell'
    ON_PATH       = Join-Path $Dotfiles 'powershell\onpath'
    WORKTREE_ROOT = $WorktreeRoot
}
foreach ($k in $vars.Keys) {
    if ([Environment]::GetEnvironmentVariable($k, 'User') -eq $vars[$k]) { continue }
    if ($PSCmdlet.ShouldProcess("User env $k", "set to $($vars[$k])")) {
        [Environment]::SetEnvironmentVariable($k, $vars[$k], 'User')
        Write-Host "  $k = $($vars[$k])"
    }
}

_Step 'links into dotfiles'
_Link (Join-Path $HOME '.profile.ps1') (Join-Path $Dotfiles 'powershell\claude.profile.ps1')
_Link (Join-Path $HOME '.gitignore_global') (Join-Path $Dotfiles 'claude\agent.gitignore_global')
_Link (Join-Path $claudeDir 'CLAUDE.md') (Join-Path $Dotfiles 'claude\CLAUDE.global.md')
_Link (Join-Path $claudeDir 'settings.json') (Join-Path $Dotfiles 'claude\settings.json')
_Link (Join-Path $claudeDir 'hooks') (Join-Path $Dotfiles 'claude\hooks')
_Link (Join-Path $claudeDir 'statusline-command.sh') (Join-Path $Dotfiles 'claude\statusline-command.sh')
foreach ($dir in 'agents', 'skills', 'commands') {
    foreach ($it in Get-ChildItem (Join-Path $Dotfiles "claude\$dir") -Force) {
        _Link (Join-Path $claudeDir "$dir\$($it.Name)") $it.FullName
    }
}

_Step 'pwsh profile'
$pwshProfile = $PROFILE.CurrentUserCurrentHost
$line = '. $HOME/.profile.ps1'
$have = (Test-Path $pwshProfile) -and (Select-String -LiteralPath $pwshProfile -SimpleMatch $line -Quiet)
if (-not $have -and $PSCmdlet.ShouldProcess($pwshProfile, "add '$line'")) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $pwshProfile) -Force | Out-Null
    Add-Content -LiteralPath $pwshProfile -Value $line
    Write-Host "  added '$line' to $pwshProfile"
}

_Step 'git config'
$fwd = { param($p) $p -replace '\\', '/' }
$include = & $fwd (Join-Path $Dotfiles 'claude\agent.gitconfig')
$hooks = & $fwd (Join-Path $Dotfiles 'githooks\agent')
$signKey = Join-Path $HOME '.ssh\id_ed25519_sign.pub'
$want = [ordered]@{ 'include.path' = $include; 'core.hooksPath' = $hooks }
if (Test-Path $signKey) { $want['user.signingkey'] = & $fwd $signKey }
else { Write-Warning "no signing key at $signKey. Commits fail until it exists (agent.gitconfig sets gpgsign)." }
foreach ($k in $want.Keys) {
    $cur = @(git config --global --get-all $k 2>$null)
    if ($cur -contains $want[$k]) { continue }
    if ($PSCmdlet.ShouldProcess("git config --global $k", "set to $($want[$k])")) {
        if ($k -eq 'include.path') { git config --global --add $k $want[$k] } else { git config --global $k $want[$k] }
        Write-Host "  $k = $($want[$k])"
    }
}

_Step 'claude code memory (dotagents)'
$mem = Join-Path $Dotagents 'claude-memory'
if (Test-Path $mem) {
    foreach ($p in Get-ChildItem (Join-Path $mem 'projects') -Directory) {
        _Link (Join-Path $claudeDir "projects\$($p.Name)\memory") $p.FullName
    }
    _Link (Join-Path $claudeDir 'agent-memory') (Join-Path $mem 'agent-memory')
} else {
    Write-Warning "no dotagents memory at $mem. Clone dotagents beside dotfiles, then run this again."
}

_Step 'statusline binary'
$sl = Join-Path $Dotfiles 'claude\tools\statusline'
$exe = Join-Path $sl 'build.claude\statusline.exe'
if (Test-Path $exe) { Write-Host '  present' }
elseif (-not (Get-Command go -ErrorAction SilentlyContinue)) { Write-Warning "go not on PATH. Build $exe by hand." }
elseif ($PSCmdlet.ShouldProcess($exe, 'go build')) {
    Push-Location $sl
    try { go build -o build.claude/statusline.exe . } finally { Pop-Location }
}

_Step 'still to do by hand (see windows/bootstrap-agent.md)'
@(
    'claude login                     (writes ~/.claude/.credentials.json)'
    '~/.ssh keys and config           (id_ed25519, id_ed25519_sign, config)'
    '~/.profile.secrets.ps1           (tokens the profile loads, never committed)'
    'MCP servers                      (mcp-gateway, DaveMCP: claude mcp add --scope user ...)'
    'atrium                           (its installer adds atrium-control and the watchdog task)'
    'claude/settings.json statusLine  (hardcodes D:/git/..., so edit it if dotfiles moves)'
) | ForEach-Object { Write-Host "  $_" }
Write-Host "`nOpen a new shell so the env vars and profile take effect." -ForegroundColor Green
