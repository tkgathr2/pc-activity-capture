# install-on-new-pc.ps1 — Revolution PC Activity Recorder: one-shot setup
# Usage: powershell -ExecutionPolicy Bypass -File install-on-new-pc.ps1
# Run as the USER (not admin) in an interactive session.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Write-Host "`n=== Revolution セットアップ ===" -ForegroundColor Cyan

# 1. Check / install ffmpeg via WinGet
$ffBin = $null
$searchPaths = @(
  "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe",
  "${env:ProgramFiles(x86)}\ffmpeg\bin\ffmpeg.exe"
)
# WinGet path (versioned wildcard)
$wgBase = "$env:LocalAppData\Microsoft\WinGet\Packages"
if (Test-Path $wgBase) {
  $searchPaths += @(Get-ChildItem $wgBase -Filter 'Gyan.FFmpeg*' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'ffmpeg-*\bin\ffmpeg.exe' } |
    ForEach-Object { Resolve-Path $_ -ErrorAction SilentlyContinue } |
    ForEach-Object { $_.Path })
}
foreach ($p in $searchPaths) { if (Test-Path $p) { $ffBin = $p; break } }

if (-not $ffBin) {
  Write-Host "[1/3] ffmpeg が見つかりません。WinGet でインストールします..." -ForegroundColor Yellow
  try {
    winget install --id Gyan.FFmpeg --source winget --silent --accept-package-agreements --accept-source-agreements
    Write-Host "    ffmpeg インストール完了" -ForegroundColor Green
  } catch {
    Write-Host "    WinGet インストール失敗: $_" -ForegroundColor Red
    Write-Host "    手動で ffmpeg を https://ffmpeg.org/download.html からインストールしてください"
  }
} else {
  Write-Host "[1/3] ffmpeg 確認済み: $ffBin" -ForegroundColor Green
}

# 2. Clone repo
$dest = "C:\dev\pc-activity-capture"
if (Test-Path $dest) {
  Write-Host "[2/3] $dest は既存。git pull で更新..." -ForegroundColor Yellow
  Push-Location $dest
  git pull origin master 2>&1 | Write-Host
  Pop-Location
} else {
  Write-Host "[2/3] リポジトリをクローン → $dest" -ForegroundColor Yellow
  New-Item -ItemType Directory -Force "C:\dev" | Out-Null
  git clone https://github.com/tkgathr2/pc-activity-capture.git $dest 2>&1 | Write-Host
}

# 3. Register scheduled tasks (AtLogon capture + 5-min watchdog)
Write-Host "[3/3] スケジュールタスク登録..." -ForegroundColor Yellow
Push-Location $dest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\register-capture-tasks.ps1"
Pop-Location

Write-Host "`n=== セットアップ完了 ===" -ForegroundColor Green
Write-Host "次回ログオン時から自動録画が開始します。"
Write-Host "今すぐ録画を開始する場合: Start-Process powershell -ArgumentList '-File C:\dev\pc-activity-capture\run-capture-daemon.ps1'"
Write-Host "ダッシュボード: Start-Process powershell -ArgumentList '-File C:\dev\pc-activity-capture\serve-dashboard.ps1'"
