<#
.SYNOPSIS
    Adds (or replaces) a Host entry in the current user's OpenSSH client config.

.DESCRIPTION
    Pasting a here-string into an interactive prompt is unreliable: the shell's own indentation gets
    folded into the literal, and a here-string terminator only closes the block when '@ sits at column
    zero. A script sidesteps both problems.

    Re-running is safe. An existing entry for the same alias is replaced rather than appended, so the
    config does not accumulate duplicate Host blocks that shadow each other.

.PARAMETER Alias
    The short name to type, as in `ssh x2`.

.PARAMETER HostName
    Address of the target machine.

.PARAMETER User
    Remote account to log in as.

.PARAMETER IdentityFile
    Private key to offer. Written into the config with forward slashes, which OpenSSH on Windows
    accepts and which avoids backslash-escaping surprises.

.PARAMETER Port
    Remote SSH port. Omitted from the entry when it is the default 22, since writing it adds noise.

.PARAMETER ConfigPath
    Client config to modify. Defaults to the current user's ~/.ssh/config.

.PARAMETER DryRun
    Print the config entry that would be written, without actually writing it.

.EXAMPLE
    .\add-ssh-host.ps1

.EXAMPLE
    .\add-ssh-host.ps1 -Alias evo -HostName 192.168.1.130 -User clint

.EXAMPLE
    .\add-ssh-host.ps1 -Alias box -HostName 10.0.0.5 -User admin -Port 2222 -IdentityFile ~\.ssh\id_rsa
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Alias        = 'sgx2',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$HostName     = 'sgx2',

    # 'inet' pins IPv4. Multicast DNS answers a .local name with link-local IPv6 addresses ahead of the
    # A record, and a fe80:: address without a scope id does not route, so the connection times out
    # while the name resolves perfectly well. 'any' restores the default behaviour.
    [Parameter()]
    [ValidateSet('inet', 'inet6', 'any')]
    [string]$AddressFamily = 'inet',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$User         = 'clint',

    [Parameter()]
    [string]$IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519",

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$Port            = 22,

    [Parameter()]
    [string]$ConfigPath   = (Join-Path $env:USERPROFILE '.ssh\config'),

    [Parameter()]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$sshDir = Split-Path -Parent $ConfigPath
$configPath = $ConfigPath

if (-not (Test-Path -LiteralPath $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir | Out-Null
}

if (-not (Test-Path -LiteralPath $IdentityFile)) {
    Write-Warning "Key not found: $IdentityFile. The entry will be written anyway, but ssh will fail until it exists."
}

# OpenSSH is happier with forward slashes here, and it keeps the value free of escape ambiguity.
$identityForConfig = $IdentityFile -replace '\\', '/'

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("Host $Alias")
$lines.Add("    HostName $HostName")
$lines.Add("    User $User")
if ($AddressFamily -ne 'any') {
    $lines.Add("    AddressFamily $AddressFamily")
}
if ($Port -ne 22) {
    $lines.Add("    Port $Port")
}
$lines.Add("    IdentityFile $identityForConfig")
$lines.Add('    IdentitiesOnly yes')
$block = $lines -join "`n"

# IdentitiesOnly matters: without it the client offers every key the agent holds, and sshd drops the
# connection after too many failed offers before it ever reaches the right one.

if ($DryRun) {
    Write-Host "SSH config entry that would be written:" -ForegroundColor Cyan
    Write-Host $block -ForegroundColor Gray
    exit 0
}

$existing = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath
} else {
    @()
}

# Drop any prior block for this alias: from its "Host <alias>" line up to the next Host line.
$kept    = [System.Collections.Generic.List[string]]::new()
$dropping = $false
$replaced = $false

foreach ($line in $existing) {
    if ($line -match '^\s*Host\s+(.+?)\s*$') {
        $names = $matches[1] -split '\s+'
        if ($names -contains $Alias) {
            $dropping = $true
            $replaced = $true
            continue
        }
        $dropping = $false
    }
    if (-not $dropping) {
        $kept.Add($line)
    }
}

while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
    $kept.RemoveAt($kept.Count - 1)
}

$output = @()
if ($kept.Count -gt 0) {
    $output += $kept
    $output += ''
}
$output += $block -split "`r?`n"

# ASCII, and no trailing BOM: PowerShell 5.1's default UTF8 encoding writes a BOM that OpenSSH reads as
# part of the first directive, which makes the whole file look malformed.
Set-Content -LiteralPath $configPath -Value $output -Encoding ascii

if ($replaced) {
    Write-Host "Replaced existing entry for '$Alias' in $configPath" -ForegroundColor Yellow
} else {
    Write-Host "Added '$Alias' to $configPath" -ForegroundColor Green
}

Write-Host ''
Get-Content -LiteralPath $configPath | Write-Host
Write-Host ''
Write-Host "Test with:  ssh -v -o PreferredAuthentications=publickey $Alias whoami" -ForegroundColor Cyan