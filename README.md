# change-nicIP-vmware

Script PowerShell para alterar o IP de uma NIC específica em VMs VMware via vCenter, utilizando VMware PowerCLI.

## Pré-requisitos

- PowerShell 5.1+
- [VMware PowerCLI](https://developer.vmware.com/powercli) instalado
- Acesso ao vCenter com permissões de `Invoke-VMScript` na VM alvo
- Credenciais de administrador local (ou domínio) na VM guest

## Uso

```powershell
.\set-nic-sql.ps1 `
    -vCenter       "<endereço do vCenter>" `
    -vCenterUser   "<usuario>" `
    -vCenterPass   "<senha>" `
    -vmId          "<ID da VM (ex: VirtualMachine-vm-123)>" `
    -guestUser     "<usuario local da VM>" `
    -guestPass     "<senha local da VM>" `
    -novoIP        "<novo IP estático>"
```

### Parâmetros

| Parâmetro     | Obrigatório | Padrão            | Descrição                                             |
|---------------|-------------|-------------------|-------------------------------------------------------|
| `vCenter`     | Sim         | —                 | Hostname ou IP do vCenter                             |
| `vCenterUser` | Sim         | —                 | Usuário do vCenter                                    |
| `vCenterPass` | Sim         | —                 | Senha do vCenter                                      |
| `vmId`        | Sim         | —                 | ID da VM no vCenter (ex: `vm-123`)                    |
| `guestUser`   | Sim         | —                 | Usuário administrador dentro da VM                    |
| `guestPass`   | Sim         | —                 | Senha do usuário da VM                                |
| `novoIP`      | Sim         | —                 | Novo endereço IP estático a configurar                |
| `mascara`     | Não         | `255.255.255.252` | Máscara de sub-rede                                   |
| `nicIndex`       | Não         | `1`               | Índice da NIC a alterar (0 = primeira NIC, 1 = segunda, etc.) |
| `-DesabilitarIPv6` | Não      | `$false`          | Se informado, desabilita o IPv6 na interface          |
| `-DryRun`        | Não         | `$false`          | Simula a execução sem aplicar nenhuma alteração       |

### Modo DryRun

Use `-DryRun` para validar credenciais e visualizar a configuração atual sem realizar nenhuma alteração:

```powershell
.\set-nic-sql.ps1 ... -novoIP "10.0.0.1" -DryRun
```

## O que o script faz

1. Conecta ao vCenter e valida as credenciais
2. Localiza a VM pelo ID informado
3. Lista todas as NICs disponíveis na VM, indicando qual será alterada
4. Lê e exibe a configuração de IP atual da NIC selecionada (via `Invoke-VMScript`)
5. Se não estiver em modo DryRun:
   - Define o novo IP estático com a máscara especificada
   - Desabilita o protocolo IPv6 na interface
   - Exibe a configuração final aplicada
6. Desconecta do vCenter

## Identificando o ID da VM

O `vmId` pode ser obtido via PowerCLI:

```powershell
Connect-VIServer -Server <vCenter> -User <user> -Password <pass>
Get-VM -Name "<nome da VM>" | Select-Object Name, Id
# O Id retornado será no formato VirtualMachine-vm-123 — passe apenas a parte vm-123
```

## Observações

- O script usa `netsh interface ip set address` para aplicar o IP estático, garantindo compatibilidade com Windows Server
- IPv6 é desabilitado automaticamente na interface alterada
- A NIC é identificada pelo endereço MAC, evitando ambiguidade com o nome da interface dentro do guest
