<#
  Otzar Hachochma Kiosk - one-click installer / updater.

  This is the source that gets compiled into "Otzar-Kiosk-Setup.exe" (with a
  requireAdministrator manifest, so double-clicking shows the UAC prompt and runs elevated).

  What it does, automatically:
    - Downloads the latest scripts from the GitHub Pages site.
    - If the "Otzar Hachochma" account does NOT exist  -> FIRST-TIME INSTALL:
        create the account, build its user profile WITHOUT an interactive login
        (CreateProfile API), then apply the full lockdown.
    - If the account already exists                    -> UPDATE / re-apply:
        just re-run setup (which self-updates and re-applies everything).
    - Offers to reboot.

  Run from an admin context (the compiled exe guarantees that via its manifest).
#>
$ErrorActionPreference = 'Stop'
$RepoOwner = 'Shalom-Karr'
$RepoName  = 'otzar-hachochma-filter'
$Pages     = "https://$($RepoOwner.ToLower()).github.io/$RepoName"
$OtzarUser = 'Otzar Hachochma'
$Work      = Join-Path $env:ProgramData 'OtzarKioskInstaller'

function Line($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Line ""
Line "==============================================" Cyan
Line "  Otzar Hachochma Kiosk  -  Setup / Update" Cyan
Line "  Built by Shalom Karr" DarkGray
Line "==============================================" Cyan
Line ""

# --- must be elevated (the exe manifest handles this; verify anyway) ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Line "Administrator rights are required. Close this and choose 'Yes' at the security prompt." Red
    Start-Sleep -Seconds 8; exit 1
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path $Work | Out-Null

    # --- download the latest scripts ---
    # Try GitHub Pages first, then fall back to raw.githubusercontent.com (which is NOT subject to
    # Pages build lag), and retry a few times - so a transient 404 during a Pages rebuild can't
    # abort the install.
    $Raw = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main"
    function Get-Script($f) {
        $dest    = Join-Path $Work $f
        $sources = @("$Pages/$f?nocache=$([guid]::NewGuid())", "$Raw/$f?nocache=$([guid]::NewGuid())")
        $lastErr = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            foreach ($u in $sources) {
                try {
                    Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -TimeoutSec 60 `
                        -Headers @{ 'Cache-Control' = 'no-cache' }
                    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 0) { return }
                } catch { $lastErr = $_ }
            }
            Start-Sleep -Seconds ($attempt * 3)   # 3s, 6s, 9s, 12s between rounds
        }
        throw "Could not download '$f' after several tries. $($lastErr.Exception.Message)"
    }

    Line "Downloading the latest kiosk scripts..." Cyan
    $files = @('setup.ps1','create.ps1','updater.ps1','uninstall.ps1','diagnostics.ps1','version')
    foreach ($f in $files) {
        Line "  - $f"
        Get-Script $f
    }
    $ver = (Get-Content -LiteralPath (Join-Path $Work 'version') -Raw).Trim()
    Line "Latest version: v$ver" DarkGray
    Line ""

    $setup  = Join-Path $Work 'setup.ps1'
    $create = Join-Path $Work 'create.ps1'
    $exists = [bool](Get-LocalUser -Name $OtzarUser -ErrorAction SilentlyContinue)

    if ($exists) {
        # ---------- UPDATE / RE-APPLY ----------
        Line "Kiosk account '$OtzarUser' found  ->  UPDATING and re-applying the lockdown." Green
        Line ""
        & $setup -NoUpdate
    }
    else {
        # ---------- FIRST-TIME INSTALL ----------
        Line "Kiosk account '$OtzarUser' not found  ->  FIRST-TIME INSTALL." Green
        Line ""

        Line "[1/3] Creating the standard kiosk account..." Cyan
        & $create -NoUpdate

        Line "[2/3] Building the account's user profile (no login needed)..." Cyan
        $sid = (New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $OtzarUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        Add-Type -Namespace KioskInstall -Name Prof -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("userenv.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern int CreateProfile(string pszUserSid, string pszUserName, System.Text.StringBuilder pszProfilePath, uint cchProfilePath);
'@
        $sb = New-Object System.Text.StringBuilder 260
        $hr = [KioskInstall.Prof]::CreateProfile($sid, $OtzarUser, $sb, 260)
        if ($hr -eq 0) {
            Line "  profile created at $($sb.ToString())" DarkGray
        } elseif (($hr -band 0xFFFF) -eq 0x00B7) {
            Line "  profile already exists - continuing." DarkGray   # HRESULT 0x800700B7 = ERROR_ALREADY_EXISTS
        } else {
            Line "  CreateProfile returned 0x$('{0:X8}' -f $hr) - continuing (setup will still try)." DarkYellow
        }

        Line "[3/3] Applying the lockdown + launcher..." Cyan
        Line ""
        & $setup -NoUpdate
    }

    Line ""
    Line "==============================================" Cyan
    Line "  Done. Reboot, then the machine boots into the" Green
    Line "  locked Otzar Hachochma kiosk." Green
    Line "==============================================" Cyan
    Line ""
    $ans = Read-Host "Reboot now? (Y / N)"
    if ($ans -match '^\s*[Yy]') { Line "Rebooting..." Cyan; Start-Sleep -Seconds 2; Restart-Computer -Force }
    else { Line "Reboot when ready. You can close this window." DarkGray; Start-Sleep -Seconds 3 }
}
catch {
    Line ""
    Line "SETUP FAILED: $($_.Exception.Message)" Red
    Line $_.ScriptStackTrace DarkYellow
    Line ""
    Line "Press Enter to close." DarkGray
    Read-Host | Out-Null
    exit 1
}
