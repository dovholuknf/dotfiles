<#
.SYNOPSIS
    What burned the weekly Claude usage: tokens and API-equivalent cost from the local transcripts.
.DESCRIPTION
    Reads ~/.claude/projects/**/*.jsonl (main sessions and subagents), counts each API message once, and
    prints a markdown report: per day (and per hour with -Hourly), the top day and what happened in it,
    the startup baseline and what a smaller one would save, the split per model, cold cache wakes, and
    cost by context size with what compacting at a given size would have saved.
    Nothing leaves the machine.
.EXAMPLE
    ./Get-UsageReport.ps1                          # current weekly window
.EXAMPLE
    ./Get-UsageReport.ps1 -From 2026-09-20T18:00 -To 2026-09-27T18:00 -Hourly -OutFile week.md
#>
[CmdletBinding()]
param(
    [datetime]$From,
    [datetime]$To,
    [switch]$Hourly,
    [int]$Top = 8,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\UsageCommon.ps1"

if (-not $From -or -not $To) {
    $w = Get-WeekWindow
    if (-not $From) { $From = $w.Start }
    if (-not $To) { $To = $w.End }
}

# --- helpers ---------------------------------------------------------------------------------------------
function Tok([double]$n) {
    if ($n -ge 1e9) { '{0:N2}B' -f ($n / 1e9) } elseif ($n -ge 1e6) { '{0:N1}M' -f ($n / 1e6) }
    elseif ($n -ge 1e3) { '{0:N0}k' -f ($n / 1e3) } else { '{0:N0}' -f $n }
}
function Usd([double]$n) { '${0:N2}' -f $n }
function Pct([double]$part, [double]$whole) { if ($whole -gt 0) { '{0:N1}%' -f (100 * $part / $whole) } else { '-' } }
function MdTable {
    param([Parameter(Mandatory)][object[]]$Rows, [string[]]$Cols)
    if (-not $Rows) { return '_(none)_' }
    if (-not $Cols) { $Cols = $Rows[0].PSObject.Properties.Name }
    $out = @(('| ' + ($Cols -join ' | ') + ' |'), ('|' + (($Cols | ForEach-Object { '---' }) -join '|') + '|'))
    foreach ($r in $Rows) { $out += '| ' + (($Cols | ForEach-Object { "$($r.$_)" -replace '\|', '/' }) -join ' | ') + ' |' }
    $out -join "`n"
}
function Sum($items, [string]$prop) { [double](($items | Measure-Object -Property $prop -Sum).Sum) }
function Totals($items) {
    [pscustomobject]@{
        Calls = @($items).Count
        In = Sum $items In; Cw5 = Sum $items Cw5; Cw1h = Sum $items Cw1h; Cr = Sum $items Cr; Out = Sum $items Out
        Cost = Sum $items Cost
    }
}
function TokRow([string]$label, $t, [double]$whole) {
    [ordered]@{
        $label = $null; Calls = $t.Calls; Input = Tok $t.In; 'Write 5m' = Tok $t.Cw5; 'Write 1h' = Tok $t.Cw1h
        'Cache read' = Tok $t.Cr; Output = Tok $t.Out; Cost = Usd $t.Cost; Share = Pct $t.Cost $whole
    }
}

# --- load ------------------------------------------------------------------------------------------------
# Load two extra weeks before From so a stream that started earlier is known to be carried over; its
# first in-window call is a resume, not a startup, and is kept out of the baseline numbers.
$all = Get-UsageRecords -From $From.AddDays(-14) -To $To
$firstSeen = @{}
foreach ($r in $all) {
    $key = $r.SessionId + '|' + $(if ($r.IsSub) { $r.AgentId } else { '' })
    if (-not $firstSeen.ContainsKey($key)) { $firstSeen[$key] = $r.Time }
}
$unpriced = @{}
$recs = foreach ($r in $all) {
    if ($r.Time -lt $From) { continue }
    $c = Get-UsageCost $r
    if ($null -eq $c) { $unpriced[$r.Model]++; $c = 0 }
    $key = $r.SessionId + '|' + $(if ($r.IsSub) { $r.AgentId } else { '' })
    [pscustomobject]@{
        Time = $r.Time; Day = $r.Time.ToString('yyyy-MM-dd ddd'); Hour = $r.Time.ToString('yyyy-MM-dd HH:00')
        SessionId = $r.SessionId; Project = $r.Project; IsSub = $r.IsSub; AgentId = $r.AgentId
        AgentType = $(if ($r.AgentType) { $r.AgentType } else { 'unknown' }); Stream = $key
        Model = $r.Model; Speed = $r.Speed; Tools = $r.Tools
        In = $r.In; Cw5 = $r.Cw5; Cw1h = $r.Cw1h; Cr = $r.Cr; Out = $r.Out; Cost = $c
        Carried = $firstSeen[$key] -lt $From
    }
}
$recs = @($recs)
if (-not $recs) { throw "no API calls found between $From and $To" }
$grand = Totals $recs

# --- per-stream events: gaps, cold wakes, context jumps ---------------------------------------------------
# A stream is one conversation: a main session, or one subagent inside it. Each call is tagged with the
# gap since the previous call in its stream. A cache write after a gap past the 5m or 1h TTL is a cold
# wake; a large write with no gap is new content (a file read, a tool result) landing in the context.
$events = foreach ($g in ($recs | Group-Object Stream)) {
    $prev = $null; $i = 0
    foreach ($r in ($g.Group | Sort-Object Time)) {
        $gap = if ($prev) { ($r.Time - $prev.Time).TotalMinutes } else { $null }
        $p = $script:UsagePrices[$r.Model]
        $cwCost = if ($p) { ($r.Cw5 * $p.Cw5 + $r.Cw1h * $p.Cw1h) / 1e6 } else { 0 }
        [pscustomobject]@{
            Rec = $r; Index = $i; Gap = $gap; CwTok = $r.Cw5 + $r.Cw1h; CwCost = $cwCost
            PrevTools = $(if ($prev) { $prev.Tools } else { '' })
        }
        $prev = $r; $i++
    }
}
$events = @($events)
$wake5 = @($events | Where-Object { $_.Gap -gt 5 -and $_.CwTok -gt 0 })
$wake60 = @($events | Where-Object { $_.Gap -gt 60 -and $_.CwTok -gt 0 })
$jumps = @($events | Where-Object { $_.Gap -ne $null -and $_.Gap -le 5 -and $_.CwTok -ge 20000 })

$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# Claude usage report: $($From.ToString('yyyy-MM-dd HH:mm')) to $($To.ToString('yyyy-MM-dd HH:mm'))")
$md.Add('')
$md.Add("API-equivalent cost at public list prices (see UsageCommon.ps1 for the table and source). This is not " +
    "the weekly meter, which Anthropic does not publish; it is the best local proxy for it.")
$md.Add('')
$md.Add("- Calls: $($grand.Calls), cost: $(Usd $grand.Cost), output: $(Tok $grand.Out), " +
    "input incl. cache: $(Tok ($grand.In + $grand.Cw5 + $grand.Cw1h + $grand.Cr))")
if ($unpriced.Count) {
    $md.Add("- UNPRICED models (counted as `$0): " +
        (($unpriced.GetEnumerator() | ForEach-Object { "$($_.Key) ($($_.Value) calls)" }) -join ', '))
}
$md.Add('')

# --- 1. per day / per hour --------------------------------------------------------------------------------
$md.Add('## 1. Per day')
$md.Add('')
$days = foreach ($g in ($recs | Group-Object Day | Sort-Object Name)) {
    $row = TokRow 'Day' (Totals $g.Group) $grand.Cost; $row.Day = $g.Name; [pscustomobject]$row
}
$md.Add((MdTable @($days)))
$md.Add('')
if ($Hourly) {
    $md.Add('### Per hour')
    $md.Add('')
    $hours = foreach ($g in ($recs | Group-Object Hour | Sort-Object Name)) {
        $row = TokRow 'Hour' (Totals $g.Group) $grand.Cost; $row.Hour = $g.Name; [pscustomobject]$row
    }
    $md.Add((MdTable @($hours)))
    $md.Add('')
}

# --- 2. the top day ---------------------------------------------------------------------------------------
$topDay = $recs | Group-Object Day | Sort-Object { Sum $_.Group Cost } -Descending | Select-Object -First 1
$dayRecs = @($topDay.Group)
$dayT = Totals $dayRecs
$md.Add("## 2. Top day: $($topDay.Name), $(Usd $dayT.Cost) ($(Pct $dayT.Cost $grand.Cost) of the window)")
$md.Add('')
$mainT = Totals @($dayRecs | Where-Object { -not $_.IsSub })
$subT = Totals @($dayRecs | Where-Object IsSub)
$md.Add("- Main sessions: $(Usd $mainT.Cost) in $($mainT.Calls) calls; subagents: $(Usd $subT.Cost) in " +
    "$($subT.Calls) calls ($(Pct $subT.Cost $dayT.Cost)).")
$dayEv = @($events | Where-Object { $_.Rec.Day -eq $topDay.Name })
$dw5 = @($dayEv | Where-Object { $_.Gap -gt 5 -and $_.CwTok -gt 0 })
$dw60 = @($dayEv | Where-Object { $_.Gap -gt 60 -and $_.CwTok -gt 0 })
$dj = @($dayEv | Where-Object { $_.Gap -ne $null -and $_.Gap -le 5 -and $_.CwTok -ge 20000 })
$dstart = @($dayEv | Where-Object { $_.Index -eq 0 })
$md.Add("- Cold wakes: $($dw5.Count) cache writes after a gap over 5 min, $(Usd (Sum $dw5 CwCost)); " +
    "$($dw60.Count) after a gap over 1 h, $(Usd (Sum $dw60 CwCost)).")
$md.Add("- Stream starts (first call of a session or subagent): $($dstart.Count), cache writes " +
    "$(Usd (Sum $dstart CwCost)).")
$md.Add("- Context jumps (a write of 20k+ tokens with no gap, i.e. a big tool result): $($dj.Count), " +
    "$(Usd (Sum $dj CwCost)) of writes.")
$md.Add("- Cache writes overall: $(Usd (Sum $dayEv CwCost)) of the day's $(Usd $dayT.Cost); " +
    "cache reads $(Usd ((($dayRecs | ForEach-Object { (Get-UsageCostParts $_).Cr }) | Measure-Object -Sum).Sum)); " +
    "output $(Usd ((($dayRecs | ForEach-Object { (Get-UsageCostParts $_).Out }) | Measure-Object -Sum).Sum)).")
$md.Add('')

$md.Add('### Top sessions that day')
$md.Add('')
$sess = foreach ($g in ($dayRecs | Group-Object SessionId)) {
    $gr = $g.Group
    $main = @($gr | Where-Object { -not $_.IsSub }); $sub = @($gr | Where-Object IsSub)
    $sw = @($dayEv | Where-Object { $_.Rec.SessionId -eq $g.Name -and $_.Gap -gt 5 -and $_.CwTok -gt 0 })
    [pscustomobject]@{
        Session = $g.Name.Substring(0, [math]::Min(8, $g.Name.Length)); Project = $gr[0].Project
        Span = '{0:HH:mm}-{1:HH:mm}' -f ($gr | Sort-Object Time)[0].Time, ($gr | Sort-Object Time)[-1].Time
        Models = (($gr | Group-Object Model | Sort-Object Count -Descending | ForEach-Object Name) -join ' ')
        'Main calls' = $main.Count; Main = Usd (Sum $main Cost)
        Subagents = @($sub | Group-Object AgentId).Count; 'Sub cost' = Usd (Sum $sub Cost)
        'Cold wakes' = "$($sw.Count) / $(Usd (Sum $sw CwCost))"
        Cost = Usd (Sum $gr Cost); Share = Pct (Sum $gr Cost) $dayT.Cost; _c = Sum $gr Cost
    }
}
$md.Add((MdTable @($sess | Sort-Object _c -Descending | Select-Object -First $Top) `
    -Cols Session, Project, Span, Models, 'Main calls', Main, Subagents, 'Sub cost', 'Cold wakes', Cost, Share))
$md.Add('')

$md.Add('### Top projects that day')
$md.Add('')
$proj = foreach ($g in ($dayRecs | Group-Object Project)) {
    $main = @($g.Group | Where-Object { -not $_.IsSub }); $sub = @($g.Group | Where-Object IsSub)
    [pscustomobject]@{
        Project = $g.Name; Sessions = @($g.Group | Group-Object SessionId).Count
        Main = Usd (Sum $main Cost); Subagents = Usd (Sum $sub Cost)
        Cost = Usd (Sum $g.Group Cost); Share = Pct (Sum $g.Group Cost) $dayT.Cost; _c = Sum $g.Group Cost
    }
}
$md.Add((MdTable @($proj | Sort-Object _c -Descending | Select-Object -First $Top) `
    -Cols Project, Sessions, Main, Subagents, Cost, Share))
$md.Add('')

$md.Add('### Subagent types that day')
$md.Add('')
$types = foreach ($g in (@($dayRecs | Where-Object IsSub) | Group-Object AgentType)) {
    [pscustomobject]@{
        Type = $g.Name; Agents = @($g.Group | Group-Object AgentId).Count; Calls = $g.Count
        Models = (($g.Group | Group-Object Model | ForEach-Object Name) -join ' ')
        Cost = Usd (Sum $g.Group Cost); _c = Sum $g.Group Cost
    }
}
$md.Add((MdTable @($types | Sort-Object _c -Descending) -Cols Type, Agents, Calls, Models, Cost))
$md.Add('')

$md.Add('### Busiest hours that day')
$md.Add('')
$dh = foreach ($g in ($dayRecs | Group-Object Hour)) {
    $row = TokRow 'Hour' (Totals $g.Group) $dayT.Cost; $row.Hour = $g.Name; $row._c = Sum $g.Group Cost
    [pscustomobject]$row
}
$md.Add((MdTable @($dh | Sort-Object Hour) -Cols Hour, Calls, Input, 'Write 5m', 'Write 1h', 'Cache read', Output, Cost, Share))
$md.Add('')

$md.Add('### Biggest single calls that day')
$md.Add('')
$big = $dayEv | Sort-Object { $_.Rec.Cost } -Descending | Select-Object -First $Top | ForEach-Object {
    $r = $_.Rec
    $why = if ($_.Index -eq 0) { if ($r.Carried) { 'resume' } else { 'stream start' } }
        elseif ($_.Gap -gt 60) { 'cold wake >1h' } elseif ($_.Gap -gt 5) { 'cold wake >5m' }
        elseif ($_.CwTok -ge 20000) { "context jump after $(if ($_.PrevTools) { $_.PrevTools } else { 'a prompt' })" }
        elseif ($r.Out -ge 8000) { 'long output' }
        else { 'large context' }
    [pscustomobject]@{
        Time = $r.Time.ToString('HH:mm:ss'); Session = $r.SessionId.Substring(0, 8)
        Who = $(if ($r.IsSub) { "sub:$($r.AgentType)" } else { 'main' }); Model = $r.Model
        Gap = $(if ($null -ne $_.Gap) { '{0:N0}m' -f $_.Gap } else { '-' })
        Write = Tok $_.CwTok; Read = Tok $r.Cr; Out = Tok $r.Out; Cost = Usd $r.Cost; Why = $why
    }
}
$md.Add((MdTable @($big)))
$md.Add('')

# --- 3. startup baseline ----------------------------------------------------------------------------------
# Baseline = the first call's full input (uncached + written + read) in a stream that started inside the
# window. Every later call in that stream re-sends it. The saving from a baseline X tokens smaller is
# priced per call: X comes off that call's cache reads first, then its cache writes, then uncached input,
# so a cold wake (all write, no read) saves at the write price and a warm call at the read price.
$md.Add('## 3. Startup baseline')
$md.Add('')
$totalInput = $grand.In + $grand.Cw5 + $grand.Cw1h + $grand.Cr
$streams = foreach ($g in ($events | Group-Object { $_.Rec.Stream })) {
    $ev = @($g.Group | Sort-Object Index)
    $first = $ev[0].Rec
    if ($first.Carried) { continue }
    [pscustomobject]@{
        Stream = $g.Name; IsSub = $first.IsSub; Calls = $ev.Count; Events = $ev
        Base = $first.In + $first.Cw5 + $first.Cw1h + $first.Cr
    }
}
$streams = @($streams)
function Saving($streamSet, [double]$x) {
    $usd = 0.0
    foreach ($s in $streamSet) {
        $cut = [math]::Min($x, $s.Base)
        foreach ($e in $s.Events) {
            $r = $e.Rec; $p = $script:UsagePrices[$r.Model]; if (-not $p) { continue }
            $left = $cut
            $a = [math]::Min($left, $r.Cr); $usd += $a * $p.Cr; $left -= $a
            $w1 = [math]::Min($left, $r.Cw1h); $usd += $w1 * $p.Cw1h; $left -= $w1
            $w5 = [math]::Min($left, $r.Cw5); $usd += $w5 * $p.Cw5; $left -= $w5
            $usd += [math]::Min($left, $r.In) * $p.In
        }
    }
    $usd / 1e6
}
$baseRows = foreach ($set in @(
        @{ N = 'Main sessions'; S = @($streams | Where-Object { -not $_.IsSub }) },
        @{ N = 'Subagents'; S = @($streams | Where-Object IsSub) },
        @{ N = 'All'; S = $streams })) {
    $s = $set.S
    if (-not $s) { continue }
    $carried = ($s | ForEach-Object { $_.Base * $_.Calls } | Measure-Object -Sum).Sum
    $bases = @($s | ForEach-Object Base | Sort-Object)
    [pscustomobject]@{
        Streams = $set.N; Count = $s.Count; 'Median base' = Tok $bases[[int]($bases.Count / 2)]
        'Median calls' = @($s | ForEach-Object Calls | Sort-Object)[[int]($s.Count / 2)]
        'Base x calls' = Tok $carried; 'Share of all input' = Pct $carried $totalInput
        'Save 10k' = Usd (Saving $s 10000); 'Save 20k' = Usd (Saving $s 20000); 'Save 30k' = Usd (Saving $s 30000)
    }
}
$md.Add((MdTable @($baseRows)))
$md.Add('')
$md.Add("Streams that began before $($From.ToString('yyyy-MM-dd HH:mm')) (resumes) are left out: " +
    "$(@($events | Where-Object { $_.Index -eq 0 -and $_.Rec.Carried }).Count) of them. " +
    'The first call includes the first prompt, so the base is a slight overcount of the pure startup context.')
$md.Add('')

# --- 4. per model -----------------------------------------------------------------------------------------
$md.Add('## 4. Per model')
$md.Add('')
$models = foreach ($g in ($recs | Group-Object { "$($_.Model)|$(if ($_.IsSub) { 'sub' } else { 'main' })" } | Sort-Object Name)) {
    $t = Totals $g.Group
    $m, $who = $g.Name -split '\|'
    [pscustomobject]@{
        Model = $m; Who = $who; Calls = $t.Calls; Input = Tok $t.In; 'Write 5m' = Tok $t.Cw5; 'Write 1h' = Tok $t.Cw1h
        'Cache read' = Tok $t.Cr; Output = Tok $t.Out; Cost = Usd $t.Cost; Share = Pct $t.Cost $grand.Cost
        'Avg ctx' = Tok (($t.In + $t.Cw5 + $t.Cw1h + $t.Cr) / [math]::Max(1, $t.Calls))
        'Cost/call' = '${0:N3}' -f ($t.Cost / [math]::Max(1, $t.Calls))
        '$/1k out' = '${0:N3}' -f (1000 * $t.Cost / [math]::Max(1, $t.Out))
        Priced = $(if ($script:UsagePrices[$m]) { 'yes' } else { 'NO' })
    }
}
$md.Add((MdTable @($models)))
$md.Add('')
$md.Add('Cost per output token folds in context size and cache behaviour, so it compares workloads, not ' +
    'models. It cannot show which model moves the weekly meter faster: that needs the meter itself ' +
    '(usage-log.jsonl) regressed against each model''s tokens, which Get-BurnFit.ps1 does.')
$md.Add('')

# --- 5. cold wakes ----------------------------------------------------------------------------------------
$md.Add('## 5. Cold wakes')
$md.Add('')
$wakeRows = foreach ($set in @(
        @{ N = 'gap > 5 min'; E = $wake5 }, @{ N = 'gap > 1 h'; E = $wake60 },
        @{ N = 'stream starts'; E = @($events | Where-Object { $_.Index -eq 0 -and -not $_.Rec.Carried }) },
        @{ N = 'resumes'; E = @($events | Where-Object { $_.Index -eq 0 -and $_.Rec.Carried }) },
        @{ N = 'context jumps (no gap, 20k+ write)'; E = $jumps })) {
    $e = $set.E
    [pscustomobject]@{
        Kind = $set.N; Count = $e.Count
        'Main' = Usd (Sum @($e | Where-Object { -not $_.Rec.IsSub }) CwCost)
        'Subagents' = Usd (Sum @($e | Where-Object { $_.Rec.IsSub }) CwCost)
        'Write tokens' = Tok (Sum $e CwTok); 'Write cost' = Usd (Sum $e CwCost)
        'Share of all cost' = Pct (Sum $e CwCost) $grand.Cost
    }
}
$md.Add((MdTable @($wakeRows)))
$md.Add('')
$allCw = Sum $events CwCost
$md.Add("All cache writes: $(Usd $allCw) ($(Pct $allCw $grand.Cost) of cost). 1h-TTL writes: " +
    "$(Tok $grand.Cw1h), 5m-TTL writes: $(Tok $grand.Cw5). The 'gap > 1 h' rows are a subset of 'gap > 5 min'.")
$md.Add('')
$jt = $jumps | ForEach-Object { if ($_.PrevTools) { $_.PrevTools -split ',' } else { '(none)' } } |
    Group-Object | Sort-Object Count -Descending | Select-Object -First 10 |
    ForEach-Object { "$($_.Name) ($($_.Count))" }
$md.Add("Tools behind the context jumps: $($jt -join ', ').")
$md.Add('')

# --- 6. context size --------------------------------------------------------------------------------------
# Every call re-sends the whole context, so cost grows with context x calls. A cap is what a /compact (or a
# fresh session) at that size would have saved: the tokens above the cap on each call, taken off its cache
# reads first and then its writes. It ignores the compaction call itself and any re-reads it causes.
$md.Add('## 6. Context size')
$md.Add('')
$bands = @(0, 50000, 100000, 200000, 400000, 600000, [double]::MaxValue)
$ctxOf = { param($r) $r.In + $r.Cw5 + $r.Cw1h + $r.Cr }
$bandRows = for ($i = 0; $i -lt $bands.Count - 1; $i++) {
    $lo = $bands[$i]; $hi = $bands[$i + 1]
    $b = @($recs | Where-Object { $c = & $ctxOf $_; $c -ge $lo -and $c -lt $hi })
    $label = if ($hi -eq [double]::MaxValue) { "$(Tok $lo)+" } else { "$(Tok $lo)-$(Tok $hi)" }
    [pscustomobject]@{
        Context = $label; Calls = $b.Count; 'Calls %' = Pct $b.Count $grand.Calls
        Cost = Usd (Sum $b Cost); 'Cost %' = Pct (Sum $b Cost) $grand.Cost
    }
}
$md.Add((MdTable @($bandRows)))
$md.Add('')
function CapSaving([double]$cap) {
    $usd = 0.0
    foreach ($r in $recs) {
        $p = $script:UsagePrices[$r.Model]; if (-not $p) { continue }
        $left = [math]::Max(0, (& $ctxOf $r) - $cap); if ($left -le 0) { continue }
        $a = [math]::Min($left, $r.Cr); $usd += $a * $p.Cr; $left -= $a
        $w1 = [math]::Min($left, $r.Cw1h); $usd += $w1 * $p.Cw1h; $left -= $w1
        $usd += [math]::Min($left, $r.Cw5) * $p.Cw5
    }
    $usd / 1e6
}
$capRows = foreach ($cap in 150000, 200000, 300000, 400000) {
    $s = CapSaving $cap
    [pscustomobject]@{ 'Compact at' = Tok $cap; 'Saving' = Usd $s; 'Share of cost' = Pct $s $grand.Cost }
}
$md.Add((MdTable @($capRows)))
$md.Add('')
$longest = foreach ($g in ($recs | Where-Object { -not $_.IsSub } | Group-Object SessionId)) {
    $gr = @($g.Group | Sort-Object Time)
    $mx = ($gr | ForEach-Object { & $ctxOf $_ } | Measure-Object -Maximum).Maximum
    [pscustomobject]@{
        Session = $g.Name.Substring(0, 8); Project = $gr[0].Project
        Hours = '{0:N1}' -f ($gr[-1].Time - $gr[0].Time).TotalHours; Calls = $gr.Count
        'Max ctx' = Tok $mx; Cost = Usd (Sum $gr Cost); _c = Sum $gr Cost
        'Over 200k' = Usd ((@($gr | Where-Object { (& $ctxOf $_) -ge 200000 }) | Measure-Object Cost -Sum).Sum)
    }
}
$md.Add('### Costliest main sessions in the window')
$md.Add('')
$md.Add((MdTable @($longest | Sort-Object _c -Descending | Select-Object -First $Top) `
    -Cols Session, Project, Hours, Calls, 'Max ctx', Cost, 'Over 200k'))
$md.Add('')

$text = $md -join "`n"
if ($OutFile) { Set-Content -Path $OutFile -Value $text -Encoding utf8; Write-Host "wrote $OutFile" } else { $text }
