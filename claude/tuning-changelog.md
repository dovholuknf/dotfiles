# Tuning changelog

Shit clint has done to try to make claude suck less. A running log of directive, hook, and config changes
aimed at how claude behaves. Newest first. One dated line per change, plus a short why.

## 2026

- **2026-08-27** Denied the `Artifact` tool in `claude/settings.json` (deny: `Artifact`, `Artifact(*)`). After the agent
  published an overview of clint's setup to a claude.ai-hosted Artifact WITHOUT authorization, clint (rightly furious)
  ordered uploads prevented in hardware, not left to judgment. Nothing publishes off-machine from this account now.
  See memory `no-external-upload-without-authorization`. Deliverables are local files by default; hosting is an
  explicit, per-instance opt-in only.

- **2026-08-26** Fixed the `githooks/pre-push` signature gate range. It verified `$r_sha..$l_sha`, so a
  force-push after rebasing onto main flagged every upstream commit main advanced by (84 of them, none
  clint's to sign). Now scopes to `$l_sha --not --remotes` -- commits genuinely new to any remote -- so real
  commits still get checked and rebases stop tripping it.

- **2026-08-21** Tab-registry reliability pass, after a wt tab-drag repeatedly nuked the layout. (1) `gwt tabs`
  show is now READ-ONLY -- it never rewrites or deletes `.tabs`; dead-pid tabs are shown marked `dead`, not
  stripped. Only `prune`/`clean` may remove entries. (2) The SessionEnd hook (`_UnregisterClaudeSession`) no
  longer strips the `.tabs` line on clean exit -- it just zeroes the ledger PID, so the layout stays
  restorable. (3) New `gwt tabs rebuild` reconstructs `.tabs` from the ledger (newest session per existing
  worktree, active in the last 18h, grouped by window) and marks them Saved so `restore` keeps them. (4) New
  hook `claude/hooks/snapshot-layout.ps1` on UserPromptSubmit: every ~10 min it appends the current
  window->tabs layout to a rolling 1-day history at `D:\worktrees\watch\layout-history.jsonl` (throttled via a
  stamp file), so the layout is restorable to any recent point even after the live registry churns. Why: the
  registry self-destructed on read and on every clean exit, so a drag-kill lost everything.

- **2026-08-19** Subagent activity now shows in `agent-log`. New hook `claude/hooks/log-subagent.ps1` writes
  a `subagent` line on PreToolUse(Task) and a `sub-done` line on SubagentStop into the same `state.log`,
  under the parent session's terminal group. `agent-log` learned the two states (magenta `SUBAGENT` /
  `sub done`). Why: subagents fire no SessionStart/Stop, so a spawned agent's work was invisible and the
  parent just sat on `thinking` until it returned.

- **2026-08-19** Added a `/recap` skill (`claude/skills/recap/`, symlinked into `~/.claude/skills/`). Writes
  a session after-action into `D:\worktrees\history\`, led by a FALSE FINISHES section (every time claude
  said "done" and it reopened) and tagging the filename `--REOPENED` when there were any. Why: clint wanted
  a "you thought this shit was done" marker for sessions, invoked on demand before exit, not auto-run on end
  (a restart looks identical to a real exit, so auto-capture would fire on every restart).

- **2026-08-19** Installed a `Terse Engineer` output style (fetched from CLBRITTON2/windows-dev), real file in
  `claude/output-styles/`, symlinked into `~/.claude/output-styles/`. Testing whether an output style is a
  cleaner home for the terse/no-filler register than the CLAUDE.md chat directives.

- **2026-08-18** Added a CMake-preset guard to the pre-tool-use hook: blocks bare `cmake --build` / bare
  configure in any repo that has presets, forcing `--preset`. Why: a bare cmake reconfigures with the shell
  env, drops `VCPKG_BINARY_SOURCES` and the shared installed dir, and rebuilds every vcpkg port from source
  into the wrong cache. Cost clint a 13-minute rebuild.

- **2026-08-14** Added a Simplified-Technical-English register to the chat directives (active voice, present
  tense, one meaning per word, short sentences). Goal: tighter, clearer replies. Set as a preference, not a
  hard rule, so meaning is never contorted to obey it.
