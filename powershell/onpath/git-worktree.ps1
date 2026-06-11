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

    [string]$From,          # 'new': create branch from this source
    [string]$Org,
    [string]$Repo,
    [string]$RemoteHost,    # explicit host (e.g. 'github.com', 'bitbucket.org') -- for callers that don't have a git remote to detect from
    [string]$Prompt,
    [string]$SourceRoot    = $( $r = if ($env:GIT_ROOT)      { $env:GIT_ROOT }      else { 'D:\git' };      ($r -replace '\\+','\').TrimEnd('\') ),
    [string]$WorktreeRoot  = $( $r = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT } else { 'D:\worktrees' }; ($r -replace '\\+','\').TrimEnd('\') ),
    [switch]$y,
    [switch]$Force,         # 'prune': also include DIRTY worktrees (otherwise they're protected)
    [switch]$Reselect,      # force re-prompt instead of reusing saved picks
    [switch]$NoAgentSetup,  # skip the post-create dotagents CLAUDE.md symlink step
    # SCOPE: when cwd is inside a repo (main clone or a worktree), session
    # subcommands default to "this repo only." Pass -All to see / act on every
    # repo's sessions. Outside any repo, scope is implicitly global.
    [switch]$All,
    # 'sessions clean -Aborted' = also drop ABORTED entries (still keeps ACTIVE).
    # -Paused kept as a legacy alias since ABORTED was previously labeled PAUSED.
    [Alias('Paused')]
    [switch]$Aborted,
    # 'sessions clean -IncludeActive' = also drop ACTIVE entries (registry only;
    # running shells unaffected). Replaces the old meaning of -All on clean.
    [switch]$IncludeActive,
    # 'sessions clean -IncludeDuplicates' = drop entries that lost the dedup
    # within their WorktreePath group (alive wins; among non-alive, newest by
    # LastSpawnedAt wins). Targets ledger cruft regardless of lifecycle tag.
    [switch]$IncludeDuplicates,
    [switch]$NoFetch,       # 'list' / 'update' / 'prune': skip the initial 'git fetch' (faster, may be stale)
    [string]$Window,        # 'sessions restore' override / 'sessions save|unsave|clean' exact-window filter
    [string]$Name,          # 'sessions save|unsave|clean|restore' exact-branch filter
    [switch]$Usage,         # 'sessions list': show the verbose command-tips block
    [string]$SortBy,        # 'sessions usage': cost|tokens|recent (default: cost)
    [switch]$DryRun,        # 'sessions clean': preview targets without removing
    [switch]$IncludeEnded,  # 'sessions restore': also restore ENDED entries (default: skip them)
    [int]$Tail = 20,        # 'watch': how many lines of state.log to show before waiting
    [switch]$WithSize,      # 'summary': also walk each worktree for byte totals (slow)
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Spawning, theming, hook dispatch, session-tracking, and listing/recovery
# helpers all live in claude-shell.ps1 -- shared between gwt and claudeshell.
. (Join-Path $PSScriptRoot '..\claude-shell.ps1')

# Path roots: env-var driven with historical defaults. Mirrors the values
# claude-shell.ps1 computes; kept script-scoped here so helper functions can
# reach them without threading $SourceRoot / $WorktreeRoot through every call.
$script:WtRoot     = $WorktreeRoot.TrimEnd('\')
$script:GitRoot    = $SourceRoot.TrimEnd('\')
$script:SessionDir = "$script:WtRoot\sessions"

function _DetectCurrentRepoFromCwd {
    # Pure path arithmetic: figure out which repo (host/org/repo) the cwd
    # belongs to. Recognizes two layouts:
    #   $script:WtRoot\<host>\<org>\<repo>\<branch>\...   (worktree)
    #   $script:GitRoot\<host>\<org>\<repo>\...           (main clone)
    # Returns @{Host;Org;Repo;MainPath;WtBase} or $null when cwd is anywhere
    # else (D:\tmp, the worktree root itself, etc).
    $cwd = (Get-Location).Path.TrimEnd('\').Replace('/','\').ToLower()
    # Both layouts need at least 3 segments under the base (<host>/<org>/<repo>)
    # to pin down a repo. WtRoot's worktree dirs are nested deeper but you can
    # still resolve the repo from just 3 segments -- sitting at the repo's
    # worktrees-root (no branch picked yet) should still count as "this repo."
    foreach ($pair in @(
        @{ Base = $script:WtRoot.ToLower();  MinSegments = 3 },
        @{ Base = $script:GitRoot.ToLower(); MinSegments = 3 }
    )) {
        $b = $pair.Base.TrimEnd('\')
        if ($cwd -eq $b) { continue }
        if (-not $cwd.StartsWith("$b\")) { continue }
        $rel = $cwd.Substring($b.Length + 1)
        $parts = $rel -split '\\'
        if ($parts.Count -lt $pair.MinSegments) { continue }
        $h = $parts[0]; $o = $parts[1]; $r = $parts[2]
        return @{
            Host     = $h
            Org      = $o
            Repo     = $r
            MainPath = (Join-Path (Join-Path (Join-Path $script:GitRoot $h) $o) $r)
            WtBase   = (Join-Path (Join-Path (Join-Path $script:WtRoot $h) $o) $r)
        }
    }
    return $null
}

function _ApplyRepoScope {
    # Filter a session-entries pool down to "this repo" unless -All is set.
    # Returns @{Entries; Scoped; ScopeName; Hidden}. When Scoped=$true, the
    # caller should print a short notice so the human knows what was excluded.
    param([array]$Entries, [switch]$All)
    if ($All) {
        return @{ Entries = $Entries; Scoped = $false; ScopeName = ''; Hidden = 0 }
    }
    $scope = _DetectCurrentRepoFromCwd
    if (-not $scope) {
        return @{ Entries = $Entries; Scoped = $false; ScopeName = ''; Hidden = 0 }
    }
    $mainNorm = $scope.MainPath.ToLower()
    $wtBase   = ($scope.WtBase + '\').ToLower()
    $kept = @($Entries | Where-Object {
        if (-not $_.WorktreePath) { return $false }
        $p = $_.WorktreePath.Replace('/','\').TrimEnd('\').ToLower()
        ($p -eq $mainNorm) -or $p.StartsWith($wtBase)
    })
    return @{
        Entries   = $kept
        Scoped    = $true
        ScopeName = "$($scope.Host)/$($scope.Org)/$($scope.Repo)"
        Hidden    = $Entries.Count - $kept.Count
    }
}

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

    # Path-based inference: if cwd sits inside the canonical layout
    # (<SourceRoot> or <WorktreeRoot>)\<host>\<org>\<repo>[\...] we can pull
    # host/org/repo out without needing a git remote. Lets `gwt list` work
    # from the repo's worktree-root dir (which has no .git of its own).
    if (-not $script:Org -or -not $script:Repo -or -not $script:RemoteHost) {
        # Resolve symlinks before parsing -- otherwise a path like
        # D:\git\github\openziti\nf\ziti (where nf\ziti is a symlink to ziti)
        # gets parsed as repo=nf instead of ziti. Walk each path segment and
        # follow any symlink we find; the final path is the canonical one.
        $cwdNorm = (Get-Location).Path.Replace('/','\').TrimEnd('\')
        try {
            $di = [System.IO.DirectoryInfo]::new($cwdNorm)
            $target = $di.ResolveLinkTarget($true)   # $true = recursive
            if ($target) { $cwdNorm = $target.FullName.TrimEnd('\') }
        } catch {}
        foreach ($root in @($WorktreeRoot, $SourceRoot)) {
            $rootNorm = $root.Replace('/','\').TrimEnd('\')
            if (-not $cwdNorm.StartsWith("$rootNorm\", [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rest  = $cwdNorm.Substring($rootNorm.Length + 1)
            $parts = $rest -split '\\'
            if ($parts.Count -lt 3) { continue }
            $hostShort = $parts[0]
            $orgGuess  = $parts[1]
            $repoGuess = $parts[2]
            $hostFull = switch ($hostShort) {
                'github'    { 'github.com'    }
                'bitbucket' { 'bitbucket.org' }
                'gitlab'    { 'gitlab.com'    }
                default     { $hostShort      }
            }
            if (-not $script:Org)        { $script:Org        = $orgGuess  }
            if (-not $script:Repo)       { $script:Repo       = $repoGuess }
            if (-not $script:RemoteHost) { $script:RemoteHost = $hostFull  }
            $script:OrgRepoFromCwd = $true
            break
        }
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
    }
    $hostShort = _HostShort $script:RemoteHost
    $src       = Join-Path (Join-Path (Join-Path $SourceRoot   $hostShort) $script:Org) $script:Repo
    $wtroot    = Join-Path (Join-Path (Join-Path $WorktreeRoot $hostShort) $script:Org) $script:Repo
    if (-not $script:_DetectedLogged) {
        $cwdNorm = (Get-Location).Path.TrimEnd('\').Replace('\','/').ToLower()
        $srcNorm = $src.TrimEnd('\').Replace('\','/').ToLower()
        $line = "detected: $($script:RemoteHost)/$($script:Org)/$($script:Repo)"
        if ($cwdNorm -ne $srcNorm) { $line += " @ $src" }
        Write-Color $line Cyan
        $script:_DetectedLogged = $true
    }

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
            Write-Color "warning: cwd doesn't fit the canonical gwt layout -- using canonical path $src" Yellow
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
        # Refuse to wipe residue if a claude session is live in that path -- that's
        # the case where the user would lose work without realizing it.
        $alive = Get-AliveSessionForPath $WtPath
        if ($alive) {
            Write-Color "REFUSING to clean residue at '$WtPath' -- a claude session is alive there" Red
            Write-Color "  branch=$($alive.Branch)  window=$($alive.WindowName)  pid=$($alive.Pid)" DarkGray
            Write-Color "  close that session first (or 'gwt sessions clean -Paused <name>'), then retry" DarkGray
            throw "aborting -- alive session would lose state"
        }
        Write-Color "path '$WtPath' exists but isn't a valid worktree -- cleaning up residue" Yellow
        try {
            _AssertUnderWorktreeRoot $WtPath
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
    $setupScript = "$script:GitRoot\github\dovholuknf\dotagents\scripts\setup-agents.ps1"
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

function _AssertUnderWorktreeRoot {
    # Defense-in-depth: any destructive op must verify the target sits under
    # $WorktreeRoot. Throws if it doesn't. Cheap, called from every Remove-Item
    # site so a bug elsewhere can't accidentally wipe a main clone or home dir.
    param([Parameter(Mandatory)][string]$Path)
    $rootNorm = $WorktreeRoot.Replace('/','\').TrimEnd('\').ToLower()
    $tgtNorm  = $Path.Replace('/','\').TrimEnd('\').ToLower()
    if (-not ($tgtNorm.StartsWith("$rootNorm\"))) {
        throw "REFUSING destructive op on '$Path' -- not under WorktreeRoot '$WorktreeRoot'"
    }
}

function _ChangeToMainFolder {
    # When the parent shell's cwd is inside (or equal to) $Path, cd it to the
    # main clone -- same as 'gwt cd main' -- so NTFS releases the directory
    # being removed. Always announces ("switching to main clone at ..."); never
    # prompts. Writes the gwt cwd hint so the gwt wrapper follows. No-op when
    # cwd is already elsewhere.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MainPath
    )
    $cwd = (Get-Location).Path.TrimEnd('\').ToLower()
    $tgt = $Path.TrimEnd('\').ToLower()
    if ($cwd -ne $tgt -and -not $cwd.StartsWith("$tgt\")) { return }
    if (-not (Test-Path $MainPath)) {
        Write-Color "  cwd is inside the dir being removed but main clone '$MainPath' is missing -- staying put (removal will likely fail)" Yellow
        return
    }
    Write-Color "  you are inside the dir being removed -- switching to main clone at $MainPath" DarkGray
    Set-Location $MainPath
    _SetGwtCwdHint $MainPath
}

function _ForceRemoveWorktreeDir {
    # Robust dir removal. Returns $true if gone after; $false if it persists.
    # Steps: best-effort Remove-Item, then a second pass that clears readonly
    # attributes on every child first (common cause of "still on disk"). Never
    # throws -- caller decides how to surface a lingering directory.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    _AssertUnderWorktreeRoot $Path
    try { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    if (-not (Test-Path $Path)) { return $true }
    try {
        Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
    return -not (Test-Path $Path)
}

function Remove-Worktree {
    param([string]$Src, [string]$WtPath, [switch]$AutoConfirm)

    # Hard guard #0: the path MUST live under $WorktreeRoot (default
    # D:\worktrees). Refuses any registration that points at a main clone, a
    # user-home dir, an external drive, or anywhere else weird. This is the
    # one rule no other code path can override.
    $rootNorm = $WorktreeRoot.Replace('/','\').TrimEnd('\').ToLower()
    $tgtNorm  = $WtPath.Replace('/','\').TrimEnd('\').ToLower()
    if (-not ($tgtNorm.StartsWith("$rootNorm\"))) {
        Write-Color "REFUSING to remove '$WtPath'" Red
        Write-Color "  path is not under '$WorktreeRoot' -- this guard rejects EVERYTHING outside that root" DarkGray
        Write-Color "  if you really need to remove this manually: git -C '$Src' worktree remove --force '$WtPath'" DarkGray
        return
    }

    if (-not (Test-Path $WtPath)) {
        Write-Color "worktree not found at '$WtPath', pruning stale registrations" DarkYellow
        Invoke-Git $Src @('worktree','prune')
        return
    }

    # Hard guard #1: refuse if a claude session is alive at this path. The
    # session has uncommitted state and our process would either fail mid-delete
    # (file locks) or wipe work the user didn't know was there.
    $alive = Get-AliveSessionForPath $WtPath
    if ($alive) {
        Write-Color "REFUSING to remove '$WtPath' -- claude session is alive there" Red
        Write-Color "  branch=$($alive.Branch)  window=$($alive.WindowName)  pid=$($alive.Pid)" DarkGray
        Write-Color "  close that session first (or 'gwt sessions clean -Paused <name>'), then retry" DarkGray
        return
    }

    # Hard guard #2: if the parent shell's cwd is inside (or equal to) the path
    # we're about to delete, cd to the main clone first -- otherwise the FS
    # locks the dir and Remove fails partway.
    _ChangeToMainFolder -Path $WtPath -MainPath $Src

    $ok = $AutoConfirm -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "remove worktree at '$WtPath'? (Y/n)")) -or $r -match '^[Yy]$')
    if ($ok) {
        Invoke-Git $Src @('worktree','remove','--force',$WtPath)
        $gone = _ForceRemoveWorktreeDir $WtPath
        if ($gone) {
            Write-Color "removed: $WtPath" Green
        } else {
            Write-Color "WARNING: '$WtPath' still on disk after remove attempt" Red
            Write-Color "  close any program with files open under that path, then 'gwt prune $WtPath -Force' again" DarkGray
        }
        # If 'current' was pointing at this worktree, repoint it to MAIN
        # ($Src is the main clone dir) instead of leaving a dangling symlink.
        _DropCurrentSymlinkIfPointsAt -WtRoot (Split-Path $WtPath -Parent) -WorktreePath $WtPath -MainPath $Src
    }
}

function Get-AliveSessionForPath {
    # Return the alive session-registry entry whose WorktreePath matches the given
    # path (case-insensitive, normalized). Returns $null if none. Used by destructive
    # ops to warn before nuking a worktree someone has claude open in.
    param([string]$WorktreePath)
    $sessionDir = $script:SessionDir
    if (-not $WorktreePath -or -not (Test-Path $sessionDir)) { return $null }
    $norm = ($WorktreePath -replace '/', '\').TrimEnd('\').ToLower()
    $procMap = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object {
        $procMap[[int]$_.ProcessId] = $_
    }
    foreach ($f in (Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $e = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not $e.WorktreePath) { continue }
            if ((($e.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()) -ne $norm) { continue }
            if (-not ($e.Pid -and $e.Pid -ne 0)) { continue }
            $cim = $procMap[[int]$e.Pid]
            if (-not $cim) { continue }
            if ($e.StartTime -and $cim.CreationDate) {
                $delta = [math]::Abs(($cim.CreationDate - [datetime]::Parse($e.StartTime)).TotalSeconds)
                if ($delta -gt 2) { continue }
            }
            return $e
        } catch {}
    }
    return $null
}

function _SetCurrentSymlink {
    # Maintain a stable "current" link at <WtRoot>\current -> $WorktreePath.
    # Uses a directory JUNCTION (reparse point) rather than a symlink: JetBrains
    # IDEs (GoLand, IntelliJ) resolve symlinks to the real path which causes
    # "project pollution" -- the IDE sees each new symlink target as a fresh
    # project. Junctions are reported by most tools (including JetBrains) as
    # the junction path itself, so the IDE keeps treating <WtRoot>\current as
    # one stable project. Junctions also don't require Developer Mode / admin.
    # Name kept as _SetCurrentSymlink for backward compatibility with callers.
    param([Parameter(Mandatory)][string]$WtRoot, [Parameter(Mandatory)][string]$WorktreePath)
    if (-not (Test-Path $WtRoot)) {
        [System.IO.Directory]::CreateDirectory($WtRoot) | Out-Null
    }
    $link = Join-Path $WtRoot 'current'
    if (Test-Path $link) {
        try { Remove-Item $link -Force -ErrorAction Stop } catch {
            Write-Color "  could not replace existing 'current' at $link : $($_.Exception.Message)" Yellow
            return
        }
    }
    try {
        New-Item -ItemType Junction -Path $link -Target $WorktreePath -ErrorAction Stop | Out-Null
        Write-Color "  $link -> $WorktreePath" DarkGray
    } catch {
        Write-Color "  junction failed: $($_.Exception.Message)" Yellow
    }
}

function _DropCurrentSymlinkIfPointsAt {
    # If <WtRoot>\current points at the given worktree (the one we just removed),
    # repoint it at the main clone instead so the IDE-pinned path keeps working.
    # Falls back to deletion if MainPath isn't provided or doesn't exist.
    param(
        [Parameter(Mandatory)][string]$WtRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [string]$MainPath
    )
    $link = Join-Path $WtRoot 'current'
    if (-not (Test-Path $link)) { return }
    try {
        $item = Get-Item $link -Force
        # Accept both legacy SymbolicLink and current Junction. Anything else
        # (real directory, file) is not ours to touch.
        if ($item.LinkType -notin 'SymbolicLink','Junction') { return }
        $target = ($item.Target | Select-Object -First 1)
        if (-not $target) { return }
        $norm = (Resolve-Path $target -ErrorAction SilentlyContinue).Path
        if (-not $norm) { $norm = $target }
        if ($norm.TrimEnd('\').ToLower() -ne $WorktreePath.TrimEnd('\').ToLower()) { return }

        # It WAS pointing at the removed worktree. Repoint to main if possible.
        Remove-Item $link -Force -ErrorAction SilentlyContinue
        if ($MainPath -and (Test-Path $MainPath)) {
            try {
                New-Item -ItemType Junction -Path $link -Target $MainPath -ErrorAction Stop | Out-Null
                Write-Color "  'current' repointed to MAIN ($MainPath)" DarkGray
            } catch {
                Write-Color "  dropped 'current' (couldn't repoint to MAIN: $($_.Exception.Message))" DarkGray
            }
        } else {
            Write-Color "  dropped 'current' link (was pointing at the removed worktree)" DarkGray
        }
    } catch {}
}

function _SetGwtCwdHint {
    # Drop a hint file the gwt profile wrapper reads after the script exits, so it
    # can Set-Location the parent shell into the newly-created worktree. Keyed on
    # $PID so concurrent gwt calls don't trample each other.
    param([string]$Path)
    if (-not $Path) { return }
    try {
        $hintFile = Join-Path $env:TEMP "gwt-cwd-hint-$PID.txt"
        Set-Content -Path $hintFile -Value $Path -Encoding UTF8 -NoNewline
    } catch {}
}

function _ClaudeProjectDirFor {
    # Encodes a cwd into the form claude code uses for $env:USERPROFILE\.claude\projects\<name>.
    # Forward direction only (unambiguous): replace ':' and '\' with '-'.
    param([string]$Path)
    $p = $Path.TrimEnd('\').Replace(':', '-').Replace('\', '-')
    Join-Path $env:USERPROFILE ".claude\projects\$p"
}

function _CleanupWorktreeMetadata {
    # Drops the session-registry entries, picks state file, AND the claude-code
    # transcript dir for a removed worktree. Used by both 'rm' and 'prune' so the
    # cleanup is consistent.
    param([string]$WtPath)
    $sessionDir = $script:SessionDir
    $normWt = ($WtPath -replace '/', '\').TrimEnd('\').ToLower()

    $projDir = _ClaudeProjectDirFor $WtPath
    if (Test-Path -LiteralPath $projDir) {
        try {
            Remove-Item -LiteralPath $projDir -Recurse -Force -ErrorAction Stop
            Write-Color "    dropped claude project dir" DarkGray
        } catch {
            Write-Color "    failed to drop claude project dir: $_" DarkYellow
        }
    }

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
# Status: MAIN | ACTIVE | ACTIVE-REMOTE-GONE | PRUNE | DIRTY

function Test-WorktreeIsSaved {
    # Returns $true if any session-registry entry for this worktree path has Saved=$true.
    # Used by 'gwt prune' to refuse deletion of worktrees the user marked as Saved.
    param([string]$WorktreePath)
    $sessionDir = $script:SessionDir
    if (-not (Test-Path $sessionDir)) { return $false }
    $norm = $WorktreePath.Replace('/', '\').TrimEnd('\').ToLower()
    foreach ($f in (Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $e = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not $e.WorktreePath) { continue }
            $epath = ($e.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()
            if ($epath -eq $norm -and $e.Saved) { return $true }
        } catch {}
    }
    return $false
}

function Get-WorktreeStatuses {
    param([string]$Src)
    # Parse `git worktree list --porcelain` into (path, branch) pairs.
    $lines = & git -C $Src worktree list --porcelain 2>&1
    $pairs = @()
    $cur   = $null
    foreach ($line in $lines) {
        if ($line -match '^worktree\s+(.+)$')      { $cur = $Matches[1]; continue }
        if ($line -match '^branch refs/heads/(.+)$') {
            $pairs += [PSCustomObject]@{ Path = $cur; Branch = $Matches[1] }
        }
    }

    $srcNorm = $Src.Replace('\','/').ToLower()

    # Batch fetch last-commit-date for every branch in ONE git call (saves N forks).
    $commitMap = @{}
    $raw = & git -C $Src for-each-ref --format='%(refname:short)|%(committerdate:iso-strict)|%(committerdate:relative)' refs/heads/ 2>$null
    foreach ($r in $raw) {
        $p = $r.Split('|', 3)
        if ($p.Count -eq 3) { $commitMap[$p[0]] = @{ Iso = $p[1]; Rel = $p[2] } }
    }

    # Parallelize per-worktree status work (each one spawns 2-4 git processes).
    $results = $pairs | ForEach-Object -ThrottleLimit 8 -Parallel {
        $b   = $_.Branch
        $cur = $_.Path
        $Src     = $using:Src
        $srcNorm = $using:srcNorm

        $isMain = ($cur.Replace('\','/').ToLower() -eq $srcNorm)
        $status = $null
        $reason = $null

        if ($isMain) {
            $status = 'MAIN'
        } elseif (-not (Test-Path $cur)) {
            $status = 'PRUNE'; $reason = 'missing'
        } else {
            $porc = (& git -C $cur status --porcelain 2>&1 | Out-String).Trim()
            $isDirty = -not [string]::IsNullOrWhiteSpace($porc)
            # UNTRACKED-ONLY used to be its own state; collapsed into DIRTY since
            # the practical distinction (`git stash` not catching `??`) wasn't
            # worth a separate label. -Verbose on gwt list shows the actual files.
            $dirtyLabel  = 'DIRTY'
            $dirtyReason = 'has local changes'

            # Check config directly -- `rev-parse @{upstream}` can fail after a
            # --prune even though branch.X.merge is still set (the ref's gone,
            # not the config). config --get returns the value and exit 0 iff set.
            $cfgMerge = & git -C $Src config --get "branch.$b.merge" 2>$null
            $hasUpstreamConfig = -not [string]::IsNullOrWhiteSpace($cfgMerge)

            if (-not $hasUpstreamConfig) {
                & git -C $Src merge-base --is-ancestor $b origin/main 2>&1 | Out-Null
                $atOrBehindMain = $LASTEXITCODE -eq 0

                if ($isDirty) {
                    $status = $dirtyLabel
                    $reason = $dirtyReason
                } elseif ($atOrBehindMain) {
                    $status = 'PRUNE'; $reason = 'no commits, at main'
                } else {
                    $status = 'ACTIVE'; $reason = 'no upstream configured -- has local commits'
                }
            } else {
                & git -C $Src rev-parse --verify "origin/$b" 2>&1 | Out-Null
                $remoteExists = $LASTEXITCODE -eq 0

                if (-not $remoteExists) {
                    # branch.X.merge config exists but origin/X is gone --
                    # i.e. the branch WAS pushed at some point, and the remote
                    # ref has since been deleted (typical after a PR merge).
                    if ($isDirty) {
                        $status = $dirtyLabel
                        $reason = "WAS pushed, remote ref deleted -- $dirtyReason"
                    } else {
                        # Clean tree. If the branch has commits NOT in main,
                        # those would be lost on PRUNE -- split out as
                        # ACTIVE-REMOTE-GONE so the user notices.
                        & git -C $Src merge-base --is-ancestor $b origin/main 2>&1 | Out-Null
                        $atOrBehindMain = $LASTEXITCODE -eq 0
                        if ($atOrBehindMain) {
                            $status = 'PRUNE';              $reason = 'WAS pushed, remote ref deleted'
                        } else {
                            $status = 'ACTIVE-REMOTE-GONE'; $reason = 'WAS pushed, remote ref deleted -- has commits not on main (do not lose)'
                        }
                    }
                } else {
                    & git -C $Src merge-base --is-ancestor $b origin/main 2>&1 | Out-Null
                    $isMerged = $LASTEXITCODE -eq 0

                    if ($isDirty) {
                        $status = $dirtyLabel
                        $reason = if ($isMerged) { "merged, $dirtyReason" } else { $dirtyReason }
                    } elseif ($isMerged) {
                        $status = 'PRUNE'; $reason = 'merged'
                    } else {
                        $status = 'ACTIVE'; $reason = 'has upstream, not merged'
                    }
                }
            }
        }

        $commitInfo = ($using:commitMap)[$b]
        $lcDate = [datetime]::MinValue
        $lcRel  = $null
        if ($commitInfo) {
            $lcRel = $commitInfo.Rel
            [datetime]::TryParse($commitInfo.Iso, [ref]$lcDate) | Out-Null
        }

        # For DIRTY, the commit date is misleading -- it predates the actual
        # edits. Replace with the most recent mtime of dirty files.
        if ($status -eq 'DIRTY' -and $porc) {
            $latest = [datetime]::MinValue
            foreach ($l in ($porc -split "`r?`n")) {
                if (-not $l) { continue }
                # porcelain lines: 'XY path' (X=index, Y=worktree). Path starts at col 3.
                if ($l.Length -lt 4) { continue }
                $rel = $l.Substring(3).Trim('"')
                # Rename: 'R  oldpath -> newpath' -- take newpath.
                if ($rel -match '^(.+?)\s+->\s+(.+)$') { $rel = $Matches[2] }
                $full = Join-Path $cur $rel
                if (Test-Path -LiteralPath $full) {
                    $mt = (Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue).LastWriteTime
                    if ($mt -and $mt -gt $latest) { $latest = $mt }
                }
            }
            if ($latest -ne [datetime]::MinValue) {
                $lcDate = $latest
                $diff   = ([datetime]::Now - $latest)
                $lcRel  =
                    if     ($diff.TotalSeconds -lt 60)  { "$([int]$diff.TotalSeconds) seconds ago" }
                    elseif ($diff.TotalMinutes -lt 60)  { "$([int]$diff.TotalMinutes) minutes ago" }
                    elseif ($diff.TotalHours   -lt 24)  { "$([int]$diff.TotalHours) hours ago" }
                    elseif ($diff.TotalDays    -lt 7)   { "$([int]$diff.TotalDays) days ago" }
                    elseif ($diff.TotalDays    -lt 30)  { "$([int]($diff.TotalDays / 7)) weeks ago" }
                    elseif ($diff.TotalDays    -lt 365) { "$([int]($diff.TotalDays / 30)) months ago" }
                    else                                { "$([int]($diff.TotalDays / 365)) years ago" }
            }
        }

        [PSCustomObject]@{
            Branch        = $b
            Path          = $cur
            Status        = $status
            Reason        = $reason
            LastCommit    = $lcDate
            LastCommitRel = $lcRel
        }
    }
    return @($results)
}

# ── URL shorthand ─────────────────────────────────────────────────────────────

if ($Help -or -not $Command) { $Command = 'help' }

if ($Command -match '^https?://') {
    # Two URL shapes get routed differently:
    #   1. <host>/<org>/<repo>/pull/<num>  -> 'pr' (existing behavior)
    #   2. <host>/<org>/<repo>             -> 'clone' (parse host/org/repo,
    #                                                 clone if missing, open)
    if ($Command -match '^https?://[^/]+/[^/]+/[^/]+/pull/\d+') {
        $Target  = $Command
        $Command = 'pr'
    } elseif ($Command -match '^https?://(?<host>[^/]+)/(?<org>[^/]+)/(?<repo>[^/]+)/issues/(?<num>\d+)') {
        $script:RemoteHost = $Matches.host
        $script:Org        = $Matches.org
        $script:Repo       = $Matches.repo
        $Target  = $Matches.num
        $Command = 'issue'
    } elseif ($Command -match '^https?://(?<host>[^/]+)/(?<org>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?\s*$') {
        $script:RemoteHost = $Matches.host
        $script:Org        = $Matches.org
        $script:Repo       = $Matches.repo
        $Target  = $Command
        $Command = 'clone'
    }
    # Anything else falls through with $Command still set to the URL -- the
    # default switch case will print "unknown command" with the URL as the name.
}

# ── commands ──────────────────────────────────────────────────────────────────

function Show-SubcommandHelp {
    param([string]$Cmd, [string]$Sub)
    $key = if ($Sub) { "$Cmd $Sub".Trim() } else { $Cmd }
    switch ($key) {
        'sessions list' {
            Write-Host ""
            Write-Color "gwt sessions list [-Usage]" Cyan
            Write-Color "  List every registered claude session, grouped by wt window." DarkGray
            Write-Color "  Tags: ACTIVE / PAUSED / STALE / SAVED (saved overrides the lifecycle tag)." DarkGray
            Write-Color "  -Usage  print the per-subcommand cheat sheet below the listing." DarkGray
        }
        'sessions restore' {
            Write-Host ""
            Write-Color "gwt sessions restore [<match>] [-Name <branch>] [-Window <name>]" Cyan
            Write-Color "  Relaunch PAUSED sessions into their original wt window." DarkGray
            Write-Color "  <match>    substring filter (Branch / WorktreePath / WindowName)" DarkGray
            Write-Color "  -Name      exact branch match (combines with the others)" DarkGray
            Write-Color "  -Window    on single-entry restore: override the destination window" DarkGray
            Write-Color "             on multi-entry restore: also filters by exact window name" DarkGray
        }
        'sessions clean' {
            Write-Host ""
            Write-Color "gwt sessions clean [<match>] [-Paused | -All] [-Name <branch>] [-Window <name>]" Cyan
            Write-Color "  Drop entries from the registry. SAVED entries are always protected." DarkGray
            Write-Color "  default    only STALE (PID dead and worktree dir is gone)" DarkGray
            Write-Color "  -Paused    also clean PAUSED (PID dead, worktree dir still on disk)" DarkGray
            Write-Color "  -All       also clean ACTIVE (running shells aren't killed -- entry only)" DarkGray
        }
        'sessions save' {
            Write-Host ""
            Write-Color "gwt sessions save <match> [-Name <branch>] [-Window <name>]" Cyan
            Write-Color "  Mark a session as Saved -- shown as [SAVED] and protected from all cleans" DarkGray
            Write-Color "  and prune-force. Multi-match prompts a picker." DarkGray
        }
        'sessions unsave' {
            Write-Host ""
            Write-Color "gwt sessions unsave <match> [-Name <branch>] [-Window <name>]" Cyan
            Write-Color "  Remove the Saved mark. Multi-match prompts a picker." DarkGray
        }
        'sessions move' {
            Write-Host ""
            Write-Color "gwt sessions move <match> -Window <new-window> [-Name <branch>]" Cyan
            Write-Color "  Move an ACTIVE session to a different wt window." DarkGray
            Write-Color "  Kills the existing pwsh+claude, re-spawns in the target window," DarkGray
            Write-Color "  reusing the same session id (in-place update, not duplicate)." DarkGray
        }
        'sessions close' {
            Write-Host ""
            Write-Color "gwt sessions close [<match>]" Cyan
            Write-Color "  Kill the pwsh + claude process for each ACTIVE session." DarkGray
            Write-Color "  Registry entries stay -- they'll show PAUSED on next listing." DarkGray
        }
        'sessions' {
            Write-Host ""
            Write-Color "gwt sessions <subcommand> [...]" Cyan
            Write-Color "  Subcommands: list / restore / close / clean / save / unsave" DarkGray
            Write-Color "  For details, run e.g.: gwt sessions list -Help" DarkGray
        }
        'rename' {
            Write-Host ""
            Write-Color "gwt rename <match> <new-label> [-Name <branch>] [-Window <name>]" Cyan
            Write-Color "  Set the display label on a session entry. Empty label clears it." DarkGray
            Write-Color "  Does NOT rename the underlying git branch." DarkGray
        }
        default {
            Write-Color "no targeted help for '$key' -- showing main help instead" DarkGray
            Write-Host ""
            $script:_FallbackToFullHelp = $true
        }
    }
}

if ($env:GWT_DEBUG_HELP) {
    Write-Host "[DEBUG] Command=[$Command] Target=[$Target] Match=[$Match] Help.IsPresent=[$($Help.IsPresent)]" -ForegroundColor Magenta
}
# Also treat a literal '-help' / '--help' that landed in $Target or $Match as a help flag.
# (Catches the case where users put it AFTER positionals and PS binds it positionally.)
$_wantSubHelp = $Help.IsPresent
if ($Target -in @('-help','--help','-h','-Help','-H')) { $_wantSubHelp = $true; $Target = $null }
if ($Match  -in @('-help','--help','-h','-Help','-H')) { $_wantSubHelp = $true; $Match  = $null }

if ($_wantSubHelp -and $Command -and $Command -notin @('help','-h','--help')) {
    $script:_FallbackToFullHelp = $false
    Show-SubcommandHelp -Cmd $Command -Sub $Target
    if (-not $script:_FallbackToFullHelp) { exit 0 }
    $Command = 'help'
}

try {
switch ($Command) {

    'new' {
        if (-not $Target)      { throw "'new' requires a branch name" }
        if ($Target -eq '.')   { throw "'new' needs an explicit branch name (the '.' shortcut is only for 'gwt claude .')" }
        if ($Target -match '^\s|\s$|[\\\/:\?\*\[\]~^]') { throw "branch name '$Target' contains an illegal character" }
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
                _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y
                _SetGwtCwdHint $existingWt
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
        _InvokeGwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath -RemoteHost $ctx.RemoteHost
        $r = Read-Host "activate this worktree (point '$($ctx.WtRoot)\current' here)? (y/N)"
        if ($r -match '^[Yy]$') { _SetCurrentSymlink -WtRoot $ctx.WtRoot -WorktreePath $wtPath }
        _ConfirmOpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y
        _SetGwtCwdHint $wtPath
    }

    'current' {
        # Manage <WtRoot>\current -- the IDE-pinned link (directory junction).
        #   gwt current           -- print what 'current' points at
        #   gwt current .         -- set to cwd's worktree (validated as a real worktree)
        #   gwt current <branch>  -- set to that branch's worktree
        $ctx  = Resolve-RepoContext
        $link = Join-Path $ctx.WtRoot 'current'

        if (-not $Target) {
            if (-not (Test-Path $link)) {
                Write-Color "no 'current' link in $($ctx.WtRoot)" DarkGray
                return
            }
            try {
                $li = Get-Item $link -Force
                if ($li.LinkType -notin 'SymbolicLink','Junction') {
                    Write-Color "$link exists but is NOT a link (LinkType=$($li.LinkType))" Yellow
                    return
                }
                $tgt = ($li.Target | Select-Object -First 1)
                Write-Color "$link -> $tgt  ($($li.LinkType))" Cyan
                if (-not (Test-Path $tgt)) {
                    Write-Color "  (target is missing!)" Red
                }
            } catch {
                Write-Color "could not read link: $($_.Exception.Message)" Red
            }
            return
        }

        # Resolve the desired target.
        if ($Target -eq '.') {
            $cwd = (Get-Location).Path.Replace('/','\').TrimEnd('\').ToLower()
            $wtPath = $null
            # Walk all worktrees (INCLUDING MAIN). Pointing 'current' at main
            # is legit -- same effect as the auto-fallback when a worktree gets
            # pruned. User explicitly asked for "current = here", we honor it.
            foreach ($wt in (Get-WorktreeStatuses $ctx.Src)) {
                $p = $wt.Path.Replace('/','\').TrimEnd('\').ToLower()
                if ($cwd -eq $p -or $cwd.StartsWith("$p\")) { $wtPath = $wt.Path; break }
            }
            if (-not $wtPath) { throw "cwd '$cwd' isn't inside the main clone or any worktree of $($ctx.Org)/$($ctx.Repo)" }
        } else {
            $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
            if (-not $wtPath) { throw "no worktree for branch '$Target' in $($ctx.Org)/$($ctx.Repo)" }
            if (-not (Test-Path $wtPath)) { throw "worktree path '$wtPath' is registered but missing -- run 'gwt prune'" }
        }
        _SetCurrentSymlink -WtRoot $ctx.WtRoot -WorktreePath $wtPath
    }

    'activate' {
        # Point <WtRoot>\current at a worktree -- IDE-friendly stable path.
        #   gwt activate            -- uses the current cwd's worktree
        #   gwt activate <branch>   -- looks up that branch's worktree
        $ctx = Resolve-RepoContext
        if ($Target) {
            $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
            if (-not $wtPath) { throw "no worktree for branch '$Target' in $($ctx.Org)/$($ctx.Repo)" }
        } else {
            # Default to whichever worktree contains cwd. Normalize separators on
            # both sides -- git emits forward slashes; Get-Location uses backslashes.
            $cwd = (Get-Location).Path.Replace('/','\').TrimEnd('\').ToLower()
            $wtPath = $null
            foreach ($wt in (Get-WorktreeStatuses $ctx.Src)) {
                if ($wt.Status -eq 'MAIN') { continue }
                $p = $wt.Path.Replace('/','\').TrimEnd('\').ToLower()
                if ($cwd -eq $p -or $cwd.StartsWith("$p\")) { $wtPath = $wt.Path; break }
            }
            if (-not $wtPath) { throw "no branch given and cwd '$cwd' isn't inside a worktree" }
        }
        _SetCurrentSymlink -WtRoot $ctx.WtRoot -WorktreePath $wtPath
    }

    'issue' {
        # Triggered by an issue URL: github.com/<org>/<repo>/issues/<num>.
        # Creates a worktree at 'issue-<num>' branched off main, opens claude
        # with a prompt that points at the issue.
        if (-not $Target -or $Target -notmatch '^\d+$') {
            throw "'issue' expects a numeric issue id (got '$Target') -- use a github issue URL"
        }
        $issueNum = $Target
        $branch   = "issue-$issueNum"
        $ctx      = Resolve-RepoContext
        [System.IO.Directory]::CreateDirectory($ctx.WtRoot) | Out-Null
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost

        # Best-effort fetch the issue title from gh, for nicer prompts.
        $issueTitle = $null
        try {
            $j = & gh issue view $issueNum --repo "$($ctx.Org)/$($ctx.Repo)" --json title 2>$null | ConvertFrom-Json
            if ($j -and $j.title) { $issueTitle = $j.title }
        } catch {}

        Write-Color "issue:  $($ctx.Org)/$($ctx.Repo)#$issueNum" Cyan
        if ($issueTitle) { Write-Color "title:  $issueTitle" DarkGray }
        Write-Color "branch: $branch" DarkGray

        # Forward to 'new' with explicit host/org/repo so Resolve-RepoContext
        # doesn't try to re-detect from cwd (which is unrelated here). Pass
        # named args via hashtable splat -- array splat is unreliable for
        # mixing positional + named values across script invocations.
        if (-not $Prompt -and $issueTitle) {
            $Prompt = "investigate $($ctx.Org)/$($ctx.Repo)#$issueNum -- ""$issueTitle"". start by reading the issue thread (gh issue view $issueNum --repo $($ctx.Org)/$($ctx.Repo) --comments) and propose next steps before changing anything."
        } elseif (-not $Prompt) {
            $Prompt = "investigate $($ctx.Org)/$($ctx.Repo)#$issueNum -- read the issue thread (gh issue view $issueNum --repo $($ctx.Org)/$($ctx.Repo) --comments) and propose next steps before changing anything."
        }
        $pass = @{
            Org        = $ctx.Org
            Repo       = $ctx.Repo
            RemoteHost = $ctx.RemoteHost
            Prompt     = $Prompt
        }
        if ($y) { $pass.y = $true }
        & $PSCommandPath new $branch @pass
    }

    'clone' {
        # Triggered by a bare repo URL (no /pull/<num>) or invoked directly.
        # Clones to the canonical D:\git\<host>\<org>\<repo> path if missing,
        # otherwise fetches + refreshes. Then opens claude in the main clone.
        $ctx = Resolve-RepoContext   # host/org/repo were set by URL parsing
        [System.IO.Directory]::CreateDirectory((Split-Path $ctx.Src -Parent)) | Out-Null
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost

        # Default branch = whatever HEAD points at after clone (main, master, etc).
        $branch = (& git -C $ctx.Src symbolic-ref --short HEAD 2>$null | Out-String).Trim()
        if (-not $branch) { $branch = 'main' }

        Write-Color "ready: $($ctx.Src) (branch $branch)" Green
        _ConfirmOpenOrCd -Path $ctx.Src -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
        _SetGwtCwdHint $ctx.Src
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
                # Branch already lives at a different path (e.g., 'gwt new <branch>'
                # created it, then 'gwt pr <num>' wants pr-<num> as the dir name).
                # Offer: focus existing wt tab, open a fresh claude tab there, or cancel.
                Write-Color "branch '$branch' is already checked out at '$existingWt'." Yellow
                $state = Load-GwtState $existingWt
                $win   = if ($state -and $state.Window) { $state.Window } else { $null }

                if (-not $state) {
                    # No saved state -- skip prompt, just open in existing path.
                    Write-Color "no saved gwt state -- opening claude in existing worktree" DarkGray
                    _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
                _SetGwtCwdHint $existingWt
                    return
                }

                if ($win) {
                    Write-Color "saved wt window: $win" DarkGray
                    $resp = (Read-Host "(f)ocus existing wt window / (o)pen new claude tab in existing worktree / (c)ancel? [f]").Trim().ToLower()
                    if (-not $resp) { $resp = 'f' }
                } else {
                    # State exists but no window -> can't focus; offer open/cancel only.
                    $resp = (Read-Host "(o)pen new claude tab in existing worktree / (c)ancel? [o]").Trim().ToLower()
                    if (-not $resp) { $resp = 'o' }
                    if ($resp -eq 'f') { $resp = 'o' }
                }

                switch ($resp) {
                    'f' {
                        # wt windows are owned by the claude user, so the focus command
                        # must run as claude too (same shape used by _OpenClaudeShell).
                        Write-Color "focusing wt window '$win' (as claude user)..." DarkGray
                        & runas /user:claude /savecred "wt.exe -w `"$win`" focus-tab" 2>&1 | Out-Null
                        return
                    }
                    'o' {
                        _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
                _SetGwtCwdHint $existingWt
                        return
                    }
                    default {
                        Write-Color "cancelled" Yellow
                        return
                    }
                }
            }
            $resp = Read-Host "worktree already exists at '$existingWt'. remove it? (y/N)"
            if ($resp -match '^[Yy]$') {
                Remove-Worktree -Src $ctx.Src -WtPath $existingWt -AutoConfirm
            } else {
                Write-Color "ready: $existingWt" Green
                _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
                _SetGwtCwdHint $existingWt
                return
            }
        }

        Sync-PrBranch $ctx.Src $branch
        Ensure-Worktree $ctx.Src $wtPath $branch
        Write-Color "ready: $wtPath" Green
        _InvokeGwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath -RemoteHost $ctx.RemoteHost
        _ConfirmOpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
        _SetGwtCwdHint $wtPath
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

        # Accept either 'org/repo' (default github) or 'host:org/repo'.
        # Empty input defaults to github/openziti/ziti.
        $defaultRepo = 'openziti/ziti'
        $resp = (Read-Host "target repo (default '$defaultRepo', also accepts 'bitbucket.org:org/repo')").Trim()
        if (-not $resp) {
            $resp = $defaultRepo
            Write-Color "no repo given -- defaulting to $defaultRepo" DarkGray
        }

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

        _InvokeGwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath -RemoteHost $ctx.RemoteHost
        _ConfirmOpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y
        _SetGwtCwdHint $wtPath
        return
    }

    'update-registry' {
        # Manual freshness/fetch for the fallback gwt-session-registry.ps1 at
        # ~\.gwt\. No-op (with a hint) if the dotfiles copy exists -- that's
        # primary, you update it via git pull.
        $primary  = "$script:DotfilesPwsh\gwt-session-registry.ps1"
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

    { $_ -in 'save','unsave' } {
        # Top-level convenience aliases for 'gwt sessions save|unsave'. Mark a
        # session entry as Saved (a "favorite") so every clean tier skips it:
        # default clean keeps it, -Aborted keeps it, -All keeps it. Saved
        # entries show as [SAVED] in the listing.
        #
        # Usage:
        #   gwt save                -- save the session for the current cwd
        #   gwt save <substring>    -- save sessions whose branch / path / window
        #                              match the substring (picker on multi-match)
        #   gwt save -Name <branch> -- exact branch match
        #   gwt unsave ...          -- same shapes, removes the Saved flag instead
        $matchArg = $Target
        # Treat empty arg AND literal "." (or "./" / ".\") as "current worktree".
        # Match style: pass the cwd path as the substring, so the inner sessions
        # filter finds the JSON entry whose WorktreePath equals cwd.
        if ((-not $matchArg -or $matchArg -in @('.', './', '.\')) -and -not $Name -and -not $Window) {
            $matchArg = (Get-Location).Path.TrimEnd('\')
        }
        $fwd = @{ Command = 'sessions'; Target = $Command }
        if ($matchArg) { $fwd.Match  = $matchArg }
        if ($Name)     { $fwd.Name   = $Name }
        if ($Window)   { $fwd.Window = $Window }
        if ($All)      { $fwd.All    = $true }
        & $PSCommandPath @fwd
        return
    }

    'sessions' {
        # Shared location so both clint and the spawned claude user shells can read/write.
        $sessionDir = $script:SessionDir
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
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object {
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

        # Default scope: this repo only (when cwd is inside one). Pass -All for
        # the global cross-repo view.
        $scopeResult = _ApplyRepoScope -Entries $entries -All:$All
        $entries = $scopeResult.Entries
        if ($scopeResult.Scoped) {
            Write-Color ("  scoped to {0}  ({1} entries from other repos hidden; pass -All to see all)" -f $scopeResult.ScopeName, $scopeResult.Hidden) DarkGray
        }

        # Resolve a candidate set against the (positional) $Match substring plus the
        # exact-match $Name / $Window filters. If multiple match, prompt with a
        # numbered picker (or 'a' for all). Returns an array of entries, or $null
        # on quit. $Verb is shown in messages ("save", "clean", etc).
        function script:_ResolveSessionTargets {
            param([array]$Pool, [string]$Verb)
            # Dedupe by WorktreePath BEFORE filtering -- otherwise the picker
            # shows triplicates when the ledger has accumulated duplicate
            # entries for the same path (alive wins; among non-alive, newest
            # by LastSpawnedAt wins). Mirrors the dedupe used by the default
            # sessions list view.
            $Pool = @($Pool |
                Group-Object WorktreePath |
                ForEach-Object {
                    $alive = $_.Group | Where-Object Alive | Select-Object -First 1
                    if ($alive) { $alive }
                    else        { $_.Group | Sort-Object @{Expression={ if ($_.LastSpawnedAt) { $_.LastSpawnedAt } else { $_.SpawnedAt } }} -Descending | Select-Object -First 1 }
                })
            $filtered = $Pool
            if ($Name)   { $filtered = @($filtered | Where-Object { $_.Branch     -ieq $Name   }) }
            if ($Window) { $filtered = @($filtered | Where-Object { $_.WindowName -ieq $Window }) }
            if ($Match) {
                # Exact-Branch match first; fall back to substring only if no exact hits.
                $exact = @($filtered | Where-Object { $_.Branch -ieq $Match })
                if ($exact.Count) {
                    $filtered = $exact
                } else {
                    $filtered = @($filtered | Where-Object {
                        $_.Branch       -like "*$Match*" -or
                        $_.WorktreePath -like "*$Match*" -or
                        $_.WindowName   -like "*$Match*"
                    })
                    if ($filtered.Count) {
                        Write-Color "  (no exact branch match for '$Match' -- using substring fallback)" DarkGray
                    }
                }
            }
            $filtered = @($filtered)
            if (-not $filtered.Count) {
                Write-Color "no entries match the given filter" Yellow
                return $null
            }
            if ($filtered.Count -eq 1) { return $filtered }
            # Multi-match: prompt to disambiguate. Up/Down + Enter for one,
            # 'a' for all, Esc/q to cancel.
            $picked = _TuiSelect -Items $filtered -AllowAll `
                -Prompt "multiple matches for $Verb -- pick one (or 'a' for all):" `
                -DisplayScript { param($e) ('{0,-30} [{1}] @ {2}' -f $e.Branch, $e.WindowName, $e.WorktreePath) }
            if (-not $picked) { return $null }
            return @($picked)
        }

        # subcommand under 'sessions': default = list. 'restore' = relaunch stale.
        # 'clean' = drop stale entries without relaunch.
        switch ($Target) {
            'restore' {
                # Idempotency: only consider STALE entries -- alive ones are already up.
                $allStale = @($entries | Where-Object { -not $_.Alive })
                if (-not $allStale.Count) { Write-Color "no paused sessions to restore (everything is ACTIVE)" DarkGray; return }

                # By default skip ENDED entries. The user closed those deliberately;
                # restoring them is annoying. Pass -IncludeEnded to opt back in.
                if (-not $IncludeEnded) {
                    $beforeEnded = $allStale.Count
                    $allStale    = @($allStale | Where-Object { $_.State -ne 'ended' })
                    $droppedEnded = $beforeEnded - $allStale.Count
                    if ($droppedEnded -gt 0) {
                        Write-Color "skipping $droppedEnded ENDED session(s) -- pass -IncludeEnded to restore them" DarkGray
                    }
                    if (-not $allStale.Count) { Write-Color "no paused sessions to restore (all not-alive were ENDED)" DarkGray; return }
                }

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

                # Optional filters: $Match (substring), $Name (exact branch), $Window (exact window).
                # Note: $Window on restore also serves as the destination override -- here we treat
                # it as a filter ONLY if $Name or $Match was passed too; bare -Window keeps acting
                # as the destination override on all paused entries.
                if ($Match -or $Name -or ($Window -and ($Match -or $Name))) {
                    $filtered = $stale
                    if ($Name)   { $filtered = @($filtered | Where-Object { $_.Branch     -ieq $Name }) }
                    if ($Window) { $filtered = @($filtered | Where-Object { $_.WindowName -ieq $Window }) }
                    if ($Match)  {
                        $filtered = @($filtered | Where-Object {
                            $_.Branch       -like "*$Match*" -or
                            $_.WorktreePath -like "*$Match*" -or
                            $_.WindowName   -like "*$Match*"
                        })
                    }
                    if (-not $filtered.Count) {
                        Write-Color "no paused entries match the given filter" Yellow
                        return
                    }
                    $stale = $filtered
                    Write-Color "filter -> $($stale.Count) match(es)" Cyan
                }

                $dupes = $allStale.Count - @($stale).Count
                if (-not $Match -and $dupes -gt 0) {
                    Write-Color "skipping $dupes duplicate(s) -- run 'gwt sessions clean' to clean them" DarkGray
                }

                # Single-entry restore: show the wt window picker (with the entry's
                # original window pre-selected). Picking IS the confirmation.
                # Skipped when -Window was passed (already explicit).
                $pickedWindow = $null
                $perEntry     = $false

                if (@($stale).Count -eq 1 -and -not $Window) {
                    Write-Color ("  $($stale[0].Branch) @ $($stale[0].WorktreePath)") DarkGray
                    $pickedWindow = _SelectWtWindow -Default $stale[0].WindowName
                    if ($pickedWindow -eq '__new__') { $pickedWindow = $null }
                } else {
                    Write-Host ""
                    foreach ($s in $stale) {
                        $dest  = if ($Window) { $Window } else { $s.WindowName }
                        $moved = if ($Window -and $Window -ne $s.WindowName) { "  (moved from '$($s.WindowName)')" } else { '' }
                        Write-Color "  $($s.Branch) -> $dest$moved" DarkGray
                    }
                    Write-Host ""
                    $destWord = if ($Window) { " into window '$Window'" } else { '' }
                    $resp = Read-Host "open all $(@($stale).Count) sessions$destWord? (Y=all / n=abort / p=prompt per entry)"
                    if ($resp -match '^[Pp]') {
                        $perEntry = $true
                    } elseif (-not ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$')) {
                        Write-Color "aborted" Yellow
                        return
                    }
                }

                foreach ($s in $stale) {
                    if (-not (Test-Path $s.WorktreePath)) {
                        Write-Color "  skip (worktree gone): $($s.Branch) @ $($s.WorktreePath)" Yellow
                        continue
                    }
                    # Window resolution order: -Window flag, then picker choice, then original
                    $effWindow = if ($Window)        { $Window }
                                 elseif ($pickedWindow) { $pickedWindow }
                                 else                 { $s.WindowName }
                    if ($perEntry) {
                        $r = Read-Host "open '$($s.Branch)' -> $effWindow? (y/N)"
                        if (-not ($r -match '^[Yy]$')) {
                            Write-Color "    skipped" DarkGray
                            continue
                        }
                    }
                    $moved = if ($Window -and $Window -ne $s.WindowName) { "  (moved from '$($s.WindowName)')" } else { '' }
                    Write-Color "  relaunch: $($s.Branch) -> window=$effWindow$moved" Green

                    # _OpenClaudeShell pre-writes a fresh entry with Pid=0 and stashes
                    # the new session id in $script:LastSpawnedSessionId. The spawned
                    # shell calls _RegisterGwtSession which patches Pid > 0, so polling
                    # that file replaces the arbitrary Start-Sleep we used to do here.
                    _OpenClaudeShell -Path $s.WorktreePath -Repo $s.Repo -Branch $s.Branch `
                                     -PromptText $s.PromptText -WindowName $effWindow `
                                     -ReuseSessionId $s.Id
                    $newId = $script:LastSpawnedSessionId
                    if ($newId) {
                        $newFile = Join-Path $script:SessionDir "$newId.json"
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

            'move' {
                # Move an ACTIVE session from one wt window to another.
                # Internally: close (kill pwsh+claude) -> wait for stale -> restore -Window <new>.
                # Requires -Window (target window) and a way to identify the session
                # (positional $Match, or $Name + optional $Window-as-source... no,
                # $Window is the destination here, so use $Match or $Name to identify).
                if (-not $Window) {
                    Write-Color "usage: gwt sessions move <match> -Window <new-window-name> [-Name <branch>]" Yellow
                    return
                }
                if (-not ($Match -or $Name)) {
                    Write-Color "usage: gwt sessions move <match> -Window <new-window-name> [-Name <branch>]" Yellow
                    Write-Color "  pass a substring or -Name to identify the session to move" DarkGray
                    return
                }

                # Find ACTIVE candidates that match the identifier.
                $candidates = @($entries | Where-Object {
                    $_.Alive -and (
                        ($Match -and (
                            $_.Branch       -like "*$Match*" -or
                            $_.WorktreePath -like "*$Match*"
                        )) -or
                        ($Name -and ($_.Branch -ieq $Name))
                    )
                })
                if (-not $candidates.Count) {
                    Write-Color "no ACTIVE sessions match the identifier" Yellow
                    return
                }
                if ($candidates.Count -gt 1) {
                    $picked = _TuiSelect -Items $candidates `
                        -Prompt "multiple ACTIVE sessions match -- pick one:" `
                        -DisplayScript { param($c) ('{0,-30} [{1}] @ {2}' -f $c.Branch, $c.WindowName, $c.WorktreePath) }
                    if (-not $picked) { return }
                    $candidates = @($picked)
                }

                $s = $candidates[0]
                if ($s.WindowName -ieq $Window) {
                    Write-Color "already in '$Window' -- nothing to do" DarkGray
                    return
                }
                Write-Color "moving '$($s.Branch)' from '$($s.WindowName)' to '$Window' ..." Cyan

                # 1. Kill the live process -- entry becomes stale.
                $killed = $false
                $null = & taskkill /T /F /PID $($s.Pid) 2>&1
                if ($LASTEXITCODE -eq 0) { $killed = $true }
                if (-not $killed) {
                    # Cross-user requires runas. Best-effort.
                    $null = & runas /user:claude /savecred "taskkill /T /F /PID $($s.Pid)" 2>&1
                    if ($LASTEXITCODE -eq 0) { $killed = $true }
                }
                if (-not $killed) {
                    Write-Color "failed to kill pid $($s.Pid) -- aborting move" Red
                    return
                }

                # 2. Wait for the registry entry to settle (PID dies, SessionEnd
                # hook zeroes Pid). Brief poll.
                Start-Sleep -Milliseconds 500

                # 3. Re-spawn in the new window via _OpenClaudeShell, reusing the
                # original session id so we update in place rather than dup.
                _OpenClaudeShell -Path $s.WorktreePath -Repo $s.Repo -Branch $s.Branch `
                                 -PromptText $s.PromptText -WindowName $Window `
                                 -ReuseSessionId $s.Id -Force
                Write-Color "  moved to '$Window'" Green
                return
            }

            { $_ -in 'save','unsave' } {
                $val = ($Target -eq 'save')
                if (-not ($Match -or $Name -or $Window)) {
                    Write-Color "usage: gwt sessions $Target <substring> [-Name <branch>] [-Window <name>]" Yellow
                    return
                }
                $targets = _ResolveSessionTargets -Pool $entries -Verb $Target
                if (-not $targets) { return }
                foreach ($m in $targets) {
                    # Ad-hoc entries (registered when claude was launched outside any
                    # git repo) are permanently locked Saved -- the underlying cwd
                    # is often something dangerous like D:\worktrees itself.
                    $isAdhoc = ($m.WindowName -eq 'ad-hoc') -or ($m.Branch -like '(adhoc:*)')
                    if ($isAdhoc -and -not $val) {
                        Write-Color "  refusing to unsave ad-hoc entry: $($m.Branch) @ $($m.WorktreePath)" Red
                        Write-Color "    (ad-hoc entries stay Saved permanently for safety)" DarkGray
                        continue
                    }
                    $e = Get-Content $m.File -Raw | ConvertFrom-Json
                    if ($e.PSObject.Properties['Saved']) {
                        $e.Saved = $val
                    } else {
                        $e | Add-Member -NotePropertyName Saved -NotePropertyValue $val -Force
                    }
                    ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $m.File -Encoding UTF8
                    $word = if ($val) { 'saved' } else { 'unsaved' }
                    $col  = if ($val) { 'Green' } else { 'Yellow' }
                    Write-Color "  $word : $($m.Branch) @ $($m.WorktreePath)" $col
                }
                return
            }

            'clean' {
                # Classify each entry: ACTIVE / ABORTED / STALE / ENDED
                #   ACTIVE  -- PID running
                #   ENDED   -- human closed the session cleanly (SessionEnd hook fired
                #              with State='ended'). Low priority for restore.
                #   ABORTED -- PID dead but SessionEnd never fired. Cause: Windows
                #              restart, claude crash, hard kill, OOM, etc. THESE are
                #              the priority for restore -- they died with work in flight.
                #   STALE   -- PID dead AND worktree dir is gone (cruft).
                # Default: drop STALE + ENDED. With -Aborted (aka -Paused), also drop
                # ABORTED. With -All, also drop ACTIVE (removes the registry entry;
                # running shell unaffected). STALE is restricted to $env:WORKTREE_ROOT
                # entries -- main-clone entries (under $env:GIT_ROOT) with a missing
                # path stay ABORTED so a temporary unmount or path move never
                # auto-nukes them.
                $wtRootRegex = "^$([regex]::Escape($script:WtRoot))\\"
                $classified = $entries | ForEach-Object {
                    $tag = if ($_.Alive) {
                        'ACTIVE'
                    } elseif ($_.State -eq 'ended') {
                        'ENDED'
                    } elseif ($_.WorktreePath -and (Test-Path $_.WorktreePath)) {
                        'ABORTED'
                    } elseif ($_.WorktreePath -and $_.WorktreePath -match $wtRootRegex) {
                        'STALE'
                    } else {
                        'ABORTED'
                    }
                    $_ | Add-Member -NotePropertyName Tag -NotePropertyValue $tag -PassThru
                }
                # Escalating drop tiers:
                #   (default)                  -> STALE + ENDED
                #   -Aborted (alias -Paused)   -> + ABORTED
                #   -IncludeActive             -> + ACTIVE (registry-only; running shells unaffected)
                # -All is now a SCOPE flag (this-repo vs all-repos), not a tier
                # multiplier. To replicate the OLD "clean everything" behavior:
                #   gwt sessions clean -All -Aborted -IncludeActive
                $dropTags = @('STALE','ENDED')
                if ($Aborted)       { $dropTags += 'ABORTED' }
                if ($IncludeActive) { $dropTags += 'ACTIVE' }
                $toDrop = @($classified | Where-Object { $_.Tag -in $dropTags })

                # -IncludeDuplicates: also collect dedup losers (entries that
                # share a WorktreePath with a winner). Winner = alive entry if
                # any, else newest non-alive by LastSpawnedAt. Adds the losers
                # to $toDrop regardless of their lifecycle tag. Each loser is
                # tagged DuplicateLoser=true so the Saved guard knows to drop
                # them anyway (the winner keeps the Saved protection).
                if ($IncludeDuplicates) {
                    $dupeLosers = @()
                    foreach ($g in ($classified | Group-Object WorktreePath)) {
                        if ($g.Count -lt 2) { continue }
                        $alive = $g.Group | Where-Object Alive | Select-Object -First 1
                        if ($alive) {
                            $winner = $alive
                        } else {
                            $winner = $g.Group | Sort-Object @{Expression={ if ($_.LastSpawnedAt) { $_.LastSpawnedAt } else { $_.SpawnedAt } }} -Descending | Select-Object -First 1
                        }
                        foreach ($loser in @($g.Group | Where-Object { $_.File -ne $winner.File })) {
                            $loser | Add-Member -NotePropertyName DuplicateLoser -NotePropertyValue $true -Force
                            $dupeLosers += $loser
                        }
                    }
                    $existingFiles = @($toDrop | ForEach-Object { $_.File })
                    $newDupes = @($dupeLosers | Where-Object { $_.File -notin $existingFiles })
                    $toDrop += $newDupes
                }

                # Canonical-path guard: only clean entries whose WorktreePath sits at
                # the expected 4+-deep layout:
                #   $env:WORKTREE_ROOT\<provider>\<org>\<repo>\<branch>   (worktree session)
                #   $env:GIT_ROOT\<provider>\<org>\<repo>                 (main-clone session)
                # Anything shallower (the WORKTREE_ROOT itself, a drive root, arbitrary
                # paths) gets protected -- even -All won't touch it. This is the safety
                # net for the case where a registration somehow points at a dangerous root.
                $wtEsc  = [regex]::Escape($script:WtRoot)
                $gitEsc = [regex]::Escape($script:GitRoot)
                $canonicalRegex = "^($wtEsc\\[^\\]+\\[^\\]+\\[^\\]+\\[^\\]+|$gitEsc\\[^\\]+\\[^\\]+\\[^\\]+)(\\|$)"
                $offLayoutSkipped = @($toDrop | Where-Object {
                    -not $_.WorktreePath -or ($_.WorktreePath -notmatch $canonicalRegex)
                })
                $toDrop = @($toDrop | Where-Object {
                    $_.WorktreePath -and ($_.WorktreePath -match $canonicalRegex)
                })

                # Protect Saved entries from ALL clean operations -- with one
                # exception: when -IncludeDuplicates is set, Saved duplicate
                # LOSERS get dropped anyway. The winner of each path keeps the
                # Saved protection, so this is safe: only redundant copies go.
                $savedSkipped = @($toDrop | Where-Object { $_.Saved -and -not $_.DuplicateLoser })
                $toDrop       = @($toDrop | Where-Object { (-not $_.Saved) -or $_.DuplicateLoser })

                # Optional filters: substring $Match plus exact $Name/$Window. With
                # any filter, multi-match prompts to disambiguate (pick / 'a' / 'q').
                if ($Match -or $Name -or $Window) {
                    $resolved = _ResolveSessionTargets -Pool $toDrop -Verb 'clean'
                    if (-not $resolved) { return }
                    $toDrop = $resolved
                }
                # Group protect-skip output by path -- the same path appears multiple
                # times when the ledger has duplicates. Show one line per unique path
                # with a count suffix when > 1.
                foreach ($g in ($offLayoutSkipped | Group-Object WorktreePath)) {
                    $suffix = if ($g.Count -gt 1) { "  (x$($g.Count) entries)" } else { '' }
                    Write-Color "  protected (off-layout): $($g.Group[0].Branch) @ $($g.Name)$suffix" Red
                }
                $savedDupeCount = 0
                foreach ($g in ($savedSkipped | Group-Object WorktreePath)) {
                    $suffix = if ($g.Count -gt 1) {
                        $savedDupeCount += ($g.Count - 1)
                        "  (x$($g.Count) entries; $($g.Count - 1) duplicate(s))"
                    } else { '' }
                    Write-Color "  protected (Saved): $($g.Group[0].Branch) @ $($g.Name)$suffix" DarkGray
                }
                if ($savedDupeCount -gt 0) {
                    Write-Color "  -> $savedDupeCount Saved duplicate(s) above can be dropped with 'gwt sessions clean -IncludeDuplicates'" Yellow
                    Write-Color "     (the winner of each path keeps its Saved protection; only redundant copies go)" DarkGray
                }
                $mode = "$($dropTags -join ' + ')"
                $verb = if ($DryRun) { 'would clean' } else { 'cleaning' }
                Write-Color "${verb}: $mode" DarkGray
                if (-not $toDrop.Count) { Write-Color "  nothing to clean" DarkGray; return }
                if ($DryRun) {
                    # Group dry-run output by (Tag, WorktreePath) so 3 ABORTED
                    # entries at the same path collapse to one line with (x3).
                    foreach ($g in ($toDrop | Group-Object Tag, WorktreePath)) {
                        $s    = $g.Group[0]
                        $note = switch ($s.Tag) {
                            'ACTIVE'  { '(was active -- entry removed; running shell unaffected)' }
                            'ABORTED' { '(aborted -- died without clean SessionEnd; worktree still on disk)' }
                            'ENDED'   { '(ended cleanly)' }
                            default   { '(stale)' }
                        }
                        $suffix = if ($g.Count -gt 1) { "  (x$($g.Count))" } else { '' }
                        Write-Color ("  [{0,-7}] {1,-30} @ {2}{3}  {4}" -f $s.Tag, $s.Branch, $s.WorktreePath, $suffix, $note) DarkGray
                    }
                    Write-Color "  -- preview only; re-run without -DryRun to act" Cyan
                } else {
                    foreach ($s in $toDrop) {
                        $note = switch ($s.Tag) {
                            'ACTIVE'  { '(was active)' }
                            'ABORTED' { '(aborted)' }
                            'ENDED'   { '(ended)' }
                            default   { '(stale)' }
                        }
                        Remove-Item $s.File -Force -ErrorAction SilentlyContinue
                        Write-Color "  removed: $($s.Branch) @ $($s.WorktreePath) $note" DarkGray
                    }
                }
            }
            'usage' {
                # Sum token usage from each session's claude jsonl logs and
                # estimate cost via a hand-maintained price table. Numbers are
                # an ESTIMATE -- pricing changes, treat as directional.
                #
                # Per WorktreePath, sums ALL jsonls in the matching project dir
                # (not just the latest ClaudeSessionId), so cost reflects total
                # spend at that path over time, including superseded sessions.

                # USD per 1M tokens. Most-specific patterns first.
                $priceTable = @(
                    @{ match='opus';   in=15.0; out=75.0; cacheW=18.75; cacheR=1.50 }
                    @{ match='sonnet'; in= 3.0; out=15.0; cacheW= 3.75; cacheR=0.30 }
                    @{ match='haiku';  in= 1.0; out= 5.0; cacheW= 1.25; cacheR=0.10 }
                )
                function script:_PriceFor([string]$model) {
                    if (-not $model) { return $null }
                    foreach ($p in $priceTable) {
                        if ($model -match $p.match) { return $p }
                    }
                    return $null
                }
                function script:_ScanJsonl([string]$path) {
                    $t = @{ in=[int64]0; out=[int64]0; cacheW=[int64]0; cacheR=[int64]0; cost=0.0; msgs=0 }
                    if (-not (Test-Path -LiteralPath $path)) { return $t }
                    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
                        if (-not $line) { continue }
                        try { $j = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                        $u = $j.message.usage
                        if (-not $u) { continue }
                        $model = $j.message.model
                        $in    = if ($u.input_tokens)                { [int64]$u.input_tokens } else { 0 }
                        $out   = if ($u.output_tokens)               { [int64]$u.output_tokens } else { 0 }
                        $cw    = if ($u.cache_creation_input_tokens) { [int64]$u.cache_creation_input_tokens } else { 0 }
                        $cr    = if ($u.cache_read_input_tokens)     { [int64]$u.cache_read_input_tokens } else { 0 }
                        $t.in     += $in
                        $t.out    += $out
                        $t.cacheW += $cw
                        $t.cacheR += $cr
                        $t.msgs   += 1
                        $p = _PriceFor $model
                        if ($p) {
                            $t.cost += ($in/1e6)*$p.in + ($out/1e6)*$p.out + ($cw/1e6)*$p.cacheW + ($cr/1e6)*$p.cacheR
                        }
                    }
                    return $t
                }

                # Dedupe by WorktreePath so each project dir is scanned once.
                $dedup = @($entries | Group-Object WorktreePath | ForEach-Object {
                    $alive = $_.Group | Where-Object Alive | Select-Object -First 1
                    if ($alive) { $alive }
                    else        { $_.Group | Sort-Object @{Expression={ if ($_.LastSpawnedAt) { $_.LastSpawnedAt } else { $_.SpawnedAt } }} -Descending | Select-Object -First 1 }
                })

                # Apply Match / Name / Window filters if given (light reuse of resolver intent without the picker).
                if ($Match)  { $dedup = @($dedup | Where-Object { $_.Branch -like "*$Match*" -or $_.WorktreePath -like "*$Match*" -or $_.WindowName -like "*$Match*" }) }
                if ($Name)   { $dedup = @($dedup | Where-Object { $_.Branch     -ieq $Name   }) }
                if ($Window) { $dedup = @($dedup | Where-Object { $_.WindowName -ieq $Window }) }
                if (-not $dedup.Count) { Write-Color "no sessions match the given filter" Yellow; return }

                $rows = @()
                foreach ($e in $dedup) {
                    $slug = $e.WorktreePath -replace '[:\\/]', '-'
                    $projDir = "C:\Users\claude\.claude\projects\$slug"
                    $jsonls = if (Test-Path -LiteralPath $projDir) { @(Get-ChildItem -LiteralPath $projDir -Filter '*.jsonl' -ErrorAction SilentlyContinue) } else { @() }

                    $sum = @{ in=[int64]0; out=[int64]0; cacheW=[int64]0; cacheR=[int64]0; cost=0.0; msgs=0; logs=$jsonls.Count }
                    foreach ($f in $jsonls) {
                        $t = _ScanJsonl $f.FullName
                        $sum.in     += $t.in
                        $sum.out    += $t.out
                        $sum.cacheW += $t.cacheW
                        $sum.cacheR += $t.cacheR
                        $sum.cost   += $t.cost
                        $sum.msgs   += $t.msgs
                    }
                    $rows += [PSCustomObject]@{
                        Branch = $e.Branch
                        Window = $e.WindowName
                        Path   = $e.WorktreePath
                        Logs   = $sum.logs
                        Msgs   = $sum.msgs
                        In     = $sum.in
                        Out    = $sum.out
                        CacheR = $sum.cacheR
                        CacheW = $sum.cacheW
                        Cost   = [Math]::Round($sum.cost, 2)
                        Last   = if ($e.LastSpawnedAt) { $e.LastSpawnedAt } else { $e.SpawnedAt }
                    }
                }

                $sortKey = if ($SortBy) { $SortBy.ToLower() } else { 'cost' }
                $sortedRows = switch ($sortKey) {
                    'tokens' { $rows | Sort-Object @{Expression={ $_.In + $_.Out + $_.CacheW + $_.CacheR }; Descending=$true} }
                    'recent' { $rows | Sort-Object @{Expression='Last'; Descending=$true} }
                    'cost'   { $rows | Sort-Object @{Expression='Cost'; Descending=$true} }
                    default  {
                        Write-Color "unknown -SortBy '$SortBy' (using 'cost'); valid: cost|tokens|recent" Yellow
                        $rows | Sort-Object @{Expression='Cost'; Descending=$true}
                    }
                }

                Write-Host ""
                Write-Color "session usage  (estimate -- pricing table is hand-maintained)" Cyan
                Write-Host ""
                $fmt = '{0,-30} {1,-12} {2,5} {3,6} {4,12} {5,12} {6,12} {7,12} {8,9}'
                Write-Color ($fmt -f 'Branch','Window','Logs','Msgs','In','Out','CacheR','CacheW','$est') DarkGray
                Write-Color ($fmt -f ('-'*30),('-'*12),('-'*5),('-'*6),('-'*12),('-'*12),('-'*12),('-'*12),('-'*9)) DarkGray

                $tIn=[int64]0; $tOut=[int64]0; $tCw=[int64]0; $tCr=[int64]0; $tMsgs=0; $tCost=0.0
                foreach ($r in $sortedRows) {
                    $branch = if ($r.Branch.Length -gt 30) { $r.Branch.Substring(0,27) + '...' } else { $r.Branch }
                    $win    = if ($r.Window.Length -gt 12) { $r.Window.Substring(0,9)  + '...' } else { $r.Window }
                    if ($r.Logs -eq 0 -or $r.Msgs -eq 0) {
                        Write-Color ($fmt -f $branch, $win, $r.Logs, '-', '-', '-', '-', '-', '-') DarkGray
                        continue
                    }
                    $tIn += $r.In; $tOut += $r.Out; $tCw += $r.CacheW; $tCr += $r.CacheR
                    $tMsgs += $r.Msgs; $tCost += $r.Cost
                    Write-Host ($fmt -f $branch, $win, $r.Logs, $r.Msgs,
                        ('{0:N0}' -f $r.In), ('{0:N0}' -f $r.Out),
                        ('{0:N0}' -f $r.CacheR), ('{0:N0}' -f $r.CacheW),
                        ('${0:N2}' -f $r.Cost))
                }

                Write-Color ($fmt -f ('-'*30),('-'*12),('-'*5),('-'*6),('-'*12),('-'*12),('-'*12),('-'*12),('-'*9)) DarkGray
                Write-Color ($fmt -f 'TOTAL','','', $tMsgs,
                    ('{0:N0}' -f $tIn), ('{0:N0}' -f $tOut),
                    ('{0:N0}' -f $tCr), ('{0:N0}' -f $tCw),
                    ('${0:N2}' -f $tCost)) Cyan
                Write-Host ""
                Write-Color "  pricing per 1M tokens: opus 15/75/18.75/1.50  sonnet 3/15/3.75/0.30  haiku 1/5/1.25/0.10  (in/out/cacheW/cacheR)" DarkGray
                Write-Color "  sort: -SortBy cost|tokens|recent  (default: cost)" DarkGray
                Write-Color "  filter: pass a substring positionally, or -Name <branch> / -Window <name>" DarkGray
                Write-Host ""
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

                # Lifecycle states (3 buckets, picked by Alive + worktree-on-disk):
                #   ACTIVE -- PID is running
                #   PAUSED -- PID dead, but worktree dir still exists on disk (restorable)
                #   STALE  -- PID dead AND worktree dir is gone (real cruft).
                #            STALE is restricted to $env:WORKTREE_ROOT entries; missing
                #            main-clone paths (under $env:GIT_ROOT) stay PAUSED so a
                #            temporary unmount or path move never gets called cruft.
                $wtRootRegex = "^$([regex]::Escape($script:WtRoot))\\"
                $byWindow = $deduped | Sort-Object @{e='Alive';desc=$true}, WindowName, Branch | Group-Object WindowName
                $abortedCount = 0
                $staleCount   = 0
                $endedCount   = 0
                foreach ($g in $byWindow) {
                    Write-Host ""
                    # Empty WindowName means the entry never got assigned a wt
                    # window (old entries pre-window-detection, or main-clone
                    # launches before ad-hoc routing). Label them explicitly
                    # instead of rendering as an empty bracket.
                    $groupLabel = if ([string]::IsNullOrEmpty($g.Name)) { 'unassociated' } else { $g.Name }
                    Write-Color "[$groupLabel]" Cyan
                    foreach ($s in $g.Group) {
                        if ($s.Alive) {
                            $tag = 'ACTIVE'; $col = 'Green'
                        } elseif ($s.State -eq 'ended') {
                            # Human closed the session cleanly (SessionEnd hook fired).
                            # Distinct from ABORTED (died without clean shutdown) and STALE
                            # (worktree dir is gone).
                            $tag = 'ENDED';   $col = 'DarkGray'; $endedCount++
                        } elseif ($s.WorktreePath -and (Test-Path $s.WorktreePath)) {
                            # Process gone but SessionEnd never fired: Windows restart,
                            # crash, hard kill. THESE are the priority for restore.
                            $tag = 'ABORTED'; $col = 'Yellow';   $abortedCount++
                        } elseif ($s.WorktreePath -and $s.WorktreePath -match $wtRootRegex) {
                            $tag = 'STALE';   $col = 'Red';      $staleCount++
                        } else {
                            $tag = 'ABORTED'; $col = 'Yellow';   $abortedCount++
                        }
                        # Saved entries get a distinct SAVED tag (overrides the lifecycle
                        # label so they pop visually). Color still reflects underlying state.
                        if ($s.Saved) { $tag = 'SAVED' }
                        $displayName = if ($s.Label) { $s.Label } else { $s.Branch }
                        # State sub-tag (thinking / idle / needs-input) is set by the
                        # claude-code hooks via set-session-state.ps1. Only meaningful
                        # for ALIVE entries; suppress otherwise.
                        $stateTag = ''
                        if ($s.Alive -and $s.State) {
                            $stateTag = switch ($s.State) {
                                'thinking'    { '[THINK]' }
                                'idle'        { '[ idle]' }
                                'needs-input' { '[INPUT]' }
                                default       { "[$($s.State)]" }
                            }
                            if ($s.State -eq 'needs-input') { $col = 'Magenta' }
                        }
                        Write-Color ("  [{0,-7}] {1,-7} {2,-30} @ {3}" -f $tag, $stateTag, $displayName, $s.WorktreePath) $col
                        # -Verbose: print the session's start time on a sub-line. Uses
                        # LastSpawnedAt (when the current incarnation began) and falls back
                        # to FirstSpawnedAt or SpawnedAt for older entries.
                        if ($VerbosePreference -eq 'Continue') {
                            $when = $s.LastSpawnedAt
                            if (-not $when) { $when = $s.FirstSpawnedAt }
                            if (-not $when) { $when = $s.SpawnedAt }
                            if ($when) {
                                try {
                                    $whenDT  = [datetime]::Parse($when)
                                    $whenStr = $whenDT.ToString('yyyy-MM-dd HH:mm')
                                    $age     = [datetime]::Now - $whenDT
                                    $ageStr  = if ($age.TotalDays   -ge 1) { '{0:N0}d ago' -f $age.TotalDays }
                                               elseif ($age.TotalHours -ge 1) { '{0:N0}h ago' -f $age.TotalHours }
                                               else                          { '{0:N0}m ago' -f $age.TotalMinutes }
                                    Write-Color ("              started: $whenStr  ($ageStr)") DarkGray
                                } catch {
                                    Write-Color ("              started: $when") DarkGray
                                }
                            }
                        }
                    }
                }
                Write-Host ""
                $noShellCount = $abortedCount + $staleCount + $endedCount
                $totalRows    = @($deduped).Count
                Write-Color ("  - $totalRows entries: $($totalRows - $noShellCount) live, $noShellCount with no live shell ($abortedCount aborted, $endedCount ended, $staleCount stale)") DarkGray
                if ($abortedCount -gt 0) {
                    Write-Color "  - ABORTED = died without clean SessionEnd (crash / restart / kill). 'gwt sessions restore' brings them back; skips ENDED by default." Yellow
                }
                if ($noShellCount -gt 10) {
                    Write-Color "  - $noShellCount sessions with no live shell: 'gwt sessions clean -Aborted' to drop (preview with -DryRun)" DarkGray
                }
                if ($dupes -gt 0) {
                    Write-Color "  - $dupes duplicate entrie(s) hidden: 'gwt sessions clean -IncludeDuplicates' to drop them" DarkGray
                }
                if ($Usage) {
                    Write-Color "  # all 'sessions' subcommands default to THIS REPO when cwd is inside one." DarkGray
                    Write-Color "  # pass -All to act across every repo's sessions." DarkGray
                    Write-Host ""
                    Write-Color "  # mark a session as Saved (protected from every clean) -- shown as [SAVED]" DarkGray
                    Write-Color "  gwt sessions save   <substring> [-Name <branch>] [-Window <name>]" DarkGray
                    Write-Color "  gwt sessions unsave <substring> [-Name <branch>] [-Window <name>]" DarkGray
                    Write-Color "  #   filters combine; multi-match prompts a picker (or 'a' for all)" DarkGray
                    Write-Host ""
                    Write-Color "  # relabel a session's display name (does not rename the git branch)" DarkGray
                    Write-Color "  gwt rename <match> <new-label> [-Name <branch>] [-Window <name>]" DarkGray
                    Write-Host ""
                    Write-Color "  # relaunch ABORTED sessions (skips ENDED; pass -IncludeEnded to include)" DarkGray
                    Write-Color "  gwt sessions restore" DarkGray
                    Write-Host ""
                    Write-Color "  # clean tiers (this-repo by default; add -All for cross-repo):" DarkGray
                    Write-Color "  gwt sessions clean                              # STALE + ENDED" DarkGray
                    Write-Color "  gwt sessions clean -Aborted [<name-substring>]  # + ABORTED" DarkGray
                    Write-Color "  gwt sessions clean -IncludeActive               # + ACTIVE (registry only; running shells unaffected)" DarkGray
                    Write-Color "  gwt sessions clean -Aborted -IncludeActive -All # nuke everything everywhere" DarkGray
                } else {
                    Write-Color "  - pass -Usage for command tips" DarkGray
                }
            }
        }
    }

    'claude' {
        # 'gwt claude' (or 'gwt claude .') tries hard to open claude here:
        #   1. resolve current branch + repo context + worktree
        #   2. if any step fails (fresh 'git init', no remote, no commits yet,
        #      not even a git repo) fall back to a tangent-style launch at cwd
        # That way `git init` + `gwt claude .` Just Works.
        $tangentFallback = $false
        if (-not $Target -or $Target -eq '.') {
            $Target = (& git rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $Target -or $Target -eq 'HEAD') {
                $tangentFallback = $true
            }
        }

        if (-not $tangentFallback) {
            try   { $ctx = Resolve-RepoContext }
            catch { $tangentFallback = $true }
        }
        if (-not $tangentFallback) {
            $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
            if (-not $wtPath -or -not (Test-Path $wtPath)) { $tangentFallback = $true }
        }

        if ($tangentFallback) {
            # No usable git context -- open claude in cwd, no worktree machinery.
            $tanPath = (Get-Location).Path
            $tanLeaf = Split-Path $tanPath -Leaf
            Write-Color "no worktree/branch context -- opening as a tangent at $tanPath" DarkGray
            if (-not (_ConfirmNoAliveSessionAt -Path $tanPath)) { return }
            $window     = if ($y) { 'tangent' } else { _SelectWtWindow -Default 'tangent' }
            $promptText = if ($Prompt) { $Prompt }
                          elseif ($y) { '' }
                          else { Select-ClaudePrompt -Repo $tanLeaf -Branch 'tangent' }
            _OpenClaudeShell -Path $tanPath -Repo $tanLeaf -Branch "tangent:$tanLeaf" `
                             -PromptText $promptText -WindowName $window -Force
            return
        }

        # Active-session check FIRST, before any state/picks prompts.
        if (-not (_ConfirmNoAliveSessionAt -Path $wtPath)) { return }

        _InvokeGwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath -RemoteHost $ctx.RemoteHost

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
            $window = _SelectWtWindow
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

        # -Force here suppresses _OpenClaudeShell's redundant alive-session guard;
        # we already prompted at the top of this block.
        _OpenClaudeShell -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptText $promptText -WindowName $window -Force
    }

    'cd' {
        if (-not $Target) { throw "'cd' requires a branch or worktree dir name" }
        $ctx    = Resolve-RepoContext

        # Special case: 'gwt cd current' resolves to whatever <WtRoot>\current
        # points at. Useful for IDE-pinned setups: cd straight to the active wt.
        if ($Target -ieq 'current') {
            $link = Join-Path $ctx.WtRoot 'current'
            if (-not (Test-Path $link)) {
                throw "no 'current' link at $link -- run 'gwt activate <branch>' first"
            }
            try {
                $li = Get-Item $link -Force
                if ($li.LinkType -notin 'SymbolicLink','Junction') { throw "'current' exists but is not a link (LinkType=$($li.LinkType))" }
                $wtPath = ($li.Target | Select-Object -First 1)
            } catch { throw "could not resolve 'current' symlink: $($_.Exception.Message)" }
            if (-not (Test-Path $wtPath)) { throw "'current' points at '$wtPath' which is missing" }
            Write-Output $wtPath
            return
        }

        $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
        if (-not $wtPath) {
            # Fall back to matching by worktree directory name (case-insensitive).
            # Useful when the branch name differs from the folder name, or when
            # case got typed wrong.
            $lines = & git -C $ctx.Src worktree list --porcelain 2>&1
            foreach ($line in $lines) {
                if ($line -match '^worktree\s+(.+)$') {
                    $candidate = $Matches[1]
                    if ((Split-Path $candidate -Leaf) -ieq $Target) {
                        $wtPath = $candidate
                        Write-Color "matched by dir name (branch differs): $candidate" DarkGray
                        break
                    }
                }
            }
        }
        if (-not $wtPath) { throw "no worktree for branch or dir '$Target' in $($ctx.Org)/$($ctx.Repo)" }
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
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object {
            $procMap[[int]$_.ProcessId] = $_
        }
        $aliveHits = @()
        $sessionsDir = $script:SessionDir
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

    'watch' {
        # Tail the per-session state log written by the claude-code hooks.
        # Each line: <iso-ts>  <state>  <branch>  @ <path>
        # Blocks; Ctrl-C to exit. -Tail <n> controls how many existing lines
        # to print before following (default 20).
        $watchDir = "$script:WtRoot\watch"
        $logFile  = Join-Path $watchDir 'state.log'
        if (-not (Test-Path $logFile)) {
            [System.IO.Directory]::CreateDirectory($watchDir) | Out-Null
            Write-Color "no state log yet at $logFile -- waiting for first transition" DarkGray
            New-Item -Path $logFile -ItemType File -Force | Out-Null
        } else {
            Write-Color "tailing $logFile (Ctrl-C to exit)" DarkGray
        }
        Get-Content -Path $logFile -Tail $Tail -Wait
        return
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
        if ($NoFetch) {
            Write-Color "skipping fetch (-NoFetch)" DarkGray
        } else {
            Write-Color "fetching origin @ $($ctx.Src)..." DarkGray
            & git -C $ctx.Src fetch origin --prune 2>&1 | Out-Null
        }

        $allStatuses = Get-WorktreeStatuses $ctx.Src | Sort-Object -Property LastCommit -Descending
        # Pin MAIN to the top, everything else in time-sorted order below.
        $mainEntry = @($allStatuses | Where-Object { $_.Status -eq 'MAIN' })
        $others    = @($allStatuses | Where-Object { $_.Status -ne 'MAIN' })
        $statuses  = $mainEntry + $others

        # Build a path -> window-name map from alive sessions, so we can mark
        # worktrees that currently have a running claude session and show which
        # wt window they're in (active-work / pull-requests / tangent / etc).
        $aliveWindow = @{}
        $sessionDir = $script:SessionDir
        if (Test-Path $sessionDir) {
            $procMap = @{}
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object {
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
            'MAIN'              = 'DarkGray'
            'ACTIVE'            = 'Green'
            'ACTIVE-REMOTE-GONE'   = 'DarkYellow'
            'PRUNE'             = 'Red'
            'DIRTY'             = 'Yellow'
            'ORPHAN'            = 'Magenta'
            'ORPHAN-DIRTY'      = 'Magenta'
            'ORPHAN-NO-GIT'     = 'Red'
        }
        $windowColorMap = @{
            'active-work'   = 'Green'
            'pull-requests' = 'Blue'
            'tangent'       = 'Magenta'
            'worktrees'     = 'DarkGray'
        }

        $printedMain = $false
        # Look up the 'current' link target if any -- print it right under
        # MAIN as a quick "this is what your IDE follows" hint.
        $currentLink = Join-Path $ctx.WtRoot 'current'
        $currentTgt  = $null
        if (Test-Path $currentLink) {
            try {
                $cli = Get-Item $currentLink -Force
                if ($cli.LinkType -in 'SymbolicLink','Junction') {
                    $currentTgt = ($cli.Target | Select-Object -First 1)
                }
            } catch {}
        }
        foreach ($wt in $statuses) {
            # Print a divider after the MAIN row to visually separate the main
            # clone from the worktrees below. If 'current' is set, print it
            # right above the divider so it sits in the MAIN block.
            if ($printedMain -and $wt.Status -ne 'MAIN') {
                if ($currentTgt) {
                    $tgtNorm = $currentTgt.Replace('\','/').TrimEnd('/')
                    Write-Host "    [CURRENT         ] " -NoNewline -ForegroundColor White
                    Write-Host "-> $tgtNorm" -ForegroundColor DarkCyan
                }
                Write-Host ('    ' + ('-' * 90)) -ForegroundColor DarkGray
                $printedMain = $false
            }
            $key   = ($wt.Path -replace '/', '\').TrimEnd('\').ToLower()
            $win   = $aliveWindow[$key]
            $alive = [bool]$win
            $statusColor = $statusColorMap[$wt.Status]
            $whenRel = $wt.LastCommitRel
            if ($whenRel) {
                $whenRel = $whenRel `
                    -replace ' seconds? ago$', 's ago' `
                    -replace ' minutes? ago$', 'min ago' `
                    -replace ' hours? ago$',   'h ago' `
                    -replace ' days? ago$',    'd ago' `
                    -replace ' weeks? ago$',   'w ago' `
                    -replace ' months? ago$',  'mo ago' `
                    -replace ' years? ago$',   'y ago'
            }
            $when  = if ($whenRel) { "($whenRel)" } else { '' }
            if ($wt.Status -eq 'MAIN') { $printedMain = $true }

            # leading marker so alive rows stand out at a glance
            if ($alive) { Write-Host "  ● " -NoNewline -ForegroundColor White }
            else        { Write-Host "    " -NoNewline }

            # status block padded to align bracket width across all rows
            $statusPad = $wt.Status.PadRight(16)
            Write-Host "[$statusPad] " -NoNewline -ForegroundColor $statusColor

            # branch (white if alive, else status color)
            $branchColor = if ($alive) { 'White' } else { $statusColor }
            Write-Host "$($wt.Branch) " -NoNewline -ForegroundColor $branchColor

            # window tag for alive entries
            if ($alive) {
                $wColor = if ($windowColorMap[$win]) { $windowColorMap[$win] } else { 'White' }
                Write-Host "[$win] " -NoNewline -ForegroundColor $wColor
            }

            if ($wt.Status -eq 'MAIN') {
                # One-line for MAIN: include date inline, squeezed
                $whenSep = if ($when) { "$when " } else { '' }
                Write-Host "$whenSep@ $($wt.Path)" -ForegroundColor DarkGray
            } else {
                Write-Host "@ $($wt.Path)" -ForegroundColor DarkGray
                # Second line: (date) reason -- indent under branch column (4 + "[" + 16 + "] " = 23)
                # If the reason mentions "WAS pushed, remote ref deleted", color
                # the detail orange regardless of the row's status color so
                # remote-deleted state always pops.
                $detail = (@($when, $wt.Reason) | Where-Object { $_ }) -join ' '
                if ($detail) {
                    $detailColor = if ($wt.Reason -match 'WAS pushed, remote ref deleted') { 'DarkYellow' } else { $statusColor }
                    Write-Color ("{0}{1}" -f (' ' * 23), $detail) $detailColor
                }

                # -Verbose (-v works too): inline 'git status --short' so the
                # user sees the actual files contributing to DIRTY. ACTIVE
                # rows intentionally skipped -- the user just wants to know
                # what's edited, not the commit history.
                if ($VerbosePreference -eq 'Continue' -and $wt.Status -eq 'DIRTY') {
                    $short = (& git -C $wt.Path status --short 2>$null | Out-String).TrimEnd()
                    if ($short) {
                        foreach ($line in ($short -split "`r?`n")) {
                            Write-Host ((' ' * 27) + $line) -ForegroundColor DarkGray
                        }
                    }
                }
            }
        }

        # Orphan sweep: directories under the worktree root that git no longer
        # tracks. Mirrors the same logic 'gwt prune' uses, but read-only here.
        if (Test-Path $ctx.WtRoot) {
            $registered = $statuses | ForEach-Object { $_.Path.Replace('\','/').ToLower() }
            Get-ChildItem $ctx.WtRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
                # Skip symlinks (e.g. our 'current' shortcut) -- they're not worktrees.
                $_.LinkType -ne 'SymbolicLink'
            } | ForEach-Object {
                $p     = $_.FullName
                $pNorm = $p.Replace('\','/').ToLower()
                if ($registered -contains $pNorm) { return }
                $dirty   = (& git -C $p status --porcelain 2>&1 | Out-String).Trim()
                $oStatus = if ([string]::IsNullOrWhiteSpace($dirty)) {
                    'ORPHAN'
                } elseif ($dirty -match '^fatal:') {
                    'ORPHAN-NO-GIT'
                } else {
                    'ORPHAN-DIRTY'
                }
                $oColor  = if ($statusColorMap[$oStatus]) { $statusColorMap[$oStatus] } else { 'Red' }
                $oReason = switch ($oStatus) {
                    'ORPHAN-DIRTY'  { 'has uncommitted changes -- skip on prune' }
                    'ORPHAN-NO-GIT' { 'no .git linkage -- not a working tree anymore' }
                    default         { 'no git registration -- prunable' }
                }
                Write-Host "    " -NoNewline
                Write-Host "[$($oStatus.PadRight(16))] " -NoNewline -ForegroundColor $oColor
                Write-Host (Split-Path $p -Leaf) -NoNewline -ForegroundColor $oColor
                Write-Host " @ $($p.Replace('\','/'))" -ForegroundColor DarkGray
                Write-Color ("{0}{1}" -f (' ' * 23), $oReason) $oColor
            }
        }
    }

    'update' {
        $ctx = Resolve-RepoContext
        if ($NoFetch) {
            Write-Color "skipping fetch (-NoFetch)" DarkGray
        } else {
            Write-Color "fetching origin @ $($ctx.Src)..." DarkGray
            & git -C $ctx.Src fetch origin --prune 2>&1 | Out-Null
        }

        $statuses = Get-WorktreeStatuses $ctx.Src

        foreach ($wt in $statuses) {
            if ($wt.Status -eq 'MAIN') { continue }
            if ($wt.Status -notin @('ACTIVE')) { continue }

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

    { $_ -in 'changes','status' } {
        # For every worktree with uncommitted local changes (DIRTY or ORPHAN-DIRTY),
        # print the branch + path + `git status --short` output. Quick way to see
        # what's lurking across all your worktrees in this repo.
        $ctx = Resolve-RepoContext
        $statuses = Get-WorktreeStatuses $ctx.Src

        # Build registered-path set so we can also scan orphan dirs.
        $registered = $statuses | ForEach-Object { $_.Path.Replace('\','/').ToLower() }
        $rows = @()
        foreach ($wt in $statuses) {
            if ($Target -and $wt.Branch -ne $Target -and (Split-Path $wt.Path -Leaf) -ne $Target) { continue }
            if ($wt.Status -in @('DIRTY','ACTIVE','ACTIVE-REMOTE-GONE')) {
                $rows += [PSCustomObject]@{ Label = $wt.Status; Branch = $wt.Branch; Path = $wt.Path }
            }
        }
        # Skip the orphan sweep when filtering to a specific branch -- orphans by
        # definition aren't tied to a branch in git's view.
        if (-not $Target -and (Test-Path $ctx.WtRoot)) {
            Get-ChildItem $ctx.WtRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
                # Skip symlinks (e.g. our 'current' shortcut) -- they're not worktrees.
                $_.LinkType -ne 'SymbolicLink'
            } | ForEach-Object {
                $p     = $_.FullName
                $pNorm = $p.Replace('\','/').ToLower()
                if ($registered -contains $pNorm) { return }
                $dirty = (& git -C $p status --porcelain 2>&1 | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($dirty)) { return }
                # If git itself bailed (no .git), it's an orphan-no-git -- different beast.
                $label = if ($dirty -match '^fatal:') { 'ORPHAN-NO-GIT' } else { 'ORPHAN-DIRTY' }
                $rows += [PSCustomObject]@{ Label = $label; Branch = (Split-Path $p -Leaf); Path = $p }
            }
        }

        if (-not $rows) {
            if ($Target) {
                Write-Color "no dirty/unpushed changes for '$Target' in $($ctx.Src)" DarkGray
            } else {
                Write-Color "no dirty worktrees in $($ctx.Src)" DarkGray
            }
            return
        }

        foreach ($r in $rows) {
            $color = switch ($r.Label) {
                'ORPHAN-DIRTY'     { 'Magenta' }
                'ORPHAN-NO-GIT'    { 'Red' }
                'ACTIVE'              { 'Cyan' }
                'ACTIVE-REMOTE-GONE'  { 'DarkYellow' }
                default            { 'Yellow' }
            }
            Write-Host ""
            Write-Color "[$($r.Label.PadRight(16))] $($r.Branch) @ $($r.Path)" $color
            if ($r.Label -eq 'ORPHAN-NO-GIT') {
                Write-Color "    no .git linkage -- not a working tree anymore (safe to inspect/delete)" $color
                continue
            }
            if ($r.Label -in @('ACTIVE','ACTIVE-REMOTE-GONE')) {
                # Show unpushed/orphaned commits (vs origin/main) -- they're the
                # "changes" here. For ACTIVE-REMOTE-GONE the remote was deleted
                # so these are the commits at risk if you prune.
                $log = (& git -C $r.Path log --oneline origin/main..HEAD 2>&1 | Out-String).TrimEnd()
                if ($log) {
                    foreach ($line in ($log -split "`r?`n")) { Write-Host "    $line" -ForegroundColor $color }
                } else {
                    Write-Host "    (no commits beyond origin/main)" -ForegroundColor $color
                }
                continue
            }
            $short = (& git -C $r.Path status --short 2>&1 | Out-String).TrimEnd()
            if ($short) {
                foreach ($line in ($short -split "`r?`n")) { Write-Host "    $line" -ForegroundColor $color }
            }
        }
    }

    'prune' {
        # If $Target looks like a path (., .., contains a backslash, or is
        # rooted with a drive letter), resolve it to an absolute path and peel
        # off the last folder. That folder name is the branch under gwt's
        # canonical D:\worktrees\<host>\<org>\<repo>\<branch>\ layout.
        $isPathish = $Target -and (
            $Target -eq '.' -or $Target -eq '..' -or
            $Target -match '\\' -or $Target -match '^[A-Za-z]:'
        )
        if ($isPathish) {
            try {
                $resolved = (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path
                $orig     = $Target
                $Target   = Split-Path $resolved.TrimEnd('\') -Leaf
                Write-Color "resolved '$orig' -> branch '$Target' (from $resolved)" DarkGray
            } catch {
                throw "could not resolve path '$Target'"
            }
        }

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
            # In multi-repo mode (Org/Repo iteration), print a per-repo header;
            # in single-repo mode the 'detected:' line at the top already shows it.
            if ($reposToProcess.Count -gt 1) {
                Write-Color "`nrepo: $repoPath" Cyan
            }
            if (-not $NoFetch) {
                & git -C $repoPath fetch origin --prune 2>&1 | Out-Null
            }
            # Clean any stale entries inside .git/worktrees/ first -- e.g. if a
            # previous prune deleted the working dir but the internal record
            # survived (or the user 'gwt new'd then twigged the branch and
            # garbage was left behind). Makes downstream detection consistent.
            & git -C $repoPath worktree prune 2>&1 | Out-Null

            $statuses   = Get-WorktreeStatuses $repoPath
            $registered = $statuses | ForEach-Object { $_.Path.Replace('\','/').ToLower() }

            $filterMatchedWorktree = $false
            if ($branchFilter) {
                $filtered = @($statuses | Where-Object { $_.Branch -eq $branchFilter })
                if ($filtered.Count -eq 0) {
                    # No branch named that. Maybe the user typed a worktree DIR
                    # name whose branch differs (e.g. 'release-v1.5.x' dir holding
                    # branch 'quickstart-never-latest-on-maint-branch'). Offer it.
                    $byDir = @($statuses | Where-Object { (Split-Path $_.Path -Leaf) -ieq $branchFilter })
                    if ($byDir.Count -eq 1) {
                        $b = $byDir[0]
                        Write-Color "  no branch named '$branchFilter' -- found a worktree dir with that name holding branch '$($b.Branch)'" Yellow
                        # -y (and -Force, which already commits to acting) auto-accepts this name-ambiguity prompt.
                        if ($y -or $Force) {
                            Write-Color "  using that worktree (auto-accepted via -y/-Force)" DarkGray
                            $filtered = $byDir
                        } else {
                            $r = Read-Host "  use that worktree? (Y/n)"
                            if ([string]::IsNullOrWhiteSpace($r) -or $r -match '^[Yy]') {
                                $filtered = $byDir
                            }
                        }
                    } elseif ($byDir.Count -gt 1) {
                        Write-Color "  no branch named '$branchFilter' -- multiple worktree dirs share that leaf name; type the full branch name to disambiguate" Yellow
                    }
                }
                if ($filtered.Count) {
                    $statuses = $filtered
                    $filterMatchedWorktree = $true
                } else {
                    # Don't bail -- the name might still match an orphan dir below.
                    $statuses = @()
                }
            }

            # Only show PRUNE candidates (and orphans below). Skip MAIN/ACTIVE/
            # ACTIVE/DIRTY -- they're not getting touched, no need to
            # narrate them. If a branch filter was passed and yields only a
            # non-prunable hit, say so explicitly.
            # -Force opens the door to DIRTY and (with confirmation) ACTIVE too.
            # For safety, -Force without -y still requires the per-row Y/n prompt.
            $eligibleStatuses = if ($Force) { @('PRUNE','DIRTY','ACTIVE') } else { @('PRUNE') }
            $prunable = @($statuses | Where-Object { $_.Status -in $eligibleStatuses })
            if ($branchFilter -and -not $prunable -and $filterMatchedWorktree) {
                # Only fire when we DID find a worktree, but its status isn't in
                # the prunable set. If no match was found at all, fall through to
                # the orphan sweep below -- it'll handle the "not found" case.
                $actualStatus = if ($statuses.Count -eq 1) { $statuses[0].Status } else { 'unknown' }
                Write-Color "  '$branchFilter' is $actualStatus -- prune won't touch it by default" Yellow
                if ($actualStatus -eq 'DIRTY' -and -not $Force) {
                    # Offer -Force inline instead of making the user re-type the command.
                    # Default is N because we're about to destroy real local content.
                    $r = if ($y) { 'y' } else { Read-Host "  delete DIRTY worktree '$branchFilter' anyway? (lose local content) (y/N)" }
                    if ($r -match '^[Yy]$') {
                        $prunable = @($statuses | Where-Object { $_.Status -in @('PRUNE','DIRTY') })
                        $Force    = $true
                    } else {
                        Write-Color "    aborted -- nothing changed" DarkGray
                        Write-Color "    -> gwt prune $branchFilter -Force   (skips this prompt)" DarkGray
                        Write-Color "    -> gwt rm $branchFilter             (deletes regardless of state)" DarkGray
                    }
                } else {
                    Write-Color "    -> gwt rm $branchFilter   (deletes regardless of state)" DarkGray
                }
            }
            foreach ($wt in $prunable) {
                $raw   = if ($wt.Reason) { "PRUNE $($wt.Reason)" } else { $wt.Status }
                $label = $raw.PadRight(16)

                # Saved guard: refuse to prune any worktree marked Saved in the session
                # registry, even with -Force. User must `gwt sessions unsave <branch>` first.
                if (Test-WorktreeIsSaved $wt.Path) {
                    Write-Color "  [SAVED   ] $($wt.Branch) @ $($wt.Path)" Cyan
                    Write-Color "                    protected -- run 'gwt sessions unsave $($wt.Branch)' first" DarkGray
                    continue
                }

                switch ($wt.Status) {
                    'PRUNE'            {
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Red
                        $ok = $y -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "  remove? (Y/n)")) -or $r -match '^[Yy]$')
                        if ($ok) {
                            _ChangeToMainFolder -Path $wt.Path -MainPath $repoPath
                            & git -C $repoPath worktree remove --force $wt.Path 2>&1 | Out-Null
                            $gone = _ForceRemoveWorktreeDir $wt.Path
                            if ($gone) { Write-Color "                    removed." DarkGray }
                            _CleanupWorktreeMetadata $wt.Path
                            if (-not $gone) {
                                Write-Color "                    WARNING: '$($wt.Path)' still on disk" Red
                                Write-Color "                    likely cause: a shell, IDE (GoLand / VS Code), or Explorer window has it open" DarkGray
                                Write-Color "                    'cd' that shell elsewhere, close the IDE project, then 'gwt prune $($wt.Branch) -Force' again" DarkGray
                            }
                        }
                    }
                    'ACTIVE' {
                        # Reached only when -Force is set. The branch has an upstream
                        # and is otherwise healthy; default prompt to N because the user
                        # may have just typo'd the branch name.
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Yellow
                        $ok = $y -or (($r = Read-Host "  -Force: delete ACTIVE worktree '$($wt.Branch)' (branch keeps its upstream; worktree dir is removed)? (y/N)") -match '^[Yy]$')
                        if ($ok) {
                            _ChangeToMainFolder -Path $wt.Path -MainPath $repoPath
                            & git -C $repoPath worktree remove --force $wt.Path 2>&1 | Out-Null
                            $gone = _ForceRemoveWorktreeDir $wt.Path
                            if ($gone) { Write-Color "                    removed." DarkGray }
                            _CleanupWorktreeMetadata $wt.Path
                            if (-not $gone) {
                                Write-Color "                    WARNING: '$($wt.Path)' still on disk" Red
                                Write-Color "                    likely cause: a shell, IDE (GoLand / VS Code), or Explorer window has it open" DarkGray
                                Write-Color "                    'cd' that shell elsewhere, close the IDE project, then 'gwt prune $($wt.Branch) -Force' again" DarkGray
                            }
                        }
                    }
                    'DIRTY' {
                        # Reached only when -Force is set. Default the prompt to N because
                        # we're about to destroy real local content.
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" Yellow
                        Write-Color "                    $($wt.Reason)" Yellow
                        $kind = 'DIRTY'
                        $ok = $y -or (($r = Read-Host "  -Force: delete $kind worktree and lose local content? (y/N)") -match '^[Yy]$')
                        if ($ok) {
                            _ChangeToMainFolder -Path $wt.Path -MainPath $repoPath
                            & git -C $repoPath worktree remove --force $wt.Path 2>&1 | Out-Null
                            # `worktree remove --force` can leave the directory if it
                            # contains ignored/untracked files. Stomp it explicitly + verify.
                            $gone = _ForceRemoveWorktreeDir $wt.Path
                            if ($gone) { Write-Color "                    removed." DarkGray }
                            _CleanupWorktreeMetadata $wt.Path
                            if (-not $gone) {
                                Write-Color "                    WARNING: '$($wt.Path)' still on disk" Red
                                Write-Color "                    likely cause: a shell, IDE (GoLand / VS Code), or Explorer window has it open" DarkGray
                                Write-Color "                    'cd' that shell elsewhere, close the IDE project, then 'gwt prune $($wt.Branch) -Force' again" DarkGray
                            }
                        }
                    }
                }
            }

            & git -C $repoPath worktree prune 2>&1 | Out-Null

            # orphan directories in worktree root that git no longer knows about.
            # When a branch filter is set, only consider the orphan whose leaf name
            # matches it -- that way 'gwt prune <name>' still finds an orphan-by-name.
            $orgPart  = if ($Org) { $Org } else { Split-Path (Split-Path $repoPath -Parent) -Leaf }
            $repoPart = Split-Path $repoPath -Leaf
            $wtRoot   = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $orgPart) $repoPart

            if (-not (Test-Path $wtRoot)) {
                if ($branchFilter -and -not $filterMatchedWorktree) {
                    Write-Color "  no worktree or orphan named '$branchFilter' in this repo" Yellow
                }
                continue
            }

            $orphanMatchFound = $false
            foreach ($d in (Get-ChildItem $wtRoot -Directory -ErrorAction SilentlyContinue)) {
                if ($d.LinkType -eq 'SymbolicLink') { continue }   # skip 'current' and friends
                $p     = $d.FullName
                $pNorm = $p.Replace('\','/').ToLower()
                if ($registered -contains $pNorm) { continue }
                if ($branchFilter -and ($d.Name -ine $branchFilter)) { continue }
                $orphanMatchFound = $true

                # Alive-session guard applies to both orphan branches -- if a claude
                # session is sitting in the dir, Remove-Item will fail with "in use".
                $alive = Get-AliveSessionForPath $p
                if ($alive) {
                    Write-Color "  REFUSING to remove orphan '$p' -- claude session is alive there" Red
                    Write-Color "    branch=$($alive.Branch)  window=$($alive.WindowName)  pid=$($alive.Pid)" DarkGray
                    Write-Color "    close that tab (or 'gwt focus $($alive.Branch)' then exit), then retry" DarkGray
                    continue
                }

                $dirty = (& git -C $p status --porcelain 2>&1 | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($dirty)) {
                    Write-Color "  [ORPHAN ] $p" Magenta
                    $ok = $y -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "  remove orphan? (Y/n)")) -or $r -match '^[Yy]$')
                    if ($ok) {
                        _ChangeToMainFolder -Path $p -MainPath $repoPath
                        $gone = _ForceRemoveWorktreeDir $p
                        if ($gone) { Write-Color "                    removed." DarkGray }
                        _CleanupWorktreeMetadata $p
                        if (-not $gone) {
                            Write-Color "                    WARNING: '$p' still on disk" Red
                            Write-Color "                    likely cause: a shell, IDE, or Explorer window has it open" DarkGray
                        }
                    }
                } elseif ($dirty -match '^fatal:') {
                    Write-Color "  [ORPHAN-NO-GIT] $p" Red
                    Write-Color "                    no .git linkage -- not a working tree anymore" Red
                    $ok = $y -or ([string]::IsNullOrWhiteSpace(($r = Read-Host "  remove? (Y/n)")) -or $r -match '^[Yy]$')
                    if ($ok) {
                        _ChangeToMainFolder -Path $p -MainPath $repoPath
                        $gone = _ForceRemoveWorktreeDir $p
                        if ($gone) { Write-Color "                    removed." DarkGray }
                        _CleanupWorktreeMetadata $p
                        if (-not $gone) {
                            Write-Color "                    WARNING: '$p' still on disk" Red
                            Write-Color "                    likely cause: a shell, IDE, or Explorer window has it open" DarkGray
                        }
                    }
                }
                # ORPHAN-DIRTY entries are silently skipped -- 'gwt list' shows them
                # if you want to see what's lurking; no need to repeat here.
            }

            if ($branchFilter -and -not $filterMatchedWorktree -and -not $orphanMatchFound) {
                Write-Color "  no worktree or orphan named '$branchFilter' in this repo" Yellow
            }
        }
    }

    'focus' {
        # Find the alive claude session(s) matching <Target> and focus their wt
        # window. Target is a substring match against Branch/WorktreePath/WindowName.
        # No args + cwd is inside a worktree -> auto-pick the session for cwd.
        # No args + not in a worktree         -> picker of all alive sessions.
        $sessionDir = $script:SessionDir
        if (-not (Test-Path $sessionDir)) { Write-Color "no session dir at $sessionDir" Yellow; return }

        # If no Target, try to default to whichever worktree contains cwd.
        # Track whether we cwd-resolved so we can offer to spawn one if none alive.
        $cwdResolved = $false
        $cwdWtPath   = $null
        $cwdWtBranch = $null
        $cwdRepo     = $null
        if (-not $Target) {
            $cwd = (Get-Location).Path.Replace('/','\').TrimEnd('\').ToLower()
            try {
                $ctxCwd = Resolve-RepoContext
                foreach ($wt in (Get-WorktreeStatuses $ctxCwd.Src)) {
                    $p = $wt.Path.Replace('/','\').TrimEnd('\').ToLower()
                    if ($cwd -eq $p -or $cwd.StartsWith("$p\")) {
                        $Target      = $wt.Path
                        $cwdResolved = $true
                        $cwdWtPath   = $wt.Path
                        $cwdWtBranch = $wt.Branch
                        $cwdRepo     = $ctxCwd.Repo
                        Write-Color "  (cwd-resolved -> $($wt.Path))" DarkGray
                        break
                    }
                }
            } catch {}
        }

        $procMap = @{}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object {
            $procMap[[int]$_.ProcessId] = $_
        }
        $alive = @()
        foreach ($f in (Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try {
                $e = Get-Content $f.FullName -Raw | ConvertFrom-Json
                if (-not ($e.Pid -and $e.Pid -ne 0)) { continue }
                if (-not $procMap[[int]$e.Pid]) { continue }
                $alive += $e
            } catch {}
        }
        if (-not $alive.Count) { Write-Color "no alive sessions" DarkGray; return }

        # Normalize the path-shaped portion of Target so backslash-vs-forward-slash
        # mismatches don't tank the match. Get-WorktreeStatuses emits forward
        # slashes; registered entries store backslashes.
        $targetAlt = if ($Target) { $Target.Replace('/','\') } else { '' }
        $hits = if ($Target) {
            @($alive | Where-Object {
                $wp = if ($_.WorktreePath) { $_.WorktreePath.Replace('/','\') } else { '' }
                $_.Branch     -like "*$Target*" -or
                $wp           -like "*$targetAlt*" -or
                $_.WindowName -like "*$Target*"
            })
        } else { @($alive) }

        if (-not $hits.Count) {
            Write-Color "no alive sessions match '$Target'" Yellow
            # Special case: we cwd-resolved into a worktree but nothing's alive
            # there. Offer to spawn a fresh claude tab in that worktree.
            if ($cwdResolved -and $cwdWtPath) {
                $r = Read-Host "open a new claude tab for '$cwdWtBranch' here? (y/N)"
                if ($r -match '^[Yy]$') {
                    _ConfirmOpenOrCd -Path $cwdWtPath -Repo $cwdRepo -Branch $cwdWtBranch -PromptOverride $Prompt -AutoOpen:$y
                }
            }
            return
        }
        if ($hits.Count -gt 1) {
            $picked = _TuiSelect -Items $hits `
                -Prompt "multiple alive sessions match -- pick one:" `
                -DisplayScript { param($h) ('{0,-30} [{1}] @ {2}' -f $h.Branch, $h.WindowName, $h.WorktreePath) }
            if (-not $picked) { return }
            $hits = @($picked)
        }
        $h = $hits[0]
        if (-not $h.WindowName) {
            Write-Color "session has no WindowName -- can't focus a wt window" Yellow
            return
        }
        Write-Color "focusing wt window '$($h.WindowName)' (branch=$($h.Branch), pid=$($h.Pid))..." DarkGray
        & runas /user:claude /savecred "wt.exe -w `"$($h.WindowName)`" focus-tab" 2>&1 | Out-Null
    }

    'summary' {
        # Cross-repo worktree summary: count + optional on-disk size.
        # Walks $WorktreeRoot\<host>\<org>\<repo>\<branch>. Each branch dir is a
        # worktree. Group by repo, count. Pass -WithSize to also do the (slow)
        # per-worktree byte walk.
        if (-not (Test-Path $WorktreeRoot)) {
            Write-Color "no worktree root at $WorktreeRoot" Yellow
            return
        }

        # Collect <host, org, repo, branch, path> rows.
        $rows = @()
        foreach ($hostDir in (Get-ChildItem $WorktreeRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($hostDir.Name -in @('sessions','hooks','templates')) { continue }
            foreach ($orgDir in (Get-ChildItem $hostDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                foreach ($repoDir in (Get-ChildItem $orgDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($wtDir in (Get-ChildItem $repoDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                        if ($wtDir.LinkType -eq 'SymbolicLink') { continue }  # 'current' and other shortcuts
                        $rows += [PSCustomObject]@{
                            Host   = $hostDir.Name
                            Org    = $orgDir.Name
                            Repo   = $repoDir.Name
                            Branch = $wtDir.Name
                            Path   = $wtDir.FullName
                        }
                    }
                }
            }
        }

        if (-not $rows.Count) {
            Write-Color "no worktrees found under $WorktreeRoot" Yellow
            return
        }

        # Size walk (parallel across rows for speed). Off by default since it
        # walks every file in every worktree. Opt-in via -WithSize.
        if ($WithSize) {
            Write-Color "scanning $($rows.Count) worktrees for size..." DarkGray
            $sized = $rows | ForEach-Object -Parallel {
                $r = $_
                $bytes = 0L
                try {
                    Get-ChildItem -LiteralPath $r.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                        ForEach-Object { $bytes += $_.Length }
                } catch {}
                $r | Add-Member -NotePropertyName Bytes -NotePropertyValue $bytes -PassThru
            } -ThrottleLimit 8
            $rows = @($sized)
        }

        function _FmtBytes($n) {
            if ($null -eq $n) { return '' }
            if ($n -lt 1KB) { return "$n B" }
            if ($n -lt 1MB) { return "{0:N1} KB" -f ($n / 1KB) }
            if ($n -lt 1GB) { return "{0:N1} MB" -f ($n / 1MB) }
            return "{0:N2} GB" -f ($n / 1GB)
        }

        # Group by host/org/repo. When sizes are present, sort by total size
        # desc; otherwise sort by count desc.
        $groups = $rows |
            Group-Object @{Expression={ "$($_.Host)/$($_.Org)/$($_.Repo)" }} |
            ForEach-Object {
                [PSCustomObject]@{
                    Key    = $_.Name
                    Count  = $_.Group.Count
                    Bytes  = if ($WithSize) { ($_.Group | Measure-Object -Property Bytes -Sum).Sum } else { $null }
                    Items  = if ($WithSize) { $_.Group | Sort-Object Bytes -Descending } else { $_.Group | Sort-Object Branch }
                }
            } | Sort-Object @{Expression = { if ($WithSize) { $_.Bytes } else { $_.Count } }} -Descending

        Write-Host ""
        Write-Color "worktree summary @ $WorktreeRoot" Cyan
        Write-Host ""
        foreach ($g in $groups) {
            if ($WithSize) {
                Write-Color ("  {0,-50} {1,3} wt   {2,10}" -f $g.Key, $g.Count, (_FmtBytes $g.Bytes)) White
                foreach ($it in $g.Items) {
                    Write-Color ("    {0,-50} {1,10}" -f $it.Branch, (_FmtBytes $it.Bytes)) DarkGray
                }
            } else {
                Write-Color ("  {0,-50} {1,3} wt" -f $g.Key, $g.Count) White
                foreach ($it in $g.Items) {
                    Write-Color ("    {0}" -f $it.Branch) DarkGray
                }
            }
        }

        $totalCount = $rows.Count
        $repoCount  = $groups.Count
        Write-Host ""
        if ($WithSize) {
            $totalBytes = ($rows | Measure-Object -Property Bytes -Sum).Sum
            Write-Color ("TOTAL: $totalCount worktrees across $repoCount repos, " + (_FmtBytes $totalBytes)) Green
        } else {
            Write-Color "TOTAL: $totalCount worktrees across $repoCount repos  (pass -WithSize for on-disk totals)" Green
        }
    }

    'rehook' {
        # Re-run the per-repo worktree hook against every existing worktree of
        # the current repo. Useful after the hook itself changes (e.g., we
        # switched CMakeUserPresets.json from Copy-Item to a symlink and want
        # all pre-existing worktrees to get the upgrade with confirmation).
        $ctx     = Resolve-RepoContext
        $allWts  = @(Get-WorktreeStatuses $ctx.Src)
        $targets = @($allWts | Where-Object { $_.Status -ne 'MAIN' })
        if (-not $targets.Count) {
            Write-Color "no non-main worktrees in this repo -- nothing to do" DarkGray
            return
        }
        Write-Color "re-running hook for $($targets.Count) worktree(s) in $($ctx.Org)/$($ctx.Repo):" Cyan
        foreach ($wt in $targets) {
            Write-Host ""
            Write-Color ">>> $($wt.Branch) @ $($wt.Path)" Cyan
            _InvokeGwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wt.Path -RemoteHost $ctx.RemoteHost
        }
    }

    'rename' {
        # gwt rename <match> <new-label> [-Window <name>] [-Name <branch>]
        # Set a display Label on a session entry so the 'gwt sessions' listing
        # shows the label instead of the (often duplicated) branch name.
        # Pass an empty new-label ("") to clear the label.
        if (-not $Target -or $null -eq $Match) {
            Write-Color "usage: gwt rename <match> <new-label> [-Window <name>] [-Name <branch>]" Yellow
            return
        }
        $patternArg = $Target
        $newLabel   = $Match

        $sessionDir = $script:SessionDir
        if (-not (Test-Path $sessionDir)) { Write-Color "no session dir at $sessionDir" Yellow; return }

        $files = @(Get-ChildItem $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue)
        $candidates = @()
        foreach ($f in $files) {
            try {
                $obj = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $obj | Add-Member -NotePropertyName _File -NotePropertyValue $f.FullName -Force
                $candidates += $obj
            } catch {}
        }

        # Match strategy: exact-Branch match first (avoids "main" hitting "maintenance").
        # Only fall back to substring across Branch/WorktreePath/WindowName when
        # no exact branch matches exist.
        $hits = @($candidates | Where-Object { $_.Branch -ieq $patternArg })
        if (-not $hits.Count) {
            $hits = @($candidates | Where-Object {
                $_.Branch       -like "*$patternArg*" -or
                $_.WorktreePath -like "*$patternArg*" -or
                $_.WindowName   -like "*$patternArg*"
            })
            if ($hits.Count) {
                Write-Color "  (no exact branch match for '$patternArg' -- using substring fallback)" DarkGray
            }
        }
        if ($Name)   { $hits = @($hits | Where-Object { $_.Branch     -ieq $Name }) }
        if ($Window) { $hits = @($hits | Where-Object { $_.WindowName -ieq $Window }) }

        if (-not $hits.Count) {
            Write-Color "no session entries match '$patternArg'" Yellow
            return
        }
        if ($hits.Count -gt 1) {
            $picked = _TuiSelect -Items $hits `
                -Prompt "multiple matches -- pick one:" `
                -DisplayScript { param($h) ('{0,-30} [{1}] @ {2}' -f $h.Branch, $h.WindowName, $h.WorktreePath) }
            if (-not $picked) { return }
            $hits = @($picked)
        }

        $entry = $hits[0]
        $e = Get-Content $entry._File -Raw | ConvertFrom-Json
        if ([string]::IsNullOrEmpty($newLabel)) {
            if ($e.PSObject.Properties.Match('Label').Count) { $e.PSObject.Properties.Remove('Label') }
            Write-Color "  cleared label on $($entry.Branch) @ $($entry.WorktreePath)" DarkGray
        } else {
            if ($e.PSObject.Properties.Match('Label').Count) { $e.Label = $newLabel }
            else { Add-Member -InputObject $e -NotePropertyName Label -NotePropertyValue $newLabel -Force }
            Write-Color "  renamed: '$($entry.Branch)' -> '$newLabel'  @ $($entry.WorktreePath)" Green
        }
        ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $entry._File -Encoding UTF8
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
        Write-Host "        shorthand -- bare URL auto-routes:" -ForegroundColor DarkGray
        Write-Host "          .../pull/<num>          -> 'pr' (worktree for that PR)" -ForegroundColor DarkGray
        Write-Host "          .../issues/<num>        -> 'issue' (worktree branched off main, named issue-<num>)" -ForegroundColor DarkGray
        Write-Host "          .../<org>/<repo>        -> 'clone' (clone if missing, open main)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt update-registry" -ForegroundColor Cyan
        Write-Host "        fetch fallback gwt-session-registry.ps1 from github into ~\.gwt\" -ForegroundColor DarkGray
        Write-Host "        (no-op if dotfiles repo is cloned -- update via git pull instead)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt current " -NoNewline -ForegroundColor Cyan
        Write-Host "[. | <branch>]"
        Write-Host "        manage the <WtRoot>\current symlink (IDE-pinned active worktree)" -ForegroundColor DarkGray
        Write-Host "        no arg    print what 'current' points at" -ForegroundColor DarkGray
        Write-Host "        .         repoint to whatever worktree contains cwd" -ForegroundColor DarkGray
        Write-Host "        <branch>  repoint to that branch's worktree" -ForegroundColor DarkGray
        Write-Host "        also: 'gwt cd current' to cd into whatever it points at" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt focus " -NoNewline -ForegroundColor Cyan
        Write-Host "[<match>]"
        Write-Host "        bring an alive claude session's wt window forward" -ForegroundColor DarkGray
        Write-Host "        <match>  substring against Branch / WorktreePath / WindowName" -ForegroundColor DarkGray
        Write-Host "        no arg   prompts a picker of all alive sessions" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt summary " -NoNewline -ForegroundColor Cyan
        Write-Host "[-WithSize]"
        Write-Host "        count every worktree under $WorktreeRoot, grouped by repo" -ForegroundColor DarkGray
        Write-Host "        -WithSize  also walk each tree for byte totals (slow)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt sessions " -NoNewline -ForegroundColor Cyan
        Write-Host "[list | restore | close | clean | save | unsave] [<match>] [flags]"
        Write-Host "        manage registered Claude sessions across windows + repos" -ForegroundColor DarkGray
        Write-Host "        states: ACTIVE (pid alive) / PAUSED (pid dead, worktree on disk) /" -ForegroundColor DarkGray
        Write-Host "                STALE (pid dead, worktree gone) / SAVED (protected from clean)" -ForegroundColor DarkGray
        Write-Host "        run 'gwt sessions list -Usage' for the per-subcommand cheat sheet" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt rename " -NoNewline -ForegroundColor Cyan
        Write-Host "<match> <new-label> [-Name <branch>] [-Window <name>]"
        Write-Host "        set a display label on a session entry (git branch untouched)" -ForegroundColor DarkGray
        Write-Host "        empty <new-label> (\"\") clears the label" -ForegroundColor DarkGray
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
        Write-Host "(alias: list) [-All] [-Verbose|-v]"
        Write-Host "        list registered sessions, scoped to the current repo by default" -ForegroundColor DarkGray
        Write-Host "        -All       show sessions across every repo (auto when run outside a repo)" -ForegroundColor DarkGray
        Write-Host "        -Verbose|-v  inline 'git status --short' for DIRTY rows" -ForegroundColor DarkGray
        Write-Host "          [MAIN            ] -- primary clone" -ForegroundColor DarkGray
        Write-Host "          [ACTIVE          ] -- branch is in-progress (has upstream OR has local commits with no upstream)" -ForegroundColor Green
        Write-Host "          [ACTIVE-REMOTE-GONE]  -- branch HAD an upstream; remote ref now deleted; you still have commits not in main" -ForegroundColor DarkYellow
        Write-Host "          [PRUNE           ] -- safe to delete (merged, remote deleted, or path missing)" -ForegroundColor Red
        Write-Host "          [DIRTY           ] -- uncommitted local changes (tracked edits and/or untracked files)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    gwt changes " -NoNewline -ForegroundColor Cyan
        Write-Host "(alias: status)"
        Write-Host "        for every dirty worktree in this repo, show 'git status --short'" -ForegroundColor DarkGray
        Write-Host "        (includes ORPHAN-DIRTY dirs that aren't registered with git)" -ForegroundColor DarkGray
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
