# comments.md

How I want code comments written. Most of what annoys me about generated code is the comments.

## The one rule

A comment earns its place only by saying something the code cannot. If a reader gets it from the code,
delete the comment.

## What a comment is FOR

- The purpose of a block whose effect you can't see in the code. An `include()` that quietly triggers a
  network fetch earns `fetch prebuilt vcpkg packages as part of the build`. Say what it's for, in a phrase.
- A non-obvious constraint, ideally on the same line as the purpose: `... must come before project() to
  take effect`.
- A gotcha or landmine: `GitHub rejects a tag that is exactly 40 hex chars`.
- WHY the code looks wrong or arbitrary but has to be this way: the reason, not the mechanism.
- A pointer: an issue number, a URL, a spec section, an upstream bug.
- A function's contract: what it takes, what it returns, what it throws, how it differs from a sibling
  (e.g. `unlike Accept, it does not retry on EWOULDBLOCK`). Describe the function itself.

## What a comment is NOT for

- Narrating the line. If it says `set(ZITI_VCPKG_CACHE_PREFIX tsdk)`, do not write "set the prefix to tsdk".
- Changelog prose. Never explain why the CHANGE was made ("we added this so builds are faster"). A file
  describes the current state, not its history. That sentence is a commit message, not a comment.
- Narrating the development journey. No abandoned approaches, no "we used to do X", no "this is better /
  stronger than Y" comparing to a path you didn't take. Comment what the code IS, not how you arrived at it.
- Restating a well-named thing. If the name carries it, drop the comment, or rename the identifier.
- Narrating the call flow or the test that exercises a function. A function comment is about the function,
  not its callers or what some test proves with it.
- A cross-reference to code that can drift. `mirrors the struct in controller.yml` rots the moment either
  side moves. Describe what THIS code does. A stable pointer (issue, URL, spec section) is still fine (see
  above), but rationale for a deferred decision belongs in the PR body or commit message, not here.
- Decoration. No banner bars, no `==== section ====`, unless a long file genuinely needs navigation.
- Examples pulled from the current session. A comment describes the code, not the conversation that produced
  it. Never use a value, path, or name that came up in our chat as the illustrative example (especially a
  throwaway or joke one). Any example must be agnostic, relevant to the code, and natural: something a reader
  with no memory of this session would find sensible and still true later.

## Style

- Terse. One line if you can. A comment is not a paragraph.
- Same prose rules as everywhere: no em-dash, no `--` used as a dash, no semicolons in prose.
- Comment the surprising line, not every line. A comment on every line means none of them is worth reading.

## The test before you write one

1. Can the reader see this from the code itself? If yes, write nothing.
2. Will it still be true and useful a year from now, to someone with no memory of this edit? If it only
   makes sense as a note about the change, it is a commit message, not a comment.
