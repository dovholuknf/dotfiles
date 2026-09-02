---
name: atrium-join
description: Put this claude session on the atrium board and start gating its tool calls through it. Invoke when the user says "join atrium", "/atrium-join", "gate this session", "put this on the board", "watch this session", or asks for this session to be supervised by atrium. Takes effect immediately, without restarting the session. Use atrium-leave to undo it.
---

# atrium-join

Registers the session you are running in with atrium, so it appears as a card on the board and its tool calls are
gated: each one waits for the human to approve or block it, unless a standing rule already answers it.

Gating used to be fixed when a session started, from its environment. This works on a session that is already
running, because the permission hook asks the daemon rather than reading its own environment. Nothing restarts.

## Run it

One command. `atrium` is expected on PATH:

```
atrium join --title "<short title>" --why "<why this exists>"
```

The title and the note are the point. The note is what tells the human in a week why this session existed, so
write one from what the session is actually doing rather than asking for it.

Do not search for the binary. No `command -v`, no listing directories, no guessing at a checkout path. If the
command is not found, that is the answer: report it and stop.

```
atrium is not on your PATH. Add the directory holding atrium.exe to it, then run this again.
```

A hardcoded path here would work on exactly one machine and rot the first time the checkout moves.

## What to tell the user

Say what changed, not what you ran:

- The session is on the board now, and every gated tool call waits for them until they answer.
- Requests appear in the perms tab, and as a desktop notification.
- A standing rule that already covers a command answers it without asking.
- `atrium leave` hands the session back and stops gating.

## If it fails

`atrium is not reachable` means the daemon is not running. Tell the user to start it:

```powershell
& "<atrium-repo>/build.claude/atrium.exe" daemon
```

Do not retry in a loop, and do not try to start the daemon yourself. It is a long running process the human owns.

## Notes

- The session identifies itself by `ATRIUM_AGENT_NAME`, falling back to the current directory's name. Two
  sessions in the same directory need `--name` to tell them apart, or they land on one card.
- Joining an already joined session is harmless: it refreshes the card and leaves the gate on.
- Joining revives a card that was previously left, done or shelved, because joining says this session is active
  now.
