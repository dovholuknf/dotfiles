<#
.SYNOPSIS
    Starts llama-server with the tuned Qwen3-Coder 30B-A3B configuration for this machine.

.DESCRIPTION
    Settings come from a llama-bench sweep on an RTX 4070 Laptop (8GB VRAM, 64GB system RAM):

      --n-cpu-moe 40    Peak of the sweep at 380 t/s prompt, 25 t/s generation. Lower values push
                        expert weights past the VRAM budget, and the Windows driver silently spills
                        to system RAM over PCIe rather than failing. A value of 32 measured 112 t/s
                        prompt, a 3.3x cliff with no error message to explain it.
      --load-mode none  Disables mmap. With experts pinned to the CPU, mmap lets the OS fault expert
                        weights in from disk mid-generation. Loading all 17.7GB up front costs about
                        10 seconds of startup and buys steady throughput.
      --parallel 1      One slot. With the default of 4, consecutive turns land on different slots by
                        LRU and re-process the whole system prompt, which is about 9.7k tokens under
                        OpenCode and takes roughly 21 seconds.
      q8_0 KV cache     An fp16 cache at 32k context would consume the VRAM headroom the experts need.

.PARAMETER CpuMoe
    Expert layers to keep on the CPU. Raise it if generation speed decays over a long response, which
    means the KV cache has pushed the GPU into spilling.

.PARAMETER ContextSize
    Must match the "context" limit in opencode.json. If the harness thinks the window is larger than
    the server's, prompts get truncated mid-thought.

.PARAMETER DryRun
    Print the llama-server command line that would be executed, without actually running it.

.EXAMPLE
    .\start-llm.ps1

.EXAMPLE
    .\start-llm.ps1 -CpuMoe 44 -ContextSize 16384
#>
[CmdletBinding()]
param(
    [string]$ModelPath   = 'D:\models\qwen3-coder-30b\Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf',
    [int]   $CpuMoe      = 40,
    [int]   $ContextSize = 32768,
    [int]   $Port        = 8080,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command llama-server -ErrorAction SilentlyContinue)) {
    throw 'llama-server is not on PATH. Expected it in C:\Users\claude\apps\llama.cpp.'
}

if (-not (Test-Path -LiteralPath $ModelPath)) {
    throw "Model not found: $ModelPath"
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    throw "Port $Port is already in use by PID $($listener.OwningProcess). Stop it first."
}

# An argument array, not a string. A command line built as one string cannot be invoked with & --
# PowerShell looks for an executable whose name is the entire string -- and printing it requires escape
# handling that is easy to get wrong.
$serverArgs = @(
    '--model',        $ModelPath
    '--gpu-layers',   '99'
    '--n-cpu-moe',    $CpuMoe
    '--load-mode',    'none'
    '--cache-type-k', 'q8_0'
    '--cache-type-v', 'q8_0'
    '--ctx-size',     $ContextSize
    '--parallel',     '1'
    '--jinja'
    '--host',         '127.0.0.1'
    '--port',         $Port
)

if ($DryRun) {
    Write-Host 'Would run:' -ForegroundColor Cyan
    Write-Host "llama-server $($serverArgs -join ' ')" -ForegroundColor Gray
    return
}

Write-Host "Qwen3-Coder 30B-A3B  |  n-cpu-moe $CpuMoe  |  ctx $ContextSize  |  http://127.0.0.1:$Port" `
    -ForegroundColor Cyan
Write-Host 'Reading 17.7GB into RAM, roughly 10 seconds before it listens.' -ForegroundColor DarkGray

& llama-server @serverArgs
