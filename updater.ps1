<#
.SYNOPSIS
  Self-update helper for the Otzar Hachochma kiosk scripts. Dot-sourced by create.ps1
  and setup.ps1.

.DESCRIPTION
  Checks the tiny /version endpoint on GitHub Pages against the local $KioskVersion in setup.ps1.
  If newer, it downloads the scripts straight from GitHub Pages (falling back to the github.com
  branch zip), overwrites the local files in place, and re-runs the calling script (with -NoUpdate
  so it can't loop). Needs no git on the target machine. Safe offline: any network problem prints a
  warning and lets the caller continue on the current version.

  Callers dot-source this file and call Invoke-OtzarSelfUpdate; if an update happens it
  re-runs the new script and exits, so the caller's old code never resumes.
#>

$script:OtzarRepoOwner  = 'Shalom-Karr'
$script:OtzarRepoName   = 'otzar-hachochma-filter'
$script:OtzarRepoBranch = 'main'

function Invoke-OtzarSelfUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,        # $PSCommandPath of the calling script
        [hashtable]$BoundParams = @{}                     # the caller's $PSBoundParameters, to preserve on re-run
    )

    $dir = Split-Path -Parent $ScriptPath

    # version lives in setup.ps1 as  $KioskVersion = 'x.y.z'  (single source of truth; no separate VERSION file)
    $verRegex = '\$KioskVersion\s*=\s*[''"]([0-9]+\.[0-9]+\.[0-9]+)[''"]'

    # local version: parse it out of the local setup.ps1 (missing/unparseable -> 0.0.0 so the copy updates)
    $current = [version]'0.0.0'
    $localSetup = Join-Path $dir 'setup.ps1'
    if (Test-Path -LiteralPath $localSetup) {
        try {
            $lm = [regex]::Match((Get-Content -LiteralPath $localSetup -Raw), $verRegex)
            if ($lm.Success) { $current = [version]$lm.Groups[1].Value }
        } catch {}
    }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    Write-Host "[updater] local version: v$current" -ForegroundColor DarkGray

    # latest version: read the tiny /version endpoint on GitHub Pages (a few bytes of plain text).
    # Falls back to parsing the remote setup.ps1 if Pages can't be reached (offline-safe either way).
    $pagesSite = "https://$($OtzarRepoOwner.ToLower()).github.io/$OtzarRepoName"
    $remote    = $null
    $verUrl    = "$pagesSite/version?nocache=$([guid]::NewGuid())"
    try {
        Write-Host "[updater] checking version endpoint: $verUrl" -ForegroundColor DarkGray
        $txt = (Invoke-WebRequest -Uri $verUrl -UseBasicParsing -TimeoutSec 20 -Headers @{ 'Cache-Control' = 'no-cache' }).Content
        $vm = [regex]::Match([string]$txt, '([0-9]+\.[0-9]+\.[0-9]+)')
        if ($vm.Success) { $remote = [version]$vm.Groups[1].Value; Write-Host "[updater] /version reports v$remote" -ForegroundColor DarkGray }
        else { Write-Host "[updater] /version had no version number; falling back to setup.ps1." -ForegroundColor DarkYellow }
    } catch {
        Write-Host "[updater] /version unreachable ($($_.Exception.Message)); falling back to setup.ps1." -ForegroundColor DarkYellow
    }

    if ($null -eq $remote) {
        # fallback: parse $KioskVersion out of the remote setup.ps1 (cache-busted vs a stale raw CDN copy)
        $rawUrl = "https://raw.githubusercontent.com/$OtzarRepoOwner/$OtzarRepoName/$OtzarRepoBranch/setup.ps1?nocache=$([guid]::NewGuid())"
        try {
            Write-Host "[updater] checking fallback: $rawUrl" -ForegroundColor DarkGray
            $remoteText = (Invoke-WebRequest -Uri $rawUrl -UseBasicParsing -TimeoutSec 20 -Headers @{ 'Cache-Control' = 'no-cache' }).Content
            $rm = [regex]::Match($remoteText, $verRegex)
            if (-not $rm.Success) { throw "could not find `$KioskVersion in remote setup.ps1" }
            $remote = [version]$rm.Groups[1].Value
            Write-Host "[updater] setup.ps1 reports v$remote" -ForegroundColor DarkGray
        } catch {
            Write-Host "Update check skipped (couldn't reach GitHub): $($_.Exception.Message)" -ForegroundColor DarkYellow
            return
        }
    }

    if ($remote -le $current) {
        Write-Host "Otzar kiosk scripts are up to date (v$current)." -ForegroundColor DarkGray
        return
    }

    Write-Host "A newer version is on GitHub: v$remote (you have v$current). Updating..." -ForegroundColor Cyan

    $tmpDir = Join-Path $env:TEMP ("otzar-update-" + [guid]::NewGuid().ToString('N'))
    $tmpZip = "$tmpDir.zip"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    # Preferred: pull each script straight from GitHub Pages (small files; works where the
    # github.com zip is blocked/slow). Download to a temp dir first, then copy in all-or-nothing.
    $files = @('setup.ps1','create.ps1','updater.ps1','uninstall.ps1','diagnostics.ps1','version')
    $viaPages = $true
    try {
        foreach ($f in $files) {
            Write-Host "[updater] downloading $f from Pages..." -ForegroundColor DarkGray
            Invoke-WebRequest -Uri "$pagesSite/$f?nocache=$([guid]::NewGuid())" `
                -OutFile (Join-Path $tmpDir $f) -UseBasicParsing -TimeoutSec 60 -Headers @{ 'Cache-Control' = 'no-cache' }
        }
    } catch {
        $viaPages = $false
        Write-Host "[updater] Pages download failed ($($_.Exception.Message)); falling back to the github.com zip." -ForegroundColor DarkYellow
    }

    try {
        if ($viaPages) {
            foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $tmpDir $f) -Destination (Join-Path $dir $f) -Force }
        } else {
            Invoke-WebRequest -Uri "https://github.com/$OtzarRepoOwner/$OtzarRepoName/archive/refs/heads/$OtzarRepoBranch.zip" `
                -OutFile $tmpZip -UseBasicParsing -TimeoutSec 60
            Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
            $inner = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1   # <repo>-<branch>\
            if (-not $inner) { throw "downloaded archive was empty" }
            Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $dir -Recurse -Force
        }
    } catch {
        Write-Host "Auto-update failed ($($_.Exception.Message)); continuing on the current version v$current." -ForegroundColor Yellow
        Remove-Item -LiteralPath $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Remove-Item -LiteralPath $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Updated to v$remote. Re-running the new version..." -ForegroundColor Green

    # re-run the freshly downloaded script in this same elevated session, preserving the
    # caller's args and forcing -NoUpdate so it can't update-loop.
    $relaunch = @{}
    foreach ($k in $BoundParams.Keys) { if ($k -ne 'NoUpdate') { $relaunch[$k] = $BoundParams[$k] } }
    $relaunch['NoUpdate'] = $true
    & $ScriptPath @relaunch
    exit $LASTEXITCODE
}
