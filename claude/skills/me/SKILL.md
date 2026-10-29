---
name: me
description: Load clint's agent-context pack (how he works, writes, reviews, and what he expects) and adopt it for the rest of the session. Slash-only.
disable-model-invocation: true
---

# me

Read `agents/load.md` in the dotfiles checkout and follow it exactly, including its confirmation reply.

Find the checkout from `$env:DOTFILES` (`D:/git/github/dovholuknf/dotfiles` on clint's Windows box). If that is
unset or the file is missing, look for a `dovholuknf/dotfiles` clone on this machine. If there is none and
`atrium_git_url` is available, call it and fetch `agents/` for `dovholuknf/dotfiles` from the URL it gives. If none
of those works, say the pack is not reachable from this machine. Do not reply from memory.

If the user typed more after `/me`, answer it after the confirmation, under the loaded rules.
