# Acium Sensor — Datto RMM Deployment Script

This repo contains `Deploy-Agent.ps1`, a PowerShell script that installs and keeps the Acium Sensor up to date across a fleet of Windows endpoints via Datto RMM.

It's designed to run as a **recurring Datto RMM Component**, safely skipping machines that are already up to date and only reinstalling when something's actually changed.

## What the script does

On each run, in order:

1. **Checks whether anything's changed** — compares the source file's ETag (a fingerprint from the download server) against what was saved from the last successful run, *and* checks whether the `AciumSensor` process is currently running. Only skips the rest of the script if both say "nothing to do."
2. **Checks for the ASP.NET Core 8.0 Runtime** — a hard requirement for the sensor to run. If it's missing, silently installs Microsoft's official Hosting Bundle before doing anything else.
3. **Downloads** the sensor package (a `.zip`) from a URL.
4. **Extracts** the `.zip` and locates `AciumSensorInstall.msi` inside it.
5. **Installs** the MSI silently via `msiexec`.
6. **Cleans up** downloaded files and records the new ETag for next time.

The script is intended to be idempotent and safe to run on a schedule — a machine that's already current will do almost nothing (a quick network check, then exit).

## Prerequisites

- Datto RMM agent installed and checking in on target endpoints.
- Endpoints running Windows with PowerShell 5.1 (Windows PowerShell, not PowerShell Core) — this is what Datto RMM Components run under by default.
- Outbound HTTPS access from endpoints to your sensor package's download URL and to `aka.ms` (for the ASP.NET Core Runtime installer, only needed on machines that don't already have it).

## Setup in Datto RMM

### 1. Create a new Component

In Datto RMM, go to **Automation > Components > New Component**, and choose a **PowerShell (or "Script")** component type.

### 2. Paste in the script

Copy the contents of `Deploy-Agent.ps1` into the Component's script body.

### 3. Add the Component Variable

This script needs exactly one input, set as a **Component Variable**:

| Variable name | Type | Example value |
|---|---|---|
| `AgentDownloadUrl` | String | `https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup-0.16.8.zip` |

> Bumping to a new sensor version later is just updating this one variable — you don't need to edit the script itself.

### 4. Set execution context

Set the Component to run as **System** (not "Logged on user"). This is usually the default, but double-check it — running as anything other than System can surface Windows security prompts (UAC) that a background service context never would.

### 5. Deploy as a recurring Job

Assign the Component to a Job/Policy that runs on a recurring schedule (e.g. daily) against your target device group or filter. Because the script checks for changes before doing any real work, recurring execution is cheap — most runs will be a quick no-op.

## Logs

The script writes its own logs to the endpoint, independent of what Datto RMM captures:

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
| `4` | Missing required Component Variable (`AgentDownloadUrl`) |
| `5` | Zip extracted successfully, but `AciumSensorInstall.msi` wasn't found inside it |

Datto RMM surfaces these in the job/dashboard results, so a quick glance tells you whether a failure was a network issue, a missing variable, or an actual install problem.

## Known dependencies

- **ASP.NET Core 8.0 Runtime** is required for the sensor service to start. The script checks for and installs this automatically, but it does add extra time (and a download) the first time it runs on any given machine. Subsequent runs skip this once the runtime is present.
- The sensor's `.zip` package must contain a file named exactly `AciumSensorInstall.msi` — the script searches for this filename specifically.

## Troubleshooting

- **UAC prompt appears on the client**: This shouldn't happen if the Component is genuinely running as System — SYSTEM-context execution never triggers UAC. If you see this, first confirm the Component's execution context, then check `deploy.log`'s `Running as:` line to see what account actually ran the script.
- **Install seems to succeed but the sensor doesn't run**: Check whether the ASP.NET Core 8.0 Runtime installed successfully in `deploy.log`, and confirm via `Get-Process AciumSensor` on the endpoint. If the runtime is present and the process still isn't running, check `msi-install.log` for the `Feature: Main; ... Action:` line — if it says `Action: Null` for every component (instead of `Action: Local`), Windows Installer silently did nothing (see the exit-code-3/1638 entry below for why, and confirm you're running a version of this script with the ProductState check — older copies always passed `REINSTALL=ALL` and could hit exactly this).
- **Script always reinstalls, never skips**: Check that the download URL returns an `ETag` header (most servers, including Google Cloud Storage, do this by default) and that `last-installed.json` is being written and persisted between runs.
- **Install fails with exit code 3 and `msi-install.log` shows error 1638 ("Another version of this product is already installed")**: The sensor's MSI keeps the same `ProductCode` across versions, so Windows Installer refuses a plain reinstall whenever that `ProductCode` is already registered — most commonly because the sensor was installed manually at some point (outside this script), so there's no `last-installed.json` to make the script skip it. The script now checks whether the product is already installed via Windows Installer's own `ProductState` API and only adds `REINSTALL=ALL REINSTALLMODE=vomus` in that case — those properties are needed to force a reinstall over an existing registration, but must NOT be passed on a genuine first-time install: doing so makes Windows Installer resolve every component's install action to `Null`, silently installing nothing while still reporting exit code 0. If you still see 1638, confirm the deployed script includes the `ProductState` check (look for `$isProductInstalled` in SECTION 7) rather than an older copy that always passed those properties.
