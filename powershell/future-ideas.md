# gwt / dotfiles future ideas

Capture for "do this later, maybe."

## Tab completion for `gwt`

Wire `Register-ArgumentCompleter` for the `gwt` function in `$PROFILE`. Two
useful levels:

**Cheap (subcommand names only, ~5 lines)**
Completes `gwt n<Tab>` -> `new`, `gwt cla<Tab>` -> `claude`. Static list of
subcommand names. Zero latency, no failure modes.

**Useful (subcommands + dynamic branch names, ~50-80 lines)**
Per-subcommand argument completion:
- `gwt cd <Tab>`, `gwt rm <Tab>`, `gwt activate <Tab>`, `gwt claude <Tab>` ->
  branches from `git worktree list --porcelain` (in the current repo context)
- `gwt pr <Tab>` -> optionally `gh pr list --json number,title` (slower, skip
  for now -- pasting URLs/numbers is fine)

Lives in `$PROFILE`, not in `git-worktree.ps1`. Completion failures are silent
(return nothing), so they can't break `gwt` itself.

**Tradeoffs**
- Each Tab fires the completer. Calling git is ~50-200ms in PowerShell.
- PS caches completions briefly but the latency is noticeable on first Tab.
- Don't enable PR/URL completions until proven not-annoying.

**Recommendation**
Start with the cheap version + branch-name completion for `cd`/`rm`/`activate`/
`claude`. That's the sweet spot.
