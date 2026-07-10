<#
.SYNOPSIS
  Read-only diagnostic for the Otzar Hachochma kiosk black-screen. Reports the account,
  ALL its profiles (to catch the duplicate-profile bug), the ACTIVE profile's shell value,
  the kiosk files, the Otzar symlink target, the USB policy, and explorer/cmd deny status.

.NOTES
  Run ELEVATED (as admin / on khaly). It signs the Otzar user out so it can read that
  profile's hive, but makes NO changes.
#>
param([string]$OtzarUser = "Otzar Hachochma")

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

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
Write-Host "Hebrew-named exe(s) on D:\ :"
Get-ChildItem 'D:\*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '[^\x00-\x7F]' } | Select-Object Name | Format-Table -AutoSize

Write-Host "===== ACTIVE PROFILE HIVE: shell / USB policy =====" -ForegroundColor Cyan
$line = quser 2>$null | Where-Object { $_ -match [regex]::Escape($OtzarUser) }
if ($line -and ($line -match '\s(\d+)\s+(Active|Disc)')) { Write-Host "Signing out session $($matches[1])..."; logoff $matches[1] 2>$null; Start-Sleep 3 }
reg load "HKU\Diag" "$prof\NTUSER.DAT" *>$null
if ($LASTEXITCODE -eq 0) {
    $wl  = "Registry::HKEY_USERS\Diag\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $rsd = "Registry::HKEY_USERS\Diag\Software\Policies\Microsoft\Windows\RemovableStorageDevices"
    Write-Host ("Shell value            : " + (Get-ItemProperty $wl -ErrorAction SilentlyContinue).Shell) -ForegroundColor Yellow
    "RemovableStorage Deny_All: " + (Get-ItemProperty $rsd -ErrorAction SilentlyContinue).Deny_All + "   (1 here can block D: and black-screen!)"
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
Write-Host "`nPaste this whole output back." -ForegroundColor Green
