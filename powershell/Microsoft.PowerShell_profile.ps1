#environment variables
#$env:WORK_ROOT="c:\work"
$env:GIT_ROOT="${env:WORK_ROOT}\git"
$env:GH_ROOT="${env:GIT_ROOT}\github"
$env:BB_ROOT="${env:GIT_ROOT}\bitbucket"
$env:OZ_ROOT="${env:GH_ROOT}\openziti"
$env:BB_DOV_ROOT="${env:BB_ROOT}\dovholuk"
$env:DOTFILES="${env:GH_ROOT}\dovholuknf\dotfiles"
$env:DOTFILES_ROOT="${env:DOTFILES}\powershell"
$env:ON_PATH="${env:DOTFILES_ROOT}\onpath"
$env:ORIG_PATH=$env:PATH
$env:PATH="${env:ON_PATH};$env:PATH;$env:BB_DOV_ROOT\dev_stuff\helper-scripts\windows"
$env:NF_ROOT="${env:OZ_ROOT}\nf"

#aliases - get rid of overlapping ones with bash
Remove-Item alias:curl -ErrorAction Ignore
Remove-Item alias:mv -ErrorAction Ignore
Remove-Item alias:cp -ErrorAction Ignore
Remove-Item alias:rm -ErrorAction Ignore
Remove-Item alias:ls -ErrorAction Ignore
Remove-Item alias:diff -ErrorAction Ignore
Remove-Item alias:find -ErrorAction Ignore
Set-Alias -name vi -value "vim.exe"


function cddev () { cd $env:BB_DOV_ROOT\dev_stuff }
function cddot () { cd $env:DOTFILES }
function cddf () { cd $env:DOTFILES_ROOT }
function cdgh () { cd $env:GH_ROOT }
function cdnf () { cd $env:NF_ROOT }
function cdz () { cd $env:NF_ROOT\ziti }
function cdo () { cd $env:OZ_ROOT }
function cdzd () { cd $env:OZ_ROOT\ziti-doc }

$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}
	