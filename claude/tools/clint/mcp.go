package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

type rpcReq struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

var textSchema = map[string]any{
	"type":       "object",
	"properties": map[string]any{"text": map[string]any{"type": "string", "description": "the text to check"}},
	"required":   []string{"text"},
}

var tools = []map[string]any{
	{"name": "clint_check", "inputSchema": textSchema,
		"description": "Check text Clint will read, or that goes out under his name, before showing it. Returns lint " +
			"hits (em dashes, LLM vocabulary, preambles, sign-offs, 'not X, it's Y') with line:col, a 0-1 score from a " +
			"model of his taste, the least clint-like paragraphs, and PASS or FAIL. On FAIL, fix every error hit and " +
			"rewrite the listed paragraphs plainly and shorter. Do not chase the number with tricks."},
	{"name": "clint_grill_next", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}},
		"description": "Get the next clint grill scenario, which teaches clint how the user writes. Each one has who " +
			"asked, what is true and an LLM's reply. Show it to the user exactly as given, with the progress line, and " +
			"wait for them to write how they would reply. Never write the reply yourself."},
	{"name": "clint_grill_answer", "description": "Record the user's reply to a clint grill scenario. Pass their words " +
		"exactly as typed, typos and all. Never fix, shorten or rephrase them, since the point is how they write. " +
		"Pass skip to skip the scenario.",
		"inputSchema": map[string]any{"type": "object", "required": []string{"id", "answer"}, "properties": map[string]any{
			"id":     map[string]any{"type": "string", "description": "the question id from clint_grill_next"},
			"answer": map[string]any{"type": "string", "description": "the user's answer, verbatim"}}}},
}

// grillTool runs the agent side of clint grill, so a chat session can ask the questions and relay the answers
func grillTool(name, id, text string) (string, error) {
	g, err := loadGrill(dataDir())
	if err != nil {
		return "", err
	}
	if name == "clint_grill_answer" {
		if strings.EqualFold(strings.TrimSpace(text), "skip") {
			if _, ok := g.find(id); !ok {
				return "", fmt.Errorf("no question %q", id)
			}
			err = g.record(answer{ID: id, Skipped: true})
		} else {
			err = g.answerText(id, text, 0)
		}
		if err != nil {
			return "", err
		}
	}
	q, ok := g.next()
	if !ok {
		return "All questions answered.\n\n" + g.summary(), nil
	}
	done, total, _, left := g.progress()
	return fmt.Sprintf("Next question id: %s\nProgress: %d of %d answered, about %s left. The user can stop any time "+
		"and pick up later.\n\n%s", q.ID, done, total, mins(left), q.prompt()), nil
}

// runMCP serves newline-delimited JSON-RPC on stdio. The model loads on first use and stays in memory.
func runMCP(in io.Reader, out io.Writer) error {
	var m *model
	enc := json.NewEncoder(out)
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		var req rpcReq
		if json.Unmarshal(sc.Bytes(), &req) != nil || len(req.ID) == 0 {
			continue // notifications need no reply
		}
		var result any
		var rpcErr map[string]any
		switch req.Method {
		case "initialize":
			var p struct {
				ProtocolVersion string `json:"protocolVersion"`
			}
			json.Unmarshal(req.Params, &p)
			if p.ProtocolVersion == "" {
				p.ProtocolVersion = "2025-06-18"
			}
			result = map[string]any{"protocolVersion": p.ProtocolVersion, "capabilities": map[string]any{"tools": map[string]any{}},
				"serverInfo": map[string]any{"name": "clint", "version": "0.1.0"}}
		case "ping":
			result = map[string]any{}
		case "tools/list":
			result = map[string]any{"tools": tools}
		case "tools/call":
			var p struct {
				Name      string `json:"name"`
				Arguments struct {
					Text   string `json:"text"`
					ID     string `json:"id"`
					Answer string `json:"answer"`
				} `json:"arguments"`
			}
			json.Unmarshal(req.Params, &p)
			text, isErr := "", false
			switch p.Name {
			case "clint_check":
				if m == nil {
					m, _ = loadModel(defaultModelPath()) // without a model, check is lint only
				}
				text, _ = checkText(m, "text", p.Arguments.Text)
			case "clint_grill_next", "clint_grill_answer":
				var err error
				if text, err = grillTool(p.Name, p.Arguments.ID, p.Arguments.Answer); err != nil {
					text, isErr = err.Error(), true
				}
			default:
				text, isErr = "unknown tool "+p.Name, true
			}
			result = map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": isErr}
		default:
			rpcErr = map[string]any{"code": -32601, "message": "method not found: " + req.Method}
		}
		resp := map[string]any{"jsonrpc": "2.0", "id": req.ID}
		if rpcErr != nil {
			resp["error"] = rpcErr
		} else {
			resp["result"] = result
		}
		if err := enc.Encode(resp); err != nil {
			return err
		}
	}
	if err := sc.Err(); err != nil {
		os.Stderr.WriteString(err.Error() + "\n")
	}
	return nil
}
