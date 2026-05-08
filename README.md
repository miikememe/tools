# Reset-WindowsUpdate.ps1

A fully automated Windows Update reset and repair script designed for IT administrators and MSPs managing multiple endpoints. Resets all Windows Update components, scans for available updates, downloads and installs them, and notifies the end user if a reboot is required — all with zero user interaction.

---

## The Problem

Windows Update can silently break in a number of ways: stuck downloads, corrupted caches, failed component registrations, stale BITS jobs, or broken WinHTTP proxy settings. When this happens across a fleet of machines, manually troubleshooting each one isn't practical. This script handles the full repair cycle automatically so you can push it to dozens (or hundreds) of endpoints and walk away.

---

## What It Does

The script executes the following steps in order:

### Step 1 — Stop Windows Update Services
Gracefully stops all services involved in the update pipeline:
- `wuauserv` (Windows Update)
- `cryptSvc` (Cryptographic Services)
- `bits` (Background Intelligent Transfer Service)
- `msiserver` (Windows Installer)
- `AppIDSvc` (Application Identity)

Services that are already stopped or not present are skipped without error.

### Step 2 — Clear Update Caches
Renames the following directories with a `.bak_<timestamp>` suffix, forcing Windows to rebuild them from scratch on next scan:
- `C:\Windows\SoftwareDistribution` — stores downloaded update files, the update history database, and scan metadata
- `C:\Windows\System32\catroot2` — stores cryptographic catalog signatures used to verify update packages

If a rename fails due to locked files, the script falls back to clearing the folder contents instead. The original folders are preserved as backups and can be deleted later once updates are confirmed working.

### Step 3 — Clear BITS Transfer Queue
Removes all Background Intelligent Transfer Service jobs across all user contexts. Stale or stuck BITS jobs are a common cause of updates appearing to download but never completing.

### Step 4 — Re-register Windows Update DLLs
Silently re-registers 36 DLLs involved in the Windows Update process using `regsvr32.exe /s`. This repairs broken COM registrations that can prevent the update agent from initializing. DLLs include core components like `wuapi.dll`, `wuaueng.dll`, `bits.dll`, `cryptdlg.dll`, and others.

### Step 5 — Reset Winsock and WinHTTP Proxy
Runs `netsh winsock reset` and `netsh winhttp reset proxy` to clear any corrupted network stack configuration or proxy settings that may be blocking update traffic. This is particularly relevant in environments where proxy configurations have changed or where VPN software has modified network settings.

### Step 6 — Restart Windows Update Services
Starts all services stopped in Step 1. Any services that fail to start are logged as warnings — this can happen if a dependency hasn't fully initialized yet, but typically resolves within seconds as Windows catches up.

### Step 7 — Scan, Download, and Install Updates
This is the core of the automation. Rather than simply triggering a background scan, the script uses the Windows Update Agent COM API to perform a **synchronous** update cycle:

1. **Scan** — Creates an update session and searches for all available updates that are not installed and not hidden. Each discovered update is logged by title.
2. **EULA Acceptance** — Automatically accepts end-user license agreements for all pending updates.
3. **Download** — Downloads all updates that haven't been cached yet. The download result code is logged (2 = Succeeded, 3 = Succeeded with errors).
4. **Install** — Installs all downloaded updates and logs per-update result codes.

If the COM API method fails for any reason, the script falls back to `UsoClient.exe` commands (`StartScan`, `StartDownload`, `StartInstall`) as a secondary mechanism.

### Step 8 — Check Reboot Status
Checks three registry keys that Windows uses to signal a pending reboot:
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending`
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired`
- `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations`

If any of these keys exist, the reboot is logged and the script exits with code `1`.

### Step 9 — User Notification
If a reboot is pending, the script sends a popup message to the currently logged-in user via `msg.exe`:

> *"Updates have been installed on this computer. Please save your work and restart at your earliest convenience."*

The message has an 8-hour timeout and can be dismissed at any time. No reboot is forced — the user retains full control over when to restart.

---

## Logging

All output is written to a timestamped log file at:

```
C:\Logs\WU-Reset_YYYYMMDD_HHMMSS.log
```

Each entry includes a timestamp and severity level (`INFO`, `WARN`, or `ERROR`). Example:

```
[2026-04-28 09:35:07] [INFO] === Windows Update Reset started on PC-HOSTNAME ===
[2026-04-28 09:35:08] [INFO] Stopping Windows Update services...
[2026-04-28 09:35:12] [INFO]   Stopped: wuauserv
[2026-04-28 09:36:46] [INFO]   Scan complete. Found 11 available update(s).
[2026-04-28 09:37:17] [INFO]   Download result code: 2 (2=Succeeded, 3=SucceededWithErrors)
[2026-04-28 09:38:45] [INFO]   Installing 11 update(s)...
[2026-04-28 09:42:03] [WARN] *** REBOOT PENDING on PC-HOSTNAME - schedule at your convenience ***
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0`  | Completed successfully, no reboot required |
| `1`  | Completed successfully, reboot pending (user notified) |

These codes are compatible with most RMM platforms for automated alerting and reporting.

---

## Requirements

- **OS:** Windows 10 / Windows 11 / Windows Server 2016+
- **Privileges:** Must run as Administrator or SYSTEM
- **Dependencies:** None — uses only built-in Windows components
- **Execution Policy:** Use `-ExecutionPolicy Bypass` when calling the script (see below)

---

## Usage

### Direct execution
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Reset-WindowsUpdate.ps1"
```

### Batch wrapper
Create a `.bat` file in the same directory as the script:
```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Reset-WindowsUpdate.ps1"
pause
```

### RMM deployment
Push as a PowerShell script configured to run as SYSTEM. Most RMM agents (ConnectWise Automate, Datto RMM, NinjaOne, etc.) handle execution policy automatically when running scripts through their agent.

### PSExec (remote execution)
```
psexec \\HOSTNAME -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "\\share\Scripts\Reset-WindowsUpdate.ps1"
```

### Group Policy
Deploy as a computer startup script or create a scheduled task via Group Policy Preferences targeting the desired machine OUs.

---

## Runtime

Expect **10–30 minutes** per machine depending on the number and size of available updates. The scan and download phases account for most of the execution time. The script runs entirely in the background with no user-facing windows (except the reboot notification at the end, if applicable).

---

## Important Notes

- **No forced reboot.** The script never restarts the machine automatically. Users are notified and can restart on their own schedule.
- **Caches are backed up, not deleted.** The SoftwareDistribution and catroot2 folders are renamed with a `.bak_<timestamp>` suffix. You can safely delete these backups after confirming updates are working, or leave them — Windows will not use them.
- **File encoding matters.** If you download or copy this script and it throws parse errors about missing closing braces, open it in a text editor and verify the encoding is **UTF-8** (no BOM) with **Windows (CR LF)** line endings. Unix-style LF line endings will cause PowerShell parse failures on Windows.
- **Safe to re-run.** The script is idempotent. Running it multiple times on the same machine will not cause issues — it will simply create new cache folders and re-scan.

---

## License

MIT — use it, modify it, share it.
