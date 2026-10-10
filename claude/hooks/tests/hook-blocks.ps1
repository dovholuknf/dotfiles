#Requires -Version 7
# hook-blocks.ps1: what the PreToolUse gate blocked, read back out of the claude-code transcripts.
#
# The hook keeps no log of its own. Every transcript does: a blocked call is a tool_use followed by a tool_result whose
# text starts 'PreToolUse:<Tool> hook error: <reason>'. This pairs the two and reports a count per rule, so a rule
# change in docs/gate-decisions.md can cite how often the rule fired and on what.
#
#   pwsh -File hook-blocks.ps1 [-Days 7] [-Sample <rule prefix>] [-N 25]
#
# Without -Sample it prints the histogram and writes every block to $env:TEMP\hook-blocks.csv. With -Sample it prints
# N random commands (fixed seed, so a rerun shows the same ones) whose reason starts with that prefix.
# atrium delivers peer messages and context warnings through the same hook-error channel. Those are left out.
param([int]$Days = 7, [string]$Sample, [int]$N = 25)

$csv = Join-Path $env:TEMP 'hook-blocks.csv'

if ($Sample) {
    $rows = @(Import-Csv $csv | Where-Object Rule -like "$Sample*")
    "== $Sample ($($rows.Count))"
    $rows | Get-Random -Count ([Math]::Min($N, $rows.Count)) -SetSeed 7 | ForEach-Object {
        $c = $_.Command
        if ($c.Length -gt 220) { $c = $c.Substring(0, 220) + ' ...' }
        "- $c"
    }
    return
}

$since = (Get-Date).AddDays(-$Days)
$rows = foreach ($f in Get-ChildItem "$env:USERPROFILE\.claude\projects" -Recurse -Filter *.jsonl |
        Where-Object LastWriteTime -gt $since) {
    $uses = @{}
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        if ($line -notmatch 'tool_use|hook error') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.timestamp -and [datetime]$o.timestamp -lt $since) { continue }
        foreach ($c in @($o.message.content)) {
            if ($c.type -eq 'tool_use') { $uses[$c.id] = "$($c.input.command)$($c.input.file_path)" }
            elseif ($c.type -eq 'tool_result' -and "$($c.content)" -match 'PreToolUse:\w+ hook error: (.*)') {
                $why = $Matches[1]
                if ($why -match '^(Message from|Messages sent through|\[atrium\])') { continue }
                $rule = $why -replace "['`].*", ''
                [pscustomobject]@{
                    Time    = $o.timestamp
                    Rule    = $rule.Substring(0, [Math]::Min(60, $rule.Length))
                    Command = "$($uses[$c.tool_use_id])" -replace '\s+', ' '
                    Session = $f.BaseName
                }
            }
        }
    }
}
$rows = @($rows | Sort-Object Time, Command -Unique)
"blocks in the last $Days days: $($rows.Count)"
$rows | Group-Object Rule | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
$rows | Export-Csv $csv -NoTypeInformation
"detail: $csv"
