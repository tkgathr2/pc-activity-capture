# run-capture-daemon.ps1 - continuous capture for "auto-start on logon" mode.
# Uses ONE long-lived ffmpeg with the segment muxer so consecutive mp4 files are
# GAPLESS (the encoder never stops between files). Writes a fresh heartbeat every
# 30s so the watchdog can tell capture is alive. Never hard-crashes.
# ASCII-only on purpose (data values are written as UTF-8 no BOM).
param(
  [int]$SegmentSec = 1800,   # one mp4 per 30 min (MVP spec v1.0)
  [int]$Fps        = 10
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir  = Join-Path $root 'state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$hbFile    = Join-Path $stateDir 'heartbeat.json'
$cfg       = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$outRoot   = [Environment]::ExpandEnvironmentVariables($cfg.captureRoot)
$minFreeGB = if ($cfg.minFreeGB) { [double]$cfg.minFreeGB } else { 10 }

# Guard: if captureRoot has unresolved env var placeholder, fail fast
if ($outRoot -match '%\w+%') {
  Write-Error "config.json captureRoot has unresolved env var: $outRoot"; exit 1
}

# Resolve ffmpeg/ffprobe to an ABSOLUTE path. A -NoProfile / HKCU Run / scheduled
# task process does NOT inherit machine PATH (chocolatey\bin, WinGet Links), so a
# bare 'ffmpeg' name fails silently on logon-start. Search the real install dirs.
function Resolve-Tool([string]$name, $cfgVal) {
  if ($cfgVal -and (Test-Path $cfgVal)) { return $cfgVal }
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $cands = @(
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\$name.exe",
    "C:\ProgramData\chocolatey\bin\$name.exe",
    "$env:ProgramFiles\ffmpeg\bin\$name.exe",
    "${env:ProgramFiles(x86)}\ffmpeg\bin\$name.exe"
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  # WinGet installs ffmpeg under a versioned Packages path. Use bounded wildcard
  # globs (NOT -Recurse, which is slow and can hang on large lib trees).
  $globs = @(
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*FFmpeg*\*\bin\$name.exe",
    "C:\ProgramData\chocolatey\lib\ffmpeg*\tools\*\bin\$name.exe"
  )
  foreach ($g in $globs) {
    $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $name
}
$ff = Resolve-Tool 'ffmpeg'  $cfg.ffmpegPath
$fp = Resolve-Tool 'ffprobe' $cfg.ffprobePath

# MicDevice: resolved from config.micDevice (set per-PC) or falls back to this PC's hardware ID.
# On a new PC, run: & ffmpeg -list_devices true -f dshow -i dummy 2>&1 | Select-String audio
# then set config.micDevice to the device name shown (without the 'audio=' prefix).
$MicDeviceName = if ($cfg.micDevice) { $cfg.micDevice } else {
  '@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{3B4BEB3B-66AA-4FB2-BD31-F6ABCFD8AF2B}'
}
$MicDevice = "audio=$MicDeviceName"

function Write-Heartbeat([string]$status, $pid2, [string]$detail) {
  # Omit ffmpeg path and OS username: exposed unauthenticated via dashboard /api/status
  $hb = [ordered]@{ ts=(Get-Date).ToString('o'); status=$status; pid=$pid2; detail=$detail }
  [System.IO.File]::WriteAllText($hbFile, ($hb | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
}

# D6 disk resilience: keep free space above the threshold by deleting the oldest
# tool-owned files. Name pattern check prevents accidental deletion of other files.
function Get-FreeGB([string]$p) {
  try {
    $r = [System.IO.Path]::GetPathRoot($p)
    $di = New-Object System.IO.DriveInfo($r)
    return [math]::Round($di.AvailableFreeSpace / 1GB, 2)
  } catch { return 9999 }
}
function Ensure-DiskSpace([string]$rootDir, [double]$minGB) {
  $guard = 0; $lastRemoved = $null
  # Pattern guards: only delete files this tool created (named by strftime or keylog_HHmmss)
  $ownedPattern = '^(\d{4}-\d{2}-\d{2}_\d{6}\.mp4|keylog_\d{6}\.jsonl)$'
  while ((Get-FreeGB $rootDir) -lt $minGB -and $guard -lt 1000) {
    $oldest = Get-ChildItem $rootDir -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match $ownedPattern } |
              Sort-Object LastWriteTime | Select-Object -First 1
    if (-not $oldest) { break }
    if ($oldest.FullName -eq $lastRemoved) { break }  # delete failed last time, stop
    $lastRemoved = $oldest.FullName
    Remove-Item $oldest.FullName -Force -ErrorAction SilentlyContinue
    $guard++
  }
  return (Get-FreeGB $rootDir)
}

function Start-KeyLog([string]$outDir) {
  $klog      = Join-Path $outDir ("keylog_{0}.jsonl" -f (Get-Date).ToString('HHmmss'))
  $klogPath  = Join-Path $root 'keylog.ps1'
  $keyProc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$klogPath`"",
    '-DurationSec','86400','-OutFile',"`"$klog`"")
  return @{ proc=$keyProc; path=$klog }
}

function Start-Capture {
  $start = Get-Date
  $day = $start.ToString('yyyy-MM-dd')
  $dayDir = Join-Path $outRoot $day
  New-Item -ItemType Directory -Force $dayDir | Out-Null

  # one continuous keylog for this capture run (timestamps aligned to wall clock)
  $kl = Start-KeyLog $dayDir

  # GAPLESS recording: single ffmpeg, segment muxer. -force_key_frames puts a
  # keyframe exactly at each boundary so segments are exactly SegmentSec long and
  # split with no lost frames. -strftime names files by wall clock = t0_video.
  $outPat = Join-Path $dayDir '%Y-%m-%d_%H%M%S.mp4'
  $ffArgs = @('-y','-f','gdigrab','-framerate',$Fps,'-i','desktop','-f','dshow','-i',$MicDevice,
              '-map','0:v','-map','1:a',
              '-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p',
              '-c:a','aac','-b:a','128k',
              '-movflags','+faststart',
              '-use_wallclock_as_timestamps','1','-vsync','cfr','-rtbufsize','256M',
              '-force_key_frames',("expr:gte(t,n_forced*{0})" -f $SegmentSec),
              '-f','segment','-segment_time',$SegmentSec,'-reset_timestamps','1','-strftime','1',
              $outPat)
  return @{ proc = (Start-Process $ff -ArgumentList $ffArgs -PassThru -WindowStyle Hidden);
            key = $kl.proc; keyPath = $kl.path; dayDir = $dayDir; day = $day }
}

# Startup check: fail fast if ffmpeg binary not found (prevents tight crash-restart loop)
if (-not (Test-Path $ff)) {
  Write-Heartbeat 'error' $PID "ffmpeg not found. Install ffmpeg and set config.ffmpegPath, or ensure WinGet/choco install is complete. Searched: $ff"
  Write-Error "ffmpeg not found at: $ff"
  exit 1
}

# Startup check: fail fast if mic device doesn't exist (prevents 5s-restart loop)
$micCheck = & $ff -list_devices true -f dshow -i dummy 2>&1
if ($micCheck -notmatch [regex]::Escape($MicDeviceName)) {
  Write-Heartbeat 'error' $PID "Mic device not found: $MicDeviceName. Run: ffmpeg -list_devices true -f dshow -i dummy, then set config.micDevice"
  Write-Error "Mic device not found: $MicDeviceName"
  exit 1
}

Write-Heartbeat 'starting' $PID ''
while ($true) {
  try {
    $cap = $null; $proc = $null   # reset before Start-Capture so stale refs never survive a crash
    New-Item -ItemType Directory -Force $outRoot | Out-Null
    $freeGB = Ensure-DiskSpace $outRoot $minFreeGB
    if ($freeGB -lt $minFreeGB) {
      Write-Heartbeat 'lowdisk' $PID "free=${freeGB}GB; waiting for disk"
      Start-Sleep -Seconds 60
      Write-Heartbeat 'lowdisk' $PID "free=${freeGB}GB; still waiting"
      continue
    }

    $cap = Start-Capture
    $proc = $cap.proc
    if (-not $proc) { Write-Heartbeat 'error' $PID 'ffmpeg Start-Process returned null'; Start-Sleep -Seconds 15; continue }

    while (-not $proc.HasExited) {
      $free = Get-FreeGB $outRoot
      if ($free -lt $minFreeGB) { Ensure-DiskSpace $outRoot $minFreeGB | Out-Null }

      # keylog watchdog: restart keylog if it died unexpectedly
      if ($cap.key -and $cap.key.HasExited) {
        $kl2 = Start-KeyLog $cap.dayDir
        $cap.key = $kl2.proc
      }

      # Midnight rollover: if calendar day changed, restart ffmpeg in new dayDir
      $todayStr = (Get-Date).ToString('yyyy-MM-dd')
      if ($todayStr -ne $cap.day) {
        Write-Heartbeat 'recording' $proc.Id "midnight-rollover; stopping ffmpeg for day boundary"
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        try { if ($cap.key -and -not $cap.key.HasExited) { Stop-Process -Id $cap.key.Id -Force -ErrorAction SilentlyContinue } } catch {}
        break  # exit inner loop; outer loop calls Start-Capture with new day
      }

      $newest = Get-ChildItem $cap.dayDir -Filter *.mp4 -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime | Select-Object -Last 1
      Write-Heartbeat 'recording' $proc.Id ("free=${free}GB last=" + $(if ($newest) { $newest.Name } else { '-' }))
      Start-Sleep -Seconds 30
    }

    # ffmpeg exited (rollover break or unexpected exit). Clean child keylog and restart.
    try { if ($cap -and $cap.key -and -not $cap.key.HasExited) { Stop-Process -Id $cap.key.Id -Force -ErrorAction SilentlyContinue } } catch {}
    if ($proc -and $proc.HasExited -and $proc.ExitCode -ne 0) {
      Write-Heartbeat 'error' $PID "ffmpeg exited (code=$($proc.ExitCode)); restarting"
      Start-Sleep -Seconds 5
    }
  } catch {
    Write-Heartbeat 'error' $PID $_.Exception.Message
    Start-Sleep -Seconds 15
  }
}
