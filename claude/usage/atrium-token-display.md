# Handover: show per-turn token use and cache misses in atrium

This is a brief for an atrium build. The dotfiles status line (`claude/statusline-command.sh`, the `turn_tokens`
function) already computes these numbers for one session in one terminal. atrium sees every session, so it can show
them on the board, across sessions, and over time. Everything below comes from the local transcript files. Nothing
needs an API call.

## Why this exists

This came out of a conversation with clint on 2026-10-20. His status line read:

```text
D:\git\github\dovholuknf\dotfiles (main) [Tue Oct 20, 09:09:59]  | 5h 11% (3h30m)  | wk 18%  | ctx 32009/400000 sweet  | tx 301K
```

He asked whether it should show more token detail: input and output, cache in and cache out. The conversation went
like this:

1. **The token segment was there but invisible.** The status line already had a per-turn segment
   (`prompt <read> <written> <out>`), but a jq escaping bug made it fail without a trace, so he had never seen it.
   Once fixed, it showed `prompt 652k 14k 5k`.
2. **The bare numbers did not explain themselves.** He had to ask what they meant ("describe"). Three unlabeled
   figures are not readable at a glance.
3. **It was not obvious which turn they belonged to.** He asked "so that is from the LAST prompt?" The counter
   resets on each prompt, so between turns it shows the turn that just finished. The display has to make that
   scope clear.
4. **He could not tell cache hits from misses.** He asked "but i can't tell what was cache hit or not?" The read
   figure is all cache hits (uncached input is about 2 tokens per call). A miss shows up as a large write, which the
   bare numbers hide. That led to the red miss marker in the status line.

What he wants to see, in his terms:

- What the last turn cost, and why: many calls, a big context, or a cache miss.
- Whether the cache hit, without doing arithmetic on three numbers.
- Labels or layout that make each number self-explanatory, and make clear which turn it covers.

The status line is one session in one terminal. atrium shows every session on one board, so it is the better place
to make this readable and to compare sessions.

## What to show

Per session, for the current turn and for each finished turn:

| Field | Meaning | Source per API call |
|---|---|---|
| read | Context sent again from cache | `cache_read_input_tokens + input_tokens` |
| written | Tokens added to the cache | `cache_creation_input_tokens` |
| out | Generated tokens, thinking included | `output_tokens` |
| calls | API calls in the turn | count of distinct `message.id` |
| misses | Calls that re-wrote the context | `cache_creation_input_tokens > cache_read_input_tokens + input_tokens` |

A turn is everything from one user turn to the next. Sum each field over the turn's calls.

Example from a live session on 2026-10-20. One turn with 14 tool calls showed `read 652k, written 14k, out 5k`. The
next turn, one reply with no tools, showed `read 46k, written 885, out 523`. The context was about 45k both times. The
read figure is roughly calls x context size, so the number of calls per turn drives it.

## Where the data lives

- Transcripts: `~/.claude/projects/<project-folder>/<session-id>.jsonl`, one JSON object per line. The status line
  payload also carries the path as `transcript_path`.
- Each assistant entry has `message.id` and `message.usage` with `input_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens` and `output_tokens`.
- Subagent calls live in their own transcripts (under a `subagents` folder, or entries with `isSidechain: true`).
  The status line leaves them out. atrium may want them as a separate figure.

## Counting rules

These are the rules the status line and `Get-TokenReport.ps1` use. Follow them so the numbers agree.

1. **Merge streamed entries by `message.id`.** A streamed reply writes one transcript entry per content block, and
   each repeats the usage. Take the max of each field per id. Summing the entries double-counts.
2. **Turn boundary.** A user entry starts a turn when it is not `isMeta`, not `isSidechain`, and its content is
   either a string that does not start with `<local-command` or `<bash-`, or an array with at least one `text` block
   and no `tool_result` block. Tool results are not turn boundaries. atrium peer messages and background task
   notifications do start a turn. `Get-TokenReport.ps1` labels the kind (`prompt`, `notification`, `atrium`,
   `resume`, `subagent`), and atrium should show that label.
3. **Read incrementally.** Keep a byte offset per transcript and parse only new lines. Hold the last, possibly
   still-streaming id apart and merge it by max until a new id appears. A partial last line is not consumed.
4. **Cache miss.** Claude Code caches the whole prompt prefix, so uncached `input_tokens` stays at a few tokens per
   call (2 in every call checked). A miss does not show up as uncached input. It shows up as a large cache write:
   the whole context is written again. The status line flags a call when it writes more than it reads. That catches
   TTL expiry (idle past 5 minutes or 1 hour, depending on the cache TTL) and model or effort switches. One false
   positive: a large tool result early in a session, while the cached context is still smaller than the result.
   `Get-UsageReport.ps1` uses a stricter rule (a write after a gap longer than the TTL is a "cold wake", and a write
   of 20k or more with no gap is a "context jump"). atrium has timestamps, so it can use the stricter rule.

## Weighting

Raw token counts mislead because the classes cost different amounts. At list prices, relative to base input:
a cache read costs about 0.1x, a cache write (5 minute TTL) 1.25x, a cache write (1 hour TTL) 2x, and output 5x. For
the 14-call turn above, that is about 65k for reads, 18k for writes and 25k for output, in input-token equivalents.
The read figure looks dominant in raw tokens but is not. The exact table, with its source and fetch date, is
`$UsagePrices` in `claude/usage/UsageCommon.ps1`. Show a weighted total next to the raw figures, or sort by it.

## Display ideas, ranked

1. **Session card: last turn.** `read / written / out`, a calls count, and a red miss badge with the count. This is
   what the status line shows, but for every session at once.
2. **Miss alert.** A miss that costs a full context write on a large context is the single most avoidable cost. On
   a session with 300k of context, one miss writes 300k at 1.25x. Show it on the board when it happens, with the idle
   gap that caused it.
3. **Per-turn history for a session.** A small table or sparkline of the weighted total per turn, with the kind
   label. It shows which turns were expensive and why: many calls, a big context, or a miss.
4. **Room or fleet totals.** Weighted total per session over the last hour or day. It answers "which session is
   burning the meter".

## Pitfalls found while building the status line

- On this box, msys `jq` gets `"\\s"` in a regex as `"\s"` and fails to compile (`Invalid escape`). The status line
  swallowed the error and the segment silently disappeared. Use `[[:space:]]` and other POSIX classes, or keep the
  program in a file. Do not hide parse errors without a visible fallback.
- An empty first field in a tab-separated `read` collapses, because tab is IFS whitespace, and shifts every later
  field. Real payloads always carry a cwd, but synthetic test input without one gives wrong numbers.
- The first look at a large transcript should start near the end (the status line starts 4 MB back). A
  multi-hundred-MB transcript otherwise stalls the first render.

## Reference implementations

- `claude/statusline-command.sh`, `turn_tokens`: incremental, one session, current turn only.
- `claude/usage/PromptScan.cs` and `Get-TokenReport.ps1`: every session, every turn, with kinds, waits, and an
  evaluation. `Get-TokenReport.ps1 -Json` emits one row per prompt and is the quickest way to prototype a view.
- `claude/usage/README.md`: the counting rules in full.
