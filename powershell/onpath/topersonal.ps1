$remote = git info

if ($remote -match '^git@github\.com:(.+)$') {
    $path = $Matches[1]
    $new  = "git@personal-github.com:$path"
    git remote set-url origin $new
}