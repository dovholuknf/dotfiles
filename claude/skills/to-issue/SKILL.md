---
name: to-issue
description: >
  Turn bug entries written in the experienced/expected format (default bug.md) into GitHub issues. Reads the file,
  works out the target repo per bug (an optional `repo:` line, otherwise it asks), and hands you a ready
  `gh issue create` command per bug to run. Invoke with /to-issue, or when the user says "file these as issues",
  "turn bug.md into issues", "make issues from the bug list". It does NOT create the issues itself.
---

# to-issue

Turn a bug-capture file into GitHub issues. This skill reads the file and produces one `gh issue create` command
per bug, targeted at the right repo, for the user to run. It does not create issues itself.

Creating a GitHub issue is an outward-facing write. This skill stops at surfacing the exact command, per the repo
rule that the user runs every git and gh mutation. Never run `gh issue create` on the user's behalf.

## Input

- Default file: `bug.md` in the current directory. A path argument overrides it, for example
  `/to-issue path\to\bugs.md`.
- Entry format (the same one bug.md uses):

  ```
  ## <short title, under ~20 words>

  experienced: <what happened>

  expected: <what should happen>
  ```

- Optional per-entry repo line, anywhere in that entry's body:

  ```
  repo: openziti/ziti
  ```

  When present, that line is the target repo. When absent, ask (see step 2).

## Steps

1. Read the file. Split into entries at each `## ` heading. The heading text is the issue title. Everything from
   that heading to the next `## ` (or end of file) is the issue body.
2. For each entry, resolve the target repo:
   - If the entry carries a `repo:` line, use it.
   - Otherwise propose one from context (the bug text, or the cwd's `origin` remote) and ask the user to confirm or
     correct it. Do not guess silently, and do not assume every bug targets the same repo. A bug list often spans
     repos.
3. Build the issue body as clean markdown that preserves the experienced/expected content, with the labels bolded:

   ```
   **Experienced:** <what happened>

   **Expected:** <what should happen>
   ```

   Keep it factual. Do not invent any detail the entry does not contain. If the entry has extra lines beyond
   experienced/expected, carry them through verbatim.
4. Present, per bug, a short preview: target repo, title, body. Then the exact command. Put all the commands in ONE
   fenced block so the user can run them together:

   ```
   gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
   ```

5. Stop there. Do NOT run `gh issue create`. The user runs the commands.

## After

- Offer to remove the transcribed entries from the source file once the user confirms the issues were created. Edit
  the file only on an explicit yes.
- If an entry is malformed (no experienced or expected line), flag it and skip it rather than filing a vague issue.

## Notes

- Titles: keep them as written, trimmed of trailing punctuation.
- Check `gh auth status` first. If there is no login, say so before handing over commands that would fail.
- Bodies with characters the shell would choke on: prefer a heredoc or `--body-file`, or note that the user should
  paste the body, rather than producing a command that breaks on quotes.
