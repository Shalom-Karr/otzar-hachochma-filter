param([string]$ProfileDir = "C:\Users\Otzar Hachochma")
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
$lblTitle.Font = New-Object System.Drawing.Font($fontName + " Semibold", 20)
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
$btnClose.Font = New-Object System.Drawing.Font($fontName + " Semibold", 14)
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
  $card.Font = New-Object System.Drawing.Font($fontName + " Semibold", 12)
  if ($kind -eq "dir") { $tag = "FOLDER"; $accent = $colFolder } else { $tag = "PDF"; $accent = $colPdf }
  $card.Text = $name
  $card.Tag = @{ Type = $kind; Path = $path }

  # accent label at the top of the card (FOLDER / PDF)
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = $tag
  $lbl.ForeColor = $accent
  $lbl.BackColor = [System.Drawing.Color]::Transparent
  $lbl.Font = New-Object System.Drawing.Font($fontName + " Semibold", 10)
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
