package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"math/bits"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
)

const (
	hashBits = 18
	dim      = 1 << hashBits
	magic    = "CLS2"
)

type feat struct {
	idx uint32
	v   float32
}

var (
	fenceRe   = regexp.MustCompile("(?s)```.*?(```|$)")
	tableRe   = regexp.MustCompile(`(?m)^\s*\|.*$`)
	mdPrefix  = regexp.MustCompile(`(?m)^\s*(#{1,6}\s+|[-*+>]\s+|\d+[.)]\s+)`)
	emphRe    = regexp.MustCompile(`\*\*|__`)
	pathRe    = regexp.MustCompile(`([A-Za-z]:[\\/]|~/|/)[^\s]*[\\/][^\s]*`)
	spaceRe   = regexp.MustCompile(`\s+`)
	pastedRe  = regexp.MustCompile(`\[(Pasted text|Image)[^\]]*\]`)
	imageLead = regexp.MustCompile(`(?i)^check out the image here:\s*\S+\s*`)
)

// normalize strips what differs between chat and markdown but says nothing about voice: code, tables, list and heading
// markers, bold, urls, paths and letter case. What is left is word choice, punctuation and cadence.
func normalize(s string) string {
	s = fenceRe.ReplaceAllString(s, " ")
	s = tableRe.ReplaceAllString(s, " ")
	s = inlineCode.ReplaceAllString(s, " ")
	s = urlRe.ReplaceAllString(s, " ")
	s = mdPrefix.ReplaceAllString(s, "")
	s = emphRe.ReplaceAllString(s, "")
	s = pathRe.ReplaceAllString(s, " ")
	s = strings.ToLower(s)
	return strings.TrimSpace(spaceRe.ReplaceAllString(s, " "))
}

const prime = 16777619

func seed(n uint32) uint32 { return (2166136261 ^ (n * 0x9e3779b1)) * prime }

// featurize hashes char 2-4 grams and word 1-2 grams of normalized text into an L2-normalized sparse vector
func featurize(norm string) []feat {
	counts := make(map[uint32]float32, len(norm)*2)
	r := []rune(" " + norm + " ")
	for n := 2; n <= 4; n++ {
		for i := 0; i+n <= len(r); i++ {
			h := seed(uint32(n))
			for _, c := range r[i : i+n] {
				h = (h ^ uint32(c)) * prime
			}
			counts[h&(dim-1)]++
		}
	}
	words := strings.FieldsFunc(norm, func(c rune) bool { return !unicode.IsLetter(c) && !unicode.IsDigit(c) && c != '\'' })
	var prev uint32
	for i, w := range words {
		h := seed(11)
		for j := 0; j < len(w); j++ {
			h = (h ^ uint32(w[j])) * prime
		}
		counts[h&(dim-1)]++
		if i > 0 {
			counts[((prev^h)*prime)&(dim-1)]++
		}
		prev = h
	}
	out := make([]feat, 0, len(counts))
	var ss float64
	for k, c := range counts {
		v := float32(1 + math.Log(float64(c)))
		out = append(out, feat{k, v})
		ss += float64(v * v)
	}
	if ss > 0 {
		inv := float32(1 / math.Sqrt(ss))
		for i := range out {
			out[i].v *= inv
		}
	}
	return out
}

var (
	bulletRe   = regexp.MustCompile(`(?m)^\s*([-*+]|\d+[.)])\s+`)
	headerRe   = regexp.MustCompile(`(?m)^#{1,6}\s`)
	boldRe     = regexp.MustCompile(`\*\*[^*\n]+\*\*`)
	sentenceRe = regexp.MustCompile(`[.!?](\s|$)`)
)

// features is the full input to the model: n-grams of the normalized text plus a few hashed shape tokens for length,
// sentence length, bullets, tables, headers, bold and code, since normalize strips those
func features(raw string) []feat {
	norm := normalize(raw)
	f := featurize(norm)
	words := len(strings.Fields(norm))
	sents := max(1, len(sentenceRe.FindAllString(norm, -1)))
	shape := []string{
		fmt.Sprintf("len:%d", bits.Len(uint(words))),
		fmt.Sprintf("sent:%d", min(words/sents/5, 8)),
		fmt.Sprintf("bul:%d", min(len(bulletRe.FindAllString(raw, -1)), 9)/3),
		fmt.Sprintf("tbl:%t", tableRe.MatchString(raw)),
		fmt.Sprintf("hdr:%d", min(len(headerRe.FindAllString(raw, -1)), 3)),
		fmt.Sprintf("bold:%d", min(len(boldRe.FindAllString(raw, -1)), 6)/2),
		fmt.Sprintf("para:%d", min(strings.Count(strings.TrimSpace(raw), "\n\n"), 10)/2),
		fmt.Sprintf("code:%t", strings.Contains(raw, "```")),
	}
	for _, s := range shape {
		h := seed(99)
		for i := 0; i < len(s); i++ {
			h = (h ^ uint32(s[i])) * prime
		}
		f = append(f, feat{h & (dim - 1), 0.5})
	}
	return f
}

type model struct {
	w []float32
	b float32
}

func (m *model) prob(f []feat) float64 {
	z := float64(m.b)
	for _, x := range f {
		z += float64(m.w[x.idx] * x.v)
	}
	return 1 / (1 + math.Exp(-z))
}

// save quantizes weights to int8 with one scale, so the file is dim bytes plus a 12 byte header
func (m *model) save(path string) error {
	var mx float32
	for _, v := range m.w {
		mx = max(mx, float32(math.Abs(float64(v))))
	}
	scale := mx / 127
	if scale == 0 {
		scale = 1
	}
	var buf bytes.Buffer
	buf.WriteString(magic)
	binary.Write(&buf, binary.LittleEndian, scale)
	binary.Write(&buf, binary.LittleEndian, m.b)
	q := make([]byte, dim)
	for i, v := range m.w {
		q[i] = byte(int8(math.Round(float64(v / scale))))
	}
	buf.Write(q)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, buf.Bytes(), 0o644)
}

func loadModel(path string) (*model, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("no model at " + path + ", run: clint train")
	}
	if len(b) != 12+dim || string(b[:4]) != magic {
		return nil, errors.New("bad model file " + path)
	}
	scale := math.Float32frombits(binary.LittleEndian.Uint32(b[4:]))
	m := &model{w: make([]float32, dim), b: math.Float32frombits(binary.LittleEndian.Uint32(b[8:]))}
	for i, q := range b[12:] {
		m.w[i] = float32(int8(q)) * scale
	}
	return m, nil
}
