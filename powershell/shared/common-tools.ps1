# Shared helpers + add-/remove- tool toggles. Dot-source from both
# clint's $PROFILE and claude's ~/.profile.ps1 so future additions only
# need to land here once. Assumes $env:DOTFILES is already set.
#
# Things that stay in the per-user profile:
#   - env var declarations whose paths are user-specific
#   - cd* shortcuts
#   - prompt functions
#   - the `gwt` wrapper (clint's variant captures cwd hints; claude's is simpler)
#   - admin / per-user one-off functions
#
# Things that live HERE:
#   - update-path / show-path / dedupe-path
#   - _TuiSelect (arrow-key picker)
#   - psfind
#   - add-/remove- pairs for tools whose install paths are stable across users
#   - add-ziti / cleanup-ziti (sophisticated; want one canonical copy)
#   - add-java / remove-java
#   - add-docker / remove-docker
#
# Each add-* expects the env var it references to already exist. We set
# the universally-same ones below; per-user variations (PYTHON_HOME version
# pin, ZITI_HOME base) are still declared in each profile.

# ── Console encoding ─────────────────────────────────────────────────────────
# Render UTF-8 correctly (em-dashes, arrows, box-drawing in gwt tables) instead of
# CP437/CP850 mojibake like the classic ΓÇö for an em-dash. [Console]::OutputEncoding
# fixes what the terminal displays; $OutputEncoding fixes what pwsh sends to native
# tools, so the whole path is UTF-8. Guarded: a redirected / non-console host has no
# console handle to set, and throwing there would break profile load for hooks.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [Text.Encoding]::UTF8

# ── PATH manipulation ────────────────────────────────────────────────────────

function update-path {
    param(
        [Parameter(Mandatory)] [string]$EnvVarName,
        [switch]$Remove,
        [switch]$First
    )
    $value = (Get-Item -Path "Env:$EnvVarName").Value
    if ($Remove) {
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -ne $value }) -join ';'
    } else {
        # Dedupe first so re-sourcing $PROFILE doesn't pile up duplicates.
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and ($_ -ne $value) }) -join ';'
        if ($First) { $env:PATH = "$value;$env:PATH" }
        else        { $env:PATH += ";$value" }
    }
}

function show-path {
    # -Sort alphabetizes; default is source order.
    param([switch]$Sort)
    $entries = $env:PATH -split ';' | Where-Object { $_ }
    if ($Sort) { $entries | Sort-Object } else { $entries }
}

function dedupe-path {
    # Drop empty + duplicate entries from $env:PATH while preserving order.
    # Normalizes for comparison: collapses '\\' -> '\', strips trailing '\'.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $kept = foreach ($e in ($env:PATH -split ';')) {
        if (-not $e) { continue }
        $key = ($e -replace '\\\\','\').TrimEnd('\')
        if ($seen.Add($key)) { $e }
    }
    $env:PATH = $kept -join ';'
}

# ── TUI picker ───────────────────────────────────────────────────────────────

function _TuiSelect {
    # The unified list picker. Use this in EVERY script that asks the user to
    # pick from a list. Do NOT hand-roll a `for ($i...) { Write-Host "[N]..." } ;
    # Read-Host "choice"` block; it breaks the consistent UX the user expects
    # across Set-Theme / gwt sessions / wt-window picker / etc.
    #
    # Returns:
    #   - the chosen item (one of $Items) on Enter / digit-key selection
    #   - $Items (the full array) when 'a' is pressed and -AllowAll is set
    #   - $null on Esc/q (or when stdin is redirected -- non-interactive defaults
    #     to returning $Items[0] silently; passes through scripts without hanging)
    #
    # Keystrokes:
    #   Up / Down / k / j      cursor move (wraps at top/bottom)
    #   PageUp / PageDown      move by one viewport
    #   Home / End             jump to first / last
    #   <digit>                jump to that-numbered item (buffered for lists > 9)
    #   Backspace              pop one digit off the buffer
    #   Enter                  commit current cursor / digit buffer
    #   Esc                    1st press: clear the digit buffer; 2nd press: cancel
    #   q                      cancel (single keystroke when buffer is empty)
    #   a                      select-all (only when -AllowAll)
    #
    # Parameters:
    #   -Items <array>            REQUIRED. The list to pick from.
    #   -Prompt <string>          Header text shown above the list.
    #   -DisplayProperty <name>   Pull the label from this property of each item.
    #   -DisplayScript  <block>   Compute the label by invoking the block with each item.
    #                             (-DisplayScript wins over -DisplayProperty when both set.)
    #   -DefaultIndex <int>       0-based row to highlight on open. Clamped to range.
    #   -AllowAll                 Enable 'a' = return full list. Caller can distinguish
    #                             single-item vs all by checking @($picked).Count.
    #   -MultiSelect              Checkbox mode. Space toggles the current row, 'a'
    #                             toggles all, Enter returns the checked items as an
    #                             array (possibly empty). Esc/q returns $null. So the
    #                             caller MUST test for $null (cancelled) BEFORE .Count
    #                             (an empty array is a real "nothing checked" answer).
    #   -Preselected <int[]>      0-based indices checked on open (MultiSelect only).
    #
    # Behaviors that MUST keep working when this function is edited (see the
    # "List pickers" section in CLAUDE.md for the full contract).
    param(
        [Parameter(Mandatory)] [array]$Items,
        [string]$Prompt = 'choose:',
        [string]$DisplayProperty,
        [scriptblock]$DisplayScript,
        [switch]$AllowAll,
        [switch]$MultiSelect,
        [int[]]$Preselected = @(),
        # 0-based row to highlight on open. Callers wanting a default of "row N"
        # in 1-based reasoning pass N-1. Clamped to a valid range.
        [int]$DefaultIndex = 0,
        # Max visible rows. Caps the viewport even when the terminal is tall.
        # Pass -PageSize 0 to mean "as many as fit in the window".
        [int]$PageSize = 12,
        # Optional callback invoked with the highlighted item whenever the cursor
        # lands on a new row (and once on open). Used for live preview, e.g. the
        # theme picker applies the theme as you scroll. Errors are swallowed.
        [scriptblock]$OnHighlight
    )
    if (-not $Items.Count) { return $null }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        # Non-interactive: single-select passes through with $Items[0]; multi-select
        # honors the remembered set (the preselected indices), or empty if none.
        if ($MultiSelect) {
            return ,@($Preselected | Where-Object { $_ -ge 0 -and $_ -lt $Items.Count } | ForEach-Object { $Items[$_] })
        }
        return $Items[0]
    }

    $ESC = [char]27
    $idx = if ($DefaultIndex -ge 0 -and $DefaultIndex -lt $Items.Count) { $DefaultIndex } else { 0 }
    # Checkbox state for MultiSelect, seeded from -Preselected indices.
    $checked = New-Object 'bool[]' $Items.Count
    foreach ($p in $Preselected) { if ($p -ge 0 -and $p -lt $Items.Count) { $checked[$p] = $true } }
    $cursorWasVisible = [Console]::CursorVisible
    $ctrlCWas = [Console]::TreatControlCAsInput
    [Console]::CursorVisible = $false
    [Console]::TreatControlCAsInput = $true
    # numBuf accumulates digit keystrokes for items > 9. e.g. type '1' '2' to
    # highlight item 12. Enter confirms; Esc clears the buffer (not the picker).
    $numBuf = ''

    $labelFor = {
        param($it)
        if ($DisplayScript)        { return (& $DisplayScript $it) }
        elseif ($DisplayProperty)  { return $it.$DisplayProperty }
        else                       { return "$it" }
    }

    # Pad index column width to fit Items.Count digits, so two-digit lists line up.
    $idxWidth = ([string]$Items.Count).Length

    # Compute viewport = min(PageSize, terminalFit, itemCount), floor 1.
    # PageSize is the soft cap so a tall window doesn't render 50 rows.
    # terminalFit is the hard cap so a tiny window still works.
    # Reserve = blank line + prompt + footer (+ allow-all row) + 2 lines safety.
    $winH = try { [Console]::WindowHeight } catch { 24 }
    $reserved = if ($AllowAll -or $MultiSelect) { 5 } else { 4 }
    $fit  = $winH - $reserved
    $cap  = if ($PageSize -gt 0) { $PageSize } else { [int]::MaxValue }
    $viewport = [Math]::Max(1, [Math]::Min($Items.Count, [Math]::Min($cap, $fit)))

    # Mutable render state. Hashtable so the render scriptblock can update it
    # without scope gymnastics.
    $state = @{ top = 0; lastLines = 0; first = $true; lastHighlight = -1 }

    $render = {
        # Live-preview hook: fire when the highlighted row changes. Done before any
        # cursor math so a callback that writes OSC (e.g. theme apply) can't shift
        # the line accounting. Swallow errors -- preview must never break the picker.
        if ($OnHighlight -and $idx -ne $state.lastHighlight) {
            try { & $OnHighlight $Items[$idx] } catch {}
            $state.lastHighlight = $idx
        }
        # Scroll the viewport to keep $idx visible.
        if ($idx -lt $state.top)                   { $state.top = $idx }
        if ($idx -ge $state.top + $viewport)       { $state.top = $idx - $viewport + 1 }
        if ($state.top -lt 0)                      { $state.top = 0 }
        if ($state.top + $viewport -gt $Items.Count) { $state.top = [Math]::Max(0, $Items.Count - $viewport) }

        $sb = [System.Text.StringBuilder]::new()
        # Synchronized output (DEC private mode 2026): the terminal buffers
        # every byte between BSU and ESU into one atomic paint. Kills the flash
        # on cursor-up + redraw. Terminals that don't grok it (older conhost)
        # just ignore the sequence -- no fallback needed.
        [void]$sb.Append("$ESC[?2026h")
        # Move cursor up to the start of the previous frame so we overwrite it
        # in place. First paint has nothing to overwrite. Uses \e[K per line
        # (clear-to-eol) instead of \e[J (clear-below) so there's no flash.
        if (-not $state.first -and $state.lastLines -gt 0) {
            [void]$sb.Append("$ESC[$($state.lastLines)A")
        }

        $linesThisFrame = 0
        $end = [Math]::Min($Items.Count, $state.top + $viewport)
        for ($i = $state.top; $i -lt $end; $i++) {
            $label = & $labelFor $Items[$i]
            $num   = "[{0,$idxWidth}] " -f ($i + 1)
            $arrow = if ($i -eq $idx) { '> ' } else { '  ' }
            $box   = if ($MultiSelect) { if ($checked[$i]) { '[x] ' } else { '[ ] ' } } else { '' }
            $line  = "$arrow$box$num$label"
            if ($i -eq $idx) {
                [void]$sb.Append("$ESC[36m$line$ESC[0m$ESC[K`r`n")    # cyan
            } else {
                [void]$sb.Append("$ESC[90m$line$ESC[0m$ESC[K`r`n")    # darkgray
            }
            $linesThisFrame++
        }
        # Footer: scroll indicator + hint OR digit-buffer prompt.
        $scroll = if ($Items.Count -gt $viewport) {
            "  ({0}-{1}/{2})" -f ($state.top + 1), $end, $Items.Count
        } else { '' }
        if ($numBuf) {
            [void]$sb.Append("$ESC[33m  pick: ${numBuf}_  (Enter to confirm, Esc to clear)${scroll}$ESC[0m$ESC[K`r`n")
        } elseif ($MultiSelect) {
            $nChecked = @($checked | Where-Object { $_ }).Count
            [void]$sb.Append("$ESC[90m  (Space toggles, Up-Down to move, Enter confirms $nChecked selected, Esc/q cancels)${scroll}$ESC[0m$ESC[K`r`n")
        } else {
            [void]$sb.Append("$ESC[90m  (type digits / Up-Down to move, Enter to pick, Esc/q to cancel)${scroll}$ESC[0m$ESC[K`r`n")
        }
        $linesThisFrame++
        if ($MultiSelect) {
            [void]$sb.Append("$ESC[90m  (press 'a' to toggle all)$ESC[0m$ESC[K`r`n")
            $linesThisFrame++
        } elseif ($AllowAll) {
            [void]$sb.Append("$ESC[90m  (press 'a' to select all)$ESC[0m$ESC[K`r`n")
            $linesThisFrame++
        }
        # Pad with cleared lines if this frame drew fewer than the last one, so
        # leftover rows from a taller previous frame don't linger.
        while ($linesThisFrame -lt $state.lastLines) {
            [void]$sb.Append("$ESC[K`r`n")
            $linesThisFrame++
        }

        [void]$sb.Append("$ESC[?2026l")   # end synchronized update
        [Console]::Out.Write($sb.ToString())
        $state.lastLines = $linesThisFrame
        $state.first = $false
    }

    try {
        Write-Host ""
        Write-Host $Prompt -ForegroundColor DarkGray
        & $render

        while ($true) {
            $k = [Console]::ReadKey($true)
            $sel = $null; $cancel = $false; $all = $false; $commitMulti = $false

            # Digits build up a numBuf and just move the cursor; commit on Enter.
            # Non-digit keys clear the buffer.
            $ch = $k.KeyChar
            if ($ch -ge '0' -and $ch -le '9') {
                $candidate = $numBuf + [string]$ch
                # cap at 3 digits; nobody is picking item 1000
                if ($candidate.Length -le 3) {
                    $n = [int]$candidate
                    if ($n -ge 1 -and $n -le $Items.Count) {
                        $numBuf = $candidate
                        $idx = $n - 1
                    }
                }
                & $render
                continue
            }

            switch ($k.Key) {
                'UpArrow'   { $idx = if ($idx -gt 0) { $idx - 1 } else { $Items.Count - 1 }; $numBuf = '' }
                'DownArrow' { $idx = if ($idx -lt $Items.Count - 1) { $idx + 1 } else { 0 };               $numBuf = '' }
                'PageUp'    { $idx = [Math]::Max(0, $idx - $viewport); $numBuf = '' }
                'PageDown'  { $idx = [Math]::Min($Items.Count - 1, $idx + $viewport); $numBuf = '' }
                'Home'      { $idx = 0; $numBuf = '' }
                'End'       { $idx = $Items.Count - 1; $numBuf = '' }
                'Enter'     { if ($MultiSelect) { $commitMulti = $true } else { $sel = $Items[$idx] }; $numBuf = '' }
                'Spacebar'  { if ($MultiSelect) { $checked[$idx] = -not $checked[$idx] }; $numBuf = '' }
                'C'         {
                    if ($k.Modifiers -band [ConsoleModifiers]::Control) { $cancel = $true }
                }
                'Escape'    {
                    if ($numBuf) { $numBuf = '' } else { $cancel = $true }
                }
                'Backspace' {
                    if ($numBuf.Length -gt 0) {
                        $numBuf = $numBuf.Substring(0, $numBuf.Length - 1)
                        if ($numBuf) {
                            $idx = [int]$numBuf - 1
                        }
                    }
                }
                default {
                    switch ($ch) {
                        'k' { $idx = if ($idx -gt 0) { $idx - 1 } else { $Items.Count - 1 }; $numBuf = '' }
                        'j' { $idx = if ($idx -lt $Items.Count - 1) { $idx + 1 } else { 0 };               $numBuf = '' }
                        'q' { $cancel = $true }
                        'a' {
                            if ($MultiSelect) {
                                # Toggle all: if every row is already checked, clear;
                                # otherwise check every row.
                                $allChecked = -not (@(0..($Items.Count - 1) | Where-Object { -not $checked[$_] }).Count)
                                for ($z = 0; $z -lt $Items.Count; $z++) { $checked[$z] = -not $allChecked }
                            } elseif ($AllowAll) { $all = $true }
                        }
                    }
                }
            }
            if ($commitMulti) {
                # Return the checked items in $Items order. Unary comma preserves an
                # empty array (a real "nothing checked" answer, distinct from $null).
                return ,@(for ($z = 0; $z -lt $Items.Count; $z++) { if ($checked[$z]) { $Items[$z] } })
            }
            if ($sel)    { return $sel }
            if ($all)    { return ,@($Items) }
            if ($cancel) { return $null }
            & $render
        }
    } finally {
        [Console]::TreatControlCAsInput = $ctrlCWas
        [Console]::CursorVisible = $cursorWasVisible
        Write-Host ""
    }
}

# ── psfind ───────────────────────────────────────────────────────────────────

function psfind {
    # usage: psfind [<path>] <pattern>
    #   psfind *.env            -> search cwd for *.env
    #   psfind . *.env          -> same
    #   psfind src *.ts         -> search ./src for *.ts
    #   psfind D:\work *.log    -> absolute path
    param(
        [Parameter(Position=0)][string]$First,
        [Parameter(Position=1)][string]$Second
    )
    if ($Second) { $path = $First; $pattern = $Second }
    else         { $path = '.';    $pattern = $First }
    if (-not $pattern) { Write-Host "usage: psfind [<path>] <pattern>" -ForegroundColor Yellow; return }
    Get-ChildItem -Path $path -Recurse -Filter $pattern -Name -ErrorAction SilentlyContinue
}

# ── common env vars + simple add/remove pairs ────────────────────────────────
# Paths here are identical across users; user-specific ones stay in each profile.

$env:GO_BIN          = "V:\work\tools\go\current\bin"
$env:DOTNET_DEFAULT  = "C:\Program Files\dotnet"
$env:DOXYGEN_DEFAULT = "C:\Program Files\doxygen\bin"
$env:CHOCO_DEFAULT   = "C:\ProgramData\chocolatey\bin"
$env:DOCKER_DEFAULT  = "$env:ProgramFiles\Docker\Docker\resources\bin"
$env:NODE_DEFAULT    = "C:\Program Files\nodejs"
$env:NPM_DEFAULT     = Join-Path $env:APPDATA 'npm'
$env:CARGO_BIN       = "$env:USERPROFILE\.cargo\bin"
$env:OLLAMA_HOME     = "$env:LOCALAPPDATA\Programs\Ollama"
$env:ZROK_DEFAULT    = "$env:USERPROFILE\.local\bin"
$env:CLION_TOOL_ROOT = "C:\Program Files\JetBrains\CLion 2025.3.3\bin"
$env:CLION_MINGW     = "$env:CLION_TOOL_ROOT\mingw\bin"
$env:CLION_CMAKE     = "$env:CLION_TOOL_ROOT\cmake\win\x64\bin\"
$env:CLION_NINJA     = "$env:CLION_TOOL_ROOT\ninja\win\x64"

function add-linux_commands    { update-path -EnvVarName LINUX_COMMANDS -First }
function remove-linux_commands { update-path -EnvVarName LINUX_COMMANDS -Remove }

function add-go_current        { update-path -EnvVarName GO_BIN -First }
function remove-go_current     { update-path -EnvVarName GO_BIN -Remove }

function add-dotnet            { update-path -EnvVarName DOTNET_DEFAULT -First }
function remove-dotnet         { update-path -EnvVarName DOTNET_DEFAULT -Remove }

function add-doxygen           { update-path -EnvVarName DOXYGEN_DEFAULT -First }
function remove-doxygen        { update-path -EnvVarName DOXYGEN_DEFAULT -Remove }

function add-choco             { update-path -EnvVarName CHOCO_DEFAULT -First }
function remove-choco          { update-path -EnvVarName CHOCO_DEFAULT -Remove }

function add-rust              { update-path -EnvVarName CARGO_BIN -First }
function remove-rust           { update-path -EnvVarName CARGO_BIN -Remove }

function add-ollama            { update-path -EnvVarName OLLAMA_HOME -First }
function remove-ollama         { update-path -EnvVarName OLLAMA_HOME -Remove }

function add-zrok              { update-path -EnvVarName ZROK_DEFAULT -First }
function remove-zrok           { update-path -EnvVarName ZROK_DEFAULT -Remove }

function add-npm {
    update-path -EnvVarName NODE_DEFAULT -First
    update-path -EnvVarName NPM_DEFAULT  -First
}
function remove-npm {
    update-path -EnvVarName NODE_DEFAULT -Remove
    update-path -EnvVarName NPM_DEFAULT  -Remove
}

function add-clion_tools {
    update-path -EnvVarName CLION_MINGW -First
    update-path -EnvVarName CLION_CMAKE -First
    update-path -EnvVarName CLION_NINJA -First
    if (-not $env:VCPKG_ROOT) {
        $env:VCPKG_ROOT = $env:VCPKG_ROOT_DEFAULT
    }
}
function remove-clion_tools {
    update-path -EnvVarName CLION_MINGW -Remove
    update-path -EnvVarName CLION_CMAKE -Remove
    update-path -EnvVarName CLION_NINJA -Remove
}

# Python: each profile sets PYTHON_HOME to its preferred version dir.
function add-python {
    update-path -EnvVarName PYTHON_HOME    -First
    update-path -EnvVarName PYTHON_SCRIPTS -First
}
function remove-python {
    update-path -EnvVarName PYTHON_HOME    -Remove
    update-path -EnvVarName PYTHON_SCRIPTS -Remove
}

# ── docker via WSL TCP ───────────────────────────────────────────────────────

function add-docker {
    update-path -EnvVarName DOCKER_DEFAULT -First
    # Point at WSL/Ubuntu dockerd via TCP rather than the Docker-Desktop named pipe.
    $env:DOCKER_HOST = "tcp://127.0.0.1:2375"
    Write-Host "docker -> $env:DOCKER_HOST" -ForegroundColor Green
    $null = & docker ps 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "docker ps failed against $env:DOCKER_HOST -- dockerd probably not listening on 2375." -ForegroundColor Yellow
        Write-Host "Inside the WSL/Ubuntu shell, run ONCE:" -ForegroundColor DarkGray
        Write-Host @'
  sudo mkdir -p /etc/systemd/system/docker.service.d && \
  sudo tee /etc/systemd/system/docker.service.d/override.conf >/dev/null <<'EOF'
  [Service]
  ExecStart=
  ExecStart=/usr/bin/dockerd \
    -H unix:///run/docker.sock \
    -H tcp://127.0.0.1:2375 \
    --containerd=/run/containerd/containerd.sock
  EOF
  sudo systemctl daemon-reload && sudo systemctl restart docker docker.socket
'@ -ForegroundColor DarkGray
    }
}
function remove-docker {
    update-path -EnvVarName DOCKER_DEFAULT -Remove
    Remove-Item Env:\DOCKER_HOST -ErrorAction SilentlyContinue
}

# ── java + gradle (auto-pick newest) ─────────────────────────────────────────

function add-java {
    # -JavaVersion / -GradleVersion override the auto-detected latest. Picks newest
    # Temurin under 'Program Files\Eclipse Adoptium\jdk-*-hotspot' and newest
    # Gradle under 'D:\tools\gradle\*'.
    param([string]$JavaVersion, [string]$GradleVersion)

    $jdks = @(Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-*-hotspot' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending)
    $jdk = if ($JavaVersion) { $jdks | Where-Object { $_.Name -like "*$JavaVersion*" } | Select-Object -First 1 } else { $jdks | Select-Object -First 1 }
    if (-not $jdk) {
        Write-Host "no JDK found under 'C:\Program Files\Eclipse Adoptium\jdk-*-hotspot' (filter: $JavaVersion)" -ForegroundColor Yellow
    } else {
        $env:JAVA_HOME = $jdk.FullName
        $env:JAVA_BIN  = Join-Path $env:JAVA_HOME 'bin'
        update-path -EnvVarName JAVA_BIN -First
        Write-Host "java   -> $env:JAVA_HOME" -ForegroundColor Green
    }

    $gradles = @(Get-ChildItem 'D:\tools\gradle' -Directory -ErrorAction SilentlyContinue |
                 Where-Object { Test-Path (Join-Path $_.FullName 'bin\gradle.bat') } |
                 Sort-Object @{Expression = { try { [version]$_.Name } catch { [version]'0.0' } }} -Descending)
    $gradle = if ($GradleVersion) { $gradles | Where-Object { $_.Name -eq $GradleVersion } | Select-Object -First 1 } else { $gradles | Select-Object -First 1 }
    if (-not $gradle) {
        Write-Host "no Gradle found under 'D:\tools\gradle\<ver>\bin' (filter: $GradleVersion)" -ForegroundColor Yellow
    } else {
        $env:GRADLE_HOME = $gradle.FullName
        $env:GRADLE_BIN  = Join-Path $env:GRADLE_HOME 'bin'
        update-path -EnvVarName GRADLE_BIN -First
        Write-Host "gradle -> $env:GRADLE_HOME" -ForegroundColor Green
    }
}

function remove-java {
    if ($env:JAVA_BIN)   { update-path -EnvVarName JAVA_BIN   -Remove }
    if ($env:GRADLE_BIN) { update-path -EnvVarName GRADLE_BIN -Remove }
}

# ── ziti (versioned, with TUI picker) ────────────────────────────────────────
# Each profile sets $env:ZITI_HOME to its own .ziti\bin base. ZITI_DEFAULT
# gets pointed at a versioned subdir by add-ziti.

function add-ziti {
    # Add a ziti binary dir to PATH.
    #
    # Default (no -Path): pick from $env:ZITI_HOME\v<ver>\... layout.
    #   - 0 versions:  fall back to $env:ZITI_HOME itself (legacy / flat layout)
    #   - 1 version:   use it silently
    #   - N versions:  TUI picker; -Version <name> bypasses the prompt
    #
    # -Path <p> (positional): use an arbitrary location instead. Accepts either
    #   the ziti.exe itself or the directory containing it. Skips $env:ZITI_HOME
    #   entirely. Example:
    #     add-ziti C:\tools\ziti-1.2.3\ziti.exe
    #     add-ziti C:\tools\ziti-1.2.3
    param(
        [Parameter(Position=0)] [string]$Path,
        [string]$Version
    )

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Host "path not found: $Path" -ForegroundColor Yellow
            return
        }
        $item = Get-Item -LiteralPath $Path
        $dir  = if ($item.PSIsContainer) { $item.FullName } else { Split-Path -Parent $item.FullName }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'ziti.exe'))) {
            Write-Host "no ziti.exe in '$dir' -- not adding to PATH" -ForegroundColor Yellow
            return
        }
        $env:ZITI_DEFAULT = $dir
        update-path -EnvVarName ZITI_DEFAULT -First
        Write-Host "ziti -> $env:ZITI_DEFAULT" -ForegroundColor Green
        return
    }

    if (-not (Test-Path $env:ZITI_HOME)) {
        Write-Host "ziti home '$env:ZITI_HOME' not found -- nothing to add" -ForegroundColor Yellow
        Write-Host "  tip: pass an explicit path: add-ziti <path-to-ziti.exe-or-its-dir>" -ForegroundColor DarkGray
        return
    }

    $versions = @(Get-ChildItem $env:ZITI_HOME -Directory -ErrorAction SilentlyContinue |
                  Where-Object Name -match '^v\d' |
                  Sort-Object @{Expression = {
                      $parts = $_.Name.TrimStart('v') -split '[.\-]'
                      $parts | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { $_ } }
                  }} -Descending)

    # Surface locally-available ziti binaries so you can switch to an ad-hoc download
    # or build without -Path: any immediate subdir of $PWD (one level deep) that holds
    # a ziti.exe, plus $PWD itself if it holds one. These float to the top of the
    # picker, pre-highlighted, ahead of the $env:ZITI_HOME versions.
    $localDirs = @(Get-ChildItem $PWD -Directory -ErrorAction SilentlyContinue |
                   Where-Object { Test-Path (Join-Path $_.FullName 'ziti.exe') } |
                   Sort-Object Name -Descending)
    if (Test-Path (Join-Path $PWD.Path 'ziti.exe')) {
        $localDirs = @(Get-Item -LiteralPath $PWD.Path) + @($localDirs)
    }
    $allVersions = @($localDirs) + @($versions)

    if (-not $allVersions.Count) {
        $env:ZITI_DEFAULT = $env:ZITI_HOME
    } elseif ($Version) {
        $hit = $allVersions | Where-Object Name -ieq $Version | Select-Object -First 1
        if (-not $hit) {
            Write-Host "version '$Version' not found -- available:" -ForegroundColor Yellow
            $allVersions | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor DarkGray }
            return
        }
        $env:ZITI_DEFAULT = $hit.FullName
    } elseif ($allVersions.Count -eq 1) {
        $env:ZITI_DEFAULT = $allVersions[0].FullName
    } else {
        $cwdNorm = $PWD.Path.TrimEnd('\').ToLower()
        $label = {
            param($d)
            $isLocal = $d.FullName.ToLower().StartsWith($cwdNorm)
            if ($isLocal) { $d.FullName } else { $d.Name }
        }
        $pick = _TuiSelect -Items $allVersions `
                    -Prompt "choose ziti version (Up/Down + Enter, Esc to cancel):" `
                    -DisplayScript $label `
                    -DefaultIndex 0
        if (-not $pick) { Write-Host "cancelled" -ForegroundColor Yellow; return }
        $env:ZITI_DEFAULT = $pick.FullName
    }

    update-path -EnvVarName ZITI_DEFAULT -First
    Write-Host "ziti -> $env:ZITI_DEFAULT" -ForegroundColor Green
}

function remove-ziti { update-path -EnvVarName ZITI_DEFAULT -Remove }

function cleanup-ziti {
    # Per-version y/N walk, newest first. Always refuses to delete the
    # currently-active version ($env:ZITI_DEFAULT). Sweeps leftover ziti-*.zip
    # files in $env:ZITI_HOME afterwards.
    #   -DryRun  -- list selections, don't actually remove
    [CmdletBinding()]
    param([switch]$DryRun)

    if (-not (Test-Path $env:ZITI_HOME)) {
        Write-Host "no ziti home at $env:ZITI_HOME -- nothing to clean" -ForegroundColor Yellow
        return
    }

    # SemVer-aware sort: zero-pad digit runs, append '~' to release versions
    # so they sort above their pre-releases.
    $padKey = {
        param($name)
        $name = $name.TrimStart('v')
        $hasSuffix = $name.Contains('-')
        $sb = [System.Text.StringBuilder]::new()
        foreach ($m in [System.Text.RegularExpressions.Regex]::Matches($name, '\d+|\D+')) {
            $t = $m.Value
            if ($t -match '^\d+$') { [void]$sb.Append($t.PadLeft(8,'0')) }
            else                   { [void]$sb.Append($t) }
        }
        if (-not $hasSuffix) { [void]$sb.Append('~') }
        $sb.ToString()
    }
    $versions = @(Get-ChildItem $env:ZITI_HOME -Directory -ErrorAction SilentlyContinue |
                  Where-Object Name -match '^v\d' |
                  Sort-Object @{Expression = { & $padKey $_.Name }} -Descending)

    if (-not $versions.Count) {
        Write-Host "no ziti versions found under $env:ZITI_HOME" -ForegroundColor Yellow
        return
    }

    $activeNorm = if ($env:ZITI_DEFAULT) { $env:ZITI_DEFAULT.TrimEnd('\').ToLower() } else { $null }

    Write-Host ""
    Write-Host "for each installed ziti version (newest first): Y=keep (default), n=remove, q=stop" -ForegroundColor DarkGray
    $toRemove = @()
    foreach ($v in $versions) {
        $tag = ''
        if ($activeNorm -and $v.FullName.TrimEnd('\').ToLower() -eq $activeNorm) { $tag = ' (ACTIVE -- always kept)' }
        $resp = (Read-Host "keep '$($v.Name)'$tag? (Y/n/q)").Trim().ToLower()
        if ($resp -eq 'q') { break }
        if ($resp -eq 'n') { $toRemove += $v }
    }

    if (-not $toRemove.Count) { Write-Host "nothing selected" -ForegroundColor DarkGray; return }

    Write-Host ""
    Write-Host "would remove $($toRemove.Count) version(s):" -ForegroundColor Yellow
    foreach ($v in $toRemove) {
        $tag = ''
        if ($activeNorm -and $v.FullName.TrimEnd('\').ToLower() -eq $activeNorm) { $tag = ' (ACTIVE -- will be skipped)' }
        Write-Host "  $($v.Name)$tag" -ForegroundColor DarkGray
    }

    if ($DryRun) { Write-Host "-DryRun: not actually removing" -ForegroundColor DarkGray; return }

    $confirm = Read-Host "proceed? (y/N)"
    if (-not ($confirm -match '^[Yy]')) { Write-Host "aborted" -ForegroundColor Yellow; return }

    foreach ($v in $toRemove) {
        if ($activeNorm -and $v.FullName.TrimEnd('\').ToLower() -eq $activeNorm) {
            Write-Host "  skipped (currently active): $($v.Name)" -ForegroundColor Yellow
            continue
        }
        try {
            Remove-Item $v.FullName -Recurse -Force -ErrorAction Stop
            Write-Host "  removed: $($v.Name)" -ForegroundColor Green
        } catch {
            Write-Host "  failed: $($v.Name) -- $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $zips = @(Get-ChildItem $env:ZITI_HOME -Filter 'ziti-*.zip' -File -ErrorAction SilentlyContinue)
    if ($zips.Count) {
        Write-Host ""
        Write-Host "leftover zip files:" -ForegroundColor DarkGray
        foreach ($z in $zips) { Write-Host "  $($z.Name)  ($([int]($z.Length/1MB)) MB)" -ForegroundColor DarkGray }
        $rmZips = Read-Host "remove these zips too? (y/N)"
        if ($rmZips -match '^[Yy]') {
            foreach ($z in $zips) {
                try {
                    Remove-Item $z.FullName -Force -ErrorAction Stop
                    Write-Host "  removed: $($z.Name)" -ForegroundColor Green
                } catch {
                    Write-Host "  failed: $($z.Name) -- $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Shared profile helpers: defined here so both users' profiles get them from one
# place. Per-user navigation shortcuts stay in each profile. The themed prompt is
# shared via _WtPrompt below, so each profile's `prompt`/`Prompt` just calls it.
# These reference env vars at call time, so they work as long as the vars are set
# before this file is dot-sourced (both profiles do that).
# ---------------------------------------------------------------------------

# The themed prompt, shared by both accounts. On a cwd change it auto-applies the
# repo theme (Set-Theme -UseRepoTheme -Quiet). When a repo is detected it draws a
# 30-char repo banner pinned top-right, true-colored from the active theme. Then
# it prints an optional [WtLabel] tab tag, the [theme]/[default] tag, host, path,
# a one-time map hint, and PS>. State is kept in globals so it behaves the same
# whichever profile calls it. Set-Theme comes from wt-themes.ps1, sourced after
# this file, which is fine because the prompt only runs after the profile loads.
# Derive a wt tab title from the cwd, mirroring the repo path layout: a clone at
# <GIT_ROOT>\<host>\<org>\<repo> or a worktree at <WORKTREE_ROOT>\<host>\<org>\<repo>\<branch>
# yields org/repo (the host segment is dropped). Worktrees append ` @ <branch>` so
# sibling worktrees don't collide. A path under neither root falls back to the leaf.
function _WtTabTitle {
    param([string]$Cwd)
    $gitRoot = if ($env:GIT_ROOT)      { $env:GIT_ROOT }      else { 'D:\git' }
    $wtRoot  = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT } else { 'D:\worktrees' }
    $c = $Cwd.TrimEnd('\')
    foreach ($root in @($gitRoot, $wtRoot)) {
        $r = $root.TrimEnd('\')
        if ($c.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $seg = $c.Substring($r.Length + 1) -split '\\'
            if ($seg.Count -ge 3) {
                $title = $seg[1,2] -join '/'
                if ($r -ieq $wtRoot.TrimEnd('\') -and $seg.Count -ge 4) { $title += " @ $($seg[3])" }
                return $title
            }
            return ($seg[-1])
        }
    }
    return (Split-Path $c -Leaf)
}

function _WtPrompt {
    $cwd = $pwd.ProviderPath
    if ($cwd -ne $global:_WtLastThemeCwd) {
        $global:_WtLastThemeCwd = $cwd
        if (Get-Command Set-Theme -ErrorAction SilentlyContinue) {
            Set-Theme -UseRepoTheme -Quiet
        }
        try { $Host.UI.RawUI.WindowTitle = _WtTabTitle $cwd } catch {}
    }

    if ($global:WtCurrentRepo) {
        $width = 30
        $name  = $global:WtCurrentRepo
        if ($name.Length -gt $width) { $name = $name.Substring(0, $width) }
        $pad   = $width - $name.Length
        $left  = [int][Math]::Floor($pad / 2)
        $label = (' ' * $left) + $name + (' ' * ($pad - $left))
        $row   = [Console]::CursorTop + 1  # 1-based ANSI row; capture NOW before any Write-Host
        $col   = [Console]::WindowWidth - $width + 1
        $esc   = [char]27
        $color = '97;44'  # fallback: bright white on blue
        if ($global:CurrentTheme -and $global:CurrentTheme.bg -and $global:CurrentTheme.ansi[6]) {
            $th = $global:CurrentTheme.bg.TrimStart('#')       # text = theme bg color
            $bh = $global:CurrentTheme.ansi[6].TrimStart('#')  # stripe bg = theme DarkCyan slot
            $tr = [Convert]::ToInt32($th.Substring(0,2),16)
            $tg = [Convert]::ToInt32($th.Substring(2,2),16)
            $tb = [Convert]::ToInt32($th.Substring(4,2),16)
            $sr = [Convert]::ToInt32($bh.Substring(0,2),16)
            $sg = [Convert]::ToInt32($bh.Substring(2,2),16)
            $sb = [Convert]::ToInt32($bh.Substring(4,2),16)
            $color = "38;2;${tr};${tg};${tb};48;2;${sr};${sg};${sb}"
        }
        [Console]::Write("${esc}[s${esc}[${row};${col}H${esc}[${color}m${label}${esc}[0m${esc}[u")
    }

    If (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[Admin]" -NoNewLine -ForegroundColor "Red"
    }
    # Apply-Theme copies the theme's own label into WtLabel, so for a theme whose
    # label equals its name this would render '[dracula] [dracula]'. Show the label
    # only when it says something the theme tag doesn't.
    if ($global:WtLabel -and $global:WtLabel -ne $global:WtThemeName) {
        Write-Host "[$global:WtLabel] " -NoNewLine -ForegroundColor "DarkCyan"
    }
    if ($global:WtThemeName) {
        Write-Host "[$global:WtThemeName] " -NoNewLine -ForegroundColor "DarkCyan"
    } else {
        Write-Host "[default] " -NoNewLine -ForegroundColor "DarkGray"
    }
    Write-Host $env:COMPUTERNAME -NoNewLine -ForegroundColor "White"
    Write-Host ": " -NoNewLine
    Write-Host $pwd.ProviderPath -ForegroundColor "Green"
    $repoChanged = $global:WtCurrentRepo -ne $global:_WtLastHintRepo
    $global:_WtLastHintRepo = $global:WtCurrentRepo
    if (-not $global:WtThemeName -and $global:WtThemeCanMap -and $repoChanged) {
        Write-Host "  hint: Set-Theme -SetRepoTheme to map a theme to this repo" -ForegroundColor DarkGray
    }
    Write-Host "PS>" -NoNewLine -ForegroundColor "DarkGray"

    return " "
}

function gwt {
    # Two ways the script tells us to move the parent shell:
    #   1. 'cd' subcommand prints the worktree path on stdout -> we Set-Location.
    #   2. Any other subcommand that lands in a worktree writes the path to a
    #      hint file (%TEMP%\gwt-cwd-hint-<PID>.txt) which we read after.
    # We also sync [Environment]::CurrentDirectory, not just $PWD: a shell whose
    # real Win32 working directory is a worktree keeps an OS handle on it, which
    # blocks a later prune. Set-Location alone does not move that handle.
    $hintFile = Join-Path $env:TEMP "gwt-cwd-hint-$PID.txt"
    Remove-Item $hintFile -Force -ErrorAction SilentlyContinue
    $env:GWT_HINT_FILE = $hintFile
    if ($args.Count -ge 1 -and $args[0] -eq 'cd') {
        $p = & "$env:ON_PATH\git-worktree.ps1" @args
        if ($LASTEXITCODE -eq 0 -and $p) { Set-Location $p; [Environment]::CurrentDirectory = $p }
    } else {
        & "$env:ON_PATH\git-worktree.ps1" @args
    }
    Remove-Item Env:GWT_HINT_FILE -ErrorAction SilentlyContinue
    if (Test-Path $hintFile) {
        $newCwd = (Get-Content $hintFile -Raw -ErrorAction SilentlyContinue).Trim()
        Remove-Item $hintFile -Force -ErrorAction SilentlyContinue
        if ($newCwd -and (Test-Path $newCwd)) { Set-Location $newCwd; [Environment]::CurrentDirectory = $newCwd }
    }
    # 'gwt close' drops a <hint>.close marker to ask us to exit this shell, which
    # closes the wt tab. Done last, after any cleanup above.
    if (Test-Path "$hintFile.close") {
        Remove-Item "$hintFile.close" -Force -ErrorAction SilentlyContinue
        exit
    }
}

# Bitbucket read-only API helper. GET-only by design; the real guardrail is the
# token's scopes (create an Atlassian API token with only read:* bitbucket
# scopes, e.g. read:repository:bitbucket + read:pullrequest:bitbucket).
# Creds come from env (set in each user's .profile.ps1, never committed):
#   $env:BB_EMAIL  = your atlassian account email
#   $env:BB_TOKEN  = the read-only atlassian API token
# Usage:
#   bbapi repositories/<workspace>/<repo>/pullrequests?state=OPEN
#   bbapi repositories/netfoundry/<repo>/pullrequests/42
#   bbapi <path> -All      # follow pagination, merge every page's .values
#   bbapi <path> -Raw      # emit raw JSON text instead of a parsed object
function bbapi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Path,
        [switch] $Raw,
        [switch] $All
    )
    if (-not $env:BB_EMAIL -or -not $env:BB_TOKEN) {
        throw "bbapi: set `$env:BB_EMAIL and `$env:BB_TOKEN in your .profile.ps1 first."
    }
    $basic = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("$($env:BB_EMAIL):$($env:BB_TOKEN)"))

    # accept a bare path (after /2.0/) or a full https URL (e.g. a 'next' link)
    $url = if ($Path -match '^https?://') { $Path }
           else { "https://api.bitbucket.org/2.0/$($Path.TrimStart('/'))" }

    $pages = @()
    while ($url) {
        # --location: several endpoints (e.g. pullrequests/N/diff|diffstat) 302
        # to the real content; without it curl returns an empty redirect body.
        $json = curl.exe --silent --show-error --fail-with-body `
            --location `
            --http1.1 --ipv4 `
            --request GET `
            --url $url `
            --header "Authorization: Basic $basic" `
            --header "Accept: application/json"
        if ($LASTEXITCODE -ne 0) { throw "bbapi: curl failed ($LASTEXITCODE) for $url`n$json" }

        if (-not $All) {
            if ($Raw) { return $json }
            return ($json | ConvertFrom-Json)
        }

        $obj = $json | ConvertFrom-Json
        if ($null -eq $obj.values) {
            if ($Raw) { return $json }
            return $obj
        }
        $pages += $obj.values
        $url = $obj.next
    }
    return $pages
}

# Navigation shortcuts that are identical for both users. Per-user ones (and the
# divergent `cddf`) live in each profile.
function cddev () { cd $env:BB_DOV_ROOT\dev_stuff }
function cdgh ()  { cd $env:GH_ROOT }
function cdghnf () { cd $env:GH_ROOT\netfoundry }
function cdtk ()  { cd $env:GH_ROOT\openziti-test-kitchen }
function cdbb ()  { cd $env:BB_ROOT }
function cdbbnf () { cd $env:BB_ROOT\netfoundry }
function cdnf ()  { cd $env:NF_ROOT }
function cdz ()   { cd $env:NF_ROOT\ziti }
function cdo ()   { cd $env:OZ_ROOT }
function cdzd ()  { cd $env:OZ_ROOT\ziti-doc }
function cdew ()  { cd $env:OZ_ROOT\desktop-edge-win }
function cdzet () { cd $env:OZ_ROOT\ziti-tunnel-sdk-c }
function cdcsdk () { cd $env:OZ_ROOT\ziti-sdk-c }
function cdcs ()   { cd $env:OZ_ROOT\ziti-sdk-csharp }
function cdds ()   { cd $env:GH_ROOT\netfoundry\docusaurus-shared }

# MCP server launchers (shared). Each speaks stdio; run when you want the server
# standalone. Paths resolve per-account: the zendesk launcher lives in the repo,
# the discourse profile (holds the API key) sits under the running user's home.
function mcp-start-zendesk {
    & "$env:GH_ROOT\netfoundry\mcp-zendesk\start-zendesk.ps1" @args
}
function mcp-start-discourse {
    # Call npx.cmd explicitly: PATH also holds an extensionless 'npx' (a Unix
    # script) that pwsh would otherwise try to ShellExecute, popping the Windows
    # "how do you want to open this file" dialog. One line -- no backtick
    # continuations, which break on a trailing space and shell-execute the fragment.
    npx.cmd -y '@discourse/mcp@latest' --profile "$env:USERPROFILE\discourse\.discourse.profile" --site 'https://openziti.discourse.group/' @args
}
function mcp-start-mercurius {
    & "$env:GH_ROOT\michaelquigley\mercurius\build.claude\mercurius.exe" --http 127.0.0.1:7337 --config "$env:GH_ROOT\michaelquigley\mercurius\mercurius.yaml" @args
}
function _ParseMcpGatewayConfig {
    # Split an mcp-gateway config.yml into (Head, Entries, Tail) so a caller can
    # rebuild it with only SOME backends enabled. Head is every line up to and
    # including the top-level 'backends:' key. Each entry is one backend list item
    # captured VERBATIM (its exact lines), with Id/Name pulled out for display.
    # Tail is any top-level section that follows the backends block. No YAML library
    # needed: the split keys off indentation, which this machine-written file keeps
    # regular. A new entry is a '- ' at the SAME indent as the first one; deeper
    # '- ' lines (a nested block list inside an entry) stay part of that entry.
    param([Parameter(Mandatory)][string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path)
    $head    = New-Object System.Collections.Generic.List[string]
    $tail    = New-Object System.Collections.Generic.List[string]
    $entries = @()

    $i = 0
    $found = $false
    while ($i -lt $lines.Count) {
        $head.Add($lines[$i])
        if ($lines[$i] -match '^backends:\s*(#.*)?$') { $i++; $found = $true; break }
        $i++
    }
    if (-not $found) { return $null }

    $cur = $null
    $entryIndent = $null
    for (; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        # A non-blank, non-comment line at column 0 ends the backends block.
        if ($ln -match '^\S' -and $ln -notmatch '^\s*#') { break }

        $isEntryStart = $false
        if ($ln -match '^(\s+)-\s') {
            $ind = $Matches[1].Length
            if ($null -eq $entryIndent) { $entryIndent = $ind }
            if ($ind -eq $entryIndent) { $isEntryStart = $true }
        }
        if ($isEntryStart) {
            if ($cur) { $entries += ,$cur }
            $cur = [pscustomobject]@{
                Id = $null; Name = $null
                Lines = (New-Object System.Collections.Generic.List[string])
            }
        }
        if ($cur) {
            $cur.Lines.Add($ln)
            $bare = $ln -replace '^\s*-\s*', ''
            if (-not $cur.Id   -and $bare -match '^\s*id:\s*["'']?([^"''#]+?)["'']?\s*(#.*)?$')   { $cur.Id   = $Matches[1].Trim() }
            if (-not $cur.Name -and $bare -match '^\s*name:\s*["'']?([^"''#]+?)["'']?\s*(#.*)?$') { $cur.Name = $Matches[1].Trim() }
        } else {
            # blank/comment lines between 'backends:' and the first entry -> head
            $head.Add($ln)
        }
    }
    if ($cur) { $entries += ,$cur }
    for (; $i -lt $lines.Count; $i++) { $tail.Add($lines[$i]) }

    return [pscustomobject]@{ Head = $head; Entries = @($entries); Tail = $tail }
}

function mcp-start-mcp-gateway {
    # Serve a chosen subset of the aggregated MCP tools over plain local HTTP.
    # Multi-select picker over the backends in config.yml, remembers the last
    # selection, then writes a filtered config.active.yml and serves only those.
    # Anything after the address prompt is passed straight to 'run'. Points at
    # build.claude for now (the only binary carrying --listen until the PR merges).
    $exe    = "$env:OZ_ROOT\mcp-gateway\build.claude\mcp-gateway.exe"
    $cfgDir = "$env:USERPROFILE\.mcp-gateway"
    $cfg    = Join-Path $cfgDir 'config.yml'
    $active = Join-Path $cfgDir 'config.active.yml'
    $selF   = Join-Path $cfgDir 'selection.json'

    if (-not (Test-Path $cfg)) { Write-Host "no config at $cfg" -ForegroundColor Red; return }

    $parsed = _ParseMcpGatewayConfig -Path $cfg
    if (-not $parsed -or -not $parsed.Entries.Count) {
        Write-Host "no 'backends:' entries found in $cfg" -ForegroundColor Red; return
    }
    $entries = $parsed.Entries

    # Remembered ids -> preselected indices in this run's entry order.
    $remembered = @()
    if (Test-Path $selF) { try { $remembered = @(Get-Content $selF -Raw | ConvertFrom-Json) } catch {} }
    $preIdx = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($remembered -contains $entries[$i].Id) { $preIdx += $i }
    }

    Write-Host "mcp-gateway -- pick which backends to serve (remembered from last run):" -ForegroundColor Cyan
    $picked = _TuiSelect -Items $entries -MultiSelect -Preselected $preIdx `
        -Prompt "backends -- Space toggles, 'a' all, Enter starts, Esc cancels:" `
        -DisplayScript { param($e) '{0,-16} {1}' -f $e.Id, $e.Name }

    if ($null -eq $picked) { Write-Host "  cancelled -- gateway not started" -ForegroundColor DarkGray; return }
    $picked = @($picked)
    if (-not $picked.Count) { Write-Host "  nothing selected -- gateway not started" -ForegroundColor Yellow; return }

    # Persist the selection (ids, in entry order) for next run.
    @($picked.Id) | ConvertTo-Json | Set-Content -Path $selF -Encoding UTF8

    # Rebuild the config with only the selected backend blocks, kept verbatim.
    $out = New-Object System.Collections.Generic.List[string]
    $parsed.Head | ForEach-Object { $out.Add($_) }
    foreach ($e in $picked) { $e.Lines | ForEach-Object { $out.Add($_) } }
    $parsed.Tail | ForEach-Object { $out.Add($_) }
    [System.IO.File]::WriteAllLines($active, $out)

    Write-Host "  serving $($picked.Count) backend(s): $(@($picked.Id) -join ', ')" -ForegroundColor Green
    Write-Host "  active config: $active" -ForegroundColor DarkGray
    Write-Host "  passthrough: --network agora | --agora-integration-file <path> | any 'run' flag" -ForegroundColor DarkGray
    $default = '127.0.0.1:8088'
    $addr = Read-Host "listen address [$default]"
    if ([string]::IsNullOrWhiteSpace($addr)) { $addr = $default }
    Write-Host "  -> http://$addr   (register: claude mcp add --transport http mcp-gateway http://$addr)" -ForegroundColor DarkGray
    & $exe run $active --listen $addr @args
}

# Alias hygiene: drop the built-in aliases that shadow the real unix tools both
# users expect (curl, mv, cp, rm, ls, diff, find), and map vi -> vim. Per-user
# extras (e.g. claude's `which`) stay in each profile.
foreach ($a in 'curl','mv','cp','rm','ls','diff','find') {
    Remove-Item "alias:$a" -ErrorAction Ignore
}
Set-Alias -Name vi -Value 'vim.exe'

# Ctrl+d: delete char, or exit on empty line (both users want this).
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key Ctrl+d -Function DeleteCharOrExit
}

function agent-log {
    # Live-tail gwt session states, showing only the two that matter:
    #   needs-input -> an agent is waiting on you      (yellow, "NEEDS YOU")
    #   idle        -> an agent finished its turn       (green,  "done")
    # All other transitions (thinking/startup/resume/...) are suppressed.
    # Each row shows: time  TAG  [terminal-group]  branch  @ path
    # The terminal group (wt WindowName) isn't in the log, so we look it up from
    # the session ledger by matching the worktree path. Ctrl-C to stop.
    $root    = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT } else { 'D:\worktrees' }
    $log     = Join-Path $root 'watch\state.log'
    $sessDir = Join-Path $root 'sessions'
    if (-not (Test-Path $log)) { Write-Host "no state log at $log" -ForegroundColor DarkGray; return }

    function _WindowForPath([string]$p) {
        if (-not (Test-Path $sessDir)) { return $null }
        $norm = ($p -replace '/', '\').TrimEnd('\').ToLower()
        foreach ($f in Get-ChildItem $sessDir -Filter '*.json' -ErrorAction SilentlyContinue) {
            try {
                $e = Get-Content $f.FullName -Raw | ConvertFrom-Json
                if ($e.WorktreePath -and ((($e.WorktreePath -replace '/', '\').TrimEnd('\').ToLower()) -eq $norm)) {
                    return $e.WindowName
                }
            } catch {}
        }
        return $null
    }

    Get-Content $log -Wait -Tail 50 | ForEach-Object {
        if ($_ -notmatch '^(?<ts>\S+)\s+(?<state>\S+)\s+(?<branch>.+?)\s+@\s+(?<path>.+)$') { return }
        $state = $Matches.state
        if ($state -notin @('needs-input','idle','thinking','subagent','sub-done')) { return }
        $time   = try { [datetime]::Parse($Matches.ts).ToString('HH:mm:ss') } catch { $Matches.ts }
        $branch = $Matches.branch.Trim()
        $path   = $Matches.path.Trim()
        # Log sometimes records '(unknown)' for the branch -- fall back to the
        # worktree dir's leaf name, which is what the branch usually is anyway.
        if ($branch -in @('(unknown)','') ) { $branch = Split-Path $path -Leaf }
        $group  = _WindowForPath $path
        $grpTag = if ($group) { "[$group]" } else { '[?]' }
        # tags padded to equal width so columns stay aligned
        $tag    = switch ($state) {
            'needs-input' { 'NEEDS YOU' }
            'thinking'    { 'thinking ' }
            'subagent'    { 'SUBAGENT ' }
            'sub-done'    { 'sub done ' }
            default       { 'done     ' }
        }
        $color  = switch ($state) {
            'needs-input' { 'Yellow' }
            'thinking'    { 'Cyan' }
            'subagent'    { 'Magenta' }
            'sub-done'    { 'DarkMagenta' }
            default       { 'Green' }
        }
        Write-Host ("{0}  {1}  {2}  {3}  @ {4}" -f `
            $time, $tag, $grpTag.PadRight(20), $branch.PadRight(28), $path) -ForegroundColor $color
    }
}
