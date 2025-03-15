git fetch origin
$branches = git branch --format="%(refname:short)" | Where-Object { $_ -ne "main" }

# Define symbols
$party = "🎉"
$greenCheck = "✅"
$warn = "⚠"

$currentBranch = git rev-parse --abbrev-ref HEAD

foreach ($branch in $branches) {
    $checkout = git checkout -f $branch 2>&1 | Out-Null
    $rebase = git rebase origin/main --reapply-cherry-picks 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "$party`t- Successfully rebased $branch." -ForegroundColor Blue -NoNewLine
        if (git branch --contains $branch | Select-String -Quiet "main") {
            # git branch -d $branch
            Write-Host " [eligible for deletion]" -ForegroundColor Green
        } else {
            Write-Host " [not fully merged into main and should not be deleted]" -ForegroundColor Yellow
        }
    } else {
        Write-Host "$warn`t- Rebase failed for $branch. Manual intervention needed." -ForegroundColor Red
        git rebase --abort
    }
    

    #if ((git branch --contains origin/main) -match (git rev-parse --abbrev-ref HEAD)) {
    #    Write-Output "Already rebased"
    #    git diff --name-status origin/main
    #} else {
    #    Write-Output "Needs rebase"
    #}

    #$base = git merge-base HEAD origin/main
    #$diffOutput = git diff --name-only $base origin/$branch

    #if ($diffOutput) {
    #    Write-Host "$warn - Potential conflicts detected in $branch! Skipping rebase." -ForegroundColor Red
    #} else {
    #    Write-Host "$greenCheck - No conflicts for $branch. Proceeding with rebase..." -ForegroundColor Green
    #    
    #    if ($(git ls-remote --heads origin $branch)) {
    #        git rebase origin/$branch
    #        if ($LASTEXITCODE -eq 0) {
    #            Write-Host "$party - Successfully rebased $branch!" -ForegroundColor Green
    #        } else {
    #            Write-Host "$warn - Rebase failed for $branch. Manual intervention needed." -ForegroundColor Red
    #            git rebase --abort
    #        }
    #    } else {
    #        Write-Host "$warn - Skipping rebase: No upstream found for $branch." -ForegroundColor Yellow
    #    }
    #}
}

# Return to original branch
git checkout -f $currentBranch

