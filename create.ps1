<#
.SYNOPSIS
  STEP 1 of the Otzar Hachochma kiosk. Creates the locked-down STANDARD account
  "Otzar Hachochma" with a temporary password 1234.

.DESCRIPTION
  Run ELEVATED (Run as Administrator). After this:
    1. Log into the 'Otzar Hachochma' account once (password 1234) so its profile builds
       and Otzar does its first-run setup.
    2. Sign out.
    3. Run setup.ps1 (STEP 2) as admin to apply the lockdown + launcher and remove the password.

.EXAMPLE
  .\create.ps1
#>
[CmdletBinding()]
param(
    [string]$OtzarUser = "Otzar Hachochma",
    [string]$Password  = "1234",
    [switch]$NoUpdate                       # skip the GitHub self-update check
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

# ---- self-update from GitHub (offline-safe; re-runs the new version if one exists) ----
if (-not $NoUpdate) {
    $upd = Join-Path $PSScriptRoot 'updater.ps1'
    if (Test-Path -LiteralPath $upd) { . $upd; Invoke-OtzarSelfUpdate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters }
}

if (Get-LocalUser -Name $OtzarUser -ErrorAction SilentlyContinue) {
    Write-Host "Account '$OtzarUser' already exists - leaving it as is." -ForegroundColor Yellow
} else {
    New-LocalUser -Name $OtzarUser -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -FullName $OtzarUser -Description "Locked-down Otzar Hachochma kiosk" -AccountNeverExpires -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -Group "Users" -Member $OtzarUser   # STANDARD user, NOT an administrator
    Write-Host "Created STANDARD account '$OtzarUser' with temporary password: $Password" -ForegroundColor Green
}

Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  1. Log into '$OtzarUser' now using password $Password (let Otzar load once)." -ForegroundColor Cyan
Write-Host "  2. Sign out of '$OtzarUser'." -ForegroundColor Cyan
Write-Host "  3. Back on this admin account, run:  .\setup.ps1" -ForegroundColor Cyan
