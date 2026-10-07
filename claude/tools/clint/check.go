package main

import (
	"flag"
	"fmt"
	"strings"
)

// minScore is the clint score below which check fails. Lint errors fail regardless.
const minScore = 0.5

// checkText runs lint and, when a model is loaded, score. It returns the report and whether the text passes.
func checkText(m *model, name, text string) (string, bool) {
	var b strings.Builder
	hits := lintText(name, text)
	errs := 0
	for _, h := range hits {
		if h.Sev == "error" {
			errs++
		}
	}
	if len(hits) > 0 {
		b.WriteString(formatHits(hits))
	}
	pass := errs == 0
	if m != nil {
		r := scoreText(m, name, text)
		b.WriteString(formatScore(r))
		pass = pass && r.Score >= minScore
	}
	verdict := "PASS"
	if !pass {
		verdict = "FAIL"
	}
	fmt.Fprintf(&b, "%s: %s\n", name, verdict)
	return b.String(), pass
}

func runCheck(args []string) (int, error) {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	path := fs.String("model", defaultModelPath(), "model file")
	fs.Parse(args)
	m, err := loadModel(*path)
	if err != nil {
		m = nil // lint still runs without a trained model
	}
	ins, err := readInputs(fs.Args())
	if err != nil {
		return 2, err
	}
	code := 0
	for _, in := range ins {
		rep, ok := checkText(m, in.name, in.text)
		fmt.Print(rep)
		if !ok {
			code = 1
		}
	}
	return code, nil
}
