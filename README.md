# autoconnect-bt

Automatically reconnects a paired Bluetooth speaker on Windows when it drops.

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Speaker already paired in Windows Bluetooth settings
- Administrator rights for reconnect / ghost cleanup

## Quick start

1. Confirm the device name in `config.json` (default is `HK GO + PLAY`).
2. Check status (no admin needed):

```powershell
cd C:\Users\O\repos\autoconnect-bt
.\Watch-BluetoothSpeaker.ps1 -Status
```

3. Force a reconnect once (best first test). Approve the UAC prompt — a **new Administrator PowerShell window** opens and does the work:

```powershell
.\Watch-BluetoothSpeaker.ps1 -ForceReconnect -Once
```

4. Or start the continuous watcher (also elevates into a new window):

```powershell
.\Watch-BluetoothSpeaker.ps1
```

Leave the **Administrator** window open. When the speaker disconnects, the script waits for cooldown, then reconnects.

> Note: `-Once` alone does nothing if the device already reports connected. Use `-ForceReconnect` to cycle it anyway.

## Commands

| Command | What it does |
| --- | --- |
| `.\Watch-BluetoothSpeaker.ps1` | Watch continuously and auto-reconnect |
| `.\Watch-BluetoothSpeaker.ps1 -Status` | Print current connection status and exit |
| `.\Watch-BluetoothSpeaker.ps1 -Once` | Check once, reconnect if needed, exit |
| `.\Watch-BluetoothSpeaker.ps1 -ForceReconnect` | Force a reconnect cycle now |
| `.\Watch-BluetoothSpeaker.ps1 -ForceReconnect -Once` | Force one reconnect, then exit |
| `.\Watch-BluetoothSpeaker.ps1 -CleanupGhosts` | Remove leftover ghost output devices, then exit |
| `.\Watch-BluetoothSpeaker.ps1 -CycleAdapter` | Also bounce the USB Bluetooth adapter (last resort) |
| `.\Watch-BluetoothSpeaker.ps1 -DeviceName "My Speaker"` | Override device name from config |

## Ghost output devices

Earlier reconnect used `BluetoothSetServiceState` **disable → enable**, which reinstalls A2DP/HFP profiles. Windows then leaves behind phantom entries in the output-device picker (duplicate "Speakers (HK GO + PLAY)" / Hands-Free devices).

Current behavior:

- **Never disables** Bluetooth audio services (enable-only)
- Cleans leftover inactive MMDevice registry entries after reconnect (`cleanupGhostsOnReconnect`)
- One-shot cleanup:

```powershell
.\Watch-BluetoothSpeaker.ps1 -CleanupGhosts
```

If the picker is already cluttered, run `-CleanupGhosts` once (elevated), then reopen the sound-output UI.

## Configuration

Edit `config.json`:

| Key | Meaning |
| --- | --- |
| `deviceName` | Exact (or unique partial) Bluetooth friendly name |
| `pollIntervalSeconds` | How often to check connection status |
| `reconnectCooldownSeconds` | Minimum time between reconnect attempts |
| `disableEnableDelaySeconds` | Wait used by PnP/adapter cycles |
| `maxReconnectAttemptsPerHour` | Safety cap to avoid reconnect loops |
| `cycleAdapter` | If true, bounce the Bluetooth radio adapter as last resort |
| `cleanupGhostsOnReconnect` | Remove leftover MMDevice ghosts after reconnect |
| `allowHfpReconnect` | Also try Hands-Free profile enable / KS Wave filter |
| `logPath` | Log file path relative to the repo folder |

## Run at logon (optional)

```powershell
.\Install-WatcherTask.ps1
Start-ScheduledTask -TaskName 'AutoConnect Bluetooth Speaker'
.\Install-WatcherTask.ps1 -Remove
```

## How it works

1. **Detect** — WinRT `ConnectionStatus` plus whether a `Speakers (...)` audio endpoint is active.
2. **Wake early** — CIM PnP events for the device name can trigger a check before the next poll.
3. **Reconnect** (in order):
   1. Core Audio KS `ONESHOT_RECONNECT` (same approach as [ToothTray](https://github.com/m2jean/ToothTray))
   2. `BluetoothSetServiceState` **enable only** for A2DP (and optionally HFP)
   3. `pnputil` disable/enable of the Bluetooth device node
   4. Optional Bluetooth adapter cycle (`-CycleAdapter`)
4. **Cleanup** — remove inactive MMDevice leftovers that are not live endpoints

## Troubleshooting

- **Ghost / duplicate outputs in the sound picker** — run `.\Watch-BluetoothSpeaker.ps1 -CleanupGhosts`. Reconnect no longer uses service disable/enable cycles.
- **Prompt returns immediately after elevation message** — approve UAC; work continues in a new Administrator window.
- **`-Once` did nothing** — normal when already connected. Use `-ForceReconnect -Once`.
- **Still Disconnected after reconnect** — power on speaker, ensure it is not connected to a phone, try `Win + K`, then `-ForceReconnect -Once`. Last resort: add `-CycleAdapter`.
- **Too aggressive** — raise `reconnectCooldownSeconds` or lower `maxReconnectAttemptsPerHour`.

## Logs

Logs are written to `logs\autoconnect-bt.log` by default.
