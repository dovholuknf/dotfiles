<#
.SYNOPSIS
    Where the tokens went, per prompt: what each prompt cost, the worst ones, and what to change.
.DESCRIPTION
    Reads ~/.claude/projects/**/*.jsonl, charges every API call to the prompt before it, and prints a markdown
    report: status, spend per project and session, the prompts that cost the most, the worst turns by kind, and an
    evaluation with the number behind each finding and the fix. Tokens, not dollars: a prompt's total is every
    token its calls sent and got back, context re-reads included. Nothing leaves the machine.
.EXAMPLE
    ./Get-TokenReport.ps1                         # last 7 days
.EXAMPLE
    ./Get-TokenReport.ps1 -Days 1 -Top 20 -Project '*openziti*' -OutFile today.md
.EXAMPLE
    ./Get-TokenReport.ps1 -Json | ConvertFrom-Json  # the per-prompt rows, for other tools
#>
[CmdletBinding()]
param(
    [int]$Days = 7,
    [datetime]$From,
    [datetime]$To,
    [int]$Top = 10,
    [string]$Project = '*',
    [string]$OutFile,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\UsageCommon.ps1"
if (-not ('PromptScan' -as [type])) { Add-Type -Path "$PSScriptRoot\PromptScan.cs" }

if (-not $To) { $To = Get-Date }
if (-not $From) { $From = $To.AddDays(-$Days) }

function Tok([double]$n) {
    if ($n -ge 1e9) { '{0:N2}B' -f ($n / 1e9) } elseif ($n -ge 1e6) { '{0:N1}M' -f ($n / 1e6) }
    elseif ($n -ge 1e3) { '{0:N0}k' -f ($n / 1e3) } else { '{0:N0}' -f $n }
}
function Pct([double]$part, [double]$whole) { if ($whole -gt 0) { '{0:N0}%' -f (100 * $part / $whole) } else { '-' } }
function MdTable([object[]]$Rows) {
    if (-not $Rows) { return '_(none)_' }
    $cols = $Rows[0].Keys
    $out = @(('| ' + ($cols -join ' | ') + ' |'), ('|' + (($cols | ForEach-Object { '---' }) -join '|') + '|'))
    foreach ($r in $Rows) { $out += '| ' + (($cols | ForEach-Object { "$($r[$_])" -replace '\|', '/' }) -join ' | ') + ' |' }
    $out -join "`n"
}
function Short([string]$s, [int]$n = 70) { if ($s.Length -gt $n) { $s.Substring(0, $n - 1) + '…' } else { $s } }
function Sum($items, [string]$prop) { [double](($items | Measure-Object -Property $prop -Sum).Sum) }
function Median([double[]]$xs) { if (-not $xs) { 0 } else { ($xs | Sort-Object)[[int]($xs.Count / 2)] } }

# --- load ------------------------------------------------------------------------------------------------
$root = Join-Path $script:ClaudeHome 'projects'
$files = Get-ChildItem $root -Recurse -Filter *.jsonl -File | Where-Object LastWriteTime -ge $From | ForEach-Object FullName
$turns = [PromptScan]::Scan([string[]]$files, $root, $From.ToUniversalTime(), $To.ToUniversalTime()) |
    Where-Object Project -like $Project

if ($Json) {
    $turns | ForEach-Object {
        [ordered]@{ time = $_.Time.ToString('s'); project = $_.Project; session = $_.SessionId; kind = $_.Kind
            sub = $_.IsSub; model = $_.Model; calls = $_.Calls.Count; tools = $_.ToolCalls; input = $_.In
            cache_write = $_.Cw; cache_read = $_.Cr; output = $_.Out; total = $_.Total; max_context = $_.MaxContext
            prompt = $_.Text }
    } | ConvertTo-Json -Depth 3
    return
}

$main = @($turns | Where-Object { -not $_.IsSub })
$typed = @($main | Where-Object Kind -eq 'prompt')
$calls = @($turns | ForEach-Object { $_.Calls })
$grand = Sum $turns Total
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# Tokens, $($From.ToString('yyyy-MM-dd HH:mm')) to $($To.ToString('yyyy-MM-dd HH:mm'))")
$md.Add('')
$md.Add('A prompt''s total is every token its API calls sent and got back. Most of it is the context re-read on each')
$md.Add('call, so a turn costs at least the size of the session before you type a word.')

# --- status ----------------------------------------------------------------------------------------------
function StatusRow([string]$label, $ts) {
    $t = @($ts); $c = @($t | ForEach-Object { $_.Calls })
    [ordered]@{ '' = $label; Prompts = @($t | Where-Object { -not $_.IsSub -and $_.Kind -eq 'prompt' }).Count
        Calls = $c.Count; Total = Tok (Sum $t Total); 'Cache read' = Tok (Sum $t Cr); 'Cache write' = Tok (Sum $t Cw)
        Input = Tok (Sum $t In); Output = Tok (Sum $t Out); 'Per prompt' = Tok ((Sum $t Total) / [math]::Max(1, $t.Count)) }
}
$md.Add(''); $md.Add('## Status'); $md.Add('')
$md.Add((MdTable @(
    (StatusRow 'window' $turns),
    (StatusRow 'today' ($turns | Where-Object { $_.Time.Date -eq (Get-Date).Date })),
    (StatusRow 'subagents' ($turns | Where-Object IsSub)))))

# --- where it went ---------------------------------------------------------------------------------------
$md.Add(''); $md.Add('## Per project'); $md.Add('')
$md.Add((MdTable @($turns | Group-Object Project | Sort-Object { Sum $_.Group Total } -Descending |
    Select-Object -First $Top | ForEach-Object {
    $t = $_.Group
    [ordered]@{ Project = $_.Name -replace '^[A-Za-z]--', ''; Sessions = @($t.SessionId | Sort-Object -Unique).Count
        Prompts = @($t | Where-Object { -not $_.IsSub -and $_.Kind -eq 'prompt' }).Count; Total = Sum $t Total
        Share = Pct (Sum $t Total) $grand; 'Per prompt' = Tok ((Sum $t Total) / [math]::Max(1, $t.Count)) }
} | ForEach-Object { $_.Total = Tok $_.Total; $_ })))

$md.Add(''); $md.Add('## Per session'); $md.Add('')
$md.Add((MdTable @($turns | Group-Object SessionId | Sort-Object { Sum $_.Group Total } -Descending |
    Select-Object -First $Top | ForEach-Object {
    $t = $_.Group | Sort-Object Time
    $first = $t | Where-Object { -not $_.IsSub -and $_.Kind -eq 'prompt' } | Select-Object -First 1
    [ordered]@{ Started = $t[0].Time.ToString('MM-dd HH:mm'); Project = $t[0].Project -replace '^[A-Za-z]--', ''
        Turns = @($t | Where-Object { -not $_.IsSub }).Count; Total = Sum $t Total
        'Max context' = Tok (($t | ForEach-Object MaxContext | Measure-Object -Maximum).Maximum)
        'First prompt' = Short "$($first.Text)" 60 }
} | ForEach-Object { $_.Total = Tok $_.Total; $_ })))

# --- prompts ---------------------------------------------------------------------------------------------
function TurnRow($x) {
    [ordered]@{ When = $x.Time.ToString('MM-dd HH:mm'); Project = Short ($x.Project -replace '^[A-Za-z]--', '') 28
        Kind = $x.Kind; Calls = $x.Calls.Count; Total = Tok $x.Total; Read = Tok $x.Cr; Write = Tok $x.Cw
        Out = Tok $x.Out; 'Context at start' = Tok $x.FirstContext; Prompt = Short $x.Text }
}
$md.Add(''); $md.Add('## Prompts that cost the most'); $md.Add('')
$md.Add('Your typed prompts, sorted by total. The calls column is how many API calls the turn took.')
$md.Add('')
$md.Add((MdTable @($typed | Sort-Object Total -Descending | Select-Object -First $Top | ForEach-Object { TurnRow $_ })))

# --- worst -----------------------------------------------------------------------------------------------
$md.Add(''); $md.Add('## Worst turns'); $md.Add('')

$md.Add('### Big re-read, little said')
$md.Add('')
$md.Add('Turns whose visible reply and tool input came to under 400 characters, by total. Output past that is')
$md.Add('thinking you never see.')
$md.Add('')
$md.Add((MdTable @($main | Where-Object { $_.Visible -lt 400 } | Sort-Object Total -Descending |
    Select-Object -First $Top | ForEach-Object { $r = TurnRow $_; $r['Visible chars'] = $_.Visible; $r })))

$md.Add(''); $md.Add('### Most calls in one turn'); $md.Add('')
$md.Add('Every call re-reads the whole context, so 30 calls at 200k is 6M tokens.')
$md.Add('')
$md.Add((MdTable @($main | Sort-Object { $_.Calls.Count } -Descending | Select-Object -First $Top | ForEach-Object { TurnRow $_ })))

$waits = @($turns | Where-Object { $_.WaitTotal -gt 0 })
$md.Add(''); $md.Add('### Waiting'); $md.Add('')
$md.Add('Turns with sleeps, polls or reads of a background task''s output, by tokens spent on those calls.')
$md.Add('')
$md.Add((MdTable @($waits | Sort-Object WaitTotal -Descending | Select-Object -First $Top | ForEach-Object {
    $r = TurnRow $_; $r['On waiting'] = Tok $_.WaitTotal; $r })))

$reads = @($turns | Group-Object SessionId | ForEach-Object {
    $sid = $_.Name; $proj = $_.Group[0].Project
    $_.Group | ForEach-Object { $_.Calls } | ForEach-Object { $_.Reads } | Group-Object | Where-Object Count -ge 3 |
        ForEach-Object { [ordered]@{ Project = Short ($proj -replace '^[A-Za-z]--', '') 28; Session = $sid.Substring(0, 8)
            File = $(if ($_.Name.Length -gt 60) { '…' + $_.Name.Substring($_.Name.Length - 59) } else { $_.Name }); Reads = $_.Count } }
})
$md.Add(''); $md.Add('### Same file read again'); $md.Add('')
$md.Add('Files read three or more times in one session.')
$md.Add('')
$md.Add((MdTable @($reads | Sort-Object { $_['Reads'] } -Descending | Select-Object -First $Top)))

$over = 200000
$md.Add(''); $md.Add("### Past $(Tok $over) context"); $md.Add('')
$md.Add("Sessions by tokens spent on calls that carried more than $(Tok $over) of context.")
$md.Add('')
$md.Add((MdTable @($turns | Group-Object SessionId |
    Sort-Object { Sum ($_.Group | ForEach-Object { $_.Calls } | Where-Object { $_.Context -gt $over }) Total } -Descending |
    Select-Object -First $Top | ForEach-Object {
    $big = @($_.Group | ForEach-Object { $_.Calls } | Where-Object { $_.Context -gt $over })
    if ($big) {
        [ordered]@{ Project = Short ($_.Group[0].Project -replace '^[A-Za-z]--', '') 28; Session = $_.Name.Substring(0, 8)
            Calls = $big.Count; Total = Sum $big Total
            'Max context' = Tok (($big | ForEach-Object Context | Measure-Object -Maximum).Maximum) }
    }
} | ForEach-Object { $_.Total = Tok $_.Total; $_ })))

$wakes = @($main | Where-Object Kind -in 'notification', 'atrium')
$md.Add(''); $md.Add('### Woken by a notification or a peer'); $md.Add('')
$md.Add('Turns started by a background task finishing or an atrium message rather than by you.')
$md.Add('')
$md.Add((MdTable @($wakes | Sort-Object Total -Descending | Select-Object -First $Top | ForEach-Object { TurnRow $_ })))

# --- evaluation ------------------------------------------------------------------------------------------
# Each finding carries the tokens it covers, so the list sorts by what fixing it is worth.
$bad = [System.Collections.Generic.List[object]]::new()
$good = [System.Collections.Generic.List[string]]::new()

$bigCalls = @($calls | Where-Object { $_.Context -gt $over })
$bigTok = Sum $bigCalls Total
if ($grand -gt 0 -and $bigTok / $grand -ge 0.15) {
    $bad.Add(@{ Tok = $bigTok; Text = "**Long sessions.** $(Pct $bigTok $grand) of all tokens ($(Tok $bigTok)) went to $($bigCalls.Count) " +
        "calls carrying more than $(Tok $over) of context. Every one re-reads all of it. Fix: /compact or start a " +
        'fresh session when the status line says getting full, and hand off with a short note.' })
} else { $good.Add("Sessions stay small: only $(Pct $bigTok $grand) of tokens went to calls past $(Tok $over).") }

$heavy = @($main | Where-Object { $_.Calls.Count -ge 15 })
$heavyTok = Sum $heavy Total
if ($heavy) {
    $bad.Add(@{ Tok = $heavyTok; Text = "**Long turns.** $($heavy.Count) turns took 15 or more calls and used " +
        "$(Tok $heavyTok) ($(Pct $heavyTok $grand)). Median calls per turn: $(Median ($main | ForEach-Object { $_.Calls.Count })). " +
        'Fix: ask for one step at a time when you only need the first answer, and push long build or test loops ' +
        'into a script that runs once.' })
}

$wakeTok = Sum $wakes Total
if ($wakes) {
    $bad.Add(@{ Tok = $wakeTok; Text = "**Wake-ups.** $($wakes.Count) turns started from a notification or a peer " +
        "message and used $(Tok $wakeTok) ($(Pct $wakeTok $grand)), median $(Tok (Median ($wakes | ForEach-Object Total))) " +
        'each. A one-line relay still re-reads the whole session. Fix: have workers report once at the end, and ' +
        'run background tasks without waiting on them in-session.' })
}

$waitTok = Sum $waits WaitTotal
if ($grand -gt 0 -and $waitTok / $grand -ge 0.03) {
    $bad.Add(@{ Tok = $waitTok; Text = "**Polling.** $(Tok $waitTok) ($(Pct $waitTok $grand)) went to sleeps, " +
        'polls and reads of task output. Fix: run long jobs in the background and let the notification wake the session.' })
} else { $good.Add("Little polling: $(Pct $waitTok $grand) of tokens went to sleeps and polls.") }

$outTok = Sum $turns Out
$visTok = (Sum $turns Visible) / 4
if ($outTok -gt 0) {
    $hidden = [math]::Max(0, $outTok - $visTok)
    if ($hidden / $outTok -ge 0.5) {
        $bad.Add(@{ Tok = $hidden * 5; Text = "**Thinking.** About $(Pct $hidden $outTok) of output tokens " +
            "($(Tok $hidden)) were thinking you never see. That is why a short reply can show 700+ tokens. Output " +
            'costs about 5x input. Fix: lower /effort for routine turns, raise it for design work.' })
    }
}

$subOpus = @($turns | Where-Object { $_.IsSub -and $_.Model -like '*opus*' })
$subTok = Sum ($turns | Where-Object IsSub) Total
if ($subOpus -and $subTok -gt 0) {
    $t = Sum $subOpus Total
    $bad.Add(@{ Tok = $t / 2; Text = "**Opus workers.** $(Pct $t $subTok) of subagent tokens ($(Tok $t)) ran on Opus. " +
        'Fix: Sonnet for search, review and mechanical edits. Keep Opus for the orchestrator and hard design.' })
}

$terse = @($typed | Where-Object { ($_.Text -split '\s+').Count -le 4 })
if ($terse) {
    $t = Sum $terse Total
    $bad.Add(@{ Tok = $t; Text = "**Go-aheads.** $($terse.Count) of $($typed.Count) typed prompts were 4 words or " +
        "fewer and cost $(Tok $t) ($(Pct $t $grand)), mostly the context re-read every turn pays. Fix: put the " +
        'go-ahead in the same message as the next ask.' })
}

$cacheIn = Sum $calls Cr; $allIn = $cacheIn + (Sum $calls Cw) + (Sum $calls In)
if ($allIn -gt 0) {
    $hit = $cacheIn / $allIn
    if ($hit -ge 0.9) { $good.Add("Cache hit rate $(Pct $cacheIn $allIn): context is reused, not re-sent.") }
    else {
        $w = (Sum $calls Cw)
        $bad.Add(@{ Tok = $w; Text = "**Cache misses.** Only $(Pct $cacheIn $allIn) of input came from cache. Writes " +
            "were $(Tok $w). Long idle gaps (over 5 minutes) drop the cache. Fix: finish or /compact a session before a break." })
    }
}

$md.Add(''); $md.Add('## Evaluation'); $md.Add('')
$md.Add('### Costing the most, biggest first'); $md.Add('')
$md.Add('These overlap: a wake-up can also be a long turn in a long session, so the shares add to more than 100%.')
$md.Add('')
if ($bad.Count) { $bad | Sort-Object { $_.Tok } -Descending | ForEach-Object { $md.Add("- $($_.Text)") } }
else { $md.Add('- Nothing over the thresholds.') }
$md.Add(''); $md.Add('### Going well'); $md.Add('')
if ($good.Count) { $good | ForEach-Object { $md.Add("- $_") } } else { $md.Add('- Nothing stood out.') }

$text = $md -join "`n"
if ($OutFile) { Set-Content -Encoding utf8NoBOM $OutFile $text; "wrote $OutFile" } else { $text }
