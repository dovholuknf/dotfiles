# Fetch and prune remote branches
git fetch --prune

# Delete local branches that are gone from remote
git branch -vv | 
    Where-Object { $_ -notmatch '^\*' -and $_ -match '\[origin/.*: gone\]' } | 
    ForEach-Object { 
        if ($_ -match '^.\s+(\S+)') {
            $branchName = $Matches[1]
            git branch -d $branchName
        }
    }