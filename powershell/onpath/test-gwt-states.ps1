# test-gwt-states.ps1 -- build a sandbox of every gwt worktree state and
# verify that 'gwt list' classifies each one correctly.
#
# Usage:
#   .\test-gwt-states.ps1                    # build, run, print matrix
#   .\test-gwt-states.ps1 -Keep              # don't tear down sandbox afterward
#   .\test-gwt-states.ps1 -SandboxRoot C:\... # override default
#
# Sandbox layout (matches gwt's expected canonical layout under -SourceRoot/-WorktreeRoot):
#   <sandbox>\
#     git\github\testorg\testrepo\           # main clone (cloned from bare below)
#     worktrees\github\testorg\testrepo\<branch>\  # each scenario lives here
#     remote\testrepo.git                    # bare repo acting as "origin"
#
# Each scenario function returns the expected status name + a short blurb so
# the matrix can score "expected vs got" at the end.

[CmdletBinding()]
param(
    [string]$SandboxRoot = (Join-Path $env:TEMP "gwt-test-$(Get-Random)"),
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$gwt = "$PSScriptRoot\git-worktree.ps1"
if (-not (Test-Path $gwt)) { throw "can't find git-worktree.ps1 next to this script" }

# ── sandbox setup ────────────────────────────────────────────────────────────

$RemoteDir   = Join-Path $SandboxRoot 'remote\testrepo.git'
$SourceRoot  = Join-Path $SandboxRoot 'git'
$WorktreeRoot = Join-Path $SandboxRoot 'worktrees'
$MainClone   = Join-Path $SourceRoot 'github\testorg\testrepo'
$WtRoot      = Join-Path $WorktreeRoot 'github\testorg\testrepo'

function _Run {
    param([string]$Where, [string[]]$GitArgs, [switch]$IgnoreFail)
    $cmd = "git -C `"$Where`" $($GitArgs -join ' ')"
    Write-Verbose "  $cmd"
    $out = & git -C $Where @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreFail) {
        throw "git failed: $cmd`n$out"
    }
}

function Setup-Sandbox {
    Write-Host "building sandbox at $SandboxRoot" -ForegroundColor Cyan
    if (Test-Path $SandboxRoot) { Remove-Item $SandboxRoot -Recurse -Force }
    [void](New-Item $RemoteDir -ItemType Directory -Force)
    [void](New-Item $MainClone -ItemType Directory -Force)
    [void](New-Item $WtRoot -ItemType Directory -Force)

    # Bare "remote"
    & git init --bare $RemoteDir 2>&1 | Out-Null

    # Main clone with an initial commit on main
    & git clone $RemoteDir $MainClone 2>&1 | Out-Null
    _Run $MainClone @('config','user.email','test@example.com')
    _Run $MainClone @('config','user.name','test')
    Set-Content -Path (Join-Path $MainClone 'README.md') -Value 'main'
    _Run $MainClone @('add','README.md')
    _Run $MainClone @('commit','-m','initial')
    _Run $MainClone @('branch','-M','main')
    _Run $MainClone @('push','-u','origin','main')
}

# ── scenario builders ────────────────────────────────────────────────────────
# Each function:
#   - creates a worktree under $WtRoot for that scenario
#   - sets up exactly the conditions that should produce a specific status
#   - returns @{ Name = <branch>; Expected = <status>; Note = <short string> }

$scenarios = @()

function _NewBranch {
    param([string]$Name, [string]$From = 'main')
    _Run $MainClone @('worktree','add','-b',$Name, (Join-Path $WtRoot $Name), $From)
}

function _Touch { param([string]$Path, [string]$Text = 'hello') Set-Content -LiteralPath $Path -Value $Text }

function _CommitTo {
    param([string]$Wt, [string]$File, [string]$Msg)
    _Touch (Join-Path $Wt $File) "content for $Msg"
    _Run $Wt @('add', $File)
    _Run $Wt @('commit','-m',$Msg)
}

# ACTIVE: branch has upstream, has commits beyond main, clean
function Scenario-Active {
    $b = 'feat-active'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _CommitTo $wt "feature.txt" "feature commit"
    _Run $wt @('push','-u','origin',$b)
    @{ Name = $b; Expected = 'ACTIVE'; Note = 'has upstream, commits beyond main' }
}

# ACTIVE (no upstream config): commits but never set --track / push -u
function Scenario-ActiveNoUpstream {
    $b = 'feat-no-upstream'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _CommitTo $wt "noup.txt" "no-upstream commit"
    @{ Name = $b; Expected = 'ACTIVE'; Note = 'no upstream config, commits beyond main' }
}

# ACTIVE-REMOTE-GONE: pushed, remote deleted, clean, has commits beyond main
function Scenario-ActiveRemoteGone {
    $b = 'feat-remote-gone'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _CommitTo $wt "rg.txt" "remote-gone commit"
    _Run $wt @('push','-u','origin',$b)
    # Delete branch on remote, then fetch --prune
    & git -C $RemoteDir branch -D $b 2>&1 | Out-Null
    _Run $MainClone @('fetch','origin','--prune')
    @{ Name = $b; Expected = 'ACTIVE-REMOTE-GONE'; Note = 'upstream config kept, origin ref deleted' }
}

# PRUNE (merged): branch is an ancestor of origin/main
function Scenario-PruneMerged {
    $b = 'feat-merged'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _CommitTo $wt "merged.txt" "merge me"
    _Run $wt @('push','-u','origin',$b)
    # Merge into main on the remote side
    _Run $MainClone @('checkout','main')
    _Run $MainClone @('merge','--no-ff',"origin/$b",'-m','merge')
    _Run $MainClone @('push','origin','main')
    _Run $MainClone @('fetch','origin','--prune')
    @{ Name = $b; Expected = 'PRUNE'; Note = 'merged to origin/main' }
}

# PRUNE (no commits, at main): branch created off main, no commits added
function Scenario-PruneNoCommits {
    $b = 'feat-nocommits'
    _NewBranch $b
    @{ Name = $b; Expected = 'PRUNE'; Note = 'no commits beyond main, no upstream config' }
}

# PRUNE (was pushed, remote deleted, clean, no commits beyond main)
function Scenario-PruneWasPushed {
    $b = 'feat-pushed-then-gone'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _Run $wt @('push','-u','origin',$b)        # push empty branch (matches main)
    & git -C $RemoteDir branch -D $b 2>&1 | Out-Null
    _Run $MainClone @('fetch','origin','--prune')
    @{ Name = $b; Expected = 'PRUNE'; Note = 'pushed then remote deleted, clean, no commits' }
}

# DIRTY: tracked file edited
function Scenario-DirtyTracked {
    $b = 'feat-dirty'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _Touch (Join-Path $wt 'README.md') 'modified'
    @{ Name = $b; Expected = 'DIRTY'; Note = 'tracked file edited' }
}

# DIRTY (untracked only) -- should still be DIRTY (we collapsed UNTRACKED-ONLY)
function Scenario-DirtyUntracked {
    $b = 'feat-untracked-only'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _Touch (Join-Path $wt 'scratch.md') 'scratch'
    @{ Name = $b; Expected = 'DIRTY'; Note = 'only new untracked file' }
}

# ORPHAN-NO-GIT: dir under WtRoot with broken/missing .git linkage
function Scenario-OrphanNoGit {
    $name = 'rogue-no-git'
    $dir = Join-Path $WtRoot $name
    [void](New-Item $dir -ItemType Directory -Force)
    @{ Name = $name; Expected = 'ORPHAN-NO-GIT'; Note = 'manually-created folder, no .git' }
}

# ORPHAN (clean, real repo, not in `git worktree list`): independent clone
# placed under WtRoot. It's a valid repo with a .git DIR, but git doesn't
# know it as a worktree of the main clone.
function Scenario-OrphanClean {
    $name = 'rogue-clean'
    $dir = Join-Path $WtRoot $name
    & git clone $RemoteDir $dir 2>&1 | Out-Null
    @{ Name = $name; Expected = 'ORPHAN'; Note = 'independent clone, clean tree' }
}

# ORPHAN-DIRTY: same as OrphanClean but with a dirty tracked-file edit.
function Scenario-OrphanDirty {
    $name = 'rogue-dirty'
    $dir = Join-Path $WtRoot $name
    & git clone $RemoteDir $dir 2>&1 | Out-Null
    _Touch (Join-Path $dir 'README.md') 'orphan dirt'
    @{ Name = $name; Expected = 'ORPHAN-DIRTY'; Note = 'independent clone with edits' }
}

# DIRTY + WAS pushed, remote ref deleted: combination of ActiveRemoteGone + edits.
function Scenario-DirtyRemoteGone {
    $b = 'feat-dirty-remote-gone'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    _CommitTo $wt "drg.txt" "dirty-remote-gone commit"
    _Run $wt @('push','-u','origin',$b)
    & git -C $RemoteDir branch -D $b 2>&1 | Out-Null
    _Run $MainClone @('fetch','origin','--prune')
    # Now add an unsaved edit on top
    _Touch (Join-Path $wt 'README.md') 'dirty after remote gone'
    @{ Name = $b; Expected = 'DIRTY'; Note = 'pushed, remote deleted, then edited tracked file' }
}

# PRUNE (path missing): create a worktree, then nuke its directory leaving
# the git registration dangling. git worktree list still has it but Test-Path
# returns false -> our detector picks PRUNE 'missing'.
function Scenario-PruneMissing {
    $b = 'feat-path-missing'
    _NewBranch $b
    $wt = Join-Path $WtRoot $b
    # Sever the .git pointer FIRST so removing the dir doesn't bother git
    Remove-Item $wt -Recurse -Force
    @{ Name = $b; Expected = 'PRUNE'; Note = 'worktree registered but dir was deleted' }
}

function Build-All {
    Setup-Sandbox
    $script:scenarios = @()
    # registered worktrees (these populate $WtRoot AND get a .git/worktrees/ entry)
    $script:scenarios += (Scenario-Active)
    $script:scenarios += (Scenario-ActiveNoUpstream)
    $script:scenarios += (Scenario-ActiveRemoteGone)
    $script:scenarios += (Scenario-PruneMerged)
    $script:scenarios += (Scenario-PruneNoCommits)
    $script:scenarios += (Scenario-PruneWasPushed)
    $script:scenarios += (Scenario-PruneMissing)
    $script:scenarios += (Scenario-DirtyTracked)
    $script:scenarios += (Scenario-DirtyUntracked)
    $script:scenarios += (Scenario-DirtyRemoteGone)
    # orphans must be created LAST so their dirs don't get scooped up as
    # candidates for `git worktree add`.
    $script:scenarios += (Scenario-OrphanClean)
    $script:scenarios += (Scenario-OrphanDirty)
    $script:scenarios += (Scenario-OrphanNoGit)
}

# ── run gwt list against the sandbox and parse the output ────────────────────

function Run-GwtList {
    Push-Location $MainClone
    try {
        # -NoFetch keeps things deterministic; force github/testorg/testrepo
        # by being inside the main clone.
        $raw = & pwsh -NoProfile -Command "& '$gwt' list -NoFetch -SourceRoot '$SourceRoot' -WorktreeRoot '$WorktreeRoot' -Org testorg -Repo testrepo -RemoteHost github.com 2>&1"
        return $raw
    } finally { Pop-Location }
}

function Parse-Status {
    # Extract '[STATUS]' tokens paired with the branch / dir name from gwt list.
    param([string[]]$Lines)
    $out = @{}
    foreach ($l in $Lines) {
        if ($l -match '^\s*[●\s]*\[(?<status>[A-Z\-]+)\s*\]\s+(?<name>\S+)') {
            $out[$Matches.name] = $Matches.status.Trim()
        }
    }
    return $out
}

# ── main ─────────────────────────────────────────────────────────────────────

Build-All

Write-Host ""
Write-Host "running gwt list against the sandbox..." -ForegroundColor Cyan
$raw = Run-GwtList
$parsed = Parse-Status -Lines $raw

Write-Host ""
Write-Host "raw gwt list output:" -ForegroundColor DarkGray
$raw | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host ""

# Score the matrix
$pass = 0; $fail = 0; $miss = 0
$rows = foreach ($s in $scenarios) {
    $got = $parsed[$s.Name]
    $verdict = if (-not $got)             { 'MISSING'; $miss++ }
               elseif ($got -eq $s.Expected) { 'OK';      $pass++ }
               else                       { 'WRONG';   $fail++ }
    [PSCustomObject]@{
        Branch   = $s.Name
        Expected = $s.Expected
        Got      = if ($got) { $got } else { '-' }
        Verdict  = $verdict
        Note     = $s.Note
    }
}

Write-Host "matrix:" -ForegroundColor Cyan
$rows | Format-Table -AutoSize

Write-Host ""
Write-Host ("totals: pass=$pass  wrong=$fail  missing=$miss") -ForegroundColor ($(if ($fail -eq 0 -and $miss -eq 0) { 'Green' } else { 'Yellow' }))

if (-not $Keep) {
    Write-Host ""
    Write-Host "tearing down sandbox (-Keep to keep it)" -ForegroundColor DarkGray
    Remove-Item $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ""
    Write-Host "sandbox kept at: $SandboxRoot" -ForegroundColor DarkGray
}
