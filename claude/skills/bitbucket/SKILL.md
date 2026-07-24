---
name: bitbucket
description: >
  Read Bitbucket Cloud data (pull requests, diffs, comments, repos, commits, pipelines) via the
  read-only `bbapi` PowerShell helper. Invoke whenever the user wants to look at something in
  Bitbucket: a PR or pull request, a bitbucket.org URL, a diff/review, repo or branch contents,
  or CI pipelines in the `netfoundry` or `dovholuk` workspaces. Read-only; it cannot write.
---

# bitbucket

`bbapi` is a read-only Bitbucket Cloud API helper (a PowerShell function defined in the shared
dotfiles at `D:\git\github\dovholuknf\dotfiles\powershell\shared\common-tools.ps1`). It is read-only
two ways: the function itself hardcodes `--request GET` (so it cannot write even with a broader
token), and the Atlassian API token is scoped read-only on top of that. Never attempt a write
(POST/PUT/DELETE). If the user needs one, tell them to do it themselves.

## How to call it (from the Bash tool)

The Bash tool is Git Bash, so call PowerShell explicitly. Running `pwsh` loads the user profile,
which defines `bbapi` and sets the creds (`$env:BB_EMAIL`, `$env:BB_TOKEN`) — no manual setup.

- Simple one-shot: `pwsh -Command "bbapi 'repositories/netfoundry/<repo>/pullrequests?state=OPEN'"`
- Flags: `-All` follows pagination and merges every page's `.values`; `-Raw` returns raw text
  (used for `/diff` and file source). Note `-Raw` yields an array of lines, not one string — fine
  for diffs, join with "`n" if you need a single blob.

### Two hard gotchas (a PreToolUse hook enforces these)

1. **No `;` anywhere in a Bash command — including inside the `pwsh -Command "..."` string.** The
   hook blocks it. So if your PowerShell needs `;` (calculated properties, multiple statements),
   DON'T inline it. Write a `.ps1` to the scratchpad and run `pwsh -File <path>`. Bare
   `bbapi '<path>'` calls have no `;` and are fine inline.
2. **One command per Bash call** — no `;` or `&&` chaining between shell commands either.

The `pwsh -File <script>` pattern is the reliable default for anything non-trivial:

```powershell
# scratchpad\pr.ps1
$base = 'repositories/netfoundry/<repo>/pullrequests/<id>'
$pr = bbapi $base
"PR #$($pr.id): $($pr.title) [$($pr.state)]  $($pr.source.branch.name) -> $($pr.destination.branch.name)"
bbapi "$base/diff" -Raw
```

Then: `pwsh -File "<scratchpad>/pr.ps1"`.

## Common endpoints (path is everything after `https://api.bitbucket.org/2.0/`)

- Open PRs:     `repositories/<ws>/<repo>/pullrequests?state=OPEN`   (add `-All`)
- One PR:       `repositories/<ws>/<repo>/pullrequests/<id>`
- PR diff:      `repositories/<ws>/<repo>/pullrequests/<id>/diff`     (`-Raw`)
- PR diffstat:  `repositories/<ws>/<repo>/pullrequests/<id>/diffstat` (`-All`)
- PR comments:  `repositories/<ws>/<repo>/pullrequests/<id>/comments` (`-All`)
- PR commits:   `repositories/<ws>/<repo>/pullrequests/<id>/commits`  (`-All`)
- Repo list:    `repositories/<ws>?pagelen=100`                       (`-All`)
- File source:  `repositories/<ws>/<repo>/src/<commit-or-branch>/<path>` (`-Raw`)
- Pipelines:    `repositories/<ws>/<repo>/pipelines?sort=-created_on`

## URL mapping

A browser URL maps to an API path with one rename: the browser uses `pull-requests` (hyphen), the
API uses `pullrequests` (no hyphen). Example:
`https://bitbucket.org/netfoundry/customer-connect-docs/pull-requests/17/diff`
-> `bbapi 'repositories/netfoundry/customer-connect-docs/pullrequests/17/diff' -Raw`

Workspaces in use: `netfoundry`, `dovholuk`.

## Troubleshooting

- `bbapi: set $env:BB_EMAIL and $env:BB_TOKEN ...` — creds aren't in the profile. Tell the user to
  add them to `C:\Users\claude\.profile.ps1` and reload (`. $PROFILE`).
- Empty diff/diffstat — these endpoints 302-redirect; `bbapi` already follows redirects
  (`--location`). If it's still empty, the PR genuinely has no changes vs its destination.
- `403` / insufficient scope — name the exact read scope to add to the token (e.g.
  `read:pipeline:bitbucket` for pipelines) and tell the user; don't try to work around it.
