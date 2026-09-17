---
name: review-panel
description: >
  Run a panel of specialist review agents over a diff or PR in parallel, then merge and triage their
  findings into one report. Use when the user wants a thorough multi-reviewer pass, says "run all the
  relevant reviewers", "review panel", "gauntlet", or wants more than one specialist on a change. The
  skill is the conductor: it selects which agents are relevant from the changed files, fans them out
  concurrently, adversarially verifies the serious findings, and consolidates the results. It does not
  review the code itself.
---

# review-panel

You are the conductor of a review panel. You do not review the code yourself. You pick the relevant
specialist agents, run them in parallel, adversarially verify their serious findings, then merge and
triage what survives into one report.

## Shared definitions (used by dispatch, verify, and merge)

**Severity scale.** Every agent uses exactly these labels so the merged ranking is comparable:

- `blocking` -- ship-stopper: data loss, crash/hang on a common path, security hole, or breaks the build.
- `high` -- wrong behavior on a realistic path, or a security/correctness bug reachable behind a
  plausible condition.
- `medium` -- bug on an edge case, or a real maintainability/fit problem that will bite later.
- `low` -- minor correctness/style/fit issue, safe to defer.
- `nit` -- cosmetic, no behavioral impact.

**Finding schema.** Every agent returns its findings as a single fenced ```json block holding an array
of objects with exactly these fields (empty array if it found nothing):

```json
[{
  "severity": "blocking|high|medium|low|nit",
  "file": "path/relative/to/repo",
  "line": 123,
  "category": "correctness|security|fit|test|perf|style",
  "claim": "one-sentence statement of the problem",
  "evidence": "why it is real -- the code path, with file:line refs the conductor can check",
  "preexisting": "introduced|preexisting|worsened-by-pr",
  "prod_survival": "blocking/high only: one sentence answering 'why isn't this already broken in production?'",
  "fix": "the concrete change that resolves it",
  "confidence": "high|medium|low"
}]
```

The `evidence` field is mandatory and must cite real lines, not restate the claim -- it is what the
verify pass and the conductor check against. Two hard rules on it, learned from panels that shipped
confident-but-wrong criticals:

- **Dependency claims must quote the dependency's source.** Any claim about how a library or dependency
  behaves (a leak, an ownership transfer, an ordering guarantee) must quote the exact line from that
  dependency's OWN source, with its path, at the version the project pins (the vcpkg / go-module / lockfile
  pin) -- never reasoning from memory. A claim about dependency behavior with no quoted source line is
  dropped, not verified: memory-based dependency reasoning is where false leaks come from.
- **`preexisting`** says whether the PR caused it. `preexisting` (the PR never touched this code) is not the
  PR's finding: demote it out of `blocking`/`high` BEFORE the verify pass so no verifier is spent on
  unchanged code, and report it in a separate "pre-existing, not introduced here" note. Only `introduced`
  and `worsened-by-pr` keep their severity.
- **`prod_survival`** is required on every `blocking`/`high`. If the finding cannot answer "why isn't this
  already broken in production?" -- e.g. the loop actually breaks on match, the path is unreachable on the
  common case -- it is not a high; the agent must lower it or drop it. The conductor uses a failed answer
  as grounds to demote in step 6.

## 1. Determine the review target

- If the user named a PR (number or URL), use it: `gh pr view <n>` for metadata and `gh pr diff <n>`
  for the diff.
- Otherwise review the working branch. Identify the changed files and the diff range:
  - committed branch work: diff against the merge-base with the default branch, for example
    `git --no-pager diff <default-branch>...HEAD`
  - include uncommitted changes if any show in `git status --porcelain`
- Capture the exact diff command AND its full output text now. Every agent reviews the identical
  snapshot, so you hand them the captured diff text (plus the range so they can widen context), not just
  the command -- this pins them to one version even if the tree changes mid-run.
- If the user named specific agents when invoking, skip selection and use exactly those.

## 2. Select the relevant agents

Look at the changed files and the shape of the change, then choose from the available agent pack. Run
`Agent` with each chosen `subagent_type`. Default mapping:

- any non-trivial code change in any language -> `codebase-steward` (fit and divergence is language
  agnostic, so it runs on almost every panel)
- `*.go` -> add `go-security-reviewer` (Go language and security footguns)
- `*.c` / `*.h` -> add `c-systems-reviewer`
- `*.cs` -> add `csharp-expert`
- Windows admin surface (registry, GPO, MSI, services, `*.admx` / `*.adml`, Intune) ->
  add `windows-enterprise-veteran`
- behavior change with test-coverage stakes (new feature, endpoint, branch, bug fix) ->
  add `functional-tester` (does it do the right thing across edges and errors)
- performance, concurrency, resource, or resilience surface (hot path, load, retries, pools, goroutines,
  outbound calls) -> add `nonfunctional-tester` -- but ONLY when there is a latency or load surface a user
  would actually notice. A periodic background tick (a posture check every 20s, a housekeeping sweep) has
  no such surface: adding this agent there yields six "add a benchmark" findings that never reach the
  report. Skip it.

Adjust with judgment. The selection rule: name the concrete surface in THIS diff each agent needs to exist,
and skip the agent when that surface is absent. A diff that only touches docs or generated files may need no
panel, say so. A change that adds a client, transport, auth, persistence, or a second copy of an existing
flow should always include `codebase-steward` regardless of language. Do not run a specialist whose language
is absent from the diff, and do not run `nonfunctional-tester` on a change with no user-visible perf/load
surface.

## 3. Report the panel, then dispatch

Invoking the skill IS the go-ahead. Do NOT make the user type "proceed". When the user ran
`/review-panel`, said "review panel", "gauntlet", "run the reviewers", or handed over a PR to review, print
the one-line selection and dispatch immediately (step 4) -- no confirmation prompt. What to print in that
one line:

- each selected agent with a one-line reason it was chosen
- the diff range or PR and the count of changed files
- a note that a verify pass and coverage critic will follow (extra agents, more tokens), so the user can
  still say "skip the verify pass" or "no critic" -- but you do not WAIT for that; they interrupt if they
  want it.

The user can always interrupt to add/remove agents; requiring "proceed" first is the friction to remove.

Pause for an explicit answer ONLY when the request was a question rather than a command ("should I review
this?", "what would you run?"), or when the selection is genuinely ambiguous and a wrong pick is expensive.
Then ask as plain text (or `AskUserQuestion` if the host allows the picker) and wait.

Example of what to print before dispatching:
`Panel for main...HEAD (6 files): c-systems-reviewer (new C API, 4 TLS backends), codebase-steward (new vtable member). Verify pass + critic to follow. Dispatching.`

## 4. Dispatch in parallel

Launch all selected agents in a SINGLE message with one `Agent` tool call each, so they run
concurrently in isolated contexts. Give every agent the same shared context:

- the repo absolute path
- the captured diff text and its range (or the PR number) so they all review the identical snapshot
- their specialized mandate (the security agent hunts footguns, the steward hunts divergence-from
  -convention, and so on)
- instructions to read whatever surrounding files or dependency source they need, NOT just the diff
- review only, do NOT modify files
- **do NOT build, compile, `go vet`, `go build`, `go test`, `make`, or run any tests.** This is a PR: CI
  already builds and vets it. Answer any "does it still build / compile / are imports/callers satisfied"
  question by READING and `grep`-ing the code (find the callers, check the signatures), never by invoking
  a build. A reviewer that shells out to a compiler is wasting minutes on something already verified.
- the Severity scale and Finding schema from the Shared definitions above, verbatim -- they MUST return
  the ```json array in that shape, with real `evidence`, a `preexisting` value on every finding, a
  `prod_survival` answer on every `blocking`/`high`, and a quoted dependency-source line (with path, at the
  pinned version) for any claim about a dependency's behavior

## 5. Adversarially verify the serious findings

Do not trust `blocking` and `high` findings on the reviewer's word -- past panels have shipped
confident-but-wrong criticals. Before merging, refute them.

- FIRST, pre-filter cheaply, before spending any verifier: drop or demote every `blocking`/`high` whose
  `preexisting` is `preexisting` (move it to the pre-existing note, not the PR report), and every one whose
  `prod_survival` answer is empty or self-defeating (the loop breaks on match, the path is unreachable).
  This is the third of the run that used to be spent verifying findings a one-line read kills.
- Collect every REMAINING finding at severity `blocking` or `high` across all agents.
- For each, spawn one verifier in a SINGLE parallel message. Prefer a fork of the same specialist type
  that raised it (falling back to `general-purpose`), and prompt it to REFUTE, not confirm: reproduce
  the exact failing path from `evidence`, or show the state is unreachable / the claim is false. It must
  read the real code, not the finding text. Default to refuted when it cannot reproduce.
- Each verifier returns `{ "verdict": "confirmed|refuted|uncertain", "reason": "...", "corrected_severity": "..." }`.
- Apply the verdicts: drop `refuted`, keep `confirmed` (with any corrected severity), and demote
  `uncertain` to `low` with a note. Carry each verdict into the report.
- `medium`/`low`/`nit` findings skip the verify pass but still get the conductor's own reachability
  sanity-check in step 6.

## 6. Merge and triage

When verification is done, consolidate into ONE report. Do not just concatenate.

- **Integrity check first.** An agent's final message is not reliably schema-compliant: its prose can
  reference findings its ```json array omits. For each agent, diff the count of findings in its array
  against what its own summary prose claims; if they disagree, send that agent back for the complete array
  before merging. Never merge from the prose.

- Deduplicate deterministically on the structured fields: same `file` + `line` (or same root cause in
  `claim`) collapses into one entry, listing every agent that raised it (agreement raises confidence).
- Keep two lanes: Correctness and security findings, and Fit and consistency findings. A reader should
  see them separately.
- Apply reachability skepticism to anything that did not go through step 5: for any claimed panic, nil
  path, or unreachable state, sanity-check it against the actual code before promoting it. Drop or mark
  low-confidence false positives and say why.
- Rank by severity across the merged set.
- Coverage check: spawn one final `general-purpose` completeness critic. Hand it the diff and the merged
  finding list and ask what dimension NO reviewer covered (thread-safety, error paths, tests, i18n,
  perf, docs, backward compat). Its output is a short "possible gaps" list, not new confirmed findings.
  Do NOT list "does it build / compile / vet" as a candidate gap and do NOT let it run a build -- CI owns
  that; it reasons from reading the code only.

## 7. Report

Output one consolidated report:

- A one-line verdict header (for example `BLOCKING: 1 high security, 1 high fit, 2 nits`).
- Findings grouped by lane, each tagged with severity, file:line, the issue, the fix, which agent(s)
  raised it, and -- for anything that went through step 5 -- the verify verdict.
- A short "possible gaps" section from the completeness critic.
- A short note on anything you merged, dropped, or downgraded during triage and verification, so the
  user can see what was reconciled.

Do not apply fixes. End by offering to apply the agreed-upon ones, and let the user choose which.
