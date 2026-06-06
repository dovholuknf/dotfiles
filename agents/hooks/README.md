# hooks/

The machine-enforced versions of the rules in the prose modules. Prose can be ignored by an agent
that's having a confident day; a hook returning `{decision: "block"}` cannot.

## What's where

The actual hook scripts live under `../../claude/hooks/` (one directory up, then into `claude/hooks/`).
They are NOT duplicated here. This README explains which hook enforces which rule and how to wire them
into your `~/.claude/settings.json`.

## The hooks

### `pre-tool-use-hook.ps1`

Blocks Bash footguns. Maps to rules in `../tooling.md`:

- `cd /path && command` compounds -> blocked.
- `git -C <path>` or `git --git-dir=<path>` -> blocked.
- bare `find ...` -> blocked.
- `;` chaining in Bash -> blocked.
- `>` / `>>` output redirection -> blocked. Use `tee`.
- `gh api` that doesn't start with `gh api -X GET` -> blocked (PR inline-comments endpoint is the
  documented exception).
- inline-env-prefixed docker (`FOO=bar docker ...`) -> blocked. Pass env via `-e`, compose, or
  `--env-file`.

### `atrium-perm-hook.ps1`

Routes permission requests to my private multi-agent hub instead of the default in-tab UI. Auto-
activates when `.mcp.json` in cwd-or-ancestor declares `atrium-agent`. Opt-out via
`$env:ATRIUM_PERM_GATE = 'off'`. Fails OPEN if the hub is unreachable -- claude-code's normal
permission flow takes over rather than the agent getting bricked.

Reads from `../security.md` implicitly: skips MCP-provided tools (`mcp__*`) so the agent's own loop
tool isn't gated on every turn.

### `session-bootstrap.ps1`

Runs `_RegisterOrClaimClaudeSession` / `_UnregisterClaudeSession` on SessionStart / SessionEnd. Uses
`$PSScriptRoot` to find the real `claude-shell.ps1` through the symlink. See `../../claude/README.md`
for the full session-state model.

### `set-session-state.ps1`

Writes lifecycle transitions to `$env:WORKTREE_ROOT\watch\state.log` and patches the per-session JSON
ledger. Fires on `UserPromptSubmit` (thinking), `Stop` (idle), `Notification` (needs-input),
`SessionStart` (startup/resume/clear/compact via `-FromPayloadSource`), `SessionEnd` (ended).

### `no-compound-cd.ps1`

Older single-purpose precursor to `pre-tool-use-hook.ps1`. Kept around for reference. You don't need
to wire this; the bigger hook supersedes it.

## How to wire them

The wiring lives in `../../claude/settings.json` (which is symlinked into `~/.claude/settings.json`).
The full file is checked in; if you adopt this, copy `claude/settings.json` from this repo into your
own dotfiles, adjust the file paths under `hooks/...` to match where you put the scripts, and
symlink it into your `~/.claude/settings.json`.

Order of hook commands within a single event matters: the array runs top-to-bottom. The
`atrium-perm-hook.ps1` runs before `pre-tool-use-hook.ps1` so atrium-approval is checked first,
but the static guards still win (an atrium-approved `FOO=bar docker ...` will still be blocked).

## How to adapt for your own setup

If you fork this template:

1. Decide which Bash patterns YOU want blocked. The list above is mine. Yours may differ.
2. Edit `pre-tool-use-hook.ps1` to add / remove regex patterns. Each pattern returns a
   `{decision: "block", reason: "<your message>"}` JSON object.
3. Skip `atrium-perm-hook.ps1` unless you also adopt atrium (it's pointless without the hub).
4. Keep `session-bootstrap.ps1` and `set-session-state.ps1` if you want session-state tracking; drop
   them otherwise.

## Why hooks beat prose

I've watched many agents read "don't use `;` to chain commands" and then run `cd /path && cmd ;
other-cmd` thirty minutes later. The hook is the authoritative answer; prose is the explanation. Ship
both.
