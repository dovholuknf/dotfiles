# Fetch and prune remote branches
git fetch --prune

# Delete local branches that are gone from remote
git branch -vv | 
    Where-Object { $_ -notmatch '^\*' -and $_ -match '\[origin/.*: gone\]' } | 
    ForEach-Object { 
        if ($_ -match '^.\s+(\S+)') {
            $branchName = $Matches[1]
            Write-Host "-------------------------------------------------------"
            Write-Host "Deleting: $branchName" -ForegroundColor Green
            git branch -d $branchName
        }
    }
    
git fetch origin
$branches = git branch --format="%(refname:short)" | Where-Object { $_ -ne "main" }

# Define symbols
$party = "🎉"
$greenCheck = "✅"
$warn = "⚠"

foreach ($branch in $branches) {
  if (git branch --contains $branch | Select-String -Quiet "main") {
    Write-Host "-------------------------------------------------------"
    Write-Host "Deleting: $branch" -ForegroundColor Green
    git branch -d $branch
  }
}

Write-Host "-------------------------------------------------------"