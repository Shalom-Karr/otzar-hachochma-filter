<#
  test-explorer.ps1 - proves the fix. Runs in Otzar's live kiosk session: starts explorer.exe, waits,
  then times the printer capability query. If it becomes fast (~2s) with explorer running, the fix is
  to have the kiosk start explorer at login. Run from ADMIN (elevated) while Otzar is logged in.
#>
$ErrorActionPreference = 'Continue'
$OtzarUser = 'Otzar Hachochma'
$pub = 'C:\Users\Public\Documents\OtzarKiosk'
$res = "$env:USERPROFILE\Downloads\test-explorer-result.txt"
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Path $pub -Force | Out-Null }
try { icacls $pub /grant "${OtzarUser}:(OI)(CI)M" /grant "*S-1-5-32-545:(OI)(CI)M" /T /Q 2>$null | Out-Null } catch {}
Remove-Item $res,"$pub\te.log" -ErrorAction SilentlyContinue
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run elevated (admin)." }
function Say($m){ Write-Host $m; Add-Content -LiteralPath $res -Value $m }
Say "===== test-explorer $(Get-Date) ====="

$probe = @'
param($out)
function P($m){ try { Add-Content -LiteralPath $out -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'),$m) } catch {} }
P "session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId) user=$env:USERNAME"
P "explorer before: $((Get-Process explorer -ErrorAction SilentlyContinue|Measure-Object).Count)"
Start-Process explorer.exe
Start-Sleep 25
P "explorer after: $((Get-Process explorer -ErrorAction SilentlyContinue|Measure-Object).Count)"
Add-Type -AssemblyName System.Drawing
foreach($pn in @('Brother MFC-J4355DW','Microsoft Print to PDF')){
  $sw=[System.Diagnostics.Stopwatch]::StartNew(); P "cap '$pn' START"
  try{ $ps=New-Object System.Drawing.Printing.PrinterSettings; $ps.PrinterName=$pn
    P "cap '$pn' IsValid=$($ps.IsValid) @ $($sw.ElapsedMilliseconds)ms"
    $c=0; try{$c=$ps.PaperSizes.Count}catch{}; P "cap '$pn' PaperSizes=$c @ $($sw.ElapsedMilliseconds)ms" }catch{ P "cap '$pn' EXC $($_.Exception.Message)" }
}
P "END"
'@
$pf = "$pub\te-probe.ps1"; Set-Content -LiteralPath $pf -Value $probe -Encoding UTF8
$plog = "$pub\te.log"
$exe = @('D:\Kiosk\kioskbar.exe','C:\Kiosk\kioskbar.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }
$tn = 'TeProbe'
try {
    if (@(Get-Process kioskbar -ErrorAction SilentlyContinue).Count -eq 0) { Say "STOP: Otzar not logged on - reboot to Otzar, switch to admin, re-run."; return }
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -out "{1}"' -f $pf,$plog)
    $principal = New-ScheduledTaskPrincipal -UserId $OtzarUser -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $tn -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Say "running in Otzar's session: start explorer, then time the capability query (~1-2 min)..."
    Start-ScheduledTask -TaskName $tn
    $deadline = (Get-Date).AddSeconds(180)
    do { Start-Sleep 3 } until ((Get-Content $plog -ErrorAction SilentlyContinue | Select-String 'END$') -or ((Get-Date) -gt $deadline))
} catch { Say "err: $($_.Exception.Message)" }
finally { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue }

Say "`n--- result (te.log) ---"
Get-Content $plog -ErrorAction SilentlyContinue | ForEach-Object { Say "  $_" }
Say "`nIf 'PaperSizes' is now ~2000ms (not ~60000ms), starting explorer is the fix."
