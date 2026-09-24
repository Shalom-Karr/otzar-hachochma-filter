# ipp-attrs.ps1 - send a real IPP Get-Printer-Attributes to the Brother's IPP-over-USB bridge
# (HttpToUsbBridge on 127.0.0.1:50000) to confirm the print path + which document formats it accepts.
# Run on the kiosk. No admin needed. Copy the output back.
$ErrorActionPreference = 'Continue'
$hostport = '127.0.0.1:50000'
$paths = @('/ipp/print','/ipp/printer','/ipp','/')

function New-IppGetAttrs($uri) {
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([byte]0x02); $bw.Write([byte]0x00)                 # IPP version 2.0
  $bw.Write([byte]0x00); $bw.Write([byte]0x0B)                 # operation-id: Get-Printer-Attributes
  $bw.Write([byte]0x00); $bw.Write([byte]0x00); $bw.Write([byte]0x00); $bw.Write([byte]0x01)  # request-id 1
  $bw.Write([byte]0x01)                                        # operation-attributes-tag
  function WA($bw,$tag,$name,$val){
    $nb=[Text.Encoding]::ASCII.GetBytes($name); $vb=[Text.Encoding]::ASCII.GetBytes($val)
    $bw.Write([byte]$tag)
    $bw.Write([byte](($nb.Length -shr 8) -band 0xFF)); $bw.Write([byte]($nb.Length -band 0xFF)); $bw.Write($nb)
    $bw.Write([byte](($vb.Length -shr 8) -band 0xFF)); $bw.Write([byte]($vb.Length -band 0xFF)); $bw.Write($vb)
  }
  WA $bw 0x47 'attributes-charset' 'utf-8'
  WA $bw 0x48 'attributes-natural-language' 'en'
  WA $bw 0x45 'printer-uri' $uri
  $bw.Write([byte]0x03)                                        # end-of-attributes-tag
  $bw.Flush(); return $ms.ToArray()
}

foreach($path in $paths){
  $url = "http://$hostport$path"
  $uri = "ipp://$hostport$path"
  Write-Host "`n===== POST IPP Get-Printer-Attributes -> $url =====" -ForegroundColor Cyan
  try {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method='POST'; $req.ContentType='application/ipp'; $req.Timeout=8000; $req.ReadWriteTimeout=8000
    $body = New-IppGetAttrs $uri
    $req.ContentLength = $body.Length
    $rs = $req.GetRequestStream(); $rs.Write($body,0,$body.Length); $rs.Close()
    $resp = $req.GetResponse()
    $ms = New-Object System.IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms)
    $bytes = $ms.ToArray()
    $status = if($bytes.Length -ge 4){ '0x{0:X2}{1:X2}' -f $bytes[2],$bytes[3] } else { '?' }
    $ok = ($status -eq '0x0000')
    Write-Host ("  HTTP {0}  IPP status-code {1} {2}" -f [int]$resp.StatusCode, $status, $(if($ok){'(successful-ok)'}else{''})) -ForegroundColor $(if($ok){'Green'}else{'Yellow'})
    $text = [Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes)
    $fmts = [regex]::Matches($text,'(application|image|text)/[A-Za-z0-9.+-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique
    if($fmts){ Write-Host "  document-formats seen: $($fmts -join ', ')" -ForegroundColor Green }
    $ms2 = [regex]::Match($text,'printer-make-and-model.{0,4}([ -~]{3,40})'); if($ms2.Success){ Write-Host "  model: $($ms2.Groups[1].Value)" }
    $st = [regex]::Match($text,'printer-state-reasons.{0,4}([ -~]{3,40})'); if($st.Success){ Write-Host "  state-reasons: $($st.Groups[1].Value)" }
    if($ok){ Write-Host "  >>> USE THIS PATH: $path" -ForegroundColor Magenta }
  } catch {
    $r=$_.Exception.Response; $code = if($r){[int]$r.StatusCode}else{'-'}
    Write-Host "  failed: HTTP $code  $($_.Exception.Message)" -ForegroundColor DarkGray
  }
}
Write-Host "`n===== done - the path marked USE THIS PATH + the document-formats line are what I need =====" -ForegroundColor Yellow
