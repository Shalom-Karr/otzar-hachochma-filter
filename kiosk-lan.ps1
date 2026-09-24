# kiosk-lan.ps1 - ONE script to run on the kiosk (elevated). Does three things:
#   1. creates a LOCAL admin account for LAN file-copy / remote management (MS-account/PIN can't auth over the network)
#   2. probes the Brother IPP-over-USB endpoint (localhost port + path) so RawPrint can print driverless
#   3. prints a check summary + how to connect from the other PC
# Prompts for the new password at runtime - nothing secret is stored in this file.
$ErrorActionPreference = 'Continue'
function H($m){ Write-Host "`n===== $m =====" -ForegroundColor Cyan }
$result = 'C:\Users\Public\OtzarKiosk\kiosk-lan-result.txt'
try { New-Item -ItemType Directory -Path (Split-Path $result) -Force | Out-Null } catch {}
try { Remove-Item $result -Force -EA SilentlyContinue } catch {}
function P($m){ Write-Host $m; try { Add-Content -LiteralPath $result -Value $m } catch {} }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
P "===== kiosk-lan $(Get-Date) on $env:COMPUTERNAME (user $env:USERNAME, elevated=$admin) ====="

# ---------------- 1. LOCAL ADMIN ACCOUNT ----------------
H "1. create local admin account for LAN access"
if (-not $admin) {
    P "  SKIPPED - not elevated. Re-run in an ADMIN PowerShell to create the account (the probe below still runs)."
} else {
    $User = Read-Host "New local admin username (press Enter for 'lanadmin')"
    if ([string]::IsNullOrWhiteSpace($User)) { $User = 'lanadmin' }
    $pw1 = Read-Host "Password for $User" -AsSecureString
    $pw2 = Read-Host "Confirm password"   -AsSecureString
    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
    if ($p1 -ne $p2)      { P "  ERROR: passwords do not match - re-run to create the account." }
    elseif ($p1.Length -lt 4) { P "  ERROR: password too short (min 4) - re-run to create the account." }
    else {
        try {
            if (Get-LocalUser -Name $User -EA SilentlyContinue) {
                Set-LocalUser -Name $User -Password $pw1; P "  updated existing account '$User' password."
            } else {
                New-LocalUser -Name $User -Password $pw1 -FullName "LAN Admin" -Description "LAN file copy / remote management" -PasswordNeverExpires -AccountNeverExpires | Out-Null
                P "  created local account '$User'."
            }
            Enable-LocalUser -Name $User -EA SilentlyContinue
            try { Set-LocalUser -Name $User -PasswordNeverExpires $true } catch {}
            try { Add-LocalGroupMember -Group 'Administrators' -Member $User -EA Stop; P "  added '$User' to Administrators." }
            catch { if ($_.Exception.Message -match 'already a member') { P "  '$User' already an Administrator." } else { P "  add-admin error: $($_.Exception.Message)" } }
            reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f | Out-Null
            P "  enabled LocalAccountTokenFilterPolicy (remote admin over LAN)."
            try { Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -EA SilentlyContinue; Enable-NetFirewallRule -DisplayGroup 'Windows Management Instrumentation (WMI)' -EA SilentlyContinue; P "  file-sharing + WMI firewall rules enabled." } catch {}
            $script:lanUser = $User
        } catch { P "  account setup error: $($_.Exception.Message)" }
    }
}

# ---------------- 2. BROTHER IPP-OVER-USB PROBE ----------------
H "2a. printers + ports"
Get-Printer -EA SilentlyContinue | Select-Object Name,PortName,DriverName,PrinterStatus | Format-Table -Auto | Out-String | ForEach-Object { P $_ }
Get-PrinterPort -EA SilentlyContinue | Select-Object Name,Description,PrinterHostAddress,PortNumber | Format-Table -Auto | Out-String | ForEach-Object { P $_ }

H "2b. Brother / bridge processes"
Get-Process -EA SilentlyContinue | Where-Object { $_.ProcessName -match 'Brother|HttpToUsb|BrCtrl|BrStsMon|ipp|usb' } | Select-Object ProcessName,Id,Path | Format-Table -Auto | Out-String | ForEach-Object { P $_ }

H "2c. localhost listening ports + owning process"
$conns = Get-NetTCPConnection -State Listen -EA SilentlyContinue | Where-Object { $_.LocalAddress -in '127.0.0.1','0.0.0.0','::1','::' }
$conns | ForEach-Object { $pr = Get-Process -Id $_.OwningProcess -EA SilentlyContinue; [pscustomobject]@{ Port=$_.LocalPort; Addr=$_.LocalAddress; Proc=$pr.ProcessName } } | Sort-Object Port -Unique | Format-Table -Auto | Out-String | ForEach-Object { P $_ }

H "2d. Brother Run-key entries (bridge exe path)"
foreach($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'){
  Get-ItemProperty $k -EA SilentlyContinue | ForEach-Object { $_.PSObject.Properties | Where-Object { $_.Value -match 'Brother|HttpToUsb' } | ForEach-Object { P ("  {0} = {1}" -f $_.Name,$_.Value) } }
}

H "2e. probe localhost ports for HTTP/IPP (the endpoint RawPrint will use)"
$ports = @(80,631,8080,54921,54922,49000,49001,49002,49152,49153,49154,8611,8612,9100) + ($conns.LocalPort) | Sort-Object -Unique
foreach($pt in $ports){
  foreach($path in @('/','/ipp/print','/ipp/printer','/ipp')){
    try { $r = Invoke-WebRequest "http://127.0.0.1:$pt$path" -Method Head -TimeoutSec 2 -UseBasicParsing -EA Stop
      P ("  RESPONDS http://127.0.0.1:{0}{1} -> HTTP {2} Server={3}" -f $pt,$path,$r.StatusCode,$r.Headers.Server) }
    catch { $resp = $_.Exception.Response; if ($resp) { P ("  responds http://127.0.0.1:{0}{1} -> HTTP {2}" -f $pt,$path,[int]$resp.StatusCode) } }
  }
}

# ---------------- 3. SUMMARY ----------------
H "3. summary / how to connect from the other PC"
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' } | Select-Object -First 1).IPAddress
P "  this kiosk : $env:COMPUTERNAME  at  $ip"
if ($script:lanUser) { P "  LAN login  : $env:COMPUTERNAME\$($script:lanUser)  (the password you just set; your PIN is unchanged)" }
P "  admin share: \\$ip\C`$"
P "  Lines above that say RESPONDS/responds = live IPP endpoints (IPP is usually /ipp/print or port 631)."
P "  full copy of this output saved to: $result"
Write-Host "`n===== DONE - copy everything above (or send me $result) =====" -ForegroundColor Green
