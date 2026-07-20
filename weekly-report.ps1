# weekly-report.ps1 - generate an HTML summary for one week of capture data.
# Usage:
#   .\weekly-report.ps1                 # last full week (Mon-Sun)
#   .\weekly-report.ps1 -WeekOffset 0  # current week so far
#   .\weekly-report.ps1 -WeekOffset -2 # two weeks ago
param([int]$WeekOffset = -1)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg        = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$captRoot   = [Environment]::ExpandEnvironmentVariables($cfg.captureRoot)
$reportDir  = Join-Path $root 'state\reports'
New-Item -ItemType Directory -Force $reportDir | Out-Null

# --- week boundaries (Monday=start, Sunday=end) ---
$today    = [datetime]::Today
$dow      = [int]$today.DayOfWeek          # 0=Sun .. 6=Sat
$mondayOffset = if ($dow -eq 0) { -6 } else { 1 - $dow }
$thisMonday   = $today.AddDays($mondayOffset)
$weekStart    = $thisMonday.AddDays($WeekOffset * 7)
$weekEnd      = $weekStart.AddDays(6)
$weekLabel    = "W{0:D2} {1}" -f (Get-Date $weekStart -UFormat '%V'), $weekStart.ToString('yyyy')
$weekId       = $weekStart.ToString('yyyy-MM-dd')
$reportFile   = Join-Path $reportDir "$weekId.html"

Write-Host "[weekly-report] $weekLabel  ($($weekStart.ToString('MM/dd')) - $($weekEnd.ToString('MM/dd')))"

# --- collect per-day stats ---
$days = @()
for ($i = 0; $i -le 6; $i++) {
  $d = $weekStart.AddDays($i)
  $dateStr = $d.ToString('yyyy-MM-dd')
  $dayDir  = Join-Path $captRoot $dateStr

  $recMinutes = 0
  $sizeMB     = 0
  $appMap     = @{}   # windowName -> keystroke count

  if (Test-Path $dayDir) {
    $mp4s = @(Get-ChildItem $dayDir -Filter '*.mp4' -ErrorAction SilentlyContinue | Where-Object Length -gt 10000)
    # estimate duration: each segment file is up to 1800s; use count * segment length
    # more precise: sum of (file size / avg bitrate). Use 1800s segments as floor.
    $recMinutes = [math]::Round($mp4s.Count * 30, 0)   # 30 min per segment
    $sizeMB     = [math]::Round(($mp4s | Measure-Object Length -Sum).Sum / 1MB, 0)

    # keylog: count keystrokes per window
    $klogs = @(Get-ChildItem $dayDir -Filter 'keylog_*.jsonl' -ErrorAction SilentlyContinue | Where-Object Length -gt 0)
    foreach ($kf in $klogs) {
      try {
        $fs = [System.IO.File]::Open($kf.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        try {
          while (-not $sr.EndOfStream) {
            $line = $sr.ReadLine()
            if (-not $line) { continue }
            try {
              $obj = $line | ConvertFrom-Json
              $win = if ($obj.window) { $obj.window } else { '(unknown)' }
              # strip long window titles to app name (first 40 chars)
              if ($win.Length -gt 40) { $win = $win.Substring(0, 40) }
              if ($appMap.ContainsKey($win)) { $appMap[$win]++ } else { $appMap[$win] = 1 }
            } catch {}
          }
        } finally { $sr.Close(); $fs.Close() }
      } catch {}
    }
  }

  $days += [PSCustomObject]@{
    date        = $dateStr
    dayName     = $d.ToString('ddd')
    recMinutes  = $recMinutes
    sizeMB      = $sizeMB
    appMap      = $appMap
    hasData     = ($recMinutes -gt 0)
  }
}

# --- aggregate app usage across week ---
$weekAppMap = @{}
foreach ($day in $days) {
  foreach ($k in $day.appMap.Keys) {
    if ($weekAppMap.ContainsKey($k)) { $weekAppMap[$k] += $day.appMap[$k] }
    else { $weekAppMap[$k] = $day.appMap[$k] }
  }
}
$topApps = $weekAppMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15

# --- totals ---
$totalMin  = ($days | Measure-Object recMinutes -Sum).Sum
$totalHr   = [math]::Round($totalMin / 60, 1)
$totalMB   = ($days | Measure-Object sizeMB -Sum).Sum
$activeDays = ($days | Where-Object hasData).Count
$totalKeys  = ($weekAppMap.Values | Measure-Object -Sum).Sum

# --- build bar chart data (max bar = longest day) ---
$maxMin = ($days | Measure-Object recMinutes -Maximum).Maximum
if ($maxMin -eq 0) { $maxMin = 1 }

# --- HTML generation ---
$dayRows = ''
foreach ($d in $days) {
  $barPct = [math]::Round($d.recMinutes / $maxMin * 100, 0)
  $hr     = [math]::Round($d.recMinutes / 60, 1)
  $cls    = if ($d.hasData) { '' } else { ' style="opacity:.35"' }
  $dayRows += @"
    <tr$cls>
      <td class="dn">$($d.dayName)</td>
      <td class="dt">$($d.date)</td>
      <td class="bar-cell"><div class="bar" style="width:$barPct%"></div></td>
      <td class="num">$($hr)h</td>
      <td class="num">$($d.sizeMB) MB</td>
      <td class="num">$(($d.appMap.Values | Measure-Object -Sum).Sum)</td>
    </tr>
"@
}

$appRows = ''
$rank = 1
foreach ($a in $topApps) {
  $appRows += "      <tr><td class='rank'>$rank</td><td class='appname'>$([System.Web.HttpUtility]::HtmlEncode($a.Key))</td><td class='num'>$($a.Value)</td></tr>`n"
  $rank++
}

$generatedAt = (Get-Date).ToString('yyyy/MM/dd HH:mm')

$html = @"
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>Weekly Report $weekLabel</title>
<style>
  :root { --bg:#f8f9fa; --card:#fff; --border:#dee2e6; --accent:#0d6efd; --bar:#4dabf7; --text:#212529; --muted:#6c757d; }
  @media(prefers-color-scheme:dark){:root{--bg:#1a1d21;--card:#25292e;--border:#373c43;--accent:#4dabf7;--bar:#4dabf7;--text:#e9ecef;--muted:#adb5bd;}}
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);padding:24px;font-size:14px}
  h1{font-size:1.4rem;margin-bottom:4px}
  .subtitle{color:var(--muted);margin-bottom:24px;font-size:.85rem}
  .cards{display:flex;gap:16px;flex-wrap:wrap;margin-bottom:24px}
  .card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:16px 20px;min-width:130px;flex:1}
  .card-val{font-size:1.8rem;font-weight:700;color:var(--accent)}
  .card-lbl{font-size:.75rem;color:var(--muted);margin-top:2px}
  table{width:100%;border-collapse:collapse}
  th,td{padding:8px 10px;text-align:left;border-bottom:1px solid var(--border)}
  th{font-size:.75rem;text-transform:uppercase;color:var(--muted);font-weight:600}
  .section{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:16px 20px;margin-bottom:20px}
  .section h2{font-size:.95rem;margin-bottom:12px}
  .bar-cell{width:40%;padding:8px 10px}
  .bar{height:12px;background:var(--bar);border-radius:6px;min-width:2px}
  .num{text-align:right;font-variant-numeric:tabular-nums}
  .dn{font-weight:600;width:40px}
  .dt{color:var(--muted);font-size:.8rem;width:90px}
  .rank{color:var(--muted);width:30px;font-size:.8rem}
  .appname{font-size:.85rem}
  .footer{margin-top:24px;font-size:.75rem;color:var(--muted)}
</style>
</head>
<body>
<h1>Weekly Report — $weekLabel</h1>
<p class="subtitle">$($weekStart.ToString('yyyy/MM/dd'))（月）〜 $($weekEnd.ToString('yyyy/MM/dd'))（日）&nbsp;·&nbsp;生成: $generatedAt</p>

<div class="cards">
  <div class="card"><div class="card-val">$totalHr h</div><div class="card-lbl">総録画時間</div></div>
  <div class="card"><div class="card-val">$activeDays / 7</div><div class="card-lbl">稼働日数</div></div>
  <div class="card"><div class="card-val">$([math]::Round($totalMB/1024,1)) GB</div><div class="card-lbl">総データ量</div></div>
  <div class="card"><div class="card-val">$([string]::Format('{0:N0}',$totalKeys))</div><div class="card-lbl">総キーストローク</div></div>
</div>

<div class="section">
  <h2>日別録画時間</h2>
  <table>
    <thead><tr><th>曜</th><th>日付</th><th colspan="2">録画時間</th><th>サイズ</th><th>キー</th></tr></thead>
    <tbody>
$dayRows
    </tbody>
  </table>
</div>

<div class="section">
  <h2>アプリ別キーストローク（上位 15）</h2>
  <table>
    <thead><tr><th>#</th><th>ウィンドウ / アプリ</th><th class="num">キー数</th></tr></thead>
    <tbody>
$appRows
    </tbody>
  </table>
</div>

<p class="footer">Revolution PC Activity Capture &nbsp;·&nbsp; $([System.Environment]::MachineName) / $([System.Environment]::UserName)</p>
</body>
</html>
"@

# Need System.Web for HtmlEncode
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# Re-render appRows with encoding (already done above but re-run if assembly was missing)
[System.IO.File]::WriteAllText($reportFile, $html, [System.Text.UTF8Encoding]::new($false))
Write-Host "[weekly-report] Saved: $reportFile"
Write-Host "[weekly-report] Summary: ${totalHr}h recorded, $activeDays active days, $($topApps.Count) apps"
