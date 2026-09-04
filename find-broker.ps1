<#
  find-broker.ps1 - reverse-engineer WHAT explorer provides that makes printing fast, so we can start
  just that (no taskbar/desktop). Run from ADMIN (elevated) while Otzar is logged in. In the Otzar
  session it: (1) times the printer capability query cold, (2) starts explorer, lists the NEW processes
  it spawned + re-times (fast), (3) kills ONLY explorer.exe, lists survivors + re-times - telling us
  which UI-less helper (sihost/RuntimeBroker/etc.) is the real broker and whether it persists.
  Takes a few minutes (the cold query is ~60s). Nothing prints on paper.
#>
$ErrorActionPreference = 'Continue'
$OtzarUser = 'Otzar Hachochma'
$pub = 'C:\Users\Public\Documents\OtzarKiosk'
$res = "$env:USERPROFILE\Downloads\find-broker-result.txt"
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Path $pub -Force | Out-Null }
try { icacls $pub /grant "${OtzarUser}:(OI)(CI)M" /grant "*S-1-5-32-545:(OI)(CI)M" /T /Q 2>$null | Out-Null } catch {}
Remove-Item $res, "$pub\fb.log" -ErrorAction SilentlyContinue
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run elevated (admin)." }
function Say($m){ Write-Host $m; Add-Content -LiteralPath $res -Value $m }
Say "===== find-broker $(Get-Date) ====="

$probe = @'
param($out)
function P($m){ try { Add-Content -LiteralPath $out -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'),$m) } catch {} }
function Caps {
  Add-Type -AssemblyName System.Drawing
  $sw=[System.Diagnostics.Stopwatch]::StartNew()
  try { $ps=New-Object System.Drawing.Printing.PrinterSettings; $ps.PrinterName='Brother MFC-J4355DW'
    $iv=$ps.IsValid; $pc=0; try{$pc=$ps.PaperSizes.Count}catch{}
    return ("PaperSizes={0} IsValid={1} in {2}ms" -f $pc,$iv,$sw.ElapsedMilliseconds) } catch { return "EXC $($_.Exception.Message)" }
}
function Procs { Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique | Sort-Object }
P "session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId) user=$env:USERNAME"
$before = @(Procs)
P "explorer running at start: $((Get-Process explorer -ErrorAction SilentlyContinue|Measure-Object).Count)"
P "[1] COLD caps (no explorer): $(Caps)"
P "starting explorer..."
Start-Process explorer.exe
Start-Sleep 15
$after = @(Procs)
$new = @($after | Where-Object { $_ -notin $before })
P "NEW processes explorer spawned: $($new -join ', ')"
P "[2] caps WITH explorer: $(Caps)"
P "killing explorer.exe only..."
Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 6
$after2 = @(Procs)
$survivors = @($new | Where-Object { $_ -in $after2 })
P "survivors after killing explorer: $($survivors -join ', ')"
P "[3] caps AFTER explorer killed: $(Caps)"
P "END"
'@
$pf = "$pub\fb-probe.ps1"; Set-Content -LiteralPath $pf -Value $probe -Encoding UTF8
$plog = "$pub\fb.log"
$exe = @('D:\Kiosk\kioskbar.exe','C:\Kiosk\kioskbar.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $exe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }
$tn = 'FbProbe'
try {
    if (@(Get-Process kioskbar -ErrorAction SilentlyContinue).Count -eq 0) { Say "STOP: Otzar not logged on - reboot to Otzar, switch to admin, re-run."; return }
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -out "{1}"' -f $pf,$plog)
    $principal = New-ScheduledTaskPrincipal -UserId $OtzarUser -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $tn -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Say "running the broker-finder in Otzar's session (a few minutes; the cold query alone is ~60s)..."
    Start-ScheduledTask -TaskName $tn
    $deadline = (Get-Date).AddSeconds(300)
    do { Start-Sleep 4 } until ((Get-Content $plog -ErrorAction SilentlyContinue | Select-String 'END$') -or ((Get-Date) -gt $deadline))
} catch { Say "err: $($_.Exception.Message)" }
finally { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue }

Say "`n--- result (fb.log) ---"
Get-Content $plog -ErrorAction SilentlyContinue | ForEach-Object { Say "  $_" }
Say "`nRead: [2] should be fast, [1] slow. If [3] is STILL fast, a survivor process is the broker - start that (no taskbar) instead of explorer."
