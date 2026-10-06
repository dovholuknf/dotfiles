# Shared pieces for the usage scripts: the price table, the transcript scanner, and the weekly window.
# Dot-source it: . "$PSScriptRoot\UsageCommon.ps1"

# API-equivalent prices, USD per million tokens, from the Anthropic pricing page:
#   https://platform.claude.com/docs/en/about-claude/pricing  (fetched 2026-09-27)
# Cache writes are 1.25x (5m) and 2x (1h) base input. Cache reads are 0.1x base input, except
# Opus 5.5 (0.05x) and Fable/Mythos 5.1 (0.025x). Long context (>200k) is standard price on 4.6+.
# Fast mode is priced separately (Opus 5.5 $8/$40, Opus 5 and 4.8 $10/$50); caching multipliers apply on top.
# A model missing here is reported as unpriced, never guessed.
$script:UsagePrices = @{
    'claude-fable-5-1'  = @{ In = 10; Cw5 = 12.50; Cw1h = 20; Cr = 0.25; Out = 50 }
    'claude-fable-5'    = @{ In = 10; Cw5 = 12.50; Cw1h = 20; Cr = 1.00; Out = 50 }
    'claude-opus-5-5'   = @{ In = 4;  Cw5 = 5.00;  Cw1h = 8;  Cr = 0.20; Out = 20 }
    'claude-opus-5'     = @{ In = 5;  Cw5 = 6.25;  Cw1h = 10; Cr = 0.50; Out = 25 }
    'claude-opus-4-8'   = @{ In = 5;  Cw5 = 6.25;  Cw1h = 10; Cr = 0.50; Out = 25 }
    'claude-opus-4-7'   = @{ In = 5;  Cw5 = 6.25;  Cw1h = 10; Cr = 0.50; Out = 25 }
    'claude-opus-4-6'   = @{ In = 5;  Cw5 = 6.25;  Cw1h = 10; Cr = 0.50; Out = 25 }
    'claude-opus-4-5'   = @{ In = 5;  Cw5 = 6.25;  Cw1h = 10; Cr = 0.50; Out = 25 }
    'claude-sonnet-5'   = @{ In = 2;  Cw5 = 2.50;  Cw1h = 4;  Cr = 0.20; Out = 10 }
    'claude-sonnet-4-6' = @{ In = 3;  Cw5 = 3.75;  Cw1h = 6;  Cr = 0.30; Out = 15 }
    'claude-sonnet-4-5' = @{ In = 3;  Cw5 = 3.75;  Cw1h = 6;  Cr = 0.30; Out = 15 }
    'claude-haiku-4-5'  = @{ In = 1;  Cw5 = 1.25;  Cw1h = 2;  Cr = 0.10; Out = 5 }
}
$script:UsageFastPrices = @{
    'claude-opus-5-5' = @{ In = 8;  Out = 40 }
    'claude-opus-5'   = @{ In = 10; Out = 50 }
    'claude-opus-4-8' = @{ In = 10; Out = 50 }
}

$script:ClaudeHome = Join-Path $env:USERPROFILE '.claude'
$script:UsageLogPath = Join-Path $script:ClaudeHome 'usage-log.jsonl'

if (-not ('UsageScan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

public class UsageRecord {
    public string MsgId, SessionId, Project, File, AgentId, AgentType, Model, Speed, Tools, Cwd;
    public bool IsSub;
    public DateTime Time;
    public long In, Cw5, Cw1h, Cr, Out;
}

// Reads Claude Code transcripts and returns one record per API message. Streamed responses write one
// transcript entry per content block, each repeating the usage block, so entries are merged by message
// id (max per field, earliest time, union of tool names). Resumed sessions can copy old entries into a
// new file; the global merge by id counts those once too.
public static class UsageScan {
    static string Str(JsonElement e, string name) {
        JsonElement v;
        return e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    }
    static long Num(JsonElement e, string name) {
        JsonElement v;
        return e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : 0;
    }

    public static List<UsageRecord> Scan(string[] files, string projectsRoot, DateTime fromUtc, DateTime toUtc) {
        var byId = new Dictionary<string, UsageRecord>();
        foreach (var path in files) {
            string rel = path.Substring(projectsRoot.Length).TrimStart('\\', '/');
            string project = rel.Split('\\', '/')[0];
            bool subPath = rel.Contains("\\subagents\\") || rel.Contains("/subagents/");
            IEnumerable<string> lines;
            try { lines = System.IO.File.ReadLines(path); } catch { continue; }
            foreach (var line in lines) {
                if (line.IndexOf("\"usage\"", StringComparison.Ordinal) < 0) continue;
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); } catch { continue; }
                using (doc) {
                    var r = doc.RootElement;
                    if (r.ValueKind != JsonValueKind.Object || Str(r, "type") != "assistant") continue;
                    JsonElement m, u;
                    if (!r.TryGetProperty("message", out m) || m.ValueKind != JsonValueKind.Object) continue;
                    if (!m.TryGetProperty("usage", out u) || u.ValueKind != JsonValueKind.Object) continue;
                    string model = Str(m, "model") ?? "";
                    if (model == "<synthetic>") continue;
                    int br = model.IndexOf('[');
                    if (br > 0) model = model.Substring(0, br);
                    DateTime t;
                    if (!DateTime.TryParse(Str(r, "timestamp"), null,
                            System.Globalization.DateTimeStyles.AdjustToUniversal, out t)) continue;
                    if (t < fromUtc || t >= toUtc) continue;
                    string id = Str(m, "id") ?? Str(r, "requestId") ?? Str(r, "uuid");
                    if (id == null) continue;

                    long cw5 = 0, cw1h = 0, cw = Num(u, "cache_creation_input_tokens");
                    JsonElement cc;
                    if (u.TryGetProperty("cache_creation", out cc) && cc.ValueKind == JsonValueKind.Object) {
                        cw5 = Num(cc, "ephemeral_5m_input_tokens");
                        cw1h = Num(cc, "ephemeral_1h_input_tokens");
                    }
                    if (cw5 + cw1h < cw) cw5 += cw - cw5 - cw1h;   // no split reported: treat as 5m

                    var tools = new List<string>();
                    JsonElement content;
                    if (m.TryGetProperty("content", out content) && content.ValueKind == JsonValueKind.Array) {
                        foreach (var b in content.EnumerateArray()) {
                            if (b.ValueKind == JsonValueKind.Object && Str(b, "type") == "tool_use") {
                                string n = Str(b, "name");
                                if (n != null) tools.Add(n);
                            }
                        }
                    }
                    JsonElement side;
                    bool isSub = subPath || (r.TryGetProperty("isSidechain", out side) &&
                                             side.ValueKind == JsonValueKind.True);

                    UsageRecord rec;
                    if (!byId.TryGetValue(id, out rec)) {
                        rec = new UsageRecord {
                            MsgId = id, SessionId = Str(r, "sessionId") ?? "", Project = project, File = path,
                            AgentId = Str(r, "agentId") ?? "", AgentType = Str(r, "attributionAgent") ?? "",
                            Model = model, Speed = Str(u, "speed") ?? "", Tools = "", Cwd = Str(r, "cwd") ?? "",
                            IsSub = isSub, Time = t
                        };
                        byId[id] = rec;
                    }
                    if (t < rec.Time) rec.Time = t;
                    rec.In = Math.Max(rec.In, Num(u, "input_tokens"));
                    rec.Cw5 = Math.Max(rec.Cw5, cw5);
                    rec.Cw1h = Math.Max(rec.Cw1h, cw1h);
                    rec.Cr = Math.Max(rec.Cr, Num(u, "cache_read_input_tokens"));
                    rec.Out = Math.Max(rec.Out, Num(u, "output_tokens"));
                    foreach (var n in tools) {
                        if (("," + rec.Tools + ",").IndexOf("," + n + ",", StringComparison.Ordinal) < 0)
                            rec.Tools = rec.Tools.Length == 0 ? n : rec.Tools + "," + n;
                    }
                }
            }
        }
        var list = new List<UsageRecord>(byId.Values);
        list.Sort((a, b) => a.Time.CompareTo(b.Time));
        return list;
    }
}
'@
}

# The current weekly window [Start, End) in local time. The reset time comes from the newest usage-log
# line, else the status line sample payload; it recurs every 7 days, so it is rolled forward past -Now.
function Get-WeekWindow {
    param([datetime]$Now = (Get-Date))
    $reset = $null
    if (Test-Path $script:UsageLogPath) {
        $last = Get-Content $script:UsageLogPath -Tail 50 |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
            Where-Object { $_.seven_day_resets_at -gt 0 } | Select-Object -Last 1
        if ($last) { $reset = $last.seven_day_resets_at }
    }
    if (-not $reset) {
        $sample = Join-Path $script:ClaudeHome 'statusline-payload.json'
        if (Test-Path $sample) { $reset = (Get-Content -Raw $sample | ConvertFrom-Json).rate_limits.seven_day.resets_at }
    }
    if (-not $reset) { throw 'no seven_day.resets_at found in the usage log or the sample payload; pass -From/-To' }
    $end = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset).LocalDateTime
    while ($end -le $Now) { $end = $end.AddDays(7) }
    while ($end.AddDays(-7) -gt $Now) { $end = $end.AddDays(-7) }
    [pscustomobject]@{ Start = $end.AddDays(-7); End = $end }
}

# One record per API message in [From, To), local times. Only files written since From are opened.
function Get-UsageRecords {
    param([Parameter(Mandatory)][datetime]$From, [Parameter(Mandatory)][datetime]$To)
    $root = Join-Path $script:ClaudeHome 'projects'
    $files = Get-ChildItem $root -Recurse -Filter *.jsonl -File |
        Where-Object LastWriteTime -ge $From | ForEach-Object FullName
    $recs = [UsageScan]::Scan([string[]]$files, $root, $From.ToUniversalTime(), $To.ToUniversalTime())
    foreach ($r in $recs) { $r.Time = $r.Time.ToLocalTime() }
    , $recs
}

# API-equivalent USD for one record, or $null when the model has no price.
function Get-UsageCost {
    param([Parameter(Mandatory)]$Rec)
    $p = $script:UsagePrices[$Rec.Model]
    if (-not $p) { return $null }
    $in = $p.In; $out = $p.Out
    if ($Rec.Speed -eq 'fast' -and $script:UsageFastPrices[$Rec.Model]) {
        $in = $script:UsageFastPrices[$Rec.Model].In; $out = $script:UsageFastPrices[$Rec.Model].Out
    }
    $k = $in / $p.In
    ($Rec.In * $in + $Rec.Cw5 * $p.Cw5 * $k + $Rec.Cw1h * $p.Cw1h * $k + $Rec.Cr * $p.Cr * $k +
        $Rec.Out * $out) / 1e6
}

# Per-token-class USD for a record, as a hashtable, for fits and splits. Unpriced models give zeros.
function Get-UsageCostParts {
    param([Parameter(Mandatory)]$Rec)
    $p = $script:UsagePrices[$Rec.Model]
    if (-not $p) { return @{ In = 0; Cw = 0; Cr = 0; Out = 0 } }
    @{
        In  = $Rec.In * $p.In / 1e6
        Cw  = ($Rec.Cw5 * $p.Cw5 + $Rec.Cw1h * $p.Cw1h) / 1e6
        Cr  = $Rec.Cr * $p.Cr / 1e6
        Out = $Rec.Out * $p.Out / 1e6
    }
}
