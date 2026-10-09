<#
.SYNOPSIS
    Which hooks block what, how often, and whether the block stopped anything.
.DESCRIPTION
    Reads ~/.claude/projects/**/*.jsonl and finds every tool call a PreToolUse hook refused, every call the user
    or a permission gate denied, and every tool call overall. Prints a markdown report: block rate per tool, a row
    per hook rule, blocks per week, and the denials.

    The rule is the hook's reason text, with numbers and paths folded so one rule is one row. atrium uses the same
    hook channel to deliver messages and context warnings mid-call, so those are counted apart as notices, not
    rules.

    "Next call ok" is how often the next call to the same tool in the same session succeeded. A rule that blocks
    and then loses to a workaround one call later costs time and stops little. A low number means the agent gave
    up or the block held. Read it as a hint, not a verdict: the next call may be unrelated. Nothing leaves the
    machine.
.EXAMPLE
    ./Get-HookReport.ps1                          # last 30 days
.EXAMPLE
    ./Get-HookReport.ps1 -Days 7 -Project '*openziti*' -OutFile hooks.md
.EXAMPLE
    ./Get-HookReport.ps1 -Json | ConvertFrom-Json  # one row per refused or denied call
#>
[CmdletBinding()]
param(
    [int]$Days = 30,
    [datetime]$From,
    [datetime]$To,
    [int]$Top = 25,
    [string]$Project = '*',
    [string]$OutFile,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\UsageCommon.ps1"

if (-not $To) { $To = Get-Date }
if (-not $From) { $From = $To.AddDays(-$Days) }
$fromUtc = $From.ToUniversalTime()
$toUtc = $To.ToUniversalTime()

function Pct([double]$part, [double]$whole) { if ($whole -gt 0) { '{0:N0}%' -f (100 * $part / $whole) } else { '-' } }
function Short([string]$s, [int]$n = 70) {
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { $s.Substring(0, $n - 1) + '…' } else { $s }
}
function MdTable([object[]]$Rows) {
    if (-not $Rows) { return '_(none)_' }
    $cols = $Rows[0].Keys
    $out = @(('| ' + ($cols -join ' | ') + ' |'), ('|' + (($cols | ForEach-Object { '---' }) -join '|') + '|'))
    foreach ($r in $Rows) {
        $out += '| ' + (($cols | ForEach-Object { "$($r[$_])" -replace '\|', '/' -replace '`', "'" }) -join ' | ') + ' |'
    }
    $out -join "`n"
}

# One rule, one row: the first sentence of the reason, with paths, numbers and quoted names folded.
function RuleKey([string]$reason) {
    $r = ($reason -replace '\s+', ' ').Trim()
    $r = ($r -split '(?<=[.!?])\s', 2)[0]
    $r = $r -replace '[A-Za-z]:\\[^\s''"]*', '<path>' -replace '(?<![\w/])/[\w.-]+(?:/[\w.-]+)+', '<path>'
    $r = $r -replace "'git [^']*' is not a git command", "'git <word>' is not a git command"
    $r = $r -replace "'[^']*' is not one", "'<name>' is not one"
    $r = $r -replace '\d+', 'N'
    Short $r 90
}

function ResultText($c) {
    if ($c.content -is [string]) { return $c.content }
    (@($c.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object text) -join ' '
}

# --- load ------------------------------------------------------------------------------------------------
$root = Join-Path $script:ClaudeHome 'projects'
$files = Get-ChildItem $root -Recurse -Filter *.jsonl -File | Where-Object LastWriteTime -ge $From

$events = [System.Collections.Generic.List[object]]::new()   # one per tool result, in file order
foreach ($f in $files) {
    $proj = ($f.FullName.Substring($root.Length + 1) -split '[\\/]')[0]
    if ($proj -notlike $Project) { continue }
    $uses = @{}
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        # Cheap text filters first: most lines are neither a tool call nor a tool result.
        $isUse = $line.Contains('"tool_use"')
        $isResult = $line.Contains('"tool_result"')
        if (-not ($isUse -or $isResult)) { continue }
        try { $o = $line | ConvertFrom-Json -Depth 40 } catch { continue }
        if (-not $o.timestamp) { continue }
        $ts = ([datetime]$o.timestamp).ToUniversalTime()
        if ($ts -lt $fromUtc -or $ts -gt $toUtc) { continue }
        foreach ($c in @($o.message.content)) {
            if ($c.type -eq 'tool_use') {
                $in = $c.input
                $what = if ($in.command) { $in.command } elseif ($in.file_path) { $in.file_path }
                        elseif ($in.prompt) { $in.prompt } else { '' }
                $uses[$c.id] = @{ Tool = $c.name; What = "$what" }
            } elseif ($c.type -eq 'tool_result') {
                $u = $uses[$c.tool_use_id]
                $tool = if ($u) { $u.Tool } else { '?' }
                $text = if ($c.is_error) { ResultText $c } else { '' }
                $kind = 'ok'
                if ($c.is_error) {
                    $kind = 'error'
                    if ($text -match '^PreToolUse:\S+ hook error: (?s)(.*)$') {
                        $reason = $Matches[1]
                        $kind = if ($reason -match 'Message from another session|^\[atrium\]|sent through atrium') {
                            'notice' } else { 'block' }
                    } elseif ($text -match "doesn't want to proceed|user rejected|denied by the user") {
                        $kind = 'user-deny'
                    } elseif ($text -match 'Permission to use .* (has been|was) denied|permission .*denied') {
                        $kind = 'gate-deny'
                    }
                }
                $events.Add([pscustomobject]@{
                    Time = $ts; Project = $proj; Session = $f.BaseName; Tool = $tool; Kind = $kind
                    Rule = if ($kind -eq 'block') { RuleKey $reason } else { '' }
                    What = if ($u) { $u.What } else { '' }; Text = $text; NextOk = $null })
            }
        }
    }
}

# Next call to the same tool in the same session: did it succeed?
$bySession = $events | Group-Object Session
foreach ($g in $bySession) {
    $list = @($g.Group)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        if ($e.Kind -notin 'block', 'user-deny', 'gate-deny') { continue }
        for ($j = $i + 1; $j -lt $list.Count; $j++) {
            if ($list[$j].Tool -ne $e.Tool -or $list[$j].Kind -eq 'notice') { continue }
            $e.NextOk = ($list[$j].Kind -eq 'ok')
            break
        }
    }
}

$refused = @($events | Where-Object Kind -in 'block', 'user-deny', 'gate-deny')
if ($Json) {
    $refused | ForEach-Object {
        [ordered]@{ time = $_.Time.ToString('s'); project = $_.Project; session = $_.Session; tool = $_.Tool
            kind = $_.Kind; rule = $_.Rule; next_ok = $_.NextOk; what = $_.What; text = $_.Text }
    } | ConvertTo-Json -Depth 3
    return
}

# --- report ----------------------------------------------------------------------------------------------
$blocks = @($events | Where-Object Kind -eq 'block')
$notices = @($events | Where-Object Kind -eq 'notice')
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# Hooks and denials, $($From.ToString('yyyy-MM-dd')) to $($To.ToString('yyyy-MM-dd'))")
$md.Add('')
$md.Add("$($events.Count) tool calls in $(@($bySession).Count) sessions. $($blocks.Count) blocked by a hook rule,")
$md.Add("$(@($events | Where-Object Kind -eq 'user-deny').Count) denied by the user, " +
    "$(@($events | Where-Object Kind -eq 'gate-deny').Count) denied by a permission gate, " +
    "and $($notices.Count) interrupted by an atrium notice (not a rule).")

$md.Add('')
$md.Add('## Per tool')
$md.Add('')
$rows = $events | Group-Object Tool | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
    $b = @($_.Group | Where-Object Kind -eq 'block').Count
    [ordered]@{ Tool = $_.Name; Calls = $_.Count; Blocked = $b; 'Block rate' = Pct $b $_.Count
        Denied = @($_.Group | Where-Object Kind -in 'user-deny', 'gate-deny').Count
        Notices = @($_.Group | Where-Object Kind -eq 'notice').Count }
}
$md.Add((MdTable @($rows)))

$md.Add('')
$md.Add('## Per rule')
$md.Add('')
$md.Add('Most blocks first. "Next call ok" is how often the next call to the same tool succeeded.')
$md.Add('')
$rows = $blocks | Group-Object Rule | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
    $grp = @($_.Group)
    $known = @($grp | Where-Object { $null -ne $_.NextOk })
    $last = ($grp | Sort-Object Time | Select-Object -Last 1)
    [ordered]@{ Rule = $_.Name; Blocks = $grp.Count
        Sessions = @($grp | Select-Object -ExpandProperty Session -Unique).Count
        Projects = @($grp | Select-Object -ExpandProperty Project -Unique).Count
        'Next call ok' = Pct @($known | Where-Object NextOk).Count $known.Count
        'Last seen' = $last.Time.ToLocalTime().ToString('MM-dd'); 'Last command' = Short $last.What 60 }
}
$md.Add((MdTable @($rows)))

$md.Add('')
$md.Add('## Per week')
$md.Add('')
$weekOf = { param($t) $d = $t.ToLocalTime().Date; $d.AddDays(-(([int]$d.DayOfWeek + 6) % 7)).ToString('yyyy-MM-dd') }
$rows = $events | Group-Object { & $weekOf $_.Time } | Sort-Object Name | ForEach-Object {
    $b = @($_.Group | Where-Object Kind -eq 'block').Count
    [ordered]@{ Week = $_.Name; Calls = $_.Count; Blocked = $b; 'Block rate' = Pct $b $_.Count
        Denied = @($_.Group | Where-Object Kind -in 'user-deny', 'gate-deny').Count }
}
$md.Add((MdTable @($rows)))

$md.Add('')
$md.Add('## Denials')
$md.Add('')
$rows = $refused | Where-Object Kind -ne 'block' | Sort-Object Time -Descending | Select-Object -First $Top |
    ForEach-Object {
        [ordered]@{ When = $_.Time.ToLocalTime().ToString('MM-dd HH:mm'); Kind = $_.Kind; Tool = $_.Tool
            Project = Short $_.Project 30; Command = Short $_.What 70 }
    }
$md.Add((MdTable @($rows)))

$text = $md -join "`n"
if ($OutFile) { Set-Content -Path $OutFile -Value $text -Encoding utf8 } else { $text }
