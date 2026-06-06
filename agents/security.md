# security.md

Things to never do. Things that need explicit sign-off.

## Never

- **Never echo or print any environment variable that matches `*TOKEN*`, `*SECRET*`, `*KEY*`,
  `*PASSWORD*`, `*CREDENTIAL*`** to the chat, to logs, or to a file you'll commit. Not even partial.
  Not even to "confirm it's set." `[Test-Path env:FOO]` or `-not [string]::IsNullOrEmpty(...)` is the
  only check you need.
- **Never commit secrets.** If you see a token, key, password, .pem, .pfx, or `~/.aws/credentials` in
  staged content, stop and tell me.
- **Never write secrets into files under a tracked path.** Profile-shaped files (`.profile.ps1`,
  `.bashrc`) that hold tokens live OUTSIDE the dotfiles repo for this reason.
- **Never log a request body that may contain auth headers.** Strip `Authorization` / `Cookie` /
  `X-Api-Key` headers before any logging or echoing.
- **Never `git push --force` to main/master.** Warn me hard even if I ask.

## Needs explicit sign-off

These need a clear "yes, do it" from me, not implicit consent from an earlier authorization:

- Anything that hits a remote with side effects: `git push`, `gh pr create`, `gh issue comment`,
  posting to Slack / Discord / forum.
- Anything destructive: deleting files, dropping db tables, killing processes, `rm -rf`,
  `git branch -D`, force-push.
- Modifying `CMakePresets.json`, `CMakeUserPresets.json`, `vcpkg.json`, triplet files, or vcpkg
  overlay ports. These can trigger expensive rebuilds (openssl, protobuf, etc. -- minutes per).
- Touching CI / CD config when the change isn't strictly the topic of the task.
- Modifying / removing dependencies. The package-manager equivalent of removing code you don't fully
  understand.
- Anything that uploads content to a third-party web service (paste-bins, diagram renderers, gists).
  Those services may cache or index even after delete. Consider whether the content is sensitive.

## When uncertain

Default to ASK. The cost of pausing is one round-trip. The cost of an unwanted action is potentially
hours of recovery, lost work, or a bad message sent to a real human.

## Authorization scope

A user approving an action ONCE does NOT mean they approve it forever. Authorization stands for the
exact scope I specified. Don't generalize "yes, push" to "yes, push anything you do from now on."
Match the scope of your actions to what was actually requested.

## When you find something already wrong

If you discover unexpected state -- unfamiliar files, unknown branches, weird configuration -- DO NOT
clean it up to "fix" your working environment. It may represent in-progress work you don't know
about. Tell me about it. Let me decide whether to delete.
