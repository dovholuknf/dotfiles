package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// a reply is rejected on style when the next prompt complains about how it was written, not what it said.
// The phrases come from the complaint buckets mined for /clintify.
var styleComplaint = regexp.MustCompile(`(?i)(too long|shorter|terse|fewer words|less words|wall of text|tl;?dr|verbose|` +
	`wordy|condense|em ?dash|semicolon|arch(a)?eolog|stop narrat|don't explain|didn't ask|answer the question|` +
	`what the (fuck|hell) (is|are|does|do you mean)|wtf (is|are|does|do you mean)|i don't understand|don't follow|` +
	`plain (english|words|language)|jargon|word salad|sounds like (an |a )?(llm|ai|robot)|llm (speak|tell|cadence)|` +
	`one (thing )?at a time|lead with|overclaim|hedg|filler|fluff|preamble|define (it|that|this|your)|` +
	`what does .{1,30} mean|make it a table|use bullets|too much (text|detail|info))`)

var accepted = regexp.MustCompile(`(?i)^(y|yes|yep|yeah|yup|ok|okay|k|kk|sure|next|do it|go|go ahead|lfg|perfect|great|` +
	`nice|thanks|thx|ty|cool|good|approved|ship it|sounds good|lgtm|love it|awesome|exactly|correct|right)\b[\s.!,]*.{0,25}$`)

var tagRe = regexp.MustCompile(`(?s)<(system-reminder|command-[a-z]+|local-command-[a-z]+)>.*?</(system-reminder|command-[a-z]+|local-command-[a-z]+)>`)

type labeled struct {
	Text   string  `json:"text"`
	Y      float32 `json:"y"`
	Strong bool    `json:"strong"`
	Prompt string  `json:"prompt"`        // what Clint typed next, which gave the label
	Ask    string  `json:"ask,omitempty"` // what Clint typed before, which the reply answered
	Why    string  `json:"why,omitempty"` // style, content, action, approve or none, when the teacher classified it
	full   string  // the next prompt at classifying length
}

type turn struct {
	Type    string `json:"type"`
	Message struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

// userText returns the typed prompt, or "" for tool results, injected context and relayed agent messages
func userText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) != nil {
		var blocks []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal(raw, &blocks) != nil {
			return ""
		}
		for _, b := range blocks {
			if b.Type == "tool_result" {
				return ""
			}
			if b.Type == "text" {
				s += b.Text + "\n"
			}
		}
	}
	s = strings.TrimSpace(tagRe.ReplaceAllString(s, ""))
	low := strings.ToLower(s)
	for _, p := range machinePrefixes {
		if strings.HasPrefix(low, p) {
			return ""
		}
	}
	if strings.HasPrefix(s, "<") || strings.HasPrefix(s, "This session is being continued") {
		return ""
	}
	return s
}

func assistantText(raw json.RawMessage) string {
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) != nil {
		return ""
	}
	var b strings.Builder
	for _, c := range blocks {
		if c.Type == "text" {
			b.WriteString(c.Text + "\n\n")
		}
	}
	return strings.TrimSpace(b.String())
}

var pairs int

var pastedTag = regexp.MustCompile(`(?s)<pasted_content[^>]*>.*?</pasted_content>`)

func promptKey(s string) string {
	s = pastedRe.ReplaceAllString(pastedTag.ReplaceAllString(s, " "), " ")
	s = strings.Join(strings.Fields(strings.ToLower(s)), " ")
	if r := []rune(s); len(r) > 40 {
		s = string(r[:40])
	}
	return s
}

// typedPrompts holds the start of every prompt in history.jsonl. A transcript "user" turn that is not in it was
// sent by a hook, a skill or another agent, not typed by Clint.
func typedPrompts(path string) (map[string]bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	keys := map[string]bool{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		var rec struct {
			Display string `json:"display"`
		}
		if json.Unmarshal(sc.Bytes(), &rec) == nil && rec.Display != "" {
			keys[promptKey(rec.Display)] = true
		}
	}
	return keys, sc.Err()
}

// labelTranscripts pairs the last assistant prose before each typed prompt with a label read from that prompt.
// Explicit approval or a style complaint is a strong label. Any other typed prompt moved on without complaining,
// which is a weak accept.
func labelTranscripts(root string, typed map[string]bool) ([]labeled, error) {
	var out []labeled
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".jsonl") {
			return nil
		}
		f, err := os.Open(p)
		if err != nil {
			return nil
		}
		defer f.Close()
		r := bufio.NewReaderSize(f, 1<<20)
		last, ask := "", ""
		for {
			line, rerr := r.ReadBytes('\n')
			var t turn
			if len(line) > 0 && json.Unmarshal(line, &t) == nil {
				switch {
				case t.Type == "assistant":
					if s := assistantText(t.Message.Content); s != "" {
						last = s
					}
				case t.Type == "user":
					prompt := userText(t.Message.Content)
					if prompt == "" || !typed[promptKey(prompt)] {
						break
					}
					if last != "" {
						pairs++
						head := pastedTag.ReplaceAllString(prompt, " ")
						if len(head) > 400 {
							head = head[:400]
						}
						l := labeled{Text: last, Y: 1, Prompt: clip(prompt, 160), Ask: clip(ask, 400),
							full: clip(pastedTag.ReplaceAllString(prompt, "[pasted text]"), 800)}
						switch {
						case styleComplaint.MatchString(head):
							l.Y, l.Strong = 0, true
						case accepted.MatchString(strings.TrimSpace(head)):
							l.Strong = true
						}
						out = append(out, l)
					}
					last, ask = "", prompt
				}
			}
			if rerr != nil {
				return nil
			}
		}
	})
	return out, err
}

func runLabel(args []string) error {
	home, _ := os.UserHomeDir()
	fl := flag.NewFlagSet("label", flag.ExitOnError)
	proj := fl.String("projects", filepath.Join(home, ".claude", "projects"), "transcripts")
	out := fl.String("out", filepath.Join(dataDir(), "labels.jsonl"), "labeled replies")
	endpoint := fl.String("endpoint", "", "OpenAI-compatible endpoint to classify each reaction, instead of the word list")
	model := fl.String("model", "local", "model name at -endpoint")
	parallel := fl.Int("parallel", 4, "requests at once")
	fl.Parse(args)
	typed, err := typedPrompts(filepath.Join(home, ".claude", "history.jsonl"))
	if err != nil {
		return err
	}
	ls, err := labelTranscripts(*proj, typed)
	if err != nil {
		return err
	}
	if *endpoint != "" {
		cache := filepath.Join(filepath.Dir(*out), "reactions.jsonl")
		if err := classifyReactions(ls, *endpoint, *model, *parallel, cache); err != nil {
			return err
		}
	}
	conf, err := confirmed(filepath.Dir(*out))
	if err != nil {
		return err
	}
	applied := 0
	for i := range ls {
		if a, ok := conf[reactKey(ls[i].Text, ls[i].Prompt)]; ok && !a.Skipped {
			applied++
			if a.Wording {
				ls[i].setWhy("style")
			} else {
				ls[i].setWhy("none")
			}
		}
	}
	if applied > 0 {
		fmt.Printf("%d labels set by clint confirm\n", applied)
	}
	f, err := os.Create(*out)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	strongPos, rej := 0, 0
	for _, l := range ls {
		enc.Encode(l)
		if l.Y == 0 {
			rej++
		} else if l.Strong {
			strongPos++
		}
	}
	fmt.Printf("%d typed prompt/reply pairs: %d rejected on style, %d approved, %d moved on, wrote %s\n",
		pairs, rej, strongPos, len(ls)-rej-strongPos, *out)
	return nil
}
