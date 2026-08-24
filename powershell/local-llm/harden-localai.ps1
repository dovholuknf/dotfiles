<#
.SYNOPSIS
    Confines the localai account to its own profile as far as Windows allows.

.DESCRIPTION
    Run this on the EVO-X2 from an elevated shell.

    What this can and cannot do, stated up front, because the gap matters:

    It CANNOT confine the account to its home folder the way a Unix chroot would. Any account that logs
    in needs read and execute on C:\Windows and C:\Program Files to run a shell, load DLLs, and complete
    the login itself. Removing that produces an account that cannot log in rather than a confined one.
    Windows OpenSSH does have a ChrootDirectory directive, but it applies to SFTP sessions only and is
    documented as unsupported for shell sessions.

    What it DOES do:

      - Confirms group membership is Users and nothing else.
      - Denies the account every fixed drive other than the system drive. This is the largest and least
        obvious hole: a secondary drive formatted and left alone often grants Users full control at its
        root, inherited all the way down.
      - Denies the account each other user profile explicitly. Default ACLs already do this; an explicit
        deny survives someone later loosening a parent folder.
      - Denies write to C:\ProgramData while leaving read intact, closing a well-known persistence path
        without breaking the module and configuration lookups that a shell performs at startup.
      - Optionally denies interactive and Remote Desktop logon, leaving SSH as the only way in.

    Deny ACEs win over allow ACEs in Windows access checks regardless of order, which is what makes this
    approach stick even if inherited permissions change later.

    For a boundary rather than a speed bump, run the workload in a VM or a Hyper-V container. File
    permissions on a shared OS constrain a well-behaved process; they do not contain a hostile one that
    finds a local privilege escalation.

.PARAMETER AccountName
    Local account to restrict.

.PARAMETER AllowPath
    Paths outside the profile that the account must still reach, such as a models directory on a data
    drive. Each is granted read and execute AFTER the drive-level denies are applied. A deny on the
    drive root beats a later allow underneath it, so a path listed here gets its parent chain opened
    just enough to traverse to it.

.PARAMETER AllowWrite
    Treat AllowPath entries as read/write rather than read-only. Use for a models directory the account
    downloads into.

.PARAMETER DenyInteractiveLogon
    Also deny console and Remote Desktop logon, leaving SSH as the only path in. Off by default: if SSH
    breaks afterwards you would have no way back in except another administrator account.

.EXAMPLE
    .\harden-localai.ps1 -WhatIf

.EXAMPLE
    .\harden-localai.ps1 -AllowPath 'D:\models' -AllowWrite

.EXAMPLE
    .\harden-localai.ps1 -DenyInteractiveLogon
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$AccountName = 'localai',

    [string[]]$AllowPath = @(),

    [switch]$AllowWrite,

    [switch]$DenyInteractiveLogon
)

$ErrorActionPreference = 'Stop'

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Elevated)) {
    throw 'Run this from an elevated shell. Changing ACLs on drive roots and other profiles needs it.'
}

$account = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
if (-not $account) {
    throw "No local account named '$AccountName'."
}

$sid        = $account.SID.Value
$systemRoot = [IO.Path]::GetPathRoot($env:SystemRoot)   # normally C:\
$profileDir = Join-Path (Split-Path -Parent $env:USERPROFILE) $AccountName

Write-Host ''
Write-Host "Restricting $AccountName ($sid)" -ForegroundColor Cyan
Write-Host "  profile:      $profileDir"
Write-Host "  system drive: $systemRoot  (left readable; the account cannot log in otherwise)"
Write-Host ''

# ---------------------------------------------------------------------------------------------------
# 1. Group membership
# ---------------------------------------------------------------------------------------------------
# Administrators is the obvious one. Remote Desktop Users, Backup Operators, and Power Users each grant
# a route around file permissions, so any membership beyond Users is reported rather than assumed safe.

Write-Host '[1] Group membership' -ForegroundColor White

# Get-LocalGroupMember throws for an entire group when that group contains any orphaned SID, which is
# common on an OEM image. Swallowing the error silently reports "no memberships" for an account that
# may well be an administrator. `net localgroup` parses the same data without choking, so it is the
# fallback rather than the error being ignored.

function Get-GroupsForAccount {
    param([string]$Name, [string]$Sid)

    $found = @()
    foreach ($group in Get-LocalGroup) {
        $matched = $false
        try {
            $members = Get-LocalGroupMember -Group $group.Name -ErrorAction Stop
            $matched = [bool]($members | Where-Object { $_.SID.Value -eq $Sid })
        } catch {
            # Fall back to the classic tool, which tolerates unresolvable members.
            $raw = & net localgroup $group.Name 2>$null
            $matched = [bool]($raw | Where-Object { $_.Trim() -ieq $Name -or $_.Trim() -ieq "$env:COMPUTERNAME\$Name" })
            if (-not $matched) {
                Write-Verbose "Could not enumerate '$($group.Name)' via either method."
            }
        }
        if ($matched) { $found += $group.Name }
    }
    $found
}

$groups = Get-GroupsForAccount -Name $AccountName -Sid $sid

if (-not $groups) {
    # New-LocalUser, unlike `net user /add`, does not put the account in Users. The account still logs
    # in and still gets Users-level access, because the Users group itself contains
    # NT AUTHORITY\Authenticated Users. Nothing here can take that away: removing Authenticated Users
    # from Users would break every account on the machine. File permissions are the only lever.
    Write-Host "    no direct group membership (inherits Users via Authenticated Users)" -ForegroundColor DarkGray
}

foreach ($g in $groups) {
    if ($g -eq 'Users') {
        Write-Host "    in $g" -ForegroundColor DarkGray
        continue
    }
    Write-Warning "    in $g -- grants a way around file permissions"
    if ($PSCmdlet.ShouldProcess("$AccountName", "remove from group '$g'")) {
        Remove-LocalGroupMember -Group $g -Member $AccountName -ErrorAction Continue
        Write-Host "    removed from $g" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------------------------------
# 2. Every fixed drive except the system drive
# ---------------------------------------------------------------------------------------------------
# The (OI)(CI) flags propagate the deny to files and folders beneath the root. This is the highest-value
# change here, because a data drive's default root ACL grants Users full control.

Write-Host ''
Write-Host '[2] Non-system fixed drives' -ForegroundColor White

# [IO.DriveInfo] rather than Get-CimInstance: importing the CIM module under -WhatIf makes PowerShell
# announce every alias the module registers, which buries the output that matters.

$drives = [IO.DriveInfo]::GetDrives() |
    Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_.Name -ne $systemRoot }

if (-not $drives) {
    Write-Host '    none' -ForegroundColor DarkGray
}

foreach ($d in $drives) {
    $root = $d.Name
    if ($PSCmdlet.ShouldProcess($root, "deny all access to $AccountName")) {
        & icacls $root /deny "${AccountName}:(OI)(CI)(F)" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    denied $root" -ForegroundColor Green
        } else {
            Write-Warning "    icacls returned $LASTEXITCODE for $root"
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# 3. Other user profiles
# ---------------------------------------------------------------------------------------------------
# Default ACLs already keep one user out of another's profile. An explicit deny is belt and braces: it
# survives a parent folder later being loosened, and it makes the intent visible to whoever reads these
# permissions next.
#
# C:\Users\Public is deliberately left alone. Some tooling writes there during install, and it holds
# nothing sensitive by default.

Write-Host ''
Write-Host '[3] Other user profiles' -ForegroundColor White

$usersRoot = Split-Path -Parent $profileDir

Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @($AccountName, 'Public', 'Default', 'All Users', 'Default User') } |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, "deny all access to $AccountName")) {
            & icacls $_.FullName /deny "${AccountName}:(OI)(CI)(F)" 2>$null | Out-Null
            Write-Host "    denied $($_.FullName)" -ForegroundColor Green
        }
    }

# ---------------------------------------------------------------------------------------------------
# 4. ProgramData: readable, not writable
# ---------------------------------------------------------------------------------------------------
# Several subtrees under ProgramData grant Users write by default, which is a persistence path: drop a
# file somewhere a privileged process later reads or executes. Read stays, because shells and modules
# look here during startup and a blanket deny breaks the login.

Write-Host ''
Write-Host '[4] ProgramData' -ForegroundColor White

$programData = $env:ProgramData
if ($PSCmdlet.ShouldProcess($programData, "deny write to $AccountName")) {
    & icacls $programData /deny "${AccountName}:(OI)(CI)(W)" | Out-Null
    Write-Host "    denied write to $programData (read left intact)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------------------------------
# 5. Paths the account still needs
# ---------------------------------------------------------------------------------------------------
# A deny on a drive root beats an allow further down, so each allowed path needs its parent chain opened
# for traversal. Granting (RX) without inheritance on each parent lets the account walk to the target
# without being able to enumerate siblings meaningfully.

if ($AllowPath.Count -gt 0) {
    Write-Host ''
    Write-Host '[5] Allowed paths' -ForegroundColor White

    $rights = if ($AllowWrite) { '(OI)(CI)(M)' } else { '(OI)(CI)(RX)' }

    foreach ($p in $AllowPath) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Warning "    skipping missing path: $p"
            continue
        }

        $full = (Resolve-Path -LiteralPath $p).Path

        # Walk up from the target to the drive root, granting traversal on each ancestor.
        $ancestors = @()
        $cur = Split-Path -Parent $full
        while ($cur) {
            $ancestors += $cur
            $parent = Split-Path -Parent $cur
            if ($parent -eq $cur) { break }
            $cur = $parent
        }

        foreach ($a in ($ancestors | Sort-Object Length)) {
            if ($PSCmdlet.ShouldProcess($a, "grant traverse to $AccountName")) {
                & icacls $a /remove:d $AccountName 2>$null | Out-Null
                & icacls $a /grant "${AccountName}:(RX)" 2>$null | Out-Null
            }
        }

        if ($PSCmdlet.ShouldProcess($full, "grant $(if ($AllowWrite) {'modify'} else {'read'}) to $AccountName")) {
            & icacls $full /remove:d $AccountName 2>$null | Out-Null
            & icacls $full /grant "${AccountName}:$rights" | Out-Null
            Write-Host "    granted $(if ($AllowWrite) {'modify'} else {'read'}) on $full" -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# 6. Logon rights
# ---------------------------------------------------------------------------------------------------
# SSH public-key auth produces a network-type logon, so denying interactive and Remote Desktop logon
# leaves SSH working. Off by default because the failure mode is being locked out of the box.

if ($DenyInteractiveLogon) {
    Write-Host ''
    Write-Host '[6] Logon rights' -ForegroundColor White

    if ($PSCmdlet.ShouldProcess($AccountName, 'deny interactive and Remote Desktop logon')) {
        $tmp = Join-Path $env:TEMP "secpol-$PID.inf"
        $db  = Join-Path $env:TEMP "secpol-$PID.sdb"

        & secedit /export /areas USER_RIGHTS /cfg $tmp | Out-Null
        $content = Get-Content -LiteralPath $tmp

        foreach ($right in 'SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight') {
            $line = $content | Where-Object { $_ -match "^$right\s*=" }
            if ($line) {
                if ($line -notmatch [regex]::Escape($sid)) {
                    $content = $content -replace "^$right\s*=\s*(.*)$", "$right = `$1,*$sid"
                }
            } else {
                $content = $content -replace '^\[Privilege Rights\]$', "[Privilege Rights]`r`n$right = *$sid"
            }
        }

        Set-Content -LiteralPath $tmp -Value $content -Encoding Unicode
        & secedit /configure /db $db /cfg $tmp /areas USER_RIGHTS | Out-Null
        Remove-Item -LiteralPath $tmp, $db -Force -ErrorAction SilentlyContinue

        Write-Host '    denied interactive and RDP logon; SSH is now the only way in' -ForegroundColor Green
        Write-Warning '    Verify SSH still works from another shell BEFORE closing this one.'
    }
}

# ---------------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Still reachable by this account, and unavoidably so:' -ForegroundColor Yellow
Write-Host '  C:\Windows and C:\Program Files  read and execute, required to run any shell'
Write-Host '  its own profile                  full control'
Write-Host '  the network                      no file permission restricts outbound connections'
Write-Host ''
Write-Host 'Verify from the workstation, and keep an existing session open while you do:' -ForegroundColor Cyan
Write-Host "  ssh sgx2 'Get-ChildItem D:\ ; Get-ChildItem C:\Users\clint'"
Write-Host '  both should fail with access denied'
Write-Host ''
