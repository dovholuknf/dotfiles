# wt-themes.ps1 — live retheme Windows Terminal tabs via OSC escape sequences.
#
# usage (from $PROFILE):
#   . "$PSScriptRoot\wt-themes.ps1"
#
# then in any shell:
#   ActiveWork | PullRequests | Tangent | Worktrees   # apply a theme
#   Reset-Theme                                       # restore WT profile defaults
#   Set-Bg <#hex>                                     # quick bg-only override
#
# to eyeball a theme, paste this line (safe to run) — exercises every PSReadLine
# token type so you can spot anything illegible and tune the theme's psr block:
#
#   if ($true -and [int]42 -gt 10) { Get-ChildItem -Path '.' | Where-Object { $_.Length -gt 1024 -and $_.Name -eq "foo.txt" } } # sample comment
#
# token coverage: Keyword (if) · Variable ($true, $_) · Operator (-and, -gt, -eq, |)
#                 · Type ([int]) · Number (42, 10, 1024) · Command (Get-ChildItem,
#                 Where-Object) · Parameter (-Path) · String ('.', "foo.txt")
#                 · Member (.Length, .Name) · Comment (# sample comment)
#
# trickier tokens — these need a specific situation, not a one-liner:
#
#   Error               type an unterminated string: "hello      (red highlight while editing)
#   Selection           select text with Shift+arrows or mouse  (highlight bg)
#   ContinuationPrompt  paste an unclosed brace: if ($true) {   (>> prompt color)
#   InlinePrediction    re-type the start of a recent command    (dim ghost text)
#   ListPrediction*     requires: Set-PSReadLineOption -PredictionViewStyle ListView
#   Emphasis            shows in dynamic help / completions      (hard to force)
#   Default             plain fg text — just the theme's fg

function Set-Bg([string]$Hex) {
    [Console]::Write([char]27 + "]11;$Hex" + [char]7)
}

function _LerpHex([string]$a, [string]$b, [double]$r) {
    $a = $a.TrimStart('#'); $b = $b.TrimStart('#')
    $ar = [Convert]::ToInt32($a.Substring(0,2),16); $ag = [Convert]::ToInt32($a.Substring(2,2),16); $ab = [Convert]::ToInt32($a.Substring(4,2),16)
    $br = [Convert]::ToInt32($b.Substring(0,2),16); $bg = [Convert]::ToInt32($b.Substring(2,2),16); $bb = [Convert]::ToInt32($b.Substring(4,2),16)
    '#{0:X2}{1:X2}{2:X2}' -f `
        [int][Math]::Round($ar + ($br - $ar) * $r), `
        [int][Math]::Round($ag + ($bg - $ag) * $r), `
        [int][Math]::Round($ab + ($bb - $ab) * $r)
}

function Apply-Theme([hashtable]$t) {
    $e = [char]27; $b = [char]7

    # ANSI 0..15
    for ($i = 0; $i -lt 16; $i++) {
        if ($t.ansi[$i]) { [Console]::Write("$e]4;$i;$($t.ansi[$i])$b") }
    }

    # xterm grayscale ramp 232..255 — remap to a theme-tinted bg-to-fg gradient
    # so apps that render with 256-color greys (e.g. Claude Code's user-message
    # strip) pick up a harmonized shade instead of neutral grey.
    if ($t.bg -and $t.fg) {
        for ($i = 0; $i -lt 24; $i++) {
            $shade = _LerpHex $t.bg $t.fg ($i / 23.0)
            [Console]::Write("$e]4;$(232 + $i);$shade$b")
        }
    }

    if ($t.bg)     { [Console]::Write("$e]11;$($t.bg)$b") }
    if ($t.fg)     { [Console]::Write("$e]10;$($t.fg)$b") }
    if ($t.cursor) { [Console]::Write("$e]12;$($t.cursor)$b") }
    if ($t.sel_bg) { [Console]::Write("$e]17;$($t.sel_bg)$b") }
    if ($t.sel_fg) { [Console]::Write("$e]19;$($t.sel_fg)$b") }

    if ($t.psr -and (Get-Module -ListAvailable PSReadLine)) {
        Set-PSReadLineOption -Colors $t.psr
    }
    $global:WtLabel      = $t.label
    $global:CurrentTheme = $t
}

function Reset-Theme {
    $e = [char]27; $b = [char]7
    for ($i = 0; $i -lt 16; $i++)   { [Console]::Write("$e]104;$i$b") }
    for ($i = 232; $i -lt 256; $i++) { [Console]::Write("$e]104;$i$b") }
    [Console]::Write("$e]110$b")    # reset fg
    [Console]::Write("$e]111$b")    # reset bg
    [Console]::Write("$e]112$b")    # reset cursor
    [Console]::Write("$e]117$b")    # reset selection bg
    [Console]::Write("$e]119$b")    # reset selection fg
    $global:WtLabel      = $null
    $global:CurrentTheme = $null
}

# ── palettes ──────────────────────────────────────────────────────────────────
# bg choices are fixed; foreground + 16 ANSI slots tuned to read well on each bg.

$theme_worktrees = @{
    label  = 'worktrees'
    bg     = '#141414'
    fg     = '#e8e8e8'
    cursor = '#d0d0d0'
    sel_bg = '#404060'
    sel_fg = '#f8f8f8'
    ansi = @(
        '#1a1a1a',  # 0  black
        '#e05050',  # 1  red
        '#80c080',  # 2  green
        '#e0b070',  # 3  yellow
        '#7090d0',  # 4  blue
        '#c080c0',  # 5  magenta
        '#60c0c0',  # 6  cyan
        '#c8c8c8',  # 7  white
        '#505050',  # 8  br black
        '#ff7080',  # 9  br red
        '#a0e0a0',  # 10 br green
        '#f0c890',  # 11 br yellow
        '#90b0f0',  # 12 br blue
        '#e0a0e0',  # 13 br magenta
        '#90e0e0',  # 14 br cyan
        '#f8f8f8'   # 15 br white
    )
    psr = @{
        Parameter          = '#9ad0e0'
        Operator           = '#c0c0c0'
        Member             = '#d0d0e8'
        Comment            = '#808080'
        Number             = '#f0c890'
        ContinuationPrompt = '#a0a0a0'
        Error              = '#ff7080'
    }
}

$theme_active_work = @{
    label  = 'active-work'
    bg     = '#0f3d1a'
    fg     = '#e0f0e0'
    cursor = '#80ff90'
    sel_bg = '#2a6a38'
    sel_fg = '#f0f8e8'
    ansi = @(
        '#0a2010',  # 0
        '#e06868',  # 1 red — pops against green
        '#78d878',  # 2 green — brighter than bg
        '#e0c070',  # 3
        '#7098e0',  # 4
        '#d088c8',  # 5
        '#68d0c0',  # 6
        '#d0e0d0',  # 7
        '#6a906a',  # 8
        '#ff8888',  # 9
        '#a8f0a8',  # 10
        '#f0d890',  # 11
        '#98b8f0',  # 12
        '#e0a8d8',  # 13
        '#90f0e0',  # 14
        '#f0f8e8'   # 15
    )
    psr = @{
        Parameter          = '#f0d890'
        Operator           = '#d8e8d8'
        Member             = '#d0e8d8'
        Comment            = '#90a890'
        Number             = '#f0b890'
        ContinuationPrompt = '#8ac098'
        Error              = '#ff8090'
    }
}

$theme_pull_requests = @{
    label  = 'pull-requests'
    bg     = '#0a2a6a'
    fg     = '#e0e8f8'
    cursor = '#90b8ff'
    sel_bg = '#3a5098'
    sel_fg = '#f0f4f8'
    ansi = @(
        '#081a40',  # 0
        '#e07080',  # 1
        '#80d088',  # 2
        '#e0c070',  # 3
        '#80a8ff',  # 4 blue — clearly brighter than bg
        '#c080d0',  # 5
        '#70c8e0',  # 6
        '#c8d0e0',  # 7
        '#6888b8',  # 8
        '#ff8898',  # 9
        '#a0e0a8',  # 10
        '#f0d890',  # 11
        '#a0c0ff',  # 12
        '#e0a0e0',  # 13
        '#90e0f0',  # 14
        '#f0f4f8'   # 15
    )
    psr = @{
        Parameter          = '#f0b870'
        Operator           = '#d8e0f0'
        Member             = '#d0d8f0'
        Comment            = '#8898b8'
        Number             = '#f0c890'
        ContinuationPrompt = '#98b8d8'
        Error              = '#ff8090'
    }
}

$theme_tangent = @{
    label  = 'tangent'
    bg     = '#5a0f1a'
    fg     = '#f8e0e0'
    cursor = '#ff90a0'
    sel_bg = '#8a2a38'
    sel_fg = '#f8e8e8'
    ansi = @(
        '#300810',  # 0
        '#ff7888',  # 1 red — brighter than bg crimson
        '#a8c878',  # 2 green — olive-toned for warmth harmony
        '#e8b858',  # 3
        '#80a0e8',  # 4 blue — cool contrast accent
        '#e090c0',  # 5
        '#60c8c0',  # 6
        '#e8c8c8',  # 7
        '#b07880',  # 8
        '#ff98a8',  # 9
        '#c0e080',  # 10
        '#f8d080',  # 11
        '#a0b8ff',  # 12
        '#f0a0d0',  # 13
        '#80e0e0',  # 14
        '#f8e8e8'   # 15
    )
    psr = @{
        Parameter          = '#90e0c0'
        Operator           = '#f0d8d8'
        Member             = '#f8d8d8'
        Comment            = '#b89898'
        Number             = '#f8d080'
        ContinuationPrompt = '#e8b0b8'
        Error              = '#ffc070'
    }
}

# ── shortcut commands ─────────────────────────────────────────────────────────

function ActiveWork   { Apply-Theme $theme_active_work }
function PullRequests { Apply-Theme $theme_pull_requests }
function Tangent      { Apply-Theme $theme_tangent }
function Worktrees    { Apply-Theme $theme_worktrees }

# Emits the sample with ANSI truecolor SGR codes to mimic PSReadLine's highlighting
# against the current theme. Not the real edit buffer — just a faithful rendering.
function Show-ThemeSample {
    $t = $global:CurrentTheme
    if (-not $t) {
        Write-Host "apply a theme first (ActiveWork, PullRequests, Tangent, Worktrees)" -ForegroundColor Yellow
        return
    }

    # per-token color map. fall back to the theme's ANSI palette for tokens the
    # psr block doesn't override (matches PSReadLine's ConsoleColor defaults).
    $psr  = $t.psr
    $ansi = $t.ansi
    $col = @{
        Keyword            = if ($psr.Keyword)    { $psr.Keyword }    else { $ansi[10] }
        Command            = if ($psr.Command)    { $psr.Command }    else { $ansi[11] }
        String             = if ($psr.String)     { $psr.String }     else { $ansi[6]  }
        Variable           = if ($psr.Variable)   { $psr.Variable }   else { $ansi[10] }
        Type               = if ($psr.Type)       { $psr.Type }       else { $ansi[7]  }
        Parameter          = $psr.Parameter
        Operator           = $psr.Operator
        Member             = $psr.Member
        Comment            = $psr.Comment
        Number             = $psr.Number
        Error              = $psr.Error
        ContinuationPrompt = $psr.ContinuationPrompt
        Default            = $t.fg
    }

    function _Hex2Rgb([string]$h) {
        $h = $h.TrimStart('#')
        "$([Convert]::ToInt32($h.Substring(0,2),16));$([Convert]::ToInt32($h.Substring(2,2),16));$([Convert]::ToInt32($h.Substring(4,2),16))"
    }
    $ESC = [char]27
    function _W([string]$text, [string]$hex) {
        $rgb = _Hex2Rgb $hex
        Write-Host -NoNewline "$ESC[38;2;${rgb}m$text$ESC[0m"
    }

    Write-Host ""
    Write-Host "── theme preview (simulated PSReadLine highlighting) ──" -ForegroundColor DarkGray
    Write-Host ""

    _W 'if'               $col.Keyword
    _W ' ('               $col.Default
    _W '$true'            $col.Variable
    _W ' '                $col.Default
    _W '-and'             $col.Operator
    _W ' '                $col.Default
    _W '[int]'            $col.Type
    _W '42'               $col.Number
    _W ' '                $col.Default
    _W '-gt'              $col.Operator
    _W ' '                $col.Default
    _W '10'               $col.Number
    _W ') { '             $col.Default
    _W 'Get-ChildItem'    $col.Command
    _W ' '                $col.Default
    _W '-Path'            $col.Parameter
    _W ' '                $col.Default
    _W "'.'"              $col.String
    _W ' '                $col.Default
    _W '|'                $col.Operator
    _W ' '                $col.Default
    _W 'Where-Object'     $col.Command
    _W ' { '              $col.Default
    _W '$_'               $col.Variable
    _W '.Length'          $col.Member
    _W ' '                $col.Default
    _W '-gt'              $col.Operator
    _W ' '                $col.Default
    _W '1024'             $col.Number
    _W ' '                $col.Default
    _W '-and'             $col.Operator
    _W ' '                $col.Default
    _W '$_'               $col.Variable
    _W '.Name'            $col.Member
    _W ' '                $col.Default
    _W '-eq'              $col.Operator
    _W ' '                $col.Default
    _W '"foo.txt"'        $col.String
    _W ' } } '            $col.Default
    _W '# sample comment' $col.Comment
    Write-Host ""

    _W '>> '                                              $col.ContinuationPrompt
    _W '"unterminated string to trigger Error token'      $col.Error
    Write-Host ""
    Write-Host ""
    Write-Host "tokens not shown: Selection (select text), InlinePrediction (history ghost)," -ForegroundColor DarkGray
    Write-Host "                  ListPrediction* (PredictionViewStyle ListView), Emphasis." -ForegroundColor DarkGray
    Write-Host ""
}
