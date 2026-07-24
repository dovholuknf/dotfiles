---
name: pr-body
description: >
  Write a PR description (or commit-message body) in the user's voice: a short story to the reviewer,
  motivation first, delivered as clean copy-pasteable plain text. Invoke when the user wants a PR body,
  PR description, commit body, or says "pr body", "make it a story", "write the PR message", "make it
  human". Reshapes/authors the prose; it does not open the PR.
---

# pr-body

Write the PR description as a short story told to the reviewer. Lead with why, then what changed, then
what it does now. The reviewer should understand the motivation before the mechanics.

## Voice

- Tell it as "this was broken / limited, so we changed it, which now does X." Cause then effect.
- Plain and human. No marketing ("improves", "streamlines", "robust"), no hype, no bullet dump unless a
  list genuinely reads better than sentences.
- Short. Two or three tight paragraphs is usually the whole thing. Cut anything the reviewer already
  knows from the diff.
- Name the concrete moving parts (file names, the one workflow, the job) so a reviewer can find them.
- End with the issue link on its own line if there is one (`Part of #83.`).

## Output format (this is what keeps burning the user)

- Output the body as ONE fenced code block containing ONLY the body text, so it copies out verbatim.
- Do NOT use a markdown blockquote (`>`), and never a `▎` gutter or any leading decoration. Those are
  not part of the text and make the body impossible to select cleanly.
- Plain ASCII punctuation only. Never the em-dash character (U+2014), never a double-hyphen `--` as a
  dash, never a semicolon in prose. Rewrite: split the sentence, or use a comma, parentheses, or a colon.
- Never a `Co-Authored-By:` trailer and never a "Generated with ..." footer. Not in the body, not in any
  commit block you hand over. This is absolute.
- No preamble around the block ("here's a more human version"). Just the block.

## Handing it over

- Default to just the pasteable body block. The user usually wants to paste it themselves.
- Only if they ask to open the PR, add a SEPARATE fenced block using a here-string so the multi-line
  body survives PowerShell, following the user's shell rules (one block, no interleaved prose):

  ```
  $body = @'
  ...body text...
  '@
  gh pr create --repo <org/repo> --base <base> --head <branch> --title "<title>" --body $body
  ```

- A commit-message body is the same voice and the same rules, just usually shorter.
