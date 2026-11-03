# bash style line completion FTW!
Set-PSReadLineKeyHandler -Key Tab -Function Complete



#environment variables
# windows/bootstrap-agent.ps1 sets the path vars as User env vars. The defaults below cover a machine without them.
if (-not $env:GIT_ROOT) { $env:GIT_ROOT = "d:\git" }
$env:GH_ROOT="${env:GIT_ROOT}\github"
$env:BB_ROOT="${env:GIT_ROOT}\bitbucket"
$env:OZ_ROOT="${env:GH_ROOT}\openziti"
$env:BB_DOV_ROOT="${env:BB_ROOT}\dovholuk"
$env:DOTFILES="${env:GH_ROOT}\dovholuknf\dotfiles"
$env:DOTFILES_PWSH="${env:DOTFILES}\powershell"
$env:ON_PATH="${env:DOTFILES_PWSH}\onpath"
$env:ORIG_PATH=$env:PATH
$env:NF_ROOT="${env:OZ_ROOT}\nf"


# user-specific: which Python and which ziti base
$env:PYTHON_HOME    = "$env:LOCALAPPDATA\Programs\Python\Python312"
$env:PYTHON_SCRIPTS = "$env:PYTHON_HOME\Scripts"
$env:ZITI_HOME      = "$env:USERPROFILE\.ziti\bin"
$env:ZITI_DEFAULT   = $env:ZITI_HOME

$env:VS_ROOT = "C:\Program Files\Microsoft Visual Studio\18\Community"
$env:PWSH_BIN = "$env:LOCALAPPDATA\pwsh-7.6.0"

# claude-specific: explicit PATH layout (replaces inherited PATH for predictable shell)
$env:PATH = "$env:PWSH_BIN;" +
            "$env:GIT_BIN;" +
            "C:\Users\claude\.local\bin;" +
            "C:\Users\claude\bin;" +
            "C:\Windows\System32;" +
            "C:\Windows;" +
            "C:\Windows\System32\Wbem;" +
            "C:\Users\claude\AppData\Local\Microsoft\WindowsApps;" +
            "C:\Program Files\GitHub CLI;" +
            "c:\ProgramData\chocolatey\bin"
# prepend dotfiles onpath + bitbucket helper scripts
$env:PATH = "${env:ON_PATH};${env:PATH};$env:BB_DOV_ROOT\dev_stuff\helper-scripts\windows"


# shared helpers + add-/remove- tool toggles
# machine-local secrets (untracked, never committed). Loaded first so tokens/hosts
# are set before the scripts below read them.
$localSecrets = Join-Path $HOME '.profile.secrets.ps1'
if (Test-Path $localSecrets) { . $localSecrets }

. $env:DOTFILES\powershell\shared\common-tools.ps1

# load gwt/wt-themes/claude-shell
. $env:DOTFILES\powershell\wt-themes.ps1
. $env:DOTFILES\powershell\wt-themes-rainbow.ps1
. $env:DOTFILES\powershell\gwt-session-registry.ps1
. $env:DOTFILES\powershell\claude-shell.ps1

# alias hygiene (curl/mv/cp/rm/ls/diff/find + vi) lives in common-tools.ps1
Set-Alias which where.exe

# shared: gwt + the common cd* shortcuts live in common-tools.ps1.
# claude-only navigation shortcuts:
function cddot () { cd $env:DOTFILES }
function cddf () { cd $env:DOTFILES_PWSH }
function cdwt() { cd d:\worktrees }
function ll { ls -tral @args }

#sets the background color of the current pane!
function Set-Bg([string]$Hex) {
  [Console]::Write([char]27 + "]11;$Hex" + [char]7)
}

function prompt { _WtPrompt }

function editterminalsettings() {
  np "C:\Users\clint\AppData\Local\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
}
function editclaudesettings() {
  np "C:\Users\claude\.claude\settings.json"
}

function editprofile() {
  np "$HOME\.profile.ps1"
}

# Ctrl+d keyhandler lives in common-tools.ps1

add-go_current
add-dotnet
add-doxygen
add-linux_commands
add-npm
add-rust
add-docker

$env:PATH="${env:PATH};C:\WINDOWS\System32\OpenSSH"

