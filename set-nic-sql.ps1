<#
.SYNOPSIS
    Changes the IP address of a specific NIC on a VMware VM via vCenter.

.DESCRIPTION
    Uses VMware PowerCLI to locate a VM by ID, identify a NIC by index, and apply
    a new static IP address inside the guest OS via Invoke-VMScript (netsh).

.EXAMPLE
    # Basic usage — change the second NIC (index 1) IP
    .\set-nic-sql.ps1 `
        -vCenter     "vcenter.corp.local" `
        -vCenterUser "administrator@vsphere.local" `
        -vCenterPass (Read-Host -AsSecureString "vCenter password") `
        -vmId        "vm-123" `
        -guestUser   "Administrator" `
        -guestPass   (Read-Host -AsSecureString "Guest password") `
        -novoIP      "10.0.0.1" `
        -netmask     "255.255.255.252" `
        -nicIndex    1

.EXAMPLE
    # DryRun — preview what would change without applying anything
    .\set-nic-sql.ps1 `
        -vCenter     "vcenter.corp.local" `
        -vCenterUser "administrator@vsphere.local" `
        -vCenterPass (Read-Host -AsSecureString "vCenter password") `
        -vmId        "vm-123" `
        -guestUser   "Administrator" `
        -guestPass   (Read-Host -AsSecureString "Guest password") `
        -novoIP      "10.0.0.1" `
        -netmask     "255.255.255.252" `
        -nicIndex    1 `
        -DryRun

.EXAMPLE
    # Change first NIC (index 0), custom mask, gateway, DNS, and disable IPv6
    .\set-nic-sql.ps1 `
        -vCenter        "vcenter.corp.local" `
        -vCenterUser    "administrator@vsphere.local" `
        -vCenterPass    (Read-Host -AsSecureString "vCenter password") `
        -vmId           "vm-456" `
        -guestUser      "Administrator" `
        -guestPass      (Read-Host -AsSecureString "Guest password") `
        -novoIP         "192.168.10.50" `
        -netmask        "255.255.255.0" `
        -nicIndex       0 `
        -gateway        "192.168.10.1" `
        -dns            "8.8.8.8","1.1.1.1" `
        -DesabilitarIPv6

.NOTES
    Requirements:
      - PowerShell 5.1+
      - VMware PowerCLI (Install-Module VMware.PowerCLI)
      - vCenter permissions: Invoke-VMScript on the target VM
      - Guest OS: Windows Server (uses netsh)

    To find the VM ID via PowerCLI:
      Connect-VIServer -Server <vCenter> -User <user> -Password <pass>
      Get-VM -Name "<VM name>" | Select-Object Name, Id
      # Pass only the "vm-123" part (without "VirtualMachine-")
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$vCenter,

    [Parameter(Mandatory=$true)]
    [string]$vCenterUser,

    [Parameter(Mandatory=$true)]
    [SecureString]$vCenterPass,

    [Parameter(Mandatory=$true)]
    [string]$vmId,

    [Parameter(Mandatory=$true)]
    [string]$guestUser,

    [Parameter(Mandatory=$true)]
    [SecureString]$guestPass,

    [Parameter(Mandatory=$true)]
    [string]$novoIP,

    [Parameter(Mandatory=$true)]
    [string]$netmask,

    [Parameter(Mandatory=$true)]
    [int]$nicIndex,

    [Parameter(Mandatory=$false)]
    [string]$gateway,

    [Parameter(Mandatory=$false)]
    [string[]]$dns,

    [Parameter(Mandatory=$false)]
    [switch]$DesabilitarIPv6,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# Input validation
$ipRegex = '^\d{1,3}(\.\d{1,3}){3}$'
foreach ($pair in @(@('novoIP', $novoIP), @('netmask', $netmask))) {
    if ($pair[1] -notmatch $ipRegex) {
        Write-Host "ERROR: '$($pair[1])' is not a valid IPv4 address for -$($pair[0])."
        exit 1
    }
}
if ($gateway -and $gateway -notmatch $ipRegex) {
    Write-Host "ERROR: '$gateway' is not a valid IPv4 address for -gateway."
    exit 1
}

if ($DryRun) { Write-Host "[DRY-RUN] Simulation mode active. No changes will be applied.`n" }

try {
    # Connect to vCenter
    $vCenterPassPlain = (New-Object PSCredential 'x', $vCenterPass).GetNetworkCredential().Password
    Write-Host "Connecting to vCenter $vCenter..."
    Connect-VIServer -Server $vCenter -User $vCenterUser -Password $vCenterPassPlain | Out-Null
    Write-Host "vCenter credentials validated successfully."

    $vm = Get-VM -Id "VirtualMachine-$vmId"
    Write-Host "VM found: $($vm.Name)"

    # List all available NICs
    $allNics = Get-NetworkAdapter -VM $vm | Sort-Object Name
    Write-Host "`n=== Available NICs ==="
    for ($i = 0; $i -lt $allNics.Count; $i++) {
        $marker = if ($i -eq $nicIndex) { ' <-- selected' } else { '' }
        Write-Host "[$i] $($allNics[$i].Name) - MAC: $($allNics[$i].MacAddress)$marker"
    }

    if ($nicIndex -lt 0 -or $nicIndex -ge $allNics.Count) {
        throw "nicIndex '$nicIndex' is invalid. Use a value between 0 and $($allNics.Count - 1)."
    }

    $nicMac = $allNics[$nicIndex].MacAddress.Replace(':', '-').ToUpper()

    # Read script (runs in both modes to show current config)
    $readScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$nicMac' } | Select-Object -ExpandProperty Name

if (-not `$iface) {
    Write-Host "ERROR: Interface with MAC $nicMac not found."
    exit 1
}

Write-Host "Interface found: `$iface"
Write-Host '=== CURRENT Configuration ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetRoute -InterfaceAlias "`$iface" -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object NextHop | Format-Table -AutoSize
Get-DnsClientServerAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object ServerAddresses | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@

    $guestCred = New-Object PSCredential($guestUser, $guestPass)

    Write-Host "`nValidating VM credentials and reading current configuration..."
    $readResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $readScript -ScriptType PowerShell
    Write-Host $readResult.ScriptOutput

    if ($DryRun) {
        Write-Host "=== What would be changed ==="
        Write-Host "  IP:      <current> --> $novoIP"
        Write-Host "  Mask:    <current> --> $netmask"
        Write-Host "  Gateway: <current> --> $(if ($gateway) { $gateway } else { 'no change' })"
        Write-Host "  DNS:     <current> --> $(if ($dns) { $dns -join ', ' } else { 'no change' })"
        Write-Host "  IPv6:    <current> --> $(if ($DesabilitarIPv6) { 'Disabled' } else { 'no change' })"
        Write-Host "`n[DRY-RUN] No changes were applied. Run without -DryRun to confirm."
        Disconnect-VIServer -Confirm:$false
        exit 0
    }

    # Build optional lines for the apply script
    $gatewayArg = if ($gateway) { " $gateway" } else { '' }
    $dnsLine    = if ($dns) {
        $quoted = ($dns | ForEach-Object { "'$_'" }) -join ','
        "Set-DnsClientServerAddress -InterfaceAlias `$iface -ServerAddresses @($quoted)"
    } else { '' }
    $ipv6Line   = if ($DesabilitarIPv6) { 'Disable-NetAdapterBinding -Name $iface -ComponentID ms_tcpip6' } else { '' }

    # Apply script (only in real mode)
    $applyScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$nicMac' } | Select-Object -ExpandProperty Name

if (-not `$iface) {
    Write-Host "ERROR: Interface with MAC $nicMac not found."
    exit 1
}

Write-Host "Interface found: `$iface"
netsh interface ip set address name="`$iface" static $novoIP $netmask$gatewayArg
$dnsLine
$ipv6Line

Write-Host '=== Final Configuration ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetRoute -InterfaceAlias "`$iface" -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object NextHop | Format-Table -AutoSize
Get-DnsClientServerAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object ServerAddresses | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@

    $applyResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $applyScript -ScriptType PowerShell
    Write-Host $applyResult.ScriptOutput

    if ($applyResult.ExitCode -ne 0) {
        throw "Guest script exited with code $($applyResult.ExitCode). Check the output above for details."
    }

    Disconnect-VIServer -Confirm:$false

} catch {
    Write-Host "ERROR: $_"
    if ($global:DefaultVIServers.Count -gt 0) { Disconnect-VIServer -Confirm:$false }
    exit 1
}
