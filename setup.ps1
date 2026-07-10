<#
.SYNOPSIS
  Otzar Hachochma kiosk setup. Creates the locked-down "Otzar Hachochma" standard account
  (no password), then blocks EVERY program except Otzar by NTFS-denying execute for that
  user, applies kiosk policies, removes Store/Calculator/media apps, disables Bluetooth,
  keeps printing + AnyDesk-incoming working, and sets Otzar as an auto-relaunching shell.

.DESCRIPTION
  Uses NTFS deny (reliable on Win 11 Pro) + per-user policies. Only the Otzar STANDARD
  account is affected; your admin account is untouched. Run it, log into Otzar once to
  build the profile, then run it again to apply the shell + policies (see readme.md).

.EXAMPLE
  .\setup.ps1 -ListOnly     # preview what would be blocked, make NO changes
.EXAMPLE
  .\setup.ps1               # create the account + apply the full lockdown
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
        "Paint","MSPaint","MediaPlayer",
        "SolitaireCollection","Xbox","GamingApp","BingWeather","BingNews",
        "GetHelp","Getstarted","Tips","OfficeHub","SkypeApp","Teams","MSTeams","People",
        "YourPhone","CrossDevice","WindowsMaps","MixedReality","WindowsAlarms","SoundRecorder",
        "Clipchamp","Todos","PowerAutomateDesktop","WindowsCamera","FeedbackHub","549981C3F5F10","Copilot"
    ),
    [switch]$ListOnly,
    [switch]$Undo
)

# ---- must be elevated ----
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from an ELEVATED PowerShell (Run as Administrator)."
}

# ---- create the locked-down STANDARD account (no password) if it doesn't exist ----
if (-not $Undo) {
    if (Get-LocalUser -Name $OtzarUser -ErrorAction SilentlyContinue) {
        Write-Host "Account '$OtzarUser' already exists." -ForegroundColor DarkGray
    } else {
        New-LocalUser -Name $OtzarUser -NoPassword -FullName $OtzarUser -Description "Locked-down Otzar Hachochma kiosk" -AccountNeverExpires | Out-Null
        Add-LocalGroupMember -Group "Users" -Member $OtzarUser   # STANDARD user, NOT an administrator
        Write-Host "Created STANDARD account '$OtzarUser' (no password)." -ForegroundColor Green
        Write-Host "NEXT: log into '$OtzarUser' ONCE (creates its profile + lets Otzar do first-run)," -ForegroundColor Yellow
        Write-Host "      sign out, then run setup.ps1 AGAIN to apply the kiosk shell + policies." -ForegroundColor Yellow
    }
}

$acct = "$env:COMPUTERNAME\$OtzarUser"
try { $sid = (New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $OtzarUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
catch { $sid = $null; Write-Host "WARN: could not resolve SID for $acct" -ForegroundColor Yellow }

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
           "mspaint.exe","iexplore.exe","WindowsPowerShell\v1.0\powershell.exe","WindowsPowerShell\v1.0\powershell_ise.exe")
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

# AnyDesk: block the USER from launching it. D:\ is allowed, so its AnyDesk.exe must be added explicitly.
# Incoming/unattended still works because the AnyDesk service runs as SYSTEM (not this user).
$adk = @()
$adk += (Get-ChildItem 'D:\' -Filter 'AnyDesk*.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
foreach ($f in @("C:\Program Files (x86)\AnyDesk\AnyDesk.exe","C:\Program Files\AnyDesk\AnyDesk.exe")) { if (Test-Path $f) { $adk += $f } }
foreach ($a in $adk) { if ($deny -notcontains $a) { $deny += $a } }

# Block File Explorer + the Settings app for the user (tested: the explorer.exe deny was NOT the cause
# of the env-var error, so it's safe to keep it blocked). The kiosk shell + policies also remove any
# way to OPEN a File Explorer window.
$extra = @("$env:windir\explorer.exe", "$env:windir\SysWOW64\explorer.exe", "$env:windir\ImmersiveControlPanel\SystemSettings.exe")
foreach ($e in $extra) { if ((Test-Path $e) -and ($deny -notcontains $e)) { $deny += $e } }

# Otzar (Electron) spawns cmd.exe at startup - it MUST be allowed, so pull it back out of the deny list
# even if a Start Menu shortcut pointed at it. The kiosk shell + policies still block the user from opening it.
$keepExe = @("$env:windir\System32\cmd.exe", "$env:windir\SysWOW64\cmd.exe")
$deny = @($deny | Where-Object { $keepExe -notcontains $_ })

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
        reg delete $exp   /v HideSCANetwork             /f 2>$null | Out-Null
        reg delete $net   /v NC_LanChangeProperties     /f 2>$null | Out-Null
        reg delete $net   /v NC_ShowSharedAccessUI      /f 2>$null | Out-Null
        reg delete $net   /v NC_PersonalFirewallConfig  /f 2>$null | Out-Null
        reg delete $net   /v NC_RasConnect              /f 2>$null | Out-Null
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
        # Keyboard layouts for the Otzar user (built into Windows; switch with Left Alt+Shift / Win+Space)
        reg add "HKU\LockAll\Keyboard Layout\Preload" /v 1 /t REG_SZ /d "0000040d" /f | Out-Null   # Hebrew (primary)
        reg add "HKU\LockAll\Keyboard Layout\Preload" /v 2 /t REG_SZ /d "00000409" /f | Out-Null   # English (secondary)
        reg add $exp   /v HideSCANetwork             /t REG_DWORD /d 1 /f | Out-Null   # no network icon / Wi-Fi flyout
        reg add $net   /v NC_LanChangeProperties     /t REG_DWORD /d 0 /f | Out-Null   # can't change connection props
        reg add $net   /v NC_ShowSharedAccessUI      /t REG_DWORD /d 0 /f | Out-Null
        reg add $net   /v NC_PersonalFirewallConfig  /t REG_DWORD /d 0 /f | Out-Null
        reg add $net   /v NC_RasConnect              /t REG_DWORD /d 0 /f | Out-Null

        # kiosk shell = a RELAUNCHER loop so closing Otzar immediately reopens it (no black screen).
        $target = $null
        if (Test-Path $ShellLnk) { $target = $sh.CreateShortcut($ShellLnk).TargetPath }
        if (-not $target) { $target = (Get-ChildItem 'D:\*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'anydesk' } | Select-Object -First 1).FullName }
        if ($target) {
            $drive = [System.IO.Path]::GetPathRoot($target)                       # e.g. D:\
            # ASCII pointer to the Hebrew-named exe (so the .vbs stays pure ASCII)
            $link = Join-Path $drive "OtzarKiosk.exe"
            try {
                if (Test-Path $link) { Remove-Item $link -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
            } catch { $link = $null }
            $appPath = if ($link) { $link } else { $target }

            # relauncher folder on the allowed drive: a copy of wscript + a loop script
            $kiosk = Join-Path $drive "Kiosk"
            New-Item -ItemType Directory -Path $kiosk -Force | Out-Null
            Copy-Item "$env:windir\System32\wscript.exe" (Join-Path $kiosk "wscript.exe") -Force
            $vbs = Join-Path $kiosk "relaunch.vbs"
            $dl      = $drive.Substring(0,2).ToLower()   # e.g. d:
            $kioskLc = $kiosk.ToLower()                  # e.g. d:\kiosk
            $kLen    = $kiosk.Length
            # Poll: only relaunch when NO Otzar process (any exe on the Otzar drive, except the relauncher) is running.
            # This survives Otzar's launcher forking into a second process and its startup dialogs.
            $vbsBody = @"
On Error Resume Next
Set sh = CreateObject("WScript.Shell")
Set svc = GetObject("winmgmts:\\.\root\cimv2")
Do
  running = False
  For Each p In svc.ExecQuery("Select Name from Win32_Process")
    If InStr(LCase("" & p.Name), "otzar") > 0 Then running = True
  Next
  If Not running Then sh.Run "$appPath", 1, False
  WScript.Sleep 5000
Loop
"@
            Set-Content -Path $vbs -Value $vbsBody -Encoding ASCII
            # lock the folder so the user can run but NOT edit the loop (read+execute only)
            icacls $kiosk /inheritance:r /grant "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "${acct}:(OI)(CI)RX" | Out-Null

            $shellCmd = (Join-Path $kiosk "wscript.exe") + " " + $vbs
            reg add $wl /v Shell /t REG_SZ /d $shellCmd /f | Out-Null
            Write-Host "Policies set; relauncher shell = $shellCmd" -ForegroundColor Green
            Write-Host "  (closing Otzar now reopens it automatically - no more black screen)" -ForegroundColor DarkGray
        } else {
            Write-Host "Policies set; could NOT resolve the Otzar exe for the shell - pass -ShellLnk." -ForegroundColor Yellow
        }
    }
    [gc]::Collect(); Start-Sleep 2
    reg unload "HKU\LockAll" | Out-Null
}

Write-Host "`nDone. Reboot or sign into '$OtzarUser' to verify." -ForegroundColor Magenta
if (-not $Undo) { Write-Host "Escape hatch: Ctrl+Alt+Del -> Switch user -> khaly (admin, unaffected)." -ForegroundColor Cyan }
