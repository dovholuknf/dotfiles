# pull-requests.md

How I want PRs and commits authored.

## PR scope

- One concern per PR. If a request bundles the actual fix with cosmetic nice-to-haves, call that out
  and scope them apart.
- A "small, mergeable, reviewable" PR beats a comprehensive one. Reviewers have a finite attention
  budget; spend it on the load-bearing change.
- If the work is genuinely two concerns, propose splitting BEFORE you write code. Ask: "this naturally
  splits into A (the fix) and B (the cleanup). Want them as two PRs?"

## PR title

- Short, imperative, lowercase, no trailing period.
- States the BEHAVIOR change, not the file change.

Good: `normalize path separators in build script`
Bad: `update path-normalize.ps1`

Good: `gate write+edit tools through atrium permission hook`
Bad: `add atrium-perm-hook.ps1 to PreToolUse`

## PR body

Template (use it loosely; don't fill in sections that have nothing to say):

```
## Summary
1-3 bullets. What and why. Not how.

## Test plan
- [ ] specific scenario 1 (with the actual command you ran)
- [ ] specific scenario 2
- [ ] regression: <what didn't break>

## Notes / caveats
Optional. Edge cases, follow-ups, things reviewers should know.
```

Rules:
- No marketing tone. No "this PR improves X." Just say what it does.
- No "🤖 Generated with Claude Code" footer. No `Co-Authored-By:` line. Ever.
- Link issues in the body, not the title.
- Document a deliberate choice a reviewer would question (a thin helper kept, a DRY violation, a skipped
  abstraction, an out-of-scope edge case) here, not in code comments. A short "Deliberate decisions" note
  preempts the objection where reviewers actually look.
- If there's a screenshot or terminal capture that proves the change works, include it.

## Commit messages

- ONE LINE only. Subject line, no body, no bullets, ever. Even a commit that touches several things
  gets a single imperative line. Short, lowercase, no trailing period. Same rules as PR title.
- Reference the issue in that one line if relevant. Don't reference the PR number (the PR didn't exist
  when the commit landed).
- No `Co-Authored-By:` trailers. None.
- One logical change per commit. If you find yourself writing "and also..." in the subject, split.
- Don't amend pushed commits. Don't force-push without explicit OK.

## Before opening the PR

1. Pull main, rebase your branch onto it.
2. Run the actual scenarios in your test plan.
3. Re-read your own diff. If you wouldn't approve it as a reviewer, fix it before opening.
4. Hand me the `gh pr create` command. Don't run it. I push.

Example handoff:

```bash
gh pr create --title "normalize path separators in build script" --body "$(cat <<'EOF'
## Summary
- Collapse runs of backslashes after env-var reads to fix `D:\\git` from trailing-slash WORK_ROOT.
- Add a fallback default for missing env vars.

## Test plan
- [x] WORK_ROOT="" produces a sane default
- [x] WORK_ROOT="D:\" no longer produces D:\\git
- [x] existing valid WORK_ROOT values unchanged
EOF
)"
```

## When a PR comes back with feedback

- Fix it, push a new commit. Don't squash-and-force-push during review (the diff history matters to
  the reviewer).
- Reply to comments inline. "Done" is enough if the change matches the request. If the change
  differs, explain why.
- After all comments resolved, ping the reviewer. Don't re-request review without changes.
