#Requires -Version 5.0

<#
.SYNOPSIS
    Detection half of the Acium Sensor Intune Remediation. Read-only -
    makes no changes to the machine. Reports "compliant" (exit 0) if the
    sensor is installed and up to date, or "non-compliant" (exit 1) to
    trigger intune-acium-remediation.ps1.

.DESCRIPTION
    Intune runs this on the Remediation's schedule (and once immediately
    on assignment), in the SYSTEM context. If it exits 1, Intune
    immediately runs intune-acium-remediation.ps1 on the same device.

    The check is the same one the remediation script uses internally to
    decide whether to skip a run:
      (a) is the AciumSensor service present at all, and
      (b) does the source file's ETag match what was recorded at the last
          successful install
    Both must hold for "compliant" - if the sensor was manually
    uninstalled, the source file hasn't changed, but the machine still
    needs remediation, so ETag agreement alone isn't enough.

    This script deliberately does NOT download the package or touch
    Windows Installer - Microsoft's guidance for Remediations is that
    detection scripts should be non-invasive, and duplicating the actual
    install logic here would only give it more ways to disagree with
    intune-acium-remediation.ps1. See .NOTES in that file for why
    $DownloadUrl must be kept identical between the two scripts.

.NOTES
    VERSION: tracked together with intune-acium-remediation.ps1's
    $ScriptVersion - this file doesn't do enough independently to warrant
    its own version number. Bump both when either changes, and record it
    in CHANGELOG.md.

    Exit codes (Intune's Remediations convention, NOT this repo's shared
    exit-code table - Remediations only recognize compliant/non-compliant):
        0   - Compliant. Sensor is installed and ETag matches last install.
        1   - Non-compliant. Triggers intune-acium-remediation.ps1.
#>

# =========================================================================
# CONFIG - MUST match intune-acium-remediation.ps1
# =========================================================================

$ErrorActionPreference = 'Stop'

# Keep this identical to $DownloadUrl in intune-acium-remediation.ps1. This
# script only reads the server's ETag for the comparison below - it never
# downloads the file - but if the two URLs disagree, this script can
# report "compliant" for a version the remediation script would actually
# install.
$DownloadUrl = 'https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup-0.16.8.zip'

# Must match intune-acium-remediation.ps1's SECTION 1 values.
$ServiceName = 'AciumSensor'
$ProcessName = 'AciumSensor'
$RootDir     = 'C:\ProgramData\AciumSensor'
$LogDir      = Join-Path $RootDir 'Logs'
$WorkDir     = Join-Path $RootDir 'Install'
$LogFile     = Join-Path $LogDir 'deploy.log'
$StateFile   = Join-Path $WorkDir 'last-installed.json'

# Append to the same deploy.log the remediation script writes, so a
# machine's history reads as one continuous timeline of detect/remediate
# cycles rather than two disconnected logs. Best-effort: detection must
# never fail just because the log directory doesn't exist yet (e.g. this
# is the very first run on a device, before the remediation script has
# ever created it).
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] [detect] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    try {
        if (Test-Path -LiteralPath $LogDir) {
            Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
        }
    } catch {
        $null = $_
    }
}

function Set-SecurityProtocol {
    $current = [Net.ServicePointManager]::SecurityProtocol
    if ($current -eq 0) { return }
    $want = $current -bor [Net.SecurityProtocolType]::Tls12
    try { $want = $want -bor [Net.SecurityProtocolType]::Tls13 } catch { $null = $_ }
    [Net.ServicePointManager]::SecurityProtocol = $want
}

# =========================================================================
# (a) Is the sensor installed?
# =========================================================================

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$process = if (-not $service) { Get-Process -Name $ProcessName -ErrorAction SilentlyContinue } else { $null }
$installed = [bool]($service -or $process)

if (-not $installed) {
    Write-Log "Sensor not installed (no '$ServiceName' service, no '$ProcessName' process). Non-compliant."
    Write-Host "Acium Sensor is not installed."
    exit 1
}

# =========================================================================
# (b) Does the source file's ETag match the last successful install?
# =========================================================================

$lastEtag = $null
if (Test-Path -LiteralPath $StateFile) {
    try {
        $lastEtag = (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).Etag
    } catch {
        Write-Log "State file could not be read - $($_.Exception.Message). Treating as no prior state." 'WARN'
    }
}

if (-not $lastEtag) {
    # No record of a successful install's ETag (state file missing/corrupt,
    # or the server has never returned one). We can't prove nothing
    # changed, so let the remediation script's own download+hash check
    # settle it rather than guessing "compliant" here.
    Write-Log "Sensor service is present but no prior ETag is recorded. Non-compliant (letting remediation confirm via package hash)." 'WARN'
    Write-Host "Acium Sensor is installed, but no prior install state is recorded - running remediation to confirm."
    exit 1
}

$currentEtag = $null
try {
    Set-SecurityProtocol
    $headRequest = [System.Net.HttpWebRequest]::Create($DownloadUrl)
    $headRequest.Method            = 'HEAD'
    $headRequest.Timeout           = 30000
    $headRequest.Proxy             = [System.Net.WebRequest]::GetSystemWebProxy()
    $headRequest.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    $headResponse = $headRequest.GetResponse()
    try {
        $currentEtag = $headResponse.Headers['ETag']
    } finally {
        $headResponse.Close()
    }
} catch {
    # Can't reach the server to compare. Sensor IS installed, so err
    # towards "compliant" rather than triggering a remediation run that
    # will just fail the same download and report a spurious failure.
    Write-Log "Could not retrieve ETag via HEAD request - $($_.Exception.Message). Sensor is installed; reporting compliant for now." 'WARN'
    Write-Host "Acium Sensor is installed. Could not reach the download server to check for updates this cycle."
    exit 0
}

if ($currentEtag -and ($currentEtag -eq $lastEtag)) {
    Write-Log "Sensor installed and ETag unchanged ($currentEtag). Compliant."
    Write-Host "Acium Sensor is installed and up to date."
    exit 0
}

Write-Log "Sensor installed but ETag differs (current: $(if ($currentEtag) { $currentEtag } else { '(none)' }), last: $lastEtag). Non-compliant."
Write-Host "Acium Sensor is installed but a newer package is available."
exit 1
