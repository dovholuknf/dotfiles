# git-worktree.ps1 — unified worktree lifecycle manager
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

    [string]$From,          # 'new': create branch from this source
    [string]$Org,
    [string]$Repo,
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
    # valid worktrees have a `.git` file (not dir) pointing at the gitdir
    if (Test-Path (Join-Path $WtPath '.git')) { return }
    if (Test-Path $WtPath) {
        Write-Color "path '$WtPath' exists but isn't a valid worktree — cleaning up residue" Yellow
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
        Write-Color "dotagents setup-agents.ps1 not found at '$setupScript' — skipping CLAUDE.md symlink" Yellow
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

function Get-ClaudePromptPresets {
    param([string]$Repo, [string]$Branch)
    return ,@(
        [PSCustomObject]@{
            Name = 'blank'
            Text = $null
        }
        [PSCustomObject]@{
            Name = 'critique'
            Text = "critique the changes from this branch ($Branch in $Repo). summarize changes commit by commit and pay attention to risks and critique overall design"
        }
        [PSCustomObject]@{
            Name = 'continue'
            Text = "look at the current state of this worktree ($Branch in $Repo). figure out what was being worked on and pick up where it left off"
        }
        [PSCustomObject]@{
            Name = 'explore'
            Text = "give me a tour of this branch ($Branch in $Repo). what's different from main? what's the shape of the changes? orientation only, no action yet"
        }
        [PSCustomObject]@{
            Name = 'test'
            Text = "run the test suite for this branch ($Branch in $Repo). if anything fails, investigate root cause before attempting fixes"
        }
    )
}

function Select-ClaudePrompt {
    param([string]$Repo, [string]$Branch)
    $presets = Get-ClaudePromptPresets -Repo $Repo -Branch $Branch

    Write-Host ""
    Write-Color "choose prompt:" DarkGray
    for ($i = 0; $i -lt $presets.Count; $i++) {
        $c       = $presets[$i]
        $preview = if ($null -eq $c.Text) { '(open claude with no initial prompt)' } else { $c.Text }
        $marker  = if ($i -eq 0) { '*' } else { ' ' }
        Write-Host ("  [{0}]{1} " -f ($i + 1), $marker) -NoNewline -ForegroundColor Cyan
        Write-Host ("{0,-9}" -f $c.Name) -NoNewline -ForegroundColor White
        Write-Host ("  {0}" -f $preview) -ForegroundColor DarkGray
    }
    $customIdx = $presets.Count + 1
    Write-Host ("  [{0}]  " -f $customIdx) -NoNewline -ForegroundColor Cyan
    Write-Host ("{0,-9}" -f 'custom')      -NoNewline -ForegroundColor White
    Write-Host "  (type your own)"                     -ForegroundColor DarkGray
    Write-Host ""

    $resp = (Read-Host "choice [1]").Trim()
    if ([string]::IsNullOrWhiteSpace($resp)) { $resp = '1' }

    if ($resp -eq "$customIdx") {
        $custom = Read-Host "prompt"
        return $custom
    }

    $idx = 0
    if (-not [int]::TryParse($resp, [ref]$idx) -or $idx -lt 1 -or $idx -gt $presets.Count) {
        Write-Color "invalid choice, using default" Yellow
        return $presets[0].Text
    }
    return $presets[$idx - 1].Text
}

function Select-WtWindow {
    $presets = @(
        [PSCustomObject]@{ Name = 'active-work';   Desc = 'attach to "active-work" window' }
        [PSCustomObject]@{ Name = 'pull-requests'; Desc = 'attach to "pull-requests" window' }
        [PSCustomObject]@{ Name = 'tangent';       Desc = 'attach to "tangent" window' }
        [PSCustomObject]@{ Name = 'worktrees';     Desc = 'attach to "worktrees" window (default)' }
        [PSCustomObject]@{ Name = '__new__';       Desc = 'open in a brand-new wt window (no attach)' }
        [PSCustomObject]@{ Name = '__custom__';    Desc = 'type your own window name' }
    )
    Write-Host ""
    Write-Color "choose wt window:" DarkGray
    for ($i = 0; $i -lt $presets.Count; $i++) {
        $marker = if ($i -eq 0) { '*' } else { ' ' }
        Write-Host ("  [{0}]{1} " -f ($i + 1), $marker) -NoNewline -ForegroundColor Cyan
        $label = switch ($presets[$i].Name) {
            '__new__'    { 'new' }
            '__custom__' { 'custom' }
            default      { $presets[$i].Name }
        }
        Write-Host ("{0,-14}" -f $label) -NoNewline -ForegroundColor White
        Write-Host ("  {0}" -f $presets[$i].Desc) -ForegroundColor DarkGray
    }
    Write-Host ""

    $resp = (Read-Host "choice [1]").Trim()
    if ([string]::IsNullOrWhiteSpace($resp)) { $resp = '1' }

    $idx = 0
    if (-not [int]::TryParse($resp, [ref]$idx) -or $idx -lt 1 -or $idx -gt $presets.Count) {
        Write-Color "invalid choice, using default" Yellow
        return $presets[0].Name
    }
    $choice = $presets[$idx - 1].Name
    if ($choice -eq '__custom__') {
        $name = (Read-Host "window name").Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { return '__new__' }
        return $name
    }
    return $choice
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

function Get-ThemeFnForWindow {
    param([string]$WindowName)
    switch ($WindowName) {
        'active-work'   { 'ActiveWork' }
        'pull-requests' { 'PullRequests' }
        'tangent'       { 'Tangent' }
        'worktrees'     { 'Worktrees' }
        default         { $null }  # custom names / new windows: no theme
    }
}

function Open-ClaudeShell {
    param(
        [string]$Path,
        [string]$Repo,
        [string]$Branch,
        [string]$PromptText,
        [string]$WindowName,        # $null/empty = brand-new window; otherwise -w <name>
        [string]$ReuseSessionId     # if set, reuse an existing session entry (e.g. on restore) instead of minting a new one — prevents orphan accumulation
    )
    # claude stores sessions per-cwd under the invoking user's profile. gwt runs
    # claude as the 'claude' user, so probe that profile (not the current user's).
    # path slug: replace ':' and '\' and '/' with '-'  (e.g. D:\worktrees\foo -> D--worktrees-foo)
    $slug       = ($Path -replace '[:\\/]','-')
    $projDir    = "C:\Users\claude\.claude\projects\$slug"
    $hasSession = (Test-Path $projDir) -and @(Get-ChildItem $projDir -Filter *.jsonl -ErrorAction SilentlyContinue).Count -gt 0
    $contFlag   = if ($hasSession) { ' --continue' } else { '' }

    # only set a name on fresh sessions — --continue carries the existing name forward
    $nameFlag = if ($hasSession -or [string]::IsNullOrWhiteSpace($Branch)) { '' } else {
        $escapedName = $Branch -replace '"', '`"'
        " --name `"$escapedName`""
    }

    # Apply the full wt-themes color scheme (ANSI palette, grayscale ramp, psr
    # colors) matching the window category. Requires wt-themes.ps1 to be sourced
    # from the spawned shell's $PROFILE — it is in this setup.
    $themeFn     = Get-ThemeFnForWindow -WindowName $WindowName
    $themePrefix = if ($themeFn) { "$themeFn; " } else { '' }

    # Session registration: pre-write the entry from here (clint user) with the
    # session metadata + a placeholder PID. The spawned shell only patches in its
    # real PID/StartTime via Register-GwtSession -Id <guid>. Keeps the encoded
    # command short — runas has a tight command-line length limit.
    $sessionDir  = 'D:\worktrees\sessions'
    [System.IO.Directory]::CreateDirectory($sessionDir) | Out-Null
    # Reuse an existing session id when caller passed one (e.g. restore) — keeps
    # the entry count stable even if the spawned shell's Register-GwtSession fails.
    $sessionId   = if ($ReuseSessionId) { $ReuseSessionId } else { [guid]::NewGuid().ToString() }
    $entry       = @{
        Id                = $sessionId
        Pid               = 0
        StartTime         = $null
        WtSession         = $null
        SpawnedAt         = $null
        WorktreePath      = $Path
        Branch            = $Branch
        Repo              = $Repo
        WindowName        = $WindowName
        PromptText        = $PromptText
        ClaudeSessionName = $Branch
    }
    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $sessionDir "$sessionId.json") -Encoding UTF8

    # Source the registry explicitly — don't depend on the spawned shell's
    # profile being correctly set up. The path is the dotfiles location, so it
    # works for both clint and the claude user. If you move dotfiles, update here.
    $regPrefix = ". 'D:\git\github\dovholuknf\dotfiles\powershell\gwt-session-registry.ps1'; Register-GwtSession -Id '$sessionId'; "

    if ([string]::IsNullOrEmpty($PromptText)) {
        $cmd = "${regPrefix}${themePrefix}Set-Location '$Path'; claude$contFlag$nameFlag"
    } else {
        $escaped = $PromptText -replace '"', '`"'
        $cmd     = "${regPrefix}${themePrefix}Set-Location '$Path'; claude$contFlag$nameFlag `"$escaped`""
    }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    # -w <name>: reuse (or create) the named window so worktrees stack as tabs.
    # window names are bound to the 'claude' user, so this only merges tabs across
    # gwt-spawned shells — it won't attach to your regular-user wt.
    if (-not [string]::IsNullOrWhiteSpace($WindowName)) {
        $wtArgs = "wt.exe -w $WindowName new-tab -d `"$Path`" pwsh -NoExit -EncodedCommand $enc"
    } else {
        $wtArgs = "wt.exe -d `"$Path`" pwsh -NoExit -EncodedCommand $enc"
    }
    # /savecred reuses the password from Windows Credential Manager after the
    # first successful auth. Removes the per-launch password prompt during
    # bulk operations like `gwt sessions restore`. To clear: `cmdkey /delete:claude`
    runas /user:claude /savecred $wtArgs

    # Stash the session id so callers (e.g. gwt sessions restore) can poll the
    # session file for Pid != 0 to know the spawned shell came up. Script-scope
    # avoids leaking the value onto stdout for callers that don't care.
    $script:LastSpawnedSessionId = $sessionId
}

function Confirm-OpenOrCd {
    param([string]$Path, [string]$Repo, [string]$Branch, [string]$PromptOverride, [switch]$AutoOpen)

    if ($AutoOpen) {
        $promptText = if ($PromptOverride) {
            $PromptOverride
        } else {
            (Get-ClaudePromptPresets -Repo $Repo -Branch $Branch)[0].Text
        }
        Open-ClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptText $promptText -WindowName 'active-work'
        return
    }

    $resp = Read-Host "open in claude? (Y/n)"
    if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
        $window = Select-WtWindow
        if ($window -eq '__new__') { $window = $null }

        $promptText = if ($PromptOverride) {
            $PromptOverride
        } else {
            Select-ClaudePrompt -Repo $Repo -Branch $Branch
        }
        Open-ClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptText $promptText -WindowName $window
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
                # The initial fetch in Ensure-RepoClonedAndUpdated normally already
                # brings down origin/<Target>. Only re-fetch explicitly if it's
                # missing (e.g. repos with restricted fetch refspecs). Use a fully
                # qualified refspec — bare-name lhs can resolve to nothing and
                # cause git to delete the dest tracking ref.
                & git -C $ctx.Src rev-parse --verify "origin/$Target" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Invoke-Git $ctx.Src @('fetch','origin',"+refs/heads/${Target}:refs/remotes/origin/$Target")
                }
                & git -C $ctx.Src rev-parse --verify "origin/$Target" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Invoke-Git $ctx.Src @('branch','--track',$Target,"origin/$Target")
                } else {
                    Write-Color "remote branch '$Target' could not be fetched — branching off origin/main" Yellow
                    Invoke-Git $ctx.Src @('branch','--no-track',$Target,'origin/main')
                }
            } else {
                Invoke-Git $ctx.Src @('branch','--no-track',$Target,'origin/main')
            }
        } else {
            # branch exists locally — reconcile with remote so we don't silently
            # check out a stale local copy that diverges from origin.
            & git -C $ctx.Src rev-parse --verify "origin/$Target" 2>&1 | Out-Null
            $remoteHas = $LASTEXITCODE -eq 0

            & git -C $ctx.Src rev-parse --abbrev-ref "${Target}@{upstream}" 2>&1 | Out-Null
            $hasUpstream = $LASTEXITCODE -eq 0

            if ($hasUpstream -and -not $remoteHas) {
                Write-Color "stale branch '$Target' (upstream gone) — resetting to origin/main" Cyan
                Invoke-Git $ctx.Src @('branch','--unset-upstream',$Target)
                Invoke-Git $ctx.Src @('branch','-f',$Target,'origin/main')
            } elseif ($remoteHas) {
                $localSha  = ((& git -C $ctx.Src rev-parse $Target) | Out-String).Trim()
                $remoteSha = ((& git -C $ctx.Src rev-parse "origin/$Target") | Out-String).Trim()
                if ($localSha -ne $remoteSha) {
                    $ahead  = [int]((& git -C $ctx.Src rev-list --count "origin/$Target..$Target") | Out-String).Trim()
                    $behind = [int]((& git -C $ctx.Src rev-list --count "$Target..origin/$Target") | Out-String).Trim()
                    if ($ahead -eq 0 -and $behind -gt 0) {
                        Write-Color "local '$Target' is $behind commits behind origin — fast-forwarding" Cyan
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

    'twig' {
        if (-not $Target) { throw "'twig' requires a new branch name" }

        $current = (& git rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $current -or $current -eq 'HEAD') {
            throw "can't detect current branch — are you inside a git worktree?"
        }
        $currentWt = (& git rev-parse --show-toplevel 2>&1 | Out-String).Trim()

        # capture dirty state as a patch (tracked changes only — git diff excludes untracked)
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

        # untracked files can't be represented in a patch — prompt whether to copy them
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
        Ensure-RepoClonedAndUpdated -Org $ctx.Org -Repo $ctx.Repo -Src $ctx.Src

        if (Test-LocalBranchExists $ctx.Src $Target) {
            throw "branch '$Target' already exists — pick a different name"
        }
        # branch off whatever $current currently points to locally — do NOT force-update it
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
                Write-Color "patch did not apply cleanly — left at: $patchFile" Red
            } else {
                Write-Color "carried changes applied (staged)." Green
                Remove-Item $patchFile -Force
            }
        }

        Confirm-OpenOrCd -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptOverride $Prompt -AutoOpen:$y
        return
    }

    'update-registry' {
        # Manual freshness/fetch for the fallback gwt-session-registry.ps1 at
        # ~\.gwt\. No-op (with a hint) if the dotfiles copy exists — that's
        # primary, you update it via git pull.
        $primary  = 'D:\git\github\dovholuknf\dotfiles\powershell\gwt-session-registry.ps1'
        $fallback = Join-Path $env:USERPROFILE '.gwt\gwt-session-registry.ps1'
        $stamp    = "$fallback.last-fetched"
        $url      = 'https://raw.githubusercontent.com/dovholuknf/dotfiles/main/powershell/gwt-session-registry.ps1'

        if (Test-Path $primary) {
            Write-Color "primary copy at $primary — update via git pull" DarkGray
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
            Write-Color "  (empty — no sessions have been registered yet)" DarkGray
            return
        }

        $parseFails = 0
        $entries = $jsonFiles | ForEach-Object {
            try {
                $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $alive = $false
                if ($e.Pid) {
                    $p = Get-Process -Id $e.Pid -ErrorAction SilentlyContinue
                    if ($p -and $e.StartTime) {
                        $alive = ($p.StartTime.ToString('o') -eq $e.StartTime)
                    } elseif ($p) {
                        $alive = $true
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
                $allStale = @($entries | Where-Object { -not $_.Alive })
                if (-not $allStale.Count) { Write-Color "no stale sessions to restore" DarkGray; return }

                # dedupe by WorktreePath (keeps newest by SpawnedAt) — protects against
                # accumulated leftover entries from failed prior launches blowing up the count.
                $stale = $allStale |
                         Group-Object WorktreePath |
                         ForEach-Object { $_.Group | Sort-Object SpawnedAt -Descending | Select-Object -First 1 }

                $dupes = $allStale.Count - @($stale).Count
                Write-Color "found $($allStale.Count) stale entries, $($stale.Count) unique by worktree path" Cyan
                if ($dupes -gt 0) {
                    Write-Color "  ($dupes duplicates will be skipped — run 'gwt sessions clean' to drop them)" DarkGray
                }
                Write-Host ""
                foreach ($s in $stale) { Write-Color "  $($s.Branch) -> $($s.WindowName)" DarkGray }
                Write-Host ""
                $resp = Read-Host "relaunch these $($stale.Count) session(s)? (Y/n)"
                if (-not ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$')) {
                    Write-Color "aborted" Yellow
                    return
                }

                foreach ($s in $stale) {
                    if (-not (Test-Path $s.WorktreePath)) {
                        Write-Color "  skip (worktree gone): $($s.Branch) @ $($s.WorktreePath)" Yellow
                        continue
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
            'clean' {
                # Default: drop only stale entries. With -All (the script-level switch),
                # also drop alive entries (will not kill the underlying shell — just
                # forgets the registry entry; the alive shell stays running).
                $toDrop = if ($All) {
                    @($entries)
                } else {
                    @($entries | Where-Object { -not $_.Alive })
                }
                $mode = if ($All) { 'all (alive + stale)' } else { 'stale only (default — pass -All to also drop alive entries)' }
                Write-Color "cleaning: $mode" DarkGray
                if (-not $toDrop.Count) { Write-Color "  nothing to drop" DarkGray; return }
                foreach ($s in $toDrop) {
                    Remove-Item $s.File -Force -ErrorAction SilentlyContinue
                    $tag = if ($s.Alive) { '(was alive — entry removed; running shell unaffected)' } else { '(stale)' }
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
                    Write-Color "  $dupes duplicate entrie(s) hidden — run 'gwt sessions clean' to drop stale dupes" DarkGray
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
                throw "'claude' requires a branch name — and you don't appear to be inside a worktree"
            }
        }
        $ctx    = Resolve-RepoContext
        $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
        if (-not $wtPath) { throw "no worktree for branch '$Target' in $($ctx.Org)/$($ctx.Repo)" }
        if (-not (Test-Path $wtPath)) { throw "worktree path '$wtPath' is registered but missing — run 'gwt prune'" }

        $state = if ($Reselect) { $null } else { Load-GwtState $wtPath }

        # confirm re-use of saved picks — 'n' falls through to re-prompt
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
            $promptText = if ($Prompt) { $Prompt } else { (Get-ClaudePromptPresets -Repo $ctx.Repo -Branch $Target)[0].Text }
        } else {
            $window = Select-WtWindow
            if ($window -eq '__new__') { $window = $null }
            $presets      = Get-ClaudePromptPresets -Repo $ctx.Repo -Branch $Target
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

        Open-ClaudeShell -Path $wtPath -Repo $ctx.Repo -Branch $Target -PromptText $promptText -WindowName $window
    }

    'cd' {
        if (-not $Target) { throw "'cd' requires a branch name" }
        $ctx    = Resolve-RepoContext
        $wtPath = Get-WorktreePathForBranch $ctx.Src $Target
        if (-not $wtPath) { throw "no worktree for branch '$Target' in $($ctx.Org)/$($ctx.Repo)" }
        if (-not (Test-Path $wtPath)) { throw "worktree path '$wtPath' is registered but missing — run 'gwt prune'" }
        # print ONLY the path to stdout — the profile's gwt wrapper captures this and Set-Locations it.
        # Write-Color uses Write-Host which bypasses the pipeline, so detection banners are fine.
        Write-Output $wtPath
    }

    'rm' {
        if (-not $Target) { throw "'rm' requires a branch name" }
        $ctx    = Resolve-RepoContext
        $wtPath = Join-Path $ctx.WtRoot $Target
        Remove-Worktree -Src $ctx.Src -WtPath $wtPath -AutoConfirm:$y
    }

    { $_ -in 'ls','list' } {
        $ctx      = Resolve-RepoContext
        $statuses = Get-WorktreeStatuses $ctx.Src |
                    Sort-Object -Property LastCommit -Descending

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
            $when  = if ($wt.LastCommitRel) { "({0})" -f $wt.LastCommitRel } else { '' }
            $when  = $when.PadRight(22)
            Write-Color "  [$label] $when $($wt.Branch) @ $($wt.Path)" $color
            if ($wt.Status -eq 'DIRTY-MERGED' -and $wt.Reason) {
                Write-Color "                                           $($wt.Reason)" $color
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
        Write-Host "    gwt twig " -NoNewline -ForegroundColor Cyan
        Write-Host "<branch> [-Prompt <str>] [-y]"
        Write-Host "        create a new worktree branched off the current worktree's HEAD" -ForegroundColor DarkGray
        Write-Host "        (shortcut for 'gwt new <branch> -From <current-branch>')" -ForegroundColor DarkGray
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
        Write-Host "    gwt update-registry" -ForegroundColor Cyan
        Write-Host "        fetch fallback gwt-session-registry.ps1 from github into ~\.gwt\" -ForegroundColor DarkGray
        Write-Host "        (no-op if dotfiles repo is cloned — update via git pull instead)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt sessions " -NoNewline -ForegroundColor Cyan
        Write-Host "[restore | clean]"
        Write-Host "        list registered Claude sessions; mark live vs. stale" -ForegroundColor DarkGray
        Write-Host "        restore  relaunch each stale session into its original window" -ForegroundColor DarkGray
        Write-Host "        clean    drop stale entries without relaunching" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    gwt claude " -NoNewline -ForegroundColor Cyan
        Write-Host "[<branch>|.] [-Prompt <str>] [-Reselect] [-y]"
        Write-Host "        open existing worktree's branch directly in claude (no 'remove?' prompt)" -ForegroundColor DarkGray
        Write-Host "        no arg / '.' — uses current worktree's branch" -ForegroundColor DarkGray
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
        Write-Host "(alias: list)"
        Write-Host "        list worktrees for the current repo with status:" -ForegroundColor DarkGray
        Write-Host "          [MAIN            ] — primary clone" -ForegroundColor DarkGray
        Write-Host "          [ACTIVE          ] — upstream exists, not yet merged (clean or dirty)" -ForegroundColor Green
        Write-Host "          [ACTIVE-NO-REMOTE] — has local changes, no upstream configured" -ForegroundColor Cyan
        Write-Host "          [PRUNE           ] — safe to delete (merged, remote deleted, or path missing)" -ForegroundColor Red
        Write-Host "          [DIRTY-MERGED    ] — merged/remote-gone but has local changes, kept for review" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    gwt prune " -NoNewline -ForegroundColor Cyan
        Write-Host "[<branch>] [-Org <org>] [-Repo <repo>] [-y]"
        Write-Host "        delete merged+clean worktrees (safe only — skips dirty)" -ForegroundColor DarkGray
        Write-Host "        no args   — current repo, all worktrees" -ForegroundColor DarkGray
        Write-Host "        <branch>  — current repo, just that worktree" -ForegroundColor DarkGray
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
