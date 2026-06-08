# claude/

claude-code configuration tracked in version control. Symlinked into `~/.claude/` so changes are committable.

## Layout

```
claude/
  hooks/
    pre-tool-use-hook.ps1     # the gatekeeper: blocks a handful of footguns
    no-compound-cd.ps1        # older single-purpose version of the cd guard, kept for reference
    set-session-state.ps1     # patches the session ledger with thinking/idle/needs-input
    session-bootstrap.ps1     # tiny dispatcher invoked by SessionStart / SessionEnd
  agents/
    persona.md                # claude-code subagent that reads the agents/ pack at runtime
                              # symlinked into ~/.claude/agents/persona.md
  settings.json               # permissions, hook bindings, statusline
```

## How it's wired in

After cloning the dotfiles repo, run (in a pwsh shell where the symlink target is writable; Developer Mode or
elevation required):

```powershell
$dst = "$env:DOTFILES\claude"
New-Item -ItemType SymbolicLink -Path $HOME\.claude\hooks         -Target "$dst\hooks"
New-Item -ItemType SymbolicLink -Path $HOME\.claude\settings.json -Target "$dst\settings.json"
```

After that, edits to either side resolve through the link. `git status` in the dotfiles repo will show your changes.

## Hook flow

`settings.json` wires these events:

| Event | Hooks fired |
| --- | --- |
| `PreToolUse` (every tool call) | `pre-tool-use-hook.ps1` |
| `UserPromptSubmit` | `set-session-state.ps1 -State thinking` |
| `Stop` | sound + `set-session-state.ps1 -State idle` |
| `Notification` (permission_prompt) | sound + `set-session-state.ps1 -State needs-input` |
| `Notification` (elicitation_dialog) | sound + `set-session-state.ps1 -State needs-input` |
| `PermissionRequest` | sound |
| `SessionStart` | (1) `session-bootstrap.ps1 -Phase start` -> `_RegisterOrClaimClaudeSession` registers / claims the entry, stamps `ClaudeSessionId`. (2) `set-session-state.ps1 -FromPayloadSource` reads claude's `source` field (`startup` / `resume` / `clear` / `compact`) and writes a matching `state.log` line plus patches `State` on the JSON. |
| `SessionEnd` | (1) `set-session-state.ps1 -State ended` writes the `ended` line to `state.log` and patches `State='ended'`. (2) `session-bootstrap.ps1 -Phase end` -> `_UnregisterClaudeSession` zeros the Pid. |

## What `pre-tool-use-hook.ps1` blocks

On `Bash` tool calls, the hook emits `{decision: "block", reason: "..."}` for:

- `cd /path && command` compounds. Run `cd` as a standalone command first.
- `git -C <path>` or `git --git-dir=<path>`. Same fix: `cd` first.
- bare `find ...`. Use glob patterns.
- `;` chaining. Run one command at a time.
- `> file` or `>> file`. Use `tee` instead.
- `gh api` that does not start with `gh api -X GET`. The only exception is the PR inline-comments endpoint.
- inline env-prefixed docker: `FOO=bar docker ...`. Pass env via `docker run -e VAR=val`, a compose block, or
  `--env-file`. Allows `sudo docker`, `time docker`, `docker run -e FOO=bar` and other prefixes that are not
  bash variable assignments.

## Session-state tracking

The state model exists so a single pane of glass (`gwt sessions` + `gwt watch`) can show what every claude-code
instance is doing across many wt tabs.

1. On `SessionStart`:
   - `session-bootstrap.ps1` runs `_RegisterOrClaimClaudeSession`, which reads the hook payload from stdin,
     extracts `session_id`, and stashes it as `ClaudeSessionId` on the matching ledger entry in
     `<WORKTREE_ROOT>\sessions\<guid>.json`.
   - `set-session-state.ps1 -FromPayloadSource` reads the same payload's `source` field (one of `startup`,
     `resume`, `clear`, `compact`) and writes a matching line to `<WORKTREE_ROOT>\watch\state.log`. Also patches
     `State` on the JSON to that source value (gets overwritten by the next `UserPromptSubmit`).
2. On `UserPromptSubmit`, `Stop`, and the two `Notification` matchers, `set-session-state.ps1` reads
   `session_id` from stdin, finds the ledger entry with that `ClaudeSessionId`, patches `State` +
   `LastStateChange`, and appends a line to `state.log`.
3. On `SessionEnd`:
   - `set-session-state.ps1 -State ended` writes an `ended` line to `state.log` and patches `State='ended'`.
   - `session-bootstrap.ps1 -Phase end` runs `_UnregisterClaudeSession` which zeroes the Pid (the entry stays
     so `gwt sessions` can still see it tagged `[ENDED]`).
4. `gwt sessions` reads `State` + `Pid` + path-on-disk and renders the lifecycle tag (`[ACTIVE]`, `[ENDED]`,
   `[PAUSED]`, `[STALE]`, `[SAVED]`) plus a sub-tag (`[THINK]`, `[ idle]`, `[INPUT]` in magenta) for ALIVE
   entries. See `powershell/docs/gwt-states.md` for the full state machine.

`State` only updates the JSON for ALIVE entries (plus the one-shot `ended` write on SessionEnd). PAUSED / STALE
entries show no state sub-tag.

## Adding a new hook

1. Drop the script in `claude/hooks/`.
2. Wire it under the right event in `claude/settings.json`. Use the same `pwsh -NoProfile -File ...` invocation
   pattern the existing hooks use, with a `"timeout"` in seconds.
3. Hooks share stdin with claude's payload (JSON). Read with `[Console]::In.ReadToEnd()` and parse. Anything you
   write to stdout that is valid JSON with a `decision` key is interpreted by claude. Anything else is logged but
   not acted on.
4. Hooks must exit `0`. A non-zero exit is treated as an error and may surface to the user.

## Safety

- `settings.json` is committed. Audit it for tokens or per-user secrets before pushing if you ever paste anything in.
  At time of writing it only contains permission lists, hook commands, and the statusline pointer.
- The `permissions.deny` block forbids destructive git, `.env*` reads, secrets dirs, `~/.aws/`, and the `E:` drive
  (a separate mount this user keeps off-limits to claude).
