package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// clint grill -file walks a markdown or text file one sentence at a time. Each sentence is shown inside its whole
// paragraph, highlighted, and the user keeps it, cuts it or types their own version. Kept and cut sentences become
// labels, typed versions become pairs, and the edited file is written next to the original.

type rvSent struct {
	id, text string
}

// rvUnit is a paragraph, or one item of a list, which is what gets rewrapped when a sentence in it changes
type rvUnit struct {
	prefix string // list marker and indent, "" for a plain paragraph
	lines  []string
	sents  []rvSent
}

type rvBlock struct {
	lines []string
	units []*rvUnit // nil for code, headings, tables and other blocks that are not prose
}

type rvDecision struct {
	ID      string    `json:"id"`
	File    string    `json:"file"`
	Text    string    `json:"text"`
	Action  string    `json:"action"` // keep, cut, rewrite, or "" when undone
	Rewrite string    `json:"rewrite,omitempty"`
	At      time.Time `json:"at"`
}

var (
	listRe     = regexp.MustCompile(`^(\s*(?:[-*+]|\d+[.)])\s+)`)
	sentEndRe  = regexp.MustCompile(`[.!?]["'”’)\]*_]*\s+`)
	abbrevRe   = regexp.MustCompile(`(?i)(\be\.g|\bi\.e|\bvs|\betc|\bmr|\bdr|\bno)\.["')\]]*\s+$`)
	punctRe    = regexp.MustCompile(`—|–| -- |;|:|!|\(`)
	nonProseRe = regexp.MustCompile(`^\s*(#|\||<|!\[|>|---\s*$|\*\*\*\s*$)`)
)

// splitSentences breaks a paragraph after . ! or ? followed by whitespace, unless that ends a common abbreviation
func splitSentences(s string) []string {
	var out []string
	start := 0
	for _, loc := range sentEndRe.FindAllStringIndex(s, -1) {
		if abbrevRe.MatchString(s[start:loc[1]]) {
			continue
		}
		if t := strings.TrimSpace(s[start:loc[1]]); t != "" {
			out = append(out, t)
		}
		start = loc[1]
	}
	if t := strings.TrimSpace(s[start:]); t != "" {
		out = append(out, t)
	}
	return out
}

func parseReview(path, src string) []*rvBlock {
	var blocks []*rvBlock
	var cur []string
	fence := false
	flush := func() {
		if len(cur) > 0 {
			blocks = append(blocks, &rvBlock{lines: cur})
			cur = nil
		}
	}
	for _, l := range strings.Split(strings.ReplaceAll(src, "\r", ""), "\n") {
		if strings.HasPrefix(strings.TrimSpace(l), "```") {
			if !fence {
				flush()
			}
			fence = !fence
			cur = append(cur, l)
			if !fence {
				blocks = append(blocks, &rvBlock{lines: cur}) // a code block is never prose
				cur = nil
			}
			continue
		}
		if !fence && strings.TrimSpace(l) == "" {
			flush()
			blocks = append(blocks, &rvBlock{lines: []string{l}})
			continue
		}
		cur = append(cur, l)
	}
	flush()
	for bi, b := range blocks {
		first := b.lines[0]
		if strings.TrimSpace(first) == "" || strings.HasPrefix(strings.TrimSpace(first), "```") ||
			nonProseRe.MatchString(first) {
			continue
		}
		var u *rvUnit
		for _, l := range b.lines {
			if m := listRe.FindString(l); m != "" {
				u = &rvUnit{prefix: m, lines: []string{strings.TrimSpace(l[len(m):])}}
				b.units = append(b.units, u)
			} else if u == nil {
				u = &rvUnit{lines: []string{strings.TrimSpace(l)}}
				b.units = append(b.units, u)
			} else {
				u.lines = append(u.lines, strings.TrimSpace(l))
			}
		}
		for ui, u := range b.units {
			for _, s := range splitSentences(strings.Join(u.lines, " ")) {
				h := sha1.Sum([]byte(fmt.Sprintf("%s\x00%d\x00%d\x00%s", path, bi, ui, s)))
				u.sents = append(u.sents, rvSent{id: hex.EncodeToString(h[:6]), text: s})
			}
		}
	}
	return blocks
}

type review struct {
	dir, file, out string
	blocks         []*rvBlock
	dec            map[string]rvDecision
}

func (r *review) record(d rvDecision) error {
	d.File, d.At = r.file, time.Now()
	if _, err := appendJSONL(filepath.Join(r.dir, "review-answers.jsonl"), d); err != nil {
		return err
	}
	r.dec[d.ID] = d
	return r.writeOutputs()
}

// writeOutputs rebuilds the labels and pairs from every file reviewed so far. The edited copy of the file is written
// when the review stops, since it is rebuilt from the decisions anyway.
func (r *review) writeOutputs() error {
	var labels, pairs strings.Builder
	le, pe := json.NewEncoder(&labels), json.NewEncoder(&pairs)
	for _, d := range r.dec {
		switch d.Action {
		case "keep":
			le.Encode(labeled{Text: d.Text, Y: 1, Strong: true, Prompt: "kept in clint grill -file"})
		case "cut":
			le.Encode(labeled{Text: d.Text, Y: 0, Strong: true, Prompt: "cut in clint grill -file"})
		case "rewrite":
			pe.Encode(pair{Orig: d.Text, Rewrite: d.Rewrite})
		}
	}
	if err := writeRetry(filepath.Join(r.dir, "labels-review.jsonl"), labels.String()); err != nil {
		return err
	}
	return writeRetry(filepath.Join(r.dir, "pairs-review.jsonl"), pairs.String())
}

// writeRetry retries a write for a moment, since a virus scanner often holds a file just after it changes
func writeRetry(path, body string) error {
	var err error
	for range 10 {
		if err = os.WriteFile(path, []byte(body), 0o644); err == nil {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return err
}

// edited returns the file with every decision applied. Paragraphs nobody changed keep their original lines.
func (r *review) edited() string {
	var out []string
	for _, b := range r.blocks {
		if b.units == nil || !r.changed(b) {
			out = append(out, b.lines...)
			continue
		}
		for _, u := range b.units {
			changed := false
			var kept []string
			for _, s := range u.sents {
				switch d := r.dec[s.id]; d.Action {
				case "cut":
					changed = true
				case "rewrite":
					changed = true
					kept = append(kept, d.Rewrite)
				default:
					kept = append(kept, s.text)
				}
			}
			switch {
			case !changed:
				out = append(out, u.prefix+u.lines[0])
				for _, l := range u.lines[1:] {
					out = append(out, strings.Repeat(" ", len(u.prefix))+l)
				}
			case len(kept) > 0:
				out = append(out, wrapPrefixed(strings.Join(kept, " "), u.prefix, 120)...)
			}
		}
	}
	return strings.Join(out, "\n")
}

func (r *review) changed(b *rvBlock) bool {
	for _, u := range b.units {
		for _, s := range u.sents {
			if a := r.dec[s.id].Action; a == "cut" || a == "rewrite" {
				return true
			}
		}
	}
	return false
}

func wrapPrefixed(s, prefix string, width int) []string {
	var out []string
	cur, pad := prefix, strings.Repeat(" ", len(prefix))
	for _, w := range strings.Fields(s) {
		if strings.TrimSpace(cur) != "" && len(cur)+1+len(w) > width {
			out = append(out, cur)
			cur = pad
		}
		if strings.TrimSpace(cur) != "" {
			cur += " "
		}
		cur += w
	}
	return append(out, cur)
}

const (
	ansiHi    = "\x1b[38;2;255;255;255;48;2;95;130;180m" // the sentence being asked about: white on steel blue
	ansiCut   = "\x1b[2;9m"
	ansiNew   = "\x1b[32m"
	ansiReset = "\x1b[0m"
)

var plainMarks = map[string][2]string{ansiHi: {">>", "<<"}, ansiCut: {"~~", "~~"}, ansiNew: {"[", "]"}}

// render prints a block wrapped at 100 columns, with the current sentence highlighted, cut sentences struck through
// and typed versions in green. Colors are applied per word so wrapping never splits an escape code.
func (r *review) render(b *rvBlock, current string, color bool) string {
	type word struct{ text, style string }
	var lines []string
	for _, u := range b.units {
		var ws []word
		for _, s := range u.sents {
			text, style := s.text, ""
			switch d := r.dec[s.id]; {
			case s.id == current:
				style = ansiHi
			case d.Action == "cut":
				style = ansiCut
			case d.Action == "rewrite":
				text, style = d.Rewrite, ansiNew
			}
			for _, f := range strings.Fields(text) {
				ws = append(ws, word{f, style})
			}
		}
		cur, n := "    "+u.prefix, 4+len(u.prefix)
		pad := strings.Repeat(" ", n)
		fresh := true
		open := "" // the style in effect, so a run of words and the spaces between them share one color
		style := func(s string) {
			if !color || s == open {
				return
			}
			if open != "" {
				cur += ansiReset
			}
			cur += s
			open = s
		}
		for i, w := range ws {
			if !fresh && n+1+len(w.text) > 104 {
				style("")
				lines = append(lines, cur)
				cur, n, fresh = pad, len(pad), true
			}
			if !fresh {
				if ws[i-1].style != w.style {
					style("")
				}
				cur += " "
				n++
			}
			text := w.text
			if m, ok := plainMarks[w.style]; ok && !color {
				// without color, marks show where the current, cut or retyped sentence starts and ends
				if i == 0 || ws[i-1].style != w.style {
					text = m[0] + text
				}
				if i == len(ws)-1 || ws[i+1].style != w.style {
					text += m[1]
				}
			}
			style(w.style)
			cur += text
			n += len(text)
			fresh = false
		}
		style("")
		lines = append(lines, cur)
	}
	return strings.Join(lines, "\n")
}

func runReview(dir, file string, punctOnly bool) error {
	src, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	abs, _ := filepath.Abs(file)
	ext := filepath.Ext(abs)
	r := &review{dir: dir, file: abs, out: strings.TrimSuffix(abs, ext) + ".clint" + ext,
		blocks: parseReview(abs, string(src)), dec: map[string]rvDecision{}}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	old, err := readJSONL[rvDecision](filepath.Join(dir, "review-answers.jsonl"))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, d := range old {
		r.dec[d.ID] = d // every file's decisions, so the labels and pairs cover all of them
	}
	type stop struct {
		b *rvBlock
		s rvSent
	}
	var stops []stop
	for _, b := range r.blocks {
		for _, u := range b.units {
			for _, s := range u.sents {
				if !punctOnly || punctRe.MatchString(s.text) {
					stops = append(stops, stop{b, s})
				}
			}
		}
	}
	if len(stops) == 0 {
		return fmt.Errorf("no sentences to review in %s", file)
	}
	color := enableVT() && os.Getenv("NO_COLOR") == ""
	in := bufio.NewReader(os.Stdin)
	readLine := func() (string, bool) {
		l, err := in.ReadString('\n')
		return strings.TrimRight(l, "\r\n"), err == nil || l != ""
	}
	done := 0
	for _, st := range stops {
		if a := r.dec[st.s.id].Action; a != "" {
			done++
		}
	}
	if done == 0 {
		fmt.Printf("\n[0/%d]\n\n%s\n\nEnter to start > ", len(stops),
			reviewHelp(len(stops), filepath.Base(abs), filepath.Base(r.out)))
		if l, ok := readLine(); !ok || strings.TrimSpace(l) == "q" {
			return nil
		}
	} else {
		fmt.Printf("%d of %d done. ? for help\n",
			done, len(stops))
	}
	for i := 0; i < len(stops); {
		st := stops[i]
		if _, done := r.dec[st.s.id]; done && r.dec[st.s.id].Action != "" {
			i++
			continue
		}
		fmt.Printf("\n[%d/%d]\n\n%s\n\n", i+1, len(stops), r.render(st.b, st.s.id, color))
		fmt.Print("Enter keep, r rewrite, c cut, s skip, ? help > ")
		l, ok := readLine()
		if !ok {
			return r.finish(fmt.Sprintf("stopped at %d of %d", i+1, len(stops)))
		}
		d := rvDecision{ID: st.s.id, Text: st.s.text}
		switch strings.ToLower(strings.TrimSpace(l)) {
		case "", "k":
			d.Action = "keep"
		case "c":
			d.Action = "cut"
		case "r":
			fmt.Print("yours (empty cancels) > ")
			t, _ := readLine()
			if strings.TrimSpace(t) == "" {
				continue
			}
			d.Action, d.Rewrite = "rewrite", strings.TrimSpace(t)
		case "s":
			d.Action = "skip"
		case "b":
			for i > 0 {
				i--
				if a := r.dec[stops[i].s.id].Action; a != "" {
					if err := r.record(rvDecision{ID: stops[i].s.id, Text: stops[i].s.text}); err != nil {
						return err
					}
					break
				}
			}
			continue
		case "q":
			return r.finish(fmt.Sprintf("stopped at %d of %d", i+1, len(stops)))
		case "?", "h":
			fmt.Printf("\n%s\n", reviewHelp(len(stops), filepath.Base(abs), filepath.Base(r.out)))
			continue
		default:
			fmt.Println("Enter, r, c, s, b, q or ?")
			continue
		}
		if err := r.record(d); err != nil {
			return err
		}
		i++
	}
	return r.finish("done")
}

func reviewHelp(n int, file, out string) string {
	return fmt.Sprintf(`  %s, one sentence at a time, highlighted in its paragraph. %d sentences.

  Enter  keep     you'd write it like that
  r      rewrite  right point, wrong words. Type yours. Best signal
  c      cut      shouldn't be there at all
  s      skip     can't judge it: code, quotes, lists, a bad split. Or it's wrong but reads fine
  b      back     undo the last one
  ?      help     this screen
  q      quit     everything's saved, rerun to pick up

  Edits go to %s.`, file, n, out)
}
func (r *review) finish(how string) error {
	if err := r.writeOutputs(); err != nil {
		return err
	}
	if err := writeRetry(r.out, r.edited()); err != nil {
		return err
	}
	fmt.Printf("\n%s. Edited file: %s\nTraining data in %s: labels-review.jsonl, pairs-review.jsonl\n", how, r.out, r.dir)
	return nil
}
