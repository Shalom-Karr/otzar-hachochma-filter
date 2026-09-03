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

Write-Host "2/2  Running the probe as '$OtzarUser' (this can take ~2 min if the Brother query is slow there)..." -ForegroundColor Cyan
$exe = @('D:\Kiosk\kioskbar.exe','C:\Kiosk\kioskbar.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }   # fallback (only works if not denied)
$tn = 'OtzarPrintProbe'
$restorePw = $false
try {
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -tag OTZAR -out "{1}"' -f $probeFile, $out)
    # Is Otzar already logged on? kioskbar.exe only runs in the Otzar session -> a reliable signal.
    $otzarLoggedOn = @(Get-Process kioskbar -ErrorAction SilentlyContinue).Count -gt 0
    if ($otzarLoggedOn) {
        # BEST: run in Otzar's LIVE session via its interactive token (no password, faithful - real bridge + per-user services)
        Write-Host "  '$OtzarUser' is logged on -> running in its live session (interactive token)." -ForegroundColor DarkGray
        $principal = New-ScheduledTaskPrincipal -UserId $OtzarUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $tn -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    } else {
        # AUTO: Otzar is not logged in. Blank passwords are blocked for batch logon, so set a
        # TEMP password, run the probe as Otzar (batch logon - no manual sign-in), then restore
        # the blank password so kiosk auto-login keeps working. (Non-interactive: the USB bridge
        # may not be up, so a slow/failed Brother query here still points at the driver path.)
        Write-Host "  '$OtzarUser' is not logged on -> auto-running it via a temporary password (restored afterward)." -ForegroundColor DarkGray
        $tmpPw = 'OtzarProbe!' + (Get-Random -Maximum 999999)
        cmd /c "net user `"$OtzarUser`" `"$tmpPw`"" | Out-Null
        $restorePw = $true
        Register-ScheduledTask -TaskName $tn -Action $action -User $OtzarUser -Password $tmpPw -RunLevel Limited -Force -ErrorAction Stop | Out-Null
    }
    Start-ScheduledTask -TaskName $tn
    $deadline = (Get-Date).AddSeconds(160)
    do { Start-Sleep 3 } until (((Get-Content $out -ErrorAction SilentlyContinue | Select-String 'END OTZAR')) -or ((Get-Date) -gt $deadline))
    if (-not (Get-Content $out -ErrorAction SilentlyContinue | Select-String 'END OTZAR')) { Add-Content -LiteralPath $out -Value "  [OTZAR]  (timed out after 160s - the Brother query never returned)" }
} catch {
    Add-Content -LiteralPath $out -Value "  [OTZAR]  could not launch as $OtzarUser : $($_.Exception.Message)"
} finally {
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    if ($restorePw) { cmd /c "net user `"$OtzarUser`" `"`"" | Out-Null; Write-Host "  restored '$OtzarUser' blank password (auto-login intact)." -ForegroundColor DarkGray }
}

Write-Host "`n=================== ADMIN vs OTZAR (also saved to $out) ===================" -ForegroundColor Green
Get-Content $out
Write-Host "==========================================================================" -ForegroundColor Green
Write-Host "Compare the 'cap' timing lines: ADMIN should be fast; if OTZAR is slow/EXC, that is the bug." -ForegroundColor Cyan
