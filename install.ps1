# install.ps1 - one-shot setup for any PC.
# Run once in PowerShell (as the target user):
#   irm https://raw.githubusercontent.com/tkgathr2/pc-activity-capture/master/install.ps1 | iex
# or:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# What this does:
#   1. Checks prerequisites (git, ffmpeg)
#   2. Clones (or updates) the repo to %USERPROFILE%\pc-activity-capture
#   3. Sets HKCU Run autostart for the capture daemon
#   4. Registers scheduled tasks: watchdog (every 5 min) + auto-update (every hour)
#   5. Starts the daemon immediately
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$repoUrl  = 'https://github.com/tkgathr2/pc-activity-capture.git'
$installDir = Join-Path $env:USERPROFILE 'pc-activity-capture'

function Log([string]$msg) { Write-Host "[install] $msg" }
function Fail([string]$msg) { Write-Error "[install] FAILED: $msg"; exit 1 }

Log "=== PC Activity Capture - Installer ==="
Log "Install path: $installDir"

# --- Prerequisite: git ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail "git not found. Install Git for Windows first: https://git-scm.com/download/win"
}

# --- Prerequisite: ffmpeg (find or warn) ---
$ffCheck = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffCheck) {
  $wingetCheck = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*FFmpeg*" -ErrorAction SilentlyContinue
  if (-not $wingetCheck) {
    Log "WARNING: ffmpeg not found. Install with: winget install Gyan.FFmpeg"
    Log "         Continuing install - daemon will report error on first start until ffmpeg is installed."
  }
}

# --- Clone or update repo ---
if (Test-Path (Join-Path $installDir '.git')) {
  Log "Repo already exists - pulling latest..."
  & git -C $installDir pull
  Log "Updated."
} else {
  Log "Cloning repo..."
  & git clone $repoUrl $installDir
  Log "Cloned."
}

$daemonScript = Join-Path $installDir 'run-capture-daemon.ps1'
$watchdogScript = Join-Path $installDir 'watchdog.ps1'
$updateScript = Join-Path $installDir 'auto-update.ps1'
$ps = '"C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe"'

# --- HKCU Run: capture daemon on logon ---
$runArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$daemonScript`""
Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
  -Name 'PCActivityCapture' -Value "$ps $runArgs"
Log "Autostart registered (HKCU Run)"

# --- Scheduled task: watchdog every 5 minutes ---
$watchdogAction  = New-ScheduledTaskAction -Execute $ps `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogScript`""
$watchdogTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable
Register-ScheduledTask -TaskName 'PCActivityCaptureWatchdog' -Action $watchdogAction `
  -Trigger $watchdogTrigger -Settings $settings -RunLevel Limited -Force | Out-Null
Log "Scheduled task registered: PCActivityCaptureWatchdog (every 5 min)"

# --- Scheduled task: auto-update every hour ---
$updateAction  = New-ScheduledTaskAction -Execute $ps `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$updateScript`""
$updateTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 1) -Once -At (Get-Date)
Register-ScheduledTask -TaskName 'PCActivityCaptureAutoUpdate' -Action $updateAction `
  -Trigger $updateTrigger -Settings $settings -RunLevel Limited -Force | Out-Null
Log "Scheduled task registered: PCActivityCaptureAutoUpdate (every hour)"

# --- Start daemon now ---
$existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*run-capture-daemon*' })
if ($existing.Count -eq 0) {
  Start-Process powershell -ArgumentList @(
    '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$daemonScript`"") -ErrorAction SilentlyContinue
  Log "Daemon started."
} else {
  Log "Daemon already running (PID $($existing[0].ProcessId)) - skipping start."
}

Log ""
Log "=== Install complete! ==="
Log "  Capture data: $env:USERPROFILE\pc-capture-data\"
Log "  Dashboard:    run serve-dashboard.ps1 to view recordings"
Log "  Watchdog:     runs every 5 min, auto-restarts daemon if down"
Log "  Auto-update:  runs every hour, pulls latest code automatically"
Log ""
Log "To check status: Get-Content `"$installDir\state\heartbeat.json`""
