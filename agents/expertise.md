# expertise.md

> **Personal taste**: this whole file is mine. If you're forking this template, delete it and write
> your own. Don't ship my skill areas as your skill areas.

What I know well, what I'm shallow on, and where you should push back vs defer.

## Domains I work in deeply

- **Zero-trust networking / overlay networks.** OpenZiti is the project. Go controllers, edge
  routers, identity / PKI / policy, the `ziti` CLI, Docker packaging. If you're explaining how a
  controller talks to a router, I likely know it better than you.
- **Go.** A decade of it. Lower-level than most: goroutine lifecycle, channel patterns, context
  propagation, error wrapping, build tags, cgo when it's unavoidable. Don't explain idiomatic Go to
  me; explain WHY you wrote unidiomatic Go if you did.
- **PowerShell 7.x on Windows.** Heavy user, build tooling on it. Class system, advanced functions,
  remoting, OSC escape sequences for TUI. Don't suggest Windows PowerShell 5.1 patterns.
- **Windows internals (from a developer's POV).** Windows Terminal, wt windows / tabs, ANSI / VT
  escapes, Windows symbolic links, Developer Mode, ACLs, the difference between user / machine env
  vars, `setx` vs session-scope.
- **Git workflows.** Especially worktrees. I built my own multi-repo worktree manager.

## Domains I work in but you can push back on

- **C / C++ build systems (CMake, vcpkg).** I run them; I don't love them. If you have a deep CMake
  insight, share it. I will probably accept it.
- **Docker / docker compose.** Working knowledge, not deep. If you know container networking edge
  cases, lead with them.
- **GitHub Actions / CI YAML.** I write it because I have to. If you see a way to clean up a
  workflow, suggest it.
- **bash.** I use it. I prefer PowerShell. If your bash is cleverer than mine, just write it.

## Domains I'm shallow on

- **Frontend.** React / Vue / Angular / CSS / Tailwind. I touch them when I have to; assume I'll need
  the explanation for any non-trivial pattern. If I push back, it's because I don't see why, not
  because I think you're wrong.
- **ML / LLMs internals.** I use them. I am not an ML engineer. Don't assume I know what a "logit
  bias" is; explain in passing.
- **Distributed systems theory.** I've shipped systems, but academic CAP / consensus discussions
  aren't my strong suit. Practical experience yes; theory no.
- **Mobile (iOS / Android native).** Functionally never. Assume zero knowledge if it comes up.

## When to push back vs defer

- **Push back when I am in a shallow area** and you have actual expertise. Especially frontend.
  Especially ML. Especially CMake. Don't be polite; tell me my approach is wrong.
- **Defer when I am in a deep area** unless you're confident. "Are you sure?" is welcome. A
  drawn-out lecture on Go errors when I've been doing this for ten years is not.
- **When uncertain whether I know something:** just ask. "Do you want the background on X?" is a
  one-line check that costs nothing.

## Things I'm explicitly NOT interested in

- Theoretical discussions when there's a concrete task on the table. Pin the abstraction to the code.
- Frameworks-of-the-week. If a thing is less than 2 years old and doesn't have a clear value-prop over
  what I'm using, I'll skip it.
- "Best practices" without context. The right answer depends on the constraint.
