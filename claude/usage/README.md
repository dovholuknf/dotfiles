# claude/usage

Find out what burns the weekly Claude usage meter. Everything here reads local files and sends nothing anywhere.

Anthropic does not publish how the weekly meter is calculated. These scripts price every API call in the local
transcripts at public list prices (the "API-equivalent cost") as a proxy, and fit the real meter against that cost
once the status line has logged enough of it.

## Pieces

| File | What it does |
|---|---|
| `../statusline-command.sh` | Appends a sample to `~/.claude/usage-log.jsonl` when a session's 5h or 7d percent changes, else at most once a minute |
| `UsageCommon.ps1` | Price table (with its source), the transcript scanner, the weekly window. Dot-sourced by the others |
| `Get-UsageReport.ps1` | Markdown report of tokens and cost: per day and hour, the top day, baseline, models, cold wakes, context size |
| `Get-TokenReport.ps1` | Markdown report of tokens per prompt: the costliest prompts, the worst turns by kind, and an evaluation |
| `PromptScan.cs` | The scanner behind `Get-TokenReport.ps1`: charges each API call to the prompt before it |
| `Get-BurnFit.ps1` | Fits the logged meter against cost, then predicts when the week hits 100% and how many calls fit |
| `Test-BurnFit.ps1` | Builds a synthetic meter with known weights and checks that the fit recovers them |

## The usage log

The status line writes one JSON line per sample to `~/.claude/usage-log.jsonl`: time, session id and name, model
id and name, effort, cwd, both rate-limit percents and reset times, context used and size, the current call's usage,
the session `cost` and `prompt_cache` blocks, and the transcript path. Per-session throttle state lives in
`~/.claude/usage-log.state/`. The logger uses only bash builtins (plus a one-time `mkdir`), adds no process to the
render, and swallows every error. It adds about 15 ms per render.

Check it by hand:

```powershell
Get-Content -Raw ~/.claude/statusline-payload.json | bash ./claude/statusline-command.sh
Get-Content ~/.claude/usage-log.jsonl -Tail 1
```

## Get-UsageReport.ps1

```powershell
./Get-UsageReport.ps1                                   # current weekly window, to stdout
./Get-UsageReport.ps1 -Hourly -OutFile week.md          # add the per-hour table
./Get-UsageReport.ps1 -From 2026-09-20T18:00 -To 2026-09-27T18:00 -Top 12
```

The default window ends at the next weekly reset. It comes from the newest `seven_day.resets_at` in the log, or the
sample payload, rolled forward in 7-day steps. It takes about 10 seconds for a week of transcripts.

How it counts:

- One record per API message. Streamed responses write one transcript entry per content block, each repeating the
  usage, so entries merge by `message.id`: max per field, earliest time. The merge is global, so a resumed session
  that copies history into a new file is not counted twice.
- Subagents are entries under a `subagents` folder or with `isSidechain`. Their type comes from
  `attributionAgent`.
- A stream is one conversation: a main session, or one subagent in it. The gap is the time since the previous call
  in the same stream.
- A cold wake is a cache write after a gap over 5 minutes (5m TTL) or over 1 hour (1h TTL). A context jump is a
  write of 20k+ tokens with no gap, which is a large tool result landing in context. It is attributed to the tools
  of the previous call.
- Baseline is the full input of a stream's first call. Streams that started before the window (resumes) are left
  out. The saving from a baseline X tokens smaller takes X off each call's cache reads first, then its writes, then
  its uncached input. That undercounts cold wakes a little, because a wake re-writes the whole prefix.
- "Compact at N" is the cost of every token above N on every call. It is an upper bound: it ignores the compaction
  call and any re-reading it causes.

## The prompt segment

The status line ends with `prompt 123k 9k 12k`: the tokens every API call since your last prompt re-read from
context, wrote to cache, and output. It grows while the turn runs and resets when you send the next prompt, a
background task wakes the session, or an atrium message arrives. Output includes thinking, so a short reply can
show hundreds of tokens.

It reads the transcript incrementally. `~/.claude/usage-log.state/<session>.turn` holds the byte offset already
read and the running totals, so a render with no new transcript lines starts no process, and a busy one runs
`tail` and `jq` over the new lines only. The first render of a large transcript starts 4 MB from the end. Subagent
calls live in their own transcripts and are not counted.

## Get-TokenReport.ps1

```powershell
./Get-TokenReport.ps1                                   # last 7 days, to stdout
./Get-TokenReport.ps1 -Days 1 -Top 20 -OutFile today.md
./Get-TokenReport.ps1 -Project '*atrium*'               # one project, by folder-name wildcard
./Get-TokenReport.ps1 -Json                             # one row per prompt, for other tools
```

It takes about 15 seconds for a week. Everything is in tokens, not dollars. A prompt's total is the sum over its
calls of input, cache writes, cache reads and output, so the context re-read on every call dominates.

How it counts:

- A turn starts at a user entry that is not a tool result, injected context (`isMeta`) or local command output.
  Its kind is `prompt` (typed, or a slash command), `notification` (a background task finished), `atrium` (a peer
  message), `resume` (a compaction summary) or `subagent` (the task a subagent got).
- Every assistant call after it, up to the next turn, is charged to it. Calls merge by `message.id` like
  `UsageScan`, and a call copied into a resumed session counts once, in the first file that holds it.
- Visible output is the characters of text and tool input a call wrote. Output tokens beyond about a quarter of
  that are thinking.
- A wait is a call to `TaskOutput`, `BashOutput` or `Monitor`, a command with `sleep`, `Start-Sleep` or an `until`
  loop, or a read of a background task's `.output` file.

The evaluation applies fixed thresholds and sorts findings by the tokens they cover. Findings overlap, so their
shares add to more than 100%.

## Get-BurnFit.ps1

```powershell
./Get-BurnFit.ps1                                       # fit on the log, predict from the newest percent
./Get-BurnFit.ps1 -CurrentPct 98 -Model claude-opus-5-5,claude-sonnet-5
./Get-BurnFit.ps1 -RateHours 6 -MinDelta 2
```

It cuts the log into intervals where the 7-day percent rose by at least `-MinDelta`. For each interval it sums
the transcript cost, then fits by least squares through the origin:

- **A**: one weight, percent per dollar.
- **B**: one weight per model. This fit answers "does Opus X burn the meter faster than Opus Y per dollar".
- **C**: one weight per token class (input, cache write, cache read, output).

Prediction: it uses fit A once it has 10 or more intervals. Until then it uses a single point: the current percent
divided by the cost since the window opened. From that weight it gives the dollars left, the time of 100% at the
recent rate, and the calls left per model at this window's average cost per call.

### How much data the fit needs

- The meter is a whole percent, so each interval has up to 1 point of rounding error. Intervals of 1% are mostly
  noise one at a time. The fit only settles after dozens of them.
- A needs about 10 intervals, which is roughly a day of normal use. B needs about 10 intervals per model, and the
  models have to vary independently: days that mix models, not one model per day. That takes most of a week.
- C is the hardest. The token classes rise and fall together, so they are collinear. On the synthetic test, with
  94 clean intervals, C still gave output a weight of zero. Treat C as unreliable until the log holds several weeks
  of mixed work.
- Every fit assumes the meter counts only Claude Code on this machine. Usage from claude.ai or another machine
  shows up as unexplained rises and pulls every weight up.

`Test-BurnFit.ps1` builds a meter from this week's transcripts with Opus 5.5 weighted 1.5x, rounded to whole
percents like the real meter. Fit B recovers 0.0676 %/$ for Opus 5.5 (expected 0.0682) and 0.0446 to 0.0451 for the
rest (expected 0.0455).

## Prices

The price table is `$UsagePrices` in `UsageCommon.ps1`. It comes from
<https://platform.claude.com/docs/en/about-claude/pricing>, fetched 2026-09-27. A model missing from the table is
listed as UNPRICED in the report and counted as $0. It is never guessed. Fast mode uses its own input and output
prices, with the cache multipliers applied on top.
