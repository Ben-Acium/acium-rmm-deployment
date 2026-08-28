<#
.SYNOPSIS
    Downloads and installs the Acium Sensor agent from a pinned URL.
    Designed to run as a Datto RMM Component (executed as SYSTEM on the
    target machine).

.DESCRIPTION
    This script does six things, in order:
      1. Checks if the file at the URL has changed since last successful
         run (skips entirely if not — important since this runs on a
         recurring schedule, not just once)
      2. Checks for the ASP.NET Core 8.0 Runtime (a hard requirement for
         the sensor) and silently installs it first if missing
      3. Downloads the installer package (a .zip) from a URL
      4. Extracts the .zip to find the .msi installer inside it
      5. Runs the .msi silently (no popups, no user interaction)
      6. Cleans up the downloaded files afterward

.NOTES
    Datto RMM Component Variables expected (set this in the Component UI
    in Datto, NOT hardcoded in this script — that way, pointing to a new
    agent version later is just editing a variable, not editing code):

        AgentDownloadUrl   - Direct URL to the pinned agent zip, e.g.
                              https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup.zip

    RECURRING-RUN NOTE: Since this Component runs on a schedule (not just
    once), the script needs a reliable way to know "did anything actually
    change since last time?" without a version number in the filename to
    compare. It does this by checking the file's ETag — a fingerprint the
    web server sends describing exactly which version of the file it's
    currently serving — before downloading anything. That ETag is saved
    locally after every successful install; on the next run, if the
    server's current ETag matches what's saved, the script knows nothing
    changed and skips straight to exit, with no download or reinstall.
    This keeps a scheduled job from redownloading and reinstalling the
    same package over and over on every run.

    If the filename happens to contain a version number (e.g.
    "...-0.16.3.zip"), that's also parsed out and logged for readability,
    but it's no longer what decides whether to skip — the ETag is, combined
    with a check for whether the AciumSensor process is actually running
    on the machine.

    Exit codes (Datto RMM reads this to decide if the run succeeded or failed):
        0   - Success (installed, or was already up to date)
        1   - Download failed
        3   - Install/uninstall failed
        4   - Missing required Component Variable
        5   - Zip extraction failed / MSI not found inside package
#>

# =========================================================================
# SECTION 1: CONFIG
# Set up file paths and read in the settings Datto RMM passes to the script.
# Nothing runs yet in this section — just defining values to use later.
# =========================================================================

# Tell PowerShell to treat any unhandled error as a script-stopping error.
# Without this, some failures would just print a red warning and keep going,
# which we don't want during an unattended install.
$ErrorActionPreference = 'Stop'

# Where we'll write log files and temporarily store the downloaded package.
# ProgramData is used because it's writable by SYSTEM and survives reboots,
# so logs are still there later if you need to troubleshoot a machine.
$LogDir      = 'C:\ProgramData\AciumSensor\Logs'
$WorkDir     = 'C:\ProgramData\AciumSensor\Install'
$LogFile     = Join-Path $LogDir 'deploy.log'          # our own running log of what happened
$MsiFileName = 'AciumSensorInstall.msi'                 # the installer file we're looking for inside the zip
$MsiLogFile  = Join-Path $LogDir 'msi-install.log'      # Windows Installer's own detailed log

# Where we remember the ETag (the server's fingerprint for the file) from
# the last time we successfully installed. This is how we detect "has the
# file at the URL changed since last run" on a recurring schedule, without
# needing a version number anywhere.
$StateFile   = Join-Path $WorkDir 'last-installed.json'

# The name of the process we expect to be running if the software is
# installed and active. Checking for a running process is simpler and
# more flexible than tracking a specific Product Code or Upgrade Code —
# it doesn't care what version is running or how Windows Installer has
# it registered, just whether the actual software is up and running
# right now. Trade-off: if the service is ever stopped or crashed but
# still installed, this will look like "not installed" and trigger a
# reinstall — an acceptable edge case since the service is designed to
# run continuously.
$ProcessName = 'AciumSensor'

# Datto RMM Component Variables show up to the script as environment
# variables at runtime. This is the only one required — without it we
# don't know what to download.
$DownloadUrl = $env:AgentDownloadUrl

# =========================================================================
# SECTION 2: SETUP
# Make sure our log/work folders exist, and set up a helper function for
# writing timestamped log lines both to the log file and to the screen.
# =========================================================================

foreach ($dir in @($LogDir, $WorkDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Write-Log is a small helper we call throughout the script instead of
# plain "Write-Output". It adds a timestamp and saves the message to our
# log file, so anyone troubleshooting later has a full history on disk —
# not just whatever Datto RMM happened to capture from that one run.
function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

Write-Log "=== Deployment started ==="

# Log exactly which account this script is actually running as. This is
# the definitive way to confirm whether Datto RMM is truly executing this
# as SYSTEM (should show "NT AUTHORITY\SYSTEM") or as something else —
# useful if a UAC prompt or permission issue shows up on the client and
# it's unclear what context the script actually ran under.
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Log "Running as: $currentIdentity"

# Bail out early if Datto didn't pass in the URL we need. Exit code 4
# signals "this is a configuration problem", not a download or install failure.
if (-not $DownloadUrl) {
    Write-Log "ERROR: Missing required Component Variable (AgentDownloadUrl)."
    exit 4
}

Write-Log "Download URL: $DownloadUrl"

# Try to pull a version number out of the filename in the URL, purely for
# readable logging (e.g. ".../acium-sensor-setup-0.16.3.zip" -> "0.16.3").
# This is NOT used to decide whether to skip the install anymore — the
# filename may not contain a version at all, so the ETag check below is
# what actually drives that decision.
$TargetVersion = $null
if ($DownloadUrl -match '(\d+\.\d+\.\d+)') {
    $TargetVersion = $Matches[1]
    Write-Log "Parsed version from URL for logging: $TargetVersion"
}

# =========================================================================
# SECTION 3: CHANGE CHECK
# Since this Component runs on a recurring schedule, we need to know
# whether it's safe to skip a full download+install this time. That's
# only true if BOTH of these hold:
#   (a) the file at the URL hasn't changed since our last successful
#       install (checked via ETag, the server's fingerprint for the file)
#   (b) the software is actually still installed on THIS machine right
#       now (checked by looking for its running process)
# We need both, not just (a) — if someone manually uninstalls the
# software, the source file hasn't changed, but the machine now needs a
# fresh install regardless. Checking the ETag alone would miss that and
# wrongly skip.
# =========================================================================

# --- (a) Has the source file changed? ---

# Read whatever ETag we saved from our last successful run, if any.
$lastEtag = $null
if (Test-Path $StateFile) {
    try {
        $lastEtag = (Get-Content -Path $StateFile -Raw | ConvertFrom-Json).Etag
    } catch {
        # State file exists but is unreadable/corrupt — treat as "no prior state".
        $lastEtag = $null
    }
}

# Ask the server for just the headers (a "HEAD" request), not the file
# itself — this is fast and cheap since it doesn't download any content.
$currentEtag = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headRequest = [System.Net.HttpWebRequest]::Create($DownloadUrl)
    $headRequest.Method = 'HEAD'
    $headResponse = $headRequest.GetResponse()
    $currentEtag = $headResponse.Headers['ETag']
    $headResponse.Close()
    Write-Log "Current file ETag from server: $currentEtag"
} catch {
    # If the HEAD request fails (some servers don't support it, or a
    # transient network hiccup), we don't treat that as fatal — we just
    # can't compare, so we fall through and do a full download+install to
    # be safe rather than silently skipping a possibly-needed update.
    Write-Log "Could not retrieve ETag via HEAD request - $($_.Exception.Message). Proceeding with download to be safe."
}

$fileUnchanged = $currentEtag -and $lastEtag -and ($currentEtag -eq $lastEtag)

# --- (b) Is the software actually installed and running right now? ---

# We check for the AciumSensor.exe process directly. This is simpler and
# more flexible than tracking a Product Code or Upgrade Code — it works
# regardless of version and doesn't depend on how Windows Installer has
# the product registered, just whether the software itself is actually
# running on this machine.
$isCurrentlyInstalled = $null -ne (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
Write-Log "Currently running on this machine: $isCurrentlyInstalled"

# --- Decision: only skip if BOTH conditions say "nothing to do" ---

if ($fileUnchanged -and $isCurrentlyInstalled) {
    Write-Log "File is unchanged AND software is already installed. Skipping."
    Write-Log "=== Deployment complete (no-op) ==="
    exit 0
}

if (-not $isCurrentlyInstalled) {
    Write-Log "Software is not currently installed on this machine — proceeding with install regardless of ETag."
} else {
    Write-Log "Source file has changed since last install — proceeding with install."
}

# =========================================================================
# SECTION 4: PREREQUISITE CHECK — ASP.NET CORE 8.0 RUNTIME
# AciumSensor.exe is a framework-dependent .NET 8.0 app — it requires
# Microsoft.AspNetCore.App 8.0.x to already be present on the machine, or
# the service will fail to start and the MSI install will roll itself
# back entirely (confirmed via a real failure: msiexec error 1603, with
# the underlying cause being Windows Installer error 1920 — "service
# failed to start" — after this runtime was missing). We check for it
# here and install it first if needed, so the actual sensor install
# further down doesn't hit that failure.
# =========================================================================

# If the ASP.NET Core 8.0 shared framework folder doesn't exist, we treat
# the runtime as missing. This doesn't check the exact patch version —
# .NET's runtime resolution automatically rolls forward to any newer
# 8.0.x patch, so any 8.0.x present is sufficient for AciumSensor.exe.
$AspNetCoreRuntimePath = 'C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App'
$aspNetCoreInstalled = (Test-Path $AspNetCoreRuntimePath) -and
    ((Get-ChildItem $AspNetCoreRuntimePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '8.0.*' }).Count -gt 0)

if ($aspNetCoreInstalled) {
    Write-Log "ASP.NET Core 8.0 Runtime already present."
} else {
    Write-Log "ASP.NET Core 8.0 Runtime not found. Installing it before deploying the sensor."

    # Microsoft's "Hosting Bundle" installs both the x86 and x64 versions
    # of the .NET Runtime and ASP.NET Core Runtime in a single package.
    # We use this instead of guessing at architecture, since the sensor
    # MSI installs under "Program Files (x86)" which hints it may be a
    # 32-bit package — installing both architectures avoids getting this
    # wrong. This aka.ms link is maintained by Microsoft to always
    # redirect to the latest 8.0.x patch, so it doesn't need updating here.
    $dotnetInstallerUrl  = 'https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe'
    $dotnetInstallerPath = Join-Path $WorkDir 'dotnet-hosting-8.0-win.exe'

    try {
        Write-Log "Downloading ASP.NET Core 8.0 Hosting Bundle..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $webClient = New-Object System.Net.WebClient
        try {
            $webClient.DownloadFile($dotnetInstallerUrl, $dotnetInstallerPath)
        } finally {
            $webClient.Dispose()
        }
        Write-Log "Download complete: $dotnetInstallerPath"
    } catch {
        Write-Log "ERROR: Failed to download ASP.NET Core Runtime installer - $($_.Exception.Message)"
        exit 1
    }

    try {
        Write-Log "Installing ASP.NET Core 8.0 Hosting Bundle silently..."
        # /install /quiet /norestart are the documented silent-install
        # flags for this Microsoft installer.
        $dotnetArgs = @('/install', '/quiet', '/norestart')
        $dotnetProc = Start-Process -FilePath $dotnetInstallerPath -ArgumentList $dotnetArgs -Wait -PassThru

        if ($dotnetProc.ExitCode -eq 0) {
            Write-Log "ASP.NET Core 8.0 Runtime installed successfully."
        } elseif ($dotnetProc.ExitCode -eq 3010) {
            Write-Log "ASP.NET Core 8.0 Runtime installed successfully (reboot required)."
        } else {
            Write-Log "ERROR: ASP.NET Core Runtime installer exited with code $($dotnetProc.ExitCode)."
            exit 3
        }
    } catch {
        Write-Log "ERROR: ASP.NET Core Runtime install failed - $($_.Exception.Message)"
        exit 3
    } finally {
        Remove-Item $dotnetInstallerPath -Force -ErrorAction SilentlyContinue
    }
}

# =========================================================================
# SECTION 5: DOWNLOAD
# Download the .zip package from the URL Datto RMM gave us.
# =========================================================================

$zipPath     = Join-Path $WorkDir 'acium-sensor-setup.zip'
$extractPath = Join-Path $WorkDir 'extracted'

try {
    Write-Log "Downloading package..."

    # Force PowerShell to use TLS 1.2 for this connection. Some older
    # Windows versions (like Server 2012 R2) default to an older,
    # unsupported TLS version, which would make the download silently fail
    # against most modern HTTPS servers. This line prevents that.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # We use .NET's WebClient here instead of Invoke-WebRequest on purpose.
    # In Windows PowerShell 5.1 (what Datto RMM components run under),
    # Invoke-WebRequest reads the entire file into memory before writing it
    # to disk, and also renders a progress bar that can make downloads
    # dramatically slower. WebClient streams the file straight to disk as
    # it downloads, which is lighter on memory and faster — important since
    # this may run unattended, at scale, across many endpoints at once.
    $webClient = New-Object System.Net.WebClient
    try {
        $webClient.DownloadFile($DownloadUrl, $zipPath)
    } finally {
        $webClient.Dispose()
    }

    Write-Log "Download complete: $zipPath"
} catch {
    # $_.Exception.Message gives us the actual reason the download failed
    # (e.g. "404 Not Found", "could not resolve host", etc.) for the log.
    Write-Log "ERROR: Download failed - $($_.Exception.Message)"
    exit 1
}

# =========================================================================
# SECTION 6: EXTRACT
# Unzip the downloaded package and find the .msi installer inside it.
# =========================================================================

try {
    Write-Log "Extracting package..."

    # If a previous run left an extracted folder behind, clear it out first
    # so we're always working with a clean copy of this version's files.
    if (Test-Path $extractPath) {
        Remove-Item $extractPath -Recurse -Force
    }

    # Unzip everything into our extraction folder.
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    # Search the extracted folder (and subfolders) for the .msi file we
    # expect to find. Take the first match, in case there's more than one.
    $msiFile = Get-ChildItem -Path $extractPath -Filter $MsiFileName -Recurse | Select-Object -First 1

    if (-not $msiFile) {
        # The zip downloaded and extracted fine, but didn't actually
        # contain the installer we expected — treat this as a failure
        # rather than silently doing nothing.
        Write-Log "ERROR: $MsiFileName not found inside extracted package."
        exit 5
    }

    Write-Log "Found installer: $($msiFile.FullName)"
} catch {
    Write-Log "ERROR: Extraction failed - $($_.Exception.Message)"
    exit 5
}

# =========================================================================
# SECTION 7: INSTALL
# Run the MSI installer silently (no dialog boxes, no user interaction —
# important since this runs unattended as SYSTEM with nobody watching).
# =========================================================================

try {
    Write-Log "Running msiexec silently..."

    # Build the argument list for msiexec.exe (Windows' built-in installer
    # engine, used to run any .msi file):
    #   /i <path>   = install this MSI
    #   /qn         = "quiet, no UI" — fully silent, no popups
    #   /norestart  = don't auto-reboot the machine even if the install wants to
    #   /l*v <path> = write a verbose log of the install to this file,
    #                 useful for troubleshooting if something goes wrong
    #
    # We pass this as an actual PowerShell array, not one big manually
    # quoted string. Start-Process knows how to correctly pass each array
    # element through to the target program as its own argument, including
    # handling spaces in paths — manually building the string ourselves
    # with escaped quotes is a common source of subtle bugs if a file path
    # ever contains a space or a PowerShell host handles it unexpectedly.
    $msiArgs = @(
        '/i', $msiFile.FullName,
        '/qn',
        '/norestart',
        '/l*v', $MsiLogFile
    )

    # Actually launch msiexec and wait for it to finish before continuing.
    # -PassThru lets us capture its exit code afterward.
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

    # msiexec's exit code tells us what happened:
    #   0    = installed successfully
    #   3010 = installed successfully, but a reboot is needed to finish
    #          (this is normal and still counts as success — just a note)
    #   anything else = something went wrong
    if ($proc.ExitCode -eq 0) {
        Write-Log "Install completed successfully."
    } elseif ($proc.ExitCode -eq 3010) {
        Write-Log "Install completed successfully (reboot required)."
    } else {
        Write-Log "ERROR: msiexec exited with code $($proc.ExitCode). See $MsiLogFile for details."
        exit 3
    }
} catch {
    Write-Log "ERROR: Install failed - $($_.Exception.Message)"
    exit 3
}

# =========================================================================
# SECTION 8: SAVE STATE
# Record the ETag we just installed, so the NEXT run of this recurring
# job can compare against it and skip if the file hasn't changed.
# We only get here if the install above succeeded — an ETag is never
# saved for a run that failed partway through.
# =========================================================================

if ($currentEtag) {
    try {
        @{ Etag = $currentEtag; InstalledAt = (Get-Date -Format 'o') } | ConvertTo-Json | Set-Content -Path $StateFile
        Write-Log "Saved ETag for next run's change check: $currentEtag"
    } catch {
        # Not being able to save state isn't fatal to this run — the
        # install already succeeded — it just means the next run won't
        # have anything to compare against and will reinstall again.
        Write-Log "WARNING: Could not save state file - $($_.Exception.Message)"
    }
} else {
    Write-Log "WARNING: No ETag was available to save. Next run will reinstall unconditionally."
}

# =========================================================================
# SECTION 9: CLEANUP
# Delete the downloaded zip and extracted files now that we're done with
# them, so we don't leave junk behind on every machine we deploy to.
# =========================================================================

# -ErrorAction SilentlyContinue here means: if these files are somehow
# already gone or locked, don't fail the whole script over a cleanup step —
# the install itself already succeeded, which is what actually matters.
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "=== Deployment complete (installed $(if ($TargetVersion) { $TargetVersion } else { 'agent' })) ==="
exit 0
