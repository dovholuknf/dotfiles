---
description: Grant + verify Docker access for this session
---
Docker should now be available. Do this:
1. Run `docker version` to confirm it's on PATH.
2. If it works: add `"Bash(docker:*)"` to the `permissions.allow` array in
   `.claude/settings.local.json` (create the file/array if missing) so you never
   prompt me for docker again this session, then use docker freely.
3. If `docker` is "command not found": PATH was frozen at launch — tell me to
   either restart Claude, or give you the install dir so you can prefix
   `PATH=<dir>:$PATH` on docker calls.
