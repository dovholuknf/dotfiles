---
name: breakdown
description: >
  Walk the user through a task ONE step at a time, waiting for them to confirm each step before giving
  the next. Invoke when the user wants a guided walkthrough, a runbook to follow live, or says
  "breakdown", "break it down", "walk me through", "step me through", "how do I". Interactive: it paces
  the current session; it does not delegate or research.
---

# breakdown

Guide the user through the task interactively, ONE step per turn. Never dump the whole list. Present a
single step, stop, and wait for the user to tell you they finished it before you give the next one.

## The loop

1. On the first turn, if there is a real prerequisite (a tool to install, a value to have on hand, gear
   to gather), state it in one line prefixed `Before you start:`. Skip it when there is none.
2. Give exactly ONE step: its number, the imperative action, and one line of why or what to watch for.
3. End the turn with a short prompt telling the user what to reply when they are done (for example
   `Tell me when the oven hits 350.` or just `Say "done" when that's set.`). Then stop and wait.
4. When the user replies (any acknowledgment: "done", "k", "ok", a result), give the NEXT single step
   the same way.
5. On the final step, say it is the last one and do not ask them to confirm to continue. Close with a
   one-line "that's it" only if it adds something (the finished result, a check they can do).

## Rules

- One step per message. If you catch yourself writing step N and step N+1 in the same turn, cut N+1.
- Keep the step to one or two lines. If it needs a paragraph, it is really two steps: give the first,
  wait, then give the second.
- Track where you are from the conversation. If the user says a step failed or asks a question, answer
  it and re-give the SAME step, do not advance until they clear it.
- If the user says "just give me all of it" (or similar), drop the pacing and list every remaining step
  at once. Their ask overrides the one-at-a-time default.
- No preamble on any turn ("here's the next step"). Lead with the step number.

## Shell commands (honor the user's standing rules)

- When a step is a command to run, put it on its own line in a fenced code block under the step prose.
- If a single step needs several commands run in sequence, use ONE fenced block with the commands back
  to back and inline `# ...` comments, not multiple blocks.
- Never chain with `;`, never `cd /path && cmd`, never suggest mutating git commands (the user runs
  those). Hand over the command; do not run it.

## When to push back instead

If the next step depends on a decision the user must make first (A vs B), do not guess. Ask the one
blocking question, then continue the walkthrough from their answer.
