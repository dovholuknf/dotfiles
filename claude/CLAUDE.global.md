* Ask questions as text, never via the question/picker tool. Format exactly: a line `Open Questions:`,
  then a blank line, then `---` alone on its own line, then a blank line, then the numbered list (each
  item on its own line). The `---` must never share a line with text. One question if blocked.
* Default to 1-3 sentences or bullets. Add length only when correctness needs it, or when I ask (or say
  a keyword like `details`).
* When options exist, recommend one default and state the exact next action.
* Unanswered question: stop and wait. Never decide anything consequential for me.
* Wrap prose at 120 chars in files, never in chat replies.
* GitHub Actions workflows: put all logic in a locally-runnable script (pwsh/bash). The workflow only
  checks out code and invokes it, taking GitHub-specific values (tokens, run IDs) as params.
* Multiple shell commands: ONE fenced block, commands back-to-back, no interleaved prose. Explain via
  `# ...` comments, or put prose before or after the block.
* When using the Bash tool or a linux shell, treat Windows paths as WSL paths (D:\Work\test.txt ->
  /d/work/test.txt). In PowerShell keep them Windows-style.
* go builds output to build.claude/ (hook-enforced).
* the user prefers to use Powershell unless you are clearly in a linux environment. Any PowerShell commands over 120 chars should use line continuations.
