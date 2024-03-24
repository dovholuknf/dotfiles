# Receive the RootFolder and SortBySize parameters
param (
    [string]$RootFolder,
    [switch]$SortByName,
    [switch]$SortBySize
)

function Get-FolderSize($Folder) {
    # Get all files in the specified subfolder and its immediate subdirectories (up to depth 1), including hidden files, and calculate their total size
    $subFolderFiles = Get-ChildItem -Path $Folder -Recurse -Force -File

    # Measure the total size of the files using the 'Length' property and sum them up
    $sizeMeasurements = $subFolderFiles | Measure-Object -Property Length -Sum

    # Select only the 'Sum' property from the measurements
    $sumSize = $sizeMeasurements | Select-Object -ExpandProperty Sum

    # Calculate size in MB and GB
    $sizeMB = [Math]::Round($sumSize / 1MB, 2)
    $sizeGB = [Math]::Round($sumSize / 1GB, 2)

    # Create and return an object with the desired output
    [PSCustomObject]@{
        Folder = $Folder
        SizeGB = $sizeGB
        SizeMB = $sizeMB
    }
}

# Get all subfolders in the specified folder and sort them
$subfolders = Get-ChildItem $RootFolder -Directory | Sort-Object

$sizes = @()
# Iterate over each subfolder
foreach ($folderItem in $subfolders) {
	$sizes += Get-FolderSize $folderItem
}

if ($SortByName) {
	$sizes
} elseif ($SortBySize) {
    $sizes | Sort-Object -Property SizeMB
} else {
	$sizes
}
