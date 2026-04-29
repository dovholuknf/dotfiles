#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('x64','arm64')]
    [string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Write-Host '==> Setting POWERSHELL_UPDATECHECK=LTS (machine scope)'
[Environment]::SetEnvironmentVariable('POWERSHELL_UPDATECHECK', 'LTS', 'Machine')
$env:POWERSHELL_UPDATECHECK = 'LTS'

Write-Host '==> Removing any Store-packaged PowerShell (conflicts with MSI)'
Get-AppxPackage Microsoft.PowerShell -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

Write-Host '==> Querying GitHub for latest LTS release'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'install-pwsh-lts' }
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases' -Headers $headers

# LTS major versions are even (7.4, 7.6 ...). Grab the newest non-preview even-major release.
$lts = $releases |
    Where-Object { -not $_.prerelease -and -not $_.draft } |
    Where-Object { $_.tag_name -match '^v(\d+)\.(\d+)\.(\d+)$' -and ([int]$Matches[2] % 2 -eq 0) } |
    Sort-Object { [version]($_.tag_name.TrimStart('v')) } -Descending |
    Select-Object -First 1

if (-not $lts) { throw 'Could not locate an LTS release on GitHub.' }

$version = $lts.tag_name.TrimStart('v')
Write-Host "    latest LTS: $version"

$asset = $lts.assets | Where-Object { $_.name -like "PowerShell-$version-win-$Arch.msi" } | Select-Object -First 1
if (-not $asset) { throw "Could not find MSI asset for $version $Arch" }

$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (Test-Path $pwshPath) {
    $installed = (Get-Item $pwshPath).VersionInfo.ProductVersion
    Write-Host "    already installed: $installed"
    if ($installed -eq $version) {
        Write-Host '==> Already at latest LTS, nothing to do.'
        & $pwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion'
        return
    }
}

$msi = Join-Path $env:TEMP $asset.name
Write-Host "==> Downloading $($asset.name)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -Headers $headers

Write-Host '==> Installing (quiet)'
$proc = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart ADD_PATH=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1" -Wait -PassThru
if ($proc.ExitCode -ne 0) { throw "msiexec exited with code $($proc.ExitCode)" }

if (-not (Test-Path $pwshPath)) { throw "pwsh.exe not found at $pwshPath after install" }

Write-Host '==> Verifying'
& $pwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion'

Write-Host ''
Write-Host "Done. pwsh at: $pwshPath (v$version, LTS channel)"
