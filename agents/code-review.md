# code-review.md

How I want code reviewed -- both when I give a review and when I receive one.

## When you're reviewing my code (or code I asked you to review)

- Be honest. Don't soften criticism to be polite. "This will break under X" is more useful than
  "Have you considered X?"
- Focus on the change, not the surrounding codebase. If the surroundings need work, say "out of scope
  for this PR but worth a follow-up." Don't expand the PR's scope by demanding adjacent cleanups.
- Prioritize: real bugs > correctness > performance > style. Don't lead with bikesheds. If something is
  pure preference, mark it `(nit:)` so I can ignore it without offense.
- Look for what's MISSING, not just what's wrong with what's there. The most common review failure is
  approving a PR that should have had an additional test, an additional path, or an additional
  consideration that wasn't on the diff.
- Run the code if you can. A review based on reading is weaker than a review that includes "I checked
  out the branch and ran <thing>."
- For Go: look for shadow variables, unwrapped errors, missing context propagation, goroutine
  lifecycle bugs (leaks on early return), io.Reader / Closer hygiene.
- For PowerShell: check for `$Args` collisions, hardcoded path literals, `Get-CimInstance` in tight
  loops, missing error handling at boundaries (file IO, network).
- For shell: shellcheck-grade issues. Unquoted expansions, missing `set -euo pipefail`, race-prone
  patterns.

## When I'm receiving a review

- I take criticism well. Don't sugar-coat for me.
- If a reviewer is wrong, I'll say so directly and explain the constraint they missed. That's not
  disrespect; that's part of the conversation.
- If a reviewer flags 5 things and 4 are taste, I'll fix the 4 anyway because resolving review faster
  is usually worth it. The 5th I'll push back on if it's wrong.
- "Out of scope" is a legitimate response. Land the targeted fix; file an issue for the rest.

## Review comments you can give on my behalf

When you're drafting a review I'll post:

- Tight. Each comment is a sentence or two. No essays.
- Refer to specific files / lines / functions. Don't say "this code"; say `path/file.ext:42`.
- Suggest a concrete change, not a vague "consider X." If you want a change, say what the change is.
- Don't pretend to be polite. If a thing is broken, just say it's broken. Don't add "Awesome work
  overall!" at the end.

## Anti-patterns I push back on

- "Just in case" exception handlers that swallow real errors. The right answer is usually to let it
  propagate or fix the cause.
- New configuration knobs for hypothetical needs. Add the knob when the second use case shows up,
  not before.
- Generated-code edits. If you see hand-edits in a generated file, that's the review comment.
- Feature flags for things that have one caller you control. Just change the call site.
- Comments that explain what well-named code already explains. Delete the comment, rename the
  identifier if needed.
- "I'll address this in a follow-up." Maybe. Track it in an issue NOW, not a verbal commitment. If
  it doesn't get an issue number, it doesn't exist.

## Approving vs requesting changes

- "Approve with comments" if the comments are taste-level.
- "Request changes" if there's a real bug or a missing test the change actually needs.
- Don't approve a PR you didn't read just because it's small. Read every line.
