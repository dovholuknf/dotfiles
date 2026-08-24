# git-worktree.ps1 -- unified worktree lifecycle manager
#
# profile alias: function gwt { & "$env:ON_PATH\git-worktree.ps1" @args }
#
# usage:
#   gwt new  <branch> [-From <source>] [-Prompt <str>] [-y] [--by-project]
#                                                # --by-project: group the tab into a
#                                                # window named after the repo, themed
#                                                # from the per-repo theme map
#   gwt twig <branch>                 [-Prompt <str>] [-y]  # branch off current worktree's HEAD
#   gwt pr  <url-or-number>           [-Prompt <str>] [-y]
#   gwt rm  <branch>                  [-y]
#   gwt ls
#   gwt prune                         [-y]          # current repo, all worktrees
#   gwt prune <branch>                [-y]          # current repo, one worktree
#   gwt prune -Org <org> [-Repo <r>]  [-y]          # whole org (or one repo)
#   gwt cd  <branch>                                # cd to that branch's worktree (needs profile wrapper)
#   gwt rehome <branch>               [-Prompt <s>] # re-home THIS tab onto another worktree + relaunch claude
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
    [string]$Lts,           # 'backport': target LTS line -- 'active' (newest release-v*.x) or 'maint' (next); or a release-vN.M.x name. Omit to be prompted.
    [string]$Org,
    [string]$Repo,
    [string]$RemoteHost,    # explicit host (e.g. 'github.com', 'bitbucket.org') -- for callers that don't have a git remote to detect from
    [string]$Prompt,
    [string]$SourceRoot    = $( $r = if ($env:GIT_ROOT)      { $env:GIT_ROOT }      else { 'D:\git' };      ($r -replace '\\+','\').TrimEnd('\') ),
    [string]$WorktreeRoot  = $( $r = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT } else { 'D:\worktrees' }; ($r -replace '\\+','\').TrimEnd('\') ),
    [switch]$y,
    [switch]$Current,       # 'new': skip the activate prompt and point <WtRoot>\current at the new worktree
    [switch]$Force,         # 'prune': also include DIRTY worktrees (otherwise they're protected)
    [switch]$Reselect,      # force re-prompt instead of reusing saved picks
    [switch]$NoAgentSetup,  # skip the post-create dotagents CLAUDE.md symlink step
    # 'new': group the spawned wt tab into a window named after the project (repo)
    # instead of a work-type window (active-work / tangent / ...). The spawned
    # shell themes itself from the per-repo theme map (e.g. ziti -> teal-dusk).
    [Alias('by-project')]
    [switch]$ByProject,
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
    [switch]$Fetch,         # 'prune': force a fresh fetch, ignoring the recent-fetch cache
    [string]$Window,        # 'sessions restore' override / 'sessions save|unsave|clean' exact-window filter
    [string]$Name,          # 'sessions save|unsave|clean|restore' exact-branch filter
    [switch]$Usage,         # 'sessions list': show the verbose command-tips block
    [string]$SortBy,        # 'sessions usage': cost|tokens|recent (default: cost)
    [switch]$DryRun,        # 'sessions clean' / 'restore': preview targets without acting
    [switch]$IncludeEnded,  # 'sessions list' / 'restore': also show/restore ENDED entries (default: hidden)
    [int]$MaxAgeDays = 7,   # 'sessions restore': skip sessions last active > N days ago (0 = no limit)
    [switch]$ByTabs,        # 'sessions restore': force the .tabs-layout mode (default; skips the picker)
    [switch]$BySessions,    # 'sessions restore': force the open-order + window-prompt mode (skips the picker)
    [switch]$ExcludeActive, # 'sessions restore': drop currently-running sessions from the set (default: include them)
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
    # Prefer git: if cwd is inside a work tree, derive host/org/repo from origin's
    # URL. This is correct no matter how the clone is nested (e.g. a non-standard
    # <git-root>\github\openziti\nf\ziti), unlike counting path segments. Fall back
    # to the path arithmetic below when there is no repo / no origin (e.g. sitting
    # at a bare worktree root with no branch checked out yet).
    try {
        $origin = (& git remote get-url origin 2>$null | Out-String).Trim()
        if ($origin) {
            $u = $origin -replace '\.git$', ''
            $h = $null; $rest = $null
            if     ($u -match '^[^@/]+@([^:]+):(.+)$')                 { $h = $Matches[1]; $rest = $Matches[2] }
            elseif ($u -match '^[a-z][a-z0-9+.-]*://(?:[^@/]+@)?([^/]+)/(.+)$') { $h = $Matches[1]; $rest = $Matches[2] }
            if ($h -and $rest) {
                $segs = @(($rest -split '/') | Where-Object { $_ })
                if ($segs.Count -ge 2) {
                    $shortHost = switch ($h) {
                        'github.com'    { 'github' }
                        'bitbucket.org' { 'bitbucket' }
                        'gitlab.com'    { 'gitlab' }
                        default         { $h }
                    }
                    $o = $segs[0]; $r = $segs[-1]
                    return @{
                        Host     = $shortHost
                        Org      = $o
                        Repo     = $r
                        MainPath = (Join-Path (Join-Path (Join-Path $script:GitRoot $shortHost) $o) $r)
                        WtBase   = (Join-Path (Join-Path (Join-Path $script:WtRoot  $shortHost) $o) $r)
                    }
                }
            }
        }
    } catch {}

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
    # When stdout is redirected ('> file', '| grep'), emit to the success stream so
    # the output can actually be captured. Write-Host paints the console directly and
    # is invisible to both redirects and pipes. Interactive: keep the colored output.
    if ([Console]::IsOutputRedirected) { Write-Output $Text }
    else { Write-Host $Text -ForegroundColor $Color }
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

function script:_SessionJournal {
    # Given a claude session id, find its transcript jsonl and return the last real
    # user message ("where you left off") plus the jsonl mtime (last activity). The
    # jsonl map is built once per gwt run and cached. Returns $null if not found.
    param([string]$ClaudeSessionId)
    if (-not $ClaudeSessionId) { return $null }
    if (-not $script:_JournalMap) {
        $script:_JournalMap = @{}
        # Claude-code transcripts live under the account that ran them (the claude
        # account hosts claude-code), so scan every user profile's projects dir, not
        # just the current user's. clint runs gwt as an admin and can read them.
        $usersRoot = Split-Path $env:USERPROFILE -Parent
        $projDirs  = foreach ($u in (Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue)) {
            $p = Join-Path $u.FullName '.claude\projects'
            if (Test-Path $p) { $p }
        }
        foreach ($proj in $projDirs) {
            foreach ($jf in (Get-ChildItem $proj -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
                             Where-Object { $_.Directory.Name -ne 'subagents' })) {
                $id = $jf.BaseName
                if (-not $script:_JournalMap.ContainsKey($id) -or $jf.LastWriteTime -gt $script:_JournalMap[$id].LastWriteTime) {
                    $script:_JournalMap[$id] = $jf
                }
            }
        }
    }
    $jf = $script:_JournalMap[$ClaudeSessionId]
    if (-not $jf) { return $null }
    $msg = $null
    foreach ($line in Get-Content $jf.FullName) {
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.type -eq 'user' -and $o.message.role -eq 'user') {
            $c = $o.message.content
            if ($c -is [string]) { $t = $c }
            else { $t = ($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
            if ($t -and $t -notmatch '^<' -and $t.Trim()) { $msg = $t }
        }
    }
    if ($msg) { $msg = ($msg -replace '\s+',' ').Trim() }
    [pscustomobject]@{ LastActive = $jf.LastWriteTime; LastMsg = $msg }
}

function _SelectTargetRepo {
    # Picker for the discourse/zendesk "which repo does this belong to?" prompt.
    # Most-likely repos first, default pre-highlighted, plus a 'custom' row that
    # falls back to free text (org/repo or host:org/repo). Uses the shared
    # _TuiSelect so it matches every other list in the toolkit.
    param([string]$Default = 'openziti/ziti')
    $common = @(
        'openziti/ziti'
        'openziti/ziti-tunnel-sdk-c'
        'openziti/ziti-sdk-c'
        'openziti/desktop-edge-win'
        'openziti/ziti-sdk-csharp'
    )
    if ($Default -and ($common -notcontains $Default)) { $common = @($Default) + $common }
    $custom = 'custom (type org/repo or host:org/repo)...'
    $items  = @($common + $custom)
    $defIdx = [Array]::IndexOf($items, $Default); if ($defIdx -lt 0) { $defIdx = 0 }
    $picked = _TuiSelect -Items $items -Prompt 'target repo:' -DefaultIndex $defIdx
    if (-not $picked) { return $null }   # cancelled
    if ($picked -eq $custom) {
        $resp = (Read-Host "  enter repo (org/repo, or host:org/repo)").Trim()
        if (-not $resp) { return $Default }
        return $resp
    }
    return $picked
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
    param([switch]$QuietLayout)   # suppress the off-layout warning for pure-navigate callers (e.g. 'gwt cd')
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
    if (-not $QuietLayout -and -not $script:WarnedLayout -and $script:OrgRepoFromCwd) {
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
    if (-not (Test-Path $Src)) {
        # No local clone: we cannot proceed offline, so this stays fatal.
        $url = "git@${RemoteHost}:$Org/$Repo.git"
        # Verify the remote is actually a reachable git repo BEFORE cloning. A
        # non-git URL (e.g. a product page routed here as host/org/repo) otherwise
        # sends git into an ssh clone that blocks on a host-key / auth prompt and
        # swallows Ctrl-C. BatchMode + no terminal prompt + a short connect timeout
        # makes ls-remote fail fast instead of hanging.
        $prevSsh    = $env:GIT_SSH_COMMAND
        $prevPrompt = $env:GIT_TERMINAL_PROMPT
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GIT_SSH_COMMAND     = 'ssh -oBatchMode=yes -oConnectTimeout=8 -oStrictHostKeyChecking=accept-new'
        try {
            & git ls-remote $url 2>&1 | Out-Null
            $reachable = ($LASTEXITCODE -eq 0)
        } finally {
            if ($null -ne $prevSsh)    { $env:GIT_SSH_COMMAND     = $prevSsh }    else { Remove-Item Env:GIT_SSH_COMMAND     -ErrorAction SilentlyContinue }
            if ($null -ne $prevPrompt) { $env:GIT_TERMINAL_PROMPT = $prevPrompt } else { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
        }
        if (-not $reachable) {
            throw "not a git repo: $url is not reachable as a git repository (is '$RemoteHost/$Org/$Repo' really a git URL?)"
        }
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Src)) | Out-Null
        & git clone $url $Src 2>&1
        if ($LASTEXITCODE -ne 0) { throw "clone failed: $url" }
    } else {
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Src)) | Out-Null
    }
    # Repo already on disk -- updating is best-effort. A fetch/pull failure
    # (offline, VPN down, auth) shouldn't block working on what's local. Ask.
    try {
        Invoke-Git $Src @('fetch','origin','--prune')
        Invoke-Git $Src @('checkout','main')
        Invoke-Git $Src @('pull','--ff-only','origin','main')
    } catch {
        Write-Color "  could not update from origin: $($_.Exception.Message)" Yellow
        $r = if ($script:y) { 'y' } else { Read-Host "  continue with the local copy as-is? (Y/n)" }
        if ($r -match '^[Nn]') { throw "aborted -- repo not updated" }
        Write-Color "  continuing with local copy (may be stale)" DarkGray
    }
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
    param([string]$Org, [string]$Repo, [string]$PrNumber, [string]$RemoteHost = 'github.com')
    if ($RemoteHost -eq 'bitbucket.org') {
        # Bitbucket exposes no PR git ref, so a PR number can't be mapped to a branch
        # from git alone. Two paths, both ending in a plain SSH fetch of that branch:
        #   API creds present -> bbapi resolves the source branch automatically.
        #   no creds          -> list remote heads over SSH (token-free) and pick one.
        if ($env:BB_EMAIL -and $env:BB_TOKEN) {
            $pr = bbapi "repositories/$Org/$Repo/pullrequests/$PrNumber"
            $b  = "$($pr.source.branch.name)"
            if (-not $b) { throw "bbapi: couldn't resolve source branch for PR $PrNumber (PR exists?)" }
            # Fork PRs live in a different source repo -- origin won't have the branch.
            $srcRepo = "$($pr.source.repository.full_name)"
            if ($srcRepo -and ($srcRepo -ine "$Org/$Repo")) {
                throw "PR $PrNumber is from a fork ($srcRepo) -- fork PRs aren't wired yet. Clone the fork or fetch the branch manually."
            }
            return $b
        }
        # No API creds: git already sees every branch, so pick the PR's source branch.
        Write-Color "PR #${PrNumber}: no Bitbucket API creds and no PR git ref -- pick the PR's source branch:" Yellow
        $raw   = & git ls-remote --heads "git@$RemoteHost`:$Org/$Repo.git" 2>$null
        $names = @($raw | ForEach-Object { if ($_ -match 'refs/heads/(.+)$') { $Matches[1] } } | Where-Object { $_ } | Sort-Object)
        if (-not $names.Count) { throw "couldn't list remote branches for $Org/$Repo over SSH (auth or network?)" }
        $picked = _TuiSelect -Items $names -Prompt "source branch for PR #${PrNumber}:"
        if (-not $picked) { throw "cancelled -- no branch picked for PR $PrNumber" }
        return $picked
    }
    $r = (& gh pr view $PrNumber --repo "$Org/$Repo" --json headRefName -q .headRefName 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "gh pr view failed for PR ${PrNumber}: $r" }
    return $r
}

function Sync-PrBranch {
    param([string]$Src, [string]$Branch, [string]$PrNumber, [string]$RemoteHost = 'github.com')
    if ($RemoteHost -eq 'bitbucket.org') {
        # Bitbucket has no refs/pull/<n>/head, so fetch the source branch by name.
        # Works for open PRs; a merged PR whose source branch was deleted can't be
        # fetched this way (say so rather than failing cryptically).
        try {
            # ${Branch} delimits the name: bare "$Branch:" parses as a scope qualifier
            # and eats the colon, producing a garbage refspec.
            Invoke-Git $Src @('fetch','origin',"+refs/heads/${Branch}:refs/heads/${Branch}")
        } catch {
            throw "couldn't fetch branch '$Branch' from origin. If the PR is merged and its branch was deleted, Bitbucket keeps no pull-head ref -- restore the branch or check out the merge commit manually."
        }
        return
    }
    # Fetch the PR head by its pull ref. 'fetch origin <branch>' fails with
    # "couldn't find remote ref" whenever origin lacks that branch: a merged PR
    # whose branch was deleted, or a PR from a fork. GitHub keeps refs/pull/<n>/head
    # in both cases, so this always resolves. Forced (+) so an existing local
    # branch updates to the current PR head.
    Invoke-Git $Src @('fetch','origin',"+refs/pull/$PrNumber/head:refs/heads/$Branch")
}

function _ResolveLtsBranch {
    # Map the symbolic LTS names to a real release branch, resolved LIVE so they don't
    # rot: 'active' = highest release-vN.M.x on origin, 'maint' = the next one down.
    # Also accepts a literal release-vN.M.x. Empty -Lts -> interactive picker.
    param([string]$Src, [string]$Lts)
    $raw = @(Invoke-GitCapture $Src @('for-each-ref', '--format=%(refname:short)', 'refs/remotes/origin/release-v*'))
    $rel = @()
    foreach ($r in $raw) {
        $name = ($r -replace '^origin/', '')
        if ($name -match '^release-v(\d+)\.(\d+)\.x$') {
            $rel += [pscustomobject]@{ Name = $name; Ver = [version]::new([int]$Matches[1], [int]$Matches[2]) }
        }
    }
    $rel = @($rel | Sort-Object Ver -Descending)
    if (-not $rel.Count) { throw "no release-vN.M.x branches on origin -- is the repo fetched?" }
    $active = $rel[0].Name
    $maint  = if ($rel.Count -ge 2) { $rel[1].Name } else { $null }

    switch ("$Lts".Trim().ToLower()) {
        'active'      { return $active }
        'maint'       { if ($maint) { return $maint } else { throw "only one release line ($active) -- no maint LTS" } }
        'maintenance' { if ($maint) { return $maint } else { throw "only one release line ($active) -- no maint LTS" } }
        '' {
            $items = @([pscustomobject]@{ Label = "active LTS  ($active)"; Branch = $active })
            if ($maint) { $items += [pscustomobject]@{ Label = "maint LTS   ($maint)"; Branch = $maint } }
            foreach ($r in ($rel | Select-Object -Skip 2)) { $items += [pscustomobject]@{ Label = "            $($r.Name)"; Branch = $r.Name } }
            $pick = _TuiSelect -Items $items -Prompt 'backport target LTS:' -DisplayScript { param($i) $i.Label } -DefaultIndex 0
            if (-not $pick) { throw "cancelled -- no backport target picked" }
            return $pick.Branch
        }
        default {
            $hit = @($rel | Where-Object { $_.Name -ieq $Lts })
            if ($hit.Count) { return $hit[0].Name }
            throw "unknown -Lts '$Lts' -- use 'active' ($active), 'maint' ($maint), or a release-vN.M.x name"
        }
    }
}

function _RehomeSessionEntry {
    # Re-point THIS tab's session-ledger entry (matched by WT_SESSION) at a new
    # worktree, so the SessionStart hook claims it with the right path/branch when
    # claude relaunches in the same tab. The hook matches by WtSession first and
    # preserves WorktreePath, so without this a re-homed tab would keep showing
    # its old worktree. Best-effort: no WT_SESSION or no match means nothing to
    # update (the hook then creates a fresh entry keyed on cwd). Returns $true if
    # an entry was patched.
    param(
        [string]$WtSession,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Repo
    )
    if (-not $WtSession) { return $false }
    if (-not (Test-Path $script:SessionDir)) { return $false }
    foreach ($f in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $e = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($e.WtSession -ne $WtSession) { continue }
            $e.WorktreePath = $WorktreePath
            $e.Branch       = $Branch
            $e.Repo         = $Repo
            ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $f.FullName -Encoding UTF8
            return $true
        } catch {}
    }
    return $false
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
    # Set-Location moves $PWD but NOT the process's real Win32 working directory,
    # which is what holds an OS handle on the dir. If this shell was launched in
    # the worktree, that handle keeps the dir locked and removal fails. Move the
    # actual process cwd too so this shell stops locking its own target.
    [Environment]::CurrentDirectory = $MainPath
    _SetGwtCwdHint $MainPath
}

function _ForceRemoveWorktreeDir {
    # Robust dir removal. Returns $true if gone after; $false if it persists.
    # Steps: best-effort Remove-Item, then a pass that clears readonly attributes
    # on every child first (common cause of "still on disk"), then a short retry
    # loop for handles a just-exited process is slow to release. Never throws --
    # caller decides how to surface a lingering directory.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    _AssertUnderWorktreeRoot $Path
    # If THIS process's real working directory is at/under the target, it holds an
    # OS handle on the dir and removal will fail. $PWD is not the lock -- the Win32
    # cwd ([Environment]::CurrentDirectory) is, and Set-Location never moves it.
    # Drop it to the drive root so this shell stops locking its own target. gwt
    # runs in-process with the interactive shell, so this releases that shell too.
    $envCwd = [Environment]::CurrentDirectory
    if ($envCwd) {
        $e = $envCwd.Replace('/','\').TrimEnd('\').ToLower()
        $t = $Path.Replace('/','\').TrimEnd('\').ToLower()
        if ($e -eq $t -or $e.StartsWith("$t\")) {
            [Environment]::CurrentDirectory = (Split-Path $Path -Qualifier) + '\'
        }
    }
    try { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    if (-not (Test-Path $Path)) { return $true }
    # Second pass: strip readonly attrs, then retry a few times with a short wait.
    for ($attempt = 0; $attempt -lt 3 -and (Test-Path $Path); $attempt++) {
        try {
            Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
            Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
        if (Test-Path $Path) { Start-Sleep -Milliseconds 300 }
    }
    return -not (Test-Path $Path)
}

function _FindFileLocksmithCli {
    # Locate PowerToys' FileLocksmithCLI.exe. Returns $null if PowerToys isn't
    # installed. This is the same engine the File Locksmith right-click uses.
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\PowerToys")) {
        if (-not $base) { continue }
        $exe = Join-Path $base 'PowerToys\FileLocksmithCLI.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function _ReportDirHolders {
    # Name what is keeping $Path locked, using PowerToys' File Locksmith engine
    # (Restart Manager) when present. Note: run non-elevated it only sees holders
    # in the same user session -- a lock held by another user (or elevated) shows
    # nothing here even though it's real.
    param([Parameter(Mandatory)][string]$Path)
    $winPath = $Path.Replace('/','\').TrimEnd('\')

    $alive = Get-AliveSessionForPath $Path
    if ($alive) {
        Write-Color "    held by claude session: branch=$($alive.Branch) window=$($alive.WindowName) pid=$($alive.Pid)" Yellow
        Write-Color "    close that tab (or 'gwt focus $($alive.Branch)' then exit), then retry" DarkGray
    }

    # File Locksmith naming is the slow part (Restart Manager scan), so ask before
    # running it. $y auto-accepts.
    $cli = _FindFileLocksmithCli
    if (-not $cli) {
        if (-not $alive) {
            Write-Color "    install PowerToys to auto-name the locking process (File Locksmith), or" DarkGray
            Write-Color "    check for a shell/editor/Explorer window whose folder is that worktree" DarkGray
        }
        return
    }
    $run = $script:y -or (($r = Read-Host "    run File Locksmith to name the holding process? (slow) (y/N)") -match '^[Yy]')
    if (-not $run) { return }

    $reported = $false
    try {
        $out  = & $cli --json $winPath 2>$null | Out-String
        $data = $out | ConvertFrom-Json
        foreach ($p in @($data.processes)) {
            # The probe itself opens a handle on the path while scanning -- don't
            # finger File Locksmith (or this gwt process) as the culprit.
            if ($p.name -eq 'FileLocksmithCLI.exe' -or [int]$p.pid -eq $PID) { continue }
            $reported = $true
            Write-Color "    locked by: $($p.name) (pid $($p.pid), user $($p.user))" Yellow
            Write-Color "    if it's safe to kill: & '$cli' --kill '$winPath'" DarkGray
        }
    } catch {}
    if (-not $reported) {
        Write-Color "    File Locksmith found no holder in this user session -- a process in" DarkGray
        Write-Color "    another user's session or an elevated one may hold it (re-run elevated to see it)" DarkGray
    }
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

function _FetchOriginCached {
    # Fetch origin (prune, no tags) unless it was already fetched within the TTL.
    # The merged / remote-gone classification needs origin reasonably fresh, but
    # not re-fetched on every gwt call. Stamp lives in .git (per-repo). -Force
    # bypasses the cache; -NoFetch skips entirely.
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$NoFetch,
        [switch]$Force,
        [int]$TtlSeconds = 300
    )
    if ($NoFetch) { Write-Color "  skipping fetch (-NoFetch)" DarkGray; return }
    $stamp = Join-Path $RepoPath '.git\gwt-last-fetch'
    if (-not $Force -and (Test-Path $stamp)) {
        $age = ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds
        if ($age -lt $TtlSeconds) {
            Write-Color ("  origin fetched {0:N0}s ago, skipping (-Fetch to force)" -f $age) DarkGray
            return
        }
    }
    Write-Color "  fetching origin..." DarkGray
    & git -C $RepoPath fetch --prune --no-tags origin 2>&1 | Out-Null
    try { Set-Content -Path $stamp -Value (Get-Date).ToString('o') -ErrorAction SilentlyContinue } catch {}
}

function _GetProcMapCached {
    # Win32_Process enumeration is ~1.9s warm. Callers in a prune loop hit this
    # repeatedly, so cache the map for the lifetime of this gwt invocation (a
    # fresh process per call -- liveness can't meaningfully change mid-run).
    if ($null -eq $script:_ProcMapCache) {
        Write-Color "  checking running processes..." DarkGray
        $script:_ProcMapCache = @{}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object {
            $script:_ProcMapCache[[int]$_.ProcessId] = $_
        }
    }
    return $script:_ProcMapCache
}

function _IsPidAlive {
    # Fast, cross-user liveness via kernel32 OpenProcess -- no WMI/CIM, so no ~2s
    # connection floor. Returns $true/$false, or $null if the P/Invoke can't be set
    # up (caller then falls back to CIM). A live PID returns a handle; if it exists
    # but we lack rights, OpenProcess fails with ERROR_ACCESS_DENIED (5), which STILL
    # means alive. ERROR_INVALID_PARAMETER (87) is the only "no such process" signal.
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    if (-not ('Gwt.Proc' -as [type])) {
        try {
            Add-Type -Namespace Gwt -Name Proc -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint pid);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(System.IntPtr h);
'@ -ErrorAction Stop
        } catch { return $null }
    }
    # PROCESS_QUERY_LIMITED_INFORMATION = 0x1000 (least-privileged, usually granted).
    $h = [Gwt.Proc]::OpenProcess(0x1000, $false, [uint32]$ProcessId)
    if ($h -ne [IntPtr]::Zero) { [void][Gwt.Proc]::CloseHandle($h); return $true }
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -eq 5) { return $true }   # access denied -> exists
    return $false                       # 87 (and anything else) -> treat as dead
}

function Get-AliveSessionForPath {
    # Return the alive session-registry entry whose WorktreePath matches the given
    # path (case-insensitive, normalized). Returns $null if none. Used by destructive
    # ops to warn before nuking a worktree someone has claude open in.
    param([string]$WorktreePath)
    $sessionDir = $script:SessionDir
    if (-not $WorktreePath -or -not (Test-Path $sessionDir)) { return $null }
    $norm = ($WorktreePath -replace '/', '\').TrimEnd('\').ToLower()
    $procMap = _GetProcMapCached
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
    # git emits forward slashes; junctions want native backslash paths, and the
    # printed target should match the Windows-style link path.
    $WorktreePath = ($WorktreePath -replace '/', '\').TrimEnd('\')
    if (-not (Test-Path $WtRoot)) {
        [System.IO.Directory]::CreateDirectory($WtRoot) | Out-Null
    }
    $link = Join-Path $WtRoot 'current'
    if (Test-Path $link) {
        # Delete the reparse point ONLY. Remove-Item on a directory junction
        # whose target has children triggers PowerShell's "has children, Recurse
        # not specified" confirm, and answering Y follows the junction and
        # deletes the TARGET's contents. Directory.Delete removes just the link.
        try {
            $li = Get-Item $link -Force
            if ($li.LinkType -in 'SymbolicLink','Junction') {
                [System.IO.Directory]::Delete($link)
            } else {
                Remove-Item $link -Force -ErrorAction Stop
            }
        } catch {
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
        # Directory.Delete drops just the reparse point (see _SetCurrentSymlink).
        try { [System.IO.Directory]::Delete($link) } catch { Remove-Item $link -Force -ErrorAction SilentlyContinue }
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

function _ShellIsInside {
    # True when the invoking shell's current directory is AT or UNDER the given
    # path. Used to skip destructive prompts (e.g. 'remove this worktree?') that
    # would fail anyway because the process cwd holds an open handle on the dir.
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Path) { return $false }
    $target = ($Path -replace '/', '\').TrimEnd('\').ToLower()
    $cwd    = ((Get-Location).Path -replace '/', '\').TrimEnd('\').ToLower()
    return ($cwd -eq $target) -or $cwd.StartsWith($target + '\')
}

function _SetGwtCwdHint {
    # Drop a hint file the gwt profile wrapper reads after the script exits, so it
    # can Set-Location the parent shell into the newly-created worktree. Keyed on
    # $PID so concurrent gwt calls don't trample each other.
    param([string]$Path)
    # _ConfirmOpenOrCd sets this when the user declined to move -- honor it once.
    if ($global:_GwtSuppressCd) { $global:_GwtSuppressCd = $false; return }
    if (-not $Path) { return }
    try {
        $hintFile = if ($env:GWT_HINT_FILE) { $env:GWT_HINT_FILE } `
                    else { Join-Path $env:TEMP "gwt-cwd-hint-$PID.txt" }
        Set-Content -Path $hintFile -Value $Path -Encoding UTF8 -NoNewline
    } catch {}
}

if (-not ('Gwt.Win' -as [type])) {
    Add-Type -Namespace Gwt -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
'@
}
function _RefocusSelfWindow {
    # 'wt focus-tab' foregrounds the target window, so a following Read-Host would
    # read keystrokes typed into THAT tab, not this shell. Reclaim our own console
    # to the foreground first. Windows blocks SetForegroundWindow from a non-
    # foreground process unless a key was just pressed, so tap ALT to unlock it.
    try {
        $h = [Gwt.Win]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) {
            [Gwt.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)  # ALT down
            [Gwt.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)  # ALT up
            [Gwt.Win]::SetForegroundWindow($h) | Out-Null
        }
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
        $Target  = $Command -replace '(?<=pull/\d+)(/.*)?$',''  # strip /changes, /files, etc.
        $Command = 'pr'
    } elseif ($Command -match '^https?://bitbucket\.org/[^/]+/[^/]+/pull-requests/\d+') {
        # Bitbucket PR URL uses 'pull-requests' (hyphen). Strip trailing /diff, /commits, /activity.
        $Target  = $Command -replace '(?<=pull-requests/\d+)(/.*)?$',''
        $Command = 'pr'
    } elseif ($Command -match '^https?://(?<host>[^/]+)/(?<org>[^/]+)/(?<repo>[^/]+)/issues/(?<num>\d+)') {
        $script:RemoteHost = $Matches.host
        $script:Org        = $Matches.org
        $script:Repo       = $Matches.repo
        $Target  = $Matches.num
        $Command = 'issue'
    } elseif ($Command -match '^https?://(?<host>[^/]+)/(?<org>[^/]+)/(?<repo>[^/]+)/security/advisories/(?<ghsa>GHSA-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4})') {
        $script:RemoteHost = $Matches.host
        $script:Org        = $Matches.org
        $script:Repo       = $Matches.repo
        $Target  = $Matches.ghsa
        $Command = 'advisory'
    } elseif ($Command -match '^https?://[^/]+\.zendesk\.com/.*?/tickets/\d+') {
        $Target  = $Command
        $Command = 'zendesk'
    } elseif ($Command -match '^https?://(?<host>[^/]+)/(?<org>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?\s*$') {
        $script:RemoteHost = $Matches.host
        $script:Org        = $Matches.org
        $script:Repo       = $Matches.repo
        $Target  = $Command
        $Command = 'clone'
    } elseif ($Command -match '^https?://(github\.com|bitbucket\.org|gitlab\.com)/[^/]+/[^/]+/') {
        # Any deeper URL on a known git host (an actions run, a blob/tree link, a
        # settings page): we can't infer a branch, so hand it to 'new', which pulls
        # org/repo out and prompts for a worktree name.
        $Target  = $Command
        $Command = 'new'
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
            Write-Color "gwt sessions list [-IncludeEnded] [-Usage]" Cyan
            Write-Color "  Registered claude sessions as a flat table, newest activity first." DarkGray
            Write-Color "  Tags: ACTIVE / ABORTED / STALE / ENDED / SAVED (saved overrides the rest)." DarkGray
            Write-Color "  ENDED (closed cleanly) is hidden by default -- pass -IncludeEnded to show it." DarkGray
            Write-Color "  Output honors '> file' and '| grep' (colored only when going to a terminal)." DarkGray
            Write-Color "  -Usage  print the per-subcommand cheat sheet below the listing." DarkGray
        }
        'sessions restore' {
            Write-Host ""
            Write-Color "gwt sessions restore [<match>] [-ByTabs|-BySessions] [-DryRun] [-MaxAgeDays <n>] [-IncludeEnded] [-Name <branch>] [-Window <name>]" Cyan
            Write-Color "  Relaunch ABORTED sessions. Only recoverable ones qualify: transcript on disk AND active recently." DarkGray
            Write-Color "  Picks a mode (announced): 'by tabs' rebuilds the exact .tabs layout (DEFAULT), or" DarkGray
            Write-Color "  'by sessions' opens in order with the auto/previous window prompt." DarkGray
            Write-Color "  <match>       substring filter (Branch / WorktreePath / WindowName)" DarkGray
            Write-Color "  -ByTabs       force .tabs-layout mode (skip the picker)" DarkGray
            Write-Color "  -BySessions   force open-order + window-prompt mode (skip the picker)" DarkGray
            Write-Color "  -DryRun       print what WOULD reopen, then stop (by-tabs: grouped by window then tab index)" DarkGray
            Write-Color "  -ExcludeActive  drop currently-RUNNING sessions from the set. Default INCLUDES them so the" DarkGray
            Write-Color "                  preview shows the full post-reboot layout (a live restore still skips running ones)." DarkGray
            Write-Color "  -MaxAgeDays   skip sessions last active > n days ago (default 7; 0 = no limit)" DarkGray
            Write-Color "  -IncludeEnded also restore sessions you closed cleanly (ENDED)" DarkGray
            Write-Color "  -Name         exact branch match (combines with the others)" DarkGray
            Write-Color "  -Window       on single-entry restore: override the destination window" DarkGray
            Write-Color "                on multi-entry restore: also filters by exact window name" DarkGray
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
# Alias: 'gwt tabs <mode>' == 'gwt sessions tabs <mode>'. Shift the mode into $Match
# (where the sessions/tabs handler reads it) and route through 'sessions'.
if ($Command -eq 'tabs') {
    # 'gwt tabs snapshot' is not a tabs sub-mode -- snapshot is a sessions-level
    # op (save -All: freeze the layout). Route it there instead of silently
    # falling through to the plain 'tabs' show, which looked like a no-op.
    if ($Target -eq 'snapshot') {
        $Target = 'snapshot'
    } else {
        $Match   = $Target
        $Target  = 'tabs'
    }
    $Command = 'sessions'
}
switch ($Command) {

    'new' {
        if (-not $Target) { throw "'new' requires a branch name" }
        if ($Target -match '^https?://[^/]+/[^/]+/[^/]+/pull/\d+') {
            $prUrl = $Target -replace '(?<=pull/\d+)(/.*)?$',''
            $rest  = if ($y) { @('-y') } else { @() }
            & $PSCommandPath $prUrl @rest
            break
        }
        if ($Target -match '^https?://(?<host>[^/]+)/(?<org>[^/]+)/(?<repo>[^/]+)/issues/(?<num>\d+)') {
            $script:RemoteHost = $Matches.host
            $script:Org        = $Matches.org
            $script:Repo       = $Matches.repo
            $passArgs = @{ Org = $Matches.org; Repo = $Matches.repo; RemoteHost = $Matches.host }
            if ($y) { $passArgs.y = $true }
            & $PSCommandPath issue $Matches.num @passArgs
            break
        }
        if ($Target -match '^https?://(?<host>[^/]+)/(?<org>[^/]+)/(?<repo>[^/]+)/security/advisories/(?<ghsa>GHSA-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4})') {
            $script:RemoteHost = $Matches.host
            $script:Org        = $Matches.org
            $script:Repo       = $Matches.repo
            $passArgs = @{ Org = $Matches.org; Repo = $Matches.repo; RemoteHost = $Matches.host }
            if ($y) { $passArgs.y = $true }
            & $PSCommandPath advisory $Matches.ghsa @passArgs
            break
        }
        # Any other URL from a KNOWN GIT HOST that we can pull host/org/repo from
        # (an actions run, a blob/tree link, a settings page): we can't infer the
        # branch, so ask for one and proceed with that repo context. Restricted to
        # git hosts so non-repo URLs (e.g. a discourse thread) don't get cloned.
        if ($Target -match '^https?://(?<host>github\.com|bitbucket\.org|gitlab\.com)/(?<org>[^/]+)/(?<repo>[^/]+?)(?:\.git)?(?:/.*)?$') {
            Write-Color "  detected $($Matches.host)/$($Matches.org)/$($Matches.repo) -- but no branch in that URL" Yellow
            $name = (Read-Host "  enter a worktree/branch name").Trim()
            if (-not $name) { throw "no name given -- aborted" }
            $passArgs = @{ Org = $Matches.org; Repo = $Matches.repo; RemoteHost = $Matches.host }
            if ($y) { $passArgs.y = $true }
            & $PSCommandPath new $name @passArgs
            break
        }
        # Zendesk ticket URLs -- point at the right command.
        if ($Target -match '^https?://[^/]+\.zendesk\.com/.*?/tickets/\d+') {
            throw "that looks like a Zendesk ticket, not a git repo. did you mean:  gwt zendesk $Target"
        }
        # Discourse thread URLs are <host>/t/<slug>[/<id>] -- point at the right command.
        if ($Target -match '^https?://[^/]+/t/[^/]+') {
            throw "that looks like a discourse thread, not a git repo. did you mean:  gwt discourse $Target"
        }
        if ($Target -match '^https?://') {
            throw "'$Target' is a URL but not a recognized git repo URL -- discourse thread: 'gwt discourse <url>', Zendesk ticket: 'gwt zendesk <url>'"
        }
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
            if (_ShellIsInside $existingWt) {
                # Standing in the target worktree: removal would fail on the cwd
                # lock, so skip the remove prompt and go straight to the open flow.
                Write-Color "already in this worktree: $existingWt" DarkGray
                _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y -ByProject:$ByProject
                _SetGwtCwdHint $existingWt
                return
            }
            $resp = Read-Host "worktree already exists at '$existingWt'. remove it? (y/N)"
            if ($resp -match '^[Yy]$') {
                Remove-Worktree -Src $ctx.Src -WtPath $existingWt -AutoConfirm
            } else {
                Write-Color "ready: $existingWt" Green
                _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y -ByProject:$ByProject
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
        if ($Current) {
            _SetCurrentSymlink -WtRoot $ctx.WtRoot -WorktreePath $wtPath
        } else {
            $r = Read-Host "activate this worktree (point '$($ctx.WtRoot)\current' here)? (y/N)"
            if ($r -match '^[Yy]$') { _SetCurrentSymlink -WtRoot $ctx.WtRoot -WorktreePath $wtPath }
        }
        _ConfirmOpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y -ByProject:$ByProject
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

    'close' {
        # Close THIS tab cleanly (run from inside it):
        #   1. drop its line from the per-window tab registry (removal reorders the
        #      rest automatically -- positions are line order, no renumber needed)
        #   2. mark its ledger entry ended
        #   3. signal the profile wrapper to exit this shell, which closes the wt tab
        # Identity comes from $env:WT_SESSION; cwd is the fallback when it's missing.
        $wtSess = $env:WT_SESSION
        $cwd    = (Get-Location).Path.Replace('/', '\').TrimEnd('\').ToLower()

        $removedTabs = 0
        $winDir = Join-Path $script:WtRoot 'windows'
        if (Test-Path $winDir) {
            foreach ($tf in (Get-ChildItem $winDir -Filter '*.tabs' -ErrorAction SilentlyContinue)) {
                $lines = @(Get-Content $tf.FullName -ErrorAction SilentlyContinue)
                $keep = @($lines | Where-Object {
                    $p  = $_ -split "`t"
                    $ws = $p[0]
                    $lp = if ($p.Count -ge 3) { ($p[2] -replace '/', '\').TrimEnd('\').ToLower() } else { '' }
                    -not (($wtSess -and $ws -eq $wtSess) -or ($lp -and $lp -eq $cwd))
                })
                if ($keep.Count -ne $lines.Count) {
                    if ($keep.Count) { Set-Content -Path $tf.FullName -Value $keep -Encoding UTF8 }
                    else { Remove-Item $tf.FullName -Force -ErrorAction SilentlyContinue }
                    $removedTabs += ($lines.Count - $keep.Count)
                }
            }
        }

        foreach ($sf in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try { $e = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
            $ep = ($e.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()
            if (($wtSess -and $e.WtSession -eq $wtSess) -or ($ep -and $ep -eq $cwd)) {
                $e.Pid = 0
                if ($e.PSObject.Properties.Match('State').Count) { $e.State = 'ended' }
                else { Add-Member -InputObject $e -NotePropertyName State -NotePropertyValue 'ended' -Force }
                ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $sf.FullName -Encoding UTF8
            }
        }

        Write-Color "closed this tab (removed $removedTabs registry line(s)) -- shell exiting" Green
        # Drop a hint the profile wrapper reads to exit the parent shell (closing the
        # wt tab). If gwt was run outside the wrapper, there's no hint -- nothing closes.
        if ($env:GWT_HINT_FILE) {
            Set-Content -Path "$($env:GWT_HINT_FILE).close" -Value '1' -Encoding UTF8 -ErrorAction SilentlyContinue
        }
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

    'advisory' {
        # Triggered by a GitHub security advisory URL:
        # github.com/<org>/<repo>/security/advisories/GHSA-xxxx-yyyy-zzzz.
        # Creates a worktree at 'advisory-<GHSA>' branched off main and opens
        # claude with a prompt pointed at the advisory. GitHub's own fix flow
        # uses a temporary private fork we can't clone over SSH; this is the
        # local fix-branch you'd PR from.
        if (-not $Target -or $Target -notmatch '^GHSA-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}$') {
            throw "'advisory' expects a GHSA id (got '$Target') -- use a github security advisory URL"
        }
        $ghsa   = $Target
        $branch = "advisory-$ghsa"
        $ctx    = Resolve-RepoContext
        [System.IO.Directory]::CreateDirectory($ctx.WtRoot) | Out-Null
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost

        # Fetch the advisory body HERE (as the invoking shell) and embed it in the
        # prompt. This matters for DRAFT advisories: a classic PAT with repo admin
        # (what you run gwt with) can read them, but a fine-grained PAT -- and the
        # spawned claude's token -- cannot. Fetching here and baking the text in means
        # the spawned claude never has to hit an endpoint its token can't reach.
        # PromptText is stored in the session JSON and passed to claude as a single
        # argv (never a command line), so multi-line markdown is safe.
        $summary = $null; $severity = $null; $description = $null; $forkFull = $null
        try {
            $raw = (& gh api "repos/$($ctx.Org)/$($ctx.Repo)/security-advisories/$ghsa" 2>$null | Out-String).Trim()
            if ($raw) {
                $adv         = $raw | ConvertFrom-Json
                $summary     = $adv.summary
                $severity    = $adv.severity
                $description = $adv.description
                $forkFull    = $adv.private_fork.full_name   # temporary private fork holding the fix PRs
            }
        } catch {}

        Write-Color "advisory: $($ctx.Org)/$($ctx.Repo) $ghsa" Cyan
        if ($severity) { Write-Color "severity: $severity" DarkGray }
        if ($summary)  { Write-Color "summary:  $summary" DarkGray }
        Write-Color "branch:   $branch" DarkGray
        if (-not ($summary -or $description)) {
            Write-Color "  (couldn't read the advisory body here -- draft advisories need a classic PAT with repo admin)" Yellow
        }

        # Pull in the actual fix. GitHub develops advisory fixes on a temporary PRIVATE
        # fork (advisory.private_fork); its PRs hold the patches. Clone the fork and
        # fetch every PR head locally as 'pr-<n>' so the spawned claude can diff them
        # all -- however many there are -- by reading local git, with no need for its
        # own access to the private fork. The clone runs over YOUR ssh; a token that
        # can't reach the fork just lands in the catch and the advisory proceeds
        # body-only.
        $forkLines = @()
        if ($forkFull -and $forkFull -match '^(?<forg>[^/]+)/(?<frepo>.+)$') {
            $forkOrg  = $Matches.forg
            $forkRepo = $Matches.frepo
            $forkSrc  = Join-Path (Split-Path $ctx.Src -Parent) $forkRepo   # sibling of the main clone (same org)
            Write-Color "fix fork: $forkFull" Cyan
            try {
                Ensure-RepoClonedAndUpdated -Org $forkOrg -Repo $forkRepo -Src $forkSrc -RemoteHost $ctx.RemoteHost
                $prsRaw = (& gh api "repos/$forkFull/pulls?state=all&per_page=100" 2>$null | Out-String).Trim()
                $prs = if ($prsRaw) { @($prsRaw | ConvertFrom-Json) } else { @() }
                if (-not $prs.Count) {
                    Write-Color "  no PRs on the fork -- the fix may live on its default branch" DarkGray
                    $forkLines += "the fix fork $forkFull is cloned at $forkSrc but has no PRs; inspect its default branch there."
                } else {
                    $forkLines += "the proposed fix is split across $($prs.Count) PR(s) on the private fork $forkFull, cloned locally at ${forkSrc}:"
                    foreach ($pr in ($prs | Sort-Object number)) {
                        $n    = $pr.number
                        $base = $pr.base.ref
                        try { Invoke-Git $forkSrc @('fetch','origin',"+refs/pull/$n/head:refs/heads/pr-$n") } catch {}
                        Write-Color ("  PR #{0} [{1}] {2}" -f $n, $pr.state, $pr.title) DarkGray
                        $forkLines += "  - PR #$n ($($pr.state)) ""$($pr.title)"" -> local branch pr-$n, base origin/$base;  diff: git -C ""$forkSrc"" diff origin/$base..pr-$n"
                    }
                    $forkLines += "read every PR diff above, then synthesize the complete change set."
                }
            } catch {
                Write-Color "  couldn't gather the fork PRs: $($_.Exception.Message)" Yellow
            }
        }

        if (-not $Prompt) {
            if ($summary -or $description -or $forkLines.Count) {
                $sev  = if ($severity) { " (severity: $severity)" } else { "" }
                $body = @("review security advisory $ghsa in $($ctx.Org)/$($ctx.Repo)$sev.")
                if ($summary)         { $body += "summary: $summary" }
                if ($description)     { $body += "details:`n$description" }
                if ($forkLines.Count) { $body += ($forkLines -join "`n") }
                $body += "propose a fix plan before changing anything."
                $Prompt = $body -join "`n`n"
            } else {
                $Prompt = "investigate security advisory $ghsa in $($ctx.Org)/$($ctx.Repo) -- try to read it (gh api repos/$($ctx.Org)/$($ctx.Repo)/security-advisories/$ghsa); if your token can't (it's likely a draft), ask me to paste the advisory. propose a fix plan before changing anything."
            }
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
        # Ensure-RepoClonedAndUpdated creates the parent dir only after the repo
        # verifies as reachable, so a non-git URL leaves nothing behind.
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
        } elseif ($Target -match '^https?://bitbucket\.org/(?<org>[^/]+)/(?<repo>[^/]+?)/pull-requests/(?<pr>\d+)') {
            $script:Org        = $Matches.org
            $script:Repo       = $Matches.repo
            $script:RemoteHost = 'bitbucket.org'
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

        $branch     = Get-PrHeadBranch -Org $ctx.Org -Repo $ctx.Repo -PrNumber $prNum -RemoteHost $ctx.RemoteHost
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
            if (_ShellIsInside $existingWt) {
                # Standing in the target worktree: removal would fail on the cwd
                # lock, so skip the remove prompt and go straight to the open flow.
                Write-Color "already in this worktree: $existingWt" DarkGray
                _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
                _SetGwtCwdHint $existingWt
                return
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

        Sync-PrBranch $ctx.Src $branch $prNum $ctx.RemoteHost
        Ensure-Worktree $ctx.Src $wtPath $branch
        Write-Color "ready: $wtPath" Green
        _InvokeGwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath -RemoteHost $ctx.RemoteHost
        _ConfirmOpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $branch -PromptOverride $Prompt -AutoOpen:$y
        _SetGwtCwdHint $wtPath
    }

    'backport' {
        # gwt backport <pr-url|num> [-Lts active|maint] [-y]
        # Branch a worktree off an LTS release line (not main) and cherry-pick the PR's
        # commits into it. Branch/dir name: backport.<vX.Y.x>.<pr-source-branch>.
        if (-not $Target) { throw "'backport' requires a GitHub PR URL or number" }
        if ($Target -match '^https?://github\.com/(?<org>[^/]+)/(?<repo>[^/]+?)/pull/(?<pr>\d+)') {
            $script:Org = $Matches.org; $script:Repo = $Matches.repo; $prNum = $Matches.pr
        } elseif ($Target -match '^\d+$') {
            $prNum = $Target
        } else {
            throw "expected a GitHub PR URL or number, got: $Target"
        }

        $ctx = Resolve-RepoContext
        [System.IO.Directory]::CreateDirectory($ctx.WtRoot) | Out-Null
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost
        Invoke-Git $ctx.Src @('worktree', 'prune')

        # Target LTS -> release branch; its 'vX.Y.x' tag prefixes the backport branch.
        $release = _ResolveLtsBranch $ctx.Src $Lts
        $verPart = ($release -replace '^release-', '')          # release-v2.0.x -> v2.0.x
        $head     = Get-PrHeadBranch -Org $ctx.Org -Repo $ctx.Repo -PrNumber $prNum -RemoteHost $ctx.RemoteHost
        $headSafe = ($head -replace '/', '-')                   # keep the dir/branch flat
        $newBranch = "backport.$verPart.$headSafe"
        $wtPath    = Join-Path $ctx.WtRoot $newBranch

        Write-Color "backport: PR #$prNum  (source: $head)" Cyan
        Write-Color "  onto:   $release" DarkGray
        Write-Color "  branch: $newBranch" DarkGray

        $existingWt = Get-WorktreePathForBranch $ctx.Src $newBranch
        if ($existingWt) {
            Write-Color "ready: $existingWt (already exists)" Green
            _ConfirmOpenOrCd -Path $existingWt -Repo $ctx.Repo -Branch $newBranch -PromptOverride $Prompt -AutoOpen:$y
            _SetGwtCwdHint $existingWt
            return
        }

        # Create the branch off the (freshly fetched) release line, then the worktree.
        if (Test-LocalBranchExists $ctx.Src $newBranch) {
            Invoke-Git $ctx.Src @('branch', '-f', '--no-track', $newBranch, "origin/$release")
        } else {
            Invoke-Git $ctx.Src @('branch', '--no-track', $newBranch, "origin/$release")
        }
        Ensure-Worktree $ctx.Src $wtPath $newBranch

        # PR commit OIDs (oldest-first) + download their objects, then cherry-pick with -x
        # (records provenance). refs/pull/<n>/head exists even for merged PRs whose branch
        # was deleted, so this works post-merge.
        $oidRaw = (& gh pr view $prNum --repo "$($ctx.Org)/$($ctx.Repo)" --json commits -q '.commits[].oid' 2>&1 | Out-String)
        $oids = @($oidRaw -split "\r?\n" | Where-Object { $_ -match '^[0-9a-f]{7,40}$' })
        if (-not $oids.Count) {
            Write-Color "couldn't read PR commits from gh -- worktree is ready; cherry-pick manually" Yellow
        } else {
            Invoke-Git $ctx.Src @('fetch', 'origin', "refs/pull/$prNum/head")   # download the objects
            Write-Color "cherry-picking $($oids.Count) commit(s) (-x) onto $newBranch..." Cyan
            Push-Location $wtPath
            try { & git cherry-pick -x @oids; $cpExit = $LASTEXITCODE } finally { Pop-Location }
            if ($cpExit -ne 0) {
                Write-Color "cherry-pick STOPPED (conflict or empty commit) -- worktree left mid-pick, resolve it:" Yellow
                Write-Color "  cd `"$wtPath`"" DarkGray
                Write-Color "  git status ; fix conflicts ; git cherry-pick --continue   (or: git cherry-pick --abort)" DarkGray
            } else {
                Write-Color "cherry-pick complete ($($oids.Count) commit(s))" Green
            }
        }

        Write-Color "ready: $wtPath" Green
        _InvokeGwtHook -Org $ctx.Org -Repo $ctx.Repo -WorktreePath $wtPath -RemoteHost $ctx.RemoteHost
        _ConfirmOpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $newBranch -PromptOverride $Prompt -AutoOpen:$y
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
        $resp = _SelectTargetRepo -Default $defaultRepo
        if (-not $resp) { Write-Color "no repo selected -- aborted" Yellow; return }

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

        # discourse always launches claude with a fixed investigate-and-summarize
        # prompt. The topic id names the DISCOURSE-<id>.md file, and the topic URL is
        # embedded so claude knows which post to read. An explicit -Prompt overrides it.
        $topicUrl = if ($titleSlug) { "https://$discourseHost/t/$titleSlug/$topicId" } else { "https://$discourseHost/t/$topicId" }
        $discoursePrompt = "read this discourse post ($topicUrl), summarize it here and in DISCOURSE-$topicId.md file, then let's figure out how you and i can make a plan to answer the user."

        # Forward to 'new' with explicit host/org/repo so Resolve-RepoContext
        # doesn't need a cwd-based git remote.
        $fwd = @{
            Command    = 'new'
            Target     = $branch
            Org        = $orgPart
            Repo       = $repoPart
            RemoteHost = $hostPart
        }
        $fwd.y       = $true   # discourse defaults to -y: auto-open claude in the auto (repo) window
        $fwd.Current = $true   # discourse defaults to -Current: point <WtRoot>\current at this worktree
        if ($Prompt) { $fwd.Prompt = $Prompt } else { $fwd.Prompt = $discoursePrompt }
        & $PSCommandPath @fwd
        return
    }

    'zendesk' {
        # Create a worktree to investigate a Zendesk support ticket. Mirrors 'discourse'.
        # Accepts:
        #   * full URL  -- https://<sub>.zendesk.com/agent/tickets/12345
        #   * bare id   -- 12345  (uses $env:ZENDESK_HOST)
        if (-not $Target) { throw "'zendesk' requires a Zendesk ticket URL or numeric ticket id" }
        $ticketId    = $null
        $zendeskHost = $null

        if ($Target -match '^\d+$') {
            $ticketId    = $Target
            $zendeskHost = $env:ZENDESK_HOST
            if (-not $zendeskHost) {
                throw "bare ticket id needs a host. set `$env:ZENDESK_HOST (e.g. in ~/.profile.secrets.ps1) or pass the full ticket URL"
            }
            Write-Color "bare ticket id -- assuming host $zendeskHost (from `$env:ZENDESK_HOST)" DarkGray
        } elseif ($Target -match '^https?://(?<zhost>[^/]+).*?/tickets/(?<id>\d+)') {
            $ticketId    = $Matches.id
            $zendeskHost = $Matches.zhost
        } else {
            throw "expected a Zendesk ticket URL or bare numeric ticket id"
        }

        Write-Color "zendesk ticket: $ticketId" Cyan
        Write-Color "zendesk host:   $zendeskHost" DarkGray

        # Accept either 'org/repo' (default github) or 'host:org/repo'.
        # Zendesk tickets are usually tunneler issues, so pre-select ziti-tunnel-sdk-c.
        $defaultRepo = 'openziti/ziti-tunnel-sdk-c'
        $resp = _SelectTargetRepo -Default $defaultRepo
        if (-not $resp) { Write-Color "no repo selected -- aborted" Yellow; return }

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

        $branch = "zendesk-$ticketId"
        Write-Color "branch:          $branch" DarkGray

        # zendesk always launches claude with a fixed investigate-and-summarize prompt.
        # The ticket id names the ZENDESK-<id>.md file, and the ticket URL is embedded
        # so claude can pull it (via the zendesk MCP). An explicit -Prompt overrides it.
        $ticketUrl     = "https://$zendeskHost/agent/tickets/$ticketId"
        $zendeskPrompt = "read this zendesk ticket ($ticketUrl), summarize it here and in ZENDESK-$ticketId.md file. list any attachments on the ticket and tell me whether there are any, then ask me which to download (a Ziti Desktop Edge for Windows feedback bundle is usually a .zip -- the debug-ziti-desktop-edge-win skill analyzes those). then let's figure out how you and i can make a plan to answer the customer."

        # Forward to 'new' with explicit host/org/repo so Resolve-RepoContext
        # doesn't need a cwd-based git remote.
        $fwd = @{
            Command    = 'new'
            Target     = $branch
            Org        = $orgPart
            Repo       = $repoPart
            RemoteHost = $hostPart
        }
        $fwd.y       = $true   # zendesk defaults to -y: auto-open claude in the auto (repo) window
        $fwd.Current = $true   # zendesk defaults to -Current: point <WtRoot>\current at this worktree
        if ($Prompt) { $fwd.Prompt = $Prompt } else { $fwd.Prompt = $zendeskPrompt }
        & $PSCommandPath @fwd
        return
    }

    'twig' {
        if (-not $Target) { throw "'twig' requires a new branch name" }

        # NOTE: not $current -- that collides (case-insensitively) with the [switch]$Current
        # parameter, so assigning a branch string to it throws a SwitchParameter cast error.
        $srcBranch = (& git rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $srcBranch -or $srcBranch -eq 'HEAD') {
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

        Write-Color "twigging '$Target' off '$srcBranch'" Cyan

        $ctx = Resolve-RepoContext
        [System.IO.Directory]::CreateDirectory($ctx.WtRoot) | Out-Null
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src -RemoteHost $ctx.RemoteHost

        if (Test-LocalBranchExists $ctx.Src $Target) {
            throw "branch '$Target' already exists -- pick a different name"
        }
        # branch off whatever $srcBranch currently points to locally -- do NOT force-update it
        Invoke-Git $ctx.Src @('branch','--no-track',$Target,$srcBranch)

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
                Copy-Item -LiteralPath $src -Destination $dst -Force -Recurse   # -Recurse carries untracked dirs (e.g. test-results/)
                Write-Color "  copied: $rel" DarkGray
            }
        }

        if ($patchFile -and (Test-Path $patchFile) -and (Get-Item $patchFile).Length -gt 0) {
            Write-Color "applying carried changes..." Cyan
            & git -C $wtPath apply $patchFile 2>&1 | Out-String | Write-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Color "patch did not apply cleanly -- left at: $patchFile" Red
            } else {
                Write-Color "carried changes applied (unstaged)." Green
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

        # 'tabs' works purely off the per-window registry files, not the session
        # ledger, so skip the full scan + CIM liveness + repo-scope preamble here
        # (it does its own lighter liveness pass only when a mode needs it).
        if ($Target -ne 'tabs') {
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
                        # Guard against PID REUSE (esp. after a reboot): a stale PID now owned
                        # by an unrelated process must NOT read as alive. Compare the live
                        # process CreationDate to the best "when this session started" stamp.
                        # StartTime is exact (tight tolerance); the spawn stamps are looser but
                        # still separate a same-boot match (seconds) from a reboot (hours+).
                        $ref = $null; $tol = 2
                        if     ($e.StartTime)     { $ref = $e.StartTime;     $tol = 2 }
                        elseif ($e.LastSpawnedAt) { $ref = $e.LastSpawnedAt; $tol = 300 }
                        elseif ($e.SpawnedAt)     { $ref = $e.SpawnedAt;     $tol = 300 }
                        if ($ref -and $cim.CreationDate) {
                            try { $alive = [math]::Abs(($cim.CreationDate - [datetime]::Parse($ref)).TotalSeconds) -lt $tol }
                            catch { $alive = $true }
                        } else {
                            $alive = $true   # no timestamp at all -- can't verify, assume alive
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
        $entriesAllRepos = $entries   # full pre-scope set, for cross-repo fallbacks (restore)
        $entries = $scopeResult.Entries
        if ($scopeResult.Scoped) {
            Write-Color ("  scoped to {0}  ({1} entries from other repos hidden; pass -All to see all)" -f $scopeResult.ScopeName, $scopeResult.Hidden) DarkGray
        }
        } # end ledger preamble (skipped for 'tabs')

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

        # 'snapshot' is the friendly name for 'save -All': mark every running session
        # Saved and freeze the current tab layout, so 'restore -ByTabs' rebuilds exactly
        # this regardless of what you close afterward.
        if ($Target -eq 'snapshot') { $Target = 'save'; $All = $true }

        # subcommand under 'sessions': default = list. 'restore' = relaunch stale.
        # 'clean' = drop stale entries without relaunch.
        switch ($Target) {
            'audit' {
                # Health + recovery overview across ALL repos. Read-only EXCEPT for one
                # opt-in prompt at the end to drop entries whose worktree dir is gone.
                # Answers "what is live, what was used recently and isn't back, and what
                # entries are junk", plus a breakdown of how sessions exited.
                $sessDir = $script:SessionDir
                if (-not (Test-Path $sessDir)) { Write-Color "no session dir at $sessDir" Yellow; return }
                $procMap = _GetProcMapCached

                # NB: do not name this $all -- PowerShell vars are case-insensitive so
                # $all would alias the [switch]$All script param and the array assignment
                # would throw a SwitchParameter conversion error.
                $auditEntries = @()
                foreach ($f in (Get-ChildItem $sessDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                    try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
                    $alive = $false
                    if ($e.Pid -and $e.Pid -ne 0) {
                        $cim = $procMap[[int]$e.Pid]
                        if ($cim) {
                            $alive = $true
                            if ($e.StartTime -and $cim.CreationDate) {
                                try { if ([math]::Abs(($cim.CreationDate - [datetime]::Parse($e.StartTime)).TotalSeconds) -gt 2) { $alive = $false } } catch {}
                            }
                        }
                    }
                    $auditEntries += [pscustomobject]@{
                        Branch    = if ($e.Branch) { $e.Branch } else { '(none)' }
                        Window    = if ($e.WindowName) { $e.WindowName } else { '(none)' }
                        State     = if ($e.State) { $e.State } else { '?' }
                        EndReason = $e.EndReason
                        Path      = if ($e.WorktreePath) { ($e.WorktreePath -replace '/','\').TrimEnd('\') } else { '' }
                        PathNorm  = if ($e.WorktreePath) { ($e.WorktreePath -replace '/','\').TrimEnd('\').ToLower() } else { '' }
                        Alive     = $alive
                        Last      = if ($e.LastStateChange) { $e.LastStateChange } elseif ($e.LastSpawnedAt) { $e.LastSpawnedAt } else { $e.SpawnedAt }
                        Started   = if ($e.FirstSpawnedAt) { $e.FirstSpawnedAt } elseif ($e.SpawnedAt) { $e.SpawnedAt } else { $null }
                        File      = $f.FullName
                    }
                }

                # Live sessions are OMITTED from this audit -- it is about what can be
                # cleaned up, not what is running. Keep only a count for the header (dedupe
                # by path so a double-registered running session counts once), and a path
                # set so a not-live entry sharing a path with a live one is skipped.
                $liveCount = @(@($auditEntries | Where-Object Alive) | Group-Object PathNorm).Count
                $livePaths = @{}
                foreach ($l in @($auditEntries | Where-Object Alive)) { if ($l.PathNorm) { $livePaths[$l.PathNorm] = $true } }

                # Candidates: not-live, worktree dir still exists, not covered by a live
                # session. Dedup by path (newest), newest first.
                $notLive = @($auditEntries | Where-Object { -not $_.Alive -and $_.Path -and (Test-Path $_.Path) -and -not $livePaths.ContainsKey($_.PathNorm) })
                $candidates = @($notLive | Group-Object PathNorm | ForEach-Object {
                    $_.Group | Sort-Object { "$($_.Last)" } -Descending | Select-Object -First 1
                } | Sort-Object { "$($_.Last)" } -Descending)

                # Merged-to-main verdict. Among the not-reopened entries (not live,
                # worktree dir present), flag the ones whose branch is already an
                # ancestor of the repo's origin default branch. A merged worktree is
                # DONE -- both the ledger entry and the worktree dir can go. This is
                # "merged as of your last fetch": audit does not fetch, it reads the
                # local origin/<default> ref. Main-clone and branchless entries are
                # never merged-flagged. Per-repo default-branch resolution is cached.
                $defRefCache = @{}
                function script:_AuditMainClone([string]$p) {
                    if (-not $p) { return $null }
                    $pfx = $script:WtRoot.TrimEnd('\')
                    if (-not $p.ToLower().StartsWith($pfx.ToLower() + '\')) { return $null }
                    $parts = $p.Substring($pfx.Length).TrimStart('\') -split '\\'
                    if ($parts.Count -lt 4) { return $null }   # need host\org\repo\branch
                    return (Join-Path (Join-Path (Join-Path $script:GitRoot $parts[0]) $parts[1]) $parts[2])
                }
                function script:_AuditDefaultRef([string]$main) {
                    if ($defRefCache.ContainsKey($main)) { return $defRefCache[$main] }
                    $ref = $null
                    $h = (& git -C $main symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null | Out-String).Trim()
                    if ($h) { $ref = ($h -replace '^refs/remotes/', '') }
                    if (-not $ref) {
                        foreach ($c in @('origin/main','origin/master')) {
                            & git -C $main rev-parse --verify --quiet $c *> $null
                            if ($LASTEXITCODE -eq 0) { $ref = $c; break }
                        }
                    }
                    $defRefCache[$main] = $ref
                    return $ref
                }
                # Classify each candidate into one factual bucket:
                #   REMOVABLE -- merged (to main, or a merged PR), 0 commits past the
                #                merge, working tree clean. Nothing local to lose.
                #   REVIEW    -- merged, but there ARE commits past the merge and/or
                #                uncommitted changes. Removing loses local work.
                #   KEEP      -- not merged: open PR, commits not in main, a main clone,
                #                or a non-worktree tangent.
                # merged = branch is an ancestor of origin/<default> (fast, local) OR the
                # pr-<n> worktree's PR is MERGED per gh (catches squash/rebase merges the
                # ancestor test misses). Dirty + commits-past are computed ONLY for merged
                # rows, to bound git calls. gh is called only for pr-<n> leaves.
                $removable = @(); $review = @(); $keep = @()
                foreach ($n in $candidates) {
                    $main = script:_AuditMainClone $n.Path
                    $n | Add-Member -NotePropertyName MainClone -NotePropertyValue $main -Force
                    $branchRef = if ($n.Branch -and $n.Branch -notin @('(none)','')) { 'refs/heads/' + $n.Branch } else { $null }

                    # PR worktree? resolve its PR once (state + head oid).
                    $prNum = $null; $pr = $null
                    $leaf = Split-Path $n.Path -Leaf
                    if ($leaf -match '^pr-(\d+)$') {
                        $prNum = $Matches[1]
                        $pfx   = $script:WtRoot.TrimEnd('\')
                        $parts = $n.Path.Substring($pfx.Length).TrimStart('\') -split '\\'
                        if ($parts.Count -ge 3) {
                            $slug = '{0}/{1}' -f $parts[1], $parts[2]
                            try {
                                $j = (& gh pr view $prNum -R $slug --json state,headRefOid 2>$null | Out-String).Trim()
                                if ($j) { $pr = $j | ConvertFrom-Json -ErrorAction SilentlyContinue }
                            } catch {}
                        }
                        $n | Add-Member -NotePropertyName PrNum -NotePropertyValue $prNum -Force
                        if ($pr -and $pr.state) { $n | Add-Member -NotePropertyName PrState -NotePropertyValue $pr.state -Force }
                    }

                    # Merged? ancestor-of-default first, then merged-PR.
                    $mergedVia = $null; $ahead = 0
                    if ($main -and (Test-Path $main) -and $branchRef -and $n.Branch -notin @('main','master')) {
                        $ref = script:_AuditDefaultRef $main
                        if ($ref) {
                            & git -C $main rev-parse --verify --quiet $branchRef *> $null
                            if ($LASTEXITCODE -eq 0) {
                                & git -C $main merge-base --is-ancestor $branchRef $ref *> $null
                                if ($LASTEXITCODE -eq 0) { $mergedVia = 'main' }
                            }
                        }
                    }
                    if (-not $mergedVia -and $pr -and $pr.state -eq 'MERGED') {
                        $mergedVia = "PR#$prNum"
                        $localTip = $null
                        if ($main -and (Test-Path $main) -and $branchRef) {
                            $localTip = (& git -C $main rev-parse --verify --quiet $branchRef 2>$null | Out-String).Trim()
                        }
                        if (-not $localTip) {
                            $localTip = (& git -C $n.Path rev-parse --verify --quiet HEAD 2>$null | Out-String).Trim()
                        }
                        if ($localTip -and $pr.headRefOid -and $localTip -ne $pr.headRefOid -and $main -and (Test-Path $main)) {
                            & git -C $main merge-base --is-ancestor $pr.headRefOid $localTip *> $null
                            if ($LASTEXITCODE -eq 0) {
                                $c = (& git -C $main rev-list --count ("$($pr.headRefOid)..$localTip") 2>$null | Out-String).Trim()
                                if ($c -match '^\d+$') { $ahead = [int]$c }
                            }
                        }
                    }

                    if ($mergedVia) {
                        # Dirty = uncommitted edits to TRACKED files (real work you would
                        # lose). --untracked-files=no drops the noise every worktree carries:
                        # the hook-injected CLAUDE.md / CMakeUserPresets.json symlinks, a
                        # stray .claude/ or handoff.md, build output. Those are not work, so
                        # they must not push a merged worktree out of REMOVABLE. (prune still
                        # runs its own full-status DIRTY guard when you actually remove it.)
                        $dirty = $false
                        $st = (& git -C $n.Path status --porcelain --untracked-files=no 2>$null | Out-String)
                        if (-not [string]::IsNullOrWhiteSpace($st)) { $dirty = $true }
                        $base  = if ($mergedVia -eq 'main') { 'merged to main' } else { "merged via $mergedVia" }
                        $extra = @()
                        if ($ahead -gt 0) { $extra += "+$ahead commits past merge" }
                        if ($dirty)       { $extra += 'uncommitted changes' }
                        $status = if ($extra.Count) { "$base, " + ($extra -join ' and ') } else { $base }
                        $n | Add-Member -NotePropertyName Status -NotePropertyValue $status -Force
                        if ($extra.Count) { $review += $n } else { $removable += $n }
                        continue
                    }

                    # Ended non-worktree session (tangent, adhoc, or a main-clone session):
                    # nothing to merge and no gwt-managed worktree to prune. The dir is the
                    # user's own and stays; the stale ledger entry is safe to drop. 'clean'
                    # skips these (off the canonical layout), so fold them into REMOVABLE
                    # here as ledger-only removals. Only ENDED ones -- an ABORTED/idle
                    # tangent may still be worth restoring, so those stay in KEEP.
                    if (-not $main -and $n.State -eq 'ended') {
                        $kind = if ($n.Branch -in @('main','master')) { 'main-clone session' } else { 'non-worktree session' }
                        $n | Add-Member -NotePropertyName Status -NotePropertyValue "$kind ended -- ledger entry only (dir kept)" -Force
                        $removable += $n
                        continue
                    }

                    # Not merged -- factual KEEP reason.
                    $reason = $null
                    if (-not $main) {
                        $reason = if ($n.Branch -in @('main','master')) { 'main clone' } else { 'not a gwt worktree' }
                    } elseif ($prNum -and $pr -and $pr.state) {
                        $reason = "PR#$prNum $($pr.state.ToLower())"
                    } elseif ($prNum) {
                        $reason = "PR#$prNum (state unknown)"
                    } elseif ($branchRef) {
                        $ref = script:_AuditDefaultRef $main
                        $aheadMain = $null
                        if ($ref) {
                            & git -C $main rev-parse --verify --quiet $branchRef *> $null
                            if ($LASTEXITCODE -eq 0) {
                                $c = (& git -C $main rev-list --count ("$ref..$branchRef") 2>$null | Out-String).Trim()
                                if ($c -match '^\d+$') { $aheadMain = [int]$c }
                            } else { $reason = 'branch not found locally' }
                        }
                        if (-not $reason) {
                            $reason = if ($null -ne $aheadMain -and $aheadMain -gt 0) { "not merged, +$aheadMain commits not in main" } else { 'not merged' }
                        }
                    } else {
                        $reason = 'not merged'
                    }
                    $n | Add-Member -NotePropertyName Status -NotePropertyValue $reason -Force
                    $keep += $n
                }

                $autoWin   = @($auditEntries | Where-Object { $_.Window -eq '__auto__' })
                $gonePath  = @($auditEntries | Where-Object { $_.Path -and -not (Test-Path $_.Path) })
                # Truly-dead subset: worktree dir gone AND path is under WORKTREE_ROOT.
                # A missing main-clone path (under GIT_ROOT) is left alone -- it may be a
                # temporary unmount or a moved drive, not real cruft.
                $wtRootPfx = ($script:WtRoot.TrimEnd('\').ToLower() + '\')
                $goneDead  = @($gonePath | Where-Object { $_.PathNorm -and $_.PathNorm.StartsWith($wtRootPfx) })
                $dupGroups = @($auditEntries | Where-Object { $_.PathNorm } | Group-Object PathNorm | Where-Object { $_.Count -gt 1 })
                $reasons   = @($auditEntries | Where-Object { $_.EndReason } | Group-Object EndReason | Sort-Object Count -Descending)

                Write-Color ("gwt sessions audit -- {0} entries, {1} live (omitted), {2} not-live below" -f $auditEntries.Count, $liveCount, $candidates.Count) Cyan
                Write-Host ""

                Write-Color "REMOVABLE ($($removable.Count)) -- nothing to lose (merged worktree, or an ended non-worktree session):" Green
                if ($removable.Count) {
                    Write-Host ('  {0,-28} {1,-34} {2}' -f 'branch','status','path') -ForegroundColor DarkGray
                    foreach ($m in ($removable | Sort-Object { "$($_.MainClone)" }, Branch)) {
                        Write-Host ('  {0,-28} {1,-34} {2}' -f $m.Branch, $m.Status, $m.Path) -ForegroundColor Green
                    }
                }
                Write-Host ""

                # Ask about the REMOVABLE set right here, before the rest of the report,
                # so the decision is made while the list is on screen. Opt-in (default N).
                # On yes, drop the ledger entries and hand over per-repo prune commands for
                # the worktree dirs. REVIEW and KEEP are never touched.
                if ($removable.Count) {
                    $resp = Read-Host ("drop {0} REMOVABLE session entr(ies) from the ledger now? (y/N)" -f $removable.Count)
                    if ($resp -match '^[Yy]') {
                        $removed = 0
                        foreach ($m in $removable) { try { Remove-Item $m.File -Force -ErrorAction Stop; $removed++ } catch {} }
                        Write-Color "  removed $removed entr(ies)" Green
                    } else {
                        Write-Color "  left as-is" DarkGray
                    }
                    $withWorktree = @($removable | Where-Object { $_.MainClone })
                    if ($withWorktree.Count) {
                        Write-Color "  worktree dirs are still on disk -- remove them per repo (prune keeps its guards):" DarkGray
                        foreach ($g in ($withWorktree | Group-Object MainClone)) {
                            Write-Color "    cd $($g.Name)" DarkGray
                            foreach ($m in $g.Group) { Write-Color "    gwt prune $($m.Branch)" DarkGray }
                        }
                    }
                    Write-Host ""
                }

                if ($review.Count) {
                    Write-Color "REVIEW FIRST ($($review.Count)) -- merged, but removing loses local work:" Yellow
                    Write-Host ('  {0,-28} {1,-42} {2}' -f 'branch','status','path') -ForegroundColor DarkGray
                    foreach ($m in ($review | Sort-Object { "$($_.MainClone)" }, Branch)) {
                        Write-Host ('  {0,-28} {1,-42} {2}' -f $m.Branch, $m.Status, $m.Path) -ForegroundColor Yellow
                    }
                    Write-Host ""
                }

                Write-Color "KEEP ($($keep.Count)) -- not merged:" Cyan
                if ($keep.Count) {
                    Write-Host ('  {0,-28} {1,-34} {2}' -f 'branch','status','path') -ForegroundColor DarkGray
                    foreach ($m in ($keep | Sort-Object { "$($_.Status)" }, Branch)) {
                        Write-Host ('  {0,-28} {1,-34} {2}' -f $m.Branch, $m.Status, $m.Path)
                    }
                }
                Write-Host ""

                if ($autoWin.Count -or $gonePath.Count -or $dupGroups.Count) {
                    Write-Color "INTEGRITY:" Magenta
                    if ($autoWin.Count)   { Write-Host ("  {0} entry(ies) with window '__auto__' (legacy data bug)" -f $autoWin.Count) }
                    if ($gonePath.Count)  {
                        Write-Host ("  {0} entry(ies) point at a worktree dir that no longer exists:" -f $gonePath.Count)
                        foreach ($g in $gonePath) { Write-Host ('      {0,-28} {1}' -f $g.Branch, $g.Path) -ForegroundColor DarkGray }
                    }
                    if ($dupGroups.Count) { Write-Host ("  {0} worktree path(s) with duplicate entries" -f $dupGroups.Count) }
                    Write-Host ""
                }
                if ($reasons.Count) {
                    Write-Color "EXIT REASONS:" DarkCyan
                    foreach ($r in $reasons) { Write-Host ('  {0,-20} {1}' -f $r.Name, $r.Count) }
                    Write-Host ""
                }
                # Offer to drop the well-and-truly-dead entries: their worktree dir is
                # gone, so they can never be restored. Opt-in (default N) so audit stays
                # safe to run casually.
                if ($goneDead.Count) {
                    $resp = Read-Host ("remove {0} dead session entr(ies) whose worktree dir is gone? (y/N)" -f $goneDead.Count)
                    if ($resp -match '^[Yy]') {
                        $removed = 0
                        foreach ($g in $goneDead) { try { Remove-Item $g.File -Force -ErrorAction Stop; $removed++ } catch {} }
                        Write-Color "  removed $removed dead entr(ies)" Green
                    } else {
                        Write-Color "  left as-is" DarkGray
                    }
                    if ($gonePath.Count -gt $goneDead.Count) {
                        Write-Color ("  ({0} missing-dir entr(ies) under the git root left alone -- could be a temporary unmount)" -f ($gonePath.Count - $goneDead.Count)) DarkGray
                    }
                    Write-Host ""
                }
                Write-Color "next:" DarkGray
                if ($keep.Count) {
                    Write-Color "  gwt sessions restore -All -DryRun         # preview the ordered set first (recent + has-transcript)" DarkGray
                    Write-Color "  gwt sessions restore -All                 # reopen crash victims (ABORTED); skips cleanly-ended" DarkGray
                    Write-Color "  gwt sessions restore -All -IncludeEnded   # also reopen sessions you closed cleanly (all rows above)" DarkGray
                }
                if ($dupGroups.Count -or $gonePath.Count) { Write-Color "  gwt sessions clean -Aborted -IncludeDuplicates   # drop dead / duplicate entries" DarkGray }
                return
            }
            'tabs' {
                # Per-window tab-order registry the hook maintains. Modes (via the
                # next positional, e.g. 'gwt sessions tabs test'):
                #   (none)  show each window's tabs, auto-dropping dead ones as it reads
                #   set     register/reposition THIS tab (does what the hook does, prompts
                #           for the window since wt can't report a tab's own window/index)
                #   prune   drop ghost lines whose session is no longer alive (re-syncs indexes)
                #   test    focus each tracked tab and ask you to confirm it landed right
                #   status  reconcile ledger vs tabs: report ghosts + ALIVE sessions missing
                #           from the registry, and offer to register the latter
                #   clear   wipe the whole registry so a clean quit-all/reopen-all rebuilds it
                $winDir = Join-Path $script:WtRoot 'windows'
                $mode   = if ($Match) { $Match.ToLower() } else { 'show' }

                if ($mode -eq 'set') {
                    # Replay what the SessionStart hook does, but for THIS tab on demand,
                    # prompting for anything not derivable. wt exposes no "what window/index
                    # am I" query, so the window (and position) come from you. Run it from
                    # the tab after exiting claude; $PID is then this tab's pwsh, which is
                    # exactly the liveness PID the registry checks.
                    $wtSess = $env:WT_SESSION
                    if (-not $wtSess) {
                        throw "no WT_SESSION -- run 'gwt sessions tabs set' inside the Windows Terminal tab you want to register"
                    }
                    $cwd    = (Get-Location).Path
                    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
                    if (-not $branch -or $branch -eq 'HEAD') { $branch = '' }
                    $scope    = _DetectCurrentRepoFromCwd
                    $repoLeaf = if ($scope) { $scope.Repo } else { Split-Path $cwd -Leaf }

                    # Find this tab's existing ledger entry (by WT_SESSION), if any.
                    $file = $null; $entry = $null
                    if (Test-Path $script:SessionDir) {
                        foreach ($sf in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                            try { $e = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
                            if ($e.WtSession -eq $wtSess) { $file = $sf.FullName; $entry = $e; break }
                        }
                    }

                    # Window: -Window wins; otherwise the picker (defaulting to auto=repo).
                    $win = $Window
                    if (-not $win) {
                        $picked = _SelectWtWindow -Repo $repoLeaf
                        if (-not $picked) { Write-Color "cancelled" DarkGray; return }
                        $win = $picked
                    }
                    if ($win -eq '__auto__') { $win = $repoLeaf }
                    if ($win -eq '__new__')  { throw "'set' needs an existing window name, not a brand-new window" }

                    # Create a ledger entry if this tab has none, then patch the fields the
                    # spawn/hook would have written so liveness + window tracking both work.
                    [System.IO.Directory]::CreateDirectory($script:SessionDir) | Out-Null
                    if (-not $entry) {
                        $id    = [guid]::NewGuid().ToString()
                        $file  = Join-Path $script:SessionDir "$id.json"
                        $entry = [pscustomobject]@{ Id = $id }
                    }
                    $now = (Get-Date).ToString('o')
                    $sets = @{ WorktreePath=$cwd; Branch=$branch; Repo=$repoLeaf; WindowName=$win; WtSession=$wtSess; Pid=$PID; State='idle'; LastStateChange=$now }
                    foreach ($k in $sets.Keys) { $entry | Add-Member -NotePropertyName $k -NotePropertyValue $sets[$k] -Force }
                    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path $file -Encoding UTF8

                    # Tab line: a worktree lives in exactly ONE tab in ONE window. So
                    # before inserting, drop any existing line across ALL window files that
                    # is either this tab (WtSession) OR the same worktree path (path is the
                    # dedupe key). That turns a second 'set' into a MOVE, not a duplicate.
                    $cwdNorm = ($cwd -replace '/', '\').TrimEnd('\').ToLower()
                    [System.IO.Directory]::CreateDirectory($winDir) | Out-Null
                    foreach ($wf in (Get-ChildItem $winDir -Filter '*.tabs' -ErrorAction SilentlyContinue)) {
                        $ls   = @(Get-Content $wf.FullName -ErrorAction SilentlyContinue)
                        $keep = @($ls | Where-Object {
                            $p        = $_ -split "`t"
                            $linePath = if ($p.Count -ge 3) { ($p[2] -replace '/', '\').TrimEnd('\').ToLower() } else { '' }
                            ($p[0] -ne $wtSess) -and ($linePath -ne $cwdNorm)
                        })
                        if ($keep.Count -ne $ls.Count) {
                            if ($keep.Count) { Set-Content -Path $wf.FullName -Value $keep -Encoding UTF8 }
                            else { Remove-Item $wf.FullName -Force -ErrorAction SilentlyContinue }
                        }
                    }
                    $safe    = ($win -replace '[^A-Za-z0-9._-]', '_')
                    $tabFile = Join-Path $winDir "$safe.tabs"
                    $lines   = [System.Collections.ArrayList]@(if (Test-Path $tabFile) { @(Get-Content $tabFile -ErrorAction SilentlyContinue) } else { @() })
                    # Label: default to the branch (or repo leaf for a main clone), but let
                    # the user name it whatever they recognize the tab as.
                    $labelDefault = if ($branch -and $branch -notin @('main','master')) { $branch } else { $repoLeaf }
                    $labelIn = Read-Host ("label for this tab (blank = '{0}')" -f $labelDefault)
                    $label   = if ([string]::IsNullOrWhiteSpace($labelIn)) { $labelDefault } else { $labelIn.Trim() }
                    $newLine = "{0}`t{1}`t{2}" -f $wtSess, $label, $cwd
                    # Ask a human 1-based tab number, then convert to the 0-based index the
                    # registry / wt focus-tab use. Blank appends at the end.
                    $numRaw = Read-Host ("what tab number is this? (1 = first tab, blank = last, {0})" -f ($lines.Count + 1))
                    $idx = $lines.Count
                    if (-not [string]::IsNullOrWhiteSpace($numRaw)) {
                        $tmp = 0
                        if ([int]::TryParse($numRaw.Trim(), [ref]$tmp) -and $tmp -gt 0) {
                            $idx = [Math]::Min($tmp - 1, $lines.Count)
                        } else {
                            Write-Color "  tab number must be a positive whole number -- appending at the end" Yellow
                        }
                    }
                    [void]$lines.Insert($idx, $newLine)
                    Set-Content -Path $tabFile -Value @($lines) -Encoding UTF8
                    Write-Color ("registered this tab -> [{0}] -t {1}  ({2})" -f $win, $idx, $label) Green
                    return
                }

                if (-not (Test-Path $winDir)) {
                    Write-Color "no tab registry yet at $winDir -- it fills in as sessions start/stop" DarkGray
                    return
                }

                if ($mode -eq 'clear') {
                    $files = @(Get-ChildItem $winDir -Filter '*.tabs' -ErrorAction SilentlyContinue)
                    foreach ($wf in $files) { Remove-Item $wf.FullName -Force -ErrorAction SilentlyContinue }
                    Write-Color "cleared $($files.Count) window file(s). Quit-all + reopen-all to rebuild the order clean." DarkGray
                    return
                }

                if ($mode -eq 'rebuild') {
                    # Reconstruct every window's .tabs registry from the LEDGER -- the
                    # reliable source after a drag-kill / restore churn corrupts the live
                    # registry (a mass claude-death leaves the shells but kills the claude
                    # processes, so liveness is useless here). One line per worktree PATH
                    # (newest session wins), grouped by that session's recorded window, and
                    # restricted to worktrees whose dir still EXISTS -- that filters out
                    # historical/pruned paths and lands on the current working set. Order
                    # within a window follows last activity (wt can't report tab index).
                    # Authoritative: this OVERWRITES the .tabs files. Reopen the rebuilt set
                    # with 'gwt sessions restore -ByTabs -IncludeEnded'.
                    $onlyWin = if ($Window) { $Window } else { $null }
                    # Recency window: the tabs you had OPEN are the recently-active ones, not
                    # every worktree that still exists on disk. Default 18h (a work day);
                    # -MaxAgeDays widens it. Without this, rebuild resurrects hundreds of old
                    # worktrees and 'show' immediately strips them as dead.
                    $cutoffHours = if ($PSBoundParameters.ContainsKey('MaxAgeDays') -and $MaxAgeDays -gt 0) { $MaxAgeDays * 24 } else { 18 }
                    $cutoff = (Get-Date).AddHours(-$cutoffHours)
                    $sessions = @()
                    foreach ($sf in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                        try { $se = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
                        if (-not ($se.WtSession -and $se.WindowName -and $se.WorktreePath)) { continue }
                        $p = ($se.WorktreePath -replace '/','\').TrimEnd('\')
                        if (-not (Test-Path $p)) { continue }   # current worktrees only
                        if ($onlyWin -and ($se.WindowName -notlike "*$onlyWin*")) { continue }
                        $last = if ($se.LastStateChange) { $se.LastStateChange } elseif ($se.LastSpawnedAt) { $se.LastSpawnedAt } else { $se.SpawnedAt }
                        $lastDt = $null; try { $lastDt = [datetime]::Parse($last) } catch {}
                        if (-not $lastDt -or $lastDt -lt $cutoff) { continue }   # recently active only
                        $sessions += [pscustomobject]@{
                            Ws=$se.WtSession; Window=$se.WindowName; Path=$p; Label=$se.Label; Branch=$se.Branch; Last=$last; File=$sf.FullName
                        }
                    }
                    # Newest session per worktree path.
                    $byPath = @($sessions | Group-Object { $_.Path.ToLower() } | ForEach-Object {
                        $_.Group | Sort-Object { "$($_.Last)" } -Descending | Select-Object -First 1
                    })
                    if (-not $byPath.Count) { Write-Color "no ledger sessions with an existing worktree to rebuild from" Yellow; return }

                    # Mark each selected session Saved, so 'restore' keeps them: with any
                    # Saved sessions present, restore restricts to Saved+running and would
                    # otherwise drop these ended sessions BEFORE the -ByTabs filter runs
                    # (which is how a rebuild reopened only the handful already Saved).
                    $savedN = 0
                    foreach ($m in $byPath) {
                        if (-not $m.File) { continue }
                        try {
                            $j = Get-Content $m.File -Raw | ConvertFrom-Json
                            $j | Add-Member -NotePropertyName Saved -NotePropertyValue $true -Force
                            ($j | ConvertTo-Json -Depth 6) | Set-Content -Path $m.File -Encoding UTF8
                            $savedN++
                        } catch {}
                    }

                    $byWin = @{}
                    foreach ($m in ($byPath | Sort-Object { "$($_.Last)" })) {
                        if (-not $byWin.ContainsKey($m.Window)) { $byWin[$m.Window] = @() }
                        $byWin[$m.Window] += $m
                    }

                    [System.IO.Directory]::CreateDirectory($winDir) | Out-Null
                    # Wipe the windows we are about to rebuild (all, unless -Window narrows).
                    foreach ($wf in (Get-ChildItem $winDir -Filter '*.tabs' -ErrorAction SilentlyContinue)) {
                        $w = [IO.Path]::GetFileNameWithoutExtension($wf.Name)
                        if ($onlyWin -and ($w -notlike "*$onlyWin*")) { continue }
                        Remove-Item $wf.FullName -Force -ErrorAction SilentlyContinue
                    }
                    $wins = 0; $total = 0
                    foreach ($win in ($byWin.Keys | Sort-Object)) {
                        $safe  = ($win -replace '[^A-Za-z0-9._-]', '_')
                        $tf    = Join-Path $winDir "$safe.tabs"
                        $lines = @()
                        foreach ($m in $byWin[$win]) {
                            $lbl = if ($m.Label) { $m.Label } elseif ($m.Branch -and $m.Branch -notin @('main','master')) { $m.Branch } else { Split-Path $m.Path -Leaf }
                            $lines += ("{0}`t{1}`t{2}" -f $m.Ws, $lbl, $m.Path)
                        }
                        Set-Content -Path $tf -Value $lines -Encoding UTF8
                        $wins++; $total += $lines.Count
                        Write-Color ("  [{0}] {1} tab(s)" -f $win, $lines.Count) Green
                        foreach ($m in $byWin[$win]) {
                            $lbl = if ($m.Label) { $m.Label } elseif ($m.Branch) { $m.Branch } else { Split-Path $m.Path -Leaf }
                            Write-Host ('        {0,-28} {1}' -f $lbl, $m.Path) -ForegroundColor DarkGray
                        }
                    }
                    Write-Color ("rebuilt {0} window(s), {1} tab(s) from the ledger (existing worktrees)" -f $wins, $total) Cyan
                    Write-Color "  reopen them:  gwt sessions restore -ByTabs -IncludeEnded" DarkGray
                    Write-Color "  then freeze:  gwt sessions snapshot" DarkGray
                    return
                }

                $files = @(Get-ChildItem $winDir -Filter '*.tabs' -ErrorAction SilentlyContinue | Sort-Object Name)
                if (-not $files.Count) { Write-Color "no windows tracked yet (start a session to populate)" DarkGray; return }

                # -Window narrows to one window so you can pick up where you left off
                # (e.g. 'gwt sessions tabs test -Window ziti'). Exact name wins; otherwise
                # substring, so 'ziti' hits the 'ziti' window, not ziti-sdk-csharp too.
                if ($Window) {
                    $exact = @($files | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $Window })
                    $files = if ($exact.Count) { $exact } else { @($files | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -like "*$Window*" }) }
                    if (-not $files.Count) { Write-Color "no tracked window matches -Window '$Window'" Yellow; return }
                }

                if ($mode -eq 'status') {
                    # Reconcile the tab registry against the ledger, both directions:
                    #   ghost     -- a .tabs line whose session is no longer alive (prune drops it)
                    #   untracked -- an ALIVE session that no .tabs file lists (should be a tab
                    #                but isn't). These are the "leftover" sessions; offer to
                    #                register each into its window so restore / order see it.
                    $meta = @{}   # WtSession -> { Label; Branch; Path; Window; Pids }
                    foreach ($sf in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                        try { $se = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
                        if (-not $se.WtSession) { continue }
                        $ws = $se.WtSession
                        if (-not $meta.ContainsKey($ws)) {
                            $meta[$ws] = [pscustomobject]@{ Ws=$ws; Label=$null; Branch=$se.Branch; Path=($se.WorktreePath -replace '/','\'); Window=$se.WindowName; Pids=@() }
                        }
                        if ($se.Label)      { $meta[$ws].Label  = $se.Label }
                        if ($se.WindowName) { $meta[$ws].Window = $se.WindowName }
                        if ($se.Pid -and [int]$se.Pid -gt 0) { $meta[$ws].Pids += [int]$se.Pid }
                    }
                    # Liveness over every ledger PID (one CIM query if P/Invoke can't see them).
                    $allPids = @($meta.Values | ForEach-Object { $_.Pids } | Sort-Object -Unique)
                    $aliveP  = @{}
                    $useCim  = $false
                    foreach ($p in $allPids) { $r = _IsPidAlive $p; if ($null -eq $r) { $useCim = $true; break }; if ($r) { $aliveP[$p] = $true } }
                    if ($useCim -and $allPids.Count) {
                        $aliveP = @{}
                        $filter = ($allPids | ForEach-Object { "ProcessId=$_" }) -join ' OR '
                        Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object { $aliveP[[int]$_.ProcessId] = $true }
                    }
                    $wsAlive = { param($ws) $meta.ContainsKey($ws) -and (@($meta[$ws].Pids | Where-Object { $aliveP[$_] }).Count -gt 0) }

                    # Ghost tab lines + the set of WtSessions that ARE in some .tabs file.
                    $inTabs = @{}
                    $ghosts = @()
                    foreach ($wf in $files) {
                        $w = [IO.Path]::GetFileNameWithoutExtension($wf.Name)
                        foreach ($ln in @(Get-Content $wf.FullName -ErrorAction SilentlyContinue)) {
                            $ws = ($ln -split "`t")[0]; if (-not $ws) { continue }
                            $inTabs[$ws] = $true
                            if (-not (& $wsAlive $ws)) {
                                $lbl = ($ln -split "`t"); $lbl = if ($lbl.Count -ge 2) { $lbl[1] } else { '(?)' }
                                $ghosts += [pscustomobject]@{ Window=$w; Label=$lbl }
                            }
                        }
                    }
                    # Alive sessions in no .tabs file. -Window (if given) narrows to that window.
                    $untracked = @($meta.Values | Where-Object {
                        (& $wsAlive $_.Ws) -and -not $inTabs.ContainsKey($_.Ws) -and
                        (-not $Window -or ($_.Window -and (($_.Window -ieq $Window) -or ($_.Window -like "*$Window*"))))
                    })

                    Write-Color "tab / session reconciliation:" Cyan
                    if ($ghosts.Count) {
                        Write-Color "  ghost tab lines (session no longer alive):" Yellow
                        foreach ($g in $ghosts) { Write-Color ("    [{0}] {1}" -f $g.Window, $g.Label) DarkGray }
                        # Fold prune in: default-yes so 'status' both reports AND cleans,
                        # and you never need a separate 'tabs prune' pass.
                        $dropAns = ("" + (Read-Host "  drop these $($ghosts.Count) ghost line(s) now? (Y/n)")).Trim()
                        if ([string]::IsNullOrWhiteSpace($dropAns) -or $dropAns -match '^[Yy]') {
                            $dropped = 0
                            foreach ($wf in $files) {
                                $lines = @(Get-Content $wf.FullName -ErrorAction SilentlyContinue)
                                $keep  = @($lines | Where-Object { & $wsAlive (($_ -split "`t")[0]) })
                                if ($keep.Count -ne $lines.Count) {
                                    if ($keep.Count) { Set-Content -Path $wf.FullName -Value $keep -Encoding UTF8 }
                                    else { Remove-Item $wf.FullName -Force -ErrorAction SilentlyContinue }
                                    $dropped += ($lines.Count - $keep.Count)
                                }
                            }
                            Write-Color "    dropped $dropped ghost line(s)" Green
                        }
                    } else {
                        Write-Color "  no ghost tab lines" DarkGray
                    }
                    if (-not $untracked.Count) {
                        Write-Color "  every alive session is tracked in a tab registry" Green
                        return
                    }
                    Write-Color "  ALIVE sessions not in any tab registry (should be open, untracked):" Yellow
                    foreach ($m in $untracked) {
                        $lbl = if ($m.Label) { $m.Label } else { $m.Branch }
                        $win = if ($m.Window) { $m.Window } else { '(no window recorded)' }
                        Write-Color ("    [{0}] {1} @ {2}" -f $win, $lbl, $m.Path) DarkGray
                    }
                    $ans = ("" + (Read-Host "  register these into their windows' tab order? (appended; run 'tabs test' to place) (y/N)")).Trim()
                    if ($ans -notmatch '^[Yy]') { Write-Color "  left as-is" DarkGray; return }
                    $added = 0
                    foreach ($m in $untracked) {
                        if (-not $m.Window) { Write-Color ("    skip (no window): {0}" -f $m.Branch) Yellow; continue }
                        $lbl  = if ($m.Label) { $m.Label } else { $m.Branch }
                        $safe = ($m.Window -replace '[^A-Za-z0-9._-]', '_')
                        $tf   = Join-Path $winDir "$safe.tabs"
                        $line = "{0}`t{1}`t{2}" -f $m.Ws, $lbl, $m.Path
                        Add-Content -Path $tf -Value $line -Encoding UTF8
                        Write-Color ("    registered '{0}' -> [{1}]" -f $lbl, $m.Window) Green
                        $added++
                    }
                    Write-Color "  added $added tab line(s). run 'gwt sessions tabs test' to fix their order." DarkGray
                    return
                }

                # Liveness scoped to the tabs actually in the registry -- NOT the whole
                # OS process table. Collect the WtSessions the .tabs files reference, map
                # them to PIDs from the ledger, then run ONE Win32_Process query filtered
                # to just those PIDs (WQL 'ProcessId=a OR ProcessId=b ...'). A WtSession is
                # live if ANY of its ledger entries' PIDs is alive (handles dup entries).
                $tabWt = @{}
                foreach ($wf in $files) {
                    foreach ($ln in @(Get-Content $wf.FullName -ErrorAction SilentlyContinue)) {
                        $ws = ($ln -split "`t")[0]
                        if ($ws) { $tabWt[$ws] = $true }
                    }
                }
                # Map each tracked WtSession to its EXPLICIT ledger Label only (from 'gwt
                # rename'). Display precedence is: explicit ledger Label -> the .tabs line's
                # own label (what you set at 'tabs set' time) -> '(?)'. The bare Branch is
                # NOT a fallback here -- it would wrongly show 'main' for every main-clone
                # tab, clobbering the label you set (e.g. 'ziti-openwrt', 'main:dotfiles').
                $wtPids  = @{}
                $wtLabel = @{}
                foreach ($sf in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                    try { $se = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
                    if (-not ($se.WtSession -and $tabWt.ContainsKey($se.WtSession))) { continue }
                    if ($se.Label) { $wtLabel[$se.WtSession] = $se.Label }
                    if ($se.Pid -and [int]$se.Pid -gt 0) {
                        if (-not $wtPids.ContainsKey($se.WtSession)) { $wtPids[$se.WtSession] = @() }
                        $wtPids[$se.WtSession] += [int]$se.Pid
                    }
                }
                $liveWt  = @{}
                $allPids = @($wtPids.Values | ForEach-Object { $_ } | Sort-Object -Unique)
                if ($allPids.Count) {
                    $aliveP = @{}
                    $useCim = $false
                    foreach ($p in $allPids) {
                        $r = _IsPidAlive $p
                        if ($null -eq $r) { $useCim = $true; break }   # P/Invoke unavailable
                        if ($r) { $aliveP[$p] = $true }
                    }
                    if ($useCim) {
                        # Fallback: one filtered CIM query (slower, but cross-user reliable).
                        Write-Color ("  checking {0} tab process(es)..." -f $allPids.Count) DarkGray
                        $aliveP = @{}
                        $filter = ($allPids | ForEach-Object { "ProcessId=$_" }) -join ' OR '
                        Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object { $aliveP[[int]$_.ProcessId] = $true }
                    }
                    foreach ($ws in $wtPids.Keys) {
                        if (@($wtPids[$ws] | Where-Object { $aliveP.ContainsKey($_) }).Count) { $liveWt[$ws] = $true }
                    }
                }

                # Collect dead-PID tab lines stripped during 'show' so they are reported
                # once at the end instead of interleaved with the live listing.
                $removedDead = @()
                foreach ($wf in $files) {
                    $win = [System.IO.Path]::GetFileNameWithoutExtension($wf.Name)

                    if ($mode -eq 'prune') {
                        $tlines  = @(Get-Content $wf.FullName -ErrorAction SilentlyContinue)
                        $kept    = @($tlines | Where-Object { $liveWt.ContainsKey(($_ -split "`t")[0]) })
                        $dropped = $tlines.Count - $kept.Count
                        if ($dropped -gt 0) {
                            Set-Content -Path $wf.FullName -Value $kept -Encoding UTF8
                            Write-Color ("[{0}] dropped {1} exited tab(s), {2} live remain" -f $win, $dropped, $kept.Count) Yellow
                        } else {
                            Write-Color ("[{0}] clean ({1} live tab(s))" -f $win, $kept.Count) DarkGray
                        }
                        continue
                    }

                    if ($mode -eq 'test') {
                        # Dead-PID lines are known junk -- strip them BEFORE focusing
                        # anything, so 'test' never tries to open an already-exited tab.
                        $raw      = @(Get-Content $wf.FullName -ErrorAction SilentlyContinue)
                        $liveOnly = @($raw | Where-Object { $liveWt.ContainsKey(($_ -split "`t")[0]) })
                        if ($liveOnly.Count -ne $raw.Count) {
                            if ($liveOnly.Count) { Set-Content -Path $wf.FullName -Value $liveOnly -Encoding UTF8 }
                            else { Remove-Item $wf.FullName -Force -ErrorAction SilentlyContinue }
                            Write-Color ("[{0}] dropped {1} exited tab(s) before testing" -f $win, ($raw.Count - $liveOnly.Count)) DarkGray
                        }
                        if (-not $liveOnly.Count) { continue }
                        # Correcting loop: focus each tab, ask if it landed right. Advance
                        # only on 'y'. Any fix stays at the SAME index and re-reads, so the
                        # tab that shifts into this slot gets verified next (no restart at 0,
                        # and after moving a branch away we ask what's actually here now).
                        Write-Color ("[{0}] verifying tab order..." -f $win) Cyan
                        $tlines = [System.Collections.ArrayList]@(Get-Content $wf.FullName -ErrorAction SilentlyContinue)
                        $i = 0
                        $skipped = $false
                        while ($i -lt $tlines.Count) {
                            $parts = $tlines[$i] -split "`t"
                            $ws    = $parts[0]
                            # Prefer the CURRENT label from the ledger (picks up 'gwt rename'
                            # and tangent-style names) over the possibly-stale .tabs label.
                            $br    = if ($wtLabel.ContainsKey($ws)) { $wtLabel[$ws] }
                                     elseif ($parts.Count -ge 2)    { $parts[1] }
                                     else                           { '(?)' }
                            & runas /user:claude /savecred "wt.exe -w `"$win`" focus-tab -t $i" 2>&1 | Out-Null
                            Start-Sleep -Milliseconds 200   # let wt raise the tab
                            _RefocusSelfWindow               # then take focus back so input lands here
                            $r = (Read-Host "    -t $i should be '$br'. correct? (y/n/s=stop/x=skip window/r=rename)").Trim().ToLower()
                            if ($r -eq 's') { Write-Color "  test stopped" DarkGray; return }
                            if ($r -eq 'x') { Write-Color "  [$win] skipped -- moving on" DarkGray; $skipped = $true; break }
                            if ($r -eq 'r') {
                                # Rename the session at this tab: set the ledger Label on every
                                # entry for this WtSession, refresh the in-memory label, and
                                # rewrite the .tabs line so all views agree.
                                $nl = (Read-Host "      new label for '$br' (blank = cancel)").Trim()
                                if ($nl) {
                                    foreach ($sf in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                                        try { $se = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
                                        if ($se.WtSession -ne $ws) { continue }
                                        if ($se.PSObject.Properties.Match('Label').Count) { $se.Label = $nl }
                                        else { Add-Member -InputObject $se -NotePropertyName Label -NotePropertyValue $nl -Force }
                                        ($se | ConvertTo-Json -Depth 5) | Set-Content -Path $sf.FullName -Encoding UTF8
                                    }
                                    $wtLabel[$ws] = $nl
                                    $p2   = $tlines[$i] -split "`t"
                                    $rest = if ($p2.Count -ge 3) { $p2[2] } else { '' }
                                    $tlines[$i] = "{0}`t{1}`t{2}" -f $ws, $nl, $rest
                                    Set-Content -Path $wf.FullName -Value @($tlines) -Encoding UTF8
                                    Write-Color "      renamed to '$nl' -- re-checking tab $i" Green
                                }
                                continue   # stay at $i, re-show with the new label
                            }
                            if ($r -eq 'y' -or [string]::IsNullOrWhiteSpace($r)) { $i++; continue }
                            # 'n' -- the line at $i is wrong for this tab. Ask what IS here,
                            # then resolve that name against the ledger so an untracked-but-
                            # known session (a worktree tab that never self-registered, or whose
                            # order drifted) gets adopted into the correct slot.
                            $name = (Read-Host "      what IS on tab ${i}? (branch/label; blank if this tab is closed/empty)").Trim()
                            if (-not $name) {
                                $tlines.RemoveAt($i)
                                Set-Content -Path $wf.FullName -Value @($tlines) -Encoding UTF8
                                Write-Color "      dropped '$br' -- re-checking tab $i" DarkGray
                                continue   # stay at $i: whatever shifts into this slot is next
                            }
                            # Find a session whose label or branch matches, preferring one in
                            # THIS window (handles the same branch open in two windows).
                            $hit = $null
                            foreach ($sf in (Get-ChildItem $script:SessionDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                                try { $se = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
                                if (-not $se.WtSession) { continue }
                                $lbl = if ($se.Label) { $se.Label } else { $se.Branch }
                                if (($lbl -ieq $name) -or ($se.Branch -ieq $name)) {
                                    if (-not $hit -or ($se.WindowName -ieq $win)) { $hit = $se }
                                }
                            }
                            if (-not $hit) {
                                Write-Color "      '$name' isn't a known gwt session -- run 'gwt sessions tabs set' from that tab to track it." Yellow
                                Write-Color "      leaving tab $i as-is and moving on." DarkGray
                                $i++; continue
                            }
                            $hlbl  = if ($hit.Label) { $hit.Label } else { $hit.Branch }
                            $hpath = ($hit.WorktreePath -replace '/', '\')
                            # If this session already has a line elsewhere, move it; else insert.
                            $j = -1
                            for ($k = 0; $k -lt $tlines.Count; $k++) { if ((($tlines[$k] -split "`t")[0]) -eq $hit.WtSession) { $j = $k; break } }
                            if ($j -ge 0) { $mv = $tlines[$j]; $tlines.RemoveAt($j) }
                            else          { $mv = "{0}`t{1}`t{2}" -f $hit.WtSession, $hlbl, $hpath }
                            $tlines.Insert([Math]::Min($i, $tlines.Count), $mv)
                            Set-Content -Path $wf.FullName -Value @($tlines) -Encoding UTF8
                            Write-Color "      set tab $i = '$hlbl'" Green
                            $i++; continue   # you named it, so advance -- don't re-ask the same tab
                        }
                        if (-not $skipped) { Write-Color ("[{0}] order confirmed" -f $win) Green }
                        continue
                    }

                    # show is READ-ONLY. It NEVER rewrites or deletes the registry -- only
                    # 'prune' and 'clean' remove entries. Dead-pid tabs are shown marked
                    # 'dead', not stripped, so a churn (drag-kill) never erases your layout
                    # just because you looked at it.
                    $tlines = @(Get-Content $wf.FullName -ErrorAction SilentlyContinue)
                    if (-not $tlines.Count) { continue }
                    $liveN = @($tlines | Where-Object { $liveWt.ContainsKey(($_ -split "`t")[0]) }).Count
                    Write-Color ("[{0}]  {1} tab(s) ({2} live)" -f $win, $tlines.Count, $liveN) Cyan
                    for ($i = 0; $i -lt $tlines.Count; $i++) {
                        $parts = $tlines[$i] -split "`t"
                        $ws    = $parts[0]
                        $br    = if ($parts.Count -ge 2) { $parts[1] } else { '(?)' }
                        $path  = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                        $live  = $liveWt.ContainsKey($ws)
                        # Live PID(s) from the ledger, so you can match a locked worktree to
                        # its tab. A dead-pid line is shown 'dead', kept in the registry.
                        $tabPids = if ($aliveP -and $wtPids.ContainsKey($ws)) { @($wtPids[$ws] | Where-Object { $aliveP.ContainsKey($_) } | Sort-Object -Unique) } else { @() }
                        $pidTag  = if ($tabPids.Count) { 'pid ' + ($tabPids -join ',') } elseif ($live) { 'pid ?' } else { 'dead' }
                        $color   = if ($live) { 'Gray' } else { 'DarkGray' }
                        Write-Host ('    -t {0,-2}  {1,-12} {2,-28} {3}' -f $i, $pidTag, $br, $path) -ForegroundColor $color
                    }
                }
                if ($mode -eq 'test') {
                    # Audit: any ALIVE session that no .tabs file tracks is an OPEN tab 'test'
                    # never saw. Rebuild the tracked set from the CURRENT .tabs (the loop may
                    # have added lines), then flag alive sessions missing from it.
                    $trackedWs = @{}
                    foreach ($tf in (Get-ChildItem $winDir -Filter '*.tabs' -ErrorAction SilentlyContinue)) {
                        foreach ($ln in @(Get-Content $tf.FullName -ErrorAction SilentlyContinue)) {
                            $ws0 = ($ln -split "`t")[0]; if ($ws0) { $trackedWs[$ws0] = $true }
                        }
                    }
                    $seenWs = @{}; $untracked = @()
                    foreach ($e in @($entriesAllRepos | Where-Object { $_.Alive -and $_.WtSession })) {
                        if ($trackedWs.ContainsKey($e.WtSession) -or $seenWs.ContainsKey($e.WtSession)) { continue }
                        $seenWs[$e.WtSession] = $true; $untracked += $e
                    }
                    Write-Host ""
                    if (-not $untracked.Count) {
                        Write-Color "audit: every alive session is tracked -- no open tab is missing" Green
                    } else {
                        Write-Color ("audit: {0} OPEN session(s) are NOT in any .tabs (never verified above):" -f $untracked.Count) Yellow
                        foreach ($e in $untracked) {
                            $lbl = if ($e.Label) { $e.Label } else { $e.Branch }
                            $w   = if ($e.WindowName) { $e.WindowName } else { '(no window)' }
                            Write-Color ("    [{0}] {1} @ {2}" -f $w, $lbl, $e.WorktreePath) DarkGray
                        }
                        $ans = (Read-Host "  register these into their windows now? (appended; re-run 'tabs test' to order) (y/N)").Trim()
                        if ($ans -match '^[Yy]') {
                            $added = 0
                            foreach ($e in $untracked) {
                                if (-not $e.WindowName) { Write-Color ("    skip (no window recorded): {0}" -f $e.Branch) Yellow; continue }
                                $lbl  = if ($e.Label) { $e.Label } else { $e.Branch }
                                $safe = ($e.WindowName -replace '[^A-Za-z0-9._-]', '_')
                                $line = "{0}`t{1}`t{2}" -f $e.WtSession, $lbl, ($e.WorktreePath -replace '/', '\')
                                Add-Content -Path (Join-Path $winDir "$safe.tabs") -Value $line -Encoding UTF8
                                Write-Color ("    registered '{0}' -> [{1}]" -f $lbl, $e.WindowName) Green
                                $added++
                            }
                            if ($added) { Write-Color "  added $added -- re-run 'gwt sessions tabs test' to place them in order" DarkGray }
                        }
                    }
                }
                if ($mode -eq 'show') {
                    if ($removedDead.Count) {
                        Write-Host ""
                        Write-Color ("removing dead claudes ({0}):" -f $removedDead.Count) Yellow
                        foreach ($d in $removedDead) {
                            Write-Host ('    [{0,-13}] {1,-30} {2}' -f $d.Window, $d.Branch, $d.Path)
                        }
                    }
                    Write-Color "modes: tabs set (register this tab) | tabs test (verify+fix) | tabs status (reconcile) | tabs prune | tabs clear (reset)" DarkGray
                    Write-Color "  tabs test: -Window <name> narrows to one window; per-tab 'x' skips window, 'r' renames" DarkGray
                    Write-Color "  tabs status: reports ghost lines + ALIVE sessions missing from the registry (offers to register them)" DarkGray
                }
                return
            }
            'restore' {
                # Include EVERYTHING by default (alive + non-alive) so the set/preview shows
                # the full layout you'll get back -- alive sessions become ABORTED on reboot.
                # A real restore still skips anything actually running (checked at spawn), so
                # this never double-opens. -ExcludeActive drops the running ones from the set.
                # Restore is inherently GLOBAL -- you want every session back, not just this
                # repo's -- so always work across all repos, ignoring the cwd scope.
                $allStale = @($entriesAllRepos | Where-Object { (-not $ExcludeActive) -or (-not $_.Alive) })
                # A discriminator ($Match/$Name) may match a session in ANOTHER repo, so
                # don't bail early on an empty scoped set when one is passed -- fall through
                # to the filter, which widens to all repos and offers to jump.
                $hasFilter = [bool]($Match -or $Name)
                if (-not $allStale.Count -and -not $hasFilter) { Write-Color "no paused sessions to restore (everything is ACTIVE)" DarkGray; return }

                # Dedupe by WorktreePath to ONE representative per path FIRST, so the ENDED
                # filter below sees each path's CURRENT state -- not a stale ABORTED duplicate
                # that would otherwise resurrect a session you actually closed. Representative
                # = the alive entry if any, else newest by LastStateChange (true current
                # state). Also flag whether ANY entry for the path is Saved.
                $stale = $allStale |
                         Group-Object WorktreePath |
                         ForEach-Object {
                             $rep = $_.Group | Where-Object Alive | Select-Object -First 1
                             if (-not $rep) {
                                 $rep = $_.Group | Sort-Object `
                                     @{Expression={ try { [datetime]$_.LastStateChange } catch { [datetime]::MinValue } }}, `
                                     @{Expression={ if ($_.LastSpawnedAt) { $_.LastSpawnedAt } else { $_.SpawnedAt } }} `
                                     -Descending | Select-Object -First 1
                             }
                             $rep | Add-Member -NotePropertyName _AnySaved -NotePropertyValue ([bool]($_.Group | Where-Object Saved)) -Force
                             $rep
                         }
                $dedupCount = @($stale).Count

                # Skip ENDED (you closed those deliberately) unless -IncludeEnded. SAVED always
                # survives -- 'gwt sessions save <match>' is the explicit "keep in restore" hatch.
                if (-not $IncludeEnded) {
                    $before = @($stale).Count
                    $stale  = @($stale | Where-Object { $_.State -ne 'ended' -or $_._AnySaved })
                    $droppedEnded = $before - @($stale).Count
                    if ($droppedEnded -gt 0) {
                        Write-Color "skipping $droppedEnded ENDED session(s) -- pass -IncludeEnded, or 'gwt sessions save' to keep one" DarkGray
                    }
                    if (-not @($stale).Count -and -not $hasFilter) { Write-Color "no recoverable sessions to restore (all closed / filtered)" DarkGray; return }
                }

                # If ANY session is Saved (e.g. after 'gwt sessions save -All' before a reboot),
                # treat that as the intended set: restore ONLY Saved + still-running, and drop
                # every unsaved dead session -- the stale aborteds you never asked for. With no
                # saves at all, fall back to the aborted-recovery heuristic below (crash case).
                if (@($stale | Where-Object { $_._AnySaved }).Count) {
                    $before = @($stale).Count
                    $stale  = @($stale | Where-Object { $_._AnySaved -or $_.Alive })
                    $droppedUnsaved = $before - @($stale).Count
                    if ($droppedUnsaved -gt 0) {
                        Write-Color "restricting to Saved + running -- dropped $droppedUnsaved unsaved session(s) (you have Saved sessions)" DarkGray
                    }
                }

                # Replay in original-add order.
                $stale = @($stale | Sort-Object @{Expression={ if ($_.FirstSpawnedAt) { $_.FirstSpawnedAt } else { $_.SpawnedAt } }})

                # Recency + transcript guard. A session is only restorable if its transcript
                # jsonl exists ('claude --resume' has nothing to replay otherwise) and it was
                # active recently. Saved sessions bypass the age cutoff (you asked to keep them);
                # the transcript check always applies. -MaxAgeDays 0 disables the age cutoff.
                $cut  = if ($MaxAgeDays -gt 0) { (Get-Date).AddDays(-$MaxAgeDays) } else { $null }
                $noTx = 0; $tooOld = 0
                $stale = @($stale | Where-Object {
                    $j = _SessionJournal $_.ClaudeSessionId
                    if (-not $j) { $noTx++; return $false }
                    if ($cut -and $j.LastActive -lt $cut -and -not $_._AnySaved) { $tooOld++; return $false }
                    $true
                })
                if ($noTx  -gt 0) { Write-Color "skipping $noTx session(s) with no transcript (nothing to replay)" DarkGray }
                if ($tooOld -gt 0) { Write-Color "skipping $tooOld session(s) last active > $MaxAgeDays day(s) ago -- pass -MaxAgeDays 0 to include" DarkGray }
                if (-not $stale.Count -and -not $hasFilter) { Write-Color "no recoverable sessions to restore (recent + has-transcript)" DarkGray; return }

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
                    if ($filtered.Count) {
                        $stale = $filtered
                        Write-Color "filter -> $($stale.Count) match(es)" Cyan
                    } else {
                        $needle   = if ($Match) { $Match } else { $Name }
                        $matchesF = {
                            param($e)
                            (-not $Name  -or $e.Branch -ieq $Name) -and
                            (-not $Match -or ($e.Branch -like "*$Match*" -or $e.WorktreePath -like "*$Match*" -or $e.WindowName -like "*$Match*"))
                        }

                        # Before declaring "no match", check whether it is already RUNNING.
                        # A live match isn't a restore at all -- offer to focus its tab. This
                        # is why 'no paused entries' was misleading: the session was alive.
                        $aliveMatch = @($entriesAllRepos | Where-Object { $_.Alive -and (& $matchesF $_) })
                        if ($aliveMatch.Count) {
                            $m = $aliveMatch[0]
                            Write-Host ""
                            Write-Color ("  '{0}' is already running @ {1}" -f $needle, $m.WorktreePath) Green
                            $f = Read-Host "  focus its tab instead? (Y/n)"
                            if ([string]::IsNullOrWhiteSpace($f) -or $f -match '^[Yy]$') {
                                & $PSCommandPath -Command 'focus' -Target $needle
                            } else {
                                Write-Color "  ok, leaving it" DarkGray
                            }
                            return
                        }

                        # Not running. If we were scoped (not -All), widen the PAUSED search
                        # to every repo and offer to jump there.
                        $expanded = @()
                        if ($scopeResult.Scoped -and -not $All) {
                            $poolAll = @($entriesAllRepos | Where-Object { -not $_.Alive })
                            if (-not $IncludeEnded) { $poolAll = @($poolAll | Where-Object { $_.State -ne 'ended' }) }
                            $poolAll = @($poolAll | Group-Object WorktreePath | ForEach-Object {
                                $_.Group | Sort-Object @{Expression={ if ($_.LastSpawnedAt) { $_.LastSpawnedAt } else { $_.SpawnedAt } }} -Descending | Select-Object -First 1
                            })
                            $expanded = @($poolAll | Where-Object { & $matchesF $_ })
                        }
                        if (-not $expanded.Count) {
                            Write-Color "no paused entries match the given filter" Yellow
                            return
                        }
                        Write-Host ""
                        Write-Color ("  not here: '{0}' isn't a paused session in {1}" -f $needle, $scopeResult.ScopeName) Yellow
                        if ($expanded.Count -eq 1) {
                            Write-Color   "  found it in another worktree:" Green
                            Write-Host  ('      {0,-30} @ {1}' -f $expanded[0].Branch, $expanded[0].WorktreePath) -ForegroundColor Cyan
                            Write-Host ""
                            $jump = Read-Host "  restore it from there? (y/N)"
                            if ($jump -notmatch '^[Yy]') { Write-Color "  aborted" DarkGray; return }
                            $stale = @($expanded)
                        } else {
                            Write-Color ("  found in {0} other worktrees -- pick one:" -f $expanded.Count) Green
                            $pick = _TuiSelect -Items @($expanded) -Prompt "  which worktree to restore?" `
                                -DisplayScript { param($e) '{0,-30} @ {1}' -f $e.Branch, $e.WorktreePath }
                            if (-not $pick) { Write-Color "  aborted" DarkGray; return }
                            $stale = @($pick)
                        }
                    }
                }

                $dupes = $allStale.Count - $dedupCount
                if (-not $Match -and $dupes -gt 0) {
                    Write-Color "skipping $dupes duplicate(s) -- run 'gwt sessions clean' to clean them" DarkGray
                }

                $autoWinFor   = { param($s) if ($s.Repo) { $s.Repo } else { $s.WindowName } }
                $pickedWindow = $null
                $restoreMode  = 'auto'

                # Restore mode: 'tabs' (rebuild the exact .tabs layout -- the default) or
                # 'sessions' (open order + auto/previous window prompt). A flag forces it;
                # otherwise a picker asks with 'by tabs' pre-selected. -y or a non-
                # interactive shell takes the default without prompting. Either way the
                # chosen mode is announced so it's never a mystery.
                if     ($ByTabs)     { $modeChoice = 'tabs' }
                elseif ($BySessions) { $modeChoice = 'sessions' }
                elseif ($y -or [Console]::IsInputRedirected) { $modeChoice = 'tabs' }
                else {
                    $mItems = @('by tabs -- rebuild the exact .tabs layout (recommended)',
                                'by sessions -- open order, auto/previous windows')
                    $mPick = _TuiSelect -Items $mItems -Prompt 'restore mode:' -DefaultIndex 0
                    if (-not $mPick) { Write-Color 'aborted' DarkGray; return }
                    $modeChoice = if ($mPick -like 'by tabs*') { 'tabs' } else { 'sessions' }
                }
                Write-Color ("restore mode: {0}" -f $(if ($modeChoice -eq 'tabs') { 'by tabs (rebuild the .tabs layout)' } else { 'by sessions (open order + window prompt)' })) Cyan

                # tabs mode: reopen into each session's audited .tabs window, in .tabs order,
                # so a restart reconstructs the exact layout you verified. Sessions in no
                # .tabs fall back to their auto (repo) window, appended after the tracked
                # ones. Done BEFORE the dry-run preview so the preview shows the real order.
                $tabsOrder = @{}
                if ($modeChoice -eq 'tabs') {
                    $tabsWinDir = Join-Path $script:WtRoot 'windows'
                    # Live .tabs first, then the .snapshot (from 'save -All') fills any line a
                    # clean shutdown stripped via SessionEnd. Live wins; snapshot only adds
                    # cwds not already present.
                    $tabsSrcs = @($tabsWinDir)
                    $snapDir  = Join-Path $tabsWinDir '.snapshot'
                    if (Test-Path $snapDir) { $tabsSrcs += $snapDir }
                    foreach ($src in $tabsSrcs) {
                        foreach ($tf in (Get-ChildItem $src -Filter '*.tabs' -ErrorAction SilentlyContinue)) {
                            $w = [IO.Path]::GetFileNameWithoutExtension($tf.Name); $idx = 0
                            foreach ($ln in @(Get-Content $tf.FullName -ErrorAction SilentlyContinue)) {
                                $p = $ln -split "`t"
                                if ($p.Count -ge 3) {
                                    $cwd = ($p[2] -replace '/', '\').TrimEnd('\').ToLower()
                                    if ($cwd -and -not $tabsOrder.ContainsKey($cwd)) { $tabsOrder[$cwd] = @{ Window = $w; Index = $idx } }
                                }
                                $idx++
                            }
                        }
                    }
                    if (-not $tabsOrder.Count) {
                        Write-Color "  -ByTabs: no .tabs registry found -- falling back to auto ordering" Yellow
                    } else {
                        $restoreMode = 'tabs'
                        # -ByTabs restores EXACTLY the tab registry. Drop anything not in .tabs
                        # so the list is ONLY your tabs -- never a 'tab -' row.
                        $before = @($stale).Count
                        $stale  = @($stale | Where-Object { $tabsOrder.ContainsKey((($_.WorktreePath -replace '/','\').TrimEnd('\').ToLower())) })
                        $droppedUntracked = $before - @($stale).Count
                        if ($droppedUntracked -gt 0) {
                            Write-Color "  dropped $droppedUntracked session(s) not in any .tabs -- -ByTabs restores only tabbed sessions" DarkGray
                        }
                        $keyFor = {
                            param($s)
                            $k = ($s.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()
                            [pscustomobject]@{ W = $tabsOrder[$k].Window; I = [int]$tabsOrder[$k].Index }
                        }
                        # Sort by window, then tab index within that window -- but always
                        # restore the 'tangent' window FIRST (it holds the driver session).
                        $stale = @($stale | Sort-Object `
                            @{ Expression = { if ((& $keyFor $_).W -ieq 'tangent') { 0 } else { 1 } } }, `
                            @{ Expression = { (& $keyFor $_).W } }, `
                            @{ Expression = { (& $keyFor $_).I } })
                    }
                }

                # -DryRun: show the ordered set restore WOULD open and stop before any
                # prompt or spawn. Order is .tabs layout under -ByTabs, else open order.
                if ($DryRun) {
                    if (-not @($stale).Count) { Write-Color "nothing to restore" DarkGray; return }
                    function script:_RstCell($v, $w) { if ($null -eq $v) { $v = '' }; $v = "$v"; if ($v.Length -gt $w) { $v = $v.Substring(0, $w - 2) + '..' }; $v.PadRight($w) }
                    $dirOf = {
                        param($s)
                        $d = ($s.WorktreePath -replace '/','\')
                        $d = $d -replace '^.*\\worktrees\\github\\(openziti|netfoundry)\\','' -replace '^.*\\worktrees\\github\\','' -replace '^.*\\git\\github\\','' -replace '^.*\\worktrees\\',''
                        if (-not $d) { $d = if ($s.Label) { $s.Label } else { $s.Branch } }
                        $d
                    }
                    Write-Color ""
                    if ($restoreMode -eq 'tabs') {
                        # Grouped by wt window, then tab index (that's how $stale is already
                        # sorted), so the preview reads exactly like the layout it rebuilds.
                        Write-Color ("  DRY RUN -- would restore $(@($stale).Count) session(s), by wt window then tab index:") Cyan
                        $wW = 16; $wT = 3; $wL = 11; $wD = 30; $wM = 40
                        $rbar = "+{0}+{1}+{2}+{3}+{4}+" -f ('-'*($wW+2)), ('-'*($wT+2)), ('-'*($wL+2)), ('-'*($wD+2)), ('-'*($wM+2))
                        Write-Color $rbar
                        Write-Color ("| {0} | {1} | {2} | {3} | {4} |" -f (_RstCell 'wt window' $wW), (_RstCell 'tab' $wT), (_RstCell 'Last active' $wL), (_RstCell 'Directory' $wD), (_RstCell 'Where you left off' $wM))
                        Write-Color $rbar
                        foreach ($s in $stale) {
                            $k   = ($s.WorktreePath -replace '/','\').TrimEnd('\').ToLower()
                            $win = if ($tabsOrder.ContainsKey($k)) { $tabsOrder[$k].Window } else { (& $autoWinFor $s) }
                            $tab = if ($tabsOrder.ContainsKey($k)) { [string]$tabsOrder[$k].Index } else { '-' }
                            $j   = _SessionJournal $s.ClaudeSessionId
                            $la  = if ($j -and $j.LastActive) { $j.LastActive.ToString('MM-dd HH:mm') } else { '?' }
                            $mg  = if ($j) { $j.LastMsg } else { $null }
                            Write-Color ("| {0} | {1} | {2} | {3} | {4} |" -f (_RstCell $win $wW), (_RstCell $tab $wT), (_RstCell $la $wL), (_RstCell (& $dirOf $s) $wD), (_RstCell $mg $wM))
                        }
                        Write-Color $rbar
                    } else {
                        Write-Color ("  DRY RUN -- would restore $(@($stale).Count) session(s) in open order:") Cyan
                        $wN = 3; $wL = 11; $wD = 34; $wM = 48
                        $rbar = "+{0}+{1}+{2}+{3}+" -f ('-'*($wN+2)), ('-'*($wL+2)), ('-'*($wD+2)), ('-'*($wM+2))
                        Write-Color $rbar
                        Write-Color ("| {0} | {1} | {2} | {3} |" -f (_RstCell '#' $wN), (_RstCell 'Last active' $wL), (_RstCell 'Directory' $wD), (_RstCell 'Where you left off' $wM))
                        Write-Color $rbar
                        $i = 0
                        foreach ($s in $stale) {
                            $i++
                            $j   = _SessionJournal $s.ClaudeSessionId
                            $la  = if ($j -and $j.LastActive) { $j.LastActive.ToString('MM-dd HH:mm') } else { '?' }
                            $mg  = if ($j) { $j.LastMsg } else { $null }
                            Write-Color ("| {0} | {1} | {2} | {3} |" -f (_RstCell $i $wN), (_RstCell $la $wL), (_RstCell (& $dirOf $s) $wD), (_RstCell $mg $wM))
                        }
                        Write-Color $rbar
                    }
                    $aliveN = @($stale | Where-Object Alive).Count
                    if ($aliveN -gt 0) {
                        Write-Color "  note: $aliveN of these are running NOW. A live restore skips them; they reopen only" Yellow
                        Write-Color "        once not running -- e.g. after the reboot. Pass -ExcludeActive to hide them." DarkGray
                    }
                    Write-Color "  -- preview only; re-run without -DryRun to open them" Cyan
                    return
                }

                # Destination per entry, chosen by the bulk prompt below:
                #   auto     -> a window named after the repo, theme auto-picked (default)
                #   previous -> each entry's own saved window (reuse the previous choice)
                #   perentry -> open the picker for each so you can change individual ones
                #   tabs     -> each session's audited .tabs window (set above by -ByTabs)
                # -Window forces one window for all and skips the prompt.
                if (@($stale).Count -eq 1 -and -not $Window -and $restoreMode -ne 'tabs') {
                    $one     = $stale[0]
                    $autoWin = (& $autoWinFor $one)
                    Write-Color ("  $($one.Branch) @ $($one.WorktreePath)") DarkGray
                    # Mirror 'gwt claude': if this worktree has saved picks, offer to resume
                    # them (Y = default). 'n', or no saved picks, drops to the window picker.
                    $state   = if ($Reselect) { $null } else { Load-GwtState $one.WorktreePath }
                    $resumed = $false
                    if ($state) {
                        $sw      = "$($state.Window)"
                        $winDesc = if ($sw -eq '__auto__') { "auto '$autoWin'" }
                                   elseif ($sw -eq '' -or $sw -eq '__new__') { 'new window' }
                                   else { $sw }
                        $resp = Read-Host "  resume last picks? (window=$winDesc) (Y/n)"
                        if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
                            $pickedWindow = if ($sw -eq '__auto__') { $autoWin }
                                            elseif ($sw -eq '' -or $sw -eq '__new__') { $null }
                                            else { $sw }
                            $resumed = $true
                        }
                    }
                    if (-not $resumed) {
                        $pickedWindow = _SelectWtWindow -Repo $one.Repo
                        # Cancelling the picker (Esc/q/Ctrl-C) aborts -- do NOT fall to auto.
                        if (-not $pickedWindow) { Write-Color "  aborted" DarkGray; return }
                        if ($pickedWindow -eq '__auto__') { $pickedWindow = $autoWin }
                        if ($pickedWindow -eq '__new__')  { $pickedWindow = $null }
                    }
                } elseif (-not $Window -and $restoreMode -ne 'tabs') {
                    Write-Host ""
                    foreach ($s in $stale) {
                        $note = if ((& $autoWinFor $s) -ne $s.WindowName) { "  (was '$($s.WindowName)')" } else { '' }
                        Write-Color "  $($s.Branch) -> $(& $autoWinFor $s)$note" DarkGray
                    }
                    Write-Host ""
                    $resp = Read-Host "open all $(@($stale).Count) sessions? (Y=all auto / p=keep previous windows / c=change per entry / n=abort)"
                    if     ($resp -match '^[Pp]') { $restoreMode = 'previous' }
                    elseif ($resp -match '^[Cc]') { $restoreMode = 'perentry' }
                    elseif ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') { $restoreMode = 'auto' }
                    else { Write-Color "aborted" Yellow; return }
                }

                foreach ($s in $stale) {
                    if ($s.Alive) {
                        # In the set for previewing, but never re-open something already running.
                        Write-Color "  skip (already running): $($s.Branch) @ $($s.WorktreePath)" DarkGray
                        continue
                    }
                    if (-not (Test-Path $s.WorktreePath)) {
                        Write-Color "  skip (worktree gone): $($s.Branch) @ $($s.WorktreePath)" Yellow
                        continue
                    }
                    # Window resolution: -Window flag wins, then single-entry picker
                    # choice, then the bulk mode (auto repo window, or the saved one).
                    $effWindow = if ($Window)          { $Window }
                                 elseif ($pickedWindow) { $pickedWindow }
                                 elseif ($restoreMode -eq 'tabs') {
                                     $k = ($s.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()
                                     if ($tabsOrder.ContainsKey($k)) { $tabsOrder[$k].Window } else { (& $autoWinFor $s) }
                                 }
                                 elseif ($restoreMode -eq 'previous') { $s.WindowName }
                                 else                   { (& $autoWinFor $s) }
                    if ($restoreMode -eq 'perentry') {
                        # Confirm + let this entry change its window. Default is auto;
                        # pick the old window (e.g. pull-requests) for the ones you want.
                        $r = Read-Host "restore '$($s.Branch)' (was '$($s.WindowName)')? (Y/n)"
                        if ($r -match '^[Nn]') { Write-Color "    skipped" DarkGray; continue }
                        $pe = _SelectWtWindow -Repo $s.Repo -Prompt "  window for '$($s.Branch)' (Enter = auto):"
                        if ($pe -eq '__new__') { $pe = $null }
                        $effWindow = $pe
                    }
                    # A saved window of '__auto__' (from earlier buggy spawns) is not a
                    # real window -- resolve it to the repo window.
                    if ($effWindow -eq '__auto__') { $effWindow = (& $autoWinFor $s) }
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
                $didSaveAll = $false
                if (-not ($Match -or $Name -or $Window)) {
                    if ($val -and $All) {
                        $didSaveAll = $true
                        # 'gwt sessions save -All' = mark every RUNNING session Saved: the
                        # pre-reboot snapshot. Saved survives the ENDED skip, so restore
                        # brings them back even if a clean shutdown marks them ended.
                        # Use the pre-scope set so it catches running sessions in every repo.
                        $targets = @($entriesAllRepos | Where-Object Alive)
                        if (-not $targets.Count) { Write-Color "no running sessions to save" DarkGray; return }
                        if ($DryRun) {
                            Write-Color "DRY RUN -- would mark $($targets.Count) running session(s) Saved and merge them into the layout snapshot (nothing written):" Cyan
                            foreach ($m in ($targets | Sort-Object WindowName, Branch)) { Write-Color "  $($m.Branch) @ $($m.WorktreePath)" DarkGray }
                            return
                        }
                        Write-Color "saving $($targets.Count) running session(s) so they survive a reboot..." Cyan
                    } else {
                        Write-Color "usage: gwt sessions $Target <substring> [-Name <branch>] [-Window <name>]" Yellow
                        Write-Color "  or:  gwt sessions save -All   # save EVERY running session (pre-reboot snapshot)" DarkGray
                        return
                    }
                } else {
                    $targets = _ResolveSessionTargets -Pool $entries -Verb $Target
                }
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
                if ($didSaveAll) {
                    # Freeze the tab layout so 'restore -ByTabs' rebuilds it even after a clean
                    # shutdown strips the live .tabs lines. MERGE, don't overwrite: keep prior
                    # snapshot lines for sessions that are STILL Saved (so re-snapshotting when
                    # fewer are running never drops a Saved-but-not-running session), then add
                    # current live lines for anything new. Unsave a session to drop it.
                    $winDir  = Join-Path $script:WtRoot 'windows'
                    $snapDir = Join-Path $winDir '.snapshot'
                    [System.IO.Directory]::CreateDirectory($snapDir) | Out-Null

                    $savedCwd = @{}
                    foreach ($en in $entriesAllRepos) {
                        if ($en.Saved -and $en.WorktreePath) { $savedCwd[($en.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()] = $true }
                    }
                    $cwdOf = { param($ln) $c = ($ln -split "`t")[2]; if ($c) { ($c -replace '/', '\').TrimEnd('\').ToLower() } else { $null } }

                    $winFiles = @(@(Get-ChildItem $winDir -Filter '*.tabs' -EA SilentlyContinue | Select-Object -ExpandProperty Name) +
                                  @(Get-ChildItem $snapDir -Filter '*.tabs' -EA SilentlyContinue | Select-Object -ExpandProperty Name)) |
                                Sort-Object -Unique
                    $snapN = 0
                    foreach ($fn in $winFiles) {
                        $livePath  = Join-Path $winDir $fn
                        $priorPath = Join-Path $snapDir $fn
                        $live  = @(if (Test-Path $livePath)  { Get-Content $livePath  -EA SilentlyContinue } else { @() })
                        $prior = @(if (Test-Path $priorPath) { Get-Content $priorPath -EA SilentlyContinue } else { @() })
                        $seen = @{}; $out = @()
                        foreach ($ln in $prior) {                    # prior order, only still-Saved
                            $ck = & $cwdOf $ln
                            if ($ck -and $savedCwd.ContainsKey($ck) -and -not $seen.ContainsKey($ck)) { $out += $ln; $seen[$ck] = $true }
                        }
                        foreach ($ln in $live) {                     # then any new live tabs
                            $ck = & $cwdOf $ln
                            if ($ck -and -not $seen.ContainsKey($ck)) { $out += $ln; $seen[$ck] = $true }
                        }
                        if ($out.Count) { Set-Content -Path $priorPath -Value $out -Encoding UTF8; $snapN++ }
                        elseif (Test-Path $priorPath) { Remove-Item $priorPath -Force -EA SilentlyContinue }
                    }
                    Write-Color "  layout snapshot saved ($snapN window file(s)) -- 'restore -ByTabs' rebuilds from it" DarkGray
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
                # This guard only matters for UNFILTERED bulk cleans (so -All can't wipe
                # records for entries at odd/dangerous roots). clean removes only the ledger
                # JSON, never the dir, so when you NAME an entry explicitly the off-layout
                # protection is dropped -- that is how you clear a tangent's stale entry
                # (e.g. gwt sessions clean local-llm).
                $wtEsc  = [regex]::Escape($script:WtRoot)
                $gitEsc = [regex]::Escape($script:GitRoot)
                $canonicalRegex = "^($wtEsc\\[^\\]+\\[^\\]+\\[^\\]+\\[^\\]+|$gitEsc\\[^\\]+\\[^\\]+\\[^\\]+)(\\|$)"
                $hasFilter = [bool]($Match -or $Name -or $Window)
                $offLayoutSkipped = @()
                if (-not $hasFilter) {
                    $offLayoutSkipped = @($toDrop | Where-Object {
                        -not $_.WorktreePath -or ($_.WorktreePath -notmatch $canonicalRegex)
                    })
                    $toDrop = @($toDrop | Where-Object {
                        $_.WorktreePath -and ($_.WorktreePath -match $canonicalRegex)
                    })
                }

                # Protect Saved entries from ALL clean operations -- with one
                # exception: when -IncludeDuplicates is set, Saved duplicate
                # LOSERS get dropped anyway. The winner of each path keeps the
                # Saved protection, so this is safe: only redundant copies go.
                $savedSkipped = @($toDrop | Where-Object { $_.Saved -and -not $_.DuplicateLoser })
                $toDrop       = @($toDrop | Where-Object { (-not $_.Saved) -or $_.DuplicateLoser })

                # Optional filters: substring $Match plus exact $Name/$Window. With
                # any filter, multi-match prompts to disambiguate (pick / 'a' / 'q').
                if ($hasFilter) {
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
                # Drop any phantom/blank elements (null or File-less) the dedupe/resolve
                # step can emit -- clean can only act on a real entry with a backing file.
                $toDrop = @($toDrop | Where-Object { $_ -and $_.File })
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
                # A non-empty $Target that matched no case above is a typo'd subcommand
                # (e.g. 'sessions prune'). It used to silently fall through to the list,
                # which reads as "it did something". Call it out and nudge toward 'clean'.
                if ($Target -and $Target -ne 'list') {
                    Write-Color "unknown 'gwt sessions' subcommand: '$Target'" Yellow
                    if ($Target -match 'prune|clean|rm|remove|delete|drop') {
                        Write-Color "  did you mean 'gwt sessions clean'?  (drops ended + stale; add -Aborted for aborted, -IncludeDuplicates for dupes)" DarkGray
                    } else {
                        Write-Color "  known: list (default), clean, restore, audit, tabs, save, unsave, close, move, usage" DarkGray
                    }
                    Write-Color "  showing 'gwt sessions list':" DarkGray
                }
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
                # Flat table (the tabular view), newest activity first. Compute tag +
                # last-active + last user message per session, then render one box table.
                $abortedCount = 0; $staleCount = 0; $endedCount = 0
                $tableRows = foreach ($s in $deduped) {
                    if     ($s.Alive)                                                { $tag = 'ACTIVE' }
                    elseif ($s.State -eq 'ended')                                    { $tag = 'ENDED';   $endedCount++ }
                    elseif ($s.WorktreePath -and (Test-Path $s.WorktreePath))        { $tag = 'ABORTED'; $abortedCount++ }
                    elseif ($s.WorktreePath -and $s.WorktreePath -match $wtRootRegex){ $tag = 'STALE';   $staleCount++ }
                    else                                                            { $tag = 'ABORTED'; $abortedCount++ }
                    if ($s.Saved)               { $tag = 'SAVED' }
                    if ($s.Alive -and $s.State) { $tag = "$tag/$($s.State)" }
                    $j  = _SessionJournal $s.ClaudeSessionId
                    $la = if ($j -and $j.LastActive) { $j.LastActive }
                          elseif ($s.LastStateChange) { try { [datetime]$s.LastStateChange } catch { $null } }
                          elseif ($s.LastSpawnedAt)   { try { [datetime]$s.LastSpawnedAt } catch { $null } }
                          else { $null }
                    $dir = ($s.WorktreePath -replace '/','\')
                    $dir = $dir -replace '^.*\\worktrees\\github\\(openziti|netfoundry)\\','' -replace '^.*\\worktrees\\github\\','' -replace '^.*\\git\\github\\','' -replace '^.*\\worktrees\\',''
                    if (-not $dir) { $dir = if ($s.Label) { $s.Label } else { $s.Branch } }
                    $mg = if ($j) { $j.LastMsg } else { $null }
                    [pscustomobject]@{ Tag = $tag; Last = $la; Dir = $dir; Msg = $mg }
                }
                $tableRows = @($tableRows | Sort-Object @{Expression={ if ($_.Last) { $_.Last } else { [datetime]::MinValue } }} -Descending)

                # ENDED sessions closed cleanly and are rarely what you're looking for, so
                # hide them by default. -IncludeEnded shows the full history. SAVED entries
                # keep their own tag (never counted as ENDED) so they always stay visible.
                $hiddenEnded = 0
                if (-not $IncludeEnded) {
                    $before      = @($tableRows).Count
                    $tableRows   = @($tableRows | Where-Object { $_.Tag -notlike 'ENDED*' })
                    $hiddenEnded = $before - @($tableRows).Count
                }

                $wL = 11; $wS = 13; $wD = 34; $wM = 50
                function script:_TblCell($v, $w) { if ($null -eq $v) { $v = '' }; $v = "$v"; if ($v.Length -gt $w) { $v = $v.Substring(0, $w - 2) + '..' }; $v.PadRight($w) }
                $bar = "+{0}+{1}+{2}+{3}+" -f ('-'*($wL+2)), ('-'*($wS+2)), ('-'*($wD+2)), ('-'*($wM+2))
                Write-Color ""
                Write-Color $bar
                Write-Color ("| {0} | {1} | {2} | {3} |" -f (_TblCell 'Last active' $wL), (_TblCell 'State' $wS), (_TblCell 'Directory' $wD), (_TblCell 'Where you left off' $wM))
                Write-Color $bar
                foreach ($r in $tableRows) {
                    $laStr = if ($r.Last) { $r.Last.ToString('MM-dd HH:mm') } else { '?' }
                    Write-Color ("| {0} | {1} | {2} | {3} |" -f (_TblCell $laStr $wL), (_TblCell $r.Tag $wS), (_TblCell $r.Dir $wD), (_TblCell $r.Msg $wM))
                }
                Write-Color $bar
                Write-Color ""
                $noShellCount = $abortedCount + $staleCount + $endedCount
                $totalRows    = @($deduped).Count
                Write-Color ("  - $totalRows entries: $($totalRows - $noShellCount) live, $noShellCount with no live shell ($abortedCount aborted, $endedCount ended, $staleCount stale)") DarkGray
                if ($abortedCount -gt 0) {
                    Write-Color "  - ABORTED = died without clean SessionEnd (crash / restart / kill). 'gwt sessions restore -DryRun' previews the recoverable set (recent + has-transcript)." Yellow
                }
                if ($noShellCount -gt 10) {
                    Write-Color "  - $noShellCount sessions with no live shell: 'gwt sessions clean -Aborted' to drop (preview with -DryRun)" DarkGray
                }
                if ($dupes -gt 0) {
                    Write-Color "  - $dupes duplicate entrie(s) hidden: 'gwt sessions clean -IncludeDuplicates' to drop them" DarkGray
                }
                if ($hiddenEnded -gt 0) {
                    Write-Color "  - $hiddenEnded ended session(s) hidden (closed cleanly): pass -IncludeEnded to show them" DarkGray
                }
                if ($Usage) {
                    Write-Color "  # all 'sessions' subcommands default to THIS REPO when cwd is inside one." DarkGray
                    Write-Color "  # pass -All to act across every repo's sessions." DarkGray
                    Write-Host ""
                    Write-Color "  # snapshot EVERYTHING running now (mark Saved + freeze the tab layout) before a reboot;" DarkGray
                    Write-Color "  # then 'gwt sessions restore -ByTabs' rebuilds exactly this, whatever you close after." DarkGray
                    Write-Color "  gwt sessions snapshot" DarkGray
                    Write-Color "  # mark a session as Saved (protected from every clean) -- shown as [SAVED]" DarkGray
                    Write-Color "  gwt sessions save   <substring> [-Name <branch>] [-Window <name>]" DarkGray
                    Write-Color "  gwt sessions unsave <substring> [-Name <branch>] [-Window <name>]" DarkGray
                    Write-Color "  #   filters combine; multi-match prompts a picker (or 'a' for all)" DarkGray
                    Write-Host ""
                    Write-Color "  # relabel a session's display name (does not rename the git branch)" DarkGray
                    Write-Color "  gwt rename <match> <new-label> [-Name <branch>] [-Window <name>]" DarkGray
                    Write-Host ""
                    Write-Color "  # relaunch ABORTED sessions (recent + has-transcript only). Prompts by-tabs / by-sessions." DarkGray
                    Write-Color "  gwt sessions restore -DryRun                    # preview (by-tabs: grouped by window then tab index)" DarkGray
                    Write-Color "  gwt sessions restore                            # pick mode (by-tabs default); skips ENDED / > 7 days" DarkGray
                    Write-Color "  gwt sessions restore -ByTabs                    # force .tabs-layout mode, no picker" DarkGray
                    Write-Color "  gwt sessions restore -BySessions                # force open-order + window prompt" DarkGray
                    Write-Color "  gwt sessions restore -MaxAgeDays 0 -IncludeEnded # no age cutoff, include cleanly-ended" DarkGray
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
            # Get-WorktreePathForBranch runs git against the canonical main clone
            # ($ctx.Src). If that clone doesn't exist (e.g. the repo was checked out
            # straight into the worktree area, no clone at $GIT_ROOT), it throws --
            # catch it instead of letting the whole command die.
            try   { $wtPath = Get-WorktreePathForBranch $ctx.Src $Target }
            catch { $wtPath = $null }
            if (-not $wtPath -or -not (Test-Path $wtPath)) {
                # No resolvable worktree, but cwd is a valid checkout of this repo.
                # Open claude right here with the real repo + branch (its .claude.json
                # MCPs are keyed to this path), not a generic tangent.
                $top = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
                if ($top) { $wtPath = ($top -replace '/', '\').TrimEnd('\') }
                else      { $tangentFallback = $true }
            }
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
        # When opening the MAIN CLONE (not a worktree), qualify the recorded branch as
        # '<branch>:<repo>' (e.g. main:ziti) so it isn't an ambiguous bare 'main' across
        # repos -- mirrors how a tangent records 'tangent:<leaf>'. 'gwt rename' / the
        # tabs 'r' key still let you change it after.
        $srcNorm = ($ctx.Src -replace '/', '\').TrimEnd('\').ToLower()
        $wtNorm  = ($wtPath  -replace '/', '\').TrimEnd('\').ToLower()
        $dispBranch = if ($wtNorm -eq $srcNorm) { "$($Target):$($ctx.Repo)" } else { $Target }
        _OpenClaudeShell -Path $wtPath -Repo $ctx.Repo -Branch $dispBranch -PromptText $promptText -WindowName $window -Force
    }

    'cd' {
        if (-not $Target) { throw "'cd' requires a branch or worktree dir name" }
        # Pure navigate: the destination is resolved from repo + branch, so the
        # current dir's layout is irrelevant -- don't nag about it.
        $ctx    = Resolve-RepoContext -QuietLayout

        # Special case: 'gwt cd current' lands on the STABLE <WtRoot>\current junction
        # itself, not its resolved target. That's the point of the IDE-pinned link:
        # the shell (and IDE) stay on one path while 'current' repoints underneath.
        # We still validate the target exists so we never cd into a broken junction.
        if ($Target -ieq 'current') {
            $link = Join-Path $ctx.WtRoot 'current'
            if (-not (Test-Path $link)) {
                throw "no 'current' link at $link -- run 'gwt activate <branch>' first"
            }
            try {
                $li = Get-Item $link -Force
                if ($li.LinkType -notin 'SymbolicLink','Junction') { throw "'current' exists but is not a link (LinkType=$($li.LinkType))" }
                $tgt = ($li.Target | Select-Object -First 1)
            } catch { throw "could not resolve 'current' link: $($_.Exception.Message)" }
            if (-not (Test-Path $tgt)) { throw "'current' points at '$tgt' which is missing -- repoint with 'gwt current <branch>'" }
            Write-Output $link
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

    'rehome' {
        # Re-home the CURRENT tab onto a different worktree of this repo and relaunch
        # claude in place. This is the alternative to dragging a tab between windows,
        # which crashes wt when the tab and window belong to different users. Run it
        # from inside a spawned tab after you have exited claude.
        if (-not $Target) { throw "'rehome' requires a branch, worktree dir name, or path in this repo" }
        $ctx = Resolve-RepoContext

        # Accept a full or relative path to a worktree directly (matches what you'd
        # type for 'cd'). Otherwise resolve by branch, then by dir-name (like 'cd').
        $wtPath = $null
        if (Test-Path -LiteralPath $Target -PathType Container) {
            $wtPath = (Resolve-Path -LiteralPath $Target).Path
        }
        if (-not $wtPath) { $wtPath = Get-WorktreePathForBranch $ctx.Src $Target }
        if (-not $wtPath) {
            $lines = & git -C $ctx.Src worktree list --porcelain 2>&1
            foreach ($line in $lines) {
                if ($line -match '^worktree\s+(.+)$') {
                    $candidate = $Matches[1]
                    if ((Split-Path $candidate -Leaf) -ieq $Target) { $wtPath = $candidate; break }
                }
            }
        }
        if (-not $wtPath)             { throw "no worktree for '$Target' in $($ctx.Org)/$($ctx.Repo) -- use 'gwt new $Target' to create one" }
        if (-not (Test-Path $wtPath)) { throw "worktree '$wtPath' is registered but missing -- run 'gwt prune'" }

        # Branch the target dir actually holds (Target may have been a dir name).
        $branch = (& git -C $wtPath rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
        if (-not $branch -or $branch -eq 'HEAD') { $branch = $Target }

        # Re-point THIS tab's ledger entry so the SessionStart hook tracks the move.
        if (_RehomeSessionEntry -WtSession $env:WT_SESSION -WorktreePath $wtPath -Branch $branch -Repo $ctx.Repo) {
            Write-Color "re-homed this tab's session -> $branch" DarkGray
        }

        # Move the REAL process cwd (not just $PWD) so claude launches in the target,
        # re-theme for the new repo, and leave a hint so the parent prompt lands here
        # too once claude exits.
        Set-Location $wtPath
        [Environment]::CurrentDirectory = $wtPath
        if (Get-Command Set-Theme -ErrorAction SilentlyContinue) { Set-Theme -UseRepoTheme -Quiet }
        _SetGwtCwdHint $wtPath
        Write-Color "ready: $wtPath ($branch)" Green

        # Launch claude inline in THIS tab. Continue if there is history at this cwd,
        # otherwise name the session after the branch. Mirrors _InvokeGwtSpawn.
        $slug       = ((Get-Location).Path -replace '[:\\/]', '-')
        $projDir    = Join-Path $env:USERPROFILE ".claude\projects\$slug"
        $hasSession = (Test-Path $projDir) -and @(Get-ChildItem $projDir -Filter *.jsonl -ErrorAction SilentlyContinue).Count -gt 0
        $claudeArgs = @()
        if ($hasSession) { $claudeArgs += '--continue' }
        elseif ($branch) { $claudeArgs += @('--name', $branch) }
        if ($Prompt)     { $claudeArgs += $Prompt }
        if ($claudeArgs.Count) { & claude @claudeArgs } else { & claude }
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
        _FetchOriginCached -RepoPath $ctx.Src -NoFetch:$NoFetch -Force:$Fetch

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
        _FetchOriginCached -RepoPath $ctx.Src -NoFetch:$NoFetch -Force:$Fetch

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
            _FetchOriginCached -RepoPath $repoPath -NoFetch:$NoFetch -Force:$Fetch
            # Clean any stale entries inside .git/worktrees/ first -- e.g. if a
            # previous prune deleted the working dir but the internal record
            # survived (or the user 'gwt new'd then twigged the branch and
            # garbage was left behind). Makes downstream detection consistent.
            & git -C $repoPath worktree prune 2>&1 | Out-Null

            Write-Color "  scanning worktrees..." DarkGray
            $statuses   = Get-WorktreeStatuses $repoPath
            $registered = $statuses | ForEach-Object { $_.Path.Replace('\','/').ToLower() }

            # Sweep adjacent EMPTY leftover worktree dirs first. When a prune can't
            # delete a dir because the OS handle releases late (a just-closed tab,
            # AV), the contents go but the top dir lingers. Those are truly empty
            # and safe to remove with no prompt. Runs every prune, ignores the
            # branch filter -- the whole point is to clean siblings you didn't name.
            $orgPart   = if ($Org) { $Org } else { Split-Path (Split-Path $repoPath -Parent) -Leaf }
            $repoPart  = Split-Path $repoPath -Leaf
            $wtRootRepo = Join-Path (Join-Path (Join-Path $WorktreeRoot 'github') $orgPart) $repoPart
            if (Test-Path $wtRootRepo) {
                foreach ($d in (Get-ChildItem $wtRootRepo -Directory -ErrorAction SilentlyContinue)) {
                    if ($d.LinkType -eq 'SymbolicLink') { continue }                 # skip the 'current' link
                    if ($registered -contains $d.FullName.Replace('\','/').ToLower()) { continue }  # real worktree
                    if (@(Get-ChildItem $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue).Count -gt 0) { continue }  # has files
                    if (Get-AliveSessionForPath $d.FullName) { continue }            # paranoia: live session
                    try {
                        [System.IO.Directory]::Delete($d.FullName, $true)
                        Write-Color "  FYI: cleaned up leftover empty worktree dir from an earlier prune: $($d.Name)" DarkGray
                    } catch {}
                }
            }

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
            $eligibleStatuses = if ($Force) { @('PRUNE','DIRTY','ACTIVE','ACTIVE-REMOTE-GONE') } else { @('PRUNE') }
            $prunable = @($statuses | Where-Object { $_.Status -in $eligibleStatuses })
            if ($branchFilter -and -not $prunable -and $filterMatchedWorktree) {
                # Only fire when we DID find a worktree, but its status isn't in
                # the prunable set. If no match was found at all, fall through to
                # the orphan sweep below -- it'll handle the "not found" case.
                $actualStatus = if ($statuses.Count -eq 1) { $statuses[0].Status } else { 'unknown' }
                Write-Color "  '$branchFilter' is $actualStatus -- prune won't touch it by default" Yellow
                if ($actualStatus -in @('ACTIVE','ACTIVE-REMOTE-GONE','DIRTY') -and -not $Force) {
                    $warn = switch ($actualStatus) {
                        'DIRTY'              { 'has uncommitted changes (local content will be lost)' }
                        'ACTIVE-REMOTE-GONE' { 'has commits not in main and its remote ref is gone' }
                        default              { 'is still active' }
                    }
                    $r = if ($y) { 'y' } else { Read-Host "  $warn -- force remove anyway? (y/N)" }
                    if ($r -match '^[Yy]$') {
                        # $statuses is already the single filtered worktree the user
                        # named, so prune it directly -- no need to re-filter by status.
                        $prunable = @($statuses)
                        $Force    = $true
                        # We just got explicit destructive consent for this one filtered
                        # worktree. Don't make the per-row loop ask the same question again.
                        $y        = $true
                    } else {
                        Write-Color "    aborted -- nothing changed" DarkGray
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

                # Live-session guard: a claude session (and its pwsh) running IN this
                # worktree holds an open handle on the dir, so NO delete can succeed --
                # -Force included, because a running process is not a permissions problem.
                # Refuse and name it up front, rather than dropping the ledger entry and
                # then crying "still exists" via a File Locksmith that (run in the other
                # account's non-elevated session) can't even see the claude-account holder.
                # The ledger PID-liveness check IS cross-session, so it names the holder
                # regardless of which account owns it.
                $aliveHere = Get-AliveSessionForPath $wt.Path
                if ($aliveHere) {
                    Write-Color "  [LIVE    ] $($wt.Branch) @ $($wt.Path)" Yellow
                    Write-Color "                    a claude session is running here (pid $($aliveHere.Pid), window '$($aliveHere.WindowName)') -- it holds the folder open" Yellow
                    Write-Color "                    close that tab (or 'gwt focus $($aliveHere.Branch)' then exit), then re-run prune" DarkGray
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
                                Write-Color "                    still on disk -- this shell will cd to the main clone now" Yellow
                                Write-Color "                    close any IDE or Explorer windows open there, then re-run the same command" DarkGray
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
                                Write-Color "                    still on disk -- this shell will cd to the main clone now" Yellow
                                Write-Color "                    close any IDE or Explorer windows open there, then re-run the same command" DarkGray
                            }
                        }
                    }
                    'ACTIVE-REMOTE-GONE' {
                        # Reached only when -Force is set. Remote ref is gone and the branch
                        # has commits not in main -- those commits will be lost.
                        Write-Color "  [$label] $($wt.Branch) @ $($wt.Path)" DarkYellow
                        Write-Color "                    $($wt.Reason)" DarkYellow
                        $ok = $y -or (($r = Read-Host "  -Force: delete '$($wt.Branch)' and lose its unmerged commits? (y/N)") -match '^[Yy]$')
                        if ($ok) {
                            _ChangeToMainFolder -Path $wt.Path -MainPath $repoPath
                            & git -C $repoPath worktree remove --force $wt.Path 2>&1 | Out-Null
                            $gone = _ForceRemoveWorktreeDir $wt.Path
                            if ($gone) { Write-Color "                    removed." DarkGray }
                            _CleanupWorktreeMetadata $wt.Path
                            if (-not $gone) {
                                Write-Color "                    still on disk -- this shell will cd to the main clone now" Yellow
                                Write-Color "                    close any IDE or Explorer windows open there, then re-run the same command" DarkGray
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
                                Write-Color "                    still on disk -- this shell will cd to the main clone now" Yellow
                                Write-Color "                    close any IDE or Explorer windows open there, then re-run the same command" DarkGray
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
                            _ReportDirHolders $p
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
                            _ReportDirHolders $p
                        }
                    }
                }
                # ORPHAN-DIRTY entries are silently skipped -- 'gwt list' shows them
                # if you want to see what's lurking; no need to repeat here.
            }

            if ($branchFilter -and -not $filterMatchedWorktree -and -not $orphanMatchFound) {
                Write-Color "  no worktree or orphan named '$branchFilter' in this repo" Yellow
            }

            # Verify: if we matched a worktree and tried to prune it, confirm the
            # directory is actually gone. A silent survivor (file lock, open IDE)
            # otherwise looks like success when nothing changed.
            # Only verify when we actually attempted a removal. If the user
            # declined the force prompt, $prunable is empty and the dir surviving
            # is expected, not an error.
            if ($branchFilter -and $filterMatchedWorktree -and $prunable.Count -gt 0) {
                $survivors = @($statuses | Where-Object { $_.Path -and (Test-Path $_.Path) })
                if ($survivors.Count) {
                    foreach ($s in $survivors) {
                        Write-Color "  ERROR: '$($s.Path)' still exists -- prune did not remove it" Red
                        _ReportDirHolders $s.Path
                    }
                    $global:LASTEXITCODE = 1
                }
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
        # Compute the tab index from the per-window tab-order registry the hook
        # maintains, so we focus the EXACT tab, not just the window. Approximate:
        # falls back to focusing the window's active tab if the tab isn't tracked.
        $tabArg = ''
        if ($h.WtSession) {
            $safe    = ($h.WindowName -replace '[^A-Za-z0-9._-]', '_')
            $tabFile = Join-Path (Join-Path $script:WtRoot 'windows') "$safe.tabs"
            if (Test-Path $tabFile) {
                $tlines = @(Get-Content $tabFile -ErrorAction SilentlyContinue)
                for ($i = 0; $i -lt $tlines.Count; $i++) {
                    if (($tlines[$i] -split "`t")[0] -eq $h.WtSession) { $tabArg = " -t $i"; break }
                }
            }
        }
        $tabNote = if ($tabArg) { " tab$tabArg" } else { " (window only -- tab not tracked yet)" }
        Write-Color "focusing wt window '$($h.WindowName)'$tabNote (branch=$($h.Branch), pid=$($h.Pid))..." DarkGray
        & runas /user:claude /savecred "wt.exe -w `"$($h.WindowName)`" focus-tab$tabArg" 2>&1 | Out-Null
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

        # Keep the per-window .tabs registry in sync so 'gwt sessions tabs' (show and
        # the label captured at 'set' time) reflect the rename, not just the ledger.
        $wsKey = $e.WtSession
        if ($wsKey) {
            $tabLabel = if ([string]::IsNullOrEmpty($newLabel)) { $e.Branch } else { $newLabel }
            $winDir2  = Join-Path $script:WtRoot 'windows'
            foreach ($tf in (Get-ChildItem $winDir2 -Filter '*.tabs' -ErrorAction SilentlyContinue)) {
                $lines   = @(Get-Content $tf.FullName -ErrorAction SilentlyContinue)
                $changed = $false
                $out = foreach ($ln in $lines) {
                    $p = $ln -split "`t"
                    if ($p.Count -ge 2 -and $p[0] -eq $wsKey) {
                        $changed = $true
                        $rest = if ($p.Count -ge 3) { $p[2] } else { '' }
                        "{0}`t{1}`t{2}" -f $p[0], $tabLabel, $rest
                    } else { $ln }
                }
                if ($changed) { Set-Content -Path $tf.FullName -Value @($out) -Encoding UTF8 }
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
        Write-Host "<branch> [-From <src>] [-Prompt <str>] [-y] [--by-project]"
        Write-Host "        create (or reopen) a worktree for a branch" -ForegroundColor DarkGray
        Write-Host "        -From         fork from this branch instead of origin/main" -ForegroundColor DarkGray
        Write-Host "        -Prompt       override the default claude prompt" -ForegroundColor DarkGray
        Write-Host "        -y            skip confirmation prompts" -ForegroundColor DarkGray
        Write-Host "        --by-project  (now the DEFAULT) group the tab in a window named after" -ForegroundColor DarkGray
        Write-Host "                      the repo, themed from the per-repo map (e.g. ziti -> teal-dusk)." -ForegroundColor DarkGray
        Write-Host "                      Pick a different window in the prompt ('auto' is highlighted)." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt twig " -NoNewline -ForegroundColor Cyan
        Write-Host "<branch> [-Prompt <str>] [-y]"
        Write-Host "        create a new worktree branched off the current worktree's HEAD" -ForegroundColor DarkGray
        Write-Host "        (shortcut for 'gwt new <branch> -From <current-branch>')" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt discourse " -NoNewline -ForegroundColor Cyan
        Write-Host "<discourse-url> [-Prompt <str>] [-y]"
        Write-Host "        create a worktree to investigate a discourse topic" -ForegroundColor DarkGray
        Write-Host "        picks target repo (most-likely list + custom; default openziti/ziti)" -ForegroundColor DarkGray
        Write-Host "        branch name: discourse-<topic-id>" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt zendesk " -NoNewline -ForegroundColor Cyan
        Write-Host "<zendesk-ticket-url|id> [-Prompt <str>] [-y]"
        Write-Host "        create a worktree to investigate a Zendesk ticket (mirrors discourse)" -ForegroundColor DarkGray
        Write-Host "        picks target repo (most-likely list + custom; default openziti/ziti)" -ForegroundColor DarkGray
        Write-Host "        branch name: zendesk-<ticket-id>" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt pr " -NoNewline -ForegroundColor Cyan
        Write-Host "<url-or-number> [-Prompt <str>] [-y]"
        Write-Host "        create (or reopen) a worktree for a PR" -ForegroundColor DarkGray
        Write-Host "        accepts a full GitHub PR URL or a bare PR number" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt backport " -NoNewline -ForegroundColor Cyan
        Write-Host "<pr-url-or-number> [-Lts active|maint] [-y]"
        Write-Host "        branch a worktree off an LTS release line (not main) and cherry-pick" -ForegroundColor DarkGray
        Write-Host "        the PR's commits (-x) into it. branch: backport.<vX.Y.x>.<pr-source-branch>" -ForegroundColor DarkGray
        Write-Host "        -Lts  active = newest release-v*.x, maint = next down (or a release-vN.M.x); prompts if omitted" -ForegroundColor DarkGray
        Write-Host "        conflicts are left in the worktree for you to resolve" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt <url> " -NoNewline -ForegroundColor Cyan
        Write-Host "[-y]"
        Write-Host "        shorthand -- bare URL auto-routes:" -ForegroundColor DarkGray
        Write-Host "          .../pull/<num>          -> 'pr' (worktree for that PR)" -ForegroundColor DarkGray
        Write-Host "          .../issues/<num>        -> 'issue' (worktree branched off main, named issue-<num>)" -ForegroundColor DarkGray
        Write-Host "          .../security/advisories/GHSA-... -> 'advisory' (worktree off main, named advisory-<GHSA>)" -ForegroundColor DarkGray
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
        Write-Host "    gwt close" -ForegroundColor Cyan
        Write-Host "        close THIS tab: drop its tab-registry line (reorders the rest)," -ForegroundColor DarkGray
        Write-Host "        mark its session ended, then exit the shell so wt closes the tab" -ForegroundColor DarkGray
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
        Write-Host "    gwt rehome " -NoNewline -ForegroundColor Cyan
        Write-Host "<branch> [-Prompt <str>]"
        Write-Host "        re-home THIS tab onto another worktree of this repo and relaunch claude" -ForegroundColor DarkGray
        Write-Host "        run it after exiting claude. avoids dragging tabs between user-owned" -ForegroundColor DarkGray
        Write-Host "        wt windows (which crashes wt). updates this tab's session entry too" -ForegroundColor DarkGray
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
    if ($env:GWT_DEBUG_STACK) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    Write-Host "run 'gwt help' for usage" -ForegroundColor DarkGray
    exit 1
}
