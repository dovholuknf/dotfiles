# Set up a review panel

You are an AI coding agent (Claude Code, or something close to it). Your user pointed you here so you can set up a
multi-agent review panel for them, based on how I (clint, github.com/dovholuknf) run mine. Read
this whole file first. Then follow "Setup" in order. Ask your user before you write or overwrite anything.

Everything referenced here is in the public repo https://github.com/dovholuknf/dotfiles. Fetch files from the raw URL
form: `https://raw.githubusercontent.com/dovholuknf/dotfiles/main/<path>`.

## What you are building

Two pieces, each a plain markdown file that Claude Code loads from `~/.claude`:

1. **Specialist review agents** (`~/.claude/agents/*.md`). Each agent has one lens: Go security, web security, C
   systems, Helm/k8s, codebase fit, functional tests, non-functional tests, and so on. Each one returns findings in
   one shared JSON shape.
2. **`/review-panel`** (`~/.claude/skills/review-panel/SKILL.md`). A conductor skill. It does not review code itself.
   It picks the agents the diff needs, runs them in parallel, tries to refute every serious finding, runs a
   completeness critic, and writes one severity-ranked report.

A separate skill, `/slop-review`, has the AI review its own branch before a human sees it. Its setup is in
`claude/setup-slop-review.md`. Offer it to your user after the panel works. For docs and blog posts, `/doc-panel`
runs a separate set of prose reviewers. Its setup is in `claude/setup-doc-panel.md`.

## How my setup works (context, not required)

You do not need any of this to run the panel. It explains why the files look the way they do. My box runs Windows,
but the panel itself does not depend on any OS. It is markdown, `git`, and `gh`. Setup step 4 removes the few
Windows-specific bits.

- Claude Code runs under a separate, unprivileged Windows account (`claude`), never under my own. The OS is the
  boundary, not a prompt rule. Overview: `claude/how-i-use-claude-code.md`. Rationale: `WHY.md`.
- One git worktree per task, managed by a PowerShell tool called `gwt` (`powershell/onpath/git-worktree.ps1`).
- `~/.claude/agents`, `~/.claude/skills`, `~/.claude/hooks`, `settings.json` and `CLAUDE.md` are symlinks into the
  dotfiles repo, so the config is version-controlled and the agent edits tracked files, not a home-dir copy.
- A `PreToolUse` hook (`claude/hooks/pre-tool-use-hook.ps1`) blocks shell shapes I never want an agent to run
  (`cd ... &&` chains, `git -C`, bare `find`, and others). Each rule's reason is in
  `claude/hooks/docs/gate-decisions.md`. Wiring: `claude/README.md`.
- The agent never commits or pushes. It surfaces the git commands and I run them.
- I run many sessions at once through a private orchestrator called atrium. The review-panel skill launches reviewers
  as atrium sessions when that tool exists, and falls back to Claude Code's `Agent` tool when it does not. Your user
  does not have atrium. Discard every atrium reference you meet and keep the non-atrium path. Do not ask about it.

## How the agents work

Each file in `claude/agents/` is a Claude Code subagent definition: YAML frontmatter, then a system prompt.

```yaml
---
name: "go-security-reviewer"
description: "Use for Go PR/code review when security, correctness, ... matter. ..."
tools: Glob, Grep, Read, WebFetch, WebSearch
model: sonnet
memory: user
---
```

- `description` is what the main session reads to decide when to delegate. Keep it specific: what the agent is for
  and what it is not for.
- `tools` limits what it can do. Reviewers read. They do not edit, build, commit or push.
- `model` pins a model per agent. Change it to suit your user's plan.
- `memory: user` gives the agent a persistent memory dir. Each prompt ends with a "Memory lives at ..." paragraph that
  names a path on my machine. You fix that path in Setup.
- The prompt body sets a persona with hard rules: inspect first, never invent a finding, every finding cites code,
  fewer high-signal findings beat many nits.

The agents worth taking for a review panel:

| Agent | Lens | Runs when the diff has |
| --- | --- | --- |
| `codebase-steward` | fit: new code that diverges from how the repo does the same job | almost any code change |
| `go-security-reviewer` | Go security, correctness, concurrency, HTTP, crypto | `*.go` |
| `web-security-reviewer` | Node/Express, proxies, browser clients, cookies, CSRF, OIDC | `*.js` `*.ts` `*.html` |
| `c-systems-reviewer` | C on networking and constrained devices, UB, lifetimes | `*.c` `*.h` |
| `csharp-expert` | C#/.NET, interop, Win32, desktop UI | `*.cs` |
| `k8s-helm-reviewer` | Helm and k8s manifests, upgrade safety, RBAC, probes | charts, manifests |
| `windows-enterprise-veteran` | GPO, MSI, services, registry, Intune | Windows admin surface |
| `functional-tester` | happy path, edges, errors, state transitions | behavior changes |
| `nonfunctional-tester` | perf, resources, load, resilience | a real latency or load surface |
| `network-expert` | TCP/UDP, TLS, DNS, packet-level | networking code |

Skip `persona`, `style-harvester` and `voice-clint`. They depend on a private style pack and on my own voice.
`doc-humanizer` is optional. If you take it, remove its pointer to `voice-clint.md`.

## How `/review-panel` works

Source: `claude/skills/review-panel/SKILL.md`. Read it in full. The short version:

1. **Target.** A PR (`gh pr diff <n>`) or the current branch against its merge-base. The conductor captures the diff
   text once, so every reviewer sees the same snapshot.
2. **Select.** It maps changed files to agents (the table above). Rule: name the concrete surface in this diff each
   agent needs, and skip the agent when that surface is absent.
3. **Announce and go.** It prints one line with the agents and why, then dispatches. Invoking the skill is the
   go-ahead. There is no "proceed?" prompt.
4. **Dispatch in parallel.** All reviewers in one message. Each gets the diff, its mandate, the severity scale and the
   finding schema verbatim, and orders to read surrounding code and dependency source, not just the diff. Reviewers
   do not build or run tests, because CI already does.
5. **Refute the serious findings.** It drops pre-existing issues and any `blocking`/`high` finding that cannot say why
   it is not already broken in production. Then it spawns one verifier per remaining serious finding, told to
   REFUTE it. A claim about a dependency's behavior needs a quoted line from that dependency's source at the pinned
   version, or it is dropped.
6. **Merge.** It checks each agent's JSON against its own prose, dedupes on file and line, and ranks by severity. Then
   a completeness critic lists the new attack surface the PR creates and names what no reviewer examined.
7. **Report.** Three files, `high.md`, `medium.md`, `low.md`, each a table with stable ids (`high-01`) so the user can
   say "fix high-02, skip low-03".
8. **Walk it.** It covers the high tier in chat, then asks "Do the medium next?" It reports only. It never applies a
   fix unless asked later.

Every reviewer returns this shape:

```json
[{ "severity": "blocking|high|medium|low|nit", "file": "...", "line": 0,
   "category": "correctness|security|fit|test|perf|style", "claim": "...", "evidence": "...",
   "preexisting": "introduced|preexisting|worsened-by-pr", "prod_survival": "...", "fix": "...",
   "confidence": "high|medium|low" }]
```

The verify pass and the critic make the panel worth its token cost. Panels without them shipped confident but wrong
criticals. The critic alone has found findings the specialists all missed.

## Setup

Do these in order. Show your user the plan (steps 1 to 4) before you write any file.

1. **Find their OS and config dir.** The config dir is `~/.claude/` on macOS and Linux, and
   `%USERPROFILE%\.claude\` on Windows. List `agents/` and `skills/`. If a file with the same name exists, ask
   before you overwrite it. Check that `git` and `gh` are installed and that `gh auth status` passes.
2. **Ask which agents to take.** Recommend `codebase-steward`, `functional-tester`, `nonfunctional-tester`, plus the
   language reviewers for the languages in their repos. Ask how to install: (a) copy the files (recommended for most
   people) or (b) clone the repo and symlink, which keeps them in step with my updates.
3. **Fetch the files.**
   - `claude/agents/<name>.md` for each chosen agent.
   - `claude/skills/review-panel/SKILL.md`.
   - Optional: `claude/skills/qa-review/SKILL.md` (functional and non-functional testers only) and
     `claude/skills/code-audit/SKILL.md` (deletes comments that do not earn their place).
4. **Adapt them to your user.** These edits are required. The files carry my paths and my tools.
   - In each agent, replace the "Memory lives at `C:\Users\claude\.claude\agent-memory\<name>\`" path with
     `<their config dir>/agent-memory/<name>/`. You can also delete that paragraph and the `memory:` line.
   - In `review-panel/SKILL.md`, step 4: delete the atrium paragraph ("If atrium is available ..."). Keep the
     `Agent` tool path.
   - In `review-panel/SKILL.md`, step 7: change the `C:/temp/review-panel/<target>/` output dir to one your user
     picks. Ask them.
   - In `review-panel/SKILL.md`, step 2: remove mappings for agents they did not take. Add any of their own.
   - In `k8s-helm-reviewer.md`, the "Running helm and kubeconform" section is Windows-only: `wslc` (the WSL
     container CLI), `MSYS_NO_PATHCONV=1`, and a `D:\` mount path. Rewrite it for your user's machine. If `helm` and
     `kubeconform` are installed, call them directly (`helm lint ./chart`, `helm template rel ./chart ...`,
     `kubeconform -summary -strict ...`). Otherwise use `docker run` (or `podman run`) with the same images and
     flags, and mount the repo with `-v "$PWD:/work" -w /work`. Also replace the agent's `wslc` fallback line.
   - `build.claude/` in `k8s-helm-reviewer.md` is my scratch-dir name. Swap in one that their repos already
     gitignore, or tell them to add it.
   - Delete every remaining `atrium` reference without asking. Then search every fetched file for `D:\`, `C:\`,
     `clint` and `dovholuknf`, and resolve each hit with your user.
5. **Write the files.** Agents go in `~/.claude/agents/`. Each skill is a folder:
   `~/.claude/skills/review-panel/SKILL.md`.
6. **Verify.** Your user restarts Claude Code. `/agents` lists the new agents. `/review-panel` shows up as a slash
   command.
7. **Smoke test.** Run `/review-panel` on a small real PR (`/review-panel 123`, or on a branch with a few commits).
   Check that it prints the one-line selection, the reviewers return JSON, the verify pass runs, and the three report
   files appear.

## Cost and tuning

- A full panel with verify and critic is several agents. On a big PR that is a lot of tokens. The user can say "skip
  the verify pass" or "no critic" for a cheap pass. For a quick look, `/qa-review` runs only the two testers.
- Pin cheaper models on the specialists and keep the conductor on the strongest one. The verify pass catches most of
  the noise a cheaper reviewer adds.
- When the panel reports something wrong, fix the agent or the skill, not the report. Each rule in `review-panel`
  that names a PR (PR 967) is a fix for a real miss. Add your own the same way.

## Optional: the guardrails

Not needed for the panel. Take them only if your user wants them, and show them each rule before you install it.
Both are written for my Windows box. Treat them as designs to port, not files to copy.

- The command gate: `claude/hooks/pre-tool-use-hook.ps1` and its wiring in `claude/settings.json`. It is PowerShell
  7, which also runs on macOS and Linux, but its rules target my shells and paths. Each rule's reason is in
  `claude/hooks/docs/gate-decisions.md`. Port the rules your user wants into a hook in their own shell.
- A separate OS account for the agent: `powershell/docs/account-isolation.md` and
  `powershell/docs/sandbox-account.md` cover Windows (`runas`, ACLs). On macOS or Linux the same idea is a
  dedicated unprivileged user that runs the agent, with file permissions that deny it the user's home. This is the
  real boundary. Hooks are defense in depth on top.
