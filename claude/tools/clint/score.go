package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
)

type paraScore struct {
	Line  int     `json:"line"`
	Score float64 `json:"score"`
	Text  string  `json:"text"`
}

type scoreResult struct {
	File   string      `json:"file"`
	Score  float64     `json:"score"`
	Worst  []paraScore `json:"worst"`
	Graded int         `json:"paragraphs"`
}

// scoreText rates the whole text and returns the three lowest-scoring paragraphs under 0.5
func scoreText(m *model, name, text string) scoreResult {
	res := scoreResult{File: name, Score: m.prob(features(text))}
	var paras []paraScore
	lines := strings.Split(text, "\n")
	start, fence := 0, false
	flush := func(end int) {
		raw := strings.Join(lines[start:end], "\n")
		if n := normalize(raw); len(n) >= 40 {
			paras = append(paras, paraScore{start + 1, m.prob(features(raw)), clip(strings.TrimSpace(raw), 100)})
		}
	}
	for i, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), "```") {
			fence = !fence
		}
		if !fence && strings.TrimSpace(l) == "" {
			flush(i)
			start = i + 1
		}
	}
	flush(len(lines))
	res.Graded = len(paras)
	// whole-text features punish length, so a long document is rated by its average paragraph instead
	if len(paras) >= 3 {
		sum := 0.0
		for _, p := range paras {
			sum += p.Score
		}
		res.Score = sum / float64(len(paras))
	}
	sort.Slice(paras, func(i, j int) bool { return paras[i].Score < paras[j].Score })
	for _, p := range paras {
		if p.Score >= 0.5 || len(res.Worst) == 3 {
			break
		}
		res.Worst = append(res.Worst, p)
	}
	return res
}

func clip(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "..."
	}
	return s
}

func formatScore(r scoreResult) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s: %.2f clint (%d paragraphs graded)\n", r.File, r.Score, r.Graded)
	for _, p := range r.Worst {
		fmt.Fprintf(&b, "  line %d: %.2f %s\n", p.Line, p.Score, p.Text)
	}
	return b.String()
}

func runScore(args []string) error {
	fs := flag.NewFlagSet("score", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "emit json")
	path := fs.String("model", defaultModelPath(), "model file")
	fs.Parse(args)
	m, err := loadModel(*path)
	if err != nil {
		return err
	}
	ins, err := readInputs(fs.Args())
	if err != nil {
		return err
	}
	var out []scoreResult
	for _, in := range ins {
		out = append(out, scoreText(m, in.name, in.text))
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(out)
	}
	for _, r := range out {
		fmt.Print(formatScore(r))
	}
	return nil
}
