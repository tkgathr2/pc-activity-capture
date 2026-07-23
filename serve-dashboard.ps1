# serve-dashboard.ps1 - HTTP server for Revolution dashboard (multi-threaded via RunspacePool).
# Endpoints:
#   GET /api/status                    -> {heartbeat, watchdog, alerts}
#   GET /api/sessions                  -> ["2026-06-28", ...]
#   GET /api/session/{date}            -> {date, mp4s:[...], klogs:[...]}
#   GET /video/{date}/{file}           -> mp4 with Range Request support (RFC 7233)
#   GET /api/keylog/{date}/{file}      -> [{ts,vk,key,window}, ...]
#   GET /*                             -> static from dashboard/
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir    = Join-Path $root 'state'
$dashDir     = Join-Path $root 'dashboard'
$port        = 8765
$prefix      = "http://127.0.0.1:$port/"

$cfg         = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$captureRoot = [Environment]::ExpandEnvironmentVariables($cfg.captureRoot)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
  Write-Host "[dashboard] ERROR: Cannot bind to port $port. Is another instance running?"
  exit 1
}

Write-Host "[dashboard] Serving at $prefix  (multi-threaded, Ctrl+C to stop)"
Start-Process $prefix

# ---------------------------------------------------------------------------
# Per-request handler — runs inside a RunspacePool worker thread.
# All helpers are defined inline so the script block is self-contained.
# ---------------------------------------------------------------------------
$handlerScript = {
  param([System.Net.HttpListenerContext]$ctx, [string]$captureRoot, [string]$dashDir, [string]$stateDir)

  function Send-Json($resp, $obj, [int]$code = 200) {
    $json  = ConvertTo-Json -InputObject $obj -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $resp.StatusCode      = $code
    $resp.ContentType     = 'application/json; charset=utf-8'
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
  }

  function Send-Error($resp, [string]$msg, [int]$code = 500) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
    $resp.StatusCode      = $code
    $resp.ContentType     = 'text/plain'
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
  }

  function Stream-File($resp, [string]$filePath, [string]$mimeType, $rangeHeader) {
    if (-not (Test-Path $filePath -PathType Leaf)) {
      Send-Error $resp 'Not Found' 404; return
    }
    $fileLen = (Get-Item $filePath).Length
    if ($fileLen -eq 0) { Send-Error $resp 'Not Found' 404; return }  # empty file = not yet usable
    $resp.AddHeader('Accept-Ranges', 'bytes')
    $resp.ContentType = $mimeType

    $start = 0L; $end = $fileLen - 1L

    if ($rangeHeader -and $rangeHeader -match 'bytes=(\d+)-(\d*)') {
      $start = [long]$Matches[1]
      if ($Matches[2] -ne '') { $end = [long]$Matches[2] }
      if ($end -ge $fileLen) { $end = $fileLen - 1L }
      if ($start -lt 0L -or $start -gt $end) {
        $resp.StatusCode = 416
        $resp.AddHeader('Content-Range', "bytes */$fileLen")
        $resp.ContentLength64 = 0
        return
      }
      $resp.StatusCode = 206
      $resp.AddHeader('Content-Range', "bytes $start-$end/$fileLen")
    } else {
      $resp.StatusCode = 200
    }

    $length = $end - $start + 1L
    $resp.ContentLength64 = $length

    $fs = [System.IO.File]::Open($filePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
      $buf       = New-Object byte[] 65536
      $remaining = $length
      while ($remaining -gt 0) {
        $toRead = [math]::Min($buf.Length, $remaining)
        $n = $fs.Read($buf, 0, $toRead)
        if ($n -le 0) { break }
        $resp.OutputStream.Write($buf, 0, $n)
        $remaining -= $n
      }
    } finally { $fs.Close() }
  }

  # ---- route ----------------------------------------------------------------
  $resp = $null
  try {
    $req  = $ctx.Request
    $resp = $ctx.Response
    $path = $req.Url.AbsolutePath

    # /api/status
    if ($path -eq '/api/status') {
      $hb = $null; $wd = $null; $alerts = @()
      if (Test-Path (Join-Path $stateDir 'heartbeat.json'))      { try { $hb = Get-Content (Join-Path $stateDir 'heartbeat.json') -Raw | ConvertFrom-Json } catch {} }
      if (Test-Path (Join-Path $stateDir 'watchdog-state.json')) { try { $wd = Get-Content (Join-Path $stateDir 'watchdog-state.json') -Raw | ConvertFrom-Json } catch {} }
      $alog = Join-Path $stateDir 'alerts.log'
      if (Test-Path $alog) {
        try {
          $fs2 = [System.IO.File]::Open($alog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
          try {
            $sr2 = [System.IO.StreamReader]::new($fs2, [System.Text.Encoding]::UTF8)
            try { $alerts = @($sr2.ReadToEnd() -split "`n" | Where-Object { $_ -ne '' } | Select-Object -Last 20) }
            finally { $sr2.Close() }
          } finally { $fs2.Close() }
        } catch { $alerts = @("[read error]") }
      }
      Send-Json $resp @{ heartbeat=$hb; watchdog=$wd; alerts=$alerts }
    }

    # /api/sessions
    elseif ($path -eq '/api/sessions') {
      $dates = @()
      if (Test-Path $captureRoot) {
        $dates = @(Get-ChildItem $captureRoot -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
                   Sort-Object Name -Descending | ForEach-Object { $_.Name })
      }
      Send-Json $resp $dates
    }

    # /api/session/{date}
    elseif ($path -match '^/api/session/(\d{4}-\d{2}-\d{2})$') {
      $date    = $Matches[1]
      $dayDir2 = Join-Path $captureRoot $date
      if (-not (Test-Path $dayDir2)) { Send-Json $resp @{ error='date not found' } 404 }
      else {
        $mp4s  = @(Get-ChildItem $dayDir2 -Filter '*.mp4' -ErrorAction SilentlyContinue |
                   Sort-Object Name | ForEach-Object {
                     $epochMs = $null
                     if ($_.Name -match '_(\d{2})(\d{2})(\d{2})\.mp4$') {
                       try {
                         $localDt = [datetime]::Parse("$date`T$($Matches[1]):$($Matches[2]):$($Matches[3])", $null, [System.Globalization.DateTimeStyles]::AssumeLocal)
                         $epochMs = [long]($localDt.ToUniversalTime() - [datetime]::new(1970,1,1)).TotalMilliseconds
                       } catch {}
                     }
                     @{ name=$_.Name; sizeBytes=$_.Length; modified=$_.LastWriteTime.ToString('o'); epochMs=$epochMs }
                   })
        $klogs = @(Get-ChildItem $dayDir2 -Filter 'keylog_*.jsonl' -ErrorAction SilentlyContinue |
                   Sort-Object Name | ForEach-Object { @{ name=$_.Name; sizeBytes=$_.Length; modified=$_.LastWriteTime.ToString('o') } })
        Send-Json $resp @{ date=$date; mp4s=$mp4s; klogs=$klogs }
      }
    }

    # /video/{date}/{file}
    elseif ($path -match '^/video/(\d{4}-\d{2}-\d{2})/([^/]+\.mp4)$') {
      $date     = $Matches[1]
      $filename = $Matches[2]
      $filePath = Join-Path (Join-Path $captureRoot $date) $filename
      $resolved = [System.IO.Path]::GetFullPath($filePath)
      $rootFull = [System.IO.Path]::GetFullPath($captureRoot) + [System.IO.Path]::DirectorySeparatorChar
      if (-not $resolved.StartsWith($rootFull)) { Send-Error $resp 'Forbidden' 403 }
      else { Stream-File $resp $filePath 'video/mp4' $req.Headers["Range"] }
    }

    # /api/open-video/{date}/{file}  — opens file in system default player (WMP/VLC)
    elseif ($path -match '^/api/open-video/(\d{4}-\d{2}-\d{2})/([^/]+\.mp4)$') {
      $date     = $Matches[1]
      $filename = $Matches[2]
      $filePath = Join-Path (Join-Path $captureRoot $date) $filename
      $resolved = [System.IO.Path]::GetFullPath($filePath)
      $rootFull = [System.IO.Path]::GetFullPath($captureRoot) + [System.IO.Path]::DirectorySeparatorChar
      if (-not $resolved.StartsWith($rootFull)) { Send-Error $resp 'Forbidden' 403 }
      elseif (-not (Test-Path $resolved -PathType Leaf)) { Send-Error $resp 'Not found' 404 }
      else {
        try { Start-Process -FilePath $resolved } catch { }
        Send-Json $resp @{ opened=$true; path=$resolved }
      }
    }

    # /api/keylog/{date}/{file}
    elseif ($path -match '^/api/keylog/(\d{4}-\d{2}-\d{2})/([^/]+\.jsonl)$') {
      $date     = $Matches[1]
      $filename = $Matches[2]
      $filePath = Join-Path (Join-Path $captureRoot $date) $filename
      $rootFull = [System.IO.Path]::GetFullPath($captureRoot) + [System.IO.Path]::DirectorySeparatorChar
      $resolved = [System.IO.Path]::GetFullPath($filePath)
      if (-not $resolved.StartsWith($rootFull)) { Send-Error $resp 'Forbidden' 403 }
      elseif (-not (Test-Path $filePath)) { Send-Json $resp @() }
      else {
        try {
          $fs3 = [System.IO.File]::Open($filePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
          $lines = @()
          try {
            $sr3 = [System.IO.StreamReader]::new($fs3, [System.Text.Encoding]::UTF8)
            try {
              $lines = @($sr3.ReadToEnd() -split "`n" | Where-Object { $_ -ne '' } | ForEach-Object {
                try { $_ | ConvertFrom-Json } catch { $null }
              } | Where-Object { $_ -ne $null })
            } finally { $sr3.Close() }
          } finally { $fs3.Close() }
          Send-Json $resp $lines
        } catch { Send-Json $resp @() }
      }
    }

    # /api/reports  — list generated weekly reports
    elseif ($path -eq '/api/reports') {
      $rptDir  = Join-Path $stateDir 'reports'
      $reports = @()
      if (Test-Path $rptDir) {
        $reports = @(Get-ChildItem $rptDir -Filter '*.html' -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending | ForEach-Object {
            @{ file=$_.Name; generated=$_.LastWriteTime.ToString('o'); sizeBytes=$_.Length }
          })
      }
      Send-Json $resp $reports
    }

    # /reports/{file}  — serve a weekly report HTML or thumbnail JPG
    elseif ($path -match '^/reports/([a-zA-Z0-9_-]+\.(html|jpg|jpeg|png))$') {
      $filename = $Matches[1]
      $filePath = Join-Path (Join-Path $stateDir 'reports') $filename
      $rptFull  = [System.IO.Path]::GetFullPath($filePath)
      $rptBase  = [System.IO.Path]::GetFullPath((Join-Path $stateDir 'reports')) + [System.IO.Path]::DirectorySeparatorChar
      if (-not $rptFull.StartsWith($rptBase)) { Send-Error $resp 'Forbidden' 403 }
      elseif (-not (Test-Path $filePath -PathType Leaf)) { Send-Error $resp 'Not Found' 404 }
      else {
        $mime = switch ([System.IO.Path]::GetExtension($filename)) {
          '.html' { 'text/html; charset=utf-8' }
          '.jpg'  { 'image/jpeg' }
          '.jpeg' { 'image/jpeg' }
          '.png'  { 'image/png' }
          default { 'application/octet-stream' }
        }
        Stream-File $resp $filePath $mime $null
      }
    }

    # static dashboard/
    else {
      $relPath = $path.TrimStart('/')
      if ($relPath -eq '') { $relPath = 'index.html' }
      $filePath = Join-Path $dashDir $relPath
      $resolved = [System.IO.Path]::GetFullPath($filePath)
      $base     = [System.IO.Path]::GetFullPath($dashDir) + [System.IO.Path]::DirectorySeparatorChar
      if (-not $resolved.StartsWith($base)) { Send-Error $resp 'Forbidden' 403 }
      elseif (Test-Path $filePath -PathType Leaf) {
        $mime = switch ([System.IO.Path]::GetExtension($filePath)) {
          '.html' { 'text/html; charset=utf-8' }
          '.css'  { 'text/css' }
          '.js'   { 'application/javascript' }
          '.json' { 'application/json' }
          default { 'application/octet-stream' }
        }
        Stream-File $resp $filePath $mime $null
      } else { Send-Error $resp 'Not found' 404 }
    }

  } catch {
    try { Add-Content -Path (Join-Path $stateDir 'dashboard-errors.log') -Value "$((Get-Date).ToString('o'))  $($_.Exception.Message)" -Encoding UTF8 } catch {}
  }
  finally {
    if ($resp) { try { $resp.OutputStream.Close() } catch {} }
  }
}

# ---------------------------------------------------------------------------
# Accept-loop: dispatch each connection to a RunspacePool worker thread.
# Up to 20 concurrent requests; video streams don't block other requests.
# ---------------------------------------------------------------------------
$pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 20)
$pool.Open()

# Track in-flight PowerShell instances so we can EndInvoke+Dispose when done.
$pending = [System.Collections.Generic.List[hashtable]]::new()

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()   # blocks until next connection arrives
    $ps  = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($handlerScript).AddParameters(@{
      ctx         = $ctx
      captureRoot = $captureRoot
      dashDir     = $dashDir
      stateDir    = $stateDir
    })
    $ar = $ps.BeginInvoke()         # non-blocking: dispatch and loop immediately
    $pending.Add(@{ ps = $ps; ar = $ar })

    # Non-blocking GC: reap completed instances on every accept iteration
    $done = @($pending | Where-Object { $_.ar.IsCompleted })
    foreach ($item in $done) {
      try { $item.ps.EndInvoke($item.ar) } catch {}
      $item.ps.Dispose()
      [void]$pending.Remove($item)
    }
  } catch { Write-Host "[dashboard] accept-err: $_" }
}

# Drain remaining instances on clean shutdown
foreach ($item in $pending) {
  try { $item.ps.EndInvoke($item.ar) } catch {}
  $item.ps.Dispose()
}
$pool.Close()
$listener.Stop()
