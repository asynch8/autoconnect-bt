#Requires -Version 5.1
<#
.SYNOPSIS
  Watches a paired Bluetooth speaker and reconnects it when it drops.

.DESCRIPTION
  Detects disconnect via WinRT ConnectionStatus + audio endpoint state.
  Reconnect tries (in order), without service disable/enable cycles that
  spawn ghost playback devices:
    1) Core Audio KS ONESHOT_RECONNECT (ToothTray method)
    2) BluetoothSetServiceState ENABLE only (never disable)
    3) pnputil disable/enable of the Bluetooth device node
    4) Optional Bluetooth adapter cycle (last resort)
  Also cleans leftover MMDevice ghost endpoints after reconnect.

.EXAMPLE
  .\Watch-BluetoothSpeaker.ps1 -Status
  .\Watch-BluetoothSpeaker.ps1 -ForceReconnect -Once
  .\Watch-BluetoothSpeaker.ps1 -CleanupGhosts -Once
#>
[CmdletBinding()]
param(
  [string]$DeviceName,
  [int]$PollIntervalSeconds,
  [switch]$Once,
  [switch]$Status,
  [switch]$ForceReconnect,
  [switch]$NoElevate,
  [switch]$CycleAdapter,
  [switch]$CleanupGhosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$ConfigPath = Join-Path $ScriptRoot 'config.json'
$CsPath = Join-Path $ScriptRoot 'BtAudioConnect.cs'

function Read-Config {
  $defaults = [pscustomobject]@{
    deviceName                  = 'HK GO + PLAY'
    pollIntervalSeconds         = 10
    reconnectCooldownSeconds    = 30
    disableEnableDelaySeconds   = 3
    maxReconnectAttemptsPerHour = 20
    logPath                     = 'logs\autoconnect-bt.log'
    cycleAdapter                = $false
    cleanupGhostsOnReconnect    = $true
    allowHfpReconnect           = $true
  }

  if (-not (Test-Path -LiteralPath $ConfigPath)) { return $defaults }

  $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  foreach ($prop in $defaults.PSObject.Properties.Name) {
    if (-not ($json.PSObject.Properties.Name -contains $prop) -or $null -eq $json.$prop -or $json.$prop -eq '') {
      $json | Add-Member -NotePropertyName $prop -NotePropertyValue $defaults.$prop -Force
    }
  }
  return $json
}

function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
  )
  $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
  Write-Host $line
  try {
    $dir = Split-Path -Parent $script:LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
  } catch {}
}

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

function Request-Elevation {
  if ($NoElevate -or (Test-IsAdmin)) { return }

  Write-Log 'Not elevated. Approve the UAC prompt - an Administrator PowerShell window will open.' 'WARN'
  $parts = @(
    '-NoProfile'
    '-ExecutionPolicy Bypass'
    '-File'
    (Quote-Arg $ScriptPath)
  )
  if ($DeviceName) { $parts += @('-DeviceName', (Quote-Arg $DeviceName)) }
  if ($PSBoundParameters.ContainsKey('PollIntervalSeconds')) {
    $parts += @('-PollIntervalSeconds', "$PollIntervalSeconds")
  }
  if ($Once) { $parts += '-Once' }
  if ($Status) { $parts += '-Status' }
  if ($ForceReconnect) { $parts += '-ForceReconnect' }
  if ($CycleAdapter) { $parts += '-CycleAdapter' }
  if ($CleanupGhosts) { $parts += '-CleanupGhosts' }
  $parts += '-NoElevate'

  $argString = $parts -join ' '
  Write-Log "Elevating with: powershell.exe $argString"
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $ScriptRoot -ArgumentList $argString | Out-Null
  } catch {
    Write-Log "Elevation failed or was cancelled: $($_.Exception.Message)" 'ERROR'
    Write-Host ''
    Write-Host 'Run elevated manually:' -ForegroundColor Yellow
    Write-Host "  cd $(Quote-Arg $ScriptRoot)"
    Write-Host '  .\Watch-BluetoothSpeaker.ps1 -ForceReconnect -Once'
    exit 1
  }
  exit 0
}

function Initialize-WinRT {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
  $script:AsTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
      $_.Name -eq 'AsTask' -and
      $_.IsGenericMethodDefinition -and
      $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } |
    Select-Object -First 1
  if (-not $script:AsTaskMethod) { throw 'Could not find WindowsRuntimeSystemExtensions.AsTask<T>.' }

  [void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
  [void][Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
}

function Await-WinRT {
  param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)][type]$ResultType)
  $task = $script:AsTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  return $task.GetAwaiter().GetResult()
}

function Initialize-NativeHelpers {
  if (-not ('BtAudioKs' -as [type])) {
    if (-not (Test-Path -LiteralPath $CsPath)) { throw "Missing $CsPath" }
    Add-Type -TypeDefinition (Get-Content -LiteralPath $CsPath -Raw) -Language CSharp -ErrorAction Stop
  }

  if (-not ('BtServiceState' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BtServiceState {
  public const uint ENABLE = 1;
  public const uint DISABLE = 0;
  [StructLayout(LayoutKind.Sequential)]
  public struct SYSTEMTIME {
    public ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct BLUETOOTH_DEVICE_INFO {
    public uint dwSize;
    public ulong Address;
    public uint ulClassofDevice;
    [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
    [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
    [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
    public SYSTEMTIME stLastSeen;
    public SYSTEMTIME stLastUsed;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)] public string szName;
  }
  [DllImport("BluetoothAPIs.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern uint BluetoothSetServiceState(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO pbtdi, ref Guid pGuidService, uint dwServiceFlags);
  [DllImport("BluetoothAPIs.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern uint BluetoothGetDeviceInfo(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO pbtdi);
  public static string Set(ulong address, string serviceGuid, bool enable) {
    var info = new BLUETOOTH_DEVICE_INFO();
    info.dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));
    info.Address = address;
    info.szName = "";
    uint gi = BluetoothGetDeviceInfo(IntPtr.Zero, ref info);
    Guid g = new Guid(serviceGuid);
    uint rc = BluetoothSetServiceState(IntPtr.Zero, ref info, ref g, enable ? ENABLE : DISABLE);
    return string.Format("GetInfo={0} connected={1} Set={2} name={3}", gi, info.fConnected, rc, info.szName);
  }
}
'@
  }
}

function Get-BluetoothDeviceByName {
  param([Parameter(Mandatory)][string]$Name)
  $selector = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelector()
  $collection = Await-WinRT `
    -Operation ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) `
    -ResultType ([Windows.Devices.Enumeration.DeviceInformationCollection])

  $match = @($collection | Where-Object { $_.Name -eq $Name })
  if ($match.Count -eq 0) { $match = @($collection | Where-Object { $_.Name -like "*$Name*" }) }
  if ($match.Count -eq 0) {
    $available = ($collection | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
    throw "Bluetooth device '$Name' not found. Paired devices: $available"
  }

  return Await-WinRT `
    -Operation ([Windows.Devices.Bluetooth.BluetoothDevice]::FromIdAsync($match[0].Id)) `
    -ResultType ([Windows.Devices.Bluetooth.BluetoothDevice])
}

function Get-AudioEndpointSnapshot {
  param([Parameter(Mandatory)][string]$Name)
  $endpoints = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*$Name*" })
  $speakersOk = @($endpoints | Where-Object {
      $_.FriendlyName -like 'Speakers*' -and $_.Status -eq 'OK'
    }).Count -gt 0
  $anyOk = @($endpoints | Where-Object { $_.Status -eq 'OK' }).Count -gt 0
  return [pscustomobject]@{
    SpeakersActive = $speakersOk
    AnyActive      = $anyOk
    Endpoints      = ($endpoints | ForEach-Object { "$($_.Status):$($_.FriendlyName)" }) -join ' | '
  }
}

function Get-ConnectionStatus {
  param([Parameter(Mandatory)][string]$Name)
  $bt = Get-BluetoothDeviceByName -Name $Name
  $audio = Get-AudioEndpointSnapshot -Name $Name
  $connected = ($bt.ConnectionStatus.ToString() -eq 'Connected') -or $audio.SpeakersActive
  return [pscustomobject]@{
    Name               = $bt.Name
    ConnectionStatus   = [string]$bt.ConnectionStatus
    Address            = ('{0:X12}' -f $bt.BluetoothAddress)
    DeviceId           = $bt.DeviceId
    SpeakersActive     = $audio.SpeakersActive
    AudioEndpoints     = $audio.Endpoints
    EffectivelyConnected = $connected
  }
}

function Get-BluetoothPnpDevice {
  param([Parameter(Mandatory)][string]$Name)
  $candidates = @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -eq $Name -and $_.InstanceId -like 'BTHENUM\DEV_*' })
  if ($candidates.Count -eq 0) {
    $candidates = @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
      Where-Object { $_.FriendlyName -eq $Name })
  }
  if ($candidates.Count -eq 0) { throw "PnP Bluetooth device '$Name' not found." }
  return $candidates[0]
}

function Get-KsReconnectDeviceIds {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$AddressHex,
    [bool]$IncludeHandsFree = $true
  )

  $selector = 'System.Devices.InterfaceClassGuid:="{6994AD04-93EF-11D0-A3CC-00A0C9223196}"'
  $all = Await-WinRT `
    -Operation ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) `
    -ResultType ([Windows.Devices.Enumeration.DeviceInformationCollection])

  $addr = $AddressHex.ToLowerInvariant()
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($d in $all) {
    $id = [string]$d.Id
    $n = [string]$d.Name
    $idLower = $id.ToLowerInvariant()
    if (-not (($idLower.Contains($addr)) -or ($n -like "*$Name*"))) { continue }
    if (-not $id.StartsWith('\\?\')) { continue }

    # Prefer A2DP \SRC. Skip \SNK (wrong direction). Optionally include HFP \Wave.
    if ($idLower.EndsWith('\snk')) { continue }
    if (-not $IncludeHandsFree -and ($idLower.Contains('bthhfenum') -or $idLower.EndsWith('\wave'))) { continue }
    if ($idLower.EndsWith('\src') -or ($IncludeHandsFree -and $idLower.EndsWith('\wave'))) {
      $ids.Add('{2}.' + $id)
    }
  }

  # Prefer SRC before Wave
  return @($ids | Select-Object -Unique | Sort-Object {
      if ($_ -match '\\SRC$') { 0 } elseif ($_ -match '\\Wave$') { 1 } else { 2 }
    })
}

function Get-LiveAudioEndpointGuids {
  $guids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' } | ForEach-Object {
    if ($_.InstanceId -match '\{([0-9A-Fa-f-]{36})\}$') {
      [void]$guids.Add($Matches[1])
    }
  }
  return $guids
}

function Test-MmDeviceNameMatch {
  param(
    [Parameter(Mandatory)]$PropertyPath,
    [Parameter(Mandatory)][string]$Name
  )
  $props = Get-ItemProperty -LiteralPath $PropertyPath -ErrorAction SilentlyContinue
  if (-not $props) { return $false }
  foreach ($p in $props.PSObject.Properties) {
    if ($p.Name -match '^PS') { continue }
    if ($p.Value -is [string] -and $p.Value -like "*$Name*") { return $true }
  }
  return $false
}

function Remove-GhostAudioDevices {
  param(
    [Parameter(Mandatory)][string]$Name
  )

  if (-not (Test-IsAdmin)) {
    Write-Log 'Ghost cleanup requires elevation; skipped.' 'WARN'
    return
  }

  $live = Get-LiveAudioEndpointGuids
  $removed = 0

  foreach ($flow in @('Render', 'Capture')) {
    $root = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$flow"
    if (-not (Test-Path -LiteralPath $root)) { continue }

    Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
      $guid = $_.PSChildName.Trim('{', '}')
      $state = 0
      try { $state = [int](Get-ItemProperty -LiteralPath $_.PSPath).DeviceState } catch { return }

      $isActive = ($state -band 0x1) -eq 0x1
      if ($isActive) { return }
      if ($live.Contains($guid)) { return }

      $propPath = Join-Path $_.PSPath 'Properties'
      if (-not (Test-MmDeviceNameMatch -PropertyPath $propPath -Name $Name)) { return }

      try {
        Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
        $removed++
        Write-Log ("Removed ghost {0} endpoint {{{1}}} DeviceState=0x{2:X}" -f $flow, $guid, $state)
      } catch {
        Write-Log ("Failed to remove ghost {{{0}}}: {1}" -f $guid, $_.Exception.Message) 'WARN'
      }
    }
  }

  if ($removed -eq 0) {
    Write-Log 'Ghost cleanup: no leftover MMDevice entries found.'
  } else {
    Write-Log "Ghost cleanup: removed $removed leftover MMDevice entr(y/ies)."
  }
}

function Invoke-PnpToggle {
  param(
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][ValidateSet('disable', 'enable')][string]$Action
  )
  $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
  if (Test-Path -LiteralPath $pnputil) {
    $flag = if ($Action -eq 'disable') { '/disable-device' } else { '/enable-device' }
    $out = & $pnputil $flag $InstanceId 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "pnputil $Action failed (exit $LASTEXITCODE): $out" }
    Write-Log ("pnputil {0}: {1}" -f $Action, ($out.Trim() -replace '\s+', ' '))
    return
  }
  if ($Action -eq 'disable') {
    Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
  } else {
    Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
  }
}

function Invoke-BluetoothReconnect {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$DelaySeconds,
    [bool]$AlsoCycleAdapter = $false,
    [bool]$CleanupGhostsAfter = $true,
    [bool]$AllowHfp = $true
  )

  Initialize-NativeHelpers
  $info = Get-ConnectionStatus -Name $Name
  $address = $info.Address
  Write-Log "Reconnect start for '$Name' (addr $address, status $($info.ConnectionStatus), speakersActive=$($info.SpeakersActive))"

  # 1) KS oneshot reconnect - does not reinstall drivers / create ghost endpoints
  try {
    $ksIds = @(Get-KsReconnectDeviceIds -Name $Name -AddressHex $address -IncludeHandsFree:$AllowHfp)
    Write-Log ("KS candidate filters: {0}" -f ($(if ($ksIds.Count) { $ksIds -join ' || ' } else { '(none)' })))
    if ($ksIds.Count -gt 0) {
      $ksResult = [BtAudioKs]::ConnectMany($ksIds)
      foreach ($line in ($ksResult -split "`r?`n")) {
        if ($line) { Write-Log "KS: $line" }
      }
    }
  } catch {
    Write-Log "KS reconnect failed: $($_.Exception.Message)" 'WARN'
  }

  Start-Sleep -Seconds 2
  $afterKs = Get-ConnectionStatus -Name $Name
  if ($afterKs.EffectivelyConnected) {
    Write-Log 'Connected after KS reconnect.'
    if ($CleanupGhostsAfter) { Remove-GhostAudioDevices -Name $Name }
    return
  }

  # 2) ENABLE services only. Never DISABLE - disable/enable reinstalls profiles and
  #    creates ghost Speakers/Headset endpoints in the Windows output picker.
  try {
    $addrUlong = [Convert]::ToUInt64($address, 16)
    $a2dp = '0000110B-0000-1000-8000-00805F9B34FB'
    $hfp = '0000111E-0000-1000-8000-00805F9B34FB'
    Write-Log ("Service enable A2DP (no disable): " + [BtServiceState]::Set($addrUlong, $a2dp, $true))
    if ($AllowHfp) {
      Write-Log ("Service enable HFP (no disable):  " + [BtServiceState]::Set($addrUlong, $hfp, $true))
    } else {
      Write-Log 'Skipping HFP enable (allowHfpReconnect=false).'
    }
  } catch {
    Write-Log "BluetoothSetServiceState failed: $($_.Exception.Message)" 'WARN'
  }

  Start-Sleep -Seconds ([Math]::Max(3, $DelaySeconds))
  $afterSvc = Get-ConnectionStatus -Name $Name
  if ($afterSvc.EffectivelyConnected) {
    Write-Log 'Connected after service enable.'
    if ($CleanupGhostsAfter) { Remove-GhostAudioDevices -Name $Name }
    return
  }

  # 3) PnP disable/enable of the Bluetooth device node (not service reinstall)
  if (-not (Test-IsAdmin)) {
    Write-Log 'Skipping pnputil cycle (not elevated).' 'WARN'
  } else {
    try {
      $pnp = Get-BluetoothPnpDevice -Name $Name
      Write-Log "PnP cycle: $($pnp.InstanceId)"
      Invoke-PnpToggle -InstanceId $pnp.InstanceId -Action disable
      Start-Sleep -Seconds $DelaySeconds
      Invoke-PnpToggle -InstanceId $pnp.InstanceId -Action enable
    } catch {
      Write-Log "PnP cycle failed: $($_.Exception.Message)" 'WARN'
    }
  }

  Start-Sleep -Seconds ([Math]::Max(3, $DelaySeconds))
  $afterPnp = Get-ConnectionStatus -Name $Name
  if ($afterPnp.EffectivelyConnected) {
    Write-Log 'Connected after PnP cycle.'
    if ($CleanupGhostsAfter) { Remove-GhostAudioDevices -Name $Name }
    return
  }

  # 4) Optional adapter cycle (disconnects other BT devices briefly)
  if ($AlsoCycleAdapter -and (Test-IsAdmin)) {
    try {
      $adapter = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'Bluetooth' -and $_.InstanceId -like 'USB\*' } |
        Select-Object -First 1
      if ($adapter) {
        Write-Log "Cycling Bluetooth adapter: $($adapter.FriendlyName)" 'WARN'
        Invoke-PnpToggle -InstanceId $adapter.InstanceId -Action disable
        Start-Sleep -Seconds ([Math]::Max(2, $DelaySeconds))
        Invoke-PnpToggle -InstanceId $adapter.InstanceId -Action enable
        Start-Sleep -Seconds 8
      }
    } catch {
      Write-Log "Adapter cycle failed: $($_.Exception.Message)" 'WARN'
    }
  }

  $final = Get-ConnectionStatus -Name $Name
  Write-Log "Reconnect finished. Status=$($final.ConnectionStatus) SpeakersActive=$($final.SpeakersActive)"
  if ($CleanupGhostsAfter) { Remove-GhostAudioDevices -Name $Name }
  if (-not $final.EffectivelyConnected) {
    Write-Log 'Still disconnected. Check: speaker powered on, in range, not connected to a phone, then try Win+K connect manually.' 'ERROR'
  }
}

function Test-ShouldThrottle {
  param([int]$MaxPerHour)
  $cutoff = (Get-Date).AddHours(-1)
  $script:ReconnectTimes = @($script:ReconnectTimes | Where-Object { $_ -ge $cutoff })
  return ($script:ReconnectTimes.Count -ge $MaxPerHour)
}

function Wait-BeforeExit {
  param([string]$Reason)
  if ($Host.Name -eq 'ConsoleHost') {
    Write-Host ''
    if ($Reason) { Write-Host $Reason -ForegroundColor Yellow }
    Write-Host 'Press Enter to close this window...'
    [void](Read-Host)
  }
}

# --- main ---
try {
  $config = Read-Config
  if (-not $DeviceName) { $DeviceName = [string]$config.deviceName }
  if (-not $PollIntervalSeconds -or $PollIntervalSeconds -le 0) {
    $PollIntervalSeconds = [int]$config.pollIntervalSeconds
  }
  $cooldown = [int]$config.reconnectCooldownSeconds
  $delay = [int]$config.disableEnableDelaySeconds
  $maxPerHour = [int]$config.maxReconnectAttemptsPerHour
  $cleanupOnReconnect = [bool]$config.cleanupGhostsOnReconnect
  $allowHfp = [bool]$config.allowHfpReconnect
  if (-not $CycleAdapter -and $config.cycleAdapter) { $CycleAdapter = $true }
  $script:LogPath = Join-Path $ScriptRoot ([string]$config.logPath)
  $script:ReconnectTimes = @()
  $script:LastReconnectAt = [datetime]::MinValue
  $script:LastStatus = $null

  Initialize-WinRT

  if ($Status) {
    $info = Get-ConnectionStatus -Name $DeviceName
    $info | Format-List
    if (-not $info.EffectivelyConnected) {
      Write-Host 'Hint: if this stays Disconnected, power on the speaker and ensure it is not connected to another device (phone).' -ForegroundColor Yellow
    }
    exit 0
  }

  Request-Elevation
  if (-not (Test-IsAdmin)) {
    throw 'Still not elevated after relaunch. Right-click PowerShell -> Run as administrator, then retry.'
  }

  Write-Log "Running elevated. Device='$DeviceName'"

  # -CleanupGhosts alone (no reconnect): remove leftover MMDevice entries and exit.
  if ($CleanupGhosts -and -not $ForceReconnect) {
    Write-Log "Cleanup-only requested for '$DeviceName'"
    Remove-GhostAudioDevices -Name $DeviceName
    Wait-BeforeExit -Reason 'Ghost cleanup finished.'
    exit 0
  }

  if ($ForceReconnect) {
    Write-Log "Force reconnect requested for '$DeviceName'"
    Invoke-BluetoothReconnect -Name $DeviceName -DelaySeconds $delay -AlsoCycleAdapter:$CycleAdapter -CleanupGhostsAfter:$cleanupOnReconnect -AllowHfp:$allowHfp
    $info = Get-ConnectionStatus -Name $DeviceName
    Write-Log "Status after force reconnect: $($info.ConnectionStatus) SpeakersActive=$($info.SpeakersActive)"
    $ForceReconnect = $false
    if ($Once) {
      Wait-BeforeExit -Reason 'Force reconnect finished.'
      exit 0
    }
  }

  if ($Once) {
    $info = Get-ConnectionStatus -Name $DeviceName
    Write-Log "Status: $($info.ConnectionStatus) SpeakersActive=$($info.SpeakersActive) addr=$($info.Address)"
    if ($info.EffectivelyConnected) {
      Write-Log 'Already connected - nothing to do. Use -ForceReconnect to cycle anyway.'
      if ($CleanupGhosts -or $cleanupOnReconnect) { Remove-GhostAudioDevices -Name $DeviceName }
      Wait-BeforeExit
      exit 0
    }
    Write-Log 'Device not connected - attempting reconnect...' 'WARN'
    Invoke-BluetoothReconnect -Name $DeviceName -DelaySeconds $delay -AlsoCycleAdapter:$CycleAdapter -CleanupGhostsAfter:$cleanupOnReconnect -AllowHfp:$allowHfp
    $after = Get-ConnectionStatus -Name $DeviceName
    Write-Log "Status after reconnect: $($after.ConnectionStatus) SpeakersActive=$($after.SpeakersActive)"
    Wait-BeforeExit
    exit 0
  }

  Write-Log "Watching '$DeviceName' every ${PollIntervalSeconds}s (cooldown ${cooldown}s). Ctrl+C to stop."

  $likeName = $DeviceName.Replace("'", "''")
  $pnpQuery = "SELECT * FROM __InstanceOperationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.Name LIKE '%$likeName%'"
  $pnpWatcher = $null
  try {
    $pnpWatcher = Register-CimIndicationEvent -Query $pnpQuery -SourceIdentifier 'BtPnpWake' -Action {
      New-Event -SourceIdentifier 'BtCheckNow' -MessageData 'pnp' | Out-Null
    } -ErrorAction Stop
    Write-Log 'PnP change watcher registered.'
  } catch {
    Write-Log "PnP watcher unavailable; timer only. ($($_.Exception.Message))" 'WARN'
  }

  try {
    while ($true) {
      try {
        $info = Get-ConnectionStatus -Name $DeviceName
        $statusKey = "$($info.ConnectionStatus)|$($info.SpeakersActive)"
        if ($script:LastStatus -ne $statusKey) {
          Write-Log "Status=$($info.ConnectionStatus) SpeakersActive=$($info.SpeakersActive) addr=$($info.Address)"
          $script:LastStatus = $statusKey
        }

        if (-not $info.EffectivelyConnected) {
          $since = (Get-Date) - $script:LastReconnectAt
          if ($since.TotalSeconds -lt $cooldown) {
            Write-Log ("Disconnected, cooldown ({0:N0}s left)." -f ($cooldown - $since.TotalSeconds)) 'WARN'
          } elseif (Test-ShouldThrottle -MaxPerHour $maxPerHour) {
            Write-Log "Disconnected, hit max reconnects/hour ($maxPerHour)." 'WARN'
          } else {
            Write-Log 'Device not connected - attempting reconnect...' 'WARN'
            Invoke-BluetoothReconnect -Name $DeviceName -DelaySeconds $delay -AlsoCycleAdapter:$CycleAdapter -CleanupGhostsAfter:$cleanupOnReconnect -AllowHfp:$allowHfp
            $script:LastReconnectAt = Get-Date
            $script:ReconnectTimes += $script:LastReconnectAt
          }
        }
      } catch {
        Write-Log $_.Exception.Message 'ERROR'
      }

      $waitUntil = (Get-Date).AddSeconds($PollIntervalSeconds)
      while ((Get-Date) -lt $waitUntil) {
        $evt = Wait-Event -SourceIdentifier 'BtCheckNow' -Timeout 1
        if ($evt) {
          Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
          Write-Log 'PnP change detected - checking now.'
          break
        }
      }
    }
  } finally {
    Unregister-Event -SourceIdentifier 'BtPnpWake' -ErrorAction SilentlyContinue
    Get-EventSubscriber -SourceIdentifier 'BtPnpWake' -ErrorAction SilentlyContinue | Unregister-Event -Force -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier 'BtCheckNow' -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    Write-Log 'Watcher stopped.'
  }
} catch {
  Write-Log $_.Exception.Message 'ERROR'
  Wait-BeforeExit -Reason 'Script failed.'
  exit 1
}
