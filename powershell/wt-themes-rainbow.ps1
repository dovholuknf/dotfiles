# wt-themes-rainbow.ps1 -- extra dark-background themes, grouped by hue family.
# Dot-source this AFTER wt-themes.ps1 so $script:WtThemes already exists.
#
#   . "$PSScriptRoot\wt-themes-rainbow.ps1"
#
# All themes follow the same shape as wt-themes.ps1. ansi[8] and ansi[15] are
# left $null so _NormalizeTheme auto-derives br-black and br-white.

# ── dark red ──────────────────────────────────────────────────────────────────

$theme_blood_moon = @{
    label='blood-moon'; bg='#1c0606'; fg='#f8d8d0'; cursor='#ff5060'
    sel_bg='#380e0e'; sel_fg='#ffe8e0'
    ansi=@('#110303','#ff4444','#7abf72','#e8b860','#7098d0','#c878c0','#72c0b8','#f8d8d0',
           $null,    '#ff7070','#94d48c','#f0cc80','#8ab0e0','#da98d8','#90d4cc',$null)
}

$theme_crimson_cave = @{
    label='crimson-cave'; bg='#260a0a'; fg='#f5d5d0'; cursor='#e85050'
    sel_bg='#441414'; sel_fg='#ffe4dc'
    ansi=@('#180606','#e84040','#78bc70','#e8b460','#6890c8','#c070b8','#70bbb0','#f5d5d0',
           $null,    '#f07070','#92d088','#f0c878','#88acd8','#d890d0','#8ed0c8',$null)
}

$theme_garnet = @{
    label='garnet'; bg='#1e0810'; fg='#f0d5e0'; cursor='#d06070'
    sel_bg='#381020'; sel_fg='#ffe4ec'
    ansi=@('#130408','#e84060','#7abf78','#e8b860','#7098c8','#c878c0','#72c0b8','#f0d5e0',
           $null,    '#f07085','#94d48e','#f0cc80','#8ab0d8','#d898d8','#90d0c8',$null)
}

# ── dark orange ───────────────────────────────────────────────────────────────

$theme_molten = @{
    label='molten'; bg='#1e1005'; fg='#f8e0c0'; cursor='#ff8040'
    sel_bg='#3a2008'; sel_fg='#fff0d8'
    ansi=@('#130a02','#ff5040','#82c870','#f0b030','#6898d0','#c07abe','#72c0b0','#f8e0c0',
           $null,    '#ff8060','#9cd888','#f8cc58','#88b4e0','#d898d4','#90d4c4',$null)
}

$theme_amber_dusk = @{
    label='amber-dusk'; bg='#201505'; fg='#f5ddb8'; cursor='#e07030'
    sel_bg='#3c2808'; sel_fg='#ffedd0'
    ansi=@('#140e02','#f05038','#80c470','#eaac30','#6690c8','#bc78bc','#70beb0','#f5ddb8',
           $null,    '#f07858','#98d488','#f0c850','#86b0e0','#d494d4','#8ed0c4',$null)
}

$theme_wrought_iron = @{
    label='wrought-iron'; bg='#1a0e08'; fg='#f0d5b8'; cursor='#c06040'
    sel_bg='#341c10'; sel_fg='#ffe8d0'
    ansi=@('#100804','#e84838','#7cc070','#e8a830','#6490c8','#ba76ba','#6ebcac','#f0d5b8',
           $null,    '#f07060','#94d088','#f0c050','#84ace0','#d092d2','#8cccc0',$null)
}

# ── dark amber / yellow ───────────────────────────────────────────────────────

$theme_old_gold = @{
    label='old-gold'; bg='#1a1600'; fg='#f5f0b8'; cursor='#d4aa20'
    sel_bg='#322c00'; sel_fg='#fffff0'
    ansi=@('#100e00','#e85848','#82c470','#d4aa20','#6698d0','#c080c8','#70bfb8','#f5f0b8',
           $null,    '#f08070','#9cd48a','#e8cc50','#86b2e0','#d4a0d8','#8ed4cc',$null)
}

$theme_tarnished = @{
    label='tarnished'; bg='#1c1808'; fg='#f0eab8'; cursor='#c8a030'
    sel_bg='#342e10'; sel_fg='#fffce0'
    ansi=@('#100e04','#e45848','#80c070','#c8a030','#6494cc','#bc7cc4','#6ebcb4','#f0eab8',
           $null,    '#f07868','#98d08a','#e0c050','#84b0e0','#d09cd8','#8cd0c8',$null)
}

$theme_khaki_night = @{
    label='khaki-night'; bg='#181a04'; fg='#eaecb0'; cursor='#a0a840'
    sel_bg='#2e3008'; sel_fg='#f8fadc'
    ansi=@('#0e1002','#e05848','#7ec870','#c0a830','#6092cc','#b878c4','#6cbab2','#eaecb0',
           $null,    '#ee7868','#98d88a','#dac450','#80aee0','#d098d8','#8cccc4',$null)
}

# ── dark green ────────────────────────────────────────────────────────────────

$theme_obsidian_grove = @{
    label='obsidian-grove'; bg='#051505'; fg='#c8e8c0'; cursor='#50d050'
    sel_bg='#0e280e'; sel_fg='#e4fae0'
    ansi=@('#030e03','#f06060','#50d050','#d8b840','#5898d0','#c080c8','#5cc0b8','#c8e8c0',
           $null,    '#f08888','#80e478','#e8cc60','#80b4e4','#d8a0d8','#84d4ce',$null)
}

$theme_deep_fern = @{
    label='deep-fern'; bg='#0c1e0c'; fg='#d0e8c8'; cursor='#68c060'
    sel_bg='#183018'; sel_fg='#e8f8e4'
    ansi=@('#081208','#f06868','#68c060','#d8b840','#6098d0','#c282c8','#62c0b8','#d0e8c8',
           $null,    '#f08c8c','#88d080','#e8cc68','#82b4e4','#d4a4d8','#88d0cc',$null)
}

$theme_jade_shadow = @{
    label='jade-shadow'; bg='#081808'; fg='#cce0cc'; cursor='#5ab860'
    sel_bg='#142814'; sel_fg='#e4f4e0'
    ansi=@('#050f05','#ee6868','#5ab860','#d8b440','#5e96d0','#c080c8','#60beb8','#cce0cc',
           $null,    '#f08888','#82cc80','#e8c860','#80b2e4','#d4a0d8','#86ceca',$null)
}

# ── dark blue ─────────────────────────────────────────────────────────────────

$theme_midnight_blue = @{
    label='midnight-blue'; bg='#050820'; fg='#c8d5f8'; cursor='#5580f0'
    sel_bg='#0e1640'; sel_fg='#e0eaff'
    ansi=@('#030510','#ff6070','#78cc78','#e8c050','#5580f0','#c07ae0','#60c8c8','#c8d5f8',
           $null,    '#ff8898','#96dc96','#f0d068','#80a8ff','#d89cf0','#84dce0',$null)
}

$theme_deep_ocean = @{
    label='deep-ocean'; bg='#081828'; fg='#c0d8f5'; cursor='#4898e0'
    sel_bg='#102840'; sel_fg='#dceeff'
    ansi=@('#050f18','#ff6070','#76ca76','#e8bc50','#4898e0','#bc78d8','#5ec4c4','#c0d8f5',
           $null,    '#ff8898','#94da94','#f0cc68','#78b4ec','#d498e8','#82d8dc',$null)
}

$theme_ink_dark = @{
    label='ink-dark'; bg='#06080f'; fg='#c8d0f0'; cursor='#6878d0'
    sel_bg='#101828'; sel_fg='#dce4ff'
    ansi=@('#040508','#ff5c70','#74c874','#e6ba50','#6878d0','#b876d0','#5cc0c0','#c8d0f0',
           $null,    '#ff8090','#92d892','#f0ca68','#8898e0','#d898e0','#80d4d8',$null)
}

# ── vivid blue (spread across the blue spectrum) ──────────────────────────────
# arctic-blue  = cyan-leaning cold blue  (bg hue ~195°)
# pure-blue    = saturated true blue     (bg hue ~240°)
# dusk-blue    = violet-leaning blue     (bg hue ~260°)

$theme_royal_blue = @{
    label='arctic-blue'; bg='#062838'; fg='#c0ecf8'; cursor='#40d0f0'
    sel_bg='#0e3e52'; sel_fg='#dcf8ff'
    ansi=@('#041820','#ff5c6e','#58d888','#f0d050','#40d0f0','#c070e0','#38d4c8','#c0ecf8',
           $null,    '#ff88a0','#80ecaa','#f8e070','#70e4ff','#d898f0','#60e8e0',$null)
}

$theme_cobalt_dark = @{
    label='pure-blue'; bg='#080890'; fg='#c8d4ff'; cursor='#6888ff'
    sel_bg='#1010b8'; sel_fg='#e0e8ff'
    ansi=@('#060660','#ff5070','#60cc70','#f0c840','#6888ff','#c060e8','#50c8d8','#c8d4ff',
           $null,    '#ff80a0','#88dc90','#f8d860','#90b0ff','#d888f4','#78dce8',$null)
}

$theme_sapphire = @{
    label='dusk-blue'; bg='#100870'; fg='#d0c8ff'; cursor='#8870ff'
    sel_bg='#1c1298'; sel_fg='#e8e0ff'
    ansi=@('#0a0648','#ff5078','#5ecc6e','#f0c840','#8870ff','#d060e0','#50c8d4','#d0c8ff',
           $null,    '#ff80a8','#86dc8c','#f8d860','#a898ff','#e080f4','#78dce4',$null)
}

# ── dark violet ───────────────────────────────────────────────────────────────

$theme_shadow_realm = @{
    label='shadow-realm'; bg='#0c0520'; fg='#ddc8f8'; cursor='#9060f0'
    sel_bg='#1c1040'; sel_fg='#eedfff'
    ansi=@('#070314','#ff5070','#80cc70','#e8c050','#7080f0','#c060e8','#60c8d0','#ddc8f8',
           $null,    '#ff7898','#9cdc8c','#f0d068','#9098ff','#d888f4','#80dce4',$null)
}

$theme_deep_amethyst = @{
    label='deep-amethyst'; bg='#100520'; fg='#e0c8f8'; cursor='#9050d8'
    sel_bg='#200e40'; sel_fg='#f0e0ff'
    ansi=@('#0a0314','#ff5878','#7eca6e','#e8bc50','#6e7eee','#be5ee4','#5ec4cc','#e0c8f8',
           $null,    '#ff80a0','#9adc8a','#f0cc68','#8ea0ff','#d484f0','#82d8e0',$null)
}

$theme_midnight_plum = @{
    label='midnight-plum'; bg='#140520'; fg='#e8c8f0'; cursor='#a060d0'
    sel_bg='#240e40'; sel_fg='#f4e0ff'
    ansi=@('#0e0314','#ff587c','#7ecc70','#e8bc50','#7080ec','#c060d8','#60c4cc','#e8c8f0',
           $null,    '#ff82a8','#9cdc8c','#f0cc68','#90a0ff','#d888ec','#82d8e0',$null)
}

# ── vivid purple (more saturated than neon-grape / shadow-realm family) ───────
# electric-purple = true vivid dark purple   (bg hue ~270°)
# mauve-dark      = purple leaning magenta   (bg hue ~300°)
# imperial        = purple leaning blue      (bg hue ~255°)

$theme_electric_purple = @{
    label='electric-purple'; bg='#1e0060'; fg='#e8d8ff'; cursor='#b060ff'
    sel_bg='#300090'; sel_fg='#f4ecff'
    ansi=@('#140040','#ff5080','#70d070','#f0d050','#7060ff','#e040d0','#50d0e0','#e8d8ff',
           $null,    '#ff80a8','#90e090','#f8e068','#9898ff','#f068e8','#78e8f0',$null)
}

$theme_mauve_dark = @{
    label='mauve-purple'; bg='#280038'; fg='#f0d0f0'; cursor='#d060d0'
    sel_bg='#420060'; sel_fg='#fce8ff'
    ansi=@('#1a0026','#ff5070','#70cc70','#f0cc50','#8870f0','#d060d0','#58ccd8','#f0d0f0',
           $null,    '#ff80a0','#90dc90','#f8dc68','#a898ff','#e880e8','#80dce8',$null)
}

$theme_imperial = @{
    label='imperial-purple'; bg='#180050'; fg='#dcd0ff'; cursor='#9070ff'
    sel_bg='#280880'; sel_fg='#ede8ff'
    ansi=@('#100038','#ff5878','#68cc68','#eec850','#9070ff','#c858e0','#50ccd8','#dcd0ff',
           $null,    '#ff80a0','#88dc88','#f8d868','#a8a0ff','#e07af0','#78dce8',$null)
}

# ── register all themes with Set-Theme ────────────────────────────────────────

$script:WtThemes['blood-moon']      = $theme_blood_moon
$script:WtThemes['crimson-cave']    = $theme_crimson_cave
$script:WtThemes['garnet']          = $theme_garnet
$script:WtThemes['molten']          = $theme_molten
$script:WtThemes['amber-dusk']      = $theme_amber_dusk
$script:WtThemes['wrought-iron']    = $theme_wrought_iron
$script:WtThemes['old-gold']        = $theme_old_gold
$script:WtThemes['tarnished']       = $theme_tarnished
$script:WtThemes['khaki-night']     = $theme_khaki_night
$script:WtThemes['obsidian-grove']  = $theme_obsidian_grove
$script:WtThemes['deep-fern']       = $theme_deep_fern
$script:WtThemes['jade-shadow']     = $theme_jade_shadow
$script:WtThemes['arctic-blue']     = $theme_royal_blue
$script:WtThemes['pure-blue']       = $theme_cobalt_dark
$script:WtThemes['dusk-blue']       = $theme_sapphire
$script:WtThemes['midnight-blue']   = $theme_midnight_blue
$script:WtThemes['deep-ocean']      = $theme_deep_ocean
$script:WtThemes['ink-dark']        = $theme_ink_dark
$script:WtThemes['electric-purple'] = $theme_electric_purple
$script:WtThemes['mauve-purple']    = $theme_mauve_dark
$script:WtThemes['imperial-purple'] = $theme_imperial
$script:WtThemes['shadow-realm']    = $theme_shadow_realm
$script:WtThemes['deep-amethyst']   = $theme_deep_amethyst
$script:WtThemes['midnight-plum']   = $theme_midnight_plum
