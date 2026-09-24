# create-lan-admin.ps1 - create a LOCAL admin account on the kiosk for LAN file copy + remote
# management (the kiosk signs in with a Microsoft account / PIN, which can't authenticate over SMB/WMI).
# RUN IN AN ELEVATED PowerShell ON THE KIOSK. Prompts for the password - nothing secret is stored here.
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "NOT elevated. Open PowerShell as Administrator (Start > type powershell > right-click > Run as administrator) and re-run." -ForegroundColor Red
    return
}

$User = Read-Host "New local admin username (press Enter for 'lanadmin')"
if ([string]::IsNullOrWhiteSpace($User)) { $User = 'lanadmin' }
$pw1 = Read-Host "Password for $User" -AsSecureString
$pw2 = Read-Host "Confirm password"   -AsSecureString
$p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
if ($p1 -ne $p2)      { Write-Host "Passwords do not match - re-run." -ForegroundColor Red; return }
if ($p1.Length -lt 4) { Write-Host "Use a password of at least 4 characters - re-run." -ForegroundColor Red; return }

# --- create (or update) the account ---
if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $User -Password $pw1
    Write-Host "updated existing account '$User' password." -ForegroundColor Yellow
} else {
    New-LocalUser -Name $User -Password $pw1 -FullName "LAN Admin" -Description "LAN file copy / remote management" -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Write-Host "created local account '$User'." -ForegroundColor Green
}
Enable-LocalUser -Name $User -ErrorAction SilentlyContinue
try { Set-LocalUser -Name $User -PasswordNeverExpires $true } catch {}

# --- make it a local administrator ---
try { Add-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction Stop; Write-Host "added '$User' to Administrators." -ForegroundColor Green }
catch { if ($_.Exception.Message -match 'already a member') { Write-Host "'$User' already an Administrator." -ForegroundColor Yellow } else { throw } }

# --- allow a LOCAL admin account to manage this PC over the network (C$ admin share + WMI in a workgroup) ---
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f | Out-Null
Write-Host "enabled LocalAccountTokenFilterPolicy (remote admin over LAN)." -ForegroundColor Green

# --- ensure the sharing/WMI firewall rules are on (needed for 445 / 135) ---
try {
    Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup 'Windows Management Instrumentation (WMI)' -ErrorAction SilentlyContinue
    Write-Host "file-sharing + WMI firewall rules enabled." -ForegroundColor Green
} catch {}

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' } | Select-Object -First 1).IPAddress
Write-Host "`n================ DONE ================" -ForegroundColor Cyan
Write-Host " From the OTHER PC, connect as:" -ForegroundColor Cyan
Write-Host "   user : $env:COMPUTERNAME\$User"
Write-Host "   host : \\$ip\C`$   (this kiosk is $ip)"
Write-Host " Your PIN sign-in is unchanged." -ForegroundColor DarkGray
Write-Host "=====================================" -ForegroundColor Cyan
