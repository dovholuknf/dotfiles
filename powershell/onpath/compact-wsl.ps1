# $env:ON_PATH\compact-wsl.ps1
#
# Reclaims the slack in WSL2 distro disks. A WSL2 distro lives on a dynamically-
# growing VHDX: it expands as the ext4 filesystem writes, but deleting files
# INSIDE the distro frees the blocks in ext4 without ever returning them to the
# host, so the vhdx ratchets up to the high-water mark of usage and stays there.
# This shuts WSL down and compacts each REGISTERED distro's vhdx back to its real
# size. Non-destructive: compaction only drops unused blocks, never file contents.
#
# Pair it with per-distro TRIM so freed blocks are known:  in each distro run once
#   sudo systemctl enable --now fstrim.timer
#
# Intended to run monthly as a scheduled task (registration command in the banner).
# Needs elevation -- Optimize-VHD / diskpart both require admin.

param(
    # Also compact loose *.vhdx found in these dirs (orphaned/old distro disks).
    # Off by default: those are usually delete candidates, not live distros.
    [string[]]$ExtraDir = @(),
    # Compact even if a distro is currently running (forces 'wsl --shutdown').
    # Off by default so the scheduled run never kills WSL out from under you --
    # if anything is running, it just skips this month.
    [switch]$Force,
    [switch]$WhatIf
)

$TaskName = 'monthly-compact-wsl'

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " compact-wsl scheduled task" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " what:    shut WSL down, compact each registered distro's vhdx" -ForegroundColor DarkGray
Write-Host " why:     WSL2 vhdx grow to the high-water mark and never shrink" -ForegroundColor DarkGray
Write-Host " safe:    compaction drops unused blocks only; file contents untouched" -ForegroundColor DarkGray
Write-Host " when:    monthly -- registered as '$TaskName'" -ForegroundColor DarkGray
Write-Host " script:  $PSCommandPath" -ForegroundColor DarkGray
Write-Host ""
Write-Host " to register the task (run once, elevated). Interactive logon so it pops a" -ForegroundColor Yellow
Write-Host " visible window and can prompt before shutting WSL down:" -ForegroundColor Yellow
Write-Host "   `$a = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File `"$PSCommandPath`"'" -ForegroundColor Yellow
Write-Host "   `$t = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At 7am" -ForegroundColor Yellow
Write-Host "   `$p = New-ScheduledTaskPrincipal -UserId `$env:USERNAME -LogonType Interactive -RunLevel Highest" -ForegroundColor Yellow
Write-Host "   `$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3)" -ForegroundColor Yellow
Write-Host "   Register-ScheduledTask -TaskName $TaskName -Action `$a -Trigger `$t -Principal `$p -Settings `$s" -ForegroundColor Yellow
Write-Host " to remove:  Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Elevated)) {
    Write-Host "ERROR: run this from an ELEVATED shell -- Optimize-VHD / diskpart need admin." -ForegroundColor Red
    exit 1
}

# Every registered distro's vhdx, from the Lxss registry (BasePath\<disk>.vhdx).
# The disk is usually ext4.vhdx; fall back to any single .vhdx in the BasePath.
function Get-DistroVhdx {
    $out = @()
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return $out }
    foreach ($k in (Get-ChildItem $lxss -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p.BasePath) { continue }
        $base = $p.BasePath -replace '^\\\\\?\\', ''   # strip \\?\ prefix
        $vhdx = Join-Path $base 'ext4.vhdx'
        if (-not (Test-Path $vhdx)) {
            $vhdx = (Get-ChildItem $base -Filter *.vhdx -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        }
        if ($vhdx -and (Test-Path $vhdx)) {
            $out += [pscustomobject]@{ Distro = $p.DistributionName; Vhdx = $vhdx }
        }
    }
    $out
}

$targets = @(Get-DistroVhdx)
foreach ($d in $ExtraDir) {
    if (-not (Test-Path $d)) { continue }
    foreach ($f in (Get-ChildItem $d -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue)) {
        if ($targets.Vhdx -notcontains $f.FullName) {
            $targets += [pscustomobject]@{ Distro = "(loose) $($f.Name)"; Vhdx = $f.FullName }
        }
    }
}
if (-not $targets.Count) { Write-Host "no distro vhdx found" -ForegroundColor Yellow; exit 0 }

Write-Host "will compact:" -ForegroundColor White
foreach ($t in $targets) {
    $gb = [math]::Round((Get-Item $t.Vhdx).Length / 1GB, 1)
    Write-Host ("  {0,-22} {1,7} GB  {2}" -f $t.Distro, $gb, $t.Vhdx) -ForegroundColor DarkGray
}
Write-Host ""
if ($WhatIf) { Write-Host "-WhatIf: nothing compacted (WSL not touched)." -ForegroundColor Cyan; exit 0 }

# Compaction needs the vhdx unlocked, so it must 'wsl --shutdown' first. Never do
# that silently. When there's a console (the scheduled task runs in a visible
# window, like weekly-disk-usage), show the plan and ASK. Headless with no console,
# skip if anything is running rather than kill it. -Force does it without asking.
$running = @(& wsl.exe -l --running --quiet 2>$null | Where-Object { $_ -and $_.Trim() })

$canPrompt = $false
try {
    $canPrompt = [Environment]::UserInteractive -and `
                 -not [Console]::IsInputRedirected -and `
                 $Host.Name -eq 'ConsoleHost'
} catch { $canPrompt = $false }

if (-not $Force) {
    if ($canPrompt) {
        if ($running.Count) {
            Write-Host ("  NOTE: {0} distro(s) running ({1}) -- proceeding SHUTS THEM DOWN." -f `
                $running.Count, ($running -join ', ')) -ForegroundColor Yellow
        }
        $ans = Read-Host "compact the vhdx above now? this runs 'wsl --shutdown' first (y/N)"
        if ($ans -notmatch '^[Yy]') { Write-Host "  cancelled -- nothing touched." -ForegroundColor DarkGray; exit 0 }
    } elseif ($running.Count) {
        # No console to ask and a distro is running -- do not kill it.
        Write-Host ("WSL in use ({0}) and no console to prompt -- skipping. Use -Force to compact headless." -f `
            ($running -join ', ')) -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "shutting WSL down..." -ForegroundColor DarkGray
& wsl.exe --shutdown 2>&1 | Out-Null
Start-Sleep -Seconds 3

$haveOptimize = [bool](Get-Command Optimize-VHD -ErrorAction SilentlyContinue)

function Compact-OneVhdx {
    param([string]$Path)
    if ($haveOptimize) {
        Optimize-VHD -Path $Path -Mode Full -ErrorAction Stop
        return
    }
    # Fallback: diskpart, attached READ-ONLY (cannot alter contents).
    $script = @(
        "select vdisk file=`"$Path`""
        "attach vdisk readonly"
        "compact vdisk"
        "detach vdisk"
        "exit"
    ) -join "`r`n"
    $tmp = Join-Path $env:TEMP ("compact-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -Path $tmp -Value $script -Encoding ascii
    & diskpart.exe /s $tmp | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$totalBefore = 0; $totalAfter = 0
foreach ($t in $targets) {
    $before = (Get-Item $t.Vhdx).Length
    Write-Host ("  compacting {0} ({1} GB)..." -f $t.Distro, [math]::Round($before/1GB,1)) -ForegroundColor DarkGray
    try {
        Compact-OneVhdx -Path $t.Vhdx
        $after = (Get-Item $t.Vhdx).Length
        $totalBefore += $before; $totalAfter += $after
        Write-Host ("    {0} GB -> {1} GB  (reclaimed {2} GB)" -f `
            [math]::Round($before/1GB,1), [math]::Round($after/1GB,1), [math]::Round(($before-$after)/1GB,1)) -ForegroundColor Green
    } catch {
        Write-Host ("    FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host (" compact-wsl done {0} -- reclaimed {1} GB total" -f `
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [math]::Round(($totalBefore-$totalAfter)/1GB,1)) -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

# Hold the window open so a scheduled run's result is visible. Same three guards
# as weekly-disk-usage: interactive session, real console, stdin not redirected.
# A 2-hour hard cap keeps a headless run from hanging forever.
if ($canPrompt) {
    Write-Host "press Enter to close (window stays open; 2h hard cap)" -ForegroundColor DarkGray
    $deadline = (Get-Date).AddHours(2)
    try {
        while ((Get-Date) -lt $deadline) {
            if ($Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                if ($key.VirtualKeyCode -eq 13) { break }   # Enter
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {}
}
