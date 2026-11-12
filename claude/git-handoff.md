# Giving clint git steps

Read this before you tell clint to do anything in git. He runs every command you give him by pasting it, so each
command must be complete and must run from the shell he is in. Never write "in your worktree" or "on that branch"
without the command that gets him there.

## Where his shell is

Assume his pwsh prompt is somewhere unrelated. Every set of steps starts by moving his shell to the right place. Each
step is one of these:

- `gwt new <branch>` makes a worktree and moves his shell into it.
- `Set-Location <path>` moves his shell to a folder that already exists.

## What gwt is

`gwt` is his worktree tool. The source is `$env:DOTFILES\powershell\onpath\git-worktree.ps1`. Run `gwt -Help` for the
full list of commands. These are the commands you will use:

| Command | What it does |
| --- | --- |
| `gwt new <branch>` | Creates a worktree for `<branch>` at `D:\worktrees\<host>\<org>\<repo>\<branch>`, then moves his shell into it. If the branch is on origin, gwt tracks it. If it is not, gwt starts the branch from `origin/main`. gwt does not start claude unless he passes `-Atrium`. |
| `gwt new <branch> -From <ref>` | Same, but the new branch starts at `<ref>`. |
| `gwt cd <branch>` | Moves his shell into the existing worktree for `<branch>`. |
| `gwt ls` | Lists the worktrees of the current repo. |
| `gwt prune <branch>` | Removes that worktree. |

Rules that trip agents up:

- gwt finds the repo from the current folder. Before `gwt new` or `gwt cd`, move him into the repo's main clone at
  `D:\git\<host>\<org>\<repo>` (for example `D:\git\github\openziti\ziti`), or into any worktree of that repo.
  `gwt new <branch> -Org <org> -Repo <repo>` also works from any folder.
- `gwt new` and `gwt twig` refuse any branch name that contains `claude`. Those branches are yours, and he never works
  on them directly. Give his branch a plain name such as `net10`, then sland `claude/net10` into it.
- A `/` in his branch name is fine. The worktree folder replaces it with `-`, so `feat/x` lives in `...\<repo>\feat-x`.
- If a worktree for that branch already exists, `gwt new` asks whether to remove it. Give him `gwt cd <branch>`
  instead.

## Handing off a claude/* branch

Your work reaches origin only through clint. He copies your branch into a worktree of his own with `git sland`, then
reviews, signs, commits, and pushes it himself. `git sland <branch>` makes his worktree's files match that branch's
committed tree, as unstaged changes. Rerunning it replaces the last copy.

Your branch must be visible to his clone. A `claude/*` branch made in the shared main clone, or in a worktree of it,
already is.

Never run `git sland` yourself. The gate blocks it. Never give him `git push` or PR commands for a `claude/*` branch.

### The pattern

Put each step in Do This Now. Commands go in one block, in step order:

```powershell
Set-Location D:\git\github\<org>\<repo>   # the repo's main clone
gwt new <his-branch>                       # makes his worktree and moves the shell into it
git sland claude/<your-branch>             # copies your branch in, unstaged
git status                                 # the files he will review
```

If his worktree already exists, replace the `gwt new` line with `gwt cd <his-branch>`.

After that he reviews the files, then commits and pushes. You do not write those commands unless he asks.

### Example

Weak, because he has no way to get there:

> 1. Copy the net10 branch into your worktree as unstaged changes, so you can review, sign, commit, and push it.
>
> `git sland claude/net10`

Good:

> 1. Move to the ziti-sdk-csharp main clone, so gwt knows the repo.
> 2. Make a net10 worktree off main and move into it.
> 3. Copy claude/net10 into it as unstaged changes, so you can review, sign, commit, and push.
> 4. After it merges, close PR 162, because net10 already carries its bumps.
>
> ```powershell
> Set-Location D:\git\github\openziti\ziti-sdk-csharp
> gwt new net10
> git sland claude/net10
> ```

Step 4 has no command, so the block ends at step 3.

## Other commands

- Name the exact branch, path, and remote. Never use a placeholder he has to fill in.
- One fenced block, commands in step order, `# ...` comments for notes. If he has to look, wait, or decide between two
  commands, put each command in its own block under its step.
- Before you write a step, check the real state (`git status --short`, `git log --oneline -3`, `gwt ls`). Never assume
  a worktree or branch exists.
