# serve-dashboard.ps1 - lightweight HTTP dashboard for pc-activity-capture.
# Serves dashboard/index.html on http://localhost:8765/
# API endpoint GET /api/status returns JSON: { heartbeat, watchdog, alerts }
# Run from the project root (where config.json lives).
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir  = Join-Path $root 'state'
$dashDir   = Join-Path $root 'dashboard'
$port      = 8765
$prefix    = "http://localhost:$port/"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
  Write-Host "[dashboard] ERROR: Cannot bind to port $port. Is another instance running?"
  exit 1
}

Write-Host "[dashboard] Serving at $prefix  (Ctrl+C to stop)"
Start-Process $prefix   # open browser

while ($listener.IsListening) {
  try {
    $ctx  = $listener.GetContext()
    $req  = $ctx.Request
    $resp = $ctx.Response

    if ($req.Url.AbsolutePath -eq '/api/status') {
      # Build status JSON
      $hb  = $null; $wd  = $null; $alerts = @()
      $hbFile = Join-Path $stateDir 'heartbeat.json'
      $wsFile = Join-Path $stateDir 'watchdog-state.json'
      $alogFile = Join-Path $stateDir 'alerts.log'
      if (Test-Path $hbFile)   { try { $hb = Get-Content $hbFile -Raw | ConvertFrom-Json } catch {} }
      if (Test-Path $wsFile)   { try { $wd = Get-Content $wsFile -Raw | ConvertFrom-Json } catch {} }
      if (Test-Path $alogFile) {
        try {
          # Use FileShare.ReadWrite so we can read even while watchdog has the file open
          $fs = [System.IO.File]::Open($alogFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
          $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
          $lines = $sr.ReadToEnd() -split "`n" | Where-Object { $_ -ne '' }
          $sr.Close(); $fs.Close()
          $alerts = @($lines | Select-Object -Last 20)
        } catch {}
      }
      $payload = [ordered]@{ heartbeat=$hb; watchdog=$wd; alerts=$alerts } | ConvertTo-Json -Depth 5 -Compress
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
      $resp.ContentType = 'application/json; charset=utf-8'
      # No CORS wildcard: localhost API should not be cross-origin-accessible from arbitrary sites
      $resp.ContentLength64 = $bytes.Length
      $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      # Serve static files from dashboard/
      $relPath = $req.Url.AbsolutePath.TrimStart('/')
      if ($relPath -eq '') { $relPath = 'index.html' }
      $filePath = Join-Path $dashDir $relPath
      # Guard against path traversal (../../config.json etc.)
      $resolved = [System.IO.Path]::GetFullPath($filePath)
      $base     = [System.IO.Path]::GetFullPath($dashDir) + [System.IO.Path]::DirectorySeparatorChar
      if (-not $resolved.StartsWith($base)) {
        $resp.StatusCode = 403
        $body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden')
        $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
        $resp.OutputStream.Close(); continue
      }
      if (Test-Path $filePath -PathType Leaf) {
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $mime = switch ([System.IO.Path]::GetExtension($filePath)) {
          '.html' { 'text/html; charset=utf-8' }
          '.css'  { 'text/css' }
          '.js'   { 'application/javascript' }
          '.json' { 'application/json' }
          default { 'application/octet-stream' }
        }
        $resp.ContentType = $mime
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        $resp.StatusCode = 404
        $body = [System.Text.Encoding]::UTF8.GetBytes('Not found')
        $resp.ContentLength64 = $body.Length
        $resp.OutputStream.Write($body, 0, $body.Length)
      }
    }
    $resp.OutputStream.Close()
  } catch { }
}
$listener.Stop()
