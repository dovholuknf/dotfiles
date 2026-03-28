# admin shell
# usage:
#   PR URL:
#     script.ps1 -Url https://github.com/org/repo/pull/123
#     "https://github.com/org/repo/pull/123" | script.ps1
#
#   Branch:
#     script.ps1 -Org org -Repo repo -Branch branch-name
#
#   Auto-open in claude:
#     add -y to skip prompt
#
# notes:
#   - requires git, wt.exe, and claude CLI
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

    [string]$SourceRoot = 'D:\git',

    [string]$WorktreeRoot = 'D:\worktrees',

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
            & git @Args 2>&1
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

    function Sync-PrBranch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoPath,

            [Parameter(Mandatory = $true)]
            [string]$PrNumber,

            [Parameter(Mandatory = $true)]
            [string]$Branch
        )

        if (-not (Test-LocalBranchExists -RepoPath $RepoPath -Branch $Branch)) {
            Invoke-Git -RepoPath $RepoPath -Args @('fetch','origin',"pull/$PrNumber/head:$Branch")
        } else {
            Invoke-Git -RepoPath $RepoPath -Args @('fetch','origin',"pull/$PrNumber/head")
            Invoke-Git -RepoPath $RepoPath -Args @('branch','-f',$Branch,'FETCH_HEAD')
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
    
    function Open-ClaudeShell {
        param(
            [string]$Path,
            [string]$Repo,
            [string]$PrNumber,
            [string]$Branch
        )

        if ($PrNumber) {
            $prompt = "review PR $PrNumber in $Repo. summarize changes, risks, and test coverage gaps"
            runas /user:claude "wt.exe -d `"$Path`" cmd /k claude `"$prompt`""
        } elseif ($Branch) {
            $prompt = "review branch $Branch in $Repo. summarize changes, risks, and test coverage gaps"
            runas /user:claude "wt.exe -d `"$Path`" cmd /k claude `"$prompt`""
        } else {
            runas /user:claude "wt.exe -d `"$Path`" cmd /k claude"
        }
    }

    function Confirm-OpenClaudeShell {
        param(
            [string]$Path,
            [string]$Repo,
            [string]$PrNumber,
            [string]$Branch,
            [switch]$AutoOpen
        )

        if ($AutoOpen) {
            Open-ClaudeShell -Path $Path -Repo $Repo -PrNumber $PrNumber -Branch $Branch
        } else {
            $resp = Read-Host "open in claude? (Y/n)"
            if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
                Open-ClaudeShell -Path $Path -Repo $Repo -PrNumber $PrNumber -Branch $Branch
            } else {
                Write-Host "cd `"$Path`""
            }
        }
    }
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'ByBranch') {
        $src = Join-Path (Join-Path (Join-Path $SourceRoot 'github') $Org) $Repo
        $wtRoot = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $Org) $Repo
        $wtPath = Join-Path $wtRoot $Branch

        [System.IO.Directory]::CreateDirectory($wtRoot) | Out-Null

        Ensure-RepoClonedAndUpdated -Provider 'github' -Org $Org -Repo $Repo -RepoSourcePath $src

        $syncResult = Sync-RemoteBranch -RepoPath $src -Remote 'origin' -Branch $Branch

        if ($syncResult.AlreadyExists) {
            Write-Host "ready: $($syncResult.WorktreePath)"
            Confirm-OpenClaudeShell -Path $syncResult.WorktreePath -Repo $Repo -Branch $Branch -AutoOpen:$y
            return
        }

        Ensure-Worktree -RepoPath $src -WorktreePath $wtPath -Branch $Branch

        Write-Host "ready: $wtPath"

        Confirm-OpenClaudeShell -Path $wtPath -Repo $Repo -Branch $Branch -AutoOpen:$y

        return
    }

    foreach ($u in $Url) {

        if ($u -notmatch '^https?://github\.com/(?<org>[^/]+)/(?<repo>[^/]+?)/pull/(?<pr>\d+)') {
            continue
        }

        $org = $Matches.org
        $repo = $Matches.repo
        $pr = $Matches.pr

        $src = Join-Path (Join-Path (Join-Path $SourceRoot 'github') $org) $repo
        $wtRoot = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $org) $repo
        $wtPath = Join-Path $wtRoot "pr-$pr"

        [System.IO.Directory]::CreateDirectory($wtRoot) | Out-Null

        Ensure-RepoClonedAndUpdated -Provider 'github' -Org $org -Repo $repo -RepoSourcePath $src

        $branch = "pr-$pr"

        Sync-PrBranch -RepoPath $src -PrNumber $pr -Branch $branch
        Ensure-Worktree -RepoPath $src -WorktreePath $wtPath -Branch $branch

        Write-Host "ready: $wtPath"

        Confirm-OpenClaudeShell -Path $wtPath -Repo $repo -PrNumber $pr -AutoOpen:$y
    }
}