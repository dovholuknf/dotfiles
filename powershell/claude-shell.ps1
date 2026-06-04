# claude-shell.ps1 -- spawning + session-tracking primitives shared by gwt and
# claudeshell. Source from $PROFILE so the helpers are available everywhere;
# git-worktree.ps1 also dot-sources this so script invocations work.
#
# Public functions (visible in tab completion):
#   ClaudeShell           -- dispatcher: list / restore / remove / open
#   Select-ClaudePrompt   -- pick a starter prompt interactively
#
# Everything else is prefixed with '_' to keep it out of tab completion while
# remaining callable internally.

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

function _GetClaudePromptPresets {
    param([string]$Repo, [string]$Branch)
    return ,@(
        [PSCustomObject]@{ Name = 'blank';    Text = $null }
        [PSCustomObject]@{
            Name = 'critique'
            Text = "critique the changes from this branch ($Branch in $Repo). pay attention to risks and critique overall design. add a cogent summary of the pr when done"
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
    $presets = _GetClaudePromptPresets -Repo $Repo -Branch $Branch

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

function _SelectWtWindow {
    param([string]$Default)   # if set + matches a preset, that row becomes the [N]* default
    $presets = @(
        [PSCustomObject]@{ Name = 'active-work';   Desc = 'attach to "active-work" window' }
        [PSCustomObject]@{ Name = 'pull-requests'; Desc = 'attach to "pull-requests" window' }
        [PSCustomObject]@{ Name = 'tangent';       Desc = 'attach to "tangent" window' }
        [PSCustomObject]@{ Name = 'worktrees';     Desc = 'attach to "worktrees" window (default)' }
        [PSCustomObject]@{ Name = '__new__';       Desc = 'open in a brand-new wt window (no attach)' }
        [PSCustomObject]@{ Name = '__custom__';    Desc = 'type your own window name' }
    )
    # Resolve default index: match $Default against preset names; fallback to row 1.
    $defaultIdx = 0
    if ($Default) {
        for ($i = 0; $i -lt $presets.Count; $i++) {
            if ($presets[$i].Name -ieq $Default) { $defaultIdx = $i; break }
        }
    }
    Write-Host ""
    Write-Color "choose wt window:" DarkGray
    for ($i = 0; $i -lt $presets.Count; $i++) {
        $marker = if ($i -eq $defaultIdx) { '*' } else { ' ' }
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

    $resp = (Read-Host ("choice [{0}]" -f ($defaultIdx + 1))).Trim()
    if ([string]::IsNullOrWhiteSpace($resp)) { $resp = ($defaultIdx + 1).ToString() }

    $idx = 0
    if (-not [int]::TryParse($resp, [ref]$idx) -or $idx -lt 1 -or $idx -gt $presets.Count) {
        Write-Color "invalid choice, using default" Yellow
        return $presets[$defaultIdx].Name
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

function _GetThemeFnForWindow {
    param([string]$WindowName)
    switch ($WindowName) {
        'active-work'   { 'ActiveWork' }
        'pull-requests' { 'PullRequests' }
        'tangent'       { 'Tangent' }
        'worktrees'     { 'Worktrees' }
        default         { $null }
    }
}

function _InvokeGwtHook {
    # Looks for a per-repo hook script at:
    #   D:\worktrees\hooks\<host>\<org>\<repo>\worktree.ps1
    # where <host> is the short host name ('github', 'bitbucket', 'gitlab', ...).
    # Invokes it with -WorktreePath, -Org, -Repo, -RemoteHost so the script can
    # do whatever (copy CMakeUserPresets.json, drop a .env, symlink config, ...).
    param(
        [Parameter(Mandatory)] [string]$Org,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$WorktreePath,
        [string]$RemoteHost = 'github.com'
    )
    $hostShort = switch ($RemoteHost) {
        'github.com'    { 'github'    }
        'bitbucket.org' { 'bitbucket' }
        'gitlab.com'    { 'gitlab'    }
        default         { $RemoteHost }
    }
    $hookFile = Join-Path 'D:\worktrees\hooks' (Join-Path $hostShort (Join-Path $Org (Join-Path $Repo 'worktree.ps1')))
    if (-not (Test-Path $hookFile)) { return }
    Write-Color "running hook: $hookFile" DarkGray
    try {
        & pwsh -NoProfile -File $hookFile -WorktreePath $WorktreePath -Org $Org -Repo $Repo -RemoteHost $RemoteHost
        if ($LASTEXITCODE -ne 0) { Write-Color "hook exited $LASTEXITCODE" Yellow }
    } catch {
        Write-Color "hook '$hookFile' failed: $_" Yellow
    }
}

# ---------------------------------------------------------------------------
# alive-session guard
# ---------------------------------------------------------------------------

function _ConfirmNoAliveSessionAt {
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
            Write-Color ("  branch : {0}" -f $e.Branch) DarkGray
            $winColor = switch ($e.WindowName) {
                'active-work'   { 'Green'    }
                'pull-requests' { 'Blue'     }
                'tangent'       { 'Magenta'  }
                'worktrees'     { 'DarkGray' }
                default         { 'White'    }
            }
            Write-Host "  window : " -NoNewline -ForegroundColor DarkGray
            Write-Host $e.WindowName -ForegroundColor $winColor
            Write-Color ("  pid    : {0}" -f $e.Pid) DarkGray
            $resp = (Read-Host "(f)ocus existing window / (o)pen another tab / (c)ancel? [f]").Trim().ToLower()
            if (-not $resp) { $resp = 'f' }
            switch ($resp) {
                'f' {
                    # wt windows are owned by the claude user, so focus must run there too.
                    Write-Color "focusing wt window '$($e.WindowName)' (as claude user)..." DarkGray
                    & runas /user:claude /savecred "wt.exe -w `"$($e.WindowName)`" focus-tab" 2>&1 | Out-Null
                    return $false
                }
                'o' { return $true }
                default {
                    Write-Color "cancelled" Yellow
                    return $false
                }
            }
            return $true
        } catch {}
    }
    return $true
}

# ---------------------------------------------------------------------------
# spawn
# ---------------------------------------------------------------------------

function _OpenClaudeShell {
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
        if (-not (_ConfirmNoAliveSessionAt -Path $Path -Force:$Force)) { return }
    }

    # Pre-write the session entry. The spawned shell calls _InvokeGwtSpawn,
    # which reads everything (theme, cwd, prompt, --name, etc.) from this file.
    # Keeps the encoded command under runas's ~1024-char limit regardless of
    # how long the prompt is.
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
        NoClaude          = [bool]$NoClaude
    }
    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $script:GwtSessionDir "$sessionId.json") -Encoding UTF8

    # Tiny encoded command: source the registry, then call the all-in-one helper.
    $cmd = ". 'D:\git\github\dovholuknf\dotfiles\powershell\gwt-session-registry.ps1'; _InvokeGwtSpawn -Id '$sessionId'"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

    if (-not [string]::IsNullOrWhiteSpace($WindowName)) {
        $wtArgs = "wt.exe -w $WindowName new-tab -d `"$Path`" pwsh -NoExit -EncodedCommand $enc"
    } else {
        $wtArgs = "wt.exe -d `"$Path`" pwsh -NoExit -EncodedCommand $enc"
    }
    # Admin shells can't read the unelevated /savecred vault -- warn early.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Color "  note: elevated (Admin) shell -- runas /savecred reads a different vault here." Yellow
    }

    if ($Verbose) {
        runas /user:claude /savecred $wtArgs
    } else {
        $runasOut = & runas /user:claude /savecred $wtArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Color "  runas failed (exit $LASTEXITCODE)" Red
            if ($runasOut) {
                Write-Color "  output: $runasOut" Red
            } else {
                Write-Color "  (no output captured -- often means saved credential missing/expired)" DarkGray
                if ($isAdmin) {
                    Write-Color "  -> Admin shell credential vault is separate. Try a non-admin shell." Yellow
                }
                Write-Color "  to (re-)save credential, run interactively once:" DarkGray
                Write-Color "      runas /user:claude /savecred wt.exe" Cyan
                Write-Color "  it will prompt for claude's password; subsequent gwt calls won't ask again." DarkGray
            }
            $encLen = $wtArgs.Length
            Write-Color "  full wt args length: $encLen chars (runas command-line limit ~2048)" DarkGray
            if ($encLen -gt 1900) {
                Write-Color "  -> encoded command may be too long; try a shorter -Prompt or -y to skip prompt" Yellow
            }
            Write-Color "  to retry with full output visible: re-run gwt with -Verbose" DarkGray
        }
    }
    $script:LastSpawnedSessionId = $sessionId
}

function _ConfirmOpenOrCd {
    param([string]$Path, [string]$Repo, [string]$Branch, [string]$PromptOverride, [switch]$AutoOpen)

    # Short-circuit: if an alive session already exists for this path, show the
    # same heads-up _OpenClaudeShell would print -- but do it BEFORE running
    # through the window/prompt picker. Saves the user a bunch of dead clicks.
    if (-not (_ConfirmNoAliveSessionAt -Path $Path)) { return }

    if ($AutoOpen) {
        $promptText = if ($PromptOverride) { $PromptOverride }
                      else { (_GetClaudePromptPresets -Repo $Repo -Branch $Branch)[0].Text }
        _OpenClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptText $promptText -WindowName 'active-work' -Force
        return
    }

    $resp = Read-Host "open in claude? (Y/n)"
    if ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$') {
        $window = _SelectWtWindow
        if ($window -eq '__new__') { $window = $null }
        $promptText = if ($PromptOverride) { $PromptOverride }
                      else { Select-ClaudePrompt -Repo $Repo -Branch $Branch }
        _OpenClaudeShell -Path $Path -Repo $Repo -Branch $Branch -PromptText $promptText -WindowName $window -Force
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

function _GetClaudeShells {
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

function _GetRecoverableClaudeShells {
    # Stale entries whose worktree path still exists on disk -- candidates for restore.
    # Default: tabular view. -Object returns raw objects.
    param([switch]$Object)
    $r = _GetClaudeShells -Object | Where-Object { -not $_.Alive -and (Test-Path $_.WorktreePath) }
    if ($Object) { return $r }
    _Format-ClaudeShells -Sessions $r
}

function _RestoreClaudeShell {
    # Relaunches a single session. Pass a session object (from _GetClaudeShells) on
    # the pipeline, or pass -Id explicitly.
    [CmdletBinding(DefaultParameterSetName = 'Pipeline')]
    param(
        [Parameter(ParameterSetName='Pipeline', ValueFromPipeline=$true)]
        $InputObject,
        [Parameter(ParameterSetName='ById')] [string]$Id
    )
    process {
        $entry = if ($Id) { _GetClaudeShells -Object | Where-Object Id -eq $Id | Select-Object -First 1 } else { $InputObject }
        if (-not $entry) { Write-Color "no session entry to restore" Yellow; return }
        if (-not (Test-Path $entry.WorktreePath)) {
            Write-Color "  skip (worktree gone): $($entry.Branch) @ $($entry.WorktreePath)" Yellow
            return
        }
        Write-Color "  relaunch: $($entry.Branch) -> window=$($entry.WindowName)" Green
        _OpenClaudeShell -Path $entry.WorktreePath -Repo $entry.Repo -Branch $entry.Branch `
                         -PromptText $entry.PromptText -WindowName $entry.WindowName `
                         -ReuseSessionId $entry.Id
    }
}

function _RemoveStaleClaudeShells {
    # Drops session entries whose process is no longer alive. Default: prompts
    # for confirmation. -Force skips. With -All, also drops alive entries.
    # Returns nothing; prints what was removed.
    param([switch]$Force, [switch]$All)
    $all = @(_GetClaudeShells -Object)
    $targets = if ($All) { $all } else { @($all | Where-Object { -not $_.Alive }) }
    if (-not $targets.Count) {
        if ($All) { Write-Color "no sessions to drop" DarkGray }
        else      { Write-Color "no stale sessions to drop" DarkGray }
        return
    }

    $label = if ($All) { 'sessions' } else { 'stale sessions' }
    Write-Color "$label ($($targets.Count)):" DarkGray
    foreach ($s in $targets) {
        $aliveTag = if ($s.Alive) { ' [ALIVE]' } else { '' }
        Write-Color ("  {0,-13}  {1,-30}  @ {2}{3}" -f $s.WindowName, $s.Branch, $s.WorktreePath, $aliveTag) DarkGray
    }
    Write-Host ""
    if (-not $Force) {
        $resp = Read-Host "drop these $($targets.Count) entries? (y/N)"
        if (-not ($resp -match '^[Yy]$')) { Write-Color "aborted" Yellow; return }
    }
    foreach ($s in $targets) {
        Remove-Item $s.File -Force -ErrorAction SilentlyContinue
        Write-Color "  removed: $($s.Branch)" DarkGray
    }
}

function _Find-AncestorPwsh {
    # Walk the parent-process chain up from $PID looking for the first pwsh/powershell
    # ancestor (the wt tab hosting claude). The hook itself runs as a child pwsh of
    # claude, so we have to step past the claude.exe layer.
    #
    # Previous implementation issued a Get-CimInstance per ancestor; each call is
    # ~400ms and the chain is ~8 deep on this box -- it cost ~6s per SessionStart
    # hook. Now we do ONE enumeration into a PID->process map and walk in memory.
    $procMap = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Verbose:$false | ForEach-Object {
        $procMap[[int]$_.ProcessId] = $_
    }
    $cur = $procMap[[int]$PID]
    while ($cur -and $cur.ParentProcessId) {
        $cur = $procMap[[int]$cur.ParentProcessId]
        if (-not $cur) { break }
        if ($cur.Name -match '^(pwsh|powershell)\.exe$') { return $cur }
    }
    return $null
}

function _RegisterOrClaimClaudeSession {
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

    # Ad-hoc claude launches outside a git checkout (no branch detectable):
    # bucket them under [ad-hoc] in the listing and use the leaf dir as the
    # "branch" so they show up identifiable rather than blank. Mark them Saved
    # so 'gwt sessions clean' (any tier) and 'gwt prune -Force' refuse to touch
    # them -- the cwd might be something dangerous like D:\worktrees itself.
    $windowForEntry = $null
    $savedForEntry  = $false
    if (-not $branch) {
        $branch         = "(adhoc:$(Split-Path $cwd -Leaf))"
        $windowForEntry = 'ad-hoc'
        $savedForEntry  = $true
    }

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
        WindowName        = $windowForEntry
        PromptText        = $null
        ClaudeSessionName = $branch
        Saved             = $savedForEntry
    }
    ($entry | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $script:GwtSessionDir "$sessionId.json") -Encoding UTF8
}

function _UnregisterClaudeSession {
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

function _RestoreAllClaudeShells {
    # Relaunch every recoverable (stale + worktree-still-exists) entry.
    # Polls each newly-spawned entry's Pid until it patches -- skips arbitrary sleeps.
    $stale = @(_GetRecoverableClaudeShells -Object)
    if (-not $stale.Count) { Write-Color "no recoverable sessions" DarkGray; return }
    Write-Color "found $($stale.Count) recoverable session(s)" Cyan
    foreach ($s in $stale) { Write-Color "  $($s.Branch) -> $($s.WindowName)" DarkGray }
    Write-Host ""
    $resp = Read-Host "relaunch these $($stale.Count) session(s)? (Y/n)"
    if (-not ([string]::IsNullOrWhiteSpace($resp) -or $resp -match '^[Yy]$')) {
        Write-Color "aborted" Yellow; return
    }
    foreach ($s in $stale) {
        _RestoreClaudeShell -InputObject $s
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

# ---------------------------------------------------------------------------
# public dispatcher
# ---------------------------------------------------------------------------

function ClaudeShell {
    # Single public entry point. Subcommands:
    #   list     -- show registered sessions (default: alive + stale, deduped)
    #               flags: -Recoverable (stale + worktree-exists only), -Object (raw objects)
    #   restore  -- relaunch sessions. -All for every recoverable entry, or -Id <guid> for one.
    #   remove   -- drop session entries. Default: stale only. -All also drops alive entries.
    #               -Force skips the confirmation prompt.
    #   open     -- spawn a wt tab as the claude user (themed, registered). Accepts the same
    #               parameters as the underlying spawn helper.
    param(
        [Parameter(Position=0)]
        [ValidateSet('list','restore','remove','open','shell','help')]
        [string]$Action,

        # list
        [switch]$Recoverable,
        [switch]$Object,

        # restore + remove
        [switch]$All,
        [string]$Id,

        # open
        [string]$Path,
        [string]$Repo,
        [string]$Branch,
        [string]$PromptText,
        [string]$WindowName,
        [string]$ReuseSessionId,
        [switch]$NoClaude,

        # shared
        [switch]$Force,
        [switch]$ShowRunas
    )

    if (-not $Action) { $Action = 'shell' }
    if ($Action -eq 'help') {
        Write-Host ""
        Write-Color "usage: ClaudeShell <action> [options]" White
        Write-Host ""
        Write-Color "  ClaudeShell list [-Recoverable] [-Object]" DarkGray
        Write-Color "      show registered sessions (default: alive + stale)." DarkGray
        Write-Color "      -Recoverable    only stale entries whose worktree still exists" DarkGray
        Write-Color "      -Object         emit raw objects (for piping)" DarkGray
        Write-Host ""
        Write-Color "  ClaudeShell restore [-All | -Id <guid>]" DarkGray
        Write-Color "      relaunch sessions. -All restores every recoverable entry;" DarkGray
        Write-Color "      -Id <guid> restores one." DarkGray
        Write-Host ""
        Write-Color "  ClaudeShell remove [-All] [-Force]" DarkGray
        Write-Color "      drop session entries. Default: stale only." DarkGray
        Write-Color "      -All     also drop alive sessions" DarkGray
        Write-Color "      -Force   skip the confirmation prompt" DarkGray
        Write-Host ""
        Write-Color "  ClaudeShell open -Path <p> [-Repo <r>] [-Branch <b>] [-PromptText <t>]" DarkGray
        Write-Color "                   [-WindowName <w>] [-ReuseSessionId <id>]" DarkGray
        Write-Color "                   [-NoClaude] [-Force] [-Verbose]" DarkGray
        Write-Color "      spawn a themed wt tab as the claude user." DarkGray
        Write-Host ""
        return
    }

    switch ($Action) {
        'list' {
            if ($Recoverable) {
                _GetRecoverableClaudeShells -Object:$Object
            } else {
                _GetClaudeShells -Object:$Object
            }
        }
        'restore' {
            if ($All) {
                _RestoreAllClaudeShells
            } elseif ($Id) {
                _RestoreClaudeShell -Id $Id
            } else {
                Write-Color "ClaudeShell restore: pass -All or -Id <guid>" Yellow
                Write-Color "  -All       relaunch every recoverable entry" DarkGray
                Write-Color "  -Id <g>    relaunch a single entry by id" DarkGray
            }
        }
        'remove' {
            _RemoveStaleClaudeShells -Force:$Force -All:$All
        }
        'shell' {
            $cwd = (Get-Location).Path

            # Guard: the spawned shell runs as user 'claude', which cannot read
            # under another user's home dir (e.g. C:\Users\clint). Spawning there
            # leaves a useless session entry. Refuse unless -Force.
            if ($cwd -match '^[A-Za-z]:\\Users\\([^\\]+)(\\|$)' -and $Matches[1] -ine 'claude') {
                Write-Color "claudeshell: cwd '$cwd' is under another user's home dir." Yellow
                Write-Color "  spawned shell runs as 'claude' and won't have access here." DarkGray
                Write-Color "  cd into a repo (or pass -Force to override)." DarkGray
                if (-not $Force) { return }
            }

            $window = if ($PSBoundParameters.ContainsKey('WindowName')) { $WindowName } else { _SelectWtWindow }
            if ($window -eq '__new__') { $window = $null }
            _OpenClaudeShell -Path $cwd `
                             -Repo (Split-Path $cwd -Leaf) `
                             -Branch 'claudeshell' `
                             -WindowName $window `
                             -NoClaude `
                             -Force:$Force
        }
        'open' {
            $openParams = @{}
            foreach ($k in 'Path','Repo','Branch','PromptText','WindowName','ReuseSessionId') {
                if ($PSBoundParameters.ContainsKey($k)) { $openParams[$k] = $PSBoundParameters[$k] }
            }
            foreach ($k in 'Force','NoClaude') {
                if ($PSBoundParameters.ContainsKey($k)) { $openParams[$k] = $PSBoundParameters[$k] }
            }
            if ($PSBoundParameters.ContainsKey('ShowRunas')) { $openParams['Verbose'] = $ShowRunas }
            _OpenClaudeShell @openParams
        }
    }
}
