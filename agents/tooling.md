# tooling.md

Rules with teeth. These map to actual hooks under `hooks/`; an agent that ignores the prose still
gets blocked at runtime.

## Shell

- **Bash for one-off checks only.** No python or ruby to poke at things. Pure shell or skip it.
- **No `;` chaining.** Run one command at a time.
- **No `cd /path && command`.** Run `cd /path` as its own command, then run the next one.
- **No bare `find`.** Use glob patterns. (`fd` if available.)
- **Use `tee` instead of `>` or `>>`.** Output redirection via shell operators is blocked.
- **`gh api` calls must start with `gh api -X GET`.** The exception is the PR inline-comments endpoint.
- **For multi-check validation blocks**, add echo banners and blank lines so the output is readable.
- **SSH is mine to run.** Batch the remote commands for me; do not call ssh from a tool.

## Git

- **Never mutate my git repo.** Do not run `git add`, `git commit`, `git branch`, `git pull`,
  `git fetch`, `git push`, `git checkout`, `git rebase`, `git reset`, `git restore`, `git clean`.
  Tell me the command and let me run it.
- **No `git -C <path>`** or `--git-dir=`. `cd` to the path as its own step, then run git normally.
- **No force-push without explicit OK.** Especially not to main/master.
- **No `--no-verify` / `--no-gpg-sign`** unless I explicitly ask.

## Docker

- **Never prefix inline env vars before a docker command** (no `FOO=bar docker ...`). Pass env
  explicitly: `docker run -e VAR=val`, a compose `environment:` block, or `--env-file`.
- **No `docker rm -f` / `docker volume rm`** without asking. These are destructive.
- **Use `docker compose` (subcommand) not `docker-compose` (hyphenated binary)** unless the project
  explicitly requires the old binary.

## Paths

- **Translate Windows paths to wsl/linux style** for any tool that runs in bash. `D:\foo` becomes
  `/d/foo`.
- **Env-var driven path config in scripts.** Hardcoded `D:\` (or any drive letter) literals are a
  regression except as fallback defaults inside `if (-not $env:X)` guards.

## Multi-command suggestions

When you need me to run several shell commands in sequence:

- ONE fenced code block with the commands back to back.
- No prose between commands.
- Put explanation as shell comments on the line above, or in prose before/after the block.

Good:
```powershell
# rebuild + restart
go build -o build.claude\atrium.exe .\cmd\atrium
.\build.claude\atrium.exe hub
```

Bad:
> First, rebuild the binary:
> ```powershell
> go build ...
> ```
> Then run the hub:
> ```powershell
> .\build.claude\atrium.exe hub
> ```

## Tools I expect to be on PATH

- `git`, `gh` (GitHub CLI), `jq`, `yq`, `rg` (ripgrep), `fd`, `bat`, `delta`, `pwsh` (PowerShell 7),
  `go`, `node`, `docker`, `wsl`.
- If you're suggesting an install, prefer `winget` over chocolatey unless the package isn't on winget.

> **Personal taste**: the specific shell rules above (no `;`, no `cd && cmd`, no `find`, `tee`-not-`>`,
> `gh api -X GET`) are mine. They're enforced by a PreToolUse hook in this repo at
> `claude/hooks/pre-tool-use-hook.ps1`. Other people may want different rules; the principle
> ("machine-enforce the things you care about") is universal.
