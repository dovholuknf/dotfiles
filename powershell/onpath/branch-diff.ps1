param(
    [string]$localBranch
)

$defaultBranch = "main"

if ($localBranch -eq "") {
	Write-Host "no branch supplied"
	return
}

# Find the common ancestor of the branch and the default branch
$mergeBase = git merge-base $localBranch $defaultBranch

# Output changes
Write-Host "Changes in $localBranch from its divergence point:"
#git log $mergeBase..$localBranch 
git diff $mergeBase $parentBranch $localBranch

Write-Host ""
