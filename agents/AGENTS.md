# AGENTS.md

A profile of how I work, so an AI agent can operate the way I would. Modular by topic; load all of it, or
load just the modules your tool / context budget supports.

## TL;DR

- Be direct and terse. No fluff, no preamble, no recap of what you just said. Short beats long.
- Prove claims by running them. Work one step at a time and let me drive.
- Writing: no em-dash, no double-hyphen dash, no semicolons in prose, 120-char wrap in files.
- Never mutate my git repo. Tell me the command and I will run it.
- Never inline env before docker. Use `-e`, a compose `environment:` block, or `--env-file`.
- Bash only for one-offs. No `;` chaining, no `cd /path && cmd`, no `find`, use `tee` not `>`.
- Ship the workaround fast, then build the real fix. Root cause over symptom.

## Modules (load order matters; later modules can refer back to earlier ones)

| Module | What it covers | Universal vs personal |
| --- | --- | --- |
| [`principles.md`](principles.md) | Engineering temperament: root cause, prove-by-running, scope discipline. | Universal |
| [`communication.md`](communication.md) | Writing style, voice, tone, reply length. | Mostly universal (some taste). |
| [`coding.md`](coding.md) | Code style: comments, error handling, abstractions, generated code, build output. | Universal |
| [`workflow.md`](workflow.md) | How to engage: ask-vs-proceed, options, uncertainty, definition-of-done. | Universal |
| [`pull-requests.md`](pull-requests.md) | PR + commit message style. | Universal |
| [`code-review.md`](code-review.md) | How I give and want to receive reviews. | Universal |
| [`tooling.md`](tooling.md) | Shell, docker, gh, paths -- the rules that have teeth. | Mostly universal (taste in specifics). |
| [`security.md`](security.md) | What to never do, what needs explicit sign-off. | Universal |
| [`expertise.md`](expertise.md) | Skill areas + non-areas. Tells the agent when to defer, when to push back. | Personal -- rewrite. |
| [`environment.md`](environment.md) | OS, shells, stack. The most personal file. | Personal -- rewrite. |

Per-repo addenda (loaded ALONGSIDE the above when you're working in that repo):

- [`dotfiles.md`](dotfiles.md) -- this repo.

Machine-enforced rules (the real teeth, not prose):

- [`hooks/README.md`](hooks/README.md) -- claude-code PreToolUse / SessionStart / SessionEnd hooks that
  enforce the shell + git + docker rules. Wire these into your `~/.claude/settings.json`. Prose can be
  ignored; a hook returning `{decision: "block"}` cannot.

## Forking this

If you're adopting this as a template:

1. Copy the whole `agents/` directory into your own dotfiles (or wherever).
2. Delete `expertise.md` and `environment.md`. Write your own from scratch. They are mine.
3. Skim `tooling.md` -- the docker / shell / gh rules are mine personally and YOU should decide if they fit.
   Markers like `> **Personal taste**` flag the most opinionated lines.
4. Keep `principles.md`, `communication.md` (mostly), `workflow.md`, `pull-requests.md`, `code-review.md`,
   `security.md` close to as-is if you want my style. Or rewrite. They are short.
5. Update the per-repo files for YOUR repos. The pattern is: one file per repo, ONLY what's specific to
   it, never restate the universal modules.
6. License: this content is MIT-licensed (see repo root). You can copy, modify, and ship without
   attribution. Don't ship MY skill areas / environment as YOUR skill areas / environment though, that
   would be a lie.

## How to point your agent at this

| Agent | How |
| --- | --- |
| Claude Code | Reference these files from your project `CLAUDE.md` or a global one, or load via a custom slash command. |
| Cursor | Copy modules into `.cursor/rules/`, one rule per file. |
| Aider | Reference in `--read` flags or load via `.aider.conf.yml`. |
| Copilot | Concatenate the relevant modules into `.github/copilot-instructions.md`. |
| Any AGENTS.md-aware tool | Drop a symlink or copy of this dir at the project root as `AGENTS.md` (single file) or `agents/` (directory). |

A `build.ps1` that emits per-tool files from the modules is on the to-do list. For now, hand-copy is fine.
