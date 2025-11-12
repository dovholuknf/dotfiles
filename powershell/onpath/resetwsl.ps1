# Check if D: and E: drives already exist
$driveD = Test-Path "D:\"
$driveE = Test-Path "E:\"

if ($driveD -and $driveE) {
    Write-Host -ForegroundColor Green "Both D: and E: drives already exist. Skipping key mounting."
} else {
    Write-Host -ForegroundColor Cyan "One or both drives (D:, E:) don't exist. Proceeding with key mounting..."
    Write-Host -ForegroundColor Cyan "D: drive exists: $driveD"
    Write-Host -ForegroundColor Cyan "E: drive exists: $driveE"
    
    # Run the mountkeys.bat script
    #& "D:\git\bitbucket\dev_stuff\helper-scripts\windows\mountkeys.bat"
    explorer d:\
    D:\git\bitbucket\dev_stuff\helper-scripts\windows\mountkeys.bat
    explorer e:\
}

wsl --shutdown
wsl --mount V:\work\wsl\100gb-dev-mar-2024.vhdx --vhd --name dev
wsl --mount v:\work\wsl\100gb-git.vhdx --vhd --name git
wsl --mount v:\work\wsl\100gb-home.vhdx --vhd --name home

