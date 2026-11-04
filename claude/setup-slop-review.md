# Set up a slop review

You are an AI coding agent (Claude Code, or something close to it). Your user pointed you here so you can set up
`/slop-review` for them, based on how I (clint, github.com/dovholuknf) run mine. Read this whole file first. Then
follow "Setup" in order. Ask your user before you write or overwrite anything.

Everything referenced here is in the public repo https://github.com/dovholuknf/dotfiles. Fetch files from the raw URL
form: `https://raw.githubusercontent.com/dovholuknf/dotfiles/main/<path>`.

## What it is

`/slop-review` is an interactive self-review of an AI-authored branch, run before a human reviewer or a maintainer
sees it. The AI reviews its own diff against the merge-base and strips the slop. The human sees only the judgment
calls, one at a time.

It exists because a maintainer caught AI slop that the human reviewer missed: three helpers where one was needed, and
a fix applied to every TLS context "to be safe" when only one had failed. A human misses slop in a large AI diff. The
AI has to review its own diff first, and present it in a form the human can judge.

It is a single skill with no agents. It does not need the review panel (`claude/setup-review-panel.md`), but the two
pair well: slop review before you open the PR, review panel after.

## How it works

Source: `claude/skills/slop-review/SKILL.md`. Read it in full. `retro.md` next to it holds the history and the
numbered rules (R1 to R50) the skill cites. Read a rule there only when its reason matters.

1. **Base.** It diffs against the merge-base with the base branch (default `main`), never HEAD or the working tree.
   Every line changed against the base has a cost, including rewording and recasing untouched code.
2. **Find.** It walks the whole diff and tags each candidate: SCOPE (a fix spread to paths that never failed), DEAD,
   DRY, CHURN, HYGIENE, TEST SCOPE, COMMENT, SIMPLIFY. Before it proposes a new helper, it searches for an existing
   one and says what it searched.
3. **Triage.** It applies the no-brainers (exact duplicates, no behavior change, fewer lines) and lists them in one
   batch for the user to veto. Everything else is a judgment call.
4. **Present.** One change site per message. A full unified diff with no `...` elisions, sized to fit one screen
   (about 35 lines), paged if bigger. Each message ends with a fixed footer, then it stops and waits:

   ```
   CHANGE DRY  : ctx_guard and e2ee_guard are each defined twice
   SUMMARY     : Keep one copy only. Apply?
   ```

5. **Decide.** "yes" approves only the last thing shown. "Apply the rest" covers only the kind just approved. An
   approval with criticism means iterate first, then apply.
6. **Verify.** It builds and runs the full test suite through the repo's own build script.
7. **Hand back.** The human commits and pushes. The skill never does.

It has `disable-model-invocation: true`, so it runs only when the user types `/slop-review` (optionally with a base
branch, for example `/slop-review develop`).

## Setup

Do these in order. Show your user the plan (steps 1 to 3) before you write any file.

1. **Find their config dir.** It is `~/.claude/` on macOS and Linux, and `%USERPROFILE%\.claude\` on Windows. If
   `skills/slop-review/` already exists, ask before you overwrite it. The skill needs only `git`, on any OS.
2. **Fetch the files.**
   - `claude/skills/slop-review/SKILL.md`
   - `claude/skills/slop-review/retro.md`
3. **Adapt them to your user.**
   - References to `agents/code-review.md` and to "atrium" point at things they do not have. They do not change
     behavior. Ask your user whether to leave or delete them.
   - The "Lead and worker" section uses a second session to draft findings. It is optional. Leave it unless your
     user asks to remove it.
   - Phase 6 mentions a cross-platform test matrix from my C SDK work. Ask your user what their repo's build and
     test commands are, and say so in that phase.
   - `build.claude/` (the lead and worker queue and scratch dirs) is my scratch-dir name. Swap in one that their
     repos already gitignore, or tell them to add it.
   - Search both files for `D:\`, `C:\`, `clint`, `atrium` and `dovholuknf`, and resolve each hit with your user.
4. **Write the files** to `~/.claude/skills/slop-review/SKILL.md` and `~/.claude/skills/slop-review/retro.md`.
5. **Verify.** Your user restarts Claude Code. `/slop-review` shows up as a slash command.
6. **Smoke test.** On a branch with a few AI-written commits, run `/slop-review`. Check that it names the base and the
   file list, batches the no-brainers, then shows one site with the `CHANGE` / `SUMMARY` footer and waits.

## Tuning

- Have your user paste their reactions during a run ("i shouldn't even have to see that"). Append them verbatim to
  `retro.md`, then turn the repeat ones into rules in `SKILL.md`. That loop is how the skill got to its current shape.
- Too many messages means the no-brainer bar is too high. Too many surprises in the batch means it is too low.
