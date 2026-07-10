<#
.SYNOPSIS
  Uninstall the Otzar Hachochma kiosk: deletes the 'Otzar Hachochma' account and its profile,
  removes the kiosk files, and reverts the machine-wide toggles (Bluetooth, env vars, printer/
  network policies) so the PC is left normal.

.NOTES
  Run ELEVATED (Run as Administrator). The account is signed out automatically if logged in.
#>
[CmdletBinding()]
param([string]$OtzarUser = "Otzar Hachochma")

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

# sign the account out if it's logged in (can't delete a profile in use)
$line = quser 2>$null | Where-Object { $_ -match [regex]::Escape($OtzarUser) }
if ($line -and ($line -match '\s(\d+)\s+(Active|Disc)')) {
    Write-Host "Signing out '$OtzarUser' (session $($matches[1]))..." -ForegroundColor Cyan
    logoff $matches[1] 2>$null; Start-Sleep 3
}

# delete the user profile (folder + registry entry) cleanly, then the account
Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPath -like "*\$OtzarUser" } |
    ForEach-Object { Remove-CimInstance $_ -ErrorAction SilentlyContinue }

if (Get-LocalUser -Name $OtzarUser -ErrorAction SilentlyContinue) {
    Remove-LocalUser -Name $OtzarUser
    Write-Host "Deleted account '$OtzarUser'." -ForegroundColor Green
} else {
    Write-Host "Account '$OtzarUser' not found." -ForegroundColor Yellow
}

# remove kiosk leftovers
Remove-Item "D:\OtzarKiosk.exe" -Force -ErrorAction SilentlyContinue
Remove-Item "D:\Kiosk" -Recurse -Force -ErrorAction SilentlyContinue

# revert machine-wide toggles so the PC is normal again
Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | ForEach-Object { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
Set-Service bthserv -StartupType Manual -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable("OTZARAPP",   $null, "Machine")
[Environment]::SetEnvironmentVariable("OTZARAPPCD", $null, "Machine")
$msys = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$mexp = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
reg delete $msys /v DontDisplayNetworkSelectionUI /f 2>$null | Out-Null
reg delete $mexp /v NoAddPrinter    /f 2>$null | Out-Null
reg delete $mexp /v NoDeletePrinter /f 2>$null | Out-Null

Write-Host "`nUninstall complete. The '$OtzarUser' account is gone and machine-wide toggles are reverted." -ForegroundColor Magenta
Write-Host "(Note: NTFS execute-denies placed on a few system tools referenced that account's now-deleted SID - harmless leftovers.)" -ForegroundColor DarkGray
