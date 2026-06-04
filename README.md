# dotfiles

Personal Windows dev setup. PowerShell 7 profile, claude-code hooks, and a worktree-management toolkit (`gwt`).

This repo is opinionated and one-user-shaped. It is published in case any of the patterns are useful, not as a
turn-key install.

## Highlights

- **`gwt`** -- a PowerShell wrapper around `git worktree` that handles cloning, new-branch worktree creation, listing
  with a real state machine (MAIN / ACTIVE / DIRTY / PRUNE / ORPHAN / etc), pruning, and a session ledger that tracks
  every claude-code instance launched into a worktree. See `powershell/docs/gwt-states.md`.
- **claude-code hooks** -- `claude/hooks/pre-tool-use-hook.ps1` blocks a handful of footguns (compound `cd ... &&`,
  `git -C`, bare `find`, `;`-chained commands, naked redirects, malformed `gh api`, inline env-prefixed docker). The
  `set-session-state.ps1` hook tags each session as `thinking` / `idle` / `needs-input` so `gwt sessions` can show
  what's actually busy across many parallel instances.
- **Shared profile** -- `powershell/shared/common-tools.ps1` is dot-sourced by two users' pwsh profiles so PATH
  helpers, add-/remove-tool functions, and a TUI selector are written once.

## Layout

```
powershell/
  Microsoft.PowerShell_profile.ps1   # main user's profile
  shared/common-tools.ps1            # shared between two users' profiles
  claude-shell.ps1                   # spawn wt tabs + claude-code session hooks
  gwt-session-registry.ps1           # session-ledger read/write helpers
  wt-themes.ps1                      # per-worktree wt tab theming
  onpath/                            # scripts intended for $env:PATH
    git-worktree.ps1                 # the gwt entrypoint
    prune-claude-projects.ps1        # find/delete orphan claude transcript dirs
    ...                              # see powershell/onpath/README.md
  docs/gwt-states.md                 # gwt state model reference
claude/
  hooks/                             # claude-code hook scripts (symlinked from ~/.claude/hooks)
  settings.json                      # claude-code settings (symlinked from ~/.claude/settings.json)
wsl/                                 # WSL bootstrap notes, bash path additions, gitconfig
cmd/                                 # legacy cmd.exe bits
```

## Setup (Windows)

All paths are env-var driven. There are no hardcoded drive assumptions in the README; pick a code drive (`D:\` in
this author's setup, but any will do) and set the variables to match. A `~/.profile.ps1` like the one below is the
single source of truth that every script reads from.

```powershell
# ~/.profile.ps1 -- minimal setup. Adjust drive letters and paths to suit.
$env:GIT_ROOT      = 'D:\git'                            # where 'git clone' lands
$env:GH_ROOT       = "$env:GIT_ROOT\github"
$env:DOTFILES      = "$env:GH_ROOT\dovholuknf\dotfiles"  # this repo
$env:DOTFILES_PWSH = "$env:DOTFILES\powershell"
$env:ON_PATH       = "$env:DOTFILES_PWSH\onpath"
$env:WORKTREE_ROOT = 'D:\worktrees'                      # where 'gwt new' creates worktrees

# prepend the onpath dir so the scripts are callable by name
$env:PATH = "$env:ON_PATH;$env:PATH"

# shared helpers (PATH add-/remove- toggles, _TuiSelect, etc) and the gwt machinery
. $env:DOTFILES\powershell\shared\common-tools.ps1
. $env:DOTFILES\powershell\wt-themes.ps1
. $env:DOTFILES\powershell\gwt-session-registry.ps1
. $env:DOTFILES\powershell\claude-shell.ps1

function gwt { & "$env:ON_PATH\git-worktree.ps1" @args }
```

Then clone and wire the symlinks:

```powershell
# clone into the location $env:DOTFILES points at
git clone https://github.com/dovholuknf/dotfiles $env:DOTFILES

# wire claude-code hooks + settings (Developer Mode or an elevated shell)
New-Item -ItemType SymbolicLink -Path $HOME\.claude\hooks         -Target "$env:DOTFILES\claude\hooks"
New-Item -ItemType SymbolicLink -Path $HOME\.claude\settings.json -Target "$env:DOTFILES\claude\settings.json"
```

Reload pwsh and run `gwt -Help`.

`gwt` currently defaults its `-SourceRoot` to `D:\git` and `-WorktreeRoot` to `D:\worktrees` if not passed. Override
per-call (`gwt new ... -SourceRoot $env:GIT_ROOT -WorktreeRoot $env:WORKTREE_ROOT`) or set those defaults to match
your env vars in `git-worktree.ps1` if you fork.

## Conventions in this repo

- Markdown wraps at 120 characters.
- No em-dashes (U+2014). No double-hyphen as dash. No semicolons in prose.
- No `Co-Authored-By:` trailers on commits.
- Scripts assume PowerShell 7.x. Windows PowerShell 5.1 is not a target.

## Further reading

- `powershell/onpath/README.md` -- what each on-PATH script does.
- `claude/README.md` -- how the claude-code hooks are wired and what each one fires on.
- `powershell/docs/gwt-states.md` -- full state model for `gwt list` / `gwt sessions`.
