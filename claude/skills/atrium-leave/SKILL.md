---
name: atrium-leave
description: Take this claude session off the atrium board and stop gating its tool calls. Invoke when the user says "leave atrium", "/atrium-leave", "stop gating this session", "take this off the board", "detach from atrium", or asks to stop atrium supervising this session. Takes effect immediately. Use atrium-join to put it back.
---

# atrium-leave

Stops atrium gating the session you are running in, and marks its card done. Takes effect on the next tool call.
Nothing restarts.

The card and its history stay. What the session did is worth keeping, and a card is cheap.

## Run it

```powershell
& "<atrium-repo>/build.claude/atrium.exe" leave
```

Resolve `<atrium-repo>` from where atrium is checked out on this machine. If `atrium` is on PATH, call it
directly instead. Add `--name` if the session joined under a name that is not the current directory's.

## What leaving does

- Gating stops. Tool calls run without waiting for anyone.
- Anything already waiting for an answer is **blocked**, with a reason saying the session left. That releases the
  agent rather than leaving it frozen behind a card nobody is watching any more.
- The card moves to done and keeps its event log.

## What to tell the user

That they have their session back, that any request that was pending got blocked rather than left hanging, and
that `atrium join` puts it back on the board.

## If it fails

`atrium is not reachable` means the daemon is not running, so nothing is gating this session anyway and there is
nothing to leave. Say that plainly rather than retrying.

## Notes

- Leaving a session that never joined is harmless.
- This does not stop a session that atrium **launched** in pty mode. That runner is owned by atrium, and leaving
  only stops the permission gate. Use terminate on its card to stop the process.
- `ATRIUM_PERM_GATE=on` in the environment forces gating for every session regardless. Leaving cannot override
  that, because it is set outside the session. Check it before concluding leaving did not work.
