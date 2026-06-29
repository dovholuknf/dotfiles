# powershell/

The pwsh side of the dotfiles. The rest of this file is one-time machine setup (WSL / VHD) notes. For how the
day-to-day pieces work, start here:

| File | What it is |
| --- | --- |
| `Microsoft.PowerShell_profile.ps1` | Clint's profile. Sets env vars, dot-sources the shared + feature scripts. |
| `shared/common-tools.ps1` | Helpers shared by both users' profiles: `_TuiSelect`, the `gwt` wrapper, common `cd*` shortcuts, alias hygiene, `agent-log`, path toggles. No secrets. |
| `wt-themes.ps1` + `wt-themes-rainbow.ps1` | Per-tab theming. See `docs/themes.md`. |
| `claude-shell.ps1` | Spawns wt tabs running claude in a worktree; the window picker; theme-per-window mapping. |
| `gwt-session-registry.ps1` | Reads / writes the session ledger and the spawn entrypoint `_InvokeGwtSpawn`. |
| `onpath/` | Scripts meant to live on `$env:PATH`. See `onpath/README.md`. `git-worktree.ps1` (`gwt`) is the big one. |
| `docs/gwt-states.md` | The `gwt` worktree + session state machines. |
| `docs/themes.md` | The theme system end to end. |

Conventions, pitfalls, and the `_TuiSelect` picker contract live in the repo-root `CLAUDE.md`.

## Starting from NOTHING

* make wsl instance
* make (or mount) a vhd for git
* make (or mount) a vhd for dev


## Making a vhd for git

powershell:
```
new-vhd -Dynamic -SizeBytes 100gb -BlockSizeBytes 1mb -path v:\work\wsl\100gb-git.vhdx
```

## Making a vhd for /home
powershell:
```
$Path = "V:\work\wsl\100gb-home.vhdx"
new-vhd -Dynamic -SizeBytes 100gb -BlockSizeBytes 1mb -path $Path
$Acl = Get-Acl $Path
$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
$Acl.SetAccessRule($AccessRule)
Set-Acl -Path $Path -AclObject $Acl
```

format the vhd as ext4
```
wsl lsblk #take note of how many there are
wsl --mount --vhd $Path --bare
wsl lsblk #find the NEW one

$DriveName="/dev/sde"
wsl sudo mkfs.ext4 $DriveName
wsl sudo mkfs.ext4 -L "WSL-Home" $DriveName
```

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

## Grant your user permisision

$Path = "V:\work\wsl\100gb-git.vhdx"
$Acl = Get-Acl $Path
$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
$Acl.SetAccessRule($AccessRule)
Set-Acl -Path $Path -AclObject $Acl



$Path = "V:\work\wsl\100gb-home.vhdx"
$Acl = Get-Acl $Path
$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
$Acl.SetAccessRule($AccessRule)
Set-Acl -Path $Path -AclObject $Acl