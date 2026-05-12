# phase5-jump01.ps1
# Run on jump01 - Windows Server 2025 Core
# Bastion / RD Gateway - dual-homed LAN + MGMT
# LAN IP:  10.0.1.41/24
# MGMT IP: 10.0.3.10/24

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - Rename
Write-Host "[1/8] Renaming to JUMP01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'JUMP01') {
    Rename-Computer -NewName 'JUMP01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already JUMP01." -ForegroundColor Green

# Step 2 - Configure both NICs
Write-Host "[2/8] Configuring dual NICs..." -ForegroundColor Cyan
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object InterfaceIndex

if ($adapters.Count -lt 2) {
    Write-Host "ERROR: Expected 2 NICs, found $($adapters.Count)." -ForegroundColor Red
    Write-Host "       Ensure jump01 was created with create-jump01.sh (2 NICs)." -ForegroundColor Red
    exit 1
}

$lanIf   = $adapters[0].InterfaceIndex
$mgmtIf  = $adapters[1].InterfaceIndex

Write-Host "     NIC1 (LAN):  index $lanIf" -ForegroundColor Gray
Write-Host "     NIC2 (MGMT): index $mgmtIf" -ForegroundColor Gray

# LAN NIC
Remove-NetIPAddress   -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute       -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress      -InterfaceIndex $lanIf -IPAddress '10.0.1.41' -PrefixLength 24 -DefaultGateway '10.0.1.1'
Set-DnsClientServerAddress -InterfaceIndex $lanIf -ServerAddresses '10.0.1.10','10.0.1.11'

# MGMT NIC — no gateway, no DNS (isolated)
Remove-NetIPAddress   -InterfaceIndex $mgmtIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute       -InterfaceIndex $mgmtIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress      -InterfaceIndex $mgmtIf -IPAddress '10.0.3.10' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $mgmtIf -ServerAddresses ''

Write-Host "     LAN:  10.0.1.41/24  GW: 10.0.1.1" -ForegroundColor Green
Write-Host "     MGMT: 10.0.3.10/24  (no gateway)" -ForegroundColor Green

# Step 3 - Join domain via LAN NIC
Write-Host "[3/8] Joining domain ad.lab..." -ForegroundColor Cyan
Start-Sleep -Seconds 10
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install RD Gateway + management tools
Write-Host "[4/8] Installing Remote Desktop Gateway and tools..." -ForegroundColor Cyan
Install-WindowsFeature -Name RDS-Gateway -IncludeManagementTools
Install-WindowsFeature -Name RSAT-AD-Tools
Install-WindowsFeature -Name RSAT-DNS-Server
Install-WindowsFeature -Name RSAT-DHCP
Install-WindowsFeature -Name GPMC
Write-Host "     Features installed." -ForegroundColor Green

# Step 5 - Request RD Gateway certificate from CA
Write-Host "[5/8] Requesting RD Gateway certificate..." -ForegroundColor Cyan
try {
    $cert = Get-Certificate `
        -Template          'WebServer' `
        -SubjectName       'CN=jump01.ad.lab' `
        -DnsName           'jump01.ad.lab','jump01' `
        -CertStoreLocation 'Cert:\LocalMachine\My'
    $rdGwCertThumb = $cert.Certificate.Thumbprint
    Write-Host "     Certificate issued: $rdGwCertThumb" -ForegroundColor Green
} catch {
    Write-Host "     WARNING: Manual cert request needed." -ForegroundColor Yellow
    certreq -enroll -machine WebServer
    $rdGwCertThumb = (Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -like '*jump01*' } |
        Select-Object -First 1).Thumbprint
}

# Step 6 - Configure RD Gateway
Write-Host "[6/8] Configuring RD Gateway..." -ForegroundColor Cyan

Import-Module RemoteDesktopServices -ErrorAction SilentlyContinue

# Set SSL cert for RD Gateway
if ($rdGwCertThumb) {
    Set-Item 'RDS:\GatewayServer\SSLCertificate\Thumbprint' $rdGwCertThumb -ErrorAction SilentlyContinue
}

# Create Connection Authorization Policy (CAP) — who can connect
New-Item 'RDS:\GatewayServer\CAP' -Name 'AdLab-CAP' `
    -UserGroups  'ADLAB\Domain Admins' `
    -AuthMethod  1 `
    -ErrorAction SilentlyContinue
Write-Host "     CAP created: Domain Admins only." -ForegroundColor Green

# Create Resource Authorization Policy (RAP) — what they can connect to
New-Item 'RDS:\GatewayServer\RAP' -Name 'AdLab-RAP' `
    -UserGroups     'ADLAB\Domain Admins' `
    -ComputerGroupType 2 `
    -ErrorAction SilentlyContinue
Write-Host "     RAP created: all LAN resources." -ForegroundColor Green

# Step 7 - Harden RDP and WinRM
Write-Host "[7/8] Hardening RDP and WinRM access..." -ForegroundColor Cyan

# RDP - allow only Domain Admins
$rdpGroup = 'BUILTIN\Remote Desktop Users'
$domainAdmins = 'ADLAB\Domain Admins'
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $domainAdmins -ErrorAction SilentlyContinue

# Restrict WinRM to Domain Admins
Enable-PSRemoting -Force -ErrorAction SilentlyContinue
Set-PSSessionConfiguration -Name 'Microsoft.PowerShell' `
    -SecurityDescriptorSddl 'O:NSG:BAD:P(A;;GA;;;DA)S:P(AU;FA;GA;;;WD)(AU;SA;GWGX;;;WD)' `
    -Force -ErrorAction SilentlyContinue

# NLA required for RDP
Set-ItemProperty `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name 'UserAuthentication' `
    -Value 1

Write-Host "     RDP restricted to Domain Admins, NLA enforced." -ForegroundColor Green

# Step 8 - Firewall rules
Write-Host "[8/8] Configuring firewall rules..." -ForegroundColor Cyan

# RD Gateway HTTPS (443) - inbound on MGMT NIC
New-NetFirewallRule -DisplayName 'RD Gateway HTTPS' `
    -Direction Inbound -Protocol TCP -LocalPort 443 `
    -LocalAddress '10.0.3.10' `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue

# RDP (3389) - inbound on both NICs from Domain Admins only
New-NetFirewallRule -DisplayName 'RDP Inbound LAN' `
    -Direction Inbound -Protocol TCP -LocalPort 3389 `
    -LocalAddress '10.0.1.41' `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue

# WinRM (5985/5986) - outbound to LAN targets only
New-NetFirewallRule -DisplayName 'WinRM Outbound to LAN' `
    -Direction Outbound -Protocol TCP -RemotePort 5985,5986 `
    -RemoteAddress '10.0.1.0/24' `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue

Write-Host "     Firewall rules configured." -ForegroundColor Green

Write-Host ""
Write-Host "JUMP01 configuration complete." -ForegroundColor Green
Write-Host ""
Write-Host "Access from laptop via SSH tunnel:" -ForegroundColor Cyan
Write-Host "  ssh -L 3389:10.0.1.41:3389 huber@192.168.18.12 -N" -ForegroundColor White
Write-Host "  Then RDP to: localhost:3389" -ForegroundColor White
Write-Host ""
Write-Host "From jump01, manage all LAN VMs via:" -ForegroundColor Cyan
Write-Host "  mstsc /v:ad01.ad.lab      (RDP to DC)" -ForegroundColor White
Write-Host "  Enter-PSSession ad01      (WinRM to DC)" -ForegroundColor White
