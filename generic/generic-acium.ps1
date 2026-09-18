#Requires -Version 5.0

<#
.SYNOPSIS
    Downloads and installs the Acium Sensor agent from a pinned URL.
    Generic version - all configuration is hardcoded in the script itself,
    so it can be run from any RMM (or manually) without needing that
    platform's variable/parameter system. Designed to run as SYSTEM on the
    target machine.

.DESCRIPTION
    On each run, in order:
      1. Takes a machine-wide lock so two overlapping runs can't stack
      2. Checks whether the file at the URL has changed since the last
         successful run (skips entirely if not - important since this runs
         on a recurring schedule, not just once)
      3. Downloads the installer package (a .zip) and verifies its SHA256
         against the last successful install - a second, server-independent
         way to answer "did anything actually change?"
      4. Checks for the ASP.NET Core 8.0 Runtime (a hard requirement for
         the sensor) and silently installs it first if missing
      5. Extracts the .zip, finds the .msi inside it, and checks its
         Authenticode signature
      6. Runs the .msi silently (no popups, no user interaction)
      7. Cleans up the downloaded files afterward

.NOTES
    VERSION: $ScriptVersion in SECTION 1 below tracks this script's own
    revision, separate from the agent version in $DownloadUrl. Bump it
    whenever this script's logic changes, and add an entry to
    CHANGELOG.md at the repo root describing what changed and why.

    CONFIGURATION: All configuration is hardcoded directly in SECTION 1
    below. Bumping to a new agent version means editing $DownloadUrl in
    this script and redeploying it - there is no external variable to
    update instead. This keeps the script self-contained and behaving
    identically no matter what runs it (any RMM platform, a scheduled
    task, or manually). $Organization (optional) sets which organization/
    tenant the installed sensor reports under, passed to the MSI as the
    ORGANIZATION property when set.

    VERIFY THE PRODUCTCODE: $ProductCode below has not been confirmed
    against a real Acium Sensor MSI. To get the true value, run this on one
    endpoint that has the sensor installed:

        Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall,
                      HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall |
          Where-Object { (Get-ItemProperty $_.PSPath).DisplayName -like '*Acium*' } |
          Select-Object PSChildName

    The key name IS the ProductCode. Until it's confirmed, the registry
    cross-check in SECTION 7 covers for it and logs the correct value.

    RECURRING-RUN NOTE: Since this script may run on a schedule, it needs a
    reliable way to know "did anything actually change since last time?"
    It uses two independent signals: the ETag (a fingerprint the web server
    sends for the file) as a cheap pre-download check, and the SHA256 of
    the downloaded package as a check that works no matter what headers the
    server does or doesn't send. Either one matching, combined with the
    sensor actually being installed, is enough to skip.

    Exit codes (your RMM reads this to decide if the run succeeded or failed):
        0   - Success (installed, already up to date, or deferred pending
              a reboot - see the log for which)
        1   - Download failed
        2   - Could not secure the working/log directory (ACL hardening
              failed) - refused to proceed with a privileged install
        3   - Install failed
        4   - Missing or invalid configuration value in the script
        5   - Zip extraction failed / MSI not found inside package
        6   - MSI failed Authenticode signature verification
#>

# =========================================================================
# SECTION 1: CONFIG
# Set up file paths and the settings this script needs. Edit the values
# in this section to configure a deployment - nothing runs yet, this is
# just defining values to use later.
# =========================================================================

# Treat any unhandled error as script-stopping. Without this, some failures
# would print a red warning and keep going, which we don't want during an
# unattended install.
$ErrorActionPreference = 'Stop'

# This script's own revision (not the agent's - see $DownloadUrl below for
# that). Bump this whenever the script's logic changes, and record the
# change in CHANGELOG.md at the repo root.
$ScriptVersion = '1.2.2'

# --- EDIT THESE VALUES TO CONFIGURE A DEPLOYMENT ---

# Direct URL to the pinned agent zip. Baked into the script itself (rather
# than read from an RMM variable) so it behaves identically no matter what
# platform runs it. Update this and redeploy when a new agent version needs
# to go out.
$DownloadUrl = 'https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup-0.16.8.zip'

# The organization/tenant ID this sensor should report under, passed to the
# MSI as the ORGANIZATION property. Optional - leave blank to install
# without setting it.
$Organization = ''

# Optional Authenticode hardening. When set to the expected signing
# certificate's subject CN (e.g. 'Acium, Inc.'), the script REFUSES to run
# an MSI that isn't validly signed by it, and exits 6. Leave blank to run
# unsigned/unverified packages but log what the signature actually says -
# fill this in once you've confirmed the real publisher name from the log.
$ExpectedPublisherCN = ''

# --- END CONFIGURABLE VALUES ---

# The MSI's ProductCode GUID for Acium Sensor. SEE "VERIFY THE PRODUCTCODE"
# IN THE HEADER - this value is unconfirmed. It is used in SECTION 7 to ask
# Windows Installer whether the product is already installed, which decides
# whether the install needs REINSTALL=ALL / REINSTALLMODE=vomus (correct
# only for a reinstall/repair) or a plain /i (needed for a genuine
# first-time install). If this GUID is wrong, that check silently always
# answers "not installed" - so SECTION 7 also cross-checks the registry and
# logs the real value.
$ProductCode = '{8F3A2E1D-6B4C-4F7E-9A5B-2C8D1E9F3A7B}'

# Used by the registry cross-check to find the product by name when the
# ProductCode above doesn't match anything. Keep this SPECIFIC - a loose
# pattern that also matches some other Acium-branded MSI would hand the
# cross-check the wrong product's ProductCode. See SECTION 8.
$DisplayNamePattern = 'Acium Sensor*'

# The Windows service the MSI installs. Presence of the service - not
# whether it happens to be running right now - is what "installed" means
# here: a crashed or stopped service is still installed, and reinstalling
# it on every scheduled run wouldn't fix it anyway.
$ServiceName = 'AciumSensor'

# Fallback only, for the case where the service is registered under a name
# other than $ServiceName.
$ProcessName = 'AciumSensor'

# Where we'll write log files and temporarily store the downloaded package.
# ProgramData is used because it's writable by SYSTEM and survives reboots,
# so logs are still there later if you need to troubleshoot a machine.
$RootDir     = 'C:\ProgramData\AciumSensor'
$LogDir      = Join-Path $RootDir 'Logs'
$WorkDir     = Join-Path $RootDir 'Install'
$LogFile     = Join-Path $LogDir 'deploy.log'          # our own running log of what happened
$MsiFileName = 'AciumSensorInstall.msi'                 # the installer file we're looking for inside the zip
$MsiLogFile  = Join-Path $LogDir 'msi-install.log'      # Windows Installer's own detailed log

# Where we remember what we last successfully installed (the server's ETag
# and the package's SHA256), so the next scheduled run can tell whether
# anything actually changed.
$StateFile   = Join-Path $WorkDir 'last-installed.json'

# Rotate a log once it passes this size rather than letting it grow forever
# on machines that have been running this for years.
$MaxLogBytes = 5MB

# =========================================================================
# SECTION 2: SETUP
# Create and lock down our folders, and set up logging.
# =========================================================================

foreach ($dir in @($RootDir, $LogDir, $WorkDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Lock down the working directories to SYSTEM and Administrators only.
#
# This matters more than it looks. The default DACL on C:\ProgramData
# includes an inheritable "BUILTIN\Users: create folders / append data"
# entry, which means a standard user can create directories inside
# subfolders like ours. We stage an MSI in $WorkDir and then execute it as
# SYSTEM, and we call Remove-Item -Recurse -Force on a path under it - a
# directory a low-privileged user can pre-create as a junction. Removing
# inheritance here closes both doors at once.
#
# SIDs rather than names so this works on non-English Windows.
function Protect-Directory {
    param([string]$Path)
    try {
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')      # NT AUTHORITY\SYSTEM
        $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')  # BUILTIN\Administrators

        $acl = Get-Acl -LiteralPath $Path
        # $true  = protect from inheritance, $false = don't copy inherited rules down
        $acl.SetAccessRuleProtection($true, $false)

        # Strip anything already explicitly granted, then grant only us.
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }

        foreach ($sid in @($systemSid, $adminsSid)) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        $acl.SetOwner($adminsSid)
        Set-Acl -LiteralPath $Path -AclObject $acl
        return $true
    } catch {
        return $false
    }
}

# Deliberately NOT $RootDir. That's the sensor's own directory
# (C:\ProgramData\AciumSensor) and the installed service may keep state
# there under an identity other than SYSTEM/Administrators - stripping its
# ACEs on every scheduled run could break the product we're deploying.
# $LogDir and $WorkDir are the ones that matter anyway: they hold the MSI
# we execute as SYSTEM and the path we recursively delete.
$aclResults = @{}
foreach ($dir in @($LogDir, $WorkDir)) {
    $aclResults[$dir] = Protect-Directory -Path $dir
}

# Rotate the log before we start appending to it.
if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes)) {
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force -ErrorAction SilentlyContinue
}

# Write-Log adds a timestamp and saves the message to our log file, so
# anyone troubleshooting later has a full history on disk - not just
# whatever the RMM happened to capture from that one run.
#
# It must never throw. Under $ErrorActionPreference='Stop', a log file
# locked by a concurrent run would otherwise become an unhandled
# terminating error at an arbitrary point in the script, exiting 1 - which
# the exit-code table documents as "download failed."
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
}

# --- Machine-wide lock ---
#
# A recurring RMM job can overlap with a slow previous run (or with a
# manual run). Two copies racing means two msiexec calls, a shared work
# directory being deleted out from under one of them, and a corrupt state
# file. Whoever gets the mutex wins; the other exits cleanly as a no-op.
# The OS releases the mutex when the process ends, including on a crash.
$lockName = 'Global\AciumSensorDeploy'
$mutex    = New-Object System.Threading.Mutex($false, $lockName)
$haveLock = $false
try {
    $haveLock = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # Previous holder died without releasing. We now own it.
    $haveLock = $true
}

if (-not $haveLock) {
    Write-Log "Another deployment run already holds the lock. Exiting as a no-op." 'WARN'
    exit 0
}

Write-Log "=== Deployment started (script version $ScriptVersion) ==="

foreach ($dir in $aclResults.Keys) {
    if (-not $aclResults[$dir]) {
        # Fail closed. This directory inherits ProgramData's default DACL,
        # which lets standard users create/plant a junction in it - the
        # exact scenario Protect-Directory exists to close off. Proceeding
        # to stage and execute a privileged MSI (or recursively delete)
        # here anyway would leave that attack live.
        Write-Log "ERROR: Could not harden ACL on $dir - refusing to proceed with a privileged install against a directory that may still be writable by non-admins." 'ERROR'
        exit 2
    }
}

# Log exactly which account this script is actually running as. This is the
# definitive way to confirm whether the RMM is truly executing as SYSTEM
# (should show "NT AUTHORITY\SYSTEM") - useful if a UAC prompt or
# permission issue shows up and it's unclear what context it ran under.
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Log "Running as: $currentIdentity"

# Bail out early if the download URL configured above is blank. Exit code 4
# signals "this is a configuration problem", not a download or install
# failure - someone editing the script left a required value empty.
if (-not $DownloadUrl) {
    Write-Log "ERROR: Missing required configuration value (`$DownloadUrl is empty in SECTION 1)." 'ERROR'
    exit 4
}

# A double quote in an MSI property value can't be passed through msiexec's
# command line unambiguously. Reject it rather than building a mangled
# command line and getting a confusing install failure downstream.
if ($Organization -match '"') {
    Write-Log "ERROR: `$Organization contains a double quote, which cannot be passed to msiexec safely." 'ERROR'
    exit 4
}

Write-Log "Download URL: $DownloadUrl"
Write-Log "Organization: $(if ($Organization) { $Organization } else { '(not set)' })"

# Try to pull a version number out of the filename in the URL, purely for
# readable logging (e.g. ".../acium-sensor-setup-0.16.3.zip" -> "0.16.3").
# This does NOT decide whether to skip the install - the URL may not
# contain a version at all.
$TargetVersion = $null
if ($DownloadUrl -match '(\d+\.\d+\.\d+)') {
    $TargetVersion = $Matches[1]
    Write-Log "Parsed version from URL for logging: $TargetVersion"
}

# A reboot already pending from some other software can make a service fail
# to start, which is what turns into msiexec 1603 / Windows Installer 1920.
# Worth knowing about in the log when diagnosing a failed install.
function Test-PendingReboot {
    # Keys whose mere existence signals a pending reboot.
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key -ErrorAction SilentlyContinue) { return $key }
    }

    # PendingFileRenameOperations is a VALUE under Session Manager, not a
    # key - Test-Path on it is always false, so it has to be read as a
    # property. It's set whenever something queued a file replacement for
    # the next boot, which is the usual reason a freshly-installed service
    # won't start yet.
    try {
        $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $props = Get-ItemProperty -LiteralPath $sessionManager -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($props -and $props.PendingFileRenameOperations) { return 'PendingFileRenameOperations' }
    } catch {
        $null = $_
    }

    return $null
}

$pendingReboot = Test-PendingReboot
if ($pendingReboot) {
    Write-Log "A reboot is already pending on this machine ($pendingReboot). If the install fails to start the service, that's the likely cause." 'WARN'
}

# =========================================================================
# SECTION 3: SHARED HELPERS
# =========================================================================

# Add TLS 1.2 (and 1.3 where the framework knows about it) to whatever is
# already enabled, rather than replacing the set.
#
# The old script assigned `= Tls12`, which on a machine already negotiating
# TLS 1.3 silently turned it off; and when SecurityProtocol is
# SystemDefault (0), assigning narrows the OS's own choice rather than
# widening it. So: leave SystemDefault alone, and OR into anything else.
function Set-SecurityProtocol {
    $current = [Net.ServicePointManager]::SecurityProtocol
    if ($current -eq 0) { return }   # SystemDefault - the OS already picks correctly.

    $want = $current -bor [Net.SecurityProtocolType]::Tls12

    # Tls13 isn't defined on older .NET Framework, where accessing the enum
    # member throws. Deliberately swallowed: TLS 1.2 alone is fine there,
    # and this must never be the thing that fails a deployment.
    try { $want = $want -bor [Net.SecurityProtocolType]::Tls13 } catch { $null = $_ }
    [Net.ServicePointManager]::SecurityProtocol = $want
}

# WebClient rather than Invoke-WebRequest on purpose: in Windows PowerShell
# 5.1 (what most RMM scripting engines run under), Invoke-WebRequest reads
# the whole file into memory before writing it to disk and renders a
# progress bar that can make downloads dramatically slower. WebClient
# streams straight to disk.
#
# Retries because a transient blip on one endpoint out of a few hundred
# shouldn't surface as a deployment failure in the RMM dashboard.
function Invoke-Download {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$Attempts = 3
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Set-SecurityProtocol
            $webClient = New-Object System.Net.WebClient
            try {
                # Honour whatever proxy the machine is configured with, using
                # the current (SYSTEM) account's credentials - otherwise an
                # authenticating proxy 407s every endpoint behind it.
                $webClient.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
                $webClient.DownloadFile($Url, $Destination)
            } finally {
                $webClient.Dispose()
            }
            return
        } catch {
            if ($attempt -ge $Attempts) { throw }
            Write-Log "Download attempt $attempt failed - $($_.Exception.Message). Retrying..." 'WARN'
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

# Is the sensor installed on this machine?
#
# The service's existence, not a running process, is the signal. A service
# that's installed but stopped or crash-looping is still installed;
# treating it as missing (which the old process check did) meant
# reinstalling on every single scheduled run without ever fixing it.
function Get-SensorInstallState {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        return [pscustomobject]@{
            Installed = $true
            Detail    = "service '$ServiceName' present, status $($service.Status)"
        }
    }

    # Fallback for the case where the service is registered under a
    # different name than we expect.
    $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($process) {
        return [pscustomobject]@{
            Installed = $true
            Detail    = "service '$ServiceName' not found, but process '$ProcessName' is running"
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Detail    = "no '$ServiceName' service and no '$ProcessName' process"
    }
}

# Find an installed Acium product in the Uninstall registry. The key name
# under Uninstall IS the MSI ProductCode, so this both answers "is it
# installed" and recovers the true ProductCode if the one configured at the
# top of this script is wrong.
function Find-InstalledProduct {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            # Only MSI-installed products have a GUID-shaped key name.
            if ($key.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }

            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($props -and $props.DisplayName -like $DisplayNamePattern) {
                return [pscustomobject]@{
                    ProductCode = $key.PSChildName
                    DisplayName = $props.DisplayName
                    Version     = $props.DisplayVersion
                }
            }
        }
    }
    return $null
}

# =========================================================================
# SECTION 4: CHANGE CHECK (cheap pass, before downloading anything)
# Since this script may run on a recurring schedule, we need to know
# whether it's safe to skip this time. That's only true if BOTH hold:
#   (a) the file at the URL hasn't changed since our last successful
#       install (checked via ETag, the server's fingerprint for the file)
#   (b) the sensor is actually still installed on THIS machine
# We need both. If someone manually uninstalls the sensor, the source file
# hasn't changed, but the machine still needs a fresh install - checking
# the ETag alone would miss that and wrongly skip.
# =========================================================================

# Read whatever we saved from our last successful run, if any.
$lastEtag = $null
$lastHash = $null
if (Test-Path -LiteralPath $StateFile) {
    try {
        $state    = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        $lastEtag = $state.Etag
        $lastHash = $state.Sha256
    } catch {
        # State file exists but is unreadable/corrupt - treat as "no prior state".
        Write-Log "State file could not be read, treating as no prior state - $($_.Exception.Message)" 'WARN'
    }
}

# --- (a) Has the source file changed? ---

# Ask the server for just the headers (a HEAD request), not the file
# itself - fast and cheap since it downloads no content.
$currentEtag = $null
try {
    Set-SecurityProtocol
    $headRequest = [System.Net.HttpWebRequest]::Create($DownloadUrl)
    $headRequest.Method    = 'HEAD'
    $headRequest.Timeout   = 30000
    $headRequest.Proxy     = [System.Net.WebRequest]::GetSystemWebProxy()
    $headRequest.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    $headResponse = $headRequest.GetResponse()
    try {
        $currentEtag = $headResponse.Headers['ETag']
    } finally {
        $headResponse.Close()
    }
    Write-Log "Current file ETag from server: $(if ($currentEtag) { $currentEtag } else { '(none returned)' })"
} catch {
    # Not fatal - some servers don't support HEAD, and network hiccups
    # happen. We just can't compare, so we fall through to a download
    # rather than silently skipping a possibly-needed update. The SHA256
    # check after the download is what keeps this from turning into a
    # reinstall-every-run loop.
    Write-Log "Could not retrieve ETag via HEAD request - $($_.Exception.Message). Proceeding with download." 'WARN'
}

# --- (b) Is the sensor actually installed right now? ---

$installState = Get-SensorInstallState
Write-Log "Sensor installed on this machine: $($installState.Installed) ($($installState.Detail))"

# --- Decision ---

$etagUnchanged = $currentEtag -and $lastEtag -and ($currentEtag -eq $lastEtag)

if ($etagUnchanged -and $installState.Installed) {
    Write-Log "ETag is unchanged AND the sensor is installed. Nothing to do."
    Write-Log "=== Deployment complete (no-op) ==="
    exit 0
}

if (-not $installState.Installed) {
    Write-Log "Sensor is not installed on this machine - proceeding regardless of ETag."
} elseif (-not $currentEtag) {
    Write-Log "No ETag available to compare - downloading and comparing the package hash instead."
} else {
    Write-Log "Source file has changed since last install - proceeding."
}

# =========================================================================
# SECTION 5: DOWNLOAD
# =========================================================================

$zipPath     = Join-Path $WorkDir 'acium-sensor-setup.zip'
$extractPath = Join-Path $WorkDir 'extracted'

try {
    Write-Log "Downloading package..."
    Invoke-Download -Url $DownloadUrl -Destination $zipPath
    Write-Log "Download complete: $zipPath"
} catch {
    # $_.Exception.Message gives the actual reason (404, DNS failure, etc.).
    Write-Log "ERROR: Download failed - $($_.Exception.Message)" 'ERROR'
    exit 1
}

# --- Second change check: the package's own hash ---
#
# This is the one that doesn't depend on the server. If the bucket ever
# stops returning an ETag header - a config change, a proxy stripping
# headers - the old script's only change signal disappeared, and it would
# reinstall the MSI on every scheduled run across the whole fleet while
# reporting success every time. Comparing the actual bytes we downloaded
# against the bytes we last installed catches that regardless.
$currentHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
Write-Log "Package SHA256: $currentHash"

if ($lastHash -and ($currentHash -eq $lastHash) -and $installState.Installed) {
    Write-Log "Package is byte-identical to the last successful install and the sensor is installed. Skipping install."

    # Refresh the stored ETag so the cheap pre-download check can start
    # working again on the next run if the server has resumed sending one.
    if ($currentEtag -and ($currentEtag -ne $lastEtag)) {
        try {
            # Preserve the rest of the saved state (ProductCode/Version/
            # ScriptVersion/InstalledAt) - this is a no-op run, not an
            # install, so only the ETag actually needs refreshing.
            [ordered]@{
                Etag          = $currentEtag
                Sha256        = $state.Sha256
                ProductCode   = $state.ProductCode
                Version       = $state.Version
                ScriptVersion = $state.ScriptVersion
                InstalledAt   = $state.InstalledAt
            } | ConvertTo-Json | Set-Content -LiteralPath $StateFile
            Write-Log "Refreshed stored ETag for the next run's pre-download check."
        } catch {
            Write-Log "Could not refresh state file - $($_.Exception.Message)" 'WARN'
        }
    }

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Write-Log "=== Deployment complete (no-op) ==="
    exit 0
}

# =========================================================================
# SECTION 6: PREREQUISITE CHECK - ASP.NET CORE 8.0 RUNTIME
# AciumSensor.exe is a framework-dependent .NET 8.0 app - it requires
# Microsoft.AspNetCore.App 8.0.x to already be present, or the service
# fails to start and the MSI rolls itself back entirely (confirmed via a
# real failure: msiexec error 1603, underlying cause Windows Installer
# error 1920, "service failed to start"). We install it first if missing.
#
# This runs after the download and hash check so a genuine no-op run never
# has to touch it.
# =========================================================================

# If the ASP.NET Core 8.0 shared framework folder doesn't exist, treat the
# runtime as missing. This doesn't check the exact patch version - .NET's
# runtime resolution rolls forward to any newer 8.0.x patch, so any 8.0.x
# present is sufficient.
$AspNetCoreRuntimePath = 'C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App'
$aspNetCoreInstalled = (Test-Path -LiteralPath $AspNetCoreRuntimePath) -and
    ((Get-ChildItem -LiteralPath $AspNetCoreRuntimePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '8.0.*' }).Count -gt 0)

if ($aspNetCoreInstalled) {
    Write-Log "ASP.NET Core 8.0 Runtime already present."
} else {
    Write-Log "ASP.NET Core 8.0 Runtime not found. Installing it before deploying the sensor."

    # Microsoft's "Hosting Bundle" installs both the x86 and x64 .NET and
    # ASP.NET Core runtimes in one package. We use it instead of guessing at
    # architecture, since the sensor MSI installs under "Program Files (x86)"
    # which hints it may be a 32-bit package. This aka.ms link is maintained
    # by Microsoft to always redirect to the latest 8.0.x patch.
    $dotnetInstallerUrl  = 'https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe'
    $dotnetInstallerPath = Join-Path $WorkDir 'dotnet-hosting-8.0-win.exe'

    try {
        Write-Log "Downloading ASP.NET Core 8.0 Hosting Bundle..."
        Invoke-Download -Url $dotnetInstallerUrl -Destination $dotnetInstallerPath
        Write-Log "Download complete: $dotnetInstallerPath"
    } catch {
        Write-Log "ERROR: Failed to download ASP.NET Core Runtime installer - $($_.Exception.Message)" 'ERROR'
        exit 1
    }

    $rebootRequired = $false
    try {
        Write-Log "Installing ASP.NET Core 8.0 Hosting Bundle silently..."
        $dotnetArgs = @('/install', '/quiet', '/norestart')
        $dotnetProc = Start-Process -FilePath $dotnetInstallerPath -ArgumentList $dotnetArgs -Wait -PassThru

        if ($dotnetProc.ExitCode -eq 0) {
            Write-Log "ASP.NET Core 8.0 Runtime installed successfully."
        } elseif ($dotnetProc.ExitCode -eq 3010) {
            Write-Log "ASP.NET Core 8.0 Runtime installed, but a reboot is required to complete it."
            $rebootRequired = $true
        } else {
            Write-Log "ERROR: ASP.NET Core Runtime installer exited with code $($dotnetProc.ExitCode)." 'ERROR'
            exit 3
        }
    } catch {
        Write-Log "ERROR: ASP.NET Core Runtime install failed - $($_.Exception.Message)" 'ERROR'
        exit 3
    } finally {
        Remove-Item -LiteralPath $dotnetInstallerPath -Force -ErrorAction SilentlyContinue
    }

    # STOP HERE if the runtime needs a reboot.
    #
    # The old script logged 3010 as success and immediately ran the sensor
    # MSI - whose service must start for the install to commit. That is
    # precisely the 1603/1920 rollback this whole section exists to
    # prevent, so continuing would reproduce the bug the check was written
    # to avoid. Exit 0 (not a failure - nothing is broken, the work is just
    # incomplete) and let the next scheduled run finish once the machine
    # has rebooted. No state is saved, so the next run does the full
    # install.
    if ($rebootRequired) {
        Write-Log "Deferring the sensor install until after the pending reboot. The next scheduled run will complete it." 'WARN'
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Write-Log "=== Deployment deferred (reboot required for prerequisite) ==="
        exit 0
    }
}

# =========================================================================
# SECTION 7: EXTRACT
# Unzip the downloaded package and find the .msi installer inside it.
# =========================================================================

try {
    Write-Log "Extracting package..."

    # Clear any folder a previous run left behind, so we always work with a
    # clean copy of this version's files.
    if (Test-Path -LiteralPath $extractPath) {
        # Refuse to recursively delete through a junction/symlink. With the
        # ACL hardening above a non-admin shouldn't be able to plant one
        # here anymore, but -Recurse -Force following a reparse point as
        # SYSTEM is a well-known arbitrary-delete primitive and the check
        # is nearly free.
        $existing = Get-Item -LiteralPath $extractPath -Force
        if ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Log "Extraction path is a reparse point (junction/symlink), which is not expected. Removing the link only." 'WARN'
            [System.IO.Directory]::Delete($extractPath, $false)
        } else {
            Remove-Item -LiteralPath $extractPath -Recurse -Force
        }
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

    # Find the .msi we expect. Take the first match, in case there's more
    # than one.
    $msiFile = Get-ChildItem -LiteralPath $extractPath -Filter $MsiFileName -Recurse |
        Select-Object -First 1

    if (-not $msiFile) {
        # The zip downloaded and extracted fine, but didn't contain the
        # installer we expected - a failure, not a silent no-op.
        Write-Log "ERROR: $MsiFileName not found inside extracted package." 'ERROR'
        exit 5
    }

    Write-Log "Found installer: $($msiFile.FullName)"
} catch {
    Write-Log "ERROR: Extraction failed - $($_.Exception.Message)" 'ERROR'
    exit 5
}

# --- Authenticode check ---
#
# We're about to execute this MSI as SYSTEM on every endpoint in the fleet.
# The only thing vouching for it right now is TLS to the bucket. Checking
# the publisher signature is cheap defence in depth against a compromised
# or misconfigured bucket.
try {
    $signature     = Get-AuthenticodeSignature -LiteralPath $msiFile.FullName
    $signerSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '(none)' }
    # Extract just the CN (simple name) rather than matching against the raw
    # Subject string - a substring/wildcard match against the full Subject
    # would let a different, unrelated certificate whose Subject merely
    # contains the expected text (or wildcard characters) pass.
    $signerCN      = if ($signature.SignerCertificate) { $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '(none)' }
    Write-Log "MSI signature status: $($signature.Status). Signer: $signerSubject"

    if ($ExpectedPublisherCN) {
        if ($signature.Status -ne 'Valid') {
            Write-Log "ERROR: MSI signature is '$($signature.Status)', not 'Valid', and `$ExpectedPublisherCN is set. Refusing to install." 'ERROR'
            exit 6
        }
        if ($signerCN -ne $ExpectedPublisherCN) {
            Write-Log "ERROR: MSI is signed by '$signerSubject' (CN '$signerCN'), which does not match the expected publisher '$ExpectedPublisherCN'. Refusing to install." 'ERROR'
            exit 6
        }
        Write-Log "MSI signature verified against expected publisher."
    } elseif ($signature.Status -ne 'Valid') {
        Write-Log "MSI is not validly signed ($($signature.Status)). Continuing because `$ExpectedPublisherCN is not set - set it in SECTION 1 to enforce this." 'WARN'
    } else {
        Write-Log "MSI is validly signed. Set `$ExpectedPublisherCN to '$signerCN' in SECTION 1 to enforce this on every run." 'WARN'
    }
} catch {
    if ($ExpectedPublisherCN) {
        Write-Log "ERROR: Could not verify MSI signature - $($_.Exception.Message)" 'ERROR'
        exit 6
    }
    Write-Log "Could not verify MSI signature - $($_.Exception.Message). Continuing (enforcement is off)." 'WARN'
}

# =========================================================================
# SECTION 8: INSTALL
# Run the MSI silently - this runs unattended as SYSTEM with nobody
# watching, so no dialog boxes and no user interaction.
# =========================================================================

try {
    # --- Is this a first-time install or a reinstall? ---
    #
    # Getting this wrong in either direction is bad:
    #
    #   * REINSTALL=ALL / REINSTALLMODE=vomus on a genuine FIRST-TIME
    #     install makes Windows Installer resolve every component's action
    #     to Null - it silently does nothing (no files, no service) while
    #     reporting exit code 0 and "Installation completed successfully."
    #     Confirmed by diffing an MSI log with REINSTALL=ALL (every
    #     component "Action: Null") against a plain /i on the same machine
    #     (every component "Action: Local").
    #
    #   * A plain /i against a ProductCode Windows Installer already has
    #     recorded fails with 1638, "another version of this product is
    #     already installed."
    #
    # So the branch has to be right. Ask Windows Installer itself via
    # ProductState (5 = installed, negative = not) - the same API msiexec
    # consults internally, unaffected by 32/64-bit registry redirection.
    #
    # AND cross-check the registry, because ProductState is only as good as
    # the ProductCode we hand it. If $ProductCode is wrong, ProductState
    # answers "not installed" for every machine, we take the first-time
    # branch on an existing install, and hit 1638 - while the header
    # comment claims the problem is solved. The cross-check catches that
    # and logs the real ProductCode.
    $effectiveProductCode = $ProductCode
    $isProductInstalled   = $false

    $productState = $null
    if ($ProductCode) {
        try {
            $installerCom = New-Object -ComObject WindowsInstaller.Installer
            $productState = $installerCom.ProductState($ProductCode)
            $isProductInstalled = ($productState -eq 5)
            Write-Log "Windows Installer ProductState for ${ProductCode}: $productState (installed: $isProductInstalled)"
        } catch {
            # A malformed GUID or a COM problem must not fail the whole run
            # as an "install failure" before we've even tried to install.
            Write-Log "Could not query ProductState for ${ProductCode} - $($_.Exception.Message). Falling back to the registry." 'WARN'
        }
    }

    $discovered = Find-InstalledProduct
    if ($discovered) {
        Write-Log "Registry shows an installed product: '$($discovered.DisplayName)' version $($discovered.Version), ProductCode $($discovered.ProductCode)"

        if (-not $isProductInstalled) {
            # Only trust a name match if the sensor is ACTUALLY on this
            # machine. Without this gate, a registry entry that merely
            # matched $DisplayNamePattern - a different Acium-branded MSI,
            # a companion package - would flip us onto the reinstall path
            # for a machine where the sensor was never installed, and
            # REINSTALL=ALL on a first-time install resolves every
            # component to Action: Null. That's the silent do-nothing
            # install this whole branch exists to avoid.
            #
            # The asymmetry decides the default: guessing "reinstall" wrong
            # installs nothing while looking successful; guessing
            # "first-time" wrong produces 1638, which is a clean,
            # diagnosable error. When in doubt, stay on first-time.
            if ($installState.Installed) {
                Write-Log "MISMATCH: the ProductCode configured in SECTION 1 ($ProductCode) is not registered as installed, but '$($discovered.DisplayName)' is and the sensor is present on this machine. Using the discovered ProductCode instead." 'WARN'
                Write-Log "ACTION: update `$ProductCode in SECTION 1 to $($discovered.ProductCode) - until you do, this fallback runs on every machine." 'WARN'
                $effectiveProductCode = $discovered.ProductCode
                $isProductInstalled   = $true
            } else {
                Write-Log "Registry matched '$($discovered.DisplayName)', but the sensor itself is not installed here ($($installState.Detail)). Not trusting that match - treating this as a first-time install." 'WARN'
            }
        }
    } elseif ($isProductInstalled) {
        # ProductState says installed but nothing matched by name - most
        # likely $DisplayNamePattern is too narrow. Trust ProductState.
        Write-Log "ProductState reports installed but no registry entry matched '$DisplayNamePattern'. Trusting ProductState." 'WARN'
    }

    Write-Log "Install mode: $(if ($isProductInstalled) { 'reinstall/repair over existing install' } else { 'first-time install' })"
    Write-Log "Running msiexec silently..."

    # Rotate the MSI log, then append rather than truncate - the old script
    # overwrote it on every run, so by the time anyone looked at a machine
    # the log of the failure they cared about was already gone.
    if ((Test-Path -LiteralPath $MsiLogFile) -and ((Get-Item -LiteralPath $MsiLogFile).Length -gt $MaxLogBytes)) {
        Move-Item -LiteralPath $MsiLogFile -Destination "$MsiLogFile.1" -Force -ErrorAction SilentlyContinue
    }

    # msiexec arguments:
    #   /i <path>          = install this MSI
    #   /qn                = quiet, no UI - fully silent
    #   /norestart         = never auto-reboot the machine
    #   /l*v+ <path>       = verbose log, appended
    #   ORGANIZATION=...   = tenant/org ID; an MSI property the installer
    #                        defines itself (listed in its own
    #                        SecureCustomProperties, with a dedicated
    #                        OrganizationIdComponent)
    #
    # Built as one explicit string rather than a PowerShell array. The
    # array form looks safer but isn't here: PowerShell 5.1 quotes any
    # array element containing a space, so an $Organization of "my org"
    # became  "ORGANIZATION=my org"  on the command line, which msiexec
    # parses as a malformed property. MSI properties need the quotes
    # *inside* the argument -  ORGANIZATION="my org"  - which only building
    # the string ourselves gets right. ($Organization is validated for
    # embedded quotes in SECTION 2.)
    $argParts = @('/i', ('"{0}"' -f $msiFile.FullName))
    if ($isProductInstalled) {
        $argParts += @('REINSTALL=ALL', 'REINSTALLMODE=vomus')
    }
    if ($Organization) {
        $argParts += ('ORGANIZATION="{0}"' -f $Organization)
    }
    $argParts += @('/qn', '/norestart', '/l*v+', ('"{0}"' -f $MsiLogFile))
    $msiArgLine = $argParts -join ' '

    Write-Log "msiexec $msiArgLine"

    # 1618 means another Windows Installer transaction is in progress -
    # extremely common when an RMM fires several deployments at once, or
    # Windows Update is mid-install. It's transient, so retry rather than
    # reporting a deployment failure.
    $maxMsiAttempts = 4
    $exitCode = $null
    for ($attempt = 1; $attempt -le $maxMsiAttempts; $attempt++) {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgLine -Wait -PassThru
        $exitCode = $proc.ExitCode

        if ($exitCode -ne 1618) { break }

        if ($attempt -lt $maxMsiAttempts) {
            Write-Log "msiexec returned 1618 (another install in progress). Attempt $attempt of $maxMsiAttempts; waiting before retry." 'WARN'
            Start-Sleep -Seconds 60
        }
    }

    # msiexec exit codes:
    #   0    = installed successfully
    #   3010 = installed successfully, reboot needed to finish (normal)
    #   1618 = another install was in progress and never cleared
    #   else = something went wrong
    if ($exitCode -eq 0) {
        Write-Log "Install completed successfully."
    } elseif ($exitCode -eq 3010) {
        Write-Log "Install completed successfully (reboot required to finish)."
    } elseif ($exitCode -eq 1618) {
        Write-Log "ERROR: msiexec still reported 1618 after $maxMsiAttempts attempts - another installation is occupying Windows Installer. See $MsiLogFile." 'ERROR'
        exit 3
    } else {
        Write-Log "ERROR: msiexec exited with code $exitCode. See $MsiLogFile for details." 'ERROR'
        exit 3
    }

    # Confirm the install actually did something. This is the direct guard
    # against the "Action: Null" failure mode - a clean exit code alone is
    # not evidence that anything was installed.
    $postState = Get-SensorInstallState
    if ($postState.Installed) {
        Write-Log "Post-install verification: sensor is present ($($postState.Detail))."
    } elseif ($exitCode -eq 3010) {
        Write-Log "Post-install verification: sensor not detected yet, but a reboot is pending, which is expected." 'WARN'
    } else {
        # Do not save state - we want the next run to try again rather than
        # skip on an ETag match for an install that didn't take.
        Write-Log "ERROR: msiexec reported success but the sensor is not installed ($($postState.Detail)). Check $MsiLogFile for 'Action: Null' on every component." 'ERROR'
        exit 3
    }
} catch {
    Write-Log "ERROR: Install failed - $($_.Exception.Message)" 'ERROR'
    exit 3
}

# =========================================================================
# SECTION 9: SAVE STATE
# Record what we just installed so the NEXT run of this recurring job can
# compare against it and skip if nothing changed. We only reach here if the
# install succeeded AND verified - state is never saved for a run that
# failed or silently installed nothing.
# =========================================================================

try {
    @{
        Etag          = $currentEtag
        Sha256        = $currentHash
        ProductCode   = $effectiveProductCode
        Version       = $TargetVersion
        ScriptVersion = $ScriptVersion
        InstalledAt   = (Get-Date -Format 'o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile

    Write-Log "Saved state for next run's change check (SHA256 $currentHash$(if ($currentEtag) { ", ETag $currentEtag" } else { ', no ETag' }))."
} catch {
    # Not fatal to this run - the install already succeeded. It just means
    # the next run has nothing to compare against and will reinstall.
    Write-Log "Could not save state file - $($_.Exception.Message). The next run will reinstall." 'WARN'
}

# =========================================================================
# SECTION 10: CLEANUP
# Delete the downloaded zip and extracted files so we don't leave junk on
# every machine we deploy to.
# =========================================================================

# SilentlyContinue: if these are already gone or locked, don't fail the
# whole script over a cleanup step - the install already succeeded, which
# is what actually matters.
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "=== Deployment complete (installed $(if ($TargetVersion) { $TargetVersion } else { 'agent' })) ==="
exit 0
