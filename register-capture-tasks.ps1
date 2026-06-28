# register-capture-tasks.ps1 - registers two scheduled tasks:
#   1) PCActivityCapture          : AtLogOn  -> run-capture-daemon.ps1 (records all day)
#   2) PCActivityCaptureWatchdog  : every 5 min -> watchdog.ps1 (dead-man alert to 上長)
# Idempotent: re-running replaces the tasks. ASCII-only.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps   = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

function Register-One($name, $scriptFile, $trigger) {
  $action = New-ScheduledTaskAction -Execute $ps `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $root $scriptFile)`""
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
  $set.DisallowStartIfOnBatteries = $false
  $set.StopIfGoingOnBatteries = $false
  $pr  = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $set -Principal $pr | Out-Null
  Write-Host "[registered] $name"
}

# 1) auto-start capture at logon
Register-One 'PCActivityCapture' 'run-capture-daemon.ps1' (New-ScheduledTaskTrigger -AtLogOn)

# 2) watchdog every 5 minutes
$wt = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-One 'PCActivityCaptureWatchdog' 'watchdog.ps1' $wt

Write-Host "[done] tasks registered. Capture auto-starts at next logon; watchdog checks every 5 min."
