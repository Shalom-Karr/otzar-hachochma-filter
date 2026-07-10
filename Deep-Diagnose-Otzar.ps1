<#
.SYNOPSIS
  Deep diagnosis of the Otzar "Access is denied" error. Drives Process Monitor from the
  script: captures kernel registry + file activity while launching Otzar AS the Otzar user
  under the live lockdown, then prints every ACCESS DENIED (and NAME NOT FOUND) with the
  exact Operation + Path, so we can see the precise registry key / file it can't write.

.NOTES
  Run ELEVATED (as admin / on khaly) with the lockdown applied and internet available
  (it downloads Process Monitor if not already present). It signs the Otzar user out, sets
  a temporary password (1234) to launch as that user, and removes the password when done.
#>
param(
    [string]$OtzarUser = "Otzar Hachochma",
    [string]$Exe       = "D:\OtzarKiosk.exe",
    [int]$Seconds      = 30
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

$work = Join-Path $env:TEMP "OtzDiag"
New-Item -ItemType Directory -Path $work -Force | Out-Null

# --- get Process Monitor ---
$arch = $env:PROCESSOR_ARCHITECTURE
$pmName = switch ($arch) { "ARM64" { "Procmon64a.exe" } "AMD64" { "Procmon64.exe" } default { "Procmon.exe" } }
$pm = Join-Path $work $pmName
if (-not (Test-Path $pm)) {
    Write-Host "Downloading Process Monitor..." -ForegroundColor Cyan
    $zip = Join-Path $work "ProcMon.zip"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "https://download.sysinternals.com/files/ProcessMonitor.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $work -Force
    } catch { throw "Could not download ProcMon: $($_.Exception.Message). Download it manually to $work and re-run." }
}
if (-not (Test-Path $pm)) { $pm = Join-Path $work "Procmon.exe" }   # fallback launcher
if (-not (Test-Path $pm)) { throw "Procmon exe not found in $work" }

$pml = Join-Path $work "otz.pml"
$csv = Join-Path $work "otz.csv"
Remove-Item $pml,$csv -ErrorAction SilentlyContinue

# --- log off the Otzar session, then set a temporary password so we can launch AS that user ---
$line = quser 2>$null | Where-Object { $_ -match [regex]::Escape($OtzarUser) }
if ($line -and ($line -match '\s(\d+)\s+(Active|Disc)')) {
    Write-Host "Signing out Otzar session $($matches[1]) ..." -ForegroundColor Cyan
    logoff $matches[1] 2>$null; Start-Sleep 3
}
Write-Host "Setting temporary password 1234 on '$OtzarUser'..." -ForegroundColor Cyan
net user "$OtzarUser" "1234" 2>$null | Out-Null
$cred = New-Object System.Management.Automation.PSCredential("$env:COMPUTERNAME\$OtzarUser", (ConvertTo-SecureString "1234" -AsPlainText -Force))

try {
    # --- start capture ---
    Write-Host "Starting capture..." -ForegroundColor Cyan
    Start-Process $pm -ArgumentList "/AcceptEula","/Quiet","/Minimized","/BackingFile",$pml
    Start-Sleep -Seconds 5

    Write-Host "Launching Otzar as $OtzarUser (let it try to load / error)..." -ForegroundColor Cyan
    try { Start-Process -FilePath $Exe -Credential $cred -WorkingDirectory (Split-Path $Exe) -ErrorAction Stop } catch { Write-Host "launch: $($_.Exception.Message)" -ForegroundColor Yellow }
    Start-Sleep -Seconds $Seconds

    # --- stop + export to CSV ---
    Write-Host "Stopping capture + exporting..." -ForegroundColor Cyan
    Start-Process $pm -ArgumentList "/Terminate" -Wait
    Start-Sleep -Seconds 4
    Start-Process $pm -ArgumentList "/OpenLog",$pml,"/SaveAs",$csv -Wait
    Start-Sleep -Seconds 4
    Get-Process Procmon,Procmon64,Procmon64a -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $csv)) { throw "CSV not produced ($csv). Open $pml in ProcMon manually and filter Result=ACCESS DENIED." }

    # --- parse ---
    $data = Import-Csv $csv
    $bad = $data | Where-Object { $_.Result -match 'ACCESS DENIED|PRIVILEGE NOT HELD' -and $_.'Process Name' -match '(?i)otzar' }
    if (-not $bad) { $bad = $data | Where-Object { $_.Result -match 'ACCESS DENIED|PRIVILEGE NOT HELD' } }

    Write-Host "`n===== ACCESS DENIED operations during Otzar launch =====" -ForegroundColor Red
    if ($bad) {
        $bad | Select-Object 'Process Name',Operation,Path,Result,Detail | Format-Table -AutoSize -Wrap
        Write-Host "`nMost likely culprit(s) - registry/file writes that were denied:" -ForegroundColor Yellow
        $bad | Where-Object { $_.Operation -match 'SetValue|CreateKey|WriteFile|CreateFile|SetInfo' } | Select-Object Operation,Path -Unique | Format-Table -AutoSize -Wrap
    } else {
        Write-Host "No ACCESS DENIED captured. The error may need the real logon session - reproduce via Switch User to Otzar while a manual ProcMon capture runs." -ForegroundColor Yellow
    }
    Write-Host "`nFull log: $csv" -ForegroundColor DarkGray
}
finally {
    # --- always remove the temporary password ---
    net user "$OtzarUser" "" 2>$null | Out-Null
    Write-Host "Removed the temporary password from '$OtzarUser'." -ForegroundColor Green
}
