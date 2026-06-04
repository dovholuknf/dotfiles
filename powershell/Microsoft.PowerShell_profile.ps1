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
$env:PATH="${env:ON_PATH};$env:PATH;$env:BB_DOV_ROOT\dev_stuff\helper-scripts\windows"
$env:NF_ROOT="${env:OZ_ROOT}\nf"

# user-specific: which Python and which ziti base
$env:PYTHON_HOME    = "$env:LOCALAPPDATA\Programs\Python\Python313"
$env:PYTHON_SCRIPTS = "$env:PYTHON_HOME\Scripts"
$env:ZITI_HOME      = "$env:USERPROFILE\.ziti\bin"
$env:ZITI_DEFAULT   = $env:ZITI_HOME   # gets repointed at a versioned subdir by add-ziti
$env:DOVHOLUK_ONPATH = "$env:ON_PATH"
$env:WORKTREE_ROOT   = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT } else { 'D:\worktrees' }

# shared helpers + add-/remove- tool toggles
. $env:DOTFILES\powershell\shared\common-tools.ps1

# clint-only: alias for the dotfiles onpath dir
function add-dotfiles_onpath    { update-path -EnvVarName DOVHOLUK_ONPATH -First }
function remove-dotfiles_onpath { update-path -EnvVarName DOVHOLUK_ONPATH -Remove }

# clint-only: dotagents scripts on path (claude doesn't author dotagents)
function add-dotagents    { update-path -EnvVarName DOTAGENTS_SCRIPTS -First }
function remove-dotagents { update-path -EnvVarName DOTAGENTS_SCRIPTS -Remove }

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

function StartMcpGateway {
    & "$env:OZ_ROOT\mcp-gateway\build\mcp-gateway.exe" run "$env:USERPROFILE\.mcp-gateway\config.yml" @args
}

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
