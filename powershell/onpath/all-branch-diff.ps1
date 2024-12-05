$defaultBranch = "main"

# List all branches except the default one
$branches = git branch --list | Select-String -Pattern "^..${defaultBranch}$" -NotMatch

foreach ($branch in $branches) {
    # Clean the branch name of any leading characters
    $localBranch = $branch -replace "^\*?\s*", ""

    # Find the common ancestor of the branch and the default branch
    $mergeBase = git merge-base $localBranch $defaultBranch

    # Output changes
    Write-Host "Changes in $localBranch from its divergence point:"
    #git log $mergeBase..$localBranch 
	git diff $mergeBase $parentBranch $localBranch > "$localBranch.txt"

    Write-Host ""
}