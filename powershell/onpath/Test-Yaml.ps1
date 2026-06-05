# Test-Yaml.ps1 -- validate one or more YAML files. Exit 0 if all parse, exit 1
# otherwise with a one-line summary per file. Lets agents check a YAML without
# resorting to node -e / python -c oneliners (which the PreToolUse hook blocks).
#
# Usage:
#   Test-Yaml.ps1 path\to\file.yml
#   Test-Yaml.ps1 a.yml b.yaml c.yml
#   gci -r *.yml | Test-Yaml.ps1
#
# Prefers `yq` (a single-binary YAML processor) if on PATH; falls back to the
# powershell-yaml module if installed; falls back to python's PyYAML; finally
# tells you to install one of them.
[CmdletBinding()]
param(
    [Parameter(Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [Alias('FullName')]
    [string[]]$Path
)

begin {
    $files = @()
    $checker = $null
    $checkerName = ''
    if (Get-Command yq -ErrorAction SilentlyContinue) {
        $checker = { param($p) & yq 'true' $p 2>&1 | Out-Null; $LASTEXITCODE }
        $checkerName = 'yq'
    } elseif (Get-Module -ListAvailable -Name powershell-yaml) {
        Import-Module powershell-yaml -ErrorAction Stop
        $checker = {
            param($p)
            try {
                $null = ConvertFrom-Yaml (Get-Content -Raw -LiteralPath $p) -ErrorAction Stop
                return 0
            } catch {
                Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
                return 1
            }
        }
        $checkerName = 'powershell-yaml'
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        $checker = {
            param($p)
            $err = & python -c "import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))" $p 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Host "  $err" -ForegroundColor Yellow }
            return $LASTEXITCODE
        }
        $checkerName = 'python+PyYAML'
    } else {
        Write-Host "no YAML validator available. install one of:" -ForegroundColor Red
        Write-Host "  winget install MikeFarah.yq" -ForegroundColor Yellow
        Write-Host "  Install-Module powershell-yaml" -ForegroundColor Yellow
        Write-Host "  pip install pyyaml" -ForegroundColor Yellow
        exit 2
    }
}

process { foreach ($p in $Path) { $files += $p } }

end {
    if (-not $files) {
        Write-Host "usage: Test-Yaml.ps1 <path> [<path>...]" -ForegroundColor Yellow
        exit 2
    }
    $failed = 0
    foreach ($p in $files) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Host "MISSING  $p" -ForegroundColor Red
            $failed++
            continue
        }
        $rc = & $checker $p
        if ($rc -eq 0) {
            Write-Host "OK       $p" -ForegroundColor Green
        } else {
            Write-Host "INVALID  $p" -ForegroundColor Red
            $failed++
        }
    }
    Write-Host "(checker: $checkerName)" -ForegroundColor DarkGray
    if ($failed -gt 0) { exit 1 } else { exit 0 }
}
