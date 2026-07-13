<#
.SYNOPSIS
  One diagnostic tool for the Otzar Hachochma kiosk (merges the old Diagnose-Kiosk +
  Deep-Diagnose-Otzar scripts).

  Default (no switch): a READ-ONLY report - account, ALL its profiles (catches the
  duplicate-profile bug), the ACTIVE profile's shell + USB policy, kiosk files, the Otzar
  symlink target, NTFS execute-deny status, D: drive type, and a dump of the runtime logs
  in C:\Users\Public\Documents\OtzarKiosk. It signs the Otzar user out (to read its hive)
  but makes NO changes.

  -Deep: drives Process Monitor to capture the Otzar "Access is denied" error - launches
  Otzar AS the Otzar user under the live lockdown and prints every ACCESS DENIED with the
  exact Operation + Path. This one DOES change things temporarily (sets password 1234 to
  launch as the user, then removes it) and needs internet the first time (downloads ProcMon).

.NOTES
  Run ELEVATED (as admin / on khaly).

.EXAMPLE
  .\diagnostics.ps1            # read-only kiosk report + logs
.EXAMPLE
  .\diagnostics.ps1 -Deep      # ProcMon capture of the Access-is-denied error
#>
param(
    [string]$OtzarUser = "Otzar Hachochma",
    [switch]$Deep,                          # run the Process Monitor "Access is denied" capture
    [string]$Exe      = "D:\OtzarKiosk.exe",
    [int]$Seconds     = 30
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

# =========================================================================================
#  READ-ONLY KIOSK REPORT (default)
# =========================================================================================
function Invoke-KioskReport {
    Write-Host "===== ACCOUNT =====" -ForegroundColor Cyan
    $u = Get-LocalUser $OtzarUser -ErrorAction SilentlyContinue
    if (-not $u) { Write-Host "Account '$OtzarUser' NOT FOUND." -ForegroundColor Red; return }
    $sid = $u.SID.Value
    "Name    : $($u.Name)"
    "Enabled : $($u.Enabled)"
    "SID     : $sid"
    $admins = (Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue).SID.Value
    "Admin?  : " + [bool]($admins -contains $sid)

    Write-Host "`n===== PROFILES (duplicate = the bug) =====" -ForegroundColor Cyan
    Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue | Where-Object Name -like "*$OtzarUser*" | Select-Object Name | Format-Table -AutoSize
    $prof = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    Write-Host "ACTIVE profile (by SID): $prof" -ForegroundColor Yellow

    Write-Host "`n===== KIOSK FILES =====" -ForegroundColor Cyan
    "D:\OtzarKiosk.exe       : $(Test-Path 'D:\OtzarKiosk.exe')  ->  $((Get-Item 'D:\OtzarKiosk.exe' -ErrorAction SilentlyContinue).Target)"
    "D:\Kiosk\kioskshell.exe : $(Test-Path 'D:\Kiosk\kioskshell.exe')"
    "D:\Kiosk\relaunch.vbs   : $(Test-Path 'D:\Kiosk\relaunch.vbs')"
    "D:\Kiosk\kioskbar.exe   : $(Test-Path 'D:\Kiosk\kioskbar.exe')"
    "D:\Kiosk\kioskbar.ps1   : $(Test-Path 'D:\Kiosk\kioskbar.ps1')"
    "D:\Kiosk\pdfbrowser.ps1 : $(Test-Path 'D:\Kiosk\pdfbrowser.ps1')"
    "D:\Kiosk\pdfopen.ps1    : $(Test-Path 'D:\Kiosk\pdfopen.ps1')"
    Write-Host "Hebrew-named exe(s) on D:\ :"
    Get-ChildItem 'D:\*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '[^\x00-\x7F]' } | Select-Object Name | Format-Table -AutoSize

    Write-Host "===== ACTIVE PROFILE HIVE: shell / USB policy / .pdf handler =====" -ForegroundColor Cyan
    $line = quser 2>$null | Where-Object { $_ -match [regex]::Escape($OtzarUser) }
    if ($line -and ($line -match '\s(\d+)\s+(Active|Disc)')) { Write-Host "Signing out session $($matches[1])..."; logoff $matches[1] 2>$null; Start-Sleep 3 }
    reg load "HKU\Diag" "$prof\NTUSER.DAT" *>$null
    if ($LASTEXITCODE -eq 0) {
        $wl  = "Registry::HKEY_USERS\Diag\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $rsd = "Registry::HKEY_USERS\Diag\Software\Policies\Microsoft\Windows\RemovableStorageDevices"
        $pdf = "Registry::HKEY_USERS\Diag\Software\Classes\.pdf"
        Write-Host ("Shell value            : " + (Get-ItemProperty $wl -ErrorAction SilentlyContinue).Shell) -ForegroundColor Yellow
        "RemovableStorage Deny_All: " + (Get-ItemProperty $rsd -ErrorAction SilentlyContinue).Deny_All + "   (1 here can block D: and black-screen!)"
        ".pdf handler (ProgId)    : " + (Get-ItemProperty $pdf -ErrorAction SilentlyContinue).'(default)'
        [gc]::Collect(); Start-Sleep 2; reg unload "HKU\Diag" *>$null
    } else {
        Write-Host "Could NOT load the hive - is '$OtzarUser' still signed in? Sign it out and re-run." -ForegroundColor Red
    }

    Write-Host "`n===== NTFS execute-deny for the user =====" -ForegroundColor Cyan
    foreach ($f in "C:\Windows\explorer.exe","C:\Windows\System32\cmd.exe","D:\OtzarKiosk.exe","D:\Kiosk\kioskshell.exe") {
        if (Test-Path $f) {
            $deny = (Get-Acl $f).Access | Where-Object { $_.AccessControlType -eq 'Deny' -and "$($_.IdentityReference)" -like "*$OtzarUser*" }
            "$f : $(if ($deny) { 'DENIED for user' } else { 'ok (not denied)' })"
        } else { "$f : (missing)" }
    }

    Write-Host "`n===== D: =====" -ForegroundColor Cyan
    "D: DriveType : $((Get-Volume D -ErrorAction SilentlyContinue).DriveType)"

    Write-Host "`n===== RUNTIME LOGS (C:\Users\Public\Documents\OtzarKiosk) =====" -ForegroundColor Cyan
    $pub = "C:\Users\Public\Documents\OtzarKiosk"
    if (Test-Path $pub) {
        foreach ($lf in "setup.log","kiosk.log","pdfopen.log","pdfbrowser.log","kioskbar-error.log","pdfbrowser-error.log") {
            $p = Join-Path $pub $lf
            if (Test-Path $p) {
                Write-Host "`n--- $lf (last 20 lines) ---" -ForegroundColor DarkGray
                Get-Content $p -Tail 20 -ErrorAction SilentlyContinue
            }
        }
    } else { Write-Host "(no log folder yet - setup has not run on this profile)" -ForegroundColor DarkGray }

    Write-Host "`nPaste this whole output back." -ForegroundColor Green
}

# =========================================================================================
#  DEEP: Process Monitor capture of the "Access is denied" error  (-Deep)
# =========================================================================================
function Invoke-OtzarDeepDiag {
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
}

# =========================================================================================
#  dispatch
# =========================================================================================
if ($Deep) { Invoke-OtzarDeepDiag } else { Invoke-KioskReport }
