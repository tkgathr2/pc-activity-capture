# auto-update.ps1 - pull latest code from GitHub and restart daemon if changed.
# Run on a schedule (e.g. every hour). Safe to run while daemon is recording:
# if no new commits, it exits in <1s; if updated, daemon restarts seamlessly.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $root 'state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$logFile = Join-Path $stateDir 'update.log'

function Write-Log([string]$msg) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
  try { Add-Content -Encoding UTF8 $logFile $line } catch {}
  Write-Host $line
}

# Rotate log: keep last 1000 lines
function Rotate-Log {
  try {
    $ls = [System.IO.File]::ReadAllLines($logFile, [System.Text.Encoding]::UTF8)
    if ($ls.Count -gt 1000) {
      [System.IO.File]::WriteAllLines($logFile, ($ls | Select-Object -Last 1000), [System.Text.UTF8Encoding]::new($false))
    }
  } catch {}
}

try {
  # Verify git is available
  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  if (-not $gitCmd) { Write-Log 'ERROR: git not found in PATH'; exit 1 }
  $gitExe = $gitCmd.Source

  $before = (& git -C $root rev-parse HEAD 2>&1) | Select-Object -First 1
  $pullOut = (& git -C $root pull 2>&1) -join ' | '
  $after  = (& git -C $root rev-parse HEAD 2>&1) | Select-Object -First 1

  if ($before -ne $after) {
    Write-Log "UPDATED $before -> $after  ($pullOut)"

    # Stop existing daemon gracefully so the new version takes over
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*run-capture-daemon*' })
    foreach ($p in $running) {
      try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($running.Count -gt 0) { Start-Sleep -Seconds 3 }

    # Restart daemon with updated code
    $daemonScript = Join-Path $root 'run-capture-daemon.ps1'
    Start-Process powershell -ArgumentList @(
      '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
      '-File', "`"$daemonScript`"") -ErrorAction SilentlyContinue
    Write-Log "Daemon restarted with new version"
  } else {
    Write-Log "No update (HEAD: $($after.Substring(0,[Math]::Min(7,$after.Length))))"
  }
} catch {
  Write-Log "ERROR: $($_.Exception.Message)"
}

Rotate-Log
