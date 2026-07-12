<#
.SYNOPSIS
  Self-update helper for the Otzar Hachochma kiosk scripts. Dot-sourced by create.ps1
  and setup.ps1.

.DESCRIPTION
  Checks GitHub for a newer VERSION than the local one. If found, downloads the latest
  branch zip, overwrites the local files in place, and re-runs the calling script (with
  -NoUpdate so it can't loop). Needs no git on the target machine. Safe offline: any
  network problem prints a warning and lets the caller continue on the current version.

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

    # local version (missing/older copies -> 0.0.0 so they update)
    $current = [version]'0.0.0'
    $localVersionFile = Join-Path $dir 'VERSION'
    if (Test-Path -LiteralPath $localVersionFile) {
        try { $current = [version]((Get-Content -LiteralPath $localVersionFile -Raw).Trim()) } catch {}
    }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # latest version on GitHub (cache-busted so we don't get a stale raw CDN copy)
    $rawUrl = "https://raw.githubusercontent.com/$OtzarRepoOwner/$OtzarRepoName/$OtzarRepoBranch/VERSION?nocache=$([guid]::NewGuid())"
    try {
        $remoteText = (Invoke-WebRequest -Uri $rawUrl -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' }).Content
        $remote = [version]($remoteText.Trim())
    } catch {
        Write-Host "Update check skipped (couldn't reach GitHub): $($_.Exception.Message)" -ForegroundColor DarkYellow
        return
    }

    if ($remote -le $current) {
        Write-Host "Otzar kiosk scripts are up to date (v$current)." -ForegroundColor DarkGray
        return
    }

    Write-Host "A newer version is on GitHub: v$remote (you have v$current). Updating..." -ForegroundColor Cyan

    $tmpDir = Join-Path $env:TEMP ("otzar-update-" + [guid]::NewGuid().ToString('N'))
    $tmpZip = "$tmpDir.zip"
    try {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        Invoke-WebRequest -Uri "https://github.com/$OtzarRepoOwner/$OtzarRepoName/archive/refs/heads/$OtzarRepoBranch.zip" `
            -OutFile $tmpZip -UseBasicParsing -TimeoutSec 60
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
        $inner = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1   # <repo>-<branch>\
        if (-not $inner) { throw "downloaded archive was empty" }
        Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $dir -Recurse -Force
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
