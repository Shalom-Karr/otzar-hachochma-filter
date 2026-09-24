# brother-ippusb-probe.ps1 - find the Brother's IPP-over-USB endpoint on the kiosk.
# Run on the kiosk (Brother connected by USB). No admin needed. Copy ALL output back.
$ErrorActionPreference = 'Continue'
function H($m){ Write-Host "`n===== $m =====" -ForegroundColor Cyan }

H "1. installed printers + their ports"
Get-Printer -EA SilentlyContinue | Select-Object Name,PortName,DriverName,PrinterStatus | Format-Table -Auto | Out-String | Write-Host
H "1b. printer ports (look for http:// or ipp:// or a 127.0.0.1 host)"
Get-PrinterPort -EA SilentlyContinue | Select-Object Name,Description,PrinterHostAddress,PortNumber | Format-Table -Auto | Out-String | Write-Host

H "2. Brother / bridge processes running"
Get-Process -EA SilentlyContinue | Where-Object { $_.ProcessName -match 'Brother|HttpToUsb|BrCtrl|BrStsMon|ipp|usb' } |
  Select-Object ProcessName,Id,Path | Format-Table -Auto | Out-String | Write-Host

H "3. localhost (127.0.0.1) listening ports + owning process"
try {
  $conns = Get-NetTCPConnection -State Listen -EA SilentlyContinue | Where-Object { $_.LocalAddress -in '127.0.0.1','0.0.0.0','::1','::' }
  $conns | ForEach-Object {
    $p = Get-Process -Id $_.OwningProcess -EA SilentlyContinue
    [pscustomobject]@{ Port=$_.LocalPort; Addr=$_.LocalAddress; PID=$_.OwningProcess; Proc=$p.ProcessName }
  } | Sort-Object Port -Unique | Format-Table -Auto | Out-String | Write-Host
} catch { "Get-NetTCPConnection failed: $($_.Exception.Message)" }

H "4. Brother Run-key entries (bridge exe path)"
foreach($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'){
  Get-ItemProperty $k -EA SilentlyContinue | ForEach-Object {
    $_.PSObject.Properties | Where-Object { $_.Value -match 'Brother|HttpToUsb' } | ForEach-Object { "  $($_.Name) = $($_.Value)" }
  }
}

H "5. probe candidate localhost ports for HTTP/IPP (GET / and an IPP path)"
$ports = @(80,631,8080,54921,54922,49000,49001,49002,49152,49153,49154,8611,8612,9100) + ($conns.LocalPort | Sort-Object -Unique)
$ports = $ports | Sort-Object -Unique
foreach($pt in $ports){
  foreach($path in @('/','/ipp/print','/ipp/printer','/ipp')){
    try {
      $u = "http://127.0.0.1:$pt$path"
      $r = Invoke-WebRequest -Uri $u -Method Head -TimeoutSec 2 -UseBasicParsing -EA Stop
      "  RESPONDS  $u  -> HTTP $($r.StatusCode)  Server=$($r.Headers.Server)"
    } catch {
      $resp = $_.Exception.Response
      if ($resp) { "  responds  http://127.0.0.1:$pt$path -> HTTP $([int]$resp.StatusCode) $($resp.StatusDescription)" }
    }
  }
}
Write-Host "`n(Lines that say RESPONDS/responds are live endpoints. IPP usually lives on /ipp/print or port 631.)" -ForegroundColor Yellow
H "done - copy everything above back"
