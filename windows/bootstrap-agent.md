# Bootstrap the agent account

`bootstrap-agent.ps1` sets up the claude account on a new Windows machine. Run it as that account, after cloning
dotfiles and dotagents side by side under `<git-root>\github\dovholuknf\`. Turn on Developer Mode first, or run it
elevated, so it can create symlinks. Pass `-WhatIf` to see every change before it happens.

```powershell
pwsh -NoProfile -File <dotfiles>\windows\bootstrap-agent.ps1 -WhatIf
pwsh -NoProfile -File <dotfiles>\windows\bootstrap-agent.ps1
```

The script header lists what it does. This page covers what it cannot do, because each item is a secret, a
private address, or belongs to another installer.

| Item | How to restore |
| --- | --- |
| `~/.claude/.credentials.json` | Run `claude login`. |
| `~/.ssh/id_ed25519`, `id_ed25519_sign`, `config` | Copy from your password manager or the old machine. The signing key must exist before the first commit, because `agent.gitconfig` turns on `commit.gpgsign`. |
| `~/.profile.secrets.ps1` | Recreate by hand. `claude.profile.ps1` dot-sources it for tokens. |
| `~/.bb-ro-claude-token` | Recreate by hand. |
| MCP servers `mcp-gateway`, `DaveMCP` | `claude mcp add --scope user --transport http <name> <url>`. The URLs stay out of this public repo. |
| skills from other repos | `debug-ziti-desktop-edge-win` and `debug-ziti-edge-tunnel-log` link into the troubleshooting docs of the openziti `desktop-edge-win` and `ziti-tunnel-sdk-c` clones. Clone those, then link each skill dir into `~/.claude/skills`. |
| atrium | Its installer adds the `atrium-control` MCP server and the `atrium2-watchdog` scheduled task. |
| statusline path | `claude/settings.json` points `statusLine` at `D:/git/...`. Edit it if dotfiles lives somewhere else. |

Memories live in the private dotagents repo under `claude-memory/`. The script links each one back into
`~/.claude`, so new memories show up as changes in dotagents. Commit them there.
