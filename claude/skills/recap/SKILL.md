---
name: recap
description: >
  Write a session recap (archeology / after-action) for the CURRENT claude-code session into the history
  root. Captures what we set out to do, what shipped, what got parked, the FALSE FINISHES (every time
  claude said "done" and it reopened), the friction, and the timing. Invoke when the user says "recap",
  "/recap", "write up the history", "capture the archeology", "session recap", or asks for a
  "you thought this was done" writeup on the way out. Writes a markdown file and prints a short reminder
  line. It does not commit anything.
---

# recap

Write an after-action recap of the current session. The star of the recap is the **False finishes**: the
moments claude declared the work done or fixed and the user had to reopen it. Those carry the most signal,
so mine them carefully and lead the reader to them.

## Where it goes

- History root: `D:\worktrees\history\` (create it if missing). Single flat root, not per-repo.
- Filename: `<repo>-<branch>-<YYYY-MM-DD-HHmm>.md`.
  - `<repo>`/`<branch>` come from the cwd git context. If cwd is the dotfiles tangent (no feature branch),
    use `dotfiles-<topic>` where `<topic>` is a two-or-three-word slug of the session's main thread.
  - Timestamp from `Get-Date -Format 'yyyy-MM-dd-HHmm'`.
  - If the session had one or more false finishes, append `--REOPENED` before `.md`
    (e.g. `ziti-tunnel-sdk-c-refactor-needs-mfa-2026-08-19-1503--REOPENED.md`). This makes the messy
    sessions spottable in the history dir at a glance.

## Check for an existing recap FIRST

Before writing anything, look for a recap this session already has, and UPDATE it instead of writing a duplicate:

1. The session ledger is the primary signal. `gwt sessions` stamps `RecapPath` on the entry for this worktree
   when a recap was written (via `stamp-recap.ps1`). Read the ledger entry for the current worktree
   (`$env:WORKTREE_ROOT\sessions\*.json`, match `WorktreePath` to cwd); if it has a `RecapPath` and that file
   exists, that is the recap to update.
2. Fallback if no stamp: glob `D:\worktrees\history\<repo>-<branch>-*.md` (include the `--REOPENED` variants). A
   match for this same repo/branch is almost certainly this session's recap.
3. If one is found, UPDATE it in place: keep its original filename and timestamp, refresh the sections that changed,
   add any new false finishes, and re-run the stamp/artifact steps. Do NOT write a second file with a new timestamp.
4. Only when nothing matches do you create a new recap.

## Gathering the material

1. **Prefer your own context.** You lived the session, so you already know the thread, the false finishes,
   and the friction. Write from memory first.
2. **Read the transcript for timing and for anything compacted away.** The current session transcript is
   the newest `*.jsonl` under `C:\Users\claude\.claude\projects\<cwd-slug>\`, where `<cwd-slug>` is the
   cwd with `:` and `\` and `/` collapsed to `-` (this repo's is `D--git-github-dovholuknf-dotfiles`).
   Glob the newest file there. Use the first and last event timestamps for elapsed wall-clock. If context
   was summarized this session, scan the transcript so the recap covers the whole session, not just the
   tail you remember.
3. Do not block on the transcript. If you cannot resolve it, write the recap from context and say timing
   is approximate.

## What to write

Plain markdown, wrapped at 120 chars, the user's prose rules (no em-dash, no `--` dash, no semicolon in
prose). Sections, in this order:

- **Header**: repo, branch, date, elapsed wall-clock, rough active-turn count. One line each.
- **Set out to do**: the goal(s) as they stood at the start, in one or two sentences.
- **Shipped**: what actually got done and verified, each with the concrete artifact (file, function,
  command). Mark each as verified-by-running or not.
- **Parked / didn't do**: what was raised and deliberately left, and why. Include standing offers the user
  declined or deferred.
- **False finishes** (the point of this document): every time you said done / fixed / verified and it
  reopened. For each, one row:
  - what you claimed was done,
  - what actually broke it (the real cause),
  - how many turns until it truly closed.
  If there were none, say so in one line ("No false finishes this session.") and drop `--REOPENED` from
  the filename.
- **Friction**: what went well and what went badly, honestly. Name the bad beats (wrong assumption,
  premature victory, re-asking a settled thing, prose the user had to cut). This is for the user to see
  patterns, so do not soften it.
- **Follow-ups**: concrete next actions and any git/gh commands still owed to the user (state them, do not
  run them).

## Length and voice

- Match the session's weight. A 20-minute session gets a tight half-page. A multi-hour slog gets more.
- Report faithfully. Failing tests get named, skipped steps get named, "done" means verified done.
- No hype, no marketing adjectives, no wrap-up cheerleading.

## Capturing debug artifacts

A recap is the point where a worktree becomes safe to prune, so anything the session made that is worth
keeping has to leave the worktree WITH the recap. After writing the markdown, sweep the session's debug
artifacts into a sibling folder next to the recap:

- Destination: `D:\worktrees\history\<same-stem>-artifacts\`, where `<same-stem>` is the recap filename
  without `.md` (and without `--REOPENED`). Create it only if there is something to put in it.
- What to collect: files this session created for its own debugging, not the repo's own output. The
  session scratchpad (the temp `...\scratchpad` dir named in the environment preamble) is the main source:
  any timing scripts, parse-check scripts, dumps, captured logs, sample outputs. Also copy any debug file
  the session deliberately wrote elsewhere that you remember making (a crash dump you pulled, a log you
  saved, a repro script).
- Copy, do not move, and never reach into the repo tree or delete anything. If the scratchpad is empty and
  the session made no artifacts, skip this step and say so.
- In the recap's Follow-ups (or a one-line note at the end), name the artifacts folder and what is in it,
  so a later reader knows the debug trail was preserved.

## After writing

- Stamp the gwt session ledger so `gwt sessions` shows this folder as recapped (a `+r` marker) and
  `gwt prune -Recapped` can target it. Run, from the worktree:
  `stamp-recap.ps1 -RecapPath '<full path to the recap .md>'`
  (it is on PATH; it defaults the worktree to the current directory and no-ops cleanly if this worktree
  was never gwt-spawned). Do this even when there were no artifacts to capture.
- Print the path you wrote, then one reminder line, e.g.
  `recap written: <path> (N false finishes) -- you thought this shit was done.`
  If artifacts were captured, add `artifacts: <folder> (K files)`.
- If nothing of substance happened this session, say so and skip the file rather than writing an empty
  recap.
- Never commit. If the history root should be tracked, that is the user's call to make.
