param([string]$Root = "C:\Users\Otzar Hachochma\Documents")
try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Root)) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
}
$Root = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\')

$colBg    = [System.Drawing.Color]::FromArgb(15,23,42)
$colTile  = [System.Drawing.Color]::FromArgb(30,41,59)
$colHover = [System.Drawing.Color]::FromArgb(51,65,85)
$colWhite = [System.Drawing.Color]::White
$fontName = "Segoe UI"

$script:current = $Root

$form = New-Object System.Windows.Forms.Form
$form.Text = "PDF Files"
$form.BackColor = $colBg
$form.WindowState = "Maximized"
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(600, 400)

# --- top bar ---
$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"
$top.Height = 64
$top.BackColor = $colTile
$form.Controls.Add($top)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = "Up"
$btnUp.SetBounds(12, 12, 90, 40)
$btnUp.FlatStyle = "Flat"
$btnUp.FlatAppearance.BorderSize = 0
$btnUp.ForeColor = $colWhite
$btnUp.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
$btnUp.Font = New-Object System.Drawing.Font($fontName, 12)
$btnUp.Cursor = "Hand"
$top.Controls.Add($btnUp)

$lblPath = New-Object System.Windows.Forms.Label
$lblPath.ForeColor = $colWhite
$lblPath.Font = New-Object System.Drawing.Font($fontName, 12)
$lblPath.TextAlign = "MiddleLeft"
$lblPath.SetBounds(116, 12, 700, 40)
$lblPath.Anchor = "Top,Left,Right"
$top.Controls.Add($lblPath)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.FlatStyle = "Flat"
$btnClose.FlatAppearance.BorderSize = 0
$btnClose.ForeColor = $colWhite
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(30,41,59)
$btnClose.Font = New-Object System.Drawing.Font($fontName, 12)
$btnClose.Cursor = "Hand"
$btnClose.Anchor = "Top,Right"
$btnClose.SetBounds(($form.ClientSize.Width - 120), 12, 100, 40)
$top.Controls.Add($btnClose)
$btnClose.Add_Click({ $form.Close() })

# --- list area ---
$list = New-Object System.Windows.Forms.ListView
$list.Dock = "Fill"
$list.View = "Details"
$list.FullRowSelect = $true
$list.MultiSelect = $false
$list.HeaderStyle = "None"
$list.BackColor = $colBg
$list.ForeColor = $colWhite
$list.Font = New-Object System.Drawing.Font($fontName, 13)
$list.BorderStyle = "None"
$list.Columns.Add("Name", 900) | Out-Null
$form.Controls.Add($list)
$list.BringToFront()

function Update-Up {
  if ($script:current.TrimEnd('\') -ieq $Root) {
    $btnUp.Enabled = $false
  } else {
    $btnUp.Enabled = $true
  }
}

function Get-RelPath {
  $c = $script:current.TrimEnd('\')
  if ($c -ieq $Root) { return "\" }
  $rel = $c.Substring($Root.Length)
  if (-not $rel.StartsWith('\')) { $rel = "\" + $rel }
  return $rel
}

function Refresh-List {
  $list.BeginUpdate()
  $list.Items.Clear()
  $lblPath.Text = Get-RelPath
  Update-Up

  $dirs = @()
  try {
    $dirs = Get-ChildItem -LiteralPath $script:current -Directory -Force -ErrorAction Stop | Sort-Object Name
  } catch { $dirs = @() }
  foreach ($d in $dirs) {
    try {
      $it = New-Object System.Windows.Forms.ListViewItem("[ ] " + $d.Name)
      $it.Tag = @{ Type = "dir"; Path = $d.FullName }
      $list.Items.Add($it) | Out-Null
    } catch {}
  }

  $files = @()
  try {
    $files = Get-ChildItem -LiteralPath $script:current -File -Force -ErrorAction Stop | Where-Object { $_.Extension -ieq ".pdf" } | Sort-Object Name
  } catch { $files = @() }
  foreach ($f in $files) {
    $it = New-Object System.Windows.Forms.ListViewItem($f.Name)
    $it.Tag = @{ Type = "pdf"; Path = $f.FullName }
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
    try { Start-Process -FilePath $info.Path -ErrorAction SilentlyContinue } catch {}
  }
}

function Go-Up {
  $c = $script:current.TrimEnd('\')
  if ($c -ieq $Root) { return }
  $parent = Split-Path -LiteralPath $c -Parent
  if ([string]::IsNullOrEmpty($parent)) { return }
  if ($parent.Length -lt $Root.Length) { $parent = $Root }
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
$btnClose.Add_MouseEnter({ $this.BackColor = $colHover })
$btnClose.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(30,41,59) })

Refresh-List
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
} catch { $_ | Out-File "$env:TEMP\pdfbrowser-error.log" -Force }
