@echo off
chcp 65001 >nul
title Revolution PC稼働記録 セットアップ
color 0B
echo ============================================================
echo    Revolution  PC稼働記録システム  セットアップ
echo ============================================================
echo.
echo  このPCに稼働記録システムを導入します。
echo  数分かかります。途中で許可を求められたら「はい」を押してください。
echo.
echo ------------------------------------------------------------

REM --- 1. git 確認・自動導入 -----------------------------------
where git >nul 2>nul
if %errorlevel% neq 0 (
  echo [1/3] git を導入しています...
  winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements
) else (
  echo [1/3] git 確認OK
)

REM --- 2. ffmpeg 確認・自動導入 --------------------------------
where ffmpeg >nul 2>nul
if %errorlevel% neq 0 (
  echo [2/3] ffmpeg を導入しています...
  winget install --id Gyan.FFmpeg -e --source winget --silent --accept-package-agreements --accept-source-agreements
) else (
  echo [2/3] ffmpeg 確認OK
)

REM --- git を同一セッションのPATHに補う（導入直後は未反映のため）---
set "PATH=%PATH%;C:\Program Files\Git\cmd;%LOCALAPPDATA%\Microsoft\WinGet\Links"

REM --- 3. 本体セットアップ（GitHubから取得＋タスク登録＋起動）--
echo [3/3] 本体をセットアップしています...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PATH += ';C:\Program Files\Git\cmd;' + $env:LOCALAPPDATA + '\Microsoft\WinGet\Links'; irm https://raw.githubusercontent.com/tkgathr2/pc-activity-capture/master/install.ps1 | iex"

echo.
echo ============================================================
echo    セットアップ完了！
echo ------------------------------------------------------------
echo  ・録画は今すぐ開始し、次回ログオン時からは自動で始まります
echo  ・記録の確認: デスクトップの「稼働レポート.bat」から
echo  ・毎時、最新版へ自動更新されます（何もしなくてOK）
echo ============================================================
echo.
pause
