package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// A word list can't read a reaction. "stupid", "sigh" and "jesus fuck" never matched it, and a complaint about a wrong
// answer looked the same as one about wordiness. The teacher model reads the reply and the message after it and says
// which kind of reaction it was. Only a reaction to how the reply was written says anything about style.
const reactInstructions = `You read a reply an AI assistant wrote, then the user's next message. Answer two questions.

1. Is the user frustrated or annoyed with the reply? Swearing alone is not frustration: this user swears when happy
   too. Asking a question, asking for something new, choosing between options or adding detail is not frustration,
   even when blunt.
2. If frustrated, at what? The wording (too long, wordy, jargon, unclear, a phrase they hate, "stupid" or "sigh" at
   text the assistant wrote), the facts (the reply was wrong or misread the ask), or an action (the assistant did
   something they didn't want).

Write one short sentence on what the message is doing. Then the last line is exactly one of:
LABEL: style      frustrated at the wording
LABEL: content    frustrated at the facts
LABEL: action     frustrated at an action
LABEL: approve    not frustrated, and says the reply or result is good: yes, nice, perfect, works
LABEL: none       not frustrated, anything else`

var labelRe = regexp.MustCompile(`(?i)LABEL:\W*(\w+)`)

var reactions = map[string]bool{"style": true, "content": true, "action": true, "approve": true, "none": true}

func reactKey(reply, prompt string) string {
	h := sha1.Sum([]byte(reply + "\x00" + prompt))
	return hex.EncodeToString(h[:8])
}

type reactCache struct {
	Key string `json:"key"`
	Why string `json:"why"`
}

// classifyReactions sets Why on every label, and from it Y and Strong. Answers are cached in cachePath, so a rerun
// only asks about new messages.
func classifyReactions(ls []labeled, endpoint, model string, parallel int, cachePath string) error {
	cache := map[string]string{}
	old, err := readJSONL[reactCache](cachePath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, c := range old {
		cache[c.Key] = c.Why
	}
	var todo []int
	for i, l := range ls {
		if why, ok := cache[reactKey(l.Text, l.full)]; ok {
			ls[i].setWhy(why)
		} else {
			todo = append(todo, i)
		}
	}
	fmt.Printf("%d reactions cached, %d to classify with %s\n", len(ls)-len(todo), len(todo), model)
	cf, err := os.OpenFile(cachePath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer cf.Close()
	enc := json.NewEncoder(cf)
	client := &http.Client{Timeout: 2 * time.Minute}
	var mu sync.Mutex
	var wg sync.WaitGroup
	ch := make(chan int)
	done, failed, start := 0, 0, time.Now()
	for range parallel {
		wg.Go(func() {
			for i := range ch {
				l := &ls[i]
				user := "Assistant reply:\n" + clip(l.Text, 2000) + "\n\nUser's next message:\n" + l.full
				out, err := chatAt(client, endpoint, model, reactInstructions, user, 0)
				why := ""
				if m := labelRe.FindStringSubmatch(out); m != nil {
					why = strings.ToLower(m[1])
				}
				mu.Lock()
				if err != nil || !reactions[why] {
					failed++ // keep the word-list label for this one
				} else {
					l.setWhy(why)
					enc.Encode(reactCache{reactKey(l.Text, l.full), why})
				}
				if done++; done%100 == 0 {
					fmt.Printf("%d of %d classified, %d failed (%s)\n", done, len(todo), failed,
						time.Since(start).Round(time.Second))
				}
				mu.Unlock()
			}
		})
	}
	for _, i := range todo {
		ch <- i
	}
	close(ch)
	wg.Wait()
	fmt.Printf("classified %d, %d failed, in %s\n", done-failed, failed, time.Since(start).Round(time.Second))
	return nil
}

// setWhy turns a reaction into a label. Only style and approve are strong, since a complaint about content or about
// what the assistant did says nothing about how the reply reads.
func (l *labeled) setWhy(why string) {
	l.Why = why
	switch why {
	case "style":
		l.Y, l.Strong = 0, true
	case "approve":
		l.Y, l.Strong = 1, true
	default:
		l.Y, l.Strong = 1, false
	}
}
