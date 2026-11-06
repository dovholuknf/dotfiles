<#
.SYNOPSIS
  Recreate symlinks from an elevated shell so Redirection Guard trusts them.

.DESCRIPTION
  Windows OpenSSH runs sessions under Redirection Guard, which refuses to follow a symlink created by a non-admin
  ("The path cannot be traversed because it contains an untrusted mount point"). The claude account's home is full of
  links into this repo that claude created itself, so over ssh its profile and ~/.claude/settings.json fail to load.

  This script finds every symlink directly inside each -Dir whose owner is not BUILTIN\Administrators, and recreates
  it with the same target. Run elevated, the new link is owned by Administrators and Redirection Guard follows it.
  It does not recurse: pass each directory that holds links.

.PARAMETER Dir
  Directories to scan. Default: the claude home, ~/.claude, ~/.claude/agents, ~/.claude/skills.

.PARAMETER Apply
  Recreate the links. Without it, the script only lists what it would do. Requires an elevated shell.

.EXAMPLE
  trust-links.ps1            # dry run over the default dirs
  trust-links.ps1 -Apply     # elevated: recreate them
#>
[CmdletBinding()]
param(
    [string[]]$Dir = @(
        'C:\Users\claude',
        'C:\Users\claude\.claude',
        'C:\Users\claude\.claude\agents',
        'C:\Users\claude\.claude\skills'
    ),
    [switch]$Apply
)

$trustedOwner = 'BUILTIN\Administrators'

$links = foreach ($d in $Dir) {
    if (-not (Test-Path -LiteralPath $d)) { Write-Host "WARNING: path not found: $d" -ForegroundColor Yellow; continue }
    Get-ChildItem -LiteralPath $d -Force | Where-Object { $_.LinkType -eq 'SymbolicLink' } | ForEach-Object {
        $owner = (Get-Acl -LiteralPath $_.FullName).Owner
        if ($owner -ne $trustedOwner) {
            [pscustomobject]@{ Path = $_.FullName; Target = $_.Target; Owner = $owner; IsDir = $_.PSIsContainer }
        }
    }
}

if (-not $links) { Write-Host "every symlink is already owned by $trustedOwner. nothing to do." -ForegroundColor Green; return }

Write-Host "$(@($links).Count) symlink(s) not owned by ${trustedOwner}:" -ForegroundColor Cyan
foreach ($l in $links) { Write-Host "  $($l.Path) -> $($l.Target)  (owner $($l.Owner))" }

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN. Pass -Apply, elevated, to recreate them." -ForegroundColor Yellow
    return
}

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { Write-Host "must run elevated to apply. aborting." -ForegroundColor Red; return }

$failed = 0
foreach ($l in $links) {
    try {
        # Delete only the link itself. [IO.Directory]::Delete on a dir link removes the link, never the target's contents.
        if ($l.IsDir) { [System.IO.Directory]::Delete($l.Path) } else { [System.IO.File]::Delete($l.Path) }
        New-Item -ItemType SymbolicLink -Path $l.Path -Target $l.Target -ErrorAction Stop | Out-Null
        Write-Host "  relinked $($l.Path)  (owner $((Get-Acl -LiteralPath $l.Path).Owner))" -ForegroundColor DarkGray
    } catch {
        $failed++
        Write-Host "  FAILED $($l.Path): $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    recreate by hand: New-Item -ItemType SymbolicLink -Path '$($l.Path)' -Target '$($l.Target)'" -ForegroundColor Red
    }
}
if ($failed) { Write-Host "$failed link(s) failed." -ForegroundColor Red }
else         { Write-Host "done. test with a fresh ssh session." -ForegroundColor Green }
