# Acium Sensor — Generic Deployment Script

This folder contains `generic-acium.ps1`, a PowerShell script that installs and keeps the Acium Sensor up to date across Windows endpoints.

It's the same deployment logic as the [Datto RMM version](../dattormm/dattormm-acium.ps1), but **all configuration is hardcoded directly in the script** instead of being read from Datto's Component Variable system. That makes it drop-in usable from any RMM platform (NinjaOne, ConnectWise, Action1, etc.), a scheduled task, or manual execution — nothing in the script depends on a platform-specific variable/parameter mechanism.

## What the script does

On each run, in order:

1. **Checks whether anything's changed** — compares the source file's ETag (a fingerprint from the download server) against what was saved from the last successful run, *and* checks whether the `AciumSensor` process is currently running. Only skips the rest of the script if both say "nothing to do."
2. **Checks for the ASP.NET Core 8.0 Runtime** — a hard requirement for the sensor to run. If it's missing, silently installs Microsoft's official Hosting Bundle before doing anything else.
3. **Downloads** the sensor package (a `.zip`) from a URL.
4. **Extracts** the `.zip` and locates `AciumSensorInstall.msi` inside it.
5. **Installs** the MSI silently via `msiexec`.
6. **Cleans up** downloaded files and records the new ETag for next time.

The script is intended to be idempotent and safe to run on a schedule — a machine that's already current will do almost nothing (a quick network check, then exit).

## Configuration

Unlike the Datto RMM version, there's no variable to set anywhere — everything needed is baked into the script itself. Open `generic-acium.ps1` and edit the value between the `EDIT THESE VALUES TO CONFIGURE A DEPLOYMENT` markers near the top of **SECTION 1: CONFIG**:

```powershell
$DownloadUrl = 'https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup.zip'
```

Set this to the direct URL of the pinned agent `.zip`. Bumping to a new sensor version later means editing this line and redeploying the script — there is no external variable to update instead.

## Prerequisites

- Endpoints running Windows with PowerShell 5.1 (Windows PowerShell, not PowerShell Core) or later.
- The script must run with local Administrator / SYSTEM privileges (it installs software and writes to `C:\ProgramData`).
- Outbound HTTPS access from endpoints to your sensor package's download URL and to `aka.ms` (for the ASP.NET Core Runtime installer, only needed on machines that don't already have it).

## Deploying it

Since this version has no RMM-specific variable requirement, deployment is just: **run the script as SYSTEM/Administrator on the target machine, on a recurring basis.** How you schedule that is up to your platform:

- **Any RMM tool**: paste the script body into a script/component of that platform, set it to run as System/Administrator, and schedule it recurring (e.g. daily). Because the script checks for changes before doing any real work, recurring execution is cheap — most runs will be a quick no-op.
- **Windows Scheduled Task**: create a task that runs `powershell.exe -ExecutionPolicy Bypass -File generic-acium.ps1` as `SYSTEM`, triggered on your preferred recurring schedule.
- **Manual / ad hoc**: run it directly from an elevated PowerShell prompt.

## Logs

The script writes its own logs to the endpoint, independent of whatever's running it:

| File | What's in it |
|---|---|
| `C:\ProgramData\AciumSensor\Logs\deploy.log` | The script's own step-by-step log — what it checked, downloaded, and decided on each run. |
| `C:\ProgramData\AciumSensor\Logs\msi-install.log` | Windows Installer's verbose log for the actual MSI install — useful for diagnosing install failures. |
| `C:\ProgramData\AciumSensor\Install\last-installed.json` | Small state file recording the ETag of the last successfully installed package, used for the change check. |

If a deployment isn't behaving as expected, `deploy.log` is the first place to look — it logs which account it's running as, the ETag comparison result, whether the ASP.NET Core Runtime was found, and the final `msiexec` exit code.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — installed, or already up to date (no-op) |
| `1` | Download failed (sensor package or ASP.NET Core Runtime installer) |
| `3` | Install failed (sensor MSI or ASP.NET Core Runtime installer) |
| `4` | Missing required configuration value (`$DownloadUrl` left empty in the script) |
| `5` | Zip extracted successfully, but `AciumSensorInstall.msi` wasn't found inside it |

Whatever runs this script can read these to tell whether a failure was a network issue, a misconfigured script, or an actual install problem.

## Known dependencies

- **ASP.NET Core 8.0 Runtime** is required for the sensor service to start. The script checks for and installs this automatically, but it does add extra time (and a download) the first time it runs on any given machine. Subsequent runs skip this once the runtime is present.
- The sensor's `.zip` package must contain a file named exactly `AciumSensorInstall.msi` — the script searches for this filename specifically.

## Troubleshooting

- **Script exits with code 4**: `$DownloadUrl` in SECTION 1 is empty — this shouldn't happen unless the script was edited and the value was accidentally cleared. Set it to the sensor package URL.
- **Install seems to succeed but the sensor doesn't run**: Check whether the ASP.NET Core 8.0 Runtime installed successfully in `deploy.log`, and confirm via `Get-Process AciumSensor` on the endpoint.
- **Script always reinstalls, never skips**: Check that the download URL returns an `ETag` header (most servers, including Google Cloud Storage, do this by default) and that `last-installed.json` is being written and persisted between runs.
- **Install fails with exit code 3 and `msi-install.log` shows error 1638 ("Another version of this product is already installed")**: The sensor's MSI keeps the same `ProductCode` across versions, so Windows Installer refuses a plain reinstall whenever that `ProductCode` is already registered — most commonly because the sensor was installed manually at some point (outside this script), so there's no `last-installed.json` to make the script skip it. The script installs with `REINSTALL=ALL REINSTALLMODE=vomus`, which forces a reinstall over an existing registration instead of hitting this error; if you still see 1638, confirm the deployed script actually includes those properties.

## Relationship to the Datto RMM version

This script is functionally identical to [`../dattormm/dattormm-acium.ps1`](../dattormm/dattormm-acium.ps1) — same download/ETag-check/install/cleanup logic, same exit codes, same log locations. The only difference is where `$DownloadUrl` comes from: the Datto version reads it from a Component Variable (`$env:AgentDownloadUrl`) set in Datto's UI; this version has it hardcoded in the script. If you fix a bug or add a feature in one, port the change to the other.
