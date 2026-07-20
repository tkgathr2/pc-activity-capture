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
$JaDay = @('日','月','火','水','木','金','土')
$days = @()
for ($i = 0; $i -le 6; $i++) {
  $d = $weekStart.AddDays($i)
  $dateStr = $d.ToString('yyyy-MM-dd')
  $dayDir  = Join-Path $captRoot $dateStr

  $recMinutes = 0
  $sizeMB     = 0
  $appMap     = @{}   # windowName -> keystroke count
  $hourArr    = New-Object int[] 24

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
              if ($obj.ts) { try { $h = [datetime]::Parse($obj.ts).Hour; $hourArr[$h]++ } catch {} }
            } catch {}
          }
        } finally { $sr.Close(); $fs.Close() }
      } catch {}
    }
  }

  $days += [PSCustomObject]@{
    date        = $dateStr
    dayName     = $d.ToString('ddd')
    dayNameJa   = $JaDay[[int]$d.DayOfWeek]
    recMinutes  = $recMinutes
    sizeMB      = $sizeMB
    appMap      = $appMap
    hourArr     = $hourArr
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

# --- category rollup for pie chart ---
function Get-WinCategory([string]$w) {
  if ($w -match 'Claude')                                              { return 'AI・Claude Code' }
  if ($w -match 'Cursor|PowerShell|ターミナル|Terminal|VSCode|vim')   { return '開発ツール' }
  if ($w -match 'LINE|メール|Gmail|Outlook|Mail')                     { return 'メール・LINE' }
  if ($w -match 'Excel|スプレッドシート|Word|PowerPoint|Notion')      { return 'ドキュメント' }
  if ($w -match 'Chrome|Firefox|Edge|Safari')                          { return 'ブラウザ' }
  return 'Slack・業務タスク'
}
$catMap = @{}
foreach ($k in $weekAppMap.Keys) {
  $cat = Get-WinCategory $k
  if ($catMap.ContainsKey($cat)) { $catMap[$cat] += $weekAppMap[$k] } else { $catMap[$cat] = $weekAppMap[$k] }
}
$catJson = '[' + (($catMap.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
  '{{"label":"{0}","value":{1}}}' -f $_.Key, $_.Value
}) -join ',') + ']'

# --- heatmap JSON: 7 x 24 int matrix (day-index x hour) ---
$heatRows  = @()
foreach ($d in $days) { $heatRows += ,([int[]]$d.hourArr) }
$heatJson  = ConvertTo-Json -InputObject @($heatRows) -Compress
$dayLabels = ($days | ForEach-Object { '"{0}({1})"' -f $_.dayNameJa, $_.date.Substring(5) }) -join ','

# --- totals ---
$totalMin  = ($days | Measure-Object recMinutes -Sum).Sum
$totalHr   = [math]::Round($totalMin / 60, 1)
$totalMB   = ($days | Measure-Object sizeMB -Sum).Sum
$activeDays = ($days | Where-Object hasData).Count
$totalKeys  = ($weekAppMap.Values | Measure-Object -Sum).Sum
$totalKeysSafe = if ($totalKeys -gt 0) { $totalKeys } else { 1 }

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
      <td class="dn">$($d.dayNameJa)</td>
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
  $pct = [math]::Round($a.Value / $totalKeysSafe * 100, 1)
  $appRows += "      <tr><td class='rank'>$rank</td><td class='appname'>$([System.Web.HttpUtility]::HtmlEncode($a.Key))</td><td class='num'>$($a.Value)</td><td class='num muted'>$pct%</td></tr>`n"
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
  .muted{color:var(--muted)}
  #heatWrap{overflow-x:auto}
  .heat-grid{display:grid;gap:2px}
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
    <thead><tr><th>#</th><th>ウィンドウ / アプリ</th><th class="num">キー数</th><th class="num">割合</th></tr></thead>
    <tbody>
$appRows
    </tbody>
  </table>
</div>

<div class="section" style="display:flex;gap:24px;flex-wrap:wrap;align-items:flex-start">
  <div style="flex:0 0 auto">
    <h2 style="margin-bottom:12px">カテゴリ別 時間分布</h2>
    <canvas id="pieChart" width="220" height="220"></canvas>
  </div>
  <div id="pieLegend" style="flex:1;min-width:180px;display:flex;flex-direction:column;gap:8px;justify-content:center;padding-top:28px"></div>
</div>

<script>
(function(){
  const data = $catJson;
  const total = data.reduce((s,d)=>s+d.value,0);
  if(!total) return;
  const COLORS=['#7c3aed','#00d4ff','#22c55e','#f59e0b','#ef4444','#ec4899','#8b5cf6','#06b6d4','#a78bfa'];
  const canvas = document.getElementById('pieChart');
  const ctx = canvas.getContext('2d');
  const cx=110,cy=110,r=95;
  let angle=-Math.PI/2;
  data.forEach((d,i)=>{
    const slice=d.value/total*Math.PI*2;
    ctx.beginPath(); ctx.moveTo(cx,cy);
    ctx.arc(cx,cy,r,angle,angle+slice);
    ctx.closePath();
    ctx.fillStyle=COLORS[i%COLORS.length];
    ctx.fill();
    ctx.strokeStyle='#00000033'; ctx.lineWidth=1; ctx.stroke();
    angle+=slice;
  });
  // donut hole
  ctx.beginPath(); ctx.arc(cx,cy,46,0,Math.PI*2);
  ctx.fillStyle=getComputedStyle(document.body).backgroundColor||'#f8f9fa';
  ctx.fill();
  // center label
  ctx.fillStyle=getComputedStyle(document.body).color||'#212529';
  ctx.font='bold 13px system-ui'; ctx.textAlign='center'; ctx.textBaseline='middle';
  ctx.fillText('活動', cx, cy-8);
  ctx.font='10px system-ui'; ctx.fillStyle='#888';
  ctx.fillText('カテゴリ', cx, cy+8);
  // legend
  const leg=document.getElementById('pieLegend');
  data.forEach((d,i)=>{
    const pct=Math.round(d.value/total*100);
    const row=document.createElement('div');
    row.style.cssText='display:flex;align-items:center;gap:8px;font-size:13px';
    row.innerHTML='<span style="display:inline-block;width:12px;height:12px;border-radius:3px;flex-shrink:0;background:'+COLORS[i%COLORS.length]+'"></span>'
      +'<span style="flex:1">'+d.label+'</span>'
      +'<span style="font-weight:700;font-variant-numeric:tabular-nums;min-width:38px;text-align:right">'+pct+'%</span>';
    leg.appendChild(row);
  });
})();
</script>

<div class="section">
  <h2>時間帯別アクティビティ（キーストローク密度）</h2>
  <div id="heatWrap"></div>
</div>

<script>
(function(){
  var heat = $heatJson;
  var dayLbls = [$dayLabels];
  var flat = [];
  for (var di = 0; di < heat.length; di++) for (var hi = 0; hi < 24; hi++) flat.push(heat[di][hi]);
  var MAX = Math.max.apply(null, flat);
  if (!MAX) { document.getElementById('heatWrap').textContent = 'この週のキーログデータなし'; return; }
  var COLS = heat.length;
  var grid = document.createElement('div');
  grid.className = 'heat-grid';
  grid.style.gridTemplateColumns = '38px repeat(' + COLS + ',1fr)';
  var hd = document.createElement('div'); grid.appendChild(hd);
  dayLbls.forEach(function(d){
    var c = document.createElement('div');
    c.style.cssText = 'font-size:10px;font-weight:600;text-align:center;padding-bottom:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
    c.textContent = d; c.title = d;
    grid.appendChild(c);
  });
  for (var h = 0; h < 24; h++) {
    var lbl = document.createElement('div');
    lbl.style.cssText = 'font-size:10px;color:var(--muted);text-align:right;padding-right:5px;line-height:17px';
    lbl.textContent = (h < 10 ? '0' : '') + h + ':00';
    grid.appendChild(lbl);
    for (var d2 = 0; d2 < COLS; d2++) {
      var v = heat[d2][h];
      var op = v ? (0.1 + (v / MAX) * 0.9).toFixed(3) : '0';
      var cell = document.createElement('div');
      cell.style.cssText = 'height:17px;border-radius:2px;background:rgba(77,171,247,' + op + ')';
      cell.title = dayLbls[d2] + ' ' + (h < 10 ? '0' : '') + h + ':00 — ' + v + ' keys';
      grid.appendChild(cell);
    }
  }
  document.getElementById('heatWrap').appendChild(grid);
})();
</script>

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
