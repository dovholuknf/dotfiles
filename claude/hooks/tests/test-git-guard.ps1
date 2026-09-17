#requires -Version 7
<#
Comprehensive validation of the git policy in pre-tool-use-hook.ps1.

Policy under test:
  - push / pull / fetch          -> ALWAYS blocked (no remote, ever)
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

function Invoke-Hook($cmd, $cwd) {
    # Returns $true when the hook BLOCKS, $false when it allows (no block decision emitted).
    $payload = @{ tool_name = 'Bash'; tool_input = @{ command = $cmd }; cwd = $cwd } | ConvertTo-Json -Compress
    $out = $payload | & pwsh -NoProfile -File $hook
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
)

$pass = 0; $fail = 0; $failed = @()
foreach ($c in $cases) {
    $cwd = if ($c.repo -eq 'claude') { $claudeRepo } else { $mainRepo }
    $blocked = Invoke-Hook $c.cmd $cwd
    $got = if ($blocked) { 'block' } else { 'allow' }
    if ($got -eq $c.expect) {
        $pass++
        Write-Host ("PASS  [{0,-6}] {1,-6} {2}" -f $c.repo, $got, $c.cmd) -ForegroundColor DarkGray
    } else {
        $fail++; $failed += $c
        Write-Host ("FAIL  [{0,-6}] want {1} got {2}  ::  {3}" -f $c.repo, $c.expect, $got, $c.cmd) -ForegroundColor Red
    }
}

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0} passed, {1} failed, {2} total" -f $pass, $fail, $cases.Count) -ForegroundColor ($(if ($fail) { 'Red' } else { 'Green' }))
if ($fail) { exit 1 } else { exit 0 }
