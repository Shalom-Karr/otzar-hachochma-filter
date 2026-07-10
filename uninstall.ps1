<#
.SYNOPSIS
  Reverses the Otzar Hachochma kiosk lockdown applied by setup.ps1: removes the NTFS
  denies, restores the normal desktop shell, re-enables Bluetooth, clears the kiosk
  policies + network/printer restrictions, and removes the machine env vars.

.DESCRIPTION
  Run ELEVATED (Run as Administrator) from the same folder as setup.ps1.
  By default the Otzar account is KEPT (its profile/data are left intact). Pass
  -RemoveAccount to also delete the account (the C:\Users profile folder is left in place).

.EXAMPLE
  .\uninstall.ps1                  # undo the lockdown, keep the account
.EXAMPLE
  .\uninstall.ps1 -RemoveAccount   # undo the lockdown AND delete the Otzar account

.NOTES
  Reboot afterward to fully restore the account to a normal desktop.
#>
[CmdletBinding()]
param(
    [string]$OtzarUser = "Otzar Hachochma",
    [switch]$RemoveAccount
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

$setup = Join-Path $PSScriptRoot "setup.ps1"
if (-not (Test-Path $setup)) { throw "setup.ps1 not found next to uninstall.ps1 ($setup)." }

Write-Host "Reversing the Otzar Hachochma lockdown..." -ForegroundColor Cyan
& $setup -Undo -OtzarUser $OtzarUser

# Optionally remove the account itself
if ($RemoveAccount) {
    if (Get-LocalUser -Name $OtzarUser -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $OtzarUser
        Write-Host "Removed account '$OtzarUser'. Its profile folder under C:\Users was left in place - delete it manually if you want it gone." -ForegroundColor Green
    } else {
        Write-Host "Account '$OtzarUser' not found - nothing to remove." -ForegroundColor DarkGray
    }
}

Write-Host "`nUninstall complete. REBOOT to fully restore the account to a normal desktop." -ForegroundColor Magenta
