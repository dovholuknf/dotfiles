# hook tests

Validation for the guards in `claude/hooks/pre-tool-use-hook.ps1`.

## git guard

`test-git-guard.ps1` exercises the git policy: claude may work only on its own `claude/*` branches and may never
reach a remote.

- push / pull / fetch are always blocked.
- branch-naming verbs (`branch` create/delete/rename, `checkout -b`, `switch`) require a `claude/*` target.
- current-branch verbs (`commit`, `add`, `rebase`, `reset`, `restore`, `clean`) require the checked-out branch to
  be `claude/*`.
- read-only git (status, log, diff, show, remote, branch listing) always passes.
- git aliases are resolved before the checks, and creating aliases via `git config` is blocked, so an alias cannot
  smuggle a blocked verb.

Run it:

```powershell
pwsh -NoProfile -File claude/hooks/tests/test-git-guard.ps1
```

It builds two throwaway repos (one on `claude/test`, one on `main`), runs the full command matrix against the live
hook, and exits non-zero if any case fails.

This is best-effort defense-in-depth, not a wall: a text-matching hook cannot catch every evasion (a renamed
binary, `sh -c`, a subprocess). The hard "never push" guarantee lives in the claude account's credentials, not
here.
