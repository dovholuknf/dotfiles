// Charges every API call in Claude Code transcripts to the prompt that caused it, for Get-TokenReport.ps1.
// UsageScan in UsageCommon.ps1 counts calls. This keeps their order inside each file, which is what ties a call
// to the prompt before it, and records what each call did: tools, files read, waits, how much it wrote.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

public class PromptCall {
    public string Id, Model;
    public DateTime Time;
    public long In, Cw, Cr, Out;
    public long Visible;   // characters of text and tool input the reply wrote; output beyond ~Visible/4 is thinking
    public int ToolCalls;
    public bool Wait;      // sleeps, polls, reads of a background task's output
    public List<string> Reads = new List<string>();
    public long Context { get { return In + Cw + Cr; } }
    public long Total { get { return In + Cw + Cr + Out; } }
}

public class PromptTurn {
    public string SessionId = "", Project = "", File = "", Kind = "", Text = "", Model = "";
    public bool IsSub;
    public DateTime Time;
    public List<PromptCall> Calls = new List<PromptCall>();
    public long In { get { long s = 0; foreach (var c in Calls) s += c.In; return s; } }
    public long Cw { get { long s = 0; foreach (var c in Calls) s += c.Cw; return s; } }
    public long Cr { get { long s = 0; foreach (var c in Calls) s += c.Cr; return s; } }
    public long Out { get { long s = 0; foreach (var c in Calls) s += c.Out; return s; } }
    public long Total { get { long s = 0; foreach (var c in Calls) s += c.Total; return s; } }
    public long Visible { get { long s = 0; foreach (var c in Calls) s += c.Visible; return s; } }
    public int ToolCalls { get { int s = 0; foreach (var c in Calls) s += c.ToolCalls; return s; } }
    public long MaxContext { get { long m = 0; foreach (var c in Calls) m = Math.Max(m, c.Context); return m; } }
    public long FirstContext { get { return Calls.Count > 0 ? Calls[0].Context : 0; } }
    public long WaitTotal { get { long s = 0; foreach (var c in Calls) if (c.Wait) s += c.Total; return s; } }
}

public static class PromptScan {
    static readonly Regex Reminder = new Regex(@"(?s)<system-reminder>.*?</system-reminder>");
    static readonly Regex Command = new Regex(@"<command-name>(.*?)</command-name>(?:.*?<command-args>(.*?)</command-args>)?",
        RegexOptions.Singleline);
    static readonly Regex Space = new Regex(@"\s+");
    static readonly Regex WaitCmd = new Regex(
        @"(^|[;&|(]\s*)sleep\s+\d|Start-Sleep|until .*(sleep|grep)|tasks[\\/][^ ""']*\.output", RegexOptions.IgnoreCase);

    static string Str(JsonElement e, string name) {
        JsonElement v;
        return e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out v) &&
            v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    }
    static long Num(JsonElement e, string name) {
        JsonElement v;
        return e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : 0;
    }
    static bool True(JsonElement e, string name) {
        JsonElement v;
        return e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.True;
    }

    // The prompt a user entry starts, as kind and text, or null when the entry starts no turn: tool results,
    // injected context, local command output.
    static string[] Prompt(JsonElement m) {
        JsonElement c;
        if (!m.TryGetProperty("content", out c)) return null;
        string s = null;
        if (c.ValueKind == JsonValueKind.String) s = c.GetString();
        else if (c.ValueKind == JsonValueKind.Array) {
            s = "";
            foreach (var b in c.EnumerateArray()) {
                string t = Str(b, "type");
                if (t == "tool_result") return null;
                if (t == "text") s += Str(b, "text") + " ";
                if (t == "image") s += "[image] ";
            }
        }
        if (s == null) return null;
        s = Space.Replace(Reminder.Replace(s, " "), " ").Trim();
        if (s.Length == 0 || s.StartsWith("<local-command") || s.StartsWith("<bash-") || s.StartsWith("Caveat:"))
            return null;
        string kind = "prompt";
        var cm = Command.Match(s);
        if (cm.Success) s = (cm.Groups[1].Value + " " + cm.Groups[2].Value).Trim();
        else if (s.StartsWith("<task-notification>")) kind = "notification";
        else if (s.StartsWith("This session is being continued")) kind = "resume";
        else if (s.StartsWith("[atrium]")) kind = "atrium";
        if (s.Length > 200) s = s.Substring(0, 200);
        return new[] { kind, s };
    }

    public static List<PromptTurn> Scan(string[] files, string projectsRoot, DateTime fromUtc, DateTime toUtc) {
        var turns = new List<PromptTurn>();
        var calls = new Dictionary<string, PromptCall>();
        foreach (var path in files) {
            string rel = path.Substring(projectsRoot.Length).TrimStart('\\', '/');
            string project = rel.Split('\\', '/')[0];
            bool sub = rel.Contains("\\subagents\\") || rel.Contains("/subagents/");
            PromptTurn cur = null;
            IEnumerable<string> lines;
            try { lines = System.IO.File.ReadLines(path); } catch { continue; }
            foreach (var line in lines) {
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); } catch { continue; }
                using (doc) {
                    var r = doc.RootElement;
                    if (r.ValueKind != JsonValueKind.Object) continue;
                    string type = Str(r, "type");
                    if (type != "user" && type != "assistant") continue;
                    JsonElement m;
                    if (!r.TryGetProperty("message", out m) || m.ValueKind != JsonValueKind.Object) continue;
                    DateTime t;
                    if (!DateTime.TryParse(Str(r, "timestamp"), null,
                            System.Globalization.DateTimeStyles.AdjustToUniversal, out t)) continue;
                    if (type == "user") {
                        if (True(r, "isMeta") || (!sub && True(r, "isSidechain"))) continue;
                        var p = Prompt(m);
                        if (p == null) continue;
                        cur = null;
                        if (t < fromUtc || t >= toUtc) continue;
                        cur = new PromptTurn {
                            SessionId = Str(r, "sessionId") ?? "", Project = project, File = path, IsSub = sub,
                            Kind = sub ? "subagent" : p[0],
                            Text = p[1], Time = t
                        };
                        turns.Add(cur);
                        continue;
                    }
                    JsonElement u;
                    if (cur == null || !m.TryGetProperty("usage", out u) || u.ValueKind != JsonValueKind.Object) continue;
                    if (!sub && True(r, "isSidechain")) continue;
                    string model = Str(m, "model") ?? "";
                    if (model == "<synthetic>") continue;
                    int br = model.IndexOf('[');
                    if (br > 0) model = model.Substring(0, br);
                    string id = Str(m, "id") ?? Str(r, "requestId") ?? Str(r, "uuid");
                    if (id == null) continue;
                    PromptCall call;
                    if (!calls.TryGetValue(id, out call)) {
                        call = new PromptCall { Id = id, Model = model, Time = t };
                        calls[id] = call;
                        cur.Calls.Add(call);   // a resumed session copies old entries; only the first copy counts
                        cur.Model = model;
                    }
                    call.In = Math.Max(call.In, Num(u, "input_tokens"));
                    call.Cw = Math.Max(call.Cw, Num(u, "cache_creation_input_tokens"));
                    call.Cr = Math.Max(call.Cr, Num(u, "cache_read_input_tokens"));
                    call.Out = Math.Max(call.Out, Num(u, "output_tokens"));
                    JsonElement content;
                    if (!m.TryGetProperty("content", out content) || content.ValueKind != JsonValueKind.Array) continue;
                    foreach (var b in content.EnumerateArray()) {
                        string bt = Str(b, "type");
                        if (bt == "text") call.Visible += (Str(b, "text") ?? "").Length;
                        if (bt != "tool_use") continue;
                        call.ToolCalls++;
                        string name = Str(b, "name") ?? "";
                        JsonElement input;
                        if (!b.TryGetProperty("input", out input) || input.ValueKind != JsonValueKind.Object) continue;
                        call.Visible += input.GetRawText().Length;
                        string cmd = Str(input, "command") ?? "", file = Str(input, "file_path") ?? "";
                        if (name == "TaskOutput" || name == "BashOutput" || name == "Monitor" || WaitCmd.IsMatch(cmd) ||
                            (name == "Read" && WaitCmd.IsMatch(file)))
                            call.Wait = true;
                        if (name == "Read" && file.Length > 0) call.Reads.Add(file);
                    }
                }
            }
        }
        turns.RemoveAll(x => x.Calls.Count == 0);
        foreach (var x in turns) x.Time = x.Time.ToLocalTime();
        return turns;
    }
}
