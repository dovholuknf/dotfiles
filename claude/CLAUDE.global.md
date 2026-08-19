Scope: these govern how you talk to ME in chat. They do NOT constrain prose you author into files,
docs, commits, or PRs. That content follows its own voice and the target repo's conventions. The
"Always" rules are the exception and apply everywhere.

# Chat (how you reply to me)

* Ask questions as text, never via the question/picker tool. Format exactly: a line `Open Questions:`,
  then a blank line, then `---` alone on its own line, then a blank line, then the numbered list (each
  item on its own line). The `---` must never share a line with text. One question if blocked.
* Default to 1-3 sentences or bullets. Add length only when correctness needs it, or when I ask (or say
  a keyword like `details`). This governs replies to me. It never means write terse docs or clipped
  commit prose.
* When options exist, recommend one default and state the exact next action.
* Unanswered question: stop and wait. Never decide anything consequential for me.
* Multiple shell commands: ONE fenced block, commands back-to-back, no interleaved prose. Explain via
  `# ...` comments, or put prose before or after the block.
* Cut filler from replies: hedges, throat-clearing, editorializing adjectives, reflexive sign-offs.
* Reply in a Simplified-Technical-English register: active voice, present tense, one meaning per word,
  plain approved words over jargon, sentences under ~20 words, one instruction per sentence. Prefer this,
  but do not contort meaning to obey it.

# Always (authored content and tooling, every project)

* Wrap prose at 120 chars in files, never in chat replies.
* GitHub Actions workflows: put all logic in a locally-runnable script (pwsh/bash). The workflow only
  checks out code and invokes it, taking GitHub-specific values (tokens, run IDs) as params.
* go builds output to build.claude/ (hook-enforced).
* When using the Bash tool or a linux shell, treat Windows paths as WSL paths (D:\Work\test.txt ->
  /d/work/test.txt). In PowerShell keep them Windows-style.
* Prefer PowerShell unless clearly in a linux environment. PowerShell commands over 120 chars should use
  line continuations.
* When clint changes how I behave (a chat directive, a hook, a permission, or config meant to make me work
  better), append a dated one-line entry to `claude/tuning-changelog.md` with a short why.
