# phase6-vpn01.ps1
# Run on vpn01 - Windows Server 2025 Core
# VPN gateway - RRAS IKEv2
# DMZ IP: 10.0.2.10/24  GW: 10.0.2.1 (fw01)
# LAN IP: 10.0.1.60/24  DNS: ad01/ad02

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NIC identification by MAC
$dmzMac = '52-54-00-68-D7-B3'
$lanMac  = '52-54-00-AC-7A-37'

# Step 1 - Rename
Write-Host "[1/6] Renaming to VPN01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'VPN01') {
    Rename-Computer -NewName 'VPN01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already VPN01." -ForegroundColor Green

# Step 2 - Configure NICs by MAC
Write-Host "[2/6] Configuring NICs..." -ForegroundColor Cyan
$dmzIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $dmzMac }).InterfaceIndex
$lanIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $lanMac }).InterfaceIndex

Write-Host "     DMZ NIC index: $dmzIf" -ForegroundColor Gray
Write-Host "     LAN NIC index: $lanIf" -ForegroundColor Gray

# DMZ NIC - default gateway here (internet-facing)
Remove-NetIPAddress -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $dmzIf -IPAddress '10.0.2.10' -PrefixLength 24 -DefaultGateway '10.0.2.1'

# LAN NIC - no gateway, DNS only
Remove-NetIPAddress -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $lanIf -IPAddress '10.0.1.60' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $lanIf -ServerAddresses '10.0.1.10','10.0.1.11'
Set-DnsClientServerAddress -InterfaceIndex $dmzIf -ServerAddresses ''

Rename-NetAdapter -Name (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $dmzIf }).Name -NewName 'DMZ' -ErrorAction SilentlyContinue
Rename-NetAdapter -Name (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $lanIf }).Name  -NewName 'LAN' -ErrorAction SilentlyContinue

Write-Host "     DMZ: 10.0.2.10/24  GW: 10.0.2.1" -ForegroundColor Green
Write-Host "     LAN: 10.0.1.60/24  (no GW, DNS only)" -ForegroundColor Green

# Step 3 - Join domain via LAN NIC
Write-Host "[3/6] Joining domain ad.lab..." -ForegroundColor Cyan
Start-Sleep -Seconds 8
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install RRAS
Write-Host "[4/6] Installing RRAS..." -ForegroundColor Cyan
Install-WindowsFeature -Name RemoteAccess,RRAS -IncludeManagementTools
Write-Host "     RRAS installed." -ForegroundColor Green

# Step 5 - Configure RRAS for IKEv2 VPN
Write-Host "[5/6] Configuring RRAS for IKEv2 VPN..." -ForegroundColor Cyan

# Enable RRAS as VPN server
cmd /c 'netsh ras set conf confstate = enabled'
cmd /c 'netsh ras add registeredserver'

# Install Remote Access using PowerShell
Install-RemoteAccess -VpnType Vpn -ErrorAction SilentlyContinue

# Request machine certificate for IKEv2
Write-Host "     Requesting machine certificate..." -ForegroundColor Cyan
certutil -pulse | Out-Null
Start-Sleep -Seconds 10

$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*VPN01*' -and $_.Issuer -like '*ADLAB*' } |
    Select-Object -First 1

if ($cert) {
    Write-Host "     Machine cert: $($cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "     WARNING: No machine cert found. Trigger autoenroll manually:" -ForegroundColor Yellow
    Write-Host "     certutil -pulse" -ForegroundColor White
}

# Step 6 - Firewall rules
Write-Host "[6/6] Configuring firewall rules..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName 'IKEv2 Inbound 500' `
    -Direction Inbound -Protocol UDP -LocalPort 500 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'IKEv2 NAT-T 4500' `
    -Direction Inbound -Protocol UDP -LocalPort 4500 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue
Write-Host "     Firewall rules added." -ForegroundColor Green

Write-Host ""
Write-Host "VPN01 configuration complete." -ForegroundColor Green
Write-Host ""
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '10.0.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength
Write-Host ""
Write-Host "Verify RRAS: Get-RemoteAccess" -ForegroundColor Cyan
Write-Host "Machine cert: Get-ChildItem Cert:\LocalMachine\My" -ForegroundColor Cyan
