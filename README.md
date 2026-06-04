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

The dotfiles assume drives `D:` (code) and ship Windows path layouts. Adapt to your own.

```powershell
# clone
git clone https://github.com/dovholuknf/dotfiles D:\git\github\dovholuknf\dotfiles

# point your pwsh profile at the included one
New-Item -ItemType SymbolicLink -Path $PROFILE `
  -Target D:\git\github\dovholuknf\dotfiles\powershell\Microsoft.PowerShell_profile.ps1

# wire claude-code hooks + settings (requires Developer Mode or an elevated shell)
New-Item -ItemType SymbolicLink -Path $HOME\.claude\hooks `
  -Target D:\git\github\dovholuknf\dotfiles\claude\hooks
New-Item -ItemType SymbolicLink -Path $HOME\.claude\settings.json `
  -Target D:\git\github\dovholuknf\dotfiles\claude\settings.json
```

Then reload pwsh and `gwt -Help` to see what `gwt` can do.

## Conventions in this repo

- Markdown wraps at 120 characters.
- No em-dashes (U+2014). No double-hyphen as dash. No semicolons in prose.
- No `Co-Authored-By:` trailers on commits.
- Scripts assume PowerShell 7.x. Windows PowerShell 5.1 is not a target.

## Further reading

- `powershell/onpath/README.md` -- what each on-PATH script does.
- `claude/README.md` -- how the claude-code hooks are wired and what each one fires on.
- `powershell/docs/gwt-states.md` -- full state model for `gwt list` / `gwt sessions`.
