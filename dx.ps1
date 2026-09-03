<#
  dx.ps1 - one-shot "why is the print capability query slow in the Otzar session" diagnostic.
  Run from the ADMIN account (elevated), ideally while the kiosk is showing the Otzar session.
  It runs the capability probe AS the Otzar user, samples WHAT the probe process waits on during
  the ~60s query (TCP connections + thread/responding state), and best-effort runs Process Monitor
  to log the exact denied / timing-out operation. Writes results to Downloads and prints a summary.
  Nothing prints on paper. Safe to re-run.
#>
$ErrorActionPreference = 'Continue'
$OtzarUser = 'Otzar Hachochma'
$pub  = 'C:\Users\Public\Documents\OtzarKiosk'
$res  = "$env:USERPROFILE\Downloads\dx-result.txt"
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Path $pub -Force | Out-Null }
foreach ($f in "$pub\dx-probe.log","$pub\dx-probe.pid","$res") { Remove-Item $f -ErrorAction SilentlyContinue }
function Say($m) { Write-Host $m; Add-Content -LiteralPath $res -Value $m }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run elevated (admin)." }
Say "===== dx  $(Get-Date) ====="

# ---- the probe: writes its PID first, then times each capability sub-call for every printer ----
$probe = @'
param($out, $pidfile)
Set-Content -LiteralPath $pidfile -Value $PID
function P($m){ try { Add-Content -LiteralPath $out -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'),$m) } catch {} }
P "PROBE pid=$PID user=$env:USERNAME session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)"
Add-Type -AssemblyName System.Drawing
foreach($pn in @('Brother MFC-J4355DW','Microsoft Print to PDF')){
  $sw=[System.Diagnostics.Stopwatch]::StartNew(); P "cap '$pn' START"
  try{ $ps=New-Object System.Drawing.Printing.PrinterSettings; $ps.PrinterName=$pn
    P "cap '$pn' IsValid=$($ps.IsValid) @ $($sw.ElapsedMilliseconds)ms"
    $c='ERR'; try{$c=$ps.PaperSizes.Count}catch{$c="EXC:$($_.Exception.Message)"}; P "cap '$pn' PaperSizes=$c @ $($sw.ElapsedMilliseconds)ms"
  }catch{ P "cap '$pn' EXC $($_.Exception.Message) @ $($sw.ElapsedMilliseconds)ms" }
}
P "END"
'@
$probeFile = "$pub\dx-probe.ps1"; Set-Content -LiteralPath $probeFile -Value $probe -Encoding UTF8
$plog = "$pub\dx-probe.log"; $pidf = "$pub\dx-probe.pid"
$exe = @('D:\Kiosk\kioskbar.exe','C:\Kiosk\kioskbar.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }

# ---- best-effort Process Monitor download + start ----
$pmDir = "$env:TEMP\dxpm"; $pm = "$pmDir\Procmon.exe"; $pml = "$pmDir\dx.pml"; $pmCsv = "$pub\dx-procmon.csv"; $pmOn = $false
try {
    if (-not (Test-Path $pm)) {
        New-Item -ItemType Directory -Path $pmDir -Force | Out-Null
        Say "downloading Process Monitor..."
        Invoke-WebRequest "https://download.sysinternals.com/files/ProcessMonitor.zip" -OutFile "$pmDir\pm.zip" -UseBasicParsing -TimeoutSec 60
        Expand-Archive "$pmDir\pm.zip" $pmDir -Force
    }
    if (Test-Path $pm) { Start-Process $pm -ArgumentList "/AcceptEula /Quiet /Minimized /BackingFile `"$pml`"" -WindowStyle Hidden; Start-Sleep 4; $pmOn = $true; Say "Process Monitor capturing." }
} catch { Say "ProcMon unavailable ($($_.Exception.Message)); continuing with network/thread sampling only." }

# ---- launch the probe as Otzar ----
$tn = 'DxProbe'; $restorePw = $false; $otzarPid = $null
try {
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -out "{1}" -pidfile "{2}"' -f $probeFile,$plog,$pidf)
    if (@(Get-Process kioskbar -ErrorAction SilentlyContinue).Count -gt 0) {
        Say "Otzar is logged on -> running in its live session (interactive token)."
        $principal = New-ScheduledTaskPrincipal -UserId $OtzarUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $tn -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    } else {
        Say "Otzar not logged on -> temp password (restored after). NOTE: batch session may hang; best run while the kiosk is showing Otzar."
        $tmpPw = 'Dx!' + (Get-Random -Maximum 999999); cmd /c "net user `"$OtzarUser`" `"$tmpPw`"" | Out-Null; $restorePw = $true
        Register-ScheduledTask -TaskName $tn -Action $action -User $OtzarUser -Password $tmpPw -RunLevel Limited -Force -ErrorAction Stop | Out-Null
    }
    Start-ScheduledTask -TaskName $tn

    # ---- sample what the probe waits on, while it runs ----
    $d0 = (Get-Date)
    while (-not $otzarPid -and ((Get-Date) - $d0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 500; $otzarPid = (Get-Content $pidf -ErrorAction SilentlyContinue | Select-Object -First 1) }
    if ($otzarPid) {
        Say "probe pid=$otzarPid - sampling its waits every 2s:"
        $deadline = (Get-Date).AddSeconds(140)
        do {
            $done  = Get-Content $plog -ErrorAction SilentlyContinue | Select-String 'END$'
            $conns = @(Get-NetTCPConnection -OwningProcess $otzarPid -ErrorAction SilentlyContinue)
            $cs = if ($conns) { ($conns | ForEach-Object { "$($_.State)->$($_.RemoteAddress):$($_.RemotePort)" }) -join ', ' } else { 'no TCP' }
            $pr = Get-Process -Id $otzarPid -ErrorAction SilentlyContinue
            Say ("  {0}  net=[{1}]  threads={2} responding={3}" -f (Get-Date -Format 'HH:mm:ss'), $cs, $(if($pr){$pr.Threads.Count}else{'?'}), $(if($pr){$pr.Responding}else{'gone'}))
            Start-Sleep 2
        } until ($done -or ((Get-Date) -gt $deadline))
    } else { Say "never got the probe PID (probe may not have started - is Otzar's kiosk exe present, and is Otzar logged on?)." }
} catch { Say "probe launch err: $($_.Exception.Message)" }
finally {
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    if ($restorePw) { cmd /c "net user `"$OtzarUser`" `"`"" | Out-Null; Say "restored '$OtzarUser' blank password." }
}

# ---- stop + parse ProcMon ----
if ($pmOn) {
    try {
        Start-Process $pm -ArgumentList "/Terminate" -WindowStyle Hidden -Wait; Start-Sleep 3
        Start-Process $pm -ArgumentList "/OpenLog `"$pml`" /SaveAs `"$pmCsv`"" -WindowStyle Hidden -Wait; Start-Sleep 2
        if (Test-Path $pmCsv) {
            $rows = Import-Csv $pmCsv -ErrorAction SilentlyContinue
            $mine = $rows | Where-Object { $_.PID -eq $otzarPid -or $_.'Process Name' -match '(?i)kioskbar|powershell' }
            Say "`n--- ProcMon: NON-SUCCESS results for the probe process ---"
            $mine | Where-Object { $_.Result -and $_.Result -ne 'SUCCESS' } | Group-Object Result | Sort-Object Count -Descending | ForEach-Object { Say ("  {0} x {1}" -f $_.Count, $_.Name) }
            Say "`n--- sample denied / not-found / network (top 30) ---"
            $mine | Where-Object { $_.Result -match '(?i)DENIED|NOT FOUND|TIMEOUT|BAD NETWORK|NO SUCH' } | Select-Object -First 30 | ForEach-Object { Say ("  [{0}] {1}  {2}" -f $_.Result, $_.Operation, $_.Path) }
            Say "`n--- TCP/UDP ops by the probe (top 20) ---"
            $mine | Where-Object { $_.Operation -match '(?i)TCP|UDP' } | Select-Object -First 20 | ForEach-Object { Say ("  {0}  {1}  {2}" -f $_.Operation, $_.Path, $_.Result) }
            Say "(full ProcMon CSV: $pmCsv)"
        }
    } catch { Say "ProcMon parse err: $($_.Exception.Message)" }
}

Say "`n--- probe timing (dx-probe.log) ---"
Get-Content $plog -ErrorAction SilentlyContinue | ForEach-Object { Say "  $_" }
Say "`n===== dx done. Send me:  $res   and (if present)  $pmCsv  ====="
Write-Host "`nResults saved to $res" -ForegroundColor Green
