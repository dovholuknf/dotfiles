# agent-log / state.log

The live activity feed for every claude-code agent running on this box. `agent-log` (a shared profile function in
`powershell/shared/common-tools.ps1`) tails it, so at any moment you can see which agents need a human, which are
working, and which just finished. If you are an agent, the "Reading it programmatically" section tells you how to
consume the raw feed.

## TL;DR (human)

Run `agent-log` in a pwsh shell. It live-tails the feed and prints one row per meaningful state change. Ctrl-C to stop.

```
time      TAG        [window]              branch                        @ path
13:56:09  NEEDS YOU  [zendesk-16157]       zendesk-16157                 @ D:\worktrees\github\openziti\desktop-edge-win\zendesk-16157
13:56:12  thinking   [ziti]                tangent-all-sdk-samples       @ D:\worktrees\github\openziti\ziti\tangent-all-sdk-samples
13:56:40  done       [ziti]                tangent-all-sdk-samples       @ D:\worktrees\github\openziti\ziti\tangent-all-sdk-samples
```

- `NEEDS YOU` (yellow) = an agent is blocked waiting on you (a permission prompt or a question).
- `thinking` (cyan) = an agent started a turn.
- `done` (green) = an agent finished a turn and is idle.
- `SUBAGENT` / `sub done` (magenta) = a subagent (Task) started or stopped.

## The log file

- Path: `D:\worktrees\watch\state.log` (or `$env:WORKTREE_ROOT\watch\state.log`).
- Append-only. Every claude session on the machine writes to this one shared file.
- One line per lifecycle event, in this format:

  ```
  <ISO-8601 timestamp>  <state>  <branch>  @ <worktree-path>
  ```

  `state` and `branch` are space-padded in the file (11 and 30 wide). Example line:

  ```
  2026-09-01T13:56:09.1234567-04:00  thinking     tangent-all-sdk-samples         @ D:\worktrees\github\openziti\ziti\tangent-all-sdk-samples
  ```

## States, and which hook writes them

Written by `claude/hooks/set-session-state.ps1` and `claude/hooks/log-subagent.ps1`, wired into `claude/settings.json`:

| state | written when |
| --- | --- |
| `thinking` | UserPromptSubmit (a turn began) |
| `idle` | Stop (the turn ended) |
| `needs-input` | Notification (permission prompt or elicitation dialog) -- the agent is waiting on a human |
| `startup` / `resume` / `clear` / `compact` | SessionStart (the payload's `source`) |
| `ended` | SessionEnd |
| `subagent` / `sub-done` | a Task subagent started / stopped |

## `agent-log` (the viewer)

Defined in `powershell/shared/common-tools.ps1`, shared by both the `clint` and `claude` accounts.

- Live-tails `state.log` and shows only the states worth watching: `needs-input`, `idle`, `thinking`, `subagent`,
  `sub-done`. It suppresses `startup` / `resume` / `clear` / `compact` / `ended`.
- Columns: `time  TAG  [window]  branch  @ path`.
  - `time` is `HH:mm:ss`.
  - `TAG` maps state to a fixed-width label: `NEEDS YOU`, `thinking`, `done`, `SUBAGENT`, `sub done`.
  - `[window]` is the Windows Terminal window (the "terminal group") the tab lives in. It is NOT in the log, so
    `agent-log` looks it up from the session ledger (`D:\worktrees\sessions\*.json`) by matching the worktree path.
    Shows `[?]` when no ledger entry matches.
  - `branch` comes from the log line. If the log recorded `(unknown)`, it falls back to the worktree dir's leaf.
- Colors: needs-input yellow, thinking cyan, idle/done green, subagent magenta, sub-done dark magenta.

## Reading it programmatically (agent)

If you are an agent and want the raw signal instead of the live viewer:

1. Tail `D:\worktrees\watch\state.log`.
2. Parse each line with:

   ```
   ^(?<ts>\S+)\s+(?<state>\S+)\s+(?<branch>.+?)\s+@\s+(?<path>.+)$
   ```

3. To resolve the window/tab for a `path`, scan `D:\worktrees\sessions\*.json` for the entry whose `WorktreePath`
   matches (case-insensitive, backslash-normalized) and read its `WindowName`. That ledger entry also carries `Pid`,
   `State`, `Label`, `Branch`, and `ClaudeSessionId`.
4. "Who needs a human right now" = for each path, the most recent `needs-input` line that has no later `idle` or
   `thinking` line for the same path.

## Related

- `gwt watch` -- gwt's built-in tail of this same `state.log`.
- `gwt sessions` -- a snapshot table of every session (ALIVE / PAUSED / STALE / ENDED / SAVED, current state, last
  active). The log here is the event stream; `gwt sessions` is the point-in-time view.
- The session ledger (`D:\worktrees\sessions\`) and the layout snapshots (`D:\worktrees\watch\layout-history.jsonl`)
  are the other pieces of the same monitoring system.
