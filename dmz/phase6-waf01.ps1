# phase6-waf01.ps1
# Run on waf01 - Windows Server 2025 Core
# IIS reverse proxy (Application Request Routing)
# DMZ IP: 10.0.2.12/24  GW: 10.0.2.1
# LAN IP: 10.0.1.62/24  DNS: ad01/ad02

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dmzMac = '52-54-00-F2-F3-7E'
$lanMac  = '52-54-00-A6-19-13'

# Step 1 - Rename
Write-Host "[1/6] Renaming to WAF01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'WAF01') {
    Rename-Computer -NewName 'WAF01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already WAF01." -ForegroundColor Green

# Step 2 - Configure NICs by MAC
Write-Host "[2/6] Configuring NICs..." -ForegroundColor Cyan
$dmzIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $dmzMac }).InterfaceIndex
$lanIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $lanMac }).InterfaceIndex

Remove-NetIPAddress -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $dmzIf -IPAddress '10.0.2.12' -PrefixLength 24 -DefaultGateway '10.0.2.1'

Remove-NetIPAddress -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $lanIf -IPAddress '10.0.1.62' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $lanIf -ServerAddresses '10.0.1.10','10.0.1.11'
Set-DnsClientServerAddress -InterfaceIndex $dmzIf -ServerAddresses ''

Rename-NetAdapter -Name (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $dmzIf }).Name -NewName 'DMZ' -ErrorAction SilentlyContinue
Rename-NetAdapter -Name (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $lanIf }).Name  -NewName 'LAN' -ErrorAction SilentlyContinue

Write-Host "     DMZ: 10.0.2.12/24  GW: 10.0.2.1" -ForegroundColor Green
Write-Host "     LAN: 10.0.1.62/24  (no GW, DNS only)" -ForegroundColor Green

# Step 3 - Join domain
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

# Step 4 - Install IIS
Write-Host "[4/6] Installing IIS..." -ForegroundColor Cyan
Install-WindowsFeature -Name `
    Web-Server, Web-Default-Doc, Web-Http-Logging, `
    Web-Stat-Compression, Web-Filtering, Web-Windows-Auth `
    -IncludeManagementTools
Write-Host "     IIS installed." -ForegroundColor Green

# Step 5 - Download and install ARR + URL Rewrite
Write-Host "[5/6] Installing ARR and URL Rewrite modules..." -ForegroundColor Cyan

$arrUrl     = 'https://download.microsoft.com/download/A/A/2/AA2B9E9E-2AEC-4E6A-94F3-A0B78F48E8C4/ARRv3_setup_amd64_en-us.EXE'
$rewriteUrl = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi'
$tmpPath    = $env:TEMP

try {
    Write-Host "     Downloading URL Rewrite..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $rewriteUrl -OutFile "$tmpPath\urlrewrite.msi" -UseBasicParsing
    Start-Process msiexec -ArgumentList "/i `"$tmpPath\urlrewrite.msi`" /qn" -Wait
    Write-Host "     URL Rewrite installed." -ForegroundColor Green

    Write-Host "     Downloading ARR..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $arrUrl -OutFile "$tmpPath\arr.exe" -UseBasicParsing
    Start-Process "$tmpPath\arr.exe" -ArgumentList '/q' -Wait
    Write-Host "     ARR installed." -ForegroundColor Green
} catch {
    Write-Host "     WARNING: Download failed (check internet via fw01)." -ForegroundColor Yellow
    Write-Host "     Install ARR manually from: https://www.iis.net/downloads/microsoft/application-request-routing" -ForegroundColor White
}

# Enable proxy in IIS
Import-Module WebAdministration -ErrorAction SilentlyContinue
try {
    Set-WebConfigurationProperty -Filter 'system.webServer/proxy' `
        -Name enabled -Value $true -PSPath 'IIS:\' -ErrorAction Stop
    Write-Host "     IIS proxy enabled." -ForegroundColor Green
} catch {
    Write-Host "     WARNING: Could not enable proxy. Enable after ARR install:" -ForegroundColor Yellow
    Write-Host "     Set-WebConfigurationProperty -Filter 'system.webServer/proxy' -Name enabled -Value true -PSPath 'IIS:\'" -ForegroundColor White
}

# Request SSL cert
certutil -pulse | Out-Null
Start-Sleep -Seconds 10
try {
    Get-Certificate -Template WebServer `
        -SubjectName 'CN=waf01.ad.lab' `
        -DnsName 'waf01.ad.lab','waf01' `
        -CertStoreLocation 'Cert:\LocalMachine\My' | Out-Null
    Write-Host "     SSL cert issued." -ForegroundColor Green
} catch {
    Write-Host "     WARNING: Cert request failed. Run certutil -pulse manually." -ForegroundColor Yellow
}

# Configure HTTPS binding
Remove-WebBinding -Name 'Default Web Site' -Protocol http -ErrorAction SilentlyContinue
New-WebBinding    -Name 'Default Web Site' -Protocol https -Port 443 -SslFlags 0 -ErrorAction SilentlyContinue

$thumb = (Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*waf01*' -and $_.Issuer -like '*ADLAB*' } |
    Sort-Object NotAfter -Descending | Select-Object -First 1).Thumbprint
if ($thumb) {
    (Get-WebBinding -Name 'Default Web Site' -Protocol https).AddSslCertificate($thumb,'My')
    Write-Host "     SSL cert bound." -ForegroundColor Green
}

# Step 6 - Firewall
Write-Host "[6/6] Configuring firewall..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName 'HTTPS Inbound WAF' `
    -Direction Inbound -Protocol TCP -LocalPort 443 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue
Write-Host "     Firewall rule added." -ForegroundColor Green

Write-Host ""
Write-Host "WAF01 configuration complete." -ForegroundColor Green
Write-Host ""
Write-Host "After ARR is installed configure reverse proxy rule:" -ForegroundColor Cyan
Write-Host "  Proxy target: https://web01.ad.lab" -ForegroundColor White
Write-Host "  Or use IIS Manager on jump01 to configure URL Rewrite rules" -ForegroundColor White
Write-Host ""
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '10.0.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength
