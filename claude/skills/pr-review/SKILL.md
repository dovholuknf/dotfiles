---
name: pr-review
description: >
  Full PR review in one shot. Runs the review-panel and qa-review skills over the same PR, merges their
  findings, drops nits and low-priority issues, and returns one tabular summary. Use when the user says
  "review this PR", "pr-review", "full review this pr", or hands over a PR number or URL to review.
---

# pr-review

One invocation, full review. You run two review skills over the same PR, then consolidate what matters into a
single table. You do not review the code yourself, and you do not apply fixes.

## 1. Identify the PR

- Given a PR number or URL, use it. GitHub: `gh pr view <n>` and `gh pr diff <n>`. Bitbucket: the `bitbucket`
  skill and `bbapi`.
- Otherwise review the working branch against the default branch.
- Capture the exact PR or diff once, and hand the SAME target to both skills so they review one snapshot.

## 2. Run both reviews (auto, no prompts)

- Invoke the `review-panel` skill on the PR. Use its automatic agent selection from the changed files (the
  correctness, security, and fit specialists it maps to) plus the adversarial verify pass. Do NOT ask the user
  to confirm or adjust the agent list. Auto-pick and dispatch.
- Invoke the `qa-review` skill on the PR at Full scope (both the functional and non-functional testers). Do NOT
  ask which pass. Full is automatic.
- This skill is the go-ahead, so neither sub-skill stops to confirm. Let each run to completion and collect its
  findings.

## 3. Merge and filter

- Pool every finding from both skills.
- Deduplicate on file plus line plus root cause. When both surface the same thing, list both sources and treat
  it as higher confidence.
- Drop everything at severity `nit` or `low`. Keep `medium`, `high`, and `blocking` or `critical`.
- Honor the verify verdicts review-panel already applied: drop refuted findings, keep confirmed ones with any
  corrected severity.

## 4. Output one table

Render a single table using the `tabular` skill's rules (hard width cap, no overflow). Columns:

| Sev | Area | File:line | Issue | Fix | Source |

- `Sev`: blocking or critical, then high, then medium. Highest first.
- `Area`: correctness, security, fit, functional, or non-functional.
- `Source`: review-panel or qa-review (name the agent when it helps).
- One row per surviving finding.
- Above the table, one verdict line only, for example `2 high, 3 medium (nits and low dropped)`. No other prose.

End with the table. Do NOT offer to fix the findings, and do NOT apply changes. This is a review only. If the
user wants something fixed, they will ask for it in a separate request. No "want me to fix any of these?" line,
no closing question, nothing after the table.

The `Fix` column stays: it describes the suggested remediation as review content. That is not the same as offering
to perform it. Describe the fix, do not propose to make it.
