#requires -Version 5.1
$ErrorActionPreference = "Stop"

$RepoOwner = "NeonSilver"
$RepoName = "deadlock-api-ingest-toast-notification"
$RepoDefaultRef = "main"
$RepoRef = $null

$TaskName = "deadlock-api-ingest"
$InstallDir = Join-Path $env:LOCALAPPDATA "deadlock-api-ingest"
$UninstallScriptUrl = $null
$CustomSubDirName = "toast-notification-addon"
$CustomDir = Join-Path $InstallDir $CustomSubDirName

$CustomVbs = Join-Path $CustomDir "run-hidden-custom.vbs"
$CustomPs1 = Join-Path $CustomDir "ingest-notify.ps1"
$CustomUninstall = Join-Path $CustomDir "uninstall-custom.ps1"
$CustomIcon = Join-Path $CustomDir "toast-icon.png"
$SeenFile  = Join-Path $CustomDir "seen-match-ids.txt"
$LogFile   = Join-Path $CustomDir "ingest.log"

$LegacyCustomVbs = Join-Path $InstallDir "run-hidden-custom.vbs"
$LegacyCustomPs1 = Join-Path $InstallDir "ingest-notify.ps1"
$LegacyCustomUninstall = Join-Path $InstallDir "uninstall-custom.ps1"
$LegacyCustomIcon = Join-Path $InstallDir "toast-icon.png"
$LegacySeenFile  = Join-Path $InstallDir "seen-match-ids.txt"
$LegacyLogFile   = Join-Path $InstallDir "ingest.log"

$UpstreamVbs = Join-Path $InstallDir "run-hidden.vbs"
$CurrentScriptPath = $PSCommandPath
if (-not $CurrentScriptPath) { $CurrentScriptPath = $MyInvocation.MyCommand.Path }
try {
  if ($CurrentScriptPath) {
    $CurrentScriptPath = (Resolve-Path -LiteralPath $CurrentScriptPath -ErrorAction Stop).Path
  }
} catch {}

function Ensure-Tls12 {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol } catch {}
}

function Get-CurrentUserId {
  try { return [Security.Principal.WindowsIdentity]::GetCurrent().Name }
  catch {
    if ($env:USERDOMAIN -and $env:USERNAME) { return "$env:USERDOMAIN\$env:USERNAME" }
    return $env:USERNAME
  }
}

function Resolve-RepoRef {
  if ($env:DEADLOCK_TOAST_REPO_REF) {
    $requested = $env:DEADLOCK_TOAST_REPO_REF.Trim()
    if ($requested) { return $requested }
  }

  Ensure-Tls12
  $latestReleaseApi = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"

  try {
    $release = Invoke-RestMethod -Uri $latestReleaseApi -Method Get -ErrorAction Stop
    $tag = [string]$release.tag_name
    if ($tag -and $tag.Trim()) { return $tag.Trim() }
  } catch {
    Write-Warning "Failed to resolve latest release tag from GitHub. Falling back to '$RepoDefaultRef'. Error: $($_.Exception.Message)"
  }

  return $RepoDefaultRef
}

function Test-IsAdministrator {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Relaunch-ElevatedIfNeeded([string]$scriptPath, [string]$fallbackUrl) {
  if (Test-IsAdministrator) { return }

  Write-Host "Administrator privileges are required. Requesting elevation..." -ForegroundColor Yellow

  $payload =
    if ($scriptPath -and (Test-Path $scriptPath)) {
      $escapedPath = $scriptPath.Replace("'", "''")
      "& '$escapedPath'"
    }
    else {
      $escapedUrl = $fallbackUrl.Replace("'", "''")
      "irm '$escapedUrl' | iex"
    }

  try {
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($payload)
    $encoded = [Convert]::ToBase64String($bytes)
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" | Out-Null
    exit 0
  } catch {
    throw "This uninstaller requires Administrator privileges. Please run PowerShell as Administrator. Error: $($_.Exception.Message)"
  }
}

function Stop-IngestProcesses {
  # Stop the scheduled task first so it doesn't respawn the process while we kill it
  try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null } catch {}

  # Only target processes that are clearly part of THIS toolchain (safe!)
  $dirEsc = [Regex]::Escape($InstallDir)
  $subEsc = [Regex]::Escape($CustomSubDirName)
  $rx = "(?i)$dirEsc\\(?:$subEsc\\)?(ingest-notify\.ps1|run-hidden-custom\.vbs|run-hidden\.vbs|deadlock-api-ingest\.exe)\b"

  try {
    Get-CimInstance Win32_Process |
      Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match $rx -and
        ($_.Name -ieq "wscript.exe" -or $_.Name -ieq "powershell.exe" -or $_.Name -ieq "deadlock-api-ingest.exe")
      } |
      ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
      }
  } catch {}
}

function Remove-DirectoryIfEmpty([string]$path) {
  try {
    if (-not (Test-Path $path)) { return }
    $hasItems = Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hasItems) {
      Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

function Start-PostExitCleanup([string]$selfPath, [string]$dirPath) {
  try {
    if (-not $selfPath) { return }
    if (-not (Test-Path $selfPath)) { return }

    $escapedSelf = $selfPath.Replace("'", "''")
    $escapedDir  = $dirPath.Replace("'", "''")
    $cleanupScript = @"
Start-Sleep -Milliseconds 1200
try { Remove-Item -LiteralPath '$escapedSelf' -Force -ErrorAction SilentlyContinue } catch {}
try {
  if (Test-Path '$escapedDir') {
    `$hasItems = Get-ChildItem -Path '$escapedDir' -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not `$hasItems) { Remove-Item -Path '$escapedDir' -Force -ErrorAction SilentlyContinue }
  }
} catch {}
"@

    $cleanupBytes = [System.Text.Encoding]::Unicode.GetBytes($cleanupScript)
    $cleanupEncoded = [Convert]::ToBase64String($cleanupBytes)
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $cleanupEncoded" | Out-Null
  } catch {}
}

$RepoRef = Resolve-RepoRef
$cacheBust =
  if ($RepoRef -ieq "main") { "?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }
  else { "" }
$UninstallScriptUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoRef/uninstall-custom.ps1$cacheBust"
Write-Host "Using wrapper source ref: $RepoRef" -ForegroundColor DarkGray
Relaunch-ElevatedIfNeeded -scriptPath $CurrentScriptPath -fallbackUrl $UninstallScriptUrl

Write-Host "Reverting scheduled task back to upstream..." -ForegroundColor Cyan

Stop-IngestProcesses

# Repoint task to upstream action when possible, but continue cleanup regardless.
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  $reverted = $false
  $userId = Get-CurrentUserId
  $upstreamPrincipal = $null
  if ($userId) {
    try {
      # Upstream uses S4U for background execution.
      $upstreamPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    } catch {}
  }

  if (Test-Path $UpstreamVbs) {
    try {
      $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$UpstreamVbs`"" -WorkingDirectory $InstallDir
      if ($upstreamPrincipal) {
        Set-ScheduledTask -TaskName $TaskName -Action $action -Principal $upstreamPrincipal | Out-Null
      } else {
        Set-ScheduledTask -TaskName $TaskName -Action $action | Out-Null
      }
      Write-Host "Scheduled Task reverted to upstream run-hidden.vbs" -ForegroundColor Green
      $reverted = $true
    } catch {
      Write-Warning "Failed to repoint task to upstream run-hidden.vbs. Error: $($_.Exception.Message)"
    }
  } else {
    Write-Warning "Upstream run-hidden.vbs not found at '$UpstreamVbs'."
  }

  if (-not $reverted) {
    $upstreamExe = Join-Path $InstallDir "deadlock-api-ingest.exe"
    if (Test-Path $upstreamExe) {
      try {
        $fallbackAction = New-ScheduledTaskAction -Execute $upstreamExe -WorkingDirectory $InstallDir
        if ($upstreamPrincipal) {
          Set-ScheduledTask -TaskName $TaskName -Action $fallbackAction -Principal $upstreamPrincipal | Out-Null
        } else {
          Set-ScheduledTask -TaskName $TaskName -Action $fallbackAction | Out-Null
        }
        Write-Host "Scheduled Task reverted to upstream executable fallback." -ForegroundColor Yellow
      } catch {
        Write-Warning "Failed to set scheduled task fallback action. Error: $($_.Exception.Message)"
      }
    } else {
      Write-Warning "Upstream executable not found at '$upstreamExe'; leaving scheduled task action unchanged."
    }
  }
} else {
  Write-Warning "Scheduled Task '$TaskName' not found. Continuing cleanup."
}

# Remove custom files
foreach ($f in @($CustomVbs, $CustomPs1, $CustomUninstall, $CustomIcon, $SeenFile, $LogFile, $LegacyCustomVbs, $LegacyCustomPs1, $LegacyCustomUninstall, $LegacyCustomIcon, $LegacySeenFile, $LegacyLogFile)) {
  try {
    if (Test-Path $f) { Remove-Item -Path $f -Force -ErrorAction Stop }
  } catch {
    $isCurrentScript =
      ($CurrentScriptPath -and
      [string]::Equals($CurrentScriptPath, $f, [System.StringComparison]::OrdinalIgnoreCase))

    if (-not $isCurrentScript) {
      Write-Warning "Failed to remove custom file '$f'. Error: $($_.Exception.Message)"
    }
  }
}

Remove-DirectoryIfEmpty -path $CustomDir

# Start upstream runner immediately after revert (optional but recommended)
try {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
  }
} catch {}

# Best-effort deferred cleanup for uninstall script + addon folder.
# - Local uninstall run: current script is inside addon folder (in-use while running).
# - Remote uninstall run: local uninstall file may still be locked transiently.
$cleanupTarget = $null
if ($CurrentScriptPath) {
  $customPrefix = ($CustomDir.TrimEnd('\') + '\')
  if ($CurrentScriptPath.StartsWith($customPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    $cleanupTarget = $CurrentScriptPath
  }
}
if (-not $cleanupTarget -and (Test-Path $CustomUninstall)) {
  $cleanupTarget = $CustomUninstall
}
if ($cleanupTarget) {
  Start-PostExitCleanup -selfPath $cleanupTarget -dirPath $CustomDir
}

Write-Host "Done." -ForegroundColor Green


