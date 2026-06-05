# wt-themes.ps1 -- live retheme Windows Terminal tabs via OSC escape sequences.
#
# usage (from $PROFILE):
#   . "$PSScriptRoot\wt-themes.ps1"
#
# then in any shell:
#   ActiveWork | PullRequests | Tangent | Worktrees   # apply a theme
#   Reset-Theme                                       # restore WT profile defaults
#   Set-Bg <#hex>                                     # quick bg-only override
#   Show-ThemeSample                                  # preview current theme
#
# to eyeball a theme, paste this line (safe to run) -- exercises every PSReadLine
# token type so you can spot anything illegible and tune the theme's psr block:
#
#   if ($true -and [int]42 -gt 10) { Get-ChildItem -Path '.' | Where-Object { $_.Length -gt 1024 -and $_.Name -eq "foo.txt" } } # sample comment
#
# token coverage: Keyword (if) · Variable ($true, $_) · Operator (-and, -gt, -eq, |)
#                 · Type ([int]) · Number (42, 10, 1024) · Command (Get-ChildItem,
#                 Where-Object) · Parameter (-Path) · String ('.', "foo.txt")
#                 · Member (.Length, .Name) · Comment (# sample comment)
#
# trickier tokens -- these need a specific situation, not a one-liner:
#
#   Error               type an unterminated string: "hello      (red highlight while editing)
#   Selection           select text with Shift+arrows or mouse  (highlight bg)
#   ContinuationPrompt  paste an unclosed brace: if ($true) {   (>> prompt color)
#   InlinePrediction    re-type the start of a recent command    (dim ghost text)
#   ListPrediction*     requires: Set-PSReadLineOption -PredictionViewStyle ListView
#   Emphasis            shows in dynamic help / completions      (hard to force)
#   Default             plain fg text -- just the theme's fg

$script:OriginalPSReadLineColors = $null

function script:_IsHex([string]$Hex) {
    $Hex -match '^#[0-9a-fA-F]{6}$'
}

function script:_WriteOsc([int]$Code, [string]$Value) {
    [Console]::Write([char]27 + "]$Code;$Value" + [char]7)
}

function script:_ResetOsc([int]$Code, [int]$Index = -1) {
    if ($Index -ge 0) {
        [Console]::Write([char]27 + "]$Code;$Index" + [char]7)
    } else {
        [Console]::Write([char]27 + "]$Code" + [char]7)
    }
}

function Set-Bg([string]$Hex) {
    if (-not (_IsHex $Hex)) { throw "invalid hex color: $Hex" }
    _WriteOsc 11 $Hex
}

function _LerpHex([string]$a, [string]$b, [double]$r) {
    if (-not (_IsHex $a)) { throw "invalid hex color: $a" }
    if (-not (_IsHex $b)) { throw "invalid hex color: $b" }

    $a = $a.TrimStart('#'); $b = $b.TrimStart('#')
    $ar = [Convert]::ToInt32($a.Substring(0,2),16); $ag = [Convert]::ToInt32($a.Substring(2,2),16); $ab = [Convert]::ToInt32($a.Substring(4,2),16)
    $br = [Convert]::ToInt32($b.Substring(0,2),16); $bg = [Convert]::ToInt32($b.Substring(2,2),16); $bb = [Convert]::ToInt32($b.Substring(4,2),16)
    '#{0:X2}{1:X2}{2:X2}' -f `
        [int][Math]::Round($ar + ($br - $ar) * $r), `
        [int][Math]::Round($ag + ($bg - $ag) * $r), `
        [int][Math]::Round($ab + ($bb - $ab) * $r)
}

function script:_Luminance([string]$Hex) {
    if (-not (_IsHex $Hex)) { return 0.5 }
    $h = $Hex.TrimStart('#')
    $r = [Convert]::ToInt32($h.Substring(0,2),16) / 255.0
    $g = [Convert]::ToInt32($h.Substring(2,2),16) / 255.0
    $b = [Convert]::ToInt32($h.Substring(4,2),16) / 255.0
    # perceived luminance (Rec. 601)
    return 0.299 * $r + 0.587 * $g + 0.114 * $b
}

function script:_AdjustHex([string]$Hex, [double]$Amount) {
    # Amount > 0 = lighten (blend toward white). Amount < 0 = darken (toward black).
    if (-not (_IsHex $Hex)) { return $Hex }
    $h = $Hex.TrimStart('#')
    $r = [Convert]::ToInt32($h.Substring(0,2),16)
    $g = [Convert]::ToInt32($h.Substring(2,2),16)
    $b = [Convert]::ToInt32($h.Substring(4,2),16)
    if ($Amount -ge 0) {
        $r = [int][Math]::Round($r + (255 - $r) * $Amount)
        $g = [int][Math]::Round($g + (255 - $g) * $Amount)
        $b = [int][Math]::Round($b + (255 - $b) * $Amount)
    } else {
        $a = [Math]::Abs($Amount)
        $r = [int][Math]::Round($r * (1 - $a))
        $g = [int][Math]::Round($g * (1 - $a))
        $b = [int][Math]::Round($b * (1 - $a))
    }
    '#{0:X2}{1:X2}{2:X2}' -f $r, $g, $b
}

function script:_BlendToLum([string]$Hex, [double]$TargetLum) {
    # Blend $Hex toward white (luminance 1) or black (luminance 0) until its
    # luminance hits $TargetLum. Lets us derive predictable br-black / br-white
    # values regardless of how extreme the source color is.
    if (-not (_IsHex $Hex)) { return $Hex }
    $cur = _Luminance $Hex
    if ([Math]::Abs($cur - $TargetLum) -lt 0.005) { return $Hex }
    if ($TargetLum -gt $cur) {
        # blend toward white: cur + (1 - cur) * t = target  =>  t = (tgt - cur) / (1 - cur)
        $t = ($TargetLum - $cur) / (1.0 - $cur)
        return _AdjustHex $Hex $t
    } else {
        # blend toward black: cur * (1 - t) = target  =>  t = 1 - tgt/cur
        $t = 1.0 - ($TargetLum / $cur)
        return _AdjustHex $Hex (-$t)
    }
}

function script:_NormalizeTheme([hashtable]$t) {
    # Auto-fill optional slots when absent so minimal themes (just bg + fg + ansi)
    # still produce a complete, readable palette. Target luminances chosen so the
    # derived shades read consistently regardless of how extreme bg/fg are.
    if (-not $t.ansi -or $t.ansi.Count -ne 16) { return }
    $bgLum  = if ($t.bg) { _Luminance $t.bg } else { 0.0 }
    $isDark = $bgLum -lt 0.5

    # ansi[8] (br-black / DarkGray) -- "dim" relative to fg, but clearly readable
    # against bg. On dark themes that's a mid-gray (clearly lighter than bg);
    # on light themes that's a dark gray (clearly darker than bg).
    if (-not $t.ansi[8]  -and $t.bg) {
        $target = if ($isDark) { 0.55 } else { 0.30 }
        $t.ansi[8]  = _BlendToLum $t.bg $target
    }
    # ansi[15] (br-white) -- "extra emphasis" anchor. Symmetric to ansi[8]:
    # on dark themes lighten fg, on light themes darken fg. Keeps the theme's
    # hue (no pure-white wash) and stays distinct from bg.
    if (-not $t.ansi[15] -and $t.fg) {
        $delta = if ($isDark) { 0.15 } else { -0.15 }
        $t.ansi[15] = _AdjustHex $t.fg $delta
    }

    # sel_bg -- visibly different from bg but not jarring. Aim for a luminance
    # offset of ~+0.18 on dark themes, -0.18 on light themes.
    if (-not $t.sel_bg -and $t.bg) {
        $target = if ($isDark) { [Math]::Min(1.0, $bgLum + 0.18) } else { [Math]::Max(0.0, $bgLum - 0.18) }
        $t.sel_bg = _BlendToLum $t.bg $target
    }
    # sel_fg -- selection text. If missing, just use fg.
    if (-not $t.sel_fg -and $t.fg) {
        $t.sel_fg = $t.fg
    }
}

function script:_ValidateTheme([hashtable]$t) {
    if (-not $t) { throw "theme is null" }
    if (-not $t.ansi -or $t.ansi.Count -ne 16) { throw "theme '$($t.label)' must define exactly 16 ANSI colors" }

    foreach ($k in @('bg', 'fg', 'cursor', 'sel_bg', 'sel_fg')) {
        if ($t.$k -and -not (_IsHex $t.$k)) { throw "theme '$($t.label)' has invalid ${k}: $($t.$k)" }
    }

    for ($i = 0; $i -lt 16; $i++) {
        if ($t.ansi[$i] -and -not (_IsHex $t.ansi[$i])) {
            throw "theme '$($t.label)' has invalid ansi[$i]: $($t.ansi[$i])"
        }
    }

    if ($t.psr) {
        foreach ($k in $t.psr.Keys) {
            if ($t.psr[$k] -and -not (_IsHex $t.psr[$k])) {
                throw "theme '$($t.label)' has invalid psr.${k}: $($t.psr[$k])"
            }
        }
    }
}

function Set-Theme {
    # Apply a theme.
    #   Set-Theme                  -- no args, interactive arrow-key / digit picker
    #   Set-Theme tangent          -- by name (substring / prefix tolerant)
    #   Set-Theme 6                -- by 1-based index into the sorted list
    #   Set-Theme -Tour            -- walk through every theme, Enter between each
    #   Set-Theme @{ ... }         -- by inline hashtable (custom test theme)
    #   $myTheme | Set-Theme       -- pipeline
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Position=0, ParameterSetName='ByName')]
        [string]$Name,

        [Parameter(Position=0, ParameterSetName='ByObject', ValueFromPipeline=$true)]
        [hashtable]$Theme,

        # Walk every theme. Forwards to Tour-Themes (which has more knobs than
        # this switch exposes -- see Tour-Themes -? for -Mode / -Filter /
        # -RestoreOnExit).
        [Parameter(ParameterSetName='ByName')]
        [switch]$Tour
    )
    process {
        if ($Tour) {
            Tour-Themes
            return
        }
        if ($PSCmdlet.ParameterSetName -eq 'ByObject' -and $Theme) {
            Apply-Theme $Theme
            return
        }

        # If $Name parses as an integer, treat it as a 1-based index into the
        # sorted theme list. Lets the user repeat the picker shortcut on the
        # command line: 'Set-Theme 6' picks the 6th theme.
        $sortedThemes = @($script:WtThemes.Keys | Sort-Object)
        $asInt = 0
        if ($Name -and [int]::TryParse($Name, [ref]$asInt)) {
            if ($asInt -ge 1 -and $asInt -le $sortedThemes.Count) {
                $Name = $sortedThemes[$asInt - 1]
            } else {
                Write-Host "theme index '$asInt' out of range (1..$($sortedThemes.Count))" -ForegroundColor Red
                return
            }
        }

        # No name passed -- show arrow-key picker. Falls back to a typed name
        # if _TuiSelect isn't available (no profile / common-tools.ps1 not
        # dot-sourced).
        if (-not $Name) {
            $sorted = @($script:WtThemes.Keys | Sort-Object)
            if (Get-Command _TuiSelect -ErrorAction SilentlyContinue) {
                $picked = _TuiSelect -Items $sorted -Prompt 'choose theme (Up/Down + Enter, Esc/q to cancel):'
                if (-not $picked) {
                    Write-Host "no selection" -ForegroundColor Yellow
                    return
                }
                $Name = $picked
            } else {
                Write-Host ""
                Write-Host "choose theme (type the name; _TuiSelect not loaded):" -ForegroundColor DarkGray
                foreach ($k in $sorted) { Write-Host "  $k" -ForegroundColor Cyan }
                Write-Host ""
                $Name = (Read-Host "theme name").Trim()
                if (-not $Name) { Write-Host "no selection" -ForegroundColor Yellow; return }
            }
        }

        if (-not $script:WtThemes.ContainsKey($Name)) {
            $needle = $Name.ToLower()
            # First try: exact prefix match. Then substring. Single match wins.
            $matchesV = @($sortedThemes | Where-Object { $_.ToLower().StartsWith($needle) })
            if ($matchesV.Count -eq 0) {
                $matchesV = @($sortedThemes | Where-Object { $_.ToLower().Contains($needle) })
            }
            if ($matchesV.Count -eq 1) {
                $hit = $matchesV[0]
                $resp = (Read-Host "unknown theme '$Name' -- did you mean '$hit'? [Y/n]").Trim()
                if (-not $resp -or $resp -match '^[Yy]') {
                    $Name = $hit
                } else {
                    Write-Host "cancelled" -ForegroundColor Yellow
                    return
                }
            } elseif ($matchesV.Count -gt 1) {
                Write-Host "unknown theme: '$Name'. multiple candidates:" -ForegroundColor Red
                foreach ($k in $matchesV) { Write-Host "  - $k" -ForegroundColor Yellow }
                Write-Host "be more specific or run 'Set-Theme' with no args for the picker." -ForegroundColor DarkGray
                return
            } else {
                Write-Host "available themes:" -ForegroundColor DarkGray
                foreach ($k in $sortedThemes) { Write-Host "  - $k" -ForegroundColor DarkGray }
                Write-Host "unknown theme: '$Name' -- no near match" -ForegroundColor Red
                return
            }
        }
        $script:_PendingThemeName = $Name
        Apply-Theme $script:WtThemes[$Name]
    }
}

function Apply-Theme([hashtable]$t) {
    _NormalizeTheme $t
    _ValidateTheme $t

    if (-not $script:OriginalPSReadLineColors -and (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
        $colors = (Get-PSReadLineOption).Colors
        if ($colors) {
            $script:OriginalPSReadLineColors = $colors.Clone()
        }
    }

    # ANSI 0..15
    for ($i = 0; $i -lt 16; $i++) {
        if ($t.ansi[$i]) { _WriteOsc 4 "$i;$($t.ansi[$i])" }
    }

    # xterm grayscale ramp 232..255 -- remap to a theme-tinted bg-to-fg gradient
    # so apps that render with 256-color greys (e.g. Claude Code's user-message
    # strip) pick up a harmonized shade instead of neutral grey.
    if ($t.bg -and $t.fg) {
        for ($i = 0; $i -lt 24; $i++) {
            $shade = _LerpHex $t.bg $t.fg ($i / 23.0)
            _WriteOsc 4 "$(232 + $i);$shade"
        }
    }

    if ($t.bg)     { _WriteOsc 11 $t.bg }
    if ($t.fg)     { _WriteOsc 10 $t.fg }
    if ($t.cursor) { _WriteOsc 12 $t.cursor }
    if ($t.sel_bg) { _WriteOsc 17 $t.sel_bg }
    if ($t.sel_fg) { _WriteOsc 19 $t.sel_fg }

    if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
        # Force a clean baseline before applying the theme's overrides. This
        # uses ANSI codes (e.g. `e[93m) which reference the palette we just set
        # via OSC 4, so Member/Number/etc. that the theme doesn't override fall
        # back to the *new* theme's palette colors -- not the previous theme's.
        $esc = [char]27
        $defaults = @{
            Command            = "$esc[93m"        # BrightYellow (ansi[11])
            Comment            = "$esc[32m"        # Green       (ansi[2])
            ContinuationPrompt = "$esc[37m"        # White       (ansi[7])
            Default            = "$esc[37m"        # White       (ansi[7])
            Emphasis           = "$esc[96m"        # BrightCyan  (ansi[14])
            Error              = "$esc[91m"        # BrightRed   (ansi[9])
            InlinePrediction   = "$esc[90m"        # DarkGray    (ansi[8])
            Keyword            = "$esc[92m"        # BrightGreen (ansi[10])
            ListPrediction     = "$esc[33m"        # Yellow      (ansi[3])
            Member             = "$esc[97m"        # BrightWhite (ansi[15])
            Number             = "$esc[97m"        # BrightWhite (ansi[15])
            Operator           = "$esc[90m"        # DarkGray    (ansi[8])
            Parameter          = "$esc[90m"        # DarkGray    (ansi[8])
            String             = "$esc[36m"        # Cyan        (ansi[6])
            Type               = "$esc[37m"        # White       (ansi[7])
            Variable           = "$esc[92m"        # BrightGreen (ansi[10])
        }
        Set-PSReadLineOption -Colors $defaults
        # Now layer the theme's specific overrides on top.
        if ($t.psr) { Set-PSReadLineOption -Colors $t.psr }
    }

    $global:WtLabel      = $t.label
    $global:CurrentTheme = $t
    if ($script:_PendingThemeName) {
        $global:WtThemeName = $script:_PendingThemeName
        $script:_PendingThemeName = $null
    }
}

function Get-Theme {
    [CmdletBinding()] param([switch]$Quiet)
    if (-not $global:CurrentTheme) {
        if (-not $Quiet) { Write-Host "no theme applied (try Set-Theme <name> or Show-Theme)" -ForegroundColor DarkGray }
        return $null
    }
    $name = if ($global:WtThemeName) { $global:WtThemeName } else { '<unknown>' }
    if (-not $Quiet) {
        Write-Host ("theme: {0}" -f $name) -ForegroundColor Cyan
        if ($global:WtLabel) { Write-Host ("label: {0}" -f $global:WtLabel) -ForegroundColor DarkGray }
    }
    return $name
}

function Reset-Theme {
    for ($i = 0; $i -lt 16; $i++)    { _ResetOsc 104 $i }
    for ($i = 232; $i -lt 256; $i++) { _ResetOsc 104 $i }

    _ResetOsc 110    # reset fg
    _ResetOsc 111    # reset bg
    _ResetOsc 112    # reset cursor
    _ResetOsc 117    # reset selection bg
    _ResetOsc 119    # reset selection fg

    if ($script:OriginalPSReadLineColors -and (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
        Set-PSReadLineOption -Colors $script:OriginalPSReadLineColors
    }

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
        '#e06868',  # 1 red -- pops against green
        '#78d878',  # 2 green -- brighter than bg
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
        '#80a8ff',  # 4 blue -- clearly brighter than bg
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
        '#ff7888',  # 1 red -- brighter than bg crimson
        '#a8c878',  # 2 green -- olive-toned for warmth harmony
        '#e8b858',  # 3
        '#80a0e8',  # 4 blue -- cool contrast accent
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

function ActiveWork   { $script:_PendingThemeName = 'active-work';   Apply-Theme $theme_active_work }
function PullRequests { $script:_PendingThemeName = 'pull-requests'; Apply-Theme $theme_pull_requests }
function Tangent      { $script:_PendingThemeName = 'tangent';       Apply-Theme $theme_tangent }
function Worktrees    { $script:_PendingThemeName = 'worktrees';     Apply-Theme $theme_worktrees }

# Registry for Set-Theme '<name>' lookups.
# Bonus themes -- registered for `Set-Theme '<name>'` lookup but no convenience
# function. Use Set-Theme 'solarized-dark' (etc) to apply.

$theme_solarized_dark = @{
    label='solarized-dark'; bg='#002b36'; fg='#93a1a1'; cursor='#93a1a1'
    sel_bg='#073642'; sel_fg='#eee8d5'
    ansi=@('#073642','#dc322f','#859900','#b58900','#268bd2','#d33682','#2aa198','#eee8d5',
           $null,    '#cb4b16','#586e75','#657b83','#839496','#6c71c4','#93a1a1',$null)
}

$theme_gruvbox_dark = @{
    label='gruvbox-dark'; bg='#282828'; fg='#ebdbb2'; cursor='#fe8019'
    sel_bg='#504945'; sel_fg='#ebdbb2'
    ansi=@('#1d2021','#cc241d','#98971a','#d79921','#458588','#b16286','#689d6a','#a89984',
           $null,    '#fb4934','#b8bb26','#fabd2f','#83a598','#d3869b','#8ec07c',$null)
}

$theme_nord = @{
    label='nord'; bg='#2e3440'; fg='#d8dee9'; cursor='#88c0d0'
    sel_bg='#434c5e'; sel_fg='#eceff4'
    ansi=@('#3b4252','#bf616a','#a3be8c','#ebcb8b','#81a1c1','#b48ead','#88c0d0','#e5e9f0',
           $null,    '#bf616a','#a3be8c','#ebcb8b','#81a1c1','#b48ead','#8fbcbb',$null)
}

$theme_forest_night = @{
    label='forest-night'; bg='#0a1f12'; fg='#d4e3d4'; cursor='#7fb069'
    sel_bg='#1f3a26'; sel_fg='#e8f0e0'
    ansi=@('#0a1610','#c46b6b','#7fb069','#d4a373','#5b8a72','#a3779e','#76a89c','#c8d4c0',
           $null,    '#e08585','#9bcc83','#e8c087','#7aa890','#bf95b8','#94c4b8',$null)
}

$theme_synthwave = @{
    label='synthwave'; bg='#241b2f'; fg='#ffffff'; cursor='#ff7edb'
    sel_bg='#3d2c4e'; sel_fg='#ffffff'
    ansi=@('#1a1027','#fe4450','#72f1b8','#fede5d','#36f9f6','#ff7edb','#03edf9','#ffffff',
           $null,    '#ff5874','#94f3c5','#fff35c','#52f6f4','#ff8eda','#41e9f5',$null)
}

$theme_dracula = @{
    label='dracula'; bg='#282a36'; fg='#f8f8f2'; cursor='#f8f8f2'
    sel_bg='#44475a'; sel_fg='#f8f8f2'
    ansi=@('#21222c','#ff5555','#50fa7b','#f1fa8c','#bd93f9','#ff79c6','#8be9fd','#f8f8f2',
           $null,    '#ff6e6e','#69ff94','#ffffa5','#d6acff','#ff92df','#a4ffff',$null)
}

$theme_monokai = @{
    label='monokai'; bg='#272822'; fg='#f8f8f2'; cursor='#f92672'
    sel_bg='#49483e'; sel_fg='#f8f8f2'
    ansi=@('#272822','#f92672','#a6e22e','#f4bf75','#66d9ef','#ae81ff','#a1efe4','#f8f8f2',
           $null,    '#f92672','#a6e22e','#f4bf75','#66d9ef','#ae81ff','#a1efe4',$null)
}

# ---- danger / admin themes (warm amber/orange backgrounds, "you're in elevated mode") ----
$theme_admin_danger = @{
    # Deep burnt-orange bg; primary "DANGER, you are root" theme.
    label='admin-danger'; bg='#3a1b08'; fg='#ffe8c4'; cursor='#ff9933'
    sel_bg='#6b3514'; sel_fg='#fff4d6'
    ansi=@('#2a1206','#ff5c3c','#d4c46a','#ffaa33','#88b6c2','#d18df0','#7bd6c4','#ffe8c4',
           $null,    '#ff8866','#e6dd80','#ffcc55','#a5d0dd','#e5b0ff','#a8f0e0',$null)
}

$theme_admin_caution = @{
    # Mustard/amber bg, less aggressive than admin-danger. "elevated but you've been here a while."
    label='admin-caution'; bg='#3d2e0f'; fg='#fff4d0'; cursor='#ffcc00'
    sel_bg='#705618'; sel_fg='#fffae0'
    ansi=@('#2a1f08','#ff6b6b','#cad669','#ffaa00','#7fa9c8','#d29be8','#7ed4c2','#fff4d0',
           $null,    '#ff8a8a','#dde888','#ffcc44','#9cc5dc','#e0b5f0','#a3f0e0',$null)
}

# ---- more orange-leaning themes (less aggressive than admin-* but same warm family) ----
$theme_pumpkin = @{
    # Vivid pumpkin-orange bg; saturated but not "danger". Good general-purpose warm theme.
    label='pumpkin'; bg='#4a1f08'; fg='#ffe2b8'; cursor='#ff8c1a'
    sel_bg='#7a3812'; sel_fg='#fff1d6'
    ansi=@('#321204','#ff5a3a','#c8c768','#ff9933','#7fb2c4','#d68fe8','#7ad1bb','#ffe2b8',
           $null,    '#ff8866','#dde088','#ffb15a','#a3cedc','#e6b3ee','#a6e8d6',$null)
}

$theme_terracotta = @{
    # Earthy red-orange/clay bg; warmer-leaning-red. Less yellow than pumpkin.
    label='terracotta'; bg='#3b1e15'; fg='#f0d8c4'; cursor='#e07845'
    sel_bg='#5f3225'; sel_fg='#ffe8d4'
    ansi=@('#28140d','#e8516a','#b9c270','#e07845','#8fa9bd','#cf8fc4','#7ec4b3','#f0d8c4',
           $null,    '#ff7589','#c8cf85','#f08e62','#a8c0d2','#dca6cf','#9bd2c0',$null)
}

# ---- ocean / cool themes ----
$theme_ocean_deep = @{
    # Saturated deep-blue, somewhere between solarized-dark and nord.
    label='ocean-deep'; bg='#0d2440'; fg='#cfe1f5'; cursor='#5cc4ff'
    sel_bg='#1e3a5f'; sel_fg='#eaf3ff'
    ansi=@('#091a30','#ff6b7a','#8ad48a','#ffd166','#5cc4ff','#c890ff','#5fd1c1','#cfe1f5',
           $null,    '#ff8b95','#a4dfa4','#ffe188','#7fd4ff','#dbb0ff','#82e0d3',$null)
}

$theme_teal_dusk = @{
    # Slate-teal bg, cool and quiet.
    label='teal-dusk'; bg='#102e35'; fg='#d9eaea'; cursor='#5fd7b8'
    sel_bg='#1f4a55'; sel_fg='#ecf6f6'
    ansi=@('#0a1f24','#ff6e6e','#5fd7b8','#e6c466','#6fb5d6','#c694e8','#7fc6c0','#d9eaea',
           $null,    '#ff8e8e','#86e3c8','#f0d488','#8fc8e3','#d6abef','#9bd4cf',$null)
}

# ---- warm / earthy themes ----
$theme_rosewood = @{
    # Deep wine bg, warm.
    label='rosewood'; bg='#2c1216'; fg='#f0d8d8'; cursor='#ff8d8d'
    sel_bg='#4b1f25'; sel_fg='#ffe6e6'
    ansi=@('#1a0a0c','#ff5a6e','#a8c285','#e8b66e','#7fa3c2','#c790c8','#7dbfb5','#f0d8d8',
           $null,    '#ff7a8d','#bbd09a','#f0c987','#9cb9d2','#d8a9d8','#9ed3c9',$null)
}

$theme_cocoa = @{
    # Soft brown bg. Cozy, low-contrast.
    label='cocoa'; bg='#2b1e16'; fg='#e8d8c4'; cursor='#d8a373'
    sel_bg='#46322a'; sel_fg='#f5e9d6'
    ansi=@('#1f150f','#cf5560','#9bbf63','#d8a373','#6c92ab','#b986b5','#76b8a8','#e8d8c4',
           $null,    '#e87580','#b2d480','#e6b88a','#8baac0','#d09acb','#92cdbd',$null)
}

# ---- high-energy / experimental ----
$theme_neon_grape = @{
    # Deep purple bg, vivid neon foreground.
    label='neon-grape'; bg='#1a0d2e'; fg='#f3e8ff'; cursor='#c084fc'
    sel_bg='#2e1655'; sel_fg='#faf5ff'
    ansi=@('#100620','#ff4d8d','#a3e635','#fbbf24','#60a5fa','#c084fc','#22d3ee','#f3e8ff',
           $null,    '#ff6ba1','#bef264','#fcd34d','#7eb5fc','#d4a9ff','#5ee6f5',$null)
}

$theme_matrix = @{
    # Near-black bg, green-on-black "I'm in the mainframe" vibe.
    label='matrix'; bg='#020a02'; fg='#a4ffa4'; cursor='#00ff66'
    sel_bg='#0c280c'; sel_fg='#e8ffe8'
    ansi=@('#031003','#ff5c5c','#00cc44','#cccc44','#5dbbd6','#a05fb0','#3fbfaa','#a4ffa4',
           $null,    '#ff8080','#33ff66','#e8e858','#88d4e6','#c089d2','#65d8c3',$null)
}

$script:WtThemes = @{
    # gwt-window themes (each also has a convenience function: ActiveWork, etc.)
    'worktrees'      = $theme_worktrees
    'active-work'    = $theme_active_work
    'pull-requests'  = $theme_pull_requests
    'tangent'        = $theme_tangent
    # bonus themes -- Set-Theme '<name>' only, no shortcut function.
    'solarized-dark' = $theme_solarized_dark
    'gruvbox-dark'   = $theme_gruvbox_dark
    'nord'           = $theme_nord
    'forest-night'   = $theme_forest_night
    'synthwave'      = $theme_synthwave
    'dracula'        = $theme_dracula
    'monokai'        = $theme_monokai
    # admin / danger -- warm orange/amber backgrounds for elevated sessions
    'admin-danger'   = $theme_admin_danger
    'admin-caution'  = $theme_admin_caution
    # additional orange-family backgrounds (less aggressive than admin-*)
    'pumpkin'        = $theme_pumpkin
    'terracotta'     = $theme_terracotta
    # cool / oceanic
    'ocean-deep'     = $theme_ocean_deep
    'teal-dusk'      = $theme_teal_dusk
    # warm / earthy
    'rosewood'       = $theme_rosewood
    'cocoa'          = $theme_cocoa
    # high-energy
    'neon-grape'     = $theme_neon_grape
    'matrix'         = $theme_matrix
}

Set-Alias aw    ActiveWork
Set-Alias pr    PullRequests
Set-Alias tan   Tangent
Set-Alias wtree Worktrees

# Emits the sample with ANSI truecolor SGR codes to mimic PSReadLine's highlighting
# against the current theme. Not the real edit buffer -- just a faithful rendering.
function Show-ThemePalette {
    # Comprehensive preview of the active theme. Prints every slot with a sample
    # and its hex value, plus notes about what real-world things they drive.
    $t = $global:CurrentTheme
    if (-not $t) {
        Write-Host "apply a theme first (ActiveWork, PullRequests, Tangent, Worktrees, or Set-Theme ...)" -ForegroundColor Yellow
        return
    }

    $ESC = [char]27

    function _Sgr {
        param([string]$Text, [string]$FgHex, [string]$BgHex)
        if (-not $FgHex -and -not $BgHex) { return $Text }
        $out = ''
        if ($FgHex) {
            $h = $FgHex.TrimStart('#')
            $r = [Convert]::ToInt32($h.Substring(0,2),16)
            $g = [Convert]::ToInt32($h.Substring(2,2),16)
            $b = [Convert]::ToInt32($h.Substring(4,2),16)
            $out += "$ESC[38;2;$r;$g;${b}m"
        }
        if ($BgHex) {
            $h = $BgHex.TrimStart('#')
            $r = [Convert]::ToInt32($h.Substring(0,2),16)
            $g = [Convert]::ToInt32($h.Substring(2,2),16)
            $b = [Convert]::ToInt32($h.Substring(4,2),16)
            $out += "$ESC[48;2;$r;$g;${b}m"
        }
        return "$out$Text$ESC[0m"
    }

    function _Row {
        # Hex   = the slot's actual hex value (printed in the hex column)
        # FgFor = color to render the 'sample text' as (defaults to Hex)
        # BgFor = bg color behind 'sample text' (defaults to none)
        param([string]$Label, [string]$Hex, [string]$Notes = '', [string]$BgFor = $null, [string]$FgFor = $null)
        $sample      = '  sample text  '
        $sampleFg    = if ($FgFor) { $FgFor } else { $Hex }
        $colored     = if ($BgFor) { _Sgr $sample $sampleFg $BgFor } else { _Sgr $sample $sampleFg }
        $displayHex  = if ($Hex)   { $Hex }   else { '(unset)' }
        Write-Host ("  {0,-22} {1}  {2,-9}  {3}" -f $Label, $colored, $displayHex, $Notes)
    }

    Write-Host ""
    Write-Host "──────────  $($t.label)  ──────────" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "FRAME (terminal-level)" -ForegroundColor DarkGray
    # bg row: hex column is bg, but sample renders fg-on-bg (so the swatch
    # is visible -- otherwise bg-text-on-bg-window is invisible).
    _Row 'bg'      $t.bg     'window background'  $t.bg  $t.fg
    _Row 'fg'      $t.fg     'default fg -- drives prompt text color (e.g. ''PS>'')'
    _Row 'cursor'  $t.cursor 'caret color'
    # sel_bg/sel_fg: WT doesn't honor OSC 17/19 -- shown as theme intent, but the
    # ACTUAL selection rendering uses your wt profile's selectionBackground.
    _Row 'sel_bg'  $t.sel_bg 'selection bg (intent only -- WT uses settings.json selectionBackground)'  $t.sel_bg  $t.fg
    _Row 'sel_fg'  $t.sel_fg 'selection fg (intent only)'  $t.sel_bg
    Write-Host ""

    Write-Host "ANSI 0-15 (used by tools that emit ANSI: ls colors, git, conhost colors, etc)" -ForegroundColor DarkGray
    $ansiLabels = @(
        'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
        'br-black', 'br-red', 'br-green', 'br-yellow', 'br-blue', 'br-magenta', 'br-cyan', 'br-white'
    )
    for ($i = 0; $i -lt 16; $i++) {
        $hex   = $t.ansi[$i]
        $label = '{0,2}: {1}' -f $i, $ansiLabels[$i]
        $note  = switch ($i) {
            0  { '(default bg in some apps)' }
            7  { '(default fg in some apps; ConsoleColor.Gray)' }
            8  { '(ConsoleColor.DarkGray -- many "dim" hints in PS)' }
            15 { '(ConsoleColor.White -- typical PS host fg)' }
            default { '' }
        }
        _Row $label $hex $note
    }
    Write-Host ""

    if ($t.psr) {
        Write-Host "PSReadLine tokens (live in the edit buffer as you type)" -ForegroundColor DarkGray
        foreach ($k in @('Default','Command','Comment','Keyword','String','Operator','Variable','Number','Type','Member','Parameter','Selection','Error','ContinuationPrompt','InlinePrediction','Emphasis')) {
            if ($t.psr.ContainsKey($k)) {
                _Row $k $t.psr[$k]
            }
        }
        Write-Host ""
    }

    Write-Host "LIVE EXAMPLES (these are real PSReadLine tokens, on the active theme)" -ForegroundColor DarkGray
    Write-Host "  paste this and look at the colors as you type:" -ForegroundColor DarkGray
    Write-Host '    if ($true -and [int]42 -gt 10) { Get-ChildItem -Path ''.'' | Where-Object { $_.Length -gt 1024 } } # comment' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "TIP: 'PS>' uses the terminal's default fg (the 'fg' row above)." -ForegroundColor DarkGray
    Write-Host "     Bump it brighter if the prompt feels dim." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Show-Theme -Demo    realistic ls/git/cmdline output" -ForegroundColor DarkGray
    Write-Host "  Show-Theme -Sample  PSReadLine token coloring on a sample line" -ForegroundColor DarkGray
    Write-Host "  Show-Theme -All     all three with pauses between" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-ThemeDemo {
    # Realistic day-to-day output simulated against the active theme. Shows what
    # you'd actually see: ls/git/find output with file types coloured, errors,
    # warnings, headers, paths, symlinks, hostname-style accents, command help.
    $t = $global:CurrentTheme
    if (-not $t) {
        Write-Host "apply a theme first (ActiveWork, PullRequests, Tangent, Worktrees, or Set-Theme ...)" -ForegroundColor Yellow
        return
    }

    $ESC  = [char]27
    $ansi = $t.ansi
    function _C {
        param([string]$Text, [string]$Hex)
        if (-not $Hex) { return $Text }
        $h = $Hex.TrimStart('#')
        $r = [Convert]::ToInt32($h.Substring(0,2),16)
        $g = [Convert]::ToInt32($h.Substring(2,2),16)
        $b = [Convert]::ToInt32($h.Substring(4,2),16)
        return "$ESC[38;2;$r;$g;${b}m$Text$ESC[0m"
    }

    # short references to common slots
    $dir       = $ansi[12]   # br-blue   directories
    $sym       = $ansi[14]   # br-cyan   symlinks
    $exe       = $ansi[10]   # br-green  executables
    $arch      = $ansi[1]    # red       archives
    $err       = if ($t.psr.Error) { $t.psr.Error } else { $ansi[9] }
    $warn      = $ansi[11]   # br-yellow warnings
    $ok        = $ansi[10]   # br-green  success
    $hint      = $ansi[8]    # br-black  hints
    $header    = $ansi[15]   # br-white  headers
    $accent    = if ($t.psr.Parameter) { $t.psr.Parameter } else { $ansi[6] }
    $stringClr = if ($t.psr.String)    { $t.psr.String }    else { $ansi[6]  }
    $cmdClr    = if ($t.psr.Command)   { $t.psr.Command }   else { $ansi[11] }
    $kwClr     = if ($t.psr.Keyword)   { $t.psr.Keyword }   else { $ansi[10] }
    $varClr    = if ($t.psr.Variable)  { $t.psr.Variable }  else { $ansi[10] }
    $numClr    = if ($t.psr.Number)    { $t.psr.Number }    else { $ansi[11] }

    Write-Host ""
    Write-Host (_C "──────────  $($t.label) demo  ──────────" $header)
    Write-Host ""

    # ls output
    Write-Host (_C "$ ls -la" $hint)
    Write-Host ("drwxr-xr-x  3 clint   480 May  1 09:14 " + (_C ".git/" $dir))
    Write-Host ("drwxr-xr-x  4 clint   320 Apr 28 17:02 " + (_C "src/" $dir))
    Write-Host ("lrwxrwxrwx  1 clint    19 May  6 11:30 " + (_C "current" $sym) + " -> " + (_C "../latest/build" $sym))
    Write-Host ("-rwxr-xr-x  1 clint  4096 May  4 14:11 " + (_C "build.sh" $exe))
    Write-Host ("-rw-r--r--  1 clint   220 Apr 27 16:48 " + ".gitignore")
    Write-Host ("-rw-r--r--  1 clint  2161 Mar 31 11:25 README.md")
    Write-Host ("-rw-r--r--  1 clint   12k Mar 11 10:15 " + (_C "release-2.10.0.tar.gz" $arch))
    Write-Host ""

    # git status
    Write-Host (_C "$ git status" $hint)
    Write-Host ("On branch " + (_C "feature/multi-tun" $cmdClr))
    Write-Host ("Your branch is " + (_C "ahead of 'origin/main' by 3 commits." $ok))
    Write-Host ""
    Write-Host "Changes not staged for commit:"
    Write-Host (_C "        modified:   src/main.go" $err)
    Write-Host (_C "        modified:   README.md" $err)
    Write-Host ""
    Write-Host "Untracked files:"
    Write-Host (_C "        notes/scratch.md" $err)
    Write-Host ""

    # cmdline with flags
    Write-Host (_C "$ " $hint) -NoNewline
    Write-Host (_C "Get-ChildItem" $cmdClr) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "-Path" $accent) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "'D:\worktrees'" $stringClr) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "-Recurse" $accent) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "-Filter" $accent) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "'*.ps1'" $stringClr) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "|" $accent) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "Where-Object" $cmdClr) -NoNewline
    Write-Host " { " -NoNewline
    Write-Host (_C '$_.Length' $varClr) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "-gt" $accent) -NoNewline
    Write-Host " " -NoNewline
    Write-Host (_C "1024" $numClr) -NoNewline
    Write-Host " }"
    Write-Host ""

    # status lines
    Write-Host ((_C "ok      " $ok)     + "  build succeeded in 12.4s")
    Write-Host ((_C "warn    " $warn)   + "  3 deprecated APIs in module")
    Write-Host ((_C "error   " $err)    + "  cannot find file 'config.yml'")
    Write-Host ((_C "info    " $accent) + "  using cache from 2026-05-06")
    Write-Host ((_C "hint    " $hint)   + "  press Ctrl+C to abort")
    Write-Host ""

    # paths
    Write-Host (_C "$ pwd" $hint)
    Write-Host (_C "D:\worktrees\github\openziti\desktop-edge-win\multi-tun-switcher" $dir)
    Write-Host ""

    # selection demo
    if ($t.sel_bg) {
        $h = $t.sel_bg.TrimStart('#')
        $sr = [Convert]::ToInt32($h.Substring(0,2),16)
        $sg = [Convert]::ToInt32($h.Substring(2,2),16)
        $sb = [Convert]::ToInt32($h.Substring(4,2),16)
        $selPrefix = "$ESC[48;2;$sr;$sg;${sb}m"
        if ($t.sel_fg) {
            $h2 = $t.sel_fg.TrimStart('#')
            $fr = [Convert]::ToInt32($h2.Substring(0,2),16)
            $fg = [Convert]::ToInt32($h2.Substring(2,2),16)
            $fb = [Convert]::ToInt32($h2.Substring(4,2),16)
            $selPrefix = "$ESC[38;2;$fr;$fg;${fb}m$selPrefix"
        }
        Write-Host (_C "selection " $hint) -NoNewline
        Write-Host "${selPrefix}highlighted text$ESC[0m" -NoNewline
        Write-Host (_C "  (sel_bg + sel_fg)" $hint)
        Write-Host ""
    }

    Write-Host (_C "Show-Theme -Palette " $hint) -NoNewline
    Write-Host "full slot legend with hex values"
    Write-Host (_C "Show-Theme -Sample  " $hint) -NoNewline
    Write-Host "PSReadLine token coloring on a sample line"
    Write-Host (_C "Show-Theme -All     " $hint) -NoNewline
    Write-Host "all three with pauses between"
    Write-Host ""
}

function Tour-Themes {
    # Apply every theme in $script:WtThemes in turn, show a quick demo, wait for
    # input between each. -Palette / -Sample to swap the preview mode. -Filter
    # narrows to matching names. -RestoreOnExit puts the original theme back.
    param(
        [ValidateSet('Demo','Palette','Sample','All')] [string]$Mode = 'Demo',
        [string]$Filter,
        [switch]$RestoreOnExit
    )
    $original = $global:WtThemeName
    $names = @($script:WtThemes.Keys | Sort-Object)
    if ($Filter) { $names = @($names | Where-Object { $_ -like "*$Filter*" }) }
    if (-not $names.Count) { Write-Host "no themes match '$Filter'" -ForegroundColor Yellow; return }

    Write-Host ""
    Write-Host "Tour-Themes: $($names.Count) theme(s). Enter=next, q=quit." -ForegroundColor DarkGray
    Write-Host ""

    for ($i = 0; $i -lt $names.Count; $i++) {
        $n = $names[$i]
        Write-Host ""
        Write-Host ("===== [{0}/{1}] {2} =====" -f ($i+1), $names.Count, $n) -ForegroundColor Cyan
        Set-Theme $n
        switch ($Mode) {
            'Demo'    { Show-Theme -Demo }
            'Palette' { Show-Theme -Palette }
            'Sample'  { Show-Theme -Sample }
            'All'     { Show-Theme -All }
        }
        if ($i -lt ($names.Count - 1)) {
            $r = Read-Host "Enter for next, q to quit"
            if ($r -ieq 'q') { break }
        }
    }

    if ($RestoreOnExit -and $original) {
        Set-Theme $original
        Write-Host ""
        Write-Host "restored: $original" -ForegroundColor DarkGray
    }
}

function Show-Theme {
    # Unified front door for the preview functions.
    #   Show-Theme -Demo            ls/git/cmdline output
    #   Show-Theme -Palette         slot legend with hex values
    #   Show-Theme -Sample          PSReadLine token coloring
    #   Show-Theme -All             all three with pauses between
    param(
        [switch]$Demo,
        [switch]$Palette,
        [switch]$Sample,
        [switch]$All
    )
    if ($All) { $Demo = $true; $Palette = $true; $Sample = $true }
    if (-not ($Demo -or $Palette -or $Sample)) {
        Write-Host "usage: Show-Theme [-Demo] [-Palette] [-Sample] [-All]" -ForegroundColor Yellow
        Write-Host "  -Demo     realistic ls/git/cmdline output" -ForegroundColor DarkGray
        Write-Host "  -Palette  full slot legend with hex values" -ForegroundColor DarkGray
        Write-Host "  -Sample   PSReadLine token coloring on a sample line" -ForegroundColor DarkGray
        Write-Host "  -All      run all three with pauses between" -ForegroundColor DarkGray
        return
    }
    $sections = @()
    if ($Demo)    { $sections += 'Demo' }
    if ($Palette) { $sections += 'Palette' }
    if ($Sample)  { $sections += 'Sample' }
    for ($i = 0; $i -lt $sections.Count; $i++) {
        switch ($sections[$i]) {
            'Demo'    { Show-ThemeDemo }
            'Palette' { Show-ThemePalette }
            'Sample'  { Show-ThemeSample }
        }
        if ($i -lt $sections.Count - 1) {
            $null = Read-Host "(press Enter for next section)"
        }
    }
}

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
        if (-not (_IsHex $h)) { throw "invalid hex color: $h" }
        $h = $h.TrimStart('#')
        "$([Convert]::ToInt32($h.Substring(0,2),16));$([Convert]::ToInt32($h.Substring(2,2),16));$([Convert]::ToInt32($h.Substring(4,2),16))"
    }
    $ESC = [char]27
    function _W([string]$text, [string]$hex) {
        # When a theme doesn't define a particular color (e.g. a custom theme
        # missing a psr.Comment), render the text uncolored instead of throwing.
        if (-not $hex) { Write-Host -NoNewline $text; return }
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

    _W '>> '                                             $col.ContinuationPrompt
    _W '"unterminated string to trigger Error token'     $col.Error
    Write-Host ""
    Write-Host ""
    Write-Host "tokens not shown: Selection (select text), InlinePrediction (history ghost)," -ForegroundColor DarkGray
    Write-Host "                  ListPrediction* (PredictionViewStyle ListView), Emphasis." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Show-Theme -Demo    realistic ls/git/cmdline output" -ForegroundColor DarkGray
    Write-Host "  Show-Theme -Palette full slot legend with hex values" -ForegroundColor DarkGray
    Write-Host "  Show-Theme -All     all three with pauses between" -ForegroundColor DarkGray
    Write-Host ""
}