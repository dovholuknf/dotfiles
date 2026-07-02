---
description: Run a Mercurius design review on the given files via the shared MCP server
argument-hint: <file> [file ...]
---

Run a Mercurius review of these artifacts: $ARGUMENTS

Mercurius is a shared, user-scope MCP server reached over HTTP. Drive it as the design agent. Steps:

1. Confirm the `mercurius` MCP tools are available (names like `mcp__mercurius__open_session`). If they are not,
   the shared server is not running. Tell me to start it in a spare terminal and then stop:

   ```
   & "D:\git\github\michaelquigley\mercurius\build.claude\mercurius.exe" `
     --http 127.0.0.1:7337 `
     --config "D:\git\github\michaelquigley\mercurius\mercurius.yaml"
   ```

2. Find the current project root (the absolute path of the directory that holds this project's `mercurius.yaml`,
   normally the repo root). If there is no `mercurius.yaml` there, tell me and offer to create one:

   ```
   & "D:\git\github\michaelquigley\mercurius\build.claude\mercurius.exe" bootstrap
   ```

   Do not proceed without one unless I explicitly say to open the session without a `working_dir` (which falls back
   to the server's launch config and generic calibration).

3. Call `open_session` with `working_dir` set to that absolute project root.

4. Call `start_review_round` with the session id and the artifacts parsed from the arguments: for each path, use the
   file's basename as `name` and its absolute path as `path`.

5. The round runs in the background and can outlast a tool timeout. Run the `monitor_command` returned by
   `start_review_round` as a background command and let it notify you on completion. Do not busy-poll.

6. When it completes, call `collect_round`. Present the result: all blocking findings as a brief overview first,
   advisory notes separately, then walk findings one at a time. For each, compress the finding and its proposed fix
   to the plainest, fewest-words version, present it, and stop for my decision before doing anything. Do not
   implement a fix until I actually respond.

7. After triage, offer to record my decisions with `record_round_notes` (disposition is `fixed`, `rejected`, or
   `deferred`), and to `close_session` when the arc is done (that writes `_synopsis.md`).

If a round fails with `reviewer_failed`, read the cause from `session_status` and tell me plainly rather than
retrying blindly.
