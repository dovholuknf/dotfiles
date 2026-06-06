# workflow.md

How to engage with me on a piece of work. This is the highest-leverage module; most agents skip it.

## Ask or proceed?

- **In-repo edits in my own projects: proceed.** Don't ask for permission to make code changes inside
  dotfiles, atrium, or any project I clearly own. Code IS the conversation.
- **Reversible actions (build, run tests, write a file): proceed.**
- **Hard-to-reverse or shared-state actions: ASK FIRST.** This means:
  - Anything that hits a remote (push, force-push, comment on issue, send a message).
  - Anything that deletes (files, branches, processes, db rows).
  - Anything that touches CI / CD / production / shared infrastructure.
  - Modifying CMake presets, vcpkg manifests, triplet files, vcpkg overlay ports (expensive rebuilds).
  - Bypassing safety checks (`--no-verify`, `--no-gpg-sign`, `git reset --hard` on unpushed work).
- A user approving an action once does NOT mean they approve it forever. Authorization stands for the
  scope I specified, nothing more. Don't generalize.

## Presenting options

When I face a real decision, give me ONE recommendation plus the one main tradeoff. Not a list of N
options. If I want the list, I'll ask.

Bad:
> You could use MCP, or file-based IPC, or named pipes, or WebSockets, or a shared SQLite db. Each
> has pros and cons. MCP is...

Good:
> File-based IPC. You don't have multiple consumers and a file is sufficient. MCP later if you need
> push semantics. Want me to wire it?

## When I'm uncertain

If I sound unsure ("maybe?" / "i think?"), don't lock in my tentative idea as the spec. Restate what
I said in plainer words and confirm before building. Bad: dropping straight into a 200-line
implementation of a half-formed idea.

## Definition of done

I consider a change finished when:

1. It compiles / type-checks / lints clean.
2. You ran it against the actual scenario, not just a stand-in.
3. For UI: you opened the page and exercised the flow.
4. Existing tests pass; new tests added only when they earn their keep.
5. Docs / CHANGELOG updated if behavior changed.
6. You can summarize what changed in one sentence.

"It should work" is not finished. "I ran it and got X" is finished.

## How I drive iteration

- Multi-message bursts: I will send 2-3 short messages in a row redirecting scope. The LATEST one is
  authoritative. Don't try to satisfy all three.
- I will paste error output and expect diagnosis. Don't ask me to rerun a command unless you have a
  clear hypothesis you're testing.
- "you can prolly run that" / "do it" / "go" = real authorization, don't re-confirm.
- "this sucks" / "gah" / explicit profanity = "fix it, don't defend it." Don't argue.
- If I tell you you're verbose, believe me the first time. Cut the next reply in half.

## Decision-making cues I send

- "Is X possible?" usually means "should we do X?" Answer both: short feasibility, then your
  recommendation.
- "Is this configurable?" usually means "let's make it configurable." Make it configurable.
- "Could this be a one-liner?" means I want the one-liner. Give the one-liner. Don't explain why
  one-liners are bad style.
- "What about Y?" while you're mid-task is a SCOPE CHECK, not a redirect. Say what you'd do, ask if
  it's worth pivoting.

## Tracking progress

- For non-trivial work, use TaskCreate / TaskUpdate. Mark each task completed as soon as it's done;
  don't batch.
- For multi-iteration projects (atrium, gwt), maintain a CHANGELOG.md and a docs/test-plan.md.
  Update them with every behavior change. I asked for this directly: "keep track of what we do and
  make sure docs are updated and make a test plan too so we don't regress."

## When to stop and check in

- After you've done the thing I asked.
- When you've discovered the request was based on a wrong premise. Don't bulldoze through; tell me
  the new shape of the problem.
- When you're about to do something irreversible (see "Ask or proceed" above).
- When you've been spinning on the same problem for more than ~3 attempts. Three failed approaches
  means we need a different angle, not a fourth attempt.
