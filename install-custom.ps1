#requires -Version 5.1
$ErrorActionPreference = "Stop"

# ==============================================================================
# CONFIG — MOST LIKELY TO CHANGE
# ==============================================================================
$RepoOwner = "NeonSilver"
$RepoName = "deadlock-api-ingest-toast-notification"
$RepoDefaultRef = "main"
$RepoRef = $null
$RepoRawBase = $null
$InstallScriptUrl = $null

$TaskName   = "deadlock-api-ingest"
$InstallDir = Join-Path $env:LOCALAPPDATA "deadlock-api-ingest"
$CustomSubDirName = "toast-notification-addon"
$CustomDir = Join-Path $InstallDir $CustomSubDirName

# Custom filenames (never overwritten by upstream)
$CustomVbsName = "run-hidden-custom.vbs"
$CustomPs1Name = "ingest-notify.ps1"
$CustomUninstallName = "uninstall-custom.ps1"
$ToastIconName = "toast-icon.png"

# Download URLs are resolved from the selected ref in main.
$IngestNotifyUrl = $null
$CustomUninstallUrl = $null
$ToastIconUrl = $null

# Upstream installer (interactive; asks Y/N for auto-update options).
# Pinning commit keeps behavior reproducible across wrapper releases.
$UpstreamInstallCommit = "537a64c507c7588dd254484125d20b09077fd27b"
$UpstreamInstallUrl = "https://raw.githubusercontent.com/deadlock-api/deadlock-api-ingest/$UpstreamInstallCommit/install-windows.ps1"

function Test-IsAdministrator {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Relaunch-ElevatedIfNeeded([string]$fallbackUrl) {
  if (Test-IsAdministrator) { return }

  Write-Host "Administrator privileges are required. Requesting elevation..." -ForegroundColor Yellow

  $scriptPath = $PSCommandPath
  if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

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
    throw "This installer requires Administrator privileges. Please run PowerShell as Administrator. Error: $($_.Exception.Message)"
  }
}

# ==============================================================================
# Helpers
# ==============================================================================
function Assert-Windows {
  if ($env:OS -notlike "*Windows*") { throw "This installer is intended for Windows." }
}

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

function Update-DependencyProgress([string]$status, [int]$percent) {
  Write-Progress -Id 1 -Activity "Preparing notification dependencies" -Status $status -PercentComplete $percent
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

function Ensure-PsGalleryAndNuGet {
  Ensure-Tls12

  Update-DependencyProgress -status "Checking NuGet provider" -percent 5
  try {
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
      Write-Host "NuGet provider not found. Installing..." -ForegroundColor Yellow
      Update-DependencyProgress -status "Installing NuGet provider (can take up to ~1 minute)" -percent 20
      $nugetTimer = [System.Diagnostics.Stopwatch]::StartNew()
      Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
      $nugetTimer.Stop()
      Write-Host ("NuGet provider installed in {0:N1}s" -f $nugetTimer.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    }
  } catch {
    throw "Failed to install NuGet package provider. Error: $($_.Exception.Message)"
  }

  Update-DependencyProgress -status "Checking PSGallery repository" -percent 45
  try {
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $repo) {
      Write-Host "PSGallery repository not found. Registering..." -ForegroundColor Yellow
      Update-DependencyProgress -status "Registering PSGallery repository" -percent 60
      Register-PSRepository -Default -ErrorAction Stop
    }
  } catch {
    throw "Failed to register PSGallery. Error: $($_.Exception.Message)"
  }

  Update-DependencyProgress -status "NuGet and PSGallery ready" -percent 70
}

function Ensure-BurntToast {
  Update-DependencyProgress -status "Preparing BurntToast module" -percent 72
  Ensure-PsGalleryAndNuGet

  $installed = Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue
  if (-not $installed) {
    $originalPolicy = $null
    $restorePolicy = $false
    try {
      $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
      $originalPolicy = $repo.InstallationPolicy

      # Avoid permanent global side-effects: trust PSGallery only for this install.
      if ($originalPolicy -ne "Trusted") {
        Update-DependencyProgress -status "Temporarily trusting PSGallery" -percent 76
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        $restorePolicy = $true
      }

      Write-Host "BurntToast module not found. Installing (this can take 1-3 minutes)..." -ForegroundColor Yellow
      Update-DependencyProgress -status "Installing BurntToast module from PSGallery" -percent 82
      $burntToastTimer = [System.Diagnostics.Stopwatch]::StartNew()
      Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop | Out-Null
      $burntToastTimer.Stop()
      Write-Host ("BurntToast installed in {0:N1}s" -f $burntToastTimer.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    } catch {
      throw "Failed to install BurntToast from PSGallery. Error: $($_.Exception.Message)"
    } finally {
      if ($restorePolicy -and $originalPolicy) {
        try {
          Set-PSRepository -Name PSGallery -InstallationPolicy $originalPolicy -ErrorAction Stop
        } catch {
          Write-Warning "BurntToast installed, but failed to restore PSGallery policy to '$originalPolicy'. Error: $($_.Exception.Message)"
        }
      }
    }
  }

  Update-DependencyProgress -status "Importing BurntToast module" -percent 95
  try { Import-Module BurntToast -ErrorAction Stop } catch {
    throw "BurntToast is installed but failed to import. Error: $($_.Exception.Message)"
  }

  Write-Progress -Id 1 -Activity "Preparing notification dependencies" -Completed
}

function Stop-IngestProcesses {
  # Stop the scheduled task first so it doesn't respawn while we kill it
  try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null } catch {}

  # Only target processes clearly tied to THIS install dir (safe!)
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

function Ensure-UpstreamInstalled {
  $exe = Join-Path $InstallDir "deadlock-api-ingest.exe"
  if (Test-Path $exe) { return }

  Write-Host "Upstream deadlock-api-ingest.exe not found. Running upstream installer..." -ForegroundColor Yellow
  Write-Host "NOTE: Upstream installer is interactive (auto-update prompts)." -ForegroundColor Yellow
  Write-Host "Using pinned upstream commit: $UpstreamInstallCommit" -ForegroundColor DarkGray

  # Run upstream installer in a child PowerShell process in this same console.
  # This avoids upstream `exit` calls terminating this wrapper.
  try {
    Write-Host "Launching upstream installer in this console..." -ForegroundColor Yellow
    Write-Host "Follow upstream prompts (Statlocker/auto-start). Wrapper install is NOT finished until this window prints Done." -ForegroundColor Yellow
    # Set CI=true in child process so upstream skips its final 'Press any key' pause.
    $payload = "`$env:CI='true'; irm '$UpstreamInstallUrl' | iex"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($payload)
    $encoded = [Convert]::ToBase64String($bytes)

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
    $upstreamExitCode = $LASTEXITCODE

    if ($upstreamExitCode -ne 0) {
      if (Test-Path $exe) {
        Write-Warning "Upstream installer exited with code $upstreamExitCode, but executable is present. Continuing with wrapper install."
      } else {
        throw "Upstream installer exited with code $upstreamExitCode."
      }
    }
  } catch {
    throw "Failed to run upstream installer from pinned commit $UpstreamInstallCommit. Error: $($_.Exception.Message)"
  }

  if (-not (Test-Path $exe)) {
    throw "Upstream install did not produce: $exe"
  }
}

function Write-FileUtf8NoBom([string]$path, [string]$content) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
}

function Download-Text([string]$url) {
  Ensure-Tls12
  try {
    $text = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
    if (-not $text -or -not ($text -is [string])) {
      throw "Unexpected response type."
    }
    return $text
  } catch {
    throw "Failed to download: $url`nError: $($_.Exception.Message)"
  }
}

function Download-File([string]$url, [string]$destinationPath) {
  Ensure-Tls12
  $dir = Split-Path -Parent $destinationPath
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
  }

  try {
    Invoke-WebRequest -Uri $url -OutFile $destinationPath -UseBasicParsing -ErrorAction Stop
  } catch {
    throw "Failed to download file: $url`nDestination: $destinationPath`nError: $($_.Exception.Message)"
  }
}

function Move-LegacyFileIfPresent([string]$legacyPath, [string]$targetPath) {
  try {
    if (-not (Test-Path $legacyPath)) { return }

    $targetDir = Split-Path -Parent $targetPath
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }

    if (Test-Path $targetPath) {
      try {
        Remove-Item -Path $legacyPath -Force -ErrorAction Stop
      } catch {
        Write-Warning "Failed to remove legacy file '$legacyPath' after migration conflict. Error: $($_.Exception.Message)"
      }
      return
    }

    try {
      Move-Item -Path $legacyPath -Destination $targetPath -Force -ErrorAction Stop
      return
    } catch {
      Write-Warning "Move failed for legacy file '$legacyPath' -> '$targetPath'. Trying copy+remove fallback. Error: $($_.Exception.Message)"
    }

    # Fallback: copy first, then remove if possible (helps when rename is temporarily blocked).
    Copy-Item -Path $legacyPath -Destination $targetPath -Force -ErrorAction Stop
    try {
      Remove-Item -Path $legacyPath -Force -ErrorAction Stop
    } catch {
      Write-Warning "Copied legacy file to '$targetPath', but could not remove original '$legacyPath'. Error: $($_.Exception.Message)"
    }
  } catch {
    Write-Warning "Failed to migrate legacy file '$legacyPath' -> '$targetPath'. Error: $($_.Exception.Message)"
  }
}

function Patch-ScheduledTaskToCustomVbs {
  $customVbsPath = Join-Path $CustomDir $CustomVbsName

  $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$customVbsPath`"" -WorkingDirectory $CustomDir
  $userId = Get-CurrentUserId
  if (-not $userId) { throw "Unable to determine current user for scheduled task configuration." }
  # Interactive logon is required for reliable toast banners in the user session.
  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal | Out-Null
    return
  }

  Write-Warning "Scheduled Task '$TaskName' not found. Creating it for the current user."

  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Runs deadlock-api-ingest with toast notification wrapper." `
    | Out-Null
}

# ==============================================================================
# Embedded VBS (tiny + stable)
# ==============================================================================
$RunHiddenCustomVbs = @'
Set WshShell = CreateObject("WScript.Shell")

args = ""
For Each arg In WScript.Arguments
  args = args & " " & arg
Next

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
      """" & CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\ingest-notify.ps1" & """" & args

WshShell.Run cmd, 0, False
'@

# ==============================================================================
# Main
# ==============================================================================
Assert-Windows

$RepoRef = Resolve-RepoRef
$RepoRawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoRef"
$cacheBust =
  if ($RepoRef -ieq "main") { "?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }
  else { "" }
$InstallScriptUrl = "$RepoRawBase/install-custom.ps1$cacheBust"
$IngestNotifyUrl = "$RepoRawBase/$CustomPs1Name$cacheBust"
$CustomUninstallUrl = "$RepoRawBase/$CustomUninstallName$cacheBust"
$ToastIconUrl = "$RepoRawBase/$ToastIconName$cacheBust"

Write-Host "Using wrapper source ref: $RepoRef" -ForegroundColor DarkGray
Relaunch-ElevatedIfNeeded -fallbackUrl $InstallScriptUrl

Write-Host "Installing/repairing custom notifications..." -ForegroundColor Cyan
Write-Host "Do not close this window until you see: Done." -ForegroundColor Yellow

Ensure-BurntToast
Write-Host "BurntToast OK" -ForegroundColor Green

Ensure-UpstreamInstalled
Write-Host "Upstream ingest OK" -ForegroundColor Green

Stop-IngestProcesses
Start-Sleep -Milliseconds 750

$customVbsPath = Join-Path $CustomDir $CustomVbsName
$customPs1Path = Join-Path $CustomDir $CustomPs1Name
$customUninstallPath = Join-Path $CustomDir $CustomUninstallName
$customIconPath = Join-Path $CustomDir $ToastIconName
$customSeenPath = Join-Path $CustomDir "seen-match-ids.txt"
$customLogPath  = Join-Path $CustomDir "ingest.log"

$legacyCustomVbsPath = Join-Path $InstallDir $CustomVbsName
$legacyCustomPs1Path = Join-Path $InstallDir $CustomPs1Name
$legacyCustomUninstallPath = Join-Path $InstallDir $CustomUninstallName
$legacyCustomIconPath = Join-Path $InstallDir $ToastIconName
$legacySeenPath      = Join-Path $InstallDir "seen-match-ids.txt"
$legacyLogPath       = Join-Path $InstallDir "ingest.log"

# Migrate state files from legacy root layout into the addon subfolder.
Move-LegacyFileIfPresent -legacyPath $legacySeenPath -targetPath $customSeenPath
Move-LegacyFileIfPresent -legacyPath $legacyLogPath  -targetPath $customLogPath

# Remove legacy wrapper launchers from root; fresh copies are written to subfolder.
foreach ($legacy in @($legacyCustomVbsPath, $legacyCustomPs1Path, $legacyCustomUninstallPath, $legacyCustomIconPath)) {
  try {
    if (Test-Path $legacy) { Remove-Item -Path $legacy -Force -ErrorAction Stop }
  } catch {
    Write-Warning "Failed to remove legacy wrapper file '$legacy'. Error: $($_.Exception.Message)"
  }
}

# Write VBS
Write-FileUtf8NoBom -path $customVbsPath -content $RunHiddenCustomVbs

# Download + write wrapper (THIS is the key fix)
$ingestNotifyContent = Download-Text $IngestNotifyUrl
Write-FileUtf8NoBom -path $customPs1Path -content $ingestNotifyContent

# Download + write local uninstall helper
$customUninstallContent = Download-Text $CustomUninstallUrl
Write-FileUtf8NoBom -path $customUninstallPath -content $customUninstallContent

# Download + write toast icon
Download-File -url $ToastIconUrl -destinationPath $customIconPath

Patch-ScheduledTaskToCustomVbs
Write-Host "Scheduled Task patched to use $CustomSubDirName\$CustomVbsName" -ForegroundColor Green

# Start once immediately
try { Start-ScheduledTask -TaskName $TaskName | Out-Null } catch {}

Write-Host "Done." -ForegroundColor Green
