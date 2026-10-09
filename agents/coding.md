# coding.md

How I want code to read. Most of this is "less is more" applied to source.

## Comments

- Default to writing none. Most code doesn't need explanation; well-named identifiers do that job.
- Add a comment only when the WHY is non-obvious: a hidden constraint, a subtle invariant, a workaround
  for a specific bug, behavior that would surprise a future reader.
- One short line max for those. Don't write multi-paragraph docstrings unless the language ecosystem
  requires them (godoc-on-exported, py3 type docs).
- Don't reference the current task or PR ("added for issue #42", "used by the foo flow"). That rots.
  Put it in the commit message and PR body where it belongs.

## Error handling

- Don't add `try/catch` or fallback paths for scenarios that can't happen. Trust internal code and
  framework guarantees. Only validate at system boundaries: user input, external APIs, file IO.
- If you write a recovery, write a comment that says what error you actually expect and why a recovery
  is the right answer. "Just in case" is not a real reason.
- Surface root-cause errors. Don't catch-and-swallow. Don't catch-and-rewrap-as-generic. The
  original error message is more useful than yours.

## Abstractions

- Three similar lines is better than a premature abstraction. The pattern hasn't fully revealed itself
  yet at N=3.
- Don't write a helper for a single caller. Inline it. When the second caller appears, then extract.
- Same for a const used once: inline the literal, don't extract a name for a single use site. A named
  const earns its name at the second use.
- Don't write configuration knobs for hypotheticals. Add the knob when the second use case actually
  shows up.

## Before you hand me a diff

Re-read the whole diff against the base branch, not just your last edit. I review what you show me, and
slop I miss goes out under my name. Look for:

- Duplicated logic: the same if/else pattern in three places, four identical free-and-null blocks, the
  same timer kick in two functions. Extract it when the copies are real, or say why not.
- Helpers that already exist. Before writing a guard, deleter, or fixture, check the file and its
  neighbors. A second `ctx_guard` next to an existing `tls_ctx_deleter` is slop.
- The same explanation in several comments. Say it once, at the definition, and nowhere else.
- Dead code your change left behind, such as a return expression that can no longer be true.
- A combined condition that re-tests its own parts inside the body. Split it back into separate blocks.
- A parameter or knob that only one caller ever sets.
- Code that breaks the project's established patterns. Read the project's guides on code and tests first. With no
  guide, read how main already does it and follow that. A code-alignment question is not a question for me.

## Tests

- Test our code, not the dependency. A test that proves the TLS library or the OS does its job is noise.
- Add a test to the existing file for that area. Do not create a new file per fix.
- Do not copy production logic into a test helper. Call the real function, or expose it.
- A shared test header holds only what more than one test file uses. The rest lives in its one user.
- No test case with a single SECTION, no fixture options nobody varies.

## Hardcoded values

- Never bake environment-specific values into code or tests: my machine hostname, absolute paths, or
  anything copied from live run output. Use neutral placeholders (testhost, example.com, /var/tmp) that
  stay sensible and correct for any reader later.

## Generated code

- Don't hand-edit generated files (protobuf, generated REST clients, generated SQL types, sqlc
  output, etc). Find the generator and the source schema, change that, regenerate.
- If a generator is producing the wrong thing, fix the generator config or the schema. Don't patch the
  output.

## Build output

- **Go**: build into a `build.claude/` folder, not the repo's normal build paths. Keeps your AI-built
  binaries separate from human-built ones so I can `rm -rf build.claude` without losing my own work.
- **PowerShell**: scripts go on `$env:ON_PATH` or are dot-sourced from `$PROFILE`. No artifacts to
  build.
- **Don't commit binary artifacts** unless the project explicitly versions them.

## Language-specific notes

### Go

- Idiomatic. No factory-pattern brain damage. No interface-per-struct-for-testing.
- Errors flow up. Wrap with context using `fmt.Errorf("... %w", err)`. Don't `errors.New` if you can
  wrap.
- Tests live next to the code in `_test.go`. Table-driven when the variants are real, not when you
  just want to look thorough.

### PowerShell

- PowerShell 7+. Windows PowerShell 5.1 is not a target.
- `$Args` is a PowerShell automatic variable. Never declare a param of that name. Use `$GitArgs` or
  similar.
- Env-var driven path config, not hardcoded `D:\` literals. Use `if (-not $env:X) { ... } else { ... }`
  for fallbacks.
- For lists of choices: use the project's canonical TUI picker if one exists. Don't hand-roll a
  `for ($i...) { Write-Host "[N] ..." } ; Read-Host "choice"` block. See the per-repo files for the
  specific picker name.

> **Personal taste**: the picker rule is mine. The repo I work in has a `_TuiSelect` helper. Yours
> probably doesn't. The principle (unify list pickers) is universal; the implementation is mine.
