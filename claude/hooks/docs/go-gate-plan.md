# Plan: port pre-tool-use-hook.ps1 to a Go executable (`gate.exe`)

Status: SUPERSEDED 2026-10-09. The gate stays `atrium hook` (H14). Verdict and reasons:
`D:\git\github\dovholuknf\atrium\docs\rnd\gate-exe-vs-atrium-hook.md`. Personal rules move to a dotfiles rules file
read through a layered `ATRIUM_GUARD_RULES`. Phase 0 and Phase 2 below still apply, run against `atrium hook`.
gate.exe was never built. The rest is kept as the record of the alternative.

## Decision

Port the PreToolUse gatekeeper (`claude/hooks/pre-tool-use-hook.ps1`, 530 lines) to a standalone Go executable. Do
NOT put it inside atrium. Card H14 (`h14-r-hooks-all-in-atrium-the-powershell`) proposes moving every hook into
atrium. This plan narrows that: the gate becomes its own exe, and only the state and title hooks are candidates for
atrium.

### Why an exe

- Every tool call runs the gate. 7-day hook report: 27,607 calls. Each call costs about 1.27 s, and 0.5 s of that is
  PowerShell startup. That is about 9.7 h of tool latency per week, 3.8 h of it pure interpreter startup.
- A Go exe starts in about 10 ms. The git subprocess calls the gate makes (alias lookup, `rev-parse`, `--list-cmds`)
  cost 30 to 50 ms each in any language, so the target is under 50 ms for a non-git command and under 150 ms for a
  git command.
- The repo already ships a Go tool built the same way: `claude/tools/clint` (`go build -o build.claude\clint.exe`,
  `build.claude/` is gitignored, settings.json calls the exe by absolute path).

### Why not atrium

- The gate is a security boundary (no push, claude/* branches only, no git -c, no drive-root folders). If it lives
  in atrium, the gate is down whenever atrium is down, restarting, or being upgraded. A daemon round trip would fail
  open or fail closed. Both are worse than a local exe that has no dependency.
- Sessions that atrium did not start still need the gate.
- Release cadence differs. Gate rules change several times a week in dotfiles. Atrium releases on its own schedule.
- The state and title hooks (`set-session-state.ps1`, `set-tab-title.ps1`) only report what atrium already tracks.
  Those fit atrium, and H14 can keep them.

## Facts the port depends on

- Production runs the gate under Windows PowerShell 5.1 (`powershell.exe`, settings.json line ~274). The test
  harness runs it under pwsh 7 (`test-git-guard.ps1` line ~430). The suite has never tested the production runtime.
  The port removes that gap.
- Rule order matters. The first rule that blocks wins and decides the reason text. The Go port keeps the same order.
- Output is `{"decision":"block","reason":"..."}` or `{"decision":"approve",...}` on stdout, exit 0. Keep that
  format byte for byte for now. A move to `hookSpecificOutput.permissionDecision` is a separate change.
- Claude Code treats a hook that cannot start (missing exe) as a non-blocking error, so a missing `gate.exe` FAILS
  OPEN. See Risks.
- `test-git-guard.ps1` already takes the hook path from `$env:GIT_GUARD_HOOK`, and it runs the hook as a child
  process. It becomes the parity spec once it can launch an exe.

## Layout

```
claude/hooks/gate/              Go module, package main
  main.go                       read stdin, dispatch by tool_name, write the decision
  rules_paths.go                drive-root folder rule
  rules_agent.go                Task/Agent -> atrium redirect
  rules_git.go                  aliases, verb resolution, remote ops, hub exception, branch rules
  rules_shell.go                co-author, go build, cd &&, git -C/-c, find, perl, python, docker, ; and >, cmake, gh api
  rules_write.go                vcpkg files, em-dash, !important, .env
  gitx.go                       git subprocess calls, the --list-cmds cache
  build.ps1                     go build -trimpath -ldflags "-s -w" -o build.claude/gate.exe, then atomic swap
  build.claude/gate.exe         gitignored
```

The hooks dir is symlinked to `~/.claude/hooks`, so settings.json calls
`C:/Users/claude/.claude/hooks/gate/build.claude/gate.exe pre-tool-use`. That keeps the AGENTS.md rule that
settings.json does not encode the dotfiles path.

## Phases

### Phase 0: freeze the spec (before any Go)

1. Let the harness launch any hook: `.ps1` under pwsh, `.ps1` under powershell.exe (`-Runtime 51`), or an `.exe`
   directly. Add a `-Hook` param that defaults to `$env:GIT_GUARD_HOOK`.
2. Run the current suite under 5.1 once. Any case that differs from pwsh is a live bug today. Fix the ps1 first.
3. Add cases for every rule the suite does not cover yet: drive-root paths (Bash and Write), the Agent/Task gate
   (explore/plan exempt, `ATRIUM_ONLY_SUBAGENTS=0`), co-authored-by, `go build` without build.claude, find, perl,
   python, inline-env docker, cmake with and without presets, the two gh api rules, vcpkg files, em-dash, CSS
   `!important`, `.env` and `default.env`.
4. Rename the file to `test-gate.ps1` once it covers more than git.
5. Assert the reason text too, not just block or allow, for one case per rule. That pins the first-match order.

### Phase 1: the port

1. One Go function per rule, called in the ps1's order. No new rules and no rule changes in this phase.
2. Regex translation. RE2 differs from .NET in ways that change matches here:
   - PowerShell `-match` ignores case. Every pattern that used `-match` gets `(?i)`. The two `-cmatch` rules (git -C,
     git -c) keep their exact case and inner `(?i:git)`.
   - RE2 has no lookbehind or lookahead. Three patterns use them: the drive-root regexes (`(?<![\w.])`,
     `(?<![\w./])`) and the redirect rule (`(?!&[\d-])`). Replace each with a match plus a check of the preceding or
     following byte in code. Each one gets its own test cases at the boundary.
   - .NET `\w`, `\s` and `\b` are Unicode. RE2's are ASCII. Add one case with a non-ASCII letter next to a git word
     and confirm the ps1's decision. Match it in Go.
   - `$Matches` after `-match` holds the LAST successful match. The ps1 reads `$Matches[1]` after the hub regex and
     after the checkout/switch regex. Port those to explicit submatch variables.
3. Filesystem: `Test-Path` to `os.Stat`, the `Get-ChildItem -Filter "$seg*"` prefix check to `os.ReadDir` with a
   case-blind prefix compare (NTFS is case-blind).
4. Git calls, with speedup 2 folded in:
   - `git --list-cmds=builtins,main`: cache in `%LOCALAPPDATA%\claude-gate\listcmds-<git version>.txt`. The key is
     the output of `git version` plus the git.exe mtime, so an upgrade invalidates it. Read `git version` only when
     the command has a git word. A cache read or write error is ignored and the list is recomputed from git. If git
     itself fails, the known list is empty, as in the ps1, so every git word in command position blocks.
   - Alias lookup: one `git config --get-regexp ^alias\.` per directory instead of one `config --get` per word.
   - No git subprocess at all when the command has no `git` word.
5. Internal errors fail CLOSED. A panic, an unreadable stdin, or a JSON parse error prints a block with the reason
   "gate.exe internal error: <msg>. Tell clint." A security gate that crashes must not allow.
6. A `gate.exe version` subcommand prints the git commit and a hash of the rule sources. Phase 3 uses it.

### Phase 2: prove parity

1. The Phase 0 suite passes against `gate.exe` and against the ps1 under 5.1. Same decision and same reason text.
2. Differential replay. Extract every Bash, PowerShell, Write, Edit, NotebookEdit, Task and Agent tool input from the
   last 30 days of `~/.claude/projects/**/*.jsonl` (the same source `claude/usage/Get-HookReport.ps1` reads). Feed
   each input to both hooks on this machine, with the same cwd when the cwd still exists. Report every difference in
   decision or reason. The bar is zero unexplained differences. Branch state may have changed since a call was
   made, but it is the same for both hooks at replay time, so it does not cause a false diff.
3. Timing. Run the suite with both hooks and record p50 and p95 per case. Expected: ps1 about 1.3 s, exe under
   150 ms.

### Phase 3: cut over

1. Change one line in `claude/settings.json`: the `powershell.exe ... pre-tool-use-hook.ps1` entry becomes the
   `gate.exe pre-tool-use` entry. Keep the ps1 in the repo. Rollback is the same one-line revert.
2. Staleness guard in `session-bootstrap.ps1` (SessionStart): if `gate.exe` is missing, or any `gate/*.go` is newer
   than it, print a loud warning at session start. A missing exe fails open. This check only detects that at
   session start. It does not stop the tool calls that run before someone acts on the warning.
3. Changelog entry in `claude/tuning-changelog.md`.
4. One week of real use. Compare `Get-HookReport.ps1` block counts by rule against the week before. A rule whose
   count drops to zero is a port bug until shown otherwise.

### Phase 4: retire the ps1

1. Delete `pre-tool-use-hook.ps1` and `no-compound-cd.ps1`. The suite targets the exe only.
2. Update `claude/README.md` and the AGENTS.md hook bullet. "Edit the ps1, it is live on save" becomes "edit the Go,
   run build.ps1".

## Out of scope here

- The other pwsh hooks. Per user prompt, three pwsh processes start (`set-session-state`, `filler-guard`,
  `snapshot-layout`), plus `set-session-state` and `set-tab-title` on Notification and `log-subagent` on subagents.
  The state and title hooks go to atrium under H14. `filler-guard`, `snapshot-layout` and `log-subagent` can become
  `gate.exe` subcommands later, once the exe exists. Not in this change.
- Rule changes. Any new or changed rule waits until Phase 3 is done, so a parity diff always means a port bug.

## Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| `gate.exe` missing or not built on a fresh box | Gate fails open, every rule is off | SessionStart warning, `build.ps1` in the setup docs, Phase 3 step 2 |
| Regex translation drift (case, lookaround, Unicode) | A rule silently allows | Phase 0 coverage, reason-text asserts, 30-day differential replay |
| Rebuild while sessions run the exe | `go build` cannot overwrite a running exe | `build.ps1` builds to `gate.new.exe`, renames the old exe aside, renames the new one in, deletes the old one on the next build |
| Edits no longer live on save | A rule fix needs a build step | `build.ps1` is one command. The staleness warning catches a forgotten build |
| Defender scans a new unsigned exe | First call after a build is slow | Measure once. If it matters, add a Defender path exclusion for the build dir (clint decides) |
| Two sources of truth during Phases 1 to 3 | A ps1 fix not ported | Rule freeze from Phase 1 until Phase 4 |

## Effort

About 700 lines of Go and 150 lines of new test cases. Phase 0 and Phase 1 are each a session. Phase 2 is half a
session. Phase 3 is a week of passive use.

## Open questions for clint

1. Does the gate fail closed on an internal error (proposed), or open like a missing exe?
2. Does H14 keep the state and title hooks, or does `gate.exe` take every pwsh hook later?
