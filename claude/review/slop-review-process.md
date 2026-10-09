# self/slop-review: the process

> **Trial status.** This process is in its second trial run and may change. Do not build a skill, a gate or a
> linter from it yet. Rules and R-numbers can still move.

Written 2026-10-09 from the first trial run: a C SDK pull request that added a Windows crypto backend for e2ee-tls
under FIPS. The operator and Claude ran this loop over two days to strip AI slop from the PR before the maintainer
saw it again. The second trial run, the same feature on a Go SDK pull request, refined it the same day. This file
is the process as it ended up working. The raw history, the operator's reactions and the numbered requirements
(R1-R50) are in `slop-review-retro.md` next to this file. Rule numbers below point there.

Goal: every AI-authored diff goes through this loop before a human reviewer or a maintainer sees it. The mechanical
parts get automated. The human only sees judgment calls, one at a time.

## Why it exists

- The PR went up with code Claude wrote and the operator reviewed. The maintainer caught slop the operator missed:
  three FIPS helpers where one was needed ("do you need all 3?"), and a FIPS restriction added to three unrelated
  source files ("why do we do it here?", "ditto").
- Root cause: one e2ee failure (2 of 72 matrix runs). Claude applied the fix to every TLS context "to be safe".
  Only e2ee needed it. The operator had to defend code that should never have existed.
- Lesson: a human misses slop in a large AI diff. The AI has to review its own diff against the PR base first, and
  present it in a form the human can judge.

## When to run it

- Before any AI-authored diff goes to a human for review, and again before it goes to a maintainer.
- After a maintainer review lands, to sweep for the same class of problem across the whole PR.
- The operator calls it a "self/slop-review" (R24).

## Phase 1: establish the base

- Diff against the PR base (merge-base with main), never against HEAD or the working tree. A change that looks like
  "just moving code" against the working tree can show its real cost or saving against the base (R35).
- Every line changed against main has a cost. Rewording, recasing and restructuring untouched code all add to it
  (Lesson 2, R9).

## Phase 2: find candidates

Walk the whole diff against the base. Tag every candidate with a category (R15):

| Category | What it looks for |
|---|---|
| SCOPE | a fix spread to paths that never failed. Each touched call site needs the failing test or run that proves it |
| DEAD | unused helpers, params, branches, includes |
| DRY | duplicated blocks, a helper that already exists nearby, the same comment in several places |
| CHURN | lines changed against main with no correctness or hygiene value: rewording, recasing, reordering by hand, whitespace. Restoring main's text is CHURN (COMMENT + CHURN for a comment) |
| HYGIENE | single-user helpers or fixtures in a shared header (R24, R32), `static` mixed with an anon namespace |
| TEST SCOPE | tests that exercise a dependency instead of the project's own code, tests in new files when the project keeps one test file per area (R43), copied production logic |
| COMMENT | comments that restate code, repeat a nearby log line (R8), or cross-reference other code |
| SIMPLIFY | code that can be shorter AND simpler |

Rules while finding:

- Rank code shapes: DRY and simple > more lines but simple > DRY but dense (R16). A DRY fix that reads worse is not
  a win.
- "Fewer lines" is not the goal by itself. Every change needs a stated reason, and the line count against the base
  must be measured, never guessed (R10, R14).
- Churn never outranks correctness. Include-what-you-use stays even if a transitive include works (R36).
- Churn from a formatter (gofmt realigning a literal) or from putting code where it belongs is not a finding (R49).
- Follow the project's established paradigms. Scan for markdown guides on code and test changes first. With no
  guide, a code-alignment question is not a question: inspect the code on main, isolate the pattern, and follow it
  (R43).
- A finding that adds a helper states what it searched for and why the existing candidates do not fit. Scan before
  proposing, not after (R47).
- A fix to a bug that also exists in main can stay. Say so (S4, S7 below).
- Do not narrow a general-purpose helper to fit its current callers (R28).
- Explain the mechanism before proposing a removal. If the human does not know what a construct is for, they cannot
  judge it (R23).

## Phase 3: triage

- No-brainers (an exact duplicate removed, no behavior change, fewer lines) get applied and listed in one batch
  summary for a glance or veto. The operator: "i shouldn't even have to see that" (R21).
- Code that an approved change leaves with no callers goes with a one-line FYI ("removing xyz, no more callers"),
  with no diff page or approval of its own (R42).
- Everything else is a judgment call and goes through Phase 4, one at a time.
- Order: code changes first. Edits to EXISTING comments come after the code they depend on, as their own item. A
  net-new comment that comes with new code may sit in the same diff (R27).
- When a finding adds a helper, show the helper before its callers (R37).
- Header priority when deciding what to touch: public API headers > internal headers > `.c` (R35).

## Phase 4: present, one site per message

One change site per message. Then stop and wait. Never batch findings (R5, R11, R37). A finding that touches two
files is two messages.

Every message fits a 40-row screen, about 35 lines (R38). If it cannot, open it with a plain-text
`=== SCROLL BACK TO HERE ===` line. Page a big diff across messages, with one approval after the last page. Do not
split one deletion into many separately compiling steps.

For a large or unfamiliar change, explain the mechanism first (background, why the code exists, what it does, why it
is out of scope), then page the diff (R50). Show a verbatim move as the list of moved names plus the import changes,
after a script confirms the cut and pasted text are identical (R46).

Message layout, top to bottom (R18, R20):

1. the full unified diff in a ```diff block, every line, no `...` elisions (R29). Generate it from a patched copy
   with `git diff --no-index` so it is the real diff. Add a second view against the PR base only when the first
   view hides the point (R35, R37).
2. any trade-off, side edit or "net new vs base" note in one or two plain lines (R22, R26, R30).
3. the footer, last, right above the prompt:

```
CHANGE DRY  : ctx_guard and e2ee_guard are each defined twice
SUMMARY     : Keep one copy only. Apply?
```

Footer rules (R19, R20, R39):

- The fenced footer ends every message and every page. A plain-prose summary does not count. A page that is not the
  last one asks "Next?" in its SUMMARY line.
- No finding IDs, no line counts the human can see in the diff, no extra prose.
- The question folds into the SUMMARY line. No separate "Apply?" row.
- Say the kind of change up front: code, comment-only, test (R12).
- Name every side edit. A comment reworded because a param was dropped is a separate change and must be called out
  (R26).

Judgment questions use the same shape, with the code shown above (R33):

```
SUMMARY HYGIENE : .h pollution - tls_with_ca is defined in a .h but only has one callsite
QUESTION        : is it possibly useful to other tests to be able to make a tls context with a provided ca?
```

- One question per message. Do not answer it for the human in a bullet list.
- Always show the code the question is about: "it's not quite enough unless i can see what i am answering".

Proposed code must be exactly what goes in the file. No annotations like `// main's line, unchanged` inside the
snippet. Notes go in the prose (R7).

## Phase 5: decisions

- "yes" approves only the last thing shown (R27).
- A blanket "apply the rest" covers only the exact kind just approved. When the scope is unclear, ask. Never widen
  it (R25).
- An answered question is the approval. If the answer settles the action, apply it and show the diff as done. Do
  not ask "Apply?" again (R34).
- Approved but criticized ("that comment fits... even though the comment itself is s***"): do not apply. Iterate on
  the weak part first, then apply the finished version once (R31).
- A conditional approval ("seems like a good idea but also scan") is not a plain yes. Once the condition is met,
  say so and say the change was applied, in the same message (R48).
- If Claude cannot tell whether something is "potentially useful in the future", it asks and does not decide (R32).
- Answer "why" in one sentence first, then offer detail. Fewer words win while the content is carried (R45).
- Withdrawn findings stay recorded with the reason (S2 below).

## Lead and worker (optional)

From the second trial run (R40, R41). A worker session drafts each finding into a queue dir
(`./build.claude/slop/queue/NN-<slug>/`) and applies it when the lead says "apply NN". The lead checks each draft
and presents it to the human through Phases 4 and 5.

- The lead owns the review-process rules. Do not relay them to the worker. The human wants to see the lead apply
  them.
- The worker sends one report per instruction. No acks, no unprompted status.
- Tell the human before ending a worker they can see.
- Keep scratch copies in a `_`-prefixed dir (`build.claude/_slop`) so tools such as `go list ./...` skip them.

## Phase 6: verify

- Build only through the repo's sanctioned build script.
- Run the full suite after library changes: unit and integration, in every build tree the PR affects. Never report
  unit-only.
- Run the cross-platform matrix when the change touches crypto, TLS or platform code. Classify every failure:
  expected by design, environment/infra, test-peer flake, or PR code. Fill every gap (ssh timeouts etc.) with a
  rerun or point to an earlier run that used the same binaries.
- Provenance: every binary in the test bundle must be traceable to a commit. In the first trial run the bundle
  recorded the SDK and its TLS library but not the Go test peer. That peer turned out to be built before every
  commit on its branch tip. Record every peer's commit and dirty state, and fail the run when a binary is older
  than its source.

## Phase 7: hand back

- The human commits and pushes. Claude never does.
- Commit messages: one `git commit -m` line, one behavior, no comma-joined lists (Lesson 6).
- Replies to the maintainer need the context they lack: what failed, in which test, what the code tried, that it
  was wrong, and what replaced it. Never "removed, the failure was X only" (Lesson 4, and `agents/code-review.md`
  in the agents pack).
- Append the human's reactions, verbatim, to the retro file while the loop runs. That is the requirement source for
  the tooling.

## Worked example: the source pass of the first trial run (S1-S8)

All eight landed in one cleanup commit.

| Site | Category | Outcome |
|---|---|---|
| S1 `new_tls_e2ee` | CHURN + correctness | applied: keep main's line order, add calloc NULL check, guard the server engine, one fail block |
| S2 `#include <string.h>` in e2ee_tls.c | CHURN | withdrawn: include-what-you-use is correct, churn does not outrank it (R36) |
| S3 | (merged into S1) | |
| S4 multipart branch counts down_rate/received | bug in main | kept, no comment needed |
| S5 `conn_inbound_data_msg` failure blocks | CHURN + DRY | applied: main's two blocks restored, each calls new helper `e2ee_failed()`. Shown as two messages, helper first (R37) |
| S6 tls version log line | CHURN | applied: main's line restored, no backend returns NULL from `version()` |
| S7 controller init failure path | bug in main | kept: closing the controller + `free_tls_contexts` fixes a leak |
| S8 bind.c `process_dial` | CHURN | applied: main's comment and `create_e2ee(opts.e2ee_mode, ...)` line restored |

Earlier passes in the same PR (T1-T8, L1-L5) covered tests and helpers. They produced R5-R35. After T6 the operator
said "this process is really working well now... i'm enjoying this" (R30).

## What tooling would need

In priority order. None of this exists yet, and none of it gets built until the trial runs settle the process.

1. **Slop gate** (a skill or an atrium step). Diffs against the PR base, runs Phase 2, applies the no-brainers,
   and pages the rest through Phase 4.
2. **Diff budget.** Lists every line changed against main that is comment-only, case-only, whitespace-only or
   reworded without a behavior change, so each one is a deliberate keep.
3. **Scope check.** For each call site a fix touches, require the failing test or run that proves the site needed
   it.
4. **Slop linter.** A diff-scoped script against the base that auto-fixes or flags the mechanical findings:
   capitalized sentence starts in net-new comments, header helpers with one user TU, `static` mixed with an anon
   namespace, duplicated bodies (jscpd / PMD CPD), a Catch2 TEST_CASE with one SECTION (flag only, R23).
   clang-tidy covers `misc-definitions-in-headers` and `misc-unused-parameters`.
5. **Review pane.** One finding at a time in a side pane or popup sized to the diff, with red/green coloring and
   the decision prompt beside it (R18). Code references open the code at the line in one click (R1). In authoring
   mode they open the local file. In PR review mode they open the PR diff line on the forge (R2).
6. **Maintainer-reply drafter.** Refuses to draft until it has the failure, the test, and what changed.
7. **Bundle provenance check.** Every test binary carries its source commit. Stale binaries fail the run.
