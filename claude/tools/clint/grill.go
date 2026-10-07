package main

import (
	"bufio"
	"crypto/sha1"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// grill.txt is the scenario bank. It is plain text so anyone can edit or extend it without touching Go.
//
//go:embed grill.txt
var grillBank string

// question is one scenario: who asked, what is true, and the reply an LLM wrote. A live question comes from the
// user's own transcripts instead, so it has the reply they got and what they said next, but no facts.
type question struct {
	ID       string   `json:"id"`
	Ask      string   `json:"ask"`
	True     string   `json:"true,omitempty"`
	Reply    string   `json:"reply"`
	Reaction string   `json:"reaction,omitempty"`
	Marks    []string `json:"marks,omitempty"`
}

type answer struct {
	ID       string    `json:"id"`
	Text     string    `json:"text"`           // the user's reply, exactly as typed
	Same     bool      `json:"same,omitempty"` // the user would send the LLM reply unchanged
	Skipped  bool      `json:"skipped,omitempty"`
	Seconds  float64   `json:"seconds,omitempty"` // time spent answering, 0 when an agent relayed it
	Ask      string    `json:"ask,omitempty"`     // a live question is not in grill.txt, so its answer carries it
	Reply    string    `json:"reply,omitempty"`
	Reaction string    `json:"reaction,omitempty"`
	At       time.Time `json:"at"`
}

// rough seconds per question, until the user's own pace replaces it
const defaultSeconds = 120

const livePrefix = "live-"

func parseQuestions(src string) []question {
	var qs []question
	var cur *question
	var body []string
	flush := func() {
		if cur != nil {
			cur.Reply = strings.TrimSpace(strings.Join(body, "\n"))
			qs = append(qs, *cur)
		}
	}
	for _, l := range strings.Split(strings.ReplaceAll(src, "\r", ""), "\n") {
		head := cur != nil && len(body) == 0
		switch {
		case strings.HasPrefix(l, "#") && cur == nil: // comments only come before the first block
		case strings.HasPrefix(l, "[reply ") && strings.HasSuffix(l, "]"):
			flush()
			cur, body = &question{ID: strings.TrimSuffix(strings.TrimPrefix(l, "[reply "), "]")}, nil
		case head && strings.HasPrefix(l, "ask: "):
			cur.Ask = strings.TrimPrefix(l, "ask: ")
		case head && strings.HasPrefix(l, "true: "):
			cur.True = strings.TrimPrefix(l, "true: ")
		case head && strings.HasPrefix(l, "mark: "):
			cur.Marks = append(cur.Marks, strings.TrimPrefix(l, "mark: "))
		case cur != nil:
			body = append(body, l)
		}
	}
	flush()
	return qs
}

type grill struct {
	dir     string
	qs      []question
	answers map[string]answer
}

func loadGrill(dir string) (*grill, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	g := &grill{dir: dir, qs: parseQuestions(grillBank), answers: map[string]answer{}}
	as, err := readJSONL[answer](filepath.Join(dir, "grill-answers.jsonl"))
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	for _, a := range as {
		g.answers[a.ID] = a // the last answer for an id wins, so a redo replaces the old one
	}
	return g, nil
}

func (g *grill) find(id string) (question, bool) {
	for _, q := range g.qs {
		if q.ID == id {
			return q, true
		}
	}
	return question{}, false
}

func (g *grill) next() (question, bool) {
	for _, q := range g.qs {
		if _, done := g.answers[q.ID]; !done {
			return q, true
		}
	}
	return question{}, false
}

// pace is the user's own average seconds per answer once there are a few timed answers
func (g *grill) pace() float64 {
	sum, n := 0.0, 0
	for _, a := range g.answers {
		if a.Seconds > 0 && !a.Skipped {
			sum, n = sum+a.Seconds, n+1
		}
	}
	if n < 3 {
		return defaultSeconds
	}
	return sum / float64(n)
}

// progress counts the scenarios in grill.txt. Live questions never run out, so they are not part of it.
func (g *grill) progress() (done, total int, spent, left time.Duration) {
	for _, q := range g.qs {
		total++
		if a, ok := g.answers[q.ID]; ok {
			done++
			spent += time.Duration(a.Seconds * float64(time.Second))
		} else {
			left += time.Duration(g.pace() * float64(time.Second))
		}
	}
	return done, total, spent, left
}

// record saves one answer and rebuilds every file derived from the answers, so quitting at any point loses nothing
func (g *grill) record(a answer) error {
	a.At = time.Now()
	f, err := os.OpenFile(filepath.Join(g.dir, "grill-answers.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	err = json.NewEncoder(f).Encode(a)
	f.Close()
	if err != nil {
		return err
	}
	g.answers[a.ID] = a
	return g.writeOutputs()
}

type item struct {
	q question
	a answer
}

// mine is the user's version of the reply: what they typed, or the LLM reply itself when they kept it
func (it item) mine() string {
	if it.a.Same {
		return it.q.Reply
	}
	return it.a.Text
}

// items is every answered question, grill.txt first in its order, then live ones oldest first
func (g *grill) items() []item {
	var out, live []item
	for _, q := range g.qs {
		if a, ok := g.answers[q.ID]; ok && !a.Skipped {
			out = append(out, item{q, a})
		}
	}
	for id, a := range g.answers {
		if strings.HasPrefix(id, livePrefix) && !a.Skipped {
			live = append(live, item{question{ID: id, Ask: a.Ask, Reply: a.Reply, Reaction: a.Reaction}, a})
		}
	}
	sort.Slice(live, func(i, j int) bool { return live[i].a.At.Before(live[j].a.At) })
	return append(out, live...)
}

// habit is one lint rule as seen across the user's replies: how often the LLM reply had it, and the times the user
// kept it anyway
type habit struct {
	msg   string
	seen  int
	kept  int
	cut   []string
	keeps []string
}

// habits compares lint hits in each LLM reply with hits in the user's version of it. A habit the user always cuts is a
// rule. One they sometimes keep is a judgment call, and the kept examples show where their line is.
func (g *grill) habits() []*habit {
	byRule := map[string]*habit{}
	for _, it := range g.items() {
		text := it.mine()
		mine := map[string][]string{}
		for _, h := range lintText("", text) {
			mine[h.Rule] = append(mine[h.Rule], around(text, h))
		}
		theirs := map[string]string{}
		for _, h := range lintText("", it.q.Reply) {
			if _, dup := theirs[h.Rule]; !dup {
				theirs[h.Rule] = around(it.q.Reply, h)
			}
			if byRule[h.Rule] == nil {
				byRule[h.Rule] = &habit{msg: h.Msg}
			}
		}
		for rule, ex := range theirs {
			hb := byRule[rule]
			hb.seen++
			if kept := mine[rule]; len(kept) > 0 {
				hb.kept++
				hb.keeps = append(hb.keeps, kept[0])
			} else {
				hb.cut = append(hb.cut, ex)
			}
		}
	}
	var out []*habit
	for _, hb := range byRule {
		out = append(out, hb)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].seen > out[j].seen })
	return out
}

// markRe matches a marked phrase as whole words, so the mark "land" does not match "island"
func markRe(mark string) *regexp.Regexp {
	re := regexp.QuoteMeta(mark)
	if w := regexp.MustCompile(`^\w`); w.MatchString(mark) {
		re = `\b` + re
	}
	if w := regexp.MustCompile(`\w$`); w.MatchString(mark) {
		re += `\b`
	}
	return regexp.MustCompile(`(?i)` + re)
}

// marks reports, for every marked phrase, whether the user kept it, with the phrase in the context the LLM used it
func (g *grill) marks() (cut, kept []string) {
	for _, it := range g.items() {
		for _, m := range it.q.Marks {
			re := markRe(m)
			loc := re.FindStringIndex(it.q.Reply)
			if loc == nil {
				continue
			}
			line := fmt.Sprintf("- %q, as in %q", m, snippet(it.q.Reply, loc[0], loc[1]))
			if re.MatchString(it.mine()) {
				kept = append(kept, line)
			} else {
				cut = append(cut, line)
			}
		}
	}
	return cut, kept
}

// around returns a lint hit with a few words on each side, since "n!" alone says nothing
func around(text string, h hit) string {
	lines := strings.Split(text, "\n")
	if h.Line < 1 || h.Line > len(lines) {
		return h.Text
	}
	off := 0
	for _, l := range lines[:h.Line-1] {
		off += len(l) + 1
	}
	r := []rune(lines[h.Line-1])
	if h.Col-1 > len(r) {
		return h.Text
	}
	at := off + len(string(r[:h.Col-1]))
	return snippet(text, at, at+len(h.Text))
}

// snippet returns text[at:end] with up to four words on each side, cut at the line it sits on
func snippet(text string, at, end int) string {
	if at < 0 || end > len(text) || at > end {
		return ""
	}
	from, to := at, end
	for words := 0; from > 0 && text[from-1] != '\n'; from-- {
		if text[from-1] == ' ' && from-1 < at-1 {
			if words++; words == 4 {
				break
			}
		}
	}
	for words := 0; to < len(text) && text[to] != '\n'; to++ {
		if text[to] == ' ' && to > end {
			if words++; words == 4 {
				break
			}
		}
	}
	out := strings.TrimSpace(text[from:to])
	if from > 0 && text[from-1] != '\n' {
		out = "..." + out
	}
	if to < len(text) && text[to] != '\n' {
		out += "..."
	}
	return out
}

func (g *grill) writeOutputs() error {
	var pairs, authored, labels strings.Builder
	pe, ae, le := json.NewEncoder(&pairs), json.NewEncoder(&authored), json.NewEncoder(&labels)
	for _, it := range g.items() {
		if it.a.Same {
			le.Encode(labeled{Text: it.q.Reply, Y: 1, Strong: true, Prompt: "kept as is in clint grill"})
			continue
		}
		pe.Encode(pair{Orig: it.q.Reply, Rewrite: it.a.Text})
		ae.Encode(map[string]string{"text": it.a.Text, "source": "grill:" + it.q.ID})
	}
	md := "# My writing rules\n\nWritten by clint grill from my own replies to LLM replies. The replies themselves are " +
		"the best guide. A phrase I cut in one place and kept in another depends on context, and the examples show " +
		"where the line is.\n"
	cut, kept := g.marks()
	if len(cut) > 0 {
		md += "\n## Phrases I cut\n\n" + strings.Join(cut, "\n") + "\n"
	}
	if len(kept) > 0 {
		md += "\n## Phrases I kept\n\n" + strings.Join(kept, "\n") + "\n"
	}
	var always, sometimes []string
	for _, hb := range g.habits() {
		switch {
		case hb.kept == 0 && hb.seen >= 2:
			always = append(always, fmt.Sprintf("- %s. Cut every time (%d of %d), such as %q.", hb.msg, hb.seen,
				hb.seen, hb.cut[0]))
		case hb.kept > 0:
			sometimes = append(sometimes, fmt.Sprintf("- %s. Kept %d of %d times, such as %q.", hb.msg, hb.kept,
				hb.seen, hb.keeps[0]))
		}
	}
	if len(always) > 0 {
		md += "\n## Habits I always cut\n\n" + strings.Join(always, "\n") + "\n"
	}
	if len(sometimes) > 0 {
		md += "\n## Habits I sometimes keep\n\n" + strings.Join(sometimes, "\n") + "\n"
	}
	for name, body := range map[string]string{"pairs-grill.jsonl": pairs.String(),
		"authored-grill.jsonl": authored.String(), "labels-grill.jsonl": labels.String(), "rules.md": md} {
		if err := os.WriteFile(filepath.Join(g.dir, name), []byte(body), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func (g *grill) summary() string {
	done, total, spent, left := g.progress()
	var n, same, live int
	for _, it := range g.items() {
		if strings.HasPrefix(it.q.ID, livePrefix) {
			live++
		}
		if it.a.Same {
			same++
		} else {
			n++
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "scenarios: %d of %d done, %s spent, about %s left\n", done, total, mins(spent), mins(left))
	if live > 0 {
		fmt.Fprintf(&b, "live: %d of your own replies\n", live)
	}
	fmt.Fprintf(&b, "wrote to %s:\n", g.dir)
	fmt.Fprintf(&b, "  pairs-grill.jsonl     %d pairs, trained on and shown to the synth teacher as examples\n", n)
	fmt.Fprintf(&b, "  authored-grill.jsonl  %d replies, trained on as your writing\n", n)
	fmt.Fprintf(&b, "  labels-grill.jsonl    %d kept as is, trained on as approved replies\n", same)
	fmt.Fprintf(&b, "  rules.md              what you cut and what you kept, used by clint synth\n")
	switch {
	case done < total:
		b.WriteString("run clint grill again to pick up where you left off\n")
	default:
		b.WriteString("run clint grill again for live questions from your own transcripts\n")
	}
	return b.String()
}

// prompt is the question as shown to a person, by the terminal or by an agent relaying it
func (q question) prompt() string {
	if strings.HasPrefix(q.ID, livePrefix) {
		s := "  You asked:\n" + block(q.Ask) + "\n\n  The reply you got:\n" + block(q.Reply)
		if q.Reaction != "" {
			s += "\n\n  What you said next:\n" + block(q.Reaction)
		}
		return s + "\n\n\nWrite it the way you wanted it, or = if it was fine. End with a line holding only a period."
	}
	return "  Who asked:\n" + block(q.Ask) + "\n\n  What's true:\n" + block(q.True) +
		"\n\n  An LLM replied:\n" + block(q.Reply) +
		"\n\n\nWrite exactly how you would reply, or = to send it as is. End with a line holding only a period."
}

// block indents s by 8 and wraps each line at 110 columns, so long replies stay readable in a terminal
func block(s string) string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		cur := ""
		for _, w := range strings.Fields(line) {
			if cur != "" && len(cur)+1+len(w) > 102 {
				out = append(out, cur)
				cur = ""
			}
			if cur != "" {
				cur += " "
			}
			cur += w
		}
		out = append(out, cur)
	}
	return indent(indent(strings.Join(out, "\n")))
}

// mins prints a duration the way a person says it: 1h 17m, 45m, under a minute
func mins(d time.Duration) string {
	m := int(d.Minutes() + 0.5)
	switch {
	case m == 0:
		return "under a minute"
	case m < 60:
		return fmt.Sprintf("%dm", m)
	}
	return fmt.Sprintf("%dh %dm", m/60, m%60)
}

func indent(s string) string { return "    " + strings.ReplaceAll(s, "\n", "\n    ") }

func liveID(text string) string {
	h := sha1.Sum([]byte(strings.TrimSpace(text)))
	return livePrefix + hex.EncodeToString(h[:5])
}

// pickLive returns the reply from the user's transcripts that the model is least sure about, since a rewrite of that
// one teaches it the most. labels.jsonl comes from clint label. Code-heavy and very short or long replies are left
// out, because rewriting them is slow or teaches nothing about voice.
func (g *grill) pickLive() (question, float64, error) {
	ls, err := readJSONL[labeled](filepath.Join(g.dir, "labels.jsonl"))
	if err != nil {
		return question{}, 0, fmt.Errorf("live questions need labels.jsonl in %s, run clint label first", g.dir)
	}
	m, _ := loadModel(filepath.Join(g.dir, "model.bin"))
	seen := map[string]bool{}
	for id := range g.answers {
		seen[id] = true
	}
	var best question
	bestD, bestS := math.Inf(1), 0.0
	for _, l := range ls {
		t := strings.TrimSpace(l.Text)
		if len(t) < 150 || len(t) > 1500 || strings.Contains(t, "```") {
			continue
		}
		id := liveID(t)
		if seen[id] {
			continue
		}
		seen[id] = true
		s := 0.5
		if m != nil {
			s = m.prob(features(t))
		}
		if d := math.Abs(s - 0.5); d < bestD {
			best, bestD, bestS = question{ID: id, Ask: l.Ask, Reply: t, Reaction: l.Prompt}, d, s
		}
	}
	if math.IsInf(bestD, 1) {
		return question{}, 0, fmt.Errorf("no replies left to ask about in labels.jsonl")
	}
	return best, bestS, nil
}

// retrain rebuilds model.bin in the grill folder, so the next live pick reflects the answer just given
func (g *grill) retrain() (time.Duration, error) {
	exe, err := os.Executable()
	if err != nil {
		return 0, err
	}
	start := time.Now()
	out, err := exec.Command(exe, "train", "-data", g.dir, "-out", filepath.Join(g.dir, "model.bin")).CombinedOutput()
	if err != nil {
		return 0, fmt.Errorf("%v: %s", err, clip(strings.TrimSpace(string(out)), 200))
	}
	return time.Since(start), nil
}

func runGrill(args []string) error {
	fl := flag.NewFlagSet("grill", flag.ExitOnError)
	dir := fl.String("data", dataDir(), "where answers and the files built from them go")
	status := fl.Bool("status", false, "print progress and what has been written, then exit")
	live := fl.Bool("live", false, "skip to live questions from your own transcripts")
	file := fl.String("file", "", "review this markdown or text file one sentence at a time")
	punct := fl.Bool("punct", false, "with -file, only visit sentences with a dash, semicolon, colon, ! or (")
	next := fl.Bool("next", false, "print the next question and exit (for agents), json with -json")
	asJSON := fl.Bool("json", false, "with -next, emit json")
	ans := fl.String("answer", "", "record stdin as the answer to this question id (for agents)")
	skip := fl.String("skip", "", "skip this question id")
	redo := fl.String("redo", "", "ask this question id again")
	backup := fl.Bool("backup", false, "copy the answers to grill-answers.<time>.jsonl")
	reset := fl.Bool("reset", false, "start over, deleting the answers and every file built from them")
	fl.Parse(args)
	if *file != "" {
		return runReview(*dir, *file, *punct)
	}

	answers := filepath.Join(*dir, "grill-answers.jsonl")
	if *backup && fileExists(answers) {
		b, err := os.ReadFile(answers)
		if err != nil {
			return err
		}
		kept := filepath.Join(*dir, "grill-answers."+time.Now().Format("20060102-150405")+".jsonl")
		if err := os.WriteFile(kept, b, 0o644); err != nil {
			return err
		}
		fmt.Println("answers copied to", kept)
	}
	if *reset {
		for _, name := range []string{"grill-answers.jsonl", "pairs-grill.jsonl", "authored-grill.jsonl",
			"labels-grill.jsonl", "rules.md"} {
			if err := os.Remove(filepath.Join(*dir, name)); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
	}
	g, err := loadGrill(*dir)
	if err != nil {
		return err
	}
	switch {
	case *status:
		fmt.Print(g.summary())
		return nil
	case *next:
		q, ok := g.next()
		if *asJSON {
			done, total, _, left := g.progress()
			return json.NewEncoder(os.Stdout).Encode(map[string]any{"done": !ok, "question": q, "prompt": q.prompt(),
				"answered": done, "total": total, "minutes_left": int(left.Minutes() + 0.5)})
		}
		if !ok {
			fmt.Print(g.summary())
			return nil
		}
		fmt.Printf("%s\n\n%s\n", q.ID, q.prompt())
		return nil
	case *skip != "":
		if _, ok := g.find(*skip); !ok {
			return fmt.Errorf("no question %q", *skip)
		}
		return g.record(answer{ID: *skip, Skipped: true})
	case *ans != "":
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			return err
		}
		return g.answerText(*ans, string(b), 0)
	}
	if *redo != "" {
		if _, ok := g.find(*redo); !ok {
			return fmt.Errorf("no question %q", *redo)
		}
		delete(g.answers, *redo)
	}
	return g.interactive(*live)
}

// answerText records one reply to a grill.txt scenario, as typed or as relayed by an agent. = keeps the LLM reply.
func (g *grill) answerText(id, text string, secs float64) error {
	if _, ok := g.find(id); !ok {
		return fmt.Errorf("no question %q", id)
	}
	if text = strings.TrimSpace(text); text == "" {
		return fmt.Errorf("empty answer for %q", id)
	}
	return g.record(answer{ID: id, Text: text, Same: text == "=", Seconds: secs})
}

// readReply reads lines until one holding only a period. q, s and = alone on the first line answer at once.
func readReply(in *bufio.Reader) (text string, cmd string) {
	var lines []string
	for {
		fmt.Print("> ")
		l, err := in.ReadString('\n')
		if err != nil && l == "" {
			return strings.TrimSpace(strings.Join(lines, "\n")), "q"
		}
		l = strings.TrimRight(l, "\r\n")
		t := strings.TrimSpace(l)
		if t == "." {
			break
		}
		if len(lines) == 0 && (t == "q" || t == "s" || t == "=") {
			return "", t
		}
		lines = append(lines, l)
	}
	return strings.TrimSpace(strings.Join(lines, "\n")), ""
}

func (g *grill) interactive(live bool) error {
	in := bufio.NewReader(os.Stdin)
	done, total, _, left := g.progress()
	switch {
	case done == 0:
		fmt.Printf("clint grill: %d scenarios, about %s if you did them all at once. You don't have to.\n", total,
			mins(left))
	case done < total && !live:
		fmt.Printf("clint grill: welcome back. %d of %d done, about %s left.\n", done, total, mins(left))
	default:
		fmt.Println("clint grill: live questions from your own transcripts. These never run out.")
	}
	fmt.Println("Every answer saves the moment you give it. Type q to stop whenever you want, and run clint grill")
	fmt.Println("again to pick up right where you left off. s skips a question, = keeps the reply as it is.")
	for !live {
		q, ok := g.next()
		if !ok {
			fmt.Println("\nThat was the last scenario. From here on the questions come from your own transcripts.")
			break
		}
		done, total, _, left = g.progress()
		fmt.Printf("\n[%d/%d, about %s left]\n\n%s\n", done+1, total, mins(left), q.prompt())
		start := time.Now()
		text, cmd := readReply(in)
		switch {
		case cmd == "q" || (cmd == "" && text == ""):
			fmt.Print("\n" + g.summary())
			return nil
		case cmd == "s":
			if err := g.record(answer{ID: q.ID, Skipped: true}); err != nil {
				return err
			}
			continue
		case cmd == "=":
			text = "="
		}
		if err := g.answerText(q.ID, text, time.Since(start).Seconds()); err != nil {
			return err
		}
	}
	for n := 1; ; n++ {
		q, s, err := g.pickLive()
		if err != nil {
			fmt.Println(err)
			fmt.Print("\n" + g.summary())
			return nil
		}
		fmt.Printf("\n[live %d. The model scores this %.2f, so it can't tell yet]\n\n%s\n", n, s, q.prompt())
		start := time.Now()
		text, cmd := readReply(in)
		a := answer{ID: q.ID, Ask: q.Ask, Reply: q.Reply, Reaction: q.Reaction, Seconds: time.Since(start).Seconds()}
		switch {
		case cmd == "q" || (cmd == "" && text == ""):
			fmt.Print("\n" + g.summary())
			return nil
		case cmd == "s":
			a.Skipped = true
		case cmd == "=":
			a.Same, a.Text = true, "="
		default:
			a.Text = text
		}
		if err := g.record(a); err != nil {
			return err
		}
		if a.Skipped {
			continue
		}
		if d, err := g.retrain(); err != nil {
			fmt.Println("retrain failed, the next pick uses the old model:", err)
		} else {
			fmt.Printf("retrained in %.1fs\n", d.Seconds())
		}
	}
}
