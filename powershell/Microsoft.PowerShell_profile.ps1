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
    # 'cd' is special-cased: the script prints the worktree path, we Set-Location
    # here (a child .ps1 can't change the parent shell's cwd).
    if ($args.Count -ge 1 -and $args[0] -eq 'cd') {
        $p = & "$env:ON_PATH\git-worktree.ps1" @args
        if ($LASTEXITCODE -eq 0 -and $p) { Set-Location $p }
    } else {
        & "$env:ON_PATH\git-worktree.ps1" @args
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

$env:ZITI_DEFAULT ="$env:USERPROFILE\.ziti\bin"
function add-ziti { update-path -EnvVarName ZITI_DEFAULT -First }
function remove-ziti { update-path -EnvVarName ZITI_DEFAULT -Remove }

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
