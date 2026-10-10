#Requires -Version 5.1
<#
.SYNOPSIS
  Installs a sign-in scheduled task that runs Speaker-Watch.ps1 elevated.

.DESCRIPTION
  The task starts when you sign in. While that process is running, the script
  checks the speaker on the poll interval from config.json. A second trigger
  starts the watcher again every few minutes if it is not already running.
  Pass -Remove to uninstall instead.
#>
[CmdletBinding()]
param(
  [string]$TaskName = 'AutoConnect Bluetooth Speaker',
  [int]$WatchdogMinutes = 5,
  [switch]$Remove,
  [switch]$NoElevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$WatcherPath = Join-Path $ScriptRoot 'Speaker-Watch.ps1'
$ResultPath = Join-Path $ScriptRoot 'logs\install-task.result.txt'

function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$identity
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Arg {
  param([Parameter(Mandatory)][string]$Value)
  if ($Value -match '[\s"]') { return '"' + ($Value.Replace('"', '\"')) + '"' }
  return $Value
}

function Write-Result {
  param([Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][string]$Text)
  $dir = Split-Path -Parent $ResultPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  Set-Content -LiteralPath $ResultPath -Value $Text -Encoding UTF8
  exit $Code
}

if ($Remove) {
  $uninstall = Join-Path $ScriptRoot 'Uninstall-WatcherTask.ps1'
  if (-not (Test-Path -LiteralPath $uninstall)) { throw "Missing $uninstall" }
  & $uninstall -TaskName $TaskName
  exit $LASTEXITCODE
}

if ($WatchdogMinutes -lt 1) { throw 'WatchdogMinutes must be at least 1.' }

if (-not $NoElevate -and -not (Test-IsAdmin)) {
  if (Test-Path -LiteralPath $ResultPath) { Remove-Item -LiteralPath $ResultPath -Force }
  $argString = @(
    '-NoProfile'
    '-ExecutionPolicy Bypass'
    '-File'
    (Quote-Arg $ScriptPath)
    '-NoElevate'
    '-TaskName'
    (Quote-Arg $TaskName)
    '-WatchdogMinutes'
    "$WatchdogMinutes"
  ) -join ' '
  Write-Host 'Approve the UAC prompt to install the scheduled task.'
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $ScriptRoot -ArgumentList $argString | Out-Null
  } catch {
    throw "Elevation failed or was cancelled: $($_.Exception.Message)"
  }
  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $ResultPath) {
      $text = Get-Content -LiteralPath $ResultPath -Raw
      Write-Host $text
      if ($text -match '(?m)^exit=(\d+)') { exit ([int]$Matches[1]) }
      exit 0
    }
    Start-Sleep -Seconds 1
  }
  throw 'Timed out waiting for the elevated installer.'
}

try {
  if (-not (Test-IsAdmin)) { throw 'Install requires an elevated process.' }
  if (-not (Test-Path -LiteralPath $WatcherPath)) { throw "Missing $WatcherPath" }

  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arguments = "-NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$WatcherPath`""
  $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $ScriptRoot

  $logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $WatchdogMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 9999)

  $userId = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Highest -LogonType Interactive
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $watchdog) `
    -Principal $principal -Settings $settings `
    -Description 'Reconnects the configured Bluetooth speaker when it drops.' -Force | Out-Null

  $poll = 10
  $configPath = Join-Path $ScriptRoot 'config.json'
  if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config.pollIntervalSeconds) { $poll = [int]$config.pollIntervalSeconds }
  }

  Start-ScheduledTask -TaskName $TaskName

  $message = @"
exit=0
Installed scheduled task '$TaskName'.
It starts when $userId signs in, and every $WatchdogMinutes minutes if the watcher is not already running.
Speaker-Watch.ps1 then checks every ${poll}s. Log: logs\speaker-watch.log
The task was started now.
"@
  Write-Host $message
  if ($NoElevate) { Write-Result -Code 0 -Text $message }
  exit 0
} catch {
  $message = "exit=1`r`n$($_.Exception.Message)"
  Write-Host $message
  if ($NoElevate) { Write-Result -Code 1 -Text $message }
  exit 1
}
