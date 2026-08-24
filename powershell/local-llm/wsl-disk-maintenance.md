# Keeping WSL disks from eating the drive

Why a WSL2 distro slowly swallows hundreds of GB, and how to stop it for good. Written 24 Aug 2026, after
`V:` filled and one Ubuntu distro's disk had grown to ~370 GB while holding 196 GB.

## Why it happens

A WSL2 distro lives on a single **dynamically-expanding VHDX** (`ext4.vhdx`). The file grows as the ext4
filesystem inside it writes blocks. It never shrinks on its own: when you delete files inside the distro,
ext4 frees those blocks internally but does not hand them back to the host, so the VHDX stays at the
**high-water mark** of everything you have ever had on disk at once.

One large transient thing sets the floor permanently until you compact:

- a big build, or a large `docker pull` / image layer churn
- package caches (`apt`, `pip`, `npm`, `go`, `cargo`)
- `node_modules`, target/ and build/ trees, giant `git clone`s

Delete them and the distro reports the space as free (`df -h /`), but the VHDX on the Windows side keeps
the allocation. That gap is the reclaimable slack.

## The check

Real size inside the distro vs the VHDX on disk:

```powershell
wsl -d Ubuntu -- df -h /                                      # Used column = real data
(Get-Item 'V:\work\virtualization\wsl\Ubuntu\ext4.vhdx').Length / 1GB   # allocated size
```

When `Used` is far below the VHDX size, the difference is pure reclaim. In the incident: 196 GB used inside
a ~370 GB file, so ~170 GB was slack.

## The fix, forever

Two independent pieces. Do both.

### 1. TRIM inside each distro

TRIM tells the host which blocks are free, so a later compact (or a sparse disk) can drop them. Enable the
weekly timer once per distro:

```powershell
wsl -d Ubuntu         -- sudo systemctl enable --now fstrim.timer
wsl -d kali-linux     -- sudo systemctl enable --now fstrim.timer
wsl -d Ubuntu-22.04   -- sudo systemctl enable --now fstrim.timer
```

`docker-desktop` has no systemd, so it gets no timer -- keep its size down with `docker system prune -af`
instead.

### 2. Compact on a schedule

TRIM marks blocks free; it does not physically shrink the VHDX. A **compact** does. `compact-wsl.ps1`
(under `powershell/onpath/`) shuts WSL down and compacts every registered distro's VHDX back to its real
size. Compaction is non-destructive -- it drops unused blocks only, never file contents (the diskpart
fallback even attaches the disk **read-only**).

Register it to run monthly (elevated, once):

```powershell
$a = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File "D:\git\github\dovholuknf\dotfiles\powershell\onpath\compact-wsl.ps1"'
$t = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At 7am
$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3)
Register-ScheduledTask -TaskName monthly-compact-wsl -Action $a -Trigger $t -Principal $p -Settings $s
```

`Interactive` logon runs the task in your logged-on session, so it opens a visible window and can prompt
before shutting WSL down. It fires only when you are logged on -- fine for a desktop that is always signed
in. The window lists the target vhdx, warns if a distro is running, and asks before doing anything.

Run it by hand any time (elevated): `compact-wsl.ps1`. Preview targets without touching anything:
`compact-wsl.ps1 -WhatIf`.

## Manual compact (what the script automates)

Elevated shell. `Optimize-VHD` (Hyper-V module) or the diskpart fallback both work; both are safe.

```powershell
wsl -d Ubuntu -- sudo fstrim -av      # mark free blocks first (optional; more reclaim)
wsl --shutdown                        # unlock the vhdx
Optimize-VHD -Path 'V:\work\virtualization\wsl\Ubuntu\ext4.vhdx' -Mode Full
```

diskpart fallback if `Optimize-VHD` is missing. Attach **read-only** so contents cannot change. Note the
here-string terminator `"@` must sit at column 0, or PowerShell keeps reading input -- writing the script
to a file avoids that trap:

```powershell
wsl --shutdown
$d = "select vdisk file=`"V:\work\virtualization\wsl\Ubuntu\ext4.vhdx`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit"
Set-Content "$env:TEMP\compact.txt" -Value $d -Encoding ascii
diskpart /s "$env:TEMP\compact.txt"
```

WSL relaunches normally on the next `wsl` invocation, everything intact.

### The sparse option, and why it is skipped here

`wsl --manage <distro> --set-sparse true` makes the VHDX auto-shrink continuously (sparse + TRIM), no
scheduled compact needed. It refuses without `--allow-unsafe` and warns about potential data corruption:
Microsoft gates it because on certain storage it can, rarely, corrupt the disk. The scheduled compact above
gets the same result without that risk, so sparse is deliberately not used.

## Orphaned distro disks

Separate from compaction: loose `*.vhdx` that back **no registered distro** are dead weight -- delete them,
do not compact. List where each live distro's disk actually is, then compare:

```powershell
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  [pscustomobject]@{ Distro = $p.DistributionName; BasePath = $p.BasePath }
} | Format-Table -AutoSize
```

Any `*.vhdx` in a directory no `BasePath` points at is orphaned (e.g. old `100gb-git.vhdx`,
`2025-home.vhdx`). Peek before deleting -- mount read-only, look, unmount:

```powershell
wsl --mount --vhd 'V:\work\wsl\100gb-git.vhdx'
# inspect under /mnt/wsl, then:
wsl --unmount 'V:\work\wsl\100gb-git.vhdx'
```

Confirmed stale ones go with a plain `Remove-Item` -- that reclaims the whole file at once, far more than a
compact would.
