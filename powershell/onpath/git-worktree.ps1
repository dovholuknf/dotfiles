# git-worktree.ps1 — unified worktree lifecycle manager
#
# profile alias: function gwt { & "$env:ON_PATH\git-worktree.ps1" @args }
#
# usage:
#   gwt new <branch> [-From <source>] [-Prompt <str>] [-y]
#   gwt pr  <url-or-number>           [-Prompt <str>] [-y]
#   gwt rm  <branch>                  [-y]
#   gwt ls
#   gwt prune                         [-y]          # current repo only
#   gwt prune -Org <org> [-Repo <r>]  [-y]          # whole org (or one repo)
#   gwt <url>                         [-y]          # bare URL shorthand for pr

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = '',  # subcommand or bare URL

    [Parameter(Position=1)]
    [string]$Target,        # branch, PR number, or URL

    [string]$From,          # 'new': create branch from this source
    [string]$Org,
    [string]$Repo,
    [string]$Prompt,
    [string]$SourceRoot    = 'D:\git',
    [string]$WorktreeRoot  = 'D:\worktrees',
    [switch]$y,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ── helpers ───────────────────────────────────────────────────────────────────

function Write-Color {
    param([string]$Text, [string]$Color = 'White')
    Write-Host $Text -ForegroundColor $Color
}

function Invoke-Git {
    param([string]$RepoPath, [string[]]$GitArgs)
    Push-Location $RepoPath
    try {
        & git @GitArgs
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in $RepoPath" }
    } finally { Pop-Location }
}

function Invoke-GitCapture {
    param([string]$RepoPath, [string[]]$GitArgs)
    Push-Location $RepoPath
    try {
        $out = & git @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in $RepoPath" }
        return $out
    } finally { Pop-Location }
}

function Resolve-RepoContext {
    if (-not $script:Org -or -not $script:Repo) {
        $remoteUrl = & git remote get-url origin 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "not inside a git repo ('$(Get-Location)') — cd into a repo or pass -Org and -Repo"
        }
        if ($remoteUrl -match '(?:github\.com[:/])(?<org>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
            if (-not $script:Org) { $script:Org = $Matches.org }
            if (-not $script:Repo) { $script:Repo = $Matches.repo }
        } else {
            throw "could not parse org/repo from remote URL: $remoteUrl — try passing -Org and -Repo explicitly"
        }
        Write-Color "detected: $($script:Org)/$($script:Repo)" Cyan
    }
    return @{
        Org    = $script:Org
        Repo   = $script:Repo
        Src    = Join-Path (Join-Path (Join-Path $SourceRoot   'github') $script:Org) $script:Repo
        WtRoot = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $script:Org) $script:Repo
    }
}

function Ensure-RepoClonedAndUpdated {
    param([string]$Org, [string]$Repo, [string]$Src)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Src)) | Out-Null
    if (-not (Test-Path $Src)) {
        & git clone "git@github.com:$Org/$Repo.git" $Src 2>&1
        if ($LASTEXITCODE -ne 0) { throw "clone failed: git@github.com:$Org/$Repo.git" }
    }
    Invoke-Git $Src @('fetch','origin','--prune')
    Invoke-Git $Src @('checkout','main')
    Invoke-Git $Src @('pull','--ff-only','origin','main')
}

function Test-LocalBranchExists {
    param([string]$Src, [string]$Branch)
    return -not [string]::IsNullOrWhiteSpace(((Invoke-GitCapture $Src @('branch','--list',$Branch)) -join ''))
}

function Test-RemoteBranchExists {
    param([string]$Src, [string]$Branch)
    return -not [string]::IsNullOrWhiteSpace(((Invoke-GitCapture $Src @('ls-remote','--heads','origin',$Branch)) -join ''))
}

function Get-WorktreePathForBranch {
    param([string]$Src, [string]$Branch)
    $lines = Invoke-GitCapture $Src @('worktree','list','--porcelain')
    $cur = $null
    foreach ($line in $lines) {
        if ($line -match '^worktree\s+(.+)$') { $cur = $Matches[1]; continue }
        if ($line -eq "branch refs/heads/$Branch") { return $cur }
    }
    return $null
}

function Ensure-Worktree {
    param([string]$Src, [string]$WtPath, [string]$Branch)
    if (-not (Test-Path $WtPath)) {
        Invoke-Git $Src @('worktree','add',$WtPath,$Branch)
    }
}

function Get-PrHeadBranch {
    param([string]$Org, [string]$Repo, [string]$PrNumber)
    $r = (& gh pr view $PrNumber --repo "$Org/$Repo" --json headRefName -q .headRefName 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "gh pr view failed for PR ${PrNumber}: $r" }
    return $r
}

function Sync-PrBranch {
    param([string]$Src, [string]$Branch)
    Invoke-Git $Src @('fetch','origin',$Branch)
    if (Test-LocalBranchExists $Src $Branch) {
        Invoke-Git $Src @('branch','-f',$Branch,"origin/$Branch")
    } else {
        Invoke-Git $Src @('branch','--track',$Branch,"origin/$Branch")
    }
}

function Remove-Worktree {
    param([string]$Src, [string]$WtPath, [switch]$AutoConfirm)
    if (-not (Test-Path $WtPath)) {
        Write-Color "worktree not found at '$WtPath', pruning stale registrations" DarkYellow
        Invoke-Git $Src @('worktree','prune')
        return
    }
    $ok = $AutoConfirm -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "remove worktree at '$WtPath'? (Y/n)")) -or $r -match '^[Yy]$')
    if ($ok) {
        Invoke-Git $Src @('worktree','remove','--force',$WtPath)
        Write-Color "removed: $WtPath" Green
    }
}

function Open-ClaudeShell {
    param([string]$Path, [string]$Repo, [string]$Branch, [string]$PromptOverride)
    $p = if ($PromptOverride) { $PromptOverride } else {
        "critique the changes from this branch ($Branch in $Repo). summarize changes commit by commit and pay attention to risks and critique overall design"
    }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Set-Location '$Path'; claude `"$p`""))
    runas /user:claude "wt.exe -d `"$Path`" pwsh -NoExit -EncodedCommand $enc"
}

function Confirm-OpenOrCd {
    param([string]$Path, [string]$Repo, [string]$Branch, [string]$PromptOverride, [switch]$AutoOpen)
    if ($AutoOpen) {
        Open-ClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptOverride $PromptOverride
        return
    }
    $resp = Read-Host "open in claude? (Y/n)"
    if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
        Open-ClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptOverride $PromptOverride
    } else {
        $cd = Read-Host "cd there? (Y/n)"
        if ([string]::IsNullOrWhiteSpace($cd) -or $cd -match '^[Yy]$') {
            Set-Clipboard $Path
            Write-Color "path copied to clipboard — just paste after 'cd '" Cyan
        }
    }
}

# Returns worktree info objects: Branch, Path, Status, Reason
# Status: MAIN | ACTIVE | ACTIVE-NO-REMOTE | PRUNE | DIRTY-MERGED

function Get-WorktreeStatuses {
    param([string]$Src)
    $lines   = & git -C $Src worktree list --porcelain 2>&1
    $srcNorm = $Src.Replace('\','/').ToLower()
    $cur     = $null
    $results = @()

    foreach ($line in $lines) {
        if ($line -match '^worktree\s+(.+)$') { $cur = $Matches[1]; continue }
        if ($line -match '^branch refs/heads/(.+)$') {
            $b      = $Matches[1]
            $isMain = ($cur.Replace('\','/').ToLower() -eq $srcNorm)
            $status = $null
            $reason = $null

            if ($isMain) {
                $status = 'MAIN'
            } elseif (-not (Test-Path $cur)) {
                $status = 'PRUNE'
                $reason = 'missing'
            } else {
                $isDirty = -not [string]::IsNullOrWhiteSpace((& git -C $cur status --porcelain 2>&1 | Out-String).Trim())

                # distinguish "never had upstream" from "upstream was deleted"
                & git -C $Src rev-parse --abbrev-ref "${b}@{upstream}" 2>&1 | Out-Null
                $hasUpstreamConfig = $LASTEXITCODE -eq 0

                if (-not $hasUpstreamConfig) {
                    & git -C $Src merge-base --is-ancestor $b origin/main 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $status = 'PRUNE'
                        $reason = 'merged'
                    } else {
                        $status = 'ACTIVE-NO-REMOTE'
                    }
                } else {
                    & git -C $Src rev-parse --verify "origin/$b" 2>&1 | Out-Null
                    $remoteExists = $LASTEXITCODE -eq 0

                    if (-not $remoteExists) {
                        $status = if ($isDirty) { 'DIRTY-MERGED' } else { 'PRUNE' }
                        $reason = if ($isDirty) { 'remote gone, has local changes' } else { 'gone' }
                    } else {
                        & git -C $Src merge-base --is-ancestor $b origin/main 2>&1 | Out-Null
                        $isMerged = $LASTEXITCODE -eq 0

                        if ($isMerged) {
                            if ($isDirty) {
                                $status = 'DIRTY-MERGED'
                                $reason = 'merged, has local changes'
                            } else {
                                $status = 'PRUNE'
                                $reason = 'merged'
                            }
                        } else {
                            $status = 'ACTIVE'
                        }
                    }
                }
            }

            $results += [PSCustomObject]@{ Branch = $b; Path = $cur; Status = $status; Reason = $reason }
        }
    }
    return $results
}

# ── URL shorthand ─────────────────────────────────────────────────────────────

if ($Help -or -not $Command) { $Command = 'help' }

if ($Command -match '^https?://') {
    $Target  = $Command
    $Command = 'pr'
}

# ── commands ──────────────────────────────────────────────────────────────────

try {
switch ($Command) {

    'new' {
        if (-not $Target) { throw "'new' requires a branch name" }
        $ctx = Resolve-RepoContext
        [System.IO.Directory]::CreateDirectory($ctx.WtRoot) | Out-Null
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src

        if ($From) {
            if (Test-RemoteBranchExists $ctx.Src $From) {
                Invoke-Git $ctx.Src @('fetch','origin',$From)
                if (-not (Get-WorktreePathForBranch $ctx.Src $From)) {
                    Invoke-Git $ctx.Src @('branch','-f',$From,"origin/$From")
                }
            }
        }

        $existingWt = Get-WorktreePathForBranch $ctx.Src $Target
        if ($existingWt) {
            $resp = Read-Host "worktree already exists at '$existingWt'. remove it? (y/N)"
            if ($resp -match '^[Yy]$') {
                Remove-Worktree -Src $ctx.Src -WtPath $existingWt -AutoConfirm
            } else {
                Write-Color "ready: $existingWt" Green
                Confirm-OpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y
                return
            }
        }

        if (-not (Test-LocalBranchExists $ctx.Src $Target)) {
            if ($From) {
                Invoke-Git $ctx.Src @('branch','--no-track',$Target,$From)
            } elseif (Test-RemoteBranchExists $ctx.Src $Target) {
                Invoke-Git $ctx.Src @('branch','--track',$Target,"origin/$Target")
            } else {
                Invoke-Git $ctx.Src @('branch','--no-track',$Target,'origin/main')
            }
        } else {
            # branch exists locally — check for stale tracking (remote deleted)
            & git -C $ctx.Src rev-parse --abbrev-ref "${Target}@{upstream}" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & git -C $ctx.Src rev-parse --verify "origin/$Target" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Color "stale branch '$Target' (upstream gone) — resetting to origin/main" Cyan
                    Invoke-Git $ctx.Src @('branch','--unset-upstream',$Target)
                    Invoke-Git $ctx.Src @('branch','-f',$Target,'origin/main')
                }
            }
        }

        $wtPath = Join-Path $ctx.WtRoot $Target
        Ensure-Worktree $ctx.Src $wtPath $Target
        Write-Color "ready: $wtPath" Green
        Confirm-OpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y
    }

    'pr' {
        if (-not $Target) { throw "'pr' requires a URL or PR number" }

        if ($Target -match '^https?://github\.com/(?<org>[^/]+)/(?<repo>[^/]+?)/pull/(?<pr>\d+)') {
            $script:Org  = $Matches.org
            $script:Repo = $Matches.repo
            $prNum = $Matches.pr
        } elseif ($Target -match '^\d+$') {
            $prNum = $Target
        } else {
            throw "expected a PR URL or number, got: $Target"
        }

        $ctx    = Resolve-RepoContext
        $wtPath = Join-Path $ctx.WtRoot "pr-$prNum"
        [System.IO.Directory]::CreateDirectory($ctx.WtRoot) | Out-Null

        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src
        Invoke-Git $ctx.Src @('worktree','prune')

        $branch     = Get-PrHeadBranch -Org $ctx.Org -Repo $ctx.Repo -PrNumber $prNum
        $existingWt = Get-WorktreePathForBranch $ctx.Src $branch

        if ($existingWt) {
            if ($existingWt.Replace('\','/') -ne $wtPath.Replace('\','/')) {
                throw "branch '$branch' already checked out at '$existingWt' — is there another PR against this branch?"
            }
            $resp = Read-Host "worktree already exists at '$existingWt'. remove it? (y/N)"
            if ($resp -match '^[Yy]$') {
                Remove-Worktree -Src $ctx.Src -WtPath $existingWt -AutoConfirm
            } else {
                Write-Color "ready: $existingWt" Green
                Confirm-OpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
                return
            }
        }

        Sync-PrBranch $ctx.Src $branch
        Ensure-Worktree $ctx.Src $wtPath $branch
        Write-Color "ready: $wtPath" Green
        Confirm-OpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
    }

    'rm' {
        if (-not $Target) { throw "'rm' requires a branch name" }
        $ctx    = Resolve-RepoContext
        $wtPath = Join-Path $ctx.WtRoot $Target
        Remove-Worktree -Src $ctx.Src -WtPath $wtPath -AutoConfirm:$y
    }

    { $_ -in 'ls','list' } {
        $ctx      = Resolve-RepoContext
        $statuses = Get-WorktreeStatuses $ctx.Src

        $colorMap = @{
            'MAIN'             = 'DarkGray'
            'ACTIVE'           = 'Green'
            'ACTIVE-NO-REMOTE' = 'Cyan'
            'PRUNE'            = 'Red'
            'DIRTY-MERGED'     = 'Yellow'
        }

        foreach ($wt in $statuses) {
            $color = $colorMap[$wt.Status]
            $raw   = if ($wt.Status -eq 'PRUNE' -and $wt.Reason) { "PRUNE $($wt.Reason)" } else { $wt.Status }
            $label = $raw.PadRight(16)
            Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" $color
            if ($wt.Status -eq 'DIRTY-MERGED' -and $wt.Reason) {
                Write-Color "                    $($wt.Reason)" $color
            }
        }
    }

    'update' {
        $ctx = Resolve-RepoContext
        Write-Color "fetching origin..." DarkGray
        & git -C $ctx.Src fetch origin --prune 2>&1 | Out-Null

        $statuses = Get-WorktreeStatuses $ctx.Src

        foreach ($wt in $statuses) {
            if ($wt.Status -eq 'MAIN') { continue }
            if ($wt.Status -notin @('ACTIVE','ACTIVE-NO-REMOTE')) { continue }

            # only pull worktrees that have a live remote tracking branch
            & git -C $ctx.Src rev-parse --abbrev-ref "$($wt.Branch)@{upstream}" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Color "  [SKIP   ] $($wt.Branch) — no upstream" DarkGray
                continue
            }
            & git -C $ctx.Src rev-parse --verify "origin/$($wt.Branch)" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Color "  [SKIP   ] $($wt.Branch) — remote branch gone" DarkGray
                continue
            }

            $isDirty = -not [string]::IsNullOrWhiteSpace((& git -C $wt.Path status --porcelain 2>&1 | Out-String).Trim())
            if ($isDirty) {
                Write-Color "  [SKIP   ] $($wt.Branch) — dirty, skipping" Yellow
                continue
            }

            $result = & git -C $wt.Path pull --ff-only 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Color "  [FAIL   ] $($wt.Branch) — cannot fast-forward" Red
                Write-Color "            $($result.Trim())" Red
            } else {
                $msg = if ($result -match 'Already up to date') { 'up to date' } else { 'updated' }
                Write-Color "  [OK     ] $($wt.Branch) — $msg" Green
            }
        }
    }

    'prune' {
        $reposToProcess = @()

        if ($Org) {
            $basePath = Join-Path (Join-Path $SourceRoot 'github') $Org
            if (-not (Test-Path $basePath)) { throw "org path not found: $basePath" }
            $candidates = if ($Repo) {
                @(Join-Path $basePath $Repo)
            } else {
                Get-ChildItem $basePath -Directory | Select-Object -ExpandProperty FullName
            }
            $reposToProcess = $candidates | Where-Object { Test-Path (Join-Path $_ '.git') }
        } else {
            $ctx = Resolve-RepoContext
            $reposToProcess = @($ctx.Src)
        }

        foreach ($repoPath in $reposToProcess) {
            Write-Color "`nrepo: $repoPath" Cyan
            & git -C $repoPath fetch origin --prune 2>&1 | Out-Null

            $statuses    = Get-WorktreeStatuses $repoPath
            $registered  = $statuses | ForEach-Object { $_.Path.Replace('\','/').ToLower() }

            foreach ($wt in $statuses) {
                $raw   = if ($wt.Status -eq 'PRUNE' -and $wt.Reason) { "PRUNE $($wt.Reason)" } else { $wt.Status }
                $label = $raw.PadRight(16)
                switch ($wt.Status) {
                    'MAIN'             { Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" DarkGray }
                    'ACTIVE'           { Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Green }
                    'ACTIVE-NO-REMOTE' { Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Cyan }
                    'DIRTY-MERGED'     {
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Yellow
                        Write-Color "                    $($wt.Reason) — keeping, review before removing" Yellow
                    }
                    'PRUNE'            {
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Red
                        $ok = $y -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "  remove? (Y/n)")) -or $r -match '^[Yy]$')
                        if ($ok) {
                            & git -C $repoPath worktree remove --force $wt.Path 2>&1 | Out-Null
                            Write-Color "                    removed." DarkGray
                        }
                    }
                }
            }

            & git -C $repoPath worktree prune 2>&1 | Out-Null

            # orphan directories in worktree root that git no longer knows about
            $orgPart  = if ($Org) { $Org } else { Split-Path (Split-Path $repoPath -Parent) -Leaf }
            $repoPart = Split-Path $repoPath -Leaf
            $wtRoot   = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $orgPart) $repoPart

            if (-not (Test-Path $wtRoot)) { continue }

            Get-ChildItem $wtRoot -Directory | ForEach-Object {
                $p     = $_.FullName
                $pNorm = $p.Replace('\','/').ToLower()
                if ($registered -contains $pNorm) { return }

                $dirty = (& git -C $p status --porcelain 2>&1 | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($dirty)) {
                    Write-Color "  [ORPHAN ] $p" Magenta
                    $ok = $y -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "  remove orphan? (Y/n)")) -or $r -match '^[Yy]$')
                    if ($ok) { Remove-Item $p -Recurse -Force }
                } else {
                    Write-Color "  [ORPHAN-DIRTY-SKIP] $p" Yellow
                }
            }
        }
    }

    { $_ -in 'help','-h','--help' } {
        Write-Host ""
        Write-Host "  gwt " -NoNewline -ForegroundColor Cyan
        Write-Host "— git worktree lifecycle manager"
        Write-Host ""
        Write-Host "  COMMANDS" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt new " -NoNewline -ForegroundColor Cyan
        Write-Host "<branch> [-From <src>] [-Prompt <str>] [-y]"
        Write-Host "        create (or reopen) a worktree for a branch" -ForegroundColor DarkGray
        Write-Host "        -From   fork from this branch instead of origin/main" -ForegroundColor DarkGray
        Write-Host "        -Prompt override the default claude prompt" -ForegroundColor DarkGray
        Write-Host "        -y      skip confirmation prompts" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt pr " -NoNewline -ForegroundColor Cyan
        Write-Host "<url-or-number> [-Prompt <str>] [-y]"
        Write-Host "        create (or reopen) a worktree for a PR" -ForegroundColor DarkGray
        Write-Host "        accepts a full GitHub PR URL or a bare PR number" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt <url> " -NoNewline -ForegroundColor Cyan
        Write-Host "[-y]"
        Write-Host "        shorthand — bare URL auto-routes to 'pr'" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt rm " -NoNewline -ForegroundColor Cyan
        Write-Host "<branch> [-y]"
        Write-Host "        remove a worktree" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt update" -ForegroundColor Cyan
        Write-Host "        pull --ff-only on all worktrees with a live upstream" -ForegroundColor DarkGray
        Write-Host "        skips dirty worktrees and those with no remote branch" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt ls " -NoNewline -ForegroundColor Cyan
        Write-Host "(alias: list)"
        Write-Host "        list worktrees for the current repo with status:" -ForegroundColor DarkGray
        Write-Host "          [MAIN            ] — primary clone" -ForegroundColor DarkGray
        Write-Host "          [ACTIVE          ] — upstream exists, not yet merged (clean or dirty)" -ForegroundColor Green
        Write-Host "          [ACTIVE-NO-REMOTE] — has local changes, no upstream configured" -ForegroundColor Cyan
        Write-Host "          [PRUNE           ] — safe to delete (merged, remote deleted, or path missing)" -ForegroundColor Red
        Write-Host "          [DIRTY-MERGED    ] — merged/remote-gone but has local changes, kept for review" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    gwt prune " -NoNewline -ForegroundColor Cyan
        Write-Host "[-Org <org>] [-Repo <repo>] [-y]"
        Write-Host "        delete merged+clean worktrees (safe only — skips dirty)" -ForegroundColor DarkGray
        Write-Host "        no flags  — current repo only (auto-detected)" -ForegroundColor DarkGray
        Write-Host "        -Org      — all repos in org; add -Repo to narrow" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  NOTES" -ForegroundColor DarkGray
        Write-Host "    org/repo auto-detected from 'git remote get-url origin'" -ForegroundColor DarkGray
        Write-Host "    sources cloned under  $SourceRoot\github\<org>\<repo>" -ForegroundColor DarkGray
        Write-Host "    worktrees created under  $WorktreeRoot\github\<org>\<repo>" -ForegroundColor DarkGray
        Write-Host ""
    }

    default { throw "unknown command '$Command'. try: gwt help" }
}
} catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "run 'gwt help' for usage" -ForegroundColor DarkGray
    exit 1
}
