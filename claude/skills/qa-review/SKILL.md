---
name: qa-review
description: >
  Run a QA review of a diff or PR using the testing agents. Asks whether you want a full, functional-only, or
  non-functional-only pass, then dispatches functional-tester and/or nonfunctional-tester and consolidates their
  findings. Use when the user wants a testing-focused review, says "qa review", "test review", "qa this", or asks
  about functional or non-functional test coverage. It selects and runs the testers; it does not review the code
  itself.
---

# qa-review

You are the conductor of a QA review. You do not review the code yourself. You pick the review scope with the
user, run the matching testing agent(s) over the same change, then merge their findings into one report.

## 1. Determine the review target

- If the user named a PR (number or URL), use it: `gh pr view <n>` for metadata and `gh pr diff <n>` for the diff.
  Bitbucket PRs: use the `bitbucket` skill / `bbapi` instead of `gh`.
- Otherwise review the working branch: diff against the merge-base with the default branch (for example
  `git --no-pager diff <default-branch>...HEAD`), and include uncommitted changes if `git status --porcelain`
  shows any.
- Capture the exact diff command or PR number. Both testers must review the identical change, so you hand them
  the same range.

## 2. Ask the scope (as text, not the picker tool)

Ask the user which pass they want, phrased for a human. Present exactly three choices and wait for the answer:

```
QA review scope for <range or PR>:
  1. Full           both passes: does it do the right thing, AND does it hold up under load, failure, and time
  2. Functional     correctness only: does the change behave correctly across happy path, edges, and errors
  3. Non-functional performance, resilience, resource use, and observability only
```

Map the answer to agents:
- Full -> `functional-tester` AND `nonfunctional-tester`
- Functional -> `functional-tester` only
- Non-functional -> `nonfunctional-tester` only

Skip the question only if the invocation already specified the scope (for example `qa-review functional`, or the
user said "just the non-functional side").

## 3. Dispatch

Launch the chosen agent(s) with the `Agent` tool. For a full review, launch both in a SINGLE message (one
`Agent` call each) so they run concurrently in isolated contexts. Give each the same shared context:

- the repo absolute path
- the exact diff command and range (or the PR number) so both review the identical change
- their mandate: functional-tester judges correctness of behavior only, nonfunctional-tester judges quality
  attributes (performance, resilience, resource use, observability) only
- instructions to read whatever surrounding files or dependency source they need, not just the diff
- review only, do NOT modify files
- **do NOT build, compile, `go vet`, `go build`, `go test`, `make`, or run any existing tests.** This is a PR:
  CI already builds and vets it. Reason about behavior and coverage by READING and `grep`-ing the code; the
  deliverable is the tests to ADD, described, not executed. A tester that shells out to a compiler or test
  runner is burning minutes on something CI already did.
- return findings as a list, each with: severity, file:line, the gap or risk in one sentence, and the concrete
  test to add

## 4. Merge and report

- One consolidated report. If both ran, keep two labeled lanes: FUNCTIONAL and NON-FUNCTIONAL. Do not interleave.
- One-line verdict header (for example `BLOCKING: 1 uncovered error path (functional), unbounded retries
  (non-functional)`).
- Each finding: severity, file:line, the gap or risk, and the test or benchmark to add.
- Apply reachability skepticism. Sanity-check a claimed gap against the actual code before promoting it, and drop
  or mark low-confidence any that look like false positives, with a one-line why.
- Do not apply fixes or write tests. End by offering to add the agreed-upon tests, and let the user choose which.
