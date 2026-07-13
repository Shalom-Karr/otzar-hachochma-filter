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
