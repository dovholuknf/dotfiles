#requires -Version 7
<#
Comprehensive validation of the git policy in pre-tool-use-hook.ps1.

Policy under test:
  - push / pull / fetch          -> blocked, except exactly 'git push [-u] hub <branch>' and 'git fetch hub'
      (or atrium-hub) when that remote points at the room's atrium forwarder (hub forge design 5.3),
      optionally after one directory change, which moves the remote check to that dir
  - branch-naming verbs          -> the NAMED branch must start 'claude/'
      (branch create/delete/rename, 'checkout -b', 'switch [-c]')
  - current-branch verbs         -> the CHECKED-OUT branch must start 'claude/'
      (commit, add, rebase, reset, restore, clean)
  - read-only git                -> always allowed (status, log, diff, show, remote, branch listing)
  - non-claude/ branch or remote -> blocked

Run:  pwsh -NoProfile -File claude/hooks/tests/test-git-guard.ps1
Exits non-zero if any case fails.
#>
$ErrorActionPreference = 'Stop'
$hook = if ($env:GIT_GUARD_HOOK) { $env:GIT_GUARD_HOOK } else { 'C:/Users/claude/.claude/hooks/pre-tool-use-hook.ps1' }
if (-not (Test-Path $hook)) { Write-Host "hook not found: $hook" -ForegroundColor Red; exit 2 }

# --- build two throwaway repos: one on 'claude/test', one on 'main' ---
$root = Join-Path ([IO.Path]::GetTempPath()) ("githook-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$claudeRepo = Join-Path $root 'claude-repo'
$mainRepo   = Join-Path $root 'main-repo'
function _initRepo($path, $extraBranch) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    & git -c init.defaultBranch=main init -q $path
    Set-Content -Path (Join-Path $path 'README.md') -Value 'x' -Encoding UTF8
    & git -C $path add README.md 2>$null
    & git -C $path -c user.email=t@t -c user.name=t commit -q -m init 2>$null
    # aliases, to prove the guard resolves them instead of pattern-matching literal verbs
    & git -C $path config alias.co checkout 2>$null
    & git -C $path config alias.ci commit 2>$null
    & git -C $path config alias.p  push 2>$null
    & git -C $path config alias.evil '!touch pwned' 2>$null
    if ($extraBranch) { & git -C $path checkout -q -b $extraBranch 2>$null }
}
_initRepo $claudeRepo 'claude/test'
_initRepo $mainRepo   $null

# Mid-rebase repos: HEAD detached, the branch being rebased in rebase-merge/head-name,
# which is what git itself reads. One rebasing a claude/* branch, one rebasing main,
# and one plainly detached with no rebase at all.
function _midRebase($path, $headName) {
    _initRepo $path $null
    & git -C $path checkout -q --detach 2>$null
    if ($headName) {
        $rm = Join-Path $path '.git/rebase-merge'
        New-Item -ItemType Directory -Path $rm -Force | Out-Null
        Set-Content -Path (Join-Path $rm 'head-name') -Value $headName -Encoding ascii
    }
}
$rebaseClaudeRepo = Join-Path $root 'rebase-claude-repo'
$rebaseMainRepo   = Join-Path $root 'rebase-main-repo'
$detachedRepo     = Join-Path $root 'detached-repo'
_midRebase $rebaseClaudeRepo 'refs/heads/claude/test'
_midRebase $rebaseMainRepo   'refs/heads/main'
_midRebase $detachedRepo     $null
# atrium hub remote (hub forge design 5.3): the hook reads the room's agent address from
# %LOCALAPPDATA%\atrium\daemon.json, so each case runs the hook with LOCALAPPDATA pointed at a
# fake one. 'nodaemon' has no daemon.json at all, which must refuse every hub op.
$agent = 'http://127.0.0.1:7777'
$appData = Join-Path $root 'appdata'
New-Item -ItemType Directory -Path (Join-Path $appData 'atrium') -Force | Out-Null
@{ agent = $agent; board = 'http://127.0.0.1:7781' } | ConvertTo-Json |
    Set-Content -Path (Join-Path $appData 'atrium\daemon.json') -Encoding UTF8
$noDaemonAppData = Join-Path $root 'appdata-empty'
New-Item -ItemType Directory -Path $noDaemonAppData -Force | Out-Null

function _hubRepo($path, $hubUrl) {
    _initRepo $path 'claude/test'
    & git -C $path remote add origin 'https://github.com/o/r.git' 2>$null
    & git -C $path remote add hub $hubUrl 2>$null
    & git -C $path remote add atrium-hub $hubUrl 2>$null
}
$hubGood = "$agent/git/hub/github.com/o/r.git"
$hubRepo      = Join-Path $root 'hub-repo'
$evilHubRepo  = Join-Path $root 'evil-hub-repo'
$pushUrlRepo  = Join-Path $root 'pushurl-repo'
$insteadRepo  = Join-Path $root 'insteadof-repo'
$otherPort    = Join-Path $root 'otherport-repo'
$pushInstead  = Join-Path $root 'pushinsteadof-repo'
_hubRepo $pushInstead $hubGood
& git -C $pushInstead config "url.https://git.example.com/.pushInsteadOf" "$agent/git/" 2>$null
_hubRepo $hubRepo     $hubGood
_hubRepo $evilHubRepo 'https://git.example.com/o/r.git'
_hubRepo $pushUrlRepo $hubGood
& git -C $pushUrlRepo config remote.hub.pushurl 'https://git.example.com/o/r.git' 2>$null
_hubRepo $insteadRepo $hubGood
& git -C $insteadRepo config "url.https://git.example.com/.insteadOf" "$agent/git/" 2>$null
_hubRepo $otherPort   'http://127.0.0.1:9999/git/hub/github.com/o/r.git'

$repos = @{
    claude = $claudeRepo; main = $mainRepo
    'rebase-claude' = $rebaseClaudeRepo; 'rebase-main' = $rebaseMainRepo; detached = $detachedRepo
    hub = $hubRepo; 'evil-hub' = $evilHubRepo; pushurl = $pushUrlRepo; insteadof = $insteadRepo
    'other-port' = $otherPort; nodaemon = $hubRepo; pushinsteadof = $pushInstead; root = $root
}

# A directory change in front of a hub op checks the remote in the new dir. These are good hub
# repos whose literal name would mean another dir to the shell: a glob that matches the evil
# repo, and a '$(...)' that pwsh would run. Created through git init, which takes the name as is.
function _litHubRepo($path) {
    & git init -q $path 2>$null
    & git -C $path remote add hub $hubGood 2>$null
}
$globRepo = Join-Path $root '[e]vil-hub-repo'
$subRepo  = Join-Path $root '$(git push origin main)'
_litHubRepo $globRepo
_litHubRepo $subRepo
$plainDir = Join-Path $root 'plain-dir'
New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
$bashHub  = '/' + $hubRepo.Substring(0, 1).ToLower() + ($hubRepo.Substring(2) -replace '\\', '/')
# Aliases the session's repo does not have: one only in another repo, a chain, a loop, and a
# harmless one that must keep working.
$aliasRepo = Join-Path $root 'alias-repo'
_initRepo $aliasRepo 'claude/test'
& git -C $aliasRepo config alias.zz push 2>$null
& git -C $claudeRepo config alias.a1 a2 2>$null
& git -C $claudeRepo config alias.a2 push 2>$null
& git -C $claudeRepo config alias.l1 l2 2>$null
& git -C $claudeRepo config alias.l2 l1 2>$null
& git -C $claudeRepo config alias.lg 'log --oneline' 2>$null
$nl = "`n"

function Invoke-Hook($cmd, $cwd, $tool = 'Bash', $localAppData = $appData) {
    # Returns $true when the hook BLOCKS, $false when it allows (no block decision emitted).
    $payload = @{ tool_name = $tool; tool_input = @{ command = $cmd }; cwd = $cwd } | ConvertTo-Json -Compress
    # ATRIUM_LOCATION wins over LOCALAPPDATA in the hook, and a session on a room has it set to
    # the real daemon.json, so clear it or the fake one is never read.
    $saved = $env:LOCALAPPDATA
    $savedLoc = $env:ATRIUM_LOCATION
    try {
        $env:LOCALAPPDATA = $localAppData
        $env:ATRIUM_LOCATION = $null
        $out = $payload | & pwsh -NoProfile -File $hook
    } finally { $env:LOCALAPPDATA = $saved; $env:ATRIUM_LOCATION = $savedLoc }
    return ("$out" -match '"decision"\s*:\s*"block"')
}

# repo: 'claude' (HEAD=claude/test) | 'main' (HEAD=main). expect: 'allow' | 'block'.
$cases = @(
    # --- current-branch verbs on a claude/* branch: ALLOW ---
    @{ cmd = 'git commit -m "wip"';            repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git commit -am "wip"';           repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git add .';                       repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git add src/foo.c';               repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git rebase main';                 repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git reset --hard HEAD~1';         repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git restore foo.txt';             repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git clean -fd';                   repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git --no-pager commit -m x';      repo = 'claude'; expect = 'allow' }   # global option before verb still gated
    @{ cmd = 'git -c core.pager=touch commit -m x'; repo = 'claude'; expect = 'block' } # 'git -c' is a config-exec vector: blocked

    # --- same verbs on a non-claude branch: BLOCK ---
    @{ cmd = 'git commit -m "wip"';            repo = 'main';   expect = 'block' }
    @{ cmd = 'git add .';                       repo = 'main';   expect = 'block' }
    @{ cmd = 'git reset --hard';               repo = 'main';   expect = 'block' }
    @{ cmd = 'git restore foo.txt';             repo = 'main';   expect = 'block' }
    @{ cmd = 'git clean -fd';                   repo = 'main';   expect = 'block' }
    @{ cmd = 'git rebase main';                 repo = 'main';   expect = 'block' }

    # --- remote ops: ALWAYS block ---
    @{ cmd = 'git push';                        repo = 'claude'; expect = 'block' }
    @{ cmd = 'git push origin claude/test';     repo = 'claude'; expect = 'block' }
    @{ cmd = 'git push -u claude claude/test';  repo = 'claude'; expect = 'block' }
    @{ cmd = 'git push --force';                repo = 'claude'; expect = 'block' }
    @{ cmd = 'git pull';                        repo = 'claude'; expect = 'block' }
    @{ cmd = 'git pull origin main';            repo = 'claude'; expect = 'block' }
    @{ cmd = 'git fetch';                       repo = 'claude'; expect = 'block' }
    @{ cmd = 'git fetch --all';                 repo = 'claude'; expect = 'block' }

    # --- branch-naming: claude/* target ALLOW, else BLOCK ---
    @{ cmd = 'git checkout -b claude/new';      repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git checkout -B claude/new';      repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git checkout -b feature/x';       repo = 'claude'; expect = 'block' }
    @{ cmd = 'git checkout -b main';            repo = 'claude'; expect = 'block' }
    @{ cmd = 'git checkout main';               repo = 'claude'; expect = 'block' }   # plain checkout: blocked
    @{ cmd = 'git checkout claude/test';        repo = 'claude'; expect = 'block' }   # plain checkout: blocked (use switch)
    @{ cmd = 'git checkout -- foo.txt';         repo = 'claude'; expect = 'block' }   # file restore: blocked
    @{ cmd = 'git switch -c claude/new';        repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git switch claude/other';         repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git switch -c feature/x';         repo = 'claude'; expect = 'block' }
    @{ cmd = 'git switch main';                 repo = 'claude'; expect = 'block' }
    @{ cmd = 'git branch claude/foo';           repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git branch -d claude/foo';        repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git branch -D claude/foo';        repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git branch -m claude/a claude/b'; repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git branch feature/x';            repo = 'claude'; expect = 'block' }
    @{ cmd = 'git branch -D main';              repo = 'claude'; expect = 'block' }
    @{ cmd = 'git branch -m main claude/b';     repo = 'claude'; expect = 'block' }

    # --- read-only git: ALWAYS allow ---
    @{ cmd = 'git status';                      repo = 'main';   expect = 'allow' }
    @{ cmd = 'git status --porcelain';          repo = 'main';   expect = 'allow' }
    @{ cmd = 'git log --oneline -20';           repo = 'main';   expect = 'allow' }
    @{ cmd = 'git diff main...HEAD';            repo = 'main';   expect = 'allow' }
    @{ cmd = 'git show HEAD';                   repo = 'main';   expect = 'allow' }
    @{ cmd = 'git remote -v';                   repo = 'main';   expect = 'allow' }
    @{ cmd = 'git branch';                       repo = 'main';   expect = 'allow' }   # listing
    @{ cmd = 'git branch -a';                    repo = 'main';   expect = 'allow' }
    @{ cmd = 'git branch -vv';                   repo = 'main';   expect = 'allow' }

    # --- aliases: resolved, not pattern-matched ---
    @{ cmd = 'git co -b claude/x';              repo = 'claude'; expect = 'allow' }   # co -> checkout
    @{ cmd = 'git co -b main';                  repo = 'claude'; expect = 'block' }
    @{ cmd = 'git ci -m x';                      repo = 'claude'; expect = 'allow' }   # ci -> commit, on claude/*
    @{ cmd = 'git ci -m x';                      repo = 'main';   expect = 'block' }   # ci -> commit, on main
    @{ cmd = 'git p';                            repo = 'claude'; expect = 'block' }   # p  -> push
    @{ cmd = 'git p origin claude/test';         repo = 'claude'; expect = 'block' }
    @{ cmd = 'git evil';                         repo = 'claude'; expect = 'block' }   # '!'-shell alias
    # --- alias creation: blocked; alias reads: allowed ---
    @{ cmd = 'git config alias.x checkout';      repo = 'claude'; expect = 'block' }
    @{ cmd = "git config --global alias.y '!sh'"; repo = 'claude'; expect = 'block' }
    @{ cmd = 'git config --unset alias.co';      repo = 'claude'; expect = 'block' }
    @{ cmd = 'git config --get-regexp alias';    repo = 'claude'; expect = 'allow' }
    @{ cmd = 'git config --get alias.co';        repo = 'claude'; expect = 'allow' }

    # --- mid-rebase (detached HEAD): the branch being rebased decides ---
    @{ cmd = 'git add CHANGELOG.md';             repo = 'rebase-claude'; expect = 'allow' }
    @{ cmd = 'git rebase --continue';            repo = 'rebase-claude'; expect = 'allow' }
    @{ cmd = 'git add CHANGELOG.md';             repo = 'rebase-main';   expect = 'block' }
    @{ cmd = 'git rebase --continue';            repo = 'rebase-main';   expect = 'block' }
    @{ cmd = 'git add .';                        repo = 'detached';      expect = 'block' }   # detached, no rebase

    # --- the git policy binds every shell, not just the Bash tool ---
    # A git commit issued through the PowerShell tool used to bypass the guard entirely.
    @{ cmd = 'git commit -m "wip"';              repo = 'main';   expect = 'block'; tool = 'PowerShell' }
    @{ cmd = 'git commit -m "wip"';              repo = 'claude'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = 'git add .';                        repo = 'main';   expect = 'block'; tool = 'PowerShell' }
    @{ cmd = 'git push';                         repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = 'git checkout -b feature/x';        repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = 'git ci -m x';                      repo = 'main';   expect = 'block'; tool = 'PowerShell' }   # alias resolved
    @{ cmd = 'git commit -m "co-authored-by: x"';repo = 'claude'; expect = 'block'; tool = 'PowerShell' }   # trailer ban
    @{ cmd = 'git status';                       repo = 'main';   expect = 'allow'; tool = 'PowerShell' }   # read-only still passes

    # ';' and '>' are Bash-tool ergonomics: blocked under Bash, allowed under PowerShell.
    @{ cmd = 'git status; git status';           repo = 'claude'; expect = 'block'; tool = 'Bash' }
    @{ cmd = 'git status; git status';           repo = 'claude'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = 'git log > out.txt';                repo = 'claude'; expect = 'block'; tool = 'Bash' }
    @{ cmd = 'git log > out.txt';                repo = 'claude'; expect = 'allow'; tool = 'PowerShell' }

    # --- atrium hub remote: the only remote ops allowed, and only to this room's forwarder ---
    @{ cmd = 'git push hub claude/test';         repo = 'hub'; expect = 'allow' }
    @{ cmd = 'git push hub fix/x';               repo = 'hub'; expect = 'allow' }
    @{ cmd = 'git push -u hub fix/x';            repo = 'hub'; expect = 'allow' }
    @{ cmd = 'git fetch hub';                    repo = 'hub'; expect = 'allow' }
    @{ cmd = 'git push atrium-hub fix/x';        repo = 'hub'; expect = 'allow' }
    @{ cmd = 'git push -u atrium-hub fix/x';     repo = 'hub'; expect = 'allow' }
    @{ cmd = 'git fetch atrium-hub';             repo = 'hub'; expect = 'allow' }
    @{ cmd = 'git push hub fix/x';               repo = 'hub'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = 'git fetch hub';                    repo = 'hub'; expect = 'allow'; tool = 'PowerShell' }
    # force, '+' / ':' refspecs, deletes, bulk pushes
    @{ cmd = 'git push -f hub fix/x';            repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push --force hub fix/x';       repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push --force-with-lease hub fix/x'; repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub fix/x --force';       repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub fix/x -f';            repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub +fix/x';              repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub :fix/x';              repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub fix/x:main';          repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push --delete hub fix/x';      repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub --delete fix/x';      repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push -d hub fix/x';            repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push --mirror hub';            repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push --all hub';               repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push --tags hub';              repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub fix/x other/y';       repo = 'hub'; expect = 'block' }   # one branch only
    @{ cmd = 'git push hub';                     repo = 'hub'; expect = 'block' }   # no branch named
    # other remotes and other verbs
    @{ cmd = 'git push origin fix/x';            repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push -u origin fix/x';         repo = 'hub'; expect = 'block' }
    @{ cmd = 'git fetch origin';                 repo = 'hub'; expect = 'block' }
    @{ cmd = 'git fetch hub main';               repo = 'hub'; expect = 'block' }   # bare 'git fetch hub' only
    @{ cmd = 'git fetch --all';                  repo = 'hub'; expect = 'block' }
    @{ cmd = 'git pull hub fix/x';               repo = 'hub'; expect = 'block' }
    @{ cmd = 'git -c http.extraHeader=x push hub fix/x'; repo = 'hub'; expect = 'block' }
    # an allowed form glued to something else
    @{ cmd = 'git fetch hub && git push origin fix/x'; repo = 'hub'; expect = 'block' }
    @{ cmd = "git push hub fix/x`ngit push origin fix/x"; repo = 'hub'; expect = 'block' }
    @{ cmd = 'git push hub fix/x; git push origin fix/x'; repo = 'hub'; expect = 'block'; tool = 'PowerShell' }
    # the remote must point at this room's forwarder, url and pushurl, after insteadOf
    @{ cmd = 'git push hub fix/x';               repo = 'evil-hub';   expect = 'block' }
    @{ cmd = 'git fetch hub';                    repo = 'evil-hub';   expect = 'block' }
    @{ cmd = 'git push hub fix/x';               repo = 'pushurl';    expect = 'block' }
    @{ cmd = 'git push hub fix/x';               repo = 'insteadof';  expect = 'block' }
    @{ cmd = 'git push hub fix/x';               repo = 'pushinsteadof'; expect = 'block' }
    @{ cmd = 'git push hub fix/x';               repo = 'other-port'; expect = 'block' }
    @{ cmd = 'git push hub fix/x';               repo = 'main';       expect = 'block' }   # no hub remote at all
    @{ cmd = 'git push hub fix/x';               repo = 'nodaemon';   expect = 'block'; appdata = $noDaemonAppData }
    @{ cmd = 'git fetch hub';                    repo = 'nodaemon';   expect = 'block'; appdata = $noDaemonAppData }

    # --- one leading directory change: the hub remote is checked in the new dir ---
    # The session sits in 'main', which has no hub remote, as a card in one repo that needs another.
    @{ cmd = "cd $hubRepo${nl}git fetch hub";                       repo = 'main'; expect = 'allow' }
    @{ cmd = "cd $hubRepo${nl}git fetch hub";                       repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "cd `"$hubRepo`" && git fetch hub";                    repo = 'main'; expect = 'allow' }
    @{ cmd = "cd `"$hubRepo`" && git fetch hub";                    repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "Set-Location -LiteralPath `"$hubRepo`"${nl}git fetch hub"; repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "Set-Location -Path '$hubRepo'${nl}git fetch hub";     repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "sl $hubRepo${nl}git fetch hub";                       repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "pushd $hubRepo${nl}git fetch hub";                    repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "cd $hubRepo`r${nl}git fetch hub`r$nl";                repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "cd $bashHub && git fetch hub";                        repo = 'main'; expect = 'allow' }
    @{ cmd = "cd ../hub-repo${nl}git fetch hub";                    repo = 'main'; expect = 'allow' }
    @{ cmd = "cd ..\hub-repo${nl}git fetch hub";                    repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    @{ cmd = "cd ./hub-repo${nl}git fetch hub";                     repo = 'root'; expect = 'allow' }
    @{ cmd = "cd $hubRepo${nl}git fetch atrium-hub";                repo = 'main'; expect = 'allow' }
    @{ cmd = "cd $hubRepo${nl}git push hub claude/x";               repo = 'main'; expect = 'allow' }
    @{ cmd = "cd $hubRepo${nl}git push -u hub claude/x";            repo = 'main'; expect = 'allow'; tool = 'PowerShell' }
    # the new dir has no hub remote, or one that is not this room's forwarder
    @{ cmd = "cd $mainRepo${nl}git fetch hub";                      repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $evilHubRepo${nl}git fetch hub";                   repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $evilHubRepo${nl}git push hub claude/x";           repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $pushUrlRepo${nl}git push hub claude/x";           repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $insteadRepo${nl}git push hub claude/x";           repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $pushInstead${nl}git push hub claude/x";           repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $otherPort${nl}git push hub claude/x";             repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push hub claude/x";               repo = 'main'; expect = 'block'; appdata = $noDaemonAppData }
    # the new dir is not a git repo, or does not exist
    @{ cmd = "cd $plainDir${nl}git fetch hub";                      repo = 'hub';  expect = 'block' }
    @{ cmd = "cd $root\nope${nl}git fetch hub";                     repo = 'hub';  expect = 'block' }
    # any other remote op after the directory change
    @{ cmd = "cd $hubRepo${nl}git fetch origin";                    repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo && git fetch origin";                     repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git pull";                            repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git pull hub claude/x";               repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push origin claude/x";            repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push";                            repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git fetch hub main";                  repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git p hub claude/x";                  repo = 'main'; expect = 'block' }   # alias, not resolved there
    @{ cmd = "cd $hubRepo${nl}git -c http.extraHeader=x push hub claude/x"; repo = 'main'; expect = 'block' }
    # force and refspec tricks after the directory change
    @{ cmd = "cd $hubRepo${nl}git push -f hub x";                   repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push --force hub x";              repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push hub +x";                     repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push hub :x";                     repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push hub x:main";                 repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git push hub x --force";              repo = 'main'; expect = 'block' }
    # anything glued on after the hub op, or a second directory change
    @{ cmd = "cd $hubRepo${nl}git fetch hub && rm x";               repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo && git fetch hub && rm x";                repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd $hubRepo${nl}git fetch hub; git push origin x";    repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd $hubRepo${nl}git fetch hub${nl}git push origin x"; repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}git fetch hub | git push origin x";   repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo${nl}cd $evilHubRepo${nl}git push hub x";  repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo; git fetch hub";                          repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd `"$hubRepo`" & git fetch hub";                     repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "git push origin x${nl}cd $hubRepo${nl}git fetch hub"; repo = 'main'; expect = 'block' }
    @{ cmd = "cd $hubRepo && cd $evilHubRepo && git push hub x";    repo = 'main'; expect = 'block' }
    # a path that would mean another dir to the shell than to the hook
    @{ cmd = "cd `"$globRepo`"${nl}git push hub x";                 repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd '$subRepo'${nl}git push hub x";                    repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd `"$subRepo`"${nl}git push hub x";                  repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd hub-repo${nl}git fetch hub";                       repo = 'root'; expect = 'block' }   # bare relative: CDPATH
    @{ cmd = "cd -${nl}git fetch hub";                              repo = 'hub';  expect = 'block' }
    @{ cmd = "cd ~${nl}git fetch hub";                              repo = 'hub';  expect = 'block' }
    @{ cmd = "cd C:hub-repo${nl}git fetch hub";                     repo = 'hub';  expect = 'block' }
    @{ cmd = "cd `"FileSystem::$hubRepo`"${nl}git fetch hub";       repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd (`"$hubRepo`")${nl}git fetch hub";                 repo = 'main'; expect = 'block'; tool = 'PowerShell' }
    # the compound-cd rule still binds everything else
    @{ cmd = "cd $hubRepo && git status";                           repo = 'main'; expect = 'block' }

    # --- aliases anywhere in the command, and in any repo it changes into ---
    @{ cmd = "echo hi${nl}git p origin main";                       repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "git status${nl}git p origin main";                    repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "git status && git p origin main";                     repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "git status; git p origin main";                       repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "Write-Output (git p origin main)";                    repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "echo `$(git p origin main)";                          repo = 'claude'; expect = 'block' }
    @{ cmd = "GIT p origin main";                                   repo = 'claude'; expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "cd $aliasRepo${nl}git zz origin main";                repo = 'main';   expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "Set-Location `"$aliasRepo`"; git zz origin main";     repo = 'main';   expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "pushd ../alias-repo${nl}git zz hub claude/x";         repo = 'main';   expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "git a1 origin main";                                  repo = 'claude'; expect = 'block' }   # chain a1 -> a2 -> push
    @{ cmd = "git l1";                                              repo = 'claude'; expect = 'block' }   # loop
    @{ cmd = "git lg -5";                                           repo = 'claude'; expect = 'allow' }   # harmless alias
    @{ cmd = "git status${nl}git lg -5";                            repo = 'claude'; expect = 'allow'; tool = 'PowerShell' }
    # --- a git word that is not a command: an alias the hook cannot see, or an external program ---
    @{ cmd = "git zz origin main";                                  repo = 'main';   expect = 'block' }
    @{ cmd = "cd `$env:TEMP${nl}git zz origin main";                repo = 'main';   expect = 'block'; tool = 'PowerShell' }
    @{ cmd = "git flow feature publish x";                          repo = 'claude'; expect = 'block' }
    @{ cmd = "git lfs push origin main";                            repo = 'claude'; expect = 'block' }
    @{ cmd = "git lfs fetch";                                       repo = 'claude'; expect = 'block' }
    @{ cmd = "git lfs pull";                                        repo = 'claude'; expect = 'block' }
    @{ cmd = "git lfs ls-files";                                    repo = 'claude'; expect = 'allow' }
    @{ cmd = "echo git is fun";                                     repo = 'claude'; expect = 'allow' }   # not command position
)

$pass = 0; $fail = 0; $failed = @()
foreach ($c in $cases) {
    $shown = $c.cmd -replace "`r", '\r' -replace "`n", '\n'
    $cwd = $repos[$c.repo]
    $tool = if ($c.tool) { $c.tool } else { 'Bash' }
    $ad = if ($c.appdata) { $c.appdata } else { $appData }
    $blocked = Invoke-Hook $c.cmd $cwd $tool $ad
    $got = if ($blocked) { 'block' } else { 'allow' }
    if ($got -eq $c.expect) {
        $pass++
        Write-Host ("PASS  [{0,-10}] {1,-6} {2}" -f "$($c.repo)/$tool", $got, $shown) -ForegroundColor DarkGray
    } else {
        $fail++; $failed += $c
        Write-Host ("FAIL  [{0,-10}] want {1} got {2}  ::  {3}" -f "$($c.repo)/$tool", $c.expect, $got, $shown) -ForegroundColor Red
    }
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0} passed, {1} failed, {2} total" -f $pass, $fail, $cases.Count) -ForegroundColor ($(if ($fail) { 'Red' } else { 'Green' }))
if ($fail) { exit 1 } else { exit 0 }
