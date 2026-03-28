# change-nicIP-vmware

PowerShell script to change the IP address of a specific NIC on VMware VMs via vCenter, using VMware PowerCLI.

## Prerequisites

- PowerShell 5.1+
- [VMware PowerCLI](https://developer.vmware.com/powercli) installed
- vCenter access with `Invoke-VMScript` permissions on the target VM
- Local (or domain) administrator credentials on the guest VM

## Usage

```powershell
.\set-nic-sql.ps1 `
    -vCenter       "<vCenter address>" `
    -vCenterUser   "<username>" `
    -vCenterPass   "<password>" `
    -vmId          "<VM ID (e.g.: VirtualMachine-vm-123)>" `
    -guestUser     "<VM local user>" `
    -guestPass     "<VM local password>" `
    -novoIP        "<new static IP>"
```

### Parameters

| Parameter          | Required | Default           | Description                                                         |
|--------------------|----------|-------------------|---------------------------------------------------------------------|
| `vCenter`          | Yes      | —                 | vCenter hostname or IP                                              |
| `vCenterUser`      | Yes      | —                 | vCenter username                                                    |
| `vCenterPass`      | Yes      | —                 | vCenter password                                                    |
| `vmId`             | Yes      | —                 | VM ID in vCenter (e.g.: `vm-123`)                                   |
| `guestUser`        | Yes      | —                 | Administrator user inside the VM                                    |
| `guestPass`        | Yes      | —                 | VM user password                                                    |
| `novoIP`           | Yes      | —                 | New static IP address to configure                                  |
| `netmask`          | Yes      | —                 | Subnet mask                                                         |
| `nicIndex`         | Yes      | —                 | Index of the NIC to change (0 = first NIC, 1 = second, etc.)       |
| `gateway`          | No       | —                 | Default gateway IP address                                          |
| `dns`              | No       | —                 | DNS server(s) — accepts an array, e.g. `"8.8.8.8","1.1.1.1"`       |
| `-DesabilitarIPv6` | No       | `$false`          | If provided, disables IPv6 on the interface                         |
| `-DryRun`          | No       | `$false`          | Simulates execution without applying any changes                    |

### DryRun Mode

Use `-DryRun` to validate credentials and preview the current configuration without making any changes:

```powershell
.\set-nic-sql.ps1 ... -novoIP "10.0.0.1" -DryRun
```

## What the script does

1. Connects to vCenter and validates credentials
2. Locates the VM by the provided ID
3. Lists all available NICs on the VM, indicating which one will be changed
4. Reads and displays the current IP configuration of the selected NIC (via `Invoke-VMScript`)
5. If not in DryRun mode:
   - Sets the new static IP with the specified subnet mask
   - Optionally disables the IPv6 protocol on the interface
   - Displays the final applied configuration
6. Disconnects from vCenter

## Finding the VM ID

The `vmId` can be obtained via PowerCLI:

```powershell
Connect-VIServer -Server <vCenter> -User <user> -Password <pass>
Get-VM -Name "<VM name>" | Select-Object Name, Id
# The returned Id will be in the format VirtualMachine-vm-123 — pass only the vm-123 part
```

## Notes

- The script uses `netsh interface ip set address` to apply the static IP, ensuring compatibility with Windows Server
- IPv6 can be optionally disabled on the changed interface using `-DesabilitarIPv6`
- The NIC is identified by its MAC address, avoiding ambiguity with the interface name inside the guest

---

> Portuguese version: [README.pt.md](README.pt.md)
