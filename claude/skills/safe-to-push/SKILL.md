---
name: safe-to-push
description: >
  Pre-push gate: inspect the changes you are about to push (commits not yet on the upstream, plus staged and
  untracked files) for anything that should not leave the machine. Runs the pii-scan secret+PII pass as one layer,
  then checks for merge-conflict markers, WIP / DO-NOT-COMMIT / debug leftovers, machine-specific absolute paths,
  stray artifacts / large or binary files, sensitive files (.env, keys, .ziti, .jwt, support bundles), and an
  unexpectedly large diff. Returns a SAFE / HOLD verdict with findings. Invoke with /safe-to-push, or when the user
  says "safe to push?", "check before I push", "pre-push check". Read-only: it surfaces remediation, never runs a
  git mutation and never uploads anything.
---

# safe-to-push

Answer one question: is what I am about to push safe to push? Detection and a verdict. It never pushes, never runs a
git mutation, and never sends the diff or the findings anywhere.

## Target (what "about to push" means)

Scan, in order:
1. Commits not yet on the upstream: `git diff @{upstream}...HEAD` (or `git diff origin/<branch>...HEAD` when no
   upstream is set). These are what actually land on the remote.
2. Staged changes: `git diff --cached` (the user often runs this before committing).
3. Untracked files: `git status --porcelain` -- flag any that look sensitive or artifact-like (see below).

Focus the line-based checks on ADDED lines (the `+` side of the diff), not context. If the user names a target (a
range, a path), use that instead.

## Layers

Report blockers first, then warnings.

### 1. Secrets and PII  (BLOCKER)

Apply the `pii-scan` skill's detection to the added lines: private keys, JWTs / enrollment tokens, `.ziti`/`.jwt`
content, token shapes (`github_pat_`, `ghp_`, `AKIA...`, `xox...`, `ATATT`, `sk-...`, `AIza...`), `password=` /
`secret=` / `token=` / `Authorization: Bearer` assignments, and customer PII (emails, public IPs, hostnames, names).
Mask every match. Do not restate pii-scan's whole pattern list here; run that skill's pass over the diff.

### 2. Merge-conflict markers  (BLOCKER)

Added lines matching `^(<<<<<<<|=======|>>>>>>>)` -- an unfinished merge is being committed.

### 3. WIP / debug leftovers  (WARNING)

- Markers: `(?i)\b(DO ?NOT ?COMMIT|DNC|WIP|FIXME|XXX|HACK)\b`.
- Debug prints left in: `console\.log`, `Write-Host .*(DEBUG|dbg)`, stray `fmt\.Print`, `debugger;`, `Set-PSDebug`,
  `print(` in non-test code. Some are project-normal; flag for review, do not treat as certain.

### 4. Machine-specific absolute paths  (WARNING)

Paths that break on another machine: `[A-Za-z]:\\Users\\`, hardcoded `C:\\Users\\clint`, `D:\\git\\...`,
`/home/<user>/`, absolute home dirs. Distinguish a hardcoded literal (bad) from an illustrative comment or a
`$env:`/`$HOME`-based path (fine).

### 5. Stray artifacts / large or binary files  (BLOCKER for secrets-bearing, else WARNING)

From `git diff --cached --name-only` and the unpushed set, flag `*.exe`, `*.dll`, `*.dmp`, `*.zip`, `*.pdf`,
`build.claude/`, `node_modules/`, `dist/`, `*.log`, and any file over ~1 MB or detected as binary.

### 6. Sensitive files staged  (BLOCKER)

Filenames that should almost never be pushed: `.env`, `.env.*`, `*.pem`, `*.key`, `*.pfx`, `*.p12`, `id_rsa`,
`*.ziti`, `*.jwt`, `*credential*`, `*secret*`, and support-bundle zips (ZDEW feedback, ziti-edge-tunnel logs).

### 7. Unexpectedly large diff  (WARNING)

A file count or added-line count well beyond the task, or vendored/generated files sneaking in
(`vendor/`, `package-lock.json`, a huge `go.sum`). Point it out so a wrong `git add -A` gets caught.

## Report

- One-line verdict: `SAFE to push` or `HOLD: N blockers, M warnings`.
- Then findings, blockers first, each: layer, `file:line` (or filename for file-based), a terse description, and a
  MASKED snippet for any secret. Never print an unmasked secret.
- End with the remediation the user runs themselves (unstage a file, delete an artifact, `/pii-scan ... redact` to
  scrub, `git rm --cached`). Surface the command; do NOT run any git mutation.

## Safety

- Read-only. Never push, never `git add`/`commit`/`rm`, never upload the diff or findings.
- When in doubt on a blocker vs warning, call it a blocker and let the user decide.
