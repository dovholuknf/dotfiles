# `gwt backport` -- design notes (in progress, 18 Aug 2026)

Captured mid-investigation. Nothing implemented yet.

## Goal

`gwt backport https://github.com/openziti/ziti/pull/4053` should:

1. Check out `release-v2.0.x` and bring it up to latest.
2. Create a worktree branched from that, not from `main`.
3. Cherry-pick the source PR's commits into the worktree.

## Where the code lives

`powershell/onpath/git-worktree.ps1`, 5292 lines.

| Thing | Line |
| --- | --- |
| `param(...)` block | 22 |
| `Invoke-Git` / `Invoke-GitCapture` | 200 / 209 |
| `Resolve-RepoContext` | 298 |
| `Ensure-RepoClonedAndUpdated` | 408 |
| `Test-LocalBranchExists` / `Test-RemoteBranchExists` | 452 / 457 |
| `Get-WorktreePathForBranch` | 462 |
| `Ensure-Worktree` | 473 |
| `Get-PrHeadBranch` | 513 |
| `Sync-PrBranch` | 545 |
| bare-URL dispatch (`/pull/<n>` -> `pr`) | ~1234 |
| `'new'` block | 1380 |
| `'pr'` block -- the model to copy | 1818 |
| `'twig'` block (branches off current HEAD) | 2071 |
| help text | ~5185 |
| `default { throw "unknown command" }` | 5286 |

`'pr'` already does most of the shape: parse the URL, `Resolve-RepoContext`,
`Ensure-RepoClonedAndUpdated`, resolve the head branch, handle an existing worktree
(focus / open / cancel), `Ensure-Worktree`, `_InvokeGwtHook`, `_ConfirmOpenOrCd`,
`_SetGwtCwdHint`. A `backport` block differs only in which base branch it uses, the
new branch name, and the cherry-pick step.

`'new'` shows the branch-from-a-source pattern via `-From`:
`git branch --no-track <target> <from>`.

## Facts established

### Release branches in openziti/ziti

```
release-next
release-v0.34.x
release-v1.1.x
release-v1.5.x
release-v1.6.x
release-v2.0.x
automate-lts-releases
```

`release-v2.0.x` is the exact name, not `release-2.0.x`. More than one live line
means the target cannot be hardcoded.

### The example PRs

| PR | State | Base | Head | Commits |
| --- | --- | --- | --- | --- |
| 4053 | MERGED | `main` | `issue-4052-use-refresh-token-to-reauth` | 4 |
| 4235 | MERGED | `main` | `fix/terminator-ops-source-router-scoping` | 1 |
| 4238 | MERGED | `release-v2.0.x` | `backport.v2.0.x.issue.4236.terminator-scoping` | 1 |
| 4239 | MERGED | `release-v1.6.x` | `backport.v1.6.x.issue.4237.terminator-scoping` | 1 |

4238 and 4239 are existing backports of 4235. They are the convention already in use.

### Merges are real merge commits, not squashes

`cffe2f08` (the merge of 4053) has **2 parents**, so the merged result is not a single
squashed commit. That decides the cherry-pick strategy:

- `git cherry-pick -m 1 <mergeCommit>` -- one commit, whole PR, loses per-commit history.
- `git cherry-pick <base>..<head>` -- replays all 4 commits individually.
- `git cherry-pick <oid> <oid> ...` from `gh pr view --json commits`.

Whichever wins, use `-x` so the cherry-pick records the source commit id. Standard
practice for backports, and it keeps provenance readable later.

## Open questions -- answer before implementing

### 1. Branch naming conflicts with the repo's own convention

The request was for `backport-<pr-head-branch>`, i.e.
`backport-issue-4052-use-refresh-token-to-reauth`.

But 4238 and 4239 use dots, embed the target line, and embed a **new issue number**
specific to that backport:

```
backport.v2.0.x.issue.4236.terminator-scoping
backport.v1.6.x.issue.4237.terminator-scoping
```

These disagree. The convention also encodes the target line, which matters once the
same PR goes to two branches -- `backport-<head>` collides with itself on the second
target, the convention name does not.

PR titles follow `[Backport-2.0] <original title>`.

### 2. Which release line, and can it be more than one?

4235 was backported to both 2.0 and 1.6. Options: a positional target, a `-To`
parameter, a prompt listing the `release-v*` branches, or accepting a list so one
invocation makes two worktrees.

### 3. A new tracking issue per backport?

The convention embeds one (4236, 4237 -- distinct from the original 4052 / 4235
issues). If the branch name needs it, it either has to be passed in or created via
`gh issue create`.

### 4. Conflict handling

Cherry-picking across release lines conflicts often. Likely right behaviour: leave the
worktree in the conflicted state, report which commit failed, print the
`git cherry-pick --continue` / `--abort` hint. Do not auto-abort -- the half-applied
state is what you want to work in.

### 5. Stop at the worktree, or go further?

Push the branch and open the backport PR with the `[Backport-N.N]` title, or leave
that manual?

### 6. The source PR need not be merged

An open PR has no merge commit. Fall back to the head branch's commits, or refuse.

## Suggested shape (unvalidated)

```
gwt backport <pr-url-or-num> [-To release-v2.0.x] [-Issue <num>] [-y]
```

- Resolve org/repo/pr from the URL with the same regex as `'pr'` at 1818.
- `gh pr view` for head branch, base, title, merge commit, commit list.
- Default `-To` to the highest `release-v*` branch, or prompt.
- `Ensure-RepoClonedAndUpdated`, then fetch and fast-forward the target branch.
- Branch name per whichever convention wins in Q1.
- `git branch --no-track <new> origin/<To>`, then `Ensure-Worktree`.
- `Sync-PrBranch` to guarantee the source commits are local. It fetches
  `refs/pull/<n>/head`, so it works for merged PRs whose branch was deleted.
- Cherry-pick with `-x` inside the worktree.
- On conflict, report and leave it.
- Then the standard `_InvokeGwtHook` / `_ConfirmOpenOrCd` / `_SetGwtCwdHint` tail.

Also needs an entry in the usage comment at the top of the file and in the help text
near 5185. The bare-URL dispatch should not route to `backport` -- `/pull/<n>` already
means `pr`.
