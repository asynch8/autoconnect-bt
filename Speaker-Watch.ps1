#Requires -Version 5.1
<#
.SYNOPSIS
  Watches a paired Bluetooth speaker and reconnects it when it drops.

.DESCRIPTION
  The reconnect method was verified on HK GO + PLAY: disable then enable the
  A2DP and HFP services. A KS oneshot and an enable-only call did not connect.
  Up means WinRT ConnectionStatus is Connected and the Speakers endpoint is OK.
  Service-call return codes are not treated as success.

.EXAMPLE
  .\Speaker-Watch.ps1 -Probe
  .\Speaker-Watch.ps1 -Once
  .\Speaker-Watch.ps1
#>
[CmdletBinding()]
param(
  [string]$DeviceName,
  [int]$PollIntervalSeconds,
  [switch]$Probe,
  [switch]$Once,
  [switch]$NoElevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$ConfigPath = Join-Path $ScriptRoot 'config.json'
$LogPath = Join-Path $ScriptRoot 'logs\speaker-watch.log'
$ProbePath = Join-Path $ScriptRoot 'logs\speaker-probe.json'
$ResultPath = Join-Path $ScriptRoot 'logs\speaker-try.result.json'

$A2dpGuid = '0000110B-0000-1000-8000-00805F9B34FB'
$HfpGuid = '0000111E-0000-1000-8000-00805F9B34FB'
$SettleSeconds = 15

function Read-Config {
  $defaults = [pscustomobject]@{
    deviceName                  = 'HK GO + PLAY'
    pollIntervalSeconds         = 10
    reconnectCooldownSeconds    = 30
    disableEnableDelaySeconds   = 3
    maxReconnectAttemptsPerHour = 20
  }

  if (-not (Test-Path -LiteralPath $ConfigPath)) { return $defaults }

  $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  foreach ($prop in $defaults.PSObject.Properties.Name) {
    if (-not ($json.PSObject.Properties.Name -contains $prop) -or $null -eq $json.$prop -or "$($json.$prop)" -eq '') {
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
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
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

function Write-AttemptResult {
  param(
    [Parameter(Mandatory)][int]$ExitCode,
    [Parameter(Mandatory)][bool]$Success,
    [string]$Detail,
    $Before,
    $After,
    $Extra
  )
  $payload = [ordered]@{
    exitCode   = $ExitCode
    success    = $Success
    method     = 'Toggle'
    detail     = $Detail
    before     = $Before
    after      = $After
    extra      = $Extra
    finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
  $dir = Split-Path -Parent $ResultPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $json = $payload | ConvertTo-Json -Depth 6
  $tmp = "$ResultPath.tmp"
  Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $ResultPath -Force
}

function Wait-ElevatedResult {
  param([int]$TimeoutSeconds = 180)
  Write-Log 'Approve the UAC prompt. The attempt runs in a new Administrator window.'
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $ResultPath) {
      $raw = Get-Content -LiteralPath $ResultPath -Raw
      Write-Host $raw
      $obj = $raw | ConvertFrom-Json
      exit ([int]$obj.exitCode)
    }
    Start-Sleep -Seconds 1
  }
  throw "Timed out after ${TimeoutSeconds}s waiting for the elevated attempt."
}

function Request-Elevation {
  if ($NoElevate -or (Test-IsAdmin)) { return }

  $parts = @(
    '-NoProfile'
    '-ExecutionPolicy Bypass'
    '-File'
    (Quote-Arg $ScriptPath)
    '-NoElevate'
  )
  if ($Once) { $parts += '-Once' }
  if ($DeviceName) { $parts += @('-DeviceName', (Quote-Arg $DeviceName)) }
  if ($script:ForwardPollInterval) {
    $parts += @('-PollIntervalSeconds', "$PollIntervalSeconds")
  }
  $argString = $parts -join ' '
  Write-Log "Elevating: powershell.exe $argString"

  if ($Once) {
    if (Test-Path -LiteralPath $ResultPath) { Remove-Item -LiteralPath $ResultPath -Force }
    $stale = "$ResultPath.tmp"
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
  }

  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $ScriptRoot -ArgumentList $argString | Out-Null
  } catch {
    throw "Elevation failed or was cancelled: $($_.Exception.Message)"
  }

  if ($Once) { Wait-ElevatedResult }
  Write-Log 'Watcher launched elevated. Leave that Administrator window open. Ctrl+C there stops it.'
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

function Initialize-Native {
  if ('BtSpeakerNative' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BtSpeakerNative {
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

  static BLUETOOTH_DEVICE_INFO InfoFor(ulong address) {
    var info = new BLUETOOTH_DEVICE_INFO();
    info.dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));
    info.Address = address;
    info.szName = "";
    return info;
  }

  static string Time(SYSTEMTIME t) {
    if (t.wYear == 0) return "never";
    return string.Format("{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}",
      t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
  }

  public static string Query(ulong address) {
    var info = InfoFor(address);
    uint rc = BluetoothGetDeviceInfo(IntPtr.Zero, ref info);
    return string.Format("GetInfo={0} connected={1} remembered={2} authenticated={3} lastSeen={4} lastUsed={5} name={6}",
      rc, info.fConnected, info.fRemembered, info.fAuthenticated, Time(info.stLastSeen), Time(info.stLastUsed), info.szName);
  }

  public static string SetService(ulong address, string serviceGuid, bool enable) {
    var info = InfoFor(address);
    uint gi = BluetoothGetDeviceInfo(IntPtr.Zero, ref info);
    Guid g = new Guid(serviceGuid);
    uint rc = BluetoothSetServiceState(IntPtr.Zero, ref info, ref g, enable ? ENABLE : DISABLE);
    string action = enable ? "enable" : "disable";
    return string.Format("{0} {1} GetInfo={2} connected={3} Set={4} name={5}",
      action, serviceGuid, gi, info.fConnected, rc, info.szName);
  }
}
'@
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

function Get-SpeakerStatus {
  param([Parameter(Mandatory)][string]$Name)
  $bt = Get-BluetoothDeviceByName -Name $Name
  $endpoints = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*$Name*" })
  $speakersOk = @($endpoints | Where-Object {
      $_.FriendlyName -like 'Speakers*' -and $_.Status -eq 'OK'
    }).Count -gt 0
  $endpointText = if ($endpoints.Count -eq 0) {
    '(none)'
  } else {
    ($endpoints | ForEach-Object { "$($_.Status):$($_.FriendlyName)" }) -join ' | '
  }
  $connection = [string]$bt.ConnectionStatus
  $address = '{0:X12}' -f $bt.BluetoothAddress

  $deviceInfo = ''
  try {
    Initialize-Native
    $deviceInfo = [BtSpeakerNative]::Query([Convert]::ToUInt64($address, 16))
  } catch {
    $deviceInfo = "QueryFailed: $($_.Exception.Message)"
  }

  return [pscustomobject]@{
    Name             = [string]$bt.Name
    Address          = $address
    DeviceId         = [string]$bt.DeviceId
    ConnectionStatus = $connection
    SpeakersOk       = [bool]$speakersOk
    IsUp             = ($connection -eq 'Connected' -and $speakersOk)
    Endpoints        = $endpointText
    DeviceInfo       = $deviceInfo
  }
}

function Format-StatusText {
  param($Status)
  if (-not $Status) { return '(none)' }
  return ("connection={0} speakersOk={1} isUp={2} endpoints={3} deviceInfo={4}" -f `
      $Status.ConnectionStatus, $Status.SpeakersOk, $Status.IsUp, $Status.Endpoints, $Status.DeviceInfo)
}

function Save-Probe {
  param($Status)
  $dir = Split-Path -Parent $ProbePath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Status | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ProbePath -Encoding UTF8
}

function Wait-SpeakerSettle {
  param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Seconds = $SettleSeconds
  )
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    $info = Get-SpeakerStatus -Name $Name
    if ($info.IsUp) { return $info }
    if ((Get-Date) -ge $deadline) { return $info }
    Start-Sleep -Seconds 1
  } while ($true)
}

function Invoke-Service {
  param(
    [Parameter(Mandatory)][string]$AddressHex,
    [Parameter(Mandatory)][bool]$Enable,
    [Parameter(Mandatory)][string]$GuidValue,
    [Parameter(Mandatory)][string]$Label
  )
  $line = [BtSpeakerNative]::SetService([Convert]::ToUInt64($AddressHex, 16), $GuidValue, $Enable)
  Write-Log "$Label $line"
  return $line
}

function Test-ValueContainsName {
  param($Value, [Parameter(Mandatory)][string]$Name)
  if ($Value -is [string]) { return $Value.IndexOf($Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
  if ($Value -is [byte[]] -and $Value.Length -ge 2) {
    $text = [Text.Encoding]::Unicode.GetString($Value)
    return $text.IndexOf($Name, [StringComparison]::OrdinalIgnoreCase) -ge 0
  }
  return $false
}

function Get-CurrentEndpointGuids {
  param([Parameter(Mandatory)][string]$Name)
  $guids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*$Name*" } |
    ForEach-Object {
      if ($_.InstanceId -match '\{([0-9A-Fa-f-]{36})\}$') {
        [void]$guids.Add($Matches[1])
      }
    }
  return $guids
}

function Initialize-PrivilegeHelper {
  if ('BtPrivilege' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BtPrivilege {
  const uint SE_PRIVILEGE_ENABLED = 0x2;
  const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
  const uint TOKEN_QUERY = 0x8;

  [StructLayout(LayoutKind.Sequential)]
  struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)]
  struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
  [StructLayout(LayoutKind.Sequential)]
  struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }

  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("advapi32.dll", SetLastError = true)]
  static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);
  [DllImport("advapi32.dll", SetLastError = true)]
  static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

  public static void Enable(string privilege) {
    IntPtr token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
      throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    try {
      LUID luid;
      if (!LookupPrivilegeValue(null, privilege, out luid))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      var tp = new TOKEN_PRIVILEGES();
      tp.PrivilegeCount = 1;
      tp.Privileges.Luid = luid;
      tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
      if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      int err = Marshal.GetLastWin32Error();
      if (err == 1300) throw new InvalidOperationException("Privilege is not assigned: " + privilege);
      if (err != 0) throw new System.ComponentModel.Win32Exception(err);
    } finally {
      CloseHandle(token);
    }
  }
}
'@
}

function Unlock-RegistryKey {
  param([Parameter(Mandatory)][string]$SubKey)
  $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry64)
  $admin = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
  $take = [System.Security.AccessControl.RegistryRights]::TakeOwnership
  $key = $base.OpenSubKey($SubKey, $take)
  if (-not $key) { throw "Could not open $SubKey to take ownership." }
  $owner = New-Object System.Security.AccessControl.RegistrySecurity
  $owner.SetOwner($admin)
  $key.SetAccessControl($owner)
  $key.Close()

  $change = [System.Security.AccessControl.RegistryRights]::ChangePermissions
  $key = $base.OpenSubKey($SubKey, $change)
  if (-not $key) { throw "Could not open $SubKey to change permissions." }
  $acl = $key.GetAccessControl()
  $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
    $admin,
    [System.Security.AccessControl.RegistryRights]::FullControl,
    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow)
  $acl.SetAccessRule($rule)
  $key.SetAccessControl($acl)
  $children = @($key.GetSubKeyNames())
  $key.Close()
  foreach ($child in $children) {
    Unlock-RegistryKey -SubKey ($SubKey + '\' + $child)
  }
}

function Remove-LeftoverEndpoints {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Test-IsAdmin)) {
    Write-Log 'Leftover cleanup requires elevation; skipped.' 'WARN'
    return 0
  }

  $current = Get-CurrentEndpointGuids -Name $Name
  $removed = 0
  $failed = 0
  foreach ($flow in @('Render', 'Capture')) {
    $root = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$flow"
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
      $guid = $item.PSChildName.Trim('{', '}')
      $propPath = Join-Path $item.PSPath 'Properties'
      $props = Get-ItemProperty -LiteralPath $propPath -ErrorAction SilentlyContinue
      if (-not $props) { continue }

      $matched = $false
      foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -match '^PS') { continue }
        if (Test-ValueContainsName -Value $p.Value -Name $Name) { $matched = $true; break }
      }
      if (-not $matched) { continue }

      $state = 0
      try { $state = [int](Get-ItemProperty -LiteralPath $item.PSPath).DeviceState } catch { continue }
      $active = ($state -band 0x1) -eq 0x1
      if ($active -or $current.Contains($guid)) { continue }

      try {
        Initialize-PrivilegeHelper
        [BtPrivilege]::Enable('SeTakeOwnershipPrivilege')
        [BtPrivilege]::Enable('SeRestorePrivilege')
        $sub = $item.Name.Substring('HKEY_LOCAL_MACHINE\'.Length)
        Unlock-RegistryKey -SubKey $sub
        Remove-Item -LiteralPath $item.PSPath -Recurse -Force -ErrorAction Stop
        $removed++
        Write-Log ("Removed leftover {0} endpoint {{{1}}} DeviceState=0x{2:X}" -f $flow, $guid, $state)
      } catch {
        $failed++
        Write-Log ("Failed to remove leftover {{{0}}}: {1}" -f $guid, $_.Exception.Message) 'WARN'
      }
    }
  }

  if ($removed -eq 0 -and $failed -eq 0) {
    Write-Log 'Leftover cleanup: no registry-only inactive endpoints.'
  }
  return $removed
}

function Invoke-ToggleReconnect {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$DelaySeconds
  )
  $before = Get-SpeakerStatus -Name $Name
  Write-Log ("Before toggle: {0}" -f (Format-StatusText $before))
  if ($before.IsUp) {
    Write-Log 'Already up. Leaving the speaker connected.'
    return $before
  }

  Initialize-Native
  Invoke-Service -AddressHex $before.Address -Enable $false -GuidValue $A2dpGuid -Label 'A2DP' | Out-Null
  Invoke-Service -AddressHex $before.Address -Enable $false -GuidValue $HfpGuid -Label 'HFP' | Out-Null
  Write-Log "Waiting ${DelaySeconds}s between disable and enable."
  Start-Sleep -Seconds $DelaySeconds
  Invoke-Service -AddressHex $before.Address -Enable $true -GuidValue $A2dpGuid -Label 'A2DP' | Out-Null
  Invoke-Service -AddressHex $before.Address -Enable $true -GuidValue $HfpGuid -Label 'HFP' | Out-Null

  $after = Wait-SpeakerSettle -Name $Name -Seconds $SettleSeconds
  Write-Log ("After toggle: {0}" -f (Format-StatusText $after))
  if ($after.IsUp) {
    $removed = Remove-LeftoverEndpoints -Name $Name
    Write-Log "Connected after toggle. Removed $removed leftover endpoint(s)."
  } else {
    Write-Log 'Still down after toggle. Not trying another method.' 'ERROR'
  }
  return $after
}

function Test-ShouldThrottle {
  param([int]$MaxPerHour)
  $cutoff = (Get-Date).AddHours(-1)
  $kept = New-Object 'System.Collections.Generic.List[datetime]'
  foreach ($t in $script:ReconnectTimes) {
    if ($t -ge $cutoff) { $kept.Add($t) }
  }
  $script:ReconnectTimes = $kept
  return ($kept.Count -ge $MaxPerHour)
}

# --- main ---
try {
  $config = Read-Config
  if (-not $DeviceName) { $DeviceName = [string]$config.deviceName }
  if (-not $DeviceName) { throw 'deviceName is empty.' }
  if (-not $PSBoundParameters.ContainsKey('PollIntervalSeconds') -or $PollIntervalSeconds -le 0) {
    $PollIntervalSeconds = [int]$config.pollIntervalSeconds
  }
  $cooldown = [int]$config.reconnectCooldownSeconds
  $delay = [int]$config.disableEnableDelaySeconds
  $maxPerHour = [int]$config.maxReconnectAttemptsPerHour

  $script:ForwardPollInterval = $PSBoundParameters.ContainsKey('PollIntervalSeconds')
  if ($Probe -and $Once) { throw 'Use either -Probe or -Once, not both.' }

  Initialize-WinRT

  if ($Probe) {
    $info = Get-SpeakerStatus -Name $DeviceName
    Save-Probe -Status $info
    Write-Log ("Probe: {0}" -f (Format-StatusText $info))
    $info | Format-List | Out-String | Write-Host
    exit 0
  }

  Request-Elevation
  if (-not (Test-IsAdmin)) { throw 'Still not elevated. Approve the UAC prompt, or run PowerShell as Administrator.' }

  if ($Once) {
    $before = Get-SpeakerStatus -Name $DeviceName
    if ($before.IsUp) {
      $removed = Remove-LeftoverEndpoints -Name $DeviceName
      $after = Get-SpeakerStatus -Name $DeviceName
      $detail = "Already up. Left connected. Removed $removed leftover endpoint(s)."
      Write-Log $detail
      $code = if ($after.IsUp) { 0 } else { 2 }
      Write-AttemptResult -ExitCode $code -Success $after.IsUp -Detail $detail -Before $before -After $after -Extra @{ removed = $removed }
      exit $code
    }

    Write-Log "Speaker is down. Toggling A2DP and HFP once."
    $after = Invoke-ToggleReconnect -Name $DeviceName -DelaySeconds $delay
    $detail = if ($after.IsUp) { 'Connected after toggle.' } else { 'Still down after toggle.' }
    $code = if ($after.IsUp) { 0 } else { 2 }
    Write-AttemptResult -ExitCode $code -Success $after.IsUp -Detail $detail -Before $before -After $after
    exit $code
  }

  $script:ReconnectTimes = New-Object 'System.Collections.Generic.List[datetime]'
  $script:LastReconnectAt = [datetime]::MinValue
  $script:LastStatus = $null
  Write-Log "Watching '$DeviceName' every ${PollIntervalSeconds}s (cooldown ${cooldown}s, max $maxPerHour/hour). Ctrl+C to stop."

  try {
    while ($true) {
      try {
        $info = Get-SpeakerStatus -Name $DeviceName
        $statusKey = "$($info.ConnectionStatus)|$($info.SpeakersOk)"
        if ($script:LastStatus -ne $statusKey) {
          Write-Log ("Status: {0}" -f (Format-StatusText $info))
          $script:LastStatus = $statusKey
        }

        if (-not $info.IsUp) {
          $since = (Get-Date) - $script:LastReconnectAt
          if ($since.TotalSeconds -lt $cooldown) {
            Write-Log ("Down, cooldown ({0:N0}s left)." -f ($cooldown - $since.TotalSeconds)) 'WARN'
          } elseif (Test-ShouldThrottle -MaxPerHour $maxPerHour) {
            Write-Log "Down, hit max reconnects/hour ($maxPerHour)." 'WARN'
          } else {
            Write-Log 'Speaker is down. Toggling A2DP and HFP once.' 'WARN'
            Invoke-ToggleReconnect -Name $DeviceName -DelaySeconds $delay | Out-Null
            $script:LastReconnectAt = Get-Date
            $script:ReconnectTimes.Add($script:LastReconnectAt)
          }
        }
      } catch {
        Write-Log $_.Exception.Message 'ERROR'
      }

      Start-Sleep -Seconds $PollIntervalSeconds
    }
  } finally {
    Write-Log 'Watcher stopped.'
  }
} catch {
  $message = $_.Exception.Message
  Write-Log $message 'ERROR'
  if ($Once -and (Test-IsAdmin)) {
    try { Write-AttemptResult -ExitCode 1 -Success $false -Detail $message } catch {}
  }
  if (-not $Probe -and -not $Once -and (Test-IsAdmin) -and $Host.Name -eq 'ConsoleHost') {
    Write-Host 'Press Enter to close this window...'
    try { [void](Read-Host) } catch {}
  }
  exit 1
}
