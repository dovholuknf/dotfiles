## Making a vhd just for wsl

https://pomeroy.me/2023/12/how-i-fixed-wsl-2-filesystem-performance-issues/
removing a vhd:
https://superuser.com/questions/964666/how-to-unmount-a-vhd-via-command-line-in-windows-10
```
$DiskSize = 50GB
$DiskName = "Repos.vhdx"
$VhdxDirectory = Join-Path -Path $Env:LOCALAPPDATA -ChildPath "wsl"
if (!(Test-Path -Path $VhdxDirectory)) {
    New-Item -Path $VhdxDirectory -ItemType Directory
}
$DiskPath = Join-Path -Path $VhdxDirectory -ChildPath $DiskName
New-VHD -Path $DiskPath -SizeBytes $DiskSize -Dynamic


new-vhd -Dynamic -SizeBytes 100gb -BlockSizeBytes 1mb -path V:\work\wsl\100gb-dev-mar-2024.vhdx
wsl --mount V:\work\wsl\100gb-dev-mar-2024.vhdx --vhd --bare
```

in wsl:
```
ls -1t /dev/sd*
sudo mkfs -t ext4 /dev/sdd <-- make sure you use the right DiskName
```

in pwsh:
```
wsl --mount V:\work\wsl\100gb-dev-mar-2024.vhdx --vhd --name dev
```

AFTER wsl --shutdown always need to rerun above