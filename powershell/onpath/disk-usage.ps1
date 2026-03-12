param(
    [Parameter(Position = 0)]
    [string]$Path = ".",

    [Parameter(Position = 1)]
    [int]$Depth = 1
)

$Path = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')

function Get-RelativeDepth {
    param(
        [string]$RootPath,
        [string]$FullPath
    )

    $relative = $FullPath.Substring($RootPath.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return 0
    }

    return ($relative -split '\\').Count
}

Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
Where-Object {
    (Get-RelativeDepth -RootPath $Path -FullPath $_.FullName) -eq $Depth
} |
ForEach-Object {
    $size = (
        Get-ChildItem -LiteralPath $_.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    ).Sum

    [PSCustomObject]@{
        Path = $_.FullName
        GB   = [math]::Round(($size / 1GB), 2)
        MB   = [math]::Round(($size / 1MB), 2)
    }
} |
Sort-Object MB -Descending