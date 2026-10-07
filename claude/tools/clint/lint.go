package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"
)

type rule struct {
	id    string
	sev   string // error or warn
	re    *regexp.Regexp
	msg   string
	start bool // match only against the line with any list or quote marker trimmed
	punct bool // punctuation is wrong even inside quotes
}

// rules mirror the Never list in claude/skills/clintify/SKILL.md and the cadence rules in agents/comments.md
var rules = []rule{
	{id: "em-dash", sev: "error", punct: true, re: regexp.MustCompile(`—`), msg: "em dash, rewrite the sentence"},
	{id: "en-dash", sev: "error", punct: true, re: regexp.MustCompile(` – `), msg: "en dash used as a dash"},
	{id: "double-dash", sev: "error", punct: true, re: regexp.MustCompile(`\s--\s`), msg: "-- used as a dash"},
	{id: "semicolon", sev: "warn", re: regexp.MustCompile(`[A-Za-z)];\s+[A-Za-z]`), msg: "semicolon in prose"},
	{id: "exclamation", sev: "warn", re: regexp.MustCompile(`[A-Za-z)]!+(\s|$)`), msg: "exclamation point"},
	{id: "llm-word", sev: "error", re: regexp.MustCompile(`(?i)\b(honest(ly)?|genuine(ly)?|worth (noting|knowing|mentioning)|` +
		`footguns?|seams?|happy[- ]path|earns? (its|their) keep|crucial(ly)?|robust(ly|ness)?|seamless(ly)?|delv(e|es|ed|ing)|` +
		`closes? (that|the|this) gap)\b`), msg: "LLM vocabulary"},
	{id: "llm-word", sev: "warn", re: regexp.MustCompile(`(?i)\b(load[- ]bearing|under the hood|it's important to note|` +
		`in summary|in short|at the end of the day|key takeaway|game[- ]changer)\b`), msg: "LLM vocabulary"},
	{id: "not-x-its-y", sev: "warn", re: regexp.MustCompile(`(?i)\b(not|isn't|wasn't|aren't|doesn't)\b[^.;:!?\n]{1,50},\s*(it's|it is|they're|that's|this is)\b`),
		msg: `"not X, it's Y" cadence`},
	{id: "punch-fragment", sev: "warn", re: regexp.MustCompile(`\b(Period|Full stop)\.`), msg: "punchy fragment"},
	{id: "preamble", sev: "error", start: true, re: regexp.MustCompile(`(?i)^((great|good|excellent) question|here's (what|the|how)\b|` +
		`let me\b|sure[,!.]|absolutely\b|certainly\b|i'll go ahead)`), msg: "preamble"},
	{id: "sign-off", sev: "error", re: regexp.MustCompile(`(?i)(let me know if|hope (this|that) helps|happy to help|` +
		`your (move|call)\.|feel free to)`), msg: "sign-off"},
	{id: "offer", sev: "warn", re: regexp.MustCompile(`(?i)\b(want me to|shall i|should i go ahead)\b`), msg: "offer, do the obvious next step instead"},
	{id: "lead-label", sev: "error", start: true, re: regexp.MustCompile(`(?i)^(\*\*)?(honest caveat|worth noting|one honest exception|` +
		`what's happening|key (insight|takeaway)|bottom line|the short version|short answer|the catch)(\*\*)?\s*:`), msg: "lead-in label, use Note: or drop it"},
	{id: "setup-line", sev: "warn", start: true, re: regexp.MustCompile(`(?i)^(two|three|four|five|a few|several) (things|lines|points|problems|` +
		`issues|changes|environments|options|pieces)\b[^.\n]{0,30}\b(are|is|worth|matter)`), msg: "setup sentence announces content"},
}

// userRules adds the phrases in banned.txt, one per line, which clint grill writes from the user's own answers
var userRules = sync.OnceValue(func() []rule {
	b, err := os.ReadFile(filepath.Join(dataDir(), "banned.txt"))
	if err != nil {
		return nil
	}
	var alts []string
	for _, l := range strings.Split(strings.ReplaceAll(string(b), "\r", ""), "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
			alts = append(alts, regexp.QuoteMeta(l))
		}
	}
	if len(alts) == 0 {
		return nil
	}
	return []rule{{id: "banned", sev: "error", re: regexp.MustCompile(`(?i)\b(` + strings.Join(alts, "|") + `)\b`),
		msg: "on your banned list"}}
})

var (
	inlineCode = regexp.MustCompile("`[^`\n]*`")
	urlRe      = regexp.MustCompile(`https?://\S+`)
	markerRe   = regexp.MustCompile(`^\s*([-*+>]|\d+[.)])?\s*`)
)

type hit struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Col  int    `json:"col"`
	Rule string `json:"rule"`
	Sev  string `json:"severity"`
	Msg  string `json:"message"`
	Text string `json:"text"`
}

func blank(m string) string { return strings.Repeat(" ", len(m)) }

// quoted reports whether byte offset at sits inside a double-quoted span. line holds the paragraph so far, since a
// quote in wrapped prose often opens on one line and closes on the next.
func quoted(line string, at int) bool {
	n := strings.Count(line[:at], `"`)
	open := strings.Count(line[:at], "“") - strings.Count(line[:at], "”")
	return n%2 == 1 || open > 0
}

func lintText(name, text string) []hit {
	var hits []hit
	all := append(rules[:len(rules):len(rules)], userRules()...)
	fence := false
	para := "" // earlier lines of the current paragraph, for quotes that span lines
	for i, raw := range strings.Split(text, "\n") {
		if strings.HasPrefix(strings.TrimSpace(raw), "```") {
			fence, para = !fence, ""
			continue
		}
		if fence {
			continue
		}
		if strings.TrimSpace(raw) == "" {
			para = ""
			continue
		}
		// blank code and urls in place so columns still line up with the raw line
		line := inlineCode.ReplaceAllStringFunc(raw, blank)
		line = urlRe.ReplaceAllStringFunc(line, blank)
		trimmed := markerRe.ReplaceAllString(line, "")
		off := len(line) - len(trimmed)
		for _, r := range all {
			src, base := line, 0
			if r.start {
				src, base = trimmed, off
			}
			for _, loc := range r.re.FindAllStringIndex(src, -1) {
				at := base + loc[0]
				if !r.punct && quoted(para+line, len(para)+at) {
					continue // a phrase in quotes is being mentioned, not used
				}
				hits = append(hits, hit{name, i + 1, utf8.RuneCountInString(raw[:at]) + 1, r.id, r.sev, r.msg,
					strings.TrimSpace(raw[at : base+loc[1]])})
			}
		}
		para += line + "\n"
	}
	sort.Slice(hits, func(i, j int) bool {
		return hits[i].Line < hits[j].Line || hits[i].Line == hits[j].Line && hits[i].Col < hits[j].Col
	})
	return hits
}

func runLint(args []string) (int, error) {
	fs := flag.NewFlagSet("lint", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "emit json")
	fs.Parse(args)
	ins, err := readInputs(fs.Args())
	if err != nil {
		return 2, err
	}
	var all []hit
	for _, in := range ins {
		all = append(all, lintText(in.name, in.text)...)
	}
	if *asJSON {
		if all == nil {
			all = []hit{}
		}
		json.NewEncoder(os.Stdout).Encode(all)
	} else {
		fmt.Print(formatHits(all))
	}
	for _, h := range all {
		if h.Sev == "error" {
			return 1, nil
		}
	}
	return 0, nil
}

func formatHits(hits []hit) string {
	var b strings.Builder
	errs := 0
	for _, h := range hits {
		if h.Sev == "error" {
			errs++
		}
		fmt.Fprintf(&b, "%s:%d:%d: %s %s: %s (%q)\n", h.File, h.Line, h.Col, h.Sev, h.Rule, h.Msg, h.Text)
	}
	fmt.Fprintf(&b, "%d hits: %d error, %d warn\n", len(hits), errs, len(hits)-errs)
	return b.String()
}
