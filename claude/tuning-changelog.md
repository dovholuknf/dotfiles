# Tuning changelog

Shit clint has done to try to make claude suck less. A running log of directive, hook, and config changes
aimed at how claude behaves. Newest first. One dated line per change, plus a short why.

- 2026-10-02: git guard allows exactly `git push [-u] hub <branch>` and `git fetch hub` (also `atrium-hub`), only
  when every url and pushurl of that remote, after insteadOf, starts with this room's forwarder (`<agent>/git/`, agent
  from atrium's daemon.json). Force, `+`/`:` refspecs, deletes, `--mirror`/`--all`/`--tags` and every other remote
  stay refused. 43 new cases in `tests/test-git-guard.ps1`. Why: hub forge stage 1 (atrium
  docs/rnd/hub-forge-design.md 5.3, wall 1), approved by clint 10-02. Inert until atrium's `hub` remote ships.

- 2026-10-02: subagent gate matches `Agent` as well as `Task` (`pre-tool-use-hook.ps1`), and the `log-subagent.ps1`
  PreToolUse matcher is now `Task|Agent`. Why: Claude Code renamed the tool to Agent, so the gate was dead and plain
  subagents ran unchecked. Follow-on, not built: with the gate live, the fan-out skills (review-panel, qa-review) are
  blocked unless they launch atrium sessions. The orchestrator sent that half to atrium's @rnd.

- 2026-10-02: `attribution.pr` set to `"🤖 Generated with deez nutz"`, matching the commit canary. Why: unset, the
  harness told claude to end PR bodies with the "Generated with Claude Code" footer, and it showed up in a suggested
  `gh pr create` for ziti-sdk-c.

- 2026-10-01: auto-compact back on, with `autoCompactWindow: 225000` (tokens). Why: clint wants a hard ceiling on
  session context instead of running sessions to the model's full window.

- 2026-10-01: review-panel skill dispatches reviewers via `atrium_launch` when atrium is available, not the Agent
  tool. Why: the skill hardcoded Agent and overrode the global atrium-first rule on tlsuv PR 378.

- 2026-09-29: denied ScheduleWakeup and ListAgents, and `skillOverrides` loop off. Why: clint says `/loop` should
  not be used, and agent teams are unused. Cuts about 2.6k tokens from every session.

- 2026-09-29: cut 8 agent descriptions to about 40 words (doc-humanizer, codebase-steward, csharp-expert,
  c-systems-reviewer, network-expert, windows-enterprise-veteran, both testers). The three generalists' `tools:`
  now match the testers' read-only set (no cron, push, remote, or task tools). Why: the agent listing loads every
  session.

- 2026-09-29: `permissions.deny` the tools AskUserQuestion, ShareOnboardingGuide, SendFeedback, Workflow, and
  ReportFindings. Why: drop their schemas from every session's startup context. Workflow (ultracode) and the
  `/code-review` findings report stop working until un-denied.

- 2026-09-29: `disableClaudeAiConnectors: true` in `claude/settings.json`. Drops the claude.ai cloud connectors
  (Atlassian, Gmail, Drive, HubSpot). Why: their tool names repeated in every agent's listing line and in the
  deferred-tool list, all unused. Also stripped the `mcp__claude_ai_*` names from the `tools:` lines of
  c-systems-reviewer, network-expert, and windows-enterprise-veteran.

- 2026-09-29: startup skill-list prune. `skillOverrides` off for the 12 claude.ai-synced skills (`enabledPlugins`
  did nothing for them) and 10 bundled skills (kept loop, update-config, code-review), and `disable-model-invocation` on 9 slash-only
  dotfiles skills. Re-symlinked `atrium-join`, `atrium-leave`, `recall`, `review-work` (live copies had drifted to
  plain dirs). Why: cut ~5k tokens of always-loaded skill descriptions.

- 2026-09-29: `autoCompactEnabled: false` in `claude/settings.json`. Why: frees the 33k autocompact buffer. Long
  sessions now hit the hard limit instead of compacting, so rehydrate by hand.

- 2026-09-28: live `~/.claude/settings.json` had become a regular file and drifted from the repo. Copied it over
  `claude/settings.json` as the canonical version and re-symlinked `~/.claude/settings.json` to it. This drops the
  repo's `permissions.deny` git list and brings in the atrium hooks, attribution, and model settings. Why: repo edits
  were not reaching the running config.

- 2026-09-27: `disable-model-invocation: true` on the rarely used skills and commands (ziti-slide, bitbucket,
  to-issue, atrium-join, atrium-leave, allow-docker, mercurius-review). Their descriptions leave the
  always-loaded skill list, and `/name` still runs each one. Also trimmed the four longest descriptions
  (safe-to-push, recap, pii-scan, zendesk-triage) to purpose, triggers, and safety rule, and unlinked
  doc-check from `~/.claude/skills` (the shared docusaurus-shared repo is untouched). Why: cut per-session context.

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
- **2026-09-28** `claude/settings.json` `spinnerTipsEnabled: false`: hide the spinner tips. Why: they are noise under
  the hook-progress line.
- **2026-09-28** `claude/hooks/atrium-perm-hook.ps1`: MCP tool calls now go through atrium's permission gate. Why:
  the `mcp__*` skip was left over from Mode A, which atrium removed.
- **2026-09-29** atrium memory `ask-once-dont-repeat.md`: ask an open question once, never re-append it. Why:
  I re-asked the same question on four routine notices and wasted output tokens.
- **2026-09-30** `claude/settings.json`: the first PreToolUse gate is now `atrium.exe hook --event permission`, not
  `atrium-perm-hook.ps1`. Why: f-006 replace, the Go gate ships with the binary and dedups on `tool_use_id`.
- **2026-09-30** sg4 Defender exclusions (atrium build.claude, D:\worktrees, claude's go-build and go\pkg, go.exe,
  chrome-headless-shell.exe) and `GOTMPDIR` for claude under go-build\tmp. Why: MsMpEng used 103%+ CPU scanning
  builds and test binaries. See atrium docs/user-guide.md Pattern 13.
- **2026-10-01** @review never asks for a whole board suite run before landing: touched sections plus bootClean,
  each alone, and the whole suite runs after landing. Why: clint found the pre-landing whole run far too slow.
- **2026-10-02** settings.json autoCompactWindow 225000 to 253000. Why: Claude compacts ~33k under the window, so 225k
  fired at ~190k, before atrium clears at 200k. 253k puts compaction at ~220k (limit plus 10%), as clint asked.
- **2026-10-05** settings.json autoCompactEnabled true to false. Why: Opus 5.5 sessions run a 200k window, so
  autoCompactWindow 253000 cannot apply and they compacted every ~30 min; clint wants no auto-compaction at all.
- **2026-10-05** settings.json autoCompactEnabled back to true, autoCompactWindow stays 253000 (compacts ~220k). Why:
  the 200k "window" behind the disable was the statusline's hardcoded denominator, not the model; 1M sessions are fine.
- **2026-10-05** statusline ctx denominator is a flat 300000 everywhere. Why: clint wants one fixed scale for now, not
  the model window or an atrium-specific limit.
- **2026-10-06** new skill `/clintify`: rewrites pasted LLM output into clint's preferred form, or with no paste sets the
  session style. Why: rules mined from ~20k of his prompts, shareable with others whose LLM output he reads.
- **2026-10-06** atrium runners on every room (sg4-control, claude-sg4, m1mini, sg3, sgg) no longer pass
  `--autocompact`: the claude row's autocompact template is cleared. Why: claude's own autocompact setting governs.
- **2026-10-06** voice-clint.md gains a "posted-as-clint" register: lowercase, casual, imprecise PR/review replies. Why:
  clint rejected a precise, capitalized PR reply draft; promoted from a project memory.
- **2026-10-06** agents/comments.md bans LLM-cadence comments by name, and /code-audit takes an optional path to audit
  beyond the diff. Why: clint wants a "stupid comment" detector that catches LLM tells and can sweep whole files.
- **2026-10-06** voice-clint.md shared rules flip from "long, comma-heavy sentences" to plain word order, few commas, no
  inversion, no "carries"; comments.md gains lowercase, no restating easy code, no trailing pointers. Why: clint's
  comment review on a PR showed that is how clint writes everywhere.
- **2026-10-06** pull-requests.md commit rule: lead with the behavior change and why users care, one plain sentence,
  small ride-along changes may go unmentioned. Why: clint approved a commit rewrite in that shape over a mechanism list.
- **2026-10-06** UserPromptSubmit hook `clint.exe rw`: a prompt starting with `rw:` saves the last reply and clint's
  rewrite of it as a training pair in pairs-rw.jsonl and is blocked, so it never reaches Claude. Why: rewrites made in
  the moment are the best training data clint can get, and capturing them should cost no tokens.
- **2026-10-07** new agent `web-security-reviewer` (JS/TS, Node/Express, proxies, browser clients). review-panel
  routes js/mjs/ts/html to it, always adds nonfunctional-tester when a diff adds a server, proxy, session store,
  cache, rate limit or retry, installs deps with `--ignore-scripts` before dispatch, tells verifiers to weigh PR intent
  over docs the PR makes stale, and has the critic list new attack surface first. The two testers hand security to
  "the language's security reviewer". Why: the PR 967 panel had no web persona, skipped nonfunctional-tester on a new
  server, could not quote dependency source, and a verifier trusted a stale doc. The critic alone found 7+ misses.
- **2026-10-07** pre-tool-use-hook: the hub-remote exception accepts one leading `cd`/`sl`/`Set-Location`/`pushd`
  (newline or `&&`) and checks the hub remote in that dir. The path must mean the same dir to the hook and the shell
  (no `$`, backtick, glob, `~`, `cd -`, bare relative). Why: a card in one repo could not fetch its sibling repo's hub
  branch and had to ask clint. Same change closes three ways past the remote block: an alias after a newline was not
  expanded, only the first `git <word>` was, and aliases were looked up only in the session's repo, not one the
  command changes into. A `git <word>` in command position that is neither a git command nor a resolved alias is now
  blocked (external `git flow` publishes), and `git lfs push/pull/fetch` is a remote op.
- **2026-10-07** pre-tool-use-hook: `git branch claude/x <start>` passes. Only the new name must be `claude/*`, the
  start point is any commit-ish made of ref characters. Rename, delete, copy and upstream forms still check every name.
  Why: orchestrator-sg4-control could not branch from a sha or tag because the start point was read as a branch name.
- **2026-10-08** atrium .git/hooks commit-msg and pre-push refuse a commit naming claude or anthropic as author,
  committer or co-author. Global git identity on sg4 and m1mini set to dovholuknf. resign-and-push.ps1 rewrites claude
  identities and takes -From to rewrite commits already on main. Why: claude@sg4.local on 6463fc35 put Claude on the
  GitHub contributor list.
- **2026-10-08** voice-clint splits text under clint's name into professional, terse and informal registers, and
  /clintify adds "vague over specific" and test-every-word. Why: a blind bake-off showed the old all-lowercase rule was
  wrong for replies to users, and that drafts lost on word count.
- **2026-10-08** /clintify is linked into ~/.claude/skills and `clint.exe` is on PATH from C:\Users\claude\apps\clint
  (sg4 only). Why: other sessions can now draft in clint's voice and gate it with `clint check`.
- **2026-10-08** Orchestrator memory no-inflight-recaps: worker reports and watch-ended notices get no reply text, only
  milestones, blockers and decisions. Why: clint flagged intra-agent and nuisance chattiness during f-room-spec.
