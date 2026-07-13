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

$colBg    = [System.Drawing.Color]::FromArgb(15,23,42)
$colTile  = [System.Drawing.Color]::FromArgb(30,41,59)
$colHover = [System.Drawing.Color]::FromArgb(51,65,85)
$colWhite = [System.Drawing.Color]::White
$colMuted = [System.Drawing.Color]::FromArgb(148,163,184)
$fontName = "Segoe UI"

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
$top.BackColor = $colTile
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

# --- list area (large touch-friendly rows via an ImageList height hack) ---
$imgs = New-Object System.Windows.Forms.ImageList
$imgs.ImageSize = New-Object System.Drawing.Size(1, 48)

$list = New-Object System.Windows.Forms.ListView
$list.Dock = "Fill"
$list.View = "Details"
$list.FullRowSelect = $true
$list.MultiSelect = $false
$list.HeaderStyle = "None"
$list.BackColor = $colBg
$list.ForeColor = $colWhite
$list.Font = New-Object System.Drawing.Font($fontName, 14)
$list.BorderStyle = "None"
$list.SmallImageList = $imgs
$list.Columns.Add("Name", 1000) | Out-Null
$form.Controls.Add($list)
$list.BringToFront()

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
  $list.BeginUpdate()
  $list.Items.Clear()
  $lblPath.Text = Get-DisplayPath
  Update-Up

  if ($null -eq $script:current) {
    # two-root home
    foreach ($r in $roots) {
      $it = New-Object System.Windows.Forms.ListViewItem("[Folder]  " + $r.Name)
      $it.Tag = @{ Type = "dir"; Path = $r.Path }
      $it.ForeColor = $colWhite
      $list.Items.Add($it) | Out-Null
    }
    $list.EndUpdate()
    return
  }

  $dirs = @()
  try {
    $dirs = Get-ChildItem -LiteralPath $script:current -Directory -Force -ErrorAction Stop | Sort-Object Name
  } catch { $dirs = @() }
  foreach ($d in $dirs) {
    try {
      $it = New-Object System.Windows.Forms.ListViewItem("[Folder]  " + $d.Name)
      $it.Tag = @{ Type = "dir"; Path = $d.FullName }
      $it.ForeColor = $colWhite
      $list.Items.Add($it) | Out-Null
    } catch {}
  }

  $files = @()
  try {
    $files = Get-ChildItem -LiteralPath $script:current -File -Force -ErrorAction Stop | Where-Object { $_.Extension -ieq ".pdf" } | Sort-Object Name
  } catch { $files = @() }
  foreach ($f in $files) {
    $it = New-Object System.Windows.Forms.ListViewItem("[PDF]     " + $f.Name)
    $it.Tag = @{ Type = "pdf"; Path = $f.FullName }
    $it.ForeColor = [System.Drawing.Color]::FromArgb(203,213,225)
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
$btnClose.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(220,80,80) })
$btnClose.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(190,60,60) })

Refresh-List
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
} catch { try { $_ | Out-File "C:\Users\Public\Documents\OtzarKiosk\pdfbrowser-error.log" -Force } catch {} }
