---
name: atrium-batch
description: >
  Run a batch of atrium backlog items as atrium workers, one per room, then review, land, deploy and write one
  evaluated report. Invoke when the user says "/atrium-batch", "do the next N", "pick N tasks and do them", "tackle the
  next five", or hands the orchestrator a list of backlog items to build while they are away. Takes an optional count
  (default 5) and optional item ids. Not for a single small fix: launch one worker for that.
disable-model-invocation: true
---

# atrium-batch

The orchestrator picks work, dispatches it, judges it, lands it and reports. It never writes the code itself.

Arguments: `/atrium-batch [N] [item ids...] [--for <minutes>]`. N defaults to 5. Named ids are taken first, the rest
are picked. `--for` defaults to 60: when the batch finishes early, keep going with design work or high bugs and
features until that much time has passed or the user returns.

## 1. Pick

- `atrium_backlog list open:true priority:high`, then `get` each candidate. Take items that are MEATY (more than a
  one-liner) and WELL SPECIFIED: a stated cause or repro, a fix direction, and a "done when".
- Check each against git before taking it: `git log --oneline -i --grep <keyword>` and a grep of the code it names.
  Backlog status lines go stale. An item already landed is closed, not dispatched.
- Fold a one-line item into a related meaty one (same files, same machine) instead of spending a worker on it.
- An item with open design questions goes to a design worker first. The design worker decides them and records why.
- Present the pick before launching ONLY when the user is present and asked to see it. Otherwise launch.

## 2. Place: one worker per room

- `atrium_resources` for the rooms. One worker per room at a time. Check each room's tools before placing (ssh it:
  `Get-Command go,node`). A room with no Go or Node takes design-only work.
- Board (Playwright) work needs a room with playwright in some node_modules. Point NODE_PATH at it in the brief.
  Never a symlink. A board run that prints "skipped" is not a pass.
- Make the worktree on the room first, on a `claude/<item-slug>` branch from the landed tip. The hook blocks git
  fetch over ssh, so create it from the room's local branch and let the worker `git fetch hub && git reset --hard
  hub/claude/main`.

## 3. Model per kind of work

| work | model | effort |
| --- | --- | --- |
| design with decisions, a phased plan | opus | default |
| implementation from a clear spec or a design doc | sonnet | low |
| small scoped UI or test fix with named files and units | haiku | low |

A design that ends with a plan gets a build worker (sonnet low) on the same room once it is reviewed.

## 4. Brief

`atrium_launch` with `brief` (written to BRIEF.md) and `prompt: "Read BRIEF.md and do the whole job it describes,
through atrium_reports and atrium_done."`. Tags `atrium:impl` or `atrium:design`, plus `atrium:subagent`. Theme
`active-work`. Workers cannot read the backlog: PASTE the item body into the brief. Every brief carries:

1. **Setup.** `date` as T_START, `git fetch hub && git reset --hard hub/claude/main`, read AGENTS.md.
2. **The item**, pasted, with its id and who asked and why.
3. **How.** Reproduce first and commit the failing test. Then fix. Then prove with only the touched tests:
   `go test -tags "integration git" -count=1 -run '<names>' ./internal/<pkg>`, or
   `node scripts/test-board-sharded.js --local --units <units>`. Never check-board.sh. A test that also fails on
   hub/claude/main is noted, not fixed.
4. **Rules.** One-line commits, no body, no trailer. Never touch schema.go unless the plan says so, and then append
   at the end. Ship notes in `changelog/<dept>/<date>-<slug>.md` and `docs/changes/<slug>.md`. Never CHANGELOG.md
   or docs/test-plan.md. `git push hub <branch>`. Never ask where to push.
5. **Finish.** REPORT.md (not committed): SHA, cause, fix, tests and pass counts, wall time, tokens incl cache from
   the worker's own transcript (newest `~/.claude/projects/*<worktree>*/*.jsonl`, assistant entries, dedupe by
   message.id, sum input, cache creation, cache read and output tokens), slowest part, what would have been faster,
   and a self-evaluation: how sure, what is still risky. Then `atrium_reports add` to "reports" with the same facts,
   then `atrium_done <sha>` or `atrium_blocked <one line>`.

The user is away: every brief says "do not ask him anything, decide and record why".

## 5. Watch

Right after each launch: `bash /d/tmp/memtrim/watch-card.sh <room~card>` in the background. It wakes the
orchestrator when the card stops. Check `atrium_task` on any card that comes up `needs-input`.

## 6. Review and land

On each done:

- `git fetch hub`, read the commits, the diffstat and REPORT.md. Read the diff of anything that touches the store,
  gitsync, the permission chain or a resilience rule.
- Take code commits only. Cherry-pick or fast-forward onto claude/main. BRIEF.md and REPORT.md never land.
- Rerun the touched tests on this machine (a different OS from the worker's when possible). Build with
  `go build -o build.claude/ ./...` and vet the touched packages.
- `git push hub claude/main`, then deploy: `atrium-deploy.ps1 -Rooms hub` for board-only changes, `-Rooms all`
  when room code changed. Busy rooms are held by the script.
- Say `ledger` to @minion so the work ledger gets the row.
- Then place the next item on the room that just freed up.

## 7. Report

One file, `notes/REPORT-<date>-<slug>.md`, when the batch is over:

- A table per worker: model, room, wall time, tokens incl cache, result, landed SHA.
- Per item: cause, verdict, fix, time, tokens. For test items, judge each test good or bad and say why.
- An evaluation per worker: was the result right, what did review catch, what is unproven.
- What would make the next batch faster.

Tell the user in chat: what landed, what did not and why, and the file path.
