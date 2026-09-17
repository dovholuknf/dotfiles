# Tuning changelog

Shit clint has done to try to make claude suck less. A running log of directive, hook, and config changes
aimed at how claude behaves. Newest first. One dated line per change, plus a short why.

## 2026

- **2026-09-16** Loosened the git guard in `pre-tool-use-hook.ps1` from "no git mutations at all" to "claude works
  only on its own `claude/*` branches, and never a remote." push/pull/fetch stay ALWAYS blocked; branch-naming
  verbs (branch create/delete/rename, `checkout -b`, `switch`) require a `claude/*` target; current-branch verbs
  (commit, add, rebase, reset, restore, clean) require the checked-out branch to be `claude/*`; read-only git still
  passes. Reason: clint wants claude to do committed work without its authorship touching his branches -- claude
  commits on `claude/*` locally, clint fetches/merges into his own and pushes as himself. Also resolves git
  aliases before the checks (an alias like `co`=checkout or a `!`-shell alias can't smuggle a blocked verb) and
  blocks creating/unsetting aliases via `git config`. Validated by `claude/hooks/tests/test-git-guard.ps1`
  (63 cases). Understood as best-effort defense-in-depth, NOT a wall: a text hook cannot catch every evasion
  (renamed binary, `sh -c`, python subprocess). The real "never push" guarantee lives in the claude account's
  credentials (no push-authorized SSH key, read-only token), not here. NOTE: edited the LIVE
  `~/.claude/hooks/pre-tool-use-hook.ps1`, which has diverged from the repo copy -- reconcile still owed.

- **2026-09-15** Reversed the `gwt new` cd default: it now cds the invoking shell INTO the new worktree as part
  of the action (was: stay in the main clone). Opt back out with `GWT_NEW_CD=off` (0/no also work). Reason: clint
  changed his mind and wants the shell to land in the new worktree. Independent of the claude/atrium spawn.

- **2026-09-06** Neutered `snapshot-layout.ps1` (early-exit unless `GWT_SNAPSHOT_LAYOUT=1`). It was the heaviest
  UserPromptSubmit hook (window/process enumeration) and under load it blew its 5s/10s budget, so every prompt
  printed a "UserPromptSubmit hook timed out" line. Reason: clint moved tab/session capture to atrium, so this hook
  is redundant. Revert by setting the env var.

- **2026-09-02** Added a python block to `pre-tool-use-hook.ps1`, mirroring the existing perl guard. Blocks
  `python`/`python3`/`python.exe` invoked as a Bash command (start or after a pipe/compound) with a nudge to use
  bash or PowerShell, or ask if python is genuinely required. Matches only real invocations, not paths, `grep python`,
  `pip`, or `pythonpath`. Reason: clint wants the agent to reach for bash/pwsh first, not python.

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

- **2026-09-04** Added the `afk` skill, after two nights of handing over a queue of work and re-explaining the
  same nuances each time. Captures the contract (never block, decide and record), the snapshot-and-diff patch
  harness that exists because `git commit` is hook-blocked, reviewing the plan before writing any code,
  verifying migrations against a COPY of the live database, and the three artifacts to leave behind: report,
  demo, replay proof. Also the bash tool's refusals, which cost real time to rediscover twice. Goal: `/afk`
  plus a task list, with nothing else to say.

- **2026-09-15** Set `includeCoAuthoredBy: false` in global settings, at clint's request to stop seeing the
  Claude attribution trailer on his commits. The setting suppresses harness-generated attribution entirely
  rather than swapping one line for another, and a hook now blocks attribution trailers outright, so any
  custom line has to come from a git `prepare-commit-msg` hook or `commit.template` rather than from me.

- **2026-09-15** Corrected the entry above. `includeCoAuthoredBy` is deprecated. The current key is
  `attribution.commit`, a string holding the exact trailer text, with an empty string to hide it. Set to
  clint custom line. No git hook or commit template needed, and the harness emits the line rather than me.
