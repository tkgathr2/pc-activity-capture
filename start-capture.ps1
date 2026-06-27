# start-capture.ps1 - PoC orchestrator: records SCREEN + MIC (one synced mp4) and KEYSTROKES,
# all tied to one session start timestamp so they can be combined into a single timeline later.
# ASCII-only on purpose. Speaker(loopback) audio is a pluggable next step (see $SpeakerDevice).
param(
  [int]$DurationSec  = 8,
  [string]$OutRoot   = "$env:USERPROFILE\pc-capture-data",
  [int]$Fps          = 10
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- locate ffmpeg ---
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ff) { $ff = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe" }
if (-not (Test-Path $ff)) {
  $ff = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin\ffmpeg.exe"
}
if (-not (Test-Path $ff)) { throw "ffmpeg not found" }

# --- capture devices (ASCII alternative names avoid Japanese arg mojibake) ---
$MicDevice     = 'audio=@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{3B4BEB3B-66AA-4FB2-BD31-F6ABCFD8AF2B}'  # マイク (EMEET SmartCam C965)
$SpeakerDevice = ''   # TODO: set to a loopback device (Stereo Mix / virtual cable) to also grab meeting/Zoom audio

# --- session folder ---
$start = Get-Date
$day = $start.ToString('yyyy-MM-dd'); $sid = $start.ToString('HHmmss')
$dir = Join-Path $OutRoot "$day\$sid"
New-Item -ItemType Directory -Force $dir | Out-Null
$mp4  = Join-Path $dir 'screen.mp4'
$klog = Join-Path $dir 'keylog.jsonl'

# --- meta (the sync key: everything maps to session_start) ---
$meta = [ordered]@{
  session_start = $start.ToString('o')
  day = $day; sid = $sid
  screen = $mp4; keylog = $klog
  mic = $MicDevice; speaker = $SpeakerDevice
  fps = $Fps; duration_sec = $DurationSec; ffmpeg = $ff
}
$meta | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $dir 'meta.json')

Write-Host "[capture] session $day/$sid -> $dir"

# --- layer 3: keystrokes (background) ---
$kl = Join-Path $PSScriptRoot 'keylog.ps1'
$kp = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
  '-NoProfile','-ExecutionPolicy','Bypass','-File', $kl,
  '-DurationSec', $DurationSec, '-OutFile', $klog
)

# --- layers 1+2: screen (gdigrab) + mic (dshow) -> one synced mp4 ---
$ffArgs = @('-y','-f','gdigrab','-framerate', $Fps, '-i','desktop',
            '-f','dshow','-i', $MicDevice,
            '-t', $DurationSec,
            '-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p',
            '-c:a','aac','-b:a','128k', $mp4)
Write-Host "[capture] recording screen+mic for $DurationSec s ..."
& $ff @ffArgs 2>&1 | Out-Null

$kp.WaitForExit(6000) | Out-Null
if (-not $kp.HasExited) { $kp.Kill() }

# --- report ---
$vid = if (Test-Path $mp4) { [math]::Round((Get-Item $mp4).Length/1KB,1) } else { 0 }
$keys = if (Test-Path $klog) { (Get-Content $klog).Count } else { 0 }
Write-Host "[capture] DONE  screen.mp4=${vid}KB  keystrokes=${keys}  folder=$dir"
