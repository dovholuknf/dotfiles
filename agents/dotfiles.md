# dotfiles.md (agent override for the dotfiles repo)

Read this AFTER `AGENTS.md` in the same folder. This file is repo-specific addenda only -- the universal
style + hard-rules in `AGENTS.md` still apply.

## Repo at a glance

Personal Windows dev setup. PowerShell 7 + Go on Windows. The non-obvious pieces:

- `powershell/onpath/git-worktree.ps1` -- `gwt`, a multi-repo worktree manager with a full state
  machine, session ledger, and integration with claude-code lifecycle hooks. The most actively
  edited code in the repo.
- `powershell/shared/common-tools.ps1` -- shared helpers dot-sourced by two users' pwsh profiles.
  Contains `_TuiSelect`, the canonical list picker (see "List pickers" below -- this is load-bearing).
- `claude/hooks/` -- claude-code PreToolUse / SessionStart / SessionEnd / Notification hooks.
  Symlinked into `~/.claude/hooks/`. Three of them matter:
  - `pre-tool-use-hook.ps1` -- blocks shell footguns (compound `cd ... &&`, bare `find`, `;` chains,
    naked `>` redirects, malformed `gh api`, inline-env-prefixed docker).
  - `set-session-state.ps1` -- writes lifecycle transitions to `$env:WORKTREE_ROOT\watch\state.log`
    and patches a `State` field on the per-session JSON ledger.
  - `atrium-perm-hook.ps1` -- when an `.mcp.json` referencing `atrium-agent` is in cwd or any
    ancestor, routes Bash/Write/Edit permission requests to my private agent hub instead of the
    default in-tab UI.

There's a sibling repo (atrium) that the hooks above talk to. If a question is about multi-agent
orchestration, look there. dotfiles owns the hooks; atrium owns the broker.

## Environment vars you should NOT hardcode around

Everything in this repo is env-var driven, with `D:\` fallbacks only inside `if (-not $env:X)` guards.
The vars you'll see:

| Var | Default | Meaning |
| --- | --- | --- |
| `GIT_ROOT` | `D:\git` | Where `git clone` lands. |
| `GH_ROOT` | `$GIT_ROOT\github` | GitHub-flavored slice. |
| `DOTFILES` | `$GH_ROOT\dovholuknf\dotfiles` | This repo. |
| `DOTFILES_PWSH` | `$DOTFILES\powershell` | All the pwsh content. |
| `ON_PATH` | `$DOTFILES_PWSH\onpath` | Scripts on `$env:PATH`. |
| `WORKTREE_ROOT` | `D:\worktrees` | Where `gwt new` creates worktrees and where session JSONs / state.log live. |

If you find yourself writing a literal `D:\worktrees\...` or `D:\git\...` in code that doesn't already
have an env-var fallback, that's a regression. There are a few intentional ones (comments, demo
strings in `wt-themes.ps1`'s help text) -- check before "fixing" them.

## List pickers (load-bearing convention)

`_TuiSelect` in `powershell/shared/common-tools.ps1` is the single picker for every list selection in
pwsh code under this repo. If you find yourself writing a
`for ($i...) { Write-Host "[N] ..." } ; $resp = Read-Host` block, stop and use `_TuiSelect` instead.
It handles arrow keys, digit-jump, multi-digit buffering for lists > 9, Esc/q cancel, an optional
default-highlighted row, and an optional "select all" mode. Consistency matters here -- I unified
every picker in the repo on this and "scan all my scripts and unify this fucking experience" is a
direct quote.

Binary y/N confirmations stay as `Read-Host "... (y/N)"`. The picker would be overkill for two
options. About 16 of those in the repo; that's fine.

The contract is documented in detail in the root `CLAUDE.md` under "List pickers." Read it before
touching `_TuiSelect`.

## Common pitfalls (you've hit these)

- `Get-CimInstance Win32_Process` is slow (~300-800ms warm). One enumeration into an in-memory map
  beats per-PID filtered calls in a loop. A SessionStart hook hit 6.75s before this was fixed.
- `$Args` is a PowerShell automatic variable. Don't declare a param of that name. Use `$GitArgs`.
- `git config --get branch.X.merge` is more reliable than `git rev-parse @{upstream}` for "has
  upstream" detection, because `git fetch --prune` can leave the config in place after the ref is gone.
- The agent-host user account has a GitHub token in its profile that is NOT committed. Never copy any
  env var matching `*TOKEN*` / `*SECRET*` / `*KEY*` into `shared/common-tools.ps1` or anywhere
  committable. Never echo those vars to chat.
- Env vars like `$env:WORK_ROOT` are sometimes set with a trailing backslash, producing doubled
  separators like `D:\\git` when concatenated. The fix is `($path -replace '\\+','\').TrimEnd('\')`.
  Watch for this anywhere you concat env vars into paths.

## Build / test conventions specific to dotfiles

- "Test" usually means I reload `$PROFILE` (or open a fresh pwsh) and run the thing. Tell me the
  one-line reload incantation when it matters.
- For `gwt` changes, run `powershell/onpath/test-gwt-states.ps1` -- it builds a sandbox with one
  example of every worktree state and asserts the classification.
- For hook changes (claude-code lifecycle hooks under `claude/hooks/`), I full-restart a claude tab
  to verify. `/clear` is not always sufficient since the MCP child process can persist.

## When you don't know what to do

- Want to know what every `gwt` subcommand does: `gwt -Help` or the param block at the top of
  `powershell/onpath/git-worktree.ps1`.
- Want to know the gwt state semantics: `powershell/docs/gwt-states.md`.
- Want to know what scripts are on PATH: `powershell/onpath/README.md`.
- Want to know how claude-code hooks are wired: `claude/README.md`.
- Want the full architectural CLAUDE.md (this user has one for agents working on the repo, separate
  from this AGENTS.md): root of repo.
