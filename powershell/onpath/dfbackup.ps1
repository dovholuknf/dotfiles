echo "backing up \$profile"
copy $profile $env:DOTFILES_ROOT

echo "copying .gitconfig"
copy $env:USERPROFILE\.gitconfig $env:DOTFILES_ROOT