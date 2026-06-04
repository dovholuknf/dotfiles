# admin shell

param(
    [Parameter(Mandatory = $true)]
    [string]$Org,

    [string]$Repo,

    [switch]$y
)

$SourceRoot   = if ($env:GIT_ROOT)      { $env:GIT_ROOT.TrimEnd('\') }       else { 'D:\git' }
$WorktreeRoot = if ($env:WORKTREE_ROOT) { "$($env:WORKTREE_ROOT.TrimEnd('\'))\github" } else { 'D:\worktrees\github' }

function Write-Color {
    param([string]$Text, [string]$Color)
    Write-Host $Text -ForegroundColor $Color
}

function Confirm-Delete {
    param([string]$Path, [switch]$Auto)

    if ($Auto) { return $true }

    $resp = Read-Host "delete '$Path'? (y/N)"
    return ($resp -match '^[Yy]$')
}

$basePath = Join-Path "$SourceRoot\github" $Org
if (-not (Test-Path $basePath)) {
    Write-Color "org not found: $Org" Red
    exit 1
}

$repos = if ($Repo) {
    @(Join-Path $basePath $Repo)
} else {
    Get-ChildItem $basePath -Directory
}

foreach ($r in $repos) {
    $repo = if ($r -is [string]) { $r } else { $r.FullName }
    if (-not (Test-Path "$repo\.git")) { continue }

    Write-Color "`nrepo: $repo" Cyan

    git -C $repo fetch origin --prune 2>&1 | Out-Null

    $lines = git -C $repo worktree list --porcelain 2>&1
    $current = $null
    $branch = $null
    $isMain = $false

    $registered = @()

    foreach ($line in $lines) {
        if ($line -match '^worktree\s+(.+)$') {
            $current = $Matches[1]
            $repoNorm = $repo.Replace('\','/').ToLower()
            $currentNorm = $current.Replace('\','/').ToLower()
            $isMain = ($currentNorm -eq $repoNorm)

            $registered += $currentNorm
            continue
        }

        if ($line -match '^branch refs/heads/(.+)$') {
            $branch = $Matches[1]

            if ($isMain) {
                Write-Color "  [MAIN]   $branch @ $current" DarkGray
                continue
            }

            if (-not (Test-Path $current)) {
                Write-Color "  [MISSING] $branch @ $current" DarkYellow
                continue
            }

            $dirty = (git -C $current status --porcelain 2>&1 | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($dirty)) {
                Write-Color "  [DIRTY]  $branch @ $current" Yellow
                continue
            }

            git -C $repo merge-base --is-ancestor $branch origin/main 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Color "  [DELETE] $branch @ $current" Red
                if (Confirm-Delete -Path $current -Auto:$y) {
                    git -C $repo worktree remove --force "$current" 2>&1 | Out-Null
                }
            } else {
                Write-Color "  [KEEP]   $branch @ $current" Green
            }
        }
    }

    git -C $repo worktree prune 2>&1 | Out-Null

    # orphan cleanup
    $wtRoot = Join-Path (Join-Path $WorktreeRoot $Org) (Split-Path $repo -Leaf)
    if (-not (Test-Path $wtRoot)) { continue }

    Get-ChildItem $wtRoot -Directory | ForEach-Object {
        $p = $_.FullName
        $pNorm = $p.Replace('\','/').ToLower()

        if ($registered -contains $pNorm) { return }

        $isGit = Test-Path (Join-Path $p '.git')

        if (-not $isGit) {
            Write-Color "  [ORPHAN-DEL] $p" Magenta
            if (Confirm-Delete -Path $p -Auto:$y) {
                Remove-Item $p -Recurse -Force 2>&1
            }
            return
        }

        $dirty = (git -C $p status --porcelain 2>&1 | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($dirty)) {
            Write-Color "  [ORPHAN-CLEAN-DEL] $p" DarkMagenta
            if (Confirm-Delete -Path $p -Auto:$y) {
                Remove-Item $p -Recurse -Force 2>&1
            }
        } else {
            Write-Color "  [ORPHAN-DIRTY-SKIP] $p" Yellow
        }
    }
}