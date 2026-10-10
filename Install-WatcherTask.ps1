#Requires -Version 5.1
<#
.SYNOPSIS
  Installs a logon Scheduled Task that runs the Bluetooth watcher elevated.
#>
[CmdletBinding()]
param(
  [string]$TaskName = 'AutoConnect Bluetooth Speaker',
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Watch-BluetoothSpeaker.ps1'

if ($Remove) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Removed scheduled task '$TaskName'."
  exit 0
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
  throw "Missing $scriptPath"
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Installed scheduled task '$TaskName' (runs at logon, elevated)."
Write-Host "Start now: Start-ScheduledTask -TaskName '$TaskName'"
