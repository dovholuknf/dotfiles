# clint

A small, fast checker for text Clint will read or that goes out under his name. It is one Go binary with no
dependencies.

- `lint` flags the LLM tells he has banned: em dashes, LLM vocabulary, preambles, sign-offs, lead-in labels and the
  "not X, it's Y" cadence. Rules live in `lint.go` and follow the Never list in `claude/skills/clintify/SKILL.md`.
- `score` rates text from 0 to 1 with a hashed n-gram logistic regression model (256 KB, int8). It also lists the
  paragraphs that scored lowest.
- `check` runs both and prints PASS or FAIL. It fails on any lint error or a score under 0.5.
- `grill` shows you about 40 scenarios with an LLM's reply and has you write your own, so someone other than Clint
  can build their own model.
- `mcp` serves `check` to agents as the `clint_check` tool over stdio, plus the grill as `clint_grill_next` and
  `clint_grill_answer`.

Each call takes about 20 ms.

## Build

```powershell
cd D:\git\github\dovholuknf\dotfiles\claude\tools\clint
go build -trimpath -ldflags "-s -w" -o build.claude\clint.exe .
```

## Use

```powershell
.\build.claude\clint.exe check reply.md
Get-Clipboard | .\build.claude\clint.exe check
```

## Register the MCP server

```powershell
claude mcp add clint -s user -- D:\git\github\dovholuknf\dotfiles\claude\tools\clint\build.claude\clint.exe mcp
```

## Train the model

The model is built from private transcripts, so the model and all training data live in `%LOCALAPPDATA%\clint`
(`os.UserCacheDir()/clint` elsewhere) and are never committed. No step needs Claude. The rewrites come from any
OpenAI-compatible endpoint: ollama, llama.cpp's `llama-server` or vLLM. Set `CLINT_API_KEY` if the endpoint wants a
bearer token.

```powershell
# label every assistant reply by the prompt that followed it: approved, complained about, or moved on
.\build.claude\clint.exe label
# rewrite a sample of those replies under the /clintify rules with a local model, giving original/rewrite pairs.
# the run is incremental: run it again and it skips replies it already rewrote
.\build.claude\clint.exe synth -endpoint http://localhost:11434/v1 -model qwen2.5:7b-instruct -count 2400
# train on the pairs, the authored text and the approved and complained-about replies, then report held-out scores
.\build.claude\clint.exe train
```

`train` also reads any `authored*.jsonl` in the data folder: one `{"text": ...}` per line, written by Clint with no
LLM help, such as blog posts and GitHub comments. Lines starting with `>` are quotes and are dropped.

The pairs carry most of the signal. Each pair has the same content written two ways, so the model learns style rather
than topic. Training on Clint's prompts against assistant replies does not work. That model learns to tell a command
from an explanation, and any explanation scores low however well it is written. See `LESSONS.md` for the rest.

### Train on a different writer

Start with `clint grill`. Each of the 41 scenarios in `grill.txt` shows who asked, what is true, and an LLM's reply
loaded with the usual habits. You write exactly how you would reply. It takes a little over an hour. Answers save as
you go, so stop with `q` and run it again to resume. `-status` shows progress, time left and what has been written.

Asking "is this phrase ok?" does not work. The answer is almost always "it depends", because the same word is fine in
one sentence and grating in the next. A rewrite shows where the line is without anyone having to state it.

Every answer rebuilds three files:

- `pairs-grill.jsonl`: the LLM reply and your rewrite as a pair. `synth` also shows the teacher three of them as
  examples.
- `authored-grill.jsonl`: your replies as text you wrote.
- `rules.md`: the lint hits in the LLM replies, split into the ones you cut every time and the ones you sometimes
  kept, each with an example.

`clint grill -file draft.md` reviews a document one sentence at a time. It shows the whole paragraph with the current
sentence highlighted, and you keep it, cut it or type your own version. Kept and cut sentences go to
`labels-review.jsonl` and typed versions to `pairs-review.jsonl`. The edited document goes to `draft.clint.md`, and
the original is never touched. `-punct` visits only sentences with a dash, semicolon, colon, `!` or parenthesis.

`synth` uses `rules.md` over the /clintify skill when it exists. Pass `-rules` to choose. An agent can run the grill
through the MCP tools `clint_grill_next` and `clint_grill_answer`, or through `grill -next -json` and
`grill -answer <id>` with the answer on stdin.

Then, if you have them, point `label` at your own transcripts, or pass `synth -labels` any jsonl of `{"text": ...}`
LLM replies to rewrite, and drop your own writing in as `authored-*.jsonl`.
