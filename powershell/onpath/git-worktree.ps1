# git-worktree.ps1 -- unified worktree lifecycle manager
#
# profile alias: function gwt { & "$env:ON_PATH\git-worktree.ps1" @args }
#
# usage:
#   gwt new  <branch> [-From <source>] [-Prompt <str>] [-y]
#   gwt twig <branch>                 [-Prompt <str>] [-y]  # branch off current worktree's HEAD
#   gwt pr  <url-or-number>           [-Prompt <str>] [-y]
#   gwt rm  <branch>                  [-y]
#   gwt ls
#   gwt prune                         [-y]          # current repo, all worktrees
#   gwt prune <branch>                [-y]          # current repo, one worktree
#   gwt prune -Org <org> [-Repo <r>]  [-y]          # whole org (or one repo)
#   gwt cd  <branch>                                # cd to that branch's worktree (needs profile wrapper)
#   gwt <url>                         [-y]          # bare URL shorthand for pr

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = '',  # subcommand or bare URL

    [Parameter(Position=1)]
    [string]$Target,        # branch, PR number, or URL

    [Parameter(Position=2)]
    [string]$Match,         # 'gwt sessions restore <pattern>' filters by Branch/WorktreePath substring

    [switch]$V,             # show runas chatter ("Attempting to start..." etc); off by default

    [string]$From,          # 'new': create branch from this source
    [string]$Org,
    [string]$Repo,
    [string]$RemoteHost,    # explicit host (e.g. 'github.com', 'bitbucket.org') -- for callers that don't have a git remote to detect from
    [string]$Prompt,
    [string]$SourceRoot    = 'D:\git',
    [string]$WorktreeRoot  = 'D:\worktrees',
    [switch]$y,
    [switch]$Reselect,      # force re-prompt instead of reusing saved picks
    [switch]$NoAgentSetup,  # skip the post-create dotagents CLAUDE.md symlink step
    [switch]$All,           # 'sessions clean -All' also drops alive entries (default = stale only)
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Spawning, theming, hook dispatch, session-tracking, and listing/recovery
# helpers all live in claude-shell.ps1 -- shared between gwt and claudeshell.
. (Join-Path $PSScriptRoot '..\claude-shell.ps1')

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

function _HostShort {
    param([string]$h)
    switch ($h) {
        'github.com'    { 'github'    }
        'bitbucket.org' { 'bitbucket' }
        'gitlab.com'    { 'gitlab'    }
        default         { $h }
    }
}

function Resolve-RepoContext {
    # If Org/Repo were passed explicitly, accept an explicit -RemoteHost too (or
    # default to github.com) -- we don't need to consult a git remote at all.
    if ($script:Org -and $script:Repo -and -not $script:RemoteHost) {
        $script:RemoteHost = if ($RemoteHost) { $RemoteHost } else { 'github.com' }
    }

    if (-not $script:Org -or -not $script:Repo -or -not $script:RemoteHost) {
        $remoteUrl = & git remote get-url origin 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "not inside a git repo ('$(Get-Location)') -- cd into a repo or pass -Org and -Repo"
        }
        # Mark that we resolved org/repo from cwd's git remote -- the layout
        # check below only matters in that case.
        $script:OrgRepoFromCwd = $true
        # accept github, bitbucket, gitlab, custom forges. Capture host + last
        # two path components from any of:
        #   git@host:org/repo(.git)
        #   https://host/org/repo(.git)
        #   ssh://git@host/org/repo(.git)
        if ($remoteUrl -match '(?:^|@|//)(?<host>[^/:@\s]+)[:/](?<org>[^/:@\s]+)/(?<repo>[^/\s]+?)(?:\.git)?/?\s*$') {
            if (-not $script:Org)        { $script:Org        = $Matches.org }
            if (-not $script:Repo)       { $script:Repo       = $Matches.repo }
            if (-not $script:RemoteHost) { $script:RemoteHost = $Matches.host }
        } else {
            throw "could not parse host/org/repo from remote URL: $remoteUrl -- try passing -Org and -Repo explicitly"
        }
        Write-Color "detected: $($script:RemoteHost) $($script:Org)/$($script:Repo)" Cyan
    }
    $hostShort = _HostShort $script:RemoteHost
    $src       = Join-Path (Join-Path (Join-Path $SourceRoot   $hostShort) $script:Org) $script:Repo
    $wtroot    = Join-Path (Join-Path (Join-Path $WorktreeRoot $hostShort) $script:Org) $script:Repo

    # Layout check: if cwd doesn't fit the canonical <SourceRoot>\<host>\<org>\<repo>
    # or <WorktreeRoot>\<host>\<org>\<repo>\* pattern, warn and prompt for confirmation.
    # Default is to abort -- gwt computes paths from the canonical layout, so a
    # non-canonical cwd often means you'd be operating on the wrong clone.
    # -y bypasses this prompt.
    # Layout warning only relevant when org/repo were inferred from cwd. When a
    # caller (gwt pr <url>, gwt discourse, gwt <bare url>, etc.) set them
    # explicitly, the cwd doesn't matter.
    if (-not $script:WarnedLayout -and $script:OrgRepoFromCwd) {
        $cwd = (Get-Location).Path.TrimEnd('\') + '\'
        $sb  = $src.TrimEnd('\')    + '\'
        $wb  = $wtroot.TrimEnd('\') + '\'
        $cmp = [System.StringComparison]::OrdinalIgnoreCase
        $inSrc = $cwd.StartsWith($sb, $cmp)
        $inWt  = $cwd.StartsWith($wb, $cmp)
        if (-not ($inSrc -or $inWt)) {
            Write-Color "warning: cwd doesn't fit the canonical gwt layout" Yellow
            Write-Color "  cwd:       $((Get-Location).Path)" DarkGray
            Write-Color "  expected:  $src" DarkGray
            Write-Color "  or under:  $wtroot\<branch>" DarkGray
            Write-Color "  gwt will use the canonical paths above, NOT your cwd." DarkGray
            if (-not $y) {
                $resp = Read-Host "proceed using canonical paths? (y/N)"
                if (-not ($resp -match '^[Yy]$')) {
                    throw "aborted -- cd to the canonical clone first, or pass -y to override"
                }
            }
        }
        $script:WarnedLayout = $true
    }

    return @{
        Org        = $script:Org
        Repo       = $script:Repo
        RemoteHost = $script:RemoteHost
        HostShort  = $hostShort
        Src        = $src
        WtRoot     = $wtroot
    }
}

function Ensure-RepoClonedAndUpdated {
    param([string]$Org, [string]$Repo, [string]$Src, [string]$RemoteHost = 'github.com')
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Src)) | Out-Null
    if (-not (Test-Path $Src)) {
        $url = "git@${RemoteHost}:$Org/$Repo.git"
        & git clone $url $Src 2>&1
        if ($LASTEXITCODE -ne 0) { throw "clone failed: $url" }
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
    # valid worktrees have a `.git` file (not dir) pointing at the gitdir
    if (Test-Path (Join-Path $WtPath '.git')) { return }
    if (Test-Path $WtPath) {
        Write-Color "path '$WtPath' exists but isn't a valid worktree -- cleaning up residue" Yellow
        try {
            Remove-Item $WtPath -Recurse -Force -ErrorAction Stop
        } catch {
            throw "couldn't remove residual '$WtPath' (often: another shell has it as cwd). Close that shell or 'cd' away, then retry."
        }
    }
    Invoke-Git $Src @('worktree','add',$WtPath,$Branch)
    Invoke-AgentSetup -Path $WtPath
}

function Invoke-AgentSetup {
    param([string]$Path)
    if ($script:NoAgentSetup) { return }
    $setupScript = 'D:\git\github\dovholuknf\dotagents\scripts\setup-agents.ps1'
    if (-not (Test-Path $setupScript)) {
        Write-Color "dotagents setup-agents.ps1 not found at '$setupScript' -- skipping CLAUDE.md symlink" Yellow
        return
    }
    & pwsh -NoProfile -File $setupScript -Path $Path
    if ($LASTEXITCODE -ne 0) {
        Write-Color "warning: setup-agents.ps1 exited $LASTEXITCODE (worktree itself was created OK)" Yellow
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

function _CleanupWorktreeMetadata {
    # Drops the session-registry entries and picks state file for a removed
    # worktree. Used by both 'rm' and 'prune' so the cleanup is consistent.
    # Claude project history is left in place (separate user-controlled concern).
    param([string]$WtPath)
    $sessionDir = 'D:\worktrees\sessions'
    $normWt = ($WtPath -replace '/', '\').TrimEnd('\').ToLower()

    if (Test-Path $sessionDir) {
        Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if (-not $e.WorktreePath) { return }
                if ((($e.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()) -eq $normWt) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    Write-Color "    dropped session entry: $($_.Name)" DarkGray
                }
            } catch {}
        }
    }

    $slug      = ($WtPath -replace '[:\\/]', '-').Trim('-')
    $stateFile = Join-Path $env:LOCALAPPDATA "gwt\state\$slug.json"
    if (Test-Path $stateFile) {
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        Write-Color "    dropped picks state" DarkGray
    }
}

function Get-GwtStatePath {
    param([string]$WorktreePath)
    $slug = ($WorktreePath -replace '[:\\/]', '-').Trim('-')
    $dir  = Join-Path $env:LOCALAPPDATA 'gwt\state'
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    return Join-Path $dir "$slug.json"
}

function Load-GwtState {
    param([string]$WorktreePath)
    $p = Get-GwtStatePath $WorktreePath
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-GwtState {
    param([string]$WorktreePath, [hashtable]$State)
    $p = Get-GwtStatePath $WorktreePath
    ($State | ConvertTo-Json -Compress) | Set-Content -Path $p -Encoding UTF8
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

            # last commit on this branch (ISO so we can sort; relative so we can display)
            $lcIso = $null; $lcRel = $null; $lcDate = [datetime]::MinValue
            $lcRaw = (& git -C $Src log -1 --format='%cI|%cr' "refs/heads/$b" 2>$null | Out-String).Trim()
            if ($lcRaw -and $lcRaw.Contains('|')) {
                $parts = $lcRaw.Split('|', 2)
                $lcIso = $parts[0]; $lcRel = $parts[1]
                [datetime]::TryParse($lcIso, [ref]$lcDate) | Out-Null
            }

            $results += [PSCustomObject]@{
                Branch    = $b
                Path      = $cur
                Status    = $status
                Reason    = $reason
                LastCommit = $lcDate
                LastCommitRel = $lcRel
            }
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
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost

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
                # The initial fetch in Ensure-RepoClonedAndUpdated normally already
                # brings down origin/<Target>. Only re-fetch explicitly if it's
                # missing (e.g. repos with restricted fetch refspecs). Use a fully
                # qualified refspec -- bare-name lhs can resolve to nothing and
                # cause git to delete the dest tracking ref.
                & git -C $ctx.Src rev-parse --verify "origin/$Target" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Invoke-Git $ctx.Src @('fetch','origin',"+refs/heads/${Target}:refs/remotes/origin/$Target")
                }
                & git -C $ctx.Src rev-parse --verify "origin/$Target" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Invoke-Git $ctx.Src @('branch','--track',$Target,"origin/$Target")
                } else {
                    Write-Color "remote branch '$Target' could not be fetched -- branching off origin/main" Yellow
                    Invoke-Git $ctx.Src @('branch','--no-track',$Target,'origin/main')
                }
            } else {
                Invoke-Git $ctx.Src @('branch','--no-track',$Target,'origin/main')
            }
        } else {
            # branch exists locally -- reconcile with remote so we don't silently
            # check out a stale local copy that diverges from origin.
            & git -C $ctx.Src rev-parse --verify "origin/$Target" 2>&1 | Out-Null
            $remoteHas = $LASTEXITCODE -eq 0

            & git -C $ctx.Src rev-parse --abbrev-ref "${Target}@{upstream}" 2>&1 | Out-Null
            $hasUpstream = $LASTEXITCODE -eq 0

            if ($hasUpstream -and -not $remoteHas) {
                Write-Color "stale branch '$Target' (upstream gone) -- resetting to origin/main" Cyan
                Invoke-Git $ctx.Src @('branch','--unset-upstream',$Target)
                Invoke-Git $ctx.Src @('branch','-f',$Target,'origin/main')
            } elseif ($remoteHas) {
                $localSha  = ((& git -C $ctx.Src rev-parse $Target) | Out-String).Trim()
                $remoteSha = ((& git -C $ctx.Src rev-parse "origin/$Target") | Out-String).Trim()
                if ($localSha -ne $remoteSha) {
                    $ahead  = [int]((& git -C $ctx.Src rev-list --count "origin/$Target..$Target") | Out-String).Trim()
                    $behind = [int]((& git -C $ctx.Src rev-list --count "$Target..origin/$Target") | Out-String).Trim()
                    if ($ahead -eq 0 -and $behind -gt 0) {
                        Write-Color "local '$Target' is $behind commits behind origin -- fast-forwarding" Cyan
                        Invoke-Git $ctx.Src @('branch','-f',$Target,"origin/$Target")
                        if (-not $hasUpstream) {
                            Invoke-Git $ctx.Src @('branch','--set-upstream-to',"origin/$Target",$Target)
                        }
                    } elseif ($ahead -gt 0 -and $behind -gt 0) {
                        Write-Color "local '$Target' has diverged from origin ($ahead ahead, $behind behind)." Yellow
                        $resp = if ($y) { 'y' } else { Read-Host "discard local and reset to origin/$Target? (Y/n)" }
                        if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
                            Invoke-Git $ctx.Src @('branch','-f',$Target,"origin/$Target")
                        } else {
                            throw "keeping local '$Target'. Resolve manually, or re-run with -y to auto-discard."
                        }
                    }
                    # ahead-only: keep local as-is, user has unpushed work
                }
            }
        }

        $wtPath = Join-Path $ctx.WtRoot $Target
        Ensure-Worktree $ctx.Src $wtPath $Target
        Write-Color "ready: $wtPath" Green
        Invoke-GwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath
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

        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost
        Invoke-Git $ctx.Src @('worktree','prune')

        $branch     = Get-PrHeadBranch -Org $ctx.Org -Repo $ctx.Repo -PrNumber $prNum
        $existingWt = Get-WorktreePathForBranch $ctx.Src $branch

        if ($existingWt) {
            if ($existingWt.Replace('\','/') -ne $wtPath.Replace('\','/')) {
                throw "branch '$branch' already checked out at '$existingWt' -- is there another PR against this branch?"
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
        Invoke-GwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath
        Confirm-OpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
    }

    'discourse' {
        # Create a worktree to investigate a discourse topic. Accepts:
        #   * full URL with id  -- https://host/t/slug/12345
        #   * URL without id    -- https://host/t/slug   (probes for id via HEAD redirect)
        #   * bare numeric id   -- 12345                 (assumes openziti.discourse.group)
        if (-not $Target) { throw "'discourse' requires a discourse topic URL or numeric topic id" }
        $topicId       = $null
        $titleSlug     = ''
        $discourseHost = $null

        if ($Target -match '^\d+$') {
            $topicId       = $Target
            $discourseHost = 'openziti.discourse.group'
            Write-Color "bare topic id -- assuming host openziti.discourse.group" DarkGray
        } elseif ($Target -match '^https?://(?<dhost>[^/]+).*?/t/(?<slug>[^/]+)/(?<id>\d+)') {
            $topicId       = $Matches.id
            $titleSlug     = $Matches.slug
            $discourseHost = $Matches.dhost
        } elseif ($Target -match '^https?://(?<dhost>[^/]+).*?/t/(?<slug>[^/]+)/?$') {
            # URL without an id -- discourse 301-redirects /t/<slug> to /t/<slug>/<id>.
            $titleSlug     = $Matches.slug
            $discourseHost = $Matches.dhost
            Write-Color "no topic id in URL -- probing $Target for redirect..." DarkGray
            try {
                $resp = Invoke-WebRequest -Uri $Target -Method Head -ErrorAction Stop
                $final = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
                if ($final -match '/t/[^/]+/(?<id>\d+)') {
                    $topicId = $Matches.id
                    Write-Color "  resolved -> topic id $topicId" DarkGray
                } else {
                    throw "redirect did not include a numeric topic id (final URL: $final)"
                }
            } catch {
                throw "could not resolve topic id from URL: $($_.Exception.Message)"
            }
        } else {
            throw "expected a discourse topic URL or bare numeric topic id"
        }

        $orgGuess = ($discourseHost -split '\.')[0]

        $topicLabel = if ($titleSlug) { "$titleSlug ($topicId)" } else { "topic $topicId" }
        Write-Color "discourse topic: $topicLabel" Cyan
        Write-Color "discourse host:  $discourseHost" DarkGray

        # Accept either 'org/repo' (default github) or 'host:org/repo'
        $resp = (Read-Host "target repo (default github, e.g. '$orgGuess/ziti' or 'bitbucket.org:org/repo')").Trim()
        if (-not $resp) { throw "no repo given -- aborted" }

        $hostPart = 'github.com'
        $orgRepo  = $resp
        if ($resp -match '^(?<host>[^:]+):(?<rest>.+)$') {
            $hostPart = $Matches.host
            $orgRepo  = $Matches.rest
        }
        if ($orgRepo -notmatch '^(?<org>[^/]+)/(?<repo>[^/]+)$') {
            throw "expected 'org/repo' -- got '$orgRepo'"
        }
        $orgPart  = $Matches.org
        $repoPart = $Matches.repo
        Write-Color "using $hostPart : $orgPart/$repoPart" Cyan

        $branch = "discourse-$topicId"
        Write-Color "branch:          $branch" DarkGray

        # Forward to 'new' with explicit host/org/repo so Resolve-RepoContext
        # doesn't need a cwd-based git remote.
        $fwd = @{
            Command    = 'new'
            Target     = $branch
            Org        = $orgPart
            Repo       = $repoPart
            RemoteHost = $hostPart
        }
        if ($y)      { $fwd.y      = $true }
        if ($Prompt) { $fwd.Prompt = $Prompt }
        & $PSCommandPath @fwd
        return
    }

    'twig' {
        if (-not $Target) { throw "'twig' requires a new branch name" }

        $current = (& git rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $current -or $current -eq 'HEAD') {
            throw "can't detect current branch -- are you inside a git worktree?"
        }
        $currentWt = (& git rev-parse --show-toplevel 2>&1 | Out-String).Trim()

        # capture dirty state as a patch (tracked changes only -- git diff excludes untracked)
        $patchFile = $null
        $untracked = @()
        $status    = & git -C $currentWt status --porcelain 2>&1
        if ($LASTEXITCODE -eq 0 -and $status) {
            $patchFile = Join-Path $env:TEMP ("gwt-twig-{0}.patch" -f ([guid]::NewGuid()))
            # --output lets git write the file itself (avoids PS UTF-16 BOM issues from `>`)
            Invoke-Git $currentWt @('diff','HEAD','--binary',"--output=$patchFile")
            $untracked = @($status | Where-Object { $_ -match '^\?\? ' } | ForEach-Object { $_.Substring(3).Trim('"') })
            Write-Color "captured working changes: $patchFile" Cyan
        }

        # untracked files can't be represented in a patch -- prompt whether to copy them
        $carryUntracked = @()
        if ($untracked.Count) {
            Write-Color "found $($untracked.Count) untracked file(s):" Yellow
            foreach ($u in $untracked) { Write-Color "  $u" Yellow }
            $resp = if ($y) { 'y' } else { Read-Host "carry untracked files to new worktree too? (Y/n)" }
            if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
                $carryUntracked = $untracked
            }
        }

        Write-Color "twigging '$Target' off '$current'" Cyan

        $ctx = Resolve-RepoContext
        [System.IO.Directory]::CreateDirectory($ctx.WtRoot) | Out-Null
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost

        if (Test-LocalBranchExists $ctx.Src $Target) {
            throw "branch '$Target' already exists -- pick a different name"
        }
        # branch off whatever $current currently points to locally -- do NOT force-update it
        Invoke-Git $ctx.Src @('branch','--no-track',$Target,$current)

        $wtPath = Join-Path $ctx.WtRoot $Target
        Ensure-Worktree $ctx.Src $wtPath $Target
        Write-Color "ready: $wtPath" Green

        if ($carryUntracked.Count) {
            Write-Color "copying untracked files..." Cyan
            foreach ($rel in $carryUntracked) {
                $src = Join-Path $currentWt $rel
                $dst = Join-Path $wtPath    $rel
                if (-not (Test-Path $src)) {
                    Write-Color "  skip (missing): $rel" Yellow
                    continue
                }
                $dstDir = Split-Path $dst -Parent
                if ($dstDir) { [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null }
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Write-Color "  copied: $rel" DarkGray
            }
        }

        if ($patchFile -and (Test-Path $patchFile) -and (Get-Item $patchFile).Length -gt 0) {
            Write-Color "applying carried changes..." Cyan
            & git -C $wtPath apply --index $patchFile 2>&1 | Out-String | Write-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Color "patch did not apply cleanly -- left at: $patchFile" Red
            } else {
                Write-Color "carried changes applied (staged)." Green
                Remove-Item $patchFile -Force
            }
        }

        Invoke-GwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath
        Confirm-OpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y
        return
    }

    'update-registry' {
        # Manual freshness/fetch for the fallback gwt-session-registry.ps1 at
        # ~\.gwt\. No-op (with a hint) if the dotfiles copy exists -- that's
        # primary, you update it via git pull.
        $primary  = 'D:\git\github\dovholuknf\dotfiles\powershell\gwt-session-registry.ps1'
        $fallback = Join-Path $env:USERPROFILE '.gwt\gwt-session-registry.ps1'
        $stamp    = "$fallback.last-fetched"
        $url      = 'https://raw.githubusercontent.com/dovholuknf/dotfiles/main/powershell/gwt-session-registry.ps1'

        if (Test-Path $primary) {
            Write-Color "primary copy at $primary -- update via git pull" DarkGray
            return
        }
        New-Item -ItemType Directory -Path (Split-Path $fallback) -Force | Out-Null
        try {
            Invoke-WebRequest $url -OutFile $fallback -UseBasicParsing
            Set-Content -Path $stamp -Value (Get-Date).ToString('o')
            Write-Color "fetched -> $fallback" Green
        } catch {
            Write-Color "fetch failed: $_" Red
        }
    }

    'sessions' {
        # Shared location so both clint and the spawned claude user shells can read/write.
        $sessionDir = 'D:\worktrees\sessions'
        Write-Color "gwt sessions: scanning '$sessionDir'" DarkGray
        if (-not (Test-Path $sessionDir)) {
            Write-Color "  directory does not exist (or not readable from this user)" Yellow
            Write-Color "  hint: run 'icacls $sessionDir' to inspect ACL, or create it via mkdir" DarkGray
            return
        }

        $jsonFiles = @(Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)
        Write-Color "  found $($jsonFiles.Count) *.json file(s)" DarkGray
        if ($jsonFiles.Count -eq 0) {
            Write-Color "  (empty -- no sessions have been registered yet)" DarkGray
            return
        }

        # One batched CIM query for all running processes -- keyed by PID for O(1) lookup.
        # Avoids per-entry WMI calls which were ~200ms each (13 entries = 2.6s).
        $procMap = @{}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            $procMap[[int]$_.ProcessId] = $_
        }

        $parseFails = 0
        $entries = $jsonFiles | ForEach-Object {
            try {
                $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
                # normalize path slashes -- legacy entries used '/', new ones use '\';
                # without this, dedupe by WorktreePath misses the duplicates.
                if ($e.WorktreePath) { $e.WorktreePath = ($e.WorktreePath -replace '/', '\').TrimEnd('\') }
                $alive = $false
                if ($e.Pid -and $e.Pid -ne 0) {
                    $cim = $procMap[[int]$e.Pid]
                    if ($cim) {
                        if ($e.StartTime -and $cim.CreationDate) {
                            $alive = [math]::Abs(($cim.CreationDate - [datetime]::Parse($e.StartTime)).TotalSeconds) -lt 2
                        } else {
                            $alive = $true
                        }
                    }
                }
                $e | Add-Member -NotePropertyName Alive -NotePropertyValue $alive -PassThru |
                     Add-Member -NotePropertyName File  -NotePropertyValue $_.FullName -PassThru
            } catch {
                $parseFails++
                Write-Color "  failed to parse $($_.Name): $_" Yellow
            }
        }
        if ($parseFails -gt 0) { Write-Color "  $parseFails file(s) failed to parse (skipped)" Yellow }
        Write-Color "  parsed $(@($entries).Count) entry/entries" DarkGray

        # subcommand under 'sessions': default = list. 'restore' = relaunch stale.
        # 'clean' = drop stale entries without relaunch.
        switch ($Target) {
            'restore' {
                # Idempotency: only consider STALE entries -- alive ones are already up.
                $allStale = @($entries | Where-Object { -not $_.Alive })
                if (-not $allStale.Count) { Write-Color "no stale sessions to restore (all alive -- nothing to do)" DarkGray; return }

                # dedupe by WorktreePath (keeps newest by LastSpawnedAt) -- protects against
                # accumulated leftover entries from failed prior launches blowing up the count.
                # Then sort ASC by FirstSpawnedAt so restore replays in original-add order.
                $stale = $allStale |
                         Group-Object WorktreePath |
                         ForEach-Object {
                             $_.Group |
                             Sort-Object @{Expression={ if ($_.LastSpawnedAt) { $_.LastSpawnedAt } else { $_.SpawnedAt } }} -Descending |
                             Select-Object -First 1
                         } |
                         Sort-Object @{Expression={ if ($_.FirstSpawnedAt) { $_.FirstSpawnedAt } else { $_.SpawnedAt } }}

                # Optional 3rd positional arg = substring filter (Branch, WorktreePath, or WindowName).
                if ($Match) {
                    $filtered = @($stale | Where-Object {
                        $_.Branch -like "*$Match*" -or
                        $_.WorktreePath -like "*$Match*" -or
                        $_.WindowName -like "*$Match*"
                    })
                    if (-not $filtered.Count) {
                        Write-Color "no stale entries match '$Match'" Yellow
                        return
                    }
                    $stale = $filtered
                    Write-Color "filter '$Match' -> $($stale.Count) match(es)" Cyan
                }

                $dupes = $allStale.Count - @($stale).Count
                if (-not $Match -and $dupes -gt 0) {
                    Write-Color "skipping $dupes duplicate(s) -- run 'gwt sessions clean' to drop them" DarkGray
                }

                Write-Host ""
                foreach ($s in $stale) { Write-Color "  $($s.Branch) -> $($s.WindowName)" DarkGray }
                Write-Host ""

                # Pick mode: open all, prompt per-entry, or nothing.
                # If filter narrowed to a single entry, skip the all/per dance.
                $perEntry = $false
                if (@($stale).Count -eq 1) {
                    $resp = Read-Host "open this 1 session? (Y/n)"
                    if (-not ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$')) {
                        Write-Color "aborted" Yellow
                        return
                    }
                } else {
                    $resp = Read-Host "open all $(@($stale).Count) sessions? (Y/n)"
                    if (-not ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$')) {
                        $resp2 = Read-Host "prompt for each individually instead? (y/N)"
                        if ($resp2 -match '^[Yy]$') {
                            $perEntry = $true
                        } else {
                            Write-Color "aborted" Yellow
                            return
                        }
                    }
                }

                foreach ($s in $stale) {
                    if (-not (Test-Path $s.WorktreePath)) {
                        Write-Color "  skip (worktree gone): $($s.Branch) @ $($s.WorktreePath)" Yellow
                        continue
                    }
                    if ($perEntry) {
                        $r = Read-Host "open '$($s.Branch)' -> $($s.WindowName)? (y/N)"
                        if (-not ($r -match '^[Yy]$')) {
                            Write-Color "    skipped" DarkGray
                            continue
                        }
                    }
                    Write-Color "  relaunch: $($s.Branch) -> window=$($s.WindowName)" Green

                    # Open-ClaudeShell pre-writes a fresh entry with Pid=0 and stashes
                    # the new session id in $script:LastSpawnedSessionId. The spawned
                    # shell calls Register-GwtSession which patches Pid > 0, so polling
                    # that file replaces the arbitrary Start-Sleep we used to do here.
                    Open-ClaudeShell -Path $s.WorktreePath -Repo $s.Repo -Branch $s.Branch `
                                     -PromptText $s.PromptText -WindowName $s.WindowName `
                                     -ReuseSessionId $s.Id
                    $newId = $script:LastSpawnedSessionId
                    if ($newId) {
                        $newFile = Join-Path 'D:\worktrees\sessions' "$newId.json"
                        $deadline = (Get-Date).AddSeconds(15)
                        while ((Get-Date) -lt $deadline) {
                            try {
                                $e = Get-Content $newFile -Raw -ErrorAction Stop | ConvertFrom-Json
                                if ($e.Pid -gt 0) { break }
                            } catch {}
                            Start-Sleep -Milliseconds 100
                        }
                    }
                }
            }
            'close' {
                # Kill the underlying pwsh process for ALIVE entries (the wt tab dies
                # with it). Doesn't touch the registry entry -- it'll show STALE next
                # listing. Optional substring filter narrows to specific entries.
                $alive = @($entries | Where-Object Alive)
                if (-not $alive.Count) { Write-Color "no alive sessions to close" DarkGray; return }

                if ($Match) {
                    $alive = @($alive | Where-Object {
                        $_.Branch -like "*$Match*" -or
                        $_.WorktreePath -like "*$Match*" -or
                        $_.WindowName -like "*$Match*"
                    })
                    if (-not $alive.Count) { Write-Color "no alive entries match '$Match'" Yellow; return }
                    Write-Color "filter '$Match' -> $($alive.Count) match(es)" Cyan
                }

                Write-Host ""
                foreach ($s in $alive) { Write-Color "  $($s.Branch) (pid $($s.Pid)) -> $($s.WindowName)" DarkGray }
                Write-Host ""

                $resp = Read-Host "close $($alive.Count) session(s)? this kills the tab and claude inside it (y/N)"
                if (-not ($resp -match '^[Yy]$')) { Write-Color "aborted" Yellow; return }

                foreach ($s in $alive) {
                    # Kill the whole process tree (/T) -- pwsh has claude as a child,
                    # and wt keeps the tab open as long as ANY process in it is alive.
                    # Try as the current user (clint) first; if that fails (cross-user
                    # access denied), fall back to runas /user:claude as the owner.
                    $killed = $false
                    $null = & taskkill /T /F /PID $s.Pid 2>&1
                    if ($LASTEXITCODE -eq 0) { $killed = $true }
                    if (-not $killed) {
                        $null = & runas /user:claude /savecred "taskkill /T /F /PID $($s.Pid)" 2>&1
                        if ($LASTEXITCODE -eq 0) { $killed = $true }
                    }
                    if ($killed) {
                        Write-Color "  closed: $($s.Branch) (pid $($s.Pid))" Green
                    } else {
                        Write-Color "  failed to close: $($s.Branch) (pid $($s.Pid)) -- exit $LASTEXITCODE" Red
                    }
                }
            }

            'clean' {
                # Default: drop only stale entries. With -All (the script-level switch),
                # also drop alive entries (will not kill the underlying shell -- just
                # forgets the registry entry; the alive shell stays running).
                $toDrop = if ($All) {
                    @($entries)
                } else {
                    @($entries | Where-Object { -not $_.Alive })
                }
                $mode = if ($All) { 'all (alive + stale)' } else { 'stale only (default -- pass -All to also drop alive entries)' }
                Write-Color "cleaning: $mode" DarkGray
                if (-not $toDrop.Count) { Write-Color "  nothing to drop" DarkGray; return }
                foreach ($s in $toDrop) {
                    Remove-Item $s.File -Force -ErrorAction SilentlyContinue
                    $tag = if ($s.Alive) { '(was alive -- entry removed; running shell unaffected)' } else { '(stale)' }
                    Write-Color "  removed: $($s.Branch) $tag" DarkGray
                }
            }
            default {
                if (-not $entries) { Write-Color "no sessions registered yet" DarkGray; return }

                # Dedupe by WorktreePath: alive entries always win; among
                # multiple stales, keep the newest by SpawnedAt. Counts the
                # duplicates so the user knows there's cruft to clean up.
                $deduped = $entries |
                           Group-Object WorktreePath |
                           ForEach-Object {
                               $alive = $_.Group | Where-Object Alive | Select-Object -First 1
                               if ($alive) { $alive }
                               else { $_.Group | Sort-Object SpawnedAt -Descending | Select-Object -First 1 }
                           }
                $dupes = @($entries).Count - @($deduped).Count

                $byWindow = $deduped | Sort-Object @{e='Alive';desc=$true}, WindowName, Branch | Group-Object WindowName
                foreach ($g in $byWindow) {
                    Write-Host ""
                    Write-Color "[$($g.Name)]" Cyan
                    foreach ($s in $g.Group) {
                        $tag = if ($s.Alive) { 'ALIVE' } else { 'STALE' }
                        $col = if ($s.Alive) { 'Green' } else { 'Red' }
                        Write-Color ("  [{0}] {1,-30} @ {2}" -f $tag, $s.Branch, $s.WorktreePath) $col
                    }
                }
                Write-Host ""
                if ($dupes -gt 0) {
                    Write-Color "  $dupes duplicate entrie(s) hidden -- run 'gwt sessions clean' to drop stale dupes" DarkGray
                }
                Write-Color "  gwt sessions restore   relaunch all stale sessions" DarkGray
                Write-Color "  gwt sessions clean     drop stale entries without relaunching" DarkGray
            }
        }
    }

    'claude' {
        if (-not $Target -or $Target -eq '.') {
            $Target = (& git rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $Target -or $Target -eq 'HEAD') {
                throw "'claude' requires a branch name -- and you don't appear to be inside a worktree"
            }
        }
        $ctx    = Resolve-RepoContext
        $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
        if (-not $wtPath) { throw "no worktree for branch '$Target' in $($ctx.Org)/$($ctx.Repo)" }
        if (-not (Test-Path $wtPath)) { throw "worktree path '$wtPath' is registered but missing -- run 'gwt prune'" }

        # Active-session check FIRST, before any state/picks prompts.
        if (-not (Confirm-NoAliveSessionAt -Path $wtPath)) { return }

        Invoke-GwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath

        $state = if ($Reselect) { $null } else { Load-GwtState $wtPath }

        # confirm re-use of saved picks -- 'n' falls through to re-prompt
        if ($state -and -not $y) {
            $winDesc = if ($state.Window -and $state.Window -ne '') { $state.Window } else { 'new window' }
            $resp    = Read-Host "resume last picks? (window=$winDesc, prompt=$($state.PromptName)) (Y/n)"
            if (-not ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$')) {
                $state = $null  # user said no, fall through to interactive pick
            }
        }

        if ($state -and -not $y) {
            $window     = if ($state.Window -eq '') { $null } else { $state.Window }
            $promptText = if ($Prompt) { $Prompt } else { $state.PromptText }
        } elseif ($y) {
            $window     = 'active-work'
            $promptText = if ($Prompt) { $Prompt } else { (_GetClaudePromptPresets -Repo $ctx.Repo -Branch $Target)[0].Text }
        } else {
            $window = Select-WtWindow
            if ($window -eq '__new__') { $window = $null }
            $presets      = _GetClaudePromptPresets -Repo $ctx.Repo -Branch $Target
            $selectedText = if ($Prompt) { $Prompt } else { Select-ClaudePrompt -Repo $ctx.Repo -Branch $Target }
            $selectedName = ($presets | Where-Object { $_.Text -eq $selectedText } | Select-Object -First 1 -ExpandProperty Name)
            if (-not $selectedName) { $selectedName = 'custom' }
            $promptText   = $selectedText
            Save-GwtState -WorktreePath $wtPath -State @{
                Window     = [string]$window
                PromptName = $selectedName
                PromptText = $promptText
                SavedAt    = (Get-Date).ToString('o')
            }
        }

        # -Force here suppresses Open-ClaudeShell's redundant alive-session guard;
        # we already prompted at the top of this block.
        Open-ClaudeShell -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptText $promptText -WindowName $window -Force
    }

    'cd' {
        if (-not $Target) { throw "'cd' requires a branch name" }
        $ctx    = Resolve-RepoContext
        $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
        if (-not $wtPath) { throw "no worktree for branch '$Target' in $($ctx.Org)/$($ctx.Repo)" }
        if (-not (Test-Path $wtPath)) { throw "worktree path '$wtPath' is registered but missing -- run 'gwt prune'" }
        # print ONLY the path to stdout -- the profile's gwt wrapper captures this and Set-Locations it.
        # Write-Color uses Write-Host which bypasses the pipeline, so detection banners are fine.
        Write-Output $wtPath
    }

    'rm' {
        if (-not $Target) { throw "'rm' requires a branch name" }
        $ctx    = Resolve-RepoContext
        $wtPath = Join-Path $ctx.WtRoot $Target
        $normWt = ($wtPath -replace '/', '\').TrimEnd('\').ToLower()

        # Refuse if a session is still alive on this worktree (unless -y/-Force).
        $procMap = @{}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            $procMap[[int]$_.ProcessId] = $_
        }
        $aliveHits = @()
        $sessionsDir = 'D:\worktrees\sessions'
        if (Test-Path $sessionsDir) {
            Get-ChildItem $sessionsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    if (-not $e.WorktreePath) { return }
                    if ((($e.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()) -ne $normWt) { return }
                    if ($e.Pid -and $e.Pid -ne 0 -and $procMap[[int]$e.Pid]) {
                        $aliveHits += $e
                    }
                } catch {}
            }
        }
        if ($aliveHits.Count -gt 0 -and -not $y) {
            Write-Color "a session is still alive for this worktree -- close the tab first or pass -y" Yellow
            foreach ($s in $aliveHits) {
                Write-Color ("  pid={0}  branch={1}  window={2}" -f $s.Pid, $s.Branch, $s.WindowName) DarkGray
            }
            return
        }

        Remove-Worktree -Src $ctx.Src -WtPath $wtPath -AutoConfirm:$y
        _CleanupWorktreeMetadata $wtPath

        # claude project history -- left in place by default; tell user where to find it
        $claudeSlug = ($wtPath -replace '[:\\/]', '-')
        $claudeDir  = "C:\Users\claude\.claude\projects\$claudeSlug"
        if (Test-Path $claudeDir) {
            Write-Color "  claude session history kept at: $claudeDir" DarkGray
            Write-Color "  (delete manually if you want a clean slate)" DarkGray
        }
    }

    { $_ -in 'ls','list' } {
        # Lists git worktrees for the current repo (MAIN + ACTIVE + PRUNE etc).
        # Sessions are shown via 'gwt sessions' -- they're a different lens.
        try {
            $ctx = Resolve-RepoContext
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'not inside a git repo') {
                Write-Color "not inside a git repo -- try 'gwt sessions' for the cross-repo view" Yellow
            } else {
                Write-Color $msg Yellow
            }
            return
        }
        # Fetch + prune so origin/main is fresh before status detection -- otherwise
        # branches that were merged remotely show ACTIVE instead of PRUNE merged.
        Write-Color "fetching origin..." DarkGray
        & git -C $ctx.Src fetch origin --prune 2>&1 | Out-Null

        $allStatuses = Get-WorktreeStatuses $ctx.Src | Sort-Object -Property LastCommit -Descending
        # Pin MAIN to the top, everything else in time-sorted order below.
        $mainEntry = @($allStatuses | Where-Object { $_.Status -eq 'MAIN' })
        $others    = @($allStatuses | Where-Object { $_.Status -ne 'MAIN' })
        $statuses  = $mainEntry + $others

        # Build a path -> window-name map from alive sessions, so we can mark
        # worktrees that currently have a running claude session and show which
        # wt window they're in (active-work / pull-requests / tangent / etc).
        $aliveWindow = @{}
        $sessionDir = 'D:\worktrees\sessions'
        if (Test-Path $sessionDir) {
            $procMap = @{}
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
                $procMap[[int]$_.ProcessId] = $_
            }
            Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    if (-not $e.WorktreePath) { return }
                    if (-not ($e.Pid -and $e.Pid -ne 0 -and $procMap[[int]$e.Pid])) { return }
                    $key = ($e.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()
                    $aliveWindow[$key] = if ($e.WindowName) { $e.WindowName } else { '?' }
                } catch {}
            }
        }

        $statusColorMap = @{
            'MAIN'             = 'DarkGray'
            'ACTIVE'           = 'Green'
            'ACTIVE-NO-REMOTE' = 'Cyan'
            'PRUNE'            = 'Red'
            'DIRTY-MERGED'     = 'Yellow'
        }
        $windowColorMap = @{
            'active-work'   = 'Green'
            'pull-requests' = 'Blue'
            'tangent'       = 'Magenta'
            'worktrees'     = 'DarkGray'
        }

        $printedMain = $false
        foreach ($wt in $statuses) {
            # Print a divider after the MAIN row to visually separate the main
            # clone from the worktrees below.
            if ($printedMain -and $wt.Status -ne 'MAIN') {
                Write-Host ('    ' + ('-' * 90)) -ForegroundColor DarkGray
                $printedMain = $false
            }
            $key   = ($wt.Path -replace '/', '\').TrimEnd('\').ToLower()
            $win   = $aliveWindow[$key]
            $alive = [bool]$win
            $statusColor = $statusColorMap[$wt.Status]
            $raw   = if ($wt.Status -eq 'PRUNE' -and $wt.Reason) { "PRUNE $($wt.Reason)" } else { $wt.Status }
            $label = $raw.PadRight(16)
            $when  = if ($wt.LastCommitRel) { "({0})" -f $wt.LastCommitRel } else { '' }
            $when  = $when.PadRight(22)
            if ($wt.Status -eq 'MAIN') { $printedMain = $true }

            # leading marker so alive rows stand out at a glance
            if ($alive) { Write-Host "  ● " -NoNewline -ForegroundColor White }
            else        { Write-Host "    " -NoNewline }

            # status block (colored by status)
            Write-Host "[$label] " -NoNewline -ForegroundColor $statusColor
            Write-Host "$when " -NoNewline -ForegroundColor DarkGray

            # branch (white if alive, else status color)
            $branchColor = if ($alive) { 'White' } else { $statusColor }
            Write-Host "$($wt.Branch) " -NoNewline -ForegroundColor $branchColor

            # window tag for alive entries
            if ($alive) {
                $wColor = if ($windowColorMap[$win]) { $windowColorMap[$win] } else { 'White' }
                Write-Host "[$win] " -NoNewline -ForegroundColor $wColor
            }

            Write-Host "@ $($wt.Path)" -ForegroundColor DarkGray

            if ($wt.Status -eq 'DIRTY-MERGED' -and $wt.Reason) {
                Write-Color "                                           $($wt.Reason)" $statusColor
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
                Write-Color "  [SKIP   ] $($wt.Branch) -- no upstream" DarkGray
                continue
            }
            & git -C $ctx.Src rev-parse --verify "origin/$($wt.Branch)" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Color "  [SKIP   ] $($wt.Branch) -- remote branch gone" DarkGray
                continue
            }

            $isDirty = -not [string]::IsNullOrWhiteSpace((& git -C $wt.Path status --porcelain 2>&1 | Out-String).Trim())
            if ($isDirty) {
                Write-Color "  [SKIP   ] $($wt.Branch) -- dirty, skipping" Yellow
                continue
            }

            $result = & git -C $wt.Path pull --ff-only 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Color "  [FAIL   ] $($wt.Branch) -- cannot fast-forward" Red
                Write-Color "            $($result.Trim())" Red
            } else {
                $msg = if ($result -match 'Already up to date') { 'up to date' } else { 'updated' }
                Write-Color "  [OK     ] $($wt.Branch) -- $msg" Green
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

        # optional branch filter: `gwt prune <branch>` narrows to one worktree.
        # only meaningful for single-repo mode; ignored when -Org is explicitly passed.
        # NOTE: $Org gets auto-populated by Resolve-RepoContext from the git remote,
        # so we must check $PSBoundParameters, not the variable itself.
        $orgExplicit  = $PSBoundParameters.ContainsKey('Org')
        $branchFilter = if (-not $orgExplicit -and $Target) { $Target } else { $null }

        foreach ($repoPath in $reposToProcess) {
            Write-Color "`nrepo: $repoPath" Cyan
            & git -C $repoPath fetch origin --prune 2>&1 | Out-Null

            $statuses   = Get-WorktreeStatuses $repoPath
            $registered = $statuses | ForEach-Object { $_.Path.Replace('\','/').ToLower() }

            if ($branchFilter) {
                $filtered = $statuses | Where-Object { $_.Branch -eq $branchFilter }
                if (-not $filtered) {
                    Write-Color "  no worktree for branch '$branchFilter' in this repo" Yellow
                    continue
                }
                $statuses = $filtered
            }

            foreach ($wt in $statuses) {
                $raw   = if ($wt.Status -eq 'PRUNE' -and $wt.Reason) { "PRUNE $($wt.Reason)" } else { $wt.Status }
                $label = $raw.PadRight(16)
                switch ($wt.Status) {
                    'MAIN'             { Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" DarkGray }
                    'ACTIVE'           { Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Green }
                    'ACTIVE-NO-REMOTE' { Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Cyan }
                    'DIRTY-MERGED'     {
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Yellow
                        Write-Color "                    $($wt.Reason) -- keeping, review before removing" Yellow
                    }
                    'PRUNE'            {
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Red
                        $ok = $y -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "  remove? (Y/n)")) -or $r -match '^[Yy]$')
                        if ($ok) {
                            & git -C $repoPath worktree remove --force $wt.Path 2>&1 | Out-Null
                            Write-Color "                    removed." DarkGray
                            _CleanupWorktreeMetadata $wt.Path
                        }
                    }
                }
            }

            & git -C $repoPath worktree prune 2>&1 | Out-Null

            # orphan sweep is a whole-repo pass; skip when caller is scoped to one branch.
            if ($branchFilter) { continue }

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
                    if ($ok) {
                        Remove-Item $p -Recurse -Force
                        _CleanupWorktreeMetadata $p
                    }
                } else {
                    Write-Color "  [ORPHAN-DIRTY-SKIP] $p" Yellow
                }
            }
        }
    }

    { $_ -in 'help','-h','--help' } {
        Write-Host ""
        Write-Host "  gwt " -NoNewline -ForegroundColor Cyan
        Write-Host "-- git worktree lifecycle manager"
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
        Write-Host "    gwt twig " -NoNewline -ForegroundColor Cyan
        Write-Host "<branch> [-Prompt <str>] [-y]"
        Write-Host "        create a new worktree branched off the current worktree's HEAD" -ForegroundColor DarkGray
        Write-Host "        (shortcut for 'gwt new <branch> -From <current-branch>')" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt discourse " -NoNewline -ForegroundColor Cyan
        Write-Host "<discourse-url> [-Prompt <str>] [-y]"
        Write-Host "        create a worktree to investigate a discourse topic" -ForegroundColor DarkGray
        Write-Host "        prompts for target repo (default github, accepts 'host:org/repo')" -ForegroundColor DarkGray
        Write-Host "        branch name: discourse-<topic-id>" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt pr " -NoNewline -ForegroundColor Cyan
        Write-Host "<url-or-number> [-Prompt <str>] [-y]"
        Write-Host "        create (or reopen) a worktree for a PR" -ForegroundColor DarkGray
        Write-Host "        accepts a full GitHub PR URL or a bare PR number" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt <url> " -NoNewline -ForegroundColor Cyan
        Write-Host "[-y]"
        Write-Host "        shorthand -- bare URL auto-routes to 'pr'" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt update-registry" -ForegroundColor Cyan
        Write-Host "        fetch fallback gwt-session-registry.ps1 from github into ~\.gwt\" -ForegroundColor DarkGray
        Write-Host "        (no-op if dotfiles repo is cloned -- update via git pull instead)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt sessions " -NoNewline -ForegroundColor Cyan
        Write-Host "[restore [<match>] | close [<match>] | clean [-All]]"
        Write-Host "        list registered Claude sessions; mark live vs. stale" -ForegroundColor DarkGray
        Write-Host "        restore         relaunch stale sessions into their original windows" -ForegroundColor DarkGray
        Write-Host "                        prompts: open all? (Y/n) -> if no, individually? (y/N)" -ForegroundColor DarkGray
        Write-Host "                        skips entries that are already alive (idempotent)" -ForegroundColor DarkGray
        Write-Host "        restore <match> filter to entries whose Branch or path contains <match>" -ForegroundColor DarkGray
        Write-Host "        close           kill the pwsh + claude process for each alive session" -ForegroundColor DarkGray
        Write-Host "                        (registry entries stay, will show STALE next listing)" -ForegroundColor DarkGray
        Write-Host "        close <match>   close only matching alive sessions" -ForegroundColor DarkGray
        Write-Host "        clean           drop only stale entries (default)" -ForegroundColor DarkGray
        Write-Host "        clean -All      drop everything (alive entries too -- running shells unaffected)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  GLOBAL FLAGS" -ForegroundColor DarkGray
        Write-Host "    -V              show runas chatter on launch (the 'Attempting to start...' noise)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt claude " -NoNewline -ForegroundColor Cyan
        Write-Host "[<branch>|.] [-Prompt <str>] [-Reselect] [-y]"
        Write-Host "        open existing worktree's branch directly in claude (no 'remove?' prompt)" -ForegroundColor DarkGray
        Write-Host "        no arg / '.' -- uses current worktree's branch" -ForegroundColor DarkGray
        Write-Host "        remembers window+prompt picks per-worktree; -Reselect to re-prompt" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt cd " -NoNewline -ForegroundColor Cyan
        Write-Host "<branch>"
        Write-Host "        cd into that branch's worktree (requires profile wrapper)" -ForegroundColor DarkGray
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
        Write-Host "(alias: list) [-All]"
        Write-Host "        list registered sessions, scoped to the current repo by default" -ForegroundColor DarkGray
        Write-Host "        -All  show sessions across every repo (auto when run outside a repo)" -ForegroundColor DarkGray
        Write-Host "          [MAIN            ] -- primary clone" -ForegroundColor DarkGray
        Write-Host "          [ACTIVE          ] -- upstream exists, not yet merged (clean or dirty)" -ForegroundColor Green
        Write-Host "          [ACTIVE-NO-REMOTE] -- has local changes, no upstream configured" -ForegroundColor Cyan
        Write-Host "          [PRUNE           ] -- safe to delete (merged, remote deleted, or path missing)" -ForegroundColor Red
        Write-Host "          [DIRTY-MERGED    ] -- merged/remote-gone but has local changes, kept for review" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    gwt prune " -NoNewline -ForegroundColor Cyan
        Write-Host "[<branch>] [-Org <org>] [-Repo <repo>] [-y]"
        Write-Host "        delete merged+clean worktrees (safe only -- skips dirty)" -ForegroundColor DarkGray
        Write-Host "        no args   -- current repo, all worktrees" -ForegroundColor DarkGray
        Write-Host "        <branch>  -- current repo, just that worktree" -ForegroundColor DarkGray
        Write-Host "        -Org      -- all repos in org; add -Repo to narrow" -ForegroundColor DarkGray
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
