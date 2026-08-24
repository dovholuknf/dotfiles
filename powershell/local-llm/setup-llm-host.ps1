<#
.SYNOPSIS
    Builds a headless local-LLM host from a fresh Windows machine.

.DESCRIPTION
    Run at the target machine, elevated, as an administrator account that is NOT the service account
    this creates.

    Phases run in order and each one is idempotent, so re-running after a failure or a reboot picks up
    where it left off:

        Account      a passwordless-to-you service account that owns the model server
        Ssh          OpenSSH server, set to start automatically
        Network      confirm the adapter profile lets the firewall rule apply
        Pwsh         PowerShell 7 from the MSI, machine-wide
        Shell        point sshd at pwsh instead of cmd
        Python       Python, pip, and the HuggingFace CLI
        Runtime      llama.cpp, CUDA or Vulkan depending on the GPU
        Model        download a GGUF
        Harden       confine the service account
        Report       print the client-side config and the launch command

    Installing the OpenSSH server requires a reboot before the service exists. The script detects this,
    tells you, and stops. Re-run it after the restart.

.PARAMETER AccountName
    Local account that owns the model server.

.PARAMETER Phase
    Run only these phases. Defaults to all of them, in the order listed above.

.PARAMETER SkipPhase
    Run everything except these.

.PARAMETER ModelRepo
    HuggingFace repo holding the GGUF.

.PARAMETER ModelFile
    Filename within that repo. Downloaded with curl, so no Python or HuggingFace CLI is needed.

.PARAMETER ModelDir
    Where weights land. Defaults to a models folder inside the service account's profile, which is the
    right answer on a single-drive machine.

.PARAMETER CpuMoe
    Expert layers to keep on the CPU, for mixture-of-experts models on a VRAM-limited GPU. Zero means
    do not pass the flag at all, which is correct when the model fits in VRAM.

.PARAMETER ContextSize
    Server context window. The harness config must declare the same number.

.PARAMETER Port
    Port for llama-server.

.PARAMETER AllowPath
    Paths outside the profile the service account must still reach. See the Harden phase.

.PARAMETER AnswerFile
    JSON file supplying any of the settings above, so a second machine can be built without retyping
    them. Keys match parameter names. Anything passed on the command line wins over the file.

.PARAMETER SaveAnswerFile
    Write the settings this run actually used to a JSON file, ready to feed the next machine.

.PARAMETER NonInteractive
    Never prompt. Unsupplied settings take their defaults. Use for unattended runs.

.PARAMETER UpgradeRuntime
    Force reinstallation of the Runtime phase, overwriting any existing llama.cpp install.

.EXAMPLE
    .\setup-llm-host.ps1 -WhatIf

.EXAMPLE
    .\setup-llm-host.ps1
    Prompts for anything not supplied, showing the default in brackets.

.EXAMPLE
    .\setup-llm-host.ps1 -AnswerFile .\evo-x2.json

.EXAMPLE
    .\setup-llm-host.ps1 -SaveAnswerFile .\next-machine.json

.EXAMPLE
    .\setup-llm-host.ps1 -Phase Runtime,Model -NonInteractive

.EXAMPLE
    .\setup-llm-host.ps1 -CpuMoe 0 -ContextSize 65536

.NOTES
    Remote use. Assume every invocation arrives over SSH as an administrator:

        ssh <host> 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File C:\Users\localai\setup-llm-host.ps1 -Phase Runtime,Model -NonInteractive'

    Two things make that work. SSH hands an administrator a filtered token by default, so
    LocalAccountTokenFilterPolicy must be 1 for the session to be elevated. And sshd reads
    C:\ProgramData\ssh\administrators_authorized_keys for any account in Administrators, never that
    account's own ~/.ssh/authorized_keys.

    Only the service account's own work runs as the service account: starting llama-server, running
    llama-bench, anything that proves the hardening did not break its access.

    -NonInteractive belongs on every remote run. There is no console to answer a prompt.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AccountName,

    # No ValidateSet on these two. Invoked over SSH as
    #   powershell.exe -File setup-llm-host.ps1 -Phase Runtime,Model
    # every argument arrives as a single string, so "Runtime,Model" never binds as an array and
    # ValidateSet rejects it. Split and validate in the body instead, which accepts both forms.
    [string[]]$Phase,
    [string[]]$SkipPhase,

    [string]$ModelRepo,
    [string]$ModelFile,
    [string]$ModelDir,

    [int]$CpuMoe,
    [int]$ContextSize,
    [int]$Port,

    [string]$InstallRoot,
    [string[]]$AllowPath,

    [string]$AnswerFile,
    [string]$SaveAnswerFile,
    [switch]$NonInteractive,
    [switch]$UpgradeRuntime
)

$ErrorActionPreference = 'Stop'
$script:RebootNeeded   = $false

# =====================================================================================================
# settings resolution
# =====================================================================================================
# Precedence: command line, then answer file, then prompt, then default.
#
# Parameters are declared without defaults on purpose. A parameter with a default is indistinguishable
# from one the caller supplied that same value for, and the answer file would silently lose to it.
# $PSBoundParameters is the only reliable signal for "the caller actually said this".

$Defaults = [ordered]@{
    AccountName = 'localai'
    Phase       = @('Account','Ssh','Network','Pwsh','Shell','Python','Runtime','Model','Harden','Report')
    SkipPhase   = @()
    ModelRepo   = 'unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF'
    ModelFile   = 'Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf'
    ModelDir    = ''          # derived from AccountName once it is known
    CpuMoe      = 40
    ContextSize = 32768
    Port        = 8080
    InstallRoot = 'C:\apps'
    AllowPath   = @()
}

$Prompts = @{
    AccountName = 'Service account name'
    ModelRepo   = 'HuggingFace repo'
    ModelFile   = 'GGUF filename'
    ModelDir    = 'Model directory (blank = inside the account profile)'
    CpuMoe      = 'Expert layers on CPU (0 = model fits in VRAM)'
    ContextSize = 'Context window'
    Port        = 'llama-server port'
    InstallRoot = 'Install root'
}

$fileAnswers = @{}
if ($AnswerFile) {
    if (-not (Test-Path -LiteralPath $AnswerFile)) { throw "Answer file not found: $AnswerFile" }
    $json = Get-Content -LiteralPath $AnswerFile -Raw | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $fileAnswers[$p.Name] = $p.Value }
    Write-Host "Answers from $AnswerFile" -ForegroundColor DarkGray
}

$Bound = $PSCmdlet.MyInvocation.BoundParameters

function Resolve-Setting {
    param([string]$Name)

    if ($Bound.ContainsKey($Name)) {
        return (Get-Variable -Name $Name -ValueOnly)
    }
    if ($fileAnswers.ContainsKey($Name)) {
        return $fileAnswers[$Name]
    }

    $default = $Defaults[$Name]

    # Only prompt for settings a human would reasonably want to change. Phase and SkipPhase are control
    # flags, not configuration, so they take their defaults silently.
    if (-not $NonInteractive -and $Prompts.ContainsKey($Name)) {
        $shown = if ($default -is [array]) { $default -join ',' } else { $default }
        $reply = Read-Host "  $($Prompts[$Name]) [$shown]"
        if ($reply) {
            if ($default -is [int])   { return [int]$reply }
            if ($default -is [array]) { return @($reply -split '\s*,\s*') }
            return $reply
        }
    }
    return $default
}

if (-not $NonInteractive -and -not $AnswerFile) {
    Write-Host ''
    Write-Host 'Settings -- press Enter to accept the value in brackets' -ForegroundColor White
}

foreach ($name in @($Defaults.Keys)) {
    Set-Variable -Name $name -Value (Resolve-Setting $name) -Scope Script
}

# Accept -Phase Runtime,Model as one string, as an array, or as repeated values.
$ValidPhases = @('Account','Ssh','Network','Pwsh','Shell','Python','Runtime','Model','Harden','Report')

function Expand-PhaseList {
    param([object]$Value, [string]$ParameterName)

    $items = @($Value) | ForEach-Object { "$_" -split '\s*,\s*' } | Where-Object { $_ }
    $bad = $items | Where-Object { $_ -notin $ValidPhases }
    if ($bad) {
        throw "Unknown $ParameterName value(s): $($bad -join ', '). Valid: $($ValidPhases -join ', ')"
    }
    ,@($items)
}

$Phase     = Expand-PhaseList -Value $Phase     -ParameterName 'Phase'
$SkipPhase = Expand-PhaseList -Value $SkipPhase -ParameterName 'SkipPhase'

# =====================================================================================================
# helpers
# =====================================================================================================

function Write-Phase {
    param([string]$Name, [string]$Detail)
    Write-Host ''
    Write-Host "== $Name " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(0, 78 - $Name.Length)) -ForegroundColor DarkCyan
    if ($Detail) { Write-Host "   $Detail" -ForegroundColor DarkGray }
}

function Write-Step { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "   $Message" -ForegroundColor DarkGray }

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Should-Run {
    param([string]$Name)
    ($Phase -contains $Name) -and ($SkipPhase -notcontains $Name)
}

function Get-LatestLlamaTag {
    # Unauthenticated GitHub API allows 60 requests an hour, which is ample for a setup run.
    try {
        $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' `
            -Headers @{ 'User-Agent' = 'setup-llm-host' }
        return $r.tag_name
    } catch {
        throw "Could not reach the llama.cpp releases API: $($_.Exception.Message)"
    }
}

function Get-GpuVendor {
    # nvidia-smi is the reliable signal for a CUDA-capable card. Everything else gets the Vulkan build,
    # which covers AMD (including Strix Halo's integrated Radeon) and Intel without a vendor toolkit.
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { return 'nvidia' }
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Basic Display|Remote Display' } |
        Select-Object -First 1
    if ($gpu.Name -match 'NVIDIA|GeForce|RTX|Quadro') { return 'nvidia' }
    return 'other'
}

if (-not (Test-Elevated)) {
    throw 'Run this from an elevated shell.'
}

if (-not $ModelDir) {
    $ModelDir = Join-Path (Join-Path (Split-Path -Parent $env:USERPROFILE) $AccountName) 'models'
}

$llamaDir = Join-Path $InstallRoot 'llama.cpp'

if ($SaveAnswerFile) {
    $snapshot = [ordered]@{}
    foreach ($name in @($Defaults.Keys)) {
        $snapshot[$name] = Get-Variable -Name $name -ValueOnly
    }
    $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SaveAnswerFile -Encoding utf8
    Write-Host "Settings written to $SaveAnswerFile" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host "Local LLM host setup on $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  account      $AccountName"
Write-Host "  runtime      $llamaDir"
Write-Host "  models       $ModelDir"
Write-Host "  phases       $($Phase -join ', ')"

# =====================================================================================================
# Account
# =====================================================================================================

if (Should-Run 'Account') {
    Write-Phase 'Account' "local service account that owns the model server"

    if (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) {
        Write-Skip "$AccountName already exists"
    } elseif ($PSCmdlet.ShouldProcess($AccountName, 'create local account')) {
        $pw = Read-Host -AsSecureString -Prompt "Password for $AccountName"
        New-LocalUser -Name $AccountName -Password $pw `
            -FullName 'Local AI' -Description 'Runs local LLM server' -PasswordNeverExpires | Out-Null
        Write-Step "created $AccountName"
    }

    # New-LocalUser leaves the account out of every group. It still logs in and still has Users-level
    # access, because the Users group contains NT AUTHORITY\Authenticated Users. Nothing to add here;
    # the Harden phase relies on file permissions rather than group membership for exactly this reason.
}

# =====================================================================================================
# Ssh
# =====================================================================================================

if (Should-Run 'Ssh') {
    Write-Phase 'Ssh' 'OpenSSH server, automatic start'

    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' |
        Select-Object -First 1

    if ($cap.State -ne 'Installed') {
        if ($PSCmdlet.ShouldProcess('OpenSSH.Server', 'install Windows capability')) {
            Write-Host '   fetching from Windows Update, this takes minutes on a fresh machine' -ForegroundColor DarkGray
            $result = Add-WindowsCapability -Online -Name $cap.Name
            Write-Step 'installed OpenSSH server'
            if ($result.RestartNeeded) { $script:RebootNeeded = $true }
        }
    } else {
        Write-Skip 'OpenSSH server already installed'
    }

    # The service is not registered until the machine restarts, so Start-Service fails with a
    # not-found error that looks like the install did nothing.
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        $script:RebootNeeded = $true
    } else {
        if ($svc.Status -ne 'Running' -and $PSCmdlet.ShouldProcess('sshd', 'start')) {
            Start-Service sshd
            Write-Step 'started sshd'
        }
        if ($svc.StartType -ne 'Automatic' -and $PSCmdlet.ShouldProcess('sshd', 'set automatic start')) {
            Set-Service sshd -StartupType Automatic
            Write-Step 'sshd set to start automatically'
        }
        if ($svc.Status -eq 'Running' -and $svc.StartType -eq 'Automatic') {
            Write-Skip 'sshd running and automatic'
        }
    }

    if ($script:RebootNeeded) {
        Write-Host ''
        Write-Warning 'Reboot required before the sshd service exists. Restart, then run this script again.'
        Write-Host '   Restart-Computer' -ForegroundColor Yellow
        return
    }
}

# =====================================================================================================
# Network
# =====================================================================================================

if (Should-Run 'Network') {
    Write-Phase 'Network' 'firewall rule and adapter profile'

    $rule = Get-NetFirewallRule -Name *OpenSSH-Server* -ErrorAction SilentlyContinue
    if (-not $rule) {
        if ($PSCmdlet.ShouldProcess('OpenSSH-Server-In-TCP', 'create firewall rule')) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
                -Profile Private, Domain | Out-Null
            Write-Step 'created inbound rule for port 22'
        }
    } else {
        Write-Skip "firewall rule present: $($rule.Name), profile $($rule.Profile)"
    }

    # An enabled rule scoped to Private does nothing while the adapter is classified Public. The
    # connection times out, which is indistinguishable from the service being down.
    foreach ($p in Get-NetConnectionProfile) {
        if ($p.NetworkCategory -eq 'Public') {
            Write-Warning "   $($p.InterfaceAlias) is classified Public; the SSH rule will not apply"
            if ($PSCmdlet.ShouldProcess($p.InterfaceAlias, 'set network category to Private')) {
                Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
                Write-Step "$($p.InterfaceAlias) set to Private"
            }
        } else {
            Write-Skip "$($p.InterfaceAlias) is $($p.NetworkCategory)"
        }
    }

    $ips = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.254\.' }
    foreach ($ip in $ips) {
        Write-Host "   reachable at $($ip.IPAddress) on $($ip.InterfaceAlias)" -ForegroundColor White
    }
}

# =====================================================================================================
# Pwsh
# =====================================================================================================

if (Should-Run 'Pwsh') {
    Write-Phase 'Pwsh' 'PowerShell 7, machine-wide'

    $pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'

    if (Test-Path -LiteralPath $pwshPath) {
        Write-Skip 'PowerShell 7 already installed'
    } elseif ($PSCmdlet.ShouldProcess('PowerShell 7', 'install from MSI')) {

        # winget installs the MSIX package, which lands as a per-user app-execution alias under
        # WindowsApps: a zero-byte reparse point that only resolves in the owning user's context, and
        # therefore useless as a machine-wide SSH shell. The MSI is the only reliable route.
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' `
            -Headers @{ 'User-Agent' = 'setup-llm-host' }
        $asset = $rel.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1
        if (-not $asset) { throw 'No win-x64 MSI in the latest PowerShell release.' }

        $msi = Join-Path $env:TEMP $asset.name
        Write-Host "   downloading $($asset.name)" -ForegroundColor DarkGray
        & curl.exe -L -s -o $msi $asset.browser_download_url

        Write-Host '   installing' -ForegroundColor DarkGray
        # /qn returns immediately while the install continues, so wait for the process.
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn ADD_PATH=1" -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "msiexec exited $($p.ExitCode)" }

        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        Write-Step 'installed PowerShell 7'
    }
}

# =====================================================================================================
# Shell
# =====================================================================================================

if (Should-Run 'Shell') {
    Write-Phase 'Shell' 'sshd default shell'

    $pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $target = if (Test-Path -LiteralPath $pwshPath) {
        $pwshPath
    } else {
        Write-Warning '   PowerShell 7 missing; falling back to Windows PowerShell'
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    $current = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
    if ($current -eq $target) {
        Write-Skip "default shell already $target"
    } elseif ($PSCmdlet.ShouldProcess('HKLM:\SOFTWARE\OpenSSH\DefaultShell', "set to $target")) {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
            -Value $target -PropertyType String -Force | Out-Null
        Write-Step "default shell set to $target"
    }
}

# =====================================================================================================
# Python
# =====================================================================================================

if (Should-Run 'Python') {
    Write-Phase 'Python' 'Python, pip, and the HuggingFace CLI'

    # The CLI is what makes model downloads bearable. HuggingFace serves these repos through Xet
    # storage, which the CLI pulls in parallel chunks; a single curl stream gets a fraction of the
    # throughput and degrades over a long transfer. Same file, same network: roughly 250 MB/s via hf
    # against 14 MB/s and falling via curl, which is the difference between ten minutes and two hours.

    # The installer records where it landed under HKLM:\SOFTWARE\Python\PythonCore, which beats
    # guessing a directory name. Falls back to a Program Files probe and finally to PATH, skipping the
    # WindowsApps entry: that is an App Execution Alias that opens the Store rather than running
    # anything.
    function Resolve-PythonExe {
        foreach ($hive in 'HKLM:\SOFTWARE\Python\PythonCore',
                          'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore',
                          'HKCU:\SOFTWARE\Python\PythonCore') {
            $hit = Get-ItemProperty "$hive\*\InstallPath" -ErrorAction SilentlyContinue |
                Where-Object { $_.ExecutablePath -and (Test-Path -LiteralPath $_.ExecutablePath) } |
                Select-Object -First 1
            if ($hit) { return $hit.ExecutablePath }
        }

        $probe = Get-ChildItem 'C:\Program Files\Python3*' -Filter python.exe -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($probe) { return $probe.FullName }

        $cmd = Get-Command python -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notmatch 'WindowsApps' } |
            Select-Object -First 1
        if ($cmd) { return $cmd.Source }

        return $null
    }

    if (Get-Command hf -ErrorAction SilentlyContinue) {
        Write-Skip 'hf CLI already present'
    } else {

        $pythonExe = Resolve-PythonExe

        if (-not $pythonExe -and $PSCmdlet.ShouldProcess('Python', 'install from python.org')) {

            # Direct from python.org rather than winget. A bare `python` on a fresh Windows install is
            # an App Execution Alias that opens the Store instead of running anything, and winget's
            # Python package has resolved to per-user MSIX installs that are invisible to other
            # accounts. The official installer with InstallAllUsers=1 avoids both.
            $pyVersion = '3.14.7'
            $url = "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-amd64.exe"
            $exe = Join-Path $env:TEMP "python-$pyVersion-amd64.exe"

            Write-Host "   downloading Python $pyVersion" -ForegroundColor DarkGray
            & curl.exe -L -s -o $exe $url
            if ($LASTEXITCODE -ne 0) { throw "curl exited $LASTEXITCODE downloading Python." }

            Write-Host '   installing' -ForegroundColor DarkGray
            $installArgs = '/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1 Include_launcher=1'
            $p = Start-Process $exe -ArgumentList $installArgs -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "Python installer exited $($p.ExitCode)" }
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue

            # The bootstrapper returns exit 0 while the real install continues in a child process, so
            # checking immediately finds nothing. Poll rather than assume either outcome.
            $deadline = (Get-Date).AddMinutes(3)
            while (-not $pythonExe -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 5
                $pythonExe = Resolve-PythonExe
            }

            if (-not $pythonExe) {
                throw "Python installer reported success but no interpreter appeared within 3 minutes. Check C:\Program Files for a Python directory and re-run -Phase Python."
            }
            Write-Step "installed Python $pyVersion at $pythonExe"
        }

        if ($pythonExe -and $PSCmdlet.ShouldProcess('huggingface_hub[cli]', 'install')) {

            # PrependPath only affects new processes, so this session calls the interpreter directly.
            & $pythonExe -m pip install --upgrade pip --quiet

            # huggingface-hub 1.x ships the CLI in the base package; the old [cli] extra no longer
            # exists and only produces a warning. hf_xet is the part that matters: without it the
            # client falls back to plain HTTP and loses the parallel chunked transfer that makes this
            # worth installing at all.
            & $pythonExe -m pip install --upgrade huggingface_hub hf_xet --quiet
            if ($LASTEXITCODE -ne 0) { throw "pip exited $LASTEXITCODE installing huggingface_hub." }

            # hf.exe lands in the Scripts directory beside the interpreter. Put it on the machine PATH
            # so the service account gets it too.
            $scripts = Join-Path (Split-Path -Parent $pythonExe) 'Scripts'
            $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
            if ($machinePath -notlike "*$scripts*") {
                [Environment]::SetEnvironmentVariable('PATH', "$scripts;$machinePath", 'Machine')
            }
            $env:PATH = "$scripts;$env:PATH"

            # Raises Xet's concurrency and buffer sizes. Off by default because it costs memory; on a
            # model host with tens of GB spare that is the right trade. Machine scope so the service
            # account inherits it.
            [Environment]::SetEnvironmentVariable('HF_XET_HIGH_PERFORMANCE', '1', 'Machine')
            $env:HF_XET_HIGH_PERFORMANCE = '1'

            Write-Step "installed hf CLI to $scripts"
        }
    }
}

# =====================================================================================================
# Runtime
# =====================================================================================================

if (Should-Run 'Runtime') {
    Write-Phase 'Runtime' 'llama.cpp'

    $runtimeExists = Test-Path (Join-Path $llamaDir 'llama-server.exe')
    $forceReinstall = $UpgradeRuntime -and $runtimeExists

    if ($runtimeExists -and -not $forceReinstall) {
        Write-Skip "llama-server already present in $llamaDir"
    } elseif ($PSCmdlet.ShouldProcess($llamaDir, 'install llama.cpp')) {

        $vendor = Get-GpuVendor
        $tag    = Get-LatestLlamaTag
        Write-Host "   release $tag, GPU vendor $vendor" -ForegroundColor DarkGray

        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$tag" `
            -Headers @{ 'User-Agent' = 'setup-llm-host' }

        # Vulkan covers AMD and Intel without a vendor toolkit; CUDA is worth the extra cudart download
        # only on NVIDIA. The cudart DLLs must unpack into the same directory as the executables.
        $wanted = if ($vendor -eq 'nvidia') { 'bin-win-cuda-\d+\.\d+-x64\.zip$' } else { 'bin-win-vulkan-x64\.zip$' }

        $main = $rel.assets | Where-Object { $_.name -match $wanted } |
            Sort-Object name -Descending | Select-Object -First 1
        if (-not $main) { throw "No asset matching $wanted in release $tag." }

        $assets = @($main)
        if ($vendor -eq 'nvidia') {
            $cudaVer = [regex]::Match($main.name, 'cuda-(\d+\.\d+)').Groups[1].Value
            $cudart = $rel.assets | Where-Object { $_.name -match "cudart-.*cuda-$([regex]::Escape($cudaVer))-x64\.zip$" } |
                Select-Object -First 1
            if ($cudart) { $assets += $cudart }
        }

        if ($forceReinstall) {
            Write-Host "   forcing reinstall of existing installation" -ForegroundColor DarkGray
            Remove-Item -LiteralPath $llamaDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        New-Item -ItemType Directory -Path $llamaDir -Force | Out-Null
        foreach ($a in $assets) {
            $zip = Join-Path $env:TEMP $a.name
            Write-Host "   downloading $($a.name)" -ForegroundColor DarkGray
            & curl.exe -L -s -o $zip $a.browser_download_url
            Expand-Archive -LiteralPath $zip -DestinationPath $llamaDir -Force
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
        Write-Step "installed llama.cpp to $llamaDir"
    }

    # Machine-wide PATH so the service account gets it too.
    $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    if ($machinePath -notlike "*$llamaDir*") {
        if ($PSCmdlet.ShouldProcess('machine PATH', "add $llamaDir")) {
            [Environment]::SetEnvironmentVariable('PATH', "$llamaDir;$machinePath", 'Machine')
            $env:PATH = "$llamaDir;$env:PATH"
            Write-Step 'added to machine PATH'
        }
    } else {
        Write-Skip 'already on machine PATH'
    }

    # --version does not prove the GPU backend loaded; --list-devices does.
    $exe = Join-Path $llamaDir 'llama-server.exe'
    if (Test-Path -LiteralPath $exe) {
        Write-Host '   devices:' -ForegroundColor DarkGray
        & $exe --list-devices 2>&1 | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
    }
}

# =====================================================================================================
# Model
# =====================================================================================================

if (Should-Run 'Model') {
    Write-Phase 'Model' "$ModelRepo"

    $dest = Join-Path $ModelDir $ModelFile

    if (Test-Path -LiteralPath $dest) {
        $gb = [Math]::Round((Get-Item -LiteralPath $dest).Length / 1GB, 2)
        Write-Skip "already downloaded ($gb GB)"
    } elseif ($PSCmdlet.ShouldProcess($ModelFile, 'download')) {
        New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null

        $free = [Math]::Round(((Get-PSDrive ([IO.Path]::GetPathRoot($ModelDir).TrimEnd('\:'))).Free) / 1GB, 1)
        Write-Host "   $free GB free on the target drive" -ForegroundColor DarkGray

        Write-Host '   downloading, this is tens of GB' -ForegroundColor DarkGray

        # Prefer the HuggingFace CLI when it is present. These repos are served through Xet storage,
        # which the CLI pulls in parallel chunks; a single curl stream gets a fraction of the
        # throughput and degrades over a long transfer. Measured on the same file and network:
        # roughly 250 MB/s via hf against 14 MB/s and falling via curl.
        $hf = Get-Command hf -ErrorAction SilentlyContinue

        if ($hf) {
            & hf download $ModelRepo --include $ModelFile --local-dir $ModelDir
            if ($LASTEXITCODE -ne 0) { throw "hf exited $LASTEXITCODE downloading the model." }
        } else {
            Write-Host '   hf CLI not found, falling back to curl (slower)' -ForegroundColor DarkGray
            Write-Host '   install it with: pip install -U "huggingface_hub[cli]"' -ForegroundColor DarkGray
            $url = "https://huggingface.co/$ModelRepo/resolve/main/$ModelFile"
            # -C - resumes a partial file rather than starting over.
            & curl.exe -L -C - -o $dest $url
            if ($LASTEXITCODE -ne 0) { throw "curl exited $LASTEXITCODE downloading the model." }
        }

        Write-Step "downloaded to $dest"
    }

    # The service account must be able to read its own models even though the file was written by an
    # administrator.
    if (Test-Path -LiteralPath $ModelDir) {
        & icacls $ModelDir /grant "${AccountName}:(OI)(CI)(RX)" 2>$null | Out-Null
    }
}

# =====================================================================================================
# Harden
# =====================================================================================================

if (Should-Run 'Harden') {
    Write-Phase 'Harden' "confine $AccountName"

    # Ceiling, so nobody mistakes this for a sandbox: the account needs read and execute on C:\Windows
    # and C:\Program Files to run a shell at all, so it can always read those. Windows OpenSSH's
    # ChrootDirectory covers SFTP only. This constrains a well-behaved process; it does not contain a
    # hostile one. Use a VM or a Hyper-V container when the boundary has to hold.

    $user = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Warning "   $AccountName does not exist, skipping"
    } else {
        $sid        = $user.SID.Value
        $systemRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
        $usersRoot  = Split-Path -Parent $env:USERPROFILE

        # Groups. Get-LocalGroupMember throws for a whole group containing any unresolvable SID, which
        # is common on an OEM image, so failures fall back to net localgroup rather than being ignored.
        foreach ($group in Get-LocalGroup) {
            $inGroup = $false
            try {
                $inGroup = [bool]((Get-LocalGroupMember -Group $group.Name -ErrorAction Stop) |
                    Where-Object { $_.SID.Value -eq $sid })
            } catch {
                $raw = & net localgroup $group.Name 2>$null
                $inGroup = [bool]($raw | Where-Object {
                    $_.Trim() -ieq $AccountName -or $_.Trim() -ieq "$env:COMPUTERNAME\$AccountName" })
            }
            if ($inGroup -and $group.Name -ne 'Users') {
                Write-Warning "   member of $($group.Name)"
                if ($PSCmdlet.ShouldProcess($AccountName, "remove from $($group.Name)")) {
                    Remove-LocalGroupMember -Group $group.Name -Member $AccountName -ErrorAction Continue
                    Write-Step "removed from $($group.Name)"
                }
            }
        }

        # Non-system fixed drives. A freshly formatted data drive grants Users full control at its root,
        # inherited all the way down. This is the largest hole on any machine that has one.
        # [IO.DriveInfo] rather than Get-CimInstance: the CIM module autoload prints an alias line per
        # cmdlet under -WhatIf and buries everything else.
        $others = [IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_.Name -ne $systemRoot }
        foreach ($d in $others) {
            if ($PSCmdlet.ShouldProcess($d.Name, "deny all access to $AccountName")) {
                & icacls $d.Name /deny "${AccountName}:(OI)(CI)(F)" | Out-Null
                Write-Step "denied $($d.Name)"
            }
        }
        if (-not $others) { Write-Skip 'no non-system fixed drives' }

        # Other profiles. Default ACLs already cover this; an explicit deny survives a parent folder
        # being loosened later. Public is left alone: installers write there and it holds nothing.
        Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @($AccountName, 'Public', 'Default', 'All Users', 'Default User') } |
            ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, "deny all access to $AccountName")) {
                    & icacls $_.FullName /deny "${AccountName}:(OI)(CI)(F)" 2>$null | Out-Null
                    Write-Step "denied $($_.FullName)"
                }
            }

        # ProgramData: several subtrees grant Users write, which is a persistence path. Read has to stay
        # or shell startup breaks.
        if ($PSCmdlet.ShouldProcess($env:ProgramData, "deny write to $AccountName")) {
            & icacls $env:ProgramData /deny "${AccountName}:(OI)(CI)(W)" | Out-Null
            Write-Step "denied write to $env:ProgramData"
        }

        # Re-open anything the account genuinely needs. A deny at a drive root beats an allow further
        # down, so each ancestor gets traversal.
        foreach ($p in $AllowPath) {
            if (-not (Test-Path -LiteralPath $p)) { Write-Warning "   missing: $p"; continue }
            $full = (Resolve-Path -LiteralPath $p).Path
            $chain = @()
            $cur = Split-Path -Parent $full
            while ($cur) {
                $chain += $cur
                $parent = Split-Path -Parent $cur
                if ($parent -eq $cur) { break }
                $cur = $parent
            }
            foreach ($a in ($chain | Sort-Object Length)) {
                & icacls $a /remove:d $AccountName 2>$null | Out-Null
                & icacls $a /grant "${AccountName}:(RX)" 2>$null | Out-Null
            }
            & icacls $full /remove:d $AccountName 2>$null | Out-Null
            & icacls $full /grant "${AccountName}:(OI)(CI)(M)" | Out-Null
            Write-Step "granted $full"
        }
    }
}

# =====================================================================================================
# Report
# =====================================================================================================

if (Should-Run 'Report') {
    Write-Phase 'Report' 'client-side setup'

    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.254\.' } |
        Select-Object -First 1).IPAddress
    $mdns = "$($env:COMPUTERNAME.ToLower()).local"
    $modelPath = Join-Path $ModelDir $ModelFile

    $moeFlag = if ($CpuMoe -gt 0) { " --n-cpu-moe $CpuMoe" } else { '' }

    Write-Host ''
    Write-Host 'On the workstation, add to ~/.ssh/config:' -ForegroundColor White
    Write-Host @"

    Host $($env:COMPUTERNAME.ToLower())
        HostName $mdns
        User $AccountName
        AddressFamily inet
        IdentityFile ~/.ssh/id_ed25519
        IdentitiesOnly yes

"@ -ForegroundColor Gray

    Write-Host '  AddressFamily inet forces IPv4. mDNS answers a .local name with link-local IPv6' -ForegroundColor DarkGray
    Write-Host '  addresses ahead of the A record, and those do not route off the host.' -ForegroundColor DarkGray
    Write-Host '  IdentitiesOnly yes stops a wildcard Host * block from supplying the wrong key.' -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Install the public key:' -ForegroundColor White
    Write-Host "    `$key = (Get-Content `"`$env:USERPROFILE\.ssh\id_ed25519.pub`" -Raw).Trim()" -ForegroundColor Gray
    Write-Host "    ssh $AccountName@$ip `"mkdir .ssh & echo `$key >> .ssh\authorized_keys`"" -ForegroundColor Gray
    Write-Host '  .Trim() matters: a trailing newline splits the remote command and writes nothing.' -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Start the server:' -ForegroundColor White
    Write-Host @"
    llama-server --model "$modelPath" ``
      --gpu-layers 99$moeFlag --load-mode none ``
      --cache-type-k q8_0 --cache-type-v q8_0 ``
      --ctx-size $ContextSize --parallel 1 --jinja ``
      --host 0.0.0.0 --port $Port
"@ -ForegroundColor Gray

    Write-Host ''
    Write-Host 'Harness config, %USERPROFILE%\.config\opencode\opencode.json on the workstation:' -ForegroundColor White
    Write-Host @"
    {
      "`$schema": "https://opencode.ai/config.json",
      "provider": {
        "llamacpp": {
          "npm": "@ai-sdk/openai-compatible",
          "options": { "baseURL": "http://${ip}:$Port/v1" },
          "models": { "local": { "limit": { "context": $ContextSize, "output": 8192 } } }
        }
      }
    }
"@ -ForegroundColor Gray
    Write-Host "  context must equal the server's --ctx-size or prompts get truncated mid-thought." -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Remaining by hand:' -ForegroundColor Yellow
    Write-Host '  - open port ' -NoNewline; Write-Host $Port -NoNewline -ForegroundColor White
    Write-Host ' in the firewall if the harness runs off-box'
    Write-Host '  - tune --n-cpu-moe with llama-bench if this is a VRAM-limited GPU'
    Write-Host '  - BIOS GPU memory split, on unified-memory hardware'
    Write-Host ''
}
