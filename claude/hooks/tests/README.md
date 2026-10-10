# hook tests

Validation for the guards in `claude/hooks/pre-tool-use-hook.ps1`.

`test-gate.ps1` runs every rule in the hook. Most of the cases cover the git policy. The rest cover the non-git
rules: drive-root folders, the subagent gate, co-authored-by, `go build` output, find / perl / python, inline-env
docker, `;` and `>` in Bash, cmake presets, `gh api`, vcpkg files, em-dash, CSS `!important` and `.env` files. One
case per rule also checks the reason text.

## git guard

The git policy: claude may work only on its own `claude/*` branches and may never reach a remote.

- push / pull / fetch are always blocked.
- branch-naming verbs (`branch` create/delete/rename, `checkout -b`, `switch`) require a `claude/*` target.
- current-branch verbs (`commit`, `add`, `rebase`, `reset`, `restore`, `clean`) require the checked-out branch to
  be `claude/*`.
- read-only git (status, log, diff, show, remote, branch listing) always passes.
- git aliases are resolved before the checks, and creating aliases via `git config` is blocked, so an alias cannot
  smuggle a blocked verb.

Run it:

```powershell
pwsh -NoProfile -File claude/hooks/tests/test-gate.ps1                # hook under pwsh 7
pwsh -NoProfile -File claude/hooks/tests/test-gate.ps1 -Runtime 51    # under powershell.exe 5.1, as in production
pwsh -NoProfile -File claude/hooks/tests/test-gate.ps1 -Hook <exe> -Runtime exe
```

It builds throwaway repos (one on `claude/test`, one on `main`, and others for the hub and rebase cases), runs the
full case matrix against the hook, and exits non-zero if any case fails.

This is best-effort defense-in-depth, not a wall: a text-matching hook cannot catch every evasion (a renamed
binary, `sh -c`, a subprocess). The hard "never push" guarantee lives in the claude account's credentials, not
here.

## hook-blocks.ps1

Counts what the gate blocked in the last N days, read back from the claude-code transcripts (the hook keeps no log).
`-Sample <rule prefix>` prints random commands that one rule blocked. Cite its output in `../docs/gate-decisions.md`
when a rule changes.

    pwsh -File claude/hooks/tests/hook-blocks.ps1 -Days 7
    pwsh -File claude/hooks/tests/hook-blocks.ps1 -Sample 'claude may only create' -N 25
