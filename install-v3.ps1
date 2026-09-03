<#
  install-v3.ps1 - install a classic v3 print driver for the USB printer and switch its queue to it.
  Run from the ADMIN account (elevated). The queue currently uses the modern "Microsoft IPP Class
  Driver", whose capability query hangs ~60s in the kiosk's shell-less session ("0 pages" in Edge).
  A v3 OEM driver reads capabilities from a local file - fast in any session.

  It: finds the printer, checks for an installed v3 driver, and if none, searches disk for the
  brand's printer INF files (from the driver package you installed), stages them with pnputil, then
  re-points the queue. Nothing prints on paper. Safe to re-run.
#>
$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run elevated (admin)." }

$phys = Get-Printer -ErrorAction SilentlyContinue | Where-Object {
    $_.DriverName -notmatch 'Print To PDF|OneNote|XPS|Fax|PDF ?Converter' -and
    $_.PortName   -notmatch '^(PORTPROMPT:|nul:?$|PCONVERT:|SHRFAX:)' } | Select-Object -First 1
if (-not $phys) { Write-Host "No physical printer found." -ForegroundColor Red; return }
$brand = ($phys.Name -split ' ')[0]
Write-Host "Printer : $($phys.Name)"
Write-Host "Driver  : $($phys.DriverName)   Port: $($phys.PortName)   Brand: $brand"

function Get-V3 { Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$brand*" -and $_.MajorVersion -eq 3 -and $_.Name -notlike '*Fax*' } | Select-Object -First 1 }

$v3 = Get-V3
if (-not $v3) {
    Write-Host "`nNo v3 $brand driver in the store yet - searching disk for its printer INF files..." -ForegroundColor Cyan
    $roots = @("$env:ProgramFiles\$brand","${env:ProgramFiles(x86)}\$brand","$env:ProgramData\$brand",
               "$env:SystemDrive\$brand","$env:SystemDrive\${brand}V3","$env:USERPROFILE\Downloads",
               "$env:windir\Temp","$env:TEMP","$env:SystemDrive\Drivers") | Select-Object -Unique
    $infs = @()
    foreach ($r in $roots) {
        if (Test-Path $r) {
            Get-ChildItem $r -Recurse -Depth 6 -Filter *.inf -ErrorAction SilentlyContinue |
                ForEach-Object { if (Select-String -Path $_.FullName -Pattern 'Class\s*=\s*Printer|ClassGuid.*4d36e979' -Quiet -ErrorAction SilentlyContinue) { $infs += $_.FullName } }
        }
    }
    $infs = $infs | Select-Object -Unique
    if ($infs) {
        Write-Host "Found $($infs.Count) printer INF(s); staging with pnputil..." -ForegroundColor Cyan
        foreach ($i in $infs) { Write-Host "  + $i"; & pnputil.exe /add-driver "$i" /install 2>&1 | Out-Null }
    } else { Write-Host "  (no $brand printer INF files found on disk)" -ForegroundColor Yellow }
    # try to register the staged driver as an installed printer driver by its likely names
    foreach ($nm in @("$($phys.Name) Printer", "$($phys.Name)", "$brand $($phys.Name.Split(' ')[-1])", "$brand $($phys.Name.Split(' ')[-1]) Printer")) {
        try { Add-PrinterDriver -Name $nm -ErrorAction Stop; Write-Host "  installed driver: $nm" -ForegroundColor Green } catch {}
    }
    $v3 = Get-V3
}

if ($v3) {
    Write-Host "`nSwitching '$($phys.Name)' to v3 driver '$($v3.Name)'..." -ForegroundColor Cyan
    try {
        Set-Printer -Name $phys.Name -DriverName $v3.Name -ErrorAction Stop
        Restart-Service Spooler -Force -ErrorAction SilentlyContinue; Start-Sleep 2
        Write-Host "SUCCESS: '$($phys.Name)' now uses '$((Get-Printer -Name $phys.Name).DriverName)'." -ForegroundColor Green
        Write-Host "Now sign into the Otzar session and Ctrl+P the Brother - the page count should appear in ~2s." -ForegroundColor Green
    } catch { Write-Host "Switch failed: $($_.Exception.Message)" -ForegroundColor Red }
} else {
    Write-Host "`nNo v3 $brand driver available. This model may only have a modern (v4/IPP) driver." -ForegroundColor Yellow
    Write-Host "Get the v3 one: support.brother.com -> $($phys.Name) -> Downloads -> 'Add Printer Wizard Driver'" -ForegroundColor Yellow
    Write-Host "  (that specific item is the v3 driver; the 'Full Package' is often v4). Extract it to C:\${brand}V3 and re-run this." -ForegroundColor Yellow
    Write-Host "`nAll installed print drivers:" -ForegroundColor Cyan
    Get-PrinterDriver | Select-Object Name, MajorVersion, PrinterEnvironment | Format-Table -Auto
}
