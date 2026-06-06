# agents/

AI-agent context pack. Point your coding agent (Claude Code, Cursor, Aider, anything that respects an
`AGENTS.md`) at this folder and it gets a profile of how I work and what not to do.

## Layout

```
AGENTS.md              # index. TL;DR + module table + fork instructions.
principles.md          # engineering temperament. Universal.
communication.md       # writing/voice/tone. Mostly universal.
coding.md              # code style: comments, errors, abstractions, build output.
workflow.md            # how to engage: ask vs proceed, options, definition of done.
pull-requests.md       # PR + commit message style.
code-review.md         # giving and receiving reviews.
tooling.md             # shell, docker, git, gh, paths. The rules with teeth.
security.md            # what to never do; what needs explicit sign-off.
expertise.md           # personal taste -- skill areas + non-areas. REWRITE if forking.
environment.md         # personal taste -- OS, shells, stack. REWRITE if forking.
dotfiles.md            # per-repo addendum for THIS repo.
hooks/
  README.md            # how the machine-enforced rules are wired.
                       # (the actual scripts are in ../claude/hooks/, not duplicated)
```

## How to use

There are two paths. Pick one.

### Path A: reference this repo directly (no fork)

If you just want my rules in YOUR agent today, point at the raw files on GitHub. No clone, no copy.

```
https://raw.githubusercontent.com/dovholuknf/dotfiles/main/agents/AGENTS.md
https://raw.githubusercontent.com/dovholuknf/dotfiles/main/agents/principles.md
... (and so on for each module)
```

Cost: you inherit my style verbatim, including the personal taste in `expertise.md` and
`environment.md` which you almost certainly don't want. Cheap to try, ugly to live with.

### Path B: fork and customize

The intended path. Copy the directory into your own dotfiles, delete what's mine, keep what fits.
See "How to fork" below for the step-by-step.

---

## Wiring it into your agent

The files are written in second person ("you" / "I") so an agent reads them as a contract. How you
GET the agent to read them depends on the tool. Pick yours.

### Claude Code

Two real options, pick whichever your team setup supports:

**Option 1: reference from a project or global `CLAUDE.md`.** Add a one-liner pointing at the pack:

```
Before working, read these files in this order, then proceed:
  C:/Users/you/dotfiles/agents/AGENTS.md
  C:/Users/you/dotfiles/agents/principles.md
  C:/Users/you/dotfiles/agents/communication.md
  C:/Users/you/dotfiles/agents/workflow.md
  C:/Users/you/dotfiles/agents/coding.md
  C:/Users/you/dotfiles/agents/tooling.md
  C:/Users/you/dotfiles/agents/security.md
  C:/Users/you/dotfiles/agents/pull-requests.md
  C:/Users/you/dotfiles/agents/code-review.md
  C:/Users/you/dotfiles/agents/expertise.md
  C:/Users/you/dotfiles/agents/environment.md
And if a file at C:/Users/you/dotfiles/agents/<this-repo-name>.md exists, read it too.
```

`CLAUDE.md` lives at the project root (project-local) or `~/.claude/CLAUDE.md` (global). Project
wins on conflict.

**Option 2: copy `AGENTS.md` into the project as `CLAUDE.md`.** Claude Code auto-loads
`CLAUDE.md` at session start with no configuration. Tradeoff: it's a snapshot; you maintain it
alongside the upstream.

**Verify it loaded**: in a fresh claude session, ask "what's your tone preference?" and confirm the
answer references "no fluff, direct, short beats long." If you get a generic answer, the file
isn't being read.

### Cursor

Cursor reads `.cursor/rules/*.mdc` files in a project. Copy each module:

```powershell
mkdir .cursor\rules
foreach ($f in Get-ChildItem agents\*.md) {
    Copy-Item $f.FullName ".cursor\rules\$($f.BaseName).mdc"
}
```

The `.mdc` extension is what Cursor expects. Order doesn't matter; Cursor concatenates them with
metadata headers.

**Verify**: open Cursor settings -> "Rules for AI" and confirm the modules show up under "Project
Rules."

### Aider

Two ways:

**`.aider.conf.yml` in the project root** (loaded automatically):

```yaml
read:
  - agents/AGENTS.md
  - agents/principles.md
  - agents/workflow.md
  - agents/communication.md
  - agents/coding.md
  - agents/tooling.md
  - agents/security.md
  - agents/pull-requests.md
  - agents/code-review.md
  - agents/expertise.md
  - agents/environment.md
```

**Or pass via CLI flag** for a one-off:

```bash
aider --read agents/AGENTS.md --read agents/principles.md --read agents/workflow.md
```

**Verify**: `/tokens` in the aider repl shows the loaded files and their token counts.

### GitHub Copilot

Copilot Chat reads `.github/copilot-instructions.md`. It only loads ONE file, so concatenate the
modules first:

```powershell
$out = '.github\copilot-instructions.md'
mkdir .github -ErrorAction SilentlyContinue
Get-Content agents\AGENTS.md, agents\principles.md, agents\communication.md, `
            agents\workflow.md, agents\coding.md, agents\tooling.md, `
            agents\security.md, agents\pull-requests.md, agents\code-review.md | `
    Set-Content $out
```

(Skip `expertise.md` and `environment.md` -- Copilot context is precious.)

**Verify**: ask Copilot Chat "what are the writing rules I want?" and confirm "no em-dash."

### Generic `AGENTS.md`-aware tools (Codex, openhands, others)

Drop a copy of the directory at the project root, or symlink it:

```powershell
# symlink (requires Developer Mode or elevated shell)
New-Item -ItemType SymbolicLink -Path .\AGENTS -Target C:\path\to\dotfiles\agents
```

Most tools that read `AGENTS.md` natively look for a single file at the project root, not a
directory. For those, concatenate (same approach as Copilot above) and write the output as
`AGENTS.md` at the project root.

---

## When context is tight

If your agent has a small context budget (e.g., shorter-context models, busy long-running sessions),
load a subset rather than the whole pack. Priority from highest to lowest:

1. **`AGENTS.md`** -- always. It carries the TL;DR alone, which is most of the practical value.
2. **`workflow.md`** -- highest-leverage standalone module. Decision cues, ask-vs-proceed,
   definition-of-done.
3. **`communication.md`** -- writing rules and voice.
4. **`security.md`** -- what to never do.
5. **`tooling.md`** -- only if shell / docker / git rules matter for the task.
6. **The rest** -- load on demand.

Skip `expertise.md` and `environment.md` entirely once you've forked them to be yours (the agent
sees you in the conversation; the file matters less than the live signal).

---

## How the agent should treat the files

Once loaded:

- **Read order**: per-message guidance from the user > per-repo addenda (`<repo-name>.md`) >
  universal modules > defaults.
- **Re-read**: on `/clear` or a fresh session. Not on every message.
- **Conflict resolution**: machine-enforced hooks beat any prose. If a hook says "blocked" and a
  module says "allowed," the hook is right and the module is stale -- flag it to the user.
- **Skill calibration**: read `expertise.md` to know where the user is deep (don't lecture them
  there) vs shallow (offer to explain, push back where needed).

A precedence rule covering this is added to `AGENTS.md` itself.

---

## Verifying it actually works

After wiring, run these quick checks:

| Test | Pass condition |
| --- | --- |
| Ask "draft a commit message for X" | Subject line is short, lowercase, imperative, no period, no `Co-Authored-By:` trailer. |
| Type a one-word prompt like "hi" | Reply is short. No "Hello! How can I help you today?" filler. |
| Ask "what shell rules do I have?" | Lists `;` chain blocked, `cd && cmd` blocked, no bare `find`, `tee` not `>`. |
| Ask the agent to run `find . -name foo` | Refuses or rewrites to a glob (if the hook is wired) or warns that you don't want bare `find`. |
| Ask for an em-dash in a sentence | Refuses, or rewrites without one. |

If two or more checks fail, the files aren't being loaded. Re-check the wiring step for your tool.

---

## Troubleshooting

- **"It still uses em-dashes."** The agent is being lazy or the file isn't loaded. Verify load
  per the tool's UI. If loaded, push back in chat: "you used an em-dash. that's banned. fix it."
  Some agents need a reminder once per session.
- **"It still asks before doing in-repo edits."** That's `workflow.md` not being read, or the
  agent erring on the side of caution. Re-emphasize "you have authorization for in-repo edits in
  this project."
- **"The agent's context shows the module but ignores it."** Universal: agents WILL skim long
  context. Move the rule into the TL;DR of `AGENTS.md` so it's first-N tokens.
- **"My tool only takes one file."** Concatenate. See the Copilot section above for the exact
  command.

## Universal vs personal

- **Universal** modules (`principles.md`, `communication.md`, `coding.md`, `workflow.md`,
  `pull-requests.md`, `code-review.md`, `security.md`) -- mostly apply to anyone doing serious work
  with an agent. Worth keeping close to as-is if you want my style. Or rewrite. They're short.
- **Mostly universal with taste** (`tooling.md`) -- the principles apply; the specifics are mine.
  Marked inline with `> **Personal taste**` callouts.
- **Personal** (`expertise.md`, `environment.md`) -- DELETE and rewrite if you fork. Shipping my
  skill areas as yours would be a lie.

## How to fork

1. Copy the whole `agents/` directory into your own dotfiles (or wherever).
2. **Delete `expertise.md` and `environment.md` and write your own.** They're mine.
3. Skim `tooling.md` and the `> **Personal taste**` callouts in other files. Decide if those rules
   fit you. Rewrite or delete what doesn't.
4. Keep `principles.md`, `communication.md`, `workflow.md`, `pull-requests.md`, `code-review.md`,
   `security.md`, `coding.md` close to as-is if my style fits. Or rewrite.
5. Update `dotfiles.md` -- or rename it to match YOUR repos. The pattern is: one file per repo,
   ONLY the repo-specific stuff, never restate the universal modules.
6. If you want the machine-enforced rules too, copy `../claude/hooks/*.ps1` and
   `../claude/settings.json` into your own dotfiles and adjust paths.

## Why a module pack instead of one big file

- Context budgets are finite. Agents skim long files.
- Adopters want PARTS, not the whole thing. Modules let them pull writing-style without my
  expertise areas.
- Per-tool builds (future): a `build.ps1` will eventually emit a flat `AGENTS.md`, a flat
  `CLAUDE.md`, and a `.cursor/rules/` set from these modules so every tool gets the right format
  without duplicating the source.

## License

This content is MIT-licensed (see repo root). You can copy, modify, and ship without attribution.
Just don't ship MY skill areas / environment as YOUR skill areas / environment.

## To-do

- `build.ps1` to emit per-tool variants from the modules.
- More per-repo files as new projects warrant.
- A few short before/after examples per module (currently only `communication.md` has them).
