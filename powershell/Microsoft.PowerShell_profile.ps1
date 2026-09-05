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
$env:NF_ROOT="${env:GH_ROOT}\netfoundry"

# user-specific: which Python and which ziti base
$env:PYTHON_HOME    = "$env:LOCALAPPDATA\Programs\Python\Python313"
$env:PYTHON_SCRIPTS = "$env:PYTHON_HOME\Scripts"
$env:ZITI_HOME      = "$env:USERPROFILE\.ziti\bin"
$env:ZITI_DEFAULT   = $env:ZITI_HOME   # gets repointed at a versioned subdir by add-ziti
$env:DOVHOLUK_ONPATH = "$env:ON_PATH"
$env:WORKTREE_ROOT   = if ($env:WORKTREE_ROOT) { $env:WORKTREE_ROOT } else { 'D:\worktrees' }

# shared helpers + add-/remove- tool toggles
. $env:DOTFILES\powershell\shared\common-tools.ps1

# Local secrets (BB_EMAIL / BB_TOKEN, etc). Lives in the user profile dir, NOT the
# repo, so it never gets pushed. Optional: skipped if the file isn't there.
$localSecrets = Join-Path $HOME '.profile.secrets.ps1'
if (Test-Path $localSecrets) { . $localSecrets }

# clint-only: alias for the dotfiles onpath dir
function add-dotfiles_onpath    { update-path -EnvVarName DOVHOLUK_ONPATH -First }
function remove-dotfiles_onpath { update-path -EnvVarName DOVHOLUK_ONPATH -Remove }

# clint-only: dotagents scripts on path (claude doesn't author dotagents)
function add-dotagents    { update-path -EnvVarName DOTAGENTS_SCRIPTS -First }
function remove-dotagents { update-path -EnvVarName DOTAGENTS_SCRIPTS -Remove }

# alias hygiene (curl/mv/cp/rm/ls/diff/find + vi) lives in common-tools.ps1

# shared: gwt + the common cd* shortcuts (cddev/cdgh/cdnf/cdz/cdo/cdzd/cdew/cdzet)
# live in common-tools.ps1. clint-only navigation shortcuts:
function cdghdov () { cd $env:GH_DOVH }
function cdda () { cd $env:DOTAGENTS }
function cddf () { cd $env:DOTFILES }
function cdop () { cd $env:ON_PATH }

function StartMcpGateway {
    # forwards to the shared launcher in common-tools.ps1 (both accounts have it)
    Write-Host "fyi: running mcp-start-mcp-gateway (shared launcher)" -ForegroundColor DarkGray
    mcp-start-mcp-gateway @args
}

function editsettings() {
  np "C:\Users\clint\AppData\Local\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
}
function vncm1mini {
    & "C:\Program Files (x86)\TigerVNC\vncviewer.exe" -AlwaysCursor -CursorType=System m1mini.vnc.dovanet
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

# Themed prompt lives in common-tools.ps1 (_WtPrompt), shared with the claude account.
function Prompt { _WtPrompt }
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

# Ctrl+d keyhandler lives in common-tools.ps1

# ziti completion powershell | Out-String | Invoke-Expression
add-go_current
add-doxygen
add-dotnet
add-linux_commands
add-dotagents
add-python
add-docker
dedupe-path


. $env:DOTFILES\powershell\wt-themes.ps1
. $env:DOTFILES\powershell\wt-themes-rainbow.ps1
. $env:DOTFILES\powershell\gwt-session-registry.ps1
. $env:DOTFILES\powershell\claude-shell.ps1

# startup nudge: warn if the local MCP gateway isn't running. Process-name check
# (port-agnostic, ~ms). clint-only -- the claude account can't see a gateway
# clint started, so this lives here, not in shared common-tools.
if (-not (Get-Process -Name mcp-gateway -ErrorAction SilentlyContinue)) {
    Write-Host "mcp-gateway not running -- run 'mcp-start-mcp-gateway' to serve MCP tools locally" -ForegroundColor DarkYellow
}


# comment
