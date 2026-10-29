<#
.SYNOPSIS
    Controlled test of what moves the usage meter: output tokens, cache reads, and cache writes, one at a time.
.DESCRIPTION
    Get-BurnFit.ps1 cannot separate the token classes from organic use: concurrent sessions share one meter, and
    the classes rise and fall together. This script spends a fixed budget on one class at a time, with a meter
    checkpoint between phases, so each delta has one cause.

      output  fresh sessions, tiny prompt, long answer. Almost all cost is output.
      read    one session loaded with a large context once (a setup call, mostly a cache write), then many
              resumed calls with a one-word answer. Almost all cost is cache reads.
      write   fresh sessions, each with a new large prompt that starts with a unique nonce. Almost all cost is
              cache writes.

    Every call is `claude -p --safe-mode --tools ""` with a short fixed system prompt, so no CLAUDE.md, hooks, MCP
    servers or tools add context. Prompts go in on stdin. Each phase stops when its summed total_cost_usd reaches
    -PhaseBudgetUsd, or at -MaxCalls.

    At each checkpoint the script shows the newest sample in ~/.claude/usage-log.jsonl and asks for the 5h and 7d
    percents from the status line. The log only moves when an interactive session renders, so read the live
    status line, not the default. The meter is account-wide: idle every other session first, and watch 5h hold
    for 10 minutes before starting.

    Output goes to claude/usage/build.claude/burn-<stamp>/: calls.jsonl (one line per call: phase, usage, cost),
    meter.jsonl (the checkpoints), summary.md, and the claude stderr. The default budgets spend about $45 at API
    list prices, which was 5 to 10% of the weekly meter when this was written.
.EXAMPLE
    ./Invoke-BurnTest.ps1 -DryRun                       # build the prompts, print the plan, call nothing
.EXAMPLE
    ./Invoke-BurnTest.ps1                               # all three phases, asks before spending
.EXAMPLE
    ./Invoke-BurnTest.ps1 -Phase read -PhaseBudgetUsd 8 -ReadContextTokens 300000
#>
[CmdletBinding()]
param(
    [ValidateSet('output', 'read', 'write')]
    [string[]]$Phase = @('output', 'read', 'write'),
    [string]$Model = 'claude-opus-5-5',
    [double]$PhaseBudgetUsd = 15,
    [int]$MaxCalls = 60,
    [int]$OutputTokens = 24000,
    [int]$ReadContextTokens = 150000,
    [int]$WriteContextTokens = 100000,
    [string]$OutDir,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\UsageCommon.ps1"

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "build.claude\burn-$stamp" }
$OutDir = (New-Item -ItemType Directory -Force $OutDir).FullName
$callsLog = Join-Path $OutDir 'calls.jsonl'
$meterLog = Join-Path $OutDir 'meter.jsonl'
$errLog = Join-Path $OutDir 'claude-stderr.txt'
$systemPrompt = 'You are a test fixture. Follow the instruction at the end of the user message exactly.'

# Filler text of roughly $Tokens tokens (4 chars each), seeded so a run is repeatable and two seeds never share a
# prefix. The nonce goes first so no cached prefix from an earlier call can match.
$vocab = -split ('amber basalt cobalt delta ember fjord granite harbor indigo juniper kelp lantern meadow nickel ' +
    'orchard pewter quartz russet saffron timber umber velvet willow xenon yarrow zephyr anvil bramble cinder dune')
function New-Filler([int]$Tokens, [int]$Seed) {
    $rng = [Random]::new($Seed)
    $sb = [Text.StringBuilder]::new($Tokens * 4 + 64)
    [void]$sb.AppendLine("nonce $([guid]::NewGuid())")
    $line = 0
    while ($sb.Length -lt $Tokens * 4) {
        $line++
        [void]$sb.Append(('{0:D6} ' -f $line))
        for ($i = 0; $i -lt 12; $i++) { [void]$sb.Append($vocab[$rng.Next($vocab.Count)]).Append(' ') }
        [void]$sb.AppendLine($rng.Next(100000, 999999))
    }
    $sb.ToString()
}

$prompts = @{
    output = "Write the integers from 1 upward, one per line, digits only, with no other text. Stop after " +
        "$([math]::Floor($OutputTokens / 2)) lines."
    readSetup = (New-Filler $ReadContextTokens 1) + "`nThe text above is reference data. Reply with the single word ok."
    read = 'Reply with the single word ok.'
}

function Invoke-Claude([string]$Prompt, [string]$Mode, [string]$SessionId) {
    $a = @('-p', '--model', $Model, '--output-format', 'json', '--safe-mode', '--tools', '',
        '--system-prompt', $systemPrompt)
    if ($Mode -eq 'new') { $a += @('--session-id', $SessionId) }
    if ($Mode -eq 'resume') { $a += @('--resume', $SessionId) }
    $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = [math]::Max(32000, $OutputTokens + 4000)
    Push-Location $OutDir
    try { $raw = $Prompt | & claude @a 2>>$errLog } finally { Pop-Location }
    try { $r = ($raw -join "`n") | ConvertFrom-Json } catch { throw "claude returned non-JSON, see $errLog`n$raw" }
    if ($r.is_error) { throw "claude reported an error: $($r.result)" }
    $r
}

function Write-Call([string]$Name, [int]$N, $R) {
    $u = $R.usage
    $rec = [ordered]@{
        ts = (Get-Date).ToString('o'); phase = $Name; n = $N; session = $R.session_id
        input = $u.input_tokens; cache_write = $u.cache_creation_input_tokens
        cache_read = $u.cache_read_input_tokens; output = $u.output_tokens; cost_usd = $R.total_cost_usd
    }
    $rec | ConvertTo-Json -Compress | Add-Content $callsLog
    Write-Host ('  {0,-10} #{1,-3} in {2,7} cw {3,8} cr {4,9} out {5,7}  ${6:N3}' -f $Name, $N, $rec.input,
        $rec.cache_write, $rec.cache_read, $rec.output, $rec.cost_usd)
    [pscustomobject]$rec
}

function Read-Meter([string]$Label) {
    $last = $null
    if (Test-Path $script:UsageLogPath) {
        $last = Get-Content $script:UsageLogPath -Tail 200 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
            Where-Object { $_.five_hour_pct -ne $null } | Sort-Object ts | Select-Object -Last 1
    }
    $d5 = $d7 = ''
    if ($last) {
        $age = [math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$last.ts) / 60, 1)
        $d5 = "$($last.five_hour_pct)"; $d7 = "$($last.seven_day_pct)"
        Write-Host "  newest log sample: 5h $d5, 7d $d7, $age min old"
    }
    Write-Host "Checkpoint '$Label': read both percents off a live status line."
    $p5 = Read-Host "  5h % [$d5]"; if (-not $p5) { $p5 = $d5 }
    $p7 = Read-Host "  7d % [$d7]"; if (-not $p7) { $p7 = $d7 }
    $rec = [ordered]@{ ts = (Get-Date).ToString('o'); label = $Label; five_hour_pct = [double]$p5; seven_day_pct = [double]$p7 }
    $rec | ConvertTo-Json -Compress | Add-Content $meterLog
    [pscustomobject]$rec
}

# --- plan -------------------------------------------------------------------------------------------------
Write-Host "Burn test, model $Model, phases $($Phase -join ', '), `$$PhaseBudgetUsd per phase, max $MaxCalls calls each"
Write-Host ("  output: ~{0:N0} output tokens per call" -f $OutputTokens)
Write-Host ("  read:   setup ~{0:N0} tokens ({1:N0} chars), then 1-word calls" -f ($prompts.readSetup.Length / 4),
    $prompts.readSetup.Length)
Write-Host ("  write:  ~{0:N0} new tokens per call" -f $WriteContextTokens)
Write-Host "  out dir: $OutDir"
if ($DryRun) {
    $prompts.output | Set-Content (Join-Path $OutDir 'prompt-output.txt')
    $prompts.readSetup | Set-Content (Join-Path $OutDir 'prompt-read-setup.txt')
    New-Filler $WriteContextTokens 1001 | Set-Content (Join-Path $OutDir 'prompt-write-1.txt')
    Write-Host 'Dry run: prompts written to the out dir, nothing sent.'
    return
}
if ((Read-Host "Spend up to `$$($PhaseBudgetUsd * $Phase.Count) API-equivalent on the meter? y/N") -ne 'y') { return }

# --- phases -----------------------------------------------------------------------------------------------
$meter = @(Read-Meter 'start')
$calls = @()

function Invoke-Phase([string]$Name, [scriptblock]$Call) {
    $spent = 0.0; $n = 0; $out = @()
    while ($spent -lt $PhaseBudgetUsd -and $n -lt $MaxCalls) {
        $n++
        $c = Write-Call $Name $n (& $Call $n)
        $spent += [double]$c.cost_usd; $out += $c
    }
    Write-Host ('  {0}: {1} calls, ${2:N2}' -f $Name, $n, $spent)
    $out
}

foreach ($p in $Phase) {
    switch ($p) {
        'output' {
            $calls += Invoke-Phase 'output' { param($n) Invoke-Claude $prompts.output 'new' ([guid]::NewGuid()) }
            $meter += Read-Meter 'after output'
        }
        'read' {
            $sid = [guid]::NewGuid().ToString()
            $calls += Write-Call 'readsetup' 1 (Invoke-Claude $prompts.readSetup 'new' $sid)
            $meter += Read-Meter 'after read setup'
            $calls += Invoke-Phase 'read' { param($n) Invoke-Claude $prompts.read 'resume' $sid }
            $meter += Read-Meter 'after read'
        }
        'write' {
            $calls += Invoke-Phase 'write' {
                param($n)
                Invoke-Claude ((New-Filler $WriteContextTokens (1000 + $n)) + "`nReply with the single word ok.") 'new' ([guid]::NewGuid())
            }
            $meter += Read-Meter 'after write'
        }
    }
}

# --- summary ----------------------------------------------------------------------------------------------
$md = @("# Burn test $stamp", '', "Model $Model. Meter deltas are whole percents, so read a 1-point move as 0 to 2.", '',
    '| segment | calls | input | cache write | cache read | output | cost $ | 5h delta | 7d delta | $ per 5h pt |',
    '|---|---|---|---|---|---|---|---|---|---|')
$segPhase = @{ 'after output' = 'output'; 'after read setup' = 'readsetup'; 'after read' = 'read'; 'after write' = 'write' }
for ($i = 1; $i -lt $meter.Count; $i++) {
    $seg = @($calls | Where-Object phase -eq $segPhase[$meter[$i].label])
    $sum = { param($f) ($seg | Measure-Object $f -Sum).Sum }
    $cost = & $sum 'cost_usd'
    $d5 = $meter[$i].five_hour_pct - $meter[$i - 1].five_hour_pct
    $d7 = $meter[$i].seven_day_pct - $meter[$i - 1].seven_day_pct
    $per = if ($d5 -gt 0) { '{0:N2}' -f ($cost / $d5) } else { '-' }
    $md += '| {0} | {1} | {2:N0} | {3:N0} | {4:N0} | {5:N0} | {6:N2} | {7} | {8} | {9} |' -f $segPhase[$meter[$i].label],
        $seg.Count, (& $sum 'input'), (& $sum 'cache_write'), (& $sum 'cache_read'), (& $sum 'output'), $cost, $d5, $d7, $per
}
$md | Set-Content (Join-Path $OutDir 'summary.md')
$md | Write-Output
