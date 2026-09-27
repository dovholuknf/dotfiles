# Tuning changelog

Shit clint has done to try to make claude suck less. A running log of directive, hook, and config changes
aimed at how claude behaves. Newest first. One dated line per change, plus a short why.

- 2026-09-25: pre-tool-use git guard now binds every shell, not just the Bash tool. The git policy +
  Co-Authored-By ban were gated on `tool_name == "Bash"`, so a `git commit` on a non-claude/* branch
  sailed straight through the PowerShell tool (that is how e7bd92d got committed to `nightly-fail`).
  Re-gated on `tool_input.command` presence; `;`-chaining and `>`-redirect stay Bash-only (legit in pwsh).
  test-git-guard.ps1 gains PowerShell-tool cases. Why: the guard must catch git regardless of how it is run.

- 2026-09-21: hard rule that features MUST merge back to main cleanly, after a squash merge silently doubled
  atrium's settings dialog. Recorded as memory `merge-cleanly-to-main` and repo doc `docs/merge-hygiene.md`.
  Why: `go build` passed while the board was broken, so the rule is: stay rebased on main, treat index.html and
  schema.go as merge hotspots, and run check-board.sh after any merge.

- 2026-09-21: further trimmed CLAUDE.md 188 -> 96 lines (~5.6k -> ~2.8k tokens). Hoisted the always-on behavioral
  rules into one top block so they cannot be skipped, then pushed the reference prose (gwt behavior, `_TuiSelect`
  contract, pitfalls, profiles, path-layout detail) into new docs: `powershell/docs/{gwt,list-pickers,pitfalls,profiles,path-layout}.md`.
  CLAUDE.md now reads as an index that says "read the doc before working in this subsystem." Why: clint called the
  reference tables dead weight to load every session. Behavioral coverage unchanged, detail is now on-demand.
- 2026-09-21: flagged the office / NetFoundry `anthropic-skills:*` sync skills (docx, pptx, xlsx, pdf, morning,
  customer-trends, hubspot-leads-reporting, ops-triage, trace-analyzer) as context dead weight on this box, ~2.3k
  tokens. NOT disabled: they are claude.ai-synced and global, so the toggle is on the claude.ai account, not in this
  repo. Restore map and per-skill notes in `claude/skills-trim-notes.md` (the "where did blah go" record).
- 2026-09-21: trimmed per-message context bloat. Rewrote the dotfiles project CLAUDE.md from ~9.2k tokens to ~3.5k
  (kept the layout / env-var tables, Conventions, Pitfalls, and the `_TuiSelect` contract verbatim; pushed the gwt /
  themes / hooks narrative into pointers to `powershell/docs/*` and `claude/README.md`). Stripped the `<example>`
  blocks from the `persona` and `style-harvester` agent descriptions (they load into every session's agent list),
  leaving a one-line trigger. Why: clint asked why one message loads ~48k and to cut it. `/context` showed the
  project CLAUDE.md was the single heaviest editable block. Bodies and behavior unchanged.
- 2026-09-21: orchestrator cycles context at wave boundaries. `/clear` (not `/compact`) once no doer has
  un-integrated work, then boot fresh from `docs/cold-start.md`. clint invokes the wrap with "execute wrapup.md"
  (`docs/wrapup.md`). Durable state moved to disk so a cold start loses nothing: `docs/parked-room-changes.md` for
  room-side SHAs owed a restart, deploy scripts relocated to `C:\Users\claude\.atrium2\scripts\` (were the session
  scratchpad, which dies on clear). Why: long warm context ossifies stale assumptions (theme + sg4/sgg errors this
  session came from carrying beliefs, not lacking context), and compaction is lossy.
- 2026-09-21: clint relaxed the "never edit CLAUDE.md" rule. The atrium CLAUDE.md files are symlinks into dotagents;
  I may now edit them when he asks, knowing it propagates to every clone at once. Not unprompted. Why: I was refusing
  a reasonable edit on symlink grounds when he owns the risk and wanted the change.
- 2026-09-21: subagents inside doers - allow READ-ONLY (Explore/Plan), keep redirecting the rest. The `Task` guard
  in `pre-tool-use-hook.ps1` now exempts Explore/Plan from the atrium_launch redirect; every subagent start stays
  logged (type + why) via log-subagent.ps1. Why: doers use Explore ~50x/day to read code; a blanket block crippled
  them, but clint still wants unwatched mutating subagents pushed to real board sessions. Also: idle validated
  doers may be culled to free the launch cap without asking (partial reversal of the 2026-09-19 no-cull rule -
  no-cull still holds for unfinished/unverified work).
- 2026-09-19: do NOT declare work "done" on my own, and do NOT cull/kill atrium doers, unless clint is AFK
  overnight. Report "doer finished, gates passed, awaiting your verification" and leave the session on the board
  with its history. Why: I marked things done and deleted doer cards before clint could verify the work was real.

## 2026

- **2026-09-21** Fixed `gwt prune` from INSIDE the target worktree (the recurring "still on disk / re-run the
  same command" two-step). The prune script is a child process and can't move the parent shell, whose Win32 cwd
  is the actual lock, so removal failed on the first run. The `gwt` wrapper (runs in the shell) now detects a
  `prune` while cwd is under `WORKTREE_ROOT` and moves the shell to the repo's main clone BEFORE invoking the
  script, so the removal succeeds in one run. Reason: clint kept hitting the two-step and it should just work.

- **2026-09-21** Pinned `GWT_ATRIUM_BOARD=http://localhost:7778` in `common-tools.ps1` (guarded; per-session env
  overrides). daemon.json discovery broke after the atrium2/hub rework (the file is no longer where the probe
  looked, for either account), so gwt's atrium opener kept falling back to wt even though the daemon was up on
  7778. Pinning the board is the fix clint asked for: tell the profile the URL, skip discovery. Edit the port
  here if the daemon moves.

- **2026-09-21** Reworked gwt spawning into pluggable "openers": `atrium` (a real board session) or `wt` (a
  Windows Terminal tab). New `_GwtOpener` resolver (in claude-shell.ps1) reads `$env:GWT_OPENER`, then a persisted
  `<WORKTREE_ROOT>\gwt-opener.txt`, then the legacy `GWT_ATRIUM=off` shim, else defaults to `atrium`. All gwt
  spawn paths already funnel through `_OpenClaudeShell`, which now asks `_GwtOpener` (replacing the inline
  GWT_ATRIUM gate), so every path is covered in one place. New `gwt open [atrium|wt]` subcommand shows/sets the
  persisted default. Legacy `New-Worktree.ps1` (dormant, reference-only) still spawns wt directly and was left as
  is. Reason: clint wanted one simple, toggleable setting for where sessions open instead of an atrium-specific env.

- **2026-09-20** Renamed the zrok repo cd-shortcut from `zrok` to `cdzrok`. The `zrok` function shadowed the
  `zrok` binary, so `zrok share ...` silently cd'd instead of running the tool. `oz` unchanged.

- **2026-09-19** Bumped the subagent-redirect concurrency nudge from 5 to 10 (hook reason + CLAUDE.global.md),
  to match the atrium-side hard cap moving to 10 with a reservation model. clint's call. Default-ON for
  `ATRIUM_ONLY_SUBAGENTS` stands.

- **2026-09-19** Redirect plain Claude subagents to atrium sessions. New `Task` branch in
  `pre-tool-use-hook.ps1`: when the `Task` tool fires it is DENIED with a reason that instructs the model to run
  the work as a real atrium session (`atrium_launch`) instead, so agent work is watchable on the board and kept
  in history. The reason also carries a HARD RULE: check `atrium_peers` first and never exceed 5 concurrent
  sessions (atrium enforces the hard cap separately). Gated by `ATRIUM_ONLY_SUBAGENTS`, ON by default (unset =
  redirect); set `=0`/`off`/`false`/`no` to allow normal subagents for a session (needed by review-panel,
  qa-review, pr-review, afk). Fail-open, no external call. Also added a matching line to `CLAUDE.global.md`.
  Reason: clint wants agent work on the board with history, not ephemeral subagents. DEFAULT-ON is pending
  clint's confirmation since it breaks the fan-out skills unless the env is set off.

- **2026-09-19** Set `disableAgentView: true` in `~/.claude/settings.json` to fully disable the agents panel
  (FleetView): the `← for agents` statusline affordance and the `claude agents` command are gone. Reason: clint
  does not use it and wanted it off. Documented setting (settings-reference). Takes effect on next start.

- **2026-09-18** clint put claude into agent-orchestrator mode for the atrium hub/room work. When clint says
  "do X", claude branches a worktree under `D:\worktrees\claude\` on a `claude/*` branch, launches a real atrium
  board session there with a full `BRIEF.md` (via `atrium_launch`, NOT a claude subagent) so both clint and claude
  can interact with it, and lets clint iterate with that agent directly. Deploy happens only when that agent
  messages the orchestrator (handle `atrium-87300`), and it is HUB-ONLY: build atrium2 from the agent's branch,
  rename-aside swap the locked binary, restart the hub process alone, and leave the room running so clint's
  terminals are not interrupted. Room-side Go changes wait for a planned room restart. Reason: clint wants
  parallel, steerable work without a room restart killing his live sessions. The harness fix that made this
  usable: the room's claude harness had `--mcp-config <file>` (variadic) last in `args`, which swallowed the
  appended `{prompt}` positional, so any prompted launch died on "MCP config file not found". Moving the boolean
  `--strict-mcp-config` to the end fixed it.

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
  credentials (no push-authorized SSH key, read-only token), not here. (The hook is tracked: `~/.claude/hooks`
  is a symlink to `dotfiles/claude/hooks`, so edits land in the repo directly -- no reconcile needed. The
  diverged file is `settings.json`, which is a separate real file.)

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
- **2026-09-23** The 10-session cap counts only sessions I launched (my `saNN:` workers), never clint's own cards. Why: his sessions blocked two dispatches.
- **2026-09-23** State and filler hooks: timeout 5s to 15s, `hook-timing.ps1` logs runs over 5s and 10s and ones that never finished to `D:\worktrees\watch\hook-timing.log`. set-session-state parses only ledger files that mention the session, and no longer writes hook-debug.log. Why: prompt hooks timed out under load.
- **2026-09-24** The git guard reads `rebase-merge/head-name` (or `rebase-apply`) when HEAD is detached, so `git add`
  and `rebase --continue` mid-rebase of a `claude/*` branch pass. Five cases in `test-git-guard.ps1`. Why: a rebase
  conflict could not be resolved without handing it back.
- **2026-09-24** Cap wording in `CLAUDE.global.md` and the Task-hook block now says "sessions you launched". Why: the
  old "sessions running" text contradicted the 2026-09-23 rule.
- **2026-09-24** ziti-sdk-c memory `feedback_no_starting_docker_desktop`: never launch Docker Desktop, report a down
  daemon and wait. Why: I started it unasked after `/allow-docker`.
