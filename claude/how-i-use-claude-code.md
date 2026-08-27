# How I run Claude Code

I drive. The agent runs as its own Windows user. One box, two accounts, a worktree per task, and enough tooling
around it that many agents stay useful and contained at the same time.

This is an overview of the daily workflow. For the full rationale see [WHY.md](../WHY.md), and for the reference docs
see [CLAUDE.md](../CLAUDE.md) and `powershell/docs/`.

## The one idea: an agent is a user, not a chat window

Every Claude Code instance runs under a separate Windows account named `claude`, never under mine (`clint`). A real
operating-system account is the boundary, not a convention and not a prompt rule. That account is a standard user with
no admin rights, its own profile, its own ACLs, and its own credential vault.

The OS enforces the blast radius. My files, SSH keys, browser data, and DPAPI secrets are denied to `claude` by Windows
itself. A scan run as the agent confirms it cannot read or even list `C:\Users\clint`. A prompt-injected or misbehaving
agent is confined to what one unprivileged user can touch.

## The loop: drive, spawn, work, watch

The daily shape is five steps. I stay the driver the whole way, and I run every git mutation myself.

1. **Drive from my own shell.** I work in an ordinary `clint` terminal. No account switching, no second login to
   manage.
2. **Spawn an agent into a worktree.** One command opens a Windows Terminal tab running Claude Code as the `claude`
   user, landed in a specific git worktree. The mechanism is `runas /user:claude /savecred`, so the isolation is real,
   not simulated.
3. **It works, contained.** The agent edits code in its worktree and maintains its own config, all version-controlled.
   It signs its commits with its own key, and it has no push credentials.
4. **Watch every agent at a glance.** A session ledger plus lifecycle hooks let me see which worktree, which window,
   and whether each agent is thinking, idle, or waiting on me. Tabs are color-themed so state reads across a wall of
   windows.
5. **Review, then I push.** Specialist review agents and skills go over the change. I run the commits and pushes. A
   hook rejects any commit not signed by me, as a backstop.

## Two accounts, one shared drive

I launch the agent from my shell with `gwt claude`. Windows starts the tab under the other account. The only thing
shared on purpose is the code drive, and that sharing is scoped by ACL, not left as a blanket grant.

```
  clint                     D:\  shared                    claude
  interactive human   <-->  dotfiles + worktrees   <-->    unprivileged agent host
  GPG signing key           scoped by ACL                  own SSH key, own tokens
  the only pusher                                          no admin, no push,
                                                           no read of clint's home

  clint ---- runas /user:claude /savecred ----> launches the claude tab
```

## gwt: a worktree per task

Almost everything routes through `gwt` (git worktree). One clone per repo, one worktree per piece of work, on a fixed
path layout the tooling relies on. I can paste a URL and it figures out what I mean.

```
gwt https://github.com/openziti/ziti-ghsa-p6gx-g438-rjc8/tree/backport...secrets
  detected: github.com/openziti/ziti  (base repo recovered from the fork name)
  remote 'ghsa-p6gx-g438-rjc8' added, fix branch fetched
  ready: worktrees\...\ziti\advisory-p6gx-g438-rjc8   opening claude here
```

A URL is inspected and sent down the right flow:

| You paste | It does |
| --- | --- |
| `.../pull/<n>` | worktree for that pull request |
| `.../issues/<n>` | worktree branched off main, named for the issue |
| `.../security/advisories/GHSA-...` | advisory worktree, prompt seeded from the advisory body |
| `.../<repo>-ghsa-.../tree/<branch>` | reuse the base clone, add the private fork as a remote, worktree the fix branch |
| `.../<org>/<repo>` | clone if missing, then open |

## Reading a wall of agents

Every lifecycle event writes the agent's state to a ledger and a log. `gwt sessions` and `gwt watch` turn that into a
live view, and a tab retitles itself the moment an agent needs me. Three states carry the signal:

- **thinking** (cyan): working.
- **idle** (green): turn done.
- **needs-input** (yellow): waiting on me.

A per-window color theme rides on top, so a screen full of tabs is scannable without reading a word. When an agent
stops for permission or a question, its tab title flips to a needs-input marker that persists exactly as long as it
waits.

## Hooks that gate and report

Claude Code hooks do two jobs here: block shell shapes I never want an agent to run, and emit the telemetry the
monitoring reads. They run even though the agent is already a contained user, as defense in depth.

- **Command gatekeeper.** A pre-tool-use hook screens each shell command and edit, refusing risky shapes like
  `cd &&` chains, `git -C`, bare `find`, semicolon chains, and stray redirects. See
  `claude/hooks/pre-tool-use-hook.ps1`.
- **Signed-push gate.** A pre-push hook rejects any pushed commit not signed by my key, scoped to only the commits the
  push actually introduces. See `githooks/pre-push`.
- **State and tab telemetry.** Lifecycle hooks patch the session ledger, append to a state log, and retitle the tab so
  `gwt watch` and the tab strip both stay current. See `claude/hooks/set-session-state.ps1`.

## Skills and specialist agents

Repeatable work is packaged, so I invoke it by name instead of re-explaining it. Reviews fan out to specialists whose
only job is one lens on the change.

- **Skills (named workflows).** A review panel and QA pass, a session recap that leads with false finishes, a PR-body
  writer in my voice, product-specific reproducers and debuggers, and a slide generator. Each is a tracked file,
  invoked with a slash command.
- **Agents (one lens each).** A Go security reviewer, a codebase steward that checks a change against how the repo
  already does the job, a C systems reviewer, a C# expert, a networking expert, and a Windows enterprise veteran. A
  change gets the reviewers its files call for.

## Config lives in the repo, not in a home dir

Claude Code reads its agents, skills, hooks, settings, and global instructions from `~/.claude`. Those entries are
symlinks into a version-controlled repo, so the real files are committable, diffable, and pushable. Edit the repo file
and the live config picks it up through the link. There is no copy to drift out of sync, and the agent maintains its
own configuration as tracked files.

The same repo holds how I shape the model's replies: a set of chat directives that keep answers short, put questions in
a fixed format, surface git commands instead of running them, and hold a plain-technical register. Every behavior
change gets a dated line in a tuning changelog with its reason, so the setup has a history I can read back.

## In short

I drive, the agent executes as a separate unprivileged user in its own worktree. Everything it touches is either
version-controlled through symlinks into one repo, or scoped by ACL. The result is an agent that stays useful and
contained at the same time, and a workstation where I can run a dozen of them without losing track of what each one is
doing.
