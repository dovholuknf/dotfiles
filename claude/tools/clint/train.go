package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

type example struct {
	f []feat
	y float32
	w float32
}

// prompts that were written by an agent or a tool rather than typed by Clint
var machinePrefixes = []string{"[atrium]", "read brief.md", "read c:/temp/atrium-tasks", "/", "!",
	"base directory for this skill", "the coordinator sent", "from the orchestrator", "run a mercurius"}

func readJSONL[T any](path string) ([]T, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []T
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		var v T
		if json.Unmarshal(sc.Bytes(), &v) == nil {
			out = append(out, v)
		}
	}
	return out, sc.Err()
}

type pair struct {
	Orig    string `json:"orig"`
	Rewrite string `json:"rewrite"`
	human   bool   // the rewrite was written by hand in clint grill or with rw:, not by a teacher model
}

// pairParagraphs splits both sides of each pair into paragraphs, so the model also sees short LLM text and short
// rewrites, not only whole replies. A paragraph that appears unchanged on both sides says nothing and is dropped.
func pairParagraphs(ps []pair) (origs, rewrites []string) {
	split := func(s string) map[string]bool {
		out := map[string]bool{}
		for _, p := range strings.Split(s, "\n\n") {
			if p = strings.TrimSpace(p); len(normalize(p)) >= 40 {
				out[p] = true
			}
		}
		return out
	}
	for _, p := range ps {
		o, r := split(p.Orig), split(p.Rewrite)
		for k := range o {
			if !r[k] {
				origs = append(origs, k)
			}
		}
		for k := range r {
			if !o[k] {
				rewrites = append(rewrites, k)
			}
		}
	}
	return origs, rewrites
}

// loadAuthored reads jsonl of {"text": ...} that Clint wrote himself, such as blog posts and GitHub comments. Quoted
// lines are someone else's words, so they are dropped before splitting into paragraphs.
func loadAuthored(path string) ([]string, error) {
	recs, err := readJSONL[struct {
		Text string `json:"text"`
	}](path)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, r := range recs {
		var kept []string
		for _, l := range strings.Split(strings.ReplaceAll(r.Text, "\r", ""), "\n") {
			if !strings.HasPrefix(strings.TrimSpace(l), ">") {
				kept = append(kept, l)
			}
		}
		for _, para := range strings.Split(strings.Join(kept, "\n"), "\n\n") {
			if len(normalize(para)) >= 25 {
				out = append(out, strings.TrimSpace(para))
			}
		}
	}
	return out, nil
}

func featurizeAll(texts []string, y, w float32) []example {
	out := make([]example, len(texts))
	var wg sync.WaitGroup
	ch := make(chan int, 256)
	for range runtime.NumCPU() {
		wg.Go(func() {
			for i := range ch {
				out[i] = example{features(texts[i]), y, w}
			}
		})
	}
	for i := range texts {
		ch <- i
	}
	close(ch)
	wg.Wait()
	return out
}

func auc(m *model, xs []example) float64 {
	ps, ys := make([]float64, len(xs)), make([]float32, len(xs))
	for i, x := range xs {
		ps[i], ys[i] = m.prob(x.f), x.y
	}
	return aucOf(ps, ys)
}

func aucOf(ps []float64, ys []float32) float64 {
	type sc struct {
		p float64
		y float32
	}
	s := make([]sc, len(ps))
	for i := range ps {
		s[i] = sc{ps[i], ys[i]}
	}
	sort.Slice(s, func(i, j int) bool { return s[i].p < s[j].p })
	var rankSum, pos float64
	for i, v := range s {
		if v.y == 1 {
			rankSum += float64(i + 1)
			pos++
		}
	}
	neg := float64(len(s)) - pos
	if pos == 0 || neg == 0 {
		return math.NaN()
	}
	return (rankSum - pos*(pos+1)/2) / (pos * neg)
}

// pairAccuracy is the share of held-out pairs where the rewrite outscores the original
func pairAccuracy(m *model, ps []pair) float64 {
	won := 0
	for _, p := range ps {
		if m.prob(features(p.Rewrite)) > m.prob(features(p.Orig)) {
			won++
		}
	}
	return float64(won) / float64(len(ps))
}

func sgd(m *model, data []example, epochs int, rng *rand.Rand) {
	const lr0, l2 = 0.5, 1e-6
	t := 0
	for range epochs {
		rng.Shuffle(len(data), func(i, j int) { data[i], data[j] = data[j], data[i] })
		for _, x := range data {
			lr := float32(lr0 / (1 + 1e-5*float64(t)))
			t++
			g := (float32(m.prob(x.f)) - x.y) * x.w
			for _, f := range x.f {
				m.w[f.idx] -= lr * (g*f.v + l2*m.w[f.idx])
			}
			m.b -= lr * g * 0.1
		}
	}
}

func runTrain(args []string) error {
	fl := flag.NewFlagSet("train", flag.ExitOnError)
	dir := fl.String("data", dataDir(), "folder holding pairs*.jsonl (from clint synth) and labels.jsonl (from label)")
	out := fl.String("out", defaultModelPath(), "model output")
	epochs := fl.Int("epochs", 10, "sgd epochs")
	labelW := fl.Float64("label-weight", 2, "weight of a reply Clint approved or complained about, relative to a pair side")
	authoredW := fl.Float64("authored-weight", 1, "weight of a paragraph Clint wrote himself, relative to a pair side")
	pairGlob := fl.String("pairs", "pairs*.jsonl", "which pairs files to train on, as a glob in -data")
	paraW := fl.Float64("para-weight", 0.5, "weight of each paragraph split out of a pair")
	humanW := fl.Float64("human-weight", 3, "weight of a pair rewritten by hand (pairs-grill, pairs-rw, pairs-review)")
	fl.Parse(args)

	start := time.Now()
	rng := rand.New(rand.NewPCG(1, 2))
	files, _ := filepath.Glob(filepath.Join(*dir, *pairGlob))
	if len(files) == 0 {
		return fmt.Errorf("no %s in %s, run clint synth first", *pairGlob, *dir)
	}
	var authored []string
	afiles, _ := filepath.Glob(filepath.Join(*dir, "authored*.jsonl"))
	for _, f := range afiles {
		as, err := loadAuthored(f)
		if err != nil {
			return err
		}
		authored = append(authored, as...)
	}
	rng.Shuffle(len(authored), func(i, j int) { authored[i], authored[j] = authored[j], authored[i] })
	aCut := len(authored) * 85 / 100
	var pairs []pair
	for _, f := range files {
		ps, err := readJSONL[pair](f)
		if err != nil {
			return err
		}
		base := filepath.Base(f)
		for i := range ps {
			ps[i].human = strings.HasPrefix(base, "pairs-grill") || strings.HasPrefix(base, "pairs-rw") ||
				strings.HasPrefix(base, "pairs-review")
		}
		pairs = append(pairs, ps...)
	}
	// labels.jsonl comes from clint label, labels-grill.jsonl from replies kept as is in clint grill
	var labels []labeled
	lfiles, _ := filepath.Glob(filepath.Join(*dir, "labels*.jsonl"))
	for _, f := range lfiles {
		ls, err := readJSONL[labeled](f)
		if err != nil {
			return err
		}
		labels = append(labels, ls...)
	}
	var strong []labeled
	for _, l := range labels {
		if l.Strong {
			strong = append(strong, l)
		}
	}

	// hold out whole pairs, so neither side of a test pair was seen in training
	rng.Shuffle(len(pairs), func(i, j int) { pairs[i], pairs[j] = pairs[j], pairs[i] })
	rng.Shuffle(len(strong), func(i, j int) { strong[i], strong[j] = strong[j], strong[i] })
	sCut := len(strong) * 70 / 100

	// a held-out reaction must not reach training as one side of a pair either
	heldOut := map[string]bool{}
	for _, l := range strong[sCut:] {
		heldOut[strings.TrimSpace(l.Text)] = true
	}
	kept := pairs[:0]
	for _, p := range pairs {
		if !heldOut[strings.TrimSpace(p.Orig)] {
			kept = append(kept, p)
		}
	}
	pairs = kept
	pCut := len(pairs) * 85 / 100
	trainPairs, testPairs := pairs[:pCut], pairs[pCut:]

	var origs, rewrites, hOrigs, hRewrites []string
	for _, p := range trainPairs {
		if p.human {
			hOrigs, hRewrites = append(hOrigs, p.Orig), append(hRewrites, p.Rewrite)
		} else {
			origs, rewrites = append(origs, p.Orig), append(rewrites, p.Rewrite)
		}
	}
	data := append(featurizeAll(origs, 0, 1), featurizeAll(rewrites, 1, 1)...)
	data = append(data, featurizeAll(hOrigs, 0, float32(*humanW))...)
	data = append(data, featurizeAll(hRewrites, 1, float32(*humanW))...)
	data = append(data, featurizeAll(authored[:aCut], 1, float32(*authoredW))...)
	po, pr := pairParagraphs(trainPairs)
	data = append(data, featurizeAll(po, 0, float32(*paraW))...)
	data = append(data, featurizeAll(pr, 1, float32(*paraW))...)
	var strongTest []example
	var lenScores []float64
	var lenYs []float32
	for i, l := range strong {
		x := example{features(l.Text), l.Y, float32(*labelW)}
		if i < sCut {
			data = append(data, x)
		} else {
			strongTest = append(strongTest, x)
			lenScores = append(lenScores, -float64(len(l.Text)))
			lenYs = append(lenYs, l.Y)
		}
	}
	fmt.Printf("data: %d pairs (%d held out), %d paragraphs Clint wrote (%d held out), %d approved/rejected replies (%d held out) (%s)\n",
		len(pairs), len(testPairs), len(authored), len(authored)-aCut, len(strong), len(strongTest),
		time.Since(start).Round(time.Millisecond))

	m := &model{w: make([]float32, dim)}
	sgd(m, data, *epochs, rng)
	if math.IsNaN(float64(m.b)) {
		return fmt.Errorf("training diverged")
	}
	if err := m.save(*out); err != nil {
		return err
	}
	q, err := loadModel(*out)
	if err != nil {
		return err
	}
	var heldPairs []example
	var o, r []string
	for _, p := range testPairs {
		o, r = append(o, p.Orig), append(r, p.Rewrite)
	}
	heldPairs = append(featurizeAll(o, 0, 1), featurizeAll(r, 1, 1)...)
	fmt.Printf("held-out pairs: rewrite beats original %.1f%%, auc %.3f\n", 100*pairAccuracy(q, testPairs), auc(q, heldPairs))
	if heldAuth := featurizeAll(authored[aCut:], 1, 1); len(heldAuth) > 0 {
		passed := 0
		for _, x := range heldAuth {
			if q.prob(x.f) >= minScore {
				passed++
			}
		}
		// his own unseen writing against the unseen LLM originals
		fmt.Printf("held-out Clint writing: %.1f%% score >= %.1f, auc vs held-out LLM originals %.3f\n",
			100*float64(passed)/float64(len(heldAuth)), minScore, auc(q, append(heldAuth, heldPairs[:len(o)]...)))
	}
	fmt.Printf("held-out real reactions: approved vs complained-about auc %.3f (shorter-is-better baseline %.3f)\n",
		auc(q, strongTest), aucOf(lenScores, lenYs))
	fmt.Printf("wrote %s (%s total)\n", *out, time.Since(start).Round(time.Millisecond))
	return nil
}
