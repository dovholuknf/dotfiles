# statusline

The Claude Code status line as one Go binary with no dependencies. It reads the statusline JSON on stdin and prints
the cwd, branch, clock, 5h and weekly limits, context fill, transcript size, and the tokens spent since the last
prompt.

It is a port of `claude/statusline-command.sh` and keeps its output and state files byte for byte: the usage log
(`~/.claude/usage-log.jsonl`) and the per-session state under `~/.claude/usage-log.state` and
`~/.claude/statusline-ctx.state`. Either one can take over mid-session. The bash version spawns jq, git, stat and
tail and takes 280 to 450 ms per render on Windows. This takes about 12 ms. It reads the branch from `.git/HEAD`
directly, so it spawns nothing.

## Build

```powershell
cd D:\git\github\dovholuknf\dotfiles\claude\tools\statusline
go build -trimpath -ldflags "-s -w" -o build.claude\statusline.exe .
```

## Use

In `claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "D:/git/github/dovholuknf/dotfiles/claude/tools/statusline/build.claude/statusline.exe"
}
```
