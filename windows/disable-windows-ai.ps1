[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$DryRun = -not $Apply

# Exact package names to remove. Anything else matching *Copilot* is listed, not removed.
$CopilotPackages = @(
    'Microsoft.Copilot'
    'Microsoft.Windows.Ai.Copilot.Provider'
)

function Write-Mode {
    if ($DryRun) {
        Write-Host "DRY RUN: no changes will be made."
        Write-Host "Run again with -Apply to make the changes."
    } else {
        Write-Host "APPLY MODE: changes will be made."
    }
    Write-Host
}

function Ensure-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]::new($id)

    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Set-PolicyDword {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int]$Value
    )

    $existing = $null
    if (Test-Path $Path) {
        $existing = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    }

    if ($existing -eq $Value) {
        Write-Host "[OK]   $Path\$Name = $Value"
        return
    }

    Write-Host "[SET]  $Path\$Name = $Value" `
        "(current: $(if ($null -eq $existing) {'<missing>'} else {$existing}))"

    if (-not $DryRun) {
        # New-Item -Force on an existing key recreates it and drops its other values.
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty `
            -Path $Path `
            -Name $Name `
            -PropertyType DWord `
            -Value $Value `
            -Force | Out-Null
    }
}

# Real user hives currently loaded under HKEY_USERS. A user who is not signed in has no
# loaded hive and is skipped, so run this again after that user signs in.
function Get-LoadedUserHives {
    Get-ChildItem 'Registry::HKEY_USERS' |
        Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
        ForEach-Object {
            $name = try {
                ([Security.Principal.SecurityIdentifier]$_.PSChildName).Translate([Security.Principal.NTAccount]).Value
            } catch { $_.PSChildName }
            [pscustomobject]@{ Sid = $_.PSChildName; Name = $name }
        }
}

function Disable-OptionalFeatureIfPresent {
    param(
        [Parameter(Mandatory)] [string]$FeatureName
    )

    # A query failure is an error, not "not present". Only a clean empty answer means absent.
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -match 'not recognized|feature name .* is unknown') { $feature = $null }
        else { Write-Warning "Could not query optional feature '$FeatureName': $($_.Exception.Message)"; return }
    }

    if (-not $feature) {
        Write-Host "[N/A]  Optional feature '$FeatureName' not present."
        return
    }

    if ($feature.State -eq 'DisabledWithPayloadRemoved') {
        Write-Host "[OK]   Optional feature '$FeatureName' already removed."
        return
    }

    Write-Host "[RM]   Optional feature '$FeatureName' (state: $($feature.State))"

    if (-not $DryRun) {
        Disable-WindowsOptionalFeature `
            -Online `
            -FeatureName $FeatureName `
            -Remove `
            -NoRestart | Out-Null
    }
}

# The Appx module does not always load natively in pwsh 7. Fall back to the Windows
# PowerShell compatibility session, and fail loudly if neither works.
function Initialize-Appx {
    try {
        Get-AppxPackage -Name '__probe__' -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "[INFO] Appx did not load natively, retrying with -UseWindowsPowerShell"
        Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
        Get-AppxPackage -Name '__probe__' -ErrorAction Stop | Out-Null
    }
}

function Remove-CopilotAppx {
    $installed   = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -like '*Copilot*' })
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -like '*Copilot*' })

    if (-not $installed -and -not $provisioned) {
        Write-Host "[N/A]  No AppX packages matching '*Copilot*'."
        return
    }

    foreach ($pkg in $installed) {
        if ($CopilotPackages -notcontains $pkg.Name) {
            Write-Host "[SKIP] Installed AppX not on the removal list: $($pkg.Name)"
            continue
        }
        Write-Host "[RM]   Installed AppX: $($pkg.Name)"
        if (-not $DryRun) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            } catch {
                Write-Warning "Could not remove installed package $($pkg.Name): $($_.Exception.Message)"
            }
        }
    }

    foreach ($pkg in $provisioned) {
        if ($CopilotPackages -notcontains $pkg.DisplayName) {
            Write-Host "[SKIP] Provisioned AppX not on the removal list: $($pkg.DisplayName)"
            continue
        }
        Write-Host "[RM]   Provisioned AppX: $($pkg.DisplayName)"
        if (-not $DryRun) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers -ErrorAction Stop | Out-Null
            } catch {
                Write-Warning "Could not remove provisioned package $($pkg.DisplayName): $($_.Exception.Message)"
            }
        }
    }
}

Ensure-Admin
Write-Mode

Write-Host "== Windows AI policies =="

$windowsAI = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'

# Prevent Recall from being enabled and disable Recall snapshot analysis.
Set-PolicyDword -Path $windowsAI -Name 'AllowRecallEnablement' -Value 0
Set-PolicyDword -Path $windowsAI -Name 'DisableAIDataAnalysis' -Value 1

# Disable Click to Do.
Set-PolicyDword -Path $windowsAI -Name 'DisableClickToDo' -Value 1

# Disable the agent in Settings. Editions without the feature ignore it.
Set-PolicyDword -Path $windowsAI -Name 'DisableSettingsAgent' -Value 1

Write-Host
Write-Host "== Copilot policy (legacy, per user) =="

# TurnOffWindowsCopilot is user scope only, with no machine form, so it goes into every
# loaded user hive. Microsoft marks it deprecated, and it does not control the newer
# Copilot app, which the AppX step below removes.
foreach ($hive in Get-LoadedUserHives) {
    Write-Host "  user: $($hive.Name)"
    Set-PolicyDword `
        -Path "Registry::HKEY_USERS\$($hive.Sid)\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" `
        -Name 'TurnOffWindowsCopilot' `
        -Value 1
}

Write-Host
Write-Host "== Paint AI =="

$paintPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'

Set-PolicyDword -Path $paintPolicy -Name 'DisableCocreator'      -Value 1
Set-PolicyDword -Path $paintPolicy -Name 'DisableImageCreator'   -Value 1
Set-PolicyDword -Path $paintPolicy -Name 'DisableGenerativeFill' -Value 1

Write-Host
Write-Host "== Notepad AI =="

Set-PolicyDword -Path 'HKLM:\SOFTWARE\Policies\WindowsNotepad' -Name 'DisableAIFeatures' -Value 1

Write-Host
Write-Host "== Edge Copilot icon =="

# Removes the Copilot toolbar icon only. The rest of the Edge sidebar stays.
Set-PolicyDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'Microsoft365CopilotChatIconEnabled' -Value 0

Write-Host
Write-Host "== Recall optional component =="

Disable-OptionalFeatureIfPresent -FeatureName 'Recall'

Write-Host
Write-Host "== Microsoft Copilot AppX packages =="

Initialize-Appx
Remove-CopilotAppx

Write-Host

if ($DryRun) {
    Write-Host "Dry run complete. Nothing was changed."
    Write-Host "To apply:"
    Write-Host "  $($MyInvocation.MyCommand.Path) -Apply"
} else {
    Write-Host "Changes applied."
    Write-Host "Restart Windows to ensure all policies and Recall removal take effect."
}
