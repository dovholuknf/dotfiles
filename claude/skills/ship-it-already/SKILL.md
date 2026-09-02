---
name: ship-it-already
description: >
  The one-shot pre-push checklist. Run this when you are about to push and want everything handled: it cleans the
  comments in the diff (code-audit), then gates the changes for secrets, PII, and junk (safe-to-push), then hands you
  the exact push command. Invoke with /ship-it-already, or when the user says "ok I'm pushing now", "do the needful",
  "ship it", "get this ready to push". It orchestrates the other skills, so keep them as the reusable pieces. It edits
  comments, surfaces a verdict, and never runs a git mutation itself.
---

# ship-it-already

The "I'm pushing now, do all the needful" button. It chains the existing skills in order so one invocation covers the
whole pre-push checklist. This is the moment a mutating pass is wanted, so unlike a bare pre-push gate it is allowed
to edit the tree (comments only).

Do NOT reimplement the sub-skills here. Invoke each one via the Skill tool and let it own its own rules. This file is
only the order, the hand-off between them, and the final report.

## The chain

1. **code-audit** (mutating). Clean the comments in the current diff. It deletes the ones the code already shows and
   tightens the survivors. Show its table.
2. **safe-to-push** (read-only). Gate the now-cleaned changes for secrets, PII, merge markers, debug leftovers,
   machine-specific paths, stray artifacts, and sensitive files. It returns SAFE or HOLD.
3. **pr-review** is NOT in the default chain. Run it only when the user asks ("...and review it", "full check").
   It is the heavy correctness pass and most pushes do not want to wait on it.

Order matters: audit first so safe-to-push gates the code that will actually ship, not a pre-clean version.

## Verdict

Combine the two into one line up top:

- **HOLD** if safe-to-push held. List what blocked it. Do not show a push command. A HOLD is the whole point of
  running this, so lead with it and stop.
- **READY** if safe-to-push came back SAFE. Then, and only then, surface the exact command for the user to run. Never
  push, commit, or otherwise mutate git yourself: print the command and let them run it.

```
git push <remote> <branch>
```

Fill in the real remote and branch from the repo state. If commits are not yet made, say so rather than guessing a
commit command.

## Report shape

1. One-line verdict: `READY` or `HOLD`.
2. code-audit result: `X comments deleted, Y tightened, Z kept` (the table already printed above).
3. safe-to-push result: SAFE, or the HOLD findings.
4. If READY: the push command, alone, for the user to run.
