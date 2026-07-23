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
# Bootstrap: config.json is git-ignored on distributed PCs; seed it from the tracked
# template on first run so a hand-edited config never conflicts with hourly git pull.
$cfgPath = Join-Path $root 'config.json'
if (-not (Test-Path $cfgPath)) {
  $tmpl = Join-Path $root 'config.template.json'
  if (Test-Path $tmpl) { Copy-Item $tmpl $cfgPath }
}
$cfg       = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$outRoot   = [Environment]::ExpandEnvironmentVariables($cfg.captureRoot)
$minFreeGB = if ($cfg.minFreeGB) { [double]$cfg.minFreeGB } else { 10 }

# PC identity stamp (Phase-2 bridge): so a central NAS can attribute each PC's
# data to a person. Created once; edit staffLabel later to a human name if wanted.
# config.staffLabel (if set) wins; otherwise default to COMPUTERNAME.
$machineFile = Join-Path $stateDir 'machine.json'
# Regenerate every daemon start (i.e. every logon) if the stamp is MISSING or
# CORRUPT/EMPTY. The old '-not Test-Path' check only covered a missing file, so a
# truncated or unparseable machine.json would never self-heal.
$machineValid = $false
if (Test-Path $machineFile) {
  try {
    $mjExisting = Get-Content $machineFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($mjExisting -and $mjExisting.computerName) { $machineValid = $true }
  } catch { $machineValid = $false }
}
if (-not $machineValid) {
  $label = if ($cfg.staffLabel) { "$($cfg.staffLabel)" } else { $env:COMPUTERNAME }
  $mj = [ordered]@{
    computerName = $env:COMPUTERNAME
    userName     = $env:USERNAME
    staffLabel   = $label
    createdAt    = (Get-Date).ToString('o')
  }
  [System.IO.File]::WriteAllText($machineFile, ($mj | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
}

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

# MicDevice: use config.micDevice if set, otherwise auto-detect the first available
# DirectShow audio device. On a new PC this requires no manual configuration.
function Get-FirstAudioDevice([string]$ffBin) {
  $out = & $ffBin -list_devices true -f dshow -i dummy 2>&1
  foreach ($line in $out) {
    # ffmpeg prints: [dshow @ ptr] "Device Name" (audio)
    if ($line -match '"([^"]+)"\s*\(audio\)') { return $matches[1] }
  }
  return $null
}
# Audio is OPTIONAL and OFF by default. Rationale: mic device names differ per PC,
# change between direct/RDP sessions (e.g. "リモート オーディオ" only exists over
# Remote Desktop), and Japanese names round-trip badly through PS5.1 -> ffmpeg -5
# crashes. For staff activity capture, screen + keylog is the core value, so we
# record VIDEO-ONLY unless config.recordAudio is explicitly true AND a mic exists.
# This makes the daemon record reliably on ANY PC with zero audio configuration.
$RecordAudio   = [bool]$cfg.recordAudio
$MicDeviceName = $null
if ($RecordAudio) {
  $MicDeviceName = if ($cfg.micDevice) { $cfg.micDevice } else { Get-FirstAudioDevice $ff }
  # Never exit over audio: if no mic, fall back to video-only instead of crashing.
  if (-not $MicDeviceName) { $RecordAudio = $false }
}
$MicDevice = if ($MicDeviceName) { "audio=$MicDeviceName" } else { $null }

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
  # Video input (always). scale=trunc(.../2)*2 rounds odd desktop resolutions to even
  # so libx264 never errors ("width not divisible by 2") on multi-monitor/high-DPI.
  $ffArgs = @('-y','-f','gdigrab','-framerate',$Fps,'-i','desktop','-video_size','1920x1080','-thread_queue_size','512')
  # Audio input (optional): only added when a mic was found and recordAudio is on.
  if ($RecordAudio -and $MicDevice) {
    $ffArgs += @('-f','dshow','-i',$MicDevice,'-thread_queue_size','512','-map','0:v','-map','1:a')
  } else {
    $ffArgs += @('-map','0:v')
  }
  $ffArgs += @('-vf','scale=trunc(iw/2)*2:trunc(ih/2)*2',
              '-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p')
  if ($RecordAudio -and $MicDevice) { $ffArgs += @('-c:a','aac','-b:a','128k') }
  $ffArgs += @('-movflags','+faststart',
              '-use_wallclock_as_timestamps','1','-vsync','cfr','-rtbufsize','512M',
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

# Startup check for mic is NON-FATAL: if audio is enabled but the mic vanished
# (e.g. RDP session ended so "リモート オーディオ" disappeared), degrade to
# video-only instead of exiting. Recording screen + keylog must never stop over audio.
if ($RecordAudio -and $MicDeviceName) {
  $micCheck = & $ff -list_devices true -f dshow -i dummy 2>&1
  if (-not ($micCheck | Where-Object { $_ -match [regex]::Escape($MicDeviceName) })) {
    Write-Heartbeat 'starting' $PID "mic '$MicDeviceName' not present; recording video-only"
    $RecordAudio = $false
  }
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
      $freeGB = Get-FreeGB $outRoot
      Write-Heartbeat 'lowdisk' $PID "free=${freeGB}GB; still waiting"
      continue
    }

    $cap = Start-Capture
    $proc = $cap.proc
    if (-not $proc) { Write-Heartbeat 'error' $PID 'ffmpeg Start-Process returned null'; Start-Sleep -Seconds 15; continue }

    $plannedStop = $false  # set true on midnight rollover to skip the error-restart penalty
    while (-not $proc.HasExited) {
      $free = Get-FreeGB $outRoot
      if ($free -lt $minFreeGB) { Ensure-DiskSpace $outRoot $minFreeGB | Out-Null }

      # keylog watchdog: restart keylog if it died unexpectedly
      if ($cap.key -and $cap.key.HasExited) {
        $kl2 = Start-KeyLog $cap.dayDir
        $cap.key     = $kl2.proc
        $cap.keyPath = $kl2.path  # update path so dashboard /api/keylog finds the new file
      }

      # Midnight rollover: if calendar day changed, restart ffmpeg in new dayDir
      $todayStr = (Get-Date).ToString('yyyy-MM-dd')
      if ($todayStr -ne $cap.day) {
        Write-Heartbeat 'recording' $proc.Id "midnight-rollover; stopping ffmpeg for day boundary"
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        try { if ($cap.key -and -not $cap.key.HasExited) { Stop-Process -Id $cap.key.Id -Force -ErrorAction SilentlyContinue } } catch {}
        $plannedStop = $true
        break  # exit inner loop; outer loop calls Start-Capture with new day
      }

      $newest = Get-ChildItem $cap.dayDir -Filter *.mp4 -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime | Select-Object -Last 1
      Write-Heartbeat 'recording' $proc.Id ("free=${free}GB last=" + $(if ($newest) { $newest.Name } else { '-' }))
      Start-Sleep -Seconds 30
    }

    # ffmpeg exited (rollover break or unexpected exit). Clean child keylog and restart.
    try { if ($cap -and $cap.key -and -not $cap.key.HasExited) { Stop-Process -Id $cap.key.Id -Force -ErrorAction SilentlyContinue } } catch {}
    if (-not $plannedStop -and $proc -and $proc.HasExited -and $proc.ExitCode -ne 0) {
      Write-Heartbeat 'error' $PID "ffmpeg exited (code=$($proc.ExitCode)); restarting"
      Start-Sleep -Seconds 5
    }
  } catch {
    Write-Heartbeat 'error' $PID $_.Exception.Message
    Start-Sleep -Seconds 15
  }
}
