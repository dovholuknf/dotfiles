# powershell/onpath/

Scripts intended to live on `$env:PATH`. The profile adds this directory automatically.

## Worktree tooling

| Script | What it does |
| --- | --- |
| `git-worktree.ps1` | The `gwt` toolkit. Clone, new worktree from branch / PR / issue, list with full state machine, prune, session-ledger management. The big one. See `../docs/gwt-states.md`. |
| `New-Worktree.ps1` | Older single-purpose "make a worktree from a PR URL" script. Kept for reference; `gwt` covers this. |
| `Prune-All-Worktrees.ps1` | Bulk prune across an entire `D:\git\<host>\<org>\<repo>` set. `gwt prune -Org <org>` is the modern equivalent. |
| `test-gwt-states.ps1` | Test harness. Builds a sandbox with one example of every worktree state, runs `gwt list`, asserts the classification. |
| `prune-claude-projects.ps1` | Find / delete orphan claude-code transcript directories under `~/.claude/projects/` whose decoded path no longer exists. Default is read-only. `-Apply` to delete. |

## Git helpers

| Script | What it does |
| --- | --- |
| `branch-diff.ps1` | Diff a local branch against `main`. |
| `all-branch-diff.ps1` | Diff every non-default branch against `main`. |
| `tidy-git-branches.ps1` | Fetch with `--prune`, then delete local branches whose upstream is `[origin/...: gone]`. |
| `tidy-git-branches-list.ps1` | Same idea, list-only variant. |
| `rebase-local-branches.ps1` | Iterate local branches and rebase each on top of `origin/main`. Has cosmetic emojis. |
| `clean-git.ps1`, `git-clean.ps1` | Per-branch cleanups. Slightly different shapes, both pre-`gwt`. |
| `dovnfgh.ps1`, `dovpersonal.ps1`, `dovpersonalgh.ps1` | Switch `git config user.email/.name/signingkey` for the current repo to a known identity. |
| `topersonal.ps1` | Rewrite the current repo's `origin` URL from `git@github.com:...` to `git@personal-github.com:...` (a ssh config alias for the personal identity). |

## System / disk

| Script | What it does |
| --- | --- |
| `disk-usage.ps1` | Tree-style disk usage with depth and sort options. |
| `disk-use.ps1` | Earlier flat-listing version. |
| `weekly-disk-usage.ps1` | Wraps `disk-usage.ps1` and timestamps a snapshot into `V:\disk-usage-history`. Wired into a scheduled task. |
| `dfbackup.ps1` | Copies `$PROFILE`, `.gitconfig`, and a few other dotfiles into `$env:DOTFILES_ROOT`. Pre-symlink legacy. |
| `install-pwsh-lts.ps1` | Admin script that pulls the current pwsh LTS msi and installs it (x64 or arm64). |
| `allow-hyperv-vm.ps1` | Opens the Windows host firewall to inbound traffic from VMs on the Hyper-V Default Switch. |
| `resetwsl.ps1` | Re-mounts the WSL data VHDs (D: and E:) after a `wsl --shutdown`. |
```
