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

    # log to the same public setup.log the admin reads, plus the console
    $LogFile = "C:\Users\Public\Documents\OtzarKiosk\setup.log"
    function Ulog($m) {
        Write-Host "[updater] $m" -ForegroundColor DarkGray
        try {
            $ld = Split-Path $LogFile -Parent
            if (-not (Test-Path $ld)) { New-Item -ItemType Directory -Path $ld -Force | Out-Null }
            Add-Content -LiteralPath $LogFile -Value ("{0}  [updater] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
        } catch {}
    }
    $checkBudget = 45   # seconds: give up the update CHECK after this and install the current copy AS-IS
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Ulog "installed version: v$current"

    # latest version: query SEVERAL sources and take the HIGHEST version any of them reports.
    # Why not just one: the raw setup.ps1 is CDN-cached for minutes and lags behind, while the tiny
    # raw /version FILE and Pages /version propagate fast. Reading only the stale source made the
    # updater wrongly conclude "up to date". Taking the max means a stale source can never mask a
    # fresh one. The whole CHECK is capped at ${checkBudget}s; if none answer we install as-is.
    $pagesSite = "https://$($OtzarRepoOwner.ToLower()).github.io/$OtzarRepoName"
    $rawBase   = "https://raw.githubusercontent.com/$OtzarRepoOwner/$OtzarRepoName/$OtzarRepoBranch"
    $verRx     = '([0-9]+\.[0-9]+\.[0-9]+)'
    $sources = @(
        @{ name = 'raw /version';   url = "$rawBase/version";   rx = $verRx },      # tiny + fast-propagating (most reliable)
        @{ name = 'Pages /version'; url = "$pagesSite/version"; rx = $verRx },
        @{ name = 'raw setup.ps1';  url = "$rawBase/setup.ps1"; rx = $verRegex }     # last resort (slow-cached)
    )
    $remote = $null
    foreach ($s in $sources) {
        if ($sw.Elapsed.TotalSeconds -ge $checkBudget) { break }
        $t = [int][math]::Max(5, $checkBudget - $sw.Elapsed.TotalSeconds)
        try {
            Ulog "checking $($s.name) (timeout ${t}s)"
            $txt = (Invoke-WebRequest -Uri ("$($s.url)?nocache=$([guid]::NewGuid())") -UseBasicParsing -TimeoutSec $t -Headers @{ 'Cache-Control' = 'no-cache' }).Content
            $m = [regex]::Match([string]$txt, $s.rx)
            if ($m.Success) {
                $v = [version]$m.Groups[1].Value
                Ulog "  $($s.name) -> v$v"
                if (($null -eq $remote) -or ($v -gt $remote)) { $remote = $v }
            }
        } catch { Ulog "  $($s.name) check failed: $($_.Exception.Message)" }
    }

    if ($null -eq $remote) {
        Ulog "could not determine the online version within ${checkBudget}s (elapsed $([int]$sw.Elapsed.TotalSeconds)s) - installing the current copy v$current AS-IS."
        return
    }

    Ulog "online (available) version: v$remote"

    if ($remote -le $current) {
        Ulog "up to date (installed v$current, online v$remote) - no update needed."
        return
    }

    Ulog "newer version available: v$remote (installed v$current) - updating..."

    $tmpDir = Join-Path $env:TEMP ("otzar-update-" + [guid]::NewGuid().ToString('N'))
    $tmpZip = "$tmpDir.zip"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $files = @('setup.ps1','create.ps1','updater.ps1','uninstall.ps1','diagnostics.ps1','dx.ps1','version')
    # Primary: the github.com branch ZIP - always current the moment a version is pushed (no Pages
    # rebuild lag, so no wasted 404s). Fallback: pull each script from GitHub Pages, for networks
    # where github.com itself is blocked by a content filter but Pages is reachable.
    $done = $false
    try {
        Ulog "downloading the github.com zip..."
        Invoke-WebRequest -Uri "https://github.com/$OtzarRepoOwner/$OtzarRepoName/archive/refs/heads/$OtzarRepoBranch.zip" `
            -OutFile $tmpZip -UseBasicParsing -TimeoutSec 60
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
        $inner = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1   # <repo>-<branch>\
        if (-not $inner) { throw "downloaded archive was empty" }
        Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $dir -Recurse -Force
        $done = $true
    } catch { Ulog "github.com zip failed ($($_.Exception.Message)); falling back to per-file from Pages." }

    if (-not $done) {
        try {
            foreach ($f in $files) {
                Invoke-WebRequest -Uri "$pagesSite/$f?nocache=$([guid]::NewGuid())" `
                    -OutFile (Join-Path $tmpDir $f) -UseBasicParsing -TimeoutSec 60 -Headers @{ 'Cache-Control' = 'no-cache' }
            }
            foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $tmpDir $f) -Destination (Join-Path $dir $f) -Force }
            $done = $true
        } catch { Ulog "Pages per-file download also failed ($($_.Exception.Message))." }
    }

    if (-not $done) {
        Ulog "auto-update failed (both github.com zip and Pages); continuing on the current version v$current."
        Remove-Item -LiteralPath $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Remove-Item -LiteralPath $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    Ulog "updated to v$remote. Re-running the new version..."

    # re-run the freshly downloaded script in this same elevated session, preserving the
    # caller's args and forcing -NoUpdate so it can't update-loop.
    $relaunch = @{}
    foreach ($k in $BoundParams.Keys) { if ($k -ne 'NoUpdate') { $relaunch[$k] = $BoundParams[$k] } }
    $relaunch['NoUpdate'] = $true
    & $ScriptPath @relaunch
    exit $LASTEXITCODE
}
