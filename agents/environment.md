# environment.md

> **Personal taste**: this whole file is mine. If you're forking, delete it and describe your own
> environment. Mine is Windows-heavy and that doesn't match most people.

OS, shells, stack, layout. The most-personal file in the pack.

## OS and shell

- Windows 11 Pro. Primary daily driver.
- PowerShell 7.x is the primary scripting runtime. Windows PowerShell 5.1 is NOT a target.
- Windows Terminal Preview as the host. Multiple windows themed per purpose (active-work,
  pull-requests, tangent, worktrees, ad-hoc).
- Git Bash + WSL for the Linux bits (mostly Docker, build tooling that assumes POSIX).
- Two Windows accounts: my interactive one (`clint`), and a separate one (`claude`) used as a host for
  agent processes. They share drives but have different profiles.

## Disk layout

- `D:\` -- code. Where everything tracked lives.
- `V:\` -- work tools (Go SDK, .NET, etc), some VHDs for WSL.
- `E:\` -- off-limits to claude (separate mount, sensitive content).
- `C:\` -- OS + small things.

## Env vars driving paths

| Var | Default | Meaning |
| --- | --- | --- |
| `GIT_ROOT` | `D:\git` | Where `git clone` lands. |
| `GH_ROOT` | `$GIT_ROOT\github` | GitHub-flavored slice. |
| `OZ_ROOT` | `$GH_ROOT\openziti` | OpenZiti repos. |
| `NF_ROOT` | `$OZ_ROOT\nf` | NetFoundry forks. |
| `BB_ROOT` | `$GIT_ROOT\bitbucket` | Bitbucket-hosted repos. |
| `DOTFILES` | `$GH_ROOT\dovholuknf\dotfiles` | This repo. |
| `DOTFILES_PWSH` | `$DOTFILES\powershell` | All the pwsh content. |
| `ON_PATH` | `$DOTFILES_PWSH\onpath` | Scripts on `$env:PATH`. |
| `WORKTREE_ROOT` | `D:\worktrees` | Where `gwt new` creates worktrees, where session JSONs live. |

If you find a hardcoded `D:\` literal in code where one of these would work, that's a regression
except as a fallback default inside `if (-not $env:X) { ... }`.

## Tools I expect on PATH

- `git`, `gh`, `pwsh` (PS 7), `go`, `node`, `docker`, `wsl`.
- `jq`, `yq`, `rg` (ripgrep), `fd`, `bat`, `delta` -- prefer these over their built-in equivalents.

## Stack preferences

- **PowerShell 7.x** for OS-side scripts. Cobra-style param blocks. Heavy use of `_TuiSelect` for any
  list picker.
- **Go 1.26.x** for CLIs and small services. Cobra for subcommands.
  `github.com/modelcontextprotocol/go-sdk` for MCP. `github.com/charmbracelet/bubbletea` + `lipgloss`
  for TUIs. `net/http` stdlib for servers.
- **MCP over HTTP/stdio** for inter-agent IPC. File-based IPC is fine for simple cases. Cross-machine
  agent traffic should go through OpenZiti / A2A; do NOT homegrow auth or network identity into a
  single-machine agent tool.
- **No Python / Ruby for one-off shell tasks.** Pure shell or skip it.

## Personal tooling I expect you to know about

These exist in my dotfiles and influence how you work in this environment:

- **`gwt`** -- a worktree manager. Pronounced "git worktree". State machine over `git worktree list`
  with a session ledger and claude-code lifecycle hook integration. Source:
  `powershell/onpath/git-worktree.ps1`. See `dotfiles.md` for the per-repo addendum.
- **Atrium** -- a sibling repo at `D:\git\github\dovholuknf\atrium`. Multi-agent broker; claude-code
  sessions register as MCP agents and POST to a Bubble Tea hub for human prompts. Permission gating
  routes through it.
- **Claude-code hooks** -- under `dotfiles/claude/hooks/`. Symlinked into `~/.claude/hooks/`. Three
  matter: `pre-tool-use-hook.ps1` (footguns), `set-session-state.ps1` (lifecycle log),
  `atrium-perm-hook.ps1` (permission gating into atrium).
- **`_TuiSelect`** -- in `powershell/shared/common-tools.ps1`. The canonical list picker. Don't
  hand-roll another one.

## Common pitfalls in this environment

- `Get-CimInstance Win32_Process` is slow (~300-800ms warm). One enumeration into an in-memory map
  beats per-PID filtered calls in a loop. A SessionStart hook here hit 6.75s before this was fixed.
- `$Args` is a PowerShell automatic variable. Don't declare a param of that name. Use `$GitArgs`.
- Env vars sometimes have trailing backslashes (`$env:WORK_ROOT = 'D:\'`), which doubles when
  concatenated (`D:\\git`). Defensive fix: `($path -replace '\\+','\').TrimEnd('\')`.
- `git config --get branch.X.merge` is more reliable than `git rev-parse @{upstream}` for "has
  upstream" detection.
