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
        -guestPass   "P@ssw0rd" `
        -novoIP      "10.0.0.1"

.EXAMPLE
    # DryRun — preview what would change without applying anything
    .\set-nic-sql.ps1 `
        -vCenter     "vcenter.corp.local" `
        -vCenterUser "administrator@vsphere.local" `
        -vCenterPass (Read-Host -AsSecureString "vCenter password") `
        -vmId        "vm-123" `
        -guestUser   "Administrator" `
        -guestPass   "P@ssw0rd" `
        -novoIP      "10.0.0.1" `
        -DryRun

.EXAMPLE
    # Change first NIC (index 0), custom mask, and disable IPv6
    .\set-nic-sql.ps1 `
        -vCenter        "vcenter.corp.local" `
        -vCenterUser    "administrator@vsphere.local" `
        -vCenterPass    (Read-Host -AsSecureString "vCenter password") `
        -vmId           "vm-456" `
        -guestUser      "Administrator" `
        -guestPass      "P@ssw0rd" `
        -novoIP         "192.168.10.50" `
        -mascara        "255.255.255.0" `
        -nicIndex       0 `
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
    [string]$guestPass,

    [Parameter(Mandatory=$true)]
    [string]$novoIP,

    [Parameter(Mandatory=$false)]
    [string]$mascara = '255.255.255.252',

    [Parameter(Mandatory=$false)]
    [int]$nicIndex = 1,

    [Parameter(Mandatory=$false)]
    [switch]$DesabilitarIPv6,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

if ($DryRun) { Write-Host "[DRY-RUN] Simulation mode active. No changes will be applied.`n" }

# Connect to vCenter (done in both modes)
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
    Write-Host "ERROR: nicIndex '$nicIndex' is invalid. Use a value between 0 and $($allNics.Count - 1)."
    Disconnect-VIServer -Confirm:$false
    exit 1
}

$secondNicMac = $allNics[$nicIndex].MacAddress
$secondNicMac = $secondNicMac.Replace(':', '-').ToUpper()

# Read script (runs in both modes to show current config)
$readScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$secondNicMac' } | Select-Object -ExpandProperty Name

if (-not `$iface) {
    Write-Host "ERROR: Interface with MAC $secondNicMac not found."
    exit 1
}

Write-Host "Interface found: `$iface"
Write-Host '=== CURRENT Configuration ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@

$guestCred = New-Object PSCredential($guestUser, (ConvertTo-SecureString $guestPass -AsPlainText -Force))

Write-Host "`nValidating VM credentials and reading current configuration..."
$readResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $readScript -ScriptType PowerShell
Write-Host $readResult.ScriptOutput

if ($DryRun) {
    Write-Host "=== What would be changed ==="
    Write-Host "  IP:      <current> --> $novoIP"
    Write-Host "  Mask:    <current> --> $mascara"
    Write-Host "  IPv6:    <current> --> $(if ($DesabilitarIPv6) { 'Disabled' } else { 'no change' })"
    Write-Host "`n[DRY-RUN] No changes were applied. Run without -DryRun to confirm."
    Disconnect-VIServer -Confirm:$false
    exit 0
}

# Apply script (only in real mode)
$applyScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$secondNicMac' } | Select-Object -ExpandProperty Name

if (-not `$iface) {
    Write-Host "ERROR: Interface with MAC $secondNicMac not found."
    exit 1
}

Write-Host "Interface found: `$iface"
netsh interface ip set address name="`$iface" static $novoIP $mascara
$(if ($DesabilitarIPv6) { 'Disable-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6' })

Write-Host '=== Final Configuration ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@

$applyResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $applyScript -ScriptType PowerShell
Write-Host $applyResult.ScriptOutput

Disconnect-VIServer -Confirm:$false