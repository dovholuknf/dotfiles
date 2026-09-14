---
name: recall
description: >
  Find a past session when the user is lost: "where did I do that thing", "did I ever", "have we done X",
  "find that session", "I'm lost", "what was that thing", "which repo was that in". Greps the recall index
  (D:\worktrees\history\INDEX.tsv) first, then the recap bodies, then transcripts only if needed, and returns
  the matching sessions with their worktree path, recap file, and transcript id. This is the read side of the
  recap skill: recap writes the index, recall reads it. It locates work; it does not modify anything.
---

# recall

The user has lost track of where or when they did something. Find it fast, cheapest source first, and hand back
enough to reopen it: the topic, the repo/branch, the worktree path on disk, the recap file, and the transcript id.

Read only. Never modify a recap, an index line, or a transcript.

## The sources, in order (stop as soon as you have a solid hit)

1. **The index: `D:\worktrees\history\INDEX.tsv`** (git-bash `/d/worktrees/history/INDEX.tsv`). One line per
   recapped session, tab-separated:
   `date  repo  branch  state  reopened  recap-file  transcript-id  keywords`. The `keywords` column is a fat
   grep blob written for exactly this. Search it first:
   ```
   grep -i <term> /d/worktrees/history/INDEX.tsv
   ```
   Try the user's word, then obvious synonyms (a host name, a repo, a bug number, an error string, the plain-English
   phrasing). The keyword blobs are generous, so a good term usually lands here.

2. **The recap bodies** if the index is thin or the user wants detail:
   ```
   grep -ril <term> /d/worktrees/history/*.md
   ```
   Each match is an ~8KB condensed writeup of that session. Read the top `## Keywords` block and the Header to
   confirm, then summarize.

3. **The transcripts** only when 1 and 2 miss, because this is the slow, large source (hundreds of MB):
   ```
   grep -ril <term> /c/Users/claude/.claude/projects --include=*.jsonl
   ```
   Rank candidates by match density before reading. This is also the ONLY source that can find work done inside a
   claude session that was never recapped. It cannot find terminal-only work (that leaves no transcript); if the
   trail runs cold here, say so and suggest checking the box's own shell history / configs.

## What to hand back

For each strong match, one tight row:

- the topic (from the keywords / recap header), plus repo and branch,
- the **worktree path on disk** so the user can `cd` there (from the recap Header, or `D:\worktrees\...` layout),
- the recap file (`D:\worktrees\history\<name>.md`) if one exists,
- the transcript id (`<session-id>.jsonl`) if known,
- state and whether it reopened, when that helps.

If several sessions match, list the top few most-recent-first and let the user pick. If nothing matches anywhere,
say that plainly rather than guessing, and name what you searched.

## After finding it

Offer the next move, do not take it: open the recap, dig the transcript for a specific detail, or `cd` to the
worktree. If the user asks for a detail the recap does not cover, go to that session's transcript and pull it.

## Note the gaps honestly

- Recaps and the index cover claude-code sessions only. Work done in a plain terminal (a manual overlay build, an
  ssh session) leaves no recap and no transcript. When the search comes up empty, say the work may have been
  terminal-only and point at the machine it would live on.
- `transcript-id` is `-` for older backfilled rows; the recap file is still the pointer there.
