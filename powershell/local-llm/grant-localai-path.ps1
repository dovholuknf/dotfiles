<#
.SYNOPSIS
    Gives a locked-down account one more folder, usually on another drive, and nothing else.

.DESCRIPTION
    Run this on the target machine from an elevated shell. It works under Windows PowerShell 5.1, so a box
    without pwsh can run it.

    The account is expected to be confined already, for example by harden-localai.ps1, which denies it every
    non-system drive at the root. This script leaves that deny alone. It sets an explicit allow on the folder
    itself, which Windows checks ahead of the deny the folder inherits from the drive root. Files and folders
    under it inherit the nearer allow first, so the whole subtree opens and the rest of the drive stays shut.

    The parent folders get no grant. Users hold "Bypass traverse checking" by default, so the account opens
    the folder by its full path without any right on the folders above it. That is also why a short path is
    handy: the script adds a junction in the account's profile that points at the folder. The junction is
    only a shortcut. Access comes from the grant, not from the link.

    Re-running is safe. The grant is replaced rather than stacked, and an existing junction to the same
    target is left as it is.

.PARAMETER Path
    The folder to open. Created when missing. A drive root is refused, since granting it would undo the
    drive-level deny for the whole drive.

.PARAMETER AccountName
    The account to grant, as a local name ('localai') or with the machine prefix ('sg3\claude').

.PARAMETER AllowWrite
    Grant modify instead of read and execute.

.PARAMETER LinkName
    Name of the junction in the account's profile. Defaults to the folder's own name, so V:\work\localai
    becomes C:\Users\<account>\localai.

.PARAMETER NoLink
    Skip the junction.

.EXAMPLE
    .\grant-localai-path.ps1 -Path V:\work\localai -AllowWrite -WhatIf

.EXAMPLE
    .\grant-localai-path.ps1 -Path V:\work\localai -AllowWrite

.EXAMPLE
    .\grant-localai-path.ps1 -Path V:\work\localai -AccountName 'sg3\claude' -AllowWrite -LinkName work
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [ValidateNotNullOrEmpty()]
    [string]$AccountName = 'localai',

    [switch]$AllowWrite,

    [string]$LinkName,

    [switch]$NoLink
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated shell. Changing ACLs on another account''s behalf needs it.'
}

# Resolve to a SID up front. A typo then fails here instead of icacls granting nothing, and icacls takes the
# '*SID' form, which sidesteps how the name is spelled.
try {
    $sid = (New-Object Security.Principal.NTAccount $AccountName).Translate(
        [Security.Principal.SecurityIdentifier]).Value
} catch {
    throw "No account named '$AccountName'."
}

$full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
if ($full.Length -le 2) {
    throw "Refusing drive root '$Path'. Granting it reopens the whole drive. Pass a folder on it instead."
}

$rights = if ($AllowWrite) { '(OI)(CI)(M)' } else { '(OI)(CI)(RX)' }
$what   = if ($AllowWrite) { 'modify' } else { 'read' }

Write-Host ''
Write-Host "Granting $AccountName ($sid) $what on $full" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $full)) {
    if ($PSCmdlet.ShouldProcess($full, 'create folder')) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        Write-Host "    created $full" -ForegroundColor Green
    }
}

if ($PSCmdlet.ShouldProcess($full, "grant $what to $AccountName")) {
    # /remove:d drops only an explicit deny set on this folder. The inherited drive-root deny is untouched,
    # and the explicit allow below outranks it.
    & icacls $full /remove:d "*$sid" 2>$null | Out-Null
    & icacls $full /grant:r "*${sid}:$rights" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls returned $LASTEXITCODE granting $full" }
    Write-Host "    granted $what on $full" -ForegroundColor Green
}

if (-not $NoLink) {
    # ProfileList is keyed by SID and holds the real profile path, which is not always C:\Users\<name>.
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    $profileDir = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).ProfileImagePath

    if (-not $profileDir) {
        Write-Warning "    no profile for $AccountName yet (it has never logged in). Skipping the junction."
    } else {
        if (-not $LinkName) { $LinkName = Split-Path -Leaf $full }
        $link = Join-Path $profileDir $LinkName
        $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

        if ($existing -and $existing.LinkType -eq 'Junction' -and
                (@($existing.Target)[0].TrimEnd('\') -ieq $full)) {
            Write-Host "    junction $link already points at $full" -ForegroundColor DarkGray
        } elseif ($existing) {
            Write-Warning "    $link already exists and is not a junction to $full. Pass -LinkName or -NoLink."
        } elseif ($PSCmdlet.ShouldProcess($link, "create junction to $full")) {
            New-Item -ItemType Junction -Path $link -Target $full | Out-Null
            Write-Host "    junction $link -> $full" -ForegroundColor Green
        }
    }
}

# Show the result next to the drive root, so the reader sees the folder open and the root still denied.
$root = [IO.Path]::GetPathRoot($full)
Write-Host ''
Write-Host "ACL entries for $AccountName" -ForegroundColor White
foreach ($p in @($full, $root)) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $acl = Get-Acl -LiteralPath $p
    $aces = @($acl.Access | Where-Object {
        try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid } catch { $false }
    })
    if (-not $aces.Count) {
        Write-Host "    ${p}: none" -ForegroundColor DarkGray
    }
    foreach ($a in $aces) {
        $src = if ($a.IsInherited) { 'inherited' } else { 'explicit' }
        Write-Host "    ${p}: $($a.AccessControlType) $($a.FileSystemRights) ($src)"
    }
}
