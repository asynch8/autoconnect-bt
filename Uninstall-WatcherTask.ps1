#Requires -Version 5.1
<#
.SYNOPSIS
  Removes the Bluetooth speaker watcher scheduled task and stops a running watcher.

.DESCRIPTION
  Removes the task named 'AutoConnect Bluetooth Speaker', plus any other task
  whose action launches Speaker-Watch.ps1 or Watch-BluetoothSpeaker.ps1.
  Also stops a watcher process started from either script.
#>
[CmdletBinding()]
param(
  [string]$TaskName = 'AutoConnect Bluetooth Speaker',
  [switch]$NoElevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$ResultPath = Join-Path $ScriptRoot 'logs\uninstall-task.result.txt'

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
  ) -join ' '
  Write-Host 'Approve the UAC prompt to remove the scheduled task.'
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
  throw 'Timed out waiting for the elevated uninstaller.'
}

try {
  if (-not (Test-IsAdmin)) { throw 'Uninstall requires an elevated process.' }

  $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
      $nameMatch = $_.TaskName -eq $TaskName
      $actionMatch = $false
      foreach ($action in @($_.Actions)) {
        $args = [string]$action.Arguments
        if ($args -like '*Speaker-Watch.ps1*' -or $args -like '*Watch-BluetoothSpeaker.ps1*') {
          $actionMatch = $true
        }
      }
      $nameMatch -or $actionMatch
    })

  $removedNames = New-Object System.Collections.Generic.List[string]
  foreach ($task in $tasks) {
    Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
    $removedNames.Add("$($task.TaskPath)$($task.TaskName)")
  }

  $stopped = 0
  $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
      $cmd = [string]$_.CommandLine
      ($cmd -like '*Speaker-Watch.ps1*' -or $cmd -like '*Watch-BluetoothSpeaker.ps1*') -and
      $cmd -notlike '*-Probe*'
    })
  foreach ($proc in $procs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    $stopped++
  }

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('exit=0')
  if ($removedNames.Count -eq 0) {
    [void]$lines.Add("No scheduled task named '$TaskName' is installed, and no task launches the watcher scripts.")
  } else {
    [void]$lines.Add('Removed scheduled task(s):')
    foreach ($name in $removedNames) { [void]$lines.Add("  $name") }
  }
  [void]$lines.Add("Stopped $stopped watcher process(es).")
  $message = $lines -join "`r`n"
  Write-Host $message
  if ($NoElevate) { Write-Result -Code 0 -Text $message }
  exit 0
} catch {
  $message = "exit=1`r`n$($_.Exception.Message)"
  Write-Host $message
  if ($NoElevate) { Write-Result -Code 1 -Text $message }
  exit 1
}
