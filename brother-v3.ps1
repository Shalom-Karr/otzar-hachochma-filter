<#
  brother-v3.ps1 - download Brother's standalone printer driver for the MFC-J4355DW, install the v3
  driver from its INF, and switch the queue to it (fixes the modern IPP driver's ~60s "0 pages" stall
  in the kiosk session). Run from the ADMIN account (elevated). Nothing prints on paper.

  Direct link resolved from support.brother.com (dlid dlf106935 - "Printer Driver"). If Brother ever
  changes it, replace $url with the new download.brother.com link.
#>
$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run elevated (admin)." }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url = 'https://download.brother.com/welcome/dlf106935/Y24B_C1-hostm-A1.EXE'
$dir = 'C:\BrotherV3'
$exe = "$dir\brother-driver.exe"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

Write-Host "Downloading Brother printer driver (~50 MB)..." -ForegroundColor Cyan
# how big should it be? (integrity check so we never extract a truncated file)
$expected = 0; try { $expected = [long]((Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent'='Mozilla/5.0' }).Headers.'Content-Length') } catch {}
function Good { param($f,$exp) (Test-Path $f) -and ((Get-Item $f).Length -ge ($(if($exp -gt 0){$exp*0.98}else{40MB}))) }

$ok = Good $exe $expected
if ($ok) { Write-Host "  already downloaded." -ForegroundColor Green }
for ($try = 1; $try -le 30 -and -not $ok; $try++) {
    Write-Host "  attempt $try ... ($(Get-Date -Format 'HH:mm'))" -ForegroundColor DarkGray
    try {
        # BITS: resumes across the filter dropping the connection; best for flaky networks. Very
        # patient (safe to leave running overnight) - keeps resuming a transient error up to 2h.
        Import-Module BitsTransfer -ErrorAction SilentlyContinue
        Start-BitsTransfer -Source $url -Destination $exe -ErrorAction Stop -RetryInterval 60 -RetryTimeout 7200
    } catch {
        Write-Host "    BITS failed ($($_.Exception.Message)); trying a direct download..." -ForegroundColor DarkGray
        try { Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing -TimeoutSec 900 -Headers @{ 'User-Agent'='Mozilla/5.0' } } catch { Write-Host "    direct download failed ($($_.Exception.Message))" -ForegroundColor DarkGray }
    }
    $ok = Good $exe $expected
    if (-not $ok) { Remove-Item $exe -Force -ErrorAction SilentlyContinue; Start-Sleep 4 }
}
if (-not $ok) {
    Write-Host "Download failed after retries - the content filter is likely blocking download.brother.com." -ForegroundColor Red
    Write-Host "Workaround: download this file on any other computer/phone:" -ForegroundColor Yellow
    Write-Host "  $url" -ForegroundColor Yellow
    Write-Host "then copy it to '$exe' and re-run this script (it will skip the download)." -ForegroundColor Yellow
    return
}
Write-Host "  saved $exe ($([math]::Round((Get-Item $exe).Length/1MB,1)) MB)" -ForegroundColor Green

Write-Host "Extracting the driver (a Brother window may briefly appear - that's fine)..." -ForegroundColor Cyan
$t0 = (Get-Date).AddMinutes(-1)
$proc = Start-Process -FilePath $exe -PassThru   # self-extracts; may also start Brother's own setup UI

# Poll up to 90s for freshly-extracted Brother PRINTER inf files to appear anywhere plausible
$searchRoots = @($dir, $env:TEMP, "$env:windir\Temp", "$env:SystemDrive\", "$env:ProgramFiles\Brother", "${env:ProgramFiles(x86)}\Brother", "$env:ProgramData\Brother") | Select-Object -Unique
$infs = @()
for ($w = 0; $w -lt 30 -and -not $infs.Count; $w++) {
    Start-Sleep 3
    foreach ($r in $searchRoots) {
        if (-not (Test-Path $r)) { continue }
        Get-ChildItem $r -Recurse -Depth 6 -Filter *.inf -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $t0 } |
            ForEach-Object { if (Select-String -Path $_.FullName -Pattern 'Class\s*=\s*Printer|ClassGuid.*4d36e979' -Quiet -ErrorAction SilentlyContinue) { $infs += $_.FullName } }
    }
    $infs = @($infs | Select-Object -Unique)
}

# stop Brother's interactive setup (only exes running from our download/extract folders) so it does
# not re-point the printer back to the IPP driver while we install from the INF ourselves
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -like "$dir\*" -or $_.Path -like "$env:TEMP\*") -and $_.Path -match '(?i)brother|setup|inst' } | Stop-Process -Force -ErrorAction SilentlyContinue

if ($infs.Count) {
    Write-Host "Found $($infs.Count) Brother printer INF(s); staging with pnputil..." -ForegroundColor Cyan
    foreach ($i in $infs) { Write-Host "  + $i"; & pnputil.exe /add-driver "$i" /install 2>&1 | Out-Null }
} else {
    Write-Host "Could not auto-locate the extracted INF. If a Brother installer window opened, finish it, then run install-v3.ps1." -ForegroundColor Yellow
}

# register the staged driver by its likely names, then switch the queue
$phys = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.DriverName -notmatch 'Print To PDF|OneNote|XPS|Fax|PDF ?Converter' -and $_.PortName -notmatch '^(PORTPROMPT:|nul:?$|PCONVERT:|SHRFAX:)' } | Select-Object -First 1
if ($phys) {
    foreach ($nm in @("$($phys.Name) Printer", "$($phys.Name)")) { try { Add-PrinterDriver -Name $nm -ErrorAction Stop; Write-Host "  registered driver: $nm" -ForegroundColor Green } catch {} }
    $v3 = Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Brother*' -and $_.MajorVersion -eq 3 -and $_.Name -notlike '*Fax*' } | Select-Object -First 1
    if ($v3) {
        Set-Printer -Name $phys.Name -DriverName $v3.Name -ErrorAction SilentlyContinue
        Restart-Service Spooler -Force -ErrorAction SilentlyContinue; Start-Sleep 2
        Write-Host "`nSUCCESS: '$($phys.Name)' now uses v3 driver '$((Get-Printer -Name $phys.Name).DriverName)'." -ForegroundColor Green
        Write-Host "Sign into the Otzar session and Ctrl+P the Brother - the page count should appear in ~2 seconds." -ForegroundColor Green
    } else {
        Write-Host "`nNo v3 Brother driver ended up in the store. Installed print drivers:" -ForegroundColor Yellow
        Get-PrinterDriver | Select-Object Name, MajorVersion | Format-Table -Auto
        Write-Host "If a Brother driver shows above as MajorVersion 4, this model's driver is v4 (same modern issue) - tell me and we switch to the session fix." -ForegroundColor Yellow
    }
}
