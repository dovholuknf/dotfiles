# allow-hyperv-vm.ps1
#
# Opens the Windows host firewall to inbound traffic from VMs sitting on the
# Hyper-V "Default Switch" — the NAT switch that Hyper-V auto-creates and that
# every Quick Create / WSL-style VM lands on unless you pick a different switch.
#
# Why this exists:
#   By default the host firewall blocks inbound connections from the Default
#   Switch subnet, so a VM can reach the internet (via NAT) but cannot reach
#   services running on the host (SSH, a dev web server, a database, etc.).
#   Poking a hole manually is fiddly because the Default Switch subnet is
#   randomized per-boot / per-install — it is NOT a fixed 172.x range.
#
# What it does:
#   1. Finds the host IP bound to "vEthernet (Default Switch)".
#   2. Derives the full CIDR subnet from that IP + prefix length (bitmath,
#      no hardcoded ranges).
#   3. Creates / updates / disables a single inbound firewall rule named
#      "Allow all from HyperV VM subnet" scoped to that CIDR.
#
# Modes:
#   usage    (default) print help
#   info     show detected adapter, computed VM range, and current rule state
#   enable   create the rule (or update its RemoteAddress if it already exists)
#   disable  disable the rule (leaves it in place so re-enable is one step)
#
# Must be run from an elevated (Administrator) PowerShell session — the
# Get/Set/New/Enable/Disable-NetFirewall* cmdlets require it.
#
# Safety notes:
#   - The rule is Inbound + Allow + Any profile, scoped ONLY to the Default
#     Switch subnet. It does NOT open the host to LAN or internet traffic.
#   - The subnet is recomputed on every run, so if Hyper-V regenerates the
#     Default Switch (reboot / reinstall) just re-run `enable` to retarget.
#   - `disable` disables rather than deletes; re-run `enable` to turn back on.

param(
    [ValidateSet("enable","disable","info","usage")]
    [string]$mode = "usage"
)

$name = "Allow all from HyperV VM subnet"

function Write-Green($msg) { Write-Host $msg -ForegroundColor Green }
function Write-Red($msg)   { Write-Host $msg -ForegroundColor Red }
function Write-Yellow($msg){ Write-Host $msg -ForegroundColor Yellow }
function Write-Cyan($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Gray($msg)  { Write-Host $msg -ForegroundColor DarkGray }

if ($mode -eq "usage") {
    Write-Cyan "Usage:"
    Write-Host "  allow-hyperv-vm.ps1 info    # show detected adapter + VM range + rule"
    Write-Host "  allow-hyperv-vm.ps1 enable  # allow inbound from VM range"
    Write-Host "  allow-hyperv-vm.ps1 disable # disable rule"
    return
}

$if = Get-NetIPAddress |
    Where-Object {
        $_.InterfaceAlias -eq "vEthernet (Default Switch)" -and
        $_.AddressFamily -eq "IPv4"
    } |
    Select-Object -First 1

if (-not $if) {
    Write-Red "Default Switch not found"
    return
}

$ip = $if.IPAddress
$prefix = [int]$if.PrefixLength

$ipBytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
[array]::Reverse($ipBytes)
$ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)

$maskInt = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix))
$netInt = $ipInt -band $maskInt

$netBytes = [System.BitConverter]::GetBytes($netInt)
[array]::Reverse($netBytes)
$network = ([System.Net.IPAddress]::new($netBytes)).ToString()
$vmRange = "$network/$prefix"

$rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue

if ($mode -eq "info") {
    Write-Cyan "Adapter: $($if.InterfaceAlias)"
    Write-Host "IP: $ip"
    Write-Host "Prefix: /$prefix"
    Write-Host "Subnet mask: $(([System.Net.IPAddress]::Parse($network).AddressFamily); (New-Object System.Net.IPAddress($maskInt)).ToString())"

    Write-Cyan "Computed VM range:"
    Write-Green "  $vmRange"

    Write-Gray "Explanation:"
    Write-Gray "  - Hyper-V Default Switch gives host IP $ip/$prefix"
    Write-Gray "  - Script converts that into the full subnet range"
    Write-Gray "  - Any VM on this switch will be inside this range"

    Write-Cyan "Rule name: $name"

    if ($rule) {
        $addr = ($rule | Get-NetFirewallAddressFilter).RemoteAddress
        Write-Green "Rule: present"
        Write-Host "  Enabled: $($rule.Enabled)"
        Write-Host "  Profile: $($rule.Profile)"
        Write-Host "  RemoteAddress: $addr"
    } else {
        Write-Yellow "Rule: not present"
    }
    return
}

if ($mode -eq "enable") {
    if (-not $rule) {
        New-NetFirewallRule `
            -DisplayName $name `
            -Direction Inbound `
            -RemoteAddress $vmRange `
            -Action Allow `
            -Profile Any | Out-Null
        Write-Green "Rule created"
    } else {
        $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $vmRange
        Enable-NetFirewallRule -DisplayName $name | Out-Null
        Write-Green "Rule updated/enabled"
    }

    Write-Cyan "Range applied:"
    Write-Green "  $vmRange"

    Write-Gray "This allows inbound traffic to this host from any VM on the Hyper-V Default Switch."
}

if ($mode -eq "disable") {
    if ($rule) {
        Disable-NetFirewallRule -DisplayName $name | Out-Null
        Write-Yellow "Rule disabled"
    } else {
        Write-Yellow "Rule not found"
    }
}