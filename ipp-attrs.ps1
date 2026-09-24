# ipp-attrs.ps1 - IPP Get-Printer-Attributes to the Brother IPP-over-USB bridge (127.0.0.1:50000),
# sent over a RAW TCP socket so we control the exact HTTP request (no Expect: 100-continue, which the
# bridge rejects with 400). Confirms the print path + accepted document formats. Run on the kiosk.
$ErrorActionPreference = 'Continue'
$phost='127.0.0.1'; $pport=50000
$paths=@('/ipp/print','/ipp/printer','/ipp','/')

function New-IppGetAttrs($uri){
  $ms=New-Object System.IO.MemoryStream; $bw=New-Object System.IO.BinaryWriter($ms)
  $bw.Write([byte]0x02); $bw.Write([byte]0x00)                                   # version 2.0
  $bw.Write([byte]0x00); $bw.Write([byte]0x0B)                                   # Get-Printer-Attributes
  $bw.Write([byte]0x00); $bw.Write([byte]0x00); $bw.Write([byte]0x00); $bw.Write([byte]0x01)  # request-id
  $bw.Write([byte]0x01)                                                          # operation-attributes-tag
  function WA($bw,$tag,$name,$val){
    $nb=[Text.Encoding]::ASCII.GetBytes($name); $vb=[Text.Encoding]::ASCII.GetBytes($val)
    $bw.Write([byte]$tag)
    $bw.Write([byte](($nb.Length -shr 8) -band 0xFF)); $bw.Write([byte]($nb.Length -band 0xFF)); $bw.Write($nb)
    $bw.Write([byte](($vb.Length -shr 8) -band 0xFF)); $bw.Write([byte]($vb.Length -band 0xFF)); $bw.Write($vb)
  }
  WA $bw 0x47 'attributes-charset' 'utf-8'
  WA $bw 0x48 'attributes-natural-language' 'en'
  WA $bw 0x45 'printer-uri' $uri
  $bw.Write([byte]0x03); $bw.Flush(); return $ms.ToArray()
}

function Send-Ipp($path){
  $body=New-IppGetAttrs "ipp://$phost`:$pport$path"
  $client=New-Object System.Net.Sockets.TcpClient
  try { $client.Connect($phost,$pport) } catch { return @{ err="connect: $($_.Exception.Message)" } }
  $s=$client.GetStream(); $s.ReadTimeout=8000; $s.WriteTimeout=8000
  $hdr="POST $path HTTP/1.1`r`nHost: $phost`:$pport`r`nContent-Type: application/ipp`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
  $hb=[Text.Encoding]::ASCII.GetBytes($hdr)
  $s.Write($hb,0,$hb.Length); $s.Write($body,0,$body.Length); $s.Flush()
  $ms=New-Object System.IO.MemoryStream; $buf=New-Object byte[] 8192
  try { while(($n=$s.Read($buf,0,$buf.Length)) -gt 0){ $ms.Write($buf,0,$n) } } catch {}
  $client.Close()
  return @{ bytes=$ms.ToArray() }
}

foreach($path in $paths){
  Write-Host "`n===== POST ipp://$phost`:$pport$path =====" -ForegroundColor Cyan
  $r=Send-Ipp $path
  if($r.err){ Write-Host "  $($r.err)" -ForegroundColor DarkGray; continue }
  $bytes=$r.bytes
  $text=[Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes)
  $statusLine=($text -split "`r`n")[0]
  Write-Host "  HTTP: $statusLine"
  $bi=$text.IndexOf("`r`n`r`n")
  if($bi -ge 0 -and $bytes.Length -ge $bi+8){
    $b=$bi+4
    $ippStatus='0x{0:X2}{1:X2}' -f $bytes[$b+2],$bytes[$b+3]
    $ok=($ippStatus -eq '0x0000')
    Write-Host ("  IPP status-code: {0} {1}" -f $ippStatus,$(if($ok){'(successful-ok)'}else{''})) -ForegroundColor $(if($ok){'Green'}else{'Yellow'})
  }
  $fmts=[regex]::Matches($text,'(application|image|text)/[A-Za-z0-9.+-]+')|ForEach-Object{$_.Value}|Sort-Object -Unique
  if($fmts){ Write-Host "  document-formats: $($fmts -join ', ')" -ForegroundColor Green }
  $mm=[regex]::Match($text,'MFC-[A-Za-z0-9]+'); if($mm.Success){ Write-Host "  model token: $($mm.Value)" }
  if($statusLine -match '200'){ Write-Host "  >>> USE THIS PATH: $path" -ForegroundColor Magenta }
}
Write-Host "`n===== done =====" -ForegroundColor Yellow
