#requires -Version 7
<#
.SYNOPSIS
  Confine a Windows account to read-only on one or more directory trees, with an explicit write allow-list.

.DESCRIPTION
  On a shared drive it is common for a broad principal (by default NT AUTHORITY\Authenticated Users) to hold an
  inherited Modify grant, so every account can write everything. That is convenient and also means a low-trust
  account can rewrite code a higher-trust account later executes.

  This tool turns that blanket grant into an allow-list for one account, on the trees you name:

    - For each -Tree, it breaks inheritance (copying the inherited ACEs down as explicit), then removes the
      broad principal from the subtree. The account keeps whatever read it had via BUILTIN\Users, and loses
      write. Administrators and SYSTEM keep their access because /inheritance:d preserved them.
    - For each -WritePath, it grants the account Modify (or -Permission), so the account can still write exactly
      the areas it needs.

  It does not touch the drive root and does not disturb other accounts. It is idempotent: re-running converges.

.PARAMETER Account
  The account to confine, e.g. "HOST\agent".

.PARAMETER Tree
  One or more directory trees to bring under the policy (the broad principal is removed from these).

.PARAMETER WritePath
  Zero or more paths inside (or outside) the trees where the account keeps write access.

.PARAMETER OwnerUser
  Optional. An account to grant Full on each tree, for when the owner is not a local administrator.

.PARAMETER BroadPrincipal
  The over-broad principal to remove. Default: "NT AUTHORITY\Authenticated Users".

.PARAMETER Permission
  The icacls permission string granted on each WritePath. Default: "(OI)(CI)(M)" (Modify, inheritable).

.PARAMETER Apply
  Execute. Without it the script prints the plan and changes nothing. -Apply also requires an elevated shell.

.EXAMPLE
  # Dry run: show what confining HOST\agent to two trees, writable only under its worktrees, would do.
  sandbox-account.ps1 -Account "HOST\agent" -Tree "D:\git","D:\worktrees" -WritePath "D:\worktrees"

.EXAMPLE
  # Apply it (elevated), also letting the agent write the subfolder it authors in the repo.
  sandbox-account.ps1 -Account "HOST\agent" -Tree "D:\git","D:\worktrees" `
      -WritePath "D:\worktrees","D:\git\org\repo\agent-area" -Apply

.NOTES
  Run elevated to apply. See powershell/docs/sandbox-account.md for the full explanation, and
  powershell/docs/account-isolation.md for the concrete clint/claude case on this box.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Account,
    [Parameter(Mandatory)] [string[]]$Tree,
    [string[]]$WritePath = @(),
    [string]$OwnerUser,
    [string]$BroadPrincipal = 'NT AUTHORITY\Authenticated Users',
    [string]$Permission = '(OI)(CI)(M)',
    [switch]$Apply
)

# Build the plan. Order matters: take each tree out of the blanket grant first, then allow-list writes.
$steps = [System.Collections.Generic.List[object]]::new()
foreach ($t in $Tree) {
    $steps.Add(@($t, '/inheritance:d'))                                   # break + copy inherited ACEs to explicit
    $steps.Add(@($t, '/remove:g', $BroadPrincipal, '/T'))                 # drop the broad principal, whole subtree
    if ($OwnerUser) { $steps.Add(@($t, '/grant', "${OwnerUser}:(OI)(CI)(F)", '/T')) }
}
foreach ($w in $WritePath) {
    $steps.Add(@($w, '/grant', "${Account}:$Permission", '/T'))           # allow-list the account's write areas
}

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "sandbox-account" -ForegroundColor Cyan
Write-Host "  account         : $Account"
Write-Host "  trees (read)    : $($Tree -join ', ')"
Write-Host "  write allow-list: $(if ($WritePath) { $WritePath -join ', ' } else { '(none)' })"
Write-Host "  broad principal : $BroadPrincipal  (removed from the trees)"
if ($OwnerUser) { Write-Host "  owner (Full)    : $OwnerUser" }
Write-Host ""

# Warn about paths that do not exist, so a typo does not silently no-op.
foreach ($p in ($Tree + $WritePath)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "  WARNING: path not found: $p" -ForegroundColor Yellow }
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN. Commands that WOULD run (pass -Apply, elevated, to execute):" -ForegroundColor Yellow
    foreach ($s in $steps) { Write-Host ("  icacls " + ($s -join ' ')) }
    Write-Host ""
    Write-Host "Verify afterwards with:  icacls <a-file-under-a-tree>" -ForegroundColor DarkGray
    return
}

if (-not $elevated) {
    Write-Host "must run elevated (as an administrator) to apply. aborting." -ForegroundColor Red
    return
}

foreach ($s in $steps) {
    Write-Host ("icacls " + ($s -join ' ')) -ForegroundColor DarkGray
    & icacls @s
}
Write-Host ""
Write-Host "done. spot-check a file under one of the trees with: icacls <path>" -ForegroundColor Green
