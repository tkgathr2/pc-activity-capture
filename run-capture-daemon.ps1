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

$MicDevice = 'audio=@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{3B4BEB3B-66AA-4FB2-BD31-F6ABCFD8AF2B}'

function Write-Heartbeat([string]$status, $pid2, [string]$detail) {
  $hb = [ordered]@{ ts=(Get-Date).ToString('o'); status=$status; pid=$pid2; detail=$detail; host=$env:COMPUTERNAME; user=$env:USERNAME; ffmpeg=$ff; segmentSec=$SegmentSec }
  $hb | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 $hbFile
}

# D6 disk resilience: keep free space above the threshold by deleting the oldest
# mp4/keylog files. Safe to run while ffmpeg writes new ones.
function Get-FreeGB([string]$p) {
  try {
    $r = [System.IO.Path]::GetPathRoot($p)
    $di = New-Object System.IO.DriveInfo($r)
    return [math]::Round($di.AvailableFreeSpace / 1GB, 2)
  } catch { return 9999 }
}
function Ensure-DiskSpace([string]$rootDir, [double]$minGB) {
  $guard = 0
  while ((Get-FreeGB $rootDir) -lt $minGB -and $guard -lt 100000) {
    $oldest = Get-ChildItem $rootDir -Recurse -File -Include *.mp4,*.jsonl -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -First 1
    if (-not $oldest) { break }
    Remove-Item $oldest.FullName -Force -ErrorAction SilentlyContinue
    $guard++
  }
  return (Get-FreeGB $rootDir)
}

function Start-Capture {
  $start = Get-Date
  $day = $start.ToString('yyyy-MM-dd')
  $dayDir = Join-Path $outRoot $day
  New-Item -ItemType Directory -Force $dayDir | Out-Null

  # one continuous keylog for this capture run (timestamps aligned to wall clock)
  $klog = Join-Path $dayDir ("keylog_{0}.jsonl" -f $start.ToString('HHmmss'))
  $keyProc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'keylog.ps1'),
    '-DurationSec','86400','-OutFile',$klog)

  # session meta: t0 anchor for syncing keylog to video. Each segment file name is
  # strftime(local wall clock) at its start, so a segment's t0_video == its filename.
  ([ordered]@{ session_start=$start.ToString('o'); day=$day; t0=$start.ToString('o');
               keylog=$klog; fps=$Fps; segmentSec=$SegmentSec; mic=$MicDevice;
               ffmpeg=$ff; segment_name='%Y-%m-%d_%H%M%S.mp4'; mode='segment-muxer-gapless' } |
    ConvertTo-Json) | Set-Content -Encoding UTF8 (Join-Path $dayDir 'session-meta.json')

  # GAPLESS recording: single ffmpeg, segment muxer. -force_key_frames puts a
  # keyframe exactly at each boundary so segments are exactly SegmentSec long and
  # split with no lost frames. -strftime names files by wall clock = t0_video.
  $outPat = Join-Path $dayDir '%Y-%m-%d_%H%M%S.mp4'
  $ffArgs = @('-y','-f','gdigrab','-framerate',$Fps,'-i','desktop','-f','dshow','-i',$MicDevice,
              '-map','0:v','-map','1:a',
              '-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p',
              '-c:a','aac','-b:a','128k',
              '-use_wallclock_as_timestamps','1','-vsync','cfr','-rtbufsize','256M',
              '-force_key_frames',("expr:gte(t,n_forced*{0})" -f $SegmentSec),
              '-f','segment','-segment_time',$SegmentSec,'-reset_timestamps','1','-strftime','1',
              $outPat)
  return @{ proc = (Start-Process $ff -ArgumentList $ffArgs -PassThru -WindowStyle Hidden);
            key = $keyProc; dayDir = $dayDir }
}

Write-Heartbeat 'starting' $PID ''
while ($true) {
  try {
    New-Item -ItemType Directory -Force $outRoot | Out-Null
    $freeGB = Ensure-DiskSpace $outRoot $minFreeGB
    if ($freeGB -lt $minFreeGB) { Write-Heartbeat 'lowdisk' $PID "free=${freeGB}GB" }

    $cap = Start-Capture
    $proc = $cap.proc

    while (-not $proc.HasExited) {
      $free = Get-FreeGB $outRoot
      if ($free -lt $minFreeGB) { Ensure-DiskSpace $outRoot $minFreeGB | Out-Null }
      $newest = Get-ChildItem $cap.dayDir -Filter *.mp4 -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime | Select-Object -Last 1
      Write-Heartbeat 'recording' $proc.Id ("free=${free}GB last=" + $(if ($newest) { $newest.Name } else { '-' }))
      Start-Sleep -Seconds 30
    }

    # ffmpeg exited unexpectedly (only gap source). Clean child keylog and restart.
    try { if ($cap.key -and -not $cap.key.HasExited) { Stop-Process -Id $cap.key.Id -Force -ErrorAction SilentlyContinue } } catch {}
    Write-Heartbeat 'error' $PID 'ffmpeg exited; restarting'
    Start-Sleep -Seconds 5
  } catch {
    Write-Heartbeat 'error' $PID $_.Exception.Message
    Start-Sleep -Seconds 15
  }
}
