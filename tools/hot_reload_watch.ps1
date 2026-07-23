param(
  [Parameter(Mandatory = $true)][string]$VmWs,
  [Parameter(Mandatory = $true)][string]$WatchDir
)

$ErrorActionPreference = "Continue"
Write-Host "[watch] watching $WatchDir"
Write-Host "[watch] vm $VmWs"

function Invoke-HotReload {
  param([string]$WsUrl)
  $ws = $null
  try {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    $ws.ConnectAsync([Uri]$WsUrl, $ct).Wait(5000) | Out-Null
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
      Write-Host "[watch] WS not open ($($ws.State))"
      return
    }

    function Send-Rpc([hashtable]$obj) {
      $json = ($obj | ConvertTo-Json -Compress -Depth 10)
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
      $segment = [System.ArraySegment[byte]]::new($bytes)
      $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
    }

    function Recv-Rpc {
      $buffer = New-Object byte[] 131072
      $segment = [System.ArraySegment[byte]]::new($buffer)
      $ms = New-Object System.IO.MemoryStream
      do {
        $result = $ws.ReceiveAsync($segment, $ct).Result
        $ms.Write($buffer, 0, $result.Count)
      } while (-not $result.EndOfMessage)
      return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    }

    Send-Rpc @{ jsonrpc = "2.0"; id = 1; method = "getVM" }
    $vm = (Recv-Rpc) | ConvertFrom-Json
    $isolateId = $null
    foreach ($iso in $vm.result.isolates) {
      if ("$($iso.name)" -match "main") {
        $isolateId = $iso.id
        break
      }
    }
    if (-not $isolateId -and $vm.result.isolates.Count -gt 0) {
      $isolateId = $vm.result.isolates[0].id
    }
    if (-not $isolateId) {
      Write-Host "[watch] no isolate"
      return
    }

    Send-Rpc @{
      jsonrpc = "2.0"
      id = 2
      method = "reloadSources"
      params = @{ isolateId = "$isolateId"; force = $false; pause = $false }
    }
    $reloadRaw = Recv-Rpc
    $reload = $reloadRaw | ConvertFrom-Json
    if ($null -ne $reload.error) {
      Write-Host "[watch] reload error: $reloadRaw"
    } else {
      Write-Host "[watch] hot reload OK $(Get-Date -Format HH:mm:ss)"
    }
  } catch {
    Write-Host "[watch] failed: $_"
  } finally {
    if ($null -ne $ws) { $ws.Dispose() }
  }
}

$stamp = @{}
Get-ChildItem -Path $WatchDir -Filter *.dart -Recurse -File | ForEach-Object {
  $stamp[$_.FullName] = $_.LastWriteTimeUtc.Ticks
}

while ($true) {
  Start-Sleep -Milliseconds 700
  $changed = $false
  Get-ChildItem -Path $WatchDir -Filter *.dart -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $ticks = $_.LastWriteTimeUtc.Ticks
    $prev = $stamp[$_.FullName]
    if ($null -eq $prev -or $prev -ne $ticks) {
      $stamp[$_.FullName] = $ticks
      $changed = $true
    }
  }
  if ($changed) {
    Start-Sleep -Milliseconds 250
    Invoke-HotReload -WsUrl $VmWs
  }
}
