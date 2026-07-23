# keylog.ps1 - keystroke logger (GetAsyncKeyState polling) -> JSONL with absolute timestamps
# PoC layer 3 of the capture system. ASCII-only on purpose (avoids CP932/BOM mojibake).
# Each line: {"ts":"ISO8601","vk":int,"key":"Name","window":"active window title"}
# Note: scans VK 8-254 (excludes mouse buttons 1-4,6,7 intentionally -- capture video only)
#
# PRIVACY: printable keys (letters, digits, punctuation, space) are NOT recorded by
# their real name. They are masked to a generic category ("alnum"/"symbol") so that
# typed strings -- passwords, card numbers, personal messages -- cannot be reconstructed
# from this log. For those masked keys the numeric vk is ALSO redacted to 0, because vk
# is 1:1 with the physical key and would otherwise fully reconstruct the typed chars on
# its own. Functional/control keys (Enter, Tab, Backspace, arrows, F1-F12, Ctrl/Alt/
# Shift, etc.) keep their real name AND real vk: they carry activity-analysis value and
# do not leak typed content. window/ts are unchanged, and per-window keystroke *counts*
# (all weekly-report.ps1 uses) are fully preserved (count = number of lines per window).
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

# Mask printable/content keys; keep functional keys named.
# Returns "alnum" for letters/digits, "symbol" for punctuation/space/numpad ops,
# and the original key name for everything else (control/modifier/navigation/function).
function Get-KeyLabel {
  param([int]$vk, [string]$name)
  # letters A-Z, top-row digits 0-9, numpad digits 0-9
  if ( ($vk -ge 0x41 -and $vk -le 0x5A) -or
       ($vk -ge 0x30 -and $vk -le 0x39) -or
       ($vk -ge 0x60 -and $vk -le 0x69) ) { return "alnum" }
  # space, numpad operators (* + sep - . /), OEM punctuation (; = , - . / ` [ \ ] ' and 102-key <>)
  if ( ($vk -eq 0x20) -or
       ($vk -ge 0x6A -and $vk -le 0x6F) -or
       ($vk -ge 0xBA -and $vk -le 0xC0) -or
       ($vk -ge 0xDB -and $vk -le 0xDF) -or
       ($vk -eq 0xE2) ) { return "symbol" }
  # functional/control keys are not content-bearing: keep real name
  return $name
}

$sw = [System.IO.StreamWriter]::new($OutFile, $true, [System.Text.UTF8Encoding]::new($false))
try {
  $end = (Get-Date).AddSeconds($DurationSec)
  $prev = @{}
  while ((Get-Date) -lt $end) {
    for ($v = 8; $v -le 254; $v++) {
      $state = [KbNative]::GetAsyncKeyState($v)
      $down  = ($state -band 0x8000) -ne 0
      if ($down -and -not $prev[$v]) {
        $label = Get-KeyLabel $v ([System.Windows.Forms.Keys]$v).ToString()
        # Redact vk for masked/content keys so the typed char cannot be recovered from vk.
        $vkOut = if ($label -eq 'alnum' -or $label -eq 'symbol') { 0 } else { $v }
        $ev = [ordered]@{
          ts     = (Get-Date).ToString("o")
          vk     = $vkOut
          key    = $label
          window = [KbNative]::ActiveWindow()
        }
        $sw.WriteLine(($ev | ConvertTo-Json -Compress))
        $sw.Flush()
      }
      $prev[$v] = $down
    }
    Start-Sleep -Milliseconds 25
  }
} finally {
  $sw.Close()
}
