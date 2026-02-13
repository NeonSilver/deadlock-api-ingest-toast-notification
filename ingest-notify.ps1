#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $ForwardArgs
)

# ==============================================================================
# MOST-LIKELY-TO-CHANGE SETTINGS
# ==============================================================================

# Toasts
$EnableToast           = $true
$ToastTitle            = "Deadlock ingest OK"
$ToastCooldownSeconds  = 30   # Minimum time between toasts (prevents spam)
$ToastFlushDelaySeconds = 5   # Flush pending toast batch even if no cycle marker appears
$ToastIconFileName     = "toast-icon.png" # Generated automatically in addon folder if missing
$RequireDeadlockClosedForToast = $true
$DeadlockProcessNames  = @("deadlock", "project8", "deadlock-win64-shipping")
$DeadlockStatePollSeconds = 3  # Reduce Get-Process frequency
$OutputPollMilliseconds = 800 # Poll cadence while upstream output is idle

# Seen-matches file format (local time, human-readable)
$SeenTimestampFormat   = "yyyy-MM-dd HH:mm:ss"  # Example: 2026-02-11 22:36:28

# Logging
$EnableLog             = $true
$MaxLogBytes           = 5MB  # Set 0 to disable rotation (keeps growing)

# Ingest verbosity
$RustLogLevel          = "info"  # debug | info | warn | error

# Disable colors from Rust output (best-effort)
$ForceNoColor          = $true

# ==============================================================================
# RARELY-CHANGED SETTINGS / PATHS
# ==============================================================================

$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$parentDir      = Split-Path -Parent $scriptDir
$exeLocalPath   = Join-Path $scriptDir "deadlock-api-ingest.exe"
$exeParentPath  = Join-Path $parentDir "deadlock-api-ingest.exe"

if (Test-Path $exeLocalPath) {
  $exe = $exeLocalPath
}
elseif (Test-Path $exeParentPath) {
  # Wrapper now lives in a subfolder; upstream exe remains one level up.
  $exe = $exeParentPath
}
else {
  # Keep a predictable path in error messages if upstream exe is missing.
  $exe = $exeLocalPath
}

$log      = Join-Path $scriptDir "ingest.log"
$seenFile = Join-Path $scriptDir "seen-match-ids.txt"
$fetchedSaltsFile = Join-Path $env:APPDATA "deadlock-api-ingest\fetched-salts.jsonl"

if (-not (Test-Path $exe)) {
  throw "deadlock-api-ingest.exe not found at: $exe"
}

# ==============================================================================
# ENV SETUP
# ==============================================================================

if ($ForceNoColor) {
  $env:NO_COLOR       = "1"
  $env:CLICOLOR       = "0"
  $env:RUST_LOG_STYLE = "never"
}

if (-not $env:RUST_LOG) { $env:RUST_LOG = $RustLogLevel }

# ==============================================================================
# HELPERS
# ==============================================================================

function Strip-Ansi([string]$s) {
  if ($null -eq $s) { return "" }
  # Robust ANSI/VT sequence removal:
  # - CSI sequences: ESC[ ... <final>
  # - Also supports single-byte CSI 0x9B
  return ($s -replace "(\x1B\[|\x9B)[0-?]*[ -/]*[@-~]", "")
}

$script:BurntToastReady = $false
$script:BurntToastWarned = $false
$script:ToastSendWarned = $false
$script:ToastIconPath = $null
$script:ToastIconResolved = $false
function Write-LogLine([string]$line) {
  if (-not $EnableLog) { return }
  if (-not $script:logWriter) { return }
  try {
    [System.Threading.Monitor]::Enter($script:logSync)
    try {
      $script:logWriter.WriteLine($line)
      Rotate-LogIfNeeded
    } finally {
      [System.Threading.Monitor]::Exit($script:logSync)
    }
  } catch {}
}

function Ensure-ToastIcon {
  if ($script:ToastIconResolved) { return $script:ToastIconPath }

  $script:ToastIconResolved = $true
  $iconPath = Join-Path $scriptDir $ToastIconFileName
  if (Test-Path $iconPath) {
    $script:ToastIconPath = $iconPath
    return $script:ToastIconPath
  }

  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $bmp = New-Object System.Drawing.Bitmap 96, 96
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(28, 34, 40))

    $outerBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(51, 176, 255))
    $innerBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 27, 32))
    $textBrush  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240, 247, 255))

    $g.FillEllipse($outerBrush, 6, 6, 84, 84)
    $g.FillEllipse($innerBrush, 14, 14, 68, 68)

    $font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString("DL", $font, $textBrush, (New-Object System.Drawing.RectangleF(0, 0, 96, 96)), $fmt)

    $bmp.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)

    $fmt.Dispose()
    $font.Dispose()
    $textBrush.Dispose()
    $innerBrush.Dispose()
    $outerBrush.Dispose()
    $g.Dispose()
    $bmp.Dispose()

    if (Test-Path $iconPath) {
      $script:ToastIconPath = $iconPath
      Write-LogLine "WRAPPER INFO: Toast icon ready at '$iconPath'."
      return $script:ToastIconPath
    }
  } catch {
    Write-LogLine "WRAPPER WARN: Toast icon generation failed; using default toast icon. Error: $($_.Exception.Message)"
  }

  return $null
}

function Ensure-BurntToast {
  if ($script:BurntToastReady) { return $true }
  try {
    Import-Module BurntToast -ErrorAction Stop
    $script:BurntToastReady = $true
    return $true
  } catch {
    if (-not $script:BurntToastWarned) {
      $msg = "BurntToast import failed; toast notifications disabled for this process. Error: $($_.Exception.Message)"
      Write-LogLine "WRAPPER WARN: $msg"
      Write-Warning $msg
      $script:BurntToastWarned = $true
    }
    return $false
  }
}

function Show-Toast([string]$title, [string]$body) {
  if (-not $EnableToast) { return $true }
  if (-not (Ensure-BurntToast)) { return $false }
  try {
    $iconPath = Ensure-ToastIcon
    if ($iconPath -and (Test-Path $iconPath)) {
      New-BurntToastNotification -Text $title, $body -AppLogo $iconPath | Out-Null
    } else {
      New-BurntToastNotification -Text $title, $body | Out-Null
    }
    Write-LogLine "WRAPPER INFO: Toast API call succeeded."
    $script:ToastSendWarned = $false
    return $true
  } catch {
    if (-not $script:ToastSendWarned) {
      $msg = "Toast send failed; will retry later. Error: $($_.Exception.Message)"
      Write-LogLine "WRAPPER WARN: $msg"
      Write-Warning $msg
      $script:ToastSendWarned = $true
    }
    # Keep ingest running even if toast fails
    return $false
  }
}

# ==============================================================================
# SEEN MATCHES LOADING (backward compatible)
# Supports:
#   57491480
#   57491480<TAB>2026-02-11 22:36:28
# ==============================================================================

$seen = New-Object "System.Collections.Generic.HashSet[string]"

if (Test-Path $seenFile) {
  try {
    Get-Content $seenFile -ErrorAction SilentlyContinue | ForEach-Object {
      $line = $_.Trim()
      if (-not $line) { return }

      # First token is match_id (split on tab or whitespace)
      $id = ($line -split "[`t ]+", 2)[0]
      if ($id -match '^\d+$') { [void]$seen.Add($id) }
    }
  } catch {}
}

function Add-SeenMatch([string]$matchId) {
  if (-not ($matchId -match '^\d+$')) { return $false }
  if ($seen.Contains($matchId)) { return $false }

  $ts = (Get-Date).ToString($SeenTimestampFormat)
  $entry = "$matchId`t$ts"

  try {
    # Create file if missing; append new line
    Add-Content -Path $seenFile -Value $entry -Encoding UTF8 -ErrorAction Stop
  } catch {
    $msg = "Failed to persist seen match id $matchId to '$seenFile'. Error: $($_.Exception.Message)"
    Write-LogLine "WRAPPER WARN: $msg"
    Write-Warning $msg
    return $false
  }

  [void]$seen.Add($matchId)

  return $true
}

# ==============================================================================
# LOGGING (append + readable while running + rotation)
# ==============================================================================

$script:logStream = $null
$script:logWriter = $null
$script:logSync = New-Object object

function Open-Log {
  if (-not $EnableLog) { return }
  try {
    $script:logStream = New-Object System.IO.FileStream(
      $log,
      [System.IO.FileMode]::Append,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::ReadWrite
    )
    $script:logWriter = New-Object System.IO.StreamWriter($script:logStream)
    $script:logWriter.AutoFlush = $true
  } catch {
    $script:logStream = $null
    $script:logWriter = $null
  }
}

function Close-Log {
  try { if ($script:logWriter) { $script:logWriter.Dispose() } } catch {}
  try { if ($script:logStream) { $script:logStream.Dispose() } } catch {}
  $script:logWriter = $null
  $script:logStream = $null
}

function Rotate-LogIfNeeded {
  if (-not $EnableLog) { return }
  if ($MaxLogBytes -le 0) { return }
  if (-not $script:logStream) { return }

  try {
    if ($script:logStream.Length -gt $MaxLogBytes) {
      Close-Log
      [System.IO.File]::WriteAllText($log, "", [System.Text.Encoding]::UTF8)
      Open-Log
    }
  } catch {}
}

if ($EnableLog) { Open-Log }

# ==============================================================================
# TOAST GROUPING (only after new matches)
# We accumulate new match IDs and flush on "Watching/Scanning cache directory" lines.
# ==============================================================================

$script:pendingToastIds = New-Object "System.Collections.Generic.HashSet[string]"
$script:pendingLastId   = $null
$script:pendingFirstAt  = $null
$script:lastToastAt     = Get-Date "2000-01-01"
$script:lastPendingDeferredLogAt = Get-Date "2000-01-01"
$script:pendingSync = New-Object object
$script:lastDeadlockCheckAt = Get-Date "2000-01-01"
$script:lastDeadlockRunning = $false
$script:saltsCursorPrimed = $false
$script:saltsPrimedPathLogged = $false
$script:lastSaltsWriteTicks = 0
$script:lastSaltsLength = -1

function Test-DeadlockRunning {
  $now = Get-Date
  if (($now - $script:lastDeadlockCheckAt).TotalSeconds -lt $DeadlockStatePollSeconds) {
    return $script:lastDeadlockRunning
  }

  $running = $false
  foreach ($name in $DeadlockProcessNames) {
    try {
      if (Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1) {
        $running = $true
        break
      }
    } catch {}
  }

  $script:lastDeadlockRunning = $running
  $script:lastDeadlockCheckAt = $now
  return $running
}

function Queue-MatchForToast([string]$matchId, [string]$source = "unknown") {
  if (-not ($matchId -match '^\d+$')) { return $false }

  if (-not (Add-SeenMatch $matchId)) { return $false }

  [System.Threading.Monitor]::Enter($script:pendingSync)
  try {
    [void]$script:pendingToastIds.Add($matchId)
    $script:pendingLastId = $matchId
    if (-not $script:pendingFirstAt) { $script:pendingFirstAt = Get-Date }
  } finally {
    [System.Threading.Monitor]::Exit($script:pendingSync)
  }

  Write-LogLine "WRAPPER INFO: Queued match $matchId for toast."
  if ($source) {
    Write-LogLine "WRAPPER INFO: Queue source: $source."
  }

  return $true
}

function Get-NewMatchIdsFromFetchedSalts {
  if (-not (Test-Path $fetchedSaltsFile)) { return @() }

  $fileInfo = Get-Item $fetchedSaltsFile -ErrorAction SilentlyContinue
  if (-not $fileInfo) { return @() }

  # Prime on first sight: baseline existing salts in memory so startup does not toast history.
  if (-not $script:saltsCursorPrimed) {
    $primedCount = 0
    foreach ($line in (Get-Content -Path $fetchedSaltsFile -ErrorAction SilentlyContinue)) {
      if ($line -match '"match_id"\s*:\s*(\d+)') {
        if ($seen.Add($matches[1])) { $primedCount++ }
      }
    }

    $script:saltsCursorPrimed = $true
    $script:lastSaltsWriteTicks = $fileInfo.LastWriteTimeUtc.Ticks
    $script:lastSaltsLength = $fileInfo.Length
    if (-not $script:saltsPrimedPathLogged) {
      Write-LogLine "WRAPPER INFO: Monitoring fetched-salts file at '$fetchedSaltsFile'."
      Write-LogLine "WRAPPER INFO: Primed $primedCount existing match IDs from fetched-salts."
      $script:saltsPrimedPathLogged = $true
    }
    return @()
  }

  if (
    $fileInfo.LastWriteTimeUtc.Ticks -eq $script:lastSaltsWriteTicks -and
    $fileInfo.Length -eq $script:lastSaltsLength
  ) {
    return @()
  }

  $script:lastSaltsWriteTicks = $fileInfo.LastWriteTimeUtc.Ticks
  $script:lastSaltsLength = $fileInfo.Length

  $ids = New-Object System.Collections.Generic.List[string]

  try {
    foreach ($line in (Get-Content -Path $fetchedSaltsFile -ErrorAction SilentlyContinue)) {
      if ($line -match '"match_id"\s*:\s*(\d+)') {
        $id = $matches[1]
        if (-not $seen.Contains($id)) {
          [void]$ids.Add($id)
        }
      }
    }
  } catch {
    # Keep ingest resilient; skip this polling cycle on read issues.
  }

  return $ids
}

function Flush-PendingToast([switch]$Force) {
  if (-not $EnableToast) { return }

  [System.Threading.Monitor]::Enter($script:pendingSync)
  try {
    if ($script:pendingToastIds.Count -le 0) { return }

    if ($RequireDeadlockClosedForToast -and (Test-DeadlockRunning)) { return }

    $now = Get-Date

    # Cooldown prevents spam
    if (-not $Force -and (($now - $script:lastToastAt).TotalSeconds -lt $ToastCooldownSeconds)) { return }

    $count = $script:pendingToastIds.Count
    $msg =
      if ($count -eq 1) {
        "Uploaded 1 new match."
      }
      elseif ($count -gt 1) {
        "Uploaded $count new matches."
      }
      else {
        "Uploaded new matches."
      }

    $sent = Show-Toast $ToastTitle $msg
    if (-not $sent) { return }

    $script:pendingToastIds.Clear()
    $script:pendingLastId = $null
    $script:pendingFirstAt = $null
    $script:lastToastAt = $now
  } finally {
    [System.Threading.Monitor]::Exit($script:pendingSync)
  }

  Write-LogLine "WRAPPER INFO: Toast sent."
}

function Flush-PendingToastWhenReady {
  $count = 0
  $firstAt = $null

  [System.Threading.Monitor]::Enter($script:pendingSync)
  try {
    $count = $script:pendingToastIds.Count
    $firstAt = $script:pendingFirstAt
  } finally {
    [System.Threading.Monitor]::Exit($script:pendingSync)
  }

  if ($count -le 0) { return }

  if (-not $RequireDeadlockClosedForToast) {
    Flush-PendingToast
    return
  }

  if (-not $firstAt) { return }
  if (((Get-Date) - $firstAt).TotalSeconds -lt $ToastFlushDelaySeconds) { return }

  # Defer until game fully closes.
  if (Test-DeadlockRunning) {
    if (((Get-Date) - $script:lastPendingDeferredLogAt).TotalSeconds -ge 20) {
      Write-LogLine "WRAPPER INFO: Pending toast deferred; Deadlock is still running."
      $script:lastPendingDeferredLogAt = Get-Date
    }
    return
  }

  Flush-PendingToast
}

function Process-IngestLine([string]$raw) {
  $line = Strip-Ansi $raw

  # Log (readable while running)
  Write-LogLine $line

  # Detect successful ingestion per match
  # Example: "Ingested salts: Salts { match_id: 57491480, ... }"
  if ($line -match 'Ingested\s+salts:\s+Salts\s+\{[^}]*\bmatch_id:\s*(\d+)\b') {
    $matchId = $matches[1]
    [void](Queue-MatchForToast -matchId $matchId -source "upstream-log")
  }

  # Flush on safe "cycle markers" so users get the toast promptly
  if (
    $line -match 'Watching\s+cache\s+directory' -or
    $line -match 'Scanning\s+cache\s+directory'
  ) {
    Flush-PendingToastWhenReady
  }

  # Fallback flush in case upstream output format changes and cycle markers are absent.
  Flush-PendingToastWhenReady
}

# ==============================================================================
# RUN
# ==============================================================================

$upstreamJob = $null
try {
  $upstreamJob = Start-Job -ScriptBlock {
    param([string]$ExePath, [string[]]$ExeArgs, [string]$RustLog, [bool]$NoColor)

    if ($NoColor) {
      $env:NO_COLOR       = "1"
      $env:CLICOLOR       = "0"
      $env:RUST_LOG_STYLE = "never"
    }

    if ($RustLog) { $env:RUST_LOG = $RustLog }

    & $ExePath @ExeArgs 2>&1 | ForEach-Object { $_.ToString() }
  } -ArgumentList $exe, $ForwardArgs, $env:RUST_LOG, $ForceNoColor

  Write-LogLine "WRAPPER INFO: Started upstream ingest job."
  $upstreamOutputCursor = 0

  while ($true) {
    $chunk = @()
    $allOutput = @(Receive-Job -Job $upstreamJob -Keep -ErrorAction SilentlyContinue)
    if ($upstreamOutputCursor -lt $allOutput.Count) {
      $chunk = $allOutput[$upstreamOutputCursor..($allOutput.Count - 1)]
      $upstreamOutputCursor = $allOutput.Count
    }

    foreach ($raw in $chunk) {
      Process-IngestLine $raw
    }

    foreach ($matchId in (Get-NewMatchIdsFromFetchedSalts)) {
      [void](Queue-MatchForToast -matchId $matchId -source "fetched-salts")
    }

    Flush-PendingToastWhenReady

    if ($upstreamJob.State -in @("Completed", "Failed", "Stopped")) {
      $chunk = @()
      $allOutput = @(Receive-Job -Job $upstreamJob -Keep -ErrorAction SilentlyContinue)
      if ($upstreamOutputCursor -lt $allOutput.Count) {
        $chunk = $allOutput[$upstreamOutputCursor..($allOutput.Count - 1)]
        $upstreamOutputCursor = $allOutput.Count
      }

      foreach ($raw in $chunk) {
        Process-IngestLine $raw
      }

      foreach ($matchId in (Get-NewMatchIdsFromFetchedSalts)) {
        [void](Queue-MatchForToast -matchId $matchId -source "fetched-salts")
      }
      break
    }

    Start-Sleep -Milliseconds $OutputPollMilliseconds
  }

  if ($upstreamJob.State -eq "Failed") {
    try {
      $reason = $upstreamJob.ChildJobs[0].JobStateInfo.Reason
      if ($reason) {
        Write-LogLine ("WRAPPER WARN: Upstream ingest job failed: " + $reason.Message)
      }
    } catch {}
  }
}
finally {
  try {
    if ($upstreamJob) { Remove-Job -Job $upstreamJob -Force -ErrorAction SilentlyContinue }
  } catch {}
  # Best effort: if something ends, still try to flush
  Flush-PendingToast -Force
  Close-Log
}
