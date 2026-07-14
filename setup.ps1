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
    [bool]$InstallApps      = $false,  # winget-install LibreOffice ONLY if missing (off by default - avoids network/winget; pass -InstallApps $true to allow)
    [string]$LibreOfficeExe = "C:\Program Files\LibreOffice\program\soffice.exe",
    [switch]$ListOnly,
    [switch]$Undo,
    [switch]$NoUpdate                       # skip the GitHub self-update check
)

$KioskVersion = '1.3.2'   # single source of truth for the self-updater (replaces the old VERSION file)

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

# ---- setup progress log: prints to console AND appends to a file the admin can read later ----
$PubLog = "C:\Users\Public\Documents\OtzarKiosk"
try { New-Item -ItemType Directory -Path $PubLog -Force | Out-Null } catch {}
function Slog([string]$m, [string]$color = "Gray") {
    try { Write-Host $m -ForegroundColor $color } catch { Write-Host $m }
    try { Add-Content -LiteralPath "$PubLog\setup.log" -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) } catch {}
}
Slog "===== setup.ps1 starting: user='$OtzarUser' ListOnly=$ListOnly Undo=$Undo InstallApps=$InstallApps =====" "Cyan"

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
    if ($realProfile) { $OtzarProfile = $realProfile; Slog "Using profile: $OtzarProfile" "DarkGray" }
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

# ---------------- find the allowed apps (LibreOffice) locally FIRST; use winget only as a last resort ----------------
# winget can HANG on a slow/firewalled network, so we detect LibreOffice on-disk (NO network) and only fall back to
# winget if it is genuinely missing AND -InstallApps was requested. Every winget call is time-boxed + non-interactive.
function Find-LibreOffice([string]$preferred) {
    $cands = @($preferred,
        "C:\Program Files\LibreOffice\program\soffice.exe",
        "C:\Program Files (x86)\LibreOffice\program\soffice.exe",
        "$env:ProgramFiles\LibreOffice\program\soffice.exe",
        "${env:ProgramFiles(x86)}\LibreOffice\program\soffice.exe")
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return (Get-Item -LiteralPath $c).FullName } }
    return $null
}
function Invoke-WingetTimed([string]$ArgLine, [int]$TimeoutSec, [string]$Label) {
    Slog "  $Label - calling winget (time-boxed ${TimeoutSec}s)..." "Cyan"
    try {
        $p = Start-Process -FilePath "winget" -ArgumentList ($ArgLine + " --disable-interactivity") -NoNewWindow -PassThru -ErrorAction Stop
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            Slog "  $Label TIMED OUT after ${TimeoutSec}s - killed, skipping (network?)." "Yellow"
            try { $p.Kill() } catch {}
        } else { Slog "  $Label - winget exited (code $($p.ExitCode))." "Gray" }
    } catch { Slog "  $Label - winget not available, skipping: $($_.Exception.Message)" "Yellow" }
}

if (-not $Undo) {
    Slog "Checking for LibreOffice on disk (no network call)..." "Cyan"
    $lo = Find-LibreOffice $LibreOfficeExe
    if ($lo) {
        $LibreOfficeExe = $lo
        Slog "LibreOffice found at $LibreOfficeExe - winget NOT needed." "Green"
    } elseif ($InstallApps -and (-not $ListOnly)) {
        Slog "LibreOffice missing and -InstallApps set -> installing via winget (may be slow)." "Yellow"
        Invoke-WingetTimed "install --exact --id TheDocumentFoundation.LibreOffice --scope machine --silent --accept-package-agreements --accept-source-agreements" 600 "LibreOffice install"
        $lo = Find-LibreOffice $LibreOfficeExe
        if ($lo) { $LibreOfficeExe = $lo; Slog "LibreOffice installed at $LibreOfficeExe." "Green" }
        else     { Slog "LibreOffice STILL not found after winget - its launcher button will be skipped." "Yellow" }
    } else {
        Slog "LibreOffice not installed. Skipping winget (pass -InstallApps `$true to auto-install, or install it manually and re-run). Its button will be skipped." "Yellow"
    }

    # remove an old SumatraPDF ONLY if it is actually on disk (local check first - winget runs only if it is present)
    if (-not $ListOnly) {
        $sumatra = @("$env:ProgramFiles\SumatraPDF\SumatraPDF.exe","${env:ProgramFiles(x86)}\SumatraPDF\SumatraPDF.exe","$env:LOCALAPPDATA\SumatraPDF\SumatraPDF.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($sumatra) { Slog "Old SumatraPDF present at $sumatra - removing." "Cyan"; Invoke-WingetTimed "uninstall --id SumatraPDF.SumatraPDF --silent --accept-source-agreements" 180 "SumatraPDF uninstall" }
        else          { Slog "SumatraPDF not installed - nothing to remove (no winget call)." "Gray" }
    }
}

# allow the app folder so the deny-scan below does NOT block LibreOffice
if (Test-Path $LibreOfficeExe) { $AllowFolders += (Split-Path (Split-Path $LibreOfficeExe -Parent) -Parent) }
Slog ("Allowed apps -> LibreOffice='{0}' exists={1} allowed={2}" -f $LibreOfficeExe, (Test-Path $LibreOfficeExe), (Test-Allowed $LibreOfficeExe)) "Green"

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
        # remove the custom .pdf handler (OtzarPDF ProgId + the .pdf Classes default)
        reg delete "HKU\LockAll\Software\Classes\OtzarPDF" /f 2>$null | Out-Null
        reg delete "HKU\LockAll\Software\Classes\.pdf" /f 2>$null | Out-Null
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
using System.Text;
using System.Runtime.InteropServices;
public class WA {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
  [DllImport("user32.dll")] public static extern IntPtr LoadKeyboardLayout(string id, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
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

# --- find a running window: by process-name regex OR by window-title substring ---
function Find-AppWindow($procRe, $titleMatch) {
  $script:hitHwnd = [IntPtr]::Zero
  $cb = [WA+EnumProc]{
    param($h, $l)
    if ($script:hitHwnd -ne [IntPtr]::Zero) { return $true }
    if (-not [WA]::IsWindowVisible($h)) { return $true }
    $len = [WA]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $sb = New-Object System.Text.StringBuilder ($len + 1)
    [WA]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
    $wt = $sb.ToString()
    if ($titleMatch) {
      if ($wt -eq $titleMatch) { $script:hitHwnd = $h; return $false }
    }
    if ($procRe) {
      $pid2 = 0
      [WA]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null
      try {
        $pr = Get-Process -Id $pid2 -ErrorAction Stop
        if ($pr.ProcessName -match $procRe) { $script:hitHwnd = $h; return $false }
      } catch {}
    }
    return $true
  }.GetNewClosure()
  try { [WA]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null } catch {}
  return $script:hitHwnd
}

# --- enumerate ALL matching windows: by process-name regex OR by window-title equality ---
# returns an array of @{ Hwnd = <IntPtr>; Title = <string> } for every visible top-level
# window (non-empty title) whose owning process name matches $procRe OR whose title -eq $titleMatch.
function Get-AppWindows($procRe, $titleMatch) {
  $script:winList = New-Object System.Collections.ArrayList
  $cb2 = [WA+EnumProc]{
    param($h, $l)
    if (-not [WA]::IsWindowVisible($h)) { return $true }
    $len = [WA]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $sb = New-Object System.Text.StringBuilder ($len + 1)
    [WA]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
    $wt = $sb.ToString()
    if ([string]::IsNullOrEmpty($wt)) { return $true }
    $match = $false
    if ($titleMatch -and ($wt -eq $titleMatch)) { $match = $true }
    if ((-not $match) -and $procRe) {
      # match the pattern against the window TITLE first (catches apps whose process name is
      # not "otzar" - e.g. a Hebrew-named or Electron exe), then fall back to the process name
      if ($wt -match $procRe) { $match = $true }
      else {
        $pid3 = 0
        [WA]::GetWindowThreadProcessId($h, [ref]$pid3) | Out-Null
        try {
          $pr = Get-Process -Id $pid3 -ErrorAction Stop
          if ($pr.ProcessName -match $procRe) { $match = $true }
        } catch {}
      }
    }
    if ($match) { [void]$script:winList.Add(@{ Hwnd = $h; Title = $wt }) }
    return $true
  }.GetNewClosure()
  try { [WA]::EnumWindows($cb2, [IntPtr]::Zero) | Out-Null } catch {}
  return @($script:winList.ToArray())
}

# --- diagnostic: log every visible titled window's process name + title (to fix matchers) ---
function Dump-AllWindows {
  try {
    $cb3 = [WA+EnumProc]{
      param($h, $l)
      if (-not [WA]::IsWindowVisible($h)) { return $true }
      $len = [WA]::GetWindowTextLength($h)
      if ($len -le 0) { return $true }
      $sb = New-Object System.Text.StringBuilder ($len + 1)
      [WA]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
      $wt = $sb.ToString()
      if ([string]::IsNullOrEmpty($wt)) { return $true }
      $pn = "?"
      $p3 = 0
      [WA]::GetWindowThreadProcessId($h, [ref]$p3) | Out-Null
      try { $pn = (Get-Process -Id $p3 -ErrorAction Stop).ProcessName } catch {}
      Log ("  WIN proc='" + $pn + "' title='" + $wt + "'")
      return $true
    }.GetNewClosure()
    [WA]::EnumWindows($cb3, [IntPtr]::Zero) | Out-Null
  } catch { Log "dump err: $($_.Exception.Message)" }
}

# --- bring a specific window forward (IsIconic-aware restore) ---
function Show-Window($hwnd) {
  try {
    if ($hwnd -eq [IntPtr]::Zero) { return }
    if ([WA]::IsIconic($hwnd)) { [WA]::ShowWindow($hwnd, 9) | Out-Null }  # SW_RESTORE
    [WA]::BringWindowToTop($hwnd) | Out-Null
    [WA]::SetForegroundWindow($hwnd) | Out-Null
  } catch { Log "show-window err: $($_.Exception.Message)" }
}

# ================= mini-taskbar: shared hover popup + per-tile badges =================
# ONE reusable borderless TopMost popup listing a tile's open windows; rebuilt each hover.
$script:pop = New-Object System.Windows.Forms.Form
$script:pop.FormBorderStyle = "None"
$script:pop.TopMost = $true
$script:pop.ShowInTaskbar = $false
$script:pop.StartPosition = "Manual"
$script:pop.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
$script:pop.Width = 360
$script:pop.Height = 40
$script:pop.Visible = $false
$script:popTile = $null   # the tile the popup currently belongs to

# hide the popup only when the cursor is over NEITHER the tile NOR the popup
$script:popTmr = New-Object System.Windows.Forms.Timer
$script:popTmr.Interval = 250
$script:popTmr.Add_Tick({
  try {
    if (-not $script:pop.Visible) { return }
    $cp = [System.Windows.Forms.Cursor]::Position
    $overPop = $script:pop.Bounds.Contains($cp)
    $overTile = $false
    if ($script:popTile -ne $null) {
      try {
        $tp = $script:popTile.PointToScreen([System.Drawing.Point]::Empty)
        $tb = New-Object System.Drawing.Rectangle($tp.X, $tp.Y, $script:popTile.Width, $script:popTile.Height)
        if ($tb.Contains($cp)) { $overTile = $true }
      } catch {}
    }
    if (-not $overPop -and -not $overTile) { $script:pop.Hide(); $script:popTile = $null }
  } catch { Log "popTmr err: $($_.Exception.Message)" }
})
$script:popTmr.Start()

# fit a title to the popup width with an ellipsis
function Fit-Text($s, $max) {
  if ($null -eq $s) { return "" }
  if ($s.Length -le $max) { return $s }
  if ($max -le 3) { return $s.Substring(0, $max) }
  return ($s.Substring(0, $max - 3) + "...")
}

# show the shared popup just ABOVE $tile, listing its open windows (rebuilds rows each call)
function Show-TilePopup($tile) {
  try {
    $t = $tile.Tag
    $wins = @()
    try { $wins = Get-AppWindows $t.Proc $t.Title } catch { Log "popup enum err: $($_.Exception.Message)"; return }
    if ($wins.Count -lt 1) {
      Log ("arrow: no windows matched [proc='" + $t.Proc + "' title='" + $t.Title + "'] - dumping all visible windows:")
      Dump-AllWindows
      $script:pop.Hide(); $script:popTile = $null; return
    }
    $script:popTile = $tile
    $script:pop.Controls.Clear()
    $rowH = 34; $pad = 6
    $script:pop.Width = 360
    $y = $pad
    $closeW = 28   # width of the per-row "X" close button on the right
    foreach ($w in $wins) {
      $rowW = 360 - $pad * 2
      $row = New-Object System.Windows.Forms.Label
      $row.Text = (Fit-Text $w.Title 42)
      $row.ForeColor = [System.Drawing.Color]::White
      $row.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
      $row.Font = New-Object System.Drawing.Font("Segoe UI", 11)
      $row.TextAlign = "MiddleLeft"
      $row.SetBounds($pad, $y, $rowW, $rowH)
      $row.Cursor = "Hand"
      # leave room on the right so the "X" button never overlaps the title text
      $row.Padding = New-Object System.Windows.Forms.Padding(8,0,($closeW + 6),0)
      $row.Tag = $w.Hwnd
      $row.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(51,65,85) })
      $row.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })
      $row.Add_Click({
        try {
          $hwnd = $this.Tag
          Show-Window $hwnd
          Log "popup focus window: $($this.Text)"
        } catch { Log "popup click err: $($_.Exception.Message)" }
        $script:pop.Hide(); $script:popTile = $null
      })
      $script:pop.Controls.Add($row)
      # per-row "X" close button (its own control, drawn on TOP of the row so it does
      # NOT trigger the row's focus/activate click). Posts WM_CLOSE (graceful) to the hwnd.
      $closeBtn = New-Object System.Windows.Forms.Button
      $closeBtn.Text = "X"
      $closeBtn.FlatStyle = "Flat"; $closeBtn.FlatAppearance.BorderSize = 0
      $closeBtn.ForeColor = [System.Drawing.Color]::White
      $closeBtn.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
      $closeBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
      $closeBtn.Cursor = "Hand"
      $closeBtn.TabStop = $false
      $cy = $y + [int](($rowH - $closeW) / 2)
      $closeBtn.SetBounds(($pad + $rowW - $closeW - 2), $cy, $closeW, $closeW)
      # keep the hwnd AND the owning tile on the button so the handler can close + refresh
      $closeBtn.Tag = @{ Hwnd = $w.Hwnd; Tile = $tile; Title = $w.Title }
      $closeBtn.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(190,60,60) })
      $closeBtn.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })
      $closeBtn.Add_Click({
        try {
          $d = $this.Tag
          $hwnd = $d.Hwnd
          # WM_CLOSE = 0x0010 - graceful close (lets the app prompt to save). NOT a kill.
          [WA]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
          Log "popup close window: $($d.Title)"
          # refresh: re-enumerate this tile's windows and rebuild the popup rows
          # (Show-TilePopup hides the popup itself when the tile now has 0 windows)
          Show-TilePopup $d.Tile
        } catch { Log "popup close err: $($_.Exception.Message)" }
      })
      $script:pop.Controls.Add($closeBtn)
      $closeBtn.BringToFront()
      $y += $rowH
    }
    $script:pop.Height = $y + $pad
    # position just above the tile
    $tp = $tile.PointToScreen([System.Drawing.Point]::Empty)
    $px = $tp.X
    if (($px + $script:pop.Width) -gt $scr.Width) { $px = $scr.Width - $script:pop.Width }
    if ($px -lt 0) { $px = 0 }
    $py = $tp.Y - $script:pop.Height - 4
    if ($py -lt 0) { $py = 0 }
    $script:pop.Location = New-Object System.Drawing.Point($px, $py)
    $script:pop.Show()
    $script:pop.BringToFront()
  } catch { Log "Show-TilePopup err: $($_.Exception.Message)" }
}

# collection of bar tiles (tile -> its badge label) for the count timer
$script:barTiles = New-Object System.Collections.ArrayList

function New-Tile($text, $exe, $x, $y, $w, $h, $fs, $tileArgs, $procMatch, $titleMatch) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.SetBounds($x, $y, $w, $h)
  $b.FlatStyle = "Flat"; $b.FlatAppearance.BorderSize = 0
  $b.ForeColor = [System.Drawing.Color]::White; $b.BackColor = $colTile
  $b.Font = New-Object System.Drawing.Font("Segoe UI Semibold", $fs)
  $b.Cursor = "Hand"
  $b.Tag = @{ Exe = $exe; Args = $tileArgs; Proc = $procMatch; Title = $titleMatch }
  $b.Add_Click({
    $t = $this.Tag
    $btn = $this; $orig = $btn.Text
    # count open windows: >=1 -> focus first (instant, no grey-out); 0 -> launch (grey-out)
    $wins = @()
    try { $wins = Get-AppWindows $t.Proc $t.Title } catch { Log "click enum err: $($_.Exception.Message)" }
    if ($wins.Count -ge 1) {
      try { Show-Window $wins[0].Hwnd; Log "reshown: $($t.Exe) ($text)" } catch { Log "reshow err: $($_.Exception.Message)" }
      return
    }
    # no open window -> launch it, with a brief "Opening..." grey-out so people don't rapid-fire click
    $btn.Enabled = $false; $btn.Text = "Opening..."
    try {
      if (-not (Test-Path -LiteralPath $t.Exe)) { Log "MISSING exe: $($t.Exe)"; $btn.Enabled = $true; $btn.Text = $orig; return }
      if ($t.Args) { Start-Process -FilePath $t.Exe -ArgumentList $t.Args -ErrorAction Stop }
      else         { Start-Process -FilePath $t.Exe -ErrorAction Stop }
      Log "launched: $($t.Exe) $($t.Args)"
    } catch { Log "FAILED: $($t.Exe) -> $($_.Exception.Message)" }
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

# turn a BAR tile into a mini-taskbar tile: a small "^" button on the tile's right edge that shows
# the open-window count and, when CLICKED, pops up the list of that app's windows.
# A child Button renders reliably over a parent Button (a sibling Label did not), and an explicit
# click is more reliable than hover.
function Register-BarTile($tile, $badgeParent) {
  try {
    $arrow = New-Object System.Windows.Forms.Button
    $arrow.Text = "^"
    $arrow.FlatStyle = "Flat"; $arrow.FlatAppearance.BorderSize = 0
    $arrow.ForeColor = [System.Drawing.Color]::White
    $arrow.BackColor = [System.Drawing.Color]::FromArgb(51,65,85)
    $arrow.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $arrow.Cursor = "Hand"
    $arrow.TabStop = $false
    $aw = 40
    $arrow.SetBounds(($tile.Width - $aw - 3), 5, $aw, ($tile.Height - 10))
    $arrow.Anchor = "Top,Right"
    $tile.Controls.Add($arrow)
    $arrow.BringToFront()
    $arrow.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(71,85,105) })
    $arrow.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(51,65,85) })
    # click the arrow -> show the window-list popup. Capture THIS tile explicitly.
    $capTile = $tile
    $arrow.Add_Click({ try { Show-TilePopup $capTile } catch { Log "arrow err: $($_.Exception.Message)" } }.GetNewClosure())
    [void]$script:barTiles.Add(@{ Tile = $tile; Arrow = $arrow; LastN = -1 })
  } catch { Log "Register-BarTile err: $($_.Exception.Message)" }
}

# --- language toggle: switch the foreground app's keyboard layout Hebrew <-> English ---
$script:hebHkl = [IntPtr]::Zero
$script:engHkl = [IntPtr]::Zero
try {
  $script:hebHkl = [WA]::LoadKeyboardLayout("0000040d", 0)   # Hebrew
  $script:engHkl = [WA]::LoadKeyboardLayout("00000409", 0)   # English (US)
} catch { Log "LoadKeyboardLayout failed: $($_.Exception.Message)" }

function Get-ForeLang {
  # returns "HE" or "EN" for the foreground window's current layout (best-effort)
  try {
    $fg = [WA]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return "EN" }
    $p = 0
    $tid = [WA]::GetWindowThreadProcessId($fg, [ref]$p)
    $hkl = [WA]::GetKeyboardLayout($tid)
    $lid = $hkl.ToInt64() -band 0xFFFF
    if ($lid -eq 0x040d) { return "HE" } else { return "EN" }
  } catch { return "EN" }
}

function Toggle-Lang {
  try {
    $fg = [WA]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { Log "toggle-lang: no foreground window"; return }
    $cur = Get-ForeLang
    if ($cur -eq "HE") { $target = $script:engHkl } else { $target = $script:hebHkl }
    if ($target -eq [IntPtr]::Zero) { Log "toggle-lang: target HKL not loaded"; return }
    # WM_INPUTLANGCHANGEREQUEST = 0x0050, flag 1 = post-to-window
    [WA]::PostMessage($fg, 0x0050, [IntPtr]1, $target) | Out-Null
    Log ("toggle-lang: " + $cur + " -> " + $(if ($cur -eq "HE") { "EN" } else { "HE" }))
  } catch { Log "toggle-lang failed: $($_.Exception.Message)" }
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
$bg.Controls.Add((New-Tile "Otzar Hachochma" "__OTZAR__" $sx $ty $tw $th 22 $null "(?i)otzar" $null))
$bg.Controls.Add((New-Tile "LibreOffice" "__LIBRE__" ($sx + $tw + $gap) $ty $tw $th 22 $null "(?i)soffice|libreoffice" $null))
$bg.Controls.Add((New-Tile "PDF Files" "__PDF__" ($sx + ($tw + $gap) * 2) $ty $tw $th 22 "__PDFARGS__" $null "PDF Files"))
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
$tileOtzar = New-Tile "Otzar Hachochma" "__OTZAR__" 12 12 230 48 12 $null "(?i)otzar" $null
$tileLibre = New-Tile "LibreOffice" "__LIBRE__" 254 12 200 48 12 $null "(?i)soffice|libreoffice" $null
$tilePdf   = New-Tile "PDF Files" "__PDF__" 466 12 200 48 12 "__PDFARGS__" $null "PDF Files"
$bar.Controls.Add($tileOtzar)
$bar.Controls.Add($tileLibre)
$bar.Controls.Add($tilePdf)
# make the bar tiles into mini-taskbar tiles: count badge + hover window-list popup
Register-BarTile $tileOtzar $bar
Register-BarTile $tileLibre $bar
Register-BarTile $tilePdf   $bar
# language toggle button (left of the credit label)
$btnLang = New-Object System.Windows.Forms.Button
$btnLang.Text = "EN"; $btnLang.SetBounds(($scr.Width - 490), 12, 90, 48)
$btnLang.FlatStyle = "Flat"; $btnLang.FlatAppearance.BorderSize = 0
$btnLang.ForeColor = [System.Drawing.Color]::White
$btnLang.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
$btnLang.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$btnLang.Cursor = "Hand"
$btnLang.Anchor = "Top,Right"
$btnLang.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(51,65,85) })
$btnLang.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })
$btnLang.Add_Click({ Toggle-Lang; try { $btnLang.Text = Get-ForeLang } catch {} })
$bar.Controls.Add($btnLang)
$barCred = New-Object System.Windows.Forms.Label
$barCred.Text = "Built by Shalom Karr (216) 451-6698"
$barCred.ForeColor = [System.Drawing.Color]::FromArgb(150,165,190)
$barCred.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$barCred.TextAlign = "MiddleRight"; $barCred.SetBounds(($scr.Width - 390), 20, 370, 30)
$barCred.Anchor = "Top,Right"
$bar.Controls.Add($barCred)
# ~1s timer to keep the language label in sync with the focused app
$langTmr = New-Object System.Windows.Forms.Timer
$langTmr.Interval = 1000
$langTmr.Add_Tick({ try { $btnLang.Text = Get-ForeLang } catch {} })
$langTmr.Start()
# ~1s timer to recompute each bar tile's open-window count and update its badge (hide at 0)
$badgeTmr = New-Object System.Windows.Forms.Timer
$badgeTmr.Interval = 1000
$badgeTmr.Add_Tick({
  try {
    foreach ($e in $script:barTiles) {
      try {
        $t = $e.Tile.Tag
        $n = 0
        $wins = Get-AppWindows $t.Proc $t.Title
        $n = @($wins).Count
        if ($n -ne $e.LastN) {
          Log ("windows [" + $t.Proc + " / " + $t.Title + "] = " + $n)
          $e.LastN = $n
          # show the count on the arrow button (e.g. "2 ^"), or just "^" when nothing is open
          if ($n -gt 0) { $e.Arrow.Text = "$n ^" } else { $e.Arrow.Text = "^" }
          $e.Arrow.BringToFront()
        }
      } catch { Log "badge tile err: $($_.Exception.Message)" }
    }
  } catch { Log "badgeTmr err: $($_.Exception.Message)" }
})
$badgeTmr.Start()
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
param([string]$ProfileDir = "__ROOT__")
try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$LogDir = "C:\Users\Public\Documents\OtzarKiosk"
try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch {}
function Log($m) { try { Add-Content -LiteralPath "$LogDir\pdfbrowser.log" -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) } catch {} }

$ProfileDir = $ProfileDir.TrimEnd('\')
$docs = Join-Path $ProfileDir "Documents"
$dl   = Join-Path $ProfileDir "Downloads"
foreach ($r in @($docs, $dl)) {
  try { if (-not (Test-Path -LiteralPath $r)) { New-Item -ItemType Directory -Force -Path $r | Out-Null } } catch {}
}
try { $docs = (Get-Item -LiteralPath $docs).FullName.TrimEnd('\') } catch {}
try { $dl   = (Get-Item -LiteralPath $dl).FullName.TrimEnd('\') } catch {}
Log ("pdfbrowser started, docs=" + $docs + " dl=" + $dl)

# the two allowed roots (label -> path)
$roots = @(
  @{ Name = "Documents"; Path = $docs },
  @{ Name = "Downloads"; Path = $dl }
)

$colBg     = [System.Drawing.Color]::FromArgb(15,23,42)
$colCard   = [System.Drawing.Color]::FromArgb(30,41,59)
$colHover  = [System.Drawing.Color]::FromArgb(51,65,85)
$colWhite  = [System.Drawing.Color]::White
$colMuted  = [System.Drawing.Color]::FromArgb(148,163,184)
$colFolder = [System.Drawing.Color]::FromArgb(250,204,21)
$colPdf    = [System.Drawing.Color]::FromArgb(96,165,250)
$fontName  = "Segoe UI"

# find msedge.exe (app-mode viewer)
$script:edge = $null
foreach ($c in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
  if ($c -and (Test-Path -LiteralPath $c)) { $script:edge = $c; break }
}

function Open-Pdf($path) {
  try {
    if (-not $script:edge) { Log ("FAILED to open PDF (no msedge): " + $path); return }
    $full = (Resolve-Path -LiteralPath $path).Path
    $uri = ([System.Uri]$full).AbsoluteUri
    Start-Process -FilePath $script:edge -ArgumentList ('--app=' + $uri) -ErrorAction Stop
    Log ("opened PDF (app-mode): " + $path)
  } catch { Log ("FAILED to open PDF: " + $path + " -> " + $_.Exception.Message) }
}

# $null current = the two-root "home"; otherwise the full path we are inside
$script:current = $null

function Get-RootFor($path) {
  # returns the root hashtable that $path lives under, or $null
  if ($null -eq $path) { return $null }
  $p = $path.TrimEnd('\')
  foreach ($r in $roots) {
    $rp = $r.Path.TrimEnd('\')
    if ($p -ieq $rp) { return $r }
    if ($p.ToLower().StartsWith($rp.ToLower() + '\')) { return $r }
  }
  return $null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "PDF Files"
$form.BackColor = $colBg
$form.WindowState = "Maximized"
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(700, 480)

# --- top header bar ---
$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"
$top.Height = 108
$top.BackColor = $colCard
$form.Controls.Add($top)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "PDF Files"
$lblTitle.ForeColor = $colWhite
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 20)
$lblTitle.TextAlign = "MiddleLeft"
$lblTitle.SetBounds(24, 10, 400, 40)
$top.Controls.Add($lblTitle)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = "Up"
$btnUp.SetBounds(24, 56, 120, 44)
$btnUp.FlatStyle = "Flat"
$btnUp.FlatAppearance.BorderSize = 0
$btnUp.ForeColor = $colWhite
$btnUp.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
$btnUp.Font = New-Object System.Drawing.Font($fontName, 13)
$btnUp.Cursor = "Hand"
$top.Controls.Add($btnUp)

$lblPath = New-Object System.Windows.Forms.Label
$lblPath.ForeColor = $colMuted
$lblPath.Font = New-Object System.Drawing.Font($fontName, 13)
$lblPath.TextAlign = "MiddleLeft"
$lblPath.SetBounds(160, 56, 800, 44)
$lblPath.Anchor = "Top,Left,Right"
$top.Controls.Add($lblPath)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.FlatStyle = "Flat"
$btnClose.FlatAppearance.BorderSize = 0
$btnClose.ForeColor = $colWhite
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(190,60,60)
$btnClose.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$btnClose.Cursor = "Hand"
$btnClose.Anchor = "Top,Right"
$btnClose.SetBounds(($form.ClientSize.Width - 180), 30, 150, 52)
$top.Controls.Add($btnClose)
$btnClose.Add_Click({ $form.Close() })

# --- card area: a scrolling FlowLayoutPanel of tiles ---
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = "Fill"
$flow.AutoScroll = $true
$flow.WrapContents = $true
$flow.FlowDirection = "LeftToRight"
$flow.BackColor = $colBg
$flow.Padding = New-Object System.Windows.Forms.Padding(12)
$form.Controls.Add($flow)
$flow.BringToFront()

function New-Card($kind, $name, $path) {
  # $kind = "dir" or "pdf"
  $card = New-Object System.Windows.Forms.Button
  $card.Width = 200; $card.Height = 150
  $card.Margin = New-Object System.Windows.Forms.Padding(12)
  $card.FlatStyle = "Flat"
  $card.FlatAppearance.BorderSize = 0
  $card.BackColor = $colCard
  $card.ForeColor = $colWhite
  $card.Cursor = "Hand"
  $card.TextAlign = "MiddleCenter"
  $card.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
  if ($kind -eq "dir") { $tag = "FOLDER"; $accent = $colFolder } else { $tag = "PDF"; $accent = $colPdf }
  $card.Text = $name
  $card.Tag = @{ Type = $kind; Path = $path }

  # accent label at the top of the card (FOLDER / PDF)
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = $tag
  $lbl.ForeColor = $accent
  $lbl.BackColor = [System.Drawing.Color]::Transparent
  $lbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
  $lbl.TextAlign = "MiddleCenter"
  $lbl.SetBounds(0, 8, 200, 22)
  $lbl.Cursor = "Hand"
  $card.Controls.Add($lbl)

  $onEnter = { $this.BackColor = $colHover }.GetNewClosure()
  $onLeave = { $this.BackColor = $colCard }.GetNewClosure()
  $card.Add_MouseEnter($onEnter)
  $card.Add_MouseLeave($onLeave)
  # clicking the label should behave like clicking the card
  $lbl.Add_Click({ $this.Parent.PerformClick() })

  $card.Add_Click({
    $info = $this.Tag
    if ($null -eq $info) { return }
    if ($info.Type -eq "dir") {
      $script:current = $info.Path
      Refresh-List
    } elseif ($info.Type -eq "pdf") {
      Open-Pdf $info.Path
    }
  })
  return $card
}

function Update-Up {
  if ($null -eq $script:current) { $btnUp.Enabled = $false } else { $btnUp.Enabled = $true }
}

function Get-DisplayPath {
  if ($null -eq $script:current) { return "Home" }
  $r = Get-RootFor $script:current
  if ($null -eq $r) { return "Home" }
  $rp = $r.Path.TrimEnd('\')
  $c = $script:current.TrimEnd('\')
  if ($c -ieq $rp) { return $r.Name }
  $rel = $c.Substring($rp.Length)
  return ($r.Name + $rel)
}

function Refresh-List {
  $flow.SuspendLayout()
  $flow.Controls.Clear()
  $lblPath.Text = Get-DisplayPath
  Update-Up

  if ($null -eq $script:current) {
    # two-root home
    foreach ($r in $roots) {
      $flow.Controls.Add((New-Card "dir" $r.Name $r.Path))
    }
    $flow.ResumeLayout()
    return
  }

  $dirs = @()
  try {
    $dirs = Get-ChildItem -LiteralPath $script:current -Directory -Force -ErrorAction Stop | Sort-Object Name
  } catch { $dirs = @() }
  foreach ($d in $dirs) {
    try { $flow.Controls.Add((New-Card "dir" $d.Name $d.FullName)) } catch {}
  }

  $files = @()
  try {
    $files = Get-ChildItem -LiteralPath $script:current -File -Force -ErrorAction Stop | Where-Object { $_.Extension -ieq ".pdf" } | Sort-Object Name
  } catch { $files = @() }
  foreach ($f in $files) {
    try { $flow.Controls.Add((New-Card "pdf" $f.Name $f.FullName)) } catch {}
  }
  $flow.ResumeLayout()
}

function Go-Up {
  if ($null -eq $script:current) { return }
  $r = Get-RootFor $script:current
  if ($null -eq $r) { $script:current = $null; Refresh-List; return }
  $c = $script:current.TrimEnd('\')
  $rp = $r.Path.TrimEnd('\')
  if ($c -ieq $rp) {
    # at a root -> back to the two-root home
    $script:current = $null
    Refresh-List
    return
  }
  $parent = Split-Path -LiteralPath $c -Parent
  if ([string]::IsNullOrEmpty($parent) -or ($parent.Length -lt $rp.Length)) { $parent = $rp }
  # never climb above the root
  if (-not (($parent.TrimEnd('\') -ieq $rp) -or ($parent.ToLower().StartsWith($rp.ToLower() + '\')))) { $parent = $rp }
  $script:current = $parent
  Refresh-List
}

$btnUp.Add_Click({ Go-Up })

# hover effect on buttons
$btnUp.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $colHover } })
$btnUp.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })
$btnClose.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(220,80,80) })
$btnClose.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(190,60,60) })

Refresh-List
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
} catch { try { $_ | Out-File "C:\Users\Public\Documents\OtzarKiosk\pdfbrowser-error.log" -Force } catch {} }
'@
            $browserBody = $browserBody.Replace('__ROOT__', "$OtzarProfile")
            Set-Content -Path $browserPs1 -Value $browserBody -Encoding ASCII

            # embed the PDF-only launch shim: opens a .pdf in an Edge APP WINDOW (no address bar / tabs),
            # and REFUSES to open anything that is not a .pdf. Registered below as the .pdf handler.
            $pdfOpenBody = @'
param([string]$Path)

$LogDir = "C:\Users\Public\Documents\OtzarKiosk"
try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch {}
function Log($m) { try { Add-Content -LiteralPath "$LogDir\pdfopen.log" -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) } catch {} }

try {
  if ([string]::IsNullOrEmpty($Path)) { Log "empty path -> exit"; return }

  $ext = [System.IO.Path]::GetExtension($Path)
  if ($ext -notmatch '^\.pdf$') { Log ("BLOCKED non-pdf: " + $Path); return }

  if (-not (Test-Path -LiteralPath $Path)) { Log ("missing: " + $Path); return }

  $full = (Resolve-Path -LiteralPath $Path).Path
  $uri = ([System.Uri]$full).AbsoluteUri

  $edge = $null
  foreach ($c in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
    if ($c -and (Test-Path -LiteralPath $c)) { $edge = $c; break }
  }
  if (-not $edge) { Log "msedge.exe not found -> exit"; return }

  Start-Process -FilePath $edge -ArgumentList ('--app=' + $uri)
  Log ("opened (app-mode): " + $uri)
} catch { Log ("EXCEPTION: " + $_.Exception.Message) }
'@
            $pdfOpenPs1 = Join-Path $kiosk "pdfopen.ps1"
            Set-Content -Path $pdfOpenPs1 -Value $pdfOpenBody -Encoding ASCII

            # Register pdfopen.ps1 as the kiosk user's .pdf handler so Otzar's own PDF opens route through it
            # (and thus open in a no-navigation Edge app window). $kioskExe is the copied powershell.exe.
            # Best-effort: if Windows later regenerates a UserChoice for .pdf, the association can revert to
            # Edge-normal, but the custom PDF browser always opens PDFs via the app-mode path regardless.
            $pdfCmd = '"' + $kioskExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $pdfOpenPs1 + '" "%1"'
            reg add "HKU\LockAll\Software\Classes\OtzarPDF" /ve /t REG_SZ /d "Otzar PDF" /f | Out-Null
            reg add "HKU\LockAll\Software\Classes\OtzarPDF\shell\open\command" /ve /t REG_SZ /d $pdfCmd /f | Out-Null
            reg add "HKU\LockAll\Software\Classes\.pdf" /ve /t REG_SZ /d "OtzarPDF" /f | Out-Null
            reg add "HKU\LockAll\Software\Classes\.pdf\OpenWithProgids" /v OtzarPDF /t REG_NONE /f | Out-Null
            # remove any forced UserChoice so the Classes fallback applies (ignore if absent)
            reg delete "HKU\LockAll\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pdf\UserChoice" /f 2>$null | Out-Null

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
    # keep Documents + Downloads + system/AppData folders and Windows junctions (ReparsePoint); delete the rest (Desktop, Music, Pictures, Videos, ...)
    $keep = @('Documents','My Documents','Downloads','AppData','Application Data','Local Settings','Cookies','NetHood','PrintHood','Recent','SendTo','Start Menu','Templates')
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
