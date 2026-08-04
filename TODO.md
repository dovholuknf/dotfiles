# TODO (dotfiles + agent setup)

Working list for clint + claude. Check items off as they land. Dates are absolute.

## Decide (clint)

- [ ] pre-tool-use hook: how to let claude commit. Pick the containment model:
  - path-sandbox: claude commits only when `git rev-parse --show-toplevel` is under `D:\worktrees\claude`.
  - branch-prefix: claude commits only on branches like `agent/`, `session/`, `feature/`.
  - Recommendation: path-sandbox as the hard fence, plus a branch-prefix rule inside it. Enforce by
    location, not a mandatory `git -C` flag (the hook already blocks `git -C`). Then I wire it into
    `claude/hooks/pre-tool-use-hook.ps1`.

## Do (clint, run these)

- [ ] Activate the push guards on clint's account:
  `git config --global core.hooksPath "D:/git/github/dovholuknf/dotfiles/githooks"`, confirm
  `commit.gpgsign=true`, then `git add githooks/pre-push` and `git update-index --chmod=+x githooks/pre-push`.
- [x] Created the main-push allowlist file at `~/.config/git/main-push-allowlist` (untracked). Add repo
  ids there, `host/org/repo` one per line (e.g. `github.com/dovholuknf/dotagents`), to always allow their
  main pushes. The pre-push hook names this file in its block message.
- [ ] Run the proof runbook: signed push allowed, unsigned blocked, main prompts, claude cannot push.
- [ ] Verify `CLAUDE_GH_TOKEN` scopes are read-only (no contents/write, no push). It is claude's own
  credential (fine for claude to hold), but a write-scoped PAT lets claude push despite the signature
  gate, cutting against the no-push premise. Lives in claude's `~/.profile.secrets.ps1` (untracked).
- [ ] Commit the accumulated changes. Two repos:
  - dotfiles: doc-humanizer agent, `_WtPrompt` in common-tools, both profiles, the Set-Theme
    `-UseRepoTheme`/`-SetRepoTheme` split (wt-themes + docs/themes.md), githooks/pre-push, cdtk,
    ziti-slide skill, allow-docker command.
  - dotagents: the CLAUDE.md shared-prompt note.

## Queued (me, on your go)

- [ ] Implement the chosen claude-commit containment in `pre-tool-use-hook.ps1`.
- [ ] Optional: bump doc-humanizer model sonnet -> opus (prose judgment), and/or wire it into
  review-panel / qa-review / a `/humanize` skill.
- [ ] Optional: add a `# Authored prose` content-side rule to CLAUDE.global.md capturing the blog tics
  (stacked pull-quotes, X-not-Y, drumbeat fragments) so committed writing has its own filter.
- [ ] Optional pre-push / `_WtPrompt` hardening: wrap the prompt banner `[Console]` calls in try/catch so
  the prompt never throws in a console-less host.
- [ ] gwt: normalize WorktreePath slash style at every write point (spawn/claim/restore/rehome), not just
  audit display.

## Security / hardening

- [ ] Apply the claude sandbox on `D:` (sharing `D:` is intentional; the blanket `Authenticated Users:Modify`
  is not). Run `powershell/onpath/sandbox-account.ps1` (dry-run first, then `-Apply` elevated as clint) with the
  invocation in `powershell/docs/account-isolation.md`. Decide whether to add `dotfiles\powershell` to
  `-WritePath`: leaving it out is the real sandbox; adding it keeps claude editing the shell tooling but re-opens
  code-exec-as-clint.
- [ ] Optional deeper scan: `accesschk -uwqs "<host>\claude" C:\` (full writable surface) and
  `accesschk -uwcqv "<host>\claude" *` (services/tasks claude can write, a path to SYSTEM).

## Back burner

- [ ] WSL/ziti blog post: set the `authors:` key and move it to the real blog posts dir.
