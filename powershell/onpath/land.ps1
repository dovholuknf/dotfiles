<#
.SYNOPSIS
Land a local scratch branch (such as claude/<item>) on the base branch as one signed commit through a PR.

.DESCRIPTION
Squashes the source branch onto a fresh land/<topic> branch cut from origin/<Base>, commits it with your own signing
setup and your message, pushes it, and opens a PR. Squash-merge the PR on GitHub. The source branch and its commits never
leave this machine, so no agent hashes, trailers or branch names reach the remote. The squash does not scrub file
contents: an agent name written into a file still ships. Review the diff before you land it.

Run it from your own shell. The commit is signed by your git config, not an agent's.

A failure before the commit removes the land branch, which then holds nothing of yours. A failure after the commit keeps
the branch and prints the command to finish by hand.

.EXAMPLE
land.ps1 -Message 'Add the zrok bootstrap script'
#>
param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Source = (git branch --show-current),
    [string]$Topic,
    [string]$Base = 'main',
    [string]$Remote = 'origin',
    [switch]$NoPr
)
$ErrorActionPreference = 'Stop'

# Not named 'Git': pwsh resolves names case-insensitively and prefers functions, so '& git' inside a function named Git
# calls itself until the call depth overflows.
function Invoke-Git { Write-Step "git $args"; & git @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed" } }
function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

if ($Message -match '(?i)claude|anthropic|co-authored-by|generated with') {
    throw 'The message mentions an agent or carries a trailer. Reword it.'
}
if (-not $Source) { throw 'No source branch. Pass -Source.' }
if (git status --porcelain --untracked-files=no) { throw 'The working tree has uncommitted changes. Commit or set them aside.' }
if (-not $Topic) { $Topic = ($Source -replace '^[^/]+/', '') }
$land = "land/$Topic"
if (git show-ref --verify --quiet "refs/heads/$land") { throw "Branch $land already exists. Pass -Topic or delete it." }
Write-Step "landing $Source on $Remote/$Base as $land"

Invoke-Git fetch $Remote $Base
Invoke-Git switch -c $land "$Remote/$Base"
try {
    Invoke-Git merge --squash $Source
    if (-not (git diff --cached --name-only)) { throw "$Source adds nothing on top of $Remote/$Base." }
    Invoke-Git commit -S -m $Message
}
catch {
    Write-Host "land failed before the commit: $_" -ForegroundColor Red
    Write-Step "cleanup: git reset --hard HEAD, git switch $Source, git branch -D $land"
    git reset -q --hard HEAD 2>$null
    git switch -q $Source
    git branch -D $land 2>$null | Out-Null
    throw
}

Write-Step "git push -u $Remote $land"
& git push -u $Remote $land
if ($LASTEXITCODE -ne 0) {
    Write-Step "git switch $Source (keeping $land)"
    git switch -q $Source
    throw "Push failed. The signed commit is kept on $land. Retry: git push -u $Remote $land"
}
if (-not $NoPr) {
    Write-Step "gh pr create --base $Base --head $land --title '$Message'"
    & gh pr create --base $Base --head $land --title $Message --body ''
    if ($LASTEXITCODE -ne 0) {
        Write-Step "git switch $Source (keeping $land)"
        git switch -q $Source
        throw "PR creation failed. $land is pushed. Retry: gh pr create --base $Base --head $land --title '$Message' --body ''"
    }
}
Invoke-Git switch -q $Source
Write-Host "Squash-merge the PR, then run: git branch -D $land; git push $Remote --delete $land"
