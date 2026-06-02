#environment variables
$env:PATH="C:\Windows\System32\OpenSSH;$env:PATH"

#$env:WORK_ROOT="c:\work"
$env:GIT_ROOT="${env:WORK_ROOT}\git"
$env:GH_ROOT="${env:GIT_ROOT}\github"
$env:BB_ROOT="${env:GIT_ROOT}\bitbucket"
$env:OZ_ROOT="${env:GH_ROOT}\openziti"
$env:BB_DOV_ROOT="${env:BB_ROOT}\dovholuk"
$env:GH_DOVH="${env:GH_ROOT}\dovholuknf"
$env:DOTFILES="${env:GH_DOVH}\dotfiles"
$env:DOTAGENTS="${env:GH_DOVH}\dotagents"
$env:DOTFILES_PWSH="${env:DOTFILES}\powershell"
$env:ON_PATH="${env:DOTFILES_PWSH}\onpath"
$env:ORIG_PATH=$env:PATH
$env:DOTAGENTS_SCRIPTS="${env:DOTAGENTS}\scripts"
$env:PYTHON_HOME="${env:LOCALAPPDATA}\Programs\Python\Python313"
$env:PYTHON_SCRIPTS="${env:PYTHON_HOME}\Scripts"
$env:PATH="${env:ON_PATH};$env:PATH;$env:BB_DOV_ROOT\dev_stuff\helper-scripts\windows"
$env:NF_ROOT="${env:OZ_ROOT}\nf"

#$env:CLION_MINGW = "C:\Users\clint\AppData\Local\Programs\CLion\bin\mingw\bin"
#$env:CLION_CMAKE = "C:\Users\clint\AppData\Local\Programs\CLion\bin\cmake\win\x64\bin"
#$env:CLION_NINJA = "C:\Users\clint\AppData\Local\Programs\CLion\bin\ninja\win\x64"

$env:CLION_TOOL_ROOT="C:\Program Files\JetBrains\CLion 2025.3.3\bin"
$env:CLION_MINGW = "$env:CLION_TOOL_ROOT\mingw\bin"
$env:CLION_CMAKE = "$env:CLION_TOOL_ROOT\cmake\win\x64\bin\"
$env:CLION_NINJA = "$env:CLION_TOOL_ROOT\ninja\win\x64"


#aliases - get rid of overlapping ones with bash
Remove-Item alias:curl -ErrorAction Ignore
Remove-Item alias:mv -ErrorAction Ignore
Remove-Item alias:cp -ErrorAction Ignore
Remove-Item alias:rm -ErrorAction Ignore
Remove-Item alias:ls -ErrorAction Ignore
Remove-Item alias:diff -ErrorAction Ignore
Remove-Item alias:find -ErrorAction Ignore
Set-Alias -name vi -value "vim.exe"


function cddev () { cd $env:BB_DOV_ROOT\dev_stuff }
function cdghdov () { cd $env:GH_DOVH }
function cdda () { cd $env:DOTAGENTS }
function cddf () { cd $env:DOTFILES }
function cdop () { cd $env:ON_PATH }
function cdgh () { cd $env:GH_ROOT }
function cdnf () { cd $env:NF_ROOT }
function cdz () { cd $env:NF_ROOT\ziti }
function cdo () { cd $env:OZ_ROOT }
function cdzd () { cd $env:OZ_ROOT\ziti-doc }
function cdew () { cd $env:OZ_ROOT\desktop-edge-win }
function cdzet() { cd $env:OZ_ROOT\ziti-tunnel-sdk-c }
function cdds() { cd $env:GH_ROOT\netfoundry\docusaurus-shared }

function gwt {
    # Two ways the script communicates "cd the parent shell" to us:
    #   1. 'cd' subcommand: script prints the worktree path on stdout, we cd to it.
    #   2. Hint file: any other subcommand (new/pr/twig/discourse) that creates or
    #      lands in a worktree writes the path to %TEMP%\gwt-cwd-hint-<PID>.txt;
    #      we read it after the script returns and Set-Location.
    # A child .ps1 can't mutate the parent shell's cwd directly, hence the dance.
    $hintFile = Join-Path $env:TEMP "gwt-cwd-hint-$PID.txt"
    Remove-Item $hintFile -Force -ErrorAction SilentlyContinue

    if ($args.Count -ge 1 -and $args[0] -eq 'cd') {
        $p = & "$env:ON_PATH\git-worktree.ps1" @args
        if ($LASTEXITCODE -eq 0 -and $p) { Set-Location $p }
    } else {
        & "$env:ON_PATH\git-worktree.ps1" @args
    }

    if (Test-Path $hintFile) {
        $newCwd = (Get-Content $hintFile -Raw -ErrorAction SilentlyContinue).Trim()
        Remove-Item $hintFile -Force -ErrorAction SilentlyContinue
        if ($newCwd -and (Test-Path $newCwd)) { Set-Location $newCwd }
    }
}

function update-path {
    param(
        [Parameter(Mandatory)]
        [string]$EnvVarName,

        [switch]$Remove,

        [switch]$First
    )

    $value = (Get-Item -Path "Env:$EnvVarName").Value

    if ($Remove) {
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -ne $value }) -join ';'
    } else {
        # Dedupe first: drop any existing copies (case-insensitive) before adding,
        # so re-sourcing $PROFILE doesn't pile up duplicates.
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and ($_ -ne $value) }) -join ';'
        if ($First) {
            $env:PATH = "$value;$env:PATH"
        } else {
            $env:PATH += ";$value"
        }
    }
}

function show-path {
    # Print $env:PATH entries one-per-line. -Sort alphabetizes; default is
    # source order so you can see precedence.
    param([switch]$Sort)
    $entries = $env:PATH -split ';' | Where-Object { $_ }
    if ($Sort) { $entries | Sort-Object } else { $entries }
}

function dedupe-path {
    # Drop empty + duplicate entries from $env:PATH while preserving order.
    # Normalizes for comparison: collapses '\\' -> '\', strips trailing '\',
    # case-insensitive. The first occurrence's original spelling is kept.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $kept = foreach ($e in ($env:PATH -split ';')) {
        if (-not $e) { continue }
        $key = ($e -replace '\\\\','\').TrimEnd('\')
        if ($seen.Add($key)) { $e }
    }
    $env:PATH = $kept -join ';'
}

function add-linux_commands { update-path -EnvVarName LINUX_COMMANDS -First }
function remove-linux_commands { update-path -EnvVarName LINUX_COMMANDS -Remove }

function add-dotagents { update-path -EnvVarName DOTAGENTS_SCRIPTS -First }
function remove-dotagents { update-path -EnvVarName DOTAGENTS_SCRIPTS -Remove }

function add-python {
    update-path -EnvVarName PYTHON_HOME    -First
    update-path -EnvVarName PYTHON_SCRIPTS -First
}
function remove-python {
    update-path -EnvVarName PYTHON_HOME    -Remove
    update-path -EnvVarName PYTHON_SCRIPTS -Remove
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

$env:GO_BIN="V:\work\tools\go\current\bin"
function add-go_current { update-path -EnvVarName GO_BIN -First }
function remove-go_current { update-path -EnvVarName GO_BIN -Remove }

$env:DOTNET_DEFAULT ="C:\Program Files\dotnet"
function add-dotnet { update-path -EnvVarName DOTNET_DEFAULT -First }
function remove-dotnet { update-path -EnvVarName DOTNET_DEFAULT -Remove }

$env:DOXYGEN_DEFAULT ="C:\Program Files\doxygen\bin"
function add-doxygen { update-path -EnvVarName DOXYGEN_DEFAULT -First }
function remove-doxygen { update-path -EnvVarName DOXYGEN_DEFAULT -Remove }

$env:DOVHOLUK_ONPATH ="D:\git\github\dovholuknf\dotfiles\powershell\onpath"
function add-dotfiles_onpath { update-path -EnvVarName DOVHOLUK_ONPATH -First }
function remove-dotfiles_onpath { update-path -EnvVarName DOVHOLUK_ONPATH -Remove }

$env:CHOCO_DEFAULT ="C:\ProgramData\chocolatey\bin"
function add-choco { update-path -EnvVarName CHOCO_DEFAULT -First }
function remove-choco { update-path -EnvVarName CHOCO_DEFAULT -Remove }

$env:DOCKER_DEFAULT ="$env:ProgramFiles\Docker\Docker\resources\bin"
function add-docker { update-path -EnvVarName DOCKER_DEFAULT -First }
function remove-docker { update-path -EnvVarName DOCKER_DEFAULT -Remove }

$env:NODE_DEFAULT ="C:\Program Files\nodejs"
$env:NPM_DEFAULT  ="C:\Users\clint\AppData\Roaming\npm"
function add-npm {
    update-path -EnvVarName NODE_DEFAULT -First
    update-path -EnvVarName NPM_DEFAULT  -First
}
function remove-npm {
    update-path -EnvVarName NODE_DEFAULT -Remove
    update-path -EnvVarName NPM_DEFAULT  -Remove
}

$env:ZITI_HOME    = "$env:USERPROFILE\.ziti\bin"
$env:ZITI_DEFAULT = $env:ZITI_HOME   # gets pointed at a versioned subdir when 'add-ziti' runs

function _TuiSelect {
    # Arrow-key picker. Returns the chosen item (object) or $null if cancelled.
    # Up/Down/k/j to move, Enter to select, Esc/q to cancel. Uses VT escapes
    # for relative cursor motion so it works with Windows Terminal's tight buffer.
    param(
        [Parameter(Mandatory)] [array]$Items,
        [string]$Prompt = 'choose:',
        [string]$DisplayProperty
    )
    if (-not $Items.Count) { return $null }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        return $Items[0]
    }

    $ESC = [char]27
    $idx = 0
    $cursorWasVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    $render = {
        # Erase from cursor to end of screen, then write all rows. Cursor lands
        # on the line just below the last row.
        Write-Host -NoNewline "$ESC[J"
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $label = if ($DisplayProperty) { $Items[$i].$DisplayProperty } else { "$($Items[$i])" }
            $line  = if ($i -eq $idx) { "> $label" } else { "  $label" }
            $color = if ($i -eq $idx) { 'Cyan' } else { 'DarkGray' }
            Write-Host $line -ForegroundColor $color
        }
    }

    try {
        Write-Host ""
        Write-Host $Prompt -ForegroundColor DarkGray
        & $render

        while ($true) {
            $k = [Console]::ReadKey($true)
            $sel = $null; $cancel = $false
            switch ($k.Key) {
                'UpArrow'   { if ($idx -gt 0) { $idx-- } }
                'DownArrow' { if ($idx -lt $Items.Count - 1) { $idx++ } }
                'Home'      { $idx = 0 }
                'End'       { $idx = $Items.Count - 1 }
                'Enter'     { $sel = $Items[$idx] }
                'Escape'    { $cancel = $true }
                default {
                    switch ($k.KeyChar) {
                        'k' { if ($idx -gt 0) { $idx-- } }
                        'j' { if ($idx -lt $Items.Count - 1) { $idx++ } }
                        'q' { $cancel = $true }
                    }
                }
            }
            if ($sel)    { return $sel }
            if ($cancel) { return $null }

            # Move cursor UP by N lines (back to first item), redraw. Render
            # itself moves the cursor back down past the items.
            Write-Host -NoNewline "`r$ESC[$($Items.Count)A"
            & $render
        }
    } finally {
        [Console]::CursorVisible = $cursorWasVisible
        Write-Host ""
    }
}

function add-ziti {
    # Add a versioned ziti binary dir to PATH.
    # Layout expected: $env:ZITI_HOME\v<ver>\<ziti binaries>
    #   - 0 versions:  fall back to $env:ZITI_HOME itself (legacy / flat layout)
    #   - 1 version:   use it silently
    #   - N versions:  prompt; -Version <name> bypasses the prompt
    param([string]$Version)

    if (-not (Test-Path $env:ZITI_HOME)) {
        Write-Host "ziti home '$env:ZITI_HOME' not found -- nothing to add" -ForegroundColor Yellow
        return
    }

    $versions = @(Get-ChildItem $env:ZITI_HOME -Directory -ErrorAction SilentlyContinue |
                  Where-Object Name -match '^v\d' |
                  Sort-Object @{Expression = {
                      # Natural sort: split on dots/dashes, parse ints when possible.
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
    # Trim old ziti installs from $env:ZITI_HOME. Per-version y/N walk only,
    # newest first. Always refuses to delete the currently-active version
    # ($env:ZITI_DEFAULT). Also offers to clean leftover ziti-*.zip files
    # in $env:ZITI_HOME.
    #   -DryRun  -- list selections, don't actually remove
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    if (-not (Test-Path $env:ZITI_HOME)) {
        Write-Host "no ziti home at $env:ZITI_HOME -- nothing to clean" -ForegroundColor Yellow
        return
    }

    # SemVer-aware sort key. Splits the version into numeric and non-numeric
    # runs, zero-pads the numerics to 8 chars, then appends '~' (0x7E) to
    # release versions (no '-pre' suffix). '~' is higher than any letter or
    # digit, so a release sorts above its own pre-releases:
    #   v2.0.0      -> '00000002.00000000.00000000~'
    #   v2.0.0-pre14-> '00000002.00000000.00000000-pre00000014'
    # Descending string compare gives: v2.0.0, v2.0.0-pre14, v2.0.0-pre13, ...
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
        # default (Enter / 'y') = keep
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

    # Sweep leftover ziti-*.zip files from getZiti.ps1 / older flows.
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

$env:ZROK_DEFAULT = "$env:USERPROFILE\.local\bin"
function add-zrok    { update-path -EnvVarName ZROK_DEFAULT -First }
function remove-zrok { update-path -EnvVarName ZROK_DEFAULT -Remove }

# Java + Gradle: -Version overrides the auto-detected latest. Picks newest
# Temurin install from "Program Files\Eclipse Adoptium\jdk-*-hotspot" and
# newest Gradle from "D:\tools\gradle\*".
function add-java {
    param([string]$JavaVersion, [string]$GradleVersion)

    # Java
    $jdks = @(Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-*-hotspot' -ErrorAction SilentlyContinue |
              Sort-Object @{Expression = { [version](($_.Name -replace '^jdk-','' -replace '-hotspot$','') -split '\.' | Select-Object -First 4 | ForEach-Object {$_ -as [int]} | Join-String -Separator '.') }} -Descending)
    $jdk = if ($JavaVersion) { $jdks | Where-Object { $_.Name -like "*$JavaVersion*" } | Select-Object -First 1 } else { $jdks | Select-Object -First 1 }
    if (-not $jdk) {
        Write-Host "no JDK found under 'C:\Program Files\Eclipse Adoptium\jdk-*-hotspot' (filter: $JavaVersion)" -ForegroundColor Yellow
    } else {
        $env:JAVA_HOME = $jdk.FullName
        $env:JAVA_BIN  = Join-Path $env:JAVA_HOME 'bin'
        update-path -EnvVarName JAVA_BIN -First
        Write-Host "java   -> $env:JAVA_HOME" -ForegroundColor Green
    }

    # Gradle
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

function StartMcpGateway {
    & 'D:\git\github\openziti\mcp-gateway\build\mcp-gateway.exe' run 'C:\Users\clint\.mcp-gateway\config.yml' @args
}

$env:CARGO_BIN="$env:USERPROFILE\.cargo\bin"
function add-rust { update-path -EnvVarName CARGO_BIN -First }
function remove-rust { update-path -EnvVarName CARGO_BIN -Remove }

$env:OLLAMA_HOME="$env:LOCALAPPDATA\Programs\Ollama"
function add-ollama { update-path -EnvVarName OLLAMA_HOME -First }
function remove-ollama { update-path -EnvVarName OLLAMA_HOME -Remove }

function editsettings() {
  np "C:\Users\clint\AppData\Local\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
}
function toclaude() {
    & "C:\Windows\System32\OpenSSH\ssh.exe" `
        -p 222 `
        claude@localhost `
        -i "C:\Users\clint\.ssh\id_ed25519"
}
function systemshell() {
    # sudo psexec.exe -i -s -d wt.exe
    # sudo psexec.exe -i -s -d powershell
    sudo psexec.exe -i -s -d "C:\Program Files\WindowsApps\Microsoft.PowerShell_7.5.5.0_x64__8wekyb3d8bbwe\pwsh.exe"
}

function showfolderaccess() {
    param($path)

    (Get-Acl $path).Access | `
    Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited | `
    Sort-Object IdentityReference
}

function denyclaude() {
    param(
        $path,
        [switch]$Recursive
    )

    if ($Recursive) {
        icacls $path /deny "claude:(OI)(CI)F" /T
    } else {
        icacls $path /deny "claude:(OI)(CI)F"
    }
}

function addrestricted() {
    param(
        [Parameter(Mandatory=$true)][string]$path,
        [switch]$Recurse
    )

    $p = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { throw "Refusing to modify root drive: $p" }

    if ($Recurse) {
        icacls $p /inheritance:d /T 2>&1
        icacls $p /remove:g "BUILTIN\Users" /T 2>&1
        icacls $p /remove:g "NT AUTHORITY\Authenticated Users" /T 2>&1
        icacls $p /grant "RestrictedUsers:(OI)(CI)F" /T 2>&1
        icacls $p /grant "BUILTIN\Administrators:(OI)(CI)F" /T 2>&1
        icacls $p /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T 2>&1
    } else {
        icacls $p /inheritance:d 2>&1
        icacls $p /remove:g "BUILTIN\Users" 2>&1
        icacls $p /remove:g "NT AUTHORITY\Authenticated Users" 2>&1
        icacls $p /grant "RestrictedUsers:(OI)(CI)F" 2>&1
        icacls $p /grant "BUILTIN\Administrators:(OI)(CI)F" 2>&1
        icacls $p /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F" 2>&1
    }
}


function removerestricted() {
    param(
        [Parameter(Mandatory=$true)][string]$path,
        [switch]$Recurse
    )

    $p = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { throw "Refusing to modify root drive: $p" }

    if ($Recurse) {
        icacls $p /remove:g "RestrictedUsers" /T 2>&1
    } else {
        icacls $p /remove:g "RestrictedUsers" 2>&1
    }
}

$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}

Function Prompt () {
    If (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[Admin]" -NoNewLine -ForegroundColor "Red"
    }
    Write-Host $env:COMPUTERNAME -NoNewLine -ForegroundColor "White"
    Write-Host ": " -NoNewLine
    Write-Host $pwd.ProviderPath -ForegroundColor "Green"
    Write-Host "PS>" -NoNewLine -ForegroundColor "DarkGray"
    return " "
}
function Set-ConsoleColor ($bc, $fc) {
    $Host.UI.RawUI.BackgroundColor = $bc
    $Host.UI.RawUI.ForegroundColor = $fc
    Clear-Host
}

function resolve {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $t = $item.LinkTarget
    if (-not $t -and $item.Target) { $t = $item.Target | Select-Object -First 1 }
    if (-not $t) { return $item.FullName }
    if ([System.IO.Path]::IsPathRooted($t)) { return $t }
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path $item.FullName -Parent) $t))
}

function ptail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Tail = 5
    )
    $real = resolve $Path
    Get-Content -LiteralPath $real -Tail $Tail -Wait
}

function tziti {
    ptail 'C:\Program Files (x86)\NetFoundry Inc\Ziti Desktop Edge\logs\service\ziti-tunneler.log'
}

function ltail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Pattern,
        [int]$Cols = 200
    )
    $real = (resolve $Path).Replace('\','/')
    if ($Pattern) {
        tail -f $real | grep --line-buffered $Pattern | cut -b "1-$Cols"
    } else {
        tail -f $real | cut -b "1-$Cols"
    }
}

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
    if ($Second) {
        $path    = $First
        $pattern = $Second
    } else {
        $path    = '.'
        $pattern = $First
    }
    if (-not $pattern) { Write-Host "usage: psfind [<path>] <pattern>" -ForegroundColor Yellow; return }
    Get-ChildItem -Path $path -Recurse -Filter $pattern -Name -ErrorAction SilentlyContinue
}

Set-PSReadLineKeyHandler -Key Ctrl+d -Function DeleteCharOrExit

# ziti completion powershell | Out-String | Invoke-Expression
add-go_current
add-doxygen
add-dotnet
add-linux_commands
add-dotagents
add-python
dedupe-path


. $env:DOTFILES\powershell\wt-themes.ps1
. $env:DOTFILES\powershell\gwt-session-registry.ps1
. $env:DOTFILES\powershell\claude-shell.ps1


# comment
