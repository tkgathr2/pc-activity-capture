@echo off
chcp 65001 >nul
title Revolution 稼働レポート
REM ダッシュボード（稼働レポート閲覧）を起動してブラウザで開く。
REM 既に起動していれば二重起動せず、そのままブラウザだけ開く。

set "INSTALL=%USERPROFILE%\pc-activity-capture"
if not exist "%INSTALL%\serve-dashboard.ps1" set "INSTALL=C:\dev\pc-activity-capture"

REM 既存のダッシュボードプロセスがなければ起動
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -EA SilentlyContinue | Where-Object { $_.CommandLine -like '*serve-dashboard*' };" ^
  "if (-not $p) { Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File','%INSTALL%\serve-dashboard.ps1'; Start-Sleep 3 }" ^
  "Start-Process 'http://127.0.0.1:8765'"
