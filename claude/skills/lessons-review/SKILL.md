---
name: lessons-review
description: >
  Walk the lessons one or more specialist personas have learned since their last review, and decide with the user
  what to promote to reviewed knowledge, keep as memory, or delete. Invoke with /lessons-review [persona-id...], or
  when the user says "review what the agents learned", "lessons review", "prune agent memory", "what have the
  reviewers learned". Reads and edits files in the dotagents persona pack. It never commits or pushes.
disable-model-invocation: true
---

# lessons-review

The pack lives at `D:\git\github\dovholuknf\dotagents\personas\<id>\`. Its README explains the layout. Memory is what
a model believed mid-review. Knowledge is what a human agreed with. This skill is the step between them.

## 1. Which personas, and what is new

- Personas named in the arguments, or else every folder under `personas\` that has a change to review.
- For each, "new" is a git fact, not a guess. Find the most recent commit whose message carries the trailer
  `Lessons-reviewed: <id>`:
  `git -C D:\git\github\dovholuknf\dotagents log -1 --format=%H --grep="^Lessons-reviewed: <id>$" -- personas/<id>`
  Everything under `personas\<id>\` changed since that commit, plus anything uncommitted, is in scope. A persona
  with no such commit has its whole history in scope.
- Skip a persona with nothing in scope, and say so in one line.

## 2. Show the landscape first

One short table: persona, new or changed memory files, new `rejected.md` lines. Then walk one persona at a time.

## 3. For each memory lesson, one at a time

Show the lesson compressed to one or two sentences, its `repo:` and its `Why:` (say "no Why line" if it has none).
Recommend one of these, then stop for the user's decision:

- **promote**: true and durable. Move its content into `knowledge\<repo key>.md` (or `knowledge\_general.md` for
  `repo: general`), as a short bullet with its reason. Delete the memory file and its line in `MEMORY.md`.
- **keep**: plausible, not yet proven. Leave it. Add a `repo:` line and a `Why:` line if either is missing.
- **delete**: wrong, stale, or duplicated. Remove the file and its `MEMORY.md` line.

Do not act until the user answers. Confidence that you can predict the answer is not consent.

## 4. Rejections

Show the new `memory\rejected.md` lines for the persona. If several describe the same mistake, propose folding them
into one sentence added to the persona's `persona.md` (then run
`D:\git\github\dovholuknf\dotagents\scripts\render-personas.ps1`), and deleting the lines it replaces. Only with
the user's yes.

## 5. Finish

- Run `render-personas.ps1 -Check` if any `persona.md` changed.
- Print the commit the user should run, message included, ending with one trailer per persona reviewed:

  ```
  personas: lessons review, <n> promoted, <n> kept, <n> deleted

  Lessons-reviewed: go-security-reviewer
  Lessons-reviewed: codebase-steward
  ```
- Never commit and never push. Remind the user to run `/safe-to-push` before pushing, because memory quotes code
  from the repos these personas review.
