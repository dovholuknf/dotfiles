# Why this setup

This repo configures one Windows workstation shared by two accounts: `clint`, the interactive human, and
`claude`, an unprivileged account that hosts claude-code agent instances. This document explains why it is built
this way. For how each part works, follow the links to the reference docs.

## The core idea: the agent runs as its own Windows user

Every claude-code instance runs under a separate Windows account named `claude`, never under `clint`. A real OS
account is the boundary, not a convention or a prompt rule.

Why a whole account:

- A Windows account is an enforced trust boundary. It has its own profile, its own ACLs, its own credential
  vault, and its own integrity level. clint's files, SSH keys, browser data, and DPAPI secrets are denied to
  `claude` by the operating system. A scan run as `claude` confirms it cannot read or list `C:\Users\clint`.
- Blast radius. A misbehaving or prompt-injected agent is confined to what the `claude` account can touch. That
  account is a standard user at Medium integrity with no admin rights and no dangerous privileges.
- Attribution and credentials. `claude` gets its own git signing key and tokens, kept in an untracked secrets
  file. Its actions are attributable to it alone, and its access to remotes is granted or denied independently
  of clint's.

What is shared on purpose: the code drive `D:`, which holds the dotfiles repo and the worktree tree. Both
accounts collaborate there. That sharing is scoped by ACL rather than left as a blanket grant. See
`powershell/docs/account-isolation.md` and the generic tool in `powershell/docs/sandbox-account.md`.

## Running a terminal as claude, from clint

clint works in an ordinary shell. To start an agent, clint runs `gwt claude`, which opens a Windows Terminal tab
that runs claude-code inside the `claude` account. The spawn logic lives in `powershell/claude-shell.ps1`.

The mechanism is `runas`:

```
runas /user:claude /savecred  wt.exe -w <window> new-tab -d <worktree>  pwsh -NoExit -EncodedCommand <base64>
```

- `runas /user:claude` starts the process as the `claude` account, so the tab genuinely runs with claude's token
  and ACLs. The isolation is enforced by Windows, not simulated.
- `/savecred` caches claude's password in Credential Manager after the first interactive entry, so later
  `gwt claude` calls do not prompt.
- `wt.exe` opens or reuses a named window and a new tab in the chosen git worktree.
- The launch command is base64-encoded and kept short. `runas` has a command-line length limit near 1 to 2 KB, so
  the per-session details live in a JSON ledger at `D:\worktrees\sessions\*.json` and the encoded command stays
  tiny.

Why this shape:

- clint stays the driver. One command from clint's own shell, no account switching and no separate login.
- The agent lands where the work is: a specific worktree, in its own window and tab, themed and titled so clint
  can read agent state at a glance.
- The session ledger plus lifecycle hooks let clint watch every agent with `gwt sessions` and `gwt watch`:
  which worktree, which window, and whether it is thinking, idle, or waiting for input.

One caveat: an elevated (Admin) clint shell reads a different `/savecred` vault, so run `gwt claude` from a normal
shell. The state model is documented in `powershell/docs/gwt-states.md`.

## Symlinking claude's config into the repo

claude-code reads its configuration from `~/.claude`: agents, skills, commands, hooks, `settings.json`, and the
global instructions in `~/.claude/CLAUDE.md`. Those are the files the agent actually loads.

Config that lives only in `~/.claude` is not version-controlled. You cannot commit it, diff it, or push it. So the
real files live in this repo under `claude/` and the `~/.claude` entries are symlinks pointing at them:

- per-file symlinks for `agents/*` and `commands/*`
- per-directory symlinks for each skill under `skills/`
- a whole-directory symlink for `hooks`
- a file symlink for `settings.json` and for `CLAUDE.md`

Why:

- Version control. Every agent, skill, and hook is committable and pushable, with history.
- One source of truth. Edit the repo file and claude-code picks it up through the symlink. There is no copy to
  drift out of sync with the live config.
- Easier self-maintenance. The agent edits the in-repo path, which sits inside its working directory. Editing the
  `~/.claude` path directly would trip an out-of-workspace approval prompt. Sourcing the files in the repo lets
  the agent maintain its own config as tracked files.

Two things stay out of the repo on purpose: skills sourced from their own repositories (`doc-check`,
`debug-ziti-desktop-edge-win`) remain canonical where they live, and `settings.local.json` is machine-local and
gitignored.

## The other pieces that make it hold together

- Git separation. `claude` signs its commits with its own SSH key for provenance. clint signs with GPG and is the
  only account that pushes. `claude` has no push credentials, the primary barrier, and a `pre-push` hook also
  rejects any commit not signed by clint. See `githooks/pre-push`.
- Action gating. A `pre-tool-use` hook screens the agent's shell commands and edits, so some actions are blocked
  even when the agent runs as itself. See `claude/README.md`.
- Secrets separation. claude's tokens live in claude's own untracked `~/.profile.secrets.ps1`, never in the
  tracked repo.
- Filesystem sandbox. An ACL policy confines `claude` to writing in its worktrees and its own `claude/` config area,
  so it cannot rewrite the PowerShell scripts clint's shell runs. Codified in `powershell/onpath/sandbox-account.ps1`.

## In short

clint drives. claude executes as a separate, unprivileged Windows user in its own worktree. Everything the agent
touches is either version-controlled, through symlinks into this repo, or scoped by ACL. The agent is useful and
contained at the same time.
