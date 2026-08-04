#requires -Version 7
<#
.SYNOPSIS
  Report what the current Windows account can reach that it maybe should not: risky group memberships and
  privileges, readable other-user profiles, writable system locations, and trees under a blanket write grant.

.DESCRIPTION
  This is the read-only companion to sandbox-account.ps1. Run it AS the account you want to check (for example,
  from a shell running as the agent account), because the read and write probes reflect the current token.

  It changes nothing. Write probes create a temp file and delete it. See powershell/docs/account-isolation.md for
  a worked example and powershell/docs/sandbox-account.md for the fix.

.PARAMETER ReadPath
  Extra paths to test for read or list access. By default it also tests every other user profile under C:\Users.

.PARAMETER WritePath
  Extra paths to test for write access. Added to a default set of system locations.

.PARAMETER Tree
  Directory trees to inspect for a blanket write grant (Everyone, Authenticated Users, or BUILTIN\Users holding
  Modify or Full). These are the grants that make a shared drive writable by every account.
#>
[CmdletBinding()]
param(
    [string[]]$ReadPath  = @(),
    [string[]]$WritePath = @(),
    [string[]]$Tree      = @()
)

$problems = 0

function Test-Read($p) {
    if (-not (Test-Path -LiteralPath $p)) { return 'absent' }
    try { Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction Stop | Out-Null; 'READABLE' } catch { 'denied' }
}
function Test-List($p) {
    if (-not (Test-Path -LiteralPath $p)) { return 'absent' }
    try { Get-ChildItem -LiteralPath $p -Force -ErrorAction Stop | Out-Null; 'LISTABLE' } catch { 'denied' }
}
function Test-Write($dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 'absent' }
    $probe = Join-Path $dir (".audit_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        'WRITABLE'
    } catch { 'protected' }
}

$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
Write-Host "audit-account-acls  for  $($id.Name)" -ForegroundColor Cyan
Write-Host ""

# --- groups ---
$groups = $id.Groups | ForEach-Object {
    try { $_.Translate([Security.Principal.NTAccount]).Value } catch { $_.Value }
}
$riskyGroups = @($groups | Where-Object {
    $_ -match 'Administrators|Backup Operators|Power Users|Hyper-V Administrators|Remote Management Users|Print Operators'
})
Write-Host "== group memberships of note ==" -ForegroundColor White
if ($riskyGroups) {
    foreach ($g in $riskyGroups) { Write-Host "  PRIVILEGED  $g" -ForegroundColor Yellow; $problems++ }
} else {
    Write-Host "  none. standard, unprivileged account." -ForegroundColor Green
}
Write-Host ""

# --- privileges ---
$privRaw = & "$env:SystemRoot\System32\whoami.exe" /priv
$dangerous = 'SeImpersonatePrivilege','SeBackupPrivilege','SeRestorePrivilege','SeDebugPrivilege',
             'SeTakeOwnershipPrivilege','SeLoadDriverPrivilege','SeTcbPrivilege','SeCreateTokenPrivilege',
             'SeAssignPrimaryTokenPrivilege','SeManageVolumePrivilege'
$hits = @($privRaw | Where-Object { $line = $_; ($dangerous | Where-Object { $line -match "\b$_\b" }) })
Write-Host "== dangerous privileges ==" -ForegroundColor White
if ($hits) {
    foreach ($h in $hits) { Write-Host "  $($h.Trim())" -ForegroundColor Yellow; $problems++ }
} else {
    Write-Host "  none held." -ForegroundColor Green
}
Write-Host ""

# --- readable other-user profiles + extra read paths ---
$me = Split-Path $id.Name -Leaf
$otherProfiles = @(Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @($me, 'Public', 'Default', 'Default User', 'All Users') } |
    Select-Object -ExpandProperty FullName)
Write-Host "== cross-account read (other user profiles + -ReadPath) ==" -ForegroundColor White
foreach ($p in ($otherProfiles + $ReadPath)) {
    $r = if (Test-Path -LiteralPath $p -PathType Container) { Test-List $p } else { Test-Read $p }
    $color = if ($r -in 'READABLE', 'LISTABLE') { 'Yellow' } else { 'DarkGray' }
    if ($r -in 'READABLE', 'LISTABLE') { $problems++ }
    Write-Host ("  {0,-10} {1}" -f $r, $p) -ForegroundColor $color
}
Write-Host ""

# --- writable system locations + extra write paths ---
$sysWrite = @('C:\', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\Windows', 'C:\Windows\System32',
              'C:\ProgramData')
Write-Host "== write access to system locations (+ -WritePath) ==" -ForegroundColor White
foreach ($p in ($sysWrite + $WritePath)) {
    $w = Test-Write $p
    $color = if ($w -eq 'WRITABLE') { 'Yellow' } else { 'DarkGray' }
    if ($w -eq 'WRITABLE') { $problems++ }
    Write-Host ("  {0,-10} {1}" -f $w, $p) -ForegroundColor $color
}
Write-Host ""

# --- blanket grants on -Tree ---
if ($Tree) {
    Write-Host "== blanket write grants on -Tree ==" -ForegroundColor White
    foreach ($t in $Tree) {
        if (-not (Test-Path -LiteralPath $t)) { Write-Host "  absent   $t" -ForegroundColor DarkGray; continue }
        $acl   = & icacls $t 2>$null
        $broad = @($acl | Where-Object {
            ($_ -match 'Everyone|Authenticated Users|BUILTIN\\Users') -and ($_ -match '\((M|F|W|GW)\)')
        })
        if ($broad) {
            Write-Host "  BLANKET  $t" -ForegroundColor Yellow
            foreach ($b in $broad) { Write-Host "           $($b.Trim())" -ForegroundColor DarkYellow }
            $problems++
        } else {
            Write-Host "  scoped   $t" -ForegroundColor Green
        }
    }
    Write-Host ""
}

$c = if ($problems -eq 0) { 'Green' } else { 'Yellow' }
Write-Host ("summary: {0} item(s) worth review. Fix scoping with sandbox-account.ps1." -f $problems) -ForegroundColor $c
