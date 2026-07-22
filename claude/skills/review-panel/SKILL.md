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
  "fix": "the concrete change that resolves it",
  "confidence": "high|medium|low"
}]
```

The `evidence` field is mandatory and must cite real lines, not restate the claim -- it is what the
verify pass and the conductor check against.

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

Adjust with judgment. A diff that only touches docs or generated files may need no panel, say so. A
change that adds a client, transport, auth, persistence, or a second copy of an existing flow should
always include `codebase-steward` regardless of language. Do not run a specialist whose language is
absent from the diff.

## 3. Report the panel and confirm before dispatching

Before launching anything, show the user what will run and wait for the go-ahead. This is a hard gate:
no agent starts until the user confirms.

- list each selected agent with a one-line reason it was chosen
- show the diff range or PR the panel will review, and the count of changed files
- ask the user to confirm, add, or remove agents

Ask however the host prefers. `AskUserQuestion` (options like Proceed / Adjust selection / Cancel, with
Other to name exact agents) is the default, but if the host or user disallows the picker, ask the same
thing as plain text. Either way, wait for the answer.

Also tell the user, in one line, that after the panel returns you will adversarially verify the serious
findings and run a coverage critic (extra agents, more tokens) -- so they can say up front "skip the
verify pass" or "no critic" if they want a lean run. A prior "just run it" / `-y` opts into everything.

Skip this gate only when the invocation already told you to proceed without asking (the user passed a
confirming argument such as `-y` or `go`, said something like "just run it", or the request itself was
"run the review panel"). In that case still print the one-line selection first, then dispatch.

Example of what to show:
`Panel for <range> (7 files): go-security-reviewer (Go footguns), codebase-steward (fit, new client added). Proceed?`

## 4. Dispatch in parallel

Launch all selected agents in a SINGLE message with one `Agent` tool call each, so they run
concurrently in isolated contexts. Give every agent the same shared context:

- the repo absolute path
- the captured diff text and its range (or the PR number) so they all review the identical snapshot
- their specialized mandate (the security agent hunts footguns, the steward hunts divergence-from
  -convention, and so on)
- instructions to read whatever surrounding files or dependency source they need, NOT just the diff
- review only, do NOT modify files
- the Severity scale and Finding schema from the Shared definitions above, verbatim -- they MUST return
  the ```json array in that shape, with real `evidence`

## 5. Adversarially verify the serious findings

Do not trust `blocking` and `high` findings on the reviewer's word -- past panels have shipped
confident-but-wrong criticals. Before merging, refute them.

- Collect every finding at severity `blocking` or `high` across all agents.
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

## 7. Report

Output one consolidated report:

- A one-line verdict header (for example `BLOCKING: 1 high security, 1 high fit, 2 nits`).
- Findings grouped by lane, each tagged with severity, file:line, the issue, the fix, which agent(s)
  raised it, and -- for anything that went through step 5 -- the verify verdict.
- A short "possible gaps" section from the completeness critic.
- A short note on anything you merged, dropped, or downgraded during triage and verification, so the
  user can see what was reconciled.

Do not apply fixes. End by offering to apply the agreed-upon ones, and let the user choose which.
