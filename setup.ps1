<#
.SYNOPSIS
  Otzar Hachochma kiosk setup (STEP 2). Locks the "Otzar Hachochma" account to Otzar +
  LibreOffice + a read-only PDF file browser: blocks every other program (NTFS deny), applies kiosk policies,
  removes Store/media apps, disables Bluetooth, keeps printing + AnyDesk-incoming working,
  builds the launcher UI, and removes the temporary password.

.DESCRIPTION
  STEP 1 is create.ps1 (makes the account with password 1234). Then log into that account
  once (password 1234) so its profile builds and Otzar does first-run, sign out, and run
  THIS script once as admin. Only the Otzar STANDARD account is affected; your admin account
  is untouched.

.EXAMPLE
  .\create.ps1              # STEP 1: make the account (then log in once with 1234, sign out)
.EXAMPLE
  .\setup.ps1 -ListOnly     # preview what would be blocked, make NO changes
.EXAMPLE
  .\setup.ps1               # STEP 2: apply the full lockdown + launcher, remove the password
.EXAMPLE
  .\uninstall.ps1           # reverse everything

.NOTES
  Run ELEVATED (Run as Administrator). Reboot / log into Otzar afterward to verify.
#>
[CmdletBinding()]
param(
    [string]$OtzarUser    = "Otzar Hachochma",
    [string]$OtzarProfile = "C:\Users\Otzar Hachochma",
    [string]$OtzarData    = "C:\OtzarApp",   # Otzar's Electron profile/cache folder (needs user write)
    [string]$OtzarAppVar   = "C:\otzarApp\otzarLocal",                        # OTZARAPP env var Otzar expects
    [string]$OtzarAppCdVar = "C:\otzarApp\otzarLocal\launcher\bin\x64\app",   # OTZARAPPCD env var Otzar expects
    [string]$ShellLnk     = "C:\Users\Otzar Hachochma\Desktop\Otzar Hachochma.lnk",
    [string[]]$AllowFolders = @("D:\", "C:\otzarApp"),   # Otzar's launcher drive + its app binaries; all else blocked (AnyDesk incoming still works via its service)
    [string[]]$RemoveUwp  = @(
        "WindowsStore","WindowsCalculator","ZuneMusic","ZuneVideo","Photos",
        "Paint","MSPaint","MediaPlayer","WindowsNotepad",
        "SolitaireCollection","Xbox","GamingApp","BingWeather","BingNews",
        "GetHelp","Getstarted","Tips","OfficeHub","SkypeApp","Teams","MSTeams","People",
        "YourPhone","CrossDevice","WindowsMaps","MixedReality","WindowsAlarms","SoundRecorder",
        "Clipchamp","Todos","PowerAutomateDesktop","WindowsCamera","FeedbackHub","549981C3F5F10","Copilot"
    ),
    [bool]$InstallApps      = $true,   # winget-install LibreOffice
    [string]$LibreOfficeExe = "C:\Program Files\LibreOffice\program\soffice.exe",
    [switch]$ListOnly,
    [switch]$Undo,
    [switch]$NoUpdate                       # skip the GitHub self-update check
)

# ---- must be elevated ----
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

# ---- self-update from GitHub (offline-safe; re-runs the new version if one exists) ----
# Skipped for -ListOnly (preview makes no changes) and -Undo (teardown).
if ((-not $NoUpdate) -and (-not $ListOnly) -and (-not $Undo)) {
    $upd = Join-Path $PSScriptRoot 'updater.ps1'
    if (Test-Path -LiteralPath $upd) { . $upd; Invoke-OtzarSelfUpdate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters }
}

# ---- the account must already exist (run create.ps1 first, then log into it once) ----
if ((-not $Undo) -and (-not (Get-LocalUser -Name $OtzarUser -ErrorAction SilentlyContinue))) {
    throw "Account '$OtzarUser' not found. Run create.ps1 first, log into it once (password 1234), sign out, then run setup.ps1."
}

$acct = "$env:COMPUTERNAME\$OtzarUser"
try { $sid = (New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $OtzarUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
catch { $sid = $null; Write-Host "WARN: could not resolve SID for $acct" -ForegroundColor Yellow }

# use the account's ACTUAL profile path (handles a duplicate 'Name.COMPUTER' profile)
if ($sid) {
    $realProfile = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    if ($realProfile) { $OtzarProfile = $realProfile; Write-Host "Using profile: $OtzarProfile" -ForegroundColor DarkGray }
}

function Test-Allowed([string]$p) {
    $lp = $p.ToLower()
    foreach ($a in $AllowFolders) { if ($lp.StartsWith($a.ToLower().TrimEnd('\'))) { return $true } }
    return $false
}

function Set-ExeDeny([string]$Path, [bool]$Deny) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $perm = if ((Get-Item -LiteralPath $Path).PSIsContainer) { "(OI)(CI)(RX)" } else { "(RX)" }
    if ($Deny) {
        icacls $Path /deny "${acct}:$perm" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {                 # TrustedInstaller-owned system file: take ownership then deny
            takeown /f $Path 2>$null | Out-Null
            icacls $Path /grant "*S-1-5-32-544:F" 2>$null | Out-Null
            icacls $Path /deny "${acct}:$perm" 2>$null | Out-Null
        }
    } else {
        icacls $Path /remove:d "$acct" 2>$null | Out-Null
    }
}

# ---------------- install the allowed apps (LibreOffice) + allow their folders ----------------
if ((-not $Undo) -and $InstallApps -and (-not $ListOnly) -and (-not (Test-Path $LibreOfficeExe))) {
    Write-Host "LibreOffice not found - installing via winget (this can be slow)..." -ForegroundColor Cyan
    try { winget install --exact --id TheDocumentFoundation.LibreOffice --scope machine --silent --accept-package-agreements --accept-source-agreements | Out-Null }
    catch { Write-Host "  LibreOffice install skipped/failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}
# best-effort: remove any previously installed SumatraPDF (this build uses the built-in PDF browser + default handler)
if ((-not $Undo) -and (-not $ListOnly)) {
    try { winget uninstall --id SumatraPDF.SumatraPDF --silent --accept-source-agreements | Out-Null }
    catch { Write-Host "  SumatraPDF uninstall skipped/failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}
# resolve exe paths if the defaults are not present (search everywhere winget may have put them)
if (-not (Test-Path $LibreOfficeExe)) {
    $hit = Get-ChildItem "C:\Program Files\LibreOffice","C:\Program Files (x86)\LibreOffice","$env:ProgramData\Microsoft\WinGet\Packages" -Recurse -Filter soffice.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $LibreOfficeExe = $hit.FullName }
}
# allow the app folders so the deny-scan below does NOT block them
if (Test-Path $LibreOfficeExe) { $AllowFolders += (Split-Path (Split-Path $LibreOfficeExe -Parent) -Parent) }
Write-Host "Allowed apps -> LibreOffice: $LibreOfficeExe" -ForegroundColor Green
# log to Public Documents so the admin can review setup + launcher activity later
$PubLog = "C:\Users\Public\Documents\OtzarKiosk"
try { New-Item -ItemType Directory -Path $PubLog -Force | Out-Null } catch {}
try { Add-Content "$PubLog\setup.log" -Value ("{0}  LibreOffice='{1}' exists={2} allowed={3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $LibreOfficeExe, (Test-Path $LibreOfficeExe), (Test-Allowed $LibreOfficeExe)) } catch {}

# ---------------- build the program list ----------------
$sh = New-Object -ComObject WScript.Shell
$found = New-Object System.Collections.Generic.List[string]

# 1) Start Menu shortcut targets (all users + the Otzar profile)
$menus = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
           "$OtzarProfile\AppData\Roaming\Microsoft\Windows\Start Menu\Programs")
Get-ChildItem $menus -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
    $t = $sh.CreateShortcut($_.FullName).TargetPath
    if ($t -and $t.ToLower().EndsWith(".exe")) { $found.Add($t) }
}

# 2) exes under Program Files (both), skipping runtimes/UWP that would break embedded use
foreach ($pf in @("$env:ProgramFiles", "${env:ProgramFiles(x86)}")) {
    if (-not (Test-Path $pf)) { continue }
    Get-ChildItem $pf -Recurse -Depth 4 -Filter *.exe -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '\\WindowsApps\\'      -and
            $_.FullName -notmatch '\\EdgeWebView\\'      -and
            $_.FullName -notmatch '\\Common Files\\'     -and
            $_.FullName -notmatch '\\Windows Defender'   -and   # AV service - never touch
            $_.FullName -notmatch '\\EdgeUpdate\\'       -and   # SYSTEM updater
            $_.FullName -notmatch '\\Realtek\\'          -and   # audio driver services
            $_.FullName -notmatch '\\Waves\\'            -and   # audio driver services
            $_.FullName -notmatch '\\NVIDIA'             -and   # GPU driver services
            $_.FullName -notmatch '\\Intel\\'
        } |
        ForEach-Object { $found.Add($_.FullName) }
}

# 3) curated Windows tools (escape / scripting / admin / remote / media) in System32 + SysWOW64
$tools = @("regedit.exe","reg.exe","taskmgr.exe","control.exe","msconfig.exe","msinfo32.exe",
           "mstsc.exe","wmic.exe","certutil.exe","bitsadmin.exe","curl.exe","ftp.exe","tftp.exe",
           "wscript.exe","cscript.exe","mshta.exe","perfmon.exe","psr.exe","cleanmgr.exe","charmap.exe",
           "mspaint.exe","notepad.exe","iexplore.exe","WindowsPowerShell\v1.0\powershell.exe","WindowsPowerShell\v1.0\powershell_ise.exe")
foreach ($t in $tools) {
    foreach ($base in @("$env:windir\System32","$env:windir\SysWOW64")) {
        $p = Join-Path $base $t
        if (Test-Path -LiteralPath $p) { $found.Add($p) }
    }
}

# 4) registered programs (Add/Remove Programs) - catches apps installed to custom folders / other drives
$uninstKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
foreach ($u in (Get-ItemProperty $uninstKeys -ErrorAction SilentlyContinue)) {
    $loc = "$($u.InstallLocation)".Trim('"').TrimEnd('\')
    if ($loc -and (Test-Path -LiteralPath $loc) -and (-not (Test-Allowed $loc)) -and ($loc -notmatch '(?i)\\Windows\b|Common Files|WindowsApps')) {
        Get-ChildItem -LiteralPath $loc -Recurse -Depth 3 -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object { $found.Add($_.FullName) }
    }
}

# 5) C:\ProgramData app exes (skip OS / system / package folders)
Get-ChildItem "$env:ProgramData" -Recurse -Depth 3 -Filter *.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '(?i)\\Microsoft\\|\\Windows\\|\\Package Cache\\|\\Packages\\' } |
    ForEach-Object { $found.Add($_.FullName) }

# 6) per-user installed apps (AppData\Local\Programs) across all profiles
Get-ChildItem "C:\Users\*\AppData\Local\Programs" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Get-ChildItem $_.FullName -Recurse -Depth 3 -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object { $found.Add($_.FullName) }
}

# 7) other FIXED drives (not C:, not the allowed Otzar drive) - installed / portable apps
foreach ($dsk in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
    $root = "$($dsk.DeviceID)\"
    if (($root -ieq "C:\") -or (Test-Allowed $root)) { continue }
    Get-ChildItem $root -Recurse -Depth 3 -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object { $found.Add($_.FullName) }
}

# dedupe + drop anything under an allowed folder; keep per-user Program installs, drop other in-profile noise
$deny = @($found | Sort-Object -Unique | Where-Object {
    (-not (Test-Allowed $_)) -and
    ( ($_ -notmatch '(?i)\\Users\\') -or ($_ -match '(?i)\\AppData\\Local\\Programs\\') )
})

# Force-deny remote-access / unwanted tools even inside ALLOWED folders (D:\, C:\otzarApp, Program Files).
# D:\ is broadly allowed, so a copy of TeamViewer/AnyDesk/VNC there would otherwise RUN - deny them by
# name wherever they live. (Incoming AnyDesk still works: its service runs as SYSTEM, not as this user.)
$blockNames = @('anydesk','teamviewer','tv_w32','tv_x64','tvnserver','winvnc','vncviewer','ultravnc','chromeremotedesktop','remotepc','splashtop','ammyy','supremo','getscreen','rustdesk')
$forceDeny = @()
foreach ($root in @('D:\', "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData")) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Recurse -Depth 3 -Filter *.exe -ErrorAction SilentlyContinue | Where-Object {
        $n = $_.Name.ToLower(); ($blockNames | Where-Object { $n -like "*$_*" }) -ne $null
    } | ForEach-Object { $forceDeny += $_.FullName }
}
foreach ($a in ($forceDeny | Sort-Object -Unique)) { if ($deny -notcontains $a) { $deny += $a } }
if ($forceDeny) { Write-Host "Force-denied remote-access tools: $($forceDeny.Count)" -ForegroundColor DarkGray }

# Block File Explorer + the Settings app for the user (tested: the explorer.exe deny was NOT the cause
# of the env-var error, so it's safe to keep it blocked). The kiosk shell + policies also remove any
# way to OPEN a File Explorer window.
$extra = @("$env:windir\explorer.exe", "$env:windir\SysWOW64\explorer.exe", "$env:windir\ImmersiveControlPanel\SystemSettings.exe")
foreach ($e in $extra) { if ((Test-Path $e) -and ($deny -notcontains $e)) { $deny += $e } }

# Otzar (Electron) spawns cmd.exe at startup - it MUST be allowed, so pull it back out of the deny list
# even if a Start Menu shortcut pointed at it. The kiosk shell + policies still block the user from opening it.
$keepExe = @("$env:windir\System32\cmd.exe", "$env:windir\SysWOW64\cmd.exe")
# keep msedge.exe runnable - it's the PDF viewer. Web browsing is blocked by the Edge URL policy (in the hive section).
$deny = @($deny | Where-Object { ($keepExe -notcontains $_) -and ($_ -notmatch '(?i)\\msedge\.exe$') })

Write-Host "`n===== ALLOWED (will still run for $OtzarUser) =====" -ForegroundColor Green
$AllowFolders | ForEach-Object { "  $_" }
Write-Host "`n===== WILL BE BLOCKED ($($deny.Count) programs) =====" -ForegroundColor Cyan
$deny | ForEach-Object { "  $_" }

if ($ListOnly) { Write-Host "`n-ListOnly: nothing changed." -ForegroundColor Yellow; return }

$verb = if ($Undo) { "REVERSING" } else { "APPLYING" }
Write-Host "`n===== $verb lockdown =====" -ForegroundColor Magenta

# ---------------- 1. NTFS deny/allow every blocked exe ----------------
Write-Host "NTFS execute rules ..." -ForegroundColor Cyan
$i = 0
foreach ($p in $deny) { $i++; Set-ExeDeny $p (-not $Undo); if ($i % 25 -eq 0) { Write-Host "  ...$i/$($deny.Count)" } }
Write-Host "  done ($($deny.Count) items)." -ForegroundColor Green

# Edge is the PDF viewer -> make sure msedge.exe is NOT left denied from a previous run
if (-not $Undo) {
    Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge","${env:ProgramFiles(x86)}\Microsoft\EdgeCore" -Recurse -Filter msedge.exe -ErrorAction SilentlyContinue | ForEach-Object { Set-ExeDeny $_.FullName $false }
}

# Otzar (Electron/Chromium) must be able to write its cache/profile under C:\OtzarApp, or it errors on start.
if (-not $Undo -and (Test-Path $OtzarData)) {
    Write-Host "Granting $OtzarUser write to $OtzarData (Otzar cache/profile) ..." -ForegroundColor Cyan
    icacls $OtzarData /grant "${acct}:(OI)(CI)M" /T /Q | Out-Null
    Write-Host "  done." -ForegroundColor Green
}

# Pre-set the env vars Otzar wants (machine-wide) so it never runs its elevated 'ovarsfix.bat' (UAC every boot).
if ($Undo) {
    [Environment]::SetEnvironmentVariable("OTZARAPP",   $null, "Machine")
    [Environment]::SetEnvironmentVariable("OTZARAPPCD", $null, "Machine")
} else {
    [Environment]::SetEnvironmentVariable("OTZARAPP",   $OtzarAppVar,   "Machine")
    [Environment]::SetEnvironmentVariable("OTZARAPPCD", $OtzarAppCdVar, "Machine")
    Write-Host "Set machine env vars OTZARAPP / OTZARAPPCD (stops Otzar's elevated ovarsfix.bat)." -ForegroundColor Green
}

# ---------------- 2. remove Store / Calculator / media UWP (apply only) ----------------
if (-not $Undo -and $sid) {
    Write-Host "Removing Store/UWP apps for $OtzarUser ..." -ForegroundColor Cyan
    foreach ($pat in $RemoveUwp) {
        Get-AppxPackage -User $sid "*$pat*" -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-AppxPackage -Package $_.PackageFullName -User $sid -ErrorAction Stop; Write-Host "  removed: $($_.Name)" -ForegroundColor Green }
            catch { Write-Host "  not removed: $($_.Name)" -ForegroundColor Yellow }
        }
    }
}

# ---------------- 3. Bluetooth ----------------
Write-Host "Bluetooth ..." -ForegroundColor Cyan
Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | ForEach-Object {
    if ($Undo) { Enable-PnpDevice  -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    else       { Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
}
if ($Undo) { Set-Service bthserv -StartupType Manual -ErrorAction SilentlyContinue }
else       { Set-Service bthserv -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service bthserv -Force -ErrorAction SilentlyContinue }
Write-Host "  bluetooth $(if($Undo){'enabled'}else{'disabled'})." -ForegroundColor Green

# block MTP phones / cameras (portable devices) machine-wide - the per-user WPD policy is not reliable
if ($Undo) { Set-Service WpdBusEnum -StartupType Manual -ErrorAction SilentlyContinue }
else       { Stop-Service WpdBusEnum -Force -ErrorAction SilentlyContinue; Set-Service WpdBusEnum -StartupType Disabled -ErrorAction SilentlyContinue }
Write-Host "  portable-device (MTP phone/camera) service $(if($Undo){'restored'}else{'disabled'})." -ForegroundColor Green

# ---------------- 3b. lock-screen network UI (blocks Wi-Fi/airplane from lock screen) + keep printing ----------------
$msys = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
if ($Undo) { reg delete $msys /v DontDisplayNetworkSelectionUI /f 2>$null | Out-Null }
else       { reg add    $msys /v DontDisplayNetworkSelectionUI /t REG_DWORD /d 1 /f | Out-Null }
# Printing must keep working - ensure the Print Spooler stays enabled and running (it runs as SYSTEM).
Set-Service Spooler -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service Spooler -ErrorAction SilentlyContinue
# Printer policy (HKLM, machine-wide): user can PRINT but not add/remove printers or manage settings.
# (Standard users get "Print" but not "Manage printers" by default, so they can't edit printer settings.)
$mexp = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
if ($Undo) {
    reg delete $mexp /v NoAddPrinter    /f 2>$null | Out-Null
    reg delete $mexp /v NoDeletePrinter /f 2>$null | Out-Null
} else {
    reg add $mexp /v NoAddPrinter    /t REG_DWORD /d 1 /f | Out-Null   # user can't add printers
    reg add $mexp /v NoDeletePrinter /t REG_DWORD /d 1 /f | Out-Null   # user can't remove printers
}
Write-Host "  lock-screen network UI $(if($Undo){'restored'}else{'hidden'}); Spooler running; printer add/remove locked (print-only)." -ForegroundColor Green

# ---------------- 4. sign Otzar out, then edit its hive (policies + shell) ----------------
$line = quser 2>$null | Where-Object { $_ -match [regex]::Escape($OtzarUser) }
if ($line -and ($line -match '\s(\d+)\s+(Active|Disc)')) {
    Write-Host "Signing out Otzar session $($matches[1]) ..." -ForegroundColor Cyan
    logoff $matches[1] 2>$null
    Start-Sleep 3
}

$dat = Join-Path $OtzarProfile "NTUSER.DAT"
reg load "HKU\LockAll" $dat | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not load the Otzar hive - policies + shell SKIPPED." -ForegroundColor Red
    Write-Host "  If the account is NEW: log into '$OtzarUser' once (creates the profile), sign out, then run setup.ps1 again." -ForegroundColor Yellow
    Write-Host "  If already set up: make sure '$OtzarUser' is SIGNED OUT, then re-run." -ForegroundColor Yellow
} else {
    $sys   = "HKU\LockAll\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    $exp   = "HKU\LockAll\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $srch1 = "HKU\LockAll\Software\Policies\Microsoft\Windows\Explorer"
    $srch2 = "HKU\LockAll\Software\Microsoft\Windows\CurrentVersion\Search"
    $net   = "HKU\LockAll\Software\Microsoft\Windows\CurrentVersion\Policies\Network"
    $wl    = "HKU\LockAll\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"

    if ($Undo) {
        reg delete $sys   /v DisableTaskMgr             /f 2>$null | Out-Null
        reg delete $sys   /v DisableCMD                 /f 2>$null | Out-Null
        reg delete $sys   /v DisableRegistryTools       /f 2>$null | Out-Null
        reg delete $sys   /v DisableChangePassword      /f 2>$null | Out-Null
        reg delete $exp   /v NoRun                      /f 2>$null | Out-Null
        reg delete $exp   /v NoControlPanel             /f 2>$null | Out-Null
        reg delete $exp   /v NoWinKeys                  /f 2>$null | Out-Null
        reg delete $srch1 /v DisableSearchBoxSuggestions /f 2>$null | Out-Null
        reg delete $srch2 /v BingSearchEnabled          /f 2>$null | Out-Null
        reg delete "HKU\LockAll\Software\Policies\Microsoft\Edge\URLBlocklist" /f 2>$null | Out-Null
        reg delete "HKU\LockAll\Software\Policies\Microsoft\Edge\URLAllowlist" /f 2>$null | Out-Null
        reg delete $exp   /v HideSCANetwork             /f 2>$null | Out-Null
        reg delete $net   /v NC_LanChangeProperties     /f 2>$null | Out-Null
        reg delete $net   /v NC_ShowSharedAccessUI      /f 2>$null | Out-Null
        reg delete $net   /v NC_PersonalFirewallConfig  /f 2>$null | Out-Null
        reg delete $net   /v NC_RasConnect              /f 2>$null | Out-Null
        reg delete "HKU\LockAll\Software\Policies\Microsoft\Windows\RemovableStorageDevices" /f 2>$null | Out-Null
        reg add    $wl    /v Shell /t REG_SZ /d "explorer.exe" /f | Out-Null
        Write-Host "Policies removed, shell restored to explorer.exe." -ForegroundColor Green
    } else {
        reg add $sys   /v DisableTaskMgr             /t REG_DWORD /d 1 /f | Out-Null
        reg add $sys   /v DisableRegistryTools       /t REG_DWORD /d 1 /f | Out-Null
        # NOTE: DisableCMD intentionally NOT set - Otzar needs cmd.exe to run at startup.
        reg add $sys   /v DisableChangePassword      /t REG_DWORD /d 1 /f | Out-Null   # remove "Change a password" on Ctrl+Alt+Del
        reg add $exp   /v NoRun                      /t REG_DWORD /d 1 /f | Out-Null
        reg add $exp   /v NoControlPanel             /t REG_DWORD /d 1 /f | Out-Null
        reg add $exp   /v NoWinKeys                  /t REG_DWORD /d 1 /f | Out-Null   # disable Win+key shortcuts (Win+I/Win+E...)
        reg add $srch1 /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f | Out-Null
        reg add $srch2 /v BingSearchEnabled          /t REG_DWORD /d 0 /f | Out-Null
        # keep Edge as the PDF viewer but block ALL web browsing (local files only)
        # block the WEB (http/https/ftp/ws) but leave local files (file://) so exported PDFs still open
        reg add "HKU\LockAll\Software\Policies\Microsoft\Edge\URLBlocklist" /v 1 /t REG_SZ /d "http://*"  /f | Out-Null
        reg add "HKU\LockAll\Software\Policies\Microsoft\Edge\URLBlocklist" /v 2 /t REG_SZ /d "https://*" /f | Out-Null
        reg add "HKU\LockAll\Software\Policies\Microsoft\Edge\URLBlocklist" /v 3 /t REG_SZ /d "ftp://*"   /f | Out-Null
        reg add "HKU\LockAll\Software\Policies\Microsoft\Edge\URLBlocklist" /v 4 /t REG_SZ /d "ws://*"    /f | Out-Null
        reg add "HKU\LockAll\Software\Policies\Microsoft\Edge\URLBlocklist" /v 5 /t REG_SZ /d "wss://*"   /f | Out-Null
        # Keyboard layouts for the Otzar user (built into Windows; switch with Left Alt+Shift / Win+Space)
        reg add "HKU\LockAll\Keyboard Layout\Preload" /v 1 /t REG_SZ /d "0000040d" /f | Out-Null   # Hebrew (primary)
        reg add "HKU\LockAll\Keyboard Layout\Preload" /v 2 /t REG_SZ /d "00000409" /f | Out-Null   # English (secondary)
        reg add $exp   /v HideSCANetwork             /t REG_DWORD /d 1 /f | Out-Null   # no network icon / Wi-Fi flyout
        reg add $net   /v NC_LanChangeProperties     /t REG_DWORD /d 0 /f | Out-Null   # can't change connection props
        reg add $net   /v NC_ShowSharedAccessUI      /t REG_DWORD /d 0 /f | Out-Null
        reg add $net   /v NC_PersonalFirewallConfig  /t REG_DWORD /d 0 /f | Out-Null
        reg add $net   /v NC_RasConnect              /t REG_DWORD /d 0 /f | Out-Null
        # block USB flash drives / SD cards / CDs (Deny_All) AND phones/cameras (WPD class needs its own deny).
        # (The Otzar D: is a FIXED disk, so it stays usable.)
        $rsd = "HKU\LockAll\Software\Policies\Microsoft\Windows\RemovableStorageDevices"
        reg add $rsd /v Deny_All /t REG_DWORD /d 1 /f | Out-Null
        foreach ($g in "{6AC27878-A6FA-4155-BA85-F98F491D4F33}","{F33FDC04-D1AC-4E8E-9A30-19BBD4B108AE}") {
            reg add "$rsd\$g" /v Deny_Read  /t REG_DWORD /d 1 /f | Out-Null
            reg add "$rsd\$g" /v Deny_Write /t REG_DWORD /d 1 /f | Out-Null
        }

        # kiosk shell = a bottom LAUNCHER BAR (Otzar / LibreOffice / PDF Viewer) that also relaunches Otzar.
        # find the REAL Otzar launcher: prefer the shortcut; else the HEBREW-named exe on D:\
        # (Otzar's launcher has a non-ASCII name; TeamViewer/AnyDesk/our symlink are ASCII), shorter name = launcher not installer.
        $badRe = '(?i)anydesk|teamviewer|otzarkiosk|tv_|winvnc|vncviewer|ultravnc|rustdesk|splashtop|remotepc|getscreen'
        $target = $null
        if (Test-Path $ShellLnk) {
            $t = $sh.CreateShortcut($ShellLnk).TargetPath
            if ($t -and (Test-Path $t) -and ($t -notmatch $badRe)) { $target = $t }
        }
        if (-not $target) {
            $target = (Get-ChildItem 'D:\*.exe' -ErrorAction SilentlyContinue |
                Where-Object { ($_.Name -notmatch $badRe) -and ($_.BaseName -match '[^\x00-\x7F]') } |
                Sort-Object { $_.Name.Length } | Select-Object -First 1).FullName
        }
        if (-not $target) {
            $target = (Get-ChildItem 'D:\*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $badRe } | Select-Object -First 1).FullName
        }
        if ($target) {
            $drive = [System.IO.Path]::GetPathRoot($target)
            $link = Join-Path $drive "OtzarKiosk.exe"     # ASCII pointer to the Hebrew-named exe
            try {
                New-Item -ItemType SymbolicLink -Path $link -Target $target -Force -ErrorAction Stop | Out-Null
                if (-not (Test-Path $link)) { $link = $null }
            } catch { $link = $null }
            $appPath = if ($link) { $link } else { $target }

            $kiosk = Join-Path $drive "Kiosk"
            New-Item -ItemType Directory -Path $kiosk -Force | Out-Null
            # renamed copies: wscript = the shell (bulletproof), powershell = runs the WinForms bar
            Copy-Item "$env:windir\System32\wscript.exe" (Join-Path $kiosk "kioskshell.exe") -Force
            Copy-Item "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" (Join-Path $kiosk "kioskbar.exe") -Force

            $barBody = @'
try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$barH = 72
try {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WA {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint c);
}
"@
$rc = New-Object WA+RECT
$rc.L = 0; $rc.T = 0; $rc.R = $scr.Width; $rc.B = $scr.Height - $barH
[WA]::SystemParametersInfo(0x2F, 0, [ref]$rc, 3) | Out-Null
} catch {}
$LogDir = "C:\Users\Public\Documents\OtzarKiosk"
try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch {}
function Log($m) { try { Add-Content -LiteralPath "$LogDir\kiosk.log" -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) } catch {} }
Log "launcher started"
$colBg   = [System.Drawing.Color]::FromArgb(15,23,42)
$colTile = [System.Drawing.Color]::FromArgb(30,41,59)
function New-Tile($text, $exe, $x, $y, $w, $h, $fs, $tileArgs) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.SetBounds($x, $y, $w, $h)
  $b.FlatStyle = "Flat"; $b.FlatAppearance.BorderSize = 0
  $b.ForeColor = [System.Drawing.Color]::White; $b.BackColor = $colTile
  $b.Font = New-Object System.Drawing.Font("Segoe UI Semibold", $fs)
  $b.Cursor = "Hand"
  $b.Tag = @{ Exe = $exe; Args = $tileArgs }
  $b.Add_Click({
    $t = $this.Tag
    if (-not (Test-Path -LiteralPath $t.Exe)) { Log "MISSING exe: $($t.Exe)"; return }
    $btn = $this; $orig = $btn.Text
    $btn.Enabled = $false; $btn.Text = "Opening..."
    try {
      if ($t.Args) { Start-Process -FilePath $t.Exe -ArgumentList $t.Args -ErrorAction Stop }
      else         { Start-Process -FilePath $t.Exe -ErrorAction Stop }
      Log "launched: $($t.Exe) $($t.Args)"
    } catch { Log "FAILED: $($t.Exe) -> $($_.Exception.Message)" }
    # grey the button out with a brief "Opening..." so people don't rapid-fire click
    $tmr = New-Object System.Windows.Forms.Timer
    $tmr.Interval = 4000
    $tmr.Tag = @{ B = $btn; T = $orig }
    $tmr.Add_Tick({ $x = $this.Tag; $x.B.Enabled = $true; $x.B.Text = $x.T; $this.Stop(); $this.Dispose() })
    $tmr.Start()
  })
  $b.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(51,65,85) })
  $b.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })
  return $b
}
# full-screen launcher "desktop" (visible when no app is open)
$bg = New-Object System.Windows.Forms.Form
$bg.FormBorderStyle = "None"; $bg.StartPosition = "Manual"
$bg.Bounds = New-Object System.Drawing.Rectangle(0, 0, $scr.Width, ($scr.Height - $barH))
$bg.BackColor = $colBg
$bg.Add_FormClosing({ if ($args[1].CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $args[1].Cancel = $true } })
$title = New-Object System.Windows.Forms.Label
$title.Text = "Otzar Hachochma"; $title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Segoe UI Light", 42)
$title.TextAlign = "MiddleCenter"; $title.SetBounds(0, 80, $scr.Width, 100)
$bg.Controls.Add($title)
$tw = 300; $th = 190; $gap = 44
$sx = [int](($scr.Width - ($tw * 3 + $gap * 2)) / 2)
$ty = [int](($scr.Height - $barH) / 2 - $th / 2 + 30)
$bg.Controls.Add((New-Tile "Otzar Hachochma" "__OTZAR__" $sx $ty $tw $th 22))
$bg.Controls.Add((New-Tile "LibreOffice" "__LIBRE__" ($sx + $tw + $gap) $ty $tw $th 22))
$bg.Controls.Add((New-Tile "PDF Files" "__PDF__" ($sx + ($tw + $gap) * 2) $ty $tw $th 22 "__PDFARGS__"))
$cred = New-Object System.Windows.Forms.Label
$cred.Text = "Built by Shalom Karr (216) 451-6698"
$cred.ForeColor = [System.Drawing.Color]::FromArgb(120,140,170)
$cred.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$cred.TextAlign = "MiddleCenter"; $cred.SetBounds(0, ($scr.Height - $barH - 60), $scr.Width, 30)
$bg.Controls.Add($cred)
# slim always-on-top bottom bar (reachable while an app is open)
$bar = New-Object System.Windows.Forms.Form
$bar.FormBorderStyle = "None"; $bar.TopMost = $true; $bar.ShowInTaskbar = $false
$bar.StartPosition = "Manual"
$bar.Bounds = New-Object System.Drawing.Rectangle(0, ($scr.Height - $barH), $scr.Width, $barH)
$bar.BackColor = $colTile
$bar.Controls.Add((New-Tile "Otzar Hachochma" "__OTZAR__" 12 12 230 48 12))
$bar.Controls.Add((New-Tile "LibreOffice" "__LIBRE__" 254 12 200 48 12))
$bar.Controls.Add((New-Tile "PDF Files" "__PDF__" 466 12 200 48 12 "__PDFARGS__"))
$barCred = New-Object System.Windows.Forms.Label
$barCred.Text = "Built by Shalom Karr (216) 451-6698"
$barCred.ForeColor = [System.Drawing.Color]::FromArgb(150,165,190)
$barCred.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$barCred.TextAlign = "MiddleRight"; $barCred.SetBounds(($scr.Width - 380), 20, 360, 30)
$barCred.Anchor = "Top,Right"
$bar.Controls.Add($barCred)
$bar.Show()
[System.Windows.Forms.Application]::Run($bg)
} catch { try { $_ | Out-File "C:\Users\Public\Documents\OtzarKiosk\kioskbar-error.log" -Force } catch {} }
'@
            $kioskExe    = Join-Path $kiosk "kioskbar.exe"
            $browserPs1  = Join-Path $kiosk "pdfbrowser.ps1"
            $pdfArgs     = "-NoProfile -Sta -ExecutionPolicy Bypass -File $browserPs1"
            $barBody = $barBody.Replace('__OTZAR__', $appPath).Replace('__LIBRE__', $LibreOfficeExe).Replace('__PDF__', $kioskExe).Replace('__PDFARGS__', $pdfArgs)
            $barPs1 = Join-Path $kiosk "kioskbar.ps1"
            Set-Content -Path $barPs1 -Value $barBody -Encoding ASCII

            # embed the read-only PDF-only Documents browser and write it into the locked kiosk folder
            $browserBody = @'
param([string]$Root = "__ROOT__")
try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Root)) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
}
$Root = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\')

$LogDir = "C:\Users\Public\Documents\OtzarKiosk"
try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch {}
function Log($m) { try { Add-Content -LiteralPath "$LogDir\pdfbrowser.log" -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) } catch {} }
Log ("pdfbrowser started, root=" + $Root)

$colBg    = [System.Drawing.Color]::FromArgb(15,23,42)
$colTile  = [System.Drawing.Color]::FromArgb(30,41,59)
$colHover = [System.Drawing.Color]::FromArgb(51,65,85)
$colWhite = [System.Drawing.Color]::White
$fontName = "Segoe UI"

$script:current = $Root

$form = New-Object System.Windows.Forms.Form
$form.Text = "PDF Files"
$form.BackColor = $colBg
$form.WindowState = "Maximized"
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(600, 400)

# --- top bar ---
$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"
$top.Height = 64
$top.BackColor = $colTile
$form.Controls.Add($top)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = "Up"
$btnUp.SetBounds(12, 12, 90, 40)
$btnUp.FlatStyle = "Flat"
$btnUp.FlatAppearance.BorderSize = 0
$btnUp.ForeColor = $colWhite
$btnUp.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
$btnUp.Font = New-Object System.Drawing.Font($fontName, 12)
$btnUp.Cursor = "Hand"
$top.Controls.Add($btnUp)

$lblPath = New-Object System.Windows.Forms.Label
$lblPath.ForeColor = $colWhite
$lblPath.Font = New-Object System.Drawing.Font($fontName, 12)
$lblPath.TextAlign = "MiddleLeft"
$lblPath.SetBounds(116, 12, 700, 40)
$lblPath.Anchor = "Top,Left,Right"
$top.Controls.Add($lblPath)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.FlatStyle = "Flat"
$btnClose.FlatAppearance.BorderSize = 0
$btnClose.ForeColor = $colWhite
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
$btnClose.Font = New-Object System.Drawing.Font($fontName, 12)
$btnClose.Cursor = "Hand"
$btnClose.Anchor = "Top,Right"
$btnClose.SetBounds(($form.ClientSize.Width - 120), 12, 100, 40)
$top.Controls.Add($btnClose)
$btnClose.Add_Click({ $form.Close() })

# --- list area ---
$list = New-Object System.Windows.Forms.ListView
$list.Dock = "Fill"
$list.View = "Details"
$list.FullRowSelect = $true
$list.MultiSelect = $false
$list.HeaderStyle = "None"
$list.BackColor = $colBg
$list.ForeColor = $colWhite
$list.Font = New-Object System.Drawing.Font($fontName, 13)
$list.BorderStyle = "None"
$list.Columns.Add("Name", 900) | Out-Null
$form.Controls.Add($list)
$list.BringToFront()

function Update-Up {
  if ($script:current.TrimEnd('\') -ieq $Root) {
    $btnUp.Enabled = $false
  } else {
    $btnUp.Enabled = $true
  }
}

function Get-RelPath {
  $c = $script:current.TrimEnd('\')
  if ($c -ieq $Root) { return "\" }
  $rel = $c.Substring($Root.Length)
  if (-not $rel.StartsWith('\')) { $rel = "\" + $rel }
  return $rel
}

function Refresh-List {
  $list.BeginUpdate()
  $list.Items.Clear()
  $lblPath.Text = Get-RelPath
  Update-Up

  $dirs = @()
  try {
    $dirs = Get-ChildItem -LiteralPath $script:current -Directory -Force -ErrorAction Stop | Sort-Object Name
  } catch { $dirs = @() }
  foreach ($d in $dirs) {
    try {
      $it = New-Object System.Windows.Forms.ListViewItem("[ ] " + $d.Name)
      $it.Tag = @{ Type = "dir"; Path = $d.FullName }
      $list.Items.Add($it) | Out-Null
    } catch {}
  }

  $files = @()
  try {
    $files = Get-ChildItem -LiteralPath $script:current -File -Force -ErrorAction Stop | Where-Object { $_.Extension -ieq ".pdf" } | Sort-Object Name
  } catch { $files = @() }
  foreach ($f in $files) {
    $it = New-Object System.Windows.Forms.ListViewItem($f.Name)
    $it.Tag = @{ Type = "pdf"; Path = $f.FullName }
    $list.Items.Add($it) | Out-Null
  }
  $list.EndUpdate()
}

function Open-Item($item) {
  if ($null -eq $item) { return }
  $info = $item.Tag
  if ($null -eq $info) { return }
  if ($info.Type -eq "dir") {
    $script:current = $info.Path
    Refresh-List
  } elseif ($info.Type -eq "pdf") {
    try { Start-Process -FilePath $info.Path -ErrorAction Stop; Log ("opened PDF: " + $info.Path) } catch { Log ("FAILED to open PDF: " + $info.Path + " -> " + $_.Exception.Message) }
  }
}

function Go-Up {
  $c = $script:current.TrimEnd('\')
  if ($c -ieq $Root) { return }
  $parent = Split-Path -LiteralPath $c -Parent
  if ([string]::IsNullOrEmpty($parent)) { return }
  if ($parent.Length -lt $Root.Length) { $parent = $Root }
  $script:current = $parent
  Refresh-List
}

$btnUp.Add_Click({ Go-Up })

$list.Add_MouseDoubleClick({
  if ($list.SelectedItems.Count -gt 0) { Open-Item $list.SelectedItems[0] }
})
$list.Add_KeyDown({
  if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    if ($list.SelectedItems.Count -gt 0) { Open-Item $list.SelectedItems[0] }
    $_.Handled = $true
  } elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Back) {
    Go-Up
    $_.Handled = $true
  }
})

# hover effect on buttons
$btnUp.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $colHover } })
$btnUp.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })
$btnClose.Add_MouseEnter({ $this.BackColor = $colHover })
$btnClose.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })

Refresh-List
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
} catch { try { $_ | Out-File "C:\Users\Public\Documents\OtzarKiosk\pdfbrowser-error.log" -Force } catch {} }
'@
            $browserBody = $browserBody.Replace('__ROOT__', "$OtzarProfile\Documents")
            Set-Content -Path $browserPs1 -Value $browserBody -Encoding ASCII

            # the SHELL is a wscript relauncher: launches the bar once (STA) + keeps Otzar running.
            # If the bar ever fails, Otzar still runs full-screen (no black screen).
            $vbsBody = @'
On Error Resume Next
Set sh = CreateObject("WScript.Shell")
sh.Run "__KIOSK__\kioskbar.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File __KIOSK__\kioskbar.ps1", 0, False
Set svc = GetObject("winmgmts:\\.\root\cimv2")
Do
  running = False
  For Each p In svc.ExecQuery("Select Name from Win32_Process")
    If InStr(LCase("" & p.Name), "otzar") > 0 Then running = True
  Next
  If Not running Then sh.Run "__OTZAR__", 1, False
  WScript.Sleep 5000
Loop
'@
            $vbsBody = $vbsBody.Replace('__KIOSK__', $kiosk.TrimEnd('\')).Replace('__OTZAR__', $appPath)
            $vbs = Join-Path $kiosk "relaunch.vbs"
            Set-Content -Path $vbs -Value $vbsBody -Encoding ASCII

            # lock the folder: user can run/read but NOT edit the scripts
            icacls $kiosk /inheritance:r /grant "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "${acct}:(OI)(CI)RX" | Out-Null

            $shellCmd = (Join-Path $kiosk "kioskshell.exe") + " " + $vbs
            reg add $wl /v Shell /t REG_SZ /d $shellCmd /f | Out-Null
            Write-Host "Policies set; shell = wscript relauncher (Otzar full-screen + the launcher bar)." -ForegroundColor Green
            Write-Host "  If the bar fails it logs to the user's TEMP\kioskbar-error.log; Otzar still runs (no black screen)." -ForegroundColor DarkGray
        } else {
            Write-Host "Policies set; could NOT resolve the Otzar exe for the shell - pass -ShellLnk." -ForegroundColor Yellow
        }
    }
    [gc]::Collect(); Start-Sleep 2
    reg unload "HKU\LockAll" | Out-Null
}

# ---------------- clean the Otzar profile: keep Documents, remove Desktop + other user folders ----------------
if ((-not $Undo) -and (Test-Path $OtzarProfile)) {
    # keep Documents + system/AppData folders and Windows junctions (ReparsePoint); delete the rest (Desktop, Downloads, Music, Pictures, Videos, ...)
    $keep = @('Documents','My Documents','AppData','Application Data','Local Settings','Cookies','NetHood','PrintHood','Recent','SendTo','Start Menu','Templates')
    Get-ChildItem $OtzarProfile -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -notin $keep) -and (-not ($_.Attributes.ToString() -match 'ReparsePoint'))
    } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "Cleaned '$OtzarUser' profile (removed Desktop + other folders; kept Documents)." -ForegroundColor Green
}

# ---------------- set the account to a BLANK password (kiosk logs in with NO password) ----------------
if ((-not $Undo) -and (Get-LocalUser -Name $OtzarUser -ErrorAction SilentlyContinue)) {
    net user "$OtzarUser" "" 2>$null | Out-Null                                    # method 1
    try { Set-LocalUser -Name $OtzarUser -Password (New-Object System.Security.SecureString) -ErrorAction Stop } catch { }  # method 2 (fallback)
    Set-LocalUser -Name $OtzarUser -PasswordNeverExpires $true -ErrorAction SilentlyContinue
    Write-Host "Set '$OtzarUser' to a BLANK password (logs in with no password)." -ForegroundColor Green
}

Write-Host "`nDone. Reboot or sign into '$OtzarUser' to verify." -ForegroundColor Magenta
if (-not $Undo) { Write-Host "Escape hatch: Ctrl+Alt+Del -> Switch user -> khaly (admin, unaffected)." -ForegroundColor Cyan }
