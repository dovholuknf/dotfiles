# Gate decisions

Why each `pre-tool-use-hook.ps1` rule exists, why some were removed, and the evidence behind each call. Newest first.
Add an entry whenever a rule is added, removed, loosened or tightened, or when a rule is evaluated and kept as is.

Each entry records the decision, the why, the evidence (block counts, sampled commands, tests), and its status. Block
counts come from `tests/hook-blocks.ps1`, which reads the blocks back out of the claude-code transcripts. Rerun it to
check a claim.

`claude/tuning-changelog.md` stays the one-line feed of behavior changes. This file holds the reasoning.

## What the gate is for

claude runs as its own Windows account. The rules that matter against a prompt-injected session are the ones that stop
code or secrets from leaving the machine, and the ones that keep claude off clint's branches:

- remote git ops are refused, except `git push`/`git fetch` to this room's atrium hub forwarder
- `gh api` is GET-only
- claude creates, deletes and renames only `claude/*` branches, and commits only on them
- no git aliases (an alias can hide a blocked verb)

The rest are style or tidiness rules. A style rule earns its place only if the retries it causes cost less than the
mess it prevents.

## 2026-10-10: drive-root guard kept for now, account hardening to be evaluated

**Decision.** Keep the guard unchanged. Evaluate whether account ACLs can replace it.

**Why.** clint would rather harden the account so claude cannot create folders at a drive root at all, and drop the
guard. The ACLs do not do that today.

**Evidence.**
- 28 blocks in 7 days. False positives seen: `ls /d/no-such-dir` (a read), and `/w/in.txt` inside a container mounted
  with `-v D:\x:/w`, read as `W:\in.txt`.
- `icacls D:\` grants `NT AUTHORITY\Authenticated Users:(M)` on the root and `(OI)(CI)(IO)(M)` inherited. Any account,
  claude included, can create folders at `D:\` and modify whatever inherits from it.
- `icacls C:\` grants Authenticated Users `(AD)` (create folders) on the root.

**Status.** Open.

## 2026-10-10: branch-name parser to be explored

**Decision.** None yet.

**Evidence.** 109 blocks in 7 days. Sampled 25, found no violations. The parser takes every token after `git branch`
to the end of the command, across `&&`, `;` and newlines. That blocks `git branch claude/a x && git branch claude/b x`,
read-only queries (`git branch -a --contains <sha>`, `git branch --list ... -v`, `git branch -r`), a valid
`git branch -d claude/x` after a `Set-Location` on the line before, and a `sed` whose text holds `git branch -D`.

**Status.** Open.

## 2026-10-10: `;` and `>` rules removed

**Decision.** Removed the Bash-only rules that blocked `;` chaining and `>`/`>>` redirection.

**Why.** Neither one protected anything. `&&` and newlines chain commands, and `tee` writes files. Both passed the
gate, so the rules only cost a retry each time. The git and remote rules read the whole command text, so a `;` cannot
hide a push or a commit. Tests cover that.

**Evidence.**
- 7-day report: 814 `;` blocks and 340 `>` blocks out of about 2,000 total, the two largest rules.
- Sampled 30 `;` blocks: read-only chains (`cat a; grep b; ls c`), `;` inside `for` loops, awk and sed scripts, and
  `ssh '...'` strings. None was dangerous.
- Sampled 25 `>` blocks: false positives on `2>/dev/null`, `grep '->message'` and a `>>>>>>>` conflict-marker regex,
  plus heredoc writes (`cat > file <<'EOF'`) that `tee` would have done.
- Drive-root writes are still caught by the drive-root guard.
- `tests/test-gate.ps1` updated: `;` and `>` cases now expect allow, plus new cases where a `;` sits next to a push, a
  commit on a non-`claude/*` branch, and a hub push followed by an origin push. All three still block. 316/316 pass
  under pwsh 7 and Windows PowerShell 5.1.

**Status.** Done.
