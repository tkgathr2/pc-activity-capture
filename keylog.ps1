# keylog.ps1 - keystroke logger (GetAsyncKeyState polling) -> JSONL with absolute timestamps
# PoC layer 3 of the capture system. ASCII-only on purpose (avoids CP932/BOM mojibake).
# Each line: {"ts":"ISO8601","vk":int,"key":"Name","window":"active window title"}
# Note: scans VK 8-254 (excludes mouse buttons 1-4,6,7 intentionally -- capture video only)
param(
  [int]$DurationSec = 8,          # default=8s for quick test; daemon passes 86400
  [string]$OutFile  = "keylog.jsonl"
)
$ErrorActionPreference = 'Continue'  # do not crash on non-fatal errors
Add-Type -AssemblyName System.Windows.Forms
$sig = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class KbNative {
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  public static string ActiveWindow() {
    var b = new StringBuilder(512);
    GetWindowText(GetForegroundWindow(), b, 512);
    return b.ToString();
  }
}
"@
Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue
$sw = [System.IO.StreamWriter]::new($OutFile, $true, [System.Text.UTF8Encoding]::new($false))
try {
  $end = (Get-Date).AddSeconds($DurationSec)
  $prev = @{}
  while ((Get-Date) -lt $end) {
    for ($v = 8; $v -le 254; $v++) {
      $state = [KbNative]::GetAsyncKeyState($v)
      $down  = ($state -band 0x8000) -ne 0
      if ($down -and -not $prev[$v]) {
        $ev = [ordered]@{
          ts     = (Get-Date).ToString("o")
          vk     = $v
          key    = ([System.Windows.Forms.Keys]$v).ToString()
          window = [KbNative]::ActiveWindow()
        }
        $sw.WriteLine(($ev | ConvertTo-Json -Compress))
        $sw.Flush()
      }
      $prev[$v] = $down
    }
    Start-Sleep -Milliseconds 12
  }
} finally {
  $sw.Close()
}
