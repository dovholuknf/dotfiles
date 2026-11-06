# Set up a doc panel

You are an AI coding agent (Claude Code, or something close to it). Your user pointed you here so you can set up
`/doc-panel` for them, based on how I (clint, github.com/dovholuknf) run mine. Read this whole file first. Then follow
"Setup" in order. Ask your user before you write or overwrite anything.

Everything referenced here is in the public repo https://github.com/dovholuknf/dotfiles. Fetch files from the raw URL
form: `https://raw.githubusercontent.com/dovholuknf/dotfiles/main/<path>`.

## What it is

`/doc-panel` reviews a doc, blog post, or README with several specialist agents, then merges their findings into one
report. It is the prose sibling of `/review-panel` (`claude/setup-review-panel.md`). It differs in three ways:

- The reviewers need a brief. A named reader and a goal are the yardstick for every finding, so the skill asks for
  them before it starts.
- The reviewers run in waves. A line edit on a paragraph the structural edit then cuts is wasted work.
- Severity means harm to a reader, not a crash.

It does not need the review panel. The two share a design: a conductor skill, specialist agents, one finding schema,
a verify pass on the serious findings, and one merged report.

## The agents

Each file in `claude/agents/` is a Claude Code subagent definition: YAML frontmatter, then a system prompt.

| Agent | Lens | Wave |
| --- | --- | --- |
| `doc-fact-checker` | every factual claim checked against the code, config, and sources it describes | 1 |
| `cold-reader` | reads as the target reader would, with no access to the repo, and reports where it gets lost | 1 |
| `doc-editor` | structure: one clear point, the opening, the order, what to cut, the title and ending | 1 |
| `doc-humanizer` | line edit into a natural human voice, stripping LLM tells | 2 |
| `seo-aeo-reviewer` | findability by search engines and quotability by AI answer engines, public pieces only | 3 |

The cold reader's ignorance is its value. The skill gives it only the document and the audience line. Keep it that
way when you adapt the files: do not give it repo tools.

## How `/doc-panel` works

Source: `claude/skills/doc-panel/SKILL.md`. Read it in full. The short version:

1. **Target.** A file, a directory of posts, a PR, or the working diff. For a diff it reviews whole documents, because
   a reader reads the whole page.
2. **Brief.** It looks for a brief (front matter, a `BRIEF.md` next to the piece, a series index, or the request). If
   the audience, the goal, or the publish target is missing, it stops and asks. It does not guess them.
3. **Select.** It prints one line with the panel and the waves, then dispatches. Invoking the skill is the go-ahead.
4. **Wave 1.** Fact-checker, cold reader (one per named audience), and editor, in parallel.
5. **Verify.** One verifier per `blocking` or `high` fact finding, told to refute it from the cited source. A fact
   finding that quotes no source line or URL is dropped.
6. **Report.** One `report.md`. It opens with the brief next to the cold reader's answers to "what is this, who is it
   for, what do I do next". A mismatch there is the headline. Then "Questions for the author", then one table per
   severity with stable ids (`high-01`).
7. **Waves 2 and 3.** Only when the author says to continue, on the revised draft: the humanizer, then SEO and AEO for
   public pieces. It reports only. It never edits the document.

## Setup

Do these in order. Show your user the plan (steps 1 to 3) before you write any file.

1. **Find their config dir.** It is `~/.claude/` on macOS and Linux, and `%USERPROFILE%\.claude\` on Windows. List
   `agents/` and `skills/`. If a file with the same name exists, ask before you overwrite it.
2. **Fetch the files.**
   - `claude/skills/doc-panel/SKILL.md`
   - `claude/agents/doc-fact-checker.md`, `claude/agents/cold-reader.md`, `claude/agents/doc-editor.md`
   - Optional: `claude/agents/doc-humanizer.md` (wave 2) and `claude/agents/seo-aeo-reviewer.md` (wave 3). Ask your
     user whether they want each one. If they skip one, delete its row and its wave from the skill.
3. **Adapt them to your user.** These edits are required. The files carry my paths and my tools.
   - In `doc-panel/SKILL.md`, step 4: delete the atrium paragraph and keep the `Agent` tool path. "atrium" is my
     private orchestrator. Your user does not have it. Delete every atrium reference without asking.
   - In `doc-panel/SKILL.md`, step 6: change the `C:/temp/doc-panel/<slug>/` output dir to one your user picks. Ask
     them.
   - In `doc-editor.md`, "Respect the author" points at `voice-clint.md`, my private voice notes. Delete that
     sentence. If your user has their own voice or style guide, point at it instead.
   - In `doc-humanizer.md`, delete the step that reads `voice-clint.md`, or point it at your user's style guide.
     Replace the "Memory lives at `C:\Users\claude\.claude\agent-memory\doc-humanizer\`" path with
     `<their config dir>/agent-memory/doc-humanizer/`, or delete that paragraph and the `memory:` line.
   - The `model:` line pins a model per agent. Keep the fact-checker and editor on the strongest model your user has.
     Change the rest to suit their plan.
   - Search every fetched file for `D:\`, `C:\`, `clint` and `dovholuknf`, and resolve each hit with your user.
4. **Write the files.** Agents go in `~/.claude/agents/`. The skill goes in `~/.claude/skills/doc-panel/SKILL.md`.
5. **Verify.** Your user restarts Claude Code. `/agents` lists the new agents. `/doc-panel` shows up as a slash
   command.
6. **Smoke test.** Run `/doc-panel README.md` on a repo your user knows. Check that it asks for the brief (or reads
   one), prints the one-line panel, runs wave 1, and writes `report.md` with the cold-read headline and the author
   questions. Then answer "continue" and check that wave 2 runs on the current file.

## Cost and tuning

- Wave 1 is three or more agents plus a verifier per serious fact finding. For a quick look, ask for the cold reader
  alone. It reads only the document, so it is the cheapest agent.
- Write the brief to `BRIEF.md` next to the document when the skill offers. The next run, and the writer, reuse it.
- When the panel reports something wrong, fix the agent or the skill, not the report.
