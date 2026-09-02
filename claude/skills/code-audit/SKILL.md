---
name: code-audit
description: >
  Audit the code comments in the current diff against agents/comments.md and DELETE the ones that do not earn their
  place. For each comment authored or changed in the diff, ask whether the adjacent code already shows it, and delete
  rather than reword when it does. Invoke with /code-audit, or when the user says "audit the comments", "check my
  comments", "clean these comments". Meant to run right before a diff is shown. It removes and tightens comments only.
  It never changes behavior and never adds a comment that was not already there.
---

# code-audit

Gate the comments in the current diff. The verdict is DELETE, not reword. This skill exists because the comment test
gets applied when a comment is first written and never again, so every later edit smuggles in comments nobody
re-checked. `/as-tech-story` is the wrong tool for those: it rewords a worthless comment into a better-worded
worthless comment. Here the default is to cut.

## Source of truth

`agents/comments.md` owns the rules. Read it at invoke time and apply it as written. Do NOT hardcode a copy of its
test here: it drifts, and drift in a comment skill is its own punchline. If that file has moved, find it
(`**/comments.md`) before proceeding. Everything below is how to APPLY it to a diff, not a replacement for it.

## Scope

- Only comments **authored or modified in the current diff**. Get the diff (`git diff`, plus staged and unpushed
  changes as relevant). A comment in an untouched region is out of scope even if it is bad.
- Never touch license or copyright headers.
- Never touch a comment to change behavior. This pass moves and deletes text, nothing else.

## The pass

For each in-scope comment, apply `agents/comments.md`'s test in order. Its first question is the gate:

1. **Can the reader see this from the code itself?** If yes, DELETE. A comment sitting directly above a single
   function call is nearly always restating the call: treat proximity to a one-line statement as strong evidence to
   delete. If the comment's content appears in the callee's name, that is conclusive (`installed_app_version()` makes
   a two-line comment about "the installed version" redundant): delete, or rename the identifier if the name is the
   weak link.
2. **Is it a note about the change rather than the code?** Changelog prose, "we used to", "this is better than",
   development-journey narration, an example pulled from the session: DELETE. A file describes its current state, not
   its history. That sentence is a commit message.
3. **Only if it survives both**, check its wording against the rest of `comments.md`: no call-flow or test narration,
   no first person, no cross-reference that can drift, no em-dash, no `--` as a dash, no semicolon in prose, one line
   where it fits. Tighten in place.

## The bias

Default to delete. Rewording is the trap this skill closes. If a comment needs a paragraph of justification to
survive, it does not survive.

The comments that DO survive most often explain a **non-obvious external contract**, the thing the code cannot show:
an include-ordering constraint a tidy-up would silently break, a registry key or file an external installer writes,
the meaning of an out-parameter only clear at the call site, why a buffer is cleared on entry, why a lookup is
attempted twice, a gotcha or landmine, a stable pointer (issue, URL, spec section). When you keep one, the report has
to name which of these it is.

## After the pass

Comment deletion is inert by construction, so do not force a rebuild. If a build or test run is already cheap or in
flight, let it confirm nothing broke. Otherwise say so and move on. Do not kick off a slow compile just to prove that
removing a comment removed a comment.

## Report

A table, deletions first because they are the point. Columns: `file:line`, the comment (trimmed), verdict
(`deleted` / `tightened` / `kept`). For `tightened`, show the new text. For `kept`, name the external contract it
carries. End with the one-line count: `N comments audited: X deleted, Y tightened, Z kept`.
