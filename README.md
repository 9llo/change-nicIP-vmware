# change-nicIP-vmware

PowerShell script to change the IP address of a specific NIC on VMware VMs via vCenter, using VMware PowerCLI. Works on both **Windows and Linux** guests without any OS-specific scripting.

## Prerequisites

- PowerShell 5.1+
- [VMware PowerCLI](https://developer.vmware.com/powercli) installed
- vCenter access with permissions on the target VM
- VMware Tools installed and running inside the guest VM

## Usage

```powershell
.\Set-VMNIC.ps1 `
    -vCenter     "<vCenter address>" `
    -vCenterUser "<username>" `
    -vCenterPass (Read-Host -AsSecureString "vCenter password") `
    -vmId        "<vm-123>" `
    -guestUser   "<local user>" `
    -guestPass   (Read-Host -AsSecureString "Guest password") `
    -IPAddress   "<new static IP>" `
    -netmask     "<subnet mask>" `
    -nicIndex    <index>
```

### Parameters

| Parameter      | Required | Description                                                        |
|----------------|----------|--------------------------------------------------------------------|
| `vCenter`      | Yes      | vCenter hostname or IP                                             |
| `vCenterUser`  | Yes      | vCenter username                                                   |
| `vCenterPass`  | Yes      | vCenter password (`SecureString`)                                  |
| `vmId`         | One of   | VM ID in vCenter (e.g.: `vm-123`). Use this **or** `-vmName`      |
| `vmName`       | One of   | VM display name in vCenter. Use this **or** `-vmId`                |
| `guestUser`    | Yes      | Administrator/root user inside the VM                              |
| `guestPass`    | Yes      | Guest user password (`SecureString`)                               |
| `IPAddress`    | Yes      | New static IP address to configure                                 |
| `netmask`      | Yes      | Subnet mask in dotted-decimal (e.g. `255.255.255.0`)               |
| `nicIndex`     | Yes      | Index of the NIC to change (0 = first NIC, 1 = second, etc.)      |
| `gateway`      | No       | Default gateway IP address                                         |
| `dns`          | No       | DNS server(s) — accepts an array, e.g. `"8.8.8.8","1.1.1.1"`      |
| `-DisableIPv6` | No       | Disables IPv6 on the target interface (Windows guests only)        |
| `-DryRun`      | No       | Previews current config and planned changes without applying them  |

### DryRun Mode

Use `-DryRun` to validate credentials and preview what would change without applying anything:

```powershell
.\Set-VMNIC.ps1 ... -IPAddress "10.0.0.1" -DryRun
```

## What the script does

1. Validates input parameters (IP/mask format, contiguous mask, DNS entries)
2. Connects to vCenter and validates credentials
3. Locates the VM by the provided ID or name
4. Auto-detects the guest OS family via VMware Tools
5. Lists all available NICs (vCenter side), indicating which one will be changed
6. Reads current IP configuration from the guest via `Invoke-VMScript`
7. If not in DryRun mode:
   - Applies the new configuration via `Invoke-VMScript`
   - Reads back and displays the final configuration
8. Disconnects from vCenter

## How it works

The script uses `Invoke-VMScript` (VMware PowerCLI), which runs scripts inside the guest OS through VMware Tools. The guest OS is auto-detected from the VMware Tools metadata:

- **Windows guests**: runs a PowerShell script using `netsh` and `NetTCPIP`/`NetAdapter` cmdlets
- **Linux guests**: runs a Bash script that configures the interface via `nmcli`, falling back to `netplan`, then `ifcfg`

The NIC is identified by its MAC address, matched between the vCenter view and the guest view. No SSH or WinRM is required.

## Finding the VM ID

```powershell
Connect-VIServer -Server <vCenter> -User <user> -Password <pass>
Get-VM -Name "<VM name>" | Select-Object Name, Id
# The returned Id will be in the format VirtualMachine-vm-123 — pass only the vm-123 part
```

---

> Portuguese version: [README.pt.md](README.pt.md)
