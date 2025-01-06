if ($PSVersionTable.PSVersion.Major -ge 7) {
    "PowerShell version 7 or higher installed. Continuing..."
} else {
    Write-Host -ForegroundColor Red "PowerShell version is below 7. Use PowerShell v7+"
    Write-Host -ForegroundColor Red "Current PowerShell version: $($PSVersionTable.PSVersion)"
    exit
}

wsl --shutdown
wsl --mount V:\work\wsl\100gb-dev-mar-2024.vhdx --vhd --name dev

explorer d:\
D:\git\bitbucket\dev_stuff\helper-scripts\windows\mountkeys.bat

explorer e:\
