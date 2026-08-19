# E: is a BitLocker-encrypted VHD (V:\work\encrypted-disk.vhd). Only mount + unlock it
# when it isn't already mapped, and prompt for the password ON THE COMMAND LINE here
# (not the Windows GUI dialog). mount-vhd + Unlock-BitLocker need admin, so the actual
# mount/unlock runs in a one-shot self-elevated pwsh; the password is handed over
# DPAPI-encrypted (current-user scoped) so plaintext never hits a command line.
if (Test-Path "E:\") {
    Write-Host -ForegroundColor Green "E: already mapped -- skipping BitLocker mount."
} else {
    Write-Host -ForegroundColor Cyan "E: not mapped. Unlocking the encrypted VHD on the command line..."
    $sec = Read-Host "BitLocker password for E:" -AsSecureString
    if ($sec.Length -eq 0) {
        Write-Host -ForegroundColor Yellow "No password entered -- skipping E: mount."
    } else {
        # Elevation keeps the same user, so a DPAPI blob encrypted here decrypts there.
        $enc = ConvertFrom-SecureString $sec
        $inner = @"
`$ErrorActionPreference = 'Continue'
Mount-VHD -Path 'V:\work\encrypted-disk.vhd' -ErrorAction SilentlyContinue
`$pw = ConvertTo-SecureString '$enc'
Unlock-BitLocker -MountPoint 'E:' -Password `$pw
# junction previously created by mountkeys.bat
cmd /c "rmdir /q v:\work\nf\envs 2>nul & mklink /j v:\work\nf\envs w:\work\nf\envs"
"@
        $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
        Start-Process pwsh -Verb RunAs -Wait -ArgumentList '-NoProfile', '-EncodedCommand', $b64
        if (Test-Path "E:\") { Write-Host -ForegroundColor Green "E: mounted." }
        else { Write-Host -ForegroundColor Red "E: still not mapped -- unlock may have failed (wrong password, or the VHD didn't attach as E:)." }
    }
}

wsl --shutdown
wsl --mount V:\work\wsl\100gb-dev-mar-2024.vhdx --vhd --name dev
wsl --mount v:\work\wsl\100gb-git.vhdx --vhd --name git
wsl --mount v:\work\wsl\100gb-home.vhdx --vhd --name home
