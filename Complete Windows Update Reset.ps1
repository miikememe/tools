#Requires -RunAsAdministrator

# ── CONFIG ──
$LogDir  = "$env:SystemDrive\Logs"
$LogFile = Join-Path $LogDir "WU-Reset_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Hostname = $env:COMPUTERNAME

# ── LOGGING ──
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Host $entry
}

Write-Log "=== Windows Update Reset started on $Hostname ==="

# ── STEP 1: STOP SERVICES ──
$services = @('wuauserv', 'cryptSvc', 'bits', 'msiserver', 'AppIDSvc')

Write-Log "Stopping Windows Update services..."
foreach ($svc in $services) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Stopped') {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Log "  Stopped: $svc"
        }
        else {
            Write-Log "  Already stopped or not present: $svc"
        }
    }
    catch {
        Write-Log "  Failed to stop $svc - $($_.Exception.Message)" "WARN"
    }
}

# ── STEP 2: CLEAR CACHES ──
Write-Log "Clearing update caches..."

$sdPath = "$env:SystemRoot\SoftwareDistribution"
$crPath = "$env:SystemRoot\System32\catroot2"
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

foreach ($folder in @($sdPath, $crPath)) {
    if (Test-Path $folder) {
        $backup = "${folder}.bak_${timestamp}"
        try {
            Rename-Item -Path $folder -NewName $backup -Force -ErrorAction Stop
            Write-Log "  Renamed $folder -> $backup"
        }
        catch {
            Write-Log "  Rename failed for $folder, clearing contents..." "WARN"
            try {
                Get-ChildItem -Path $folder -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "  Cleared contents of $folder"
            }
            catch {
                Write-Log "  Could not clear $folder - $($_.Exception.Message)" "ERROR"
            }
        }
    }
}

# ── STEP 3: CLEAR BITS QUEUE ──
Write-Log "Clearing BITS transfer queue..."
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Write-Log "  BITS queue cleared."
}
catch {
    Write-Log "  BITS clear skipped - $($_.Exception.Message)" "WARN"
}

# ── STEP 4: RE-REGISTER WU DLLs ──
Write-Log "Re-registering Windows Update DLLs..."
$dlls = @(
    'atl.dll', 'urlmon.dll', 'mshtml.dll', 'shdocvw.dll', 'browseui.dll',
    'jscript.dll', 'vbscript.dll', 'scrrun.dll', 'msxml.dll', 'msxml3.dll',
    'msxml6.dll', 'actxprxy.dll', 'softpub.dll', 'wintrust.dll', 'dssenh.dll',
    'rsaenh.dll', 'gpkcsp.dll', 'sccbase.dll', 'slbcsp.dll', 'cryptdlg.dll',
    'oleaut32.dll', 'ole32.dll', 'shell32.dll', 'initpki.dll', 'wuapi.dll',
    'wuaueng.dll', 'wuaueng1.dll', 'wucltui.dll', 'wups.dll', 'wups2.dll',
    'wuweb.dll', 'qmgr.dll', 'qmgrprxy.dll', 'wucltux.dll', 'muweb.dll',
    'wuwebv.dll'
)

$regCount = 0
foreach ($dll in $dlls) {
    & regsvr32.exe /s $dll 2>&1 | Out-Null
    $regCount++
}
Write-Log "  Registered $regCount DLLs."

# ── STEP 5: RESET WINSOCK & PROXY ──
Write-Log "Resetting Winsock and WinHTTP proxy..."
try {
    & netsh winsock reset 2>&1 | Out-Null
    & netsh winhttp reset proxy 2>&1 | Out-Null
    Write-Log "  Winsock and proxy reset complete."
}
catch {
    Write-Log "  Winsock/proxy reset issue - $($_.Exception.Message)" "WARN"
}

# ── STEP 6: RESTART SERVICES ──
Write-Log "Starting Windows Update services..."
foreach ($svc in $services) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Start-Service -Name $svc -ErrorAction Stop
            Write-Log "  Started: $svc"
        }
    }
    catch {
        Write-Log "  Failed to start $svc - $($_.Exception.Message)" "WARN"
    }
}

# ── STEP 7: SCAN, DOWNLOAD, AND INSTALL UPDATES ──
Write-Log "Running synchronous update scan (this may take several minutes)..."

try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searchResult = $searcher.Search("IsInstalled=0 AND IsHidden=0")

    $updateCount = $searchResult.Updates.Count
    Write-Log "  Scan complete. Found $updateCount available update(s)."

    if ($updateCount -gt 0) {
        # Log what was found
        for ($i = 0; $i -lt $updateCount; $i++) {
            $u = $searchResult.Updates.Item($i)
            Write-Log "  [$($i+1)] $($u.Title)"
        }

        # Build collection of updates to download
        $updatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $updateCount; $i++) {
            $u = $searchResult.Updates.Item($i)
            if (-not $u.IsDownloaded) {
                # Accept EULA silently
                if ($u.EulaAccepted -eq $false) {
                    $u.AcceptEula()
                }
                $updatesToDownload.Add($u) | Out-Null
            }
        }

        if ($updatesToDownload.Count -gt 0) {
            Write-Log "  Downloading $($updatesToDownload.Count) update(s)..."
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $updatesToDownload
            $dlResult = $downloader.Download()
            Write-Log "  Download result code: $($dlResult.ResultCode) (2=Succeeded, 3=SucceededWithErrors)"
        }
        else {
            Write-Log "  All updates already downloaded."
        }

        # Build collection of updates to install
        $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $updateCount; $i++) {
            $u = $searchResult.Updates.Item($i)
            if ($u.IsDownloaded) {
                $updatesToInstall.Add($u) | Out-Null
            }
        }

        if ($updatesToInstall.Count -gt 0) {
            Write-Log "  Installing $($updatesToInstall.Count) update(s)..."
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $updatesToInstall
            $installResult = $installer.Install()
            Write-Log "  Install result code: $($installResult.ResultCode) (2=Succeeded, 3=SucceededWithErrors)"

            # Log per-update results
            for ($i = 0; $i -lt $updatesToInstall.Count; $i++) {
                $uResult = $installResult.GetUpdateResult($i)
                $uTitle = $updatesToInstall.Item($i).Title
                Write-Log "    $uTitle -> ResultCode: $($uResult.ResultCode)"
            }
        }
        else {
            Write-Log "  No downloaded updates ready to install." "WARN"
        }
    }
    else {
        Write-Log "  System is up to date."
    }
}
catch {
    Write-Log "  Update scan/install failed - $($_.Exception.Message)" "ERROR"
    Write-Log "  Falling back to UsoClient..."
    $usoPath = "$env:SystemRoot\System32\UsoClient.exe"
    if (Test-Path $usoPath) {
        & $usoPath StartScan 2>&1 | Out-Null
        & $usoPath StartDownload 2>&1 | Out-Null
        & $usoPath StartInstall 2>&1 | Out-Null
        Write-Log "  UsoClient scan/download/install triggered."
    }
}

# ── STEP 8: CHECK REBOOT STATUS ──
Write-Log "Checking pending reboot status..."
$rebootPending = $false

$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
)

foreach ($key in $rebootKeys) {
    if (Test-Path $key) {
        $rebootPending = $true
        Write-Log "  Reboot indicator found: $key"
    }
}

if ($rebootPending) {
    Write-Log "*** REBOOT PENDING on $Hostname - schedule at your convenience ***" "WARN"

    # Show a non-blocking toast notification to the logged-in user
    try {
        $msgTitle = "Windows Updates Installed"
        $msgBody = "Updates have been installed on this computer. Please save your work and restart at your earliest convenience."

        # Use msg.exe to notify the console user (works as SYSTEM)
        & msg.exe * /TIME:28800 "$msgBody" 2>&1 | Out-Null
        Write-Log "  Reboot notification sent to user via msg.exe."
    }
    catch {
        Write-Log "  Could not send user notification - $($_.Exception.Message)" "WARN"
    }
}
else {
    Write-Log "  No reboot pending."
}

# ── SUMMARY ──
Write-Log "=== Windows Update Reset completed on $Hostname ==="
Write-Log "Log saved to: $LogFile"

if ($rebootPending) { exit 1 } else { exit 0 }
