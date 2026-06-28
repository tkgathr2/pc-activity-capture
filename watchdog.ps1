# watchdog.ps1 - dead-man switch. Runs every few minutes (scheduled task).
# If capture's heartbeat is missing or stale (=not running), alert the 上長 (manager).
# Alerts only on state CHANGE (up->down / down->up) to avoid spam. ASCII-only.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $root 'state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$hbFile   = Join-Path $stateDir 'heartbeat.json'
$wsFile   = Join-Path $stateDir 'watchdog-state.json'
$alogFile = Join-Path $stateDir 'alerts.log'
$cfg      = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
# Guard against missing/zero staleSeconds (would make every heartbeat look stale)
$staleSec = if ($cfg.staleSeconds -and [int]$cfg.staleSeconds -gt 0) { [int]$cfg.staleSeconds } else { 300 }

# --- determine current health ---
$down = $true; $reason = 'heartbeat missing (capture never started?)'
if (Test-Path $hbFile) {
  try {
    $hb = Get-Content $hbFile -Raw | ConvertFrom-Json
    $age = ((Get-Date) - [datetime]$hb.ts).TotalSeconds
    if ($age -le $staleSec -and $hb.status -ne 'error') { $down = $false }
    elseif ($hb.status -eq 'error') {
      $reason = "capture reported error (age=$([int]$age)s): $($hb.detail)"
    } else {
      $reason = "heartbeat stale $([int]$age)s (status=$($hb.status))"
    }
  } catch { $reason = 'heartbeat unreadable' }
}
$state = if ($down) { 'DOWN' } else { 'UP' }

# --- load previous state ---
$prev = 'UNKNOWN'
if (Test-Path $wsFile) { try { $prev = (Get-Content $wsFile -Raw | ConvertFrom-Json).state } catch {} }

function Send-Alert([string]$msg) {
  $line = "$((Get-Date).ToString('o'))  $msg"
  Add-Content -Encoding UTF8 $alogFile $line
  $method = "$($cfg.notify.method)".ToLower()
  if ($method -eq 'slack' -and $cfg.notify.slackWebhook) {
    try {
      $body = @{ text = $msg } | ConvertTo-Json
      Invoke-RestMethod -Method Post -Uri $cfg.notify.slackWebhook -ContentType 'application/json' -Body $body | Out-Null
    } catch { Add-Content -Encoding UTF8 $alogFile "$((Get-Date).ToString('o'))  [send-fail] $($_.Exception.GetType().Name): slack webhook request failed" }
  }
}

# --- alert on transition OR on first-ever run if already DOWN ---
$shouldAlert = ($state -ne $prev -and $prev -ne 'UNKNOWN') -or ($state -eq 'DOWN' -and $prev -eq 'UNKNOWN')
if ($shouldAlert) {
  if ($state -eq 'DOWN') {
    Send-Alert ("[ALERT] PC activity capture is NOT running on {0}/{1}. {2}  -> notify 上長: {3}" -f `
      $env:COMPUTERNAME, $env:USERNAME, $reason, $cfg.notify.johcho)
  } else {
    Send-Alert ("[RECOVERED] PC activity capture is running again on {0}/{1}." -f $env:COMPUTERNAME, $env:USERNAME)
  }
}

([ordered]@{ state=$state; reason=$reason; checked=(Get-Date).ToString('o') } |
  ConvertTo-Json -Compress) | Set-Content -Encoding UTF8 $wsFile
Write-Host "[watchdog] $state  $reason"
