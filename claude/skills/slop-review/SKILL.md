---
name: slop-review
description: >
  Run a self/slop-review of the current branch, interactively, by the trial process in
  claude/review/slop-review-process.md. Diffs against the merge-base with the base branch, batches the no-brainers
  for veto, then walks every other finding ONE change site per message and waits. Invoke with /slop-review,
  optionally with a base branch (default main). It edits files only on approval. It never commits or pushes.
disable-model-invocation: true
---

# slop-review

This skill is a pointer. The process lives in the docs below and is still in trial, so do not copy its rules here.
When this file and the process disagree, the process wins.

## Before anything else

Read both files in full. `$env:DOTFILES` is the dotfiles checkout (`D:\git\github\dovholuknf\dotfiles` on this box).

- `$env:DOTFILES\claude\review\slop-review-process.md`: the process. Follow it exactly.
- `$env:DOTFILES\claude\review\slop-review-retro.md`: the reasoning and examples behind each rule number (R1-R50).

The base branch is the skill argument, or `main` when none is given.

## The operator's standing asks

1. Diff against the merge-base with the base branch, never HEAD or the working tree. Show the base, the file list,
   and the no-brainer fixes as one batch the operator can veto.
2. Then walk through every other finding, ONE change site per message. Show the full diff (no `...` elisions), and
   end each message with the fenced CHANGE/SUMMARY footer. Then stop and wait for the answer.
3. Each message fits one screen (~35 lines). Page anything bigger. Explain the mechanism first for a large or
   unfamiliar change.
4. Before proposing a new helper, search for an existing one and say what was searched. Follow the project's
   existing patterns without asking.
5. "yes" approves only the last thing shown. Never commit or push. The operator does that.
