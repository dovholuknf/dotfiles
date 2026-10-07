package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const synthInstructions = `You rewrite assistant chat replies for one reader. The rules below are theirs. Apply them to the reply you are given.

%s

This is an edit, not a reply. Hard limits on the edit:
- Keep every fact, warning, condition, path, number and command. A constraint like "never in the repo" or "it needs
  your login" must survive.
- Never open with "Done." unless the original says it.
- Add nothing. No new questions, no Open Questions block, no offers, no claims that something was done. Only keep a
  question if the original asks it.
- Never change who does what. If the original tells the reader to run something, the rewrite still tells the reader.
- Write normal grammatical English: full sentences with articles ("the daemon", "a session"), subject first.
  Shorten by cutting whole sentences and filler, never by dropping articles or verbs. Telegraphic text is as wrong
  as padded text.

Output ONLY the rewritten reply. No preamble, no note about what you changed, no code fence around it. If the reply
already follows the rules, output it unchanged.`

var thinkRe = regexp.MustCompile(`(?s)<think>.*?</think>`)

// chat sends one completion request to an OpenAI-compatible endpoint, such as ollama or llama.cpp's server
func chat(client *http.Client, endpoint, model, system, user string) (string, error) {
	return chatAt(client, endpoint, model, system, user, 0.3)
}

func chatAt(client *http.Client, endpoint, model, system, user string, temp float64) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"model":       model,
		"temperature": temp,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": user},
		},
	})
	req, err := http.NewRequest("POST", strings.TrimRight(endpoint, "/")+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if key := os.Getenv("CLINT_API_KEY"); key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Error any `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("%s: %w", resp.Status, err)
	}
	if resp.StatusCode != 200 || len(out.Choices) == 0 {
		return "", fmt.Errorf("%s: %v", resp.Status, out.Error)
	}
	return strings.TrimSpace(thinkRe.ReplaceAllString(out.Choices[0].Message.Content, "")), nil
}

var doneLead = regexp.MustCompile(`(?i)^\W*done\b`)

// usableRewrite drops rewrites that would teach the wrong thing. An unchanged or longer rewrite teaches nothing. One
// under a fifth of the original lost facts, since small teachers collapse whole replies to "Done.". A "Done." the
// original never said is invented, and a rewrite that still fails lint is not a good example.
func usableRewrite(orig, rw string) bool {
	if rw == "" || rw == orig || len(rw) > len(orig) || len(rw) < len(orig)/5 {
		return false
	}
	if doneLead.MatchString(rw) && !doneLead.MatchString(orig) {
		return false
	}
	for _, h := range lintText("", rw) {
		if h.Sev == "error" {
			return false
		}
	}
	return true
}

// defaultRulesPath prefers the rules clint grill wrote from your answers, then the installed /clintify skill, then the
// copy in the repo this binary was built in
func defaultRulesPath(home string) string {
	if grilled := filepath.Join(dataDir(), "rules.md"); fileExists(grilled) {
		return grilled
	}
	installed := filepath.Join(home, ".claude", "skills", "clintify", "SKILL.md")
	if _, err := os.Stat(installed); err == nil {
		return installed
	}
	if exe, err := os.Executable(); err == nil {
		repo := filepath.Join(filepath.Dir(exe), "..", "..", "..", "skills", "clintify", "SKILL.md")
		if _, err := os.Stat(repo); err == nil {
			return repo
		}
	}
	return installed
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// grillExamples shows the teacher up to three rewrites the reader wrote by hand in clint grill, shortest first, so it
// copies their voice instead of guessing at it from the rules
func grillExamples(dir string) string {
	ps, _ := readJSONL[pair](filepath.Join(dir, "pairs-grill.jsonl"))
	if len(ps) == 0 {
		return ""
	}
	sort.Slice(ps, func(i, j int) bool { return len(ps[i].Orig) < len(ps[j].Orig) })
	var b strings.Builder
	b.WriteString("\n\nThe reader rewrote these replies by hand. Match their voice.")
	for _, p := range ps[:min(3, len(ps))] {
		fmt.Fprintf(&b, "\n\nOriginal:\n%s\n\nTheir rewrite:\n%s", p.Orig, p.Rewrite)
	}
	return b.String()
}

func runSynth(args []string) error {
	home, _ := os.UserHomeDir()
	fl := flag.NewFlagSet("synth", flag.ExitOnError)
	labels := fl.String("labels", filepath.Join(dataDir(), "labels.jsonl"), "replies to rewrite, from clint label")
	endpoint := fl.String("endpoint", "http://localhost:11434/v1", "OpenAI-compatible base url (ollama, llama.cpp, vllm)")
	model := fl.String("model", "qwen2.5:7b-instruct", "teacher model name")
	rulesPath := fl.String("rules", defaultRulesPath(home), "the rules to rewrite under")
	count := fl.Int("count", 200, "new replies to rewrite this run")
	parallel := fl.Int("parallel", 2, "concurrent requests")
	out := fl.String("out", "", "pairs file to append to (default pairs-<model>.jsonl next to -labels)")
	fl.Parse(args)

	skill, err := os.ReadFile(*rulesPath)
	if err != nil {
		return err
	}
	rules := strings.SplitN(string(skill), "## Procedure", 2)[0]
	if parts := strings.SplitN(rules, "---", 3); len(parts) == 3 {
		rules = parts[2] // drop the frontmatter
	}
	system := fmt.Sprintf(synthInstructions, strings.TrimSpace(rules)) + grillExamples(filepath.Dir(*labels))
	fmt.Println("rules from", *rulesPath)

	dir := filepath.Dir(*labels)
	if *out == "" {
		*out = filepath.Join(dir, "pairs-"+regexp.MustCompile(`[^A-Za-z0-9.]+`).ReplaceAllString(*model, "-")+".jsonl")
	}

	// a reply already in this teacher's pairs file is skipped, which makes repeated runs incremental
	done := map[string]bool{}
	ps, _ := readJSONL[pair](*out)
	for _, p := range ps {
		done[strings.TrimSpace(p.Orig)] = true
	}
	ls, err := readJSONL[labeled](*labels)
	if err != nil {
		return err
	}
	var todo []string
	seen := map[string]bool{}
	for _, l := range ls {
		t := strings.TrimSpace(l.Text)
		if len(t) >= 150 && len(t) <= 3000 && !done[t] && !seen[t] {
			seen[t] = true
			todo = append(todo, t)
		}
	}
	rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), 7)).Shuffle(len(todo), func(i, j int) { todo[i], todo[j] = todo[j], todo[i] })
	todo = todo[:min(*count, len(todo))]
	fmt.Printf("%d replies to rewrite with %s at %s, %d already done\n", len(todo), *model, *endpoint, len(done))

	f, err := os.OpenFile(*out, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	client := &http.Client{Timeout: 10 * time.Minute}
	var mu sync.Mutex
	var wg sync.WaitGroup
	ch := make(chan string)
	kept, failed, start := 0, 0, time.Now()
	for range *parallel {
		wg.Go(func() {
			for orig := range ch {
				rw, err := chat(client, *endpoint, *model, system, orig)
				mu.Lock()
				switch {
				case err != nil:
					failed++
					fmt.Fprintln(os.Stderr, "synth:", err)
				case !usableRewrite(orig, rw):
				default:
					enc.Encode(pair{Orig: orig, Rewrite: rw})
					kept++
				}
				if n := kept + failed; n%10 == 0 {
					fmt.Printf("%d pairs kept, %d failed (%s)\n", kept, failed, time.Since(start).Round(time.Second))
				}
				mu.Unlock()
			}
		})
	}
	for _, t := range todo {
		ch <- t
	}
	close(ch)
	wg.Wait()
	fmt.Printf("done: %d pairs kept, %d failed, wrote %s (%s)\n", kept, failed, *out, time.Since(start).Round(time.Second))
	return nil
}
