<#
.SYNOPSIS
    Changes the IP address of a specific NIC on a VMware VM via vCenter.

.DESCRIPTION
    Uses VMware PowerCLI to locate a VM by ID, identify a NIC by index, and apply
    a new static IP address inside the guest OS via Invoke-VMScript.
    The guest OS (Windows or Linux) is detected automatically through VMware Tools.
    On Linux, configuration is applied via nmcli, netplan, or ifcfg — whichever is available.

.EXAMPLE
    # Change the second NIC (index 1) on any guest OS
    .\Set-VMNIC.ps1 `
        -vCenter     "vcenter.corp.local" `
        -vCenterUser "administrator@vsphere.local" `
        -vCenterPass (Read-Host -AsSecureString "vCenter password") `
        -vmId        "vm-123" `
        -guestUser   "Administrator" `
        -guestPass   (Read-Host -AsSecureString "Guest password") `
        -IPAddress   "10.0.0.1" `
        -netmask     "255.255.255.252" `
        -nicIndex    1

.EXAMPLE
    # With gateway and DNS
    .\Set-VMNIC.ps1 `
        -vCenter     "vcenter.corp.local" `
        -vCenterUser "administrator@vsphere.local" `
        -vCenterPass (Read-Host -AsSecureString "vCenter password") `
        -vmId        "vm-456" `
        -guestUser   "root" `
        -guestPass   (Read-Host -AsSecureString "Guest password") `
        -IPAddress   "192.168.10.50" `
        -netmask     "255.255.255.0" `
        -nicIndex    0 `
        -gateway     "192.168.10.1" `
        -dns         "8.8.8.8","1.1.1.1"

.EXAMPLE
    # DryRun — preview without applying
    .\Set-VMNIC.ps1 `
        -vCenter     "vcenter.corp.local" `
        -vCenterUser "administrator@vsphere.local" `
        -vCenterPass (Read-Host -AsSecureString "vCenter password") `
        -vmId        "vm-123" `
        -guestUser   "Administrator" `
        -guestPass   (Read-Host -AsSecureString "Guest password") `
        -IPAddress   "10.0.0.1" `
        -netmask     "255.255.255.252" `
        -nicIndex    1 `
        -DryRun

.NOTES
    Requirements:
      - PowerShell 5.1+
      - VMware PowerCLI (Install-Module VMware.PowerCLI)
      - vCenter permissions: Invoke-VMScript on the target VM
      - VMware Tools installed and running inside the guest (required for OS detection)
      - Windows guests: uses netsh + NetTCPIP/NetAdapter cmdlets
      - Linux guests:   uses nmcli (falls back to netplan, then ifcfg)

    To find the VM ID via PowerCLI:
      $cred = Get-Credential
      Connect-VIServer -Server <vCenter> -Credential $cred
      Get-VM -Name "<VM name>" | Select-Object Name, Id
      # Pass only the "vm-123" part (without "VirtualMachine-")
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$vCenter,

    [Parameter(Mandatory=$true)]
    [string]$vCenterUser,

    [Parameter(Mandatory=$true)]
    [SecureString]$vCenterPass,

    [Parameter(Mandatory=$false)]
    [string]$vmId,

    [Parameter(Mandatory=$false)]
    [string]$vmName,

    [Parameter(Mandatory=$true)]
    [string]$guestUser,

    [Parameter(Mandatory=$true)]
    [SecureString]$guestPass,

    [Parameter(Mandatory=$true)]
    [string]$IPAddress,

    [Parameter(Mandatory=$true)]
    [string]$netmask,

    [Parameter(Mandatory=$true)]
    [int]$nicIndex,

    [Parameter(Mandatory=$false)]
    [string]$gateway,

    [Parameter(Mandatory=$false)]
    [string[]]$dns,

    # Windows guests only — disables IPv6 on the target interface
    [Parameter(Mandatory=$false)]
    [switch]$DisableIPv6,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# --- Input validation ---
if (-not $vmId -and -not $vmName) {
    Write-Host "ERROR: Provide either -vmId (e.g. vm-123) or -vmName (e.g. 'MyVM')."
    exit 1
}
if ($vmId -and $vmName) {
    Write-Host "ERROR: Provide either -vmId or -vmName, not both."
    exit 1
}

$ipRegex = '^(25[0-5]|2[0-4]\d|[01]?\d\d?)(\.(25[0-5]|2[0-4]\d|[01]?\d\d?)){3}$'

if ($IPAddress -notmatch $ipRegex) {
    Write-Host "ERROR: '$IPAddress' is not a valid IPv4 address for -IPAddress."
    exit 1
}
if ($netmask -notmatch $ipRegex) {
    Write-Host "ERROR: '$netmask' is not a valid subnet mask for -netmask."
    exit 1
}
if ($gateway -and $gateway -notmatch $ipRegex) {
    Write-Host "ERROR: '$gateway' is not a valid IPv4 address for -gateway."
    exit 1
}
foreach ($dnsEntry in $dns) {
    if ($dnsEntry -notmatch $ipRegex) {
        Write-Host "ERROR: '$dnsEntry' is not a valid IPv4 address for -dns."
        exit 1
    }
}

# Convert dotted-decimal mask to CIDR prefix length (used for Linux configs)
$prefixLength = (($netmask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join '').ToCharArray() |
                Where-Object { $_ -eq '1' } | Measure-Object | Select-Object -ExpandProperty Count

# Verify the mask is contiguous (valid subnet mask, not e.g. 255.0.255.0)
$maskBits = ('1' * $prefixLength).PadRight(32, '0')
$roundTripMask = (0..3 | ForEach-Object { [Convert]::ToInt32($maskBits.Substring($_ * 8, 8), 2) }) -join '.'
if ($roundTripMask -ne $netmask) {
    Write-Host "ERROR: '$netmask' is not a valid contiguous subnet mask."
    exit 1
}

if ($DryRun) { Write-Host "[DRY-RUN] Simulation mode active. No changes will be applied.`n" }

try {
    # Connect to vCenter — use PSCredential to avoid holding a plaintext password in memory
    $vCenterCred = New-Object PSCredential($vCenterUser, $vCenterPass)
    Write-Host "Connecting to vCenter $vCenter..."
    Connect-VIServer -Server $vCenter -Credential $vCenterCred | Out-Null
    Write-Host "vCenter credentials validated successfully."

    $vm = if ($vmId) { Get-VM -Id "VirtualMachine-$vmId" } else { Get-VM -Name $vmName }
    Write-Host "VM found: $($vm.Name)"

    # Auto-detect guest OS via VMware Tools
    $vmGuest = Get-VMGuest -VM $vm
    $guestFamily = $vmGuest.GuestFamily
    if (-not $guestFamily) {
        throw "Could not detect guest OS. Ensure VMware Tools is installed and the VM is powered on."
    }
    $guestIsLinux  = $guestFamily -eq 'linuxGuest'
    $guestIsWindows = $guestFamily -eq 'windowsGuest'
    if (-not $guestIsLinux -and -not $guestIsWindows) {
        throw "Unsupported guest OS family: '$guestFamily'."
    }
    Write-Host "Guest OS detected: $($vmGuest.OSFullName)"

    if ($DisableIPv6 -and $guestIsLinux) {
        Write-Host "WARNING: -DisableIPv6 is not supported for Linux guests and will be ignored."
    }

    # List all available NICs
    $allNics = Get-NetworkAdapter -VM $vm | Sort-Object Name

    if ($nicIndex -lt 0 -or $nicIndex -ge $allNics.Count) {
        throw "nicIndex '$nicIndex' is invalid. Use a value between 0 and $($allNics.Count - 1)."
    }

    Write-Host "`n=== Available NICs ==="
    for ($i = 0; $i -lt $allNics.Count; $i++) {
        $marker = if ($i -eq $nicIndex) { ' <-- selected' } else { '' }
        Write-Host "[$i] $($allNics[$i].Name) - MAC: $($allNics[$i].MacAddress)$marker"
    }

    # PowerCLI returns MAC addresses as xx:xx:xx:xx:xx:xx; normalize to xx-xx-xx-xx-xx-xx for Windows netsh/Get-NetAdapter
    $nicMac      = $allNics[$nicIndex].MacAddress.Replace(':', '-').ToUpper()
    $nicMacLinux = $nicMac.Replace('-', ':').ToLower()
    $guestCred   = New-Object PSCredential($guestUser, $guestPass)
    $scriptType  = if ($guestIsWindows) { 'PowerShell' } else { 'Bash' }

    # -------------------------------------------------------------------------
    # READ SCRIPTS
    # -------------------------------------------------------------------------
    if ($guestIsWindows) {
        $readScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$nicMac' } | Select-Object -ExpandProperty Name
if (-not `$iface) { Write-Host "ERROR: Interface with MAC $nicMac not found."; exit 1 }
Write-Host "Interface found: `$iface"
Write-Host '=== CURRENT Configuration ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetRoute -InterfaceAlias "`$iface" -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object NextHop | Format-Table -AutoSize
Get-DnsClientServerAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object ServerAddresses | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@
    } else {
        $readScript = @'
TARGET_MAC="PS_NICMAC"
iface=$(grep -rl "$TARGET_MAC" /sys/class/net/*/address 2>/dev/null | awk -F'/' '{print $5}' | head -1)
if [ -z "$iface" ]; then echo "ERROR: Interface with MAC $TARGET_MAC not found."; exit 1; fi
echo "Interface found: $iface"
echo "=== CURRENT Configuration ==="
echo "--- IP ---"
ip addr show "$iface" | grep 'inet '
echo "--- Gateway ---"
ip route show default dev "$iface" 2>/dev/null || echo "(none)"
echo "--- DNS ---"
if command -v nmcli >/dev/null 2>&1 && nmcli general status >/dev/null 2>&1; then
    nmcli dev show "$iface" | grep 'IP4.DNS' || echo "(none)"
else
    grep nameserver /etc/resolv.conf || echo "(none)"
fi
echo "--- IPv6 ---"
ip -6 addr show "$iface" | grep 'inet6' || echo "(none)"
'@
        $readScript = $readScript.Replace('PS_NICMAC', $nicMacLinux)
    }

    Write-Host "`nReading current configuration..."
    $readResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $readScript -ScriptType $scriptType
    Write-Host $readResult.ScriptOutput
    if ($readResult.ExitCode -ne 0 -or $readResult.ScriptOutput -match '^ERROR:') {
        throw "Failed to read current configuration from guest. Check the output above for details."
    }

    if ($DryRun) {
        Write-Host "=== What would be changed ==="
        Write-Host "  IP:      <current> --> $IPAddress"
        Write-Host "  Mask:    <current> --> $netmask$(if ($guestIsLinux) { " (/$prefixLength)" })"
        Write-Host "  Gateway: <current> --> $(if ($gateway) { $gateway } else { 'no change' })"
        Write-Host "  DNS:     <current> --> $(if ($dns) { $dns -join ', ' } else { 'no change' })"
        if ($guestIsWindows) {
            Write-Host "  IPv6:    <current> --> $(if ($DisableIPv6) { 'Disabled' } else { 'no change' })"
        }
        Write-Host "`n[DRY-RUN] No changes were applied. Run without -DryRun to confirm."
        Disconnect-VIServer -Server $vCenter -Confirm:$false
        exit 0
    }

    # -------------------------------------------------------------------------
    # APPLY SCRIPTS
    # -------------------------------------------------------------------------
    if ($guestIsWindows) {
        $gatewayArg = if ($gateway) { " $gateway" } else { '' }
        $dnsLine    = if ($dns) {
            $quoted = ($dns | ForEach-Object { "'$_'" }) -join ','
            "Set-DnsClientServerAddress -InterfaceAlias `$iface -ServerAddresses @($quoted)"
        } else { '' }
        $ipv6Line   = if ($DisableIPv6) { 'Disable-NetAdapterBinding -Name $iface -ComponentID ms_tcpip6' } else { '' }

        $applyScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$nicMac' } | Select-Object -ExpandProperty Name
if (-not `$iface) { Write-Host "ERROR: Interface with MAC $nicMac not found."; exit 1 }
Write-Host "Interface found: `$iface"
netsh interface ip set address name="`$iface" static $IPAddress $netmask$gatewayArg
$dnsLine
$ipv6Line
Write-Host '=== Final Configuration ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetRoute -InterfaceAlias "`$iface" -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object NextHop | Format-Table -AutoSize
Get-DnsClientServerAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object ServerAddresses | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@
    } else {
        # Build optional Linux config lines
        $gwLine        = if ($gateway) { 'nmcli con mod "$con" ipv4.gateway "' + $gateway + '"' } else { '' }
        $dnsLine       = if ($dns)     { 'nmcli con mod "$con" ipv4.dns "' + ($dns -join ',') + '"' } else { '' }
        $netplanGw     = if ($gateway) { "      routes:`n        - to: default`n          via: $gateway" } else { '' }
        $netplanDns    = if ($dns)     { "      nameservers:`n        addresses: [" + ($dns -join ', ') + "]" } else { '' }
        $ifcfgGwLine   = if ($gateway) { 'echo "GATEWAY=' + $gateway + '" >> "$cfg"' } else { '' }
        $ifcfgDnsLines = if ($dns) {
            (0..($dns.Count - 1) | ForEach-Object { 'echo "DNS' + ($_ + 1) + '=' + $dns[$_] + '" >> "$cfg"' }) -join "`n    "
        } else { '' }

        $applyScript = @'
TARGET_MAC="PS_NICMAC"
iface=$(grep -rl "$TARGET_MAC" /sys/class/net/*/address 2>/dev/null | awk -F'/' '{print $5}' | head -1)
if [ -z "$iface" ]; then echo "ERROR: Interface with MAC $TARGET_MAC not found."; exit 1; fi
echo "Interface found: $iface"

if command -v nmcli >/dev/null 2>&1 && nmcli general status >/dev/null 2>&1; then
    con=$(nmcli -t -f NAME,DEVICE con show --active | grep ":${iface}$" | cut -d: -f1)
    if [ -z "$con" ]; then echo "ERROR: No active nmcli connection found for $iface."; exit 1; fi
    echo "Method: nmcli  |  Connection: $con"
    nmcli con mod "$con" ipv4.method manual ipv4.addresses "PS_IPADDRESS/PS_PREFIX"
    PS_GW_LINE
    PS_DNS_LINE
    nmcli con up "$con"
elif ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    netplan_file=$(grep -rl "$iface" /etc/netplan/*.yaml 2>/dev/null | head -1)
    [ -z "$netplan_file" ] && netplan_file="/etc/netplan/99-set-vmnic.yaml"
    echo "Method: netplan  |  Config: $netplan_file"
    tee "$netplan_file" > /dev/null << NETPLAN_EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: false
      addresses:
        - PS_IPADDRESS/PS_PREFIX
PS_NETPLAN_GW
PS_NETPLAN_DNS
NETPLAN_EOF
    netplan apply
elif [ -d /etc/sysconfig/network-scripts ]; then
    cfg="/etc/sysconfig/network-scripts/ifcfg-$iface"
    [ ! -f "$cfg" ] && touch "$cfg"
    echo "Method: ifcfg  |  Config: $cfg"
    sed -i 's/^BOOTPROTO=.*/BOOTPROTO=none/' "$cfg"
    sed -i '/^IPADDR=/d;/^NETMASK=/d;/^PREFIX=/d;/^GATEWAY=/d;/^DNS[0-9]*=/d' "$cfg"
    echo "IPADDR=PS_IPADDRESS" >> "$cfg"
    echo "PREFIX=PS_PREFIX"    >> "$cfg"
    PS_IFCFG_GW
    PS_IFCFG_DNS
    ifdown "$iface" && ifup "$iface"
else
    echo "ERROR: No supported network configuration method found (tried nmcli, netplan, ifcfg)."
    exit 1
fi

echo "=== Final Configuration ==="
ip addr show "$iface" | grep 'inet '
ip route show default dev "$iface" 2>/dev/null || echo "Gateway: (none)"
grep nameserver /etc/resolv.conf | head -3 || echo "DNS: (none)"
'@
        $applyScript = $applyScript.Replace('PS_NICMAC',      $nicMacLinux)
        $applyScript = $applyScript.Replace('PS_IPADDRESS',   $IPAddress)
        $applyScript = $applyScript.Replace('PS_PREFIX',      [string]$prefixLength)
        $applyScript = $applyScript.Replace('PS_GW_LINE',     $gwLine)
        $applyScript = $applyScript.Replace('PS_DNS_LINE',    $dnsLine)
        $applyScript = $applyScript.Replace('PS_NETPLAN_GW',  $netplanGw)
        $applyScript = $applyScript.Replace('PS_NETPLAN_DNS', $netplanDns)
        $applyScript = $applyScript.Replace('PS_IFCFG_GW',    $ifcfgGwLine)
        $applyScript = $applyScript.Replace('PS_IFCFG_DNS',   $ifcfgDnsLines)
    }

    $applyResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $applyScript -ScriptType $scriptType
    Write-Host $applyResult.ScriptOutput

    if ($applyResult.ExitCode -ne 0 -or $applyResult.ScriptOutput -match '^ERROR:') {
        throw "Guest script failed (exit code $($applyResult.ExitCode)). Check the output above for details."
    }

    Disconnect-VIServer -Server $vCenter -Confirm:$false

} catch {
    Write-Host "ERROR: $_"
    if ($global:DefaultVIServers | Where-Object { $_.Name -eq $vCenter }) {
        Disconnect-VIServer -Server $vCenter -Confirm:$false
    }
    exit 1
}
