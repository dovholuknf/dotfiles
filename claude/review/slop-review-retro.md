# Slop-review retro: the first two trial runs (2026-10-08 / 10-09)

> **Trial status.** The self/slop-review process is in its second trial run and may change. Do not build a skill,
> a gate or a linter from these requirements yet.

Raw material for building review tooling. Captures what happened, the operator's reactions in their own words, and
why each step was taken. The process distilled from it is `slop-review-process.md` next to this file.

## What happened

- The PR (a C SDK change adding a Windows crypto backend for e2ee-tls under FIPS) went up with code Claude wrote and
  the operator reviewed. The maintainer's review caught slop the operator had missed: `tls_is_fips`,
  `tls_restrict_fips` and `e2ee_restrict_tls` in crypto.c ("do you need all 3?"), a restriction call in an auth
  source file ("why do we do it here?"), and the same in two more unrelated source files ("ditto").
- Root cause of that slop: the only failure was e2ee (OpenSSL 3.0 dialer -> Go FIPS host, 2 of 72 matrix runs).
  Claude applied the FIPS restriction to every TLS context in FIPS mode "to be safe". Normal TLS recovers through a
  HelloRetryRequest, so the extra restriction did nothing. Only e2ee needed it.
- Earlier cleanup commits had already dropped tests that exercised the TLS library instead of SDK code, dropped the
  e2ee-tls parser, and removed or cleaned comments.
- This session: dropped `tls_restrict_fips` and `tls_is_fips`, restored the three unrelated source files to match
  main, merged 5 new test files into 2, deleted a hold comment, and ran full ctest in both trees plus the Azure matrix.
- The operator then asked for a DRY, code smell and slop review of the whole PR. It found dead code, duplicated logic,
  repeated comments, duplicated test helpers and single-user code in a shared header.

## The operator's reactions, verbatim (names removed)

- On the drafted maintainer reply: "look. [the maintainer] doesn't knwo waht failures we hit. we need to explain 'i
  hit this failure during this test. this was an attempt at fixing that but was misguided' something like that"
- On a comment in connect.c: "was this a comment we added? i want as few changes to main as possible"
- Same comment: "fine delete teh coment it is kinda gross"
- "have we unslopped ourself now?"
- "i want yiou to review the PR and changes for DRYness, code smells, slop/sloppy code"
- "it's been rough and i've looked like a d*** cause i did a poor job revieing your slop"
- "first i want to learn from this experience and build tooling to help me/atrium with this flow"
- From the earlier session (handoff): frustrated by slow, unannounced work. Said "drop it" on `tls_restrict_fips`.
  Asked for the test files to be merged into fewer files.

## Lessons

1. A fix spread to paths that never failed is a guess, and the human ends up defending it to the maintainer.
2. Every line changed against main has a cost. Rewording, recasing and restructuring untouched code all add to it.
3. The human reviewer misses slop in a large AI diff, so the AI has to self-review against the base before showing
   it.
4. Replies to a maintainer need the context they lack: what failed, in which test, what the code tried, and that it
   was wrong.
5. Tests should cover the project's own code, go in the existing file for their area, reuse existing helpers, and
   not copy production logic.
6. Commit messages: one behavior line, not a comma-joined list. Claude's suggested message broke this rule.

Folded into the agents pack: `agents/principles.md`, `coding.md`, `code-review.md` (2026-10-09).

## TODO

- [ ] Build the slop gate. Not yet: the operator said "i definitely want a slop gate but we aren't building it yet.
      our priority is getting this pr unslopped first". Collect requirements from the trial runs until then.

## Requirements gathered from interactions

- R1 (2026-10-09) Code references must open the code at that line, in one click. Today, `library/connect.c:982`
  in the terminal links only the file part. Clicking shows a hover card ("click to open it: in atrium's editor, in a
  tab..."), then a menu ("open in atrium's editor / open in a tab"). Two clicks, no line, and annoying. Atrium owns
  that fix.
- R2 Mode matters:
  - Authoring mode ("we are authoring code"): the reference should open the code at the line, in a popup or a
    link. Not inline text, which makes the human scroll.
  - PR review mode: the reference should go straight to the PR diff line on the forge, where the human can add a
    comment.
- R3 Findings come ranked by priority ("that output was fine"), and each one must make the referenced code easy to
  see.
- R4 When fixes are proposed, go bullet by bullet and show the code being changed (until R1/R2 exist, inline
  before/after in chat).
- R5 "Bullet by bullet" means ONE finding per message, then stop and wait for the human's call. Claude dumped all
  13 findings in one message, and the answer was "is taht ONE AT A F***ING TIME????". The gate must page findings
  and never batch them.
- R6 Presentation that worked ("phenomenal"): a finding title with file:line range, a one-to-two sentence why, then
  a Current block and a Proposed block that show only the changed lines, with `...` for the code between them.
  Limit: it stops working when the change is much larger.
- R7 Proposed code must be exactly what goes in the file. Never annotate a snippet with a comment that would not be
  in the code ("// main's line, unchanged" was flagged). Put notes in the prose around the snippet.
- R8 No comment where a nearby log line already says it (the hold's CONN_LOG explains the `return false`).
- R9 ALWAYS make as few changes as possible ("wehn making changes we __ALWAYS__ need to make as few changes as
  possible. ALWAYS...."). A smell fix that adds code is not a cleanup. Drop it, or show it shrinks the diff
  against main.
- R10 The description must match the proposed code. L2 was described as "keep main's two blocks, change only their
  last two lines" while it added a helper and more lines. The operator: "this current/proposed is more code and
  does not seem to align with the description?" The gate should count lines changed against the base for each
  proposal and state that count honestly.
- R11 One change site per message. L4 put two files in one message, with "current:" buried at the end of a prose
  line. The operator saw "TWO 'proposed' sections ... and 0 'current'". Each site gets its own message, with
  **Current** and **Proposed** as standalone labels.
- R12 Say up front what kind of change it is (comment-only, code, test). The operator had to ask "just comments
  changing?".
- R13 The split format (one site, a kind tag, a one-line why, **Current**/**Proposed** labels) got a plain "yes"
  on the first try (L4a).
- R14 R9 is not "no new code". The operator: "adding code is fine when it has 'a reason' are you being overly
  agreessive with 'no new code'?". Claude overcorrected and dismissed L5 without counting lines. The
  free_tls_contexts helper actually SHRINKS the code, and Claude claimed it "would add lines". The rule: every
  change needs a stated reason, and the line count must be measured, never guessed.
- R15 Tag each finding by category (DRY, dead code, comment-only, simplification, test scope, ...). The operator:
  "this is a 'dry' fix? categorizing the changes is prolly a good learning".
- R16 Ranking of code shapes: DRY and simple (best) > more lines but simple > DRY but dense. The operator: "'more
  lines but simple' is better than DRY but dense but DRY AND SIMPLE is best". Fewer lines should also read simpler.
  A DRY fix that is harder to read is not a win.
- R17 Current/Proposed (R6) breaks down for moves and deletes spread over a file. T1 showed ~30 lines per side, and
  the operator said "too many lines to tell - hard to understand the proposed updte". For a move or delete, use a
  unified `diff` block with only the -/+ lines and a line number on each hunk header.
- R18 Red/green diff coloring works ("f***ing love the green/red added/removed code"). But a tall message scrolls
  off the terminal. The description sits at the top and the human types at the bottom, so they cannot review it.
  In chat: code first, then the description and question last, next to the prompt. For the tool: show the change
  in a side pane or popup, sized to fit, with the decision prompt beside it.
- R19 Footer format, verbatim from the operator. No finding IDs (T1/L4) for the human, no line counts they can see
  in the diff, no extra prose:
  ```
  CHANGE DRY  : ctx_guard and e2ee_guard are each defined twice
  SUMMARY     : Keep one copy only.
  ```
  The operator: "i don't need '8 lines' i can f***ing see that... 'T1' - i don't care about the f***ing identifier
  as the human... all the other words you use are just more of the same".
- R20 Minimize vertical space. No blank line plus a separate "Apply?" row (that costs 2 rows). Fold the question
  into the SUMMARY line. Each message is the diff and then the 2-line footer, nothing else.
- R21 Triage by obviousness. The operator on T1: "that seems like a no bariner. i shouldn't ecen have to see that
  :)". The gate should auto-apply no-brainers (an exact duplicate removed, no behavior change, fewer lines), list
  them in one batch summary for a glance or veto, and spend the human's one-at-a-time attention only on judgment
  calls.
- R22 Before any comment edit, the first question the human asks is "net new or existing?". Rewording a comment
  that exists in main is bad (diff churn). Rewording one the PR adds is fine. State "net new vs the base" in the
  finding so they do not have to ask. On T8/T5: "really these are nits but whatever".
- R23 Explain the mechanism before proposing removal. On T7 (a single Catch2 SECTION) the operator asked "what's a
  section for?". After the answer, they kept it: the section name states the behavior under test, so it is not dead
  weight.
- R24 The operator names this pass a "self/slop-review". Moving single-user fixtures out of the shared header is
  hygiene, not a nit: "this seems 'dumb' until it's needed we should not needlessly pollute .h files". A helper
  goes in a header only once a second file uses it.
- R25 A blanket "apply" covers only the exact kind just approved. The operator said "any other of these just apply
  too" after a .h pollution move. Claude also applied a different T5 part (one anon namespace instead of `static`)
  unseen. The operator: "i meant any '.h pollution' to fix not ALL of them we haven't reviewed yet". It was
  reverted. When the scope is unclear, ask. Never widen it.
- R26 A forced side edit is still a separate change. T4 (drop dead params) also reworded the comment that named
  them, and the footer said nothing. The operator: "you have also mushed a comment change in there". Call out every
  side edit in the footer. Prefer deleting a stale clause to rewording it.
- R27 A "yes" approves only the last thing shown. Claude showed T4 code, then a comment-only follow-up ending
  "Apply T4 with this?". The "yes" was for the comment. Claude applied both, and they were reverted. Also, edits to
  EXISTING comments come after the code changes they depend on, as their own finding. A net-new comment that comes
  with new code can sit in the same diff (the operator's correction during T6).
- R28 Do not narrow a general-purpose helper to fit its current callers. T4 proposed hardcoding issue_cert's
  ca/validity params because the one caller passes constants. The operator rejected it: it is a helper whose params
  make it reusable later, and hardcoding them breaks any other caller. "Same constant at every call site" is not a
  finding on a helper's natural parameters. Drop it from the linter idea.
- R29 Never condense a diff with "..." elisions. The operator on T2: "the condensed version hides the full diff for
  me. if i ask for a full diff give it to me". Generate the real diff from a patched copy (git diff --no-index) and
  show every line.
- R30 By T6 the loop worked ("this process is really working well now... i'm enjoying this"). By then it ran: one
  finding, the full diff, net-new vs base stated, side effects named, code before comments, any trade-off (like +2
  lines that only pay off in a follow-up) said up front with a recommendation.
- R31 If the human approves a change but criticizes part of it ("that comment fits... even though the comment
  itself is s***"), do not apply it yet. Iterate on the weak part first, then apply the finished version once.
  Claude applied T6 with the bad comment and then fixed it in a second edit. The operator: "we should have not made
  that change before and should have iterated".
- R32 Refines R24. A single-user item leaves the shared header unless it is a helper that other tests could
  plausibly use later. If Claude cannot tell whether it is "potentially useful in the future", it asks and does not
  decide.
- R33 Judgment questions use the same 2-line footer as findings, one item per message. The operator's template:
  ```
  SUMMARY HYGIENE : .h pollution - tls_with_ca is defined in a .h but only has one callsite
  QUESTION        : is it possibly useful to other tests to be able to make a tls context with a provided ca?
  ```
  Do not answer the question for the human in a bullet list, and do not bundle several items into one question.
  Always show the code the question is about above the footer: "it's not quite enough unless i can see what i am
  answering".
- R34 An answered question is the approval. After the operator answered "yes, reusable" to the R33 question, Claude
  showed the move-back diff and asked "Apply?" again. The operator: "the previous question should have answered
  this". When the answer settles the action, apply it and show the diff as done.
- R35 For a move or a shrink, also show the diff against the PR base. Against the working tree, moving crypto.h's
  record macros and inline body into crypto.c read as "just moving them around". Against the base it showed the
  point: the PR's header addition drops from 2 macros and a body to one declaration. Header priority: public API
  headers are hardest to change, then internal headers, then .c.
- R36 Churn does not outrank correctness. S2 proposed dropping the PR's `#include <string.h>` from e2ee_tls.c
  because main already used memcpy through a transitive include. The operator: "it seems wrong to remove for the
  churn reason". Include-what-you-use is the correct state, so "fewer lines vs main" only applies to changes with
  no correctness value.
- R37 One site per message holds even for a single finding. S5 showed a new helper plus its call site, each against
  main and the working tree: 4 views in one message. The operator: "too many changes presented at once". Split a
  finding into one site per message and show one diff each. Add the second view only when the first one hides the
  point (R35). Order the sites by dependency: the S5 split showed the call site first, and the operator asked
  "e2ee_failed doesn't exist yet tho?". Show a new helper before its callers.

### Second trial run: a Go SDK pull request (2026-10-09)

The same e2ee-tls feature on the Go SDK side, reviewed against its merge-base with main (19 files, +2750/-58). It
ran with a new lead and worker split (R40). The operator committed every review edit as one commit, and CI passed.

- R38 Every review message fits a 40-row screen (about 35 lines). After a /clear, a finding came back as a ~90-line
  message. The operator: "too much displayed at once". If a message cannot fit, it opens with a plain-text
  `=== SCROLL BACK TO HERE ===` line. Page a big diff across messages, with one approval after the last page. Do
  not split one deletion into many separately compiling steps (the worker cut one deletion into 7).
- R39 The fenced footer (`CHANGE <CAT> :` / `SUMMARY :`, or `SUMMARY <CAT>` / `QUESTION`) ends every message and
  every page. Paging dropped it once: page 1 ended with a SUMMARY line in plain prose, and the operator flagged it.
  A page that is not the last one asks "Next?" in its SUMMARY line.
- R40 Lead and worker. A worker session drafts each finding into a queue dir (`./build.claude/slop/queue/NN-<slug>/`)
  and applies it when the lead says "apply NN". The lead checks each draft and presents it to the operator.
- R41 The lead owns the rules. Do not relay review-process rules to the worker. The operator wants to see the lead
  apply them (the lead had forwarded the "no callers" rule). The worker sends one report per instruction, with no
  acks and no unprompted status (it sent a say plus a blocked report for each step). Tell the operator before
  ending a worker they can see. The lead ended one without a word, and the operator asked "where did your slop
  agent go?".
- R42 Code that an approved change leaves with no callers goes with a one-line FYI ("removing xyz, no more
  callers"). It needs no diff page or approval of its own. A parser and a constant took 2 extra pages before this.
- R43 Follow the project's established paradigms when that is more correct for the project. First scan for markdown
  guides on code and test changes. With no guide, a code-alignment question is not a question: inspect the code on
  main, isolate the pattern, and follow it. Here CONTRIBUTING.md linked a policy page that returned 404, and main
  split test files by topic, so the PR's topic test files stayed as they were.
- R44 Restoring main's text is CHURN, or COMMENT + CHURN for a comment. It is not plain COMMENT.
- R45 Answer "why" in one sentence first, then offer detail. The operator asked "why remove?" and got a 4-section
  answer. The lead sentence ("duplicates coverage that already exists, and the one thing it adds is a path no SDK
  caller can reach") was all they needed. Brevity always wins while the content is carried.
- R46 Show a verbatim move as a list of the moved names plus the import changes. Confirm by script that the cut text
  and the pasted text are identical before showing it.
- R47 A finding that adds a helper states what it searched for and why the existing candidates do not fit. The
  operator asked "is this already a thing in any OTHER funcs?" after the helper was proposed. The scan comes first.
- R48 When an approval is conditional ("seems like a good idea but also scan"), say in the same message that the
  condition was met and that the change was applied. Do not read the condition as a plain yes.
- R49 Churn from a formatter (gofmt realigning a struct literal) or from putting code where it belongs is not a
  finding. A proposal to move a field out of its literal to dodge gofmt got "no that dumb. it's acceptable to churn
  vs main for 'correctness' or code hygiene". CHURN only covers changes with no correctness or hygiene value.
- R50 Refines R23. For a large or unfamiliar change, explain the mechanism first (background, why the code exists,
  what it does, why it is out of scope), then split the diff. A 100-line deletion with a 4-bullet note got "i don't
  understand this change yet and the diff is so large that it's hard to understand it needs exposition". The
  rewrite got "i love that explanation".

Tooling friction from the second run:

- The control room hit its 5-worker launch cap, so the worker launched in another room.
- `atrium_launch` wrote BRIEF.md into the cwd and replaced an untracked BRIEF.md already there.
- `ATRIUM_ONLY_SUBAGENTS` blocks fork agents too, not only plain subagents.
- Scratch `.go` copies under `build.claude/` break `go list ./...`. Put them in a `_`-prefixed dir
  (`build.claude/_slop`), which the go tool skips.
- A shell hook that blocks `go build` without `-o build.claude/` matched the text `<file>.go build.claude/...` inside a
  `cp` command. Writing `./build.claude/` avoids the false match.

## Tooling ideas (not built)

- Slop gate: a skill or atrium step that diffs against the PR base, not HEAD, and runs the `coding.md` checklist
  before any diff reaches the human. It flags duplicated blocks, helpers that already exist nearby, the same comment
  in several places, and dead branches.
- Diff budget: lists every line changed against main that is comment-only, case-only or whitespace-only, or reworded
  without a behavior change, so each one is a deliberate keep.
- Scope check: for each call site the fix touches, require the failing test or run that proves the site needed it.
- Slop linter (the operator's idea, during T4): a diff-scoped script against the PR base that auto-fixes or flags
  the mechanical findings, so review only covers judgment calls. Candidate checks: capitalized sentence starts in
  net-new comments, header helpers with a single user TU, `static` mixed with an anon namespace, duplicated
  struct/function bodies (jscpd or PMD CPD), a Catch2 TEST_CASE with one SECTION (flag only, see R23). clang-tidy
  covers parts: misc-definitions-in-headers, misc-unused-parameters.
- Maintainer-reply drafter: requires the failure, the test, and what changed before it writes a reply.
