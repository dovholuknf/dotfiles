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

## After writing

- Print the path you wrote, then one reminder line, e.g.
  `recap written: <path> (N false finishes) -- you thought this shit was done.`
- If nothing of substance happened this session, say so and skip the file rather than writing an empty
  recap.
- Never commit. If the history root should be tracked, that is the user's call to make.
