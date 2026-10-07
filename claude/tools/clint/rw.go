package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// rwPrefix starts a prompt that rewrites the last reply instead of going to Claude
var rwPrefix = regexp.MustCompile(`(?is)^\s*rw:\s*(.*)$`)

// runRW is a UserPromptSubmit hook. A prompt starting with rw: is Clint's own version of the last assistant reply. It
// is saved as a pair and blocked, so it costs no tokens and never reaches the model. Any other prompt passes through.
func runRW(args []string) error {
	var in struct {
		Prompt         string `json:"prompt"`
		TranscriptPath string `json:"transcript_path"`
	}
	b, err := io.ReadAll(os.Stdin)
	if err != nil || json.Unmarshal(b, &in) != nil {
		return nil // never break a prompt because of this hook
	}
	m := rwPrefix.FindStringSubmatch(in.Prompt)
	if m == nil {
		return nil
	}
	block := func(reason string) error {
		return json.NewEncoder(os.Stdout).Encode(map[string]string{"decision": "block", "reason": reason})
	}
	mine := strings.TrimSpace(m[1])
	if mine == "" {
		return block("rw: needs your version of the last reply after the colon. Nothing was sent.")
	}
	last, err := lastReply(in.TranscriptPath)
	if err != nil || last == "" {
		return block("rw: found no assistant reply in this session to pair with. Nothing was sent.")
	}
	dir := dataDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return block("rw: " + err.Error())
	}
	n, err := appendJSONL(filepath.Join(dir, "pairs-rw.jsonl"), pair{Orig: last, Rewrite: mine})
	if err == nil {
		_, err = appendJSONL(filepath.Join(dir, "authored-rw.jsonl"), map[string]string{"text": mine, "source": "rw"})
	}
	if err != nil {
		return block("rw: could not save: " + err.Error())
	}
	return block(fmt.Sprintf("rw: saved as pair %d in %s. Nothing was sent to Claude. The nightly train picks it up.",
		n, filepath.Join(dir, "pairs-rw.jsonl")))
}

// lastReply returns the prose of the last assistant turn in a transcript
func lastReply(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	last := ""
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		var t turn
		if json.Unmarshal(sc.Bytes(), &t) == nil && t.Type == "assistant" {
			if s := assistantText(t.Message.Content); s != "" {
				last = s
			}
		}
	}
	return last, sc.Err()
}

// appendJSONL appends one record and returns how many lines the file now holds
func appendJSONL(path string, v any) (int, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_RDWR, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if err := json.NewEncoder(f).Encode(v); err != nil {
		return 0, err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return 0, err
	}
	n := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		n++
	}
	return n, sc.Err()
}
