# Deadlock API Ingest Toast Notifications (Windows)

This is a small add-on for the upstream `deadlock-api-ingest` tool.
It adds Windows toast notifications when new matches are uploaded.

Upstream project:
https://github.com/deadlock-api/deadlock-api-ingest

## Quick Start (Windows)

1. Open **PowerShell as Administrator**.
2. Run:

```powershell
irm https://raw.githubusercontent.com/NeonSilver/deadlock-api-ingest-toast-notification/main/install-custom.ps1 | iex
```

3. Approve the UAC prompt when asked.

If you cancel UAC, run the same command again from Administrator PowerShell.

## How To Use

Typical flow:
1. Play Deadlock.
2. Close Deadlock.
3. Reopen Deadlock.
4. Open match details from your recent matches.
5. Close Deadlock.

If new matches were uploaded (and not already seen), you should get a Windows toast.

## What You Should See

- Toast title: `Deadlock ingest OK`
- Toast body: `Uploaded N new matches.`
- Toast icon: custom `toast-icon.png` from the add-on folder

## Uninstall

Remote uninstall:

```powershell
irm https://raw.githubusercontent.com/NeonSilver/deadlock-api-ingest-toast-notification/main/uninstall-custom.ps1 | iex
```

Local uninstall (after install):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\deadlock-api-ingest\toast-notification-addon\uninstall-custom.ps1"
```

This removes only this add-on and keeps upstream `deadlock-api-ingest` installed.

## No Toast? Quick Checks

1. Make sure Deadlock is fully closed (toast is deferred while game is running).
2. Check Windows notifications are enabled:
`Settings -> System -> Notifications`
3. Re-run installer command once (repairs wrapper/task wiring).
4. Test toast channel directly:

```powershell
Import-Module BurntToast
New-BurntToastNotification -Text "Direct toast test","If you see this, Windows toast channel is OK."
```

## Why Admin/UAC Is Needed

The installer/uninstaller updates and restarts the Windows Scheduled Task used by ingest.
That task/process management requires elevation.
No separate system-wide app package is installed by this add-on.

## For Advanced Users

### Install behavior

- Bootstrap command is fetched from `main`, then resolves add-on files from the latest release tag by default.
- Ensures `BurntToast` is available.
- Ensures upstream `deadlock-api-ingest` is installed (pinned upstream installer commit).
- Writes add-on files to:
`%LOCALAPPDATA%\deadlock-api-ingest\toast-notification-addon\`
- Patches scheduled task `deadlock-api-ingest` to run `run-hidden-custom.vbs`.
- Uses scheduled task logon type `Interactive` while wrapper is installed (for reliable toast banners).

### Add-on files

- `ingest-notify.ps1` - wrapper that runs ingest and triggers toasts
- `run-hidden-custom.vbs` - hidden launcher for wrapper
- `uninstall-custom.ps1` - local uninstall script
- `toast-icon.png` - toast icon
- `seen-match-ids.txt` - dedupe list (`<match_id><TAB><local timestamp>`)
- `ingest.log` - wrapper log (auto-trimmed)

## Privacy

This add-on does not add extra telemetry or new servers.
It only:
- reads local Steam cache files (same as upstream),
- stores local dedupe state (`seen-match-ids.txt`),
- shows Windows notifications.

## License

- Upstream: MIT
- This repo (wrapper scripts): MIT
