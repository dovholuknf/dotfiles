# gwt states

Reference for what `gwt list`, `gwt status`/`gwt changes`, `gwt prune`, and `gwt sessions`
see. Source of truth is `powershell/onpath/git-worktree.ps1`. This doc is for humans;
update it when the code changes.

Two state machines live in gwt and they're independent:

1. **Worktree state** -- what `gwt list` / `gwt prune` care about. Driven by git: branch
   has commits, has upstream, working tree dirty, etc. See "worktree states" below.
2. **Session state** -- what `gwt sessions` cares about. Driven by claude-code hooks
   writing to the session ledger (`$env:WORKTREE_ROOT\sessions\<id>.json`) and the
   transition log (`$env:WORKTREE_ROOT\watch\state.log`). See "session states" below.

## worktree states

Source: `Get-WorktreeStatuses` in `git-worktree.ps1`.

## the state set

| Label | Color | Meaning | Detection |
|---|---|---|---|
| `MAIN` | DarkGray | The repo's main clone (not a worktree). Always one per repo. | `git worktree list` row whose path matches `$ctx.Src` |
| `ACTIVE` | Cyan / Green | Branch is in-progress. Either tracking an upstream that isn't merged to `origin/main`, OR no upstream config but has local commits not in main. | `git status --porcelain` is clean AND (has upstream + not merged) OR (no upstream + commits beyond main) |
| `ACTIVE-REMOTE-GONE` | DarkYellow | Branch HAD an upstream (`branch.X.merge` config still set), but `origin/X` ref is gone, AND there are local commits not in main. Real risk: pruning loses those commits. | `hasUpstreamConfig=true` + `remoteExists=false` + clean + NOT atOrBehindMain |
| `PRUNE` | Red | Safe to delete. One of: merged to origin/main, remote deleted with no commits-beyond-main, no commits beyond main + no upstream, or path missing. | See PRUNE reasons table below |
| `DIRTY` | Yellow | Working tree has any local content: tracked edits AND/OR untracked files. | `git status --porcelain` non-empty |
| `ORPHAN` | Magenta | A directory under `$WtRoot` that git no longer tracks as a worktree, but is still a valid (.git linkage works) clean repo. | Dir exists under WtRoot, NOT in `git worktree list`, `git status` succeeds AND is clean |
| `ORPHAN-NO-GIT` | Red | A directory under `$WtRoot` whose `.git` pointer is broken (target missing). Truly stranded -- safe to delete. | Dir exists under WtRoot, NOT in `git worktree list`, `git status` returns `fatal: not a git repository` |
| `ORPHAN-DIRTY` | Magenta | Orphan with uncommitted local changes -- skipped on prune, surfaces on list. | Like ORPHAN but `git status` returns non-empty dirty output |

## reason text catalog

| Status | Reason | When |
|---|---|---|
| `MAIN` | (none) | always |
| `ACTIVE` | `has upstream, not merged` | upstream config present, ref exists, NOT merged into origin/main |
| `ACTIVE` | `no upstream configured -- has local commits` | no upstream config, has commits beyond origin/main |
| `ACTIVE-REMOTE-GONE` | `WAS pushed, remote ref deleted -- has commits not on main (do not lose)` | upstream config present, remote ref gone, clean, has commits beyond main |
| `PRUNE` | `merged` | upstream present, remote present, branch is an ancestor of origin/main |
| `PRUNE` | `no commits, at main` | no upstream config, no commits beyond main |
| `PRUNE` | `WAS pushed, remote ref deleted` | upstream config present, remote ref gone, clean, no commits beyond main |
| `PRUNE` | `missing` | worktree path doesn't exist on disk |
| `DIRTY` | `has local changes` | working tree non-empty (any combo of tracked edits + untracked files) |
| `DIRTY` | `merged, has local changes` | DIRTY but branch is merged (rare) |
| `DIRTY` | `WAS pushed, remote ref deleted -- has local changes` | upstream was set, remote deleted, AND tree dirty |

## color rules for the reason line

In `gwt list`, the second line (the reason text) is colored the same as the status,
EXCEPT when the reason matches `"WAS pushed, remote ref deleted"` -- then the reason
line forces DarkYellow regardless of status color. This makes "remote deleted" state
visible across DIRTY / UNTRACKED-ONLY / PRUNE / ACTIVE-REMOTE-GONE rows.

## what changes between states

| Trigger | Old state | New state |
|---|---|---|
| `git add` + `git commit` on a DIRTY worktree | DIRTY | ACTIVE (if has remote) or PRUNE (if nothing left) |
| `git push -u origin <branch>` for the first time | ACTIVE (no upstream) | ACTIVE (with upstream) |
| Remote branch deleted (PR merged + cleanup) | ACTIVE | PRUNE (clean) or ACTIVE-REMOTE-GONE (has commits) |
| Merge worktree into main (then fetch) | ACTIVE | PRUNE (`merged`) |
| Delete worktree dir manually | any | ORPHAN-NO-GIT (the dir leftovers); registration becomes PRUNE (`missing`) on next list |
| `git worktree remove` | any | (removed entirely, dir cleaned up by gwt's helpers) |

## commands and which states they show

| Command | Shows |
|---|---|
| `gwt list` | All states + MAIN + CURRENT (the symlink) + orphans |
| `gwt status` / `gwt changes` | DIRTY, ACTIVE, ACTIVE-REMOTE-GONE, ORPHAN-DIRTY, ORPHAN-NO-GIT (everything with "something to look at") |
| `gwt prune` | Only PRUNE candidates + orphans; DIRTY skipped unless `-Force` |
| `gwt prune -Force` | Adds DIRTY to the prunable set |
| `gwt list -Verbose` | Same as `gwt list` but inlines `git status --short` for DIRTY rows and `git log origin/main..HEAD` for ACTIVE/ACTIVE-REMOTE-GONE rows |

## detection limits (honest about what we can and can't know)

- **"Was this branch ever pushed?"** Not reliably determinable from local state alone.
  We use `branch.<name>.merge` config as a proxy for "was tracked at some point" --
  but a `git push origin <branch>` (no `-u`) won't set that config, and someone could
  have manually unset it. To get a definitive answer, query the remote
  (`git ls-remote origin <branch>`) -- not done by default because it's a network
  call per branch.

- **"Are these untracked files mine or build artifacts?"** Can't tell. UNTRACKED-ONLY
  used to be a separate state but it was indistinguishable from DIRTY for practical
  purposes (both block clean prunes, both surface in `gwt status`). Now folded into
  DIRTY. Use `gwt list -Verbose` to see the actual files.

- **"Did the remote delete this branch on purpose (merge cleanup) or accidentally?"**
  Can't tell. ACTIVE-REMOTE-GONE just tells you the remote is gone -- you have to
  check the PR history (`gh pr list --state merged --head <branch>`) to know why.

- **Orphan vs gwt-managed orphan**: We assume any directory directly under
  `<WtRoot>\<host>\<org>\<repo>\` is meant to be a worktree. A user-created dir
  there (e.g. for scratch space) would be flagged as ORPHAN. Don't put random
  stuff in worktree roots.

## locking conventions (the protection guards)

| Guard | Where | What it does |
|---|---|---|
| `_AssertUnderWorktreeRoot` | All `Remove-Item -Recurse -Force` sites | Throws if the target isn't under `$WorktreeRoot`. Last-line-of-defense against deleting outside the canonical layout. |
| Alive-session check | `Remove-Worktree`, orphan-removal | Refuses to remove a path if a claude session is alive there |
| cwd-inside-target hop | `Remove-Worktree` | If the parent shell's cwd is inside the worktree about to be deleted, auto-cd's to MAIN and sets the gwt hint file so the wrapper follows |
| Saved-protection | `Test-WorktreeIsSaved` | Reads session-registry entries; if any has Saved=true for this path, prune refuses (even with -Force). Ad-hoc claude launches in non-git dirs auto-set Saved. |
| Canonical-path guard in clean | `gwt sessions clean` | Refuses to drop session entries whose WorktreePath isn't under `$env:WORKTREE_ROOT\<host>\<org>\<repo>\<branch>` or `$env:GIT_ROOT\<host>\<org>\<repo>` |

---

## session states

Driven by claude-code lifecycle hooks (see `claude/README.md` for the hook wiring).
Each session has a JSON entry at `$env:WORKTREE_ROOT\sessions\<id>.json`; every transition
also appends one line to `$env:WORKTREE_ROOT\watch\state.log` so `gwt watch` and any other
log tail can observe it.

### lifecycle buckets (what `gwt sessions` displays)

These are the row-level tags in the `gwt sessions` listing. Picked by the combination of
process-liveness, the `State` field on the JSON, and whether the worktree path still exists.

| Tag | Color | Meaning | Detection |
|---|---|---|---|
| `ACTIVE` | Green | PID is running, the session is live | `Pid != 0` AND that pid actually exists on the box |
| `ENDED` | DarkGray | Human closed the session cleanly (SessionEnd hook fired with State='ended'). Low priority for restore. | not alive AND `State == 'ended'` |
| `ABORTED` | Yellow | Process is gone but SessionEnd never fired. Cause: Windows restart, claude crash, hard kill, OOM. **The priority for restore.** Worktree dir still exists. | not alive AND `State != 'ended'` AND path exists |
| `STALE` | Red | Process is gone AND the worktree dir is missing | not alive AND path missing AND path was under `$env:WORKTREE_ROOT` |
| `SAVED` | (tag-only override) | Marked saved by the user; protected from every `clean` tier | `Saved == true` on the JSON (overrides the lifecycle tag) |

A missing path under `$env:GIT_ROOT` (a main-clone path, not a worktree path) stays
`ABORTED` rather than `STALE` so a temporary unmount or path move never causes a main-clone
session entry to be auto-classified as cruft.

Historical note: `ABORTED` was previously labeled `PAUSED`. The flag for cleaning it is now
`-Aborted`, with `-Paused` kept as a backward-compat alias.

### sub-state tag (alive sessions only)

For an ALIVE row, the listing shows a second bracket after the lifecycle tag with the
current `State` field:

| State | Sub-tag | Set by |
|---|---|---|
| `idle` | `[ idle]` | `Stop` hook (claude finished its turn) |
| `thinking` | `[THINK]` | `UserPromptSubmit` hook (claude received a prompt and is working) |
| `needs-input` | `[INPUT]` (row colored Magenta) | `Notification` hook with matcher `permission_prompt` or `elicitation_dialog` |
| `startup` / `resume` / `clear` / `compact` | `[<value>]` | `SessionStart` hook, taken from the payload's `source` field |
| `ended` | (no sub-tag; ENDED becomes the lifecycle tag instead) | `SessionEnd` hook |

The startup-family states (`startup`, `resume`, `clear`, `compact`) appear briefly after
SessionStart fires, then get overwritten to `thinking` on the first user prompt.

### state.log format

Each line in `$env:WORKTREE_ROOT\watch\state.log` is:

```
<iso-ts>  <state>  <branch>  @ <path>
```

`<state>` is one of: `startup`, `resume`, `clear`, `compact`, `thinking`, `idle`,
`needs-input`, `ended`. A full session's worth of events looks like:

```
2026-06-05T09:00:01-04:00  startup      fix-algolia  @ D:\worktrees\github\netfoundry\docusaurus-shared\fix-algolia
2026-06-05T09:00:08-04:00  thinking     fix-algolia  @ D:\worktrees\...
2026-06-05T09:00:23-04:00  idle         fix-algolia  @ D:\worktrees\...
2026-06-05T09:01:55-04:00  needs-input  fix-algolia  @ D:\worktrees\...
2026-06-05T09:02:04-04:00  thinking     fix-algolia  @ D:\worktrees\...
2026-06-05T09:02:30-04:00  idle         fix-algolia  @ D:\worktrees\...
2026-06-05T09:05:00-04:00  ended        fix-algolia  @ D:\worktrees\...
```

### `gwt sessions` scope

Every `sessions` subcommand defaults to "this repo" when the cwd is inside one (main clone OR any
worktree of that repo). Pass `-All` to drop the scope and act across every repo's sessions. When
the cwd is NOT inside any known repo, scope is implicitly global.

Detection is pure path arithmetic:
- `$env:WORKTREE_ROOT\<host>\<org>\<repo>\<branch>\...` -> repo = `<host>/<org>/<repo>`.
- `$env:GIT_ROOT\<host>\<org>\<repo>\...` -> same.

### `gwt sessions clean` drop tiers

| Flag | Drops |
|---|---|
| (default) | `STALE` + `ENDED` |
| `-Aborted` (alias `-Paused`) | adds `ABORTED` |
| `-IncludeActive` | adds `ACTIVE` (the registry entry only; the running shell is unaffected) |

Tiers compose. `-All` is now a SCOPE flag, not a tier multiplier; to nuke every tier across every
repo run `gwt sessions clean -Aborted -IncludeActive -All`.

### `gwt sessions restore` defaults

By default `restore` brings back `ABORTED` sessions and skips `ENDED` ones (the user closed those
deliberately). Pass `-IncludeEnded` to restore everything not-alive. Pass `-All` to restore across
every repo (default is this-repo-only when cwd is in a repo).

`SAVED` entries are protected from every tier. `-DryRun` previews without acting.
