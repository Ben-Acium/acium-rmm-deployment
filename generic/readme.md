# Acium Sensor — Generic Deployment Script

This folder contains `generic-acium.ps1`, a PowerShell script that installs and keeps the Acium Sensor up to date across Windows endpoints.

**All configuration is hardcoded directly in the script** instead of being read from an external variable system. That makes it drop-in usable from any RMM platform (NinjaOne, ConnectWise, Action1, etc.), a scheduled task, or manual execution — nothing in the script depends on a platform-specific variable/parameter mechanism.

## What the script does

On each run, in order:

1. **Takes a machine-wide lock** so an overlapping run (a slow previous run plus a new scheduled trigger, or a manual run stacked on a scheduled one) can't run twice at once.
2. **Checks whether anything's changed** — compares the source file's ETag (a fingerprint from the download server) against what was saved from the last successful run, *and* checks whether the `AciumSensor` Windows service is present (not just whether its process happens to be running right now). Only skips the rest of the script if both say "nothing to do."
3. **Downloads** the sensor package (a `.zip`) and hashes it (SHA256) as a second, server-independent change check, in case the server ever stops sending an ETag.
4. **Checks for the ASP.NET Core 8.0 Runtime** — a hard requirement for the sensor to run. If it's missing, silently installs Microsoft's official Hosting Bundle before doing anything else. If that install needs a reboot, the script defers the sensor install to the next scheduled run rather than installing against a runtime that can't start yet.
5. **Extracts** the `.zip`, locates `AciumSensorInstall.msi` inside it, and checks its Authenticode signature.
6. **Installs** the MSI silently via `msiexec`, correctly distinguishing a first-time install from a reinstall (see Known dependencies below for why that distinction matters), and verifies afterward that the sensor is actually present.
7. **Cleans up** downloaded files and records the new ETag/SHA256 for next time — only after a verified successful install.

The script is intended to be idempotent and safe to run on a schedule — a machine that's already current will do almost nothing (a quick network check, then exit).

## Configuration

There's no variable to set anywhere — everything needed is baked into the script itself. Open `generic-acium.ps1` and edit the values between the `EDIT THESE VALUES TO CONFIGURE A DEPLOYMENT` markers near the top of **SECTION 1: CONFIG**:

```powershell
$DownloadUrl = 'https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup-0.17.3.zip'
$Organization = ''
```

- `$DownloadUrl` — the direct URL of the pinned agent `.zip`. **Required** — the script exits with code `4` and logs that it's missing if left blank. Bumping to a new sensor version later means editing this line and redeploying the script — there is no external variable to update instead.
- `$Organization` — the organization/tenant ID these endpoints belong to. **Optional** — when set, it's passed to the MSI as the `ORGANIZATION` property so the installed sensor reports in under the right org; when left blank, the install just proceeds without setting that property.

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
| `C:\ProgramData\AciumSensor\Install\last-installed.json` | Small state file recording the ETag and SHA256 of the last successfully installed package, used for the change check. |

If a deployment isn't behaving as expected, `deploy.log` is the first place to look — it logs which account it's running as, the ETag comparison result, whether the ASP.NET Core Runtime was found, and the final `msiexec` exit code.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — installed, already up to date (no-op), or deferred pending a reboot (see the log for which) |
| `1` | Download failed (sensor package or ASP.NET Core Runtime installer) |
| `2` | Could not secure the working/log directory (ACL hardening failed) — refused to proceed with a privileged install |
| `3` | Install failed (sensor MSI or ASP.NET Core Runtime installer) |
| `4` | Missing or invalid configuration value (`$DownloadUrl` left empty, or `$Organization` contains a double quote) |
| `5` | Zip extracted successfully, but `AciumSensorInstall.msi` wasn't found inside it |
| `6` | MSI failed Authenticode signature verification against `$ExpectedPublisherCN` |

Whatever runs this script can read these to tell whether a failure was a network issue, a misconfigured script, or an actual install problem.

## Known dependencies

- **ASP.NET Core 8.0 Runtime** is required for the sensor service to start. The script checks for and installs this automatically, but it does add extra time (and a download) the first time it runs on any given machine. Subsequent runs skip this once the runtime is present.
- The sensor's `.zip` package must contain a file named exactly `AciumSensorInstall.msi` — the script searches for this filename specifically.

## Troubleshooting

- **Script exits with code 2**: The script couldn't lock down `$LogDir` or `$WorkDir`'s permissions (`Set-Acl`/`Get-Acl` failed), so it refused to proceed rather than stage/execute a privileged MSI in a directory that might still be writable by non-admins. This should be very rare when running as SYSTEM — check `deploy.log` for the exact directory and investigate why an ACL change failed there (endpoint security software, filesystem issue, or an already-tampered-with directory are the likely causes).
- **Script exits with code 4**: `$DownloadUrl` in SECTION 1 is empty — this shouldn't happen unless the script was edited and the value was accidentally cleared. Set it to the sensor package URL. (`$Organization` being empty is fine — it's optional; a double quote inside it is not.)
- **Install seems to succeed but the sensor doesn't run**: Check whether the ASP.NET Core 8.0 Runtime installed successfully in `deploy.log`, and confirm via `Get-Service AciumSensor` on the endpoint. If the runtime is present and the service still isn't there, check `msi-install.log` for the `Feature: Main; ... Action:` line — if it says `Action: Null` for every component (instead of `Action: Local`), Windows Installer silently did nothing (see the exit-code-3/1638 entry below for why, and confirm you're running a version of this script with the ProductState check — older copies always passed `REINSTALL=ALL` and could hit exactly this).
- **Script always reinstalls, never skips**: Check that the download URL returns an `ETag` header (most servers, including Google Cloud Storage, do this by default) and that `last-installed.json` is being written and persisted between runs.
- **Install fails with exit code 3 and `msi-install.log` shows error 1638 ("Another version of this product is already installed")**: The sensor's MSI keeps the same `ProductCode` across versions, so Windows Installer refuses a plain reinstall whenever that `ProductCode` is already registered — most commonly because the sensor was installed manually at some point (outside this script), so there's no `last-installed.json` to make the script skip it. The script checks whether the product is already installed via Windows Installer's own `ProductState` API and only adds `REINSTALL=ALL REINSTALLMODE=vomus` in that case — those properties are needed to force a reinstall over an existing registration, but must NOT be passed on a genuine first-time install: doing so makes Windows Installer resolve every component's install action to `Null`, silently installing nothing while still reporting exit code 0. If you still see 1638, confirm the deployed script includes the `ProductState` check (look for `$isProductInstalled` in SECTION 8) rather than an older copy that always passed those properties.
- **Script exits 0 but nothing was installed and the log says "deferred"**: The ASP.NET Core Hosting Bundle needed a reboot to finish. This is expected — the script intentionally stops rather than installing the sensor against a runtime that can't start yet. The next scheduled run completes the install once the machine has rebooted.
