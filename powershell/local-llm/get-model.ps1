<#
.SYNOPSIS
    Downloads a GGUF model from HuggingFace and reports what landed.

.DESCRIPTION
    Run on the model host, as the account that owns the models directory.

    Uses the HuggingFace CLI when present, because these repos are served through Xet storage and the
    CLI pulls chunks in parallel. A single curl stream gets a fraction of the throughput and degrades
    over a long transfer. Falls back to curl when the CLI is missing, which requires an exact filename
    rather than a pattern.

    Progress reporting is the reason this exists as a script rather than a one-liner. Run over SSH
    there is no TTY, so Python buffers its output and the transfer looks frozen at 0% for minutes at a
    time. PYTHONUNBUFFERED and HF_HUB_DISABLE_PROGRESS_BARS are set here so output arrives as it
    happens.

.PARAMETER Repo
    HuggingFace repo id.

.PARAMETER Include
    Filename or glob to fetch. A glob is the safer choice for large quants, which are often split into
    several part files whose exact names are hard to predict.

.PARAMETER Dest
    Directory to download into. Created if missing.

.PARAMETER Token
    HuggingFace token, for gated repos. Omit for public ones.

.PARAMETER Force
    Re-download even when destination already contains matching .gguf files.

.EXAMPLE
    .\get-model.ps1

.EXAMPLE
    .\get-model.ps1 -Repo unsloth/Qwen3-Coder-Next-GGUF -Include "*UD-Q4_K_XL*"

.EXAMPLE
    .\get-model.ps1 -Repo unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF -Include "*UD-Q4_K_XL*" -Dest D:\models\qwen3-30b
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Include,
    [string]$Dest,
    [string]$Token,
    [switch]$NonInteractive,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------------------------------
# settings
# -------------------------------------------------------------------------------------------------

$Defaults = [ordered]@{
    Repo    = 'unsloth/Qwen3-Coder-Next-GGUF'
    Include = '*UD-Q4_K_XL*'
    Dest    = 'C:\Users\localai\models\qwen3-coder-next'
}

$Bound = $PSCmdlet.MyInvocation.BoundParameters

foreach ($name in @($Defaults.Keys)) {
    if ($Bound.ContainsKey($name)) { continue }
    $value = $Defaults[$name]
    if (-not $NonInteractive) {
        $reply = Read-Host "  $name [$value]"
        if ($reply) { $value = $reply }
    }
    Set-Variable -Name $name -Value $value -Scope Script
}

# -------------------------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
}

# If Force is specified, remove existing .gguf files
if ($Force) {
    Write-Host 'Force switch specified. Removing existing .gguf files.' -ForegroundColor Yellow
    Get-ChildItem -LiteralPath $Dest -Filter *.gguf -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

$drive = [IO.Path]::GetPathRoot($Dest).TrimEnd('\:')
$freeGB = [Math]::Round((Get-PSDrive $drive).Free / 1GB, 1)

Write-Host ''
Write-Host "Repo     $Repo"
Write-Host "Include  $Include"
Write-Host "Dest     $Dest"
Write-Host "Free     $freeGB GB on ${drive}:"
Write-Host ''

# Without these the transfer looks frozen at 0% over SSH: no TTY means Python block-buffers stdout and
# tqdm holds its bar until the buffer flushes, which on a 50GB download can be many minutes.
$env:PYTHONUNBUFFERED             = '1'
$env:HF_HUB_DISABLE_PROGRESS_BARS = '0'
$env:HF_XET_HIGH_PERFORMANCE      = '1'
if ($Token) { $env:HF_TOKEN = $Token }

$hf = Get-Command hf -ErrorAction SilentlyContinue
if (-not $hf) {
    # The CLI installs beside the interpreter; a session started before the PATH change will not see it.
    $probe = Get-ChildItem 'C:\Program Files\Python3*\Scripts' -Filter hf.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($probe) { $hf = @{ Source = $probe.FullName } }
}

$started = Get-Date

if ($hf) {
    Write-Host "Downloading with $($hf.Source)" -ForegroundColor Cyan
    Write-Host ''

    $hfArgs = @('download', $Repo, '--include', $Include, '--local-dir', $Dest)
    & $hf.Source @hfArgs
    if ($LASTEXITCODE -ne 0) { throw "hf exited $LASTEXITCODE" }

} else {
    Write-Warning 'hf CLI not found; falling back to curl.'
    if ($Include -match '[*?]') {
        throw "curl cannot expand a pattern. Re-run with an exact filename for -Include, or install the CLI: pip install -U huggingface_hub hf_xet"
    }
    $url  = "https://huggingface.co/$Repo/resolve/main/$Include"
    $file = Join-Path $Dest $Include
    Write-Host "Downloading with curl (slower)" -ForegroundColor Cyan
    & curl.exe -L -C - -o $file $url
    if ($LASTEXITCODE -ne 0) { throw "curl exited $LASTEXITCODE" }
}

$elapsed = (Get-Date) - $started

# -------------------------------------------------------------------------------------------------
# report
# -------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host ("Done in {0:hh\:mm\:ss}" -f $elapsed) -ForegroundColor Green
Write-Host ''

$files = Get-ChildItem -LiteralPath $Dest -Filter *.gguf -File -ErrorAction SilentlyContinue |
    Sort-Object Name

if (-not $files) {
    Write-Warning "No .gguf files in $Dest -- check the repo and pattern."
    return
}

$files | Select-Object Name, @{ N = 'GB'; E = { [Math]::Round($_.Length / 1GB, 1) } } | Format-Table -AutoSize

$total = [Math]::Round(($files | Measure-Object Length -Sum).Sum / 1GB, 1)
Write-Host "Total $total GB"
Write-Host ''

# A split quant arrives as -00001-of-0000N. llama.cpp wants the first part; it finds the rest itself.
$first = $files | Where-Object { $_.Name -match '-00001-of-\d+\.gguf$' } | Select-Object -First 1
if (-not $first) { $first = $files | Select-Object -First 1 }

Write-Host 'Bench it:' -ForegroundColor Cyan
Write-Host "  C:\apps\llama.cpp\llama-bench.exe -m `"$($first.FullName)`" -ngl 99 -p 4096 -n 128 -r 3"
Write-Host ''
