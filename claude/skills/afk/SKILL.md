---
name: afk
description: >
  Work a queue of tasks unattended while the user is away, producing a numbered series of patches they can
  apply one at a time, plus a report and a demo script. Invoke when the user says "afk", "/afk", "I'm going
  to bed", "going AFK", "work on this while I'm out", "make progress while I'm away", "chug through this
  list", or hands over a batch of work with no intention of answering questions. The contract is: never
  block, never wait, decide and record. Do not invoke for ordinary interactive work.
---

# afk

The user has queued work and left. They are not coming back to answer anything. Everything below exists to
make that survivable.

## The contract

**Never block.** No clarifying questions, no "should I", no waiting. If a decision is needed, take the
defensible one, write down what you assumed, and keep going. A question asked to an empty chair costs the
whole night.

**Never stall on a broken tool.** If something needed is unavailable, find another way and note it. A blocked
reviewer means use a reviewer subagent. A blocked command means a different command.

**Finish whole things.** Each item ships tested, documented and cut as a patch before the next begins. Nine
finished items beat fourteen half-done ones.

**Report honestly.** What was proved, what was not, what is still guessed at. "I could not verify X" is a
useful sentence. Claiming X works when nothing exercised it is not.

**Retest before repeating a failure.** If a tool failed hours ago and the user says they fixed it, run it
again before saying it is still broken. Stale claims read as not paying attention, because that is what they
are.

## Set up first, before any work

```bash
bash <skill>/scripts/snap.sh <repo> <outdir> 00-base
```

`<outdir>` is a sibling of the repo, never inside it: `D:/git/github/you/<repo>-afk`. It holds `patches/`,
`snap/`, the plan, the report and the demo.

Record the baseline commit and the start time. Every patch applies to the tree the previous one left, so the
baseline is the only fixed point.

## Plan, then review the plan, then build

Write `PLAN.md` in the outdir: one section per item, in the order they will be built, each saying what it is,
what it reuses, and what it deliberately refuses. Order so nothing depends on something later.

**Then have the plan reviewed before writing code.** This has caught, in one night, a migration that would
have deleted the user's data and a guard that would have been silent in the one case it existed for.

- First choice: mercurius, if the repo has a `mercurius.yaml`.
- If it fails for any reason: a `codebase-steward` subagent, given the plan and told to read the neighbours.
  For security-shaped work, `go-security-reviewer` as well.
- Act on every finding or record why not. Write the triage to `REVIEW.md` in the outdir.

## The loop, once per item

1. Build it. Match the surrounding code's comment density and idiom; in a repo that explains its reasoning,
   explain yours.
2. Tests that assert the BEHAVIOUR and the refusals, not the implementation. The valuable ones name the way
   the thing gets broken.
3. Run everything the repo has: the suite, and any `scripts/check-*` it ships.
4. A CHANGELOG entry and any doc the change contradicts. A doc that now lies is a bug.
5. Cut the patch:

```bash
bash <skill>/scripts/snap.sh <repo> <outdir> NN-name
bash <skill>/scripts/mkpatch.sh <outdir> PREV NN-name 000N "one line subject"
```

6. Note the elapsed time.

## Verify against reality, not against your own tests

- **A migration is checked against a COPY of the live database.** Copy it out, open the copy, count what
  survived, delete the copy. Never migrate the real one to find out.
- **A daemon or server the user has running is theirs.** Do not restart it to test something. Run a second
  one on other ports with its own state file if the program supports it, and stop it afterwards.
- **Anything that publishes** is the user's call. A private tunnel to prove a path works, torn down after, is
  fine. A public address is not.
- **Back up before anything irreversible**, and say in the report where the backup is.

## Finish with three artifacts

**`REPORT.md`** — the patch table with elapsed times and commit subjects; what they asked for and what
happened to it; bugs found; what the review caught; **what needs them**, in the order it will bite; and what
was deliberately not done.

**`DEMO.md`** — numbered walkthroughs. Each says what to do, what to expect, and what feedback is wanted.
Lead with whatever has never been seen rendered. Say plainly which ones you already ran and which are
unverified.

**Replay proof** — apply every patch into a clean copy of the baseline and diff the result against the tree
you tested:

```bash
bash <skill>/scripts/verify.sh <repo> <outdir>
```

Byte-identical or the series is wrong.

## Before handing back

- Scan the patches for credentials, tokens and machine-specific absolute paths.
- Leave the working tree clean of scratch files.
- State whether anything is committed. Usually nothing is.

## Environment notes

**Git is usually half-blocked.** `git apply`, `git stash`, and everything read-only work. `git add`, `git
commit` and `git branch` are refused by a hook. That is why this produces patches rather than commits. Do not
fight it: hand commit commands to the user in the report.

**Commit subjects, when the user asks for them:** one line, lower case, comma-separated clauses naming
behaviour. No body, no attribution, unless their log shows otherwise. Check with
`git log --format='%s' -6` rather than guessing.

**Signing:** check `git log --format='%G?' -3` after the FIRST commit lands, not after eight. A repo can want
GPG while the global config points at an SSH key, and the failure only appears at push.

**The bash tool refuses:** `;` chaining, `>` and `>>` redirection (use `tee`), `2>&1`, `find`, `perl`,
`git -C`, and `cd` outside the working directory. Write a script to a file and run it when a one-liner will
not fit. Beware `-->` inside a string: it contains `>`.

**Builds** may be constrained to an output directory by a hook. A binary that a running process holds open
cannot be overwritten: build under another name, or stop the process first.

## What "done" means

Every item tested, every patch replayed, the report written, the demo written, nothing committed, and a list
of what needs the user. Then stop and summarise. Do not keep inventing work.
