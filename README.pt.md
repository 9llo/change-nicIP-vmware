# change-nicIP-vmware

Script PowerShell para alterar o IP de uma NIC específica em VMs VMware via vCenter, utilizando VMware PowerCLI. Funciona em guests **Windows e Linux** sem necessidade de scripts específicos por sistema operacional.

## Pré-requisitos

- PowerShell 5.1+
- [VMware PowerCLI](https://developer.vmware.com/powercli) instalado
- Acesso ao vCenter com permissões na VM alvo
- VMware Tools instalado e em execução dentro da VM guest

## Uso

```powershell
.\Set-VMNIC.ps1 `
    -vCenter     "<endereço do vCenter>" `
    -vCenterUser "<usuario>" `
    -vCenterPass (Read-Host -AsSecureString "Senha do vCenter") `
    -vmId        "<vm-123>" `
    -guestUser   "<usuario local>" `
    -guestPass   (Read-Host -AsSecureString "Senha do guest") `
    -IPAddress   "<novo IP estático>" `
    -netmask     "<máscara de sub-rede>" `
    -nicIndex    <índice>
```

### Parâmetros

| Parâmetro      | Obrigatório | Descrição                                                                    |
|----------------|-------------|------------------------------------------------------------------------------|
| `vCenter`      | Sim         | Hostname ou IP do vCenter                                                    |
| `vCenterUser`  | Sim         | Usuário do vCenter                                                           |
| `vCenterPass`  | Sim         | Senha do vCenter (`SecureString`)                                            |
| `vmId`         | Um dos dois | ID da VM no vCenter (ex: `vm-123`). Use este **ou** `-vmName`                |
| `vmName`       | Um dos dois | Nome de exibição da VM no vCenter. Use este **ou** `-vmId`                   |
| `guestUser`    | Sim         | Usuário administrador/root dentro da VM                                      |
| `guestPass`    | Sim         | Senha do usuário guest (`SecureString`)                                      |
| `IPAddress`    | Sim         | Novo endereço IP estático a configurar                                       |
| `netmask`      | Sim         | Máscara em decimal pontuado (ex: `255.255.255.0`)                            |
| `nicIndex`     | Sim         | Índice da NIC a alterar (0 = primeira NIC, 1 = segunda, etc.)                |
| `gateway`      | Não         | Endereço IP do gateway padrão                                                |
| `dns`          | Não         | Servidor(es) DNS — aceita array, ex: `"8.8.8.8","1.1.1.1"`                  |
| `-DisableIPv6` | Não         | Desabilita o IPv6 na interface alvo (somente guests Windows)                 |
| `-DryRun`      | Não         | Exibe configuração atual e mudanças planejadas sem aplicá-las                |

### Modo DryRun

Use `-DryRun` para validar credenciais e visualizar o que seria alterado sem realizar nenhuma mudança:

```powershell
.\Set-VMNIC.ps1 ... -IPAddress "10.0.0.1" -DryRun
```

## O que o script faz

1. Valida os parâmetros de entrada (formato de IP/máscara, máscara contígua, entradas de DNS)
2. Conecta ao vCenter e valida as credenciais
3. Localiza a VM pelo ID ou nome informado
4. Detecta automaticamente o sistema operacional guest via VMware Tools
5. Lista todas as NICs disponíveis (lado vCenter), indicando qual será alterada
6. Lê a configuração de IP atual do guest via `Invoke-VMScript`
7. Se não estiver em modo DryRun:
   - Aplica a nova configuração via `Invoke-VMScript`
   - Lê e exibe a configuração final aplicada
8. Desconecta do vCenter

## Como funciona

O script utiliza `Invoke-VMScript` (VMware PowerCLI), que executa scripts dentro do guest através do VMware Tools. O sistema operacional é detectado automaticamente pelos metadados do VMware Tools:

- **Guests Windows**: executa um script PowerShell usando `netsh` e cmdlets `NetTCPIP`/`NetAdapter`
- **Guests Linux**: executa um script Bash que configura a interface via `nmcli`, com fallback para `netplan` e depois `ifcfg`

A NIC é identificada pelo endereço MAC, correspondido entre a visão do vCenter e a visão do guest. Não é necessário SSH ou WinRM.

## Identificando o ID da VM

```powershell
Connect-VIServer -Server <vCenter> -User <user> -Password <pass>
Get-VM -Name "<nome da VM>" | Select-Object Name, Id
# O Id retornado será no formato VirtualMachine-vm-123 — passe apenas a parte vm-123
```

---

> English version: [README.md](README.md)
