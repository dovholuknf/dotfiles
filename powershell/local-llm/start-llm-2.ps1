<#
.SYNOPSIS
    Starts llama-server with optimized Qwen3-Coder 30B-A3B configuration for this machine.

.DESCRIPTION
    Optimized settings based on llama-bench sweep results for RTX 4070 Laptop (8GB VRAM, 64GB system RAM):
    
    --n-cpu-moe 40    Peak performance at 380 t/s prompt, 25 t/s generation. Lower values push
                      expert weights past VRAM budget, with Windows driver silently spilling
                      to system RAM over PCIe without error messages.
    --load-mode none  Disables mmap. With experts pinned to CPU, mmap faults expert weights
                      from disk mid-generation. Loading all 17.7GB upfront costs ~10s startup
                      but provides steady throughput.
    --parallel 1      Single slot. Default of 4 causes consecutive turns to land on different
                      slots by LRU and re-process full system prompt (~9.7k tokens under OpenCode,
                      ~21 seconds).
    q8_0 KV cache     fp16 cache at 32k context would consume VRAM headroom needed by experts.

.PARAMETER ModelPath
    Path to the GGUF model file. Defaults to Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf.

.PARAMETER CpuMoe
    Expert layers to keep on the CPU. Raise if generation speed decays over long responses,
    indicating KV cache pushed GPU into spilling.

.PARAMETER ContextSize
    Must match "context" limit in opencode.json. If harness thinks window is larger than
    server's, prompts get truncated mid-thought.

.PARAMETER Port
    HTTP port to listen on. Defaults to 8080.

.EXAMPLE
    .\start-llm-2.ps1

.EXAMPLE
    .\start-llm-2.ps1 -CpuMoe 44 -ContextSize 16384
#>
[CmdletBinding()]
param(
    [string]$ModelPath   = 'D:\models\qwen3-coder-30B\Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf',
    [int]   $CpuMoe      = 40,
    [int]   $ContextSize = 32768,
    [int]   $Port        = 8080
)

$ErrorActionPreference = 'Stop'

# Validate prerequisites
if (-not (Get-Command llama-server -ErrorAction SilentlyContinue)) {
    throw 'llama-server is not on PATH. Expected it in C:\Users\claude\apps\llama.cpp.'
}

if (-not (Test-Path -LiteralPath $ModelPath)) {
    throw "Model not found: $ModelPath"
}

# Check if port is already in use
try {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
    if ($listener) {
        throw "Port $Port is already in use by PID $($listener.OwningProcess). Stop it first."
    }
} catch {
    # If Get-NetTCPConnection fails, continue without checking
    Write-Warning "Could not check port usage: $_"
}

# Display startup information
Write-Host "Qwen3-Coder 30B-A3B  |  n-cpu-moe $CpuMoe  |  ctx $ContextSize  |  http://127.0.0.1:$Port" `
    -ForegroundColor Cyan
Write-Host 'Reading 17.7GB into RAM, roughly 10 seconds before it listens.' -ForegroundColor DarkGray

# Start the server with optimized parameters
$startTime = Get-Date
$process = Start-Process -FilePath llama-server `
    -ArgumentList @(
        "--model", $ModelPath,
        "--gpu-layers", "99",
        "--n-cpu-moe", $CpuMoe,
        "--load-mode", "none",
        "--cache-type-k", "q8_0",
        "--cache-type-v", "q8_0",
        "--ctx-size", $ContextSize,
        "--parallel", "1",
        "--jinja",
        "--host", "127.0.0.1",
        "--port", $Port
    ) -PassThru -WindowStyle Hidden

# Display process info
$endTime = Get-Date
$duration = $endTime - $startTime
Write-Host "Server started in $($duration.TotalSeconds.ToString('F2')) seconds" -ForegroundColor Green

# Monitor process and display logs
$process | ForEach-Object {
    Write-Host "Process started with PID $($_.Id)" -ForegroundColor Yellow
}