<#
.SYNOPSIS
  Run from the ADMIN account (elevated). Runs the print capability diagnostic BOTH as this admin
  account AND as the "Otzar Hachochma" user in its live logged-on session, then prints the two
  side by side. Lets you reproduce the Otzar-account printing problem from admin - no switching
  users, no copying logs.

.NOTES
  - The Otzar Hachochma user must be LOGGED ON (the kiosk auto-logs it in). The Otzar run uses that
    session's interactive token via a scheduled task, so it needs no password and faithfully
    reproduces the real kiosk session (bridge, per-user print services, its registry hive).
  - Nothing is printed on paper; it only READS printer capabilities.
#>
$ErrorActionPreference = 'Continue'
$OtzarUser = 'Otzar Hachochma'
$pub = 'C:\Users\Public\Documents\OtzarKiosk'
$out = "$pub\admin-vs-otzar.log"
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Path $pub -Force | Out-Null }
Remove-Item $out -ErrorAction SilentlyContinue

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an ELEVATED PowerShell (admin)."
}

# ---- the probe: writes tagged, timed capability lines to $out (readable by admin afterwards) ----
$probe = @'
param($tag, $out)
function P($m) { try { Add-Content -LiteralPath $out -Value ("{0}  [{1,-5}]  {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $tag, $m) } catch {} }
P "==================== $tag  user=$env:USERNAME  session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId) ===================="
try { Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)print|spool|workflow|deviceconfig|deviceassoc' } | ForEach-Object { P "svc $($_.Name) = $($_.Status) [$($_.StartType)]" } } catch { P "svc err: $($_.Exception.Message)" }
try { $b=$false; Get-Process HttpToUsbBridge -ErrorAction SilentlyContinue | ForEach-Object { $b=$true; P "bridge pid=$($_.Id) session=$($_.SessionId)" }; if (-not $b) { P "bridge: NONE running" } } catch {}
try { Get-NetTCPConnection -LocalPort 50000 -ErrorAction SilentlyContinue | ForEach-Object { $pr=Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; P "port50000 $($_.State) pid=$($_.OwningProcess) name=$($pr.ProcessName) session=$($pr.SessionId)" } } catch {}
Add-Type -AssemblyName System.Drawing
foreach ($pn in @('Brother MFC-J4355DW','Microsoft Print to PDF')) {
  $sw=[System.Diagnostics.Stopwatch]::StartNew(); P "cap '$pn' START"
  try {
    $ps=New-Object System.Drawing.Printing.PrinterSettings; $ps.PrinterName=$pn
    P "cap '$pn' IsValid=$($ps.IsValid) @ $($sw.ElapsedMilliseconds)ms"
    $c='ERR'; try { $c=$ps.PaperSizes.Count } catch { $c="EXC:$($_.Exception.Message)" }; P "cap '$pn' PaperSizes=$c @ $($sw.ElapsedMilliseconds)ms"
    $r='ERR'; try { $r=$ps.PrinterResolutions.Count } catch { $r="EXC:$($_.Exception.Message)" }; P "cap '$pn' Resolutions=$r @ $($sw.ElapsedMilliseconds)ms"
  } catch { P "cap '$pn' OUTER EXC $($_.Exception.Message) @ $($sw.ElapsedMilliseconds)ms" }
}
P "==================== END $tag ===================="
'@
$probeFile = "$pub\print-probe.ps1"     # public folder: Otzar can read it; kioskbar.exe can run it
Set-Content -LiteralPath $probeFile -Value $probe -Encoding UTF8

Write-Host "1/2  Running the probe as ADMIN ($env:USERNAME)..." -ForegroundColor Cyan
& $probeFile -tag 'ADMIN' -out $out

Write-Host "2/2  Running the probe as '$OtzarUser' in its live session (this can take ~2 min if the Brother query is slow there)..." -ForegroundColor Cyan
$exe = @('D:\Kiosk\kioskbar.exe','C:\Kiosk\kioskbar.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }   # fallback (only works if not denied)
$tn = 'OtzarPrintProbe'
try {
    $loggedOn = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object { ($_ | Invoke-CimMethod -MethodName GetOwner).User }) -contains ($OtzarUser.Split(' ')[0]) -or `
                (@(Get-Process kioskbar -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $loggedOn) { Write-Host "  NOTE: '$OtzarUser' may not be logged on; the interactive run needs it signed in (it's the kiosk auto-login)." -ForegroundColor Yellow }
    $action    = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -tag OTZAR -out "{1}"' -f $probeFile, $out)
    $principal = New-ScheduledTaskPrincipal -UserId $OtzarUser -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $tn -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $tn
    $deadline = (Get-Date).AddSeconds(160)
    do { Start-Sleep 3 } until (((Get-Content $out -ErrorAction SilentlyContinue | Select-String 'END OTZAR')) -or ((Get-Date) -gt $deadline))
} catch {
    Add-Content -LiteralPath $out -Value "  [OTZAR]  could not launch as $OtzarUser : $($_.Exception.Message)"
} finally {
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host "`n=================== ADMIN vs OTZAR (also saved to $out) ===================" -ForegroundColor Green
Get-Content $out
Write-Host "==========================================================================" -ForegroundColor Green
Write-Host "Compare the 'cap' timing lines: ADMIN should be fast; if OTZAR is slow/EXC, that is the bug." -ForegroundColor Cyan
