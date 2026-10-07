// clint checks text against how Clint wants to read it. lint flags known LLM tells by rule, score rates the text
// with a small model trained on replies rewritten under his rules and on his real reactions, and mcp serves both to
// agents over stdio.
package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const usage = `usage (every command reads stdin when no file is given):
  clint check [file ...]             lint plus score, PASS or FAIL, exit 1 on FAIL
  clint lint  [-json] [file ...]     flag LLM tells, exit 1 on any error-level hit
  clint score [-json] [file ...]     0-1 clint score, plus the least clint-like paragraphs
  clint label [-projects d] [-out f]  label assistant replies by the prompt that followed
  clint synth [-endpoint u] [-model m] [-count n]
                                           rewrite new replies under /clintify with a local LLM, giving pairs
  clint train [-data dir] [-out f]     train from pairs*.jsonl, authored*.jsonl and labels*.jsonl
  clint grill [-status] [-live]        write your own replies to 34 scenarios, then to your own transcripts
  clint grill -file f [-punct]         keep, cut or retype a document one sentence at a time
  clint confirm [-in f]              say whether each flagged complaint was about wording
  clint rw                           UserPromptSubmit hook: rw: <text> saves your version of the last reply
  clint mcp                          serve clint_check and the grill tools over stdio`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	code := 0
	switch os.Args[1] {
	case "check":
		code, err = runCheck(os.Args[2:])
	case "lint":
		code, err = runLint(os.Args[2:])
	case "score":
		err = runScore(os.Args[2:])
	case "label":
		err = runLabel(os.Args[2:])
	case "synth":
		err = runSynth(os.Args[2:])
	case "train":
		err = runTrain(os.Args[2:])
	case "confirm":
		err = runConfirm(os.Args[2:])
	case "rw":
		err = runRW(os.Args[2:])
	case "grill":
		err = runGrill(os.Args[2:])
	case "mcp":
		err = runMCP(os.Stdin, os.Stdout)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "clint:", err)
		os.Exit(2)
	}
	os.Exit(code)
}

// dataDir holds the model and its training data. Both come from private transcripts, so they live outside the repo.
// CLINT_DATA overrides it, so two accounts can share one model and its data.
func dataDir() string {
	if d := os.Getenv("CLINT_DATA"); d != "" {
		return d
	}
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "clint")
}

func defaultModelPath() string { return filepath.Join(dataDir(), "model.bin") }

type input struct {
	name string
	text string
}

func readInputs(files []string) ([]input, error) {
	if len(files) == 0 || (len(files) == 1 && files[0] == "-") {
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			return nil, err
		}
		return []input{{"<stdin>", string(b)}}, nil
	}
	var out []input
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		out = append(out, input{f, string(b)})
	}
	return out, nil
}
