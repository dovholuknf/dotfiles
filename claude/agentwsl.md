# agentwsl: the agents' own Linux box

When you need Linux or docker, run it on `agentwsl`:

```bash
ssh agentwsl                  # interactive
ssh -n agentwsl 'docker ps'   # one command
```

Do NOT use `cdwsl` for agent work. That is clint's own distro. Anything running there can reach clint's Windows
files through `/mnt/c` and start Windows programs as `sg4\clint` through interop.

## What it is

- A WSL2 distro named `agent-ubuntu` (Ubuntu 24.04), registered under the Windows `claude` account. Its disk lives in
  `%LOCALAPPDATA%\wsl\agent-ubuntu` of that account.
- Each Windows user gets their own WSL VM. So `/mnt/c` and interop here act as `sg4\claude`, and Windows denies that
  account access to clint's profile. Verified 2026-11-12: `cmd.exe /c whoami` says `sg4\claude`, and
  `/mnt/c/Users/clint` is "Permission denied", even as root.
- Linux user `claude` has passwordless sudo and is in the `docker` group. That is fine here: it is the agents' box, and
  nothing of clint's lives in it.
- sshd listens on port 2223 (key auth only, user `claude`). Port 2222 belongs to clint's `rhel9` entry.

## What is installed

- clint's `apt-mark showmanual` list from his distro, minus GUI apps: build tools (gcc, cmake, ninja, autotools,
  valgrind, gdb), docker-ce with compose and buildx, gh, git, jq, yq, node and tsc, python3 with venv, openziti,
  ziti-edge-tunnel, zrok, nmap, socat, wireguard-tools, and the rest.
- Snaps: go, powershell, aws-cli, htmlq. `/usr/local/bin/cosign`. dotnet lives in `~/.dotnet`.
- `/home/claude` was copied from the old `claude` user in clint's distro on 2026-11-12 (everything but `.cache` and
  `authorized_keys`).

## Keeping it up

`C:\Users\claude\.wslconfig` sets `instanceIdleTimeout=-1` and `vmIdleTimeout=-1`, so the distro and sshd stay up
with nothing attached. Nothing starts it after a reboot. If `ssh agentwsl` says "Connection refused", start it from
the Windows `claude` account:

```powershell
wsl.exe -d agent-ubuntu --exec true
```

## ssh config

Windows `claude` account, `~/.ssh/config`:

```text
Host agentwsl
  HostName localhost
  Port 2223
  User claude
  IdentityFile ~/.ssh/agentwsl_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/known_hosts.agentwsl
```

clint's own `id_ed25519` keys (Windows and his distro) are in `authorized_keys` too, so he can get in with the same
entry minus the `IdentityFile`, `IdentitiesOnly` and `UserKnownHostsFile` lines.

## The catch

The agent's Windows keys in `C:\Users\claude\.ssh` are readable from inside agentwsl (`/mnt/c/Users/claude/.ssh`). Any
of those keys that logs into a box of clint's carries the agent there. The isolation holds only while no agent key
opens a door into clint's account or distro.
