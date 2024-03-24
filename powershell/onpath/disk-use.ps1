# Receive the RootFolder and SortBySize parameters
param (
    [string]$RootFolder,
    [switch]$SortBySize
)

# Get all directories at the specified root folder
$directories = Get-ChildItem -Path $RootFolder -Directory

# Sort directories by total size if SortBySize switch is provided
if ($SortBySize) {
    $directories = $directories | Sort-Object {
        $totalSize = (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $totalSize
    }
}

# Initialize a dictionary to store job ID and corresponding directory
$jobDirectoryMap = @{}

# Initialize an array to store background jobs
$jobs = @()

# Start jobs for each directory
foreach ($directory in $directories) {
    $job = Start-Job -ScriptBlock {
        param($dir)
        $items = Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue
        $size = ($items | Measure-Object -Property Length -Sum).Sum
        $sizeInMB = [Math]::Round($size / 1MB, 2)
        $sizeInGB = [Math]::Round($size / 1GB, 2)
        "$($sizeInGB.ToString().PadLeft(8)) GB`t$($sizeInMB.ToString().PadLeft(8)) MB`t$($dir.FullName)"
    } -ArgumentList $directory
    $jobs += $job
    $jobDirectoryMap[$job.Id] = $directory
}

# Check and display job status while running
while ($jobs.State -contains 'Running') {
    $runningJobs = $jobs | Where-Object { $_.State -eq 'Running' }
    foreach ($job in $runningJobs) {
        $directory = $jobDirectoryMap[$job.Id]
        Write-Host "Still waiting for $($directory.FullName) ..."
    }
    Start-Sleep -Seconds 5
}

# Retrieve and display job results
foreach ($job in $jobs) {
    $result = Receive-Job $job
    Write-Output $result
}

# Cleanup: Remove completed jobs
Remove-Job -Job $jobs
