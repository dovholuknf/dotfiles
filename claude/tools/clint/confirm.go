package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A model can find the messages where Clint was annoyed, but not what annoyed him. confirm shows each one with the
// reply before it and asks whether the complaint was about the wording. label applies the answers: a yes is a strong
// style reject, a no is a weak accept, since that reply was not rejected for how it read.

type confirmItem struct {
	Text   string `json:"text"`   // the reply
	Prompt string `json:"prompt"` // the message after it
	Source string `json:"source"` // what flagged it
}

type confirmAnswer struct {
	Key     string `json:"key"`
	Wording bool   `json:"wording"`
	Skipped bool   `json:"skipped,omitempty"`
	At      string `json:"at"`
}

func confirmed(dir string) (map[string]confirmAnswer, error) {
	as, err := readJSONL[confirmAnswer](filepath.Join(dir, "confirm-answers.jsonl"))
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	m := map[string]confirmAnswer{}
	for _, a := range as {
		m[a.Key] = a // the last answer wins, so b can redo one
	}
	return m, nil
}

func runConfirm(args []string) error {
	fl := flag.NewFlagSet("confirm", flag.ExitOnError)
	dir := fl.String("data", dataDir(), "data folder")
	in := fl.String("in", "", "candidates, one {text, prompt, source} per line (default <data>/confirm-candidates.jsonl)")
	fl.Parse(args)
	if *in == "" {
		*in = filepath.Join(*dir, "confirm-candidates.jsonl")
	}
	items, err := readJSONL[confirmItem](*in)
	if err != nil {
		return err
	}
	done, err := confirmed(*dir)
	if err != nil {
		return err
	}
	out := filepath.Join(*dir, "confirm-answers.jsonl")
	color := enableVT() && os.Getenv("NO_COLOR") == ""
	hi := func(s string) string {
		if color {
			return ansiHi + s + ansiReset
		}
		return ">> " + s
	}
	dim := func(s string) string {
		if color {
			return "\x1b[2m" + s + ansiReset
		}
		return s
	}
	fmt.Printf(`
  You were annoyed after each of these replies. Was it at the wording?

  y   yes   too long, jargon, filler, a phrase or name you hate, not your voice
  n   no    a bug, slow or ugly UI, something it did, a wrong fact, a bad plan
  s   skip  can't tell
  b   back  redo the last one
  q   quit  everything's saved, rerun to pick up

  %d of %d done. Answers go to %s, and label applies them.

`, len(done), len(items), out)
	r := bufio.NewReader(os.Stdin)
	var hist []int
	for i := 0; i < len(items); i++ {
		it := items[i]
		key := reactKey(it.Text, it.Prompt)
		if _, ok := done[key]; ok {
			continue
		}
		fmt.Printf("\n[%d/%d] %s\n\n%s\n\n%s\n\n", i+1, len(items), it.Source, dim(block(clip(it.Text, 700))),
			hi(it.Prompt))
		for {
			fmt.Print("wording? y, n, s, b, q > ")
			line, err := r.ReadString('\n')
			if err != nil && line == "" {
				return nil
			}
			a := confirmAnswer{Key: key, At: time.Now().Format(time.RFC3339)}
			switch strings.ToLower(strings.TrimSpace(line)) {
			case "y":
				a.Wording = true
			case "n":
			case "s":
				a.Skipped = true
			case "q":
				return nil
			case "b":
				if len(hist) == 0 {
					fmt.Println("nothing to undo")
					continue
				}
				// forget the last answer in memory; the redo appends a newer one, which wins
				prev := hist[len(hist)-1]
				hist = hist[:len(hist)-1]
				delete(done, reactKey(items[prev].Text, items[prev].Prompt))
				i = prev - 1
			default:
				fmt.Println("y, n, s, b or q")
				continue
			}
			if line = strings.ToLower(strings.TrimSpace(line)); line != "b" {
				if _, err := appendJSONL(out, a); err != nil {
					return err
				}
				done[key] = a
				hist = append(hist, i)
			}
			break
		}
	}
	fmt.Println("\nall done. Run clint label, then clint train.")
	return nil
}
