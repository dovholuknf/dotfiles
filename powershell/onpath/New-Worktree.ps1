# admin shell
# usage:
#   PR URL:
#     script.ps1 -Url https://github.com/org/repo/pull/123
#     "https://github.com/org/repo/pull/123" | script.ps1
#
#   Branch:
#     script.ps1 -Org org -Repo repo -Branch branch-name
#
#   Branch with iteration fork:
#     script.ps1 -Org org -Repo repo -Branch branch-name -ToBranch my-iteration
#
#   Auto-open in claude:
#     add -y to skip prompt
#
#   Remove a worktree:
#     script.ps1 -Url https://github.com/org/repo/pull/123 -Remove
#     script.ps1 -Org org -Repo repo -Branch branch-name -Remove
#     add -y to skip confirmation prompt
#
# notes:
#   - requires git, gh, wt.exe, and claude CLI
#   - clones to $SourceRoot if missing
#   - creates/updates worktree under $WorktreeRoot

[CmdletBinding(DefaultParameterSetName = 'ByUrl')]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'ByUrl')]
    [string[]]$Url,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByBranch')]
    [string]$Org,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByBranch')]
    [string]$Repo,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByBranch')]
    [string]$Branch,

    # When supplied, $Branch is the source; a new local branch named $ToBranch is created from it.
    # Re-running is safe: if $ToBranch already has a worktree it is simply reopened.
    [Parameter(ParameterSetName = 'ByBranch')]
    [string]$ToBranch,

    [string]$SourceRoot = 'D:\git',

    [string]$WorktreeRoot = 'D:\worktrees',

    [string]$Prompt,

    [switch]$Remove,

    [switch]$y
)

begin {
    $ErrorActionPreference = 'Stop'

    function Invoke-Git {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string[]]$Args
        )

        Push-Location $RepoPath
        try {
            & git @Args
            if ($LASTEXITCODE -ne 0) {
                throw "git $($Args -join ' ') failed in $RepoPath"
            }
        }
        finally {
            Pop-Location
        }
    }

    function Invoke-GitCapture {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string[]]$Args
        )

        Push-Location $RepoPath
        try {
            $Output = & git @Args 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git $($Args -join ' ') failed in $RepoPath"
            }
            return $Output
        }
        finally {
            Pop-Location
        }
    }

    function Ensure-RepoClonedAndUpdated {
        param(
            [string]$Provider,
            [string]$Org,
            [string]$Repo,
            [string]$RepoSourcePath
        )

        $RepoParent = Split-Path -Parent $RepoSourcePath
        [System.IO.Directory]::CreateDirectory($RepoParent) | Out-Null

        if (-not (Test-Path $RepoSourcePath)) {
            $CloneUrl = "git@github.com:$Org/$Repo.git"
            & git clone $CloneUrl $RepoSourcePath 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "clone failed: $CloneUrl"
            }
        }

        Invoke-Git -RepoPath $RepoSourcePath -Args @('fetch','origin','--prune')
        Invoke-Git -RepoPath $RepoSourcePath -Args @('checkout','main')
        Invoke-Git -RepoPath $RepoSourcePath -Args @('pull','--ff-only','origin','main')
    }

    function Test-LocalBranchExists {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$Branch
        )

        $exists = (Invoke-GitCapture -RepoPath $RepoPath -Args @('branch','--list',$Branch)) -join ''
        return -not [string]::IsNullOrWhiteSpace($exists)
    }

    function Test-RemoteBranchExists {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$Remote,

            [Parameter(Mandatory = $true)]
            [string]$Branch
        )

        $exists = (Invoke-GitCapture -RepoPath $RepoPath -Args @('ls-remote','--heads',$Remote,$Branch)) -join ''
        return -not [string]::IsNullOrWhiteSpace($exists)
    }

    function Ensure-Worktree {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$WorktreePath,

            [Parameter(Mandatory = $true)]
            [string]$Branch
        )

        if (-not (Test-Path $WorktreePath)) {
            Invoke-Git -RepoPath $RepoPath -Args @('worktree','add',$WorktreePath,$Branch)
        }
    }

    # Returns the real head branch name for a PR via gh.
    function Get-PrHeadBranch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Org,

            [Parameter(Mandatory = $true)]
            [string]$Repo,

            [Parameter(Mandatory = $true)]
            [string]$PrNumber
        )

        $result = (& gh pr view $PrNumber --repo "$Org/$Repo" --json headRefName -q .headRefName 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "gh pr view failed for PR ${PrNumber}: $result"
        }
        return $result
    }

    # Fetches the branch from origin and creates/updates a local tracking branch.
    # Caller must ensure the branch is not currently checked out in any worktree.
    function Sync-PrBranch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$Branch
        )

        Invoke-Git -RepoPath $RepoPath -Args @('fetch','origin',$Branch)

        $localExists = Test-LocalBranchExists -RepoPath $RepoPath -Branch $Branch
        if ($localExists) {
            Invoke-Git -RepoPath $RepoPath -Args @('branch','-f',$Branch,"origin/$Branch")
        } else {
            Invoke-Git -RepoPath $RepoPath -Args @('branch','--track',$Branch,"origin/$Branch")
        }
    }

    function Get-WorktreePathForBranch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$Branch
        )

        $output = Invoke-GitCapture -RepoPath $RepoPath -Args @('worktree','list','--porcelain')

        $currentPath = $null
        foreach ($line in $output) {
            if ($line -match '^worktree\s+(.+)$') {
                $currentPath = $Matches[1]
                continue
            }

            if ($line -eq "branch refs/heads/$Branch") {
                return $currentPath
            }
        }

        return $null
    }

    function Sync-RemoteBranch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$Remote,

            [Parameter(Mandatory = $true)]
            [string]$Branch
        )

        $branchWorktreePath = Get-WorktreePathForBranch -RepoPath $RepoPath -Branch $Branch
        if ($branchWorktreePath) {
            return @{
                Branch = $Branch
                WorktreePath = $branchWorktreePath
                AlreadyExists = $true
            }
        }

        $remoteExists = Test-RemoteBranchExists -RepoPath $RepoPath -Remote $Remote -Branch $Branch

        if ($remoteExists) {
            Invoke-Git -RepoPath $RepoPath -Args @('fetch',$Remote,$Branch)
            Invoke-Git -RepoPath $RepoPath -Args @('branch','-f',$Branch,"$Remote/$Branch")
            return @{
                Branch = $Branch
                WorktreePath = $null
                AlreadyExists = $false
            }
        }

        # fallback: create from main
        $localExists = Test-LocalBranchExists -RepoPath $RepoPath -Branch $Branch

        if (-not $localExists) {
            Invoke-Git -RepoPath $RepoPath -Args @('branch',$Branch,'origin/main')
        } else {
            Invoke-Git -RepoPath $RepoPath -Args @('branch','-f',$Branch,'origin/main')
        }

        return @{
            Branch = $Branch
            WorktreePath = $null
            AlreadyExists = $false
        }
    }

    function Invoke-WorktreeRemove {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$WorktreePath,

            [switch]$AutoConfirm
        )

        if (-not (Test-Path $WorktreePath)) {
            Write-Host "worktree not found at '$WorktreePath', pruning stale registrations"
            Invoke-Git -RepoPath $RepoPath -Args @('worktree','prune')
            return
        }

        if ($AutoConfirm) {
            $confirmed = $true
        } else {
            $resp = Read-Host "remove worktree at '$WorktreePath'? (Y/n)"
            $confirmed = [string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$'
        }

        if ($confirmed) {
            Invoke-Git -RepoPath $RepoPath -Args @('worktree','remove','--force',$WorktreePath)
            Write-Host "removed: $WorktreePath"
        }
    }

    function Open-ClaudeShell {
        param(
            [string]$Path,
            [string]$Repo,
            [string]$PrNumber,
            [string]$Branch,
            [string]$PromptOverride
        )

        $prompt = if ($PromptOverride) { $PromptOverride } else { "critique the changes from this branch ($Branch in $Repo). summarize changes commit by commit and pay attention to risks and crtique overall design" }
        $encodedCmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Set-Location '$Path'; claude `"$prompt`""))
        runas /user:claude "wt.exe -d `"$Path`" pwsh -NoExit -EncodedCommand $encodedCmd"
    }

    function Confirm-OpenClaudeShell {
        param(
            [string]$Path,
            [string]$Repo,
            [string]$PrNumber,
            [string]$Branch,
            [string]$PromptOverride,
            [switch]$AutoOpen
        )

        if ($AutoOpen) {
            Open-ClaudeShell -Path $Path -Repo $Repo -PrNumber $PrNumber -Branch $Branch -PromptOverride $PromptOverride
        } else {
            $resp = Read-Host "open in claude? (Y/n)"
            if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
                Open-ClaudeShell -Path $Path -Repo $Repo -PrNumber $PrNumber -Branch $Branch -PromptOverride $PromptOverride
            } else {
                Write-Host "cd `"$Path`""
            }
        }
    }
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'ByBranch') {
        $src    = Join-Path (Join-Path (Join-Path $SourceRoot   'github') $Org) $Repo
        $wtRoot = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $Org) $Repo

        if ($Remove) {
            $targetBranch = if ($ToBranch) { $ToBranch } else { $Branch }
            $wtPath = Join-Path $wtRoot $targetBranch
            Invoke-WorktreeRemove -RepoPath $src -WorktreePath $wtPath -AutoConfirm:$y
            return
        }

        [System.IO.Directory]::CreateDirectory($wtRoot) | Out-Null

        Ensure-RepoClonedAndUpdated -Provider 'github' -Org $Org -Repo $Repo -RepoSourcePath $src

        if ($ToBranch) {
            # Sync the source branch from remote (no worktree needed for it)
            $remoteExists = Test-RemoteBranchExists -RepoPath $src -Remote 'origin' -Branch $Branch
            if ($remoteExists) {
                Invoke-Git -RepoPath $src -Args @('fetch','origin',$Branch)
                # Only force-update if it isn't checked out somewhere already
                $sourceWt = Get-WorktreePathForBranch -RepoPath $src -Branch $Branch
                if (-not $sourceWt) {
                    Invoke-Git -RepoPath $src -Args @('branch','-f',$Branch,"origin/$Branch")
                }
            }

            $existingWt = Get-WorktreePathForBranch -RepoPath $src -Branch $ToBranch
            if ($existingWt) {
                $resp = Read-Host "worktree already exists at '$existingWt'. remove it? (y/N)"
                if ($resp -match '^[Yy]$') {
                    Invoke-WorktreeRemove -RepoPath $src -WorktreePath $existingWt -AutoConfirm
                } else {
                    Write-Host "ready: $existingWt"
                    Confirm-OpenClaudeShell -Path $existingWt -Repo $Repo -Branch $ToBranch -PromptOverride $Prompt -AutoOpen:$y
                    return
                }
            }

            # Create ToBranch from Branch if it doesn't exist yet
            $localExists = Test-LocalBranchExists -RepoPath $src -Branch $ToBranch
            if (-not $localExists) {
                Invoke-Git -RepoPath $src -Args @('branch',$ToBranch,$Branch)
            }

            $wtPath = Join-Path $wtRoot $ToBranch
            Ensure-Worktree -RepoPath $src -WorktreePath $wtPath -Branch $ToBranch
            Write-Host "ready: $wtPath"
            Confirm-OpenClaudeShell -Path $wtPath -Repo $Repo -Branch $ToBranch -PromptOverride $Prompt -AutoOpen:$y
            return
        }

        $wtPath     = Join-Path $wtRoot $Branch
        $syncResult = Sync-RemoteBranch -RepoPath $src -Remote 'origin' -Branch $Branch

        if ($syncResult.AlreadyExists) {
            $resp = Read-Host "worktree already exists at '$($syncResult.WorktreePath)'. remove it? (y/N)"
            if ($resp -match '^[Yy]$') {
                Invoke-WorktreeRemove -RepoPath $src -WorktreePath $syncResult.WorktreePath -AutoConfirm
            } else {
                Write-Host "ready: $($syncResult.WorktreePath)"
                Confirm-OpenClaudeShell -Path $syncResult.WorktreePath -Repo $Repo -Branch $Branch -PromptOverride $Prompt -AutoOpen:$y
                return
            }
        }

        Ensure-Worktree -RepoPath $src -WorktreePath $wtPath -Branch $Branch
        Write-Host "ready: $wtPath"
        Confirm-OpenClaudeShell -Path $wtPath -Repo $Repo -Branch $Branch -PromptOverride $Prompt -AutoOpen:$y
        return
    }

    foreach ($u in $Url) {
        if ($u -notmatch '^https?://github\.com/(?<org>[^/]+)/(?<repo>[^/]+?)/pull/(?<pr>\d+)') {
            Write-Warning "skipping unrecognised URL: $u"
            continue
        }

        $org  = $Matches.org
        $repo = $Matches.repo
        $pr   = $Matches.pr

        $src    = Join-Path (Join-Path (Join-Path $SourceRoot   'github') $org) $repo
        $wtRoot = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $org) $repo
        $wtPath = Join-Path $wtRoot "pr-$pr"

        if ($Remove) {
            Invoke-WorktreeRemove -RepoPath $src -WorktreePath $wtPath -AutoConfirm:$y
            continue
        }

        [System.IO.Directory]::CreateDirectory($wtRoot) | Out-Null

        Ensure-RepoClonedAndUpdated -Provider 'github' -Org $org -Repo $repo -RepoSourcePath $src
        Invoke-Git -RepoPath $src -Args @('worktree','prune')

        $branch     = Get-PrHeadBranch -Org $org -Repo $repo -PrNumber $pr
        $existingWt = Get-WorktreePathForBranch -RepoPath $src -Branch $branch

        if ($existingWt) {
            # Normalize separators for comparison
            $existingNorm = $existingWt.Replace('\','/')
            $wtNorm       = $wtPath.Replace('\','/')

            if ($existingNorm -ne $wtNorm) {
                throw "branch '$branch' is already checked out at '$existingWt' — is there another PR against this branch?"
            }

            $resp = Read-Host "worktree already exists at '$existingWt'. remove it? (y/N)"
            if ($resp -match '^[Yy]$') {
                Invoke-WorktreeRemove -RepoPath $src -WorktreePath $existingWt -AutoConfirm
                # fall through to re-sync and re-create below
            } else {
                Write-Host "ready: $existingWt"
                Confirm-OpenClaudeShell -Path $existingWt -Repo $repo -PrNumber $pr -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
                continue
            }
        }

        Sync-PrBranch -RepoPath $src -Branch $branch
        Ensure-Worktree -RepoPath $src -WorktreePath $wtPath -Branch $branch

        Write-Host "ready: $wtPath"
        Confirm-OpenClaudeShell -Path $wtPath -Repo $repo -PrNumber $pr -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
    }
}
