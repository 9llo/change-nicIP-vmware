param(
    [Parameter(Mandatory=$true)]
    [string]$vCenter,

    [Parameter(Mandatory=$true)]
    [string]$vCenterUser,

    [Parameter(Mandatory=$true)]
    [string]$vCenterPass,

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
    [switch]$DryRun
)

if ($DryRun) { Write-Host "[DRY-RUN] Modo simulacao ativo. Nenhuma alteracao sera aplicada.`n" }

# Conectar ao vCenter (feito em ambos os modos)
Write-Host "Conectando ao vCenter $vCenter..."
Connect-VIServer -Server $vCenter -User $vCenterUser -Password $vCenterPass | Out-Null
Write-Host "Credenciais do vCenter validadas com sucesso."

$vm = Get-VM -Id $vmId
Write-Host "VM encontrada: $($vm.Name)"

# Listar todas as NICs disponíveis
$allNics = Get-NetworkAdapter -VM $vm | Sort-Object Name
Write-Host "`n=== NICs disponíveis ==="
for ($i = 0; $i -lt $allNics.Count; $i++) {
    $marker = if ($i -eq $nicIndex) { ' <-- selecionada' } else { '' }
    Write-Host "[$i] $($allNics[$i].Name) - MAC: $($allNics[$i].MacAddress)$marker"
}

if ($nicIndex -lt 0 -or $nicIndex -ge $allNics.Count) {
    Write-Host "ERRO: nicIndex '$nicIndex' invalido. Use um valor entre 0 e $($allNics.Count - 1)."
    Disconnect-VIServer -Confirm:$false
    exit 1
}

$secondNicMac = $allNics[$nicIndex].MacAddress
$secondNicMac = $secondNicMac.Replace(':', '-').ToUpper()

# Script de leitura (executado em ambos os modos para mostrar config atual)
$readScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$secondNicMac' } | Select-Object -ExpandProperty Name

if (-not `$iface) {
    Write-Host "ERRO: Interface com MAC $secondNicMac nao encontrada."
    exit 1
}

Write-Host "Interface encontrada: `$iface"
Write-Host '=== Configuracao ATUAL ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@

$guestCred = New-Object PSCredential($guestUser, (ConvertTo-SecureString $guestPass -AsPlainText -Force))

Write-Host "`nValidando credenciais da VM e lendo configuracao atual..."
$readResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $readScript -ScriptType PowerShell
Write-Host $readResult.ScriptOutput

if ($DryRun) {
    Write-Host "=== O que seria alterado ==="
    Write-Host "  IP:     <atual> --> $novoIP"
    Write-Host "  Mascara: <atual> --> $mascara"
    Write-Host "  IPv6:   <atual> --> Desabilitado"
    Write-Host "`n[DRY-RUN] Nenhuma alteracao foi aplicada. Execute sem -DryRun para confirmar."
    Disconnect-VIServer -Confirm:$false
    exit 0
}

# Script de alteracao (somente no modo real)
$applyScript = @"
`$iface = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$secondNicMac' } | Select-Object -ExpandProperty Name

if (-not `$iface) {
    Write-Host "ERRO: Interface com MAC $secondNicMac nao encontrada."
    exit 1
}

Write-Host "Interface encontrada: `$iface"
netsh interface ip set address name="`$iface" static $novoIP $mascara
Disable-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6

Write-Host '=== Configuracao final ==='
Get-NetIPAddress -InterfaceAlias "`$iface" -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetAdapterBinding -Name "`$iface" -ComponentID ms_tcpip6 | Select-Object Name, Enabled | Format-Table -AutoSize
"@

$applyResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $applyScript -ScriptType PowerShell
Write-Host $applyResult.ScriptOutput

Disconnect-VIServer -Confirm:$false