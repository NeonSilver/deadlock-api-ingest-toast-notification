# Deadlock API Ingest - Toast Notifications (Windows)

Small add-on for the upstream `deadlock-api-ingest` tool.
It adds Windows toast notifications when new matches are uploaded.

Upstream project:
https://github.com/deadlock-api/deadlock-api-ingest

---

## Install

Run:

```powershell
irm https://raw.githubusercontent.com/NeonSilver/deadlock-api-ingest-toast-notification/main/install-custom.ps1 | iex
```

Installer behavior:
- Uses latest release by default when resolving addon script downloads.
- Bootstrap command is fetched from `main`, then script content is resolved from the latest release tag unless overridden.
- Ensures `BurntToast` is installed.
- Temporarily trusts PSGallery only while installing BurntToast, then restores your prior PSGallery policy.
- Ensures upstream `deadlock-api-ingest` is installed.
- Uses a pinned upstream installer commit for reproducible behavior.
- Writes this repo's wrapper scripts to `%LOCALAPPDATA%\deadlock-api-ingest\toast-notification-addon\`.
- Downloads `toast-icon.png` into that addon folder for toast branding.
- Writes `uninstall-custom.ps1` into that same addon folder for local uninstall.
- Attempts to migrate legacy root-level addon files (`seen-match-ids.txt`, `ingest.log`) into that subfolder.
- Patches scheduled task `deadlock-api-ingest` to run the custom wrapper.
- Sets scheduled task logon mode to `Interactive` while wrapper is installed (required for reliable toast banners).
- If scheduled task `deadlock-api-ingest` is missing, installer creates it for the current user.

Install auto-prompts for UAC elevation when needed.

Why UAC is required:
- The script updates the Windows Scheduled Task action (Set-ScheduledTask).
- The script stops/starts the scheduled task and related ingest processes.
- No system-wide app install is performed; elevation is only for task/process management.

If you cancel the UAC prompt, rerun from an Administrator PowerShell window.

---

## Notification behavior

- Toasts are based on successful ingest events parsed from upstream output.
- Toast is sent only after Deadlock is no longer running.
- Seen IDs are deduped using `seen-match-ids.txt`.
- File format is: `<match_id><TAB><local timestamp>`.
- `seen-match-ids.txt` is created lazily on first write (not pre-created at startup).
- Existing files are loaded in backward-compatible form:
  - `57491480`
  - `57491480<TAB>2026-02-11 22:36:28`

Example toast:
- Title: `Deadlock ingest OK`
- Body: `Uploaded N new matches.`
- Icon: custom local icon (`toast-icon.png`) in the addon folder.
  - If missing/corrupted, wrapper auto-generates a fallback icon.

Deadlock process detection defaults:
- `deadlock`
- `project8`
- `deadlock-win64-shipping`

---

## Normal flow

Typical upstream usage flow:
1. Play Deadlock.
2. Close Deadlock.
3. Reopen Deadlock.
4. Open match details from your previous session.

If uploads happen for matches not already in `seen-match-ids.txt`, a toast is shown.

---

## Files

Upstream install root:
`%LOCALAPPDATA%\deadlock-api-ingest\`

Addon subfolder:
`%LOCALAPPDATA%\deadlock-api-ingest\toast-notification-addon\`

Files used by this add-on:
- `ingest-notify.ps1` - wrapper that runs ingest and triggers toasts
- `run-hidden-custom.vbs` - hidden launcher for the wrapper
- `uninstall-custom.ps1` - local uninstall script for this add-on
- `toast-icon.png` - icon used in Windows toast notifications
- `seen-match-ids.txt` - local dedupe list (match ID + timestamp)
- `ingest.log` - optional local log (auto-trimmed)

---

## Uninstall

Remote command:

```powershell
irm https://raw.githubusercontent.com/NeonSilver/deadlock-api-ingest-toast-notification/main/uninstall-custom.ps1 | iex
```

Local command (after install):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\deadlock-api-ingest\toast-notification-addon\uninstall-custom.ps1"
```

Uninstall auto-prompts for UAC elevation when needed for the same scheduled-task and process management operations.

Uninstall behavior:
- Stops the scheduled task and related running ingest processes.
- Restores scheduled task action to upstream `run-hidden.vbs` when available (falls back to upstream executable if needed).
- Attempts to restore upstream-style scheduled task principal (`S4U`) during revert.
- Removes only custom files added by this repo (including legacy root layout files).
- Leaves upstream ingest installed.

---

## Privacy

This add-on does not add new servers or extra data collection.
It only:
- reads local Steam cache files (same as upstream),
- stores a local `seen-match-ids.txt`,
- shows Windows notifications.

---

## License

- Upstream: MIT
- This repo (wrapper scripts): MIT
