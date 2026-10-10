# autoconnect-bt

Automatically reconnects a paired Bluetooth speaker on Windows when it drops.

The running watcher is `Speaker-Watch.ps1`. It is also what the sign-in scheduled task starts.

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Speaker already paired in Windows Bluetooth settings
- Administrator rights for reconnect

## Quick start

1. Confirm the device name in `config.json` (default is `HK GO + PLAY`).
2. Check status (no admin needed):

```powershell
cd C:\Users\O\repos\autoconnect-bt
.\Speaker-Watch.ps1 -Probe
```

`IsUp` is true only when WinRT reports `Connected` and the `Speakers (...)` endpoint is `OK`.

3. Reconnect once if it is down. Approve the UAC prompt. If it is already up, this leaves it connected:

```powershell
.\Speaker-Watch.ps1 -Once
```

4. Or install it so it starts when you sign in:

```powershell
.\Install-WatcherTask.ps1
```

## Commands

| Command | What it does |
| --- | --- |
| `.\Speaker-Watch.ps1 -Probe` | Print connection status and exit |
| `.\Speaker-Watch.ps1 -Once` | Reconnect once if the speaker is down, then exit |
| `.\Speaker-Watch.ps1` | Watch continuously and reconnect when it drops |
| `.\Speaker-Watch.ps1 -DeviceName "My Speaker"` | Override the device name from config |
| `.\Install-WatcherTask.ps1` | Register the sign-in task and start it |
| `.\Uninstall-WatcherTask.ps1` | Remove the task and stop a running watcher |

## Configuration

Edit `config.json`:

| Key | Meaning |
| --- | --- |
| `deviceName` | Exact (or unique partial) Bluetooth friendly name |
| `pollIntervalSeconds` | How often the running watcher checks status |
| `reconnectCooldownSeconds` | Minimum time between reconnect attempts |
| `disableEnableDelaySeconds` | Wait between disabling and enabling the audio services |
| `maxReconnectAttemptsPerHour` | Safety cap so a missing speaker does not reconnect in a loop |

## Run at sign-in

`Install-WatcherTask.ps1` registers `AutoConnect Bluetooth Speaker` for the current user, elevated. It starts when you sign in. Task Scheduler starts it again every 5 minutes if that process is not already running. While it is running, it checks the speaker on `pollIntervalSeconds`.

Uninstall removes that task, any other task that launches the watcher, and a running watcher process.

Logs are written to `logs\speaker-watch.log`.

## How it works

1. Find the paired device with WinRT and read `BluetoothGetDeviceInfo` (`connected`, `remembered`, `authenticated`, `lastSeen`).
2. Treat it as up only when `ConnectionStatus` is `Connected` and a `Speakers (...)` audio endpoint is `OK`.
3. If it is down, and cooldown and the hourly cap allow it, disable then enable these services:
   - A2DP `0000110B-0000-1000-8000-00805F9B34FB`
   - Hands-Free `0000111E-0000-1000-8000-00805F9B34FB`
4. Wait up to 15 seconds. A service-call return of 0 is not success. Success is the speaker actually being up.
5. If it is still down, log that and wait for the next cooldown. There is no second method.

This disable-then-enable sequence was verified on `HK GO + PLAY` on 2026-10-10, including once from the scheduled task after a manual disconnect.

## What we tried and dropped

These were removed after a live test with the speaker powered on, in range, and not connected to a phone.

- **KS `ONESHOT_RECONNECT`**, the approach used by [ToothTray](https://github.com/m2jean/ToothTray). The repo never contained a ToothTray checkout. The helper lived in `BtAudioConnect.cs`. On the A2DP `\SRC` filter it returned `0x80070492` and the speaker stayed disconnected. The `\SNK` filter could not be activated (`0x80070002`) in earlier logs. That helper is deleted.
- **Enable only**, without a disable first. `BluetoothSetServiceState` returned `87` (`ERROR_INVALID_PARAMETER`) for both A2DP and Hands-Free, and the speaker stayed disconnected.
- **Chained fallbacks** (`pnputil` device restart, Bluetooth adapter power cycle, a PnP event watcher). The event watcher flooded the log. The other fallbacks were added while the speaker was unavailable, so a failed reconnect looked like a software problem. One attempt, then wait, is enough to tell a dropped link from a speaker that is off.
- **The old `Watch-BluetoothSpeaker.ps1` script.** Nothing starts it now. Uninstall still recognizes that filename so a leftover process or task from it can be stopped.

Disable-then-enable can leave an inactive audio-device registry entry. On the verified runs the live Speakers, Hands-Free, and Microphone endpoints stayed the ones Windows was using. One older inactive key, `{2dfdddb8-e1d8-4472-952a-8ba154bde5d9}`, is still present because Windows denied the delete. Do not delete inactive entries while the speaker is disconnected: the real endpoints look inactive in that state.

## Troubleshooting

- **Probe stays disconnected** — power the speaker on, keep it in range, and disconnect it from a phone. `remembered=True` only means Windows has paired it before.
- **`-Once` leaves it connected** — that is what it does when `IsUp` is already true.
- **Still down after one toggle** — the watcher will not try another method until the cooldown passes. Confirm the speaker is actually on before running `-Once` again.
- **Too aggressive** — raise `reconnectCooldownSeconds` or lower `maxReconnectAttemptsPerHour`.
