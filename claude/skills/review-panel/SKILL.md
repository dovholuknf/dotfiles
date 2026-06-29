---
name: review-panel
description: >
  Run a panel of specialist review agents over a diff or PR in parallel, then merge and triage their
  findings into one report. Use when the user wants a thorough multi-reviewer pass, says "run all the
  relevant reviewers", "review panel", "gauntlet", or wants more than one specialist on a change. The
  skill is the conductor: it selects which agents are relevant from the changed files, fans them out
  concurrently, and consolidates the results. It does not review the code itself.
---

# review-panel

You are the conductor of a review panel. You do not review the code yourself. You pick the relevant
specialist agents, run them in parallel, then merge and triage what they return into one report.

## 1. Determine the review target

- If the user named a PR (number or URL), use it: `gh pr view <n>` for metadata and `gh pr diff <n>`
  for the diff.
- Otherwise review the working branch. Identify the changed files and the diff range:
  - committed branch work: diff against the merge-base with the default branch, for example
    `git --no-pager diff <default-branch>...HEAD`
  - include uncommitted changes if any show in `git status --porcelain`
- Capture the exact diff command and range you settled on. Every agent must review the same thing, so
  you will hand them this same range.
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

Use `AskUserQuestion` with options like Proceed, Adjust selection, and Cancel, so the user can change the
panel before any tokens are spent. The user can pick Other to name exact agents to run.

Skip this gate only when the invocation already told you to proceed without asking (the user passed a
confirming argument such as `-y` or `go`, or said something like "just run it"). In that case still
print the one-line selection first, then dispatch.

Example of what to show:
`Panel for <range> (7 files): go-security-reviewer (Go footguns), codebase-steward (fit, new client added). Proceed?`

## 4. Dispatch in parallel

Launch all selected agents in a SINGLE message with one `Agent` tool call each, so they run
concurrently in isolated contexts. Give every agent the same shared context:

- the repo absolute path
- the exact diff command and range (or the PR number) so they all review the identical change
- their specialized mandate (the security agent hunts footguns, the steward hunts divergence-from
  -convention, and so on)
- instructions to read whatever surrounding files or dependency source they need, NOT just the diff
- review only, do NOT modify files
- return findings as a list, each with: severity, file:line, the issue in one sentence, and the fix

## 5. Merge and triage

When all agents return, consolidate into ONE report. Do not just concatenate.

- Deduplicate: when two agents flag the same file:line or the same root cause, merge into one entry and
  note which agents raised it (agreement raises confidence).
- Keep two lanes: Correctness and security findings, and Fit and consistency findings. A reader should
  see them separately.
- Apply reachability skepticism: for any claimed panic, nil path, or unreachable state, sanity-check it
  against the actual code before promoting it. If it looks like a false positive, drop it or mark it low
  confidence and say why. Past panels have produced confident-but-wrong criticals, so do not pass those
  through unexamined.
- Rank by severity across the merged set.

## 6. Report

Output one consolidated report:

- A one-line verdict header (for example `BLOCKING: 1 high security, 1 high fit, 2 nits`).
- Findings grouped by lane, each tagged with severity, file:line, the issue, the fix, and which
  agent(s) raised it.
- A short note on anything you merged or dropped during triage, so the user can see what was
  reconciled.

Do not apply fixes. End by offering to apply the agreed-upon ones, and let the user choose which.
