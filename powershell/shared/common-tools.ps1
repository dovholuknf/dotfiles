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
    #
    # Behaviors that MUST keep working when this function is edited (see the
    # "List pickers" section in CLAUDE.md for the full contract).
    param(
        [Parameter(Mandatory)] [array]$Items,
        [string]$Prompt = 'choose:',
        [string]$DisplayProperty,
        [scriptblock]$DisplayScript,
        [switch]$AllowAll,
        # 0-based row to highlight on open. Callers wanting a default of "row N"
        # in 1-based reasoning pass N-1. Clamped to a valid range.
        [int]$DefaultIndex = 0,
        # Max visible rows. Caps the viewport even when the terminal is tall.
        # Pass -PageSize 0 to mean "as many as fit in the window".
        [int]$PageSize = 12
    )
    if (-not $Items.Count) { return $null }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        return $Items[0]
    }

    $ESC = [char]27
    $idx = if ($DefaultIndex -ge 0 -and $DefaultIndex -lt $Items.Count) { $DefaultIndex } else { 0 }
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
    $reserved = if ($AllowAll) { 5 } else { 4 }
    $fit  = $winH - $reserved
    $cap  = if ($PageSize -gt 0) { $PageSize } else { [int]::MaxValue }
    $viewport = [Math]::Max(1, [Math]::Min($Items.Count, [Math]::Min($cap, $fit)))

    # Mutable render state. Hashtable so the render scriptblock can update it
    # without scope gymnastics.
    $state = @{ top = 0; lastLines = 0; first = $true }

    $render = {
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
            $line  = "$arrow$num$label"
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
        } else {
            [void]$sb.Append("$ESC[90m  (type digits / Up-Down to move, Enter to pick, Esc/q to cancel)${scroll}$ESC[0m$ESC[K`r`n")
        }
        $linesThisFrame++
        if ($AllowAll) {
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
            $sel = $null; $cancel = $false; $all = $false

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
                'Enter'     { $sel = $Items[$idx]; $numBuf = '' }
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
                        'a' { if ($AllowAll) { $all = $true } }
                    }
                }
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

    if (-not $versions.Count) {
        $env:ZITI_DEFAULT = $env:ZITI_HOME
    } elseif ($Version) {
        $hit = $versions | Where-Object Name -ieq $Version | Select-Object -First 1
        if (-not $hit) {
            Write-Host "version '$Version' not found in $env:ZITI_HOME -- available:" -ForegroundColor Yellow
            $versions | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor DarkGray }
            return
        }
        $env:ZITI_DEFAULT = $hit.FullName
    } elseif ($versions.Count -eq 1) {
        $env:ZITI_DEFAULT = $versions[0].FullName
    } else {
        $pick = _TuiSelect -Items $versions -Prompt "choose ziti version (Up/Down + Enter, Esc to cancel):" -DisplayProperty 'Name'
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
