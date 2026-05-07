# claude-shell.ps1 -- spawning + session-tracking primitives shared by gwt and
# claudeshell. Source from $PROFILE so the helpers are available everywhere;
# git-worktree.ps1 also dot-sources this so script invocations work.
#
# Public functions:
#   Open-ClaudeShell             -- spawn a wt tab as the claude user, register session, theme
#   Confirm-OpenOrCd             -- "open in claude? (Y/n)" prompt -> Open-ClaudeShell
#   Confirm-NoAliveSessionAt     -- guard: refuse to double-spawn for the same worktree
#   Select-WtWindow              -- pick a wt window category interactively
#   Select-ClaudePrompt          -- pick a starter prompt interactively
#   Get-ClaudePromptPresets      -- prompt preset list (data)
#   Get-ThemeFnForWindow         -- window category -> theme function name
#   Invoke-GwtHook               -- per-project hook dispatcher
#   Get-ClaudeShells             -- list registered sessions (alive + stale, deduped)
#   Get-RecoverableClaudeShells  -- stale entries whose worktree path still exists
#   Restore-ClaudeShell          -- relaunch one entry by id or pipeline object
#   Restore-AllClaudeShells      -- relaunch every recoverable entry

if (-not (Get-Command Write-Color -ErrorAction SilentlyContinue)) {
    function Write-Color {
        param([string]$Text, [string]$Color = 'White')
        Write-Host $Text -ForegroundColor $Color
    }
}

$script:GwtSessionDir = 'D:\worktrees\sessions'

# ---------------------------------------------------------------------------
# prompt presets + picker
# ---------------------------------------------------------------------------

function Get-ClaudePromptPresets {
    param([string]$Repo, [string]$Branch)
    return ,@(
        [PSCustomObject]@{ Name = 'blank';    Text = $null }
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
        return (Read-Host "prompt")
    }
    $idx = 0
    if (-not [int]::TryParse($resp, [ref]$idx) -or $idx -lt 1 -or $idx -gt $presets.Count) {
        Write-Color "invalid choice, using default" Yellow
        return $presets[0].Text
    }
    return $presets[$idx - 1].Text
}

# ---------------------------------------------------------------------------
# wt window picker
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# theme + hook
# ---------------------------------------------------------------------------

function Get-ThemeFnForWindow {
    param([string]$WindowName)
    switch ($WindowName) {
        'active-work'   { 'ActiveWork' }
        'pull-requests' { 'PullRequests' }
        'tangent'       { 'Tangent' }
        'worktrees'     { 'Worktrees' }
        default         { $null }
    }
}

function Invoke-GwtHook {
    # Looks for a per-project hook function named 'gwt_hook_<org>_<repo>'
    # (non-alphanumerics replaced with '_') and calls it with the worktree path.
    param(
        [Parameter(Mandatory)] [string]$Org,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$WorktreePath
    )
    $sanOrg  = $Org  -replace '[^a-zA-Z0-9]', '_'
    $sanRepo = $Repo -replace '[^a-zA-Z0-9]', '_'
    $name    = "gwt_hook_${sanOrg}_${sanRepo}"
    $fn = Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
    if (-not $fn) { return }
    Write-Color "running hook: $name" DarkGray
    try { & $fn -WorktreePath $WorktreePath } catch { Write-Color "hook '$name' failed: $_" Yellow }
}

# ---------------------------------------------------------------------------
# alive-session guard
# ---------------------------------------------------------------------------

function Confirm-NoAliveSessionAt {
    # Returns $true to proceed, $false to abort. Prints the warning + prompt
    # when an alive session matches the given path. -Force skips.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [switch]$Force
    )
    if ($Force) { return $true }
    if (-not (Test-Path $script:GwtSessionDir)) { return $true }

    $normCur = ($Path -replace '/', '\').TrimEnd('\')
    $procMap = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $procMap[[int]$_.ProcessId] = $_
    }
    foreach ($f in Get-ChildItem $script:GwtSessionDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        try {
            $e = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not $e.WorktreePath) { continue }
            if ((($e.WorktreePath -replace '/', '\').TrimEnd('\')) -ne $normCur) { continue }
            if (-not ($e.Pid -and $e.Pid -ne 0)) { continue }
            $cim = $procMap[[int]$e.Pid]
            if (-not $cim) { continue }
            if ($e.StartTime -and $cim.CreationDate) {
                $delta = [math]::Abs(($cim.CreationDate - [datetime]::Parse($e.StartTime)).TotalSeconds)
                if ($delta -gt 2) { continue }
            }
            Write-Color "a session is already alive for '$Path'" Yellow
            Write-Color ("  branch={0}  window={1}  pid={2}" -f $e.Branch, $e.WindowName, $e.Pid) DarkGray
            $resp = Read-Host "open another? (y/N)"
            if (-not ($resp -match '^[Yy]$')) { Write-Color "aborted" Yellow; return $false }
            return $true
        } catch {}
    }
    return $true
}

# ---------------------------------------------------------------------------
# spawn
# ---------------------------------------------------------------------------

function Open-ClaudeShell {
    param(
        [string]$Path,
        [string]$Repo,
        [string]$Branch,
        [string]$PromptText,
        [string]$WindowName,        # $null/empty = brand-new window; otherwise -w <name>
        [string]$ReuseSessionId,    # if set, reuse an existing session entry (e.g. on restore)
        [switch]$Force,             # bypass the "session already alive" guard
        [switch]$NoClaude,          # spawn the themed shell but don't launch claude (for claudeshell)
        [switch]$Verbose            # show runas chatter
    )

    if (-not $ReuseSessionId) {
        if (-not (Confirm-NoAliveSessionAt -Path $Path -Force:$Force)) { return }
    }

    # claude --continue if claude has a prior session for this cwd under the claude user
    $slug       = ($Path -replace '[:\\/]','-')
    $projDir    = "C:\Users\claude\.claude\projects\$slug"
    $hasSession = (Test-Path $projDir) -and @(Get-ChildItem $projDir -Filter *.jsonl -ErrorAction SilentlyContinue).Count -gt 0
    $contFlag   = if ($hasSession) { ' --continue' } else { '' }

    # only set --name on fresh sessions; --continue carries the existing name forward
    $nameFlag = if ($hasSession -or [string]::IsNullOrWhiteSpace($Branch)) { '' } else {
        $escapedName = $Branch -replace '"', '`"'
        " --name `"$escapedName`""
    }

    $themeFn     = Get-ThemeFnForWindow -WindowName $WindowName
    $themePrefix = if ($themeFn) { "$themeFn; " } else { '' }

    # Pre-write the session entry (Pid=0); the spawned shell patches in PID via Register-GwtSession.
    [System.IO.Directory]::CreateDirectory($script:GwtSessionDir) | Out-Null
    $sessionId = if ($ReuseSessionId) { $ReuseSessionId } else { [guid]::NewGuid().ToString() }
    $existingFirst = $null
    if ($ReuseSessionId) {
        $existingFile = Join-Path $script:GwtSessionDir "$ReuseSessionId.json"
        if (Test-Path $existingFile) {
            try {
                $prev = Get-Content $existingFile -Raw | ConvertFrom-Json
                if ($prev.FirstSpawnedAt) { $existingFirst = $prev.FirstSpawnedAt }
                elseif ($prev.SpawnedAt)  { $existingFirst = $prev.SpawnedAt }
            } catch {}
        }
    }
    $now = (Get-Date).ToString('o')
    $entry = @{
        Id                = $sessionId
        Pid               = 0
        StartTime         = $null
        WtSession         = $null
        FirstSpawnedAt    = if ($existingFirst) { $existingFirst } else { $now }
        LastSpawnedAt     = $null
        SpawnedAt         = $null
        WorktreePath      = $Path
        Branch            = $Branch
        Repo              = $Repo
        WindowName        = $WindowName
        PromptText        = $PromptText
        ClaudeSessionName = $Branch
    }
    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $script:GwtSessionDir "$sessionId.json") -Encoding UTF8

    # Source the registry explicitly -- spawned shell may not have our profile
    $regPrefix = ". 'D:\git\github\dovholuknf\dotfiles\powershell\gwt-session-registry.ps1'; Register-GwtSession -Id '$sessionId'; "

    if ($NoClaude) {
        $cmd = "${regPrefix}${themePrefix}Set-Location '$Path'"
    } elseif ([string]::IsNullOrEmpty($PromptText)) {
        $cmd = "${regPrefix}${themePrefix}Set-Location '$Path'; claude$contFlag$nameFlag"
    } else {
        $escaped = $PromptText -replace '"', '`"'
        $cmd     = "${regPrefix}${themePrefix}Set-Location '$Path'; claude$contFlag$nameFlag `"$escaped`""
    }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

    if (-not [string]::IsNullOrWhiteSpace($WindowName)) {
        $wtArgs = "wt.exe -w $WindowName new-tab -d `"$Path`" pwsh -NoExit -EncodedCommand $enc"
    } else {
        $wtArgs = "wt.exe -d `"$Path`" pwsh -NoExit -EncodedCommand $enc"
    }
    if ($Verbose) {
        runas /user:claude /savecred $wtArgs
    } else {
        $runasOut = & runas /user:claude /savecred $wtArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Color "  runas failed (exit $LASTEXITCODE): $runasOut" Red
        }
    }
    $script:LastSpawnedSessionId = $sessionId
}

function Confirm-OpenOrCd {
    param([string]$Path, [string]$Repo, [string]$Branch, [string]$PromptOverride, [switch]$AutoOpen)

    if ($AutoOpen) {
        $promptText = if ($PromptOverride) { $PromptOverride }
                      else { (Get-ClaudePromptPresets -Repo $Repo -Branch $Branch)[0].Text }
        Open-ClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptText $promptText -WindowName 'active-work'
        return
    }

    $resp = Read-Host "open in claude? (Y/n)"
    if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
        $window = Select-WtWindow
        if ($window -eq '__new__') { $window = $null }
        $promptText = if ($PromptOverride) { $PromptOverride }
                      else { Select-ClaudePrompt -Repo $Repo -Branch $Branch }
        Open-ClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptText $promptText -WindowName $window
    } else {
        $cd = Read-Host "cd there? (Y/n)"
        if ([string]::IsNullOrWhiteSpace($cd) -or $cd -match '^[Yy]$') {
            Set-Clipboard $Path
            Write-Color "path copied to clipboard -- just paste after 'cd '" Cyan
        }
    }
}

# ---------------------------------------------------------------------------
# listing / recovery
# ---------------------------------------------------------------------------

function _Format-ClaudeShells {
    # Render a session collection as a nice colored table.
    param([Parameter(ValueFromPipeline=$true)]$Sessions)
    begin { $items = @() }
    process { if ($Sessions) { $items += $Sessions } }
    end {
        if (-not $items.Count) { Write-Color "(no sessions)" DarkGray; return }
        # Alive: by WindowName, then StartTime (oldest tab first -- proxy for tab order).
        # Stale: by WindowName, then Branch (no meaningful "order" without a process).
        $aliveItems = @($items | Where-Object Alive |
                        Sort-Object WindowName, @{e={ try { [datetime]::Parse($_.StartTime) } catch { [datetime]::MaxValue } } })
        $staleItems = @($items | Where-Object { -not $_.Alive } | Sort-Object WindowName, Branch)
        $sorted = @($aliveItems) + @($staleItems)
        $windowColor = @{
            'active-work'   = 'Green'
            'pull-requests' = 'Blue'
            'tangent'       = 'Magenta'
            'worktrees'     = 'DarkGray'
        }
        Write-Host ""
        Write-Host ("    {0,-13} {1,-30} {2,-22} {3}" -f 'WINDOW','BRANCH','REPO','PATH') -ForegroundColor DarkGray
        Write-Host ("    {0,-13} {1,-30} {2,-22} {3}" -f '------','------','----','----') -ForegroundColor DarkGray
        foreach ($s in $sorted) {
            if ($s.Alive) { Write-Host '  ' -NoNewline; Write-Host '* ' -NoNewline -ForegroundColor White }
            else          { Write-Host '    ' -NoNewline }
            $win = if ($s.WindowName) { $s.WindowName } else { '' }
            $wc  = if ($windowColor[$win]) { $windowColor[$win] } else { 'White' }
            Write-Host ("{0,-13} " -f $win) -NoNewline -ForegroundColor $wc
            $branchColor = if ($s.Alive) { 'White' } else { 'DarkGray' }
            $branchDisp  = if ($s.Branch -and $s.Branch.Length -gt 30) {
                $s.Branch.Substring(0, 28) + '..'
            } else { $s.Branch }
            Write-Host ("{0,-30} " -f $branchDisp) -NoNewline -ForegroundColor $branchColor
            Write-Host ("{0,-22} " -f $s.Repo) -NoNewline -ForegroundColor DarkGray
            Write-Host ("{0}" -f $s.WorktreePath) -ForegroundColor DarkGray
        }
        Write-Host ""
        $aliveN = ($items | Where-Object Alive).Count
        $staleN = $items.Count - $aliveN
        Write-Host ("  alive: {0}    stale: {1}" -f $aliveN, $staleN) -ForegroundColor DarkGray
        Write-Host "  sort:  alive by window -> StartTime (proxy for tab order); stale by window -> branch" -ForegroundColor DarkGray
        Write-Host "  pass -Object for raw objects (pipe / scripting)" -ForegroundColor DarkGray
    }
}

function Get-ClaudeShells {
    # By default, prints a colored tabular view. Pass -Object to return the raw
    # PSCustomObjects (Branch, Repo, WindowName, WorktreePath, Pid, Alive,
    # FirstSpawnedAt, LastSpawnedAt, File, etc.) for piping/scripting.
    param([switch]$Object)
    if (-not (Test-Path $script:GwtSessionDir)) {
        if ($Object) { return @() } else { Write-Color "(no sessions registered yet)" DarkGray; return }
    }

    $procMap = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $procMap[[int]$_.ProcessId] = $_
    }

    $entries = Get-ChildItem $script:GwtSessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
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
        } catch {}
    }

    # Dedupe: alive entry wins; otherwise newest by FirstSpawnedAt (then SpawnedAt)
    $deduped = $entries | Group-Object WorktreePath | ForEach-Object {
        $alive = $_.Group | Where-Object Alive | Select-Object -First 1
        if ($alive) { $alive }
        else {
            $_.Group | Sort-Object @{e='FirstSpawnedAt';desc=$true}, @{e='SpawnedAt';desc=$true} | Select-Object -First 1
        }
    }

    if ($Object) { return $deduped }
    _Format-ClaudeShells -Sessions $deduped
}

function Get-RecoverableClaudeShells {
    # Stale entries whose worktree path still exists on disk -- candidates for restore.
    # Default: tabular view. -Object returns raw objects.
    param([switch]$Object)
    $r = Get-ClaudeShells -Object | Where-Object { -not $_.Alive -and (Test-Path $_.WorktreePath) }
    if ($Object) { return $r }
    _Format-ClaudeShells -Sessions $r
}

function Restore-ClaudeShell {
    # Relaunches a single session. Pass a session object (from Get-ClaudeShells) on
    # the pipeline, or pass -Id explicitly.
    [CmdletBinding(DefaultParameterSetName = 'Pipeline')]
    param(
        [Parameter(ParameterSetName='Pipeline', ValueFromPipeline=$true)]
        $InputObject,
        [Parameter(ParameterSetName='ById')] [string]$Id
    )
    process {
        $entry = if ($Id) { Get-ClaudeShells | Where-Object Id -eq $Id | Select-Object -First 1 } else { $InputObject }
        if (-not $entry) { Write-Color "no session entry to restore" Yellow; return }
        if (-not (Test-Path $entry.WorktreePath)) {
            Write-Color "  skip (worktree gone): $($entry.Branch) @ $($entry.WorktreePath)" Yellow
            return
        }
        Write-Color "  relaunch: $($entry.Branch) -> window=$($entry.WindowName)" Green
        Open-ClaudeShell -Path $entry.WorktreePath -Repo $entry.Repo -Branch $entry.Branch `
                         -PromptText $entry.PromptText -WindowName $entry.WindowName `
                         -ReuseSessionId $entry.Id
    }
}

function _Find-AncestorPwsh {
    # Walk the parent-process chain up from $PID looking for the first pwsh/powershell
    # ancestor (the wt tab hosting claude). The hook itself runs as a child pwsh of
    # claude, so we have to step past the claude.exe layer.
    $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    while ($cur -and $cur.ParentProcessId) {
        $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$($cur.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $cur) { break }
        if ($cur.Name -match '^(pwsh|powershell)\.exe$') { return $cur }
    }
    return $null
}

function Register-OrClaim-ClaudeSession {
    # Called by the claude SessionStart hook. Either claims (and updates) an
    # existing entry that matches WT_SESSION or cwd, or creates a fresh entry
    # for ad-hoc claude launches that didn't go through gwt/claudeshell.
    [System.IO.Directory]::CreateDirectory($script:GwtSessionDir) | Out-Null
    $cwd      = (Get-Location).Path.TrimEnd('\')
    $wtSess   = $env:WT_SESSION
    $tabProc  = _Find-AncestorPwsh
    $tabPid   = if ($tabProc) { [int]$tabProc.ProcessId } else { 0 }
    $tabStart = if ($tabProc) { $tabProc.CreationDate.ToString('o') } else { $null }

    # Try to find an existing entry: prefer WtSession match, then WorktreePath.
    $existing = $null
    Get-ChildItem $script:GwtSessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($existing) { return }
        try {
            $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($wtSess -and $e.WtSession -eq $wtSess) {
                $existing = [PSCustomObject]@{ Entry = $e; File = $_.FullName; MatchedBy = 'WtSession' }
                return
            }
            if ($e.WorktreePath) {
                $epath = ($e.WorktreePath -replace '/', '\').TrimEnd('\')
                if ($epath -eq $cwd -and -not ($e.Pid -and $e.Pid -ne 0)) {
                    $existing = [PSCustomObject]@{ Entry = $e; File = $_.FullName; MatchedBy = 'WorktreePath' }
                }
            }
        } catch {}
    }

    if ($existing) {
        # Claim: patch in the live tab info, preserve original metadata.
        $e = $existing.Entry
        $e.Pid       = $tabPid
        $e.StartTime = $tabStart
        $e.WtSession = $wtSess
        $e.LastSpawnedAt = (Get-Date).ToString('o')
        ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $existing.File -Encoding UTF8
        return
    }

    # Create a new entry from scratch. Best-guess branch/repo via git.
    $branch = ''
    $repo   = ''
    try {
        $b = & git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $b) { $branch = $b.Trim() }
    } catch {}
    try {
        $url = & git -C $cwd remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $url -match '/(?<repo>[^/]+?)(?:\.git)?/?\s*$') {
            $repo = $Matches.repo
        }
    } catch {}
    if (-not $repo) { $repo = Split-Path $cwd -Leaf }

    $now = (Get-Date).ToString('o')
    $sessionId = [guid]::NewGuid().ToString()
    $entry = @{
        Id                = $sessionId
        Pid               = $tabPid
        StartTime         = $tabStart
        WtSession         = $wtSess
        FirstSpawnedAt    = $now
        LastSpawnedAt     = $now
        SpawnedAt         = $now
        WorktreePath      = $cwd
        Branch            = $branch
        Repo              = $repo
        WindowName        = $null
        PromptText        = $null
        ClaudeSessionName = $branch
    }
    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $script:GwtSessionDir "$sessionId.json") -Encoding UTF8
}

function Unregister-ClaudeSession {
    # Called by the claude SessionEnd hook. Best-effort: marks the matching
    # entry as stale by zeroing the PID. We keep the entry so 'gwt sessions list'
    # still shows what was there -- run 'gwt sessions clean' to drop them.
    $wtSess = $env:WT_SESSION
    if (-not $wtSess) { return }
    Get-ChildItem $script:GwtSessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($e.WtSession -eq $wtSess) {
                $e.Pid       = 0
                $e.StartTime = $null
                ($e | ConvertTo-Json -Depth 5) | Set-Content -Path $_.FullName -Encoding UTF8
            }
        } catch {}
    }
}

function Restore-AllClaudeShells {
    # Relaunch every recoverable (stale + worktree-still-exists) entry.
    # Polls each newly-spawned entry's Pid until it patches -- skips arbitrary sleeps.
    $stale = @(Get-RecoverableClaudeShells -Object)
    if (-not $stale.Count) { Write-Color "no recoverable sessions" DarkGray; return }
    Write-Color "found $($stale.Count) recoverable session(s)" Cyan
    foreach ($s in $stale) { Write-Color "  $($s.Branch) -> $($s.WindowName)" DarkGray }
    Write-Host ""
    $resp = Read-Host "relaunch these $($stale.Count) session(s)? (Y/n)"
    if (-not ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$')) {
        Write-Color "aborted" Yellow; return
    }
    foreach ($s in $stale) {
        Restore-ClaudeShell -InputObject $s
        $newId = $script:LastSpawnedSessionId
        if ($newId) {
            $newFile = Join-Path $script:GwtSessionDir "$newId.json"
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
