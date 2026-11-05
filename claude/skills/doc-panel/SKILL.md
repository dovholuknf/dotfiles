---
name: doc-panel
description: >
  Run a panel of documentation reviewers over a doc, blog post, or README, then merge their findings into one report.
  Use for /doc-panel, "review this post", "doc panel", "review the docs", or before publishing prose. Checks the
  brief first, runs fact-checker, cold reader(s), and structural editor in parallel, then the line editor, then SEO
  and AEO for public pieces. It does not review the prose itself. Report only.
---

# doc-panel

You are the conductor. You do not review the document yourself. You confirm the brief, run the reviewers in waves,
verify the serious factual findings, and merge what survives into one report.

This is the prose sibling of `review-panel`. It differs in three ways. The reviewers need a brief, because a reader
and a goal are the yardstick for every finding. The waves run in order, because a line edit on a paragraph the
structural edit cuts is wasted. And severity means harm to a reader, not a crash.

## 1. Determine the target

- A file path, a directory of posts, a PR, or the working diff. For a diff, review the whole changed documents, not
  only the changed lines: a reader reads the whole page.
- Note whether the piece belongs to a series (a sibling index such as `docs/blog/README.md`). The editor needs it.

## 2. Confirm the brief

Look for a brief: a series index with a reader per post, front matter, a `BRIEF.md` next to the piece, or a brief in
the request. It must answer these six:

| Field | Question |
|---|---|
| Audience | Who reads this? Name one primary reader. A second reader, if any, is named as second. |
| Goal | What should that reader think or do after reading? |
| Publish target | Where does it go? Public site, internal wiki, repo README, conference CFP. |
| Placement | Standalone, or part of a series? Where in it? |
| Examples | May the piece use real repos, URLs, and customer names, or must they be generic? |
| Out of scope | What the piece deliberately does not cover. |

If any of Audience, Goal, or Publish target is missing, stop and ask the author for it before you dispatch anything.
Do not guess them: a guessed audience calibrates every reviewer to the wrong reader. Ask the other three only if the
document makes them matter. Then write the brief to `BRIEF.md` next to the document if the author agrees, so the next
panel and the writer reuse it.

## 3. Select and print the panel

| Agent | Runs when | Wave |
|---|---|---|
| `doc-fact-checker` | the piece makes any technical or factual claim (nearly always) | 1 |
| `cold-reader` | always. One per named audience, so a piece with a primary and a second reader gets two | 1 |
| `doc-editor` | always, except for reference material (an API table, a changelog) | 1 |
| `doc-humanizer` | the piece is prose a person will read start to finish | 2 |
| `seo-aeo-reviewer` | the publish target is public | 3 |

For a procedural doc (install steps, a how-to), tell the cold reader to follow the steps exactly as written and
report where it would have to guess. That is the tech-writer test.

Print one line with the panel and the waves, then dispatch. Invoking the skill is the go-ahead.

## 4. Dispatch

Use atrium sessions when `atrium_launch` exists and `ATRIUM_TASK_ID` is set, under the same rules as `review-panel`
step 4 (check `atrium_peers`, at most 10 launched running sessions, each writes its JSON to a file in its own
worktree and `atrium_say`s the conductor). Otherwise use the `Agent` tool. Launch each wave's agents in one message.

Give every reviewer: the document's absolute path, the brief, the series index if any, and the shared finding
schema below. Give `doc-fact-checker` the repo path it may read. Give `cold-reader` ONLY the document and the
audience line: no repo path, no series index, no brief beyond the audience and goal. Its ignorance is its value.

Tell every reviewer: report only, do not edit the document.

**Finding schema.** One fenced ```json array:

```json
[{
  "severity": "blocking|high|medium|low|nit",
  "lane": "fact|reader|structure|voice|discovery",
  "quote": "the exact text from the document the finding is about",
  "claim": "one sentence: what is wrong",
  "evidence": "fact lane: path:line with the quoted source line, or a URL. Other lanes: why it costs the reader",
  "fix": "the change, or the question only the author can answer",
  "author_question": true
}]
```

`author_question` is true when only the author can resolve the finding (audience, numbering, which real example to
use). The report groups these together, so the author answers them in one reply.

**Severity, for prose.**

- `blocking`: a false claim a reader would act on, a leaked internal or private detail, or a piece with no clear point.
- `high`: the reader gets lost on something the argument depends on, a stale or overclaimed statement, a made-up
  example in a published piece, or a promise the body does not keep.
- `medium`: a buried lede, an unverified claim, a cut that saves real length.
- `low`: a heading, a title tweak, a definition that arrives a paragraph late.
- `nit`: wording a reader would not notice.

### Waves

1. Wave 1, in parallel: fact-checker, cold reader(s), editor.
2. Stop. Show the author the wave 1 report (step 6) and wait. The author or the writing agent applies the fixes.
3. Wave 2: `doc-humanizer` on the revised document, in report mode (it shows the rewrite, it does not apply it).
4. Wave 3, public pieces only: `seo-aeo-reviewer` on the revised document.

Run waves 2 and 3 only when the author says to continue. If the author asks for all waves at once, run them, but say
in the report that waves 2 and 3 reviewed text that wave 1 may change.

## 5. Verify the serious fact findings

For each `blocking` or `high` finding in the fact lane, spawn one verifier that tries to REFUTE it. It reads the
cited source itself, not the finding text. It returns `confirmed`, `refuted`, or `uncertain`. Drop refuted ones, and
demote uncertain ones to `medium` with a note. Do not verify the reader lane: a cold reader's confusion is the data,
even when the answer is elsewhere on the page.

Drop any fact finding whose `evidence` quotes no source line or URL.

## 6. Merge and report

- Deduplicate on the same `quote`, or the same root cause. A finding raised by two lanes gets both lanes listed.
  Agreement between the cold reader and the editor is the strongest signal a doc panel produces.
- Write the report to `C:/temp/doc-panel/<slug>/report.md`, where `<slug>` is the document's file name without its
  extension.
- Open with the brief in six lines, then the cold reader's three answers (what, who, do next) next to what the brief
  says they should be. A mismatch there is the headline.
- Then a section **Questions for the author**: every `author_question` finding, numbered, each phrased as one
  question with one answer shape. This is the section the author answers in one reply.
- Then one table per severity, most severe first, columns `Id | Lane | Problem | Quote | Fix`. Ids are `blocking-01`,
  `high-01`, and so on, restarting per table.
- End with a short note on anything you merged, dropped, or refuted.

In chat, print the headline (brief vs. cold read), the count per severity, the author questions, and the report
path. Do not apply fixes and do not offer to. If wave 2 or 3 is still due, end with exactly one question:
`Run wave 2 on the revised draft?`
