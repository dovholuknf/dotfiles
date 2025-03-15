# store current branch name
$curBranch = git rev-parse --abbrev-ref HEAD 2>$null

# store tag if possible then
if($curBranch -eq "HEAD" -or $curBranch -eq "" -or $curBranch -eq $null){
    $curBranch = git describe --exact-match --tags 2>$null
}

# ok just the commit hash
if($curBranch -eq "HEAD" -or $curBranch -eq "" -or $curBranch -eq $null){
    $curBranch = git rev-parse HEAD
}

git checkout main

# Fetch latest from all remotes
#git fetch --all
#git fat

# List all branches that are merged to 'release-next'
$mergedBranches = git branch --merged main

# Iterate through each merged branch
foreach ($branch in $mergedBranches) {
    $branch = $branch.Trim()

    # Skip branch if it is 'release-next' or the current branch
    if ($branch -eq "release-next" -or $branch -eq "* release-next" -or $branch -eq "main") {
        "- skipping: " + $branch
        continue
    }

    # Delete the merged branch
    git branch -d $branch
}

git checkout $curBranch


git branch --no-merged main | ForEach-Object { "git checkout $_" }