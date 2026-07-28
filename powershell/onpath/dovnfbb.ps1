# email comes from $env:BB_EMAIL (set in ~/.profile.secrets.ps1, not the repo) so the
# real work address never lands in a tracked file.
if (-not $env:BB_EMAIL) {
    Write-Host "dovnfbb: set `$env:BB_EMAIL in ~/.profile.secrets.ps1 first" -ForegroundColor Yellow
    return
}
git config user.email $env:BB_EMAIL
git config user.name "dovholuknf"
