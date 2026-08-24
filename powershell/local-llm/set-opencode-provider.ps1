<#
.SYNOPSIS
    Points OpenCode at a llama.cpp server.

.DESCRIPTION
    Run on the workstation, as the account that runs OpenCode.

    This exists as a script rather than a pasted here-string because a here-string terminator only
    closes the block when '@ sits at column zero, and pasting into an indented prompt breaks it.

    The config is built as an object and serialised, so the JSON is valid by construction.

.PARAMETER BaseUrl
    Root of the OpenAI-compatible API. llama-server serves it under /v1.

.PARAMETER ModelId
    Key OpenCode uses for the model. llama.cpp ignores the model name in requests, so this is a label
    rather than a lookup.

.PARAMETER DisplayName
    Name shown in OpenCode's model picker.

.PARAMETER Context
    Must match the server's --ctx-size. A larger number here makes OpenCode build prompts the server
    will truncate mid-thought.

.PARAMETER MaxOutput
    Cap on generated tokens per response.

.PARAMETER Restore
    Restore the config from the .bak file and exit.

.EXAMPLE
    .\set-opencode-provider.ps1

.EXAMPLE
    .\set-opencode-provider.ps1 -BaseUrl http://127.0.0.1:8080/v1 -Context 32768

.EXAMPLE
    .\set-opencode-provider.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$BaseUrl     = 'http://sgx2:8080/v1',
    [string]$ModelId     = 'qwen3-coder-next-80b',
    [string]$DisplayName = 'Qwen3-Coder-Next 80B (sgx2)',
    [int]$Context        = 65536,
    [int]$MaxOutput      = 16384,
    [string]$ProviderId  = 'llamacpp',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$configDir  = Join-Path $env:USERPROFILE '.config\opencode'
$configPath = Join-Path $configDir 'opencode.json'

# Restore has to come after $configPath is assigned, not before it.
if ($Restore) {
    $backup = "$configPath.bak"
    if (-not (Test-Path -LiteralPath $backup)) {
        throw "No backup found at $backup"
    }
    Copy-Item -LiteralPath $backup -Destination $configPath -Force
    Write-Host "Restored $configPath from $backup" -ForegroundColor Green
    return
}

if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

if (Test-Path -LiteralPath $configPath) {
    $backup = "$configPath.bak"
    Copy-Item -LiteralPath $configPath -Destination $backup -Force
    Write-Host "Backed up existing config to $backup" -ForegroundColor DarkGray
}

$config = [ordered]@{
    '$schema' = 'https://opencode.ai/config.json'
    provider  = [ordered]@{
        $ProviderId = [ordered]@{
            npm     = '@ai-sdk/openai-compatible'
            name    = $DisplayName
            options = [ordered]@{ baseURL = $BaseUrl }
            models  = [ordered]@{
                $ModelId = [ordered]@{
                    name  = $DisplayName
                    limit = [ordered]@{ context = $Context; output = $MaxOutput }
                }
            }
        }
    }
}

# ASCII rather than PowerShell 5.1's default UTF8, which prepends a BOM that some JSON parsers read as
# part of the first key.
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding ascii

Write-Host "Wrote $configPath" -ForegroundColor Green
Write-Host ''
Get-Content -LiteralPath $configPath | Write-Host
Write-Host ''

# No reachability probe here on purpose. This script writes a config file; it should not be able to
# hang or warn because of the network. Check the endpoint separately with the command printed below.
$probe = $BaseUrl.TrimEnd('/') + '/models'

Write-Host 'Check the server, then restart OpenCode and pick the model with /models:' -ForegroundColor Cyan
Write-Host "  curl.exe -s -m 5 --ipv4 $probe"
Write-Host ''
